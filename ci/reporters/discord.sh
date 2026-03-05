#!/usr/bin/env bash
# =============================================================================
# discord.sh — Discord webhook notifications with embeds
# =============================================================================
# Usage: ./discord.sh <status> <branch> <sha> <run_id> [summary_file]
#   status: pass | fail | error | preempted | regression
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
load_config 2>/dev/null || true

# Arguments
STATUS="${1:?Usage: $0 <status> <branch> <sha> <run_id> [summary_file]}"
BRANCH="${2:?Missing branch}"
SHA="${3:?Missing sha}"
RUN_ID="${4:?Missing run_id}"
SUMMARY_FILE="${5:-}"

# Status → color + emoji mapping
case "${STATUS}" in
    pass|success) COLOR=3066993;  EMOJI="✅"; TITLE="CI Passed" ;;
    fail|failure) COLOR=15158332; EMOJI="❌"; TITLE="CI Failed" ;;
    error)        COLOR=16744192; EMOJI="⚠️";  TITLE="CI Error" ;;
    preempted)    COLOR=10181046; EMOJI="🔄"; TITLE="CI Preempted" ;;
    regression)   COLOR=16776960; EMOJI="📉"; TITLE="Performance Regression" ;;
    *)            COLOR=9807270;  EMOJI="❓"; TITLE="CI: ${STATUS}" ;;
esac

# Build description
SHORT_SHA="${SHA:0:7}"
DESCRIPTION="**Branch:** \`${BRANCH}\`\n**Commit:** \`${SHORT_SHA}\`\n**Run:** \`${RUN_ID}\`"

# Append summary if provided
if [[ -n "${SUMMARY_FILE}" && -f "${SUMMARY_FILE}" ]]; then
    SUMMARY_CONTENT=$(cat "${SUMMARY_FILE}")
    DESCRIPTION="${DESCRIPTION}\n\n\`\`\`\n${SUMMARY_CONTENT}\n\`\`\`"
fi

# Append mention on failure
if [[ "${STATUS}" == "fail" || "${STATUS}" == "failure" || "${STATUS}" == "error" ]] && [[ -n "${DISCORD_MENTION_ON_FAIL:-}" ]]; then
    DESCRIPTION="${DESCRIPTION}\n\n${DISCORD_MENTION_ON_FAIL}"
fi

# JSON escaping
ESCAPED_TITLE=$(json_escape "${EMOJI} ${TITLE}")
ESCAPED_DESC=$(json_escape "${DESCRIPTION}")

# Truncate to stay under Discord 4096 char limit
MAX_DESC_LEN=3800
if [[ ${#ESCAPED_DESC} -gt ${MAX_DESC_LEN} ]]; then
    ESCAPED_DESC="${ESCAPED_DESC:0:${MAX_DESC_LEN}}\\n\\n... (truncated)"
fi

# Build JSON payload
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
PAYLOAD=$(cat <<ENDJSON
{
  "embeds": [{
    "title": "${ESCAPED_TITLE}",
    "description": "${ESCAPED_DESC}",
    "color": ${COLOR},
    "timestamp": "${TIMESTAMP}",
    "footer": {"text": "torchtitan CI | ${SLURM_JOB_PREFIX:-ci-torchtitan}"}
  }]
}
ENDJSON
)

# Send notification
if [[ -z "${DISCORD_WEBHOOK_URL:-}" ]]; then
    log_debug "No DISCORD_WEBHOOK_URL set. Payload:"
    log_debug "${PAYLOAD}"
    exit 0
fi

MAX_RETRIES=3
RETRY_DELAY=5

for attempt in $(seq 1 ${MAX_RETRIES}); do
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
        -H "Content-Type: application/json" \
        -d "${PAYLOAD}" \
        "${DISCORD_WEBHOOK_URL}" 2>/dev/null) || HTTP_CODE=000

    if [[ "${HTTP_CODE}" == "204" || "${HTTP_CODE}" == "200" ]]; then
        log_info "Discord notification sent (${STATUS})"
        exit 0
    elif [[ "${HTTP_CODE}" == "429" ]]; then
        log_warn "Rate limited (attempt ${attempt}/${MAX_RETRIES}), waiting ${RETRY_DELAY}s..."
        sleep ${RETRY_DELAY}
        RETRY_DELAY=$((RETRY_DELAY * 2))
    else
        log_warn "HTTP ${HTTP_CODE} on attempt ${attempt}/${MAX_RETRIES}"
        if [[ ${attempt} -lt ${MAX_RETRIES} ]]; then
            sleep ${RETRY_DELAY}
            RETRY_DELAY=$((RETRY_DELAY * 2))
        fi
    fi
done

log_error "Failed to send Discord notification after ${MAX_RETRIES} attempts"
exit 1
