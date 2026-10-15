#!/usr/bin/env bash
# pipeline v3.4: spec -> tests-first -> implement -> static checks -> parallel code+security review -> docs -> final judge -> commit -> retro
# Usage (inside herdr only; use run-in-herdr.sh): pipeline.sh <repo> <task-id> <task-file>
# Env: AGENT_MODE=herdr|headless (default herdr: every LLM stage is a herdr agent session; Amp stays headless unless AMP_AGENT_MODE=herdr)
# Env: ACCEPTANCE=<file> public acceptance criteria (seen by everyone)
#      HIDDEN_ACCEPTANCE=<file> judge-only criteria; copied to $PRIVATE_DIR/<task>/ (outside worktree and runs/)
#      REUSE_SPEC=1 reuse runs/<task>/spec.md (no Amp call); AMP_RETRO=1 retrospective via Amp
#      PROFILE=<name> source pipeline.conf.<name> first (e.g. core); RESUME=1 resume runs/<task> in its existing worktree/panes (reuses spec, tests commit; restarts at S3 checks/fix loop)
#      LIGHT=1 overlay pipeline.conf.light (after PROFILE): single merged review, no S4m/S4.5/S6/S7/S9
#      PIPELINE_CONF=<file> (default: pipeline.conf next to this script); every conf var can be overridden by env
set -uo pipefail
if [ "${HERDR_ENV:-}" != 1 ]; then
  echo "pipeline.sh must run inside a herdr-managed pane (HERDR_ENV=1)." >&2
  echo "Use the launcher instead: /workspace/agents-lab/run-in-herdr.sh <repo> <task-id> <task-file>" >&2; exit 3
fi
export PATH="$HOME/.local/bin:$PATH"
LAB=$(dirname "$(realpath "$0")")
if [ -n "${PROFILE:-}" ]; then source "$LAB/pipeline.conf.$PROFILE" || exit 3; fi
if [ "${LIGHT:-0}" = 1 ]; then source "$LAB/pipeline.conf.light" || exit 3; fi
source "${PIPELINE_CONF:-$LAB/pipeline.conf}"
REPO=$(realpath "$1"); TASK=$2; TASK_FILE=$(realpath "$3")
RUN="$LAB/runs/$TASK"
if [ "${RESUME:-0}" = 1 ]; then [ -f "$RUN/herdr-ids.json" ] && [ -s "$RUN/spec.md" ] || { echo "RESUME: no prior run in $RUN" >&2; exit 3; }
  ARCH="$RUN-attempt$(date +%H%M%S)"; cp -a "$RUN" "$ARCH"; REUSE_SPEC=1; fi
WT="$LAB/wt/$TASK"; PRIV="$PRIVATE_DIR/$TASK"; mkdir -p "$RUN" "$LAB/wt" "$PRIV"; chmod 700 "$PRIVATE_DIR" "$PRIV"
TOMS=$((STEP_TIMEOUT*1000)); TRACE="$RUN/trace.md"; STAGES="$RUN/stages.tsv"
cp "$TASK_FILE" "$RUN/task.md"; : > "$RUN/acceptance.md"; [ -n "${ACCEPTANCE:-}" ] && cp "$(realpath "$ACCEPTANCE")" "$RUN/acceptance.md"
HTESTS=""; if [ -n "${HIDDEN_TESTS:-}" ]; then HTESTS="$PRIV/hidden-tests.py"; cp "$(realpath "$HIDDEN_TESTS")" "$HTESTS"; chmod 600 "$HTESTS"; fi
HID=""; if [ -n "${HIDDEN_ACCEPTANCE:-}" ]; then HID="$PRIV/hidden-acceptance.md"; cp "$(realpath "$HIDDEN_ACCEPTANCE")" "$HID"; chmod 600 "$HID"; fi
j() { python3 -c "import sys,json;d=json.load(sys.stdin);print(eval('d'+sys.argv[1]))" "$1"; }
log() { echo "- $(date +%T) $*" | tee -a "$TRACE"; }
# checkpoint hash = HEAD sha + (path, content sha1) of every file in the worktree that git tracks or would track
# (tracked + untracked-not-ignored, staged or not - index state is irrelevant) + names of deleted tracked files.
# __pycache__/ and *.pyc excluded; runs/ and the private dir are outside the worktree and never part of it.
wtstate() { (cd "$WT" 2>/dev/null && { git rev-parse HEAD; git ls-files -co --exclude-standard -z | tr '\0' '\n' | grep -vE '(^|/)__pycache__/|\.pyc$' | sort -u |
  while IFS= read -r f; do if [ -f "$f" ]; then printf '%s %s\n' "$f" "$(sha1sum < "$f" | cut -c1-40)"; else printf '%s DELETED\n' "$f"; fi; done; } | sha1sum | cut -c1-12); }
# v3.3 stage(): stages.tsv row + metrics.jsonl + checkpoint (worktree hash) + global budget gate (wall clock / agent-call caps)
BUDGET_HIT=""
stage() { # stage agent model secs verdict
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" >> "$STAGES"; log "[$1] $2/$3 -> $5 ($4s)"
  local el=$(( $(date +%s)-T0 )) calls; calls=$(wc -l < "$RUN/calls.tsv" 2>/dev/null || echo 0); local wh; wh=$(wtstate)
  printf '%s\t%s\t%s\n' "$1" "$5" "$wh" >> "$RUN/checkpoints.tsv"
  python3 -c 'import json,sys;a=sys.argv;print(json.dumps({"ts":a[1],"task":a[2],"stage":a[3],"agent":a[4],"model":a[5],"secs":int(a[6] or 0),"result":a[7],"agent_calls_total":int(a[8]),"stage_calls":int(a[9]),"elapsed":int(a[10]),"wt":a[11],"tokens":None,"cost":None}))' \
    "$(date +%FT%T%z)" "$TASK" "$1" "$2" "$3" "$4" "$5" "$calls" "$(awk -F'\t' -v s="$(echo "$1" | tr 'A-Z' 'a-z' | sed -E 's/-.*//')" 'index($4,s)==1' "$RUN/calls.tsv" 2>/dev/null | wc -l)" "$el" "$wh" >> "$RUN/metrics.jsonl"
  [ -n "$BUDGET_HIT" ] && return 0
  local why=""
  [ "$el" -gt "$TASK_TIMEOUT" ] && why="wall clock ${el}s > TASK_TIMEOUT=${TASK_TIMEOUT}s"
  for a in amp droid grok agy; do local c; c=$(awk -F'\t' -v a=$a '$2==a' "$RUN/calls.tsv" 2>/dev/null | wc -l); local cap; cap=$(eval echo "\${MAX_CALLS_$(echo $a | tr a-z A-Z):-999}")
    [ "$c" -gt "$cap" ] && why="$why${why:+; }$a agent calls $c > MAX_CALLS_$(echo $a | tr a-z A-Z)=$cap"; done
  [ "$calls" -gt "$MAX_CALLS_TOTAL" ] && why="$why${why:+; }agent calls $calls > MAX_CALLS_TOTAL=$MAX_CALLS_TOTAL"
  if [ -n "$why" ]; then BUDGET_HIT=1; echo "$why (after stage $1)" > "$RUN/budget.txt"; log "BUDGET EXCEEDED: $why -> ESCALATE"
    chmod -R u+w "$WT" 2>/dev/null; escalate_human "budget exceeded: $why" "$RUN/budget.txt"; exit 5; fi
}
count_call() { printf '%s\t%s\t%s\t%s\n' "$(date +%s)" "$1" "$2" "$3" >> "$RUN/calls.tsv"; }  # agent model label
verdict() { python3 "$LAB/lab_tools.py" parse_verdict "$1" 2>>"$RUN/verdict-parse.log" || true; }  # JSON block preferred; text VERDICT must be the last line
T0=$(date +%s)
if [ "${RESUME:-0}" = 1 ]; then echo; echo "## RESUME $(date '+%F %T %Z') profile=${PROFILE:-default}${LIGHT:+ light=$LIGHT} (previous attempt archived: $ARCH)" >> "$TRACE"; printf 'RESUME\torchestrator\t%s\t0\t-\n' "${PROFILE:-default}" >> "$STAGES"
else echo "# Pipeline v2 $TASK ($(date '+%F %T %Z')) profile=${PROFILE:-default}${LIGHT:+ light=$LIGHT}" > "$TRACE"; printf 'stage\tagent\tmodel\tsecs\tresult\n' > "$STAGES"; fi
log "orchestrator context: workspace=$HERDR_WORKSPACE_ID tab=$HERDR_TAB_ID pane=$HERDR_PANE_ID"
[ -n "$HID" ] && log "hidden acceptance stored at $HID (sha256 $(sha256sum "$HID" | cut -c1-12)); not copied to runs/ or worktree"
amp usage </dev/null 2>/dev/null | grep -i 'free' > "$RUN/amp-usage-before.txt"
: >> "$RUN/calls.tsv"; rm -f "$RUN/.ro.count"
python3 "$LAB/lab_tools.py" orphans "$LAB" "${PROTECTED_TASKS:-t1 t2 t6 t7}" > "$RUN/orphans.txt" 2>/dev/null
n_orph=$(grep -P '\tORPHAN\t-$' "$RUN/orphans.txt" | grep -v "/$TASK\s" | wc -l); [ "$n_orph" -gt 0 ] && log "startup recovery: $n_orph unprotected orphan worktree(s) from crashed runs (reported only, see $RUN/orphans.txt; protected ones are never touched)"
# checkpoint resume (v3.3): RESUME=1 resumes after the last checkpoint whose worktree hash still matches (S4.5 / S5+S6 / S7 / S8); RESUME_FROM=S4.5|S5|S7|S8|COMMIT forces it
RESUME_IDX=0
if [ "${RESUME:-0}" = 1 ]; then
  RESUME_AT=${RESUME_FROM:-$(python3 - "$ARCH/checkpoints.tsv" "$(wtstate)" "${SKIP_DOCS:-0}" <<'PY'
import sys
skip_docs = len(sys.argv) > 3 and sys.argv[3] == '1'
# (checkpoint, row prefixes, accepted results, optional?)  optional = stage may legitimately be absent (MUTATION_N=0 / PREREVIEW=0 / SKIP_DOCS=1); only the first prefix is required (S6 absent under SINGLE_REVIEW=1)
order = [('S4m', ('S4-mutation',), ('score=',), True), ('S4.5', ('S4.5-prereview',), ('PASS', 'REVERTED'), True),
         ('S5', ('S5-review', 'S6-security'), ('APPROVE',), False), ('S7', ('S7-docs',), ('PASS',), skip_docs), ('S8', ('S8-judge',), ('APPROVE',), False)]
nxt = {'S4m': 'S4.5', 'S4.5': 'S5', 'S5': 'S7', 'S7': 'S8', 'S8': 'COMMIT'}
try: rows = [l.rstrip('\n').split('\t') for l in open(sys.argv[1]) if l.strip()]
except OSError: rows = []
at, last_hash = 'S4', None
for name, prefixes, ok, optional in order:
    hits = [r for r in rows if r[0].startswith(prefixes)]
    if not hits:
        if optional:
            if at == name: at = nxt[name]   # absent optional stage right at the resume point: step over it (LIGHT: no S4m/S7)
            continue
        break
    lastrow = {}
    for r in hits: lastrow[[p for p in prefixes if r[0].startswith(p)][0]] = r
    if prefixes[0] not in lastrow or not all(r[1].split()[0].startswith(ok) for r in lastrow.values()): break
    at, last_hash = nxt[name], max(lastrow.values(), key=lambda r: rows.index(r))[2]
# hash mismatch (worktree changed after the checkpoint) -> 'S4': re-run S4 checks on the existing implementation (S3 fix loop if red), then continue normally
print(at if last_hash == sys.argv[2] else 'S4')
PY
)}
  case "$RESUME_AT" in S4m) RESUME_IDX=1;; S4.5) RESUME_IDX=2;; S5) RESUME_IDX=3;; S7) RESUME_IDX=4;; S8) RESUME_IDX=5;; COMMIT) RESUME_IDX=6;; *) RESUME_IDX=0;; esac
  log "resume checkpoint: continuing at ${RESUME_AT} (earlier stages with a matching worktree hash are skipped; S4 checks always re-run)"
fi
skip_until() { [ "$RESUME_IDX" -gt "$1" ]; }  # stage index: 1=S4m 2=S4.5 3=S5/S6 4=S7 5=S8 ; S1/S2/S3/S4 are never skipped by checkpoints (S1/S2 via REUSE_SPEC/tests commit, S3 impl lives in the worktree, S4 always re-runs)

# ---------- herdr topology
if [ "${RESUME:-0}" = 1 ]; then
  ids() { python3 -c "import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]])" "$RUN/herdr-ids.json" "$1"; }
  WS=$(ids worktree_workspace); P_IMPL=$(ids impl_pane); P_PLAN=$(ids planner_pane); P_A=$(ids verifier_pane); P_B=$(ids verifier2_pane)
  for p in $P_IMPL $P_A $P_B; do herdr pane get "$p" >/dev/null 2>&1 || { echo "RESUME: pane $p gone" >&2; exit 3; }; done
  log "resume: reusing workspace $WS panes implementer=$P_IMPL droid-a=$P_A droid-b=$P_B"
else
out=$(herdr worktree create --cwd "$REPO" --branch "agent/pipe-$TASK" --path "$WT" --label "pipe-$TASK" ${BASE_REF:+--base "$BASE_REF"} --no-focus) || { echo "$out"; exit 1; }
WS=$(echo "$out" | j '["result"]["workspace"]["workspace_id"]'); P_IMPL=$(echo "$out" | j '["result"]["root_pane"]["pane_id"]')
P_PLAN=$(herdr pane split --current --direction right --cwd "$WT" --no-focus | j '["result"]["pane"]["pane_id"]')
P_A=$(herdr pane split "$P_IMPL" --direction right --cwd "$WT" --no-focus | j '["result"]["pane"]["pane_id"]')
P_B=$(herdr pane split "$P_A" --direction down --cwd "$WT" --no-focus | j '["result"]["pane"]["pane_id"]')
for p in "$P_PLAN:planner" "$P_IMPL:implementer" "$P_A:droid-a" "$P_B:droid-b"; do herdr pane rename "${p%%:*}" "${p#*:}-$TASK" >/dev/null 2>&1; done
python3 - "$RUN/herdr-ids.json" <<PY
import json,sys
json.dump({"task":"$TASK","repo":"$REPO","branch":"agent/pipe-$TASK","worktree_path":"$WT","worktree_workspace":"$WS",
 "impl_pane":"$P_IMPL","verifier_pane":"$P_A","verifier2_pane":"$P_B","planner_pane":"$P_PLAN","agent_name":"impl-$TASK",
 "orchestrator_workspace":"$HERDR_WORKSPACE_ID","orchestrator_tab":"$HERDR_TAB_ID","orchestrator_pane":"$HERDR_PANE_ID",
 "orchestrator_tab_created_by_launcher": "${LAUNCHER_TAB_CREATED:-0}"=="1"},open(sys.argv[1],"w"),indent=2)
PY
log "workspace $WS worktree $WT panes planner=$P_PLAN implementer=$P_IMPL droid-a=$P_A droid-b=$P_B"
fi
PREV_TESTS_SHA=$(git -C "$WT" log --format=%h --grep="^pipeline $TASK: tests first" -n1)
if [ "${RESUME:-0}" = 1 ] && [ -n "$PREV_TESTS_SHA" ]; then BASE=$(git -C "$WT" rev-parse "$PREV_TESTS_SHA^"); else BASE=$(git -C "$WT" rev-parse HEAD); fi
GIT() { git -C "$WT" -c user.name="agents-lab pipeline" -c user.email=pipeline@agents-lab.local "$@"; }

# ---- herdr adapter (herdr is the base; core logic calls only these)
ag_exists() { herdr agent get "$1" >/dev/null 2>&1; }
ag_status() { herdr agent get "$1" 2>/dev/null | grep -oE '"agent_status":"[a-z]+"' | cut -d'"' -f4; }
ag_start()  { local n=$1 k=$2 p=$3 to=$4; shift 4; herdr agent start "$n" --kind "$k" --pane "$p" --timeout "$to" -- "$@"; }
ag_prompt() { herdr agent prompt "$1" "$2" --wait --timeout "$3"; }
ag_wait()   { herdr agent wait "$1" --until idle --timeout "$2" >/dev/null 2>&1; }
ag_ready()  { local i; for i in $(seq 1 30); do [ "$(ag_status "$1")" = idle ] && return 0; sleep 1; done; return 1; }  # poll instead of fixed sleep
ag_read()   { herdr agent read "$1" --source recent-unwrapped --lines "${2:-400}"; }
s1_rcdesc() { # rc specfile -> human rc: 124/137 = TIMEOUT (S1_TIMEOUT), 143 = KILLED, 0 with empty output = killed/hung (amp exits 0 on SIGTERM)
  case "$1" in 124|137) echo "TIMEOUT(${S1_TIMEOUT:-900}s,rc=$1)";; 143) echo "KILLED(rc=143)";; 0) [ -s "$2" ] && echo 0 || echo "0-EMPTY-OUTPUT(killed/hung?)";; *) echo "$1";; esac; }
pane_step() { # pane name script -> prints rc
  local p=$1 n=$2 s=$3; herdr pane run "$p" "bash $s; echo __DONE_${n}_rc=\$?" >/dev/null
  herdr pane wait-output "$p" --regex "__DONE_${n}_rc=[0-9]+" --timeout "$TOMS" >/dev/null || { echo 124; return; }
  herdr pane read "$p" --source recent-unwrapped --lines 400 | grep -oE "__DONE_${n}_rc=[0-9]+" | tail -n1 | cut -d= -f2
}
droid_step() { # pane label model auto promptfile outfile [effort] -> rc
  printf 'cd "%s" && droid exec -m %s %s --auto %s -f "%s" </dev/null > "%s" 2>&1\n' "$WT" "$3" "${7:+-r $7}" "$4" "$5" "$6" > "$RUN/$2.sh"
  count_call "$3" "$4" "$2"; pane_step "$1" "$2" "$RUN/$2.sh"
}
agent_step_headless() { # pane label agent model effort auto promptfile outfile -> rc   (headless one-shot steps)
  local cmd
  case $3 in
    droid) cmd="droid exec -m $4 ${5:+-r $5} --auto $6 -f \"$7\"";;
    grok)  to=$(step_ms grok); cmd="grok -m $4 ${5:+--effort $5} --always-approve --output-format plain --prompt-file \"$7\"";;
    amp)   cmd="amp -m $4 -x \"\$(cat \"$7\")\"";;
    agy)   cmd="agy -p \"\$(cat \"$7\")\" --model $4 --dangerously-skip-permissions";;
    *) log "unknown agent $3"; echo 99; return;;
  esac
  printf 'cd "%s" && %s </dev/null > "%s" 2>&1\n' "$WT" "$cmd" "$8" > "$RUN/$2.sh"
  pane_step "$1" "$2" "$RUN/$2.sh"
}
# ---- herdr agent mode (default): one long-lived herdr agent per role, own tab in the task workspace; files are the source of truth
agent_args() { # name kind model effort auto -> sets global AARGS
  AARGS=()
  case $2 in
    droid) printf '{"model":"%s"%s,"sessionDefaultSettings":{"autonomyLevel":"%s"}}\n' "$3" "${4:+,\"reasoningEffort\":\"$4\"}" "${5:-medium}" > "$RUN/droid-settings-$1.json"; AARGS=(--settings "$RUN/droid-settings-$1.json");;
    grok)  AARGS=(-m "$3"); [ -n "$4" ] && AARGS+=(--effort "$4"); AARGS+=(--always-approve);;
    amp)   AARGS=(-m "$3");;
    agy)   AARGS=(--model "$3" --dangerously-skip-permissions);;
  esac
}
step_ms() { [ "$1" = grok ] && echo $((GROK_STEP_TIMEOUT*1000)) || echo "$TOMS"; }
drain() { # session-name : after the agent is idle, wait <=60s for leftover child processes in its pane, then log + kill
  local pane sp left i
  pane=$(herdr agent get "$1" 2>/dev/null | grep -oE '"pane_id":"[^"]+"' | head -1 | cut -d'"' -f4); [ -n "$pane" ] || return 0
  sp=$(herdr pane process-info --pane "$pane" 2>/dev/null | grep -oE '"shell_pid":[0-9]+' | cut -d: -f2); [ -n "$sp" ] || return 0
  for i in $(seq 1 12); do left=$(python3 "$LAB/lab_tools.py" leftovers "$sp"); [ -z "$left" ] && return 0; sleep 5; done
  log "DRAIN: $1 idle but processes still running after 60s -> killing: $(echo "$left" | tr '\n\t' '; ' | cut -c1-300)"
  echo "$left" | cut -f1 | xargs -r kill 2>/dev/null; sleep 2; echo "$left" | cut -f1 | xargs -r kill -9 2>/dev/null; return 0
}
snap_take() { # name : tracked state (stash-create sha) + copy of untracked files, stored outside the worktree
  local d="$PRIV/snap-$1"; rm -rf "$d"; mkdir -p "$d"
  (cd "$WT" && { git stash create 2>/dev/null || true; } > "$d/sha"; [ -s "$d/sha" ] || git rev-parse HEAD > "$d/sha"
   git ls-files --others --exclude-standard | grep -v __pycache__ > "$d/untracked"; tar -cf "$d/untracked.tar" -T "$d/untracked" 2>/dev/null || true)
}
snap_restore() { # name : full rollback + git clean -fd inside the worktree only, then restore pre-existing untracked files
  local d="$PRIV/snap-$1"
  (cd "$WT" && git checkout "$(cat "$d/sha")" -- . 2>/dev/null; git reset -q; git clean -fdq -e __pycache__; [ -s "$d/untracked" ] && tar -xf "$d/untracked.tar")
}
snap_revert_except() { # name regex : revert every change since snapshot whose path does NOT match regex (+ remove new non-matching untracked files)
  local d="$PRIV/snap-$1" sha f reverted=""; sha=$(cat "$d/sha")
  for f in $(cd "$WT" && { git diff --name-only "$sha"; git ls-files --others --exclude-standard; } | grep -v __pycache__ | sort -u); do
    echo "$f" | grep -qE "$2" && continue
    if grep -qxF "$f" "$d/untracked"; then (cd "$WT" && tar -xf "$d/untracked.tar" "$f")
    elif git -C "$WT" cat-file -e "$sha:$f" 2>/dev/null; then git -C "$WT" checkout "$sha" -- "$f"; git -C "$WT" reset -q -- "$f"
    else git -C "$WT" clean -fdq -- "$f"; rm -f "$WT/$f"; fi
    reverted="$reverted $f"
  done; echo "$reverted"
}
escalate_human() { # reason details-file...
  FINAL=ESCALATE; { echo "# ESCALATE: $1"; echo; echo "Time: $(date '+%F %T %Z'). Pipeline stopped for a human decision; worktree and herdr surfaces kept."; shift; for f in "$@"; do echo; echo "## $(basename "$f")"; cat "$f"; done; } >> "$RUN/escalation.md"
  stage ESCALATE orchestrator - 0 "see escalation.md"
}
sess_ensure() { # name kind model effort auto -> 0 if session ready
  ag_exists "$1" && return 0
  local P; agent_args "$@"; local args=("${AARGS[@]}")
  P=$(herdr tab create --workspace "$WS" --cwd "$WT" --label "$1" --no-focus | python3 -c "import sys,json;r=json.load(sys.stdin)['result'];print((r.get('root_pane') or r.get('pane'))['pane_id'])") || { log "tab create failed for $1"; return 1; }
  ag_start "$1" "$2" "$P" 120000 "${args[@]}" > "$RUN/start-$1.json" 2>&1 || { log "agent start failed $1: $(head -c 300 "$RUN/start-$1.json")"; return 1; }
  ag_ready "$1" || ag_wait "$1" 30000
  python3 -c "import json,sys;f=sys.argv[1];d=json.load(open(f));d.setdefault('sessions',{})[sys.argv[2]]={'pane':sys.argv[3],'kind':sys.argv[4],'model':sys.argv[5],'effort':sys.argv[6]};json.dump(d,open(f,'w'),indent=2)" "$RUN/herdr-ids.json" "$1" "$P" "$2" "$3" "${4:-}"
  log "session $1 started: $2 $3 ${4:+effort $4} in $P"
}
agent_step() { # pane label agent model effort auto promptfile outfile -> rc
  if [ "$AGENT_MODE" != herdr ] || { [ "$3" = amp ] && [ "$AMP_AGENT_MODE" != herdr ]; }; then agent_step_headless "$@"; return; fi
  local role name msg st
  role=$(echo "$2" | sed -E 's/-[0-9]+[a-z]*$//'); name="$role-$3-$TASK"; local to; to=$(step_ms "$3")
  sess_ensure "$name" "$3" "$4" "$5" "$6" || { log "falling back to headless for $2"; agent_step_headless "$@"; return; }
  rm -f "$8"
  msg="Step $2. Your instructions for this step are in the file $7 - read it and follow it exactly (it supersedes earlier step instructions in this session). When finished, write your COMPLETE final answer (everything you would reply, including any required VERDICT line as the last line) to the file $8, overwriting it. Then reply with one word: DONE."
  for attempt in 1 2; do
    count_call "$3" "$4" "$2"
    if [ "$attempt" = 1 ]; then ag_prompt "$name" "$msg" "$to" > "${TRANSCRIPT_DIR:-$RUN}/$2.prompt.json" 2>&1
    else ag_prompt "$name" "The file $8 is missing or empty. Write your complete final answer for step $2 to $8 now, then reply DONE." "$to" > "${TRANSCRIPT_DIR:-$RUN}/$2.prompt.json" 2>&1; fi
    st=$(ag_status "$name")
    # still working after the wait timeout: keep waiting (never send a new prompt into a busy session)
    for _ in 1 2; do [ "$st" = working ] || break; log "$2: session $name still working after $((TOMS/1000))s -> waiting"
      ag_wait "$name" "$to"; [ -s "$8" ] && break
      st=$(ag_status "$name"); done
    [ "$st" = blocked ] && log "BLOCKED: session $name is waiting on an approval/question UI after $2 (left as is)"
    [ -s "$8" ] && break
    [ "$st" = blocked ] && break
    log "$2: no output file after attempt $attempt (status=$st) -> re-prompt"
  done
  drain "$name"
  ag_read "$name" 400 > "${TRANSCRIPT_DIR:-$RUN}/$2.transcript.txt" 2>&1
  [ -s "$8" ] || { log "$2: agent did not write $8 -> using transcript"; cp "${TRANSCRIPT_DIR:-$RUN}/$2.transcript.txt" "$8"; }
  echo 0
}
checks() { # label -> 0 if tests+lint pass; writes runs/<label>.log
  printf 'cd "%s"; { echo "## tests"; %s; t=$?; echo "## lint"; %s; l=$?; echo "tests_rc=$t lint_rc=$l"; } > "%s" 2>&1; [ $t = 0 ] && [ $l = 0 ]\n' \
    "$WT" "$TEST_CMD" "$LINT_CMD" "$RUN/$1.log" > "$RUN/$1.sh"
  local rc; rc=$(pane_step "$P_B" "$1" "$RUN/$1.sh"); find "$WT" -name __pycache__ -type d -prune -exec rm -rf {} + 2>/dev/null; return "$rc"
}
AGENT_MODE=${AGENT_MODE:-herdr}; AMP_AGENT_MODE=${AMP_AGENT_MODE:-headless}
[ "$REVIEW_AGENT" = amp ] && { REVIEW_MODEL=$AMP_REVIEW_MODE; REVIEW_EFFORT=; }
[ "$JUDGE_AGENT" = amp ] && { JUDGE_MODEL=$AMP_JUDGE_MODE; JUDGE_EFFORT=; }
CTX="Task: $RUN/task.md. Public acceptance criteria: $RUN/acceptance.md. Spec: $RUN/spec.md."

spec_ok() { # S1 gate (v3.2): case-insensitive section headers + machine-readable Interface Stubs
  { python3 "$LAB/lab_tools.py" spec_sections "$RUN/spec.md" && python3 "$LAB/lab_tools.py" stubs_check "$RUN/spec.md"; } > "$RUN/spec-stubcheck.txt" 2>&1
}
# ---------- S1 spec + architecture + task breakdown (Amp, single call, high -> fallback)
t=$(date +%s)
if [ "${REUSE_SPEC:-0}" = 1 ] && [ -s "$RUN/spec.md" ]; then USED_MODE="(reused spec.md)"
  spec_ok || { stage S1-spec amp reused 0 "FAIL(spec gate)"; log "S1 gate: reused spec invalid: $(head -c 300 "$RUN/spec-stubcheck.txt" 2>/dev/null)"; exit 1; }
  stage S1-spec amp reused 0 REUSED
else
  cat > "$RUN/spec-prompt.md" <<P
You are the SPEC AUTHOR and ARCHITECT for a small Python repo (current dir). Do not edit files. Read the repo briefly.
Write a precise, self-contained spec in Markdown with EXACTLY these sections:
## Requirements (numbered, testable)  ## Interface (function signatures, CLI usage, error types/messages, exit codes)
## Architecture (modules/files, data flow)  ## Task breakdown (ordered small steps)  ## Test plan (named test cases incl. edge/error cases)
## Limits & Input domain (REQUIRED: numeric ranges and max magnitudes, resource limits such as nesting depth/input length/result size, allowed character set, and for each violation the exact error type + message + exit code)
## Interface Stubs (REQUIRED, machine-readable; one line per NEW top-level function/class the tests will import: '- <relpath.py> :: def name(args) -> Type' or '- <relpath.py> :: class Name', OR exactly '- NONE (existing entrypoint only)' when tests only use existing entrypoints such as the CLI main)
## Out of scope. Max 160 lines. Be concrete; no prose padding.
TASK:
$(cat "$RUN/task.md")
PUBLIC ACCEPTANCE CRITERIA:
$(cat "$RUN/acceptance.md")
P
  for mode in "$SPEC_MODE" "$SPEC_FALLBACK"; do
    printf 'cd "%s" && timeout -k 30 %s amp -m %s -x "$(cat "%s")" </dev/null > "%s" 2> "%s"\n' "$WT" "${S1_TIMEOUT:-900}" "$mode" "$RUN/spec-prompt.md" "$RUN/spec.md" "$RUN/spec.err" > "$RUN/s1-$mode.sh"
    t1=$(date +%s); count_call amp "$mode" "s1-$mode"; rc=$(pane_step "$P_PLAN" "s1$mode" "$RUN/s1-$mode.sh")
    if [ "$rc" = 0 ] && spec_ok; then USED_MODE=$mode; break; fi
    rcs=$(s1_rcdesc "$rc" "$RUN/spec.md"); S1_NOTE="${S1_NOTE:+$S1_NOTE; }$mode $rcs after $(( $(date +%s)-t1 ))s"
    log "S1 amp -m $mode failed (rc=$rcs; gate: $(head -c 200 "$RUN/spec-stubcheck.txt" 2>/dev/null | tr '\n' ' ')); $(head -c 200 "$RUN/spec.err" | tr '\n' ' ')"
  done
  SA=amp; SM=$USED_MODE
  if [ -z "${USED_MODE:-}" ]; then
    # fallback chain (family rule: never the implementer family): Droid paid -> Droid core -> grok
    for c in $(python3 "$LAB/lab_tools.py" s1chain --impl "agy:$IMPL_MODEL" --paid "$DROID_PAID_AVAILABLE"); do
      IFS=: read -r fa fm fe <<< "$c"; log "S1: Amp unavailable -> trying fallback spec author $fa/$fm effort $fe"
      agent_step "$P_A" "s1-spec" "$fa" "$fm" "$fe" "$DROID_AUTO_RO" "$RUN/spec-prompt.md" "$RUN/spec.md" >/dev/null
      if spec_ok; then SA=$fa; SM=$fm; USED_MODE="$fm/$fe (fallback)"; break; fi
      log "S1 fallback $fa/$fm did not produce a valid spec"
    done
  fi
  [ -n "${USED_MODE:-}" ] || { stage S1-spec amp "$SPEC_MODE" $(( $(date +%s)-t )) FAIL; exit 1; }
  stage S1-spec "$SA" "$USED_MODE" $(( $(date +%s)-t )) "PASS${S1_NOTE:+ (incl. $S1_NOTE)}"
fi
[ "${SA:-amp}" = amp ] && SM=${SM:-high}
# ---------- family resolver: S1/S2 != implementer family (incl. escalation target); S2 != S1 preferred; escalation != S2/S1
# v3.2: S2 effort is locked to the configured value (medium); a missing Test plan is an S1 gate failure, not an effort switch.
eval "$(python3 "$LAB/lab_tools.py" resolve --impl "agy:$IMPL_MODEL" --s1 "${SA:-amp}:${SM:-high}" --tests "$TESTS_AGENT:$TESTS_MODEL:$TESTS_EFFORT" --impl2 "$IMPL2_AGENT:$IMPL2_MODEL:$IMPL2_EFFORT" --reviewers "$REVIEW_MODEL,$SECURITY_MODEL,$JUDGE_MODEL" --paid "$DROID_PAID_AVAILABLE")"
log "family resolver: $RESOLVE_FAMILIES; $RESOLVE_NOTE"
stage S1.5-resolve orchestrator "S2=$TESTS_AGENT/$TESTS_MODEL esc=$IMPL2_AGENT/$IMPL2_MODEL" 0 "$([ "$RESOLVE_FAIL" = 0 ] && echo OK || echo IMPOSSIBLE)"
if [ "$RESOLVE_FAIL" != 0 ]; then echo "$RESOLVE_NOTE" > "$RUN/resolve.txt"; escalate_human "family constraints cannot be satisfied" "$RUN/resolve.txt"; exit 4; fi

agy_trust() { python3 - "$1" "$WT" <<'PY'
import json,os,sys
f=os.path.expanduser("~/.gemini/antigravity-cli/settings.json"); d=json.load(open(f)) if os.path.exists(f) else {}
l=d.setdefault("trustedWorkspaces",[]); p=sys.argv[2]
if sys.argv[1]=="add" and p not in l: l.append(p)
if sys.argv[1]=="rm": d["trustedWorkspaces"]=[x for x in l if x!=p]
json.dump(d,open(f,"w"),indent=2)
PY
}
agy_trust add; trap 'chmod -R u+w "$WT" 2>/dev/null; rm -f "$RUN/.ro.count"; agy_trust rm' EXIT

# ---------- S2 tests first (Droid, codex family, different agent than implementer)
t=$(date +%s)
if [ "${RESUME:-0}" = 1 ] && [ -n "$PREV_TESTS_SHA" ]; then
  TESTS_SHA=$PREV_TESTS_SHA; TEST_FILES=$(git -C "$WT" show --name-only --format= "$TESTS_SHA" | tr '\n' ' '); TESTS_MODEL="(reused $TESTS_SHA)"
  stage S2-tests droid reused 0 "REUSED($TEST_FILES)"
else
# ---------- S1.8 deterministic interface stubs from the spec's '## Interface Stubs' (base commit for S2)
t8=$(date +%s); STUB_FILES=$(python3 "$LAB/lab_tools.py" gen_stubs "$RUN/spec.md" "$WT" 2> "$RUN/s18-stubs.err") || { stage S1.8-stubs orchestrator gen_stubs 0 FAIL; log "S1.8 stub generation failed: $(head -c 300 "$RUN/s18-stubs.err")"; exit 1; }
if [ -n "$STUB_FILES" ]; then GIT add -- $STUB_FILES && GIT commit -qm "pipeline $TASK: interface stubs (S1.8, generated from spec)"; fi
STUBS_SHA=$(GIT rev-parse --short HEAD); stage S1.8-stubs orchestrator gen_stubs $(( $(date +%s)-t8 )) "PASS(${STUB_FILES:-none}; base $STUBS_SHA)"
python3 "$LAB/lab_tools.py" s2ctx "$RUN/spec.md" "$WT" > "$RUN/s2-context.md" 2>/dev/null || true
cat > "$RUN/s2-prompt.md" <<P
You are the TEST DESIGNER (tests-first) in $WT. Everything you need is below - do NOT explore the repository.
Write Python unittest test files (test_*.py or tests/) that encode the spec's Test plan, Interface and Limits exactly, through the public interface only (no implementation coupling, no tautologies; 'tdd' skill tests.md, not its user-confirmation steps).
Interface stubs raising NotImplementedError are already committed ($STUB_FILES). You may ONLY create/modify test files; any other change is reverted automatically.
Tool budget: write the files, run 'ruff check --isolated --select E9,F,B <your test files>' at most ONCE, run '$TEST_CMD' at most ONCE (it is expected to be RED: only AssertionError/NotImplementedError failures, no import/collection errors). Do not iterate on unittest. Do not commit. Reply with one line: DONE.
===== SPEC ($RUN/spec.md)
$(cat "$RUN/spec.md")
===== PUBLIC ACCEPTANCE ($RUN/acceptance.md)
$(cat "$RUN/acceptance.md")
===== PUBLIC SIGNATURES AND TEST STYLE
$(cat "$RUN/s2-context.md")
P
s2_gate() { # attempt -> 0 ok; sets TEST_FILES; v3.2: S2 may only touch tests - everything else is reverted (git clean inside worktree only)
  local f bad=""
  TEST_FILES=$(cd "$WT" && git status --porcelain --untracked-files=all | awk '{print $2}' | grep -E '(^|/)test[^/]*\.py$|^tests/' | grep -v __pycache__ || true)
  [ -n "$TEST_FILES" ] || { log "S2 gate: no test files"; return 1; }
  for f in $(cd "$WT" && git status --porcelain --untracked-files=all | awk '{print $2}' | grep -vE '(^|/)test[^/]*\.py$|^tests/|__pycache__' || true); do
    bad="$bad $f"
  done
  if [ -n "$bad" ]; then log "S2 gate: non-test changes reverted:$bad"
    for f in $bad; do if git -C "$WT" ls-files --error-unmatch "$f" >/dev/null 2>&1; then git -C "$WT" checkout HEAD -- "$f"; else git -C "$WT" clean -fdq -- "$f"; fi; done; fi
  (cd "$WT" && ruff check --isolated --select E9,F,B --output-format concise $TEST_FILES) > "$RUN/s2-ruff-$1.log" 2>&1 || { log "S2 gate: ruff on tests failed ($(tail -n1 "$RUN/s2-ruff-$1.log"))"; return 2; }
  checks "s2-red-$1"; python3 "$LAB/lab_tools.py" redcheck "$RUN/s2-red-$1.log" > "$RUN/s2-redcheck-$1.txt" || { log "S2 gate: red run not clean: $(cat "$RUN/s2-redcheck-$1.txt")"; return 3; }
  return 0
}
agent_step "$P_A" s2-tests "$TESTS_AGENT" "$TESTS_MODEL" "$TESTS_EFFORT" "$DROID_AUTO_RW" "$RUN/s2-prompt.md" "$RUN/s2-tests.md" >/dev/null
s2_gate 1; g=$?
if [ $g != 0 ]; then
  printf 'The S2 gate failed (code %s: 1=no tests, 2=ruff on tests, 3=red run had collection/wiring errors or no failures). Logs: %s %s %s. Fix the TESTS only (stubs are generated and fixed; failures must be AssertionError/NotImplementedError only). Same tool budget: ruff once, unittest once, no repo exploration. Do not commit. Reply: DONE.\n' "$g" "$RUN/s2-ruff-1.log" "$RUN/s2-red-1.log" "$RUN/s2-redcheck-1.txt" > "$RUN/s2-prompt-2.md"
  agent_step "$P_A" s2-tests-2 "$TESTS_AGENT" "$TESTS_MODEL" "$TESTS_EFFORT" "$DROID_AUTO_RW" "$RUN/s2-prompt-2.md" "$RUN/s2-tests-2.md" >/dev/null
  s2_gate 2; g=$?
fi
if [ $g != 0 ]; then stage S2-tests "$TESTS_AGENT" "$TESTS_MODEL/$TESTS_EFFORT" $(( $(date +%s)-t )) "FAIL(gate $g)"; exit 1; fi
find "$WT" -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null
GIT add -- $TEST_FILES && GIT commit -qm "pipeline $TASK: tests first (S2, $TESTS_AGENT/$TESTS_MODEL)" && TESTS_SHA=$(GIT rev-parse --short HEAD)
if [ "${TEST_FAULT_INJECT:-0}" = 1 ] && [ -s "${TEST_FAULT_FILE:-}" ]; then
  FT="${TEST_FAULT_TARGET:-test_zz_extra.py}"; cp "$TEST_FAULT_FILE" "$WT/$FT"; TEST_FILES="$TEST_FILES $FT"
  GIT add -- "$FT" && GIT commit -q --amend --no-edit && TESTS_SHA=$(GIT rev-parse --short HEAD)
  echo "planted fault: $FT from $TEST_FAULT_FILE into tests commit $TESTS_SHA at $(date +%T)" >> "$PRIV/planted-fault.log"
  log "TEST_FAULT_INJECT active: one deliberately spec-contradicting test planted into the tests commit (details: $PRIV/planted-fault.log)"
fi
stage S2-tests "$TESTS_AGENT" "$TESTS_MODEL/${TESTS_EFFORT:-default}" $(( $(date +%s)-t )) "PASS($(echo $TEST_FILES | wc -w) test files, stubs:${STUB_FILES:- none}, red=clean, commit $TESTS_SHA)"
fi

# ---------- S3 implement (agy as herdr agent) + S4 static checks; bounded loop
if [ "${RESUME:-0}" = 1 ] && ag_exists "impl-$TASK"; then log "resume: reusing agy agent impl-$TASK"
else ag_start "impl-$TASK" agy "$P_IMPL" 60000 --model "$IMPL_MODEL" --dangerously-skip-permissions > "$RUN/agy-start.json" 2>&1 \
  || { log "agy start failed: $(cat "$RUN/agy-start.json")"; exit 1; }
fi
IMPL_NAME="impl-$TASK"; IMPL_AG=agy; IMPL_M="$IMPL_MODEL"; IMPL_ESCALATED=""
escalate_impl() { # reason ; switch implementer once to IMPL2 (herdr agent in the planner pane)
  [ -n "$IMPL_ESCALATED" ] && return 0
  if [ "$IMPL2_AGENT" = none ]; then IMPL_ESCALATED=human; echo "$1 (no escalation implementer satisfies the family rules: $RESOLVE_NOTE)" > "$RUN/impl-escalation.txt"; escalate_human "implementer escalation needed but no eligible model" "$RUN/impl-escalation.txt"; return 0; fi
  log "implementer escalation ($1): agy/$IMPL_MODEL -> $IMPL2_AGENT/$IMPL2_MODEL effort $IMPL2_EFFORT"
  agent_args "impl2-$TASK" "$IMPL2_AGENT" "$IMPL2_MODEL" "$IMPL2_EFFORT" high
  if ag_start "impl2-$TASK" "$IMPL2_AGENT" "$P_PLAN" 120000 "${AARGS[@]}" > "$RUN/impl2-start.json" 2>&1; then ag_ready "impl2-$TASK" || ag_wait "impl2-$TASK" 30000
    IMPL_ESCALATED=1; IMPL_NAME="impl2-$TASK"; IMPL_AG=$IMPL2_AGENT; IMPL_M="$IMPL2_MODEL/$IMPL2_EFFORT"
    python3 -c "import json,sys;f=sys.argv[1];d=json.load(open(f));d['agent2_name']=sys.argv[2];d['agent2_pane']=sys.argv[3];json.dump(d,open(f,'w'),indent=2)" "$RUN/herdr-ids.json" "impl2-$TASK" "$P_PLAN"
    stage ESCALATE-IMPL orchestrator "$IMPL_M" 0 "$1"
    IMPL_PREFIX="You are taking over as IMPLEMENTER in $WT (previous implementer: agy/$IMPL_MODEL; its work is uncommitted in the worktree). $CTX Committed tests ($TEST_FILES) must NOT be modified. "
  else log "implementer escalation failed: $(head -c 300 "$RUN/impl2-start.json")"; IMPL_ESCALATED=failed; fi
}
herdr_impl_prompt() { ag_prompt "$IMPL_NAME" "$1" "$(step_ms "$IMPL_AG")"; }
impl() { # prompt label
  local t=$(date +%s)
  count_call "$IMPL_AG" "$IMPL_M" "s3-$2"; herdr_impl_prompt "${IMPL_PREFIX:-}$1 TEST DISPUTES: if (and only if) you are convinced a committed test contradicts the spec/acceptance, do NOT edit it; write one line per disputed test to $RUN/$2.dispute.md as 'TEST_DISPUTE: [file:line] (ref: <spec/acceptance id>) <reason + repro command>' and implement everything else." > "$RUN/$2.json" 2>&1; IMPL_PREFIX=""
  drain "$IMPL_NAME"
  ag_read "$IMPL_NAME" 300 > "$RUN/$2.transcript.txt" 2>&1
  IMPL_SECS=$(( $(date +%s)-t ))
  if [ "$IMPL_AG" = agy ] && [ -z "$IMPL_ESCALATED" ] && grep -qiE 'network (issue|error)|connecting to the server|ECONNRESET|ETIMEDOUT|503 Service Unavailable|UNAVAILABLE' "$RUN/$2.transcript.txt"; then
    log "agy network error detected in $2 -> fast-fail"; escalate_impl "agy network error ($2)"
    [ "$IMPL_ESCALATED" = 1 ] && impl "$1" "$2-retry"
  fi
}
DISPUTE_ROUNDS=0; DISPUTE_PENALTY=0
handle_dispute() { # label -> 0 no dispute, 1 UPHELD (test fixed + committed, not counted), 2 escalated (UNCLEAR/none/2nd dispute), 3 REJECTED (counted as 1 S3 failure)
  local f="$RUN/$1.dispute.md" adj fa fm fe dec
  python3 "$LAB/review_issues.py" disputes "$f" > "$RUN/$1.dispute.parsed" 2>/dev/null || return 0
  stage S3-dispute "$IMPL_AG" "$IMPL_M" 0 "TEST_DISPUTE x$(wc -l < "$RUN/$1.dispute.parsed") (not counted as failure)"
  if [ "$DISPUTE_ROUNDS" -ge 1 ]; then escalate_human "second test dispute (max 1 round)" "$f"; return 2; fi
  DISPUTE_ROUNDS=1; local t=$(date +%s)
  adj=$(python3 "$LAB/lab_tools.py" adjudicator --s2 "$TESTS_AGENT:$TESTS_MODEL" --impl "agy:$IMPL_MODEL" --impl2 "$IMPL2_AGENT:$IMPL2_MODEL" --cands "$JUDGE_AGENT:$JUDGE_MODEL:$JUDGE_EFFORT,droid:$SECURITY_MODEL:$SECURITY_EFFORT,$REVIEW_AGENT:$REVIEW_MODEL:$REVIEW_EFFORT") || { escalate_human "no third-family adjudicator" "$f"; return 2; }
  IFS=: read -r fa fm fe <<< "$adj"
  cat > "$RUN/s25-prompt.md" <<P
You are the TEST ADJUDICATOR (S2.5). Do not modify files. $CTX
The implementer disputes committed tests (file:line, ref, reason):
$(cat "$RUN/$1.dispute.parsed")
Read the spec and public acceptance, open each disputed test at the given location, run it if useful, and decide strictly against the spec/acceptance text.
Output: per dispute a short rationale; for UPHELD disputes the exact required correction of the test (what the assertion must check instead).
The LAST line must be exactly one of: 'ADJUDICATION: UPHELD', 'ADJUDICATION: REJECTED', 'ADJUDICATION: UNCLEAR' (UPHELD only if every dispute is clearly correct per the spec).
P
  agent_step "$P_A" s25-adjudicate "$fa" "$fm" "$fe" "$DROID_AUTO_RO" "$RUN/s25-prompt.md" "$RUN/s25-adjudication.md" >/dev/null
  dec=$(grep -oE 'ADJUDICATION: (UPHELD|REJECTED|UNCLEAR)' "$RUN/s25-adjudication.md" | tail -n1 | cut -d' ' -f2)
  stage S2.5-adjudicate "$fa" "$fm/$fe" $(( $(date +%s)-t )) "${dec:-NONE}"
  if [ "$dec" = REJECTED ]; then DISPUTE_PENALTY=1; log "S2.5 REJECTED the dispute -> reason fed back to implementer; counted as 1 S3 failure"; return 3; fi
  [ "$dec" = UPHELD ] || { escalate_human "test dispute ${dec:-without decision} (human decision needed)" "$RUN/$1.dispute.parsed" "$RUN/s25-adjudication.md"; return 2; }
  t=$(date +%s); snap_take s25
  cat > "$RUN/s2-fix-prompt.md" <<P
TEST FIX after adjudication. The adjudicator upheld a dispute against your tests: see $RUN/s25-adjudication.md (disputes: $RUN/$1.dispute.parsed).
Correct ONLY the disputed test(s) exactly as required there. Do not change any other test or any production file. Run ruff check --isolated --select E9,F,B on the test files. Do not commit.
P
  agent_step "$P_A" s2-tests-3 "$TESTS_AGENT" "$TESTS_MODEL" "$TESTS_EFFORT" "$DROID_AUTO_RW" "$RUN/s2-fix-prompt.md" "$RUN/s2-tests-fix.md" >/dev/null
  local rev; rev=$(snap_revert_except s25 "$(echo $TEST_FILES | sed 's/ /|/g; s/\./\\./g; s/^/^(/; s/$/)$/')"); [ -n "$rev" ] && log "S2 test-fix touched non-test files (reverted):$rev"
  (cd "$WT" && ruff check --isolated --select E9,F,B --output-format concise $TEST_FILES) > "$RUN/s2-fix-ruff.log" 2>&1 || { escalate_human "S2 test fix failed ruff" "$RUN/s2-fix-ruff.log"; return 2; }
  GIT add -- $TEST_FILES && GIT commit -qm "pipeline $TASK: test fix after upheld dispute (S2.5, $TESTS_AGENT/$TESTS_MODEL)" && TESTS_SHA=$(GIT rev-parse --short HEAD)
  stage S2-testfix "$TESTS_AGENT" "$TESTS_MODEL" $(( $(date +%s)-t )) "PASS(commit $TESTS_SHA)"
  return 1
}
impl_d() { # prompt label : impl + dispute protocol; a dispute round is not counted as an implementation failure
  impl "$1" "$2"; handle_dispute "$2"; case $? in
    1) impl "The disputed test was corrected by the test designer and committed ($TESTS_SHA). Continue: make ALL committed tests pass without modifying them; re-run $TEST_CMD and $LINT_CMD. Do not commit. Reply: FIXED." "$2-postdispute"; handle_dispute "$2-postdispute" >/dev/null;;
    3) impl "The adjudicator REJECTED your test dispute; the committed tests are correct. Reasoning: $RUN/s25-adjudication.md. Make ALL committed tests pass without modifying them; re-run $TEST_CMD and $LINT_CMD. Do not commit. No further disputes are possible. Reply: FIXED." "$2-postreject"; handle_dispute "$2-postreject" >/dev/null;;
  esac
}
tests_tampered() { git -C "$WT" diff --quiet HEAD -- $TEST_FILES || echo yes; }
t=$(date +%s)
if [ "${RESUME:-0}" = 1 ]; then IMPL_SECS=0; log "resume: skipping initial implementation, re-checking current worktree"; else
impl_d "You are the IMPLEMENTER in $WT. $CTX Tests already exist and are committed ($TEST_FILES): make them pass WITHOUT modifying them. Follow the spec's Task breakdown. Then run: $TEST_CMD and: $LINT_CMD and fix issues. Do not commit. Reply with one line: IMPLEMENTED. (Skill hints: tdd for red->green discipline; diagnosing-bugs if a failure is unclear.)" s3-impl-1
fi
[ "${FINAL:-}" = ESCALATE ] || checks s3-check-1; ok=$?; [ "${FINAL:-}" = ESCALATE ] && ok=9; n=1; FAILS=$([ $ok = 0 ] && echo 0 || echo 1); FAILS=$((FAILS+DISPUTE_PENALTY)); DISPUTE_PENALTY=0
stage S3-implement "$IMPL_AG" "$IMPL_M" $IMPL_SECS "$([ $ok = 0 ] && echo PASS || echo FAIL)$([ -n "$(tests_tampered)" ] && echo ' (tests modified!)')"
while [ "${FINAL:-}" != ESCALATE ] && [ $ok != 0 ] && [ $n -le "$MAX_IMPL_LOOPS" ]; do
  [ "$FAILS" -ge "$IMPL_ESCALATE_AFTER" ] && escalate_impl "S4 failed $FAILS times in a row"
  [ "${FINAL:-}" = ESCALATE ] && break
  impl_d "Checks failed. See $RUN/s3-check-$n.log (tests + ruff). Fix production code (not tests) until both pass; for each failure re-test its whole input class. Use the diagnosing-bugs skill: reproduce with the failing test first, then fix the root cause. Do not commit. Reply: FIXED." "s3-fix-$n"
  n=$((n+1)); checks "s3-check-$n"; ok=$?; [ $ok = 0 ] && FAILS=0 || FAILS=$((FAILS+1)); FAILS=$((FAILS+DISPUTE_PENALTY)); DISPUTE_PENALTY=0
  stage "S3-fix-$((n-1))" "$IMPL_AG" "$IMPL_M" $IMPL_SECS "$([ $ok = 0 ] && echo PASS || echo FAIL)"
done
stage S4-static ruff+unittest deterministic 0 "$([ $ok = 0 ] && echo PASS || echo FAIL)"
if [ $ok = 0 ] && [ "${MUTATION_N:-0}" -gt 0 ] && ! skip_until 1; then t=$(date +%s)
  python3 "$LAB/lab_tools.py" mutate "$WT" "$BASE" "$TEST_CMD" "$MUTATION_N" 120 > "$RUN/s4-mutation.txt" 2>&1
  MSCORE=$(grep -oE 'score=[0-9.na/]+' "$RUN/s4-mutation.txt" | cut -d= -f2)
  MRES="score=${MSCORE:-?} ($(head -n1 "$RUN/s4-mutation.txt"))"
  if [ "$MSCORE" != n/a ] && [ -n "$MSCORE" ] && python3 -c "import sys;sys.exit(0 if float(sys.argv[1])<float(sys.argv[2]) else 1)" "$MSCORE" "$MUTATION_FLOOR"; then
    MRES="$MRES BELOW floor $MUTATION_FLOOR"
    [ "$MUTATION_GATE" = fail ] && { stage S4-mutation orchestrator mutate $(( $(date +%s)-t )) "$MRES"; escalate_human "test strength below mutation floor" "$RUN/s4-mutation.txt"; }
  fi
  [ "${FINAL:-}" = ESCALATE ] || stage S4-mutation orchestrator mutate $(( $(date +%s)-t )) "$MRES"
fi
[ $ok = 0 ] || [ "${FINAL:-}" = ESCALATE ] || { log "S3/S4 gate failed after $MAX_IMPL_LOOPS fix loops"; FINAL=FAIL; }

# ---------- S4.5 optional Grok self-review prefilter (PREREVIEW=1): may edit production code, never tests; reverted if it breaks the gate
if [ -z "${FINAL:-}" ] && [ "$PREREVIEW" = 1 ] && ! skip_until 2; then
  t=$(date +%s); snap_take s45
  cat > "$RUN/s45-prompt.md" <<P
You are a PRE-REVIEWER (self-review prefilter) in $WT. $CTX Look at git diff $BASE. Fix only obvious code smells, dead code, unclear names, missing input validation and obvious security issues (eval/exec, unbounded resources, path handling) in production code.
Do NOT modify test files ($TEST_FILES), do not change behaviour required by the spec, do not commit. Run $TEST_CMD and $LINT_CMD afterwards. Print a short list of changes.
P
  agent_step "$P_A" s45-prereview grok "$PREREVIEW_MODEL" "$PREREVIEW_EFFORT" - "$RUN/s45-prompt.md" "$RUN/s45-prereview.md" >/dev/null
  checks s45-check; pok=$?
  if [ $pok != 0 ] || [ -n "$(tests_tampered)" ]; then log "S4.5 broke the gate or touched tests -> full rollback (checkout + git clean -fd in worktree)"; snap_restore s45; git -C "$WT" checkout HEAD -- $TEST_FILES; checks s45-revert-check; R45=REVERTED; else R45=PASS; fi
  stage S4.5-prereview grok "$PREREVIEW_MODEL/$PREREVIEW_EFFORT" $(( $(date +%s)-t )) "$R45"
fi

# ---------- S5 code review + S6 security review (parallel, different families) with bounded fix loop
FMT=$(cat <<'F'
ISSUE FORMAT (mandatory): list ALL blocking issues in ONE pass (probe each input class fully; do not stop at the first). One line per issue:
BLOCKING: [category] (ref: <spec section/requirement id or acceptance id>) <issue + reproducing command>
SUGGESTION: [category] <non-blocking idea>
category is one of: correctness, input-domain, limits, error-handling, security, tests, docs, api, other.
Only issues that violate the spec (incl. its Limits & Input domain section) or the acceptance criteria may be BLOCKING and they MUST cite the ref. Edge cases the spec does not define are SUGGESTION, never BLOCKING.
Refs must be ids that literally exist in the spec/acceptance (e.g. A3, L2, R4 = spec Requirement 4); unknown refs are downgraded to SUGGESTION by the orchestrator. Put a runnable repro in backticks: repro: `<command>` - the orchestrator runs it once in a read-only sandbox and attaches the result.
Also end with a machine-readable block (preferred over text):
```json
{"verdict": "APPROVE|REJECT", "blocking": [{"ref": "A3", "category": "correctness", "desc": "...", "repro": "..."}]}
```
followed by the VERDICT line as the very last line.
F
)
fmt_fix() { # pane label agent model effort outfile : REJECT without valid BLOCKING lines -> one format-correction re-prompt (same session, not counted)
  python3 "$LAB/review_issues.py" valid "$6" >/dev/null && return 0
  log "$2: REJECT without a well-formed BLOCKING line -> format-correction re-prompt (not counted)"
  cp "$6" "${6%.md}.preformat.md"
  printf 'FORMAT CORRECTION for step %s. Your answer (copy: %s) ends with VERDICT: REJECT but has no well-formed blocking line. Rewrite the full answer: every blocking issue as one line "BLOCKING: [category] (ref: <spec/acceptance id>) <issue + repro command>". If no issue qualifies (spec/acceptance-based), change the verdict to APPROVE and list SUGGESTION lines. Keep the last line VERDICT: APPROVE or VERDICT: REJECT.\n' "$2" "${6%.md}.preformat.md" > "$RUN/$2f-prompt.md"
  agent_step "$1" "${2}f" "$3" "$4" "$5" "$DROID_AUTO_RO" "$RUN/$2f-prompt.md" "$6" >/dev/null
}
incr_pack() { # round(jN) pre-fix-sha -> $RUN/incr-context-<round>.md : ONLY redacted S8 BLOCKING list + fix diff + touched tests
  local r=$1 base=$2 jr=${1#j} f out="$RUN/incr-context-$1.md" tf
  { echo "### 1. Previous round's BLOCKING findings (final judge round $jr, as given to the implementer)"
    grep -E '^[[:space:]]*BLOCKING:' "$RUN/s8-judge-$jr.md" 2>/dev/null || echo '(none listed)'
    echo; echo "### 2. Fix diff (git diff $base, plus new untracked files)"; echo '```diff'
    git -C "$WT" diff "$base" -- . ':(exclude)*__pycache__*'
    for f in $(git -C "$WT" ls-files -o --exclude-standard | grep -v __pycache__); do git -C "$WT" diff --no-index /dev/null "$f" 2>/dev/null; done
    echo '```'
    tf=$( { git -C "$WT" diff --name-only "$base"; git -C "$WT" ls-files -o --exclude-standard; } | grep -E '(^|/)test[^/]*\.py$|^tests/' | sort -u)
    echo; echo "### 3. Test files touched by the fix"
    if [ -n "$tf" ]; then for f in $tf; do echo "#### $f"; echo '```python'; cat "$WT/$f"; echo '```'; done
    else echo "(none; committed test files for reference only: $TEST_FILES)"; fi; } > "$out"
}
wt_ro() { # on|off : refcounted under flock, so overlapping/parallel read-only stages never re-enable writes early (trap restores on exit)
  [ "${RO_REVIEW:-1}" = 1 ] || return 0
  ( flock 9; n=$(cat "$RUN/.ro.count" 2>/dev/null || echo 0)
    if [ "$1" = on ]; then [ "$n" -eq 0 ] && chmod -R a-w "$WT"; echo $((n+1)) > "$RUN/.ro.count"
    else n=$((n>0 ? n-1 : 0)); echo $n > "$RUN/.ro.count"; [ "$n" -eq 0 ] && chmod -R u+w "$WT"; fi ) 9>"$RUN/.ro.lock"; }
ground_review() { # file -> refs must be public ids (else SUGGESTION), repro run once in bwrap read-only/no-net sandbox
  [ -s "$1" ] || return 0; verdict "$1" >/dev/null; local g; g=$(python3 "$LAB/lab_tools.py" ground "$1" "$RUN/spec.md" "$RUN/acceptance.md" "$WT" "${GROUND_REPRO:-1}" 2>&1); log "grounding $(basename "$1"): $g"; }
settle() { # pane label agent model effort file -> prints final verdict. REJECT whose BLOCKING lines are all invalid/downgraded
  # gets ONE format-correction re-prompt (same session, not a round); if still none valid -> APPROVE with logged downgrades + WARN.
  local v; ground_review "$6" >&2; v=$(verdict "$6")
  if [ "$v" = REJECT ] && ! python3 "$LAB/review_issues.py" valid "$6" >/dev/null; then
    fmt_fix "$1" "$2" "$3" "$4" "$5" "$6" >&2; ground_review "$6" >&2; v=$(verdict "$6")
    if [ "$v" = REJECT ] && ! python3 "$LAB/review_issues.py" valid "$6" >/dev/null; then
      printf '\nWARN: [orchestrator] REJECT had no BLOCKING finding with a valid public ref after one format correction; downgraded findings kept as SUGGESTION; treated as APPROVE.\nVERDICT: APPROVE\n' >> "$6"
      log >&2 "WARN $2: REJECT without any valid BLOCKING after re-prompt -> APPROVE with suggestions"; echo "$2" >> "$RUN/warn-approved.txt"; v=APPROVE; fi
  fi; echo "$v"; }
review_round() { # round [incremental-base]
  local r=$1 t=$(date +%s); WS0=$(wtstate); PREV_SEC=""
  local RSCOPE="all changes since $BASE (git diff $BASE; tests were committed separately and must not be weakened)"
  if [ -n "${2:-}" ]; then incr_pack "$r" "$2"; RSCOPE="ONLY the S8 fix described in the pre-packed context file $RUN/incr-context-$r.md (previous BLOCKING list, fix diff, touched tests). Do NOT explore or open any other file and do not review the rest of the change. Judge ONLY (a) whether each listed BLOCKING finding is fixed by the diff and (b) whether the fix diff itself introduces a NEW blocking issue. Context:
$(cat "$RUN/incr-context-$r.md")
"; fi
  if [[ "$r" =~ ^[0-9]+$ ]] && [ "$r" -gt 1 ] && [ -f "$RUN/s6-security-$((r-1)).md" ]; then
    PREV_SEC="CONSISTENCY: your previous round ($((r-1))) verdict was $(verdict "$RUN/s6-security-$((r-1)).md") with these blocking issues:
$(grep -iE 'BLOCKING:' "$RUN/s6-security-$((r-1)).md" || echo '(none)')
Code changed since then: $(cd "$WT" && git diff --stat | tail -n1). Re-check each previous issue (fixed/not fixed). Do NOT flip APPROVE->REJECT unless you cite NEW evidence (a reproducing command against code that changed or a previously unprobed input); otherwise keep your verdict."
  fi
  cat > "$RUN/s5-prompt-$r.md" <<P
You are the CODE REVIEWER. Do not modify files. $CTX Review $RSCOPE.
Check correctness vs spec, edge cases, error handling, readability, test adequacy. Focus on async calls, thread/coroutine shared state and lock contention (where applicable). Single pass, read-only. Run: $TEST_CMD. Only report findings that affect correctness or stated requirements as blocking.
Use the 'code-review' skill's two axes (Spec = $RUN/spec.md, Standards = repo conventions) but do it yourself in this session (no issue tracker, no sub-agents needed).
$FMT
Write a concise review; the LAST line must be exactly 'VERDICT: APPROVE' or 'VERDICT: REJECT'.
P
  cat > "$RUN/s6-prompt-$r.md" <<P
You are the SECURITY REVIEWER. Do not modify files. $CTX Review $RSCOPE for security issues: code injection (eval/exec), unbounded recursion/resource exhaustion (deep nesting, huge exponents), unsafe input handling, information leakage in errors.
Blocking = an exploitable or crash-inducing issue reachable from the CLI or public API that violates the spec/acceptance.
$FMT
$PREV_SEC
Last line exactly 'VERDICT: APPROVE' or 'VERDICT: REJECT'.
P
  if [ -n "${2:-}" ]; then # incremental re-review after an S8 fix: pre-packed, focused prompts only (no full-diff invitation)
    for k in s5:CODE s6:SECURITY; do printf 'You are the %s REVIEWER for an INCREMENTAL re-review. Do not modify files. Review %s\n%s\nLast line exactly '"'"'VERDICT: APPROVE'"'"' or '"'"'VERDICT: REJECT'"'"'.\n' "${k#*:}" "$RSCOPE" "$FMT" > "$RUN/${k%%:*}-prompt-$r.md"; done
  fi
  if [ "${SINGLE_REVIEW:-0}" = 1 ]; then # LIGHT: one Droid reviewer, code + security merged
    { echo; echo "ALSO act as the SECURITY REVIEWER (single merged review):"; sed -n '1,3p' "$RUN/s6-prompt-$r.md" | sed '1s/^You are the [A-Z ]*REVIEWER[^.]*\. Do not modify files\. //'; } > "$RUN/s5-sec-$r.tmp"
    sed -i '$d' "$RUN/s5-prompt-$r.md"; cat "$RUN/s5-sec-$r.tmp" >> "$RUN/s5-prompt-$r.md"; echo "Last line exactly 'VERDICT: APPROVE' or 'VERDICT: REJECT'." >> "$RUN/s5-prompt-$r.md"; rm -f "$RUN/s5-sec-$r.tmp" "$RUN/s6-prompt-$r.md"
  fi
  [ -s "$RUN/s4-mutation.txt" ] && grep -q '^survived' "$RUN/s4-mutation.txt" && printf '\nTEST STRENGTH (orchestrator mutation sampling, %s): mutants the committed tests did NOT detect:\n%s\nThese are hints only: report weak tests as SUGGESTION: [tests] lines; a surviving mutant alone is NEVER a BLOCKING issue.\n' "$(head -n1 "$RUN/s4-mutation.txt")" "$(grep '^survived' "$RUN/s4-mutation.txt")" >> "$RUN/s5-prompt-$r.md"
  wt_ro on
  agent_step "$P_A" "s5-review-$r" "$REVIEW_AGENT" "$REVIEW_MODEL" "$REVIEW_EFFORT" "$DROID_AUTO_RO" "$RUN/s5-prompt-$r.md" "$RUN/s5-review-$r.md" > /dev/null &
  [ "${SINGLE_REVIEW:-0}" = 1 ] || agent_step "$P_B" "s6-security-$r" droid "$SECURITY_MODEL" "$SECURITY_EFFORT" "$DROID_AUTO_RO" "$RUN/s6-prompt-$r.md" "$RUN/s6-security-$r.md" > /dev/null &
  wait
  RV=$(verdict "$RUN/s5-review-$r.md"); if [ "${SINGLE_REVIEW:-0}" = 1 ]; then SV=SKIP; else SV=$(verdict "$RUN/s6-security-$r.md"); fi
  # infrastructure retry: a reviewer that produced no verdict (crash/permission) is re-run once, not counted as a fix round
  if [ -z "$RV" ]; then log "S5 round $r produced no verdict -> retry ($(tail -c 160 "$RUN/s5-review-$r.md" | tr '\n' ' '))"; mv "$RUN/s5-review-$r.md" "$RUN/s5-review-$r.noverdict.md"
    agent_step "$P_A" "s5-review-${r}b" "$REVIEW_AGENT" "$REVIEW_MODEL" "$REVIEW_EFFORT" "$DROID_AUTO_RO" "$RUN/s5-prompt-$r.md" "$RUN/s5-review-$r.md" > /dev/null; RV=$(verdict "$RUN/s5-review-$r.md"); fi
  if [ -z "$SV" ]; then log "S6 round $r produced no verdict -> retry ($(tail -c 160 "$RUN/s6-security-$r.md" | tr '\n' ' '))"; mv "$RUN/s6-security-$r.md" "$RUN/s6-security-$r.noverdict.md"
    agent_step "$P_B" "s6-security-${r}b" droid "$SECURITY_MODEL" "$SECURITY_EFFORT" "$DROID_AUTO_RO" "$RUN/s6-prompt-$r.md" "$RUN/s6-security-$r.md" > /dev/null; SV=$(verdict "$RUN/s6-security-$r.md"); fi
  RV=$(settle "$P_A" "s5-review-$r" "$REVIEW_AGENT" "$REVIEW_MODEL" "$REVIEW_EFFORT" "$RUN/s5-review-$r.md")
  [ "$SV" = SKIP ] || SV=$(settle "$P_B" "s6-security-$r" droid "$SECURITY_MODEL" "$SECURITY_EFFORT" "$RUN/s6-security-$r.md")
  wt_ro off
  [ "$(wtstate)" = "$WS0" ] || log "WARNING: a reviewer modified the worktree in round $r"
  local s=$(( $(date +%s)-t ))
  stage "S5-review-$r" "$REVIEW_AGENT" "$REVIEW_MODEL/${REVIEW_EFFORT:-default}" $s "${RV:-UNKNOWN}"
  if [ "$SV" = SKIP ]; then SV=$RV; else stage "S6-security-$r" droid "$SECURITY_MODEL/${SECURITY_EFFORT:-default}" $s "${SV:-UNKNOWN} (parallel)"; fi
}
if [ "${FINAL:-}" != FAIL ] && skip_until 3; then RV=APPROVE; SV=APPROVE; log "resume: S5/S6 skipped (checkpoint APPROVE with unchanged worktree)"
elif [ "${FINAL:-}" != FAIL ]; then
  r=1; review_round $r
  if { [ "$RV" != APPROVE ] || [ "$SV" != APPROVE ]; } && ! why=$(python3 "$LAB/review_issues.py" escalate "$RUN" 1); then FINAL=ESCALATE; log "ESCALATE after review round 1: $(echo "$why" | head -n3 | tr '\n' ' ')"; stage ESCALATE orchestrator - 0 "see escalation.md"; fi
  while [ "${FINAL:-}" != ESCALATE ] && { [ "$RV" != APPROVE ] || [ "$SV" != APPROVE ]; } && [ $r -le "$MAX_REVIEW_LOOPS" ]; do
    escalate_impl "review REJECT round $r"
    impl "Reviewers requested changes. Address every blocking finding in $RUN/s5-review-$r.md and $RUN/s6-security-$r.md (only files marked REJECT matter; code review: ${RV:-?}, security: ${SV:-?}). For EACH blocking issue: identify its whole input class (e.g. all non-ASCII digits, all huge exponents), re-test the whole class, fix the root cause, and ADD regression tests covering the class. Do not weaken existing tests. Re-run $TEST_CMD and $LINT_CMD. Do not commit. Reply: FIXED." "s5-fix-$r"
    checks "s5-check-$r"; ok=$?; stage "S5/6-fix-$r" "$IMPL_AG" "$IMPL_M" $IMPL_SECS "checks $([ $ok = 0 ] && echo PASS || echo FAIL)"
    r=$((r+1)); review_round $r
    if [ "$RV" != APPROVE ] || [ "$SV" != APPROVE ]; then
      if why=$(python3 "$LAB/review_issues.py" escalate "$RUN" "$r"); then :; else FINAL=ESCALATE; log "ESCALATE after review round $r -> $RUN/escalation.md: $(echo "$why" | head -n3 | tr '\n' ' ')"; stage ESCALATE orchestrator - 0 "see escalation.md"; break; fi
    fi
  done
  { [ "$RV" = APPROVE ] && [ "$SV" = APPROVE ]; } || [ "${FINAL:-}" = ESCALATE ] || { log "review gate failed after $MAX_REVIEW_LOOPS loops"; FINAL=FAIL; }
fi

# ---------- S7 docs + changelog (cheap model)
if [ -z "${FINAL:-}" ] && ! skip_until 4 && [ "${SKIP_DOCS:-0}" != 1 ]; then
  t=$(date +%s)
  cat > "$RUN/s7-prompt.md" <<P
You are the DOCS WRITER. $CTX Update README.md with a short usage section for the new functionality (API + CLI examples that are actually correct; verify by running them),
and add/extend CHANGELOG.md with an entry for this change. Do NOT modify any .py files. Print the commands you ran to verify examples.
P
  snap_take s7
  agent_step "$P_A" s7-docs "$DOCS_AGENT" "$DOCS_MODEL" "$DOCS_EFFORT" "$DROID_AUTO_RW" "$RUN/s7-prompt.md" "$RUN/s7-docs.md" > /dev/null
  rev=$(snap_revert_except s7 '\.md$|(^|/)CHANGELOG[^/]*$|^docs/'); [ -n "$rev" ] && log "S7 post-gate: reverted non-doc changes:$rev"
  checks s7-check; ok=$?
  stage S7-docs "$DOCS_AGENT" "$DOCS_MODEL/${DOCS_EFFORT:-default}" $(( $(date +%s)-t )) "$([ $ok = 0 ] && echo PASS || echo FAIL)"
fi

# ---------- S8 final judge (strongest model, sees hidden acceptance) + bounded fix loop
HT_ADJ=""
hidden_adjudicate() { # round : a failing hidden test is checked against spec+acceptance by a third-family adjudicator before it can fail/escalate the task
  local r=$1 adj fa fm fe pf="$PRIV/s8-hidden-adj-prompt.md" po="$PRIV/s8-hidden-adj.md"
  adj=$(python3 "$LAB/lab_tools.py" adjudicator --s2 "$TESTS_AGENT:$TESTS_MODEL" --impl "agy:$IMPL_MODEL" --impl2 "$IMPL2_AGENT:$IMPL2_MODEL" --cands "$JUDGE_AGENT:$JUDGE_MODEL:$JUDGE_EFFORT,droid:$SECURITY_MODEL:$SECURITY_EFFORT,$REVIEW_AGENT:$REVIEW_MODEL:$REVIEW_EFFORT") || { HT_ADJ=VALID; log "hidden tests: no third-family adjudicator -> treated as valid"; return; }
  IFS=: read -r fa fm fe <<< "$adj"
  { echo "You are the HIDDEN-TEST ADJUDICATOR. Do not modify files. Spec: $RUN/spec.md. Public acceptance: $RUN/acceptance.md."
    echo "Confidential executable tests: $HTESTS. Their failing output: $PRIV/hidden-tests-$r.out."
    echo "Decide ONLY whether each FAILING hidden test asserts behaviour that the spec/public acceptance actually require (VALID) or contradicts/exceeds them (INVALID). Do not judge the implementation."
    echo "Last line exactly 'HIDDEN_TEST: VALID' or 'HIDDEN_TEST: INVALID'."; } > "$pf"
  TRANSCRIPT_DIR="$PRIV" agent_step "$P_A" s8-hidden-adj "$fa" "$fm" "$fe" "$DROID_AUTO_RO" "$pf" "$po" >/dev/null
  HT_ADJ=$(grep -oE 'HIDDEN_TEST: (VALID|INVALID)' "$po" | tail -n1 | cut -d' ' -f2); HT_ADJ=${HT_ADJ:-VALID}
  stage S8-hidden-adjudicate "$fa" "$fm/$fe" 0 "$HT_ADJ"
  if [ "$HT_ADJ" = INVALID ]; then echo "$(date '+%F %T') round $r: hidden tests marked INVALID by $fa/$fm (see $po); excluded from this task's gate" >> "$PRIV/hidden-tests-invalid.md"
    log "hidden tests judged INVALID vs spec by third-family adjudicator -> marked in private dir, not failing the task"; HT=""; fi
}
judge() { # round
  local r=$1 t=$(date +%s) pf="$PRIV/s8-judge-prompt-$r.md" po="$PRIV/s8-judge-$r.md" n HT=""
  if [ -n "$HTESTS" ] && [ "$HT_ADJ" != INVALID ]; then HT=$(python3 "$LAB/lab_tools.py" hidden_tests "$WT" "$HTESTS" "$PRIV/hidden-tests-$r.out" 2>&1); HTRC=$?; log "S8 round $r: executable hidden tests: ${HT%% *} rc=$HTRC (details private)"; fi
  { echo "You are the FINAL JUDGE. Do not modify files. $CTX"
    echo "Evaluate the full change (git diff $BASE; git log $BASE..HEAD) plus reviews in $RUN (s5-*, s6-*), check logs, docs (README.md, CHANGELOG.md)."
    echo "Run: $TEST_CMD and: $LINT_CMD yourself. Verify every public acceptance criterion and every spec Requirement with evidence (commands + output)."
    [ "${HTRC:-0}" = 2 ] && echo "NOTE: the confidential executable tests could not be run in the sandbox (unverified); rely on the written criteria."
    [ -n "$HT" ] && [ "${HTRC:-0}" != 2 ] && { echo "EXECUTABLE CONFIDENTIAL TESTS were run by the orchestrator on a sandboxed copy: $HT. Full output: $PRIV/hidden-tests-$r.out. Failing ones are unmet criteria (map them to public ids; never quote them)."; }
    [ -n "$HID" ] && { echo "ADDITIONAL CONFIDENTIAL ACCEPTANCE CRITERIA (mandatory; REJECT if any unmet; you may describe unmet ones as findings):"; cat "$HID"; }
    echo "RULES FOR FINDINGS: every blocking finding is one line 'BLOCKING: [category] (ref: <PUBLIC spec requirement or acceptance id such as A3/L2>) <behaviour gap in your own words + repro command>'. NEVER quote, paraphrase or mention the confidential criteria text or ids; map each unmet confidential criterion to the closest public spec/acceptance id. Your output is shown to the implementer."
    echo "Output: a checklist of PUBLIC criteria (id -> PASS/FAIL + evidence), BLOCKING lines, then the LAST line exactly 'VERDICT: APPROVE' or 'VERDICT: REJECT'."; } > "$pf"
  wt_ro on
  TRANSCRIPT_DIR="$PRIV" agent_step "$P_A" "s8-judge-$r" "$JUDGE_AGENT" "$JUDGE_MODEL" "$JUDGE_EFFORT" "$DROID_AUTO_RO" "$pf" "$po" > /dev/null
  JV=$(verdict "$po")
  if [ -z "$JV" ]; then log "S8 round $r no verdict -> retry"; mv "$po" "${po%.md}.noverdict.md"
    TRANSCRIPT_DIR="$PRIV" agent_step "$P_A" "s8-judge-${r}b" "$JUDGE_AGENT" "$JUDGE_MODEL" "$JUDGE_EFFORT" "$DROID_AUTO_RO" "$pf" "$po" > /dev/null; JV=$(verdict "$po"); fi
  JV=$(TRANSCRIPT_DIR="$PRIV" settle "$P_A" "s8-judge-$r" "$JUDGE_AGENT" "$JUDGE_MODEL" "$JUDGE_EFFORT" "$po")
  wt_ro off
  if [ -n "$HT" ] && [ "${HTRC:-0}" = 1 ] && [ -z "${HT_ADJ:-}" ]; then hidden_adjudicate "$r"; fi
  if [ -n "$HT" ] && [ "${HTRC:-0}" = 1 ] && [ "${HT_ADJ:-}" = VALID ] && [ "$JV" = APPROVE ]; then log "S8 round $r: judge APPROVED although executable hidden tests fail -> ESCALATE"; echo "$HT" > "$RUN/hidden-tests-summary.txt"; escalate_human "judge approved but executable hidden tests fail" "$RUN/hidden-tests-summary.txt"; JV=ESCALATED; fi
  if [ -n "$HID" ]; then n=$(python3 "$LAB/lab_tools.py" redact "$HID" "$po" "$RUN/s8-judge-$r.md" "${REDACT_NGRAM:-6}" "$RUN/spec.md" "$RUN/acceptance.md"); [ "$n" != 0 ] && log "S8 round $r: redacted $n line(s) overlapping confidential criteria (unredacted copy: $po)"
  else cp "$po" "$RUN/s8-judge-$r.md"; fi
  stage "S8-judge-$r" "$JUDGE_AGENT" "$JUDGE_MODEL/${JUDGE_EFFORT:-default}" $(( $(date +%s)-t )) "${JV:-UNKNOWN}"
}
if [ -z "${FINAL:-}" ] && skip_until 5; then JV=APPROVE; log "resume: S8 skipped (checkpoint APPROVE with unchanged worktree)"
elif [ -z "${FINAL:-}" ]; then
  r=1; judge $r
  while [ "$JV" != APPROVE ] && [ "$JV" != ESCALATED ] && [ $r -le "$MAX_JUDGE_LOOPS" ]; do
    escalate_impl "judge REJECT"
    [ "${FINAL:-}" = ESCALATE ] && break
    snap_take s8pre; PRE8=$(cat "$PRIV/snap-s8pre/sha")
    impl "The final judge rejected. Address every BLOCKING finding in $RUN/s8-judge-$r.md (re-test each finding's whole input class, add regression tests). Do not weaken tests. Re-run $TEST_CMD and $LINT_CMD. Do not commit. Reply: FIXED." "s8-fix-$r"
    checks "s8-check-$r"; ok=$?; stage "S8-fix-$r" "$IMPL_AG" "$IMPL_M" $IMPL_SECS "checks $([ $ok = 0 ] && echo PASS || echo FAIL)"
    [ $ok = 0 ] || { log "S8 fix broke the S4 gate"; FINAL=FAIL; break; }
    review_round "j$r" "$PRE8"   # quick incremental S5/S6 on the post-judge diff
    { [ "$RV" = APPROVE ] && [ "$SV" = APPROVE ]; } || { log "incremental re-review after S8 fix rejected"; FINAL=FAIL; break; }
    r=$((r+1)); judge $r
  done
  [ "$JV" = APPROVE ] || [ "${FINAL:-}" = ESCALATE ] || FINAL=FAIL
fi

# ---------- commit (gate: judge APPROVE + deterministic checks)
checks final-check; ok=$?
COMMIT=none
if [ -z "${FINAL:-}" ] && [ "${JV:-}" = APPROVE ] && [ $ok = 0 ]; then
  GIT add -A -- . ':!*__pycache__*' ':!*.pyc'
  GIT diff --cached --quiet || GIT commit -q -m "pipeline $TASK: $(head -n1 "$RUN/task.md" | sed 's/^#* *//' | cut -c1-60)" -m "Spec: ${SA:-amp}/${USED_MODE:-?}
Tests: $TESTS_AGENT/$TESTS_MODEL r=$TESTS_EFFORT (commit $TESTS_SHA)
Implementer: agy/$IMPL_MODEL$([ "$IMPL_ESCALATED" = 1 ] && echo " -> $IMPL_AG/$IMPL_M (escalated)")
Families: $RESOLVE_FAMILIES
Code-review: $REVIEW_AGENT/$REVIEW_MODEL r=$REVIEW_EFFORT
Security-review: droid/$SECURITY_MODEL r=$SECURITY_EFFORT
Docs: $DOCS_AGENT/$DOCS_MODEL r=$DOCS_EFFORT
Judge: $JUDGE_AGENT/$JUDGE_MODEL r=${JUDGE_EFFORT:-default} (APPROVE)
Profile: ${PROFILE:-default}${RESUME:+ (resumed)}"
  COMMIT=$(GIT rev-parse --short HEAD); FINAL=PASS; log "commit: $COMMIT on agent/pipe-$TASK (tests commit $TESTS_SHA)"
else [ "${FINAL:-}" = ESCALATE ] || FINAL=FAIL; log "commit: skipped (judge=${JV:-n/a}, checks rc=$ok)"; fi
STAT=$(git -C "$WT" diff --shortstat "$BASE" HEAD); git -C "$WT" diff "$BASE" HEAD > "$RUN/final.diff"

# ---------- S9 retrospective (non-blocking; SKIP_RETRO=1 skips it and the rule merge)
t=$(date +%s)
if [ "${SKIP_RETRO:-0}" = 1 ]; then log "S9 skipped (SKIP_RETRO=1)"; else
cat > "$RUN/s9-prompt.md" <<P
$([ "$RETRO_AGENT" = droid ] && echo "/retro ")You are the RETROSPECTIVE writer (non-interactive; do not ask questions). Do NOT modify any files. Digest ALL logs in $RUN: trace.md, stages.tsv, every s*-*.md / *.log / *.transcript.txt, escalation.md if present.
Output plain Markdown, <= 30 lines: (1) what went well, (2) what failed or looped and the root cause per stage, (3) stage/model/effort changes for next time, (4) prompt improvements,
(5) a section '## Proposed AGENTS.md rules': read the existing AGENTS.md in $WT (if any) and the previous proposals, MERGE and GENERALIZE (dedupe, keep rules generic and testable, one line each), cap at 30 rules total, and mark new/changed rules with (new)/(changed).
The worktree is read-only for this step.
P
if [ "${AMP_RETRO:-0}" = 1 ]; then (cd "$WT" && amp -m "$SPEC_FALLBACK" -x "$(cat "$RUN/s9-prompt.md")" </dev/null > "$RUN/s9-retro.md" 2>&1); RA=amp; RM=$SPEC_FALLBACK
else wt_ro on
  agent_step "$P_A" s9-retro "$RETRO_AGENT" "$RETRO_MODEL" "$RETRO_EFFORT" "$DROID_AUTO_RO" "$RUN/s9-prompt.md" "$RUN/s9-retro.md" > /dev/null; wt_ro off; RA=$RETRO_AGENT; RM="$RETRO_MODEL/${RETRO_EFFORT:-default}"; chmod -R u+w "$WT"; fi
stage S9-retro $RA "$RM" $(( $(date +%s)-t )) done
mkdir -p "$LAB/rules"; log "S9 rule store: $(python3 "$LAB/lab_tools.py" rules_merge "$LAB/rules/agents-rules.json" "$RUN/s9-retro.md" "$(date +%F)" "${RULE_EXPIRE_MERGES:-10}" 30 2>&1) -> $LAB/rules/agents-rules.md"
fi

amp usage </dev/null 2>/dev/null | grep -i 'free' > "$RUN/amp-usage-after.txt"
{ echo; echo "## Result"; echo "- final: $FINAL"; echo "- commit: $COMMIT (tests-first commit: ${TESTS_SHA:-none})"; echo "- diff:$STAT"
  echo "- total: $(( $(date +%s)-T0 ))s"; echo "- amp usage: before [$(cat "$RUN/amp-usage-before.txt")] after [$(cat "$RUN/amp-usage-after.txt")]"
  echo "- herdr workspace $WS; agent impl-$TASK in $P_IMPL; planner pane $P_PLAN"; echo; echo '## Stages'; echo '```'; cat "$STAGES"; echo '```'; } >> "$TRACE"
cat "$TRACE"
[ "$FINAL" = PASS ]
