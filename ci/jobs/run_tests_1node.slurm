#!/bin/bash
#SBATCH --job-name=ci-torchtitan-1n
#SBATCH --output=%x-%j.out
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --gpus-per-node=8
#SBATCH --cpus-per-task=48
#SBATCH --mem=0
#SBATCH --exclusive
#SBATCH --time=01:30:00
#SBATCH --signal=B:USR1@120

# =============================================================================
# CI Test Runner — 1 Node (unit + distributed + integration)
# =============================================================================
# Triggered by: commit_scheduler, pr_scheduler, or manual `ttci run`
# Exports: CI_COMMIT_SHA, CI_RUN_ID, CI_RUN_LOG_DIR, CI_TRIGGER, CI_PR_NUMBER
# =============================================================================

# Resolve CI_DIR: use exported env var (from sbatch) or fall back to relative path
if [[ -n "${CI_DIR:-}" ]]; then
    SCRIPT_DIR="${CI_DIR}/jobs"
else
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    CI_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
fi
source "${CI_DIR}/lib/common.sh"
load_config
setup_environment

# Override with scheduler-provided values or defaults
CI_RUN_LOG_DIR="${CI_RUN_LOG_DIR:-${CI_LOG_DIR}/manual-${SLURM_JOB_ID}}"
CI_COMMIT_SHA="${CI_COMMIT_SHA:-HEAD}"
CI_RUN_ID="${CI_RUN_ID:-manual-$(generate_run_id)}"
CI_TRIGGER="${CI_TRIGGER:-manual}"
CI_PR_NUMBER="${CI_PR_NUMBER:-}"
CI_SUITE="${CI_SUITE:-all}"
CI_QUALITY="${CI_QUALITY:-false}"

ensure_dir "${CI_RUN_LOG_DIR}"

# Redirect all output to log file AND stdout
exec > >(tee -a "${CI_RUN_LOG_DIR}/full_output.log") 2>&1

SUMMARY_FILE="${CI_RUN_LOG_DIR}/summary.txt"
SUMMARY_JSON="${CI_RUN_LOG_DIR}/summary.json"
GPU_CSV="${CI_RUN_LOG_DIR}/gpu_monitor.csv"
OVERALL_STATUS="pass"
PHASE_RESULTS=()
PHASE_JSON_PARTS=()
START_TIME=$(date +%s)

# =============================================================================
# GPU Monitoring
# =============================================================================
source "${CI_DIR}/lib/gpu_monitor.sh"
start_gpu_monitor "$GPU_CSV"

# =============================================================================
# Preemption signal handler
# =============================================================================
handle_preemption() {
    echo ""
    log_error "PREEMPTED by Slurm (USR1 signal) at $(date)"
    stop_gpu_monitor
    generate_summary "preempted"
    "${CI_DIR}/reporters/discord.sh" preempted "${GIT_BRANCH}" "${CI_COMMIT_SHA}" "${CI_RUN_ID}" "${SUMMARY_FILE}" || true
    exit 1
}
trap handle_preemption USR1

cleanup_on_exit() {
    stop_gpu_monitor
}
trap cleanup_on_exit EXIT

# =============================================================================
# Helper: run a phase with timeout and logging
# =============================================================================
run_phase() {
    local phase_name="$1"
    local timeout_val="$2"
    shift 2
    local cmd=("$@")

    local phase_log="${CI_RUN_LOG_DIR}/${phase_name}.log"
    local phase_start=$(date +%s)

    section "Phase: ${phase_name}"
    log_info "Command: ${cmd[*]}"
    log_info "Timeout: ${timeout_val}"

    local exit_code=0
    timeout "${timeout_val}" bash -c "${cmd[*]}" > "${phase_log}" 2>&1 || exit_code=$?

    local phase_end=$(date +%s)
    local duration=$((phase_end - phase_start))

    local status_str="pass"
    local passed=0 failed=0 skipped=0

    if [[ ${exit_code} -eq 0 ]]; then
        status_str="pass"
        log_info "${phase_name}: PASS (${duration}s)"
        # Try to extract test counts from pytest output
        if grep -qE "[0-9]+ passed" "${phase_log}" 2>/dev/null; then
            passed=$(grep -oE "[0-9]+ passed" "${phase_log}" | tail -1 | grep -oE "[0-9]+")
            failed=$(grep -oE "[0-9]+ failed" "${phase_log}" | tail -1 | grep -oE "[0-9]+" || echo 0)
            skipped=$(grep -oE "[0-9]+ skipped" "${phase_log}" | tail -1 | grep -oE "[0-9]+" || echo 0)
        fi
    elif [[ ${exit_code} -eq 124 ]]; then
        status_str="timeout"
        OVERALL_STATUS="fail"
        log_error "${phase_name}: TIMEOUT after ${timeout_val} (${duration}s)"
    else
        status_str="fail"
        OVERALL_STATUS="fail"
        log_error "${phase_name}: FAIL (exit ${exit_code}, ${duration}s)"
        # Print last 20 lines for diagnosis
        log_warn "Last 20 lines of ${phase_name}.log:"
        tail -20 "${phase_log}" | sed 's/^/     /'
    fi

    PHASE_RESULTS+=("${phase_name}: ${status_str^^} (${duration}s)")
    PHASE_JSON_PARTS+=("\"${phase_name}\": {\"status\": \"${status_str}\", \"passed\": ${passed:-0}, \"failed\": ${failed:-0}, \"skipped\": ${skipped:-0}, \"duration_sec\": ${duration}, \"exit_code\": ${exit_code}}")
}

# Helper: run distributed test via torchrun (single node)
run_torchrun_test() {
    local phase_name="$1"
    local ngpu="$2"
    local rdzv_port="$3"
    local test_module="$4"
    local timeout_val="$5"

    local torchrun_cmd="cd ${TORCHTITAN_DIR} && \
source ${VENV_DIR}/bin/activate && \
torchrun \
    --nnodes=1 \
    --nproc_per_node=${ngpu} \
    --rdzv_id=${SLURM_JOB_ID}_${phase_name} \
    --rdzv_backend=c10d \
    --rdzv_endpoint=localhost:${rdzv_port} \
    -m ${test_module}"

    run_phase "${phase_name}" "${timeout_val}" "${torchrun_cmd}"
}

# Helper: run integration test suite
run_integration_suite() {
    local suite_name="$1"
    local ngpu="$2"
    local timeout_val="$3"

    local output_dir="${CI_RUN_LOG_DIR}/integration_${suite_name}"
    mkdir -p "${output_dir}"

    local cmd="cd ${TORCHTITAN_DIR} && \
source ${VENV_DIR}/bin/activate && \
python -m tests.integration_tests.run_tests ${output_dir} \
    --test_suite ${suite_name} --ngpu ${ngpu}"

    run_phase "integration_${suite_name}" "${timeout_val}" "${cmd}"
}

# =============================================================================
# Generate summary (text + JSON)
# =============================================================================
generate_summary() {
    local final_status="${1:-${OVERALL_STATUS}}"
    local end_time=$(date +%s)
    local total_duration=$((end_time - START_TIME))

    # Text summary
    {
        echo "torchtitan CI Run Summary"
        echo "========================="
        echo "Run ID:   ${CI_RUN_ID}"
        echo "Commit:   ${CI_COMMIT_SHA:0:7}"
        echo "Branch:   ${GIT_BRANCH}"
        echo "Trigger:  ${CI_TRIGGER}${CI_PR_NUMBER:+ (PR #${CI_PR_NUMBER})}"
        echo "Status:   ${final_status^^}"
        echo "Duration: ${total_duration}s"
        echo "Job ID:   ${SLURM_JOB_ID}"
        echo "Node:     $(hostname)"
        echo "Date:     $(date)"
        echo ""
        echo "Phase Results:"
        for result in "${PHASE_RESULTS[@]}"; do
            echo "  ${result}"
        done
    } > "${SUMMARY_FILE}"

    cat "${SUMMARY_FILE}"

    # JSON summary
    local phases_json
    phases_json=$(printf ", %s" "${PHASE_JSON_PARTS[@]}")
    phases_json="{${phases_json:2}}"

    # GPU stats (if available)
    local gpu_stats="{}"
    if [[ -f "$GPU_CSV" ]] && [[ -s "$GPU_CSV" ]]; then
        gpu_stats=$("${CI_DIR}/reporters/gpu_report.sh" --json "$GPU_CSV" 2>/dev/null || echo "{}")
    fi

    cat > "${SUMMARY_JSON}" <<ENDJSON
{
  "run_id": "${CI_RUN_ID}",
  "trigger": "${CI_TRIGGER}",
  "pr_number": ${CI_PR_NUMBER:-null},
  "sha": "${CI_COMMIT_SHA}",
  "branch": "${GIT_BRANCH}",
  "node_count": 1,
  "job_id": "${SLURM_JOB_ID}",
  "hostname": "$(hostname)",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "phases": ${phases_json},
  "gpu_stats": ${gpu_stats},
  "overall_status": "${final_status}",
  "total_duration_sec": ${total_duration}
}
ENDJSON

    # Append to runs.jsonl
    local jsonl_entry
    jsonl_entry=$(tr -d '\n' < "${SUMMARY_JSON}" | tr -s ' ')
    append_jsonl "${CI_DATA_DIR}/runs.jsonl" "${jsonl_entry}"
}

# =============================================================================
# Main execution
# =============================================================================
section "torchtitan CI Test Runner (1-node)"
log_info "Run ID:  ${CI_RUN_ID}"
log_info "Commit:  ${CI_COMMIT_SHA}"
log_info "Trigger: ${CI_TRIGGER}${CI_PR_NUMBER:+ (PR #${CI_PR_NUMBER})}"
log_info "Suite:   ${CI_SUITE}"
log_info "Job ID:  ${SLURM_JOB_ID}"
log_info "Node:    $(hostname)"

# Activate venv
activate_venv

# Checkout exact commit
cd "${TORCHTITAN_DIR}"
git checkout "${CI_COMMIT_SHA}" --quiet 2>/dev/null || {
    log_warn "Could not checkout ${CI_COMMIT_SHA}, using current HEAD"
    CI_COMMIT_SHA=$(git rev-parse HEAD)
}

# --- Phase 1: Unit Tests ---
if [[ "${CI_SUITE}" == "all" || "${CI_SUITE}" == "unit" ]]; then
    PYTEST_FILES=""
    for f in "${UNIT_TEST_FILES[@]}"; do
        PYTEST_FILES="${PYTEST_FILES} ${f}"
    done

    run_phase "unit_tests" "${TIMEOUT_UNIT_TESTS}" \
        "cd ${TORCHTITAN_DIR} && source ${VENV_DIR}/bin/activate && \
python -m pytest -x -v ${PYTEST_FILES}"
fi

# --- Phase 2: Distributed Tests ---
if [[ "${CI_SUITE}" == "all" || "${CI_SUITE}" == "distributed" ]]; then
    run_torchrun_test "distributed_deepep" \
        "${DIST_TEST_DEEPEP_NGPU}" "${RDZV_PORT}" \
        "${DIST_TEST_DEEPEP_MODULE}" "${TIMEOUT_DISTRIBUTED_TESTS}"
fi

# --- Phase 3: Integration Tests ---
if [[ "${CI_SUITE}" == "all" || "${CI_SUITE}" == "integration" ]]; then
    run_integration_suite "features" "4" "${TIMEOUT_INTEGRATION_TESTS}"
    run_integration_suite "models" "8" "${TIMEOUT_INTEGRATION_TESTS}"
fi

# --- Phase 4: Quality Checks (optional) ---
if [[ "${CI_QUALITY}" == "true" ]]; then
    run_phase "quality" "10m" \
        "bash ${CI_DIR}/quality/run_quality.sh --ci"
fi

# =============================================================================
# Finalize
# =============================================================================
stop_gpu_monitor
generate_summary

# Update last tested SHA only on full success
if [[ "${OVERALL_STATUS}" == "pass" ]]; then
    echo "${CI_COMMIT_SHA}" > "${LAST_TESTED_SHA_FILE}"
    log_info "Updated last tested SHA to ${CI_COMMIT_SHA:0:7}"
fi

# Update PR state if this was a PR run
if [[ -n "${CI_PR_NUMBER}" ]]; then
    source "${CI_DIR}/lib/github_api.sh"
    update_pr_state "${CI_PR_NUMBER}" "${CI_COMMIT_SHA}" "${CI_RUN_ID}" "${OVERALL_STATUS}"
fi

# Send notifications
"${CI_DIR}/reporters/discord.sh" "${OVERALL_STATUS}" "${GIT_BRANCH}" "${CI_COMMIT_SHA}" "${CI_RUN_ID}" "${SUMMARY_FILE}" || true

# Generate GPU report
if [[ -f "$GPU_CSV" ]] && [[ -s "$GPU_CSV" ]]; then
    "${CI_DIR}/reporters/gpu_report.sh" "$GPU_CSV" > "${CI_RUN_LOG_DIR}/gpu_report.txt" 2>/dev/null || true
fi

log_info "CI run complete: ${OVERALL_STATUS}"
exit $([[ "${OVERALL_STATUS}" == "pass" ]] && echo 0 || echo 1)
