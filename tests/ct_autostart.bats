#!/usr/bin/env bats
# Tests for bin/ct-autostart: gating flags, the leading-hyphen transcript
# convention, idempotence and the failure tally.

setup() {
  REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  export PATH="$REPO/tests/stubs:$REPO/bin:$PATH"
  export TMUX_STUB_LOG="$BATS_TEST_TMPDIR/tmux.log"
  export TMUX_STUB_SESSIONS="$BATS_TEST_TMPDIR/sessions"
  export CLAUDE_STUB_LOG="$BATS_TEST_TMPDIR/claude.log"
  : > "$TMUX_STUB_LOG"; : > "$TMUX_STUB_SESSIONS"; : > "$CLAUDE_STUB_LOG"
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/dev/agent-one" "$HOME/dev/agent-two"
  export CT_AUTOSTART_STAGGER=0
  # The suite must not inherit the caller's ct settings: an agent started BY
  # ct-autostart runs with CT_AUTOSTART_GLOB set, and the defaults are under test.
  unset CT_AUTOSTART_GLOB CT_AUTOSTART_FORCE CT_AUTOSTART_INTERVAL CT_AUTOSTART_RETRY CT_AUTOSTART_DIALOG_RE CT_WORKSPACE_ROOT CT_FRESH CT_DETACH
  # transcript dir names are the cwd with / -> -  (they START with a hyphen)
  mktranscript() {
    local ws="$1"; local key; key="$HOME/.claude/projects/$(printf '%s' "$ws" | tr -c 'A-Za-z0-9' '-')"
    mkdir -p "$key" && for _ in $(seq 60); do printf "%s\n" "{\"sessionId\":\"x\"}"; done > "$key/x.jsonl"
  }
  export -f mktranscript
}

@test "does nothing without the opt-in file" {
  run "$REPO/bin/ct-autostart"
  [ "$status" -eq 0 ]
  [[ "$output" == *"not enabled"* ]]
  ! grep -q new-session "$TMUX_STUB_LOG"
}

@test "kill switch wins over opt-in" {
  touch "$HOME/.ct-autostart" "$HOME/.ct-noautostart"
  run "$REPO/bin/ct-autostart"
  [ "$status" -eq 0 ]
  [[ "$output" == *"disabled"* ]]
}

@test "starts workspaces with transcripts, resumes that transcript by id" {
  touch "$HOME/.ct-autostart"
  mktranscript "$HOME/dev/agent-one"
  run env CT_AUTOSTART_FORCE=1 CT_AUTOSTART_NO_WARMUP=1 "$REPO/bin/ct-autostart"
  [ "$status" -eq 0 ]
  [[ "$output" == *"agent-one: started"* ]]
  grep -q -- "--resume x" "$TMUX_STUB_LOG"
}

@test "idempotent: an already-running session is skipped" {
  touch "$HOME/.ct-autostart"
  mktranscript "$HOME/dev/agent-one"
  echo "claude-agent-one" > "$TMUX_STUB_SESSIONS"
  run env CT_AUTOSTART_NO_WARMUP=1 "$REPO/bin/ct-autostart"
  [ "$status" -eq 0 ]
  [[ "$output" == *"agent-one: already running"* ]]
  ! grep -q -- 'new-session.*claude-agent-one ' "$TMUX_STUB_LOG"
}

@test "warm-up runs once unless CT_AUTOSTART_NO_WARMUP" {
  touch "$HOME/.ct-autostart"
  run "$REPO/bin/ct-autostart"
  grep -q -- 'claude -p ok' "$CLAUDE_STUB_LOG"
  : > "$CLAUDE_STUB_LOG"
  run env CT_AUTOSTART_NO_WARMUP=1 "$REPO/bin/ct-autostart"
  ! grep -q -- 'claude -p' "$CLAUDE_STUB_LOG"
}

@test "summary line reports counts and exit reflects failures" {
  touch "$HOME/.ct-autostart"
  run env CT_AUTOSTART_NO_WARMUP=1 "$REPO/bin/ct-autostart"
  [[ "$output" == *"done — started="* ]]
  [ "$status" -eq 0 ]
}

@test "default discovery is agent-* only" {
  touch "$HOME/.ct-autostart"
  mkdir -p "$HOME/dev/plain"; mktranscript "$HOME/dev/plain"; mktranscript "$HOME/dev/agent-one"
  run env CT_AUTOSTART_NO_WARMUP=1 "$REPO/bin/ct-autostart"
  [[ "$output" == *"agent-one: started"* ]]
  [[ "$output" != *"plain:"* ]]
}

@test "CT_AUTOSTART_GLOB widens discovery to plainly named workspaces" {
  touch "$HOME/.ct-autostart"
  mkdir -p "$HOME/dev/plain"; mktranscript "$HOME/dev/plain"
  run env CT_AUTOSTART_GLOB='*' CT_AUTOSTART_NO_WARMUP=1 "$REPO/bin/ct-autostart"
  [ "$status" -eq 0 ]
  [[ "$output" == *"plain: started"* ]]
}

@test "dot-dirs are never workspaces, even with a transcript" {
  touch "$HOME/.ct-autostart"
  mkdir -p "$HOME/dev/.gitcache"; mktranscript "$HOME/dev/.gitcache"
  run env CT_AUTOSTART_GLOB='*' CT_AUTOSTART_NO_WARMUP=1 "$REPO/bin/ct-autostart"
  [[ "$output" != *".gitcache"* ]]
  ! grep -q -- 'claude-.gitcache' "$TMUX_STUB_LOG"
}

@test "--restart stops managed sessions and starts them again" {
  touch "$HOME/.ct-autostart"
  mktranscript "$HOME/dev/agent-one"
  echo "claude-agent-one" > "$TMUX_STUB_SESSIONS"
  run env CT_AUTOSTART_NO_WARMUP=1 "$REPO/bin/ct-autostart" --restart
  [ "$status" -eq 0 ]
  grep -q -- 'kill-session -t =claude-agent-one' "$TMUX_STUB_LOG"
  [[ "$output" == *"agent-one: stopped"* ]]
  [[ "$output" == *"agent-one: started"* ]]
}

@test "--restart never kills the session it runs inside" {
  touch "$HOME/.ct-autostart"
  mktranscript "$HOME/dev/agent-one"; mktranscript "$HOME/dev/agent-two"
  printf 'claude-agent-one\nclaude-agent-two\n' > "$TMUX_STUB_SESSIONS"
  run env TMUX=/tmp/fake,1,0 TMUX_STUB_SELF=claude-agent-two CT_AUTOSTART_NO_WARMUP=1 \
      "$REPO/bin/ct-autostart" --restart
  grep -q -- 'kill-session -t =claude-agent-one' "$TMUX_STUB_LOG"
  ! grep -q -- 'kill-session -t =claude-agent-two' "$TMUX_STUB_LOG"
  [[ "$output" == *"agent-two: this command runs inside it"* ]]
}

@test "--restart leaves sessions it does not manage alone" {
  touch "$HOME/.ct-autostart"
  printf 'claude-something-else\n' > "$TMUX_STUB_SESSIONS"
  run env CT_AUTOSTART_NO_WARMUP=1 "$REPO/bin/ct-autostart" --restart
  ! grep -q -- 'kill-session' "$TMUX_STUB_LOG"
}

@test "--loop repeats the pass and survives a failed round" {
  touch "$HOME/.ct-autostart"
  run env CT_AUTOSTART_NO_WARMUP=1 CT_AUTOSTART_INTERVAL=0.1 \
      timeout 2 "$REPO/bin/ct-autostart" --loop
  # timeout ends it; what matters is that more than one round ran
  [ "$(grep -c 'done —' <<<"$output")" -ge 2 ]
}

@test "--loop stops when the kill switch appears" {
  touch "$HOME/.ct-autostart"
  ( sleep 0.5; touch "$HOME/.ct-noautostart" ) &
  run env CT_AUTOSTART_NO_WARMUP=1 CT_AUTOSTART_INTERVAL=0.1 \
      timeout 5 "$REPO/bin/ct-autostart" --loop
  [ "$status" -eq 0 ]
  [[ "$output" == *"stopping the loop"* ]]
}

@test "an unknown argument fails loudly instead of doing a pass" {
  touch "$HOME/.ct-autostart"
  run "$REPO/bin/ct-autostart" --lopo
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown argument"* ]]
  ! grep -q new-session "$TMUX_STUB_LOG"
}

@test "a workspace without a transcript gets a fresh session instead of being skipped" {
  touch "$HOME/.ct-autostart"
  run env CT_AUTOSTART_NO_WARMUP=1 "$REPO/bin/ct-autostart"
  [ "$status" -eq 0 ]
  [[ "$output" == *"agent-one: started (no transcript yet — fresh session)"* ]]
  grep -q -- 'new-session.*claude-agent-one' "$TMUX_STUB_LOG"
  ! grep -q -- '--resume' "$TMUX_STUB_LOG"
}

@test "a running session waiting at a dialog is reported, not touched" {
  touch "$HOME/.ct-autostart"
  echo "claude-agent-one" > "$TMUX_STUB_SESSIONS"
  mkdir -p "$BATS_TEST_TMPDIR/screens"
  printf '  New MCP server found in this project: x\n  ❯ Continue without using this MCP server\n  Enter to confirm · Esc to cancel\n' \
    > "$BATS_TEST_TMPDIR/screens/claude-agent-one"
  run env TMUX_STUB_SCREENS="$BATS_TEST_TMPDIR/screens" CT_AUTOSTART_NO_WARMUP=1 "$REPO/bin/ct-autostart"
  [ "$status" -eq 0 ]
  [[ "$output" == *"agent-one: WARNING — running, but waiting at a prompt: New MCP server found"* ]]
  [[ "$output" == *"warned=1"* ]]
  ! grep -q -- 'send-keys' "$TMUX_STUB_LOG"
  ! grep -q -- 'kill-session' "$TMUX_STUB_LOG"
}

@test "a blank or unreadable screen is reported too" {
  touch "$HOME/.ct-autostart"
  printf 'claude-agent-one\nclaude-agent-two\n' > "$TMUX_STUB_SESSIONS"
  mkdir -p "$BATS_TEST_TMPDIR/screens"
  printf '\n   \n\n' > "$BATS_TEST_TMPDIR/screens/claude-agent-one"
  echo "-" > "$BATS_TEST_TMPDIR/screens/claude-agent-two"
  run env TMUX_STUB_SCREENS="$BATS_TEST_TMPDIR/screens" CT_AUTOSTART_NO_WARMUP=1 "$REPO/bin/ct-autostart"
  [[ "$output" == *"agent-one: WARNING — running, but blank screen"* ]]
  [[ "$output" == *"agent-two: WARNING — running, but its screen could not be read"* ]]
  [[ "$output" == *"warned=2"* ]]
}

@test "a healthy running session gets no warning" {
  touch "$HOME/.ct-autostart"
  echo "claude-agent-one" > "$TMUX_STUB_SESSIONS"
  run env CT_AUTOSTART_NO_WARMUP=1 "$REPO/bin/ct-autostart"
  [[ "$output" == *"agent-one: already running"* ]]
  [[ "$output" != *"WARNING"* ]]
  [[ "$output" == *"warned=0"* ]]
}


@test "--supervise waits quietly while not enabled, and logs it once" {
  run env CT_AUTOSTART_RETRY=0.1 timeout 1 "$REPO/bin/ct-autostart" --supervise
  [ "$(grep -c 'waiting: not enabled' <<<"$output")" -eq 1 ]
  [[ "$output" != *"looping every"* ]]
}

@test "--supervise restarts --loop when it exits" {
  touch "$HOME/.ct-autostart"
  # A tmux that cannot run makes every --loop give up at once (exit 1).
  mkdir -p "$BATS_TEST_TMPDIR/broken"
  printf '#!/bin/sh\nexit 1\n' > "$BATS_TEST_TMPDIR/broken/tmux"; chmod +x "$BATS_TEST_TMPDIR/broken/tmux"
  run env PATH="$BATS_TEST_TMPDIR/broken:$PATH" CT_AUTOSTART_NO_WARMUP=1 CT_AUTOSTART_RETRY=0.1 \
      CT_AUTOSTART_SUPERVISE_RUNS=2 timeout 20 "$REPO/bin/ct-autostart" --supervise
  [ "$status" -eq 0 ]
  [ "$(grep -c 'no working tmux' <<<"$output")" -eq 2 ]
  [[ "$output" == *"--loop exited (1) — starting it again"* ]]
}

@test "a dialog the pattern does not know is still caught: no input box on screen" {
  touch "$HOME/.ct-autostart"
  echo "claude-agent-one" > "$TMUX_STUB_SESSIONS"
  mkdir -p "$BATS_TEST_TMPDIR/screens"
  # edgelab's effort dialog, verbatim: no footer, no known question.
  printf '  Use Fable 5.1 at high effort by default?\n  ❯ Keep xhigh\n    Switch Fable 5.1 to high effort\n' \
    > "$BATS_TEST_TMPDIR/screens/claude-agent-one"
  run env TMUX_STUB_SCREENS="$BATS_TEST_TMPDIR/screens" CT_AUTOSTART_NO_WARMUP=1 "$REPO/bin/ct-autostart"
  [[ "$output" == *"agent-one: WARNING — running, but no input box on screen (a dialog?) — last line: Switch Fable 5.1 to high effort"* ]]
  [[ "$output" == *"warned=1"* ]]
}

@test "a fresh start in an untrusted workspace says it will likely wait at the trust dialog" {
  touch "$HOME/.ct-autostart"
  command -v jq >/dev/null || skip "jq not installed"
  printf '{"projects":{"%s":{"hasTrustDialogAccepted":true}}}' "$HOME/dev/agent-two" > "$HOME/.claude.json"
  run env CT_AUTOSTART_NO_WARMUP=1 "$REPO/bin/ct-autostart"
  [[ "$output" == *"agent-one: started (no transcript yet — fresh session) — not trusted yet"* ]]
  [[ "$output" == *"agent-two: started (no transcript yet — fresh session)"* ]]
  [[ "$output" != *"agent-two: started (no transcript yet — fresh session) — not trusted"* ]]
}

@test "resumes, not 'no transcript', where bash has no compgen (Fedora 43)" {
  touch "$HOME/.ct-autostart"
  mktranscript "$HOME/dev/agent-one"
  printf 'enable -n compgen complete 2>/dev/null\n' > "$BATS_TEST_TMPDIR/nocompgen.sh"
  run env BASH_ENV="$BATS_TEST_TMPDIR/nocompgen.sh" CT_AUTOSTART_NO_WARMUP=1 "$REPO/bin/ct-autostart"
  [ "$status" -eq 0 ]
  [[ "$output" == *"agent-one: started"* ]]
  [[ "$output" != *"agent-one: started (no transcript"* ]]
  [[ "$output" != *"command not found"* ]]
  grep -q -- "--resume x" "$TMUX_STUB_LOG"
}

# --- agents: what ct recorded is what comes back

mkrecord() { mkdir -p "$HOME/.local/share/ct/agents"; printf '%b' "$2" > "$HOME/.local/share/ct/agents/$1"; }

@test "no record: claude only, exactly as before agents existed" {
  touch "$HOME/.ct-autostart"
  run env CT_AUTOSTART_NO_WARMUP=1 "$REPO/bin/ct-autostart"
  [ "$status" -eq 0 ]
  grep -q -- 'new-session -d -s claude-agent-one ' "$TMUX_STUB_LOG"
  ! grep -q -- 'opencode' "$TMUX_STUB_LOG"
  [[ "$output" == *"agent-one: started"* ]]
}

@test "starts every recorded agent, opencode on its recorded port" {
  touch "$HOME/.ct-autostart"
  mkrecord agent-one 'claude\nopencode 4150\n'
  run env CT_AUTOSTART_NO_WARMUP=1 "$REPO/bin/ct-autostart"
  [ "$status" -eq 0 ]
  grep -q -- 'new-session -d -s claude-agent-one ' "$TMUX_STUB_LOG"
  grep -q -- 'new-session -d -s opencode-agent-one .*opencode --port 4150 --hostname 127.0.0.1 --continue' "$TMUX_STUB_LOG"
  [[ "$output" == *"agent-one [opencode]: started"* ]]
}

@test "an empty record starts nothing for that workspace" {
  touch "$HOME/.ct-autostart"
  mkrecord agent-one ''
  run env CT_AUTOSTART_NO_WARMUP=1 "$REPO/bin/ct-autostart"
  ! grep -q -- 'agent-one' "$TMUX_STUB_LOG"
  grep -q -- 'new-session -d -s claude-agent-two ' "$TMUX_STUB_LOG"
}

@test "no claude anywhere: no claude warm-up" {
  touch "$HOME/.ct-autostart"
  mkrecord agent-one 'opencode 4150\n'
  mkrecord agent-two ''
  run "$REPO/bin/ct-autostart"
  [ "$status" -eq 0 ]
  [ ! -s "$CLAUDE_STUB_LOG" ]
  [[ "$output" != *"warm-up"* ]]
}

@test "a healthy running opencode session is skipped after a health probe" {
  touch "$HOME/.ct-autostart"
  mkrecord agent-one 'opencode 4150\n'; mkrecord agent-two ''
  echo "opencode-agent-one" > "$TMUX_STUB_SESSIONS"
  export CURL_STUB_LOG="$BATS_TEST_TMPDIR/curl.log"
  run env CT_AUTOSTART_NO_WARMUP=1 "$REPO/bin/ct-autostart"
  [[ "$output" == *"agent-one [opencode]: already running"* ]]
  grep -q -- 'http://127.0.0.1:4150/global/health' "$CURL_STUB_LOG"
  ! grep -q -- 'new-session' "$TMUX_STUB_LOG"
}

@test "an opencode session whose server does not answer is a WARNING, not killed" {
  touch "$HOME/.ct-autostart"
  mkrecord agent-one 'opencode 4150\n'; mkrecord agent-two ''
  echo "opencode-agent-one" > "$TMUX_STUB_SESSIONS"
  run env CT_AUTOSTART_NO_WARMUP=1 CURL_STUB_FAIL=1 "$REPO/bin/ct-autostart"
  [[ "$output" == *"agent-one [opencode]: WARNING — running, but its server on port 4150 does not answer"* ]]
  ! grep -q -- 'kill-session' "$TMUX_STUB_LOG"
}

@test "the next pass (what --loop repeats) brings a dead opencode session back" {
  touch "$HOME/.ct-autostart"
  mkrecord agent-one 'opencode 4150\n'; mkrecord agent-two ''
  # first round finds it running; it then dies; the second round restarts it
  echo "opencode-agent-one" > "$TMUX_STUB_SESSIONS"
  run env CT_AUTOSTART_NO_WARMUP=1 "$REPO/bin/ct-autostart"
  : > "$TMUX_STUB_SESSIONS"
  run env CT_AUTOSTART_NO_WARMUP=1 "$REPO/bin/ct-autostart"
  [[ "$output" == *"agent-one [opencode]: started"* ]]
  grep -q -- 'new-session -d -s opencode-agent-one ' "$TMUX_STUB_LOG"
}

@test "--restart stops every recorded agent but never its own session" {
  touch "$HOME/.ct-autostart"
  mkrecord agent-one 'claude\nopencode 4150\n'; mkrecord agent-two ''
  printf 'claude-agent-one\nopencode-agent-one\n' > "$TMUX_STUB_SESSIONS"
  run env CT_AUTOSTART_NO_WARMUP=1 TMUX=1 TMUX_STUB_SELF=claude-agent-one "$REPO/bin/ct-autostart" --restart
  grep -q -- 'kill-session -t =opencode-agent-one' "$TMUX_STUB_LOG"
  ! grep -q -- 'kill-session -t =claude-agent-one' "$TMUX_STUB_LOG"
  [[ "$output" == *"agent-one: this command runs inside it"* ]]
  grep -q -- 'new-session -d -s opencode-agent-one ' "$TMUX_STUB_LOG"
}

# --- wake message and pinned sessions (v0.5.0)

mkpin() { # name session-id dir
  mkdir -p "$HOME/.local/share/ct/sessions" "$3"
  printf 'claude %s %s %s\n' "$2" "$1" "$3" > "$HOME/.local/share/ct/sessions/$1"
  local key; key="$HOME/.claude/projects/$(printf '%s' "$3" | tr -c 'A-Za-z0-9' '-')"
  mkdir -p "$key"; for _ in $(seq 60); do echo '{}'; done > "$key/$2.jsonl"
}

@test "a resumed agent is woken with what happened" {
  touch "$HOME/.ct-autostart"
  mktranscript "$HOME/dev/agent-one"
  run env CT_AUTOSTART_NO_WARMUP=1 CT_POD_START_EPOCH=$(date -d '+1 min' +%s) "$REPO/bin/ct-autostart"
  [ "$status" -eq 0 ]
  grep -q -- 'new-session -d -s claude-agent-one .*machine' "$TMUX_STUB_LOG"
  # agent-two has no transcript: a fresh session, nothing to wake
  ! grep -q -- 'new-session -d -s claude-agent-two .*machine' "$TMUX_STUB_LOG"
}

@test "CT_WAKE=0 wakes nobody" {
  touch "$HOME/.ct-autostart"
  mktranscript "$HOME/dev/agent-one"
  run env CT_WAKE=0 CT_AUTOSTART_NO_WARMUP=1 CT_POD_START_EPOCH=$(date +%s) "$REPO/bin/ct-autostart"
  grep -q -- 'new-session -d -s claude-agent-one ' "$TMUX_STUB_LOG"
  ! grep -q -- 'machine' "$TMUX_STUB_LOG"
}

@test "the machine's start is read from /proc when not given" {
  touch "$HOME/.ct-autostart"
  mktranscript "$HOME/dev/agent-one"
  touch -d '2000-01-01' "$HOME/.claude/projects/"*agent-one/*.jsonl   # long before any boot
  run env CT_AUTOSTART_NO_WARMUP=1 "$REPO/bin/ct-autostart"
  grep -q -- 'new-session -d -s claude-agent-one .*this\\ machine\\ restarted\|this machine restarted' "$TMUX_STUB_LOG"
}

@test "a pinned session is revived by its id, in its dir, and woken" {
  touch "$HOME/.ct-autostart"
  mkpin forky fork-1234 "$HOME/dev/agent-one/wt"
  mkrecord agent-one ''; mkrecord agent-two ''
  run env CT_AUTOSTART_NO_WARMUP=1 CT_POD_START_EPOCH=$(date -d '+1 min' +%s) "$REPO/bin/ct-autostart"
  [ "$status" -eq 0 ]
  [[ "$output" == *"forky (pinned): started"* ]]
  grep -q -- "new-session -d -s claude-forky -c $HOME/dev/agent-one/wt claude --resume fork-1234 --name forky .*machine" "$TMUX_STUB_LOG"
}

@test "a pinned session's health is read by its own name; --restart stops it" {
  touch "$HOME/.ct-autostart"
  mkpin forky fork-1234 "$HOME/dev/agent-one/wt"
  mkrecord agent-one ''; mkrecord agent-two ''
  echo "claude-forky" > "$TMUX_STUB_SESSIONS"
  run env CT_AUTOSTART_NO_WARMUP=1 "$REPO/bin/ct-autostart"
  [[ "$output" == *"forky (pinned): already running — skipping"* ]]
  run env CT_AUTOSTART_NO_WARMUP=1 "$REPO/bin/ct-autostart" --restart
  grep -q -- 'kill-session -t =claude-forky' "$TMUX_STUB_LOG"
}

@test "a pinned session whose dir is gone is a WARNING, not a failure" {
  touch "$HOME/.ct-autostart"
  mkpin forky fork-1234 "$HOME/dev/agent-one/wt"; rm -rf "$HOME/dev/agent-one/wt"
  mkrecord agent-one ''; mkrecord agent-two ''
  run env CT_AUTOSTART_NO_WARMUP=1 "$REPO/bin/ct-autostart"
  [ "$status" -eq 0 ]
  [[ "$output" == *"forky (pinned): WARNING — its directory"*"is gone"* ]]
  ! grep -q new-session "$TMUX_STUB_LOG"
}

@test "a pinned claude session alone still gets the warm-up" {
  touch "$HOME/.ct-autostart"
  mkpin forky fork-1234 "$HOME/dev/agent-one/wt"
  mkrecord agent-one 'opencode 4150\n'; mkrecord agent-two ''
  run "$REPO/bin/ct-autostart"
  grep -q "claude -p ok" "$CLAUDE_STUB_LOG"
}
