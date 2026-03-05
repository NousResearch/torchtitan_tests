#!/usr/bin/env bash
# =============================================================================
# Convergence Test — deterministic loss comparison across code changes
# =============================================================================
# This script:
# 1. Creates a fixed local dataset (synthetic nanoset) if one doesn't exist
# 2. Creates a seed checkpoint (random init weights) if one doesn't exist
# 3. Trains for N steps from that seed with deterministic mode + fixed dataset
# 4. Saves per-step loss to JSON
# 5. Compares against reference loss file (first run becomes reference)
#
# Both the dataset and seed checkpoint are stored in ci/data/ and persist
# across runs. They are NOT in git (too large) but are deterministically
# generated so they can be recreated identically on any machine.
#
# Usage: convergence_test.sh <output_dir> [--config <toml>] [--steps N] [--seed S]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CI_DIR="${CI_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
source "${CI_DIR}/lib/common.sh"
load_config

# =============================================================================
# Parse arguments
# =============================================================================
OUTPUT_DIR="${1:?Usage: convergence_test.sh <output_dir>}"
shift || true

CONV_CONFIG=$(yaml_get "${TTCI_CONFIG}" "convergence_test.config")
CONV_NGPU=$(yaml_get "${TTCI_CONFIG}" "convergence_test.ngpu")
CONV_STEPS=$(yaml_get "${TTCI_CONFIG}" "convergence_test.steps")
CONV_SEED=$(yaml_get "${TTCI_CONFIG}" "convergence_test.seed")
CONV_DATASET_SEED=$(yaml_get "${TTCI_CONFIG}" "convergence_test.dataset_seed")
CONV_SEED_CKPT_DIR=$(yaml_get "${TTCI_CONFIG}" "convergence_test.seed_checkpoint_dir")
CONV_DATASET_DIR=$(yaml_get "${TTCI_CONFIG}" "convergence_test.dataset_dir")
CONV_REF_LOSS=$(yaml_get "${TTCI_CONFIG}" "convergence_test.reference_loss_file")
CONV_TOLERANCE=$(yaml_get "${TTCI_CONFIG}" "convergence_test.tolerance")

# CLI overrides
while [[ $# -gt 0 ]]; do
    case "$1" in
        --config) CONV_CONFIG="$2"; shift 2 ;;
        --steps)  CONV_STEPS="$2"; shift 2 ;;
        --seed)   CONV_SEED="$2"; shift 2 ;;
        --ngpu)   CONV_NGPU="$2"; shift 2 ;;
        *) shift ;;
    esac
done

CONV_NGPU="${CONV_NGPU:-8}"
CONV_STEPS="${CONV_STEPS:-100}"
CONV_SEED="${CONV_SEED:-42}"
CONV_DATASET_SEED="${CONV_DATASET_SEED:-12345}"
CONV_TOLERANCE="${CONV_TOLERANCE:-0.0}"

ensure_dir "${OUTPUT_DIR}"
ensure_dir "${CONV_SEED_CKPT_DIR}"
ensure_dir "${CONV_DATASET_DIR}"

LOSS_FILE="${OUTPUT_DIR}/step_losses.json"
TRAIN_LOG="${OUTPUT_DIR}/convergence_train.log"
RESULT_FILE="${OUTPUT_DIR}/convergence_result.json"

cd "${TORCHTITAN_DIR}"
source "${VENV_DIR}/bin/activate"

# =============================================================================
# Step 1: Verify fixed dataset exists (committed in ci/data/convergence_dataset/)
# =============================================================================
DATASET_FILE="${CONV_DATASET_DIR}/convergence_data.ds"

if [[ ! -f "${DATASET_FILE}" ]]; then
    log_error "Convergence dataset not found at ${CONV_DATASET_DIR}!"
    log_error "This should be committed in the repo. Run: python3 ci/scripts/create_convergence_dataset.py ${CONV_DATASET_DIR}"
    exit 1
fi

log_info "Convergence dataset: ${CONV_DATASET_DIR} ($(du -sh "${CONV_DATASET_DIR}" | cut -f1))"

# =============================================================================
# Step 2: Create seed checkpoint if it doesn't exist
# =============================================================================
SEED_STEP_DIR="${CONV_SEED_CKPT_DIR}/step-0"

if [[ ! -d "${SEED_STEP_DIR}" ]] || [[ -z "$(ls -A "${SEED_STEP_DIR}" 2>/dev/null)" ]]; then
    log_info "Creating seed checkpoint (random init weights)..."
    log_info "This runs once with NGPU=1 to save initial model state"

    NGPU=1 LOG_RANK=0 CONFIG_FILE="./${CONV_CONFIG}" \
        ./run_train.sh \
        --checkpoint.enable \
        --checkpoint.create_seed_checkpoint \
        --checkpoint.folder "${CONV_SEED_CKPT_DIR}" \
        --parallelism.data_parallel_replicate_degree 1 \
        --parallelism.data_parallel_shard_degree 1 \
        --parallelism.tensor_parallel_degree 1 \
        --parallelism.pipeline_parallel_degree 1 \
        --parallelism.context_parallel_degree 1 \
        --parallelism.expert_parallel_degree 1 \
        --debug.seed "${CONV_SEED}" \
        --training.steps 1 \
        > "${OUTPUT_DIR}/seed_checkpoint_creation.log" 2>&1

    if [[ ! -d "${SEED_STEP_DIR}" ]]; then
        log_error "Failed to create seed checkpoint!"
        tail -30 "${OUTPUT_DIR}/seed_checkpoint_creation.log"
        exit 1
    fi

    log_info "Seed checkpoint created at ${SEED_STEP_DIR}"
else
    log_info "Seed checkpoint exists at ${SEED_STEP_DIR}"
fi

# =============================================================================
# Step 3: Run deterministic training from seed checkpoint + fixed dataset
# =============================================================================
log_info "Running convergence test: ${CONV_STEPS} steps, seed=${CONV_SEED}, ngpu=${CONV_NGPU}"
log_info "Dataset: ${CONV_DATASET_DIR}"
log_info "Seed checkpoint: ${SEED_STEP_DIR}"

RDZV_PORT=29503
JOB_ID="${SLURM_JOB_ID:-$$}"

torchrun \
    --nnodes=1 \
    --nproc_per_node="${CONV_NGPU}" \
    --rdzv_id="${JOB_ID}_convergence" \
    --rdzv_backend=c10d \
    --rdzv_endpoint="localhost:${RDZV_PORT}" \
    --local-ranks-filter=0 --role rank --tee 3 \
    -m torchtitan.train \
    --job.config_file "./${CONV_CONFIG}" \
    --checkpoint.enable \
    --checkpoint.initial_load_path "${SEED_STEP_DIR}" \
    --checkpoint.initial_load_model_only \
    --checkpoint.load_only \
    --debug.seed "${CONV_SEED}" \
    --debug.deterministic \
    --training.steps "${CONV_STEPS}" \
    --training.dataset_random_seed 1234 \
    --training.dataset_folders "[\"${CONV_DATASET_DIR}\"]" \
    --training.dataset_weights "[1]" \
    --metrics.log_freq 1 \
    --metrics.enable_wandb=false \
    --metrics.enable_tensorboard=false \
    --job.dump_folder "${OUTPUT_DIR}/train_output" \
    > "${TRAIN_LOG}" 2>&1

TRAIN_EXIT=$?

if [[ ${TRAIN_EXIT} -ne 0 ]]; then
    log_error "Convergence training failed (exit ${TRAIN_EXIT})"
    tail -20 "${TRAIN_LOG}"
    exit 1
fi

log_info "Training completed. Extracting per-step loss..."

# =============================================================================
# Step 4: Extract per-step loss values from training log
# =============================================================================
python3 - "${TRAIN_LOG}" "${LOSS_FILE}" <<'PYEOF'
import re, json, sys

log_file = sys.argv[1]
output_file = sys.argv[2]

step_losses = {}

with open(log_file) as f:
    for line in f:
        # Match lines like: "step:  1  loss:  8.1234  ..."
        m = re.search(r'step:\s*(\d+)\s+loss:\s*([\d.]+)', line)
        if m:
            step = int(m.group(1))
            loss = float(m.group(2))
            step_losses[step] = loss

# Sort by step
sorted_losses = dict(sorted(step_losses.items(), key=lambda x: x[0]))

result = {
    "steps": sorted_losses,
    "num_steps": len(sorted_losses),
    "final_loss": sorted_losses[max(sorted_losses.keys())] if sorted_losses else None,
}

with open(output_file, 'w') as f:
    json.dump(result, f, indent=2)

print(f"Extracted {len(sorted_losses)} step losses")
if sorted_losses:
    steps = sorted(sorted_losses.keys())
    print(f"  Step {steps[0]}: loss={sorted_losses[steps[0]]:.6f}")
    print(f"  Step {steps[-1]}: loss={sorted_losses[steps[-1]]:.6f}")
PYEOF

# =============================================================================
# Step 5: Compare with reference loss file
# =============================================================================
python3 - "${LOSS_FILE}" "${CONV_REF_LOSS}" "${RESULT_FILE}" "${CONV_TOLERANCE}" <<'PYEOF'
import json, sys, os

current_file = sys.argv[1]
reference_file = sys.argv[2]
result_file = sys.argv[3]
tolerance = float(sys.argv[4])

with open(current_file) as f:
    current = json.load(f)

current_steps = current.get("steps", {})

# If no reference exists, this run becomes the reference
if not os.path.exists(reference_file):
    print(f"No reference loss file found. Saving current run as reference.")
    with open(reference_file, 'w') as f:
        json.dump(current, f, indent=2)
    result = {
        "status": "baseline",
        "message": "First run — saved as reference baseline",
        "num_steps": len(current_steps),
        "final_loss": current.get("final_loss"),
        "max_diff": 0.0,
        "diffs": {}
    }
    with open(result_file, 'w') as f:
        json.dump(result, f, indent=2)
    print("CONVERGENCE: BASELINE (first run)")
    sys.exit(0)

# Load reference and compare
with open(reference_file) as f:
    reference = json.load(f)

ref_steps = reference.get("steps", {})

diffs = {}
max_diff = 0.0
max_diff_step = 0
num_compared = 0
num_mismatch = 0

for step_str, ref_loss in ref_steps.items():
    step = str(step_str)
    if step in current_steps:
        cur_loss = current_steps[step]
        diff = abs(cur_loss - ref_loss)
        rel_diff = diff / max(abs(ref_loss), 1e-10)
        diffs[step] = {
            "reference": ref_loss,
            "current": cur_loss,
            "abs_diff": round(diff, 8),
            "rel_diff_pct": round(rel_diff * 100, 6)
        }
        if diff > max_diff:
            max_diff = diff
            max_diff_step = int(step)
        if diff > tolerance:
            num_mismatch += 1
        num_compared += 1

# Determine status
if num_mismatch == 0:
    status = "pass"
    message = f"All {num_compared} steps match within tolerance {tolerance}"
    print(f"CONVERGENCE: PASS — {message}")
else:
    status = "fail"
    message = f"{num_mismatch}/{num_compared} steps differ beyond tolerance {tolerance}"
    print(f"CONVERGENCE: FAIL — {message}")
    print(f"  Max diff: {max_diff:.8f} at step {max_diff_step}")
    # Print first 5 mismatches
    shown = 0
    for step, d in sorted(diffs.items(), key=lambda x: int(x[0])):
        if d["abs_diff"] > tolerance:
            print(f"  Step {step}: ref={d['reference']:.6f} cur={d['current']:.6f} diff={d['abs_diff']:.8f}")
            shown += 1
            if shown >= 5:
                remaining = num_mismatch - shown
                if remaining > 0:
                    print(f"  ... and {remaining} more mismatches")
                break

# Summary
final_ref = reference.get("final_loss")
final_cur = current.get("final_loss")
if final_ref and final_cur:
    print(f"  Final loss: ref={final_ref:.6f} cur={final_cur:.6f} diff={abs(final_cur - final_ref):.8f}")

result = {
    "status": status,
    "message": message,
    "num_compared": num_compared,
    "num_mismatch": num_mismatch,
    "max_diff": round(max_diff, 8),
    "max_diff_step": max_diff_step,
    "tolerance": tolerance,
    "final_loss_ref": final_ref,
    "final_loss_cur": final_cur,
    "diffs": diffs
}

with open(result_file, 'w') as f:
    json.dump(result, f, indent=2)

sys.exit(0 if status == "pass" else 1)
PYEOF

COMPARE_EXIT=$?
log_info "Convergence comparison exit code: ${COMPARE_EXIT}"
exit ${COMPARE_EXIT}
