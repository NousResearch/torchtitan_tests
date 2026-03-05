#!/usr/bin/env bash
# =============================================================================
# pr_scheduler.sh — Poll GitHub API for new/updated PRs
# =============================================================================
# Cron entry: */15 * * * * /path/to/pr_scheduler.sh
# Requires: GITHUB_TOKEN env var (optional for public repos)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source "${SCRIPT_DIR}/../lib/github_api.sh"
source "${SCRIPT_DIR}/../lib/slurm_helpers.sh"
load_config

ensure_dir "${CI_LOG_DIR}" "${CI_STATE_DIR}" "${CI_DATA_DIR}"

SCHEDULER_LOG="${CI_LOG_DIR}/pr_scheduler.log"
exec >> "${SCHEDULER_LOG}" 2>&1

log_info "=== PR scheduler run ==="

# Check idle nodes first
IDLE=$(count_idle_nodes "${SLURM_PARTITION}")
if [[ "${IDLE}" -lt "${MIN_IDLE_NODES_1N}" ]]; then
    log_info "Not enough idle nodes: ${IDLE} < ${MIN_IDLE_NODES_1N}, skipping"
    exit 0
fi

# Check for existing CI job
JOB_NAME="${SLURM_JOB_PREFIX}-1n"
if is_job_running "$JOB_NAME"; then
    log_info "CI job already running, skipping"
    exit 0
fi

# Fetch open PRs
log_info "Fetching open PRs from ${GITHUB_API_REPO}..."
PR_JSON=$(list_open_prs)

if [[ -z "$PR_JSON" || "$PR_JSON" == "null" || "$PR_JSON" == "[]" ]]; then
    log_info "No open PRs found"
    exit 0
fi

# Process each PR
python3 -c "
import json, sys, subprocess

prs = json.loads('''${PR_JSON}''')

# Load current PR state
state_file = '${CI_DATA_DIR}/pr_state.json'
try:
    with open(state_file) as f:
        state = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    state = {}

to_test = []
for pr in prs:
    num = str(pr['number'])
    sha = pr['head']['sha']
    branch = pr['head']['ref']

    pr_state = state.get(num, {})

    # Skip ignored PRs
    if pr_state.get('ignored', False):
        continue

    # Skip already-tested SHA
    if pr_state.get('last_tested_sha') == sha:
        continue

    to_test.append({
        'number': num,
        'sha': sha,
        'branch': branch,
        'title': pr['title'][:60]
    })

if not to_test:
    print('NO_NEW_PRS')
else:
    # Output first untested PR (one at a time to avoid overload)
    p = to_test[0]
    print(f\"TEST_PR {p['number']} {p['sha']} {p['branch']}\")
" 2>/dev/null | while IFS= read -r line; do
    if [[ "$line" == "NO_NEW_PRS" ]]; then
        log_info "All open PRs are up to date"
        continue
    fi

    if [[ "$line" == TEST_PR* ]]; then
        read -r _ PR_NUM PR_SHA PR_BRANCH <<< "$line"
        log_info "New/updated PR: #${PR_NUM} (${PR_SHA:0:7}, branch: ${PR_BRANCH})"

        # Fetch PR branch
        cd "${TORCHTITAN_DIR}"
        git fetch "${GIT_REMOTE}" "pull/${PR_NUM}/head:pr-${PR_NUM}" --quiet 2>/dev/null || {
            log_error "Failed to fetch PR #${PR_NUM}"
            continue
        }

        # Submit test job
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
            --export="ALL,CI_COMMIT_SHA=${PR_SHA},CI_RUN_ID=${RUN_ID},CI_RUN_LOG_DIR=${RUN_LOG_DIR},CI_TRIGGER=pr,CI_PR_NUMBER=${PR_NUM}")

        log_info "Submitted PR test job ${JOB_ID} for PR #${PR_NUM} (run: ${RUN_ID})"
    fi
done

log_info "=== PR scheduler complete ==="
