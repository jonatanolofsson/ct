# Restore runbook — bringing the agents back after a restart

Template: copy this next to your workspace root, fill in the <angle-bracket>
placeholders for your site, and keep it where a rescuer will look first.

## 0. What just happened?

A container/pod restart wipes everything on the overlay filesystem: tmux, the
tmux server, and any runtime-installed tools. It does NOT touch your home
volume: workspaces, `~/.claude/projects/` transcripts, `~/.local/bin`, and the
autostart opt-in flags all survive. Every agent conversation is therefore
recoverable — the only question is reattaching to it correctly.

## 1. The automatic path

If `~/.ct-autostart` exists (and `~/.ct-noautostart` does not), the boot hook
runs `ct-autostart` ~45 s after start: it heals tmux, does one credential
warm-up, then walks the workspaces and starts each agent detached with its
saved conversation. Log: `~/.ct-autostart.log`. Expect
`done — started=N skipped=M failed=0`.

## 2. The manual path (per workspace)

    cd <workspace-root>/<session>   # e.g. ~/dev/agent-a
    ct --continue                   # resume the saved conversation
    # Ctrl-b d to detach; tmux ls to list; tmux attach -t '=claude-<session>'

## 3. Three traps (each has bitten for real)

1. **`--continue` is not optional** on first launch after a restart. A bare
   `ct` starts a FRESH conversation and the context is gone from that session
   (the transcript file still exists — resume it explicitly by id if this
   happens: transcripts live in `~/.claude/projects/<cwd-with-slashes-as-hyphens>/`,
   and each `<uuid>.jsonl` filename is a session id `claude --resume <uuid>` accepts).
2. **`ct -d` does not mean detach.** Unknown arguments are forwarded to
   `claude`, where `-d` means `--debug`. Detached start is `CT_DETACH=1 ct …`.
3. **Transcript directories start with a hyphen** (`-home-you-dev-agent-a`).
   `ls`, `find` and `stat` parse that as an option and silently return
   nothing. Use bash globs (`compgen -G`) or `--` separators.

## 4. Site services to verify after a restart

| Service | URL / probe | Expected |
|---|---|---|
| <service> | <url> | <expected> |

## 5. Out-of-band levers (when the pod itself is wedged)

- Scale the deployment to 0, fix, scale back: <command for your site>
- Disable autostart from outside the pod (e.g. via the node's storage path for
  the home volume): `touch <home-volume-path>/.ct-noautostart`

## 6. What a restart does NOT touch

- Home volume: workspaces, clones, `.gitcache`, transcripts, flags, installed
  user binaries in `~/.local/bin` (they are refreshed, not lost, by the next
  bootstrap/install run).
- Remote state: git remotes, deployed workloads, anything in your cluster.
