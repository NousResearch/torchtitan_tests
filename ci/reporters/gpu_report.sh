#!/usr/bin/env bash
# =============================================================================
# gpu_report.sh — Parse nvidia-smi CSV into per-GPU statistics
# =============================================================================
# Usage: ./gpu_report.sh [--json] <gpu_monitor.csv>
# Output: Human-readable (default) or JSON (--json) per-GPU stats
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh" 2>/dev/null || true

# Parse args
JSON_MODE=false
CSV_FILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --json)   JSON_MODE=true; shift ;;
        *)        CSV_FILE="$1"; shift ;;
    esac
done

if [[ -z "${CSV_FILE}" ]]; then
    echo "Usage: $0 [--json] <gpu_monitor.csv>" >&2
    exit 1
fi

if [[ ! -f "${CSV_FILE}" ]] || [[ ! -s "${CSV_FILE}" ]]; then
    if [[ "$JSON_MODE" == "true" ]]; then
        echo "{}"
    else
        echo "No GPU monitoring data available."
    fi
    exit 0
fi

# Parse CSV using python (reliable, handles edge cases)
python3 -c "
import csv, json, sys
from collections import defaultdict

stats = defaultdict(lambda: {
    'utilization': [], 'memory_used': [], 'memory_total': [],
    'temperature': [], 'power': []
})

with open('${CSV_FILE}') as f:
    reader = csv.reader(f)
    header = next(reader, None)  # skip header
    for row in reader:
        if len(row) < 7:
            continue
        try:
            idx = row[1].strip()
            stats[idx]['utilization'].append(float(row[2].strip()))
            stats[idx]['memory_used'].append(float(row[3].strip()))
            stats[idx]['memory_total'].append(float(row[4].strip()))
            stats[idx]['temperature'].append(float(row[5].strip()))
            stats[idx]['power'].append(float(row[6].strip()))
        except (ValueError, IndexError):
            continue

if not stats:
    if ${JSON_MODE}:
        print('{}')
    else:
        print('No GPU data collected.')
    sys.exit(0)

result = {}
for gpu_id in sorted(stats.keys()):
    s = stats[gpu_id]
    result[gpu_id] = {
        'avg_utilization_pct': round(sum(s['utilization']) / len(s['utilization']), 1) if s['utilization'] else 0,
        'max_utilization_pct': round(max(s['utilization']), 1) if s['utilization'] else 0,
        'avg_memory_used_mib': round(sum(s['memory_used']) / len(s['memory_used']), 0) if s['memory_used'] else 0,
        'max_memory_used_mib': round(max(s['memory_used']), 0) if s['memory_used'] else 0,
        'memory_total_mib': round(s['memory_total'][0], 0) if s['memory_total'] else 0,
        'max_temperature_c': round(max(s['temperature']), 0) if s['temperature'] else 0,
        'avg_power_w': round(sum(s['power']) / len(s['power']), 1) if s['power'] else 0,
        'max_power_w': round(max(s['power']), 1) if s['power'] else 0,
        'samples': len(s['utilization'])
    }

json_mode = ${JSON_MODE}
if json_mode:
    print(json.dumps(result))
else:
    print('GPU Monitoring Report')
    print('=' * 60)
    total_samples = 0
    for gpu_id, r in sorted(result.items()):
        total_samples = r['samples']
        mem_pct = (r['max_memory_used_mib'] / r['memory_total_mib'] * 100) if r['memory_total_mib'] > 0 else 0
        print(f\"\"\"
GPU {gpu_id}:
  Utilization:  avg {r['avg_utilization_pct']}%  max {r['max_utilization_pct']}%
  Memory:       avg {r['avg_memory_used_mib']:.0f} MiB  max {r['max_memory_used_mib']:.0f} MiB / {r['memory_total_mib']:.0f} MiB ({mem_pct:.1f}%)
  Temperature:  max {r['max_temperature_c']:.0f}°C
  Power:        avg {r['avg_power_w']}W  max {r['max_power_w']}W\"\"\")
    print(f'\nTotal samples per GPU: {total_samples}')
    print('=' * 60)
" 2>/dev/null

# JSON mode: output goes through python above
# Human mode: output goes through python above
