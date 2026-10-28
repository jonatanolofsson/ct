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
  json 'grep { $_ eq "Bash(git push --force*)" } @{$d->{permissions}{ask}}'
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
