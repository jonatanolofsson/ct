#!/usr/bin/env bats
# Tests for bin/ct against recorded tmux invocations. The stubs prepend PATH;
# ct never executes `claude` itself, so asserting the tmux argv is the truth.

setup() {
  REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  export PATH="$REPO/tests/stubs:$PATH"
  export TMUX_STUB_LOG="$BATS_TEST_TMPDIR/tmux.log"
  export TMUX_STUB_SESSIONS="$BATS_TEST_TMPDIR/sessions"
  # Not the caller's ct settings: an agent started by ct-autostart has some set.
  unset CT_AUTOSTART_GLOB CT_WORKSPACE_ROOT CT_FRESH CT_DETACH
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

@test "claude starts at the workspace root even when ct runs inside a repo" {
  ( cd "$HOME/dev/agent-alpha/repo-x" && "$REPO/bin/ct" )
  # one start dir means one transcript key for the agent, whichever clone ct ran in
  grep -q -- "-c $HOME/dev/agent-alpha " "$TMUX_STUB_LOG"
  ! grep -q -- "-c $HOME/dev/agent-alpha/repo-x " "$TMUX_STUB_LOG"
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

# --- auto-resume (2026-09-11 regression: a dead session must not come back empty)

mkts() { # workspace, session-id, lines
  local key="$HOME/.claude/projects/${1//\//-}"
  mkdir -p "$key"
  local i; : > "$key/$2.jsonl"
  for ((i=0;i<$3;i++)); do echo '{"type":"user"}' >> "$key/$2.jsonl"; done
}

@test "resumes the workspace transcript by id instead of starting fresh" {
  mkts "$HOME/dev/agent-alpha" "aaaaaaaa-1111" 200
  ( cd "$HOME/dev/agent-alpha" && "$REPO/bin/ct" )
  grep -q -- '--resume aaaaaaaa-1111' "$TMUX_STUB_LOG"
}

@test "a stub transcript does not hijack the resume" {
  mkts "$HOME/dev/agent-alpha" "real-0000" 500
  sleep 1
  mkts "$HOME/dev/agent-alpha" "stub-9999" 3      # newer, but tiny
  ( cd "$HOME/dev/agent-alpha" && "$REPO/bin/ct" )
  grep -q -- '--resume real-0000' "$TMUX_STUB_LOG"
  ! grep -q -- 'stub-9999' "$TMUX_STUB_LOG"
}

@test "the newest substantive transcript wins over an older one" {
  mkts "$HOME/dev/agent-alpha" "old-1111" 900
  sleep 1
  mkts "$HOME/dev/agent-alpha" "new-2222" 120
  ( cd "$HOME/dev/agent-alpha" && "$REPO/bin/ct" )
  grep -q -- '--resume new-2222' "$TMUX_STUB_LOG"
}

@test "CT_FRESH=1 starts a new conversation despite a transcript" {
  mkts "$HOME/dev/agent-alpha" "aaaaaaaa-1111" 200
  ( cd "$HOME/dev/agent-alpha" && CT_FRESH=1 "$REPO/bin/ct" )
  ! grep -q -- '--resume' "$TMUX_STUB_LOG"
}

@test "caller's own --continue is not doubled with --resume" {
  mkts "$HOME/dev/agent-alpha" "aaaaaaaa-1111" 200
  ( cd "$HOME/dev/agent-alpha" && "$REPO/bin/ct" --continue )
  ! grep -q -- '--resume' "$TMUX_STUB_LOG"
  grep -q -- '--continue' "$TMUX_STUB_LOG"
}

@test "no transcript at all: plain fresh start, no --resume" {
  ( cd "$HOME/dev/agent-alpha" && "$REPO/bin/ct" )
  ! grep -q -- '--resume' "$TMUX_STUB_LOG"
}

# Fedora 43's bash is built without programmable completion: no compgen. A
# BASH_ENV that disables the builtin reproduces that for every script started.
no_compgen() { printf 'enable -n compgen complete 2>/dev/null\n' > "$BATS_TEST_TMPDIR/nocompgen.sh"; export BASH_ENV="$BATS_TEST_TMPDIR/nocompgen.sh"; }

@test "resumes by id where bash has no compgen (Fedora 43)" {
  mkts "$HOME/dev/agent-alpha" "aaaaaaaa-1111" 200
  no_compgen
  ( cd "$HOME/dev/agent-alpha" && "$REPO/bin/ct" )
  grep -q -- '--resume aaaaaaaa-1111' "$TMUX_STUB_LOG"
}

@test "resumes a workspace whose path has spaces" {
  mkdir -p "$HOME/dev/agent with space"
  mkts "$HOME/dev/agent with space" "bbbbbbbb-2222" 200
  no_compgen
  ( cd "$HOME/dev/agent with space" && "$REPO/bin/ct" )
  grep -q -- '--resume bbbbbbbb-2222' "$TMUX_STUB_LOG"
}

# --- agents: CT_AGENT=opencode, the agent record, ports

record() { cat "$HOME/.local/share/ct/agents/$1"; }

@test "unknown CT_AGENT is refused" {
  run bash -c "cd '$HOME/dev/agent-alpha' && CT_AGENT=vim '$REPO/bin/ct'"
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown CT_AGENT"* ]]
  ! grep -q new-session "$TMUX_STUB_LOG"
}

@test "opencode: own session, loopback server, workspace root, --continue" {
  ( cd "$HOME/dev/agent-alpha/repo-x" && CT_AGENT=opencode "$REPO/bin/ct" )
  grep -qE -- "new-session -d -s opencode-agent-alpha -c $HOME/dev/agent-alpha opencode --port 41[0-9]{2} --hostname 127.0.0.1 --continue" "$TMUX_STUB_LOG"
  grep -q -- 'set-option -t opencode-agent-alpha @ct_agent opencode' "$TMUX_STUB_LOG"
  grep -qE -- 'set-option -t opencode-agent-alpha @ct_port 41[0-9]{2}' "$TMUX_STUB_LOG"
  ! grep -q -- '--name' "$TMUX_STUB_LOG"
}

@test "opencode: the port is recorded and reused on the next launch" {
  ( cd "$HOME/dev/agent-alpha" && CT_AGENT=opencode "$REPO/bin/ct" )
  port="$(record agent-alpha | awk '$1=="opencode"{print $2}')"
  [[ "$port" =~ ^41[0-9]{2}$ ]]
  : > "$TMUX_STUB_SESSIONS"; : > "$TMUX_STUB_LOG"      # the session died
  ( cd "$HOME/dev/agent-alpha" && CT_AGENT=opencode "$REPO/bin/ct" )
  grep -q -- "--port $port " "$TMUX_STUB_LOG"
  [ "$(record agent-alpha | grep -c opencode)" -eq 1 ]
}

@test "opencode: two workspaces never share a port, a full range is an error" {
  export CT_OPENCODE_PORT_MIN=4100 CT_OPENCODE_PORT_MAX=4101
  mkdir -p "$HOME/dev/agent-c"
  ( cd "$HOME/dev/agent-alpha" && CT_AGENT=opencode "$REPO/bin/ct" )
  ( cd "$HOME/dev/agent-alpha-2" && CT_AGENT=opencode "$REPO/bin/ct" )
  a="$(record agent-alpha | awk '{print $2}')"; b="$(record agent-alpha-2 | awk '{print $2}')"
  [ "$a" != "$b" ]
  run bash -c "cd '$HOME/dev/agent-c' && CT_AGENT=opencode '$REPO/bin/ct'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no free opencode port"* ]]
}

@test "opencode: CT_FRESH and the caller's own session flag drop --continue" {
  ( cd "$HOME/dev/agent-alpha" && CT_AGENT=opencode CT_FRESH=1 "$REPO/bin/ct" )
  ! grep -q -- '--continue' "$TMUX_STUB_LOG"
  : > "$TMUX_STUB_SESSIONS"; : > "$TMUX_STUB_LOG"
  ( cd "$HOME/dev/agent-alpha" && CT_AGENT=opencode "$REPO/bin/ct" -s ses_123 )
  ! grep -q -- '--continue' "$TMUX_STUB_LOG"
  grep -q -- '-s ses_123' "$TMUX_STUB_LOG"
}

@test "opencode starts beside a running claude session, not attached to it" {
  echo "claude-agent-alpha" > "$TMUX_STUB_SESSIONS"
  export TMUX_STUB_WS="$HOME/dev/agent-alpha"
  run bash -c "cd '$HOME/dev/agent-alpha' && CT_AGENT=opencode '$REPO/bin/ct'"
  [ "$status" -eq 0 ]
  grep -q -- 'new-session -d -s opencode-agent-alpha ' "$TMUX_STUB_LOG"
  [[ "$output" != *"already running"* ]]
}

@test "reattaching an opencode session prints how to reach its server" {
  echo "opencode-agent-alpha" > "$TMUX_STUB_SESSIONS"
  export TMUX_STUB_WS="$HOME/dev/agent-alpha" TMUX_STUB_PORT=4123
  run bash -c "cd '$HOME/dev/agent-alpha' && CT_AGENT=opencode CT_OPENCODE_WEB='https://code.example/absproxy/{port}/' '$REPO/bin/ct'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"opencode attach http://127.0.0.1:4123"* ]]
  [[ "$output" == *"https://code.example/absproxy/4123/"* ]]
}

@test "record: a claude launch records claude" {
  ( cd "$HOME/dev/agent-alpha" && "$REPO/bin/ct" )
  [ "$(record agent-alpha)" = "claude" ]
}

@test "record: first opencode launch keeps a pre-existing claude agent" {
  mkts "$HOME/dev/agent-alpha" "aaaaaaaa-1111" 200     # claude ran here before records
  ( cd "$HOME/dev/agent-alpha" && CT_AGENT=opencode "$REPO/bin/ct" )
  record agent-alpha | grep -qx claude
  record agent-alpha | grep -qE '^opencode [0-9]+$'
}

@test "record: opencode in a workspace claude never ran records opencode only" {
  ( cd "$HOME/dev/agent-alpha" && CT_AGENT=opencode "$REPO/bin/ct" )
  ! record agent-alpha | grep -q claude
}

@test "CT_AGENT_FORGET drops one agent and launches nothing" {
  mkts "$HOME/dev/agent-alpha" "aaaaaaaa-1111" 200
  ( cd "$HOME/dev/agent-alpha" && CT_AGENT=opencode "$REPO/bin/ct" )
  : > "$TMUX_STUB_LOG"
  ( cd "$HOME/dev/agent-alpha" && CT_AGENT=opencode CT_AGENT_FORGET=1 "$REPO/bin/ct" )
  [ "$(record agent-alpha)" = "claude" ]
  ! grep -q new-session "$TMUX_STUB_LOG"
}

@test "CT_AGENT_FORGET for claude without a record leaves an empty record" {
  ( cd "$HOME/dev/agent-alpha" && CT_AGENT_FORGET=1 "$REPO/bin/ct" )
  [ -f "$HOME/.local/share/ct/agents/agent-alpha" ]
  [ -z "$(record agent-alpha)" ]
}
