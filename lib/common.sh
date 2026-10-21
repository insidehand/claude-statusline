#!/usr/bin/env bash
# claude-statusline/lib/common.sh
# Shared helpers for install.sh / uninstall.sh. Sourced, not executed.
# Keep this bash 3.2 compatible (macOS /bin/bash).

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLAUDE_DIR="$HOME/.claude"
SETTINGS="$CLAUDE_DIR/settings.json"
MODS_DIR="$CLAUDE_DIR/mods"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)-$$"  # pid keeps same-second runs apart

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()    { echo -e "${GREEN}✓${NC} $*"; }
warn()    { echo -e "${YELLOW}⚠${NC}  $*"; }
err()     { echo -e "${RED}✗${NC} $*" >&2; }

require_jq() {
  if ! command -v jq &>/dev/null; then
    err "jq is required. Install with: brew install jq"
    exit 1
  fi
}

# Print the names of all mods in the repo (one per line)
list_mods() {
  local d
  for d in "$REPO_DIR"/mods/*/; do
    [[ -f "$d/.claude-plugin/plugin.json" ]] && basename "$d"
  done
}

require_mod() {
  if [[ -z "${1:-}" ]]; then
    err "Missing mod name. Available mods:"
    list_mods | sed 's/^/    /' >&2
    exit 1
  fi
  if [[ ! -f "$REPO_DIR/mods/$1/.claude-plugin/plugin.json" ]]; then
    err "Unknown mod: $1. Available mods:"
    list_mods | sed 's/^/    /' >&2
    exit 1
  fi
}

# ── settings.json ─────────────────────────────────────────────────────────────

SETTINGS_BACKED_UP=0

# settings_apply <jq filter> [jq args...]
# Applies the filter to settings.json. Writes only when the result differs,
# backs the file up (once per run) before the first write, and replaces it
# atomically via tmp + mv. Other keys are left untouched by the filters below.
settings_apply() {
  local filter="$1"; shift
  mkdir -p "$CLAUDE_DIR"
  [[ -f "$SETTINGS" ]] || echo '{}' > "$SETTINGS"

  local before after
  before=$(jq . "$SETTINGS")
  after=$(jq "$@" "$filter" "$SETTINGS")
  [[ "$before" == "$after" ]] && return 0

  if [[ $SETTINGS_BACKED_UP -eq 0 ]]; then
    cp "$SETTINGS" "$SETTINGS.bak.$TIMESTAMP"
    info "Backed up: ~/.claude/settings.json.bak.$TIMESTAMP"
    SETTINGS_BACKED_UP=1
  fi
  printf '%s\n' "$after" > "$SETTINGS.tmp"
  mv "$SETTINGS.tmp" "$SETTINGS"
}

# CLAUDE_CODE_PLUGIN_DIRS is a ":"-separated list. Entries are compared with
# "~" expanded to $HOME, and duplicates are dropped (first one wins).
JQ_PLUGIN_DIRS_DEFS='
  def norm: if startswith("~/") then $home + .[1:] else . end;
  def dirs: (.env.CLAUDE_CODE_PLUGIN_DIRS // "") | split(":") | map(select(length > 0));
  def dedupe: reduce .[] as $d ([]; if any(.[]; norm == ($d | norm)) then . else . + [$d] end);
'

plugin_dirs_add() {
  settings_apply "$JQ_PLUGIN_DIRS_DEFS
    .env.CLAUDE_CODE_PLUGIN_DIRS = ((dirs + [\$path]) | dedupe | join(\":\"))
  " --arg home "$HOME" --arg path "$1"
}

plugin_dirs_remove() {
  settings_apply "$JQ_PLUGIN_DIRS_DEFS
    (dirs | map(select(norm != (\$path | norm))) | dedupe) as \$left
    | if (\$left | length) == 0 then del(.env.CLAUDE_CODE_PLUGIN_DIRS)
      else .env.CLAUDE_CODE_PLUGIN_DIRS = (\$left | join(\":\")) end
  " --arg home "$HOME" --arg path "$1"
}

# env_add_missing <json object> — adds each key to .env only if not already set
env_add_missing() {
  settings_apply '
    reduce ($decl | to_entries[]) as $kv (.;
      if (.env // {}) | has($kv.key) then . else .env[$kv.key] = $kv.value end)
  ' --argjson decl "$1"
}

# ── files ─────────────────────────────────────────────────────────────────────

# link_into <source> <target>
# Points target at source with a symlink. An existing symlink is replaced;
# anything else at target is moved to <target>.bak.<timestamp>, never deleted.
link_into() {
  local src="$1" dst="$2"
  mkdir -p "$(dirname "$dst")"
  if [[ -L "$dst" ]]; then
    if [[ "$(readlink "$dst")" == "$src" ]]; then
      return 0
    fi
    rm "$dst"
  elif [[ -e "$dst" ]]; then
    mv "$dst" "$dst.bak.$TIMESTAMP"
    warn "Existing $dst moved to $dst.bak.$TIMESTAMP"
  fi
  ln -s "$src" "$dst"
}
