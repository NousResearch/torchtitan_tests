#!/usr/bin/env bash
# =============================================================================
# pre_commit.sh — Run pre-commit hooks on torchtitan codebase
# =============================================================================
# Usage: ./pre_commit.sh [--fix] [--files file1 file2 ...]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
load_config

FIX_MODE=false
FILES=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --fix)   FIX_MODE=true; shift ;;
        --files) shift; FILES=("$@"); break ;;
        *)       shift ;;
    esac
done

if [[ ! -d "${TORCHTITAN_DIR}/.git" ]]; then
    log_error "torchtitan repository not found at ${TORCHTITAN_DIR}"
    exit 1
fi

if [[ ! -f "${TORCHTITAN_DIR}/.pre-commit-config.yaml" ]]; then
    log_error "No .pre-commit-config.yaml found in torchtitan"
    exit 1
fi

cd "${TORCHTITAN_DIR}"
activate_venv

log_info "Running pre-commit hooks..."

PRE_COMMIT_ARGS=("run" "--show-diff-on-failure")

if [[ ${#FILES[@]} -gt 0 ]]; then
    PRE_COMMIT_ARGS+=("--files" "${FILES[@]}")
    log_info "Running on ${#FILES[@]} specified files"
else
    PRE_COMMIT_ARGS+=("--all-files")
    log_info "Running on all files"
fi

EXIT_CODE=0
pre-commit "${PRE_COMMIT_ARGS[@]}" 2>&1 || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 && "$FIX_MODE" == "true" ]]; then
    log_info "Attempting auto-fix..."
    # ufmt format (black + usort) for auto-fixable issues
    if command -v ufmt &>/dev/null; then
        ufmt format . 2>/dev/null || true
    fi
    # Re-run pre-commit to check if fixes resolved issues
    pre-commit "${PRE_COMMIT_ARGS[@]}" 2>&1 || EXIT_CODE=$?
fi

if [[ $EXIT_CODE -eq 0 ]]; then
    log_info "Pre-commit: all hooks passed"
else
    log_warn "Pre-commit: some hooks failed (exit ${EXIT_CODE})"
fi

exit $EXIT_CODE
