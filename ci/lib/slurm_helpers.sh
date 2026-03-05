#!/usr/bin/env bash
# =============================================================================
# slurm_helpers.sh — Slurm submit/query/cancel helpers
# =============================================================================

[[ -n "${_TTCI_SLURM_HELPERS_LOADED:-}" ]] && return 0
_TTCI_SLURM_HELPERS_LOADED=1

SCRIPT_DIR_SLURM="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR_SLURM}/common.sh"

# Submit a Slurm job
# Usage: submit_job <slurm_script> [extra_sbatch_args...]
# Returns: job ID on stdout
submit_job() {
    local script="$1"
    shift

    if [[ ! -f "$script" ]]; then
        log_error "Slurm script not found: $script"
        return 1
    fi

    local job_id
    job_id=$(sbatch --parsable "$@" "$script" 2>&1)
    local rc=$?

    if [[ $rc -eq 0 ]]; then
        log_info "Submitted job ${job_id} (script: $(basename "$script"))"
        echo "$job_id"
    else
        log_error "sbatch failed: $job_id"
        return 1
    fi
}

# Check if a job with given name prefix is running or queued
# Usage: is_job_running <job_name_prefix>
is_job_running() {
    local name_prefix="$1"
    local count
    count=$(squeue -n "${name_prefix}" -h -o "%i" 2>/dev/null | wc -l)
    [[ "$count" -gt 0 ]]
}

# Count idle nodes in a partition
# Usage: count_idle_nodes <partition>
count_idle_nodes() {
    local partition="${1:-${SLURM_PARTITION:-batch}}"
    local count
    count=$(sinfo -p "$partition" -t idle -h -o "%D" 2>/dev/null | head -1)
    echo "${count:-0}"
}

# Cancel jobs by name prefix
# Usage: cancel_job <job_name_prefix>
cancel_job() {
    local name_prefix="$1"
    local job_ids
    job_ids=$(squeue -n "$name_prefix" -h -o "%i" 2>/dev/null)

    if [[ -z "$job_ids" ]]; then
        log_info "No jobs found matching '$name_prefix'"
        return 0
    fi

    for jid in $job_ids; do
        scancel "$jid" 2>/dev/null
        log_info "Cancelled job $jid"
    done
}

# Wait for a job to complete
# Usage: wait_for_job <job_id> [poll_interval_sec]
# Returns 0 if job completed successfully, 1 otherwise
wait_for_job() {
    local job_id="$1"
    local poll_interval="${2:-10}"

    log_info "Waiting for job $job_id to complete..."

    while true; do
        local state
        state=$(squeue -j "$job_id" -h -o "%T" 2>/dev/null)

        if [[ -z "$state" ]]; then
            # Job no longer in queue — check sacct for final status
            local exit_info
            exit_info=$(sacct -j "$job_id" -n -o State -X 2>/dev/null | head -1 | tr -d ' ')

            case "$exit_info" in
                COMPLETED)
                    log_info "Job $job_id completed successfully"
                    return 0
                    ;;
                FAILED|TIMEOUT|CANCELLED*|PREEMPTED|OUT_OF_MEMORY)
                    log_warn "Job $job_id ended with status: $exit_info"
                    return 1
                    ;;
                *)
                    log_info "Job $job_id finished (status: ${exit_info:-unknown})"
                    return 0
                    ;;
            esac
        fi

        log_debug "Job $job_id state: $state"
        sleep "$poll_interval"
    done
}

# Get job details by ID
# Usage: get_job_info <job_id>
get_job_info() {
    local job_id="$1"
    squeue -j "$job_id" -h -o "%i %j %T %M %N %P" 2>/dev/null
}

# List all CI jobs (running + queued)
list_ci_jobs() {
    local prefix="${SLURM_JOB_PREFIX:-ci-torchtitan}"
    squeue -u "$USER" -h -o "%i %j %T %M %N %P" 2>/dev/null | grep "$prefix" || true
}
