#!/usr/bin/env bash
# =============================================================================
# gpu_monitor.sh — nvidia-smi CSV collector (background sampling)
# =============================================================================

[[ -n "${_TTCI_GPU_MONITOR_LOADED:-}" ]] && return 0
_TTCI_GPU_MONITOR_LOADED=1

SCRIPT_DIR_GPU="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR_GPU}/common.sh"

GPU_MONITOR_PID_FILE="${CI_STATE_DIR:-.}/.gpu_monitor.pid"

# Start GPU monitoring in background
# Usage: start_gpu_monitor <output_csv> [interval_sec]
start_gpu_monitor() {
    local output_csv="$1"
    local interval="${2:-${GPU_MONITOR_INTERVAL:-5}}"

    if [[ "${GPU_MONITOR_ENABLED:-true}" != "true" ]]; then
        log_debug "GPU monitoring disabled"
        return 0
    fi

    if ! command -v nvidia-smi &>/dev/null; then
        log_warn "nvidia-smi not found, GPU monitoring disabled"
        return 0
    fi

    ensure_dir "$(dirname "$output_csv")"

    # Write CSV header
    echo "timestamp,index,utilization.gpu [%],memory.used [MiB],memory.total [MiB],temperature.gpu,power.draw [W]" > "$output_csv"

    # Launch nvidia-smi in background
    nvidia-smi \
        --query-gpu=timestamp,index,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw \
        --format=csv,nounits,noheader \
        -l "$interval" >> "$output_csv" 2>/dev/null &

    local pid=$!
    echo "$pid" > "$GPU_MONITOR_PID_FILE"
    log_info "GPU monitor started (PID=$pid, interval=${interval}s, output=$output_csv)"
}

# Stop GPU monitoring
stop_gpu_monitor() {
    if [[ -f "$GPU_MONITOR_PID_FILE" ]]; then
        local pid
        pid=$(cat "$GPU_MONITOR_PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
            wait "$pid" 2>/dev/null || true
            log_info "GPU monitor stopped (PID=$pid)"
        fi
        rm -f "$GPU_MONITOR_PID_FILE"
    fi
}

# Check if GPU monitor is running
is_gpu_monitor_running() {
    if [[ -f "$GPU_MONITOR_PID_FILE" ]]; then
        local pid
        pid=$(cat "$GPU_MONITOR_PID_FILE")
        kill -0 "$pid" 2>/dev/null && return 0
    fi
    return 1
}
