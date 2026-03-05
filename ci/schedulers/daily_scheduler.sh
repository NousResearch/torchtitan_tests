#!/usr/bin/env bash
# =============================================================================
# daily_scheduler.sh — Daily 2-node tests + benchmarks + quality
# =============================================================================
# Cron entry: 0 2 * * * /path/to/daily_scheduler.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source "${SCRIPT_DIR}/../lib/slurm_helpers.sh"
load_config

ensure_dir "${CI_LOG_DIR}" "${CI_STATE_DIR}" "${CI_DATA_DIR}"

SCHEDULER_LOG="${CI_LOG_DIR}/daily_scheduler.log"
exec >> "${SCHEDULER_LOG}" 2>&1

log_info "=== Daily scheduler run ==="

cd "${TORCHTITAN_DIR}"
git fetch "${GIT_REMOTE}" "${GIT_BRANCH}" --quiet 2>/dev/null || {
    log_error "git fetch failed"
    exit 1
}
LATEST_SHA=$(git rev-parse "${GIT_REMOTE}/${GIT_BRANCH}")

# --- 2-node test job ---
log_info "Checking 2-node job availability..."
IDLE=$(count_idle_nodes "${SLURM_PARTITION}")

if [[ "${IDLE}" -ge "${MIN_IDLE_NODES_2N}" ]]; then
    JOB_NAME="${SLURM_JOB_PREFIX}-2n"
    if ! is_job_running "$JOB_NAME"; then
        RUN_ID="daily-2n-$(generate_run_id)"
        RUN_LOG_DIR="${CI_LOG_DIR}/${RUN_ID}"
        ensure_dir "$RUN_LOG_DIR"

        JOB_ID=$(submit_job "${SCRIPT_DIR}/../jobs/run_tests_2node.slurm" \
            --job-name="${JOB_NAME}" \
            --partition="${SLURM_PARTITION}" \
            --nodes="${SLURM_2N_NODES}" \
            --gpus-per-node="${SLURM_2N_GPUS}" \
            --cpus-per-task="${SLURM_2N_CPUS}" \
            --time="${SLURM_2N_TIME}" \
            --output="${RUN_LOG_DIR}/slurm-%j.out" \
            --export="ALL,CI_DIR=${CI_DIR},CI_COMMIT_SHA=${LATEST_SHA},CI_RUN_ID=${RUN_ID},CI_RUN_LOG_DIR=${RUN_LOG_DIR},CI_TRIGGER=daily")

        log_info "Submitted 2-node job ${JOB_ID} (run: ${RUN_ID})"
    else
        log_info "2-node CI job already running, skipping"
    fi
else
    log_info "Not enough idle nodes for 2-node job: ${IDLE} < ${MIN_IDLE_NODES_2N}"
fi

# --- Benchmark job (1 hour after 2-node test) ---
log_info "Scheduling benchmark job..."
BENCH_JOB_NAME="${SLURM_JOB_PREFIX}-bench"

if [[ "${IDLE}" -ge "${MIN_IDLE_NODES_1N}" ]] && ! is_job_running "$BENCH_JOB_NAME"; then
    BENCH_RUN_ID="daily-bench-$(generate_run_id)"
    BENCH_LOG_DIR="${CI_LOG_DIR}/${BENCH_RUN_ID}"
    ensure_dir "$BENCH_LOG_DIR"

    # Submit with --begin to start 1 hour later (after 2-node test likely done)
    BENCH_JOB_ID=$(submit_job "${SCRIPT_DIR}/../jobs/run_benchmark.slurm" \
        --job-name="${BENCH_JOB_NAME}" \
        --partition="${SLURM_PARTITION}" \
        --nodes=1 \
        --gpus-per-node="${SLURM_1N_GPUS}" \
        --cpus-per-task="${SLURM_1N_CPUS}" \
        --time="${SLURM_1N_TIME}" \
        --begin="now+60minutes" \
        --output="${BENCH_LOG_DIR}/slurm-%j.out" \
        --export="ALL,CI_DIR=${CI_DIR},CI_COMMIT_SHA=${LATEST_SHA},CI_RUN_ID=${BENCH_RUN_ID},CI_RUN_LOG_DIR=${BENCH_LOG_DIR},CI_BENCHMARK_NAME=qwen3_30b_a3b_deepep")

    log_info "Submitted benchmark job ${BENCH_JOB_ID} (run: ${BENCH_RUN_ID}, starts in 60min)"
else
    log_info "Skipping benchmark (nodes: ${IDLE}, or job already running)"
fi

# --- Quality checks (run locally, no Slurm needed) ---
log_info "Running quality checks..."
QUALITY_LOG="${CI_LOG_DIR}/daily-quality-$(generate_run_id).log"
bash "${SCRIPT_DIR}/../quality/run_quality.sh" --ci > "${QUALITY_LOG}" 2>&1 || {
    log_warn "Quality checks had failures (see ${QUALITY_LOG})"
}

# --- Daily summary notification ---
log_info "Sending daily summary..."
DAILY_SUMMARY="${CI_LOG_DIR}/daily_summary.txt"
{
    echo "torchtitan Daily CI Summary"
    echo "==========================="
    echo "Date: $(date)"
    echo "Branch: ${GIT_BRANCH}"
    echo "HEAD: ${LATEST_SHA:0:7}"
    echo ""
    echo "Jobs submitted:"
    [[ -n "${JOB_ID:-}" ]] && echo "  2-node test: ${JOB_ID}" || echo "  2-node test: skipped"
    [[ -n "${BENCH_JOB_ID:-}" ]] && echo "  Benchmark: ${BENCH_JOB_ID}" || echo "  Benchmark: skipped"
    echo ""
    echo "Quality checks: see ${QUALITY_LOG}"
} > "${DAILY_SUMMARY}"

"${SCRIPT_DIR}/../reporters/discord.sh" "pass" "${GIT_BRANCH}" "${LATEST_SHA}" "daily-$(date +%Y%m%d)" "${DAILY_SUMMARY}" || true

# Cleanup old logs
cleanup_old_logs

log_info "=== Daily scheduler complete ==="
