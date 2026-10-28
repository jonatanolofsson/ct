# ct

tmux'd coding-agent sessions (Claude Code, OpenCode) that survive container restarts.

One agent session per workspace and agent kind, named after the workspace. The sessions live in tmux, so
they outlive terminals, editor reloads and extension hosts, and `ct-autostart` brings them back by
themselves after a reboot. ct ships with an independent-checkouts workspace convention for running many
agents in parallel against shared remotes.

## Usage

    cd ~/dev/<workspace>            # or anywhere inside it
    ct                              # Claude Code: start, or reattach if running
    CT_AGENT=opencode ct            # OpenCode, in its own session beside Claude, on the shared server
    CT_DETACH=1 ct                  # start without attaching (scripts, boot)
    CT_FRESH=1 ct                   # a new conversation instead of resuming

Settings are environment variables, never flags. Every argument is forwarded to the agent untouched.

| Variable | Meaning |
|---|---|
| `CT_AGENT` | `claude` (default) or `opencode` |
| `CT_DETACH` | start the session and return instead of attaching |
| `CT_FRESH` | don't resume the workspace's last conversation |
| `CT_AGENT_FORGET` | with `CT_AGENT`: stop `ct-autostart` from starting that agent in this workspace |
| `CT_OPENCODE_SERVER_PORT` | loopback port of the one OpenCode server (default 4096) |
| `CT_OPENCODE_SERVER_WAIT` | seconds to wait for that server to answer (default 60) |
| `CT_OPENCODE_WEB` | URL printed for the OpenCode web UI; `{port}` is replaced by the server's port |
| `CT_WORKSPACE_ROOT` | a single workspace root instead of `~/dev` and `~/workspaces` |
| `CT_PROFILE` | at a workspace's first launch: share the named login profile (see below) instead of its own logins |
| `CT_BEDROCK_SETTINGS` | for `ct-profile claude <name> bedrock`: the site's Claude settings for its Bedrock backend (a JSON file merged into the profile's) |

ct also *exports* two variables into every agent it starts, so the workspace conventions' "Add a repo"
recipe runs as written: `CT_WORKSPACE` (the agent's workspace) and `WORKSPACE_ROOT` (the root holding
`.gitcache/`, `.env` and `.kubeconfig`). A pinned session gets the workspace that holds its directory.
| `CT_SESSION_ID` + `CT_NAME` | pin one claude conversation by id, run from its own directory (see below) |
| `CT_WAKE` | `0`: ct-autostart wakes nobody with a message (see below) |

### The workspace's environment: logins belong to a workspace or a profile

At a workspace's first launch ct writes `<workspace>/.envrc` (never overwriting one that exists) and starts
the agent through `direnv exec` on it. The file sets `CLOUDSDK_CONFIG`, so gcloud logins and
application-default credentials belong to that workspace, or, with `CT_PROFILE=<name>`, to a profile in
`<root>/.profiles/<name>/` that every workspace naming it shares. Never to the machine. Each repo's
`.envrc` inherits it with `source_up_if_exists`. A blocked `.envrc` makes ct warn and start the agent without
it, rather than not at all. See the conventions, "Logins belong to a workspace or a profile".

A profile also carries a Claude Code identity: the `.envrc` points `CLAUDE_CONFIG_DIR` at
`<root>/.profiles/<name>/claude`, so a profile has its own claude.ai login or its own backend, settings and
conversations, and ct resumes from there. `ct-profile claude <name> [bedrock]` sets one up and `ct-profile move`
copies a workspace's conversations into it. A workspace named `*-bedrock` should use a bedrock profile; ct warns
when the name and the profile disagree.

### One OpenCode server, one terminal per workspace

ct runs ONE OpenCode server per machine, `opencode serve` on a loopback port (`CT_OPENCODE_SERVER_PORT`,
default 4096), in its own tmux session `ct-opencode-server`. It starts the server on first use, restarts
it if it exits, and waits for it to answer. Each workspace's OpenCode session is a terminal attached to
that server for its own directory:

    opencode attach http://127.0.0.1:4096 --dir <workspace> --session <id>

ct resumes the workspace's most recent session by id, asking the server for that directory's sessions.
(`--continue` would pick the most recent session of any workspace.) A resumed agent's wake message
goes into its session through the server's API, before the terminal attaches.

One server means one address for every workspace: its web UI lists them all. A site points a browser at
it through an authenticating proxy that runs in the same machine, and prints that address by setting
`CT_OPENCODE_WEB`. The server binds to loopback only, so it is never reachable from the network directly.

Two consequences:
- A server restart drops every attached terminal at once. ct-autostart's next pass brings them back.
- The agents' shells run in their workspace directory but do not carry `CT_WORKSPACE`; the conventions'
  recipe falls back to the current directory, which is the same thing.

Before 0.7.0 each workspace's terminal was its own server, on its own port (4100–4199). A session started
that way keeps running until it exits; the next start uses the shared server.

OpenCode reads `AGENTS.md` and falls back to `CLAUDE.md`, searching upward from where it starts (the
workspace root). The workspace-root `CLAUDE.md` that ct maintains therefore reaches it too. Unlike Claude,
OpenCode loads only the **first** file it finds.

### After a restart, agents are told what happened

When `ct-autostart` brings back a conversation, its first message says what happened. Either the machine
restarted, or the session ended while the machine was up. It gives the time and the agent's last
activity, and says that background shells, watchers and port-forwards are gone. It asks the agent to
check its work in flight, tell you where it stands in a line or two, and continue only work you had
already approved. A fresh session gets no message, and neither does a session you start with `ct`
yourself.

- Turn it off with `CT_WAKE=0` in ct-autostart's environment.
- Replace the text with `~/.config/ct/wake.md`, using the placeholders `{event}`, `{time}` and `{gap}`.

### Pinned sessions: a second conversation that should survive restarts

A workspace has one claude agent. A second conversation that belongs with it (a fork, or an agent
working in a worktree) has no slot, so a restart ends it and nothing brings it back. Pin it from the
directory it was started in:

    cd ~/dev/agent-llm/edgelab-root/.claude/worktrees/aws-bedrock
    CT_SESSION_ID=60c1e059-… CT_NAME=agent-llm-fork ct

ct resumes exactly that conversation as `claude-agent-llm-fork` and records it in
`~/.local/share/ct/sessions/`. From then on `ct-autostart` revives it, health-checks it and wakes it
like a workspace agent. `CT_AGENT_FORGET=1`, with the same two variables, unpins it.

Claude keys a conversation on its directory, so ct refuses to pin from anywhere else. A `--resume`
from the wrong directory would silently start an empty conversation.

## Docs

- [Integrating ct into a container/pod bootstrap](docs/bootstrap-integration.md), including autostart
- [Restore runbook](docs/restore-runbook.md)
- [Workspace conventions](docs/workspace-conventions.md): the block ct maintains in the workspace `CLAUDE.md`
