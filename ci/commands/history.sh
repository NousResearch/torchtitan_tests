#!/usr/bin/env bash
# =============================================================================
# ttci history — Query historical run data
# =============================================================================
# Usage: ttci history [--json] [--since <period>] [--failures] [--pr <number>] [--limit N]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
load_config

# Parse args
JSON_MODE=false
SINCE=""
FAILURES_ONLY=false
PR_FILTER=""
LIMIT=20

while [[ $# -gt 0 ]]; do
    case "$1" in
        --json)      JSON_MODE=true; shift ;;
        --since)     SINCE="$2"; shift 2 ;;
        --failures)  FAILURES_ONLY=true; shift ;;
        --pr)        PR_FILTER="$2"; shift 2 ;;
        --limit)     LIMIT="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: ttci history [--json] [--since <period>] [--failures] [--pr <number>] [--limit N]"
            echo ""
            echo "Options:"
            echo "  --json          Output raw JSON"
            echo "  --since <N>d    Only show runs from last N days"
            echo "  --failures      Only show failed runs"
            echo "  --pr <number>   Only show runs for specific PR"
            echo "  --limit N       Max runs to show (default: 20)"
            exit 0
            ;;
        *) log_error "Unknown option: $1"; exit 1 ;;
    esac
done

RUNS_FILE="${CI_DATA_DIR}/runs.jsonl"

if [[ ! -f "$RUNS_FILE" ]] || [[ ! -s "$RUNS_FILE" ]]; then
    log_info "No run history found."
    exit 0
fi

python3 -c "
import json, sys
from datetime import datetime, timedelta

json_mode = ${JSON_MODE}
failures_only = ${FAILURES_ONLY}
pr_filter = '${PR_FILTER}' or None
since_str = '${SINCE}' or None
limit = ${LIMIT}

# Parse since period
since_dt = None
if since_str:
    if since_str.endswith('d'):
        days = int(since_str[:-1])
        since_dt = datetime.utcnow() - timedelta(days=days)
    elif since_str.endswith('h'):
        hours = int(since_str[:-1])
        since_dt = datetime.utcnow() - timedelta(hours=hours)

# Read all runs
runs = []
with open('${RUNS_FILE}') as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            runs.append(json.loads(line))
        except json.JSONDecodeError:
            continue

# Filter
filtered = []
for run in runs:
    if failures_only and run.get('overall_status') == 'pass':
        continue
    if pr_filter and str(run.get('pr_number', '')) != pr_filter:
        continue
    if since_dt:
        ts = run.get('timestamp', '')
        try:
            run_dt = datetime.fromisoformat(ts.replace('Z', '+00:00')).replace(tzinfo=None)
            if run_dt < since_dt:
                continue
        except (ValueError, TypeError):
            pass
    filtered.append(run)

# Limit
filtered = filtered[-limit:]

if json_mode:
    for run in filtered:
        print(json.dumps(run))
    sys.exit(0)

if not filtered:
    print('No matching runs found.')
    sys.exit(0)

# Table output
print(f\"{'#':<4} {'Timestamp':<20} {'Nodes':>5} {'Trigger':<12} {'SHA':<9} {'Status':<8} {'Duration':>8} {'Phases'}\")
print('-' * 100)

for i, run in enumerate(filtered):
    status = run.get('overall_status', '?').upper()
    icon = '✅' if status == 'PASS' else '❌' if status == 'FAIL' else '🔄'
    rid = run.get('run_id', '?')
    sha = run.get('sha', '?')[:7]
    trigger = run.get('trigger', '?')
    pr = run.get('pr_number')
    nodes = run.get('node_count', '?')
    dur = run.get('total_duration_sec', 0)
    ts = run.get('timestamp', '?')[:19].replace('T', ' ')

    trigger_str = trigger
    if pr:
        trigger_str = f'PR #{pr}'

    phases = run.get('phases', {})
    phase_parts = []
    for pname, pinfo in phases.items():
        ps = pinfo.get('status', '?')[0].upper()
        phase_parts.append(f'{pname}:{ps}')
    phases_str = ' '.join(phase_parts)

    print(f'{icon}  {ts:<20} {str(nodes):>5} {trigger_str:<12} {sha:<9} {status:<8} {dur:>6}s {phases_str}')

print(f'\nTotal: {len(filtered)} runs')
" 2>/dev/null
