#!/usr/bin/env bash
# claude-statusline/uninstall.sh
# Usage:
#   ./uninstall.sh statusline      → removes both statusline versions + statusLine setting
#   ./uninstall.sh mod <name>      → removes the ~/.claude/mods/<name> link + its PLUGIN_DIRS entry
#   ./uninstall.sh all             → statusline + every mod in mods/
# Env added by a mod's install.json (e.g. CLAUDE_CODE_NO_FLICKER) is left in place.

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

usage() {
  sed -n '3,7p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 1
}

# ── statusline ────────────────────────────────────────────────────────────────
uninstall_statusline() {
  # Remove installed binaries/scripts (symlink or copied file)
  local f
  for f in statusline.sh statusline-go; do
    if [[ -L "$CLAUDE_DIR/$f" || -f "$CLAUDE_DIR/$f" ]]; then
      rm "$CLAUDE_DIR/$f"
      info "Removed ~/.claude/$f"
    fi
  done

  if [[ -f "$SETTINGS" ]]; then
    settings_apply 'del(.statusLine)'
    info "Removed statusLine from ~/.claude/settings.json"
  fi

  # Optionally remove session-tracker data
  echo ""
  read -rp "  Remove session-tracker data (~/.claude/session-tracker/)? [y/N] " ans
  if [[ "${ans,,}" == "y" ]]; then
    rm -rf "$CLAUDE_DIR/session-tracker"
    info "Removed ~/.claude/session-tracker/"
  fi
}

# ── mods ──────────────────────────────────────────────────────────────────────
uninstall_mod() {
  local name="$1"
  require_mod "$name"

  local dst="$MODS_DIR/$name"
  if [[ -L "$dst" ]]; then
    rm "$dst"
    info "Removed link ~/.claude/mods/$name"
  elif [[ -e "$dst" ]]; then
    warn "~/.claude/mods/$name is not a symlink; left in place"
  fi

  if [[ -f "$SETTINGS" ]]; then
    plugin_dirs_remove "~/.claude/mods/$name"
    info "settings.json: ~/.claude/mods/$name removed from CLAUDE_CODE_PLUGIN_DIRS"
  fi
}

# ── main ──────────────────────────────────────────────────────────────────────
echo ""
echo "  Claude Code Statusline – uninstaller"
echo ""

require_jq

case "${1:-}" in
  statusline)
    uninstall_statusline
    ;;
  mod)
    uninstall_mod "${2:-}"
    ;;
  all)
    for m in $(list_mods); do uninstall_mod "$m"; done
    uninstall_statusline
    ;;
  *)
    usage
    ;;
esac

echo ""
echo "  Done. Restart Claude Code to apply."
echo ""
