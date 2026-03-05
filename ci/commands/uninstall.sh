#!/usr/bin/env bash
# =============================================================================
# ttci uninstall — Remove cron jobs and clean up
# =============================================================================
# Usage: ttci uninstall [--all]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
load_config

CLEAN_ALL=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --all)    CLEAN_ALL=true; shift ;;
        --help|-h)
            echo "Usage: ttci uninstall [--all]"
            echo ""
            echo "Options:"
            echo "  --all    Also clean logs, state, and data directories"
            exit 0
            ;;
        *) log_error "Unknown option: $1"; exit 1 ;;
    esac
done

section "ttci Uninstall"

# Remove cron jobs
log_info "Removing cron jobs..."
CURRENT_CRON=$(crontab -l 2>/dev/null || true)
if echo "$CURRENT_CRON" | grep -q "ttci-"; then
    echo "$CURRENT_CRON" | grep -v "ttci-" | crontab - 2>/dev/null || true
    log_info "Cron jobs removed"
else
    log_info "No ttci cron jobs found"
fi

# Also remove legacy cron entries
if echo "$CURRENT_CRON" | grep -q "torchtitan-ci-scheduler"; then
    CURRENT_CRON=$(crontab -l 2>/dev/null || true)
    echo "$CURRENT_CRON" | grep -v "torchtitan-ci-scheduler" | crontab - 2>/dev/null || true
    log_info "Legacy cron job removed"
fi

# Cancel running CI jobs
log_info "Checking for running CI jobs..."
source "${SCRIPT_DIR}/../lib/slurm_helpers.sh"
cancel_job "${SLURM_JOB_PREFIX}" 2>/dev/null || true

# Clean up if --all
if [[ "$CLEAN_ALL" == "true" ]]; then
    log_warn "Cleaning all data..."

    if [[ -d "${CI_LOG_DIR}" ]]; then
        rm -rf "${CI_LOG_DIR}"/*
        log_info "Logs cleaned: ${CI_LOG_DIR}"
    fi

    if [[ -d "${CI_STATE_DIR}" ]]; then
        rm -rf "${CI_STATE_DIR}"/*
        log_info "State cleaned: ${CI_STATE_DIR}"
    fi

    if [[ -d "${CI_DATA_DIR}" ]]; then
        rm -rf "${CI_DATA_DIR}"/*
        log_info "Data cleaned: ${CI_DATA_DIR}"
    fi
fi

echo ""
log_info "Uninstall complete."
