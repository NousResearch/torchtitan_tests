# torchtitan CI/CD (`ttci`)

Autonomous Slurm-based CI for torchtitan. Watches for new commits and PRs, runs tests automatically, forces a run every 24h.

## Quick Start

```bash
vi ci/config.yaml                # edit config (branch, partition, etc)
./ci/ttci start                  # start autonomous daemon — that's it
./ci/ttci status                 # check what's happening
```

The daemon will:
- Poll for new commits on `dev-updated-again` every 5 min
- Poll for new/updated PRs on `NousResearch/torchtitan` every 5 min
- Force a test run if nothing ran in 24h
- Submit 1-node Slurm jobs (8 GPU) automatically

## CLI

### `ttci start` / `ttci stop` — Daemon control

```bash
ttci start                       # start autonomous CI daemon
ttci start --poll 600            # poll every 10 min instead of 5
ttci start --heartbeat 12        # force run every 12h instead of 24
ttci stop                        # stop the daemon
ttci status                      # check daemon state, running jobs, last runs
```

### `ttci run` — Manual trigger

```bash
ttci run                                    # 1-node test on current HEAD
ttci run --force                            # skip commit-changed check
ttci run --2node                            # 2-node job
ttci run --pr 42                            # test a PR
ttci run --pr 42 --wait                     # test PR, block until done
ttci run --suite unit                       # only unit tests
ttci run --suite distributed                # only distributed tests
ttci run --suite integration                # only integration tests
ttci run --benchmark qwen3_30b_a3b_deepep   # run benchmark
ttci run --local                            # run without Slurm
ttci run --quality                          # include quality checks
ttci run --dry-run                          # preview, don't submit
```

### `ttci logs` — View logs

```bash
ttci logs                        # latest run log
ttci logs --follow               # tail -f active job
ttci logs --run 20260305-171054  # specific run
ttci logs --grep "FAIL"          # search all logs
ttci logs --gpu                  # GPU monitoring report
```

### `ttci history` — Past runs

```bash
ttci history                     # last 20 runs (table)
ttci history --json              # JSON output
ttci history --since 7d          # last 7 days
ttci history --failures          # only failures
ttci history --pr 42             # runs for PR #42
```

### `ttci config` — Configuration

```bash
ttci config                      # show full config
ttci config get slurm.partition  # get specific value
ttci config edit                 # open in $EDITOR
ttci config path                 # print file path
```

### `ttci benchmark` — Performance

```bash
ttci benchmark --list                    # list configured benchmarks
ttci benchmark qwen3_30b_a3b_deepep      # run benchmark
ttci benchmark --history                 # trend over time
ttci benchmark --compare HEAD~5..HEAD    # compare commits
```

### `ttci pr` — PR testing

```bash
ttci pr list             # open PRs + test status
ttci pr test 42          # trigger test for PR
ttci pr status 42        # show results
ttci pr ignore 99        # skip auto-testing
ttci pr unignore 99      # re-enable
```

Set `GITHUB_TOKEN` env var for private repos / rate limits.

### `ttci quality` — Code quality

```bash
ttci quality                 # all checks (pre-commit + coverage + shellcheck)
ttci quality --pre-commit    # only pre-commit (flake8, ufmt, codespell)
ttci quality --coverage      # only pytest coverage
ttci quality --shellcheck    # only lint CI scripts
ttci quality --fix           # auto-fix formatting
```

### `ttci install` / `ttci uninstall`

```bash
ttci install                 # cron jobs + pre-commit hooks + dep check
ttci install --cron-only     # only cron
ttci install --check         # dry-run

ttci uninstall               # remove cron jobs
ttci uninstall --all         # also clean logs, state, data
```

## How Autonomous Mode Works

```
ttci start
  └─ watchdog daemon (background, PID file)
       loop every 5 min:
         ├── CI job already running? → skip
         ├── idle nodes available? → skip if not
         ├── new commit on branch? → submit 1-node job
         ├── new/updated PR? → submit 1-node job
         └── 24h since last run? → force 1-node job
```

The daemon logs to `ci/logs/watchdog.log`. Monitor with `tail -f ci/logs/watchdog.log`.

Cron jobs (`ttci install`) are optional — the daemon handles everything. Use cron only if you prefer cron-based scheduling over the daemon.

## Configuration

All in `ci/config.yaml`. Key settings:

| Key | What |
|-----|------|
| `git.branch` | Branch to monitor |
| `git.github_api_repo` | GitHub repo for PR polling (`NousResearch/torchtitan`) |
| `slurm.partition` | Slurm partition |
| `slurm.one_node.gpus_per_node` | GPUs per node |
| `timeouts.*` | Per-phase timeouts (5m/10m/30m) |
| `notifications.discord_webhook_url` | Discord webhook |
| `benchmarks.*.regression_threshold_pct` | Regression alert threshold |

### `ttci report` — Performance & regression tracking

```bash
ttci report                      # all tables (durations, benchmark, convergence, GPU, pass/fail)
ttci report --json               # machine-readable JSON
ttci report --limit 10           # last 10 runs only
ttci report --since 7d           # last 7 days
```

## Test Phases (single Slurm job)

All phases run sequentially within one Slurm allocation:

| Phase | What | GPUs | Timeout |
|-------|------|------|---------|
| unit_tests | `pytest -x -v` on 12 test files | 0 | 5m |
| distributed_deepep | DeepEP dispatcher via torchrun | 8 | 10m |
| integration_features | Feature tests (checkpoint, data loading) | 4 | 30m |
| integration_models | Model tests (Llama, DeepSeek V3, Qwen3) | 8 | 30m |
| reference_benchmark | qwen3_30b_a3b_deepep 20-step TPS/memory tracking | 8 | 20m |
| convergence_test | Deterministic 100-step loss comparison from seed weights | 8 | 30m |

## Discord

```bash
export DISCORD_WEBHOOK_URL='https://discord.com/api/webhooks/...'
```

Green = pass, Red = fail, Orange = error, Purple = preempted.

## Prerequisites

- Python 3.10 venv with torchtitan[dev]
- Slurm (`sbatch`, `squeue`, `sinfo`)
- `nvidia-smi` on compute nodes
- Optional: `GITHUB_TOKEN`, `DISCORD_WEBHOOK_URL`
