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
#   1. installs bin/{ct,ct-autostart,ensure-nix,ct-scratch-guard,ct-profile} into CT_PREFIX
#   2. writes the generic workspace conventions into CT_HOME/CLAUDE.md inside
#      a <!-- BEGIN ct-managed --> marker block (hand edits outside survive;
#      site layers add their own block — see docs/bootstrap-integration.md)
#   3. seeds ~/.claude/settings.json from the template ONLY if none exists,
#      then migrates an existing one step by step (plansDirectory, the scratch
#      guard, the template's retired ask rules, autoMode's ct entries); what
#      its owner wrote is kept
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
for tool in ct ct-autostart ensure-nix ct-scratch-guard ct-profile; do
    install -m 0755 "$srcdir/bin/$tool" "$CT_PREFIX/$tool"
done
say "installed ct, ct-autostart, ensure-nix, ct-scratch-guard, ct-profile -> $CT_PREFIX"

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
# Every Claude settings file ct manages: the machine's, and each profile's
# (<CT_HOME>/.profiles/<name>/claude, ct >= 0.10). A profile is seeded from the
# machine's file once, at creation, so a later release's settings would never
# reach it otherwise. Both steps below are idempotent per file.
claude_settings=("$HOME/.claude/settings.json")
for f in "$CT_HOME"/.profiles/*/claude/settings.json; do
    [ -f "$f" ] && claude_settings+=("$f")
done
for settings in "${claude_settings[@]}"; do
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
# allows rm inside <CT_HOME>/<ws>/.scratch/ in every permission mode. Any other
# rm it leaves to Claude Code's normal flow (auto mode's classifier, or a prompt
# outside auto mode); it never asks itself. Register the hook (or repoint it if
# CT_PREFIX/CT_HOME moved), and only then remove exactly the two rules the
# template shipped; rules anyone added themselves are left alone. Rewritten
# only when something changes.
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

# --- 3e. the root deny stops shadowing the scratch guard ---------------------
# The template denied `Bash(rm -rf /*)` to stop `rm -rf /`. A `*` in a rule matches
# any characters, so it denied every `rm -rf /<path>`, scratch deletions the guard
# allows included, and a deny wins over any hook. Exactly that rule is replaced by
# the template's root-only denies; rules anyone added themselves are left alone.
perl -MJSON::PP -e '
    my ($f, $tmpl) = @ARGV;
    local $/;
    open(my $in, "<", $f) or exit 0; my $raw = <$in>; close $in;
    my $d = eval { JSON::PP->new->relaxed->decode($raw) };
    exit 0 if !defined $d || ref $d ne "HASH" || ref $d->{permissions} ne "HASH";
    my $deny = $d->{permissions}{deny};
    exit 0 unless ref $deny eq "ARRAY" && grep { $_ eq "Bash(rm -rf /*)" } @$deny;
    open(my $t, "<", $tmpl) or die "read $tmpl: $!\n"; my $td = JSON::PP->new->relaxed->decode(<$t>); close $t;
    my @keep = grep { $_ ne "Bash(rm -rf /*)" } @$deny;
    my %have = map { $_ => 1 } @keep;
    $d->{permissions}{deny} = [ (grep { !$have{$_} } @{ $td->{permissions}{deny} }), @keep ];
    my $mode = (stat $f)[2] & 07777;
    open(my $out, ">", "$f.ct-tmp") or die "write $f.ct-tmp: $!\n";
    print $out JSON::PP->new->pretty->canonical->encode($d); close $out;
    chmod $mode, "$f.ct-tmp"; rename "$f.ct-tmp", $f or die "rename: $!\n";
    print STDERR "ct-install: root deny narrowed in $f (scratch rm -rf no longer denied)\n";
' "$settings" "$srcdir/templates/claude-settings.json"

# --- 3d. nothing asks by rule: auto mode's classifier decides ----------------
# Every ask rule a template ever shipped is retired (the list is
# templates/retired-ask-rules.txt; the template's "//" note says why). An ask
# rule prompts where the classifier would have decided, and it wins over any
# allow rule or hook: on one machine the shipped rules raised 1300 prompts in
# four weeks, of which the person refused three. Exactly the listed rules leave
# `permissions.ask`. A rule anyone added is kept, and the installer says how
# many went, so none disappears unannounced.
#
# A file seeded from the template of ct #11 to #14 (never tagged) allowed git
# whole, `Bash(git *)`, beside ask rules for the destructive forms. An allow
# rule skips the classifier, so without those ask rules it would let a force
# push through unseen: such a file gets `Bash(git add *)` back in its place. A
# `Bash(git *)` its owner wrote, with no such ask rules beside it, is left alone.
perl -MJSON::PP -e '
    my ($f, $list) = @ARGV;
    local $/;
    open(my $in, "<", $f) or exit 0; my $raw = <$in>; close $in;
    my $d = eval { JSON::PP->new->relaxed->decode($raw) };
    exit 0 if !defined $d || ref $d ne "HASH" || ref $d->{permissions} ne "HASH";
    open(my $l, "<", $list) or die "read $list: $!\n";
    my %retired = map { $_ => 1 } grep { length && !/^#/ } split /\n/, <$l>; close $l;
    my $p = $d->{permissions};
    my $ask = ref $p->{ask} eq "ARRAY" ? $p->{ask} : [];
    my @keep = grep { !$retired{$_} } @$ask;
    my $gone = @$ask - @keep;
    # ct #11 and later: this rule is in every such template and in none before.
    my $git_whole = grep { $_ eq "Bash(git push*--force)" } @$ask;
    my $changed = 0;
    if ($gone) { if (@keep) { $p->{ask} = \@keep } else { delete $p->{ask} } $changed = 1 }
    if ($git_whole && ref $p->{allow} eq "ARRAY") {
        my %wide = map { $_ => 1 } ("Bash(git *)", "Bash(direnv exec*git *)");
        my @allow = grep { !$wide{$_} } @{ $p->{allow} };
        if (@allow != @{ $p->{allow} }) {
            unshift @allow, "Bash(git add *)" unless grep { $_ eq "Bash(git add *)" } @allow;
            $p->{allow} = \@allow; $changed = 1;
        }
    }
    exit 0 unless $changed;
    my $mode = (stat $f)[2] & 07777;
    open(my $out, ">", "$f.ct-tmp") or die "write $f.ct-tmp: $!\n";
    print $out JSON::PP->new->pretty->canonical->encode($d); close $out;
    chmod $mode, "$f.ct-tmp"; rename "$f.ct-tmp", $f or die "rename: $!\n";
    print STDERR "ct-install: retired $gone ask rule(s) of the template in $f (auto mode decides; rules you added are kept)\n";
' "$settings" "$srcdir/templates/retired-ask-rules.txt"

# --- 3f. the classifier is told what a ct workspace is -----------------------
# Auto mode's classifier trusts "the repository the agent started in". ct starts
# an agent in its workspace, which is no repository: asked to describe it, the
# classifier's own set-up wrote "no remotes are configured" and then treated
# every clone's remote as foreign. The template's `autoMode` entries labelled
# `(ct)` say what the workspace is and that its .scratch/ is the agent's to
# clean. They are ct's: added to a file that lacks them, replaced when a release
# rewords one, removed when a release drops one. Every other entry is the
# owner's or the site's and is left as it is. A list ct creates starts with
# `$defaults`, without which it would replace Claude Code's own entries.
perl -MJSON::PP -e '
    my ($f, $tmpl) = @ARGV;
    local $/;
    open(my $in, "<", $f) or exit 0; my $raw = <$in>; close $in;
    my $d = eval { JSON::PP->new->relaxed->decode($raw) };
    exit 0 if !defined $d || ref $d ne "HASH";
    open(my $t, "<", $tmpl) or die "read $tmpl: $!\n"; my $td = JSON::PP->new->relaxed->decode(<$t>); close $t;
    if (exists $d->{autoMode} && ref $d->{autoMode} ne "HASH") { print STDERR "ct-install: autoMode in $f is not an object; left as it is\n"; exit 0 }
    my $label = sub { $_[0] =~ /^(\*{0,2}[^:*]*\(ct\)\*{0,2}:)/ ? $1 : undef };
    my $changed = 0;
    for my $key ("environment", "allow", "soft_deny") {
        my %mine = map { $label->($_) => $_ } grep { defined $label->($_) } @{ $td->{autoMode}{$key} || [] };
        my $have = $d->{autoMode}{$key};
        if (ref $have ne "ARRAY") {
            next unless %mine;
            $d->{autoMode}{$key} = ["\$defaults", map { $mine{$_} } sort keys %mine]; $changed = 1; next;
        }
        my (@new, %seen);
        for my $e (@$have) {
            my $l = ref $e ? undef : $label->($e);
            if (!defined $l) { push @new, $e; next }
            if (!exists $mine{$l}) { $changed = 1; next }          # an entry a release dropped
            $seen{$l} = 1; $changed = 1 if $e ne $mine{$l}; push @new, $mine{$l};
        }
        for my $l (sort keys %mine) { next if $seen{$l}; push @new, $mine{$l}; $changed = 1 }
        $d->{autoMode}{$key} = \@new;
    }
    exit 0 unless $changed;
    my $mode = (stat $f)[2] & 07777;
    open(my $out, ">", "$f.ct-tmp") or die "write $f.ct-tmp: $!\n";
    print $out JSON::PP->new->pretty->canonical->encode($d); close $out;
    chmod $mode, "$f.ct-tmp"; rename "$f.ct-tmp", $f or die "rename: $!\n";
    print STDERR "ct-install: autoMode in $f describes the ct workspace to the classifier\n";
' "$settings" "$srcdir/templates/claude-settings.json"
done

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
