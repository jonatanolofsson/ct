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

## Docs

- [Integrating ct into a container/pod bootstrap](docs/bootstrap-integration.md), including autostart
- [Restore runbook](docs/restore-runbook.md)
- [Workspace conventions](docs/workspace-conventions.md): the block ct maintains in the workspace `CLAUDE.md`
