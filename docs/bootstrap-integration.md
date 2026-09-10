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

If your image lacks tmux at boot, pre-cache its .deb closure on the home
volume (`~/.cache/debs/`) — deriving that closure on a machine where tmux was
already installed once will silently miss transitive dependencies.

## Keys the environment must provide

| What | Why |
|---|---|
| `claude` CLI installed + credentials present | `ct-autostart` refuses to start agents that would die on missing login |
| tmux installable (apt, cached .debs, or nix) | sessions live in tmux |
| Persistent `$HOME` | transcripts, workspaces and installed copies must survive restarts |
