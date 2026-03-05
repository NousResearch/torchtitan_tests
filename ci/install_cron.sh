#!/usr/bin/env bash
# One-time setup for torchtitan CI
# Usage: ./install_cron.sh [--remove]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env"

CRON_TAG="# torchtitan-ci-scheduler"
CRON_ENTRY="0 * * * * ${SCRIPT_DIR}/scheduler.sh ${CRON_TAG}"

# ============================================================================
# Flags
# ============================================================================
if [[ "${1:-}" == "--remove" ]]; then
    echo "Removing torchtitan CI cron job..."
    crontab -l 2>/dev/null | grep -v "${CRON_TAG}" | crontab - 2>/dev/null || true
    echo "Done. Cron entry removed."
    exit 0
fi

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    echo "Usage: $0 [--remove]"
    echo "  (no args)  Install hourly cron job + verify prerequisites"
    echo "  --remove   Remove the cron job"
    exit 0
fi

# ============================================================================
# Pre-flight checks
# ============================================================================
echo "Running pre-flight checks..."

ERRORS=0

# Check Slurm
if ! command -v sinfo &>/dev/null; then
    echo "  [FAIL] sinfo not found (Slurm not installed or not in PATH)"
    ERRORS=$((ERRORS + 1))
else
    echo "  [OK]   Slurm available"
fi

# Check git repo
if [[ ! -d "${TORCHTITAN_DIR}/.git" ]]; then
    echo "  [FAIL] ${TORCHTITAN_DIR} is not a git repository"
    ERRORS=$((ERRORS + 1))
else
    echo "  [OK]   Git repository at ${TORCHTITAN_DIR}"
fi

# Check Python venv
if [[ ! -f "${VENV_DIR}/bin/activate" ]]; then
    echo "  [FAIL] Python venv not found at ${VENV_DIR}"
    ERRORS=$((ERRORS + 1))
else
    echo "  [OK]   Python venv at ${VENV_DIR}"
fi

# Check pytest
if ! "${VENV_DIR}/bin/python" -m pytest --version &>/dev/null; then
    echo "  [WARN] pytest not found in venv (unit tests may fail)"
else
    echo "  [OK]   pytest available"
fi

# Check curl for Discord
if ! command -v curl &>/dev/null; then
    echo "  [WARN] curl not found (Discord notifications won't work)"
else
    echo "  [OK]   curl available"
fi

if [[ ${ERRORS} -gt 0 ]]; then
    echo ""
    echo "Pre-flight failed with ${ERRORS} error(s). Fix issues and re-run."
    exit 1
fi

# ============================================================================
# Make scripts executable
# ============================================================================
echo ""
echo "Setting permissions..."
chmod +x "${SCRIPT_DIR}/scheduler.sh"
chmod +x "${SCRIPT_DIR}/notify.sh"
chmod +x "${SCRIPT_DIR}/install_cron.sh"
chmod +x "${SCRIPT_DIR}/run_tests.slurm"
echo "  [OK]   Scripts are executable"

# ============================================================================
# Create directories
# ============================================================================
mkdir -p "${CI_LOG_DIR}" "${CI_STATE_DIR}"
echo "  [OK]   Directories created"

# ============================================================================
# Install cron (idempotent)
# ============================================================================
echo ""
echo "Installing cron job..."

CURRENT_CRON=$(crontab -l 2>/dev/null || true)
if echo "${CURRENT_CRON}" | grep -q "${CRON_TAG}"; then
    echo "  [OK]   Cron entry already exists (updating)"
    CURRENT_CRON=$(echo "${CURRENT_CRON}" | grep -v "${CRON_TAG}")
fi

echo "${CURRENT_CRON}
${CRON_ENTRY}" | crontab -
echo "  [OK]   Cron job installed (hourly at :00)"

# ============================================================================
# Summary
# ============================================================================
echo ""
echo "============================================================"
echo "Setup complete! Next steps:"
echo "============================================================"
echo ""
echo "1. Set Discord webhook (optional):"
echo "   export DISCORD_WEBHOOK_URL='https://discord.com/api/webhooks/...'"
echo "   (or edit ci/config.env directly)"
echo ""
echo "2. Test notification:"
echo "   ${SCRIPT_DIR}/notify.sh success main abc1234 test-run"
echo ""
echo "3. Test scheduler (dry run):"
echo "   ${SCRIPT_DIR}/scheduler.sh --dry-run"
echo ""
echo "4. Force a test run now:"
echo "   ${SCRIPT_DIR}/scheduler.sh --force"
echo ""
echo "5. Monitor:"
echo "   tail -f ${CI_LOG_DIR}/scheduler.log"
echo ""
echo "6. Remove cron later:"
echo "   ${SCRIPT_DIR}/install_cron.sh --remove"
echo ""
