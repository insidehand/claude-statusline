#!/usr/bin/env bash
# claude-statusline/install.sh
# Installs the Claude Code statusline.
# Usage:
#   ./install.sh          → installs bash version (no build tools needed)
#   ./install.sh --go     → builds & installs the Go version (faster)

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$HOME/.claude"
SETTINGS="$CLAUDE_DIR/settings.json"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()    { echo -e "${GREEN}✓${NC} $*"; }
warn()    { echo -e "${YELLOW}⚠${NC}  $*"; }
err()     { echo -e "${RED}✗${NC} $*" >&2; }

echo ""
echo "  Claude Code Statusline – installer"
echo "  ────────────────────────────────────"
echo ""

# ── Dependency check ──────────────────────────────────────────────────────────
if ! command -v jq &>/dev/null; then
  err "jq is required. Install with: brew install jq"
  exit 1
fi

mkdir -p "$CLAUDE_DIR"

# ── Choose version ────────────────────────────────────────────────────────────
USE_GO=0
if [[ "${1:-}" == "--go" ]]; then
  if ! command -v go &>/dev/null; then
    err "Go not found. Install from https://go.dev/dl/ then re-run with --go"
    exit 1
  fi
  USE_GO=1
fi

# ── Install files ─────────────────────────────────────────────────────────────
if [[ $USE_GO -eq 1 ]]; then
  echo "  Building Go binary…"
  cd "$REPO_DIR"
  go build -o "$CLAUDE_DIR/statusline-go" statusline.go
  chmod +x "$CLAUDE_DIR/statusline-go"
  COMMAND="~/.claude/statusline-go"
  info "Built and installed: ~/.claude/statusline-go"
else
  cp "$REPO_DIR/statusline.sh" "$CLAUDE_DIR/statusline.sh"
  chmod +x "$CLAUDE_DIR/statusline.sh"
  COMMAND="~/.claude/statusline.sh"
  info "Installed: ~/.claude/statusline.sh"
fi

# ── Update settings.json ─────────────────────────────────────────────────────
if [[ ! -f "$SETTINGS" ]]; then
  echo '{}' > "$SETTINGS"
fi

# Merge statusLine key into existing settings (preserves other keys)
UPDATED=$(jq --arg cmd "$COMMAND" '
  .statusLine = {
    "type": "command",
    "command": $cmd,
    "padding": 0
  }
' "$SETTINGS")

echo "$UPDATED" > "$SETTINGS"
info "Updated: ~/.claude/settings.json"

echo ""
echo "  Done! Start or restart Claude Code to see the statusline."
echo ""
echo "  What you'll see:"
echo "    Line 1 → [model] 📂 project ⚡ branch | [████░░] 42% 84k | 1h23m"
echo "    Line 2 → ｜your last message to Claude"
echo ""

if [[ $USE_GO -eq 0 ]]; then
  echo "  Tip: run  ./install.sh --go  for a faster (Go-compiled) version."
  echo ""
fi
