#!/usr/bin/env bash
# =============================================================================
# ttci benchmark — Run or compare benchmarks
# =============================================================================
# Usage: ttci benchmark [--list] [--config <toml>] [--compare HEAD~5..HEAD] [--history]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
load_config

# Parse args
LIST_MODE=false
COMPARE=""
HISTORY_MODE=false
CONFIG_OVERRIDE=""
BENCHMARK_NAME=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --list)     LIST_MODE=true; shift ;;
        --compare)  COMPARE="$2"; shift 2 ;;
        --history)  HISTORY_MODE=true; shift ;;
        --config)   CONFIG_OVERRIDE="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: ttci benchmark [options] [benchmark_name]"
            echo ""
            echo "Options:"
            echo "  --list                    List configured benchmarks"
            echo "  --compare HEAD~5..HEAD    Compare commits"
            echo "  --history                 Show benchmark trend"
            echo "  --config <toml>           Custom config file"
            echo ""
            echo "Examples:"
            echo "  ttci benchmark --list"
            echo "  ttci benchmark qwen3_30b_a3b_deepep"
            echo "  ttci benchmark --history"
            exit 0
            ;;
        -*) log_error "Unknown option: $1"; exit 1 ;;
        *)  BENCHMARK_NAME="$1"; shift ;;
    esac
done

# List benchmarks from config
if [[ "$LIST_MODE" == "true" ]]; then
    section "Configured Benchmarks"
    python3 -c "
import sys

in_benchmarks = False
current = {}
benchmarks = []
with open('${TTCI_CONFIG}') as f:
    for line in f:
        stripped = line.strip()
        if stripped == 'benchmarks:':
            in_benchmarks = True
            continue
        if in_benchmarks:
            if line.startswith('  - name:'):
                if current:
                    benchmarks.append(current)
                current = {'name': stripped.split(':', 1)[1].strip()}
            elif line.startswith('    ') and ':' in stripped and in_benchmarks:
                k, v = stripped.split(':', 1)
                current[k.strip()] = v.strip()
            elif not line.startswith(' ') and stripped:
                if current:
                    benchmarks.append(current)
                break
if current and current not in benchmarks:
    benchmarks.append(current)

if not benchmarks:
    print('No benchmarks configured.')
    sys.exit(0)

for b in benchmarks:
    name = b.get('name', 'unknown')
    config = b.get('config', 'N/A')
    ngpu = b.get('ngpu', '?')
    steps = b.get('steps', '?')
    threshold = b.get('regression_threshold_pct', '10')
    print(f'''  {name}
    Config:    {config}
    GPUs:      {ngpu}
    Steps:     {steps}
    Threshold: {threshold}%
''')
" 2>/dev/null
    exit 0
fi

# Show benchmark history/trend
if [[ "$HISTORY_MODE" == "true" ]]; then
    BENCHMARKS_FILE="${CI_DATA_DIR}/benchmarks.jsonl"
    if [[ ! -f "$BENCHMARKS_FILE" ]] || [[ ! -s "$BENCHMARKS_FILE" ]]; then
        log_info "No benchmark history found."
        exit 0
    fi

    section "Benchmark History"
    python3 -c "
import json, sys

runs = []
with open('${BENCHMARKS_FILE}') as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            runs.append(json.loads(line))
        except json.JSONDecodeError:
            continue

if not runs:
    print('No benchmark data.')
    sys.exit(0)

name_filter = '${BENCHMARK_NAME}' or None

print(f\"{'Timestamp':<22} {'Benchmark':<25} {'SHA':<9} {'TPS':>8} {'MFU':>7} {'TFLOPS':>8} {'Memory':>10} {'Status':<6}\")
print('-' * 105)

for run in runs[-30:]:
    if name_filter and run.get('benchmark') != name_filter:
        continue
    ts = run.get('timestamp', '?')[:19].replace('T', ' ')
    name = run.get('benchmark', '?')
    sha = run.get('sha', '?')[:7]
    m = run.get('metrics', {})
    status = run.get('status', '?')
    icon = '✅' if status == 'pass' else '❌'
    print(f\"{ts:<22} {name:<25} {sha:<9} {m.get('tps', 0):>8} {m.get('mfu', 0):>6.1f}% {m.get('tflops', 0):>8} {m.get('max_memory_gib', 0):>8.1f}Gi {icon}\")
" 2>/dev/null
    exit 0
fi

# Compare mode
if [[ -n "$COMPARE" ]]; then
    log_info "Compare mode: ${COMPARE}"
    log_info "Fetching benchmark data for comparison..."
    BENCHMARKS_FILE="${CI_DATA_DIR}/benchmarks.jsonl"

    if [[ ! -f "$BENCHMARKS_FILE" ]]; then
        log_error "No benchmark history to compare"
        exit 1
    fi

    # Parse range
    if [[ "$COMPARE" == *".."* ]]; then
        FROM_REF="${COMPARE%%\.\.*}"
        TO_REF="${COMPARE##*\.\.}"
    else
        log_error "Invalid compare range. Use: HEAD~5..HEAD"
        exit 1
    fi

    cd "${TORCHTITAN_DIR}"
    FROM_SHA=$(git rev-parse "$FROM_REF" 2>/dev/null | head -c 7)
    TO_SHA=$(git rev-parse "$TO_REF" 2>/dev/null | head -c 7)

    log_info "Comparing ${FROM_SHA} → ${TO_SHA}"
    python3 -c "
import json, sys

from_sha = '${FROM_SHA}'
to_sha = '${TO_SHA}'

runs = []
with open('${BENCHMARKS_FILE}') as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            runs.append(json.loads(line))
        except json.JSONDecodeError:
            continue

from_run = None
to_run = None
for run in runs:
    sha = run.get('sha', '')[:7]
    if sha == from_sha:
        from_run = run
    if sha == to_sha:
        to_run = run

if not from_run:
    print(f'No benchmark data for {from_sha}')
    sys.exit(1)
if not to_run:
    print(f'No benchmark data for {to_sha}')
    sys.exit(1)

fm = from_run.get('metrics', {})
tm = to_run.get('metrics', {})

print(f\"{'Metric':<20} {from_sha:<12} {to_sha:<12} {'Delta':>10}\")
print('-' * 56)
for metric in ['tps', 'mfu', 'tflops', 'max_memory_gib']:
    fv = fm.get(metric, 0)
    tv = tm.get(metric, 0)
    if fv > 0:
        delta = ((tv - fv) / fv) * 100
        print(f'{metric:<20} {fv:<12.2f} {tv:<12.2f} {delta:>+8.1f}%')
    else:
        print(f'{metric:<20} {fv:<12.2f} {tv:<12.2f} {\"N/A\":>10}')
" 2>/dev/null
    exit 0
fi

# Run a benchmark (delegates to ttci run --benchmark)
if [[ -n "$BENCHMARK_NAME" ]]; then
    exec bash "${SCRIPT_DIR}/run.sh" --benchmark "$BENCHMARK_NAME"
fi

# Default: run all configured benchmarks
log_info "Running all configured benchmarks..."
exec bash "${SCRIPT_DIR}/run.sh" --benchmark "qwen3_30b_a3b_deepep"
