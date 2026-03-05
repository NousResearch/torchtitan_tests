# torchtitan CI/CD System

Automated hourly test runner for torchtitan on a single Slurm GPU node (8x B200).

## Quick Start

```bash
# 1. Review/edit config
vi ci/config.env

# 2. Install cron job
./ci/install_cron.sh

# 3. (Optional) Set Discord webhook
export DISCORD_WEBHOOK_URL='https://discord.com/api/webhooks/...'

# 4. Force first run
./ci/scheduler.sh --force
```

## Architecture

```
cron (hourly, login node)
  └─> scheduler.sh
        ├── git fetch + compare SHA against .last_tested_sha
        ├── sinfo: check idle nodes >= 1
        ├── squeue: check no existing CI job running
        └── sbatch run_tests.slurm (1 node, 8 GPUs)
              ├── Phase 1: Unit tests (pytest, 12 files, 5min timeout)
              ├── Phase 2: Distributed tests (torchrun, 8 GPUs, 10min timeout)
              │     └── 2a: DeepEP token dispatcher (8 GPU)
              ├── Phase 3: Integration tests (features suite, 30min timeout)
              └── notify.sh → Discord webhook (or log-only if no URL)
```

## Files

| File | Description |
|------|-------------|
| `config.env` | Central configuration (paths, timeouts, Slurm settings, test file lists) |
| `scheduler.sh` | Cron entry point. Checks for new commits, GPU availability, submits job |
| `run_tests.slurm` | Slurm batch script. Runs all test phases, generates summary |
| `notify.sh` | Discord webhook notification with color-coded embeds |
| `install_cron.sh` | One-time setup: pre-flight checks, permissions, cron install |
| `logs/` | Run logs (auto-cleaned after 30 days) |
| `state/` | State files (`.last_tested_sha`) |

## Test Phases

### Phase 1: Unit Tests (5min timeout)
- Runs 12 test files with `pytest -x -v`
- Plain Python tests, no GPU/torchrun required
- Stops on first failure (`-x`)

### Phase 2: Distributed Tests (10min timeout)
| Sub-phase | Test | GPUs | Description |
|-----------|------|------|-------------|
| 2a | DeepEP dispatcher | 8 | Token dispatch correctness via torchrun |

Uses rendezvous port 29501 on localhost (single node).

### Phase 3: Integration Tests (30min timeout)
- Runs the `features` test suite via `tests.integration_tests.run_tests`
- Tests model training workflows end-to-end with 8 GPUs

## Prerequisites

- Python 3.10 venv at `$PROJECT_ROOT/.venv` with torchtitan[dev] installed
- DeepEP built for B200 (CUDA arch 10.0)
- NVSHMEM symlink: `libnvshmem_host.so -> libnvshmem_host.so.3`

## Discord Notifications

### Setup
1. In Discord: Server Settings → Integrations → Webhooks → New Webhook
2. Copy the webhook URL
3. Set in `config.env` or environment: `DISCORD_WEBHOOK_URL='https://...'`

### Message Colors
| Color | Status | Meaning |
|-------|--------|---------|
| Green | Success | All phases passed |
| Red | Failure | One or more phases failed |
| Orange | Error | Script/infrastructure error |
| Purple | Preempted | Slurm preempted the job |

## Failure Handling

| Scenario | Behavior |
|----------|----------|
| No new commits | Scheduler exits silently |
| Not enough idle nodes | Scheduler exits, retries next hour |
| CI job already running | Scheduler exits, no duplicate jobs |
| Unit test failure | Logs failure, continues to Phase 2 |
| Distributed test timeout | Logs timeout, continues to next sub-phase |
| Integration test failure | Logs failure, proceeds to summary |
| All phases pass | Updates `.last_tested_sha`, sends success |
| Any phase fails | Does NOT update SHA (auto-retry next hour) |
| Slurm preemption | Signal handler sends Discord alert, exits |
| Discord webhook down | Retries 3x with backoff, falls back to log |

## Manual Operations

```bash
# Check scheduler log
tail -f ci/logs/scheduler.log

# Force a run (skip commit check)
./ci/scheduler.sh --force

# Dry run (check everything, don't submit)
./ci/scheduler.sh --dry-run

# Check running CI jobs
squeue -u $(whoami) -n ci-torchtitan-tests

# Cancel CI job
scancel -n ci-torchtitan-tests

# View latest run summary
cat ci/logs/ci-*/summary.txt | tail -30

# Remove cron job
./ci/install_cron.sh --remove

# Reset last tested SHA (force retest)
rm ci/state/.last_tested_sha
```
