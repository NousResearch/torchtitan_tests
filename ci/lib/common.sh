#!/usr/bin/env bash
# =============================================================================
# common.sh — Shared functions for torchtitan CI/CD
# =============================================================================
# Source this from all CI scripts:
#   source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# =============================================================================

# Guard against double-sourcing
[[ -n "${_TTCI_COMMON_LOADED:-}" ]] && return 0
_TTCI_COMMON_LOADED=1

# =============================================================================
# Color codes
# =============================================================================
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    PURPLE='\033[0;35m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    DIM='\033[2m'
    NC='\033[0m'  # No Color
else
    RED='' GREEN='' YELLOW='' BLUE='' PURPLE='' CYAN='' BOLD='' DIM='' NC=''
fi

# =============================================================================
# Logging
# =============================================================================
log_info()  { echo -e "${GREEN}[INFO]${NC}  [$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  [$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} [$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2; }
log_debug() {
    if [[ "${TTCI_DEBUG:-0}" == "1" ]]; then
        echo -e "${DIM}[DEBUG]${NC} [$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2
    fi
}

# =============================================================================
# YAML parser — lightweight, handles simple key-value + lists
# =============================================================================
# Resolve CI_DIR for config path — prefer CI_DIR env var (set by sbatch --export)
if [[ -n "${CI_DIR:-}" ]]; then
    TTCI_CI_DIR="${CI_DIR}"
else
    TTCI_CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
TTCI_CONFIG="${TTCI_CI_DIR}/config.yaml"

# yaml_get <file> <dotted.key> — extract a scalar value from YAML
# Handles nested keys like "slurm.one_node.nodes"
yaml_get() {
    local file="$1"
    local key="$2"
    local result=""

    # Split dotted key into parts
    IFS='.' read -ra parts <<< "$key"
    local depth=${#parts[@]}

    if [[ $depth -eq 1 ]]; then
        # Top-level key
        result=$(grep -E "^${parts[0]}:" "$file" 2>/dev/null | head -1 | sed 's/^[^:]*:[[:space:]]*//' | sed 's/[[:space:]]*$//' | sed 's/^"//' | sed 's/"$//')
    elif [[ $depth -eq 2 ]]; then
        # Two-level: find section, then key
        result=$(awk -v sec="${parts[0]}" -v key="${parts[1]}" '
            /^[^ #]/ { current_sec = $0; sub(/:.*/, "", current_sec) }
            current_sec == sec && $0 ~ "^  " key ":" {
                val = $0; sub(/^[^:]*:[[:space:]]*/, "", val);
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", val);
                gsub(/^"|"$/, "", val);
                print val; exit
            }
        ' "$file" 2>/dev/null)
    elif [[ $depth -eq 3 ]]; then
        # Three-level: section.subsection.key
        result=$(awk -v sec="${parts[0]}" -v subsec="${parts[1]}" -v key="${parts[2]}" '
            /^[^ #]/ { current_sec = $0; sub(/:.*/, "", current_sec); current_subsec = "" }
            current_sec == sec && /^  [^ #]/ { s = $0; gsub(/^[[:space:]]+/, "", s); sub(/:.*/, "", s); current_subsec = s }
            current_sec == sec && current_subsec == subsec && $0 ~ "^    " key ":" {
                val = $0; sub(/^[^:]*:[[:space:]]*/, "", val);
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", val);
                gsub(/^"|"$/, "", val);
                print val; exit
            }
        ' "$file" 2>/dev/null)
    elif [[ $depth -eq 4 ]]; then
        # Four-level: section.subsection.subsubsection.key
        result=$(awk -v sec="${parts[0]}" -v subsec="${parts[1]}" -v subsub="${parts[2]}" -v key="${parts[3]}" '
            /^[^ #]/ { current_sec = $0; sub(/:.*/, "", current_sec); current_subsec = ""; current_subsub = "" }
            current_sec == sec && /^  [^ #-]/ { s = $0; gsub(/^[[:space:]]+/, "", s); sub(/:.*/, "", s); current_subsec = s; current_subsub = "" }
            current_sec == sec && current_subsec == subsec && /^    [^ #-]/ { s = $0; gsub(/^[[:space:]]+/, "", s); sub(/:.*/, "", s); current_subsub = s }
            current_sec == sec && current_subsec == subsec && current_subsub == subsub && $0 ~ "^      " key ":" {
                val = $0; sub(/^[^:]*:[[:space:]]*/, "", val);
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", val);
                gsub(/^"|"$/, "", val);
                print val; exit
            }
        ' "$file" 2>/dev/null)
    fi

    # Variable substitution: replace ${var} with values from config
    while [[ "$result" =~ \$\{([a-zA-Z_]+)\} ]]; do
        local var_name="${BASH_REMATCH[1]}"
        local var_val=""
        # Look up the variable in the config (search all sections)
        var_val=$(grep -E "^  ${var_name}:" "$file" 2>/dev/null | head -1 | sed 's/^[^:]*:[[:space:]]*//' | sed 's/[[:space:]]*$//' | sed 's/^"//' | sed 's/"$//')
        if [[ -z "$var_val" ]]; then
            # Try top-level
            var_val=$(grep -E "^${var_name}:" "$file" 2>/dev/null | head -1 | sed 's/^[^:]*:[[:space:]]*//' | sed 's/[[:space:]]*$//' | sed 's/^"//' | sed 's/"$//')
        fi
        result="${result/\$\{${var_name}\}/${var_val}}"
    done

    echo "$result"
}

# yaml_get_list <file> <dotted.key> — extract list items (lines starting with "- ")
yaml_get_list() {
    local file="$1"
    local key="$2"
    IFS='.' read -ra parts <<< "$key"
    local depth=${#parts[@]}

    if [[ $depth -eq 1 ]]; then
        awk -v sec="${parts[0]}" '
            /^[^ #]/ { current = $0; sub(/:.*/, "", current) }
            current == sec && /^  - / { val = $0; sub(/^  - /, "", val); gsub(/^[[:space:]]+|[[:space:]]+$/, "", val); print val }
        ' "$file" 2>/dev/null
    elif [[ $depth -eq 2 ]]; then
        awk -v sec="${parts[0]}" -v subsec="${parts[1]}" '
            /^[^ #]/ { current_sec = $0; sub(/:.*/, "", current_sec); current_subsec = ""; in_list = 0 }
            current_sec == sec && /^  [^ #-]/ { s = $0; gsub(/^[[:space:]]+/, "", s); sub(/:.*/, "", s); current_subsec = s; in_list = 0 }
            current_sec == sec && current_subsec == subsec && /^    - / { val = $0; sub(/^    - /, "", val); gsub(/^[[:space:]]+|[[:space:]]+$/, "", val); print val }
        ' "$file" 2>/dev/null
    fi
}

# =============================================================================
# Config loading — populates standard CI variables
# =============================================================================
load_config() {
    local config="${1:-${TTCI_CONFIG}}"

    if [[ ! -f "$config" ]]; then
        log_error "Config file not found: $config"
        return 1
    fi

    # Paths
    PROJECT_ROOT=$(yaml_get "$config" "paths.project_root")
    TORCHTITAN_DIR=$(yaml_get "$config" "paths.torchtitan_dir")
    VENV_DIR=$(yaml_get "$config" "paths.venv_dir")
    CI_DIR=$(yaml_get "$config" "paths.ci_dir")
    CI_LOG_DIR=$(yaml_get "$config" "paths.log_dir")
    CI_STATE_DIR=$(yaml_get "$config" "paths.state_dir")
    CI_DATA_DIR=$(yaml_get "$config" "paths.data_dir")
    LAST_TESTED_SHA_FILE="${CI_STATE_DIR}/.last_tested_sha"

    # Git
    GIT_BRANCH=$(yaml_get "$config" "git.branch")
    GIT_REMOTE=$(yaml_get "$config" "git.remote")
    GIT_REPO_URL=$(yaml_get "$config" "git.repo_url")
    GITHUB_API_REPO=$(yaml_get "$config" "git.github_api_repo")

    # Slurm
    SLURM_PARTITION=$(yaml_get "$config" "slurm.partition")
    SLURM_JOB_PREFIX=$(yaml_get "$config" "slurm.job_name_prefix")
    SLURM_1N_NODES=$(yaml_get "$config" "slurm.one_node.nodes")
    SLURM_1N_GPUS=$(yaml_get "$config" "slurm.one_node.gpus_per_node")
    SLURM_1N_CPUS=$(yaml_get "$config" "slurm.one_node.cpus_per_task")
    SLURM_1N_TIME=$(yaml_get "$config" "slurm.one_node.time_limit")
    SLURM_2N_NODES=$(yaml_get "$config" "slurm.two_node.nodes")
    SLURM_2N_GPUS=$(yaml_get "$config" "slurm.two_node.gpus_per_node")
    SLURM_2N_CPUS=$(yaml_get "$config" "slurm.two_node.cpus_per_task")
    SLURM_2N_TIME=$(yaml_get "$config" "slurm.two_node.time_limit")
    MIN_IDLE_NODES_1N=$(yaml_get "$config" "slurm.min_idle_nodes_1n")
    MIN_IDLE_NODES_2N=$(yaml_get "$config" "slurm.min_idle_nodes_2n")

    # Timeouts
    TIMEOUT_UNIT_TESTS=$(yaml_get "$config" "timeouts.unit_tests")
    TIMEOUT_DISTRIBUTED_TESTS=$(yaml_get "$config" "timeouts.distributed_tests")
    TIMEOUT_INTEGRATION_TESTS=$(yaml_get "$config" "timeouts.integration_tests")
    TIMEOUT_BENCHMARK=$(yaml_get "$config" "timeouts.benchmark")

    # Tests
    DIST_TEST_DEEPEP_MODULE=$(yaml_get "$config" "tests.distributed.deepep.module")
    DIST_TEST_DEEPEP_NGPU=$(yaml_get "$config" "tests.distributed.deepep.ngpu")
    RDZV_PORT=$(yaml_get "$config" "tests.distributed.deepep.rdzv_port")

    # Notifications
    DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-$(yaml_get "$config" "notifications.discord_webhook_url")}"
    DISCORD_MENTION_ON_FAIL="${DISCORD_MENTION_ON_FAIL:-$(yaml_get "$config" "notifications.discord_mention_on_fail")}"

    # Quality
    QUALITY_PRE_COMMIT=$(yaml_get "$config" "quality.pre_commit")
    QUALITY_COVERAGE_THRESHOLD=$(yaml_get "$config" "quality.coverage_threshold")
    QUALITY_SHELLCHECK=$(yaml_get "$config" "quality.shellcheck")

    # GPU monitoring
    GPU_MONITOR_ENABLED=$(yaml_get "$config" "gpu_monitoring.enabled")
    GPU_MONITOR_INTERVAL=$(yaml_get "$config" "gpu_monitoring.sample_interval_sec")

    # Log retention
    LOG_RETENTION_DAYS=$(yaml_get "$config" "log_retention_days")

    # Load unit test files list
    mapfile -t UNIT_TEST_FILES < <(yaml_get_list "$config" "tests.unit_files")

    export PROJECT_ROOT TORCHTITAN_DIR VENV_DIR CI_DIR CI_LOG_DIR CI_STATE_DIR CI_DATA_DIR
    export GIT_BRANCH GIT_REMOTE GIT_REPO_URL GITHUB_API_REPO
    export SLURM_PARTITION SLURM_JOB_PREFIX
    export DISCORD_WEBHOOK_URL DISCORD_MENTION_ON_FAIL
}

# =============================================================================
# Environment setup — export CUDA/NCCL/LD_LIBRARY_PATH from config
# =============================================================================
setup_environment() {
    local config="${1:-${TTCI_CONFIG}}"

    # LD_LIBRARY_PATH from config
    local extra_paths
    mapfile -t extra_paths < <(yaml_get_list "$config" "environment.ld_library_path_extra")
    for p in "${extra_paths[@]}"; do
        # Resolve ${venv_dir}
        p="${p/\$\{venv_dir\}/${VENV_DIR}}"
        export LD_LIBRARY_PATH="${p}:${LD_LIBRARY_PATH:-}"
    done

    export NVSHMEM_DIR="${VENV_DIR}/lib/python3.10/site-packages/nvidia/nvshmem"
    export CUDA_DEVICE_MAX_CONNECTIONS=$(yaml_get "$config" "environment.cuda_device_max_connections")
    export PYTORCH_CUDA_ALLOC_CONF=$(yaml_get "$config" "environment.pytorch_cuda_alloc_conf")
    export NCCL_TIMEOUT=$(yaml_get "$config" "environment.nccl_timeout")
    export NCCL_DEBUG=$(yaml_get "$config" "environment.nccl_debug")
    export NCCL_SOCKET_IFNAME=$(yaml_get "$config" "environment.nccl_socket_ifname")
    export OMP_NUM_THREADS=$(yaml_get "$config" "environment.omp_num_threads")
}

# =============================================================================
# Venv activation
# =============================================================================
activate_venv() {
    if [[ -f "${VENV_DIR}/bin/activate" ]]; then
        source "${VENV_DIR}/bin/activate"
    else
        log_error "Venv not found at ${VENV_DIR}"
        return 1
    fi
}

# =============================================================================
# Utility functions
# =============================================================================
ensure_dir() {
    local dir="$1"
    if [[ ! -d "$dir" ]]; then
        mkdir -p "$dir"
        log_debug "Created directory: $dir"
    fi
}

generate_run_id() {
    echo "$(date +%Y%m%d-%H%M%S)"
}

cleanup_old_logs() {
    local log_dir="${CI_LOG_DIR}"
    local retention="${LOG_RETENTION_DAYS:-30}"

    if [[ -d "$log_dir" ]]; then
        local count
        count=$(find "$log_dir" -maxdepth 1 -type d -name "20*" -mtime "+${retention}" 2>/dev/null | wc -l)
        if [[ "$count" -gt 0 ]]; then
            find "$log_dir" -maxdepth 1 -type d -name "20*" -mtime "+${retention}" -exec rm -rf {} + 2>/dev/null
            log_info "Cleaned up $count old log directories (>${retention} days)"
        fi
    fi
}

# JSON escape helper (no jq dependency)
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/}"
    s="${s//$'\t'/\\t}"
    echo -n "$s"
}

# Append a JSON object as a line to a JSONL file
append_jsonl() {
    local file="$1"
    local json="$2"
    ensure_dir "$(dirname "$file")"
    echo "$json" >> "$file"
}

# Read the last N lines from a JSONL file
read_jsonl_tail() {
    local file="$1"
    local n="${2:-20}"
    if [[ -f "$file" ]]; then
        tail -n "$n" "$file"
    fi
}

# Print a horizontal rule
hr() {
    local char="${1:-=-}"
    printf '%*s\n' 60 '' | tr ' ' "$char"
}

# Print a section header
section() {
    echo ""
    echo -e "${BOLD}${CYAN}$*${NC}"
    hr
}
