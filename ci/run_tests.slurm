#!/bin/bash
#SBATCH --job-name=ci-torchtitan-tests
#SBATCH --output=%x-%j.out
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --gpus-per-node=8
#SBATCH --cpus-per-task=48
#SBATCH --mem=0
#SBATCH --exclusive
#SBATCH --time=01:00:00
#SBATCH --signal=B:USR1@120

# ============================================================================
# CI Test Runner for torchtitan (single node)
# Runs unit tests, distributed tests, and integration tests
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env"

# Override log dir if provided by scheduler
CI_RUN_LOG_DIR="${CI_RUN_LOG_DIR:-${CI_LOG_DIR}/manual-${SLURM_JOB_ID}}"
CI_COMMIT_SHA="${CI_COMMIT_SHA:-HEAD}"
CI_RUN_ID="${CI_RUN_ID:-manual-${SLURM_JOB_ID}}"

mkdir -p "${CI_RUN_LOG_DIR}"

# Redirect all output to log file AND stdout
exec > >(tee -a "${CI_RUN_LOG_DIR}/full_output.log") 2>&1

SUMMARY_FILE="${CI_RUN_LOG_DIR}/summary.txt"
OVERALL_STATUS="success"
PHASE_RESULTS=()
START_TIME=$(date +%s)

# ============================================================================
# Preemption signal handler
# ============================================================================
handle_preemption() {
    echo ""
    echo "============================================================"
    echo "PREEMPTED by Slurm (USR1 signal) at $(date)"
    echo "============================================================"
    generate_summary "preempted"
    "${SCRIPT_DIR}/notify.sh" preempted "${GIT_BRANCH}" "${CI_COMMIT_SHA}" "${CI_RUN_ID}" "${SUMMARY_FILE}" || true
    exit 1
}
trap handle_preemption USR1

# ============================================================================
# Helper: run a phase with timeout and logging
# ============================================================================
run_phase() {
    local phase_name="$1"
    local timeout_val="$2"
    shift 2
    local cmd=("$@")

    local phase_log="${CI_RUN_LOG_DIR}/${phase_name}.log"
    local phase_start=$(date +%s)

    echo ""
    echo "============================================================"
    echo "Phase: ${phase_name}"
    echo "Command: ${cmd[*]}"
    echo "Timeout: ${timeout_val}"
    echo "Started: $(date)"
    echo "============================================================"

    local exit_code=0
    timeout "${timeout_val}" bash -c "${cmd[*]}" > "${phase_log}" 2>&1 || exit_code=$?

    local phase_end=$(date +%s)
    local duration=$((phase_end - phase_start))

    local status_str
    if [[ ${exit_code} -eq 0 ]]; then
        status_str="PASS"
        echo "  -> ${phase_name}: PASS (${duration}s)"
    elif [[ ${exit_code} -eq 124 ]]; then
        status_str="TIMEOUT"
        OVERALL_STATUS="failure"
        echo "  -> ${phase_name}: TIMEOUT after ${timeout_val} (${duration}s)"
    else
        status_str="FAIL (exit ${exit_code})"
        OVERALL_STATUS="failure"
        echo "  -> ${phase_name}: FAIL (exit ${exit_code}, ${duration}s)"
        # Print last 20 lines of log for quick diagnosis
        echo "  -> Last 20 lines of ${phase_name}.log:"
        tail -20 "${phase_log}" | sed 's/^/     /'
    fi

    PHASE_RESULTS+=("${phase_name}: ${status_str} (${duration}s)")
}

# ============================================================================
# Helper: run distributed test via torchrun (single node, no srun needed)
# ============================================================================
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

# ============================================================================
# Generate summary
# ============================================================================
generate_summary() {
    local final_status="${1:-${OVERALL_STATUS}}"
    local end_time=$(date +%s)
    local total_duration=$((end_time - START_TIME))

    {
        echo "torchtitan CI Run Summary"
        echo "========================="
        echo "Run ID:   ${CI_RUN_ID}"
        echo "Commit:   ${CI_COMMIT_SHA:0:7}"
        echo "Branch:   ${GIT_BRANCH}"
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

    echo ""
    cat "${SUMMARY_FILE}"
}

# ============================================================================
# Main execution
# ============================================================================
echo "============================================================"
echo "torchtitan CI Test Runner (single node)"
echo "Run ID:  ${CI_RUN_ID}"
echo "Commit:  ${CI_COMMIT_SHA}"
echo "Job ID:  ${SLURM_JOB_ID}"
echo "Node:    $(hostname)"
echo "Started: $(date)"
echo "============================================================"

# Activate venv
source "${VENV_DIR}/bin/activate"

# Checkout exact commit (avoid TOCTOU with scheduler)
cd "${TORCHTITAN_DIR}"
git checkout "${CI_COMMIT_SHA}" --quiet 2>/dev/null || {
    echo "Warning: Could not checkout ${CI_COMMIT_SHA}, using current HEAD"
    CI_COMMIT_SHA=$(git rev-parse HEAD)
}

# ============================================================================
# Phase 1: Unit Tests (plain pytest)
# ============================================================================
PYTEST_FILES=""
for f in "${UNIT_TEST_FILES[@]}"; do
    PYTEST_FILES="${PYTEST_FILES} ${f}"
done

run_phase "1_unit_tests" "${TIMEOUT_UNIT_TESTS}" \
    "cd ${TORCHTITAN_DIR} && source ${VENV_DIR}/bin/activate && \
python -m pytest -x -v ${PYTEST_FILES}"

# ============================================================================
# Phase 2: Distributed Tests (torchrun, single node)
# ============================================================================

# 2a: DeepEP token dispatcher (8 GPU)
run_torchrun_test "2a_deepep_dispatcher" \
    "${DIST_TEST_DEEPEP_NGPU}" "${RDZV_PORT_2A}" \
    "${DIST_TEST_DEEPEP}" "${TIMEOUT_DISTRIBUTED_TESTS}"

# ============================================================================
# Phase 3: Integration Tests (features suite)
# ============================================================================
INTEGRATION_OUTPUT_DIR="${CI_RUN_LOG_DIR}/integration_output"
mkdir -p "${INTEGRATION_OUTPUT_DIR}"

run_phase "3_integration_tests" "${TIMEOUT_INTEGRATION_TESTS}" \
    "cd ${TORCHTITAN_DIR} && source ${VENV_DIR}/bin/activate && \
python -m tests.integration_tests.run_tests ${INTEGRATION_OUTPUT_DIR} \
    --test_suite features --ngpu 8"

# ============================================================================
# Finalize
# ============================================================================
generate_summary

# Update last tested SHA only on full success
if [[ "${OVERALL_STATUS}" == "success" ]]; then
    echo "${CI_COMMIT_SHA}" > "${LAST_TESTED_SHA_FILE}"
    echo "Updated ${LAST_TESTED_SHA_FILE} to ${CI_COMMIT_SHA:0:7}"
fi

# Send notification
"${SCRIPT_DIR}/notify.sh" "${OVERALL_STATUS}" "${GIT_BRANCH}" "${CI_COMMIT_SHA}" "${CI_RUN_ID}" "${SUMMARY_FILE}" || true

echo ""
echo "CI run complete: ${OVERALL_STATUS}"
exit $([[ "${OVERALL_STATUS}" == "success" ]] && echo 0 || echo 1)
