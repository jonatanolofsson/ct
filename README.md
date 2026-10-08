# ct

tmux'd coding-agent sessions (Claude Code, OpenCode) that survive container restarts.

One agent session per workspace and agent kind, named after the workspace. The sessions live in tmux, so
they outlive terminals, editor reloads and extension hosts, and `ct-autostart` brings them back by
themselves after a reboot. ct ships with an independent-checkouts workspace convention for running many
agents in parallel against shared remotes.

## Usage

    cd ~/dev/<workspace>            # or anywhere inside it
    ct                              # Claude Code: start, or reattach if running
    CT_AGENT=opencode ct            # OpenCode, in its own session beside Claude
    CT_DETACH=1 ct                  # start without attaching (scripts, boot)
    CT_FRESH=1 ct                   # a new conversation instead of resuming

Settings are environment variables, never flags. Every argument is forwarded to the agent untouched.

| Variable | Meaning |
|---|---|
| `CT_AGENT` | `claude` (default) or `opencode` |
| `CT_DETACH` | start the session and return instead of attaching |
| `CT_FRESH` | don't resume the workspace's last conversation |
| `CT_AGENT_FORGET` | with `CT_AGENT`: stop `ct-autostart` from starting that agent in this workspace |
| `CT_OPENCODE_WEB` | URL template printed for an OpenCode session's web UI; `{port}` is replaced |
| `CT_OPENCODE_PORT_MIN` / `_MAX` | port range for OpenCode servers (default 4100–4199) |
| `CT_WORKSPACE_ROOT` | a single workspace root instead of `~/dev` and `~/workspaces` |

ct also *exports* two variables into every agent it starts, so the workspace conventions' "Add a repo"
recipe runs as written: `CT_WORKSPACE` (the agent's workspace) and `WORKSPACE_ROOT` (the root holding
`.gitcache/`, `.env` and `.kubeconfig`). A pinned session gets the workspace that holds its directory.
| `CT_SESSION_ID` + `CT_NAME` | pin one claude conversation by id, run from its own directory (see below) |
| `CT_WAKE` | `0`: ct-autostart wakes nobody with a message (see below) |

### OpenCode sessions are also servers

An OpenCode session serves its HTTP API on a loopback port. The port is chosen once per workspace and
kept, so it is the same after every restart. ct prints it on launch and on reattach. Join the live
session from a second terminal:

    opencode attach http://127.0.0.1:<port>

or from a browser through an authenticating proxy that runs in the same pod. With code-server, that's
`https://<code-server-host>/absproxy/<port>/`, which a site can print by setting
`CT_OPENCODE_WEB='https://<host>/absproxy/{port}/'`. The server binds to loopback only, so it is never
reachable from the network directly.

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
