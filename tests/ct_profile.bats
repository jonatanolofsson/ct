#!/usr/bin/env bats
# Tests for bin/ct-profile and ct's billing-name check: the Claude Code half of
# a ct profile (docs/workspace-conventions.md, "Logins belong to a workspace or
# a profile").

setup() {
  REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  export PATH="$REPO/tests/stubs:$PATH"
  export HOME="$BATS_TEST_TMPDIR/home"
  unset WORKSPACE_ROOT CT_WORKSPACE_ROOT CT_BEDROCK_SETTINGS CT_PROFILE CT_FRESH XDG_CONFIG_HOME
  mkdir -p "$HOME/.claude/skills" "$HOME/dev/agent-alpha" "$HOME/dev/agent-alpha-bedrock"
  echo '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"ct-scratch-guard"}]}]},"plansDirectory":".claude/plans"}' > "$HOME/.claude/settings.json"
  export TMUX_STUB_LOG="$BATS_TEST_TMPDIR/tmux.log" TMUX_STUB_SESSIONS="$BATS_TEST_TMPDIR/sessions" CT_DETACH=1
  : > "$TMUX_STUB_LOG"; : > "$TMUX_STUB_SESSIONS"
  P="$HOME/dev/.profiles"
}

@test "an account profile starts from the machine's settings and links its skills, with no login" {
  run "$REPO/bin/ct-profile" claude acme
  [ "$status" -eq 0 ]
  jq -e '.hooks.PreToolUse[0].hooks[0].command == "ct-scratch-guard" and .plansDirectory == ".claude/plans"' "$P/acme/claude/settings.json"
  [ -L "$P/acme/claude/skills" ]
  [ ! -e "$P/acme/claude/.credentials.json" ]
  [ "$(stat -c %a "$P/acme/claude/settings.json")" = 600 ]
}

@test "a bedrock profile merges the site's settings and marks itself bedrock" {
  echo '{"apiKeyHelper":"cat ~/.key","env":{"ANTHROPIC_BASE_URL":"https://gw.example"}}' > "$BATS_TEST_TMPDIR/site.json"
  run env CT_BEDROCK_SETTINGS="$BATS_TEST_TMPDIR/site.json" "$REPO/bin/ct-profile" claude work bedrock
  [ "$status" -eq 0 ]
  jq -e '.env.ANTHROPIC_BASE_URL == "https://gw.example" and .ct_profile_kind == "bedrock" and .plansDirectory == ".claude/plans"' "$P/work/claude/settings.json"
}

@test "a bedrock profile without the site's settings is refused, and nothing is half-made" {
  run "$REPO/bin/ct-profile" claude work bedrock
  [ "$status" -eq 2 ]
  [[ "$output" == *"CT_BEDROCK_SETTINGS"* ]]
  [ ! -e "$P/work" ]
}

@test "an existing profile is left as it is" {
  "$REPO/bin/ct-profile" claude acme
  echo '{"mine":1}' > "$P/acme/claude/settings.json"
  run "$REPO/bin/ct-profile" claude acme
  [ "$status" -eq 0 ]
  jq -e '.mine == 1' "$P/acme/claude/settings.json"
}

@test "a bad profile name is refused" {
  run "$REPO/bin/ct-profile" claude '../x'
  [ "$status" -eq 2 ]
  [ ! -e "$HOME/dev/.profiles/../x" ]
}

@test "move copies a workspace's conversations into the profile and keeps the originals" {
  "$REPO/bin/ct-profile" claude acme
  key="$(printf '%s' "$HOME/dev/agent-alpha" | tr -c 'A-Za-z0-9' '-')"
  mkdir -p "$HOME/.claude/projects/$key/memory"; echo '{}' > "$HOME/.claude/projects/$key/s1.jsonl"; echo m > "$HOME/.claude/projects/$key/memory/MEMORY.md"
  run "$REPO/bin/ct-profile" move "$HOME/dev/agent-alpha" acme
  [ "$status" -eq 0 ]
  [ -f "$P/acme/claude/projects/$key/s1.jsonl" ]
  [ -f "$P/acme/claude/projects/$key/memory/MEMORY.md" ]
  [ -f "$HOME/.claude/projects/$key/s1.jsonl" ]
}

@test "ct warns when a -bedrock workspace's Claude is not a bedrock profile, and the reverse" {
  run bash -c "cd '$HOME/dev/agent-alpha-bedrock' && '$REPO/bin/ct'"
  [[ "$output" == *"named -bedrock but its Claude"* ]]
  echo '{"env":{}}' > "$BATS_TEST_TMPDIR/site.json"
  CT_BEDROCK_SETTINGS="$BATS_TEST_TMPDIR/site.json" "$REPO/bin/ct-profile" claude work bedrock
  mkdir -p "$HOME/dev/agent-beta"
  : > "$TMUX_STUB_SESSIONS"
  run bash -c "cd '$HOME/dev/agent-beta' && CT_PROFILE=work '$REPO/bin/ct'"
  [[ "$output" == *"runs Claude on a bedrock profile but is not named -bedrock"* ]]
}

@test "a -bedrock workspace on a bedrock profile starts without a warning" {
  echo '{"env":{}}' > "$BATS_TEST_TMPDIR/site.json"
  CT_BEDROCK_SETTINGS="$BATS_TEST_TMPDIR/site.json" "$REPO/bin/ct-profile" claude work bedrock
  run bash -c "cd '$HOME/dev/agent-alpha-bedrock' && CT_PROFILE=work '$REPO/bin/ct'"
  [[ "$output" != *"WARNING"* ]]
}
