#!/usr/bin/env bats
# install.sh must own exactly one marker block and never move it: another
# writer (a site layer) owns its own block, and alternating order made the
# file churn on every boot (found 2026-09-25 on the first real run).

setup() {
  REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  export HOME="$BATS_TEST_TMPDIR/home" CT_HOME="$BATS_TEST_TMPDIR/home/dev" CT_PREFIX="$BATS_TEST_TMPDIR/home/bin"
  mkdir -p "$HOME"
  MD="$CT_HOME/CLAUDE.md"
}

site_write() {  # the site-layer shape from docs/bootstrap-integration.md
  local b='<!-- BEGIN ct-site-managed -->' e='<!-- END ct-site-managed -->'
  if grep -qF "$b" "$MD"; then sed -i "\|^${b}\$|,\|^${e}\$|d" "$MD"; fi
  { echo "$b"; echo "site text"; echo "$e"; } >> "$MD"
}

order() { grep -oE 'BEGIN ct(-site)?-managed' "$MD" | tr '\n' ' '; }

@test "first run appends one ct block" {
  "$REPO/install.sh" 2>/dev/null
  [ "$(grep -c 'BEGIN ct-managed' "$MD")" -eq 1 ]
}

@test "re-run is byte-identical (idempotent)" {
  "$REPO/install.sh" 2>/dev/null; h1=$(sha256sum < "$MD")
  "$REPO/install.sh" 2>/dev/null; h2=$(sha256sum < "$MD")
  [ "$h1" = "$h2" ]
}

@test "block order is stable when install and a site writer alternate" {
  "$REPO/install.sh" 2>/dev/null; site_write
  first="$(order)"; h1=$(sha256sum < "$MD")
  "$REPO/install.sh" 2>/dev/null; site_write
  "$REPO/install.sh" 2>/dev/null
  [ "$(order)" = "$first" ]
  [ "$(sha256sum < "$MD")" = "$h1" ]
}

@test "hand edits outside the block survive and keep their position" {
  mkdir -p "$CT_HOME"; printf 'TOP\n' > "$MD"
  "$REPO/install.sh" 2>/dev/null
  printf 'BOTTOM\n' >> "$MD"
  "$REPO/install.sh" 2>/dev/null
  [ "$(head -1 "$MD")" = "TOP" ]
  [ "$(tail -1 "$MD")" = "BOTTOM" ]
}

@test "VERSION records ref and resolved commit" {
  "$REPO/install.sh" 2>/dev/null
  read -r ref commit _ < "$HOME/.local/share/ct/VERSION"
  [ -n "$ref" ]
  [[ "$commit" =~ ^[0-9a-f]{7,}(-dirty)?$ ]]
}

# Plans live in the workspace, never the shared ~/.claude/plans/ (two agents
# rewrote each other's plan file there, 2026-10-17/18).
@test "a fresh install seeds plansDirectory" {
  "$REPO/install.sh" 2>/dev/null
  grep -q '"plansDirectory": ".claude/plans"' "$HOME/.claude/settings.json"
}

@test "an existing settings.json gains plansDirectory, keeps its keys and mode" {
  mkdir -p "$HOME/.claude"
  printf '{"model": "x", "permissions": {"allow": ["Read"]}}\n' > "$HOME/.claude/settings.json"
  chmod 600 "$HOME/.claude/settings.json"
  "$REPO/install.sh" 2>/dev/null
  perl -MJSON::PP -e 'local $/; open F, shift; my $d = decode_json(<F>);
    exit !($d->{plansDirectory} eq ".claude/plans" && $d->{model} eq "x" && $d->{permissions}{allow}[0] eq "Read")' \
    "$HOME/.claude/settings.json"
  [ "$(stat -c %a "$HOME/.claude/settings.json")" = "600" ]
}

@test "a plansDirectory someone chose is left alone, and the file is not rewritten" {
  mkdir -p "$HOME/.claude"
  printf '{"plansDirectory": "docs/plans"}\n' > "$HOME/.claude/settings.json"
  h1=$(sha256sum < "$HOME/.claude/settings.json")
  "$REPO/install.sh" 2>/dev/null
  [ "$(sha256sum < "$HOME/.claude/settings.json")" = "$h1" ]
}

@test "the conventions block tells agents where plans live" {
  "$REPO/install.sh" 2>/dev/null
  grep -q '<workspace>/.claude/plans/' "$CT_HOME/CLAUDE.md"
}
