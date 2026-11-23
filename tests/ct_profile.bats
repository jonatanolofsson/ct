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

@test "a new profile takes the machine's migration record with its settings" {
  # The machine's file has been through the installer; its owner then put one retired rule back.
  export CT_HOME="$HOME/dev" CT_PREFIX="$HOME/bin"
  echo '{"permissions":{"ask":["Bash(kill*)","Bash(kubectl delete*)"]}}' > "$HOME/.claude/settings.json"
  "$REPO/install.sh" 2>/dev/null
  jq -e '.permissions | has("ask") | not' "$HOME/.claude/settings.json"
  jq '.permissions.ask = ["Bash(kubectl delete*)"]' "$HOME/.claude/settings.json" > "$BATS_TEST_TMPDIR/s" && cp "$BATS_TEST_TMPDIR/s" "$HOME/.claude/settings.json"
  "$REPO/bin/ct-profile" claude acme
  grep -qxF "retire-shipped-rules-1" "$P/acme/claude/.ct-migrations"
  # The next install must not take the rule out of the profile's copy.
  run "$REPO/install.sh"
  [ "$status" -eq 0 ]
  jq -e '.permissions.ask == ["Bash(kubectl delete*)"]' "$P/acme/claude/settings.json"
  jq -e '.permissions.ask == ["Bash(kubectl delete*)"]' "$HOME/.claude/settings.json"
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

linked_transcript() { # dir id: a conversation once linked to Remote Control, and vetoed
  mkdir -p "$1"
  {
    echo '{"type":"user","sessionId":"'"$2"'","message":"hi"}'
    echo '{"type":"bridge-session","sessionId":"'"$2"'","bridgeSessionId":"cse_old","ownerAccountUuid":"a1"}'
    echo '{"type":"history-suppression","sessionId":"'"$2"'","cause":"restored_owner_mismatch"}'
    echo '{"type":"custom-title","customTitle":"agent-alpha","sessionId":"'"$2"'"}'
  } > "$1/$2.jsonl"
}

OLD_ORG=0a0a0a0a-0000-0000-0000-000000000000
NEW_ORG=0b0b0b0b-0000-0000-0000-000000000000
signed_in() { # profile: a claude.ai login in the profile's state, as `claude auth login` leaves it
  echo '{"oauthAccount":{"accountUuid":"acct-new","organizationUuid":"'"$NEW_ORG"'"}}' > "$P/$1/claude/.claude.json"
}
owned_transcript() { # dir id: a conversation that also names its old account and organization
  linked_transcript "$1" "$2"
  {
    echo '{"type":"session-owner","accountUuid":"acct-old","organizationUuid":"'"$OLD_ORG"'","sessionId":"'"$2"'"}'
    echo '{"parentUuid":"u1","attachment":{"type":"credential_org","organizationUuid":"'"$OLD_ORG"'"},"type":"attachment","uuid":"u2","sessionId":"'"$2"'"}'
    echo '{"type":"assistant","uuid":"u3","parentUuid":"u2","sessionId":"'"$2"'","message":"rows like {\"type\":\"session-owner\"} carry the account"}'
    echo '{"parentUuid":null,"logicalParentUuid":"u3","type":"system","subtype":"compact_boundary","content":"Conversation compacted","compactMetadata":{"trigger":"auto","preCompactOrganizations":["'"$OLD_ORG"'"]},"uuid":"u4","sessionId":"'"$2"'"}'
  } >> "$1/$2.jsonl"
  mkdir -p "$1/$2/subagents"
  echo '{"parentUuid":null,"isSidechain":true,"agentId":"a1","attachment":{"type":"credential_org","organizationUuid":"'"$OLD_ORG"'"},"type":"attachment","uuid":"s1","sessionId":"'"$2"'"}' \
    > "$1/$2/subagents/agent-a1.jsonl"
}

@test "move copies a conversation's file history too" {
  "$REPO/bin/ct-profile" claude acme
  key="$(printf '%s' "$HOME/dev/agent-alpha" | tr -c 'A-Za-z0-9' '-')"
  mkdir -p "$HOME/.claude/projects/$key" "$HOME/.claude/file-history/s1"
  echo '{}' > "$HOME/.claude/projects/$key/s1.jsonl"; echo v1 > "$HOME/.claude/file-history/s1/f@v1"
  run "$REPO/bin/ct-profile" move "$HOME/dev/agent-alpha" acme
  [ "$status" -eq 0 ]
  [ -f "$P/acme/claude/file-history/s1/f@v1" ]
}

@test "move brings the conversation's uploaded files and points its paths at them" {
  "$REPO/bin/ct-profile" claude acme
  key="$(printf '%s' "$HOME/dev/agent-alpha" | tr -c 'A-Za-z0-9' '-')"
  mkdir -p "$HOME/.claude/projects/$key" "$HOME/.claude/uploads/s1"
  echo pdf > "$HOME/.claude/uploads/s1/a1-offert.pdf"
  echo '{"message":"read '"$HOME"'/.claude/uploads/s1/a1-offert.pdf"}' > "$HOME/.claude/projects/$key/s1.jsonl"
  run "$REPO/bin/ct-profile" move "$HOME/dev/agent-alpha" acme
  [ "$status" -eq 0 ]
  [ -f "$P/acme/claude/uploads/s1/a1-offert.pdf" ]
  grep -qF "$P/acme/claude/uploads/s1/a1-offert.pdf" "$P/acme/claude/projects/$key/s1.jsonl"
  grep -qF "$HOME/.claude/uploads/s1/a1-offert.pdf" "$HOME/.claude/projects/$key/s1.jsonl"
}

@test "move --own-accounts files the uploads under the new id, also when ~/.claude is a link" {
  # Moving between two profiles: ~/.claude links to the source, and the
  # transcript spells the source's real path.
  "$REPO/bin/ct-profile" claude acme
  signed_in acme
  key="$(printf '%s' "$HOME/dev/agent-alpha" | tr -c 'A-Za-z0-9' '-')"
  old=11111111-1111-1111-1111-111111111111
  mv "$HOME/.claude" "$HOME/real-claude"; ln -s "$HOME/real-claude" "$HOME/.claude"
  linked_transcript "$HOME/.claude/projects/$key" "$old"
  mkdir -p "$HOME/.claude/uploads/$old"; echo png > "$HOME/.claude/uploads/$old/b2-image.png"
  echo '{"type":"user","sessionId":"'"$old"'","message":"see '"$HOME"'/real-claude/uploads/'"$old"'/b2-image.png"}' >> "$HOME/.claude/projects/$key/$old.jsonl"
  run "$REPO/bin/ct-profile" move "$HOME/dev/agent-alpha" acme --own-accounts
  [ "$status" -eq 0 ]
  dst="$P/acme/claude/projects/$key"
  new="$(basename "$(ls "$dst"/*.jsonl)" .jsonl)"
  [ -f "$P/acme/claude/uploads/$new/b2-image.png" ]
  grep -qF "$P/acme/claude/uploads/$new/b2-image.png" "$dst/$new.jsonl"
  run grep -c real-claude "$dst/$new.jsonl"
  [ "$output" = 0 ]
}

@test "move refuses while the workspace's agent is running, and copies nothing" {
  "$REPO/bin/ct-profile" claude acme
  key="$(printf '%s' "$HOME/dev/agent-alpha" | tr -c 'A-Za-z0-9' '-')"
  mkdir -p "$HOME/.claude/projects/$key"; echo '{}' > "$HOME/.claude/projects/$key/s1.jsonl"
  echo claude-agent-alpha > "$TMUX_STUB_SESSIONS"
  run "$REPO/bin/ct-profile" move "$HOME/dev/agent-alpha" acme
  [ "$status" -eq 2 ]
  [[ "$output" == *"is running"* ]]
  [ ! -e "$P/acme/claude/projects/$key" ]
}

@test "a plain move keeps the Remote Control rows and says what that means" {
  "$REPO/bin/ct-profile" claude acme
  key="$(printf '%s' "$HOME/dev/agent-alpha" | tr -c 'A-Za-z0-9' '-')"
  linked_transcript "$HOME/.claude/projects/$key" 11111111-1111-1111-1111-111111111111
  run "$REPO/bin/ct-profile" move "$HOME/dev/agent-alpha" acme
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 of them were linked to Remote Control"* ]]
  grep -q bridge-session "$P/acme/claude/projects/$key/11111111-1111-1111-1111-111111111111.jsonl"
}

@test "move --own-accounts copies each conversation under a new id without its Remote Control rows" {
  "$REPO/bin/ct-profile" claude acme
  signed_in acme
  key="$(printf '%s' "$HOME/dev/agent-alpha" | tr -c 'A-Za-z0-9' '-')"
  src="$HOME/.claude/projects/$key"; old=11111111-1111-1111-1111-111111111111
  linked_transcript "$src" "$old"
  mkdir -p "$src/$old/subagents" "$src/memory" "$HOME/.claude/file-history/$old"
  echo m > "$src/memory/MEMORY.md"; echo v1 > "$HOME/.claude/file-history/$old/f@v1"
  touch -d '2026-01-01 00:00' "$src/$old.jsonl"
  run "$REPO/bin/ct-profile" move "$HOME/dev/agent-alpha" acme --own-accounts
  [ "$status" -eq 0 ]
  dst="$P/acme/claude/projects/$key"
  [ ! -e "$dst/$old.jsonl" ]
  new="$(basename "$(ls "$dst"/*.jsonl)" .jsonl)"
  [[ $new =~ ^[0-9a-f-]{36}$ ]]
  run grep -c -e bridge-session -e history-suppression -e "$old" "$dst/$new.jsonl"
  [ "$output" = 0 ]
  jq -e -s 'length == 2 and all(.sessionId == "'"$new"'") and .[1].customTitle == "agent-alpha"' "$dst/$new.jsonl"
  [ "$(stat -c %Y "$dst/$new.jsonl")" = "$(stat -c %Y "$src/$old.jsonl")" ]
  [ -d "$dst/$new/subagents" ]
  [ -f "$dst/memory/MEMORY.md" ]
  [ -f "$P/acme/claude/file-history/$new/f@v1" ]
  grep -q bridge-session "$src/$old.jsonl"
}

@test "move --own-accounts will not run twice into the same profile" {
  "$REPO/bin/ct-profile" claude acme
  signed_in acme
  key="$(printf '%s' "$HOME/dev/agent-alpha" | tr -c 'A-Za-z0-9' '-')"
  linked_transcript "$HOME/.claude/projects/$key" 11111111-1111-1111-1111-111111111111
  "$REPO/bin/ct-profile" move "$HOME/dev/agent-alpha" acme --own-accounts
  run "$REPO/bin/ct-profile" move "$HOME/dev/agent-alpha" acme --own-accounts
  [ "$status" -eq 2 ]
  [[ "$output" == *"would duplicate"* ]]
  [ "$(ls "$P/acme/claude/projects/$key"/*.jsonl | wc -l)" -eq 1 ]
}

@test "move --own-accounts drops the old owner and names the profile's organization, keeping the chain" {
  "$REPO/bin/ct-profile" claude acme
  signed_in acme
  key="$(printf '%s' "$HOME/dev/agent-alpha" | tr -c 'A-Za-z0-9' '-')"
  owned_transcript "$HOME/.claude/projects/$key" 11111111-1111-1111-1111-111111111111
  run "$REPO/bin/ct-profile" move "$HOME/dev/agent-alpha" acme --own-accounts
  [ "$status" -eq 0 ]
  f="$(ls "$P/acme/claude/projects/$key"/*.jsonl)"
  run grep -c -e '^{"type":"session-owner"' -e "$OLD_ORG" "$f"
  [ "$output" = 0 ]
  jq -e -s 'map(select(.attachment.type == "credential_org")) | length == 1 and .[0].organizationUuid == null and .[0].attachment.organizationUuid == "'"$NEW_ORG"'" and .[0].uuid == "u2"' "$f"
  # a turn that only quotes a row type stays, or the chain from u2 to u3 breaks
  jq -e -s 'any(.uuid == "u3" and .parentUuid == "u2")' "$f"
  # a compaction records the organizations it summarised; the old one there
  # opens the remote session without its history, as surely as an owner row
  jq -e -s 'any(.uuid == "u4" and .compactMetadata.preCompactOrganizations == ["'"$NEW_ORG"'"])' "$f"
  # the subagents are read too: their organization and their parent's id follow
  new="$(basename "$f" .jsonl)"
  s="$P/acme/claude/projects/$key/$new/subagents/agent-a1.jsonl"
  jq -e '.attachment.organizationUuid == "'"$NEW_ORG"'" and .sessionId == "'"$new"'"' "$s"
  grep -q "$OLD_ORG" "$HOME/.claude/projects/$key/11111111-1111-1111-1111-111111111111.jsonl"
  grep -q "$OLD_ORG" "$HOME/.claude/projects/$key/11111111-1111-1111-1111-111111111111/subagents/agent-a1.jsonl"
}

@test "move --own-accounts keeps only the last of the rows Claude Code rewrites every turn" {
  "$REPO/bin/ct-profile" claude acme
  signed_in acme
  key="$(printf '%s' "$HOME/dev/agent-alpha" | tr -c 'A-Za-z0-9' '-')"
  d="$HOME/.claude/projects/$key"; id=11111111-1111-1111-1111-111111111111
  mkdir -p "$d"
  {
    for i in 1 2 3; do
      echo '{"type":"user","uuid":"m'"$i"'","sessionId":"'"$id"'","message":"turn '"$i"'"}'
      echo '{"type":"custom-title","customTitle":"agent-alpha","sessionId":"'"$id"'"}'
      echo '{"type":"permission-mode","permissionMode":"mode-'"$i"'","sessionId":"'"$id"'"}'
      echo '{"type":"last-prompt","lastPrompt":"turn '"$i"'","sessionId":"'"$id"'"}'
    done
  } > "$d/$id.jsonl"
  run "$REPO/bin/ct-profile" move "$HOME/dev/agent-alpha" acme --own-accounts
  [ "$status" -eq 0 ]
  f="$(ls "$P/acme/claude/projects/$key"/*.jsonl)"
  jq -e -s '(map(select(.type == "user")) | length == 3)
    and (map(select(.type == "custom-title")) | length == 1)
    and (map(select(.type == "permission-mode")) | length == 1 and .[0].permissionMode == "mode-3")
    and (map(select(.type == "last-prompt")) | length == 1 and .[0].lastPrompt == "turn 3")
    and (.[-1].type == "last-prompt")' "$f"
}

@test "move --own-accounts warns when a transcript is still too long for Remote Control's scan" {
  "$REPO/bin/ct-profile" claude acme
  signed_in acme
  key="$(printf '%s' "$HOME/dev/agent-alpha" | tr -c 'A-Za-z0-9' '-')"
  d="$HOME/.claude/projects/$key"; id=11111111-1111-1111-1111-111111111111
  mkdir -p "$d"
  yes '{"type":"user","message":"x","sessionId":"'"$id"'"}' | head -100001 > "$d/$id.jsonl"
  run "$REPO/bin/ct-profile" move "$HOME/dev/agent-alpha" acme --own-accounts
  [ "$status" -eq 0 ]
  [[ "$output" == *"without its history"* ]]
}

@test "move --own-accounts refuses a profile that is not signed in, and copies nothing" {
  "$REPO/bin/ct-profile" claude acme
  key="$(printf '%s' "$HOME/dev/agent-alpha" | tr -c 'A-Za-z0-9' '-')"
  owned_transcript "$HOME/.claude/projects/$key" 11111111-1111-1111-1111-111111111111
  run "$REPO/bin/ct-profile" move "$HOME/dev/agent-alpha" acme --own-accounts
  [ "$status" -eq 2 ]
  [[ "$output" == *"signed in first"* ]]
  [ ! -e "$P/acme/claude/projects/$key" ]
}

@test "move --from copies from another profile, with its uploads" {
  "$REPO/bin/ct-profile" claude old
  "$REPO/bin/ct-profile" claude acme
  signed_in acme
  key="$(printf '%s' "$HOME/dev/agent-alpha" | tr -c 'A-Za-z0-9' '-')"
  id=11111111-1111-1111-1111-111111111111
  owned_transcript "$P/old/claude/projects/$key" "$id"
  mkdir -p "$P/old/claude/uploads/$id"; echo pdf > "$P/old/claude/uploads/$id/c3-avtal.pdf"
  echo '{"type":"user","sessionId":"'"$id"'","message":"read '"$P"'/old/claude/uploads/'"$id"'/c3-avtal.pdf"}' >> "$P/old/claude/projects/$key/$id.jsonl"
  run "$REPO/bin/ct-profile" move "$HOME/dev/agent-alpha" acme --own-accounts --from old
  [ "$status" -eq 0 ]
  dst="$P/acme/claude/projects/$key"
  new="$(basename "$(ls "$dst"/*.jsonl)" .jsonl)"
  [ -f "$P/acme/claude/uploads/$new/c3-avtal.pdf" ]
  grep -qF "$P/acme/claude/uploads/$new/c3-avtal.pdf" "$dst/$new.jsonl"
  run grep -c -e "$P/old/" -e "$OLD_ORG" "$dst/$new.jsonl"
  [ "$output" = 0 ]
  [ -f "$P/old/claude/projects/$key/$id.jsonl" ]
}

@test "move takes a workspace by its bare name, under the root" {
  "$REPO/bin/ct-profile" claude acme
  key="$(printf '%s' "$HOME/dev/agent-alpha" | tr -c 'A-Za-z0-9' '-')"
  mkdir -p "$HOME/.claude/projects/$key"; echo '{"type":"user"}' > "$HOME/.claude/projects/$key/s1.jsonl"
  cd "$BATS_TEST_TMPDIR"
  run "$REPO/bin/ct-profile" move agent-alpha acme
  [ "$status" -eq 0 ]
  [ -f "$P/acme/claude/projects/$key/s1.jsonl" ]
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

@test "ct-profile --help prints its commands, including move --from" {
  for flag in --help -h help; do
    run "$REPO/bin/ct-profile" "$flag"
    [ "$status" -eq 0 ]
    [[ $output == *"ct-profile claude <name>"* && $output == *"--from <profile>"* ]]
    [[ $output != *"set -euo"* ]]
  done
}

# A workspace that lives in profile $2, with ct's .envrc and one conversation there.
ws_in_profile() { # workspace profile
  local d="$HOME/dev/$1" key
  mkdir -p "$d"
  cat > "$d/.envrc" <<ENVRC
ct_profile=$2
if [[ -n \$ct_profile ]]; then logins="\${PWD%/*}/.profiles/\$ct_profile"; else logins="\$PWD/.config"; fi
export CLOUDSDK_CONFIG="\$logins/gcloud"
export GOOGLE_APPLICATION_CREDENTIALS="\$CLOUDSDK_CONFIG/application_default_credentials.json"
if [[ -n \$ct_profile ]]; then export CLAUDE_CONFIG_DIR="\$logins/claude"; fi

source_env_if_exists .envrc.local
ENVRC
  key="$(printf '%s' "$d" | tr -c 'A-Za-z0-9' '-')"
  linked_transcript "$P/$2/claude/projects/$key" 22222222-2222-2222-2222-222222222222
  echo "$key"
}
envrc_env() { (cd "$HOME/dev/$1" && DIRENV_STUB_SOURCE=1 direnv exec . sh -c 'echo "$CLAUDE_CONFIG_DIR|$CLOUDSDK_CONFIG|$GOOGLE_APPLICATION_CREDENTIALS"'); }

@test "switch moves the agent onto the profile's Claude login, and pins its other logins where they were" {
  export DIRENV_STUB_SOURCE=1
  "$REPO/bin/ct-profile" claude old; signed_in old
  "$REPO/bin/ct-profile" claude new; signed_in new
  key="$(ws_in_profile work old)"
  echo claude-work >> "$TMUX_STUB_SESSIONS"
  run "$REPO/bin/ct-profile" switch work new
  [ "$status" -eq 0 ]
  grep -qx 'ct_profile=new' "$HOME/dev/work/.envrc"
  [ "$(envrc_env work)" = "$P/new/claude|$P/old/gcloud|$P/old/gcloud/application_default_credentials.json" ]
  [ "$(grep -c '^# >>> ct-profile switch' "$HOME/dev/work/.envrc")" = 1 ]
  ls "$P/new/claude/projects/$key/"*.jsonl
  jq -e '.projects["'"$HOME/dev/work"'"].hasTrustDialogAccepted and .hasCompletedOnboarding' "$P/new/claude/.claude.json"
  grep -q 'kill-session -t =claude-work' "$TMUX_STUB_LOG"
  grep -q 'new-session -d -s claude-work' "$TMUX_STUB_LOG"
  [ ! -e "$HOME/.ct-noautostart" ]
  ls "$HOME/dev/.profiles/.switch-backups/work.envrc."*
}

@test "switch back replaces its block and sets the target's earlier copy aside" {
  export DIRENV_STUB_SOURCE=1
  "$REPO/bin/ct-profile" claude old; signed_in old
  "$REPO/bin/ct-profile" claude new; signed_in new
  key="$(ws_in_profile work old)"
  "$REPO/bin/ct-profile" switch work new
  run "$REPO/bin/ct-profile" switch work old
  [ "$status" -eq 0 ]
  grep -qx 'ct_profile=old' "$HOME/dev/work/.envrc"
  [ "$(envrc_env work)" = "$P/old/claude|$P/old/gcloud|$P/old/gcloud/application_default_credentials.json" ]
  ! grep -q '^export' <(sed -n '/^# >>> ct-profile switch/,/^# <<< ct-profile switch/p' "$HOME/dev/work/.envrc")
  [ "$(grep -c '^# >>> ct-profile switch' "$HOME/dev/work/.envrc")" = 1 ]
  ls -d "$P/old/claude/projects/$key.superseded-"*
  [ "$(ls "$P/old/claude/projects/$key/"*.jsonl | wc -l)" = 1 ]
}

@test "switch leaves an agent that is mid-turn alone, and says to try again" {
  "$REPO/bin/ct-profile" claude old; signed_in old
  "$REPO/bin/ct-profile" claude new; signed_in new
  ws_in_profile work old >/dev/null
  echo claude-work >> "$TMUX_STUB_SESSIONS"
  export TMUX_STUB_SCREENS="$BATS_TEST_TMPDIR/screens"; mkdir -p "$TMUX_STUB_SCREENS"
  printf '✻ Working… (3s · esc to interrupt)\n' > "$TMUX_STUB_SCREENS/claude-work"
  run "$REPO/bin/ct-profile" switch work new
  [ "$status" -eq 3 ]
  grep -qx 'ct_profile=old' "$HOME/dev/work/.envrc"
  ! grep -q kill-session "$TMUX_STUB_LOG"
}

@test "switch to a profile that is not signed in is refused before the agent is stopped" {
  "$REPO/bin/ct-profile" claude old; signed_in old
  "$REPO/bin/ct-profile" claude new
  ws_in_profile work old >/dev/null
  echo claude-work >> "$TMUX_STUB_SESSIONS"
  run "$REPO/bin/ct-profile" switch work new
  [ "$status" -eq 2 ]
  [[ $output == *"new is not signed in"* ]]
  ! grep -q kill-session "$TMUX_STUB_LOG"
  grep -qx 'ct_profile=old' "$HOME/dev/work/.envrc"
}
