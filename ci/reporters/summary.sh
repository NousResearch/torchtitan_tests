#!/usr/bin/env bash
# =============================================================================
# summary.sh — Generate human-readable summary from summary.json
# =============================================================================
# Usage: ./summary.sh <summary_json_file>
#        ./summary.sh <run_log_dir>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

INPUT="${1:?Usage: $0 <summary.json or run_log_dir>}"

# Resolve input to JSON file
if [[ -d "$INPUT" ]]; then
    JSON_FILE="${INPUT}/summary.json"
elif [[ -f "$INPUT" ]]; then
    JSON_FILE="$INPUT"
else
    log_error "Not found: $INPUT"
    exit 1
fi

if [[ ! -f "$JSON_FILE" ]]; then
    log_error "summary.json not found at $JSON_FILE"
    exit 1
fi

# Parse and display using python
python3 -c "
import json, sys

with open('${JSON_FILE}') as f:
    data = json.load(f)

status = data.get('overall_status', 'unknown').upper()
status_icon = '✅' if status == 'PASS' else '❌' if status == 'FAIL' else '🔄' if status == 'PREEMPTED' else '❓'

print(f'''
{'=' * 60}
  {status_icon} torchtitan CI Run Summary
{'=' * 60}
  Run ID:    {data.get('run_id', 'N/A')}
  Commit:    {data.get('sha', 'N/A')[:7]}
  Branch:    {data.get('branch', 'N/A')}
  Trigger:   {data.get('trigger', 'N/A')}{f\" (PR #{data['pr_number']})\" if data.get('pr_number') else ''}
  Nodes:     {data.get('node_count', 'N/A')}
  Status:    {status}
  Duration:  {data.get('total_duration_sec', 0)}s
  Timestamp: {data.get('timestamp', 'N/A')}
{'=' * 60}

Phase Results:
{'-' * 60}''')

phases = data.get('phases', {})
for name, info in phases.items():
    pstatus = info.get('status', 'unknown').upper()
    icon = '✅' if pstatus == 'PASS' else '❌' if pstatus == 'FAIL' else '⏱' if pstatus == 'TIMEOUT' else '❓'
    passed = info.get('passed', 0)
    failed = info.get('failed', 0)
    skipped = info.get('skipped', 0)
    dur = info.get('duration_sec', 0)
    counts = ''
    if passed or failed or skipped:
        counts = f'  ({passed} passed, {failed} failed, {skipped} skipped)'
    print(f'  {icon} {name:<30} {pstatus:<8} {dur:>4}s{counts}')

# GPU stats
gpu = data.get('gpu_stats', {})
if gpu and gpu != {}:
    print(f'''
{'=' * 60}
GPU Statistics:
{'-' * 60}''')
    for gpu_id, stats in gpu.items():
        if isinstance(stats, dict):
            print(f'  GPU {gpu_id}:')
            for metric, value in stats.items():
                print(f'    {metric}: {value}')

print(f'''
{'=' * 60}''')
" 2>/dev/null
