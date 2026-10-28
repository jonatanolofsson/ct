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
    CT_PROFILE=<name> ct                                            # instead, to share a login profile (below)

Tear down = confirm each clone is clean and pushed (`git status`; nothing unpushed), then delete the session dir.
The canonical creds here are untouched — only the symlinks go. So is a profile in `.profiles/`: it outlives
any one workspace.

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
- **Scratch files** go in `<workspace>/.scratch/`. Delete your own when you are finished with them. A file
  someone else deletes mid-use, or a directory a reboot wipes (`/tmp`), is lost work, not cleanup.
- **Delete scratch files with a plain `rm` and literal paths** (`rm -f <workspace>/.scratch/x.json`). That runs
  without a prompt: ct registers `ct-scratch-guard`, a hook that allows `rm` only inside a workspace's
  `.scratch/`. Any other `rm` asks, and so does an `rm` it cannot check: one with a variable, a glob, `$(…)`,
  `sudo`, or a relative path after a `cd`.

## Logins belong to a workspace or a profile — never the machine
No login is machine-global. Two workspaces may work as two different accounts, and a login under `~/.config` is
every agent's at once: one agent's `gcloud auth application-default login` silently changes whose identity every
other agent's tooling uses. So ct writes `<workspace>/.envrc` at a workspace's first launch, and starts the agent
through `direnv exec` on it. The file's `ct_profile=` line decides where gcloud keeps its whole state, accounts
and application-default credentials alike (`CLOUDSDK_CONFIG`):

- **Empty (the default):** the workspace's own, in `<workspace>/.config/gcloud`. Deleting the workspace deletes it.
- **A name:** a **profile** shared by every workspace that names it, in `.profiles/<name>/gcloud` beside this file.
  Sign in once and all of them use it, for example every workspace of one company. Tearing down one workspace
  keeps the profile. Choose it at the first launch with `CT_PROFILE=<name> ct`, or later with the recipe below.

Rules that keep it working:

- **Every repo's `.envrc` begins with `source_up_if_exists`.** `direnv exec <clone>` swaps out the environment
  direnv loaded before it, so a clone without that line drops the workspace's settings. gcloud then falls back to
  the machine's `~/.config/gcloud`, and nothing tells you. Missing in a repo you work in? Add it, as its first line.
- **Sign in only with `CLOUDSDK_CONFIG` pointing into your workspace or profile**: `gcloud auth login`, then
  `gcloud auth application-default login`. If `echo $CLOUDSDK_CONFIG` is empty, stop. Never sign in without it.
- **Go programs ignore `CLOUDSDK_CONFIG`**: OpenTofu's and Terraform's Google provider look for
  application-default credentials in `~/.config/gcloud` unless `GOOGLE_APPLICATION_CREDENTIALS` names the file.
  The `.envrc` ct writes since v0.8.1 sets it. An older one lacks it, so add it after the `CLOUDSDK_CONFIG` line:
  `export GOOGLE_APPLICATION_CREDENTIALS="$CLOUDSDK_CONFIG/application_default_credentials.json"`.
- **Any other tool that signs in works the same way**: its config-directory variable goes in the workspace
  `.envrc`, under `$logins`, so it follows the profile.
- **The agent's own environment is fixed when it starts.** After editing the workspace `.envrc`, run
  `direnv allow <workspace>`. Until the agent is restarted (the site section says how), run commands through
  `direnv exec <clone> …` from a clone, which reads the edited file. A blocked `.envrc` makes ct start the agent
  *without* it, with a warning.
- **OpenCode** runs every workspace's tools in its one shared server, so they don't get the workspace's
  environment. A command run as `direnv exec <clone> …` still does.

### Claude Code follows the profile too
A profile also holds a whole Claude Code identity in `.profiles/<name>/claude`: its login or the backend it calls,
its settings, transcripts and memory. The workspace `.envrc` exports `CLAUDE_CONFIG_DIR` there when `ct_profile=`
is set (an older `.envrc` lacks the line: add `if [[ -n $ct_profile ]]; then export
CLAUDE_CONFIG_DIR="$logins/claude"; fi` after the gcloud lines). Without a profile, Claude keeps the machine's
`~/.claude`, as before. ct and ct-autostart look for a workspace's conversations in the same place.

    ct-profile claude <name>             # its own claude.ai login: sign in once with `claude /login`
    ct-profile claude <name> bedrock     # the site's backend, from $CT_BEDROCK_SETTINGS: no login
    ct-profile move <workspace> <name>   # copy the workspace's conversations and memory into it
    ct-profile move <workspace> <name> --own-accounts   # ...and let Remote Control show their history

A new profile starts from the machine's `~/.claude/settings.json` (hooks, permissions, `plansDirectory`) and links
its skills, agents, commands and plugins; it never copies a login. A conversation copied into a profile resumes
there with its whole history, on the profile's backend.

**Move with the agent stopped:** `touch ~/.ct-noautostart`, `tmux kill-session -t =claude-<workspace>`, then
move, then `rm ~/.ct-noautostart`. `move` refuses while the agent runs, because the copy would miss its last turns.

**Remote Control belongs to a claude.ai account.** A conversation that was linked to it under one account and then
resumes under another shows there without its history or its name: Claude Code records a veto in the transcript
(`history-suppression`) on the first such start, and renews it on every later one. `/rename` does not reach the
remote session. When the profile's account is also the person's, move with `--own-accounts`, before the agent
first starts in the profile: each conversation is copied under a new id without its Remote Control rows, so it
comes up as a new remote session with its whole history and its name. The old remote sessions stay under the old
account; archive them there. Don't use it to move a conversation into someone else's account.

**A workspace's name says who pays.** One ending in `-bedrock` uses a bedrock profile, and no other workspace
does; ct warns at start when the two disagree.

### Check or set your workspace's profile — you can do this yourself
Which profile is a question of **identity**: workspaces that work as the same accounts (one company, one person's
private work) share a profile, and anything else gets its own. Joining a profile hands this workspace every login
in it, so if the person has not said which one, ask. Don't guess from a name. To check:

    ws="${CT_WORKSPACE:-$PWD}"; root="${WORKSPACE_ROOT:-${ws%/*}}"
    grep '^ct_profile=' "$ws/.envrc"                                     # empty: the workspace's own logins
    (cd "$ws" && direnv exec . sh -c 'echo "$CLOUDSDK_CONFIG"')          # where gcloud actually looks
    ls "$root/.profiles/"                                                # the profiles that exist
    grep -l '^ct_profile=<name>$' "$root"/*/.envrc                       # who shares <name>

To set it, **execute this block**. It brings the logins this workspace already has along, so nobody signs in
again, and it never merges two sets of logins:

    ws="${CT_WORKSPACE:-$PWD}"; root="${WORKSPACE_ROOT:-${ws%/*}}"
    profile=<name>                                       # [a-z0-9-]; agreed with the person
    (umask 077 && mkdir -p "$root/.profiles/$profile")
    if [ -d "$ws/.config/gcloud" ]; then                 # logins of the workspace's own
      if [ -e "$root/.profiles/$profile/gcloud" ]; then echo "profile has logins: use them, keep yours aside"
      else mv "$ws/.config/gcloud" "$root/.profiles/$profile/gcloud"; fi
    fi
    sed -i "s/^ct_profile=.*/ct_profile=$profile/" "$ws/.envrc" && direnv allow "$ws"
    (cd "$ws" && direnv exec . sh -c 'echo "$CLOUDSDK_CONFIG"; gcloud auth list')   # the profile's dir and accounts

**Logins still in the machine's `~/.config/gcloud`**, from before this convention, can be brought into a profile
the same way, without anyone signing in again. Do it only after `CLOUDSDK_CONFIG=~/.config/gcloud gcloud auth list`
shows nothing but that profile's accounts. **Copy** (`cp -a`), don't move, while other agents still read the
machine's copy. Delete the machine's copy once no workspace depends on it, and only with the person's go-ahead.
Never delete a profile that any workspace still names.

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
