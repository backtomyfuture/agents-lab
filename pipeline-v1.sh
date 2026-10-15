#!/usr/bin/env bash
# Serial herdr pipeline: planner -> implementer -> verifier (-> one fix round -> re-verify)
# Usage: pipeline.sh <repo> <task-id> <task-file>
# Env (roles/models):  REUSE_PLAN=1 skips amp if runs/<task>/plan.md exists
#   PLANNER=amp     PLANNER_MODE=high   PLANNER_FALLBACK=medium   AMP_SUMMARY=0
#   IMPLEMENTER=agy IMPL_MODEL=gemini-3.8-flash-high
#   VERIFIER=droid  VERIFY_MODEL=claude-sonnet-5-5  VERIFY_AUTO=medium
#   VERIFY_EXTRA=<file>  verifier-only acceptance criteria (not shown to planner/implementer)
#   TEST_CMD="python3 -m unittest discover -v"  MAX_FIX=1  STEP_TIMEOUT=900 (sec)
set -uo pipefail
if [ "${HERDR_ENV:-}" != 1 ]; then
  echo "pipeline.sh must run inside a herdr-managed pane (HERDR_ENV=1)." >&2
  echo "Use the launcher instead: /workspace/agents-lab/run-in-herdr.sh <repo> <task-id> <task-file>" >&2
  exit 3
fi
export PATH="$HOME/.local/bin:$PATH"
REPO=$(realpath "$1"); TASK=$2; TASK_FILE=$(realpath "$3")
PLANNER_MODE=${PLANNER_MODE:-high}; PLANNER_FALLBACK=${PLANNER_FALLBACK:-medium}; AMP_SUMMARY=${AMP_SUMMARY:-0}
IMPL_MODEL=${IMPL_MODEL:-gemini-3.8-flash-high}; VERIFY_MODEL=${VERIFY_MODEL:-claude-sonnet-5-5}; VERIFY_AUTO=${VERIFY_AUTO:-medium}
TEST_CMD=${TEST_CMD:-"python3 -m unittest discover -v"}; MAX_FIX=${MAX_FIX:-1}; TO=${STEP_TIMEOUT:-900}; TOMS=$((TO*1000))
LAB=$(dirname "$(realpath "$0")"); RUN="$LAB/runs/$TASK"; WT="$LAB/wt/$TASK"; mkdir -p "$RUN" "$LAB/wt"
TRACE="$RUN/trace.md"; cp "$TASK_FILE" "$RUN/task.txt"
[ -n "${VERIFY_EXTRA:-}" ] && cp "$(realpath "$VERIFY_EXTRA")" "$RUN/acceptance.txt"
j() { python3 -c "import sys,json;d=json.load(sys.stdin);print(eval('d'+sys.argv[1]))" "$1"; }
log() { echo "- $(date +%T) $*" | tee -a "$TRACE"; }
T0=$(date +%s); el() { echo $(( $(date +%s)-$1 ))s; }
echo "# Pipeline $TASK ($(date '+%F %T %Z'))" > "$TRACE"
echo "planner=amp/$([ "${REUSE_PLAN:-0}" = 1 ] && [ -s "$RUN/plan.md" ] && echo "(reused plan.md)" || echo "$PLANNER_MODE") implementer=agy/$IMPL_MODEL verifier=droid/$VERIFY_MODEL" >> "$TRACE"
log "orchestrator context: workspace=$HERDR_WORKSPACE_ID tab=$HERDR_TAB_ID pane=$HERDR_PANE_ID"
# amp usage before
amp usage </dev/null 2>/dev/null | grep -i 'free' > "$RUN/amp-usage-before.txt"

# --- herdr topology: worktree workspace with 3 panes (planner | implementer / verifier)
out=$(herdr worktree create --cwd "$REPO" --branch "agent/pipe-$TASK" --path "$WT" --label "pipe-$TASK" --no-focus) || { echo "$out"; exit 1; }
WS=$(echo "$out" | j '["result"]["workspace"]["workspace_id"]'); P_IMPL=$(echo "$out" | j '["result"]["root_pane"]["pane_id"]')
# planner = sibling of the orchestrator's own pane (caller context); implementer/verifier in the worktree workspace
P_PLAN=$(herdr pane split --current --direction right --cwd "$WT" --no-focus | j '["result"]["pane"]["pane_id"]')
P_VER=$(herdr pane split "$P_IMPL" --direction right --cwd "$WT" --no-focus | j '["result"]["pane"]["pane_id"]')
herdr pane rename "$P_PLAN" "planner-$TASK" >/dev/null 2>&1; herdr pane rename "$P_IMPL" "implementer-$TASK" >/dev/null 2>&1; herdr pane rename "$P_VER" "verifier-$TASK" >/dev/null 2>&1
python3 - "$RUN/herdr-ids.json" <<PY
import json,sys
json.dump({"task":"$TASK","repo":"$REPO","branch":"agent/pipe-$TASK","worktree_path":"$WT","worktree_workspace":"$WS",
 "impl_pane":"$P_IMPL","verifier_pane":"$P_VER","planner_pane":"$P_PLAN","agent_name":"impl-$TASK",
 "orchestrator_workspace":"$HERDR_WORKSPACE_ID","orchestrator_tab":"$HERDR_TAB_ID","orchestrator_pane":"$HERDR_PANE_ID",
 "orchestrator_tab_created_by_launcher": "${LAUNCHER_TAB_CREATED:-0}"=="1"},open(sys.argv[1],"w"),indent=2)
PY
log "workspace $WS worktree $WT panes planner=$P_PLAN implementer=$P_IMPL verifier=$P_VER"
BASE=$(git -C "$WT" rev-parse HEAD)

# run a script in a pane and wait for its sentinel; returns script exit code
pane_step() { # pane name script
  local p=$1 n=$2 s=$3; herdr pane run "$p" "bash $s; echo __DONE_${n}_rc=\$?" >/dev/null
  herdr pane wait-output "$p" --regex "__DONE_${n}_rc=[0-9]+" --timeout "$TOMS" >/dev/null || return 124
  herdr pane read "$p" --source recent-unwrapped --lines 400 | grep -oE "__DONE_${n}_rc=[0-9]+" | tail -n1 | cut -d= -f2
}

# --- 1. PLAN (amp, one -x call; fallback mode on failure)
AMPSET="$RUN/amp-settings.json"; echo '{"amp.dangerouslyAllowAll": false}' > "$AMPSET"
MODES="$PLANNER_MODE $PLANNER_FALLBACK"
if [ "${REUSE_PLAN:-0}" = 1 ] && [ -s "$RUN/plan.md" ]; then MODES=""; USED_MODE="(reused plan.md)"; log "plan: reusing existing $RUN/plan.md (no amp call)"; fi
for mode in $MODES; do
  t=$(date +%s)
  cat > "$RUN/plan-step.sh" <<S
cd "$WT"
amp --settings-file "$AMPSET" -m $mode -x "You are the PLANNER. Do not edit any files. Read the repo briefly and output ONLY a concise implementation plan in Markdown (files to change, functions/signatures, test cases, acceptance criteria; max 40 lines) for this task:
\$(cat "$RUN/task.txt")" </dev/null > "$RUN/plan.md" 2> "$RUN/plan.err"
S
  rc=$(pane_step "$P_PLAN" plan "$RUN/plan-step.sh")
  log "plan: amp -m $mode rc=$rc ($(el $t))"
  [ "$rc" = 0 ] && [ -s "$RUN/plan.md" ] && { USED_MODE=$mode; break; }
done
[ -s "$RUN/plan.md" ] || { log "planning failed"; exit 1; }

# pre-trust the worktree for agy (otherwise its TUI blocks on a folder-trust dialog)
# agy does NOT inherit trust from a parent dir (tested), so trust this exact path and untrust it on exit
agy_trust() { python3 - "$1" "$WT" <<'PY'
import json,os,sys
f=os.path.expanduser("~/.gemini/antigravity-cli/settings.json"); d=json.load(open(f)) if os.path.exists(f) else {}
l=d.setdefault("trustedWorkspaces",[]); p=sys.argv[2]
if sys.argv[1]=="add" and p not in l: l.append(p)
if sys.argv[1]=="rm": d["trustedWorkspaces"]=[x for x in l if x!=p]
json.dump(d,open(f,"w"),indent=2)
PY
}
agy_trust add; trap 'agy_trust rm' EXIT
# --- 2. IMPLEMENT (agy as a herdr-managed interactive agent)
t=$(date +%s)
herdr agent start "impl-$TASK" --kind agy --pane "$P_IMPL" --timeout 60000 -- --model "$IMPL_MODEL" --dangerously-skip-permissions > "$RUN/agy-start.json" 2>&1 \
  || { log "agy start failed: $(cat "$RUN/agy-start.json")"; exit 1; }
log "implementer started ($(el $t))"
impl() { # prompt label
  local t=$(date +%s)
  herdr agent prompt "impl-$TASK" "$1" --wait --timeout "$TOMS" > "$RUN/$2.json" 2>&1; local rc=$?
  herdr agent read "impl-$TASK" --source recent-unwrapped --lines 300 > "$RUN/$2.transcript.txt" 2>&1
  log "$2: agy rc=$rc state=$(herdr agent get "impl-$TASK" 2>/dev/null | j '["result"]["agent"]["agent_status"]' 2>/dev/null) ($(el $t))"
}
impl "You are the IMPLEMENTER working in $WT. Task: $(tr '\n' ' ' < "$RUN/task.txt") Follow the plan in $RUN/plan.md exactly. Run: $TEST_CMD and make it pass. Do not commit. When finished reply with one line: IMPLEMENTED." implement-1

# --- 3. VERIFY (droid exec in verifier pane), optional fix rounds
verify() { # round
  local r=$1 t=$(date +%s)
  EXTRA=""; [ -s "$RUN/acceptance.txt" ] && EXTRA=" Additional verifier-only acceptance criteria (mandatory; REJECT if any is unmet; list each unmet one as a finding): $(tr '\n' ' ' < "$RUN/acceptance.txt")"; printf '%s' "$EXTRA" > "$RUN/verify-extra.txt"
  cat > "$RUN/verify-$r.sh" <<S
cd "$WT"
droid exec -m $VERIFY_MODEL --auto $VERIFY_AUTO "You are the VERIFIER/REVIEWER. Do not modify source files. Task: \$(cat "$RUN/task.txt")
Plan: $RUN/plan.md. \$(cat "$RUN/verify-extra.txt" 2>/dev/null) Review the uncommitted changes (git status; git diff; read new files) against task and plan, run: $TEST_CMD, and check edge cases. Output a short review with actionable findings, and the LAST line must be exactly 'VERDICT: APPROVE' or 'VERDICT: REJECT'. Reject only for real correctness/requirement gaps." </dev/null > "$RUN/review-$r.md" 2>&1
S
  rc=$(pane_step "$P_VER" "verify$r" "$RUN/verify-$r.sh")
  V=$(grep -oE 'VERDICT: (APPROVE|REJECT)' "$RUN/review-$r.md" | tail -n1 | cut -d' ' -f2); V=${V:-UNKNOWN}
  log "verify-$r: droid rc=$rc verdict=$V ($(el $t))"
}
verify 1; round=1
while [ "$V" != APPROVE ] && [ $round -le "$MAX_FIX" ]; do
  impl "The VERIFIER reviewed your work. Address every actionable finding in $RUN/review-$round.md, re-run $TEST_CMD, do not commit. Reply with one line: FIXED." "fix-$round"
  round=$((round+1)); verify $round
done

# --- 4. final tests + diff (in verifier pane, visible in herdr)
printf 'cd "%s" && %s > "%s" 2>&1; rc=$?; tail -n 5 "%s"; exit $rc\n' "$WT" "$TEST_CMD" "$RUN/final-test.log" "$RUN/final-test.log" > "$RUN/final-test.sh"
trc=$(pane_step "$P_VER" final "$RUN/final-test.sh")
git -C "$WT" add -A; git -C "$WT" diff --cached "$BASE" -- . ':!*__pycache__*' > "$RUN/final.diff"
STAT=$(git -C "$WT" diff --cached --shortstat "$BASE" -- . ':!*__pycache__*'); git -C "$WT" reset -q
log "final tests rc=$trc; diff:$STAT"
COMMIT=none
if [ "$V" = APPROVE ] && [ "$trc" = 0 ]; then
  find "$WT" -name __pycache__ -type d -prune -exec rm -rf {} + 2>/dev/null
  git -C "$WT" add -A -- . ':!*__pycache__*' ':!*.pyc'
  if git -C "$WT" diff --cached --quiet; then log "commit: nothing to commit"
  else
    git -C "$WT" -c user.name="agents-lab pipeline" -c user.email=pipeline@agents-lab.local commit -q \
      -m "pipeline $TASK: $(head -n1 "$RUN/task.txt" | cut -c1-60)" \
      -m "Planner: amp/${USED_MODE:-?}
Implementer: agy/$IMPL_MODEL
Verifier: droid/$VERIFY_MODEL
Verdict: APPROVE (rounds: $round)" && COMMIT=$(git -C "$WT" rev-parse --short HEAD)
    log "commit: $COMMIT on agent/pipe-$TASK"
  fi
else log "commit: skipped (verdict=$V, tests rc=$trc)"; fi

if [ "$AMP_SUMMARY" = 1 ]; then
  (cd "$WT" && amp -m "${USED_MODE:-$PLANNER_FALLBACK}" -x "In <=8 lines summarize this pipeline outcome: $(tail -n 30 "$TRACE")" </dev/null > "$RUN/amp-summary.md" 2>&1)
fi
amp usage </dev/null 2>/dev/null | grep -i 'free' > "$RUN/amp-usage-after.txt"
{ echo; echo "## Result"; echo "- verdict: $V (rounds: $round)"; echo "- commit: $COMMIT"; echo "- final tests: $([ "$trc" = 0 ] && echo PASS || echo FAIL)"; echo "- diff:$STAT"
  echo "- total: $(el $T0)"; echo "- amp usage: before [$(cat "$RUN/amp-usage-before.txt")] after [$(cat "$RUN/amp-usage-after.txt")]"
  echo "- herdr workspace $WS kept; agent 'impl-$TASK' still live in $P_IMPL; planner pane $P_PLAN"; } >> "$TRACE"
cat "$TRACE"
[ "$V" = APPROVE ] && [ "$trc" = 0 ]
