#!/usr/bin/env bash
# CI Scheduler for torchtitan
# Checks for new commits, verifies GPU availability, submits test job
# Usage: ./scheduler.sh [--force] [--dry-run]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env"

# ============================================================================
# Flags
# ============================================================================
FORCE=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force)   FORCE=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        --help|-h)
            echo "Usage: $0 [--force] [--dry-run]"
            echo "  --force    Skip commit check (always run)"
            echo "  --dry-run  Check everything but don't submit job"
            exit 0
            ;;
        *) echo "Unknown flag: $1"; exit 1 ;;
    esac
done

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# Ensure directories exist
mkdir -p "${CI_LOG_DIR}" "${CI_STATE_DIR}"

# Append to scheduler log
SCHEDULER_LOG="${CI_LOG_DIR}/scheduler.log"
exec >> "${SCHEDULER_LOG}" 2>&1

log "=== Scheduler run started ==="
log "Force=${FORCE}, DryRun=${DRY_RUN}"

# ============================================================================
# Step 1: Check for new commits
# ============================================================================
cd "${TORCHTITAN_DIR}"
git fetch "${GIT_REMOTE}" "${GIT_BRANCH}" --quiet 2>/dev/null || {
    log "ERROR: git fetch failed"
    exit 1
}

LATEST_SHA=$(git rev-parse "${GIT_REMOTE}/${GIT_BRANCH}")
LAST_TESTED_SHA=""
if [[ -f "${LAST_TESTED_SHA_FILE}" ]]; then
    LAST_TESTED_SHA=$(cat "${LAST_TESTED_SHA_FILE}")
fi

if [[ "${FORCE}" == "false" && "${LATEST_SHA}" == "${LAST_TESTED_SHA}" ]]; then
    log "No new commits. Latest=${LATEST_SHA:0:7}, LastTested=${LAST_TESTED_SHA:0:7}"
    exit 0
fi

if [[ "${FORCE}" == "true" ]]; then
    log "Force mode: ignoring commit check"
fi
log "New commit detected: ${LATEST_SHA:0:7} (was: ${LAST_TESTED_SHA:0:7})"

# ============================================================================
# Step 2: Check GPU availability
# ============================================================================
IDLE_NODES=$(sinfo -p "${SLURM_PARTITION}" -t idle -h -o "%D" 2>/dev/null | head -1)
IDLE_NODES="${IDLE_NODES:-0}"

if [[ "${IDLE_NODES}" -lt "${MIN_IDLE_NODES}" ]]; then
    log "Not enough idle nodes: ${IDLE_NODES} < ${MIN_IDLE_NODES}, skipping"
    exit 0
fi
log "Idle nodes: ${IDLE_NODES} (need ${MIN_IDLE_NODES})"

# ============================================================================
# Step 3: Check for existing CI job
# ============================================================================
EXISTING_JOBS=$(squeue -n "${SLURM_JOB_NAME}" -h -o "%i" 2>/dev/null | wc -l)
if [[ "${EXISTING_JOBS}" -gt 0 ]]; then
    log "CI job already running/queued (${EXISTING_JOBS} jobs), skipping"
    exit 0
fi
log "No existing CI job found"

# ============================================================================
# Step 4: Submit job
# ============================================================================
RUN_ID="ci-$(date +%Y%m%d_%H%M%S)"
RUN_LOG_DIR="${CI_LOG_DIR}/${RUN_ID}"
mkdir -p "${RUN_LOG_DIR}"

if [[ "${DRY_RUN}" == "true" ]]; then
    log "DRY RUN: Would submit sbatch with SHA=${LATEST_SHA:0:7}, RUN_ID=${RUN_ID}"
    log "DRY RUN: Log dir would be ${RUN_LOG_DIR}"
    exit 0
fi

JOB_ID=$(sbatch \
    --parsable \
    --partition="${SLURM_PARTITION}" \
    --nodes="${SLURM_NODES}" \
    --gpus-per-node="${SLURM_GPUS_PER_NODE}" \
    --cpus-per-task="${SLURM_CPUS_PER_TASK}" \
    --time="${SLURM_TIME_LIMIT}" \
    --output="${RUN_LOG_DIR}/slurm-%j.out" \
    --export="ALL,CI_COMMIT_SHA=${LATEST_SHA},CI_RUN_ID=${RUN_ID},CI_RUN_LOG_DIR=${RUN_LOG_DIR}" \
    "${SCRIPT_DIR}/run_tests.slurm" 2>&1)

if [[ $? -eq 0 ]]; then
    log "Submitted job ${JOB_ID} for commit ${LATEST_SHA:0:7} (run: ${RUN_ID})"
else
    log "ERROR: sbatch failed: ${JOB_ID}"
    exit 1
fi

# ============================================================================
# Step 5: Clean up old logs
# ============================================================================
if [[ -d "${CI_LOG_DIR}" ]]; then
    CLEANED=$(find "${CI_LOG_DIR}" -maxdepth 1 -type d -name "ci-*" -mtime "+${LOG_RETENTION_DAYS}" -exec rm -rf {} + 2>/dev/null && echo "done" || echo "none")
    log "Log cleanup: ${CLEANED}"
fi

log "=== Scheduler run complete ==="
