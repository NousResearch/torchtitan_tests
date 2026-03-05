#!/usr/bin/env bash
# =============================================================================
# watchdog.sh — Autonomous CI daemon
# =============================================================================
# Runs in a loop, watching for:
#   1. New commits on the tracked branch → submit 1-node job
#   2. New/updated PRs on GitHub → submit 1-node job
#   3. 24h heartbeat — if nothing ran in 24h, force a 1-node run
#
# Usage: nohup ./watchdog.sh &
# Managed via: ttci start / ttci stop
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source "${SCRIPT_DIR}/../lib/slurm_helpers.sh"
source "${SCRIPT_DIR}/../lib/github_api.sh"
load_config

ensure_dir "${CI_LOG_DIR}" "${CI_STATE_DIR}" "${CI_DATA_DIR}"

# --- Config ---
POLL_INTERVAL="${WATCHDOG_POLL_INTERVAL:-300}"   # seconds between checks (default 5 min)
HEARTBEAT_SEC="${WATCHDOG_HEARTBEAT_SEC:-86400}"  # force run after this many seconds (default 24h)
PID_FILE="${CI_STATE_DIR}/watchdog.pid"
LOG_FILE="${CI_LOG_DIR}/watchdog.log"
LAST_RUN_FILE="${CI_STATE_DIR}/.last_run_timestamp"

# --- Logging to file ---
exec >> "${LOG_FILE}" 2>&1

# --- PID management ---
if [[ -f "$PID_FILE" ]]; then
    OLD_PID=$(cat "$PID_FILE")
    if kill -0 "$OLD_PID" 2>/dev/null; then
        log_error "Watchdog already running (PID $OLD_PID). Exiting."
        exit 1
    fi
    rm -f "$PID_FILE"
fi
echo $$ > "$PID_FILE"

cleanup() {
    rm -f "$PID_FILE"
    log_info "Watchdog stopped (PID $$)"
}
trap cleanup EXIT
trap 'exit 0' SIGTERM SIGINT

log_info "=========================================="
log_info "Watchdog started (PID $$)"
log_info "  Branch:     ${GIT_BRANCH}"
log_info "  Repo:       ${GITHUB_API_REPO}"
log_info "  Poll:       every ${POLL_INTERVAL}s"
log_info "  Heartbeat:  every ${HEARTBEAT_SEC}s ($(( HEARTBEAT_SEC / 3600 ))h)"
log_info "=========================================="

# --- Helpers ---

record_run_time() {
    date +%s > "$LAST_RUN_FILE"
}

seconds_since_last_run() {
    if [[ ! -f "$LAST_RUN_FILE" ]]; then
        echo "999999"
        return
    fi
    local last
    last=$(cat "$LAST_RUN_FILE")
    local now
    now=$(date +%s)
    echo $(( now - last ))
}

submit_1node_job() {
    local sha="$1"
    local trigger="$2"
    local pr_number="${3:-}"

    local run_id
    run_id=$(generate_run_id)
    local run_log_dir="${CI_LOG_DIR}/${run_id}"
    ensure_dir "$run_log_dir"

    local job_name="${SLURM_JOB_PREFIX}-1n"
    local export_vars="ALL,CI_DIR=${CI_DIR},CI_COMMIT_SHA=${sha},CI_RUN_ID=${run_id},CI_RUN_LOG_DIR=${run_log_dir},CI_TRIGGER=${trigger}"
    [[ -n "$pr_number" ]] && export_vars="${export_vars},CI_PR_NUMBER=${pr_number}"

    local job_id
    job_id=$(submit_job "${SCRIPT_DIR}/../jobs/run_tests_1node.slurm" \
        --job-name="${job_name}" \
        --partition="${SLURM_PARTITION}" \
        --nodes="${SLURM_1N_NODES}" \
        --gpus-per-node="${SLURM_1N_GPUS}" \
        --cpus-per-task="${SLURM_1N_CPUS}" \
        --time="${SLURM_1N_TIME}" \
        --output="${run_log_dir}/slurm-%j.out" \
        --export="${export_vars}")

    log_info "Submitted job ${job_id} [${trigger}] sha=${sha:0:7} run=${run_id}${pr_number:+ PR=#${pr_number}}"
    record_run_time
    return 0
}

ci_job_active() {
    is_job_running "${SLURM_JOB_PREFIX}-1n" || is_job_running "${SLURM_JOB_PREFIX}-2n"
}

# --- Main loop ---
while true; do
    log_debug "--- poll cycle ---"

    # Skip if a CI job is already running or queued
    if ci_job_active; then
        log_debug "CI job active, sleeping"
        sleep "$POLL_INTERVAL"
        continue
    fi

    # Check idle nodes
    IDLE=$(count_idle_nodes "${SLURM_PARTITION}" 2>/dev/null || echo "0")
    if [[ "${IDLE}" -lt "${MIN_IDLE_NODES_1N}" ]]; then
        log_debug "Not enough idle nodes (${IDLE} < ${MIN_IDLE_NODES_1N})"
        sleep "$POLL_INTERVAL"
        continue
    fi

    SUBMITTED=false

    # ----- 1. New commits -----
    cd "${TORCHTITAN_DIR}"
    if git fetch "${GIT_REMOTE}" "${GIT_BRANCH}" --quiet 2>/dev/null; then
        LATEST_SHA=$(git rev-parse "${GIT_REMOTE}/${GIT_BRANCH}" 2>/dev/null || echo "")
        LAST_TESTED_SHA=""
        [[ -f "${LAST_TESTED_SHA_FILE}" ]] && LAST_TESTED_SHA=$(cat "${LAST_TESTED_SHA_FILE}")

        if [[ -n "$LATEST_SHA" && "$LATEST_SHA" != "$LAST_TESTED_SHA" ]]; then
            log_info "New commit: ${LATEST_SHA:0:7} (was: ${LAST_TESTED_SHA:0:7})"
            if submit_1node_job "$LATEST_SHA" "commit"; then
                SUBMITTED=true
            fi
        fi
    else
        log_warn "git fetch failed"
    fi

    # ----- 2. New/updated PRs -----
    if [[ "$SUBMITTED" == "false" ]]; then
        PR_TO_TEST=$(python3 - "${CI_DATA_DIR}/pr_state.json" "${GITHUB_API_REPO}" <<'PYEOF'
import json, sys, urllib.request, os

state_file = sys.argv[1]
repo = sys.argv[2]

# Load PR state
try:
    with open(state_file) as f:
        state = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    state = {}

# Fetch open PRs
url = f"https://api.github.com/repos/{repo}/pulls?state=open&per_page=30"
headers = {"Accept": "application/vnd.github.v3+json"}
token = os.environ.get("GITHUB_TOKEN", "")
if token:
    headers["Authorization"] = f"token {token}"

try:
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=15) as resp:
        prs = json.loads(resp.read())
except Exception:
    print("")
    sys.exit(0)

# Find first untested PR
for pr in prs:
    num = str(pr["number"])
    sha = pr["head"]["sha"]
    branch = pr["head"]["ref"]
    pr_state = state.get(num, {})
    if pr_state.get("ignored", False):
        continue
    if pr_state.get("last_tested_sha") == sha:
        continue
    print(f"{num} {sha} {branch}")
    sys.exit(0)

print("")
PYEOF
        )

        if [[ -n "$PR_TO_TEST" ]]; then
            read -r PR_NUM PR_SHA PR_BRANCH <<< "$PR_TO_TEST"
            log_info "Untested PR: #${PR_NUM} (${PR_SHA:0:7}, branch: ${PR_BRANCH})"

            # Fetch PR branch
            cd "${TORCHTITAN_DIR}"
            if git fetch "${GIT_REMOTE}" "pull/${PR_NUM}/head:pr-${PR_NUM}" --quiet 2>/dev/null; then
                if submit_1node_job "$PR_SHA" "pr" "$PR_NUM"; then
                    SUBMITTED=true
                fi
            else
                log_warn "Failed to fetch PR #${PR_NUM}"
            fi
        fi
    fi

    # ----- 3. Heartbeat (24h) -----
    if [[ "$SUBMITTED" == "false" ]]; then
        ELAPSED=$(seconds_since_last_run)
        if [[ "$ELAPSED" -ge "$HEARTBEAT_SEC" ]]; then
            cd "${TORCHTITAN_DIR}"
            git fetch "${GIT_REMOTE}" "${GIT_BRANCH}" --quiet 2>/dev/null || true
            HEAD_SHA=$(git rev-parse "${GIT_REMOTE}/${GIT_BRANCH}" 2>/dev/null || echo "")
            if [[ -n "$HEAD_SHA" ]]; then
                log_info "Heartbeat: ${ELAPSED}s since last run (threshold: ${HEARTBEAT_SEC}s). Forcing run."
                submit_1node_job "$HEAD_SHA" "heartbeat" || true
            fi
        else
            log_debug "Heartbeat OK (${ELAPSED}s / ${HEARTBEAT_SEC}s)"
        fi
    fi

    # Cleanup old logs periodically
    cleanup_old_logs 2>/dev/null || true

    sleep "$POLL_INTERVAL"
done
