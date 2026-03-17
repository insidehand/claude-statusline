#!/usr/bin/env bash
# claude-statusline/statusline.sh
# Bash version (fallback / no-build-required)
# For the faster Go version, run: ./build.sh

set -euo pipefail

input=$(cat)

# ── Directories ──────────────────────────────────────────────────────────────
CACHE_DIR="$HOME/.claude/statusline-cache"
TRACKER_DIR="$HOME/.claude/session-tracker"
SESSIONS_DIR="$TRACKER_DIR/sessions"
mkdir -p "$CACHE_DIR" "$SESSIONS_DIR"

# ── Parse JSON ───────────────────────────────────────────────────────────────
MODEL=$(echo "$input" | jq -r '.model.display_name // "unknown"')
SESSION_ID=$(echo "$input" | jq -r '.session_id // ""')
CURRENT_DIR=$(echo "$input" | jq -r '.workspace.current_dir // ""')
TRANSCRIPT_PATH=$(echo "$input" | jq -r '.transcript_path // ""')

PROJECT_NAME=$(basename "$CURRENT_DIR")

# ── Colors ────────────────────────────────────────────────────────────────────
RESET='\033[0m'
GRAY='\033[38;2;64;64;64m'
MSG_COLOR='\033[38;2;152;195;121m'  # onedark green

case "$MODEL" in
  *Opus*)   MODEL_COLOR='\033[38;2;195;158;83m';  MODEL_ICON="💛" ;;
  *Sonnet*) MODEL_COLOR='\033[38;2;118;170;185m'; MODEL_ICON="💠" ;;
  *Haiku*)  MODEL_COLOR='\033[38;2;255;182;193m'; MODEL_ICON="🌸" ;;
  *)        MODEL_COLOR='\033[38;2;192;192;192m'; MODEL_ICON="🤖" ;;
esac

# ── Git branch (5s cache) ─────────────────────────────────────────────────────
GIT_CACHE="$CACHE_DIR/git_branch"
BRANCH=""
if git -C "$CURRENT_DIR" rev-parse --git-dir &>/dev/null 2>&1; then
  NOW=$(date +%s)
  USE_CACHE=0
  if [[ -f "$GIT_CACHE" ]]; then
    CACHE_MTIME=$(stat -f %m "$GIT_CACHE" 2>/dev/null || stat -c %Y "$GIT_CACHE" 2>/dev/null)
    [[ $((NOW - CACHE_MTIME)) -lt 5 ]] && USE_CACHE=1
  fi

  if [[ $USE_CACHE -eq 1 ]]; then
    BRANCH=$(cat "$GIT_CACHE")
  else
    BRANCH_NAME=$(git -C "$CURRENT_DIR" --no-optional-locks branch --show-current 2>/dev/null || true)
    [[ -n "$BRANCH_NAME" ]] && BRANCH=" ⚡ $BRANCH_NAME"
    echo "$BRANCH" > "$GIT_CACHE"
  fi
fi

# ── Session tracker ───────────────────────────────────────────────────────────
CURRENT_TIME=$(date +%s)
TODAY=$(date +%Y-%m-%d)
SESSION_FILE="$SESSIONS_DIR/$SESSION_ID.json"

if [[ ! -f "$SESSION_FILE" ]]; then
  cat > "$SESSION_FILE" <<EOF
{"id":"$SESSION_ID","date":"$TODAY","start":$CURRENT_TIME,"last_heartbeat":$CURRENT_TIME,"total_seconds":0,"intervals":[{"start":$CURRENT_TIME,"end":null}]}
EOF
else
  jq --argjson now "$CURRENT_TIME" '
    ($now - .last_heartbeat) as $gap |
    .last_heartbeat = $now |
    if $gap < 600
      then .intervals[-1].end = $now
      else .intervals += [{"start": $now, "end": $now}]
    end |
    .total_seconds = ([.intervals[] | if .end != null then (.end - .start) else 0 end] | add // 0)
  ' "$SESSION_FILE" > "$SESSION_FILE.tmp" && mv "$SESSION_FILE.tmp" "$SESSION_FILE"
fi

# Total hours today
TOTAL_SECS=0
ACTIVE=0
while IFS= read -r -d '' f; do
  DATA=$(jq -r '[.date // "", .total_seconds // 0, .last_heartbeat // 0] | @tsv' "$f" 2>/dev/null) || continue
  IFS=$'\t' read -r s_date s_secs s_hb <<< "$DATA"
  [[ "$s_date" != "$TODAY" ]] && continue
  TOTAL_SECS=$((TOTAL_SECS + s_secs))
  [[ $((CURRENT_TIME - s_hb)) -lt 600 ]] && ACTIVE=$((ACTIVE + 1))
done < <(find "$SESSIONS_DIR" -name "*.json" -print0 2>/dev/null)

HOURS=$((TOTAL_SECS / 3600))
MINS=$(( (TOTAL_SECS % 3600) / 60 ))
if [[ $HOURS -gt 0 ]]; then
  TIME_STR="${HOURS}h${MINS}m"
else
  TIME_STR="${MINS}m"
fi
[[ $ACTIVE -gt 1 ]] && TIME_STR="$TIME_STR [${ACTIVE}×]"

# ── Context usage ─────────────────────────────────────────────────────────────
CTX_DISPLAY=""
if [[ -n "$TRANSCRIPT_PATH" && "$TRANSCRIPT_PATH" != "null" && -f "$TRANSCRIPT_PATH" ]]; then
  CTX_TOKENS=$(tail -100 "$TRANSCRIPT_PATH" 2>/dev/null | awk '
    /isSidechain.*false|"isSidechain":false/ && /"usage":/ {
      input=0; cr=0; cc=0
      if (match($0, /"input_tokens":([0-9]+)/, a)) input=a[1]+0
      if (match($0, /"cache_read_input_tokens":([0-9]+)/, a)) cr=a[1]+0
      if (match($0, /"cache_creation_input_tokens":([0-9]+)/, a)) cc=a[1]+0
      total = input + cr + cc
      if (total > 0) { print total; exit }
    }
  ')

  if [[ -n "$CTX_TOKENS" && "$CTX_TOKENS" -gt 0 ]]; then
    # autocompact kicks in at ~80% → effective ceiling is 160k of 200k
    CTX_PCT=$((CTX_TOKENS * 100 / 160000))
    [[ $CTX_PCT -gt 100 ]] && CTX_PCT=100

    BAR_W=10
    FILLED=$((CTX_PCT * BAR_W / 100))
    EMPTY=$((BAR_W - FILLED))

    if [[ $CTX_PCT -lt 60 ]]; then
      CTX_COLOR='\033[38;2;108;167;108m'   # green
    elif [[ $CTX_PCT -lt 80 ]]; then
      CTX_COLOR='\033[38;2;188;155;83m'    # gold
    else
      CTX_COLOR='\033[38;2;185;102;82m'    # red
    fi

    BAR="${CTX_COLOR}"
    for ((i=0; i<FILLED; i++)); do BAR="${BAR}█"; done
    BAR="${BAR}${GRAY}"
    for ((i=0; i<EMPTY; i++)); do BAR="${BAR}░"; done
    BAR="${BAR}${RESET}"

    # Format token count
    if [[ $CTX_TOKENS -ge 1000 ]]; then
      CTX_LABEL="$((CTX_TOKENS / 1000))k"
    else
      CTX_LABEL="${CTX_TOKENS}"
    fi

    CTX_DISPLAY=" | ${BAR} ${CTX_COLOR}${CTX_PCT}% ${CTX_LABEL}${RESET}"
  fi
fi

# ── Last user message ─────────────────────────────────────────────────────────
USER_MSG_LINES=""
if [[ -n "$TRANSCRIPT_PATH" && "$TRANSCRIPT_PATH" != "null" && -f "$TRANSCRIPT_PATH" ]]; then
  LAST_MSG=$(tail -200 "$TRANSCRIPT_PATH" 2>/dev/null | tac | awk -v sid="$SESSION_ID" '
    /^$/ { next }
    {
      if (!match($0, /^\{.*\}$/)) next
      if (match($0, /"isSidechain":true/)) next
      if (!match($0, /"sessionId":"' "$SESSION_ID" '"/) ) next
      if (!match($0, /"role":"user"/) || !match($0, /"type":"user"/)) next
      if (match($0, /"content":"([^"]*)"/, arr)) {
        c = arr[1]
        if (c ~ /^\[/ || c ~ /^\{/ || c ~ /<(local-command|command-)/ || c ~ /^Caveat:/ || c == "") next
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", c)
        if (length(c) > 0) { print c; exit }
      }
    }
  ' 2>/dev/null || true)

  if [[ -n "$LAST_MSG" ]]; then
    MAX_LINES=3
    LINE_COUNT=0
    while IFS= read -r line && [[ $LINE_COUNT -lt $MAX_LINES ]]; do
      [[ ${#line} -gt 80 ]] && line="${line:0:77}..."
      USER_MSG_LINES+="$(printf "${RESET}｜${MSG_COLOR}%s${RESET}" "$line")\n"
      LINE_COUNT=$((LINE_COUNT + 1))
    done <<< "$LAST_MSG"
  fi
fi

# ── Output ────────────────────────────────────────────────────────────────────
# Line 1: model | project | branch | context | time
printf "${RESET}[${MODEL_COLOR}${MODEL_ICON} %s${RESET}] 📂 %s%s%s | %s\n" \
  "$MODEL" "$PROJECT_NAME" "$BRANCH" "$CTX_DISPLAY" "$TIME_STR"

# Line 2+: last user message (optional)
[[ -n "$USER_MSG_LINES" ]] && printf "$USER_MSG_LINES"

exit 0
