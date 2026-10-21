#!/usr/bin/env bash
# claude-statusline/statusline.sh
# Bash version (fallback / no-build-required)
# For the faster Go version, run: ./install.sh --go

set -euo pipefail

input=$(cat)
NOW=$(date +%s)

# ── Directories ───────────────────────────────────────────────────────────────
CACHE_DIR="$HOME/.claude/statusline-cache"
TRACKER_DIR="$HOME/.claude/session-tracker"
SESSIONS_DIR="$TRACKER_DIR/sessions"
mkdir -p "$CACHE_DIR" "$SESSIONS_DIR"

# ── Parse JSON ────────────────────────────────────────────────────────────────
MODEL=$(echo "$input" | jq -r '.model.display_name // "unknown"')
SESSION_ID=$(echo "$input" | jq -r '.session_id // ""')
CURRENT_DIR=$(echo "$input" | jq -r '.workspace.current_dir // ""')
TRANSCRIPT_PATH=$(echo "$input" | jq -r '.transcript_path // ""')

FH_USED=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // 0' | cut -d'.' -f1)
FH_RESETS=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // 0')
SD_USED=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // 0' | cut -d'.' -f1)
SD_RESETS=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // 0')

PROJECT_NAME=$(basename "$CURRENT_DIR")

# ── Colors ────────────────────────────────────────────────────────────────────
RESET='\033[0m'
GRAY='\033[38;2;64;64;64m'
MSG_COLOR='\033[38;2;152;195;121m'

CTX_GREEN='\033[38;2;108;167;108m'
CTX_GOLD='\033[38;2;188;155;83m'
CTX_ORANGE='\033[38;2;210;120;60m'
CTX_RED='\033[38;2;185;102;82m'

case "$MODEL" in
  *Opus*)   MODEL_COLOR='\033[38;2;195;158;83m';  MODEL_ICON="💛" ;;
  *Sonnet*) MODEL_COLOR='\033[38;2;118;170;185m'; MODEL_ICON="💠" ;;
  *Haiku*)  MODEL_COLOR='\033[38;2;255;182;193m'; MODEL_ICON="🌸" ;;
  *)        MODEL_COLOR='\033[38;2;192;192;192m'; MODEL_ICON="🤖" ;;
esac

# ── Color helpers ─────────────────────────────────────────────────────────────

# Linear green→red based on usage percentage (0–100)
used_pct_color() {
  local pct=$1
  if   [[ $pct -le 25 ]]; then printf '%b' "$CTX_GREEN"
  elif [[ $pct -le 50 ]]; then printf '%b' "$CTX_GOLD"
  elif [[ $pct -le 75 ]]; then printf '%b' "$CTX_ORANGE"
  else                          printf '%b' "$CTX_RED"
  fi
}

# Waste urgency: score = (100 - used%) × (elapsed / total_window)
# High score = used little but window almost over → red warning
waste_urgency_color() {
  local used_pct=$1 resets_at=$2 total_secs=$3
  local remaining=$(( resets_at - NOW ))
  if [[ $remaining -le 0 || $total_secs -le 0 ]]; then
    printf '%b' "$GRAY"; return
  fi
  local elapsed=$(( total_secs - remaining ))
  [[ $elapsed -lt 0 ]] && elapsed=0
  local urgency=$(( elapsed * 100 / total_secs ))
  local waste=$(( 100 - used_pct ))
  local score=$(( waste * urgency / 100 ))
  if   [[ $score -le 20 ]]; then printf '%b' "$CTX_GREEN"
  elif [[ $score -le 50 ]]; then printf '%b' "$CTX_GOLD"
  elif [[ $score -le 70 ]]; then printf '%b' "$CTX_ORANGE"
  else                           printf '%b' "$CTX_RED"
  fi
}

# Format seconds into human duration: 2d15h / 3h20m / 45m
format_reset() {
  local secs=$1
  local days=$(( secs / 86400 ))
  local hours=$(( (secs % 86400) / 3600 ))
  local mins=$(( (secs % 3600) / 60 ))
  if   [[ $days -gt 0 && $hours -gt 0 ]]; then echo "${days}d${hours}h"
  elif [[ $days -gt 0 ]];                 then echo "${days}d"
  elif [[ $hours -gt 0 && $mins -gt 0 ]]; then echo "${hours}h${mins}m"
  elif [[ $hours -gt 0 ]];                then echo "${hours}h"
  else                                         echo "${mins}m"
  fi
}

# ── Git branch (5s cache) ─────────────────────────────────────────────────────
GIT_CACHE="$CACHE_DIR/git_branch"
BRANCH=""
if git -C "$CURRENT_DIR" rev-parse --git-dir &>/dev/null 2>&1; then
  USE_CACHE=0
  if [[ -f "$GIT_CACHE" ]]; then
    CACHE_MTIME=$(stat -f %m "$GIT_CACHE" 2>/dev/null || stat -c %Y "$GIT_CACHE" 2>/dev/null)
    [[ $(( NOW - CACHE_MTIME )) -lt 5 ]] && USE_CACHE=1
  fi

  if [[ $USE_CACHE -eq 1 ]]; then
    BRANCH=$(cat "$GIT_CACHE")
  else
    BRANCH_NAME=$(git -C "$CURRENT_DIR" --no-optional-locks branch --show-current 2>/dev/null || true)
    if [[ -n "$BRANCH_NAME" ]]; then
      case "$BRANCH_NAME" in
        main|master)          BRANCH_ICON="🌳" ;;
        feature/*|feat/*)     BRANCH_ICON="🌿" ;;
        fix/*|bugfix/*|bug/*) BRANCH_ICON="🔧" ;;
        hotfix/*)             BRANCH_ICON="🚨" ;;
        release/*)            BRANCH_ICON="🚀" ;;
        chore/*)              BRANCH_ICON="🧹" ;;
        docs/*)               BRANCH_ICON="📝" ;;
        test/*)               BRANCH_ICON="🧪" ;;
        refactor/*)           BRANCH_ICON="♻️"  ;;
        *)                    BRANCH_ICON="🪾" ;;
      esac
      BRANCH=" $BRANCH_ICON $BRANCH_NAME"
    fi
    echo "$BRANCH" > "$GIT_CACHE"
  fi
fi

# ── Session tracker ───────────────────────────────────────────────────────────
TODAY=$(date +%Y-%m-%d)
SESSION_FILE="$SESSIONS_DIR/$SESSION_ID.json"

if [[ ! -f "$SESSION_FILE" ]]; then
  cat > "$SESSION_FILE" <<EOF
{"id":"$SESSION_ID","date":"$TODAY","start":$NOW,"last_heartbeat":$NOW,"total_seconds":0,"intervals":[{"start":$NOW,"end":null}]}
EOF
else
  jq --argjson now "$NOW" '
    ($now - .last_heartbeat) as $gap |
    .last_heartbeat = $now |
    if $gap < 600
      then .intervals[-1].end = $now
      else .intervals += [{"start": $now, "end": $now}]
    end |
    .total_seconds = ([.intervals[] | if .end != null then (.end - .start) else 0 end] | add // 0)
  ' "$SESSION_FILE" > "$SESSION_FILE.tmp" && mv "$SESSION_FILE.tmp" "$SESSION_FILE"
fi

# Total time today
TOTAL_SECS=0
ACTIVE=0
while IFS= read -r -d '' f; do
  DATA=$(jq -r '[.date // "", .total_seconds // 0, .last_heartbeat // 0] | @tsv' "$f" 2>/dev/null) || continue
  IFS=$'\t' read -r s_date s_secs s_hb <<< "$DATA"
  [[ "$s_date" != "$TODAY" ]] && continue
  TOTAL_SECS=$(( TOTAL_SECS + s_secs ))
  [[ $(( NOW - s_hb )) -lt 600 ]] && ACTIVE=$(( ACTIVE + 1 ))
done < <(find "$SESSIONS_DIR" -name "*.json" -print0 2>/dev/null)

HOURS=$(( TOTAL_SECS / 3600 ))
MINS=$(( (TOTAL_SECS % 3600) / 60 ))
if [[ $HOURS -gt 0 ]]; then
  TIME_STR="${HOURS}h${MINS}m"
else
  TIME_STR="${MINS}m"
fi
LIVE_STR=""
[[ $ACTIVE -gt 1 ]] && LIVE_STR=" $(printf '%b' "$GRAY")[${ACTIVE}×]$(printf '%b' "$RESET")"

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
    CTX_PCT=$(( CTX_TOKENS * 100 / 160000 ))
    [[ $CTX_PCT -gt 100 ]] && CTX_PCT=100

    BAR_W=10
    FILLED=$(( CTX_PCT * BAR_W / 100 ))
    EMPTY=$(( BAR_W - FILLED ))

    if   [[ $CTX_PCT -lt 60 ]]; then CTX_COLOR="$CTX_GREEN"
    elif [[ $CTX_PCT -lt 80 ]]; then CTX_COLOR="$CTX_GOLD"
    else                              CTX_COLOR="$CTX_RED"
    fi

    BAR="$(printf '%b' "$CTX_COLOR")"
    for ((i=0; i<FILLED; i++)); do BAR="${BAR}█"; done
    BAR="${BAR}$(printf '%b' "$GRAY")"
    for ((i=0; i<EMPTY; i++)); do BAR="${BAR}░"; done
    BAR="${BAR}$(printf '%b' "$RESET")"

    if   [[ $CTX_TOKENS -ge 1000000 ]]; then CTX_LABEL="$((CTX_TOKENS / 1000000))M"
    elif [[ $CTX_TOKENS -ge 1000 ]];    then CTX_LABEL="$((CTX_TOKENS / 1000))k"
    else                                     CTX_LABEL="${CTX_TOKENS}"
    fi

    CTX_DISPLAY=" | ${BAR} $(printf '%b' "$CTX_COLOR")${CTX_PCT}% ${CTX_LABEL}$(printf '%b' "$RESET")"
  fi
fi

# ── Rate limits ───────────────────────────────────────────────────────────────
RATE_STR=""
if [[ $FH_USED -gt 0 || $SD_USED -gt 0 ]]; then
  FH_PCT_COLOR=$(used_pct_color "$FH_USED")
  SD_PCT_COLOR=$(used_pct_color "$SD_USED")

  FH_RESET_STR=""
  if [[ $FH_RESETS -gt 0 ]]; then
    FH_REMAINING=$(( FH_RESETS - NOW ))
    if [[ $FH_REMAINING -gt 0 ]]; then
      FH_TIME=$(format_reset "$FH_REMAINING")
      FH_TIME_COLOR=$(waste_urgency_color "$FH_USED" "$FH_RESETS" $(( 5 * 3600 )))
      FH_RESET_STR=" | ${FH_TIME_COLOR}${FH_TIME}$(printf '%b' "$RESET")"
    fi
  fi

  SD_RESET_STR=""
  if [[ $SD_RESETS -gt 0 ]]; then
    SD_REMAINING=$(( SD_RESETS - NOW ))
    if [[ $SD_REMAINING -gt 0 ]]; then
      SD_TIME=$(format_reset "$SD_REMAINING")
      SD_TIME_COLOR=$(waste_urgency_color "$SD_USED" "$SD_RESETS" $(( 7 * 24 * 3600 )))
      SD_RESET_STR=" | ${SD_TIME_COLOR}${SD_TIME}$(printf '%b' "$RESET")"
    fi
  fi

  RATE_STR="5h: ${FH_PCT_COLOR}${FH_USED}%$(printf '%b' "$RESET")${FH_RESET_STR} | 7d: ${SD_PCT_COLOR}${SD_USED}%$(printf '%b' "$RESET")${SD_RESET_STR} | "
fi

# ── Last user message ─────────────────────────────────────────────────────────
USER_MSG_LINE=""
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
    FIRST_LINE=$(echo "$LAST_MSG" | head -1)
    TOTAL_LINES=$(echo "$LAST_MSG" | wc -l | tr -d ' ')
    [[ ${#FIRST_LINE} -gt 80 ]] && FIRST_LINE="${FIRST_LINE:0:77}..."
    SUFFIX=""
    [[ $TOTAL_LINES -gt 1 ]] && SUFFIX=" $(printf '%b' "$GRAY")(+$(( TOTAL_LINES - 1 )) lines)$(printf '%b' "$RESET")"
    USER_MSG_LINE="$(printf '%b' "$RESET")> $(printf '%b' "$MSG_COLOR")${FIRST_LINE}$(printf '%b' "$RESET")${SUFFIX}"
  fi
fi

# ── Output ────────────────────────────────────────────────────────────────────
# Line 1: model | project | branch | context
printf "${RESET}[${MODEL_COLOR}${MODEL_ICON} %s${RESET}] 📂 %s%s%s\n" \
  "$MODEL" "$PROJECT_NAME" "$BRANCH" "$CTX_DISPLAY"

# Line 2: rate limits | today usage time | live sessions
printf "${RESET}! %s%s%s\n" "$RATE_STR" "$TIME_STR" "$LIVE_STR"

# Line 3: last user message
[[ -n "$USER_MSG_LINE" ]] && printf "%s\n" "$USER_MSG_LINE"

exit 0
