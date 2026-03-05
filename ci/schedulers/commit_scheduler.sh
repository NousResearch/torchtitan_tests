#!/usr/bin/env bash
# =============================================================================
# commit_scheduler.sh — Poll git for new commits, submit 1-node jobs
# =============================================================================
# Cron entry: */10 * * * * /path/to/commit_scheduler.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source "${SCRIPT_DIR}/../lib/slurm_helpers.sh"
load_config

ensure_dir "${CI_LOG_DIR}" "${CI_STATE_DIR}" "${CI_DATA_DIR}"

# Append to scheduler log
SCHEDULER_LOG="${CI_LOG_DIR}/commit_scheduler.log"
exec >> "${SCHEDULER_LOG}" 2>&1

log_info "=== Commit scheduler run ==="

# Step 1: Fetch latest commits
cd "${TORCHTITAN_DIR}"
git fetch "${GIT_REMOTE}" "${GIT_BRANCH}" --quiet 2>/dev/null || {
    log_error "git fetch failed"
    exit 1
}

LATEST_SHA=$(git rev-parse "${GIT_REMOTE}/${GIT_BRANCH}")
LAST_TESTED_SHA=""
if [[ -f "${LAST_TESTED_SHA_FILE}" ]]; then
    LAST_TESTED_SHA=$(cat "${LAST_TESTED_SHA_FILE}")
fi

if [[ "${LATEST_SHA}" == "${LAST_TESTED_SHA}" ]]; then
    log_debug "No new commits. Latest=${LATEST_SHA:0:7}, LastTested=${LAST_TESTED_SHA:0:7}"
    exit 0
fi

log_info "New commit detected: ${LATEST_SHA:0:7} (was: ${LAST_TESTED_SHA:0:7})"

# Step 2: Check idle nodes
IDLE=$(count_idle_nodes "${SLURM_PARTITION}")
if [[ "${IDLE}" -lt "${MIN_IDLE_NODES_1N}" ]]; then
    log_info "Not enough idle nodes: ${IDLE} < ${MIN_IDLE_NODES_1N}, skipping"
    exit 0
fi

# Step 3: Check for existing CI job
JOB_NAME="${SLURM_JOB_PREFIX}-1n"
if is_job_running "$JOB_NAME"; then
    log_info "CI job already running, skipping"
    exit 0
fi

# Step 4: Submit job
RUN_ID=$(generate_run_id)
RUN_LOG_DIR="${CI_LOG_DIR}/${RUN_ID}"
ensure_dir "$RUN_LOG_DIR"

JOB_ID=$(submit_job "${SCRIPT_DIR}/../jobs/run_tests_1node.slurm" \
    --job-name="${JOB_NAME}" \
    --partition="${SLURM_PARTITION}" \
    --nodes="${SLURM_1N_NODES}" \
    --gpus-per-node="${SLURM_1N_GPUS}" \
    --cpus-per-task="${SLURM_1N_CPUS}" \
    --time="${SLURM_1N_TIME}" \
    --output="${RUN_LOG_DIR}/slurm-%j.out" \
    --export="ALL,CI_COMMIT_SHA=${LATEST_SHA},CI_RUN_ID=${RUN_ID},CI_RUN_LOG_DIR=${RUN_LOG_DIR},CI_TRIGGER=commit")

log_info "Submitted job ${JOB_ID} for commit ${LATEST_SHA:0:7} (run: ${RUN_ID})"

# Step 5: Clean old logs
cleanup_old_logs

log_info "=== Commit scheduler complete ==="
