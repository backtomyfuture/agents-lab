#!/usr/bin/env bash
# Launch pipeline.sh inside a herdr-managed 'orchestrator' pane and wait for it.
# Usage: [AUTO_CLEANUP=1] run-in-herdr.sh <repo> <task-id> <task-file>   (env vars are forwarded to pipeline.sh, see its header)
set -uo pipefail
export PATH="$HOME/.local/bin:$PATH"
[ $# -eq 3 ] || { sed -n '2,3p' "$0"; exit 2; }
LAB=$(dirname "$(realpath "$0")"); REPO=$(realpath "$1"); TASK=$2; TF=$(realpath "$3")
j() { python3 -c "import sys,json;d=json.load(sys.stdin);print(eval('d'+sys.argv[1]))" "$1"; }
herdr status server >/dev/null 2>&1 || { nohup herdr server >/tmp/herdr-server.log 2>&1 & sleep 2; }
WS=$(herdr workspace list | python3 -c 'import sys,json;print(next((w["workspace_id"] for w in json.load(sys.stdin)["result"]["workspaces"] if w["label"]=="orchestrator"),""))')
if [ -z "$WS" ]; then
  out=$(herdr workspace create --cwd "$LAB" --label orchestrator --no-focus); WS=$(echo "$out" | j '["result"]["workspace"]["workspace_id"]')
fi
# fresh tab per task so the orchestrator pane is an idle shell
out=$(herdr tab create --workspace "$WS" --cwd "$LAB" --label "$TASK" --no-focus); P=$(echo "$out" | j '["result"]["root_pane"]["pane_id"]')
herdr pane rename "$P" "orchestrator-$TASK" >/dev/null 2>&1
ENVS="LAUNCHER_TAB_CREATED=1 "; for v in PROFILE RESUME RESUME_FROM TASK_TIMEOUT MAX_CALLS_TOTAL MAX_CALLS_AMP MAX_CALLS_DROID MAX_CALLS_GROK MAX_CALLS_AGY MUTATION_N MUTATION_FLOOR MUTATION_GATE RO_REVIEW GROUND_REPRO HIDDEN_TESTS S1_TIMEOUT LIGHT SINGLE_REVIEW SKIP_DOCS SKIP_RETRO PROTECTED_TASKS GROK_STEP_TIMEOUT DROID_PAID_AVAILABLE CORE_SWAP_REVIEW TEST_FAULT_INJECT TEST_FAULT_FILE TEST_FAULT_TARGET REDACT_NGRAM TESTS_EFFORT_NO_PLAN SPEC_FALLBACK_AGENT SPEC_FALLBACK_MODEL SPEC_FALLBACK_EFFORT BASE_REF AGENT_MODE AMP_AGENT_MODE TESTS_AGENT DOCS_AGENT RETRO_AGENT REVIEW_AGENT JUDGE_AGENT PREREVIEW PREREVIEW_MODEL PREREVIEW_EFFORT IMPL2_AGENT IMPL2_MODEL IMPL2_EFFORT IMPL_ESCALATE_AFTER AMP_REVIEW_MODE AMP_JUDGE_MODE TESTS_EFFORT REVIEW_EFFORT SECURITY_EFFORT DOCS_EFFORT JUDGE_EFFORT RETRO_EFFORT ACCEPTANCE HIDDEN_ACCEPTANCE REUSE_SPEC AMP_RETRO PIPELINE_CONF SPEC_MODE SPEC_FALLBACK TESTS_MODEL REVIEW_MODEL SECURITY_MODEL DOCS_MODEL JUDGE_MODEL RETRO_MODEL MAX_IMPL_LOOPS MAX_REVIEW_LOOPS MAX_JUDGE_LOOPS LINT_CMD VERIFY_EXTRA PLANNER_MODE PLANNER_FALLBACK AMP_SUMMARY REUSE_PLAN IMPL_MODEL VERIFY_MODEL VERIFY_AUTO TEST_CMD MAX_FIX STEP_TIMEOUT; do
  [ -n "${!v:-}" ] && ENVS+="$v=$(printf %q "${!v}") "; done
echo "orchestrator workspace $WS pane $P"
sleep 1
herdr pane run "$P" "${ENVS}'$LAB/pipeline.sh' '$REPO' '$TASK' '$TF' > '$LAB/runs/$TASK.orchestrator.log' 2>&1; echo __PIPELINE_DONE_rc=\$?" >/dev/null
herdr pane wait-output "$P" --regex '__PIPELINE_DONE_rc=[0-9]+' --timeout $(( ${LAUNCH_TIMEOUT:-3600} * 1000 )) >/dev/null || echo "timeout waiting; check pane $P"
rc=$(herdr pane read "$P" --source recent-unwrapped --lines 200 | grep -oE '__PIPELINE_DONE_rc=[0-9]+' | tail -n1 | cut -d= -f2)
cat "$LAB/runs/$TASK/trace.md" 2>/dev/null || cat "$LAB/runs/$TASK.orchestrator.log"
echo "pipeline exit code: ${rc:-unknown}"
if [ "${AUTO_CLEANUP:-0}" = 1 ]; then
  if [ "${rc:-1}" = 0 ]; then echo "AUTO_CLEANUP: cleaning $TASK (branch kept)"; "$LAB/cleanup.sh" "$TASK"
  else echo "AUTO_CLEANUP: pipeline failed; keeping surfaces for inspection"; fi
fi
exit "${rc:-1}"
