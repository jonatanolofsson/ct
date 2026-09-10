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
    mkdir -p "$key" && printf '%s\n' '{"sessionId":"x"}' > "$key/x.jsonl"
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

@test "starts workspaces with transcripts, resumes with --continue" {
  touch "$HOME/.ct-autostart"
  mktranscript "$HOME/dev/agent-one"
  run env CT_AUTOSTART_FORCE=1 CT_AUTOSTART_NO_WARMUP=1 "$REPO/bin/ct-autostart"
  [ "$status" -eq 0 ]
  [[ "$output" == *"agent-one: started"* ]]
  grep -q -- '--continue' "$TMUX_STUB_LOG"
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
