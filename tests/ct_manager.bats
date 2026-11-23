#!/usr/bin/env bats
# Tests for bin/ct-manager: which subscriptions are out of usage, and what a
# profile manager's watch hands it (docs/profile-managers.md).

setup() {
  REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  export PATH="$REPO/tests/stubs:$PATH"
  export HOME="$BATS_TEST_TMPDIR/home"
  unset WORKSPACE_ROOT CT_WORKSPACE_ROOT CT_PROFILE CT_FRESH XDG_CONFIG_HOME CLAUDE_CONFIG_DIR
  export TMUX_STUB_LOG="$BATS_TEST_TMPDIR/tmux.log" TMUX_STUB_SESSIONS="$BATS_TEST_TMPDIR/sessions" CT_DETACH=1
  : > "$TMUX_STUB_LOG"; : > "$TMUX_STUB_SESSIONS"
  export CT_WATCH_INTERVAL=1
  R="$HOME/dev"; P="$R/.profiles"
  for p in a b c; do mkdir -p "$P/$p/claude"; echo '{"oauthAccount":{"organizationUuid":"0b0b0b0b-0000-0000-0000-00000000000'"${#p}"'"}}' > "$P/$p/claude/.claude.json"; done
  printf 'MANAGED=(a b c)\n' > "$P/managers.conf"
}

ago() { date -u -d "$1" +%Y-%m-%dT%H:%M:%S.000Z; }
ws() { # workspace profile: one on that profile
  mkdir -p "$R/$1"; printf 'ct_profile=%s\n' "$2" > "$R/$1/.envrc"
}
said() { # profile workspace when [limit text]: an assistant turn in its transcript
  local d="$P/$1/claude/projects/$(printf '%s' "$R/$2" | tr -c 'A-Za-z0-9' '-')"
  mkdir -p "$d"
  if [[ -n ${4:-} ]]; then
    jq -cn --arg t "$(ago "$3")" --arg x "$4" '{type:"assistant",timestamp:$t,message:{model:"<synthetic>",content:[{type:"text",text:$x}]}}'
  else
    jq -cn --arg t "$(ago "$3")" '{type:"assistant",timestamp:$t,message:{model:"claude-opus-5-5",content:[{type:"text",text:"done"}]}}'
  fi >> "$d/s.jsonl"
}
weekly() { echo "You've hit your weekly limit · resets $(date -u -d "$1" '+%b %-d, %-I%P') (UTC)"; }
watch_as() { run timeout 5 "$REPO/bin/ct-manager" watch "$1"; }

@test "status: out while the newest limit beats the newest real reply and its reset is ahead" {
  ws w1 a; ws w2 a; ws w3 b
  said a w1 '-2 hours'
  said a w2 '-1 hour' "$(weekly '+2 days')"
  said b w3 '-3 hours' "$(weekly '+1 day')"
  said b w3 '-1 hour'
  run "$REPO/bin/ct-manager" status
  [ "$status" -eq 0 ]
  [[ ${lines[0]} == $'a\tout\t'*$'\tw1 w2' ]]
  [[ ${lines[1]} == $'b\tok\t-\t-\tw3' ]]
  [[ ${lines[2]} == $'c\tok\t-\t-\t' ]]
}

@test "status: a limit whose reset has passed is no longer out" {
  ws w1 a
  said a w1 '-3 hours' "You've hit your 5-hour limit · resets $(date -u -d '-1 hour' '+%-I%P') (UTC)"
  run "$REPO/bin/ct-manager" status
  [[ ${lines[0]} == $'a\tok\t-\t'* ]]
}

@test "watch: with nothing armed, the first manager that could take them says OUT, once" {
  ws w1 a; ws w2 a; ws a-manager a
  limit="$(weekly '+2 days')"   # one outage, one reset text, even across an hour
  said a w1 '-10 min' "$limit"
  watch_as b
  [ "$status" -eq 0 ]
  [[ $output == "OUT a "*" w1 w2" ]]
  watch_as b
  [ "$status" -eq 124 ]
  said a w2 '-1 min' "$limit"   # another agent hits the same limit later
  watch_as b
  [ "$status" -eq 124 ]
  watch_as c
  [ "$status" -eq 124 ]
}

@test "watch: an armed pair takes the agents, in order; a site's MIN_OUTAGE waits out a short one" {
  ws w1 a; ws w2 a
  said a w1 '-10 min' "$(weekly '+2 days')"
  echo 'a c' > "$P/managers.armed"
  watch_as c
  [ "$output" = $'TAKE w1 a\nTAKE w2 a' ]
  watch_as b
  [[ $output == "OUT a "* ]]
  : > "$P/managers.armed"; echo 'a b' > "$P/managers.armed"; rm -rf "$P/.managers-state"
  printf 'MANAGED=(a b c)\nMIN_OUTAGE=10800\n' > "$P/managers.conf"
  said a w2 '-1 min' "You've hit your 5-hour limit · resets $(date -u -d '+1 hour' '+%-I:%M%P') (UTC)"
  watch_as b
  [[ $output == "OUT a "* ]]
}

@test "watch: a later manager in order steps in only after the stagger" {
  ws w1 a
  said a w1 '-1 min' "$(weekly '+2 days')"
  printf 'a b\na c\n' > "$P/managers.armed"
  watch_as c
  [ "$status" -eq 124 ]
  watch_as b
  [ "$output" = "TAKE w1 a" ]
}

@test "watch: ONLY keeps a profile to its own workspaces, and a group goes only where all of it may" {
  ws x-one a; ws y-one a; ws y-two a
  said a x-one '-10 min' "$(weekly '+2 days')"
  printf 'MANAGED=(a b c)\nONLY=([b]="x-*")\nTOGETHER=([g]="x-one y-two")\n' > "$P/managers.conf"
  printf 'a b\na c\n' > "$P/managers.armed"
  watch_as b
  [ "$status" -eq 124 ]
  watch_as c
  [ "$output" = $'TAKE x-one a g\nTAKE y-one a\nTAKE y-two a g' ]
}

@test "watch: a group apart on this host is reported once a day, by the first manager" {
  ws x-one a; ws x-two b
  said a x-one '-1 hour'
  printf 'MANAGED=(a b c)\nTOGETHER=([g]="x-one x-two x-remote")\n' > "$P/managers.conf"
  watch_as a
  [ "$output" = "SPLIT g x-one=a x-two=b" ]
  watch_as a
  [ "$status" -eq 124 ]
  watch_as b
  [ "$status" -eq 124 ]
}

@test "watch: a manager that stopped on its own limit is woken once its profile resets" {
  ws a-manager a
  said a a-manager '-5 hours' "You've hit your 5-hour limit · resets $(date -u -d '-30 min' '+%-I:%M%P') (UTC)"
  watch_as b
  [ "$output" = "WAKE a-manager" ]
  watch_as b
  [ "$status" -eq 124 ]
}

@test "watch: managers and STAYS never move, and an out manager does nothing" {
  ws a-manager a; ws mine a
  said a mine '-10 min' "$(weekly '+2 days')"
  printf 'MANAGED=(a b c)\nSTAYS=("*-manager" mine)\n' > "$P/managers.conf"
  echo 'a b' > "$P/managers.armed"
  watch_as b
  [ "$status" -eq 124 ]
  watch_as a
  [ "$status" -eq 124 ]
}

@test "peers names the other hosts' managers for a group's move" {
  printf 'MANAGED=(a b)\nPEERS=([g]="{profile}-manager-far other")\n' > "$P/managers.conf"
  run "$REPO/bin/ct-manager" peers g b
  [ "$output" = $'b-manager-far\nother' ]
  run "$REPO/bin/ct-manager" peers h b
  [ -z "$output" ]
}

@test "init makes the manager workspace with the brief, trusted, and starts it on the profile" {
  run "$REPO/bin/ct-manager" init b
  [ "$status" -eq 0 ]
  [ "$(readlink -f "$R/b-manager/CLAUDE.md")" = "$(readlink -f "$REPO/docs/profile-managers.md")" ]
  jq -e '.projects["'"$R/b-manager"'"].hasTrustDialogAccepted' "$P/b/claude/.claude.json"
  grep -qx 'ct_profile=b' "$R/b-manager/.envrc"
  grep -q 'new-session -d -s claude-b-manager' "$TMUX_STUB_LOG"
}

@test "ct-manager --help prints its commands" {
  run "$REPO/bin/ct-manager" --help
  [ "$status" -eq 0 ]
  [[ $output == *"ct-manager watch"* && $output == *"TOGETHER"* && $output != *"set -uo"* ]]
}

@test "watch: by default an armed pair moves at once, however soon the limit resets" {
  ws w1 a
  said a w1 '-1 min' "You've hit your 5-hour limit · resets $(date -u -d '+1 hour' '+%-I:%M%P') (UTC)"
  echo 'a b' > "$P/managers.armed"
  watch_as b
  [ "$output" = "TAKE w1 a" ]
}
