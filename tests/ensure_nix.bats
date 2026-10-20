#!/usr/bin/env bats
# Tests for bin/ensure-nix with a persistent /nix: what the installer put in /etc
# is kept under /nix and put back after a restart. /nix and /etc are temp dirs
# (ENSURE_NIX_ROOT / ENSURE_NIX_ETC); sudo runs the command unprivileged.

setup() {
  REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  STUBS="$BATS_TEST_TMPDIR/stubs"
  mkdir -p "$STUBS"
  printf '#!/bin/sh\nexit 0\n' > "$STUBS/pgrep"   # the daemon is already running
  chmod +x "$STUBS/pgrep"
  export PATH="$STUBS:$REPO/tests/stubs:$REPO/bin:$PATH"
  export SUDO_STUB_EXEC=1 CURL_STUB_LOG="$BATS_TEST_TMPDIR/curl.log"
  : > "$CURL_STUB_LOG"
  export ENSURE_NIX_ROOT="$BATS_TEST_TMPDIR/nix" ENSURE_NIX_ETC="$BATS_TEST_TMPDIR/etc"
  mkdir -p "$ENSURE_NIX_ROOT/var/nix/profiles/default/bin" "$ENSURE_NIX_ETC"
  printf '#!/bin/sh\necho "nix (Determinate Nix 3.23.3)"\n' \
    > "$ENSURE_NIX_ROOT/var/nix/profiles/default/bin/nix"
  chmod +x "$ENSURE_NIX_ROOT/var/nix/profiles/default/bin/nix"
  printf 'root:x:0:\n' > "$ENSURE_NIX_ETC/group"
  printf 'root:x:0:0:root:/root:/bin/sh\n' > "$ENSURE_NIX_ETC/passwd"
  printf 'root:*:1::::::\n' > "$ENSURE_NIX_ETC/shadow"
}

installed_etc() {   # /etc as the installer leaves it
  mkdir -p "$ENSURE_NIX_ETC/nix"
  echo 'extra-experimental-features = nix-command flakes' > "$ENSURE_NIX_ETC/nix/nix.conf"
  echo 'nixbld:x:30000:nixbld1,nixbld2' >> "$ENSURE_NIX_ETC/group"
  printf 'nixbld1:x:30001:30000:Nix build user 1:/var/empty:/sbin/nologin\nnixbld2:x:30002:30000:Nix build user 2:/var/empty:/sbin/nologin\n' \
    >> "$ENSURE_NIX_ETC/passwd"
  printf 'nixbld1:!:1::::::\nnixbld2:!:1::::::\n' >> "$ENSURE_NIX_ETC/shadow"
}

@test "keeps the installer's /etc state under /nix" {
  installed_etc
  run "$REPO/bin/ensure-nix"
  [ "$status" -eq 0 ]
  [[ "$output" == *"kept"* ]]
  grep -q flakes "$ENSURE_NIX_ROOT/.ensure-nix/etc-nix/nix.conf"
  grep -q '^nixbld:x:30000:' "$ENSURE_NIX_ROOT/.ensure-nix/group"
  [ "$(wc -l < "$ENSURE_NIX_ROOT/.ensure-nix/passwd")" -eq 2 ]
  [ "$(wc -l < "$ENSURE_NIX_ROOT/.ensure-nix/shadow")" -eq 2 ]
}

@test "after a restart (persistent /nix, fresh /etc) restores it without reinstalling" {
  installed_etc
  "$REPO/bin/ensure-nix" >/dev/null
  rm -r "$ENSURE_NIX_ETC"; mkdir -p "$ENSURE_NIX_ETC"     # the overlay is new
  printf 'root:x:0:\n' > "$ENSURE_NIX_ETC/group"
  printf 'root:x:0:0:root:/root:/bin/sh\n' > "$ENSURE_NIX_ETC/passwd"
  printf 'root:*:1::::::\n' > "$ENSURE_NIX_ETC/shadow"
  run "$REPO/bin/ensure-nix"
  [ "$status" -eq 0 ]
  [[ "$output" == *"restored"* ]]
  grep -q flakes "$ENSURE_NIX_ETC/nix/nix.conf"
  grep -q '^nixbld:x:30000:nixbld1,nixbld2$' "$ENSURE_NIX_ETC/group"
  grep -q '^nixbld2:x:30002:30000:' "$ENSURE_NIX_ETC/passwd"
  grep -q '^nixbld1:!:' "$ENSURE_NIX_ETC/shadow"
  grep -q '^root:' "$ENSURE_NIX_ETC/passwd"
  [ ! -s "$CURL_STUB_LOG" ]                                # no installer download
}

@test "idempotent: a second run adds no duplicate users" {
  installed_etc
  "$REPO/bin/ensure-nix" >/dev/null
  run "$REPO/bin/ensure-nix"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^nixbld:' "$ENSURE_NIX_ETC/group")" -eq 1 ]
  [ "$(grep -c '^nixbld1:' "$ENSURE_NIX_ETC/passwd")" -eq 1 ]
}

@test "never overwrites an /etc/nix that is already there" {
  installed_etc
  "$REPO/bin/ensure-nix" >/dev/null
  echo 'max-jobs = 2' > "$ENSURE_NIX_ETC/nix/nix.conf"
  run "$REPO/bin/ensure-nix"
  [ "$status" -eq 0 ]
  grep -q 'max-jobs = 2' "$ENSURE_NIX_ETC/nix/nix.conf"
}

@test "without nix and without a download, gives up loudly" {
  rm "$ENSURE_NIX_ROOT/var/nix/profiles/default/bin/nix"
  run env CURL_STUB_FAIL=1 "$REPO/bin/ensure-nix"
  [ "$status" -eq 1 ]
  [[ "$output" == *"nix still missing"* ]]
}
