#!/usr/bin/env bash
# =============================================================================
# github_api.sh — GitHub API via curl (PR listing, status updates)
# =============================================================================
# No `gh` CLI dependency — pure curl with JSON parsing.
# Supports optional GITHUB_TOKEN for auth (required for private repos / rate limits).

[[ -n "${_TTCI_GITHUB_API_LOADED:-}" ]] && return 0
_TTCI_GITHUB_API_LOADED=1

if [[ -n "${CI_DIR:-}" ]]; then
    source "${CI_DIR}/lib/common.sh"
else
    SCRIPT_DIR_GH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "${SCRIPT_DIR_GH}/common.sh"
fi

GITHUB_API_BASE="https://api.github.com"

# Make a GET request to GitHub API
# Usage: gh_api_get <endpoint>
# Example: gh_api_get "/repos/NousResearch/torchtitan/pulls?state=open"
gh_api_get() {
    local endpoint="$1"
    local url="${GITHUB_API_BASE}${endpoint}"
    local auth_header=""

    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        auth_header="-H Authorization: token ${GITHUB_TOKEN}"
    fi

    curl -s -L \
        -H "Accept: application/vnd.github.v3+json" \
        ${auth_header:+"$auth_header"} \
        "$url" 2>/dev/null
}

# List open pull requests
# Usage: list_open_prs [page]
# Outputs JSON array of PRs
list_open_prs() {
    local page="${1:-1}"
    local repo="${GITHUB_API_REPO:-}"

    if [[ -z "$repo" ]]; then
        load_config 2>/dev/null || true
        repo="${GITHUB_API_REPO}"
    fi

    if [[ -z "$repo" ]]; then
        log_error "GITHUB_API_REPO not set"
        return 1
    fi

    gh_api_get "/repos/${repo}/pulls?state=open&per_page=30&page=${page}"
}

# Get the head SHA for a specific PR
# Usage: get_pr_head_sha <pr_number>
get_pr_head_sha() {
    local pr_number="$1"
    local repo="${GITHUB_API_REPO:-}"

    [[ -z "$repo" ]] && { load_config 2>/dev/null || true; repo="${GITHUB_API_REPO}"; }

    local response
    response=$(gh_api_get "/repos/${repo}/pulls/${pr_number}")

    # Extract head sha using python one-liner (available in venv)
    echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin)['head']['sha'])" 2>/dev/null
}

# Get PR details: number, title, author, branch, sha
# Usage: get_pr_details <pr_number>
# Output: JSON object with pr details
get_pr_details() {
    local pr_number="$1"
    local repo="${GITHUB_API_REPO:-}"

    [[ -z "$repo" ]] && { load_config 2>/dev/null || true; repo="${GITHUB_API_REPO}"; }

    local response
    response=$(gh_api_get "/repos/${repo}/pulls/${pr_number}")

    echo "$response" | python3 -c "
import sys, json
pr = json.load(sys.stdin)
print(json.dumps({
    'number': pr['number'],
    'title': pr['title'],
    'author': pr['user']['login'],
    'branch': pr['head']['ref'],
    'sha': pr['head']['sha'],
    'base': pr['base']['ref'],
    'state': pr['state'],
    'updated_at': pr['updated_at']
}, indent=2))
" 2>/dev/null
}

# Parse a list of PRs into a simple table format
# Usage: echo "$prs_json" | parse_pr_list
parse_pr_list() {
    python3 -c "
import sys, json
prs = json.load(sys.stdin)
for pr in prs:
    print(f\"#{pr['number']:>4}  {pr['head']['sha'][:7]}  {pr['user']['login']:<20}  {pr['title'][:50]}\")
" 2>/dev/null
}

# Load PR state from data/pr_state.json
# Usage: load_pr_state
load_pr_state() {
    local state_file="${CI_DATA_DIR}/pr_state.json"
    if [[ -f "$state_file" ]]; then
        cat "$state_file"
    else
        echo "{}"
    fi
}

# Save PR state to data/pr_state.json
# Usage: save_pr_state <json_string>
save_pr_state() {
    local state="$1"
    local state_file="${CI_DATA_DIR}/pr_state.json"
    ensure_dir "$(dirname "$state_file")"
    echo "$state" > "$state_file"
}

# Update a single PR's state
# Usage: update_pr_state <pr_number> <sha> <run_id> <status>
update_pr_state() {
    local pr_number="$1"
    local sha="$2"
    local run_id="$3"
    local status="$4"

    local state_file="${CI_DATA_DIR}/pr_state.json"
    local current_state
    current_state=$(load_pr_state)

    python3 -c "
import json, sys
state = json.loads('''${current_state}''')
state['${pr_number}'] = {
    'last_tested_sha': '${sha}',
    'last_run_id': '${run_id}',
    'status': '${status}',
    'ignored': state.get('${pr_number}', {}).get('ignored', False)
}
print(json.dumps(state, indent=2))
" > "$state_file" 2>/dev/null
}

# Check if a PR SHA has already been tested
# Usage: is_pr_tested <pr_number> <sha>
is_pr_tested() {
    local pr_number="$1"
    local sha="$2"
    local state
    state=$(load_pr_state)

    python3 -c "
import json, sys
state = json.loads('''${state}''')
pr = state.get('${pr_number}', {})
if pr.get('last_tested_sha') == '${sha}':
    sys.exit(0)
else:
    sys.exit(1)
" 2>/dev/null
}

# Check if a PR is ignored
# Usage: is_pr_ignored <pr_number>
is_pr_ignored() {
    local pr_number="$1"
    local state
    state=$(load_pr_state)

    python3 -c "
import json, sys
state = json.loads('''${state}''')
if state.get('${pr_number}', {}).get('ignored', False):
    sys.exit(0)
else:
    sys.exit(1)
" 2>/dev/null
}
