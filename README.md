# ct

tmux'd Claude Code sessions that survive container restarts.

One agent per workspace, named after the workspace; sessions live in tmux so
they outlive terminals, editor reloads and extension hosts — and come back by
themselves after a reboot. Ships with an independent-checkouts workspace
convention for running many agents in parallel against shared remotes.

Quickstart, design and integration docs land with v0.1.0.
