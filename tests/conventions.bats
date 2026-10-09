#!/usr/bin/env bats
# The "Add a repo" recipe in docs/workspace-conventions.md is what every agent
# is told to run. These tests run THAT block, extracted from the doc, so the
# doc cannot drift from something that works. Fixtures: a local upstream repo
# with a submodule, a mirror cache for each, and the root's credential files.

setup() {
  REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  ROOT="$BATS_TEST_TMPDIR/root"
  WS="$ROOT/agent-x"
  UP="$BATS_TEST_TMPDIR/upstream"
  mkdir -p "$ROOT/.gitcache" "$WS" "$UP"
  : > "$ROOT/.env"; : > "$ROOT/.kubeconfig"
  # Local file:// submodules are refused by default since git 2.38.
  export GIT_CONFIG_COUNT=3 \
    GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always \
    GIT_CONFIG_KEY_1=user.email GIT_CONFIG_VALUE_1=t@example.com \
    GIT_CONFIG_KEY_2=user.name GIT_CONFIG_VALUE_2=t
  git init -q -b main "$UP/sub-src" && git -C "$UP/sub-src" commit -q --allow-empty -m sub
  git clone -q --bare "$UP/sub-src" "$UP/sub.git"
  git init -q -b main "$UP/proj-src"
  git -C "$UP/proj-src" submodule -q add "$UP/sub.git" libs/sub
  printf '# proj\n' > "$UP/proj-src/CLAUDE.md"; git -C "$UP/proj-src" add CLAUDE.md
  git -C "$UP/proj-src" commit -q -m proj
  git clone -q --bare "$UP/proj-src" "$UP/proj.git"
  git clone -q --mirror "$UP/proj.git" "$ROOT/.gitcache/proj.git"
  git clone -q --mirror "$UP/sub.git" "$ROOT/.gitcache/sub.git"
}

# The recipe's first indented block under "## Add a repo", placeholders filled.
recipe() {
  awk '/^## Add a repo/ {f=1; next} f && /^    / {print substr($0,5); b=1; next} f && b {exit}' \
    "$REPO/docs/workspace-conventions.md" |
    sed -e "s|^url=<clone-url>.*|url=$UP/proj.git|"
}

@test "the doc has the recipe: one placeholder, the repo name derived from the URL" {
  run recipe
  [[ "$output" == *'repo="${url##*/}"'* ]]
  [[ "$output" == *"url=$UP/proj.git"* ]]
  [[ "$output" == *'--reference-if-able "$root/.gitcache/$repo.git"'* ]]
}

@test "run from ANOTHER directory with ct's exports, it does everything the conventions ask" {
  recipe > "$BATS_TEST_TMPDIR/recipe.sh"
  ( cd / && CT_WORKSPACE="$WS" WORKSPACE_ROOT="$ROOT" bash -e "$BATS_TEST_TMPDIR/recipe.sh" )
  # the clone, borrowing from its cache by an ABSOLUTE path
  [ "$(cat "$WS/proj/.git/objects/info/alternates")" = "$ROOT/.gitcache/proj.git/objects" ]
  # the submodule, through ITS OWN cache
  [ "$(cat "$WS/proj/.git/modules/libs/sub/objects/info/alternates")" = "$ROOT/.gitcache/sub.git/objects" ]
  # both credential links inside the clone, resolving to the root's files
  [ "$(readlink -f "$WS/proj/.env")" = "$ROOT/.env" ]
  [ "$(readlink -f "$WS/proj/.kubeconfig")" = "$ROOT/.kubeconfig" ]
  # AGENTS.md links the repo's CLAUDE.md, for agents that read only AGENTS.md,
  # and git never sees it
  [ "$(readlink "$WS/proj/AGENTS.md")" = "CLAUDE.md" ]
  ! git -C "$WS/proj" status --porcelain | grep -q AGENTS.md
  # and nothing stray in the workspace
  [ "$(ls -A "$WS")" = "proj" ]
}

@test "a repo that already has an AGENTS.md keeps it" {
  printf '# own agents file\n' > "$UP/proj-src/AGENTS.md"
  git -C "$UP/proj-src" add AGENTS.md && git -C "$UP/proj-src" commit -q -m agents
  git -C "$UP/proj-src" push -q "$UP/proj.git" main
  recipe > "$BATS_TEST_TMPDIR/recipe.sh"
  ( cd / && CT_WORKSPACE="$WS" WORKSPACE_ROOT="$ROOT" bash -e "$BATS_TEST_TMPDIR/recipe.sh" )
  [ ! -L "$WS/proj/AGENTS.md" ]
  [ "$(cat "$WS/proj/AGENTS.md")" = "# own agents file" ]
  [ -z "$(git -C "$WS/proj" status --porcelain -- AGENTS.md)" ]
}

@test "without ct's exports, run from the workspace, it does the same" {
  recipe > "$BATS_TEST_TMPDIR/recipe.sh"
  ( cd "$WS" && unset CT_WORKSPACE WORKSPACE_ROOT && bash -e "$BATS_TEST_TMPDIR/recipe.sh" )
  [ "$(cat "$WS/proj/.git/objects/info/alternates")" = "$ROOT/.gitcache/proj.git/objects" ]
  [ "$(readlink -f "$WS/proj/.env")" = "$ROOT/.env" ]
  [ "$(ls -A "$WS")" = "proj" ]
}

@test "with no cache for the repo, it still clones (and borrows nothing)" {
  rm -rf "$ROOT/.gitcache/proj.git"
  recipe > "$BATS_TEST_TMPDIR/recipe.sh"
  ( cd / && CT_WORKSPACE="$WS" WORKSPACE_ROOT="$ROOT" bash -e "$BATS_TEST_TMPDIR/recipe.sh" )
  [ -d "$WS/proj/.git" ]
  [ ! -s "$WS/proj/.git/objects/info/alternates" ]
  [ "$(readlink -f "$WS/proj/.env")" = "$ROOT/.env" ]
}
