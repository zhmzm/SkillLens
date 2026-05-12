# SkillLens

**SkillLens** is a diagnostic benchmark that decomposes the efficacy of expert-authored agent skills on language-agent task performance across three domains: **mathematics**, **code**, and **chemistry**.

---

## Dataset

The full dataset (tasks, skills, and task instructions for all three domains) is hosted on HuggingFace:

**[https://huggingface.co/datasets/zhmzm/SkillLens](https://huggingface.co/datasets/zhmzm/SkillLens)**

```bash
git lfs install
git clone https://huggingface.co/datasets/zhmzm/SkillLens
```

Dataset structure:

```
data/{domain}/train/tasks/        # train_set.json
data/{domain}/train/skills/       # train_set_skills.json
data/{domain}/test/tasks/         # test_set_tasks.json
data/{domain}/test/skills/        # test_set_skills.json
data/skill_index.json             # 29 test-set skills across all domains
task_instructions/{domain}/*.md   # standalone task prompts
```

| Domain    | Test tasks | Test skills | Train tasks | Train skills |
|-----------|:----------:|:-----------:|:-----------:|:------------:|
| code      | 57         | 10          | 2 492       | 402          |
| math      | 60         | 9           | 1 186       | 53           |
| chemistry | 75         | 10          | 1 092       | 27           |

---

## Experimental design

Each task is evaluated under three conditions:

| Condition | Description |
|-----------|-------------|
| **C0** | No skill — agent receives only the task instruction |
| **C1** | One relevant skill prepended to the instruction |
| **C2** | Routed — model selects a skill from same-domain candidates (or none) using task metadata |

Skills are domain-specific markdown documents (see `skills/`) that describe algorithmic workflows, API patterns, and code scaffolding. The benchmark tests whether injecting a skill at inference time raises the agent's pass rate on that task.

---

## Repository contents

```
run_experiment.sh          # unified runner (all domains × conditions × backends)
configs/
  code.env                 # code domain defaults
  math.env                 # math domain defaults
  chemistry.env            # chemistry domain defaults
runners/
  collect_harbor_csv.py    # result collection from Harbor job outputs
  README.md                # runner internals reference
                           # skills are hosted on HuggingFace (see Dataset section)
run_harbor_agent.sh        # Harbor launcher (claude-code / codex / codex-oauth)
run_openrouter_tasklist.sh # OpenRouter launcher (mini-swe-agent)
```

---

## Prerequisites

- [Harbor](https://github.com/av/harbor) installed and on `PATH`
- Docker running
- API key for your chosen model backend

---

## Reproducing experiments

### 1. Get the Harbor task directories

Harbor tasks are self-contained directories generated from the HuggingFace dataset. Clone the dataset, then generate task roots using the build scripts in the full research repo ([harvenstar/sbench](https://github.com/harvenstar/sbench)).

Alternatively, task roots for the benchmark tasks are available for direct download alongside the HuggingFace dataset.

Each task directory has the structure:

```
<task_id>_wo/          # C0 — no skill
  instruction.md
  environment/Dockerfile
  tests/test.sh
<task_id>_ws/          # C1 — skill prepended to instruction.md
  ...
```

### 2. Run a condition

```bash
# C0 baseline — code domain, OpenRouter model
export OPENROUTER_API_KEY=sk-or-...
bash run_experiment.sh code c0 openrouter/anthropic/claude-haiku-4-5 my_code_c0

# C1 with skill — math domain, Harbor-local model alias
export ANTHROPIC_API_KEY=...
bash run_experiment.sh math c1 haiku my_math_c1

# Chemistry C0, custom task root
TASK_ROOT=/path/to/harbor_tasks_chem \
  bash run_experiment.sh chemistry c0 haiku my_chem_c0
```

Results are written to `<job_name>_results.csv` with columns `task,reward,n_input,n_output,n_cache,elapsed_s`.

### 3. Override defaults

All defaults come from `configs/<domain>.env`. Override with environment variables:

```bash
BACKEND=openrouter           # harbor (default for math/chem) | openrouter (default for code)
AGENT=mini-swe-agent         # claude-code | codex | codex-oauth | mini-swe-agent
TASK_ROOT=/my/task/root      # override the task directory
N_CONCURRENT=4               # parallel Harbor trials
RESUME=1                     # skip already-completed tasks in CSV_LOG
DRY_RUN=1                    # print plan without running
```

### 4. Collect results

The runner writes a CSV automatically. To re-collect from existing Harbor job output:

```bash
python3 runners/collect_harbor_csv.py \
  --harbor-out harbor_jobs \
  --job-name my_code_c0 \
  --csv-log my_code_c0_results.csv
```

---

## License

See [NOTICE.md](https://github.com/harvenstar/sbench/blob/main/NOTICE.md) in the full research repo for per-source licenses. Benchmark task content that cannot be redistributed (AtCoder, Kaggle competition data) is replaced with IDs and fetch scripts.

The runner code and skill documents in this repository are released under the **MIT License**.
