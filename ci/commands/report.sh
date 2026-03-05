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
            echo "Shows duration trends, benchmark regression, GPU memory."
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

since_dt = None
if since_str:
    if since_str.endswith('d'):
        since_dt = datetime.utcnow() - timedelta(days=int(since_str[:-1]))
    elif since_str.endswith('h'):
        since_dt = datetime.utcnow() - timedelta(hours=int(since_str[:-1]))

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
    report = {"runs": [], "phase_trends": {}, "benchmark_trend": [], "convergence_trend": [], "gpu_trends": [], "pass_fail": {}}

# ===========================================================================
# TABLE 1: Run Overview with Duration & Status
# ===========================================================================
phases_all = ['unit_tests', 'distributed_deepep', 'integration_features', 'integration_models', 'reference_benchmark', 'convergence_test']

if not json_mode:
    print("=" * 120)
    print("  RUN HISTORY")
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
        run_entry = {"run_id": rid, "sha": sha, "trigger": trigger, "status": status, "total_sec": total, "phases": {}}

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
            marker = "!" if ps == "fail" else ""
            cell = f"{dur}s{marker}" if dur else "-"
            line += f" {cell:>10}"

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
# TABLE 2: Phase Duration Trends
# ===========================================================================
if not json_mode:
    print()
    print("=" * 100)
    print("  PHASE DURATION TRENDS")
    print("=" * 100)
    print(f"  {'Phase':<28} {'Avg':>7} {'Min':>7} {'Max':>7} {'Latest':>8} {'vs Avg':>8} {'Trend'}")
    print("  " + "-" * 95)

for p in phases_all:
    durations = [r.get('phases', {}).get(p, {}).get('duration_sec', 0) for r in runs]
    durations = [d for d in durations if d > 0]
    if not durations:
        if not json_mode:
            print(f"  {p:<28} {'--':>7} {'--':>7} {'--':>7} {'--':>8} {'--':>8}")
        continue

    avg = sum(durations) / len(durations)
    mn, mx, latest = min(durations), max(durations), durations[-1]
    delta_pct = ((latest - avg) / avg * 100) if avg > 0 else 0

    if json_mode:
        report["phase_trends"][p] = {"avg_sec": round(avg, 1), "min_sec": mn, "max_sec": mx, "latest_sec": latest, "delta_vs_avg_pct": round(delta_pct, 1), "samples": len(durations)}
    else:
        if delta_pct > 15: trend = "\u2b06\ufe0f  SLOWER"
        elif delta_pct > 5: trend = "\u26a0\ufe0f  slower"
        elif delta_pct < -15: trend = "\u2b07\ufe0f  FASTER"
        elif delta_pct < -5: trend = "\u2705 faster"
        else: trend = "   stable"
        sign = "+" if delta_pct > 0 else ""
        print(f"  {p:<28} {avg:>6.0f}s {mn:>6}s {mx:>6}s {latest:>7}s {sign}{delta_pct:>6.0f}%  {trend}")

# ===========================================================================
# TABLE 3: Reference Benchmark Trend (TPS, MFU, Memory regression)
# ===========================================================================
runs_with_bench = [r for r in runs if r.get('benchmark_metrics') and r['benchmark_metrics'] != {}]

if runs_with_bench:
    if not json_mode:
        print()
        print("=" * 120)
        print("  REFERENCE BENCHMARK — qwen3_30b_a3b_deepep (8 GPU)")
        print("=" * 120)
        print(f"  {'Run ID':<18} {'SHA':<9} {'Avg TPS':>9} {'TPS Delta':>10} {'Avg MFU':>9} {'TFLOPS':>9} {'Max Mem':>10} {'Mem Delta':>10} {'Steps':>6}")
        print("  " + "-" * 105)

    prev_tps = None
    prev_mem = None
    all_tps = []
    all_mem = []

    for r in runs_with_bench:
        bm = r['benchmark_metrics']
        rid = r.get('run_id', '?')
        sha = r.get('sha', '?')[:7]
        avg_tps = bm.get('avg_tps', 0)
        avg_mfu = bm.get('avg_mfu_pct', 0)
        avg_tflops = bm.get('avg_tflops', 0)
        max_mem = bm.get('max_memory_gib', 0)
        samples = bm.get('samples', 0)

        all_tps.append(avg_tps)
        all_mem.append(max_mem)

        tps_delta = ""
        mem_delta = ""
        if prev_tps and prev_tps > 0:
            d = (avg_tps - prev_tps) / prev_tps * 100
            if abs(d) >= 2:
                sign = "+" if d > 0 else ""
                tps_delta = f"{sign}{d:.1f}%"
                if d < -10:
                    tps_delta += " \u274c"
                elif d < -5:
                    tps_delta += " \u26a0\ufe0f"

        if prev_mem and prev_mem > 0:
            d = (max_mem - prev_mem) / prev_mem * 100
            if abs(d) >= 2:
                sign = "+" if d > 0 else ""
                mem_delta = f"{sign}{d:.1f}%"
                if d > 10:
                    mem_delta += " \u274c"
                elif d > 5:
                    mem_delta += " \u26a0\ufe0f"

        if json_mode:
            entry = {"run_id": rid, "sha": sha, "avg_tps": avg_tps, "avg_mfu_pct": avg_mfu, "avg_tflops": avg_tflops, "max_memory_gib": max_mem, "samples": samples}
            if prev_tps and prev_tps > 0:
                entry["tps_delta_pct"] = round((avg_tps - prev_tps) / prev_tps * 100, 1)
            if prev_mem and prev_mem > 0:
                entry["mem_delta_pct"] = round((max_mem - prev_mem) / prev_mem * 100, 1)
            report["benchmark_trend"].append(entry)
        else:
            print(f"  {rid:<18} {sha:<9} {avg_tps:>8.0f} {tps_delta:>10} {avg_mfu:>7.2f}% {avg_tflops:>8.2f} {max_mem:>8.2f}GiB {mem_delta:>10} {samples:>5}")

        prev_tps = avg_tps
        prev_mem = max_mem

    # Summary line
    if not json_mode and len(all_tps) >= 2:
        avg_all_tps = sum(all_tps) / len(all_tps)
        avg_all_mem = sum(all_mem) / len(all_mem)
        latest_tps = all_tps[-1]
        latest_mem = all_mem[-1]
        tps_vs_avg = ((latest_tps - avg_all_tps) / avg_all_tps * 100) if avg_all_tps > 0 else 0
        mem_vs_avg = ((latest_mem - avg_all_mem) / avg_all_mem * 100) if avg_all_mem > 0 else 0
        print("  " + "-" * 105)
        tsign = "+" if tps_vs_avg > 0 else ""
        msign = "+" if mem_vs_avg > 0 else ""
        print(f"  {'Avg over all runs':<28}         {avg_all_tps:>8.0f}           {' ':>8}   {' ':>8} {avg_all_mem:>8.2f}GiB")
        print(f"  {'Latest vs avg':<28}               {tsign}{tps_vs_avg:.1f}%{' ':>20}{msign}{mem_vs_avg:.1f}%")

elif not json_mode:
    print()
    print("=" * 80)
    print("  REFERENCE BENCHMARK")
    print("=" * 80)
    print("  No benchmark data yet. Next CI run will include reference benchmark.")
    print("  Config: qwen3_30b_a3b_with_deepep.toml (8 GPU, 20 steps)")

# ===========================================================================
# TABLE 4: Convergence Test (deterministic loss comparison)
# ===========================================================================
runs_with_conv = [r for r in runs if r.get('convergence_test') and r['convergence_test'] != {} and r['convergence_test'].get('status')]

if runs_with_conv:
    if not json_mode:
        print()
        print("=" * 110)
        print("  CONVERGENCE TEST — deterministic loss comparison (seed=42)")
        print("=" * 110)
        print(f"  {'Run ID':<18} {'SHA':<9} {'Status':<10} {'Steps':>6} {'Mismatches':>11} {'Max Diff':>12} {'Final Loss':>12} {'vs Ref':>12}")
        print("  " + "-" * 105)

    for r in runs_with_conv:
        ct = r['convergence_test']
        rid = r.get('run_id', '?')
        sha = r.get('sha', '?')[:7]
        status = ct.get('status', '?').upper()
        num_compared = ct.get('num_compared', 0)
        num_mismatch = ct.get('num_mismatch', 0)
        max_diff = ct.get('max_diff', 0)
        final_cur = ct.get('final_loss_cur')
        final_ref = ct.get('final_loss_ref')

        if status == 'BASELINE':
            icon = "\U0001f4cb"
        elif status == 'PASS':
            icon = "\u2705"
        else:
            icon = "\u274c"

        final_str = f"{final_cur:.4f}" if final_cur else "-"
        ref_delta = ""
        if final_cur and final_ref:
            d = abs(final_cur - final_ref)
            if d > 0:
                ref_delta = f"diff={d:.6f}"

        if json_mode:
            report["convergence_trend"].append({
                "run_id": rid, "sha": sha, "status": status,
                "num_compared": num_compared, "num_mismatch": num_mismatch,
                "max_diff": max_diff, "final_loss": final_cur, "final_loss_ref": final_ref
            })
        else:
            mismatch_str = f"{num_mismatch}/{num_compared}" if num_compared else "-"
            diff_str = f"{max_diff:.8f}" if max_diff > 0 else "0.0"
            print(f"  {icon} {rid:<16} {sha:<9} {status:<10} {num_compared:>5} {mismatch_str:>11} {diff_str:>12} {final_str:>12} {ref_delta:>12}")

    if not json_mode:
        pass_ct = sum(1 for r in runs_with_conv if r['convergence_test'].get('status') in ('pass', 'baseline'))
        fail_ct = sum(1 for r in runs_with_conv if r['convergence_test'].get('status') == 'fail')
        print("  " + "-" * 105)
        print(f"  Summary: {pass_ct} pass, {fail_ct} fail out of {len(runs_with_conv)} runs with convergence data")

elif not json_mode:
    print()
    print("=" * 80)
    print("  CONVERGENCE TEST")
    print("=" * 80)
    print("  No convergence data yet. First run will create seed checkpoint + baseline.")

# ===========================================================================
# TABLE 5: GPU Memory Trend (nvidia-smi, aggregate)
# ===========================================================================
runs_with_gpu = [r for r in runs if r.get('gpu_stats')]

if runs_with_gpu:
    if not json_mode:
        print()
        print("=" * 110)
        print("  GPU MONITORING (nvidia-smi)")
        print("=" * 110)
        print(f"  {'Run ID':<18} {'SHA':<9} {'Peak Mem':>10} {'Avg Mem':>10} {'Mem %':>7} {'Peak Temp':>10} {'Peak Pwr':>10} {'Avg Pwr':>10}")
        print("  " + "-" * 105)

    prev_max_mem = None
    for r in runs_with_gpu:
        gs = r.get('gpu_stats', {})
        rid = r.get('run_id', '?')
        sha = r.get('sha', '?')[:7]

        all_max_mem = [s.get('max_memory_used_mib', 0) for s in gs.values()]
        all_avg_mem = [s.get('avg_memory_used_mib', 0) for s in gs.values()]
        all_mem_total = [s.get('memory_total_mib', 0) for s in gs.values()]
        all_max_temp = [s.get('max_temperature_c', 0) for s in gs.values()]
        all_max_pwr = [s.get('max_power_w', 0) for s in gs.values()]
        all_avg_pwr = [s.get('avg_power_w', 0) for s in gs.values()]

        if not all_max_mem:
            continue

        peak_mem = max(all_max_mem)
        avg_mem = sum(all_avg_mem) / len(all_avg_mem)
        total_mem = max(all_mem_total) if all_mem_total else 0
        mem_pct = (peak_mem / total_mem * 100) if total_mem > 0 else 0
        peak_temp = max(all_max_temp)
        peak_pwr = max(all_max_pwr)
        avg_pwr = sum(all_avg_pwr) / len(all_avg_pwr)

        mem_delta = ""
        if prev_max_mem is not None and prev_max_mem > 0:
            d = (peak_mem - prev_max_mem) / prev_max_mem * 100
            if abs(d) >= 3:
                sign = "+" if d > 0 else ""
                mem_delta = f" ({sign}{d:.0f}%)"

        if json_mode:
            report["gpu_trends"].append({"run_id": rid, "sha": sha, "peak_memory_mib": peak_mem, "avg_memory_mib": round(avg_mem), "memory_total_mib": total_mem, "memory_pct": round(mem_pct, 1), "peak_temperature_c": peak_temp, "peak_power_w": peak_pwr, "avg_power_w": round(avg_pwr, 1)})
        else:
            print(f"  {rid:<18} {sha:<9} {peak_mem:>8.0f}Mi {avg_mem:>8.0f}Mi {mem_pct:>5.1f}% {peak_temp:>8.0f}C {peak_pwr:>8.1f}W {avg_pwr:>8.1f}W{mem_delta}")

        prev_max_mem = peak_mem

# ===========================================================================
# TABLE 6: Pass/Fail Rate
# ===========================================================================
if not json_mode:
    print()
    print("=" * 80)
    print("  PASS/FAIL RATE")
    print("=" * 80)
    print(f"  {'Phase':<28} {'Pass':>6} {'Fail':>6} {'Total':>6} {'Rate':>8} {'Streak'}")
    print("  " + "-" * 75)

for p in phases_all:
    pass_count = fail_count = streak = 0
    streak_type = None
    for r in runs:
        s = r.get('phases', {}).get(p, {}).get('status', '')
        if s == 'pass':
            pass_count += 1
            streak = streak + 1 if streak_type == 'pass' else 1
            streak_type = 'pass'
        elif s == 'fail':
            fail_count += 1
            streak = streak + 1 if streak_type == 'fail' else 1
            streak_type = 'fail'

    total = pass_count + fail_count
    rate = (pass_count / total * 100) if total > 0 else 0
    streak_str = f"{streak} {'pass' if streak_type == 'pass' else 'FAIL'}" if streak_type else "-"

    if json_mode:
        report["pass_fail"][p] = {"pass": pass_count, "fail": fail_count, "total": total, "rate_pct": round(rate, 1), "current_streak": streak_str}
    else:
        ic = "\u2705" if rate == 100 else "\u26a0\ufe0f" if rate >= 50 else "\u274c"
        print(f"  {p:<28} {pass_count:>6} {fail_count:>6} {total:>6} {rate:>6.0f}%  {ic} {streak_str}")

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
    print(f"  Analyzed {len(runs)} runs. GPU data: {len(runs_with_gpu)}. Benchmark data: {len(runs_with_bench)}. Convergence data: {len(runs_with_conv)}.")
    print()

PYEOF
