#!/usr/bin/env bash
# claude-statusline/build.sh
# Compile the Go version and copy to ~/.claude/statusline-go
# Run this after editing statusline/statusline.go to apply changes.
# Alias for: ./install.sh statusline --go

set -euo pipefail

exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/install.sh" statusline --go
