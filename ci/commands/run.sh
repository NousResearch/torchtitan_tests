#!/usr/bin/env bash
# =============================================================================
# ttci run — Trigger a test run
# =============================================================================
# Usage: ttci run [options]
#   --force           Skip commit-changed check
#   --2node           2-node test job
#   --pr <number>     Test specific PR
#   --suite <name>    Only run: unit, distributed, integration
#   --benchmark <name> Run specific benchmark
#   --local           Run directly (no Slurm)
#   --wait            Block until job completes
#   --quality         Include quality checks
#   --dry-run         Show what would be done
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source "${SCRIPT_DIR}/../lib/slurm_helpers.sh"
load_config
setup_environment

# Parse arguments
FORCE=false
TWO_NODE=false
PR_NUMBER=""
SUITE="all"
BENCHMARK=""
LOCAL=false
WAIT=false
QUALITY=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force)     FORCE=true; shift ;;
        --2node)     TWO_NODE=true; shift ;;
        --pr)        PR_NUMBER="$2"; shift 2 ;;
        --suite)     SUITE="$2"; shift 2 ;;
        --benchmark) BENCHMARK="$2"; shift 2 ;;
        --local)     LOCAL=true; shift ;;
        --wait)      WAIT=true; shift ;;
        --quality)   QUALITY=true; shift ;;
        --dry-run)   DRY_RUN=true; shift ;;
        --help|-h)
            echo "Usage: ttci run [--force] [--2node] [--pr N] [--suite S] [--benchmark B] [--local] [--wait] [--quality] [--dry-run]"
            exit 0
            ;;
        *) log_error "Unknown option: $1"; exit 1 ;;
    esac
done

# Determine what to run
RUN_ID=$(generate_run_id)
RUN_LOG_DIR="${CI_LOG_DIR}/${RUN_ID}"
TRIGGER="manual"

# Handle PR checkout
if [[ -n "$PR_NUMBER" ]]; then
    TRIGGER="pr"
    source "${SCRIPT_DIR}/../lib/github_api.sh"
    log_info "Fetching PR #${PR_NUMBER} details..."
    PR_SHA=$(get_pr_head_sha "$PR_NUMBER")
    if [[ -z "$PR_SHA" ]]; then
        log_error "Could not fetch PR #${PR_NUMBER}"
        exit 1
    fi
    COMMIT_SHA="$PR_SHA"
    log_info "PR #${PR_NUMBER} HEAD: ${COMMIT_SHA:0:7}"

    # Fetch and checkout PR
    cd "${TORCHTITAN_DIR}"
    git fetch "${GIT_REMOTE}" "pull/${PR_NUMBER}/head:pr-${PR_NUMBER}" --quiet 2>/dev/null || {
        log_error "Failed to fetch PR #${PR_NUMBER}"
        exit 1
    }
    COMMIT_SHA=$(git rev-parse "pr-${PR_NUMBER}")
else
    # Use latest commit on tracked branch
    cd "${TORCHTITAN_DIR}"
    git fetch "${GIT_REMOTE}" "${GIT_BRANCH}" --quiet 2>/dev/null || {
        log_error "git fetch failed"
        exit 1
    }
    COMMIT_SHA=$(git rev-parse "${GIT_REMOTE}/${GIT_BRANCH}")

    # Check if already tested
    if [[ "$FORCE" == "false" && -f "${LAST_TESTED_SHA_FILE}" ]]; then
        LAST_SHA=$(cat "${LAST_TESTED_SHA_FILE}")
        if [[ "$COMMIT_SHA" == "$LAST_SHA" ]]; then
            log_info "Commit ${COMMIT_SHA:0:7} already tested. Use --force to re-run."
            exit 0
        fi
    fi
fi

# Handle benchmark run
if [[ -n "$BENCHMARK" ]]; then
    log_info "Running benchmark: ${BENCHMARK}"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "DRY RUN: Would submit benchmark job for ${BENCHMARK}"
        exit 0
    fi

    ensure_dir "$RUN_LOG_DIR"

    if [[ "$LOCAL" == "true" ]]; then
        # Run directly
        CI_RUN_LOG_DIR="$RUN_LOG_DIR" \
        CI_COMMIT_SHA="$COMMIT_SHA" \
        CI_RUN_ID="$RUN_ID" \
        CI_BENCHMARK_NAME="$BENCHMARK" \
            bash "${SCRIPT_DIR}/../jobs/run_benchmark.slurm"
    else
        JOB_ID=$(submit_job "${SCRIPT_DIR}/../jobs/run_benchmark.slurm" \
            --partition="${SLURM_PARTITION}" \
            --nodes=1 \
            --gpus-per-node="${SLURM_1N_GPUS}" \
            --cpus-per-task="${SLURM_1N_CPUS}" \
            --time="${SLURM_1N_TIME}" \
            --output="${RUN_LOG_DIR}/slurm-%j.out" \
            --export="ALL,CI_DIR=${CI_DIR},CI_COMMIT_SHA=${COMMIT_SHA},CI_RUN_ID=${RUN_ID},CI_RUN_LOG_DIR=${RUN_LOG_DIR},CI_BENCHMARK_NAME=${BENCHMARK}")

        log_info "Benchmark job submitted: ${JOB_ID}"

        if [[ "$WAIT" == "true" ]]; then
            wait_for_job "$JOB_ID"
        fi
    fi
    exit 0
fi

# Determine Slurm script and resources
if [[ "$TWO_NODE" == "true" ]]; then
    SLURM_SCRIPT="${SCRIPT_DIR}/../jobs/run_tests_2node.slurm"
    NODES="${SLURM_2N_NODES}"
    GPUS="${SLURM_2N_GPUS}"
    CPUS="${SLURM_2N_CPUS}"
    TIME_LIMIT="${SLURM_2N_TIME}"
    MIN_IDLE="${MIN_IDLE_NODES_2N}"
    JOB_NAME="${SLURM_JOB_PREFIX}-2n"
else
    SLURM_SCRIPT="${SCRIPT_DIR}/../jobs/run_tests_1node.slurm"
    NODES="${SLURM_1N_NODES}"
    GPUS="${SLURM_1N_GPUS}"
    CPUS="${SLURM_1N_CPUS}"
    TIME_LIMIT="${SLURM_1N_TIME}"
    MIN_IDLE="${MIN_IDLE_NODES_1N}"
    JOB_NAME="${SLURM_JOB_PREFIX}-1n"
fi

log_info "Run ID:  ${RUN_ID}"
log_info "Commit:  ${COMMIT_SHA:0:7}"
log_info "Trigger: ${TRIGGER}${PR_NUMBER:+ (PR #${PR_NUMBER})}"
log_info "Suite:   ${SUITE}"
log_info "Nodes:   ${NODES}"
log_info "Quality: ${QUALITY}"

if [[ "$DRY_RUN" == "true" ]]; then
    log_info "DRY RUN: Would submit ${NODES}-node job for ${COMMIT_SHA:0:7}"
    log_info "DRY RUN: Script: ${SLURM_SCRIPT}"
    log_info "DRY RUN: Log dir: ${RUN_LOG_DIR}"
    exit 0
fi

ensure_dir "$RUN_LOG_DIR"

if [[ "$LOCAL" == "true" ]]; then
    # Run directly (no Slurm)
    log_info "Running locally (no Slurm)..."
    export SLURM_JOB_ID="local-$$"
    export SLURM_NNODES="${NODES}"
    CI_RUN_LOG_DIR="$RUN_LOG_DIR" \
    CI_COMMIT_SHA="$COMMIT_SHA" \
    CI_RUN_ID="$RUN_ID" \
    CI_TRIGGER="$TRIGGER" \
    CI_PR_NUMBER="$PR_NUMBER" \
    CI_SUITE="$SUITE" \
    CI_QUALITY="$QUALITY" \
        bash "$SLURM_SCRIPT"
else
    # Check idle nodes
    if [[ "$FORCE" == "false" ]]; then
        IDLE=$(count_idle_nodes "$SLURM_PARTITION")
        if [[ "$IDLE" -lt "$MIN_IDLE" ]]; then
            log_warn "Not enough idle nodes: ${IDLE} < ${MIN_IDLE}"
            exit 0
        fi

        # Check for running CI jobs
        if is_job_running "$JOB_NAME"; then
            log_warn "CI job already running. Use --force to submit anyway."
            exit 0
        fi
    fi

    # Submit Slurm job
    JOB_ID=$(submit_job "$SLURM_SCRIPT" \
        --job-name="${JOB_NAME}" \
        --partition="${SLURM_PARTITION}" \
        --nodes="${NODES}" \
        --gpus-per-node="${GPUS}" \
        --cpus-per-task="${CPUS}" \
        --time="${TIME_LIMIT}" \
        --output="${RUN_LOG_DIR}/slurm-%j.out" \
        --export="ALL,CI_DIR=${CI_DIR},CI_COMMIT_SHA=${COMMIT_SHA},CI_RUN_ID=${RUN_ID},CI_RUN_LOG_DIR=${RUN_LOG_DIR},CI_TRIGGER=${TRIGGER},CI_PR_NUMBER=${PR_NUMBER},CI_SUITE=${SUITE},CI_QUALITY=${QUALITY}")

    log_info "Job submitted: ${JOB_ID} (run: ${RUN_ID})"

    if [[ "$WAIT" == "true" ]]; then
        wait_for_job "$JOB_ID"
        # Show summary
        if [[ -f "${RUN_LOG_DIR}/summary.txt" ]]; then
            echo ""
            cat "${RUN_LOG_DIR}/summary.txt"
        fi
    fi
fi
