#!/usr/bin/env bash
# claude-statusline/build.sh
# Compile the Go version and copy to ~/.claude/statusline-go
# Run this after editing statusline.go to apply changes.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$HOME/.claude/statusline-go"

if ! command -v go &>/dev/null; then
  echo "Go not found. Install from https://go.dev/dl/"
  exit 1
fi

echo "Building…"
go build -o "$OUT" "$REPO_DIR/statusline.go"
chmod +x "$OUT"
echo "✓ Built: $OUT"
