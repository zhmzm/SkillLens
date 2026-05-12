#!/usr/bin/env bash
# Unified experiment entry point for math, chemistry, and code domains.

set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage:
  bash run_experiment.sh <domain> <condition> <model> <job_name> [task_list]

domain:    math | chemistry | code
condition: c0 | c1
model:     Harbor model alias (haiku, sonnet, gpt-5.4-mini) or openrouter/...
job_name:  output job prefix
task_list: optional file with base task ids or already-suffixed Harbor task ids

Common env:
  BACKEND=harbor|openrouter
  AGENT=claude-code|codex|codex-oauth|mini-swe-agent
  TASK_ROOT=/path/to/root or TASK_ROOT_C0/TASK_ROOT_C1=/path/to/root
  HARBOR_OUT=harbor_jobs
  CSV_LOG=<job_name>_results.csv
  RESUME=1
  N_CONCURRENT=1
  DRY_RUN=1
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

DOMAIN="${1:?$(usage)}"
CONDITION="${2:?$(usage)}"
MODEL="${3:?$(usage)}"
JOB_NAME="${4:?$(usage)}"
TASK_LIST="${5:-}"

_USER_BACKEND="${BACKEND:-}"
_USER_AGENT="${AGENT:-}"
_USER_TASK_ROOT="${TASK_ROOT:-}"
_USER_TASK_ROOT_C0="${TASK_ROOT_C0:-}"
_USER_TASK_ROOT_C1="${TASK_ROOT_C1:-}"
_USER_HARBOR_OUT="${HARBOR_OUT:-}"
_USER_N_CONCURRENT="${N_CONCURRENT:-}"
_USER_TIMEOUT_MULT="${TIMEOUT_MULT:-}"
_USER_MEMORY_MB="${MEMORY_MB:-}"
_USER_CHEM_TASKS_PATH="${CHEM_TASKS_PATH:-}"

CONFIG_FILE="configs/${DOMAIN}.env"
if [ ! -f "$CONFIG_FILE" ]; then
  echo "ERROR: unknown domain '$DOMAIN' (missing $CONFIG_FILE)" >&2
  exit 2
fi
source "$CONFIG_FILE"

BACKEND="${_USER_BACKEND:-${DEFAULT_BACKEND:-harbor}}"
if [[ "$MODEL" == openrouter/* ]] && [ -z "$_USER_BACKEND" ]; then
  BACKEND="openrouter"
fi
AGENT="${_USER_AGENT:-${DEFAULT_AGENT:-claude-code}}"
HARBOR_OUT="${_USER_HARBOR_OUT:-${HARBOR_OUT:-harbor_jobs}}"
N_CONCURRENT="${_USER_N_CONCURRENT:-${DEFAULT_N_CONCURRENT:-1}}"
TIMEOUT_MULT="${_USER_TIMEOUT_MULT:-${DEFAULT_TIMEOUT_MULT:-3}}"
MEMORY_MB="${_USER_MEMORY_MB:-${DEFAULT_MEMORY_MB:-8192}}"
CSV_LOG="${CSV_LOG:-${JOB_NAME}_results.csv}"
RESUME="${RESUME:-0}"
AUTO_PRUNE="${AUTO_PRUNE:-0}"
DRY_RUN="${DRY_RUN:-0}"
CHEM_TASKS_PATH="${_USER_CHEM_TASKS_PATH:-${CHEM_TASKS_PATH:-}}"

TASK_ROOT_C0="${_USER_TASK_ROOT_C0:-${_USER_TASK_ROOT:-${TASK_ROOT_C0:-}}}"
TASK_ROOT_C1="${_USER_TASK_ROOT_C1:-${_USER_TASK_ROOT:-${TASK_ROOT_C1:-}}}"
case "$CONDITION" in
  c0) TASK_ROOT="$TASK_ROOT_C0"; TASK_SUFFIX="${TASK_SUFFIX_WO:-_wo}" ;;
  c1) TASK_ROOT="$TASK_ROOT_C1"; TASK_SUFFIX="${TASK_SUFFIX_WS:-_ws}" ;;
  *) echo "ERROR: condition must be c0 or c1, got '$CONDITION'" >&2; exit 2 ;;
esac

mkdir -p "$(dirname "$CSV_LOG")" 2>/dev/null || true

resolve_task_dir() {
  local task="$1"
  if [[ "$task" == *"${TASK_SUFFIX_WO:-_wo}" || "$task" == *"${TASK_SUFFIX_WS:-_ws}" ]]; then
    printf '%s\n' "$task"
  else
    printf '%s%s\n' "$task" "$TASK_SUFFIX"
  fi
}

base_task_id() {
  local task="$1"
  task="${task%"${TASK_SUFFIX_WO:-_wo}"}"
  task="${task%"${TASK_SUFFIX_WS:-_ws}"}"
  printf '%s\n' "$task"
}

init_csv() {
  if [ "$RESUME" != "1" ] || [ ! -f "$CSV_LOG" ]; then
    printf 'task,reward,n_input,n_output,n_cache,elapsed_s\n' > "$CSV_LOG"
  fi
}

task_done() {
  local task="$1"
  [ -f "$CSV_LOG" ] && awk -F, -v t="$task" '$1==t {found=1; exit} END{exit !found}' "$CSV_LOG"
}

build_task_files() {
  local base_file="$1"
  local harbor_file="$2"
  : > "$base_file"
  : > "$harbor_file"

  if [ -n "$TASK_LIST" ]; then
    if [ ! -f "$TASK_LIST" ]; then
      echo "ERROR: task_list not found: $TASK_LIST" >&2
      exit 2
    fi
    while IFS= read -r raw; do
      [ -z "$raw" ] && continue
      local base
      base="$(base_task_id "$raw")"
      if [ "$RESUME" = "1" ] && task_done "$base"; then
        continue
      fi
      printf '%s\n' "$base" >> "$base_file"
      resolve_task_dir "$raw" >> "$harbor_file"
    done < "$TASK_LIST"
  else
    if [ -z "$TASK_ROOT" ] || [ ! -d "$TASK_ROOT" ]; then
      echo "ERROR: TASK_ROOT for $DOMAIN/$CONDITION does not exist: ${TASK_ROOT:-<empty>}" >&2
      if [ "$CONDITION" = "c0" ]; then
        echo "Set TASK_ROOT or TASK_ROOT_C0, or checkout/generate the Harbor task root first." >&2
      else
        echo "Set TASK_ROOT or TASK_ROOT_C1, or checkout/generate the Harbor task root first." >&2
      fi
      exit 2
    fi
    find "$TASK_ROOT" -maxdepth 1 -mindepth 1 -type d -name "*$TASK_SUFFIX" -print \
      | sed 's|.*/||' | sort \
      | while IFS= read -r task_dir; do
          local base
          base="$(base_task_id "$task_dir")"
          if [ "$RESUME" = "1" ] && task_done "$base"; then
            continue
          fi
          printf '%s\n' "$base" >> "$base_file"
          printf '%s\n' "$task_dir" >> "$harbor_file"
        done
  fi
}

collect_harbor_csv() {
  local job="$1"
  local mode="$2"
  python3 runners/collect_harbor_csv.py \
    --harbor-out "$HARBOR_OUT" \
    --job-name "$job" \
    --csv-log "$CSV_LOG" \
    --mode "$mode" \
    --append \
    --suffix-wo "${TASK_SUFFIX_WO:-_wo}" \
    --suffix-ws "${TASK_SUFFIX_WS:-_ws}"
}

run_harbor_backend() {
  local base_file="$1"
  local harbor_file="$2"
  local count
  count=$(grep -cve '^[[:space:]]*$' "$harbor_file" || true)
  echo "Tasks to run: $count"
  [ "$count" -gt 0 ] || return 0
  if [ "$DRY_RUN" = "1" ]; then
    echo "DRY_RUN=1: would run Harbor backend with task ids:"
    sed -n '1,20p' "$harbor_file"
    return 0
  fi

  if [ "$N_CONCURRENT" -gt 1 ]; then
    local batch_job="${JOB_NAME}_batch_$(date +%Y%m%d_%H%M%S)"
    AGENT="$AGENT" MODEL="$MODEL" TASK_ROOT="$TASK_ROOT" HARBOR_OUT="$HARBOR_OUT" \
      N_CONCURRENT="$N_CONCURRENT" HARBOR_BATCH=1 TIMEOUT_MULT="$TIMEOUT_MULT" MEMORY_MB="$MEMORY_MB" \
      bash run_harbor_agent.sh "$batch_job" "$harbor_file"
    collect_harbor_csv "$batch_job" exact
    return 0
  fi

  local idx=0
  while IFS= read -r task_dir; do
    [ -z "$task_dir" ] && continue
    idx=$((idx + 1))
    local one
    one=$(mktemp)
    printf '%s\n' "$task_dir" > "$one"
    local job="${JOB_NAME}_${idx}"
    AGENT="$AGENT" MODEL="$MODEL" TASK_ROOT="$TASK_ROOT" HARBOR_OUT="$HARBOR_OUT" \
      N_CONCURRENT=1 HARBOR_BATCH=1 TIMEOUT_MULT="$TIMEOUT_MULT" MEMORY_MB="$MEMORY_MB" \
      bash run_harbor_agent.sh "$job" "$one"
    collect_harbor_csv "$job" exact
    rm -f "$one"
    if [ "$AUTO_PRUNE" = "1" ]; then
      docker container prune -f >/dev/null 2>&1 || true
      docker network prune -f >/dev/null 2>&1 || true
    fi
  done < "$harbor_file"
}

run_openrouter_backend() {
  local harbor_file="$1"
  local count
  count=$(grep -cve '^[[:space:]]*$' "$harbor_file" || true)
  echo "Tasks to run: $count"
  [ "$count" -gt 0 ] || return 0
  if [ "$DRY_RUN" = "1" ]; then
    echo "DRY_RUN=1: would run OpenRouter backend with task ids:"
    sed -n '1,20p' "$harbor_file"
    return 0
  fi
  : "${OPENROUTER_API_KEY:?Set OPENROUTER_API_KEY}"

  local job="${JOB_NAME}_batch_$(date +%Y%m%d_%H%M%S)"
  N_CONCURRENT="$N_CONCURRENT" TIMEOUT_MULT="$TIMEOUT_MULT" MEMORY_MB="$MEMORY_MB" HARBOR_OUT="$HARBOR_OUT" \
    bash run_openrouter_tasklist.sh "$MODEL" "$job" "$TASK_ROOT" "$harbor_file"
  collect_harbor_csv "$job" exact
}


echo "============================================================"
echo " sbench unified experiment runner"
echo "============================================================"
echo " Domain:     $DOMAIN"
echo " Condition:  $CONDITION"
echo " Backend:    $BACKEND"
echo " Agent:      $AGENT"
echo " Model:      $MODEL"
echo " Job name:   $JOB_NAME"
echo " Task root:  ${TASK_ROOT:-<not used>}"
echo " Output:     $HARBOR_OUT"
echo " CSV log:    $CSV_LOG"
echo " Dry run:    $DRY_RUN"
echo "============================================================"

case "$BACKEND" in
  harbor|openrouter)
    if [ "$DRY_RUN" != "1" ]; then
      init_csv
    fi
    BASE_TASKS=$(mktemp)
    HARBOR_TASKS=$(mktemp)
    build_task_files "$BASE_TASKS" "$HARBOR_TASKS"
    if [ "$BACKEND" = "openrouter" ]; then
      run_openrouter_backend "$HARBOR_TASKS"
    else
      run_harbor_backend "$BASE_TASKS" "$HARBOR_TASKS"
    fi
    rm -f "$BASE_TASKS" "$HARBOR_TASKS"
    ;;
  *)
    echo "ERROR: unknown BACKEND=$BACKEND (expected harbor, openrouter)" >&2
    exit 2
    ;;
esac

echo "=== Experiment complete: $JOB_NAME ==="
echo "Results: $CSV_LOG"
