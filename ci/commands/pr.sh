#!/usr/bin/env bash
# =============================================================================
# ttci pr — Manage PR testing
# =============================================================================
# Usage: ttci pr <subcommand> [args]
#   list              List open PRs and their test status
#   test <number>     Trigger test for PR
#   status <number>   Show test results for PR
#   ignore <number>   Skip auto-testing for PR

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source "${SCRIPT_DIR}/../lib/github_api.sh"
load_config

SUBCMD="${1:-list}"
shift 2>/dev/null || true

case "$SUBCMD" in
    list)
        section "Open Pull Requests"
        log_info "Fetching from ${GITHUB_API_REPO}..."

        PR_JSON=$(list_open_prs)
        if [[ -z "$PR_JSON" || "$PR_JSON" == "null" ]]; then
            log_info "No open PRs found (or API error)"
            exit 0
        fi

        # Load PR state
        PR_STATE=$(load_pr_state)

        python3 -c "
import json, sys

prs = json.loads('''${PR_JSON}''')
state = json.loads('''${PR_STATE}''')

if not prs:
    print('No open PRs.')
    sys.exit(0)

print(f\"{'PR':<6} {'SHA':<9} {'Author':<20} {'CI Status':<12} {'Title'}\")
print('-' * 80)

for pr in prs:
    num = str(pr['number'])
    sha = pr['head']['sha'][:7]
    author = pr['user']['login'][:18]
    title = pr['title'][:40]

    pr_state = state.get(num, {})
    tested_sha = pr_state.get('last_tested_sha', '')[:7]
    ci_status = pr_state.get('status', 'untested')
    ignored = pr_state.get('ignored', False)

    if ignored:
        status_str = '⏭ ignored'
    elif tested_sha == sha:
        icon = '✅' if ci_status == 'pass' else '❌' if ci_status == 'fail' else '❓'
        status_str = f'{icon} {ci_status}'
    elif tested_sha:
        status_str = '🔄 outdated'
    else:
        status_str = '⏳ pending'

    print(f'#{num:<5} {sha:<9} {author:<20} {status_str:<12} {title}')
" 2>/dev/null || log_error "Failed to parse PR data"
        ;;

    test)
        PR_NUM="${1:?Usage: ttci pr test <number>}"
        log_info "Triggering test for PR #${PR_NUM}..."
        exec bash "${SCRIPT_DIR}/run.sh" --pr "$PR_NUM"
        ;;

    status)
        PR_NUM="${1:?Usage: ttci pr status <number>}"
        section "PR #${PR_NUM} Test Status"

        # Get PR details
        DETAILS=$(get_pr_details "$PR_NUM")
        if [[ -n "$DETAILS" ]]; then
            echo "$DETAILS" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(f\"\"\"  Title:   {d['title']}
  Author:  {d['author']}
  Branch:  {d['branch']}
  SHA:     {d['sha'][:7]}
  Base:    {d['base']}
  Updated: {d['updated_at']}\"\"\")
" 2>/dev/null || true
        fi

        echo ""

        # Get test history
        PR_STATE=$(load_pr_state)
        python3 -c "
import json, sys
state = json.loads('''${PR_STATE}''')
pr = state.get('${PR_NUM}', {})
if not pr:
    print('  No test results found for this PR.')
else:
    print(f\"  Last Tested SHA: {pr.get('last_tested_sha', 'N/A')[:7]}\")
    print(f\"  Last Run ID:     {pr.get('last_run_id', 'N/A')}\")
    print(f\"  Status:          {pr.get('status', 'N/A')}\")
    print(f\"  Ignored:         {pr.get('ignored', False)}\")
" 2>/dev/null

        # Show run history for this PR
        RUNS_FILE="${CI_DATA_DIR}/runs.jsonl"
        if [[ -f "$RUNS_FILE" ]]; then
            echo ""
            echo "Run History:"
            grep "\"pr_number\": ${PR_NUM}" "$RUNS_FILE" 2>/dev/null | python3 -c "
import json, sys
for line in sys.stdin:
    try:
        run = json.loads(line)
        status = run.get('overall_status', '?').upper()
        icon = '✅' if status == 'PASS' else '❌'
        print(f\"  {icon} {run.get('timestamp', '?')[:19]}  {run.get('sha', '?')[:7]}  {status}  {run.get('run_id', '?')}\")
    except json.JSONDecodeError:
        pass
" 2>/dev/null || true
        fi
        ;;

    ignore)
        PR_NUM="${1:?Usage: ttci pr ignore <number>}"
        STATE_FILE="${CI_DATA_DIR}/pr_state.json"
        ensure_dir "$(dirname "$STATE_FILE")"

        PR_STATE=$(load_pr_state)
        python3 -c "
import json
state = json.loads('''${PR_STATE}''')
if '${PR_NUM}' not in state:
    state['${PR_NUM}'] = {}
state['${PR_NUM}']['ignored'] = True
print(json.dumps(state, indent=2))
" > "$STATE_FILE" 2>/dev/null

        log_info "PR #${PR_NUM} marked as ignored (will skip auto-testing)"
        ;;

    unignore)
        PR_NUM="${1:?Usage: ttci pr unignore <number>}"
        STATE_FILE="${CI_DATA_DIR}/pr_state.json"

        PR_STATE=$(load_pr_state)
        python3 -c "
import json
state = json.loads('''${PR_STATE}''')
if '${PR_NUM}' in state:
    state['${PR_NUM}']['ignored'] = False
print(json.dumps(state, indent=2))
" > "$STATE_FILE" 2>/dev/null

        log_info "PR #${PR_NUM} unmarked (will be auto-tested)"
        ;;

    --help|-h)
        echo "Usage: ttci pr <subcommand> [args]"
        echo ""
        echo "Subcommands:"
        echo "  list              List open PRs and test status"
        echo "  test <number>     Trigger test for PR"
        echo "  status <number>   Show test results for PR"
        echo "  ignore <number>   Skip auto-testing for PR"
        echo "  unignore <number> Re-enable auto-testing for PR"
        ;;

    *)
        log_error "Unknown subcommand: $SUBCMD"
        echo "Run 'ttci pr --help' for usage."
        exit 1
        ;;
esac
