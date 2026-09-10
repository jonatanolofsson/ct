#!/usr/bin/env bash
# ct installer — sets up the workspace root and the ct toolchain.
#
#   curl -fsSL https://raw.githubusercontent.com/jonatanolofsson/ct/<tag>/install.sh | bash
#   ./install.sh          # from a checkout
#
# Idempotent: safe to re-run at every boot. Environment:
#   CT_HOME    workspace root                (default: ~/dev)
#   CT_PREFIX  where binaries go             (default: ~/.local/bin)
#   CT_REF     tag/branch to fetch when run  (default: main)
#              without a checkout (curl mode)
#
# What it does:
#   1. installs bin/{ct,ct-autostart,ensure-nix} into CT_PREFIX
#   2. writes the generic workspace conventions into CT_HOME/CLAUDE.md inside
#      a <!-- BEGIN ct-managed --> marker block (hand edits outside survive;
#      site layers add their own block — see docs/bootstrap-integration.md)
#   3. seeds ~/.claude/settings.json from the template ONLY if none exists
#   4. stamps ~/.local/share/ct/VERSION
set -euo pipefail

CT_HOME="${CT_HOME:-$HOME/dev}"
CT_PREFIX="${CT_PREFIX:-$HOME/.local/bin}"
CT_REF="${CT_REF:-main}"

say() { printf 'ct-install: %s\n' "$*" >&2; }

# --- locate the payload: a checkout next to this script, or fetch a tarball -
srcdir=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "$(dirname "${BASH_SOURCE[0]}")/bin/ct" ]; then
    srcdir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    say "fetching ct@${CT_REF} ..."
    curl -fsSL --max-time 120 \
        "https://codeload.github.com/jonatanolofsson/ct/tar.gz/refs/tags/${CT_REF}" \
        -o "$tmp/ct.tar.gz" 2>/dev/null \
      || curl -fsSL --max-time 120 \
        "https://codeload.github.com/jonatanolofsson/ct/tar.gz/refs/heads/${CT_REF}" \
        -o "$tmp/ct.tar.gz"
    tar -xzf "$tmp/ct.tar.gz" -C "$tmp"
    srcdir="$(find "$tmp" -maxdepth 1 -type d -name 'ct-*' | head -1)"
    [ -n "$srcdir" ] && [ -f "$srcdir/bin/ct" ] || { say "payload missing bin/ct — aborting, nothing changed"; exit 1; }
fi

# --- 1. binaries (replace only on success; old copies survive any failure) --
mkdir -p "$CT_PREFIX"
for tool in ct ct-autostart ensure-nix; do
    install -m 0755 "$srcdir/bin/$tool" "$CT_PREFIX/$tool"
done
say "installed ct, ct-autostart, ensure-nix -> $CT_PREFIX"

# --- 2. workspace root + conventions block ---------------------------------
mkdir -p "$CT_HOME"
md="$CT_HOME/CLAUDE.md"
BEGIN='<!-- BEGIN ct-managed -->'
END='<!-- END ct-managed -->'
touch "$md"
if grep -qF "$BEGIN" "$md"; then
    sed -i "\|^${BEGIN}\$|,\|^${END}\$|d" "$md"
fi
{ echo "$BEGIN"; cat "$srcdir/docs/workspace-conventions.md"; echo "$END"; } >> "$md"
say "wrote ct-managed block in $md"

# --- 3. settings seed (write-once, never clobber) ---------------------------
if [ ! -f "$HOME/.claude/settings.json" ]; then
    mkdir -p "$HOME/.claude"
    install -m 0600 "$srcdir/templates/claude-settings.json" "$HOME/.claude/settings.json"
    say "seeded ~/.claude/settings.json from template"
fi

# --- 4. version stamp -------------------------------------------------------
mkdir -p "$HOME/.local/share/ct"
printf '%s %s\n' "$CT_REF" "$(date -u +%Y-%m-%dT%H:%MZ)" > "$HOME/.local/share/ct/VERSION"
say "done (${CT_REF}). Next: create a workspace under $CT_HOME and run: ct"
