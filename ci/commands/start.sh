#!/usr/bin/env bash
# =============================================================================
# ttci start — Start the autonomous CI watchdog daemon
# =============================================================================
# Usage: ttci start [--poll <seconds>] [--heartbeat <hours>]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
load_config

POLL_INTERVAL=""
HEARTBEAT_HOURS=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --poll)      POLL_INTERVAL="$2"; shift 2 ;;
        --heartbeat) HEARTBEAT_HOURS="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: ttci start [--poll <seconds>] [--heartbeat <hours>]"
            echo ""
            echo "Start the autonomous CI watchdog. It will:"
            echo "  - Watch for new commits on ${GIT_BRANCH} (submit 1-node job)"
            echo "  - Watch for new/updated PRs on GitHub (submit 1-node job)"
            echo "  - Force a run every 24h if nothing else triggered"
            echo ""
            echo "Options:"
            echo "  --poll <sec>     Poll interval in seconds (default: 300 = 5 min)"
            echo "  --heartbeat <h>  Force run after N hours of inactivity (default: 24)"
            exit 0
            ;;
        *) log_error "Unknown option: $1"; exit 1 ;;
    esac
done

PID_FILE="${CI_STATE_DIR}/watchdog.pid"

# Check if already running
if [[ -f "$PID_FILE" ]]; then
    OLD_PID=$(cat "$PID_FILE")
    if kill -0 "$OLD_PID" 2>/dev/null; then
        log_info "Watchdog already running (PID $OLD_PID)"
        echo ""
        echo "  Log:  tail -f ${CI_LOG_DIR}/watchdog.log"
        echo "  Stop: ttci stop"
        exit 0
    fi
    rm -f "$PID_FILE"
fi

ensure_dir "${CI_LOG_DIR}" "${CI_STATE_DIR}" "${CI_DATA_DIR}"

# Build env
ENV_VARS=""
[[ -n "$POLL_INTERVAL" ]] && ENV_VARS="WATCHDOG_POLL_INTERVAL=${POLL_INTERVAL}"
if [[ -n "$HEARTBEAT_HOURS" ]]; then
    HEARTBEAT_SEC=$(( HEARTBEAT_HOURS * 3600 ))
    ENV_VARS="${ENV_VARS:+${ENV_VARS} }WATCHDOG_HEARTBEAT_SEC=${HEARTBEAT_SEC}"
fi

# Launch watchdog in background
WATCHDOG="${SCRIPT_DIR}/../schedulers/watchdog.sh"
chmod +x "$WATCHDOG"

if [[ -n "$ENV_VARS" ]]; then
    env $ENV_VARS nohup bash "$WATCHDOG" >> /dev/null 2>&1 &
else
    nohup bash "$WATCHDOG" >> /dev/null 2>&1 &
fi

DAEMON_PID=$!

# Give it a moment to start and check it's alive
sleep 1
if kill -0 "$DAEMON_PID" 2>/dev/null; then
    log_info "Watchdog started (PID $DAEMON_PID)"
    echo ""
    echo "  Watching: ${GIT_BRANCH} @ ${GITHUB_API_REPO}"
    echo "  Poll:     every ${POLL_INTERVAL:-300}s"
    echo "  Heartbeat: every ${HEARTBEAT_HOURS:-24}h"
    echo ""
    echo "  Log:  tail -f ${CI_LOG_DIR}/watchdog.log"
    echo "  Stop: ttci stop"
else
    log_error "Watchdog failed to start. Check: ${CI_LOG_DIR}/watchdog.log"
    exit 1
fi
