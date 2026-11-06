#!/usr/bin/env bats
# ct-scratch-guard: a command that is nothing but rm inside a workspace .scratch/ is allowed.
# Every other command gets no decision: the guard never asks (it did until 0.12, and raised 210
# prompts in ten days on one machine, one of them refused). The allow is for the whole Bash
# call, so anything beside the rm takes it away. Runs against a throwaway workspace root.

setup() {
  ROOT="$BATS_TEST_TMPDIR/dev"
  WS="$ROOT/ws1"
  mkdir -p "$WS/.scratch/sub" "$WS/repo"
  ln -s "$WS/repo" "$WS/.scratch/link"
  mkdir -p "$ROOT/ws2"; ln -s "$WS/repo" "$ROOT/ws2/.scratch"   # a symlinked .scratch
  GUARD="$BATS_TEST_DIRNAME/../bin/ct-scratch-guard"
}

decide() {  # decide <command> -> prints allow or none (or whatever else it said)
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

@test "output sent to /dev/null, and several rm in one command, keep the allow" {
  expect allow "rm -f $WS/.scratch/a.txt 2>/dev/null"
  expect allow "rm -f $WS/.scratch/a.txt >/dev/null 2>&1"
  expect allow "rm -f $WS/.scratch/a.txt 2> /dev/null;"
  expect allow "rm -f $WS/.scratch/a.txt; rm -rf $WS/.scratch/sub"
  expect allow "rm -f $WS/.scratch/a.txt && rm -f $WS/.scratch/b.txt 2>/dev/null"
  expect allow "rm -f -- $WS/.scratch/-odd-name"
  expect allow "command rm -f $WS/.scratch/a.txt"
}

# A hook's allow is for the entire Bash call. The guard used to judge the rm and skip every
# other segment, so each of these came back "allow" (review of 0.12, before release).
@test "anything beside the rm takes the allow away, because the allow would cover it too" {
  ok="rm -f $WS/.scratch/a.txt"
  expect none "$ok && git push --force origin main"
  expect none "$ok; kubectl delete namespace prod"
  expect none "$ok; ls"
  expect none "ls; $ok"
  expect none "$ok; if true; then rm -rf $WS/repo; fi"
  expect none "$ok; for f in 1; do rm -rf $WS/repo; done"
  expect none "$ok; FOO=1 rm -rf $WS/repo"
  expect none "$ok; bash -c 'rm -rf $WS/repo'"
  expect none "$ok; timeout 5 rm -rf $WS/repo"
  expect none "$ok; env -i rm -rf $WS/repo"
  expect none "$ok; nice -n 5 rm -rf $WS/repo"
  expect none "$ok; time -p rm -rf $WS/repo"
  expect none "$ok; exec rm -rf $WS/repo"
  expect none "$ok; ! rm -rf $WS/repo"
  expect none "$ok; direnv exec . sudo rm -rf $WS/repo"
  expect none "$ok | tee $WS/repo/x"
  expect none "$ok &"
  expect none "$ok & rm -rf $WS/repo"
}

@test "a redirection to a file, and a path that is only digits, are not waved through" {
  expect none "rm -f $WS/.scratch/a.txt >$WS/repo/x"
  expect none "rm -f $WS/.scratch/a.txt > $WS/repo/x"
  expect none "rm -f $WS/.scratch/a.txt 2>$WS/repo/x"
  expect none "rm -rf $WS/.scratch/a.txt 2024"
  expect none "rm -f $WS/.scratch/a.txt < /dev/null"
}

@test "a relative path resolves against the session's directory" {
  expect allow "rm -f .scratch/a.txt"
}

@test "a symlink inside .scratch is removed, not followed" {
  expect allow "rm $WS/.scratch/link"
}

@test "an rm that leaves .scratch gets no decision, so the normal permission flow decides" {
  expect none "rm -rf $WS/.scratch"
  expect none "rm -rf $WS/.scratch/"
  expect none "rm -rf $WS/.scratch/../repo"
  expect none "rm -rf $WS/.scratch/link/x"
  expect none "rm $WS/repo/x"
  expect none "rm -f $ROOT/ws2/.scratch/x"
  expect none "rm -f /etc/hosts"
}

@test "doubt is never allow: variables, globs, substitutions, root, cd, parse errors" {
  expect none 'rm -f "$S/a.txt"'
  expect none "rm -f $WS/.scratch/*.txt"
  expect none 'x=$(rm foo)'
  expect none "sudo rm $WS/.scratch/a.txt"
  expect none "cd /tmp && rm -f .scratch/a.txt"
  expect none "rm -f \"$WS/.scratch/a.txt"
  expect none "rm -f"
  expect none "rm --no-preserve-root $WS/.scratch/a.txt"
}

@test "one rm outside .scratch takes the allow from the whole command" {
  expect none "rm -f $WS/.scratch/a.txt && rm -rf /tmp/x"
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
