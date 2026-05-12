#!/usr/bin/env bash
# Unified Harbor launcher across agents. Wraps `harbor run` with the right
# `-a <agent>` flag and the right credentials, so the rest of the pipeline
# (task root, task list, output dir) is identical across backends.
#
# Usage:
#     AGENT=claude-code   MODEL=haiku           bash run_harbor_agent.sh <job> <task_list> [extra harbor flags]
#     AGENT=codex-oauth   MODEL=gpt-5.4-mini    bash run_harbor_agent.sh <job> <task_list>
#     AGENT=codex         MODEL=gpt-5.4-mini    bash run_harbor_agent.sh <job> <task_list>
#     HARBOR_BATCH=1 N_CONCURRENT=2 AGENT=claude-code MODEL=haiku \
#       bash run_harbor_agent.sh <job> <task_list>
#     USE_PREINSTALLED_AGENT_CLI=1 AGENT=claude-code MODEL=haiku \
#       TASK_ROOT=harbor_tasks_lean_v3_... bash run_harbor_agent.sh <job> <task_list>
#
# Auth resolution:
#   claude-code  -> OAuth access token refreshed from macOS Keychain.
#                   The Harbor Claude adapter forwards ANTHROPIC_API_KEY into
#                   the container, and the Claude CLI accepts the Claude Code
#                   OAuth access token there.
#   codex-oauth  -> ~/.codex/auth.json (codex login, ChatGPT plan)
#   codex        -> $OPENAI_API_KEY from env
#
# Both agent variants accept the same task root layout (instruction.md,
# environment/Dockerfile, tests/test.sh, ws variants vendoring skills/ via
# `COPY skills /root/.claude/skills`).
#
# Set USE_PREINSTALLED_AGENT_CLI=1 when task images already include `claude`
# and/or `codex` (for example the project lean-agent-base image). This switches
# to local Harbor adapters that verify the CLI exists instead of downloading it
# inside every trial.

set -euo pipefail

JOB_NAME="${1:?usage: $0 <job_name> <task_list_file> [extra flags...]}"
TASK_FILE="${2:?usage: $0 <job_name> <task_list_file> [extra flags...]}"
shift 2
EXTRA_FLAGS="$*"

AGENT="${AGENT:-claude-code}"
MODEL="${MODEL:-haiku}"
TASK_ROOT="${TASK_ROOT:-harbor_tasks}"
HARBOR_OUT="${HARBOR_OUT:-harbor_jobs}"
HARBOR_BATCH="${HARBOR_BATCH:-0}"
N_CONCURRENT="${N_CONCURRENT:-1}"
MEMORY_MB="${MEMORY_MB:-8192}"
TIMEOUT_MULT="${TIMEOUT_MULT:-3}"
USE_PREINSTALLED_AGENT_CLI="${USE_PREINSTALLED_AGENT_CLI:-0}"
REFRESH_CLAUDE_OAUTH="${REFRESH_CLAUDE_OAUTH:-0}"
CLAUDE_REFRESH_MODEL="${CLAUDE_REFRESH_MODEL:-haiku}"

refresh_claude_oauth() {
  if [ "$REFRESH_CLAUDE_OAUTH" != "1" ]; then
    return 0
  fi
  env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN -u CLAUDE_CODE_OAUTH_TOKEN \
    claude --print --model "$CLAUDE_REFRESH_MODEL" "Return exactly: ok" >/dev/null 2>&1 || true
}

case "$AGENT" in
  claude-code)
    if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
      refresh_claude_oauth
      export CLAUDE_CODE_OAUTH_TOKEN=$(
        security find-generic-password -s "Claude Code-credentials" -a "$(whoami)" -w 2>/dev/null \
          | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['claudeAiOauth']['accessToken'])"
      )
    fi
    export ANTHROPIC_API_KEY="$CLAUDE_CODE_OAUTH_TOKEN"
    unset ANTHROPIC_AUTH_TOKEN
    if [ "$USE_PREINSTALLED_AGENT_CLI" = "1" ]; then
      AGENT_FLAGS="--agent-import-path sbench.harbor_agents.preinstalled:ClaudeCodePreinstalled"
    else
      AGENT_FLAGS="-a claude-code"
    fi
    ;;
  codex-oauth)
    if [ ! -f "$HOME/.codex/auth.json" ]; then
      echo "codex-oauth requires ~/.codex/auth.json — run 'codex login' first" >&2
      exit 1
    fi
    if [ "$USE_PREINSTALLED_AGENT_CLI" = "1" ]; then
      AGENT_FLAGS="--agent-import-path sbench.harbor_agents.preinstalled:CodexOAuthPreinstalled"
    else
      AGENT_FLAGS="--agent-import-path sbench.harbor_agents.codex_oauth:CodexOAuth"
    fi
    ;;
  codex)
    if [ -z "${OPENAI_API_KEY:-}" ]; then
      echo "codex agent requires OPENAI_API_KEY in env" >&2
      exit 1
    fi
    if [ "$USE_PREINSTALLED_AGENT_CLI" = "1" ]; then
      AGENT_FLAGS="--agent-import-path sbench.harbor_agents.preinstalled:CodexPreinstalled"
    else
      AGENT_FLAGS="-a codex"
    fi
    ;;
  *)
    echo "unknown AGENT=$AGENT (expected claude-code | codex-oauth | codex)" >&2
    exit 1
    ;;
esac

TOTAL=$(wc -l < "$TASK_FILE" | tr -d ' ')
echo "=== Running $TOTAL tasks as job: $JOB_NAME (agent=$AGENT, model=$MODEL, task_root=$TASK_ROOT, preinstalled_cli=$USE_PREINSTALLED_AGENT_CLI) ==="

if [ "$HARBOR_BATCH" = "1" ]; then
  if [ "$AGENT" = "claude-code" ] && [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
    refresh_claude_oauth
    export CLAUDE_CODE_OAUTH_TOKEN=$(
      security find-generic-password -s "Claude Code-credentials" -a "$(whoami)" -w 2>/dev/null \
        | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['claudeAiOauth']['accessToken'])"
    )
  fi
  if [ "$AGENT" = "claude-code" ]; then
    export ANTHROPIC_API_KEY="$CLAUDE_CODE_OAUTH_TOKEN"
    unset ANTHROPIC_AUTH_TOKEN
  fi

  TASK_FLAGS=""
  while IFS= read -r TASK; do
    [ -z "$TASK" ] && continue
    TASK_FLAGS="$TASK_FLAGS -i $TASK"
  done < "$TASK_FILE"

  EFFORT_FLAG=""
  if [ -n "${REASONING_EFFORT:-}" ]; then
    EFFORT_FLAG="--ak reasoning_effort=${REASONING_EFFORT}"
  fi

  harbor run \
    $AGENT_FLAGS \
    -m "$MODEL" \
    -p "$TASK_ROOT" \
    -o "$HARBOR_OUT" \
    --job-name "$JOB_NAME" \
    -n "$N_CONCURRENT" \
    $TASK_FLAGS \
    -y \
    --override-memory-mb "$MEMORY_MB" \
    --timeout-multiplier "$TIMEOUT_MULT" \
    $EFFORT_FLAG \
    $EXTRA_FLAGS

  echo "=== Done ==="
  exit 0
fi

IDX=0
while IFS= read -r TASK; do
  [ -z "$TASK" ] && continue
  IDX=$((IDX + 1))

  if [ "$AGENT" = "claude-code" ]; then
    unset CLAUDE_CODE_OAUTH_TOKEN
    refresh_claude_oauth
    export CLAUDE_CODE_OAUTH_TOKEN=$(
      security find-generic-password -s "Claude Code-credentials" -a "$(whoami)" -w 2>/dev/null \
        | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['claudeAiOauth']['accessToken'])"
    )
    export ANTHROPIC_API_KEY="$CLAUDE_CODE_OAUTH_TOKEN"
    unset ANTHROPIC_AUTH_TOKEN
  fi
  echo "[$IDX/$TOTAL] $TASK"

  EFFORT_FLAG=""
  if [ -n "${REASONING_EFFORT:-}" ]; then
    EFFORT_FLAG="--ak reasoning_effort=${REASONING_EFFORT}"
  fi

  harbor run \
    $AGENT_FLAGS \
    -m "$MODEL" \
    -p "$TASK_ROOT" \
    -o "$HARBOR_OUT" \
    --job-name "${JOB_NAME}_${IDX}" \
    -n 1 \
    -i "$TASK" \
    -y \
    --override-memory-mb "$MEMORY_MB" \
    --timeout-multiplier "$TIMEOUT_MULT" \
    $EFFORT_FLAG \
    $EXTRA_FLAGS 2>&1 | tail -5

  echo ""
done < "$TASK_FILE"

echo "=== Done ==="
