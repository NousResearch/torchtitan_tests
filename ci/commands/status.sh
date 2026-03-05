#!/usr/bin/env bash
# =============================================================================
# ttci status — Show CI system status
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
load_config

section "CI System Status"

# --- Watchdog Daemon ---
echo -e "${BOLD}Daemon:${NC}"
PID_FILE="${CI_STATE_DIR}/watchdog.pid"
if [[ -f "$PID_FILE" ]]; then
    WD_PID=$(cat "$PID_FILE")
    if kill -0 "$WD_PID" 2>/dev/null; then
        UPTIME=""
        WD_START=$(stat -c %Y "$PID_FILE" 2>/dev/null || echo "")
        if [[ -n "$WD_START" ]]; then
            ELAPSED=$(( $(date +%s) - WD_START ))
            HOURS=$(( ELAPSED / 3600 ))
            MINS=$(( (ELAPSED % 3600) / 60 ))
            UPTIME=" (up ${HOURS}h${MINS}m)"
        fi
        echo -e "  ${GREEN}running${NC}  PID ${WD_PID}${UPTIME}"
        echo "  Log: ${CI_LOG_DIR}/watchdog.log"
    else
        echo -e "  ${YELLOW}stale PID${NC} ${WD_PID} (process dead, run 'ttci start')"
    fi
else
    echo -e "  ${DIM}stopped${NC}  (run 'ttci start' to enable autonomous mode)"
fi
echo ""

# --- Cron Jobs ---
echo -e "${BOLD}Cron Jobs:${NC}"
CRON_LINES=$(crontab -l 2>/dev/null | grep "torchtitan" || echo "")
if [[ -n "$CRON_LINES" ]]; then
    while IFS= read -r line; do
        # Extract schedule and script name
        schedule=$(echo "$line" | awk '{print $1, $2, $3, $4, $5}')
        script=$(echo "$line" | grep -oP '[^ ]+\.sh' | xargs basename 2>/dev/null || echo "unknown")
        echo "  ${GREEN}active${NC}  ${schedule}  ${script}"
    done <<< "$CRON_LINES"
else
    echo "  ${DIM}none${NC}  (optional — daemon handles scheduling)"
fi
echo ""

# --- Running Slurm Jobs ---
echo -e "${BOLD}Running Jobs:${NC}"
RUNNING=$(squeue -u "$USER" -h -o "%i %j %T %M %N" 2>/dev/null | grep "${SLURM_JOB_PREFIX}" || true)
if [[ -n "$RUNNING" ]]; then
    printf "  %-12s %-25s %-10s %-8s %s\n" "JOB_ID" "NAME" "STATE" "TIME" "NODE"
    while IFS= read -r line; do
        read -r jid jname jstate jtime jnode <<< "$line"
        color="${GREEN}"
        [[ "$jstate" == "PENDING" ]] && color="${YELLOW}"
        echo -e "  ${color}${jid}${NC}  ${jname}  ${jstate}  ${jtime}  ${jnode}"
    done <<< "$RUNNING"
else
    echo "  ${DIM}No CI jobs running${NC}"
fi
echo ""

# --- Last 5 Runs ---
echo -e "${BOLD}Last 5 Runs:${NC}"
RUNS_FILE="${CI_DATA_DIR}/runs.jsonl"
if [[ -f "$RUNS_FILE" ]] && [[ -s "$RUNS_FILE" ]]; then
    tail -5 "$RUNS_FILE" | python3 -c "
import sys, json
runs = []
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        runs.append(json.loads(line))
    except json.JSONDecodeError:
        continue

if not runs:
    print('  No runs recorded yet')
    sys.exit(0)

for i, run in enumerate(reversed(runs)):
    status = run.get('overall_status', '?').upper()
    icon = '✅' if status == 'PASS' else '❌' if status == 'FAIL' else '🔄'
    rid = run.get('run_id', '?')
    sha = run.get('sha', '?')[:7]
    trigger = run.get('trigger', '?')
    pr = run.get('pr_number')
    nodes = run.get('node_count', '?')
    dur = run.get('total_duration_sec', 0)
    ts = run.get('timestamp', '?')[:16]

    trigger_str = trigger
    if pr:
        trigger_str = f'PR #{pr}'

    # Summarize phases
    phases = run.get('phases', {})
    phase_summary = []
    for pname, pinfo in phases.items():
        pstatus = pinfo.get('status', '?')
        passed = pinfo.get('passed', 0)
        failed = pinfo.get('failed', 0)
        if passed or failed:
            phase_summary.append(f'{pname}: {passed}p/{failed}f')
        else:
            phase_summary.append(f'{pname}: {pstatus}')

    phases_str = ', '.join(phase_summary) if phase_summary else ''
    print(f'  {icon} {ts}  {nodes}n  {trigger_str:<12} {sha}  {status:<6}  ({phases_str})')
" 2>/dev/null || echo "  Error reading run history"
else
    echo "  ${DIM}No runs recorded yet${NC}"
fi
echo ""

# --- Git Status ---
echo -e "${BOLD}Git:${NC}"
if [[ -d "${TORCHTITAN_DIR}/.git" ]]; then
    cd "${TORCHTITAN_DIR}"
    CURRENT_SHA=$(git rev-parse HEAD 2>/dev/null | head -c 7)
    LAST_TESTED=""
    if [[ -f "${LAST_TESTED_SHA_FILE}" ]]; then
        LAST_TESTED=$(cat "${LAST_TESTED_SHA_FILE}" | head -c 7)
    fi

    echo "  Branch:       ${GIT_BRANCH}"
    echo "  HEAD:         ${CURRENT_SHA}"
    echo -n "  Last Tested:  "
    if [[ -n "$LAST_TESTED" ]]; then
        if [[ "$CURRENT_SHA" == "$LAST_TESTED" ]]; then
            echo -e "${GREEN}${LAST_TESTED} (current)${NC}"
        else
            echo -e "${YELLOW}${LAST_TESTED} (behind)${NC}"
        fi
    else
        echo -e "${DIM}none${NC}"
    fi
else
    echo "  ${YELLOW}torchtitan repo not found at ${TORCHTITAN_DIR}${NC}"
fi
echo ""

# --- Disk Usage ---
echo -e "${BOLD}Disk:${NC}"
if [[ -d "${CI_LOG_DIR}" ]]; then
    LOG_SIZE=$(du -sh "${CI_LOG_DIR}" 2>/dev/null | awk '{print $1}')
    LOG_COUNT=$(find "${CI_LOG_DIR}" -maxdepth 1 -type d 2>/dev/null | wc -l)
    echo "  Logs: ${LOG_SIZE} (${LOG_COUNT} runs)"
fi
if [[ -d "${CI_DATA_DIR}" ]]; then
    DATA_SIZE=$(du -sh "${CI_DATA_DIR}" 2>/dev/null | awk '{print $1}')
    echo "  Data: ${DATA_SIZE}"
fi
echo ""
