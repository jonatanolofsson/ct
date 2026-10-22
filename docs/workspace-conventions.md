# Multi-repo agent sessions — this directory is the workspace root

This directory is the root for parallel Claude Code sessions that each work across several repos at once. Each
session is a subdirectory here, holding a **full clone** of every repo it touches, isolated from other sessions.
This root is not a git repo itself.

## Layout
- `<session>/<repo>/` — one full clone per repo per session (e.g. `agent-a/myrepo/`). Independent `.git`;
  branch, commit, and push inside each clone independently. Don't edit another session's clones.
- `.env`, `.kubeconfig` (here, beside this file) — canonical operator credentials. What they contain is
  site-defined; the convention is only this: **always symlink both into every clone** — don't check whether a
  given repo needs them; the symlinks are harmless when unused and save a round-trip. Never copy, edit, commit,
  or print them.

## Add a repo to your workspace — you are already in it
An agent starts INSIDE its workspace (`<root>/<workspace>/`); a workspace holds as many repos as the work spans.
To add one, **execute this block in your shell** — do not print it as an answer. Every path is absolute, so it
runs from any directory. Fill in only `url`: the site section below lists each repo's full clone URL. If any
line fails, stop and fix that line; never fall back to a plain `git clone` or skip the remaining lines.

    ws="${CT_WORKSPACE:-$PWD}"               # your workspace dir (ct exports it; else: where you started)
    root="${WORKSPACE_ROOT:-${ws%/*}}"       # this root: .gitcache/, .env, .kubeconfig and this file
    url=<clone-url>                          # the full URL, as the site section lists it
    repo="${url##*/}"; repo="${repo%.git}"   # its directory and cache name: the URL's last segment
    git clone --reference-if-able "$root/.gitcache/$repo.git" "$url" "$ws/$repo"
    ln -s ../../.env        "$ws/$repo/.env"         # always both, even if the repo doesn't use them
    ln -s ../../.kubeconfig "$ws/$repo/.kubeconfig"
    git -C "$ws/$repo" config -f .gitmodules --get-regexp '\.path$' 2>/dev/null | while read -r _ path; do
      cache="$root/.gitcache/${path##*/}.git"            # each submodule against ITS OWN cache, if one exists
      if [ -d "$cache" ]; then git -C "$ws/$repo" submodule update --init --reference "$cache" -- "$path"
      else git -C "$ws/$repo" submodule update --init -- "$path"; fi
    done
    git -C "$ws/$repo" submodule update --init --recursive   # nested submodules, if any
    if [ -f "$ws/$repo/.envrc" ]; then (cd "$ws/$repo" && direnv allow); fi
    if [ -f "$ws/$repo/CLAUDE.md" ] && [ ! -e "$ws/$repo/AGENTS.md" ]; then   # for agents that read only AGENTS.md
      ln -s CLAUDE.md "$ws/$repo/AGENTS.md" && echo /AGENTS.md >> "$ws/$repo/.git/info/exclude"; fi

Then check it, and only then say it is done — a command that printed an error did not succeed:

    ls -la "$ws/$repo/.env" "$ws/$repo/.kubeconfig"   # both must resolve: no "No such file"
    cat "$ws/$repo/.git/objects/info/alternates"       # an absolute .gitcache path, if a cache existed
    ls -A "$ws"                                        # only your repos (+ your own files): nothing stray

`--reference-if-able` borrows objects from the cache when it exists and falls back to a plain clone when it does
not, so always use it. Never clone from, copy, or edit another workspace's clones.

## Make a new workspace — for a person, or when told to
    mkdir -p <root>/<workspace> && cd <root>/<workspace> && ct    # then add repos with the block above

Tear down = confirm each clone is clean and pushed (`git status`; nothing unpushed), then delete the session dir.
The canonical creds here are untouched — only the symlinks go.

## Shared object cache — clone with `--reference` so sessions don't each store the same objects
Every session cloning the same repos means N copies of identical git objects on disk. Bare **mirror caches**
under `.gitcache/` (beside this file) hold one shared copy; new clones borrow from them via git "alternates" and
store only their own new objects. Working tree, branches, commits, and push stay fully per-clone — only the
object store is shared, so this doesn't weaken the per-session isolation above.

The clone command is in the recipe above. Its two rules: **absolute** cache paths (a relative alternate is
resolved against `<repo>/.git/objects` and silently breaks if the clone moves), and submodules cloned *through*
their own caches rather than with `--recurse-submodules` on the clone, so shared submodules are deduplicated too.
Which caches exist is discoverable, not documented:  `ls .gitcache/`.

**The one rule that keeps borrowers safe: a cache is append-only.** Never delete a cache dir while any clone
references it, and never prune its objects — a borrowed object that vanishes corrupts every clone using it. The
caches are set `gc.auto=0` + `gc.pruneExpire=never` so they only grow. `.gitcache/` lives beside this file,
outside every session dir, so session teardown never touches it.

- Refresh a cache with new upstream history:  `git -C .gitcache/<repo>.git remote update`
- Build a cache for a new repo:  `git clone --mirror <url> .gitcache/<repo>.git && \`
  `git -C .gitcache/<repo>.git config gc.auto 0 && git -C .gitcache/<repo>.git config gc.pruneExpire never`
- Cut a clone loose from its cache (before archiving/moving it off this box):
  `git -C <clone> repack -a -d && rm <clone>/.git/objects/info/alternates`  (or clone with `--dissociate`).

## Your plan and scratch are yours — in your workspace, never shared
Every agent is independent, so its working files live in its OWN workspace, never in a directory that several
sessions share:

- **Plans** are written to `<workspace>/.claude/plans/`. `plansDirectory` in `~/.claude/settings.json` sets this
  (`.claude/plans`, resolved against the project root, which is the workspace, because ct starts the agent there).
  Before it, every session wrote plans into the one shared `~/.claude/plans/`. Two agents then took the same file
  for different work, each rewriting the other's, and the first plan's text was lost.
- **Edit only your own plan.** To change what another agent planned, message it. Never edit its file, not even to
  add a section about your own work.
- Delete your own working files when you are finished with them. A file someone else deletes mid-use, or a
  directory a reboot wipes (`/tmp`), is lost work, not cleanup.

## Logins belong to a workspace or a profile — never the machine
No login is machine-global. Two workspaces may work as two different accounts, and a login under `~/.config` is
every agent's at once: one agent's `gcloud auth application-default login` silently changes whose identity every
other agent's tooling uses. So ct writes `<workspace>/.envrc` at a workspace's first launch, and starts the agent
through `direnv exec` on it. The file's `ct_profile=` line decides where gcloud keeps its whole state, accounts
and application-default credentials alike (`CLOUDSDK_CONFIG`):

- **Empty (the default):** the workspace's own, in `<workspace>/.config/gcloud`. Deleting the workspace deletes it.
- **A name:** a **profile** shared by every workspace that names it, in `.profiles/<name>/gcloud` beside this file.
  Sign in once and all of them use it, for example every workspace of one company. Tearing down one workspace
  keeps the profile. Choose it at the first launch with `CT_PROFILE=<name> ct`, or later by editing the line.

- **Every repo's `.envrc` begins with `source_up_if_exists`.** `direnv exec <clone>` swaps out the environment
  direnv loaded before it, so a clone without that line drops the workspace's settings. gcloud then falls back to
  the machine's `~/.config/gcloud`, and nothing tells you.
- **Sign in from inside the workspace**, with `CLOUDSDK_CONFIG` pointing into it: `gcloud auth login`, then
  `gcloud auth application-default login`. If `echo $CLOUDSDK_CONFIG` is empty, stop. Never sign in without it.
- **Any other tool that signs in works the same way**: its config-directory variable goes in the workspace
  `.envrc`, pointing inside the workspace.
- **After editing the workspace `.envrc`**, run `direnv allow <workspace>` and restart the agent. Its environment
  is set when it starts. A blocked `.envrc` makes ct start the agent *without* it, with a warning.
- **OpenCode** runs every workspace's tools in its one shared server, so they don't get the workspace's
  environment. A command run as `direnv exec <clone> …` still does.

## Sessions share remotes — sync, don't clobber
Clones are isolated; **the remotes are not**. Another session is very likely pushing to the same `main` while
you work. Therefore, in every clone you touch:

- **`git pull --rebase` when you start a work unit, and again before you push.** A rejected push means someone
  landed work you don't have — rebase onto it, re-run the repo's checks, push. Never `--force`.
- **Update submodules after every pull / rebase / checkout**: `git submodule update --init --recursive`.
  Git does *not* move submodules for you. After a pull your submodule working tree still points at the OLD
  commit, so the next `git add -A` records that stale pointer and silently reverts whoever bumped it. This is
  not theoretical: it has caused a production outage where new app code ran against old framework code —
  builds clean, starts clean, then errors on every message, with the health UI still green.
- Prefer explicit `git add <paths>` over `git add -A` in a repo with submodules.
- **Before you build or deploy an image, verify the tree you built is the tree you meant** — images come from
  the working tree, not from `origin/main`. Check `git ls-tree HEAD <submodule>` and `git status -sb`.
- **Floating image tags (`deployment-latest`) mean the last builder wins.** If a deployed pod misbehaves in a
  way your code shouldn't, compare the running image digest against the one you built before debugging your
  own logic.

Repo templates can enforce the first two mechanically (e.g. an `.envrc` setting `submodule.recurse=true` +
`fetch.recurseSubmodules=on-demand`, and a pre-push gate failing a backwards submodule pointer move — see
github.com/jonatanolofsson/ruskin for one such setup).
