#!/usr/bin/env bash
# Run an explicit Harbor task list through an OpenRouter-backed mini-swe-agent.
#
# Usage:
#   OPENROUTER_API_KEY=sk-or-... bash run_openrouter_tasklist.sh \
#     <model_id> <job_name> <task_root> <task_list>
#
# Set USE_PREINSTALLED_MINI_SWE_AGENT=1 when the task image already has uv and
# mini-swe-agent installed, for example asbench-bixbench-bio-base:20260501-agent.

set -euo pipefail

MODEL="${1:?Usage: $0 <model_id> <job_name> <task_root> <task_list>}"
JOB_NAME="${2:?Usage: $0 <model_id> <job_name> <task_root> <task_list>}"
TASK_ROOT="${3:?Usage: $0 <model_id> <job_name> <task_root> <task_list>}"
TASK_FILE="${4:?Usage: $0 <model_id> <job_name> <task_root> <task_list>}"

: "${OPENROUTER_API_KEY:?Set OPENROUTER_API_KEY}"

N_CONCURRENT="${N_CONCURRENT:-1}"
TIMEOUT_MULT="${TIMEOUT_MULT:-8}"
MEMORY_MB="${MEMORY_MB:-8192}"
HARBOR_OUT="${HARBOR_OUT:-harbor_jobs}"
USE_PREINSTALLED_MINI_SWE_AGENT="${USE_PREINSTALLED_MINI_SWE_AGENT:-0}"

if [ "$USE_PREINSTALLED_MINI_SWE_AGENT" = "1" ]; then
  AGENT_FLAGS=(--agent-import-path sbench.harbor_agents.preinstalled:MiniSweAgentPreinstalled)
else
  AGENT_FLAGS=(-a mini-swe-agent)
fi

TOTAL=$(grep -cve '^[[:space:]]*$' "$TASK_FILE" || true)
echo "=== Running $TOTAL tasks as job: $JOB_NAME (model=$MODEL, task_root=$TASK_ROOT, preinstalled_mini_swe=$USE_PREINSTALLED_MINI_SWE_AGENT) ==="

TASK_FLAGS=()
while IFS= read -r TASK; do
  [ -z "$TASK" ] && continue
  TASK_FLAGS+=("-i" "$TASK")
done < "$TASK_FILE"

harbor run "${AGENT_FLAGS[@]}" -m "$MODEL" \
  -p "$TASK_ROOT" \
  -o "$HARBOR_OUT" \
  --job-name "$JOB_NAME" \
  -n "$N_CONCURRENT" \
  "${TASK_FLAGS[@]}" \
  -y \
  --override-memory-mb "$MEMORY_MB" \
  --timeout-multiplier "$TIMEOUT_MULT"

echo "=== Done ==="
