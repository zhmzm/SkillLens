# Runner Contract

All three backends must satisfy this interface.

## Input

| Parameter | Type | Required | Description |
|---|---|---|---|
| `JOB_NAME` | string | yes | Unique prefix for this experiment run |
| `MODEL` | string | yes | Model identifier |
| `CONDITION` | c0 / c1 | yes | Without / with skill |
| `TASK_IDS` | file or auto | yes | One base task ID per line (no _wo/_ws suffix) |
| `TASK_ROOT` | directory | harbor backends only | Harbor task directory root |
| `TASKS_JSON` | file | api-direct only | JSON with question/answer/tolerance per task |

## Output

Every backend MUST produce a CSV at `$CSV_LOG` with exactly these columns:

```
task,reward,n_input,n_output,n_cache,elapsed_s
```

- `task`: base task ID (no suffix, no hash)
- `reward`: 0, 1, or ? (unknown/error)
- `n_input,n_output,n_cache`: integer token counts (0 if unavailable)
- `elapsed_s`: integer seconds

## Resume

When `RESUME=1` and `$CSV_LOG` exists:
- Read existing CSV
- Skip any task ID already present
- Append only new results

## Backends

### 1. harbor (claude-code / codex / codex-oauth)

Delegates to `run_harbor_agent.sh`. Task IDs are resolved to `{id}{suffix}` dirs under `TASK_ROOT`. After each run, parses Harbor trial result JSONs through `collect_harbor_csv.py`.

### 2. openrouter (mini-swe-agent)

Detected when `MODEL` starts with `openrouter/`, unless `BACKEND` is explicitly set. Delegates to `run_openrouter_tasklist.sh`, then parses Harbor trial result JSONs through `collect_harbor_csv.py`.

### 3. api-direct

For domains where tasks are evaluated via direct LLM API call (no Docker sandbox). Requires a `TASKS_JSON` file with domain-specific schema. The runner validates the JSON schema before execution and reports clear errors if fields are missing.

Chemistry accepted schemas:
```json
[{
  "task_id": "pka_01",
  "skill": "pka_titration",
  "question": "full question text",
  "answer": {"pH": 4.76},
  "answer_schema": "{\"pH\": float}",
  "tolerance": {"pH_abs": 0.05}
}]
```

or:

```json
[{
  "task_id": "chem_hard_pka_01",
  "question": "full question text",
  "answer": 3.52,
  "rtol": 0.0,
  "atol": 0.05
}]
```
