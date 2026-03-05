#!/usr/bin/env bash
# =============================================================================
# run_quality.sh — Orchestrate all quality checks
# =============================================================================
# Usage: ./run_quality.sh [--ci] [--pr <files...>]
#   --ci     Run in CI mode (non-interactive, structured output)
#   --pr     Run only on changed files (for PR testing)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
load_config

CI_MODE=false
PR_FILES=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ci)  CI_MODE=true; shift ;;
        --pr)  shift; PR_FILES="$*"; break ;;
        *)     shift ;;
    esac
done

OVERALL_EXIT=0
RESULTS=()

run_check() {
    local name="$1"
    local script="$2"
    shift 2

    section "Quality Check: ${name}"

    local exit_code=0
    bash "$script" "$@" || exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
        RESULTS+=("${GREEN}[PASS]${NC} ${name}")
        log_info "${name}: PASS"
    else
        RESULTS+=("${RED}[FAIL]${NC} ${name}")
        log_warn "${name}: FAIL (exit ${exit_code})"
        OVERALL_EXIT=1
    fi
}

# Pre-commit
if [[ "${QUALITY_PRE_COMMIT:-true}" == "true" ]]; then
    if [[ -n "$PR_FILES" ]]; then
        run_check "pre-commit (PR files)" "${SCRIPT_DIR}/pre_commit.sh" --files $PR_FILES
    else
        run_check "pre-commit" "${SCRIPT_DIR}/pre_commit.sh"
    fi
fi

# Coverage
run_check "test-coverage" "${SCRIPT_DIR}/coverage.sh"

# Shellcheck
if [[ "${QUALITY_SHELLCHECK:-true}" == "true" ]]; then
    run_check "shellcheck" "${SCRIPT_DIR}/shellcheck.sh"
fi

# Summary
section "Quality Summary"
for result in "${RESULTS[@]}"; do
    echo -e "  ${result}"
done
echo ""

if [[ $OVERALL_EXIT -eq 0 ]]; then
    log_info "All quality checks passed"
else
    log_warn "Some quality checks failed"
fi

exit $OVERALL_EXIT
