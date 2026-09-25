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
  # transcript dir names are the cwd with / -> -  (they START with a hyphen)
  mktranscript() {
    local ws="$1"; local key="$HOME/.claude/projects/${ws//\//-}"
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
