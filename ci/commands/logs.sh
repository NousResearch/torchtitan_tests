#!/usr/bin/env bash
# =============================================================================
# ttci logs — View and search run logs
# =============================================================================
# Usage: ttci logs [--run <id>] [--follow] [--grep <pattern>] [--gpu]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
load_config

# Parse args
RUN_ID=""
FOLLOW=false
GREP_PATTERN=""
GPU_MODE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --run)     RUN_ID="$2"; shift 2 ;;
        --follow)  FOLLOW=true; shift ;;
        --grep)    GREP_PATTERN="$2"; shift 2 ;;
        --gpu)     GPU_MODE=true; shift ;;
        --help|-h)
            echo "Usage: ttci logs [--run <id>] [--follow] [--grep <pattern>] [--gpu]"
            echo ""
            echo "Options:"
            echo "  --run <id>      Show logs for specific run ID"
            echo "  --follow        Tail -f active job log"
            echo "  --grep <pat>    Search across logs"
            echo "  --gpu           Show GPU monitoring report"
            exit 0
            ;;
        *) log_error "Unknown option: $1"; exit 1 ;;
    esac
done

# Find the target log directory
if [[ -n "$RUN_ID" ]]; then
    LOG_DIR="${CI_LOG_DIR}/${RUN_ID}"
    if [[ ! -d "$LOG_DIR" ]]; then
        # Try to find by partial match
        LOG_DIR=$(find "${CI_LOG_DIR}" -maxdepth 1 -type d -name "*${RUN_ID}*" | head -1)
        if [[ -z "$LOG_DIR" ]]; then
            log_error "Run not found: ${RUN_ID}"
            exit 1
        fi
    fi
else
    # Latest run
    LOG_DIR=$(find "${CI_LOG_DIR}" -maxdepth 1 -type d -name "20*" 2>/dev/null | sort | tail -1)
    if [[ -z "$LOG_DIR" ]]; then
        # Also check manual/bench runs
        LOG_DIR=$(find "${CI_LOG_DIR}" -maxdepth 1 -type d 2>/dev/null | sort | tail -1)
    fi
    if [[ -z "$LOG_DIR" || "$LOG_DIR" == "$CI_LOG_DIR" ]]; then
        log_error "No run logs found"
        exit 1
    fi
fi

RUN_NAME=$(basename "$LOG_DIR")
log_info "Logs for run: ${RUN_NAME}"
log_info "Directory: ${LOG_DIR}"
echo ""

# Grep mode
if [[ -n "$GREP_PATTERN" ]]; then
    log_info "Searching for: ${GREP_PATTERN}"
    grep -rn --color=always "$GREP_PATTERN" "$LOG_DIR" 2>/dev/null || echo "No matches found."
    exit 0
fi

# GPU mode
if [[ "$GPU_MODE" == "true" ]]; then
    GPU_CSV="${LOG_DIR}/gpu_monitor.csv"
    if [[ -f "$GPU_CSV" ]]; then
        "${SCRIPT_DIR}/../reporters/gpu_report.sh" "$GPU_CSV"
    else
        log_warn "No GPU monitoring data found for this run"
    fi
    exit 0
fi

# Follow mode
if [[ "$FOLLOW" == "true" ]]; then
    FULL_LOG="${LOG_DIR}/full_output.log"
    if [[ -f "$FULL_LOG" ]]; then
        tail -f "$FULL_LOG"
    else
        log_error "No log file found at ${FULL_LOG}"
        exit 1
    fi
    exit 0
fi

# Default: show summary then tail full log
if [[ -f "${LOG_DIR}/summary.txt" ]]; then
    cat "${LOG_DIR}/summary.txt"
    echo ""
fi

FULL_LOG="${LOG_DIR}/full_output.log"
if [[ -f "$FULL_LOG" ]]; then
    hr
    echo "Last 50 lines of full_output.log:"
    hr
    tail -50 "$FULL_LOG"
else
    # List available log files
    echo "Available log files:"
    find "$LOG_DIR" -type f -name "*.log" -o -name "*.txt" -o -name "*.csv" -o -name "*.json" 2>/dev/null | sort | while read -r f; do
        SIZE=$(du -sh "$f" 2>/dev/null | awk '{print $1}')
        echo "  ${SIZE}  $(basename "$f")"
    done
fi
