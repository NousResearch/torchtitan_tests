#!/usr/bin/env bash
# =============================================================================
# ttci stop — Stop the autonomous CI watchdog daemon
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
load_config

PID_FILE="${CI_STATE_DIR}/watchdog.pid"

if [[ ! -f "$PID_FILE" ]]; then
    log_info "Watchdog is not running (no PID file)"
    exit 0
fi

PID=$(cat "$PID_FILE")

if ! kill -0 "$PID" 2>/dev/null; then
    log_info "Watchdog is not running (stale PID $PID)"
    rm -f "$PID_FILE"
    exit 0
fi

log_info "Stopping watchdog (PID $PID)..."
kill "$PID" 2>/dev/null
rm -f "$PID_FILE"

# Wait for it to exit
for i in $(seq 1 10); do
    if ! kill -0 "$PID" 2>/dev/null; then
        log_info "Watchdog stopped"
        exit 0
    fi
    sleep 0.5
done

# Force kill if still alive
kill -9 "$PID" 2>/dev/null || true
rm -f "$PID_FILE"
log_info "Watchdog force-killed"
