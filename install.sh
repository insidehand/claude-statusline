#!/usr/bin/env bash
# claude-statusline/install.sh
# Installs the Claude Code statusline and/or mods. Re-running reinstalls.
# Usage:
#   ./install.sh statusline        → bash version (symlinked, no build tools needed)
#   ./install.sh statusline --go   → builds & installs the Go version (faster)
#   ./install.sh mod <name>        → links mods/<name> into ~/.claude/mods/
#   ./install.sh all               → Go statusline + every mod in mods/

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

usage() {
  sed -n '3,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 1
}

# ── statusline ────────────────────────────────────────────────────────────────
install_statusline() {
  local command
  if [[ "${1:-}" == "--go" ]]; then
    if ! command -v go &>/dev/null; then
      err "Go not found. Install from https://go.dev/dl/ then re-run with --go"
      exit 1
    fi
    echo "  Building Go binary…"
    mkdir -p "$CLAUDE_DIR"
    go build -o "$CLAUDE_DIR/statusline-go" "$REPO_DIR/statusline/statusline.go"
    chmod +x "$CLAUDE_DIR/statusline-go"
    command="~/.claude/statusline-go"
    info "Built and installed: ~/.claude/statusline-go"
  else
    link_into "$REPO_DIR/statusline/statusline.sh" "$CLAUDE_DIR/statusline.sh"
    command="~/.claude/statusline.sh"
    info "Linked: ~/.claude/statusline.sh → statusline/statusline.sh"
  fi

  settings_apply '
    .statusLine = {
      "type": "command",
      "command": $cmd,
      "padding": 0
    }
  ' --arg cmd "$command"
  info "settings.json: statusLine → $command"
}

# ── mods ──────────────────────────────────────────────────────────────────────
install_mod() {
  local name="$1"
  require_mod "$name"

  link_into "$REPO_DIR/mods/$name" "$MODS_DIR/$name"
  info "Linked: ~/.claude/mods/$name → mods/$name"

  plugin_dirs_add "~/.claude/mods/$name"
  info "settings.json: CLAUDE_CODE_PLUGIN_DIRS includes ~/.claude/mods/$name"

  # Env the mod needs, declared in mods/<name>/install.json. Only added when
  # not already set, so existing user values win.
  local decl="$REPO_DIR/mods/$name/install.json"
  if [[ -f "$decl" ]] && [[ "$(jq '.env // {} | length' "$decl")" -gt 0 ]]; then
    env_add_missing "$(jq -c '.env' "$decl")"
    info "settings.json: env $(jq -r '.env | keys | join(", ")' "$decl") present"
  fi
}

# ── main ──────────────────────────────────────────────────────────────────────
echo ""
echo "  Claude Code Statusline – installer"
echo "  ────────────────────────────────────"
echo ""

require_jq

case "${1:-}" in
  statusline)
    install_statusline "${2:-}"
    ;;
  mod)
    install_mod "${2:-}"
    ;;
  all)
    install_statusline --go
    for m in $(list_mods); do install_mod "$m"; done
    ;;
  *)
    usage
    ;;
esac

echo ""
echo "  Done! Restart Claude Code to apply settings changes."
echo "  Edits to a linked mod hot-reload; edits to statusline.go need ./build.sh."
echo ""
