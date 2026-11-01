#!/usr/bin/env bats
# install.sh must own exactly one marker block and never move it: another
# writer (a site layer) owns its own block, and alternating order made the
# file churn on every boot (found 2026-09-25 on the first real run).

setup() {
  REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  export HOME="$BATS_TEST_TMPDIR/home" CT_HOME="$BATS_TEST_TMPDIR/home/dev" CT_PREFIX="$BATS_TEST_TMPDIR/home/bin"
  mkdir -p "$HOME"
  MD="$CT_HOME/CLAUDE.md"
}

site_write() {  # the site-layer shape from docs/bootstrap-integration.md
  local b='<!-- BEGIN ct-site-managed -->' e='<!-- END ct-site-managed -->'
  if grep -qF "$b" "$MD"; then sed -i "\|^${b}\$|,\|^${e}\$|d" "$MD"; fi
  { echo "$b"; echo "site text"; echo "$e"; } >> "$MD"
}

order() { grep -oE 'BEGIN ct(-site)?-managed' "$MD" | tr '\n' ' '; }

@test "first run appends one ct block" {
  "$REPO/install.sh" 2>/dev/null
  [ "$(grep -c 'BEGIN ct-managed' "$MD")" -eq 1 ]
}

@test "re-run is byte-identical (idempotent)" {
  "$REPO/install.sh" 2>/dev/null; h1=$(sha256sum < "$MD")
  "$REPO/install.sh" 2>/dev/null; h2=$(sha256sum < "$MD")
  [ "$h1" = "$h2" ]
}

@test "block order is stable when install and a site writer alternate" {
  "$REPO/install.sh" 2>/dev/null; site_write
  first="$(order)"; h1=$(sha256sum < "$MD")
  "$REPO/install.sh" 2>/dev/null; site_write
  "$REPO/install.sh" 2>/dev/null
  [ "$(order)" = "$first" ]
  [ "$(sha256sum < "$MD")" = "$h1" ]
}

@test "hand edits outside the block survive and keep their position" {
  mkdir -p "$CT_HOME"; printf 'TOP\n' > "$MD"
  "$REPO/install.sh" 2>/dev/null
  printf 'BOTTOM\n' >> "$MD"
  "$REPO/install.sh" 2>/dev/null
  [ "$(head -1 "$MD")" = "TOP" ]
  [ "$(tail -1 "$MD")" = "BOTTOM" ]
}

@test "VERSION records ref and resolved commit" {
  "$REPO/install.sh" 2>/dev/null
  read -r ref commit _ < "$HOME/.local/share/ct/VERSION"
  [ -n "$ref" ]
  [[ "$commit" =~ ^[0-9a-f]{7,}(-dirty)?$ ]]
}

# Plans live in the workspace, never the shared ~/.claude/plans/ (two agents
# rewrote each other's plan file there, 2026-10-17/18).
@test "a fresh install seeds plansDirectory" {
  "$REPO/install.sh" 2>/dev/null
  grep -qE '"plansDirectory" ?: ".claude/plans"' "$HOME/.claude/settings.json"
}

@test "an existing settings.json gains plansDirectory, keeps its keys and mode" {
  mkdir -p "$HOME/.claude"
  printf '{"model": "x", "permissions": {"allow": ["Read"]}}\n' > "$HOME/.claude/settings.json"
  chmod 600 "$HOME/.claude/settings.json"
  "$REPO/install.sh" 2>/dev/null
  perl -MJSON::PP -e 'local $/; open F, shift; my $d = decode_json(<F>);
    exit !($d->{plansDirectory} eq ".claude/plans" && $d->{model} eq "x" && $d->{permissions}{allow}[0] eq "Read")' \
    "$HOME/.claude/settings.json"
  [ "$(stat -c %a "$HOME/.claude/settings.json")" = "600" ]
}

@test "a plansDirectory someone chose is left alone, and the file is not rewritten" {
  mkdir -p "$HOME/.claude"
  printf '{"plansDirectory": "docs/plans"}\n' > "$HOME/.claude/settings.json"
  # the first run registers the scratch guard (3c); the chosen value survives it,
  # and a second run finds nothing to add, so the file is not rewritten again
  "$REPO/install.sh" 2>/dev/null
  grep -q '"plansDirectory" : "docs/plans"' "$HOME/.claude/settings.json"
  h1=$(sha256sum < "$HOME/.claude/settings.json")
  "$REPO/install.sh" 2>/dev/null
  [ "$(sha256sum < "$HOME/.claude/settings.json")" = "$h1" ]
}

# --- 3c: ct-scratch-guard replaces the template's `ask: rm` rules ------------

json() {  # json <perl expression over $d> : exit status of the expression
  perl -MJSON::PP -e 'local $/; open F, $ARGV[0]; my $d = decode_json(<F>); exit !(eval $ARGV[1])' \
    "$HOME/.claude/settings.json" "$1"
}

guard_cmd() { printf "'%s' '%s'" "$CT_PREFIX/ct-scratch-guard" "$CT_HOME"; }

@test "a fresh install registers the scratch guard and has no rm ask rule" {
  "$REPO/install.sh" 2>/dev/null
  [ -x "$CT_PREFIX/ct-scratch-guard" ]
  want=$(guard_cmd)
  json 'grep { $_->{command} eq "'"$want"'" } map { @{$_->{hooks}} } @{$d->{hooks}{PreToolUse}}'
  json '!grep { /\brm \*/ } @{$d->{permissions}{ask}}'
  json 'grep { $_ eq "Bash(git push*--force *)" } @{$d->{permissions}{ask}}'
  json '!grep { $_ eq "Bash(git push --force*)" } @{$d->{permissions}{ask}}'
  json 'grep { $_ eq "Bash(git *)" } @{$d->{permissions}{allow}}'
}

@test "an existing settings.json loses exactly the template's rm rules and keeps its own" {
  mkdir -p "$HOME/.claude"
  printf '%s\n' '{"permissions": {"ask": ["Bash(rm *)", "Bash(rm -i *)", "Bash(direnv exec*rm *)", "Bash(kill*)"]},
    "hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "/x/pkill-guard.sh"}]}]}}' \
    > "$HOME/.claude/settings.json"
  "$REPO/install.sh" 2>/dev/null
  json 'join(",", @{$d->{permissions}{ask}}) eq "Bash(rm -i *),Bash(kill*)"'
  json '@{$d->{hooks}{PreToolUse}} == 2 && $d->{hooks}{PreToolUse}[0]{hooks}[0]{command} eq "/x/pkill-guard.sh"'
}

@test "re-running does not register the guard twice or rewrite the file" {
  "$REPO/install.sh" 2>/dev/null
  h1=$(sha256sum < "$HOME/.claude/settings.json")
  "$REPO/install.sh" 2>/dev/null
  [ "$(sha256sum < "$HOME/.claude/settings.json")" = "$h1" ]
  json '1 == grep { $_->{command} =~ /ct-scratch-guard/ } map { @{$_->{hooks}} } @{$d->{hooks}{PreToolUse}}'
}

@test "a moved CT_HOME repoints the registered guard instead of adding another" {
  "$REPO/install.sh" 2>/dev/null
  export CT_HOME="$BATS_TEST_TMPDIR/home/work"
  "$REPO/install.sh" 2>/dev/null
  want=$(guard_cmd)
  json '1 == grep { $_->{command} =~ /ct-scratch-guard/ } map { @{$_->{hooks}} } @{$d->{hooks}{PreToolUse}}'
  json 'grep { $_->{command} eq "'"$want"'" } map { @{$_->{hooks}} } @{$d->{hooks}{PreToolUse}}'
}

@test "a settings.json that is not JSON is left untouched" {
  mkdir -p "$HOME/.claude"
  printf 'not json\n' > "$HOME/.claude/settings.json"
  "$REPO/install.sh" 2>/dev/null
  [ "$(cat "$HOME/.claude/settings.json")" = "not json" ]
}

@test "the registered command, run as Claude Code runs it, allows scratch and asks elsewhere" {
  "$REPO/install.sh" 2>/dev/null
  mkdir -p "$CT_HOME/ws/.scratch"
  cmd=$(perl -MJSON::PP -e 'local $/; open F, shift; my $d = decode_json(<F>);
    print grep { /ct-scratch-guard/ } map { $_->{command} } map { @{$_->{hooks}} } @{$d->{hooks}{PreToolUse}}' \
    "$HOME/.claude/settings.json")
  hook_input() { perl -MJSON::PP -e 'print encode_json({tool_input=>{command=>$ARGV[0]},cwd=>"/"})' "$1" > "$BATS_TEST_TMPDIR/in.json"; }
  hook_input "rm -f $CT_HOME/ws/.scratch/a"
  run sh -c "$cmd" < "$BATS_TEST_TMPDIR/in.json"
  [[ "$output" == *'"permissionDecision":"allow"'* ]]
  hook_input "rm -f /etc/hosts"
  run sh -c "$cmd" < "$BATS_TEST_TMPDIR/in.json"
  [[ "$output" == *'"permissionDecision":"ask"'* ]]
}

@test "the conventions block tells agents where plans live" {
  "$REPO/install.sh" 2>/dev/null
  grep -q '<workspace>/.claude/plans/' "$CT_HOME/CLAUDE.md"
}

@test "every profile's Claude settings get the scratch guard and plansDirectory, not only ~/.claude" {
  mkdir -p "$CT_HOME/.profiles/acme/claude" "$CT_HOME/.profiles/gw/claude"
  echo '{"model":"m"}' > "$CT_HOME/.profiles/acme/claude/settings.json"
  echo '{"plansDirectory":"mine","hooks":{"PreToolUse":[]}}' > "$CT_HOME/.profiles/gw/claude/settings.json"
  "$REPO/install.sh" 2>/dev/null
  for p in acme gw; do
    jq -e --arg g "$CT_PREFIX/ct-scratch-guard" '[.hooks.PreToolUse[].hooks[].command | select(contains($g))] | length == 1' "$CT_HOME/.profiles/$p/claude/settings.json"
  done
  jq -e '.plansDirectory == ".claude/plans" and .model == "m"' "$CT_HOME/.profiles/acme/claude/settings.json"
  jq -e '.plansDirectory == "mine"' "$CT_HOME/.profiles/gw/claude/settings.json"   # a choice is kept
  "$REPO/install.sh" 2>/dev/null                                                  # idempotent
  jq -e '[.hooks.PreToolUse[].hooks[].command | select(contains("ct-scratch-guard"))] | length == 1' "$CT_HOME/.profiles/acme/claude/settings.json"
}


# --- 3d: git is allowed whole; only what destroys work or history asks -------

# Claude Code's Bash rule: the command must match the whole pattern, `*` any run of characters;
# deny wins over ask, ask over allow.
decide() {  # decide <command> : prints ask, allow or none, from the installed settings
  perl -MJSON::PP -e '
    local $/; open F, $ARGV[0]; my $d = decode_json(<F>); my $cmd = $ARGV[1];
    my $hit = sub { for (@{ $_[0] || [] }) { next unless /^Bash\((.*)\)$/s;
      my $re = join ".*", map { quotemeta } split /\*/, $1, -1; return 1 if $cmd =~ /^$re$/s } 0 };
    print $hit->($d->{permissions}{ask}) ? "ask" : $hit->($d->{permissions}{allow}) ? "allow" : "none";
  ' "$HOME/.claude/settings.json" "$1"
}

@test "destructive git asks, in every form, and the rest of git runs unprompted" {
  "$REPO/install.sh" 2>/dev/null
  while IFS= read -r cmd; do
    [ "$(decide "$cmd")" = ask ] || { echo "should ask: $cmd"; return 1; }
  done <<'ASK'
git push --force origin feat/a
git push origin feat/a --force
git push -f origin feat/a
git push origin feat/a -f
git push origin +main
git push origin --delete feat/a
git push -d origin feat/a
git push origin :feat/a
git push --mirror backup
git push --prune origin
git -C /w/repo push --force origin feat/a
direnv exec . git push --force origin feat/a
git reset --hard HEAD~1
git -C /w/repo reset --hard origin/main
git checkout -- file.py
git checkout .
git checkout -f main
git switch --discard-changes main
git restore file.py
git clean -fdx
git branch -D feat/a
git branch -f main HEAD~1
git stash drop
git stash clear
git worktree remove --force ../wt
git tag -d v1
git reflog expire --expire=now --all
git gc --prune=now
git filter-branch --tree-filter x HEAD
ASK
  while IFS= read -r cmd; do
    [ "$(decide "$cmd")" = allow ] || { echo "should run unprompted: $cmd ($(decide "$cmd"))"; return 1; }
  done <<'ALLOW'
git push --force-with-lease origin feat/a
git push --force-with-lease=feat/a:abc123 origin feat/a
direnv exec . git push --force-with-lease origin feat/a
git -C /w/repo push --force-with-lease origin feat/a
git push -q -u origin feat/a
git commit -m 'x'
git commit -q --amend --no-edit
git commit -m 'docs: say when to push --force-with-lease'
git fetch -q origin
git pull --rebase
git rebase origin/main
git reset --soft HEAD~1
git switch -q -c feat/a origin/main
git worktree add ../wt -b feat/a origin/main
git stash push -u -m tag
git branch -m old new
git log --oneline -3
git -C /w/repo status --short
direnv exec . git status
ALLOW
}

@test "an existing settings.json has exactly the template's old git rules replaced, its own kept" {
  mkdir -p "$HOME/.claude"
  printf '%s\n' '{"permissions": {
      "ask": ["Bash(git push --force*)", "Bash(direnv exec*git push --force*)", "Bash(git clean*)", "Bash(git rebase -i*)", "Bash(kill*)"],
      "allow": ["Bash(git add *)", "Read"]}}' > "$HOME/.claude/settings.json"
  "$REPO/install.sh" 2>/dev/null
  json '!grep { $_ eq "Bash(git push --force*)" || $_ eq "Bash(direnv exec*git push --force*)" } @{$d->{permissions}{ask}}'
  json 'grep { $_ eq "Bash(git rebase -i*)" } @{$d->{permissions}{ask}}'
  json 'grep { $_ eq "Bash(kill*)" } @{$d->{permissions}{ask}}'
  json '1 == grep { $_ eq "Bash(git clean*)" } @{$d->{permissions}{ask}}'
  json 'grep { $_ eq "Bash(git push*--force *)" } @{$d->{permissions}{ask}}'
  json '!grep { $_ eq "Bash(git add *)" } @{$d->{permissions}{allow}}'
  json 'grep { $_ eq "Bash(git *)" } @{$d->{permissions}{allow}} and grep { $_ eq "Read" } @{$d->{permissions}{allow}}'
  [ "$(decide "git push --force-with-lease origin feat/a")" = allow ]
  h1=$(sha256sum < "$HOME/.claude/settings.json")
  "$REPO/install.sh" 2>/dev/null
  [ "$(sha256sum < "$HOME/.claude/settings.json")" = "$h1" ]
}
