#!/usr/bin/env bats
# ct-scratch-guard: rm inside a workspace .scratch/ is allowed, any other rm asks,
# commands without rm get no decision. Runs against a throwaway workspace root.

setup() {
  ROOT="$BATS_TEST_TMPDIR/dev"
  WS="$ROOT/ws1"
  mkdir -p "$WS/.scratch/sub" "$WS/repo"
  ln -s "$WS/repo" "$WS/.scratch/link"
  mkdir -p "$ROOT/ws2"; ln -s "$WS/repo" "$ROOT/ws2/.scratch"   # a symlinked .scratch
  GUARD="$BATS_TEST_DIRNAME/../bin/ct-scratch-guard"
}

decide() {  # decide <command> -> prints allow|ask|none
  local out
  out=$(perl -MJSON::PP -e 'print encode_json({tool_name=>"Bash",cwd=>$ARGV[1],tool_input=>{command=>$ARGV[0]}})' "$1" "$WS" \
        | "$GUARD" "$ROOT")
  if [ -z "$out" ]; then echo none; return; fi
  perl -MJSON::PP -e 'print decode_json(<STDIN>)->{hookSpecificOutput}{permissionDecision}' <<<"$out"
}

expect() {  # expect <want> <command>
  run decide "$2"
  [ "$status" -eq 0 ] || { echo "guard failed: $output"; return 1; }
  [ "$output" = "$1" ] || { echo "want=$1 got=$output for: $2"; return 1; }
}

@test "rm of files inside .scratch is allowed" {
  expect allow "rm -f $WS/.scratch/a.txt"
  expect allow "rm $WS/.scratch/a.txt $WS/.scratch/b.txt"
  expect allow "rm -rf $WS/.scratch/sub"
  expect allow "rm -f '$WS/.scratch/a b.txt'"
  expect allow "direnv exec . rm -f $WS/.scratch/a.txt"
}

@test "redirections and trailing commands do not turn an allow into ask" {
  expect allow "rm -f $WS/.scratch/a.txt 2>/dev/null; ls"
  expect allow "rm -f $WS/.scratch/a.txt >/dev/null 2>&1"
}

@test "a relative path resolves against the session's directory" {
  expect allow "rm -f .scratch/a.txt"
}

@test "a symlink inside .scratch is removed, not followed" {
  expect allow "rm $WS/.scratch/link"
}

@test "anything else with rm asks" {
  expect ask "rm -rf $WS/.scratch"
  expect ask "rm -rf $WS/.scratch/"
  expect ask "rm -rf $WS/.scratch/../repo"
  expect ask "rm -rf $WS/.scratch/link/x"
  expect ask "rm $WS/repo/x"
  expect ask "rm -f $ROOT/ws2/.scratch/x"
  expect ask "rm -f /etc/hosts"
}

@test "doubt asks: variables, globs, substitutions, root, cd, parse errors" {
  expect ask 'rm -f "$S/a.txt"'
  expect ask "rm -f $WS/.scratch/*.txt"
  expect ask 'x=$(rm foo)'
  expect ask "sudo rm $WS/.scratch/a.txt"
  expect ask "cd /tmp && rm -f .scratch/a.txt"
  expect ask "rm -f \"$WS/.scratch/a.txt"
  expect ask "rm -f"
  expect ask "rm --no-preserve-root $WS/.scratch/a.txt"
}

@test "one rm outside .scratch makes the whole command ask" {
  expect ask "rm -f $WS/.scratch/a.txt && rm -rf /tmp/x"
}

@test "commands without rm get no decision" {
  expect none "grep -n rm /etc/hosts"
  expect none "echo hello"
  expect none "rmdir /tmp/x"
}

@test "garbage input or no root is silent, so the normal permission flow applies" {
  run bash -c "echo 'not json' | '$GUARD' '$ROOT'"
  [ "$status" -eq 0 ] && [ -z "$output" ]
  run bash -c "echo '{}' | '$GUARD'"
  [ "$status" -eq 0 ] && [ -z "$output" ]
}
