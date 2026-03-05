#!/usr/bin/env bash
# =============================================================================
# coverage.sh — Run pytest with coverage and check thresholds
# =============================================================================
# Usage: ./coverage.sh [--threshold N]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
load_config

THRESHOLD="${1:-${QUALITY_COVERAGE_THRESHOLD:-0}}"

if [[ ! -d "${TORCHTITAN_DIR}" ]]; then
    log_error "torchtitan directory not found"
    exit 1
fi

cd "${TORCHTITAN_DIR}"
activate_venv

log_info "Running test coverage analysis..."

COVERAGE_JSON="${CI_DATA_DIR}/coverage.json"
ensure_dir "$(dirname "$COVERAGE_JSON")"

# Build pytest file list
PYTEST_FILES=""
for f in "${UNIT_TEST_FILES[@]}"; do
    if [[ -f "$f" ]]; then
        PYTEST_FILES="${PYTEST_FILES} ${f}"
    fi
done

if [[ -z "${PYTEST_FILES}" ]]; then
    log_warn "No test files found"
    exit 0
fi

EXIT_CODE=0
python -m pytest ${PYTEST_FILES} \
    --cov=torchtitan \
    --cov-report=term-missing \
    --cov-report=json:"${COVERAGE_JSON}" \
    -q --tb=no 2>&1 || EXIT_CODE=$?

# Extract coverage percentage
if [[ -f "${COVERAGE_JSON}" ]]; then
    TOTAL_COV=$(python3 -c "
import json
with open('${COVERAGE_JSON}') as f:
    data = json.load(f)
print(f\"{data['totals']['percent_covered']:.1f}\")
" 2>/dev/null || echo "0")

    log_info "Total coverage: ${TOTAL_COV}%"

    # Check threshold
    if [[ "${THRESHOLD}" -gt 0 ]]; then
        MEETS=$(python3 -c "print('yes' if float('${TOTAL_COV}') >= ${THRESHOLD} else 'no')" 2>/dev/null)
        if [[ "$MEETS" == "no" ]]; then
            log_error "Coverage ${TOTAL_COV}% is below threshold ${THRESHOLD}%"
            exit 1
        fi
        log_info "Coverage meets threshold (${TOTAL_COV}% >= ${THRESHOLD}%)"
    fi
else
    log_warn "Coverage report not generated"
fi

exit $EXIT_CODE
