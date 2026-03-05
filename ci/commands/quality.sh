#!/usr/bin/env bash
# =============================================================================
# ttci quality — Run code quality checks
# =============================================================================
# Usage: ttci quality [--pre-commit] [--coverage] [--shellcheck] [--fix]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
load_config

# Parse args
PRE_COMMIT_ONLY=false
COVERAGE_ONLY=false
SHELLCHECK_ONLY=false
FIX_MODE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --pre-commit)  PRE_COMMIT_ONLY=true; shift ;;
        --coverage)    COVERAGE_ONLY=true; shift ;;
        --shellcheck)  SHELLCHECK_ONLY=true; shift ;;
        --fix)         FIX_MODE=true; shift ;;
        --help|-h)
            echo "Usage: ttci quality [--pre-commit] [--coverage] [--shellcheck] [--fix]"
            echo ""
            echo "Options:"
            echo "  --pre-commit   Only run pre-commit hooks"
            echo "  --coverage     Only run test coverage"
            echo "  --shellcheck   Only run shellcheck on CI scripts"
            echo "  --fix          Auto-fix where possible"
            exit 0
            ;;
        *) log_error "Unknown option: $1"; exit 1 ;;
    esac
done

QUALITY_DIR="${SCRIPT_DIR}/../quality"
RUN_ALL=true

if [[ "$PRE_COMMIT_ONLY" == "true" || "$COVERAGE_ONLY" == "true" || "$SHELLCHECK_ONLY" == "true" ]]; then
    RUN_ALL=false
fi

OVERALL_EXIT=0

# Pre-commit
if [[ "$RUN_ALL" == "true" || "$PRE_COMMIT_ONLY" == "true" ]]; then
    if [[ "$FIX_MODE" == "true" ]]; then
        bash "${QUALITY_DIR}/pre_commit.sh" --fix || OVERALL_EXIT=1
    else
        bash "${QUALITY_DIR}/pre_commit.sh" || OVERALL_EXIT=1
    fi
fi

# Coverage
if [[ "$RUN_ALL" == "true" || "$COVERAGE_ONLY" == "true" ]]; then
    bash "${QUALITY_DIR}/coverage.sh" || OVERALL_EXIT=1
fi

# Shellcheck
if [[ "$RUN_ALL" == "true" || "$SHELLCHECK_ONLY" == "true" ]]; then
    bash "${QUALITY_DIR}/shellcheck.sh" || OVERALL_EXIT=1
fi

# Summary
echo ""
if [[ $OVERALL_EXIT -eq 0 ]]; then
    log_info "All quality checks passed"
else
    log_warn "Some quality checks failed"
fi

exit $OVERALL_EXIT
