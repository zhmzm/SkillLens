# Unified Experiment Runner

This directory documents the shared experiment entry point for the math,
chemistry, and code domains.

The goal is one runner contract across domains:

```bash
bash run_experiment.sh <domain> <condition> <model> <job_name> [task_list]
```

Every backend writes the same CSV format:

```text
task,reward,n_input,n_output,n_cache,elapsed_s
```

## Domains

| Domain | Default backend | Default task source |
|---|---|---|
| `math` | `harbor` via `run_harbor_agent.sh` | `harbor_tasks` unless overridden |
| `chemistry` | `harbor` via `run_harbor_agent.sh` | `harbor_tasks_chem_intent_hard_v4_20260503` unless overridden |
| `code` | `openrouter` via `run_openrouter_tasklist.sh` | `harbor_code_pilot/without_skill` and `with_skill` |

Math and chemistry task roots may live on the experiment host rather than in a
fresh checkout. If a default root is missing, set `TASK_ROOT`, `TASK_ROOT_C0`,
or `TASK_ROOT_C1`.

## Examples

Code C0 through OpenRouter:

```bash
OPENROUTER_API_KEY=sk-or-... bash run_experiment.sh \
  code c0 openrouter/qwen/qwen3-8b code_qwen8b_c0
```

Code C1 through the same backend:

```bash
OPENROUTER_API_KEY=sk-or-... bash run_experiment.sh \
  code c1 openrouter/qwen/qwen3-8b code_qwen8b_c1
```

Math C0 through Claude Code:

```bash
TASK_ROOT=harbor_tasks_math_c123_20260501_agent_cli \
AGENT=claude-code bash run_experiment.sh \
  math c0 haiku math_haiku_c0
```

Chemistry C0 through Harbor:

```bash
TASK_ROOT=harbor_tasks_chem_intent_hard_v4_20260503 \
AGENT=claude-code bash run_experiment.sh \
  chemistry c0 haiku chem_haiku_c0
```

Chemistry direct API calibration:

```bash
BACKEND=api-direct ANTHROPIC_API_KEY=sk-ant-... \
CHEM_TASKS_PATH=data/tasks_chem_50.json \
bash run_experiment.sh \
  chemistry c0 claude-haiku-4-5-20251001 chem_api_haiku
```

Resume a run:

```bash
RESUME=1 CSV_LOG=code_qwen8b_c0_results.csv OPENROUTER_API_KEY=sk-or-... \
bash run_experiment.sh code c0 openrouter/qwen/qwen3-8b code_qwen8b_c0
```

## Backend Selection

- `MODEL=openrouter/...` selects `BACKEND=openrouter` unless `BACKEND` is set.
- Otherwise the domain config selects `BACKEND=harbor` or `api-direct`.
- `BACKEND=harbor` supports `AGENT=claude-code`, `codex`, and `codex-oauth`.
- `BACKEND=api-direct` is currently chemistry-only.

## Task Lists

`task_list` may contain either base task IDs or already-suffixed Harbor task
directory names. Both of these are accepted for C0:

```text
cvxopt_01
cvxopt_01_wo
```

The output CSV always uses the base task ID without `_wo` / `_ws`.

## Source Files From `chem-math-run-code-20260506`

The unified runner builds on the May 6 branch files:

- `run_harbor_agent.sh`
- `run_openrouter_tasklist.sh`
- `harbor_agents/preinstalled.py`
- `eval_chem_haiku_api.py`
- `docker/lean-agent-base/Dockerfile`
- `docker/math-agent-base/Dockerfile`
- `remote_openrouter_c01_after_lean_base.sh`
- `remote_openrouter_c01_continue_after_leanfix.sh`
- `.gitignore`

The remote scripts remain operational references for host-specific math runs;
the reusable entry point is `run_experiment.sh`.
