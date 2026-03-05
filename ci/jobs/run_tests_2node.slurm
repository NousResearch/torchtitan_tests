#!/bin/bash
#SBATCH --job-name=ci-torchtitan-2n
#SBATCH --output=%x-%j.out
#SBATCH --nodes=2
#SBATCH --ntasks=2
#SBATCH --gpus-per-node=8
#SBATCH --cpus-per-task=48
#SBATCH --mem=0
#SBATCH --exclusive
#SBATCH --time=02:00:00
#SBATCH --signal=B:USR1@120

# =============================================================================
# CI Test Runner — 2 Node (multi-node distributed + integration)
# =============================================================================
# Triggered by: daily_scheduler or manual `ttci run --2node`
# Uses srun + torchrun for cross-node coordination
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
load_config
setup_environment

# Override with scheduler-provided values or defaults
CI_RUN_LOG_DIR="${CI_RUN_LOG_DIR:-${CI_LOG_DIR}/manual-2n-${SLURM_JOB_ID}}"
CI_COMMIT_SHA="${CI_COMMIT_SHA:-HEAD}"
CI_RUN_ID="${CI_RUN_ID:-manual-2n-$(generate_run_id)}"
CI_TRIGGER="${CI_TRIGGER:-manual}"
CI_SUITE="${CI_SUITE:-all}"

ensure_dir "${CI_RUN_LOG_DIR}"

exec > >(tee -a "${CI_RUN_LOG_DIR}/full_output.log") 2>&1

SUMMARY_FILE="${CI_RUN_LOG_DIR}/summary.txt"
SUMMARY_JSON="${CI_RUN_LOG_DIR}/summary.json"
GPU_CSV="${CI_RUN_LOG_DIR}/gpu_monitor.csv"
OVERALL_STATUS="pass"
PHASE_RESULTS=()
PHASE_JSON_PARTS=()
START_TIME=$(date +%s)

# =============================================================================
# Multi-node setup — extract head node IP
# =============================================================================
nodes=( $( scontrol show hostnames $SLURM_JOB_NODELIST ) )
nodes_array=($nodes)
head_node=${nodes_array[0]}
head_node_ip=$(srun --nodes=1 --ntasks=1 -w "$head_node" hostname --ip-address)

log_info "Head node: ${head_node} (${head_node_ip})"
log_info "All nodes: ${nodes[*]}"

# =============================================================================
# GPU Monitoring (on head node only)
# =============================================================================
source "${SCRIPT_DIR}/../lib/gpu_monitor.sh"
start_gpu_monitor "$GPU_CSV"

# =============================================================================
# Preemption handler
# =============================================================================
handle_preemption() {
    log_error "PREEMPTED by Slurm (USR1 signal) at $(date)"
    stop_gpu_monitor
    generate_summary "preempted"
    "${SCRIPT_DIR}/../reporters/discord.sh" preempted "${GIT_BRANCH}" "${CI_COMMIT_SHA}" "${CI_RUN_ID}" "${SUMMARY_FILE}" || true
    exit 1
}
trap handle_preemption USR1
trap 'stop_gpu_monitor' EXIT

# =============================================================================
# Phase runner (same pattern as 1-node)
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
        tail -20 "${phase_log}" | sed 's/^/     /'
    fi

    PHASE_RESULTS+=("${phase_name}: ${status_str^^} (${duration}s)")
    PHASE_JSON_PARTS+=("\"${phase_name}\": {\"status\": \"${status_str}\", \"passed\": ${passed:-0}, \"failed\": ${failed:-0}, \"skipped\": ${skipped:-0}, \"duration_sec\": ${duration}, \"exit_code\": ${exit_code}}")
}

# Multi-node torchrun via srun
run_multinode_torchrun() {
    local phase_name="$1"
    local nnodes="$2"
    local ngpu="$3"
    local rdzv_port="$4"
    local test_module="$5"
    local timeout_val="$6"

    local cmd="cd ${TORCHTITAN_DIR} && \
source ${VENV_DIR}/bin/activate && \
srun torchrun \
    --nnodes=${nnodes} \
    --nproc_per_node=${ngpu} \
    --rdzv_id=${SLURM_JOB_ID}_${phase_name} \
    --rdzv_backend=c10d \
    --rdzv_endpoint=${head_node_ip}:${rdzv_port} \
    -m ${test_module}"

    run_phase "${phase_name}" "${timeout_val}" "${cmd}"
}

# Multi-node integration suite
run_multinode_integration() {
    local suite_name="$1"
    local ngpu="$2"
    local timeout_val="$3"

    local output_dir="${CI_RUN_LOG_DIR}/integration_${suite_name}"
    mkdir -p "${output_dir}"

    local cmd="cd ${TORCHTITAN_DIR} && \
source ${VENV_DIR}/bin/activate && \
srun torchrun \
    --nnodes=${SLURM_NNODES} \
    --nproc_per_node=${ngpu} \
    --rdzv_id=${SLURM_JOB_ID}_integ_${suite_name} \
    --rdzv_backend=c10d \
    --rdzv_endpoint=${head_node_ip}:29502 \
    -m tests.integration_tests.run_tests ${output_dir} \
    --test_suite ${suite_name} --ngpu ${ngpu}"

    run_phase "integration_${suite_name}" "${timeout_val}" "${cmd}"
}

# =============================================================================
# Generate summary
# =============================================================================
generate_summary() {
    local final_status="${1:-${OVERALL_STATUS}}"
    local end_time=$(date +%s)
    local total_duration=$((end_time - START_TIME))

    {
        echo "torchtitan CI Run Summary (2-node)"
        echo "===================================="
        echo "Run ID:   ${CI_RUN_ID}"
        echo "Commit:   ${CI_COMMIT_SHA:0:7}"
        echo "Branch:   ${GIT_BRANCH}"
        echo "Trigger:  ${CI_TRIGGER}"
        echo "Status:   ${final_status^^}"
        echo "Duration: ${total_duration}s"
        echo "Job ID:   ${SLURM_JOB_ID}"
        echo "Nodes:    ${nodes[*]}"
        echo "Date:     $(date)"
        echo ""
        echo "Phase Results:"
        for result in "${PHASE_RESULTS[@]}"; do
            echo "  ${result}"
        done
    } > "${SUMMARY_FILE}"

    cat "${SUMMARY_FILE}"

    local phases_json
    phases_json=$(printf ", %s" "${PHASE_JSON_PARTS[@]}")
    phases_json="{${phases_json:2}}"

    local gpu_stats="{}"
    if [[ -f "$GPU_CSV" ]] && [[ -s "$GPU_CSV" ]]; then
        gpu_stats=$("${SCRIPT_DIR}/../reporters/gpu_report.sh" --json "$GPU_CSV" 2>/dev/null || echo "{}")
    fi

    cat > "${SUMMARY_JSON}" <<ENDJSON
{
  "run_id": "${CI_RUN_ID}",
  "trigger": "${CI_TRIGGER}",
  "sha": "${CI_COMMIT_SHA}",
  "branch": "${GIT_BRANCH}",
  "node_count": 2,
  "job_id": "${SLURM_JOB_ID}",
  "nodes": ["${nodes_array[0]}", "${nodes_array[1]}"],
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "phases": ${phases_json},
  "gpu_stats": ${gpu_stats},
  "overall_status": "${final_status}",
  "total_duration_sec": ${total_duration}
}
ENDJSON

    local jsonl_entry
    jsonl_entry=$(tr -d '\n' < "${SUMMARY_JSON}" | tr -s ' ')
    append_jsonl "${CI_DATA_DIR}/runs.jsonl" "${jsonl_entry}"
}

# =============================================================================
# Main execution
# =============================================================================
section "torchtitan CI Test Runner (2-node)"
log_info "Run ID:  ${CI_RUN_ID}"
log_info "Commit:  ${CI_COMMIT_SHA}"
log_info "Job ID:  ${SLURM_JOB_ID}"
log_info "Nodes:   ${nodes[*]}"
log_info "Head:    ${head_node} (${head_node_ip})"

activate_venv

cd "${TORCHTITAN_DIR}"
git checkout "${CI_COMMIT_SHA}" --quiet 2>/dev/null || {
    log_warn "Could not checkout ${CI_COMMIT_SHA}, using current HEAD"
    CI_COMMIT_SHA=$(git rev-parse HEAD)
}

# --- Phase 1: Multi-node distributed tests ---
if [[ "${CI_SUITE}" == "all" || "${CI_SUITE}" == "distributed" ]]; then
    run_multinode_torchrun "multinode_deepep" \
        2 8 29501 \
        "${DIST_TEST_DEEPEP_MODULE}" "${TIMEOUT_DISTRIBUTED_TESTS}"
fi

# --- Phase 2: Multi-node integration tests ---
if [[ "${CI_SUITE}" == "all" || "${CI_SUITE}" == "integration" ]]; then
    run_multinode_integration "models" 8 "${TIMEOUT_INTEGRATION_TESTS}"
fi

# =============================================================================
# Finalize
# =============================================================================
stop_gpu_monitor
generate_summary

if [[ "${OVERALL_STATUS}" == "pass" ]]; then
    echo "${CI_COMMIT_SHA}" > "${LAST_TESTED_SHA_FILE}"
    log_info "Updated last tested SHA to ${CI_COMMIT_SHA:0:7}"
fi

"${SCRIPT_DIR}/../reporters/discord.sh" "${OVERALL_STATUS}" "${GIT_BRANCH}" "${CI_COMMIT_SHA}" "${CI_RUN_ID}" "${SUMMARY_FILE}" || true

if [[ -f "$GPU_CSV" ]] && [[ -s "$GPU_CSV" ]]; then
    "${SCRIPT_DIR}/../reporters/gpu_report.sh" "$GPU_CSV" > "${CI_RUN_LOG_DIR}/gpu_report.txt" 2>/dev/null || true
fi

log_info "CI run complete: ${OVERALL_STATUS}"
exit $([[ "${OVERALL_STATUS}" == "pass" ]] && echo 0 || echo 1)
