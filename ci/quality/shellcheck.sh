#!/usr/bin/env bash
# =============================================================================
# shellcheck.sh — Lint all CI bash scripts
# =============================================================================
# Usage: ./shellcheck.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
load_config

log_info "Running shellcheck on CI scripts..."

# Try to find shellcheck
SHELLCHECK_BIN=""
if command -v shellcheck &>/dev/null; then
    SHELLCHECK_BIN="shellcheck"
elif [[ -f "${VENV_DIR}/bin/shellcheck" ]]; then
    SHELLCHECK_BIN="${VENV_DIR}/bin/shellcheck"
else
    # Try installing shellcheck-py
    log_info "shellcheck not found, attempting to install shellcheck-py..."
    "${VENV_DIR}/bin/pip" install shellcheck-py -q 2>/dev/null || true
    if [[ -f "${VENV_DIR}/bin/shellcheck" ]]; then
        SHELLCHECK_BIN="${VENV_DIR}/bin/shellcheck"
    else
        log_warn "shellcheck not available. Install with: pip install shellcheck-py"
        exit 0
    fi
fi

log_info "Using: $($SHELLCHECK_BIN --version | head -1 2>/dev/null || echo "$SHELLCHECK_BIN")"

# Find all shell scripts in CI directory
SCRIPTS=()
while IFS= read -r -d '' script; do
    SCRIPTS+=("$script")
done < <(find "${CI_DIR}" -name "*.sh" -type f -print0 2>/dev/null)

# Also check the ttci dispatcher
if [[ -f "${CI_DIR}/ttci" ]]; then
    SCRIPTS+=("${CI_DIR}/ttci")
fi

# Also check .slurm files
while IFS= read -r -d '' script; do
    SCRIPTS+=("$script")
done < <(find "${CI_DIR}" -name "*.slurm" -type f -print0 2>/dev/null)

if [[ ${#SCRIPTS[@]} -eq 0 ]]; then
    log_info "No scripts found to check"
    exit 0
fi

log_info "Checking ${#SCRIPTS[@]} scripts..."

TOTAL=0
ERRORS=0
WARNINGS=0

for script in "${SCRIPTS[@]}"; do
    TOTAL=$((TOTAL + 1))
    REL_PATH="${script#${CI_DIR}/}"

    OUTPUT=$("$SHELLCHECK_BIN" -x -S warning "$script" 2>&1 || true)

    if [[ -n "$OUTPUT" ]]; then
        SCRIPT_ERRORS=$(echo "$OUTPUT" | grep -c "error" 2>/dev/null || echo 0)
        SCRIPT_WARNINGS=$(echo "$OUTPUT" | grep -c "warning" 2>/dev/null || echo 0)

        if [[ "$SCRIPT_ERRORS" -gt 0 ]]; then
            echo -e "  ${RED}[ERROR]${NC} ${REL_PATH}"
            ERRORS=$((ERRORS + SCRIPT_ERRORS))
        elif [[ "$SCRIPT_WARNINGS" -gt 0 ]]; then
            echo -e "  ${YELLOW}[WARN]${NC}  ${REL_PATH}"
            WARNINGS=$((WARNINGS + SCRIPT_WARNINGS))
        fi

        echo "$OUTPUT" | head -20 | sed 's/^/    /'

        if [[ $(echo "$OUTPUT" | wc -l) -gt 20 ]]; then
            echo "    ... ($(echo "$OUTPUT" | wc -l) total lines)"
        fi
    else
        echo -e "  ${GREEN}[OK]${NC}    ${REL_PATH}"
    fi
done

echo ""
log_info "Shellcheck summary: ${TOTAL} scripts, ${ERRORS} errors, ${WARNINGS} warnings"

if [[ $ERRORS -gt 0 ]]; then
    exit 1
fi

exit 0
