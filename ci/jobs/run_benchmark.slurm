#!/bin/bash
#SBATCH --job-name=ci-torchtitan-bench
#SBATCH --output=%x-%j.out
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --gpus-per-node=8
#SBATCH --cpus-per-task=48
#SBATCH --mem=0
#SBATCH --exclusive
#SBATCH --time=01:00:00
#SBATCH --signal=B:USR1@120

# =============================================================================
# CI Benchmark Runner
# =============================================================================
# Accepts benchmark name as CI_BENCHMARK_NAME env var.
# Runs torchtitan training for N steps and extracts performance metrics.
# GPU monitoring at 1-second intervals.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
load_config
setup_environment

CI_RUN_LOG_DIR="${CI_RUN_LOG_DIR:-${CI_LOG_DIR}/bench-${SLURM_JOB_ID}}"
CI_COMMIT_SHA="${CI_COMMIT_SHA:-HEAD}"
CI_RUN_ID="${CI_RUN_ID:-bench-$(generate_run_id)}"
CI_BENCHMARK_NAME="${CI_BENCHMARK_NAME:-qwen3_30b_a3b_deepep}"

ensure_dir "${CI_RUN_LOG_DIR}"

exec > >(tee -a "${CI_RUN_LOG_DIR}/full_output.log") 2>&1

GPU_CSV="${CI_RUN_LOG_DIR}/gpu_monitor.csv"
TRAIN_LOG="${CI_RUN_LOG_DIR}/train.log"
START_TIME=$(date +%s)

# =============================================================================
# GPU Monitoring (1-second intervals for benchmarks)
# =============================================================================
source "${SCRIPT_DIR}/../lib/gpu_monitor.sh"
start_gpu_monitor "$GPU_CSV" 1

# Preemption handler
handle_preemption() {
    log_error "PREEMPTED during benchmark at $(date)"
    stop_gpu_monitor
    "${SCRIPT_DIR}/../reporters/discord.sh" preempted "${GIT_BRANCH}" "${CI_COMMIT_SHA}" "${CI_RUN_ID}" "" || true
    exit 1
}
trap handle_preemption USR1
trap 'stop_gpu_monitor' EXIT

# =============================================================================
# Lookup benchmark config from config.yaml
# =============================================================================
# Parse benchmark config — find matching benchmark entry
BENCH_CONFIG=""
BENCH_NGPU=""
BENCH_STEPS=""

# Use python to parse benchmark config from YAML
eval "$(python3 -c "
import sys
name = '${CI_BENCHMARK_NAME}'
in_benchmarks = False
current = {}
with open('${TTCI_CONFIG}') as f:
    for line in f:
        stripped = line.strip()
        if stripped == 'benchmarks:':
            in_benchmarks = True
            continue
        if in_benchmarks:
            if line.startswith('  - name:'):
                if current.get('name') == name:
                    break
                current = {'name': stripped.split(':', 1)[1].strip()}
            elif line.startswith('    ') and ':' in stripped and in_benchmarks:
                k, v = stripped.split(':', 1)
                current[k.strip()] = v.strip()
            elif not line.startswith(' ') and stripped:
                break
if current.get('name') == name:
    print(f\"BENCH_CONFIG='{current.get('config', '')}'\" )
    print(f\"BENCH_NGPU='{current.get('ngpu', '8')}'\" )
    print(f\"BENCH_STEPS='{current.get('steps', '20')}'\" )
    print(f\"BENCH_THRESHOLD='{current.get('regression_threshold_pct', '10')}'\" )
else:
    print('echo \"Benchmark not found: ${CI_BENCHMARK_NAME}\"; exit 1')
" 2>/dev/null)"

section "torchtitan Benchmark Runner"
log_info "Benchmark: ${CI_BENCHMARK_NAME}"
log_info "Config:    ${BENCH_CONFIG}"
log_info "GPUs:      ${BENCH_NGPU}"
log_info "Steps:     ${BENCH_STEPS}"
log_info "Commit:    ${CI_COMMIT_SHA}"
log_info "Job ID:    ${SLURM_JOB_ID}"

# Activate venv and checkout
activate_venv
cd "${TORCHTITAN_DIR}"
git checkout "${CI_COMMIT_SHA}" --quiet 2>/dev/null || {
    log_warn "Could not checkout ${CI_COMMIT_SHA}, using current HEAD"
    CI_COMMIT_SHA=$(git rev-parse HEAD)
}

# Pause DCGM profiling if available
command -v dcgmi &> /dev/null && dcgmi profile --pause || true

# =============================================================================
# Run benchmark
# =============================================================================
log_info "Starting benchmark training..."

BENCH_EXIT=0
timeout "${TIMEOUT_BENCHMARK}" torchrun \
    --nnodes=1 \
    --nproc_per_node="${BENCH_NGPU}" \
    --rdzv_id="${SLURM_JOB_ID}_bench" \
    --rdzv_backend=c10d \
    --rdzv_endpoint=localhost:29500 \
    -m torchtitan.train \
    --job.config_file "${BENCH_CONFIG}" \
    --training.steps "${BENCH_STEPS}" \
    --job.dump_folder "${CI_RUN_LOG_DIR}/dump" \
    --job.description "CI benchmark: ${CI_BENCHMARK_NAME}" \
    > "${TRAIN_LOG}" 2>&1 || BENCH_EXIT=$?

# Resume DCGM profiling
command -v dcgmi &> /dev/null && dcgmi profile --resume || true

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

# =============================================================================
# Extract metrics from training log
# =============================================================================
log_info "Extracting metrics..."

LAST_METRICS=$(grep -E "step:.*tps:.*tflops:.*mfu:" "${TRAIN_LOG}" 2>/dev/null | tail -1 || echo "")

TPS=0; MFU=0; TFLOPS=0; MAX_MEMORY_GIB=0

if [[ -n "${LAST_METRICS}" ]]; then
    TPS=$(echo "${LAST_METRICS}" | grep -oP 'tps:\s*\K[0-9,]+' | tr -d ',' || echo 0)
    TFLOPS=$(echo "${LAST_METRICS}" | grep -oP 'tflops:\s*\K[0-9,]+' | tr -d ',' || echo 0)
    MFU=$(echo "${LAST_METRICS}" | grep -oP 'mfu:\s*\K[0-9.]+' || echo 0)
    MAX_MEMORY_GIB=$(echo "${LAST_METRICS}" | grep -oP 'memory:\s*\K[0-9.]+(?=GiB)' || echo 0)
    log_info "Metrics: TPS=${TPS}, MFU=${MFU}%, TFLOPS=${TFLOPS}, Memory=${MAX_MEMORY_GIB}GiB"
else
    log_warn "No metrics found in training log"
fi

# =============================================================================
# Stop GPU monitor and get stats
# =============================================================================
stop_gpu_monitor

GPU_STATS="{}"
if [[ -f "$GPU_CSV" ]] && [[ -s "$GPU_CSV" ]]; then
    GPU_STATS=$("${SCRIPT_DIR}/../reporters/gpu_report.sh" --json "$GPU_CSV" 2>/dev/null || echo "{}")
fi

# =============================================================================
# Save benchmark result to benchmarks.jsonl
# =============================================================================
BENCH_STATUS="pass"
[[ ${BENCH_EXIT} -ne 0 ]] && BENCH_STATUS="fail"

BENCH_JSON=$(cat <<ENDJSON
{"timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)", "sha": "${CI_COMMIT_SHA}", "benchmark": "${CI_BENCHMARK_NAME}", "status": "${BENCH_STATUS}", "metrics": {"tps": ${TPS}, "mfu": ${MFU}, "tflops": ${TFLOPS}, "max_memory_gib": ${MAX_MEMORY_GIB}}, "gpu_stats": ${GPU_STATS}, "duration_sec": ${DURATION}, "regression_detected": false}
ENDJSON
)

append_jsonl "${CI_DATA_DIR}/benchmarks.jsonl" "${BENCH_JSON}"
log_info "Benchmark result saved to benchmarks.jsonl"

# =============================================================================
# Check for regression
# =============================================================================
REGRESSION_RESULT=""
if [[ "${BENCH_STATUS}" == "pass" ]]; then
    REGRESSION_RESULT=$("${SCRIPT_DIR}/../reporters/regression.sh" \
        "${CI_BENCHMARK_NAME}" "${TPS}" "${MFU}" "${TFLOPS}" "${MAX_MEMORY_GIB}" \
        2>/dev/null || echo "")

    if [[ "${REGRESSION_RESULT}" == *"REGRESSION"* ]]; then
        log_warn "Performance regression detected!"
        echo "${REGRESSION_RESULT}" | tee "${CI_RUN_LOG_DIR}/regression_report.txt"
        # Update JSONL with regression flag
        # (The regression reporter handles notifications)
    fi
fi

# =============================================================================
# Generate summary
# =============================================================================
{
    echo "torchtitan Benchmark Summary"
    echo "============================"
    echo "Benchmark: ${CI_BENCHMARK_NAME}"
    echo "Commit:    ${CI_COMMIT_SHA:0:7}"
    echo "Status:    ${BENCH_STATUS^^}"
    echo "Duration:  ${DURATION}s"
    echo ""
    echo "Metrics:"
    echo "  TPS:        ${TPS}"
    echo "  MFU:        ${MFU}%"
    echo "  TFLOPS:     ${TFLOPS}"
    echo "  Max Memory: ${MAX_MEMORY_GIB} GiB"
    if [[ -n "${REGRESSION_RESULT}" ]]; then
        echo ""
        echo "Regression Report:"
        echo "${REGRESSION_RESULT}"
    fi
} > "${CI_RUN_LOG_DIR}/summary.txt"

cat "${CI_RUN_LOG_DIR}/summary.txt"

# GPU report
if [[ -f "$GPU_CSV" ]] && [[ -s "$GPU_CSV" ]]; then
    "${SCRIPT_DIR}/../reporters/gpu_report.sh" "$GPU_CSV" > "${CI_RUN_LOG_DIR}/gpu_report.txt" 2>/dev/null || true
fi

# Discord notification
"${SCRIPT_DIR}/../reporters/discord.sh" "${BENCH_STATUS}" "${GIT_BRANCH}" "${CI_COMMIT_SHA}" "${CI_RUN_ID}" "${CI_RUN_LOG_DIR}/summary.txt" || true

log_info "Benchmark complete: ${BENCH_STATUS}"
exit $([[ "${BENCH_STATUS}" == "pass" ]] && echo 0 || echo 1)
