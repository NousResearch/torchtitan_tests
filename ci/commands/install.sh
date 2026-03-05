#!/usr/bin/env bash
# =============================================================================
# ttci install — Set up cron jobs, pre-commit hooks, dependencies
# =============================================================================
# Usage: ttci install [--cron-only] [--hooks-only] [--check]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
load_config

# Parse args
CRON_ONLY=false
HOOKS_ONLY=false
CHECK_ONLY=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --cron-only)  CRON_ONLY=true; shift ;;
        --hooks-only) HOOKS_ONLY=true; shift ;;
        --check)      CHECK_ONLY=true; shift ;;
        --help|-h)
            echo "Usage: ttci install [--cron-only] [--hooks-only] [--check]"
            echo ""
            echo "Options:"
            echo "  --cron-only   Only install cron jobs"
            echo "  --hooks-only  Only install pre-commit hooks"
            echo "  --check       Dry-run, report what would be installed"
            exit 0
            ;;
        *) log_error "Unknown option: $1"; exit 1 ;;
    esac
done

section "ttci Install"

# =============================================================================
# Pre-flight checks
# =============================================================================
log_info "Running pre-flight checks..."
ERRORS=0

# Slurm
if command -v sinfo &>/dev/null; then
    echo -e "  ${GREEN}[OK]${NC}   Slurm available"
else
    echo -e "  ${RED}[FAIL]${NC} sinfo not found (Slurm not installed or not in PATH)"
    ERRORS=$((ERRORS + 1))
fi

# Git repo
if [[ -d "${TORCHTITAN_DIR}/.git" ]]; then
    echo -e "  ${GREEN}[OK]${NC}   Git repository at ${TORCHTITAN_DIR}"
else
    echo -e "  ${RED}[FAIL]${NC} ${TORCHTITAN_DIR} is not a git repository"
    ERRORS=$((ERRORS + 1))
fi

# Python venv
if [[ -f "${VENV_DIR}/bin/activate" ]]; then
    echo -e "  ${GREEN}[OK]${NC}   Python venv at ${VENV_DIR}"
else
    echo -e "  ${RED}[FAIL]${NC} Python venv not found at ${VENV_DIR}"
    ERRORS=$((ERRORS + 1))
fi

# pytest
if "${VENV_DIR}/bin/python" -m pytest --version &>/dev/null 2>&1; then
    echo -e "  ${GREEN}[OK]${NC}   pytest available"
else
    echo -e "  ${YELLOW}[WARN]${NC} pytest not found in venv"
fi

# curl
if command -v curl &>/dev/null; then
    echo -e "  ${GREEN}[OK]${NC}   curl available"
else
    echo -e "  ${YELLOW}[WARN]${NC} curl not found (Discord notifications won't work)"
fi

# pre-commit
if "${VENV_DIR}/bin/python" -m pre_commit --version &>/dev/null 2>&1; then
    echo -e "  ${GREEN}[OK]${NC}   pre-commit available"
else
    echo -e "  ${YELLOW}[WARN]${NC} pre-commit not found in venv"
fi

if [[ ${ERRORS} -gt 0 ]]; then
    log_error "Pre-flight failed with ${ERRORS} error(s). Fix issues and re-run."
    exit 1
fi

if [[ "$CHECK_ONLY" == "true" ]]; then
    echo ""
    log_info "CHECK mode: Would install the following:"
    echo "  - Cron jobs: commit_scheduler ($(yaml_get "${TTCI_CONFIG}" "scheduling.commit_poll_interval"))"
    echo "  - Cron jobs: pr_scheduler ($(yaml_get "${TTCI_CONFIG}" "scheduling.pr_poll_interval"))"
    echo "  - Cron jobs: daily_scheduler ($(yaml_get "${TTCI_CONFIG}" "scheduling.daily_schedule"))"
    echo "  - Directories: logs, state, data"
    echo "  - Script permissions: all CI scripts"
    exit 0
fi

# =============================================================================
# Set permissions
# =============================================================================
if [[ "$HOOKS_ONLY" != "true" ]]; then
    log_info "Setting permissions..."
    find "${CI_DIR}" -name "*.sh" -exec chmod +x {} \;
    chmod +x "${CI_DIR}/ttci"
    chmod +x "${CI_DIR}/jobs/"*.slurm 2>/dev/null || true
    echo -e "  ${GREEN}[OK]${NC}   Scripts are executable"
fi

# =============================================================================
# Create directories
# =============================================================================
if [[ "$HOOKS_ONLY" != "true" ]]; then
    ensure_dir "${CI_LOG_DIR}"
    ensure_dir "${CI_STATE_DIR}"
    ensure_dir "${CI_DATA_DIR}"
    echo -e "  ${GREEN}[OK]${NC}   Directories created"
fi

# =============================================================================
# Install cron jobs
# =============================================================================
if [[ "$HOOKS_ONLY" != "true" ]]; then
    log_info "Installing cron jobs..."

    SCHEDULERS_DIR="${CI_DIR}/schedulers"
    CRON_TAG="# ttci-"

    COMMIT_SCHEDULE=$(yaml_get "${TTCI_CONFIG}" "scheduling.commit_poll_interval")
    PR_SCHEDULE=$(yaml_get "${TTCI_CONFIG}" "scheduling.pr_poll_interval")
    DAILY_SCHEDULE=$(yaml_get "${TTCI_CONFIG}" "scheduling.daily_schedule")

    CRON_ENTRIES=(
        "${COMMIT_SCHEDULE} ${SCHEDULERS_DIR}/commit_scheduler.sh ${CRON_TAG}commit"
        "${PR_SCHEDULE} ${SCHEDULERS_DIR}/pr_scheduler.sh ${CRON_TAG}pr"
        "${DAILY_SCHEDULE} ${SCHEDULERS_DIR}/daily_scheduler.sh ${CRON_TAG}daily"
    )

    # Remove existing ttci cron entries
    CURRENT_CRON=$(crontab -l 2>/dev/null || true)
    CLEANED_CRON=$(echo "$CURRENT_CRON" | grep -v "# ttci-" || true)

    # Add new entries
    NEW_CRON="$CLEANED_CRON"
    for entry in "${CRON_ENTRIES[@]}"; do
        NEW_CRON="${NEW_CRON}
${entry}"
    done

    echo "$NEW_CRON" | crontab -
    echo -e "  ${GREEN}[OK]${NC}   Cron jobs installed:"
    echo "         commit-poll: ${COMMIT_SCHEDULE}"
    echo "         pr-poll:     ${PR_SCHEDULE}"
    echo "         daily:       ${DAILY_SCHEDULE}"
fi

# =============================================================================
# Install pre-commit hooks
# =============================================================================
if [[ "$CRON_ONLY" != "true" ]]; then
    if [[ -d "${TORCHTITAN_DIR}/.git" ]] && [[ -f "${TORCHTITAN_DIR}/.pre-commit-config.yaml" ]]; then
        log_info "Installing pre-commit hooks..."
        cd "${TORCHTITAN_DIR}"
        source "${VENV_DIR}/bin/activate"
        pre-commit install 2>/dev/null && \
            echo -e "  ${GREEN}[OK]${NC}   pre-commit hooks installed in torchtitan" || \
            echo -e "  ${YELLOW}[WARN]${NC} pre-commit install failed"
    fi
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
section "Install Complete"
echo ""
echo "Quick start:"
echo "  ttci status           # Check system state"
echo "  ttci run --dry-run    # Test without submitting"
echo "  ttci run --force      # Force a test run"
echo "  ttci quality          # Run quality checks"
echo ""
echo "To remove:"
echo "  ttci uninstall"
echo ""
