#!/usr/bin/env bats
# Tests for bin/ct against recorded tmux invocations. The stubs prepend PATH;
# ct never executes `claude` itself, so asserting the tmux argv is the truth.

setup() {
  REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  export PATH="$REPO/tests/stubs:$PATH"
  export TMUX_STUB_LOG="$BATS_TEST_TMPDIR/tmux.log"
  export TMUX_STUB_SESSIONS="$BATS_TEST_TMPDIR/sessions"
  : > "$TMUX_STUB_LOG"; : > "$TMUX_STUB_SESSIONS"
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/dev/agent-alpha/repo-x" "$HOME/dev/agent-alpha-2" "$HOME/elsewhere"
  unset CT_DETACH CT_WORKSPACE_ROOT || true
  export CT_DETACH=1   # tests are non-TTY; assert creation, not attach
}

run_ct() { ( cd "$1" && shift && run_from="$PWD" "$REPO/bin/ct" "$@" ); }

@test "session named after the workspace, not the inner repo dir" {
  ( cd "$HOME/dev/agent-alpha/repo-x" && "$REPO/bin/ct" )
  grep -q -- '-s claude-agent-alpha ' "$TMUX_STUB_LOG"
  ! grep -q -- 'claude-repo-x' "$TMUX_STUB_LOG"
}

@test "claude gets --name <workspace> when caller passed no -n" {
  ( cd "$HOME/dev/agent-alpha" && "$REPO/bin/ct" )
  grep -q -- '--name agent-alpha' "$TMUX_STUB_LOG"
}

@test "caller's -n wins over the derived name" {
  ( cd "$HOME/dev/agent-alpha" && "$REPO/bin/ct" -n custom )
  ! grep -q -- '--name agent-alpha' "$TMUX_STUB_LOG"
  grep -q -- '-n custom' "$TMUX_STUB_LOG"
}

@test "CT_WORKSPACE_ROOT overrides the default roots" {
  mkdir -p "$HOME/elsewhere/ws1/inner"
  ( cd "$HOME/elsewhere/ws1/inner" && CT_WORKSPACE_ROOT="$HOME/elsewhere" "$REPO/bin/ct" )
  grep -q -- '-s claude-ws1 ' "$TMUX_STUB_LOG"
}

@test "outside all roots falls back to the current directory name" {
  ( cd "$HOME/elsewhere" && "$REPO/bin/ct" )
  grep -q -- '-s claude-elsewhere ' "$TMUX_STUB_LOG"
}

@test "no trailing dash in sanitized names" {
  mkdir -p "$HOME/dev/agent-b"
  ( cd "$HOME/dev/agent-b" && "$REPO/bin/ct" )
  ! grep -qE -- '-s claude-[A-Za-z0-9_-]*- ' "$TMUX_STUB_LOG"
}

@test "has-session probes use exact-match = prefix" {
  ( cd "$HOME/dev/agent-alpha" && "$REPO/bin/ct" )
  grep -q -- 'has-session -t =claude-agent-alpha' "$TMUX_STUB_LOG"
}

@test "refuses to attach when @ct_workspace names another workspace" {
  echo "claude-agent-alpha" > "$TMUX_STUB_SESSIONS"
  export TMUX_STUB_WS="$HOME/dev/agent-OTHER"
  run bash -c "cd '$HOME/dev/agent-alpha' && '$REPO/bin/ct'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"refusing to attach"* ]]
}

@test "running session + CT_DETACH exits 0 without attaching, args warned as ignored" {
  echo "claude-agent-alpha" > "$TMUX_STUB_SESSIONS"
  export TMUX_STUB_WS="$HOME/dev/agent-alpha"
  run bash -c "cd '$HOME/dev/agent-alpha' && '$REPO/bin/ct' --continue"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already running"* ]]
  ! grep -q -- 'new-session' "$TMUX_STUB_LOG"
}

@test "arguments with spaces survive quoting into the tmux command" {
  ( cd "$HOME/dev/agent-alpha" && "$REPO/bin/ct" -p 'two words' )
  grep -qE -- "two\\\\? words" "$TMUX_STUB_LOG"
}

@test "legacy trailing-dash session gets adopted" {
  echo "claude-agent-alpha-" > "$TMUX_STUB_SESSIONS"
  run bash -c "cd '$HOME/dev/agent-alpha' && '$REPO/bin/ct'"
  grep -q -- 'rename-session -t =claude-agent-alpha- claude-agent-alpha' "$TMUX_STUB_LOG"
}
