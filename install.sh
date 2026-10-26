#!/usr/bin/env bash
# ct installer — sets up the workspace root and the ct toolchain.
#
#   curl -fsSL https://raw.githubusercontent.com/jonatanolofsson/ct/<tag>/install.sh | bash
#   ./install.sh          # from a checkout
#
# Idempotent: safe to re-run at every boot. Environment:
#   CT_HOME    workspace root                (default: ~/dev)
#   CT_PREFIX  where binaries go             (default: ~/.local/bin)
#   CT_REF     tag/branch to fetch when run  (default: main)
#              without a checkout (curl mode)
#
# What it does:
#   1. installs bin/{ct,ct-autostart,ensure-nix,ct-scratch-guard} into CT_PREFIX
#   2. writes the generic workspace conventions into CT_HOME/CLAUDE.md inside
#      a <!-- BEGIN ct-managed --> marker block (hand edits outside survive;
#      site layers add their own block — see docs/bootstrap-integration.md)
#   3. seeds ~/.claude/settings.json from the template ONLY if none exists,
#      then adds what later releases need (plansDirectory, the scratch guard)
#   4. stamps ~/.local/share/ct/VERSION
set -euo pipefail

CT_HOME="${CT_HOME:-$HOME/dev}"
CT_PREFIX="${CT_PREFIX:-$HOME/.local/bin}"
CT_REF="${CT_REF:-main}"

say() { printf 'ct-install: %s\n' "$*" >&2; }

# --- locate the payload: a checkout next to this script, or fetch a tarball -
srcdir=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "$(dirname "${BASH_SOURCE[0]}")/bin/ct" ]; then
    srcdir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    say "fetching ct@${CT_REF} ..."
    curl -fsSL --max-time 120 \
        "https://codeload.github.com/jonatanolofsson/ct/tar.gz/refs/tags/${CT_REF}" \
        -o "$tmp/ct.tar.gz" 2>/dev/null \
      || curl -fsSL --max-time 120 \
        "https://codeload.github.com/jonatanolofsson/ct/tar.gz/refs/heads/${CT_REF}" \
        -o "$tmp/ct.tar.gz"
    tar -xzf "$tmp/ct.tar.gz" -C "$tmp"
    # GitHub's archives carry the commit in a pax header; without this, curl
    # mode — what every bootstrap runs — stamped VERSION with "unknown".
    tarball_commit="$(gzip -dc "$tmp/ct.tar.gz" | git get-tar-commit-id 2>/dev/null | cut -c1-7 || true)"
    srcdir="$(find "$tmp" -maxdepth 1 -type d -name 'ct-*' | head -1)"
    if [ -z "$srcdir" ] || [ ! -f "$srcdir/bin/ct" ]; then
        say "payload missing bin/ct — aborting, nothing changed"; exit 1
    fi
fi

# --- 1. binaries (replace only on success; old copies survive any failure) --
mkdir -p "$CT_PREFIX"
for tool in ct ct-autostart ensure-nix ct-scratch-guard; do
    install -m 0755 "$srcdir/bin/$tool" "$CT_PREFIX/$tool"
done
say "installed ct, ct-autostart, ensure-nix, ct-scratch-guard -> $CT_PREFIX"

# --- 2. workspace root + conventions block ---------------------------------
mkdir -p "$CT_HOME"
md="$CT_HOME/CLAUDE.md"
BEGIN='<!-- BEGIN ct-managed -->'
END='<!-- END ct-managed -->'
touch "$md"
# Replace the block IN PLACE when it exists; append only when it does not.
# Delete-then-append made the block order alternate with any other marker-block
# writer (e.g. a site layer): whichever ran last ended up at the bottom, so the
# file churned on every boot although its content never changed.
block="$(mktemp)"
{ echo "$BEGIN"; cat "$srcdir/docs/workspace-conventions.md"; echo "$END"; } > "$block"
if grep -qxF "$BEGIN" "$md"; then
    awk -v b="$BEGIN" -v e="$END" -v f="$block" '
        $0 == b { while ((getline l < f) > 0) print l; skip = 1; next }
        skip && $0 == e { skip = 0; next }
        !skip
    ' "$md" > "$md.ct-tmp" && mv "$md.ct-tmp" "$md"
else
    cat "$block" >> "$md"
fi
rm -f "$block"
say "wrote ct-managed block in $md"

# --- 3. settings seed (write-once, never clobber) ---------------------------
if [ ! -f "$HOME/.claude/settings.json" ]; then
    mkdir -p "$HOME/.claude"
    install -m 0600 "$srcdir/templates/claude-settings.json" "$HOME/.claude/settings.json"
    say "seeded ~/.claude/settings.json from template"
fi

# --- 3b. plans live in the workspace (added to an existing file if absent) --
# The seed above is write-once, so a machine set up before plansDirectory
# existed would keep writing every session's plans into the one shared
# ~/.claude/plans/, where two agents took the same file for different work
# (docs/workspace-conventions.md, "Your plan and scratch are yours"). Add the key
# only when it is absent: a value someone chose is left alone, and the file is
# rewritten only when the key is actually added. perl + JSON::PP because they
# are core on every base image this runs on at boot; jq, python3 and node are
# not.
settings="$HOME/.claude/settings.json"
perl -MJSON::PP -e '
    my $f = shift;
    local $/; open(my $in, "<", $f) or exit 0; my $raw = <$in>; close $in;
    my $d = eval { JSON::PP->new->relaxed->decode($raw) };
    if (!defined $d || ref $d ne "HASH") { print STDERR "ct-install: $f is not a JSON object; plansDirectory not added\n"; exit 0 }
    exit 0 if exists $d->{plansDirectory};
    $d->{plansDirectory} = ".claude/plans";
    my $mode = (stat $f)[2] & 07777;
    open(my $out, ">", "$f.ct-tmp") or die "write $f.ct-tmp: $!\n";
    print $out JSON::PP->new->pretty->canonical->encode($d); close $out;
    chmod $mode, "$f.ct-tmp"; rename "$f.ct-tmp", $f or die "rename: $!\n";
    print STDERR "ct-install: added plansDirectory=.claude/plans to $f\n";
' "$settings"

# --- 3c. scratch deletions run unprompted (the guard replaces `ask: rm`) -----
# The conventions tell every agent to delete its own .scratch files, and the
# template's `ask: Bash(rm *)` prompted for each one. An ask rule wins over any
# hook, so the rule itself has to go and ct-scratch-guard (a PreToolUse hook)
# carries the policy: rm inside <CT_HOME>/<ws>/.scratch/ is allowed, every other
# rm still asks. Register the hook (or repoint it if CT_PREFIX/CT_HOME moved),
# and only then remove exactly the two rules the template shipped; rules anyone
# added themselves are left alone. Rewritten only when something changes.
perl -MJSON::PP -e '
    my ($f, $guard, $home) = @ARGV;
    local $/; open(my $in, "<", $f) or exit 0; my $raw = <$in>; close $in;
    my $d = eval { JSON::PP->new->relaxed->decode($raw) };
    if (!defined $d || ref $d ne "HASH") { print STDERR "ct-install: $f is not a JSON object; scratch guard not registered\n"; exit 0 }
    my $q = sub { my $s = shift; $s =~ s/\x27/\x27\\\x27\x27/g; "\x27$s\x27" };
    my $want = $q->($guard) . " " . $q->($home);
    my $changed = 0;
    $d->{hooks} = {} unless ref $d->{hooks} eq "HASH";
    $d->{hooks}{PreToolUse} = [] unless ref $d->{hooks}{PreToolUse} eq "ARRAY";
    my $found = 0;
    for my $m (@{ $d->{hooks}{PreToolUse} }) {
        next unless ref $m eq "HASH" && ref $m->{hooks} eq "ARRAY";
        for my $h (@{ $m->{hooks} }) {
            next unless ref $h eq "HASH" && ($h->{command} // "") =~ m{ct-scratch-guard\x27? };
            $found = 1;
            if ($h->{command} ne $want) { $h->{command} = $want; $changed = 1 }
        }
    }
    unless ($found) {
        push @{ $d->{hooks}{PreToolUse} },
            { matcher => "Bash", hooks => [ { type => "command", command => $want, timeout => 10 } ] };
        $changed = 1;
    }
    if (ref $d->{permissions} eq "HASH" && ref $d->{permissions}{ask} eq "ARRAY") {
        my %old = map { $_ => 1 } ("Bash(rm *)", "Bash(direnv exec*rm *)");
        my @keep = grep { !$old{$_} } @{ $d->{permissions}{ask} };
        if (@keep != @{ $d->{permissions}{ask} }) { $d->{permissions}{ask} = \@keep; $changed = 1 }
    }
    exit 0 unless $changed;
    my $mode = (stat $f)[2] & 07777;
    open(my $out, ">", "$f.ct-tmp") or die "write $f.ct-tmp: $!\n";
    print $out JSON::PP->new->pretty->canonical->encode($d); close $out;
    chmod $mode, "$f.ct-tmp"; rename "$f.ct-tmp", $f or die "rename: $!\n";
    print STDERR "ct-install: registered ct-scratch-guard in $f (rm inside .scratch/ no longer prompts)\n";
' "$settings" "$CT_PREFIX/ct-scratch-guard" "$CT_HOME"

# --- 4. version stamp -------------------------------------------------------
mkdir -p "$HOME/.local/share/ct"
# Record the resolved commit next to the ref: a checkout run on `main` would
# otherwise overwrite a fleet's version signal with just "main".
commit="unknown"
# rev-parse, not `[ -d .git ]`: in a worktree or submodule .git is a FILE.
if command -v git >/dev/null 2>&1 && git -C "$srcdir" rev-parse --git-dir >/dev/null 2>&1; then
    commit="$(git -C "$srcdir" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    [ -n "$(git -C "$srcdir" status --porcelain 2>/dev/null)" ] && commit="$commit-dirty"
elif [ -n "${tarball_commit:-}" ]; then
    commit="$tarball_commit"
fi
printf '%s %s %s\n' "$CT_REF" "$commit" "$(date -u +%Y-%m-%dT%H:%MZ)" > "$HOME/.local/share/ct/VERSION"
say "done (${CT_REF}). Next: create a workspace under $CT_HOME and run: ct"
