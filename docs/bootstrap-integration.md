# Integrating ct into a container/pod bootstrap

How to wire ct into an environment that reprovisions itself on every start
(a code-server pod, a devcontainer, a VM image). The standalone path is just
`install.sh`; this page is for the fleet case.

## The consumer pattern (pinned curl, PVC fallback)

Pin a tag and fetch the installer at boot; on any failure keep the previously
installed copies (they live on the persistent home volume):

    CT_TAG="v0.1.0"   # bump = a deliberate commit; revert = rollback
    if curl -fsSL --max-time 60 \
         "https://raw.githubusercontent.com/jonatanolofsson/ct/${CT_TAG}/install.sh" \
         -o /tmp/ct-install.sh; then
        CT_REF="$CT_TAG" CT_HOME="$HOME/dev" bash /tmp/ct-install.sh \
          || echo "warn: ct install failed — keeping existing copies"
    else
        echo "warn: could not fetch ct@${CT_TAG} — keeping existing copies"
    fi

Why this shape:

- **`--max-time`** so a network hang can never stall the boot past a liveness
  probe.
- **Failure keeps the old copies** — the installer replaces files only on
  success, so a bad release or an offline registry degrades to "yesterday's
  version" instead of "no tooling".
- **The tag is pinned in your config repo**, so rolling back the consumer is a
  normal `git revert`.

## Site-specific conventions layer

`install.sh` writes the generic workspace conventions into
`$CT_HOME/CLAUDE.md` inside a `<!-- BEGIN ct-managed -->` marker block. Your
site layer (repo rosters, credential specifics, cluster constraints) should be
written as a SECOND, independent marker block after it:

    SITE_BEGIN='<!-- BEGIN ct-site-managed -->'
    SITE_END='<!-- END ct-site-managed -->'
    if grep -qF "$SITE_BEGIN" "$CT_HOME/CLAUDE.md"; then
        sed -i "\|^${SITE_BEGIN}\$|,\|^${SITE_END}\$|d" "$CT_HOME/CLAUDE.md"
    fi
    { echo "$SITE_BEGIN"; cat /path/to/your/site-fragment.md; echo "$SITE_END"; } \
        >> "$CT_HOME/CLAUDE.md"

Two blocks, two owners: the ct installer never touches your site block, your
bootstrap never touches the ct block, and hand edits outside both survive.

## Autostart at boot

`ct-autostart` is opt-in per user (`touch ~/.ct-autostart`; kill switch
`~/.ct-noautostart` wins). Launch it detached and late — the boot process
must reach its main service before the agents start competing for CPU:

    setsid bash -c 'sleep 45; exec ct-autostart >> "$HOME/.ct-autostart.log" 2>&1' &

Two modes worth knowing for a fleet:

- **`ct-autostart --loop`** repeats the pass every `CT_AUTOSTART_INTERVAL` seconds
  (default 300). A boot-only pass leaves a workspace created after boot without an
  agent, and a crashed agent dead, until the next pod restart; the pass is
  idempotent, so re-running it on a timer closes both. The kill switch is re-read
  every round, so it stops a running loop too. Launch it in place of the one-shot:

      setsid bash -c 'sleep 45; exec ct-autostart --loop >> "$HOME/.ct-autostart.log" 2>&1' &

- **`ct-autostart --restart`** stops every managed session and starts it again —
  what you want after upgrading `claude`, when every running agent is still the
  old binary. It never kills the session it is run from.

- **`ct-autostart --supervise`** runs `--loop` forever and starts it again if it
  ever exits — the stand-in for a systemd unit in a container that has none. While
  the kill switch is set or the opt-in is missing it waits (and says so once), so
  lifting either takes effect within `CT_AUTOSTART_RETRY` seconds (default 30).
  **Run it in the same container as your main process, not a sidecar:** tmux's
  server lives in whichever container starts it, so every agent becomes a child of
  that container, and a sidecar restart would kill them all. Launch it in place of
  `--loop`:

      setsid bash -c 'sleep 45; exec ct-autostart --supervise >> "$HOME/.ct-autostart.log" 2>&1' &

Every workspace gets its agents back, each resuming its own conversation:
- Claude resumes its newest substantive transcript by id.
- OpenCode resumes with `--continue`, its last session in the workspace.
- An agent with no saved conversation yet (a workspace created but never prompted) gets a fresh session.

A workspace IS an agent; to retire one, remove its directory.

**Which agents** a workspace runs is ct's record, `~/.local/share/ct/agents/<workspace>`. ct writes it
whenever it launches an agent, with one line per agent: `claude`, or `opencode <port>`.
- **No record** means `claude`, exactly as before agents existed. An existing pod therefore upgrades with
  no change.
- **An empty record** means no agents.
- **`CT_AGENT=<agent> CT_AGENT_FORGET=1 ct`** drops one agent from the record without touching a running
  session.

`ct-autostart` never builds a command line itself. It starts every recorded agent with
`CT_AGENT=<agent> CT_DETACH=1 ct`, so ct remains the only place that knows how to launch one. The
credential warm-up (`claude -p ok`) runs only when some workspace records `claude`; OpenCode reads its
keys from the environment and has no OAuth token to race on.

Every pass also reads the screen of each session that was already running and
logs `WARNING — running, but …` when it is blank, unreadable, or does not show
the input box. The test is positive: a healthy session, idle or working, always
shows the input box, whose top border carries the session name
(`──── <workspace> ─`); every dialog replaces it, including ones nobody thought
to list. `CT_AUTOSTART_DIALOG_RE` only names the known ones (trust, MCP
approval) in the warning. A session stuck at a dialog looks healthy to every
process check; this is the only place it shows. The summary line counts them
(`warned=N`). It only warns — answering a dialog is a person's decision. A fresh
session in a directory `~/.claude.json` does not trust yet is flagged at start,
since it will stop at the trust dialog.

An OpenCode session is checked over HTTP instead of by its screen:
`GET http://127.0.0.1:<port>/global/health` must answer `"healthy":true`. That is sturdier than reading
a TUI. A server that doesn't answer is a `WARNING` too, and the session is not killed. A session whose
process has died is gone from tmux, and the next pass (`--loop`) starts it again, as for Claude.

Workspaces are discovered as `~/dev/agent-*` by default. If your site names them
plainly (`~/dev/billing`, `~/dev/billing-api`), set `CT_AUTOSTART_GLOB='*'`;
dot-dirs such as `.gitcache/` are never treated as workspaces.

If your image lacks tmux at boot, pre-cache its .deb closure on the home
volume (`~/.cache/debs/`) — deriving that closure on a machine where tmux was
already installed once will silently miss transitive dependencies.

## Keys the environment must provide

| What | Why |
|---|---|
| `claude` CLI installed + credentials present | `ct-autostart` refuses to start agents that would die on missing login |
| `opencode` installed, its provider keys in the environment (only for OpenCode agents) | OpenCode sessions start from `ct-autostart` with no person present to log in |
| `curl` (only for OpenCode agents) | the health probe; without it, running OpenCode sessions are not checked |
| tmux installable (apt, cached .debs, or nix) | sessions live in tmux |
| Persistent `$HOME` | transcripts, workspaces and installed copies must survive restarts |

**Note on `--loop`:** it restarts any managed workspace whose session is gone —
including an agent someone ended on purpose with `/exit`. To retire an agent,
remove or rename its workspace directory (or touch `~/.ct-noautostart` to stop
the loop altogether); exiting the session alone is undone within one interval.
