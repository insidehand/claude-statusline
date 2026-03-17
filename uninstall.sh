#!/usr/bin/env bash
# claude-statusline/uninstall.sh

set -euo pipefail

CLAUDE_DIR="$HOME/.claude"
SETTINGS="$CLAUDE_DIR/settings.json"

echo ""
echo "  Removing Claude Code statusline…"

# Remove installed binaries/scripts
for f in statusline.sh statusline-go; do
  [[ -f "$CLAUDE_DIR/$f" ]] && rm "$CLAUDE_DIR/$f" && echo "  ✓ Removed ~/.claude/$f"
done

# Remove statusLine key from settings.json
if [[ -f "$SETTINGS" ]]; then
  jq 'del(.statusLine)' "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
  echo "  ✓ Removed statusLine from ~/.claude/settings.json"
fi

# Optionally remove session-tracker data
echo ""
read -rp "  Remove session-tracker data (~/.claude/session-tracker/)? [y/N] " ans
if [[ "${ans,,}" == "y" ]]; then
  rm -rf "$CLAUDE_DIR/session-tracker"
  echo "  ✓ Removed ~/.claude/session-tracker/"
fi

echo ""
echo "  Done. Restart Claude Code to apply."
echo ""
