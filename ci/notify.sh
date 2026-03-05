#!/usr/bin/env bash
# Discord webhook notification for CI results
# Usage: ./notify.sh <status> <branch> <sha> <run_id> [summary_file]
#   status: success | failure | error | preempted
#   branch: git branch name
#   sha: commit SHA (short or full)
#   run_id: CI run identifier
#   summary_file: optional path to summary file to include in message

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env"

# ============================================================================
# Arguments
# ============================================================================
STATUS="${1:?Usage: $0 <status> <branch> <sha> <run_id> [summary_file]}"
BRANCH="${2:?Missing branch}"
SHA="${3:?Missing sha}"
RUN_ID="${4:?Missing run_id}"
SUMMARY_FILE="${5:-}"

# ============================================================================
# Status → color + emoji mapping
# ============================================================================
case "${STATUS}" in
    success)   COLOR=3066993;  EMOJI="✅"; TITLE="CI Passed" ;;
    failure)   COLOR=15158332; EMOJI="❌"; TITLE="CI Failed" ;;
    error)     COLOR=16744192; EMOJI="⚠️";  TITLE="CI Error" ;;
    preempted) COLOR=10181046; EMOJI="🔄"; TITLE="CI Preempted" ;;
    *)         COLOR=9807270;  EMOJI="❓"; TITLE="CI Unknown: ${STATUS}" ;;
esac

# ============================================================================
# Build description
# ============================================================================
SHORT_SHA="${SHA:0:7}"
DESCRIPTION="**Branch:** \`${BRANCH}\`\n**Commit:** \`${SHORT_SHA}\`\n**Run:** \`${RUN_ID}\`"

# Append summary if provided
if [[ -n "${SUMMARY_FILE}" && -f "${SUMMARY_FILE}" ]]; then
    SUMMARY_CONTENT=$(cat "${SUMMARY_FILE}")
    DESCRIPTION="${DESCRIPTION}\n\n\`\`\`\n${SUMMARY_CONTENT}\n\`\`\`"
fi

# Append mention on failure
if [[ "${STATUS}" == "failure" || "${STATUS}" == "error" ]] && [[ -n "${DISCORD_MENTION_ON_FAIL}" ]]; then
    DESCRIPTION="${DESCRIPTION}\n\n${DISCORD_MENTION_ON_FAIL}"
fi

# ============================================================================
# JSON escaping (no jq dependency)
# ============================================================================
json_escape() {
    local s="$1"
    # Escape backslashes first, then other special chars
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/}"
    s="${s//$'\t'/\\t}"
    echo -n "$s"
}

ESCAPED_TITLE=$(json_escape "${EMOJI} ${TITLE}")
ESCAPED_DESC=$(json_escape "${DESCRIPTION}")

# Truncate description to stay under Discord's 4096 char embed limit
MAX_DESC_LEN=3800
if [[ ${#ESCAPED_DESC} -gt ${MAX_DESC_LEN} ]]; then
    ESCAPED_DESC="${ESCAPED_DESC:0:${MAX_DESC_LEN}}\\n\\n... (truncated)"
fi

# ============================================================================
# Build JSON payload
# ============================================================================
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
PAYLOAD=$(cat <<ENDJSON
{
  "embeds": [{
    "title": "${ESCAPED_TITLE}",
    "description": "${ESCAPED_DESC}",
    "color": ${COLOR},
    "timestamp": "${TIMESTAMP}",
    "footer": {"text": "torchtitan CI | ${SLURM_JOB_NAME}"}
  }]
}
ENDJSON
)

# ============================================================================
# Send notification
# ============================================================================
if [[ -z "${DISCORD_WEBHOOK_URL}" ]]; then
    echo "[notify] No DISCORD_WEBHOOK_URL set. Payload would be:"
    echo "${PAYLOAD}"
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
        echo "[notify] Discord notification sent (${STATUS})"
        exit 0
    elif [[ "${HTTP_CODE}" == "429" ]]; then
        echo "[notify] Rate limited (attempt ${attempt}/${MAX_RETRIES}), waiting ${RETRY_DELAY}s..."
        sleep ${RETRY_DELAY}
        RETRY_DELAY=$((RETRY_DELAY * 2))
    else
        echo "[notify] HTTP ${HTTP_CODE} on attempt ${attempt}/${MAX_RETRIES}"
        if [[ ${attempt} -lt ${MAX_RETRIES} ]]; then
            sleep ${RETRY_DELAY}
        fi
    fi
done

echo "[notify] Failed to send after ${MAX_RETRIES} attempts. Payload:"
echo "${PAYLOAD}"
exit 1
