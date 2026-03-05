#!/usr/bin/env bash
# =============================================================================
# regression.sh — Compare benchmark results, detect performance regressions
# =============================================================================
# Usage: ./regression.sh <benchmark_name> <tps> <mfu> <tflops> <max_memory_gib>
# Compares against rolling average of last 10 runs.
# Prints "REGRESSION" if any metric degrades beyond threshold.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
load_config 2>/dev/null || true

BENCHMARK_NAME="${1:?Usage: $0 <name> <tps> <mfu> <tflops> <memory>}"
CURRENT_TPS="${2:?Missing tps}"
CURRENT_MFU="${3:?Missing mfu}"
CURRENT_TFLOPS="${4:?Missing tflops}"
CURRENT_MEMORY="${5:?Missing max_memory_gib}"

BENCHMARKS_FILE="${CI_DATA_DIR}/benchmarks.jsonl"
DEFAULT_THRESHOLD=10  # percent

if [[ ! -f "${BENCHMARKS_FILE}" ]]; then
    echo "No historical benchmark data found. Skipping regression check."
    exit 0
fi

python3 -c "
import json, sys

benchmark_name = '${BENCHMARK_NAME}'
current = {
    'tps': float('${CURRENT_TPS}'),
    'mfu': float('${CURRENT_MFU}'),
    'tflops': float('${CURRENT_TFLOPS}'),
    'max_memory_gib': float('${CURRENT_MEMORY}')
}
threshold_pct = ${DEFAULT_THRESHOLD}

# Load last 10 successful runs for this benchmark
history = []
with open('${BENCHMARKS_FILE}') as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
            if entry.get('benchmark') == benchmark_name and entry.get('status') == 'pass':
                history.append(entry['metrics'])
        except (json.JSONDecodeError, KeyError):
            continue

# Use last 10
history = history[-10:]

if len(history) < 2:
    print(f'Not enough historical data for {benchmark_name} ({len(history)} runs). Need at least 2.')
    sys.exit(0)

# Compute rolling averages
def avg(values):
    return sum(values) / len(values) if values else 0

avg_metrics = {
    'tps': avg([h.get('tps', 0) for h in history]),
    'mfu': avg([h.get('mfu', 0) for h in history]),
    'tflops': avg([h.get('tflops', 0) for h in history]),
    'max_memory_gib': avg([h.get('max_memory_gib', 0) for h in history])
}

# Check for regressions (performance should not decrease, memory should not increase)
regressions = []
for metric in ['tps', 'mfu', 'tflops']:
    if avg_metrics[metric] > 0:
        delta_pct = ((current[metric] - avg_metrics[metric]) / avg_metrics[metric]) * 100
        if delta_pct < -threshold_pct:
            regressions.append({
                'metric': metric,
                'expected': round(avg_metrics[metric], 2),
                'actual': round(current[metric], 2),
                'delta_pct': round(delta_pct, 1)
            })

# Memory: regression if it increases significantly
if avg_metrics['max_memory_gib'] > 0:
    mem_delta_pct = ((current['max_memory_gib'] - avg_metrics['max_memory_gib']) / avg_metrics['max_memory_gib']) * 100
    if mem_delta_pct > threshold_pct:
        regressions.append({
            'metric': 'max_memory_gib',
            'expected': round(avg_metrics['max_memory_gib'], 2),
            'actual': round(current['max_memory_gib'], 2),
            'delta_pct': round(mem_delta_pct, 1)
        })

if regressions:
    print('REGRESSION DETECTED')
    print(f'Benchmark: {benchmark_name}')
    print(f'Threshold: {threshold_pct}%')
    print(f'History:   {len(history)} runs')
    print()
    print(f'{\"Metric\":<20} {\"Expected\":<12} {\"Actual\":<12} {\"Delta\":<10}')
    print('-' * 54)
    for r in regressions:
        print(f\"{r['metric']:<20} {r['expected']:<12} {r['actual']:<12} {r['delta_pct']:>+.1f}%\")
    print()
    print('Comparison (current vs rolling avg):')
    for metric in ['tps', 'mfu', 'tflops', 'max_memory_gib']:
        flag = ' ⚠️' if any(r['metric'] == metric for r in regressions) else ''
        if avg_metrics[metric] > 0:
            delta = ((current[metric] - avg_metrics[metric]) / avg_metrics[metric]) * 100
            print(f'  {metric:<20} avg={avg_metrics[metric]:<10.2f} current={current[metric]:<10.2f} ({delta:>+.1f}%){flag}')
else:
    print(f'No regression detected for {benchmark_name}')
    print(f'History: {len(history)} runs, threshold: {threshold_pct}%')
    for metric in ['tps', 'mfu', 'tflops', 'max_memory_gib']:
        if avg_metrics[metric] > 0:
            delta = ((current[metric] - avg_metrics[metric]) / avg_metrics[metric]) * 100
            print(f'  {metric:<20} avg={avg_metrics[metric]:<10.2f} current={current[metric]:<10.2f} ({delta:>+.1f}%)')
" 2>/dev/null
