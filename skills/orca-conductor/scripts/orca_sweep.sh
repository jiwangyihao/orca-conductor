#!/usr/bin/env bash
# 只读巡检：打印当前 worktree（带保护标记）、task 终态分布、worker/资源对账与建议动作。
# 不执行任何 release / rm / stop。建议动作必须先与你的 owned 清单核对再手动执行。
# 用法: orca_sweep.sh [--all]      --all 打印完整 worker 表（默认只打印摘要与需要动作的条目）
set -uo pipefail

ORCA="${ORCA_BIN:-orca}"
SHOW_ALL=0
[ "${1:-}" = "--all" ] && SHOW_ALL=1

command -v "$ORCA" >/dev/null 2>&1 || { echo "orca CLI not found (set ORCA_BIN)" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq not found" >&2; exit 1; }

hr() { printf '%s\n' "------------------------------------------------------------"; }
run_json() { "$ORCA" $1 --json 2>/dev/null; }
CAP="${SWEEP_MAX:-30}"
# keep每段可动作清单有界，避免未按 run 收敛时刷屏
cap() { awk -v n="$CAP" 'NR<=n; NR==n+1 {print "  … truncated, set SWEEP_MAX= to see more"}'; }

echo "== SELF (PROTECTED — NEVER REMOVE) =="
self=$(run_json "worktree current")
self_id=$(printf '%s' "$self" | jq -r '.result.worktree.id // empty')
self_path=$(printf '%s' "$self" | jq -r '.result.worktree.path // empty')
self_main=$(printf '%s' "$self" | jq -r '.result.worktree.isMainWorktree // empty')
if [ -z "$self_id" ]; then
  echo "<current directory is not an Orca-managed worktree>"
else
  echo "path: $self_path"
  echo "id:   $self_id"
  [ "$self_main" = "true" ] && echo "note: this is the repo MAIN worktree"
fi
hr

echo "== TASKS =="
tasks=$(run_json "orchestration task-list --brief")
run_id=$(printf '%s' "$tasks" | jq -r '.result.runId // empty')
if [ -z "$run_id" ]; then
  echo "<no Run resolved from this directory — cd into the coordinator worktree first>"
else
  echo "run: $run_id"
  printf '%s' "$tasks" | jq -r '[.result.tasks[]?.status] | group_by(.) | map("\(.[0])=\(length)") | join("  ")'
  echo "-- open (neither completed nor failed) --"
  printf '%s' "$tasks" | jq -r '
    (.result.tasks[]? | select((.status // "") | IN("completed","failed") | not)
     | "  \(.id)  \(.status)  \((.task_title // "") | gsub("\n";" ") | .[0:60])") // empty'
fi
hr

echo "== WORKERS =="
# worker-list is global unless scoped; scope to the resolved run to cut noise.
if [ -n "$run_id" ]; then
  workers=$(run_json "orchestration worker-list --run $run_id")
  echo "(scoped to run $run_id)"
else
  workers=$(run_json "orchestration worker-list")
  echo "(NOT scoped to a run — showing every worker this host knows about)"
fi
if [ -z "$(printf '%s' "$workers" | jq -r '.result.workers // empty')" ]; then
  echo "<worker-list unavailable or empty>"
  workers=""
else
  printf '%s' "$workers" | jq -r '
    "total=\(.result.workers | length)   " +
    ([.result.workers[].workerState] | group_by(.) | map("\(.[0])=\(length)") | join("  "))'
  if [ "$SHOW_ALL" = "1" ]; then
    printf '%s' "$workers" | jq -r '
      .result.workers[]
      | "  \(.dispatchId)  task=\(.taskId)  worker=\(.workerState)  term=\(.terminalState)  own=\(.resource.ownershipState // "?")  rel=\(.resource.releaseState // "?")\n      wt=\(.resource.worktreeId // "-")"'
  else
    echo "(re-run with --all for the full table)"
  fi
fi
hr

echo "== ACTIONABLE (verify against your owned list before acting) =="
if [ -n "$workers" ]; then
  echo "-- still live (ready/running/…) → observe or follow the recovery playbook; never rm their worktree --"
  printf '%s' "$workers" | jq -r '
    (.result.workers[] | select((.workerState // "") | IN("succeeded","failed","stopped","abandoned","stop_unknown") | not)
     | "  \(.dispatchId)  worker=\(.workerState)  term=\(.terminalState)  wt=\(.resource.worktreeId // "-")") // empty' | cap

  echo "-- terminated without a result (stopped/abandoned/unknown) → decide retry-of vs. drop --"
  printf '%s' "$workers" | jq -r '
    (.result.workers[] | select((.workerState // "") | IN("stopped","abandoned","stop_unknown"))
     | "  \(.dispatchId)  worker=\(.workerState)  term=\(.terminalState)  wt=\(.resource.worktreeId // "-")") // empty' | cap

  echo "-- settled, terminal not released → candidate: worker-release --dispatch <id> --"
  printf '%s' "$workers" | jq -r '
    (.result.workers[]
     | select((.workerState // "") | IN("succeeded","failed"))
     | select((.resource.releaseState // "") != "released")
     | select((.resource.ownershipState // "") == "coordinator")
     | "  \(.dispatchId)  \(.workerState)  rel=\(.resource.releaseState // "?")") // empty' | cap

  echo "-- ownership unproven → DO NOT release/rm; list these to the user --"
  printf '%s' "$workers" | jq -r '
    ([.result.workers[]
      | select((.resource.ownershipState // "") != "coordinator")
      | .resource.worktreeId // "-"] | unique | .[]
     | "  \(.)") // empty' | cap
fi
hr
[ -n "$self_path" ] && echo "reminder: never pass \"$self_path\" (or $self_id) to 'orca worktree rm'."
