#!/usr/bin/env bash
# =============================================================================
# ttci report — Generate performance & regression tracking tables
# =============================================================================
# Usage: ttci report [--json] [--limit N] [--since <period>]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
load_config

JSON_MODE=false
LIMIT=20
SINCE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --json)   JSON_MODE=true; shift ;;
        --limit)  LIMIT="$2"; shift 2 ;;
        --since)  SINCE="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: ttci report [--json] [--limit N] [--since <period>]"
            echo ""
            echo "Generate performance tracking tables from run history."
            echo "Shows duration trends, GPU memory, regressions per phase."
            echo ""
            echo "Options:"
            echo "  --json         Output raw JSON"
            echo "  --limit N      Max runs to analyze (default: 20)"
            echo "  --since <N>d   Only analyze runs from last N days"
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

PY_JSON=$([[ "$JSON_MODE" == "true" ]] && echo "1" || echo "0")

python3 - "$RUNS_FILE" "$PY_JSON" "$LIMIT" "$SINCE" <<'PYEOF'
import json, sys
from datetime import datetime, timedelta

runs_file = sys.argv[1]
json_mode = sys.argv[2] == "1"
limit = int(sys.argv[3])
since_str = sys.argv[4] or None

# Parse since
since_dt = None
if since_str:
    if since_str.endswith('d'):
        since_dt = datetime.utcnow() - timedelta(days=int(since_str[:-1]))
    elif since_str.endswith('h'):
        since_dt = datetime.utcnow() - timedelta(hours=int(since_str[:-1]))

# Load runs
runs = []
with open(runs_file) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            r = json.loads(line)
            if since_dt:
                ts = r.get('timestamp', '')
                try:
                    run_dt = datetime.fromisoformat(ts.replace('Z', '+00:00')).replace(tzinfo=None)
                    if run_dt < since_dt:
                        continue
                except (ValueError, TypeError):
                    pass
            runs.append(r)
        except json.JSONDecodeError:
            continue

runs = runs[-limit:]

if not runs:
    print("No matching runs found.")
    sys.exit(0)

if json_mode:
    report = {"runs": [], "phase_trends": {}, "gpu_trends": []}

# ===========================================================================
# TABLE 1: Run Overview
# ===========================================================================
phases_all = ['unit_tests', 'distributed_deepep', 'integration_features', 'integration_models']

if not json_mode:
    print("=" * 120)
    print("  RUN HISTORY — Duration & Status")
    print("=" * 120)
    hdr = f"{'Run ID':<18} {'SHA':<9} {'Trigger':<10} {'Status':<6}"
    for p in phases_all:
        short = p.replace('integration_', 'integ_').replace('distributed_', 'dist_')[:10]
        hdr += f" {short:>10}"
    hdr += f" {'Total':>7} {'Delta':>7}"
    print(hdr)
    print("-" * 120)

prev_total = None
for r in runs:
    rid = r.get('run_id', '?')
    sha = r.get('sha', '?')[:7]
    trigger = r.get('trigger', '?')
    pr = r.get('pr_number')
    if pr:
        trigger = f"PR#{pr}"
    status = r.get('overall_status', '?').upper()
    phases = r.get('phases', {})
    total = r.get('total_duration_sec', 0)

    if json_mode:
        run_entry = {
            "run_id": rid, "sha": sha, "trigger": trigger, "status": status,
            "total_sec": total, "phases": {}
        }

    if not json_mode:
        icon = "\u2705" if status == "PASS" else "\u274c"
        line = f"{icon} {rid:<16} {sha:<9} {trigger:<10} {status:<6}"

    for p in phases_all:
        pi = phases.get(p, {})
        dur = pi.get('duration_sec', 0)
        ps = pi.get('status', '?')
        if json_mode:
            run_entry["phases"][p] = {"duration_sec": dur, "status": ps}
        else:
            marker = ""
            if ps == "fail":
                marker = "!"
            elif ps == "pass":
                marker = ""
            cell = f"{dur}s{marker}" if dur else "-"
            line += f" {cell:>10}"

    # Delta vs previous run
    delta_str = ""
    if prev_total is not None and prev_total > 0:
        delta = total - prev_total
        pct = (delta / prev_total) * 100
        if abs(pct) >= 5:
            sign = "+" if delta > 0 else ""
            delta_str = f"{sign}{pct:.0f}%"
            if json_mode:
                run_entry["total_delta_pct"] = round(pct, 1)

    if not json_mode:
        line += f" {total:>6}s {delta_str:>7}"
        print(line)

    if json_mode:
        report["runs"].append(run_entry)

    prev_total = total

# ===========================================================================
# TABLE 2: Phase Duration Trends (avg, min, max, latest, delta)
# ===========================================================================
if not json_mode:
    print()
    print("=" * 100)
    print("  PHASE DURATION TRENDS")
    print("=" * 100)
    print(f"  {'Phase':<28} {'Avg':>7} {'Min':>7} {'Max':>7} {'Latest':>8} {'vs Avg':>8} {'Trend'}")
    print("  " + "-" * 95)

for p in phases_all:
    durations = []
    for r in runs:
        d = r.get('phases', {}).get(p, {}).get('duration_sec', 0)
        if d > 0:
            durations.append(d)

    if not durations:
        if not json_mode:
            print(f"  {p:<28} {'--':>7} {'--':>7} {'--':>7} {'--':>8} {'--':>8}")
        continue

    avg = sum(durations) / len(durations)
    mn = min(durations)
    mx = max(durations)
    latest = durations[-1]
    delta_pct = ((latest - avg) / avg * 100) if avg > 0 else 0

    if json_mode:
        report["phase_trends"][p] = {
            "avg_sec": round(avg, 1), "min_sec": mn, "max_sec": mx,
            "latest_sec": latest, "delta_vs_avg_pct": round(delta_pct, 1),
            "samples": len(durations)
        }
    else:
        # Trend indicator
        if delta_pct > 15:
            trend = "\u2b06\ufe0f  SLOWER"
        elif delta_pct > 5:
            trend = "\u26a0\ufe0f  slower"
        elif delta_pct < -15:
            trend = "\u2b07\ufe0f  FASTER"
        elif delta_pct < -5:
            trend = "\u2705 faster"
        else:
            trend = "   stable"

        sign = "+" if delta_pct > 0 else ""
        print(f"  {p:<28} {avg:>6.0f}s {mn:>6}s {mx:>6}s {latest:>7}s {sign}{delta_pct:>6.0f}%  {trend}")

# ===========================================================================
# TABLE 3: GPU Memory & Power (per run, aggregate across GPUs)
# ===========================================================================
runs_with_gpu = [r for r in runs if r.get('gpu_stats')]

if runs_with_gpu:
    if not json_mode:
        print()
        print("=" * 120)
        print("  GPU STATS PER RUN (aggregate across all GPUs)")
        print("=" * 120)
        print(f"  {'Run ID':<18} {'SHA':<9} {'Max Mem':>10} {'Avg Mem':>10} {'Mem Total':>10} {'Mem %':>7} {'Max Temp':>9} {'Max Pwr':>9} {'Avg Pwr':>9} {'Samples':>8}")
        print("  " + "-" * 115)

    prev_max_mem = None
    for r in runs_with_gpu:
        gs = r.get('gpu_stats', {})
        rid = r.get('run_id', '?')
        sha = r.get('sha', '?')[:7]

        all_max_mem = []
        all_avg_mem = []
        all_mem_total = []
        all_max_temp = []
        all_max_pwr = []
        all_avg_pwr = []
        all_samples = []

        for gpu_id, s in gs.items():
            all_max_mem.append(s.get('max_memory_used_mib', 0))
            all_avg_mem.append(s.get('avg_memory_used_mib', 0))
            all_mem_total.append(s.get('memory_total_mib', 0))
            all_max_temp.append(s.get('max_temperature_c', 0))
            all_max_pwr.append(s.get('max_power_w', 0))
            all_avg_pwr.append(s.get('avg_power_w', 0))
            all_samples.append(s.get('samples', 0))

        if not all_max_mem:
            continue

        peak_mem = max(all_max_mem)
        avg_mem = sum(all_avg_mem) / len(all_avg_mem)
        total_mem = max(all_mem_total) if all_mem_total else 0
        mem_pct = (peak_mem / total_mem * 100) if total_mem > 0 else 0
        peak_temp = max(all_max_temp)
        peak_pwr = max(all_max_pwr)
        avg_pwr = sum(all_avg_pwr) / len(all_avg_pwr)
        samples = max(all_samples)

        # Memory delta
        mem_delta = ""
        if prev_max_mem is not None and prev_max_mem > 0:
            d = (peak_mem - prev_max_mem) / prev_max_mem * 100
            if abs(d) >= 3:
                sign = "+" if d > 0 else ""
                mem_delta = f" ({sign}{d:.0f}%)"

        if json_mode:
            report["gpu_trends"].append({
                "run_id": rid, "sha": sha,
                "peak_memory_mib": peak_mem, "avg_memory_mib": round(avg_mem),
                "memory_total_mib": total_mem, "memory_pct": round(mem_pct, 1),
                "peak_temperature_c": peak_temp,
                "peak_power_w": peak_pwr, "avg_power_w": round(avg_pwr, 1),
                "samples": samples
            })
        else:
            print(f"  {rid:<18} {sha:<9} {peak_mem:>8.0f}Mi {avg_mem:>8.0f}Mi {total_mem:>8.0f}Mi {mem_pct:>5.1f}% {peak_temp:>7.0f}C {peak_pwr:>7.1f}W {avg_pwr:>7.1f}W {samples:>7}{mem_delta}")

        prev_max_mem = peak_mem

    # Per-GPU breakdown for latest run
    latest_gpu = runs_with_gpu[-1]
    gs = latest_gpu.get('gpu_stats', {})
    if gs and not json_mode:
        print()
        print(f"  Per-GPU Breakdown (latest run: {latest_gpu.get('run_id', '?')})")
        print(f"  {'GPU':>5} {'Max Mem':>10} {'Avg Mem':>10} {'Mem %':>7} {'Max Util':>9} {'Avg Util':>9} {'Max Temp':>9} {'Max Pwr':>9}")
        print("  " + "-" * 80)
        total_mem = 0
        for gpu_id in sorted(gs.keys(), key=lambda x: int(x)):
            s = gs[gpu_id]
            mm = s.get('max_memory_used_mib', 0)
            am = s.get('avg_memory_used_mib', 0)
            mt = s.get('memory_total_mib', 0)
            total_mem = mt
            mp = (mm / mt * 100) if mt > 0 else 0
            mu = s.get('max_utilization_pct', 0)
            au = s.get('avg_utilization_pct', 0)
            mtemp = s.get('max_temperature_c', 0)
            mpwr = s.get('max_power_w', 0)
            print(f"  {'GPU'+gpu_id:>5} {mm:>8.0f}Mi {am:>8.0f}Mi {mp:>5.1f}% {mu:>7.0f}% {au:>7.1f}% {mtemp:>7.0f}C {mpwr:>7.1f}W")

elif not json_mode:
    print()
    print("  (No GPU stats available yet — first run had no monitoring)")

# ===========================================================================
# TABLE 4: Pass/Fail Rate Summary
# ===========================================================================
if not json_mode:
    print()
    print("=" * 80)
    print("  PASS/FAIL RATE")
    print("=" * 80)
    print(f"  {'Phase':<28} {'Pass':>6} {'Fail':>6} {'Total':>6} {'Rate':>8} {'Streak'}")
    print("  " + "-" * 75)

for p in phases_all:
    pass_count = 0
    fail_count = 0
    streak = 0
    streak_type = None
    for r in runs:
        s = r.get('phases', {}).get(p, {}).get('status', '')
        if s == 'pass':
            pass_count += 1
            if streak_type == 'pass':
                streak += 1
            else:
                streak = 1
                streak_type = 'pass'
        elif s == 'fail':
            fail_count += 1
            if streak_type == 'fail':
                streak += 1
            else:
                streak = 1
                streak_type = 'fail'

    total = pass_count + fail_count
    rate = (pass_count / total * 100) if total > 0 else 0

    streak_str = f"{streak} {'pass' if streak_type == 'pass' else 'FAIL'}" if streak_type else "-"

    if json_mode:
        if "pass_fail" not in report:
            report["pass_fail"] = {}
        report["pass_fail"][p] = {
            "pass": pass_count, "fail": fail_count, "total": total,
            "rate_pct": round(rate, 1), "current_streak": streak_str
        }
    else:
        rate_color = ""
        if rate == 100:
            rate_color = "\u2705"
        elif rate >= 50:
            rate_color = "\u26a0\ufe0f"
        else:
            rate_color = "\u274c"
        print(f"  {p:<28} {pass_count:>6} {fail_count:>6} {total:>6} {rate:>6.0f}%  {rate_color} {streak_str}")

# Overall
op = sum(1 for r in runs if r.get('overall_status') == 'pass')
of = sum(1 for r in runs if r.get('overall_status') == 'fail')
ot = op + of
orate = (op / ot * 100) if ot > 0 else 0
if not json_mode:
    print(f"  {'OVERALL':<28} {op:>6} {of:>6} {ot:>6} {orate:>6.0f}%")

if json_mode:
    report["overall"] = {"pass": op, "fail": of, "total": ot, "rate_pct": round(orate, 1)}
    print(json.dumps(report, indent=2))
else:
    print()
    print(f"  Analyzed {len(runs)} runs.  Runs with GPU data: {len(runs_with_gpu)}.")
    print()

PYEOF
