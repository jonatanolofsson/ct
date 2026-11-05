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

@test "a fresh install registers the scratch guard and ships no ask rule" {
  "$REPO/install.sh" 2>/dev/null
  [ -x "$CT_PREFIX/ct-scratch-guard" ]
  want=$(guard_cmd)
  json 'grep { $_->{command} eq "'"$want"'" } map { @{$_->{hooks}} } @{$d->{hooks}{PreToolUse}}'
  json '!exists $d->{permissions}{ask}'
  json 'grep { $_ eq "Bash(git add *)" } @{$d->{permissions}{allow}}'
  json '!grep { $_ eq "Bash(git *)" } @{$d->{permissions}{allow}}'
  json '$d->{permissions}{defaultMode} eq "auto"'
}

@test "an existing settings.json loses the template's rm rules and keeps its own" {
  mkdir -p "$HOME/.claude"
  printf '%s\n' '{"permissions": {"ask": ["Bash(rm *)", "Bash(rm -i *)", "Bash(direnv exec*rm *)"]},
    "hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "/x/pkill-guard.sh"}]}]}}' \
    > "$HOME/.claude/settings.json"
  "$REPO/install.sh" 2>/dev/null
  json 'join(",", @{$d->{permissions}{ask}}) eq "Bash(rm -i *)"'
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

@test "the registered command, run as Claude Code runs it, allows scratch and is silent elsewhere" {
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
  [ "$status" -eq 0 ] && [ -z "$output" ]      # no decision: auto mode's classifier, or a prompt, decides
}

@test "the conventions block tells agents where plans live" {
  "$REPO/install.sh" 2>/dev/null
  grep -q '<workspace>/.claude/plans/' "$CT_HOME/CLAUDE.md"
}

@test "the conventions block tells agents what to do when auto mode refuses" {
  "$REPO/install.sh" 2>/dev/null
  grep -q 'A refusal is an answer' "$CT_HOME/CLAUDE.md"
  grep -q 'do not ask the person to change mode' "$CT_HOME/CLAUDE.md"
  grep -q 'hook itself never asks' "$CT_HOME/CLAUDE.md"
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


# --- 3d: nothing asks by rule; auto mode's classifier decides ----------------

# Claude Code's Bash rule: the command must match the whole pattern, `*` any run of characters;
# deny wins over ask, ask over allow. "none" is what the classifier (or, outside auto mode, a
# prompt) decides.
decide() {  # decide <command> : prints deny, ask, allow or none, from the installed settings
  perl -MJSON::PP -e '
    local $/; open F, $ARGV[0]; my $d = decode_json(<F>); my $cmd = $ARGV[1];
    my $hit = sub { for (@{ $_[0] || [] }) { next unless /^Bash\((.*)\)$/s; my $p = $1;
      $p =~ s/:\*$/ */;   # `:*` is recognised only at the end, and means ` *`
      return 1 if $p =~ / \*$/ && ($p =~ tr/*//) == 1 && $cmd eq substr($p, 0, -2);   # `ls *` matches `ls`
      my $re = join ".*", map { quotemeta } split /\*/, $p, -1; return 1 if $cmd =~ /^$re$/s } 0 };
    print $hit->($d->{permissions}{deny}) ? "deny" : $hit->($d->{permissions}{ask}) ? "ask" : $hit->($d->{permissions}{allow}) ? "allow" : "none";
  ' "$HOME/.claude/settings.json" "$1"
}

# The ask rules of the template as it was released (ct 0.9.0 to 0.11.0): what a machine holds today.
released_ask='["Bash(git push --force*)","Bash(git reset --hard*)","Bash(git checkout -- *)","Bash(git clean*)","Bash(git branch -D*)","Bash(kill*)","Bash(pkill*)","Bash(reboot*)","Bash(shutdown*)","Bash(systemctl restart*)","Bash(systemctl stop*)","Bash(systemctl enable*)","Bash(systemctl disable*)","Bash(kubectl apply*)","Bash(kubectl delete*)","Bash(kubectl patch*)","Bash(kubectl edit*)","Bash(kubectl scale*)","Bash(kubectl cordon*)","Bash(kubectl drain*)","Bash(kubectl taint*)","Bash(helm install*)","Bash(helm upgrade*)","Bash(helm uninstall*)","Bash(helm rollback*)","Bash(direnv exec*git push --force*)","Bash(direnv exec*git reset --hard*)","Bash(direnv exec*git checkout -- *)","Bash(direnv exec*git clean*)","Bash(direnv exec*git branch -D*)","Bash(direnv exec*kubectl apply*)","Bash(direnv exec*kubectl delete*)","Bash(direnv exec*kubectl patch*)","Bash(direnv exec*kubectl edit*)","Bash(direnv exec*kubectl scale*)","Bash(direnv exec*kubectl cordon*)","Bash(direnv exec*kubectl drain*)","Bash(direnv exec*kubectl taint*)","Bash(direnv exec*helm install*)","Bash(direnv exec*helm upgrade*)","Bash(direnv exec*helm uninstall*)","Bash(direnv exec*helm rollback*)"]'

# Every rule of the retired list, as a JSON array: the template of ct #11 to #14 and all before it.
retired_json() { grep -v '^#' "$REPO/templates/retired-ask-rules.txt" | jq -R . | jq -cs .; }

@test "after a fresh install no command asks by rule: the classifier decides what no rule allows" {
  "$REPO/install.sh" 2>/dev/null
  while IFS= read -r cmd; do
    [ "$(decide "$cmd")" = none ] || { echo "should be left to the classifier: $cmd ($(decide "$cmd"))"; return 1; }
  done <<'NONE'
git push --force origin feat/a
git push --force-with-lease origin feat/a
git push origin main
git reset --hard HEAD~1
git checkout -- file.py
git clean -fdx
git branch -D feat/a
git worktree remove --force ../wt
git commit -m 'x'
git -c alias.x=!sh x
direnv exec . git push --force origin feat/a
kill 1234
pkill -f '^python server.py'
kubectl delete pod probe -n dev
kubectl apply -f probe.yaml
direnv exec . kubectl delete pod probe -n dev
helm upgrade app chart
systemctl restart nginx
rm -rf build
NONE
  while IFS= read -r cmd; do
    [ "$(decide "$cmd")" = allow ] || { echo "should be allowed: $cmd ($(decide "$cmd"))"; return 1; }
  done <<'ALLOW'
git add src/a.py
kubectl get pods -n dev
direnv exec . kubectl logs deploy/app -n dev
helm template chart
ALLOW
  [ "$(decide "rm -rf /")" = deny ]
}

@test "the retired list holds every rule a template shipped, and the template none of them" {
  # the released template's rules are all in the list
  jq -r '.[]' <<<"$released_ask" | while IFS= read -r rule; do
    grep -qxF -- "$rule" "$REPO/templates/retired-ask-rules.txt" || { echo "not retired: $rule"; exit 1; }
  done
  # every line is one Bash rule, and the template asks nothing
  ! grep -v '^#' "$REPO/templates/retired-ask-rules.txt" | grep -qvE '^Bash\(.+\)$'
  jq -e '.permissions | has("ask") | not' "$REPO/templates/claude-settings.json"
}

@test "settings as released lose every ask rule of the template, keep the owner's, and say so" {
  mkdir -p "$HOME/.claude"
  jq -n --argjson ask "$released_ask" '{model: "x", permissions: {
      ask: ($ask + ["Bash(terraform apply*)", "Bash(git rebase -i*)"]),
      allow: ["Bash(git add *)", "Read", "Bash(git commit -m '"'"' *)"],
      defaultMode: "auto"}}' > "$HOME/.claude/settings.json"
  chmod 600 "$HOME/.claude/settings.json"
  [ "$(decide "kill 1234")" = ask ]
  [ "$(decide "direnv exec . kubectl delete pod x -n dev")" = ask ]
  run "$REPO/install.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"retired 42 ask rule(s) of the template"* ]]
  json 'join(",", @{$d->{permissions}{ask}}) eq "Bash(terraform apply*),Bash(git rebase -i*)"'
  json 'join(",", @{$d->{permissions}{allow}}) eq "Bash(git add *),Read,Bash(git commit -m \x27 *)"'
  json '$d->{model} eq "x" && $d->{permissions}{defaultMode} eq "auto"'
  [ "$(stat -c %a "$HOME/.claude/settings.json")" = "600" ]
  [ "$(decide "kill 1234")" = none ]
  [ "$(decide "git push --force origin main")" = none ]
  [ "$(decide "terraform apply -auto-approve")" = ask ]
  h1=$(sha256sum < "$HOME/.claude/settings.json")
  run "$REPO/install.sh"
  [[ "$output" != *"retired"* ]]
  [ "$(sha256sum < "$HOME/.claude/settings.json")" = "$h1" ]
}

@test "settings holding only the template's ask rules end with no ask list at all" {
  mkdir -p "$HOME/.claude"
  jq -n --argjson ask "$released_ask" '{permissions: {ask: $ask}}' > "$HOME/.claude/settings.json"
  "$REPO/install.sh" 2>/dev/null
  json '!exists $d->{permissions}{ask}'
}

@test "settings seeded from ct #11 to #14 lose the git ask rules and the allow of git whole" {
  mkdir -p "$HOME/.claude"
  jq -n --argjson ask "$(retired_json)" '{permissions: {
      ask: ($ask + ["Bash(terraform apply*)"]),
      allow: ["Bash(git *)", "Bash(direnv exec*git *)", "WebFetch", "Bash(kubectl get:*)"]}}' > "$HOME/.claude/settings.json"
  [ "$(decide "git push --force origin main")" = ask ]
  [ "$(decide "git push origin main")" = allow ]
  "$REPO/install.sh" 2>/dev/null
  json 'join(",", @{$d->{permissions}{ask}}) eq "Bash(terraform apply*)"'
  json 'join(",", @{$d->{permissions}{allow}}) eq "Bash(git add *),WebFetch,Bash(kubectl get:*)"'
  # Without its ask rules, an allow of git whole would have let this through unseen.
  [ "$(decide "git push --force origin main")" = none ]
  [ "$(decide "git add a.py")" = allow ]
  h1=$(sha256sum < "$HOME/.claude/settings.json")
  "$REPO/install.sh" 2>/dev/null
  [ "$(sha256sum < "$HOME/.claude/settings.json")" = "$h1" ]
}

@test "an allow of git whole that its owner wrote is kept" {
  mkdir -p "$HOME/.claude"
  jq -n --argjson ask "$released_ask" '{permissions: {ask: $ask, allow: ["Bash(git *)", "Read"]}}' > "$HOME/.claude/settings.json"
  "$REPO/install.sh" 2>/dev/null
  json 'join(",", @{$d->{permissions}{allow}}) eq "Bash(git *),Read"'
}

@test "every profile's settings lose the template's ask rules too" {
  mkdir -p "$CT_HOME/.profiles/acme/claude"
  jq -n --argjson ask "$released_ask" '{permissions: {ask: ($ask + ["Bash(mine *)"])}}' > "$CT_HOME/.profiles/acme/claude/settings.json"
  "$REPO/install.sh" 2>/dev/null
  jq -e '.permissions.ask == ["Bash(mine *)"]' "$CT_HOME/.profiles/acme/claude/settings.json"
}

@test "rm -rf of a workspace's scratch is not denied; rm -rf of the root is" {
  "$REPO/install.sh" 2>/dev/null
  [ "$(decide "rm -rf $CT_HOME/ws/.scratch/sub")" != deny ]
  [ "$(decide "rm -rf /tmp/x")" != deny ]
  [ "$(decide "rm -rf /")" = deny ]
  [ "$(decide "rm -rf / --no-preserve-root")" = deny ]
}

@test "an existing settings.json loses the template's broad rm deny and keeps its own denies" {
  mkdir -p "$HOME/.claude"
  printf '%s\n' '{"permissions": {"deny": ["Bash(rm -rf /*)", "Read(**/*.pem)"]}}' > "$HOME/.claude/settings.json"
  "$REPO/install.sh" 2>/dev/null
  json '!grep { $_ eq "Bash(rm -rf /*)" } @{$d->{permissions}{deny}}'
  json 'grep { $_ eq "Read(**/*.pem)" } @{$d->{permissions}{deny}}'
  [ "$(decide "rm -rf $CT_HOME/ws/.scratch/sub")" != deny ]
  [ "$(decide "rm -rf /")" = deny ]
  h1=$(sha256sum < "$HOME/.claude/settings.json")
  "$REPO/install.sh" 2>/dev/null
  [ "$(sha256sum < "$HOME/.claude/settings.json")" = "$h1" ]
}


# --- 3f: autoMode tells the classifier what a ct workspace is ----------------

ct_env()   { jq -r '.autoMode.environment[] | select(startswith("**Workspace layout (ct)**:"))' "$1"; }
ct_allow() { jq -r '.autoMode.allow[] | select(startswith("Workspace Scratch Cleanup (ct):"))' "$1"; }

@test "a fresh install describes the workspace to the classifier and keeps Claude Code's own entries" {
  "$REPO/install.sh" 2>/dev/null
  s="$HOME/.claude/settings.json"
  jq -e '.autoMode.environment[0] == "$defaults" and .autoMode.allow[0] == "$defaults"' "$s"
  [[ "$(ct_env "$s")" == *"is not itself a git repository"* ]]
  [[ "$(ct_allow "$s")" == *".scratch/"* ]]
  jq -e '.autoMode | has("soft_deny") | not' "$s"      # ct blocks nothing more, and unblocks nothing
}

@test "settings without autoMode gain ct's entries after \$defaults" {
  mkdir -p "$HOME/.claude"; echo '{"model":"x"}' > "$HOME/.claude/settings.json"
  "$REPO/install.sh" 2>/dev/null
  s="$HOME/.claude/settings.json"
  jq -e '(.autoMode.environment | length) == 2 and .autoMode.environment[0] == "$defaults"' "$s"
  jq -e '(.autoMode.allow | length) == 2 and .autoMode.allow[0] == "$defaults"' "$s"
  h1=$(sha256sum < "$s"); "$REPO/install.sh" 2>/dev/null; [ "$(sha256sum < "$s")" = "$h1" ]
}

@test "a site's own autoMode entries are kept as they are, with ct's added beside them" {
  mkdir -p "$HOME/.claude"
  printf '%s\n' '{"autoMode": {"environment": ["**Organization**: Acme", "**Source control**: git.acme.example/acme"],
    "soft_deny": ["$defaults", "Acme Rule: never touch billing"]}}' > "$HOME/.claude/settings.json"
  "$REPO/install.sh" 2>/dev/null
  s="$HOME/.claude/settings.json"
  # the site chose to replace the default environment: ct adds its entry and no $defaults
  jq -e '.autoMode.environment[0:2] == ["**Organization**: Acme", "**Source control**: git.acme.example/acme"]' "$s"
  jq -e '(.autoMode.environment | length) == 3 and (.autoMode.environment | index("$defaults") | not)' "$s"
  [[ -n "$(ct_env "$s")" ]]
  jq -e '.autoMode.soft_deny == ["$defaults", "Acme Rule: never touch billing"]' "$s"
  jq -e '.autoMode.allow[0] == "$defaults"' "$s"       # a list ct creates keeps the defaults
  h1=$(sha256sum < "$s"); "$REPO/install.sh" 2>/dev/null; [ "$(sha256sum < "$s")" = "$h1" ]
}

@test "an entry of ct's that a release reworded is replaced, and one it dropped is removed" {
  mkdir -p "$HOME/.claude"
  printf '%s\n' '{"autoMode": {"environment": ["$defaults", "**Workspace layout (ct)**: an older wording", "**Old thing (ct)**: gone since", "**Organization**: Acme"],
    "allow": ["$defaults", "Workspace Scratch Cleanup (ct): an older wording"]}}' > "$HOME/.claude/settings.json"
  "$REPO/install.sh" 2>/dev/null
  s="$HOME/.claude/settings.json"
  [[ "$(ct_env "$s")" == *"is not itself a git repository"* ]]
  [[ "$(ct_allow "$s")" != *"an older wording"* ]]
  jq -e '.autoMode.environment | map(select(test("\\(ct\\)"))) | length == 1' "$s"
  jq -e '.autoMode.environment | index("**Organization**: Acme")' "$s"
  jq -e '.autoMode.environment[0] == "$defaults" and .autoMode.environment[1] == (.autoMode.environment | map(select(test("^\\*\\*Workspace layout"))) | .[0])' "$s"
}

@test "every profile's settings describe the workspace too" {
  mkdir -p "$CT_HOME/.profiles/acme/claude"; echo '{"model":"m"}' > "$CT_HOME/.profiles/acme/claude/settings.json"
  "$REPO/install.sh" 2>/dev/null
  [[ -n "$(ct_env "$CT_HOME/.profiles/acme/claude/settings.json")" ]]
  [[ -n "$(ct_allow "$CT_HOME/.profiles/acme/claude/settings.json")" ]]
}
