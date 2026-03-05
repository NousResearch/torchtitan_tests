# torchtitan CI/CD System (`ttci`)

Automated test runner and CI/CD system for torchtitan on Slurm-managed GPU clusters.

Supports 1-node and 2-node test jobs, GPU monitoring, benchmark regression detection, PR testing via GitHub API, code quality gates, and Discord notifications — all managed through a single `ttci` CLI.

## Quick Start

```bash
# 1. Review/edit config
vi ci/config.yaml

# 2. Install cron jobs + pre-commit hooks
./ci/ttci install

# 3. (Optional) Set Discord webhook for notifications
export DISCORD_WEBHOOK_URL='https://discord.com/api/webhooks/...'

# 4. Run tests manually
./ci/ttci run --force

# 5. Check status
./ci/ttci status
```

## Architecture

```
ci/
├── ttci                          # CLI entry point (bash dispatcher)
├── config.yaml                   # Central YAML config
├── lib/
│   ├── common.sh                 # Shared functions (logging, YAML parser, env setup)
│   ├── gpu_monitor.sh            # nvidia-smi CSV background collector
│   ├── slurm_helpers.sh          # Slurm submit/query/cancel helpers
│   └── github_api.sh             # GitHub API via curl (PR listing, state tracking)
├── commands/                     # CLI command implementations
│   ├── status.sh                 # ttci status
│   ├── run.sh                    # ttci run
│   ├── config.sh                 # ttci config
│   ├── logs.sh                   # ttci logs
│   ├── history.sh                # ttci history
│   ├── benchmark.sh              # ttci benchmark
│   ├── pr.sh                     # ttci pr
│   ├── quality.sh                # ttci quality
│   ├── install.sh                # ttci install
│   └── uninstall.sh              # ttci uninstall
├── jobs/
│   ├── run_tests_1node.slurm     # 1-node test job (unit + distributed + integration)
│   ├── run_tests_2node.slurm     # 2-node test job (multi-node distributed)
│   └── run_benchmark.slurm       # Benchmark job (configurable model, GPU monitoring)
├── schedulers/
│   ├── commit_scheduler.sh       # Polls git for new commits → 1-node jobs
│   ├── pr_scheduler.sh           # Polls GitHub API for new/updated PRs
│   └── daily_scheduler.sh        # 2-node + benchmark + quality (daily)
├── reporters/
│   ├── summary.sh                # Human-readable summary from JSON
│   ├── discord.sh                # Discord webhook with color-coded embeds
│   ├── gpu_report.sh             # Parse nvidia-smi CSV → per-GPU stats
│   └── regression.sh             # Compare benchmarks, detect regressions
├── quality/
│   ├── run_quality.sh            # Quality check orchestrator
│   ├── pre_commit.sh             # Run pre-commit hooks
│   ├── coverage.sh               # pytest --cov coverage report
│   └── shellcheck.sh             # Lint CI bash scripts
├── data/                         # Persistent data (gitignored internals)
│   ├── runs.jsonl                # Append-only run history
│   ├── benchmarks.jsonl          # Append-only benchmark results
│   └── pr_state.json             # PR tracking state
├── logs/                         # Per-run log directories (auto-cleaned)
└── state/                        # Runtime state (.last_tested_sha)
```

## Pipeline Flow

```
Trigger (cron / manual / PR)
 │
 ├── Commit scheduler (every 10 min)
 │     git fetch → compare SHA → idle nodes check → submit 1-node job
 │
 ├── PR scheduler (every 15 min)
 │     GitHub API → new/updated PRs → checkout → submit 1-node job
 │
 └── Daily scheduler (2 AM)
       Submit 2-node job → benchmarks (3 AM) → quality checks → summary
 │
 ▼
Slurm Job (1-node or 2-node)
 │
 ├── Start GPU monitoring (nvidia-smi CSV, 5s interval)
 ├── Phase 1: Unit tests (pytest, 12 files, 5min timeout)
 ├── Phase 2: Distributed tests (torchrun 8 GPU, 10min timeout)
 ├── Phase 3: Integration features (4 GPU, 30min timeout)
 ├── Phase 4: Integration models (8 GPU, 30min timeout)
 ├── Stop GPU monitoring
 ├── Generate summary.json + summary.txt
 ├── Append to runs.jsonl
 └── Discord notification
```

---

## CLI Reference

### `ttci status`

Show CI system status: cron jobs, running Slurm jobs, recent runs, git state, disk usage.

```bash
ttci status
```

**Output includes:**
- Active cron jobs and their schedules
- Currently running CI Slurm jobs
- Last 5 test runs with pass/fail status
- Current git branch and HEAD SHA
- Whether HEAD has been tested
- Disk usage of logs and data directories

---

### `ttci run`

Trigger a test run manually.

```bash
ttci run [options]
```

| Flag | Description |
|------|-------------|
| `--force` | Skip the commit-changed check (run even if HEAD already tested) |
| `--2node` | Submit a 2-node test job instead of 1-node |
| `--pr <number>` | Test a specific GitHub PR (fetches the PR branch) |
| `--suite <name>` | Only run one suite: `unit`, `distributed`, or `integration` |
| `--benchmark <name>` | Run a specific benchmark instead of tests |
| `--local` | Run directly without Slurm (useful for debugging) |
| `--wait` | Block until the Slurm job completes and print summary |
| `--quality` | Include code quality checks in the run |
| `--dry-run` | Show what would be done without actually submitting |

**Examples:**

```bash
# Standard 1-node test run
ttci run

# Force re-run even if commit already tested
ttci run --force

# Test only unit tests, no Slurm
ttci run --suite unit --local

# Test a PR and wait for results
ttci run --pr 42 --wait

# 2-node multi-GPU test
ttci run --2node

# Run benchmark
ttci run --benchmark qwen3_30b_a3b_deepep

# Dry run — see what would happen
ttci run --dry-run
```

---

### `ttci logs`

View and search run logs.

```bash
ttci logs [options]
```

| Flag | Description |
|------|-------------|
| `--run <id>` | Show logs for a specific run ID (e.g., `20260305-171054`) |
| `--follow` | Tail -f the active job's log output |
| `--grep <pattern>` | Search across all logs for a pattern |
| `--gpu` | Show GPU monitoring report for the latest run |

**Examples:**

```bash
# View latest run log
ttci logs

# Follow a running job's output in real time
ttci logs --follow

# View logs for a specific run
ttci logs --run 20260305-171054

# Search for failures across all logs
ttci logs --grep "FAIL"

# Show GPU utilization/memory/temperature report
ttci logs --gpu
```

---

### `ttci history`

Query historical run data.

```bash
ttci history [options]
```

| Flag | Description |
|------|-------------|
| `--json` | Output raw JSON (one object per line) |
| `--since <period>` | Filter by time period: `7d` (7 days), `24h` (24 hours) |
| `--failures` | Only show failed runs |
| `--pr <number>` | Only show runs for a specific PR |
| `--limit <N>` | Max runs to display (default: 20) |

**Examples:**

```bash
# Last 20 runs in table format
ttci history

# Failures in the last 7 days
ttci history --since 7d --failures

# All runs for PR #42
ttci history --pr 42

# JSON output for scripting
ttci history --json --limit 100
```

---

### `ttci config`

View or edit the central YAML configuration.

```bash
ttci config [subcommand]
```

| Subcommand | Description |
|------------|-------------|
| `show` | Display the full config file (default) |
| `get <key>` | Get a specific value by dotted key path |
| `edit` | Open config.yaml in `$EDITOR` |
| `path` | Print the config file path |

**Examples:**

```bash
# Show full config
ttci config
ttci config show

# Get a specific value
ttci config get slurm.partition
ttci config get timeouts.unit_tests
ttci config get git.branch

# Open in editor
ttci config edit

# Get file path (for scripting)
ttci config path
```

**Key config sections:**

| Section | What it controls |
|---------|-----------------|
| `paths.*` | Project root, torchtitan dir, venv, logs, data |
| `git.*` | Branch, remote, repo URL, GitHub API repo |
| `slurm.*` | Partition, job name, node counts, GPUs, time limits |
| `timeouts.*` | Per-phase test timeouts |
| `scheduling.*` | Cron intervals for commit/PR/daily polling |
| `tests.*` | Unit test files, distributed test config, integration suites |
| `benchmarks.*` | Benchmark configs, metrics, regression thresholds |
| `gpu_monitoring.*` | Enable/disable, sample interval, metrics |
| `notifications.*` | Discord webhook URL, mention roles, notification triggers |
| `quality.*` | Pre-commit, coverage threshold, shellcheck |
| `environment.*` | CUDA, NCCL, LD_LIBRARY_PATH, OMP settings |

---

### `ttci benchmark`

Run or compare performance benchmarks.

```bash
ttci benchmark [options] [name]
```

| Flag | Description |
|------|-------------|
| `--list` | List all configured benchmarks |
| `--compare <range>` | Compare benchmark results across commits (e.g., `HEAD~5..HEAD`) |
| `--history` | Show benchmark trend over time |
| `--config <toml>` | Use a custom TOML config file |

**Examples:**

```bash
# List configured benchmarks
ttci benchmark --list

# Run the default benchmark
ttci benchmark qwen3_30b_a3b_deepep

# Show benchmark history
ttci benchmark --history

# Compare last 5 commits
ttci benchmark --compare HEAD~5..HEAD
```

**Tracked metrics:** TPS (tokens/sec), MFU (model FLOPS utilization), TFLOPS, max memory (GiB)

**Regression detection:** Alerts if any metric degrades >10% (configurable via `benchmarks.*.regression_threshold_pct` in config.yaml).

---

### `ttci pr`

Manage GitHub PR testing.

```bash
ttci pr <subcommand> [number]
```

| Subcommand | Description |
|------------|-------------|
| `list` | List open PRs and their CI test status (default) |
| `test <number>` | Trigger a test run for a specific PR |
| `status <number>` | Show test results for a PR |
| `ignore <number>` | Skip auto-testing for a PR |
| `unignore <number>` | Re-enable auto-testing for a PR |

**Examples:**

```bash
# List open PRs with test status
ttci pr list

# Test PR #42
ttci pr test 42

# Check results for PR #42
ttci pr status 42

# Skip a noisy PR from auto-testing
ttci pr ignore 99
ttci pr unignore 99
```

**Authentication:** Set `GITHUB_TOKEN` environment variable for private repos or to avoid API rate limits. Without it, public repo API access is used (60 requests/hour).

---

### `ttci quality`

Run code quality checks.

```bash
ttci quality [options]
```

| Flag | Description |
|------|-------------|
| `--pre-commit` | Only run pre-commit hooks (flake8, ufmt, codespell, etc.) |
| `--coverage` | Only run pytest coverage report |
| `--shellcheck` | Only lint CI bash scripts |
| `--fix` | Auto-fix issues where possible (ufmt formatting, trailing whitespace) |

**Examples:**

```bash
# Run all quality checks
ttci quality

# Auto-fix formatting issues
ttci quality --fix

# Just check test coverage
ttci quality --coverage

# Just lint CI scripts
ttci quality --shellcheck
```

**Quality checks included:**
- **pre-commit**: Uses torchtitan's existing `.pre-commit-config.yaml` — flake8, ufmt (black+usort), codespell, pydoclint, trailing whitespace, etc.
- **coverage**: `pytest --cov=torchtitan` with configurable minimum threshold (default: report-only)
- **shellcheck**: Lints all `.sh` files in `ci/` for common bash pitfalls

---

### `ttci install`

Set up cron jobs, pre-commit hooks, and verify dependencies.

```bash
ttci install [options]
```

| Flag | Description |
|------|-------------|
| `--cron-only` | Only install cron jobs |
| `--hooks-only` | Only install pre-commit hooks in torchtitan |
| `--check` | Dry-run: report what would be installed without changing anything |

**Examples:**

```bash
# Full install (cron + hooks + dependency check)
ttci install

# Check what would be installed
ttci install --check

# Only set up cron jobs
ttci install --cron-only
```

**What gets installed:**
- **Cron jobs**: commit polling (every 10 min), PR polling (every 15 min), daily run (2 AM)
- **Pre-commit hooks**: in the torchtitan repo directory
- **Pre-flight checks**: verifies Python, venv, Slurm tools, nvidia-smi, config.yaml

---

### `ttci uninstall`

Remove cron jobs and optionally clean up all CI data.

```bash
ttci uninstall [options]
```

| Flag | Description |
|------|-------------|
| `--all` | Also remove logs, state, and data directories |

**Examples:**

```bash
# Remove cron jobs only
ttci uninstall

# Full cleanup: cron + logs + data + state
ttci uninstall --all
```

---

## Configuration

All configuration lives in `ci/config.yaml`. Edit directly or via `ttci config edit`.

### Key settings to customize

**Git branch:**
```yaml
git:
  branch: dev-updated-again    # branch to monitor for commits
```

**Slurm partition and resources:**
```yaml
slurm:
  partition: batch
  one_node:
    gpus_per_node: 8
    time_limit: "01:30:00"
```

**Test timeouts:**
```yaml
timeouts:
  unit_tests: 5m
  distributed_tests: 10m
  integration_tests: 30m
```

**Scheduling intervals:**
```yaml
scheduling:
  commit_poll_interval: "*/10 * * * *"   # every 10 minutes
  pr_poll_interval: "*/15 * * * *"       # every 15 minutes
  daily_schedule: "0 2 * * *"            # 2 AM daily
```

**Discord notifications:**
```yaml
notifications:
  discord_webhook_url: "https://discord.com/api/webhooks/..."
  discord_mention_on_fail: "<@&ROLE_ID>"
  notify_on: [failure, success, regression, preemption]
```

**Benchmarks:**
```yaml
benchmarks:
  - name: qwen3_30b_a3b_deepep
    config: torchtitan/models/qwen3/train_configs/qwen3_30b_a3b_with_deepep.toml
    ngpu: 8
    steps: 20
    regression_threshold_pct: 10
```

**Variable substitution:** Use `${variable}` to reference other values:
```yaml
paths:
  project_root: /home/phuc/workspace/moe/small_prs/pr009_slurm_cicd
  torchtitan_dir: ${project_root}/torchtitan   # resolves at runtime
```

---

## GPU Monitoring

GPU metrics are collected via background `nvidia-smi` sampling during every test run.

**Collected metrics** (configurable in `gpu_monitoring.metrics`):
- GPU utilization (%)
- Memory used / total (MiB)
- Temperature (C)
- Power draw (W)

**View GPU report:**
```bash
ttci logs --gpu
```

**Output:**
```
GPU Monitoring Report
============================================================

GPU 0:
  Utilization:  avg 85.2%  max 100.0%
  Memory:       avg 45000 MiB  max 65000 MiB / 183000 MiB (35.5%)
  Temperature:  max 72 C
  Power:        avg 350.1W  max 700.0W
...
Total samples per GPU: 74
============================================================
```

**Raw CSV** is stored at `ci/logs/<run_id>/gpu_monitor.csv` for custom analysis.

---

## Discord Notifications

### Setup

1. In Discord: **Server Settings** > **Integrations** > **Webhooks** > **New Webhook**
2. Copy the webhook URL
3. Set in `config.yaml` or as environment variable:
   ```bash
   export DISCORD_WEBHOOK_URL='https://discord.com/api/webhooks/...'
   ```

### Notification colors

| Color | Status | Meaning |
|-------|--------|---------|
| Green | Success | All test phases passed |
| Red | Failure | One or more phases failed |
| Orange | Error | Script or infrastructure error |
| Purple | Preempted | Slurm preempted the job |

### What triggers notifications

Configurable via `notifications.notify_on`:
- `failure` — any test phase fails
- `success` — all phases pass
- `regression` — benchmark performance degraded
- `preemption` — Slurm preempted the job mid-run

---

## Test Phases

### Phase 1: Unit Tests (5min timeout)

- Runs 12 test files with `pytest -x -v`
- Plain Python, no GPU required
- Stops on first failure (`-x`)

### Phase 2: Distributed Tests (10min timeout)

- DeepEP token dispatcher test
- Uses `torchrun` with 8 GPUs on single node
- Rendezvous via localhost:29501

### Phase 3: Integration Features (30min timeout)

- Feature integration tests: checkpoint, data loading, training workflows
- Uses 4 GPUs via `tests.integration_tests.run_tests --test_suite features`

### Phase 4: Integration Models (30min timeout)

- Model-specific integration tests: Llama, DeepSeek V3, Qwen3, etc.
- Uses 8 GPUs via `tests.integration_tests.run_tests --test_suite models`
- Includes multi-parallelism configs (PP+FSDP+TP+EP)

---

## Data Storage

All historical data is stored in append-only JSONL files:

### `data/runs.jsonl` — Run History

Each line is a JSON object:
```json
{
  "run_id": "20260305-171054",
  "trigger": "manual",
  "pr_number": null,
  "sha": "4d917b3...",
  "branch": "dev-updated-again",
  "node_count": 1,
  "job_id": "59813",
  "hostname": "d2dfac12-031.cloud.together.ai",
  "timestamp": "2026-03-05T17:17:06Z",
  "phases": {
    "unit_tests": {"status": "pass", "duration_sec": 23, "exit_code": 0},
    "distributed_deepep": {"status": "pass", "duration_sec": 24, "exit_code": 0},
    "integration_features": {"status": "fail", "duration_sec": 241, "exit_code": 1},
    "integration_models": {"status": "fail", "duration_sec": 78, "exit_code": 1}
  },
  "gpu_stats": {},
  "overall_status": "fail",
  "total_duration_sec": 367
}
```

### `data/benchmarks.jsonl` — Benchmark History

```json
{
  "timestamp": "2026-03-05T14:30:22Z",
  "sha": "abc1234",
  "benchmark": "qwen3_30b_a3b_deepep",
  "metrics": {"tps": 1234.5, "mfu": 45.2, "tflops": 890.1, "max_memory_gib": 65.3},
  "duration_sec": 300
}
```

### `data/pr_state.json` — PR Tracking

```json
{
  "23": {"last_tested_sha": "abc123", "last_run_id": "20260305-143022", "status": "pass"},
  "25": {"last_tested_sha": "def456", "last_run_id": "20260305-150000", "status": "fail"}
}
```

---

## Failure Handling

| Scenario | Behavior |
|----------|----------|
| No new commits | Scheduler exits silently |
| Not enough idle nodes | Scheduler skips, retries next poll |
| CI job already running | Scheduler skips, no duplicate jobs |
| Unit test failure | Logs failure, continues to next phase |
| Distributed test timeout | Logs timeout, continues to next phase |
| Integration test failure | Logs failure, proceeds to summary |
| All phases pass | Updates `.last_tested_sha`, sends success notification |
| Any phase fails | Does NOT update SHA (auto-retests next poll) |
| Slurm preemption | USR1 signal handler sends Discord alert, exits |
| Discord webhook down | Retries 3x with exponential backoff, falls back to log |
| Benchmark regression | Flags in report, sends separate Discord alert |

---

## Common Operations

```bash
# Check what's running right now
ttci status

# Force re-run on current commit
ttci run --force

# Run only unit tests locally (no Slurm)
ttci run --suite unit --local

# Follow a running job's output
ttci logs --follow

# See GPU stats from last run
ttci logs --gpu

# View failures from the last week
ttci history --since 7d --failures

# Test a specific PR
ttci pr test 42

# See all PR test results
ttci pr list

# Run quality checks with auto-fix
ttci quality --fix

# Check cron status and install
ttci install --check
ttci install

# Remove everything
ttci uninstall --all
```

## Prerequisites

- Python 3.10 venv at `$PROJECT_ROOT/.venv` with torchtitan[dev] installed
- Slurm cluster with `sbatch`, `squeue`, `sinfo`, `sacct`
- `nvidia-smi` on compute nodes
- NCCL configured (bond0 interface)
- (Optional) `GITHUB_TOKEN` for PR testing on private repos
- (Optional) `DISCORD_WEBHOOK_URL` for notifications
- (Optional) `shellcheck` for CI script linting (auto-installed via `shellcheck-py`)
