#!/usr/bin/env bats
# Tests for bin/ct-profile: the Claude Code half of
# a ct profile (docs/workspace-conventions.md, "Logins belong to a workspace or
# a profile").

setup() {
  REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  export PATH="$REPO/tests/stubs:$PATH"
  export HOME="$BATS_TEST_TMPDIR/home"
  unset WORKSPACE_ROOT CT_WORKSPACE_ROOT CT_GATEWAY_SETTINGS CT_PROFILE CT_FRESH XDG_CONFIG_HOME
  mkdir -p "$HOME/.claude/skills" "$HOME/dev/agent-alpha"
  ct_envrc agent-alpha ""
  echo '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"ct-scratch-guard"}]}]},"plansDirectory":".claude/plans"}' > "$HOME/.claude/settings.json"
  export TMUX_STUB_LOG="$BATS_TEST_TMPDIR/tmux.log" TMUX_STUB_SESSIONS="$BATS_TEST_TMPDIR/sessions" CT_DETACH=1
  export DIRENV_STUB_SOURCE=1   # load each .envrc as direnv does: transfer reads what it exports
  : > "$TMUX_STUB_LOG"; : > "$TMUX_STUB_SESSIONS"
  P="$HOME/dev/.profiles"
}

# ct's .envrc for a workspace under the root, on profile $2 (empty: the machine's ~/.claude).
ct_envrc() { # workspace profile
  mkdir -p "$HOME/dev/$1"
  cat > "$HOME/dev/$1/.envrc" <<ENVRC
ct_profile=$2
if [[ -n \$ct_profile ]]; then logins="\${PWD%/*}/.profiles/\$ct_profile"; else logins="\$PWD/.config"; fi
export CLOUDSDK_CONFIG="\$logins/gcloud"
export GOOGLE_APPLICATION_CREDENTIALS="\$CLOUDSDK_CONFIG/application_default_credentials.json"
if [[ -n \$ct_profile ]]; then export CLAUDE_CONFIG_DIR="\$logins/claude"; fi

source_env_if_exists .envrc.local
ENVRC
}
gateway() { # profile: a gateway profile, from the site's settings
  echo '{"env":{"ANTHROPIC_BASE_URL":"https://gw.example"}}' > "$BATS_TEST_TMPDIR/site.json"
  CT_GATEWAY_SETTINGS="$BATS_TEST_TMPDIR/site.json" "$REPO/bin/ct-profile" new "$1" gateway
}

@test "a subscription profile starts from the machine's settings and links its skills, with no login" {
  run "$REPO/bin/ct-profile" new acme
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
  "$REPO/bin/ct-profile" new acme
  grep -qxF "retire-shipped-rules-1" "$P/acme/claude/.ct-migrations"
  # The next install must not take the rule out of the profile's copy.
  run "$REPO/install.sh"
  [ "$status" -eq 0 ]
  jq -e '.permissions.ask == ["Bash(kubectl delete*)"]' "$P/acme/claude/settings.json"
  jq -e '.permissions.ask == ["Bash(kubectl delete*)"]' "$HOME/.claude/settings.json"
}

@test "a gateway profile merges the site's settings and marks itself gateway" {
  echo '{"apiKeyHelper":"cat ~/.key","env":{"ANTHROPIC_BASE_URL":"https://gw.example"}}' > "$BATS_TEST_TMPDIR/site.json"
  run env CT_GATEWAY_SETTINGS="$BATS_TEST_TMPDIR/site.json" "$REPO/bin/ct-profile" new work gateway
  [ "$status" -eq 0 ]
  jq -e '.env.ANTHROPIC_BASE_URL == "https://gw.example" and .ct_profile_kind == "gateway" and .plansDirectory == ".claude/plans"' "$P/work/claude/settings.json"
}

@test "a gateway profile without the site's settings is refused, and nothing is half-made" {
  run "$REPO/bin/ct-profile" new work gateway
  [ "$status" -eq 2 ]
  [[ "$output" == *"CT_GATEWAY_SETTINGS"* ]]
  [ ! -e "$P/work" ]
}

@test "an unknown kind of profile is refused" {
  run "$REPO/bin/ct-profile" new work bedrock
  [ "$status" -eq 2 ]
  [[ "$output" == *"subscription or gateway"* ]]
  [ ! -e "$P/work" ]
}

@test "an existing profile is left as it is" {
  "$REPO/bin/ct-profile" new acme
  echo '{"mine":1}' > "$P/acme/claude/settings.json"
  run "$REPO/bin/ct-profile" new acme
  [ "$status" -eq 0 ]
  jq -e '.mine == 1' "$P/acme/claude/settings.json"
}

@test "a bad profile name is refused" {
  run "$REPO/bin/ct-profile" new '../x'
  [ "$status" -eq 2 ]
  [ ! -e "$HOME/dev/.profiles/../x" ]
}

@test "transfer to a gateway copies the conversations as they are, keeps the originals, and repoints the workspace" {
  gateway acme
  key="$(printf '%s' "$HOME/dev/agent-alpha" | tr -c 'A-Za-z0-9' '-')"
  mkdir -p "$HOME/.claude/projects/$key/memory"; echo '{}' > "$HOME/.claude/projects/$key/s1.jsonl"; echo m > "$HOME/.claude/projects/$key/memory/MEMORY.md"
  run "$REPO/bin/ct-profile" transfer "$HOME/dev/agent-alpha" acme
  [ "$status" -eq 0 ]
  [ -f "$P/acme/claude/projects/$key/s1.jsonl" ]
  [ -f "$P/acme/claude/projects/$key/memory/MEMORY.md" ]
  [ -f "$HOME/.claude/projects/$key/s1.jsonl" ]
  grep -qx 'ct_profile=acme' "$HOME/dev/agent-alpha/.envrc"
  grep -q 'new-session -d -s claude-agent-alpha' "$TMUX_STUB_LOG"
  [[ "$output" == *"transferred from the machine's ~/.claude to acme and started"* ]]
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

@test "transfer copies a conversation's file history too" {
  gateway acme
  key="$(printf '%s' "$HOME/dev/agent-alpha" | tr -c 'A-Za-z0-9' '-')"
  mkdir -p "$HOME/.claude/projects/$key" "$HOME/.claude/file-history/s1"
  echo '{}' > "$HOME/.claude/projects/$key/s1.jsonl"; echo v1 > "$HOME/.claude/file-history/s1/f@v1"
  run "$REPO/bin/ct-profile" transfer "$HOME/dev/agent-alpha" acme
  [ "$status" -eq 0 ]
  [ -f "$P/acme/claude/file-history/s1/f@v1" ]
}

@test "transfer brings the conversation's uploaded files and points its paths at them" {
  gateway acme
  key="$(printf '%s' "$HOME/dev/agent-alpha" | tr -c 'A-Za-z0-9' '-')"
  mkdir -p "$HOME/.claude/projects/$key" "$HOME/.claude/uploads/s1"
  echo pdf > "$HOME/.claude/uploads/s1/a1-offert.pdf"
  echo '{"message":"read '"$HOME"'/.claude/uploads/s1/a1-offert.pdf"}' > "$HOME/.claude/projects/$key/s1.jsonl"
  run "$REPO/bin/ct-profile" transfer "$HOME/dev/agent-alpha" acme
  [ "$status" -eq 0 ]
  [ -f "$P/acme/claude/uploads/s1/a1-offert.pdf" ]
  grep -qF "$P/acme/claude/uploads/s1/a1-offert.pdf" "$P/acme/claude/projects/$key/s1.jsonl"
  grep -qF "$HOME/.claude/uploads/s1/a1-offert.pdf" "$HOME/.claude/projects/$key/s1.jsonl"
}

@test "a relinking transfer files the uploads under the new id, also when ~/.claude is a link" {
  # Moving between two profiles: ~/.claude links to the source, and the
  # transcript spells the source's real path.
  "$REPO/bin/ct-profile" new acme
  signed_in acme
  key="$(printf '%s' "$HOME/dev/agent-alpha" | tr -c 'A-Za-z0-9' '-')"
  old=11111111-1111-1111-1111-111111111111
  mv "$HOME/.claude" "$HOME/real-claude"; ln -s "$HOME/real-claude" "$HOME/.claude"
  linked_transcript "$HOME/.claude/projects/$key" "$old"
  mkdir -p "$HOME/.claude/uploads/$old"; echo png > "$HOME/.claude/uploads/$old/b2-image.png"
  echo '{"type":"user","sessionId":"'"$old"'","message":"see '"$HOME"'/real-claude/uploads/'"$old"'/b2-image.png"}' >> "$HOME/.claude/projects/$key/$old.jsonl"
  run "$REPO/bin/ct-profile" transfer "$HOME/dev/agent-alpha" acme
  [ "$status" -eq 0 ]
  dst="$P/acme/claude/projects/$key"
  new="$(basename "$(ls "$dst"/*.jsonl)" .jsonl)"
  [ -f "$P/acme/claude/uploads/$new/b2-image.png" ]
  grep -qF "$P/acme/claude/uploads/$new/b2-image.png" "$dst/$new.jsonl"
  run grep -c real-claude "$dst/$new.jsonl"
  [ "$output" = 0 ]
}

@test "a transfer to a gateway keeps the Remote Control rows: there is no account to relink to" {
  gateway acme
  key="$(printf '%s' "$HOME/dev/agent-alpha" | tr -c 'A-Za-z0-9' '-')"
  linked_transcript "$HOME/.claude/projects/$key" 11111111-1111-1111-1111-111111111111
  run "$REPO/bin/ct-profile" transfer "$HOME/dev/agent-alpha" acme
  [ "$status" -eq 0 ]
  grep -q bridge-session "$P/acme/claude/projects/$key/11111111-1111-1111-1111-111111111111.jsonl"
}

@test "a transfer to a signed-in profile relinks: each conversation under a new id, without its Remote Control rows" {
  "$REPO/bin/ct-profile" new acme
  signed_in acme
  key="$(printf '%s' "$HOME/dev/agent-alpha" | tr -c 'A-Za-z0-9' '-')"
  src="$HOME/.claude/projects/$key"; old=11111111-1111-1111-1111-111111111111
  linked_transcript "$src" "$old"
  mkdir -p "$src/$old/subagents" "$src/memory" "$HOME/.claude/file-history/$old"
  echo m > "$src/memory/MEMORY.md"; echo v1 > "$HOME/.claude/file-history/$old/f@v1"
  touch -d '2026-01-01 00:00' "$src/$old.jsonl"
  run "$REPO/bin/ct-profile" transfer "$HOME/dev/agent-alpha" acme
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

@test "a relinking transfer drops the old owner and names the profile's organization, keeping the chain" {
  "$REPO/bin/ct-profile" new acme
  signed_in acme
  key="$(printf '%s' "$HOME/dev/agent-alpha" | tr -c 'A-Za-z0-9' '-')"
  owned_transcript "$HOME/.claude/projects/$key" 11111111-1111-1111-1111-111111111111
  run "$REPO/bin/ct-profile" transfer "$HOME/dev/agent-alpha" acme
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

@test "a relinking transfer keeps only the last of the rows Claude Code rewrites every turn" {
  "$REPO/bin/ct-profile" new acme
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
  run "$REPO/bin/ct-profile" transfer "$HOME/dev/agent-alpha" acme
  [ "$status" -eq 0 ]
  f="$(ls "$P/acme/claude/projects/$key"/*.jsonl)"
  jq -e -s '(map(select(.type == "user")) | length == 3)
    and (map(select(.type == "custom-title")) | length == 1)
    and (map(select(.type == "permission-mode")) | length == 1 and .[0].permissionMode == "mode-3")
    and (map(select(.type == "last-prompt")) | length == 1 and .[0].lastPrompt == "turn 3")
    and (.[-1].type == "last-prompt")' "$f"
}

@test "a relinking transfer warns when a transcript is still too long for Remote Control's scan" {
  "$REPO/bin/ct-profile" new acme
  signed_in acme
  key="$(printf '%s' "$HOME/dev/agent-alpha" | tr -c 'A-Za-z0-9' '-')"
  d="$HOME/.claude/projects/$key"; id=11111111-1111-1111-1111-111111111111
  mkdir -p "$d"
  yes '{"type":"user","message":"x","sessionId":"'"$id"'"}' | head -100001 > "$d/$id.jsonl"
  run "$REPO/bin/ct-profile" transfer "$HOME/dev/agent-alpha" acme
  [ "$status" -eq 0 ]
  [[ "$output" == *"without its history"* ]]
}

@test "a transfer from another profile brings its uploads, relinked" {
  "$REPO/bin/ct-profile" new old
  "$REPO/bin/ct-profile" new acme
  signed_in acme
  key="$(printf '%s' "$HOME/dev/agent-alpha" | tr -c 'A-Za-z0-9' '-')"
  id=11111111-1111-1111-1111-111111111111
  ct_envrc agent-alpha old
  owned_transcript "$P/old/claude/projects/$key" "$id"
  mkdir -p "$P/old/claude/uploads/$id"; echo pdf > "$P/old/claude/uploads/$id/c3-avtal.pdf"
  echo '{"type":"user","sessionId":"'"$id"'","message":"read '"$P"'/old/claude/uploads/'"$id"'/c3-avtal.pdf"}' >> "$P/old/claude/projects/$key/$id.jsonl"
  run "$REPO/bin/ct-profile" transfer "$HOME/dev/agent-alpha" acme
  [ "$status" -eq 0 ]
  dst="$P/acme/claude/projects/$key"
  new="$(basename "$(ls "$dst"/*.jsonl)" .jsonl)"
  [ -f "$P/acme/claude/uploads/$new/c3-avtal.pdf" ]
  grep -qF "$P/acme/claude/uploads/$new/c3-avtal.pdf" "$dst/$new.jsonl"
  run grep -c -e "$P/old/" -e "$OLD_ORG" "$dst/$new.jsonl"
  [ "$output" = 0 ]
  [ -f "$P/old/claude/projects/$key/$id.jsonl" ]
}

@test "transfer takes a workspace by its bare name, under the root" {
  gateway acme
  key="$(printf '%s' "$HOME/dev/agent-alpha" | tr -c 'A-Za-z0-9' '-')"
  mkdir -p "$HOME/.claude/projects/$key"; echo '{"type":"user"}' > "$HOME/.claude/projects/$key/s1.jsonl"
  cd "$BATS_TEST_TMPDIR"
  run "$REPO/bin/ct-profile" transfer agent-alpha acme
  [ "$status" -eq 0 ]
  [ -f "$P/acme/claude/projects/$key/s1.jsonl" ]
}

@test "ct-profile --help prints its commands" {
  for flag in --help -h help; do
    run "$REPO/bin/ct-profile" "$flag"
    [ "$status" -eq 0 ]
    [[ $output == *"ct-profile new <name>"* && $output == *"ct-profile transfer <workspace> <name>"* ]]
    [[ $output != *"set -euo"* ]]
  done
}

# A workspace that lives in profile $2, with ct's .envrc and one conversation there.
ws_in_profile() { # workspace profile
  local d="$HOME/dev/$1" key
  ct_envrc "$1" "$2"
  key="$(printf '%s' "$d" | tr -c 'A-Za-z0-9' '-')"
  linked_transcript "$P/$2/claude/projects/$key" 22222222-2222-2222-2222-222222222222
  echo "$key"
}
envrc_env() { (cd "$HOME/dev/$1" && DIRENV_STUB_SOURCE=1 direnv exec . sh -c 'echo "$CLAUDE_CONFIG_DIR|$CLOUDSDK_CONFIG|$GOOGLE_APPLICATION_CREDENTIALS"'); }

@test "transfer moves the agent onto the profile's Claude login, and pins its other logins where they were" {
  export DIRENV_STUB_SOURCE=1
  "$REPO/bin/ct-profile" new old; signed_in old
  "$REPO/bin/ct-profile" new new; signed_in new
  key="$(ws_in_profile work old)"
  echo claude-work >> "$TMUX_STUB_SESSIONS"
  run "$REPO/bin/ct-profile" transfer work new
  [ "$status" -eq 0 ]
  grep -qx 'ct_profile=new' "$HOME/dev/work/.envrc"
  [ "$(envrc_env work)" = "$P/new/claude|$P/old/gcloud|$P/old/gcloud/application_default_credentials.json" ]
  [ "$(grep -c '^# >>> ct-profile transfer' "$HOME/dev/work/.envrc")" = 1 ]
  ls "$P/new/claude/projects/$key/"*.jsonl
  jq -e '.projects["'"$HOME/dev/work"'"].hasTrustDialogAccepted and .hasCompletedOnboarding' "$P/new/claude/.claude.json"
  grep -q 'kill-session -t =claude-work' "$TMUX_STUB_LOG"
  grep -q 'new-session -d -s claude-work' "$TMUX_STUB_LOG"
  [ ! -e "$HOME/.ct-noautostart" ]
  ls "$HOME/dev/.profiles/.transfer-backups/work.envrc."*
}

@test "transferring back replaces its block and sets the target's earlier copy aside" {
  export DIRENV_STUB_SOURCE=1
  "$REPO/bin/ct-profile" new old; signed_in old
  "$REPO/bin/ct-profile" new new; signed_in new
  key="$(ws_in_profile work old)"
  "$REPO/bin/ct-profile" transfer work new
  run "$REPO/bin/ct-profile" transfer work old
  [ "$status" -eq 0 ]
  grep -qx 'ct_profile=old' "$HOME/dev/work/.envrc"
  [ "$(envrc_env work)" = "$P/old/claude|$P/old/gcloud|$P/old/gcloud/application_default_credentials.json" ]
  ! grep -q '^export' <(sed -n '/^# >>> ct-profile transfer/,/^# <<< ct-profile transfer/p' "$HOME/dev/work/.envrc")
  [ "$(grep -c '^# >>> ct-profile transfer' "$HOME/dev/work/.envrc")" = 1 ]
  ls -d "$P/old/claude/projects/$key.superseded-"*
  [ "$(ls "$P/old/claude/projects/$key/"*.jsonl | wc -l)" = 1 ]
}

@test "transfer leaves an agent that is mid-turn alone, and says to try again" {
  "$REPO/bin/ct-profile" new old; signed_in old
  "$REPO/bin/ct-profile" new new; signed_in new
  ws_in_profile work old >/dev/null
  echo claude-work >> "$TMUX_STUB_SESSIONS"
  export TMUX_STUB_SCREENS="$BATS_TEST_TMPDIR/screens"; mkdir -p "$TMUX_STUB_SCREENS"
  printf '✻ Working… (3s · esc to interrupt)\n' > "$TMUX_STUB_SCREENS/claude-work"
  run "$REPO/bin/ct-profile" transfer work new
  [ "$status" -eq 3 ]
  grep -qx 'ct_profile=old' "$HOME/dev/work/.envrc"
  ! grep -q kill-session "$TMUX_STUB_LOG"
}

@test "transfer to a subscription profile that is not signed in is refused before the agent is stopped" {
  "$REPO/bin/ct-profile" new old; signed_in old
  "$REPO/bin/ct-profile" new new
  ws_in_profile work old >/dev/null
  echo claude-work >> "$TMUX_STUB_SESSIONS"
  run "$REPO/bin/ct-profile" transfer work new
  [ "$status" -eq 2 ]
  [[ $output == *"new is not signed in"* ]]
  ! grep -q kill-session "$TMUX_STUB_LOG"
  grep -qx 'ct_profile=old' "$HOME/dev/work/.envrc"
}

@test "transfer from the machine's ~/.claude keeps the workspace's own gcloud login, and relinks to the profile" {
  export DIRENV_STUB_SOURCE=1
  "$REPO/bin/ct-profile" new acme; signed_in acme
  key="$(printf '%s' "$HOME/dev/agent-alpha" | tr -c 'A-Za-z0-9' '-')"
  owned_transcript "$HOME/.claude/projects/$key" 11111111-1111-1111-1111-111111111111
  echo '{"projects":{"'"$HOME/dev/agent-alpha"'":{"allowedTools":["x"]}}}' > "$HOME/.claude.json"
  echo claude-agent-alpha >> "$TMUX_STUB_SESSIONS"
  run "$REPO/bin/ct-profile" transfer agent-alpha acme
  [ "$status" -eq 0 ]
  [[ $output == *"transferred from the machine's ~/.claude to acme and started"* ]]
  [ "$(envrc_env agent-alpha)" = "$P/acme/claude|$HOME/dev/agent-alpha/.config/gcloud|$HOME/dev/agent-alpha/.config/gcloud/application_default_credentials.json" ]
  grep -q '^# >>> ct-profile transfer: Claude on acme since .*, from the machine.s ~/.claude' "$HOME/dev/agent-alpha/.envrc"
  # the trust the folder had under the machine's login comes along
  jq -e '.projects["'"$HOME/dev/agent-alpha"'"] | .allowedTools == ["x"] and .hasTrustDialogAccepted' "$P/acme/claude/.claude.json"
  f="$(ls "$P/acme/claude/projects/$key"/*.jsonl)"
  ! grep -q "$OLD_ORG" "$f"
  grep -q 'kill-session -t =claude-agent-alpha' "$TMUX_STUB_LOG"
}

@test "a workspace whose .envrc has no ct_profile= line is refused, and nothing moves" {
  "$REPO/bin/ct-profile" new acme; signed_in acme
  echo 'export FOO=1' > "$HOME/dev/agent-alpha/.envrc"
  echo claude-agent-alpha >> "$TMUX_STUB_SESSIONS"
  run "$REPO/bin/ct-profile" transfer agent-alpha acme
  [ "$status" -eq 2 ]
  [[ $output == *"has no ct_profile= line"* ]]
  ! grep -q kill-session "$TMUX_STUB_LOG"
}

@test "an older .envrc without the Claude line gets it in the transfer's block, so Claude really moves" {
  "$REPO/bin/ct-profile" new acme; signed_in acme
  cat > "$HOME/dev/agent-alpha/.envrc" <<'ENVRC'
ct_profile=
if [[ -n $ct_profile ]]; then logins="${PWD%/*}/.profiles/$ct_profile"; else logins="$PWD/.config"; fi
export CLOUDSDK_CONFIG="$logins/gcloud"
ENVRC
  run "$REPO/bin/ct-profile" transfer agent-alpha acme
  [ "$status" -eq 0 ]
  grep -qx "export CLAUDE_CONFIG_DIR=\"$P/acme/claude\"" "$HOME/dev/agent-alpha/.envrc"
  [ "$(cd "$HOME/dev/agent-alpha" && direnv exec . sh -c 'echo "$CLAUDE_CONFIG_DIR|$CLOUDSDK_CONFIG"')" = "$P/acme/claude|$HOME/dev/agent-alpha/.config/gcloud" ]
}

@test "back on a gateway it was on before, a conversation's newer files are merged in, not skipped" {
  gateway gw1; gateway gw2
  key="$(printf '%s' "$HOME/dev/agent-alpha" | tr -c 'A-Za-z0-9' '-')"; id=s1
  mkdir -p "$HOME/.claude/projects/$key" "$HOME/.claude/uploads/$id"
  echo one > "$HOME/.claude/uploads/$id/a-one.pdf"
  echo '{"type":"user","sessionId":"s1"}' > "$HOME/.claude/projects/$key/$id.jsonl"
  "$REPO/bin/ct-profile" transfer agent-alpha gw1
  "$REPO/bin/ct-profile" transfer agent-alpha gw2
  echo two > "$P/gw2/claude/uploads/$id/b-two.pdf"            # attached while on gw2
  run "$REPO/bin/ct-profile" transfer agent-alpha gw1
  [ "$status" -eq 0 ]
  [ -f "$P/gw1/claude/uploads/$id/a-one.pdf" ]
  [ -f "$P/gw1/claude/uploads/$id/b-two.pdf" ]
}

@test "a relinking transfer between two different login addresses says whose account the history moves to" {
  "$REPO/bin/ct-profile" new acme
  echo '{"oauthAccount":{"accountUuid":"acct-new","organizationUuid":"'"$NEW_ORG"'","emailAddress":"b@example.org"}}' > "$P/acme/claude/.claude.json"
  echo '{"oauthAccount":{"emailAddress":"a@example.com"}}' > "$HOME/.claude.json"
  run "$REPO/bin/ct-profile" transfer agent-alpha acme
  [ "$status" -eq 0 ]
  [[ $output == *"history moves from a@example.com's account to b@example.org's"* ]]
}
