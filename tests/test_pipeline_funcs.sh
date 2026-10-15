source "$(dirname "$0")/lib.sh"; cd "$T"
mkdir -p bin run priv; mkrepo wt 'echo x > a.py'
cat > bin/herdr <<H
#!/bin/bash
echo "\$*" >> $T/herdr.log
case "\$1 \$2" in
 "agent get") [ -f $T/sess_\$3 ] && echo '{"agent_status":"idle","pane_id":"w1:p9"}' || exit 1;;
 "agent start") touch $T/sess_\$3; echo '{}';;
 "tab create") echo '{"result":{"root_pane":{"pane_id":"w1:p9"}}}';;
 "agent prompt") f=\$(echo "\$4" | grep -oE 'to the file [^ ,]+' | awk '{print \$4}'); [ -n "\$f" ] && printf 'review\nVERDICT: APPROVE\n' > "\$f"; echo '{}';;
 *) echo '{}';;
esac
H
chmod +x bin/herdr
{ echo "set -uo pipefail; export PATH=$T/bin:\$PATH; LAB=$LABDIR; source \$LAB/pipeline.conf; TASK=tx; RUN=$T/run; WT=$T/wt; WS=w1; PRIV=$T/priv"
  echo 'TRACE=$RUN/trace.md; STAGES=$RUN/stages.tsv; T0=$(date +%s); AGENT_MODE=herdr; AMP_AGENT_MODE=x; TOMS=1000; echo "{}" > $RUN/herdr-ids.json; : > $RUN/calls.tsv'
  echo 'escalate_human(){ FINAL=ESCALATE; echo "ESCALATE_HUMAN: $1"; stage ESCALATE orchestrator - 0 x; }; drain(){ :; }; step_ms(){ echo 1000; }'
  awk '/^log\(\) \{/{f=1} f{print} /^verdict\(\)/{exit}' "$P"
  for f in 'ag_exists()' 'ag_status()' 'ag_start()' 'ag_prompt()' 'ag_wait()' 'ag_ready()' 'ag_read()' 'agent_args()' 'sess_ensure()' 'agent_step()' 'wt_ro()' 'ground_review()' 'fmt_fix()' 'settle()' 'incr_pack()' 'spec_ok()'; do fx "$f"; done; } > lib.sh
source ./lib.sh
# adapter + call counting (fake herdr)
echo prompt > run/p.md; agent_step pane s5-review-1 droid glm-5.3 high medium run/p.md run/out.md >/dev/null
eq "adapter: verdict from agent file" "$(verdict run/out.md)" APPROVE
eq "adapter: one call counted" "$(cut -f2-4 run/calls.tsv)" "$(printf 'droid\tglm-5.3\ts5-review-1')"
has "adapter: start via ag_start" "$(cat herdr.log)" "agent start s5-review-droid-tx --kind droid"
# metrics + checkpoint
stage S5-review-1 droid glm 12 APPROVE >/dev/null
has "metrics.jsonl row" "$(tail -1 run/metrics.jsonl)" '"stage": "S5-review-1".*"tokens": null'
has "checkpoint row" "$(tail -1 run/checkpoints.tsv)" "^S5-review-1	APPROVE	[0-9a-f]{12}$"
# checkpoint hash definition
h0=$(wtstate); echo new > wt/u.txt; h1=$(wtstate); echo changed > wt/u.txt; h2=$(wtstate); mkdir -p wt/__pycache__; echo b > wt/__pycache__/x.pyc; h3=$(wtstate)
[ "$h0" != "$h1" ] && ok "hash: untracked file counted" || bad "hash: untracked file counted"
[ "$h1" != "$h2" ] && ok "hash: untracked CONTENT counted" || bad "hash: untracked CONTENT counted"
eq "hash: __pycache__ ignored" "$h3" "$h2"
git -C wt add u.txt; eq "hash: staging does not change state" "$(wtstate)" "$h2"; git -C wt reset -q; rm -rf wt/u.txt wt/__pycache__
# budget (soft, stage boundary)
o=$( MAX_CALLS_DROID=0; stage S6-security-1 droid q 1 APPROVE; echo NOT-EXITED ); rc=$?
eq "budget: call cap exits 5" $rc 5; has "budget: escalated" "$o" "ESCALATE_HUMAN: budget exceeded: droid agent calls 1 > MAX_CALLS_DROID=0"
o=$( T0=$(( $(date +%s)-8000 )); stage S7-docs grok g 1 PASS; echo NOT-EXITED ); eq "budget: wall clock exits 5" $? 5; has "budget: default TASK_TIMEOUT 7200" "$o" "TASK_TIMEOUT=7200s"
# refcounted read-only, concurrent reviewers
( wt_ro on; sleep 2; touch wt/c1 2>/dev/null && echo W1 > $T/ro1; wt_ro off ) & ( sleep 0.5; wt_ro on; sleep 0.3; wt_ro off; sleep 0.5; touch wt/c2 2>/dev/null && echo W2 > $T/ro2 ) & wait
[ ! -f ro1 ] && [ ! -f ro2 ] && ok "ro refcount: worktree stays read-only until the LAST reviewer finishes" || bad "ro refcount race (ro1=$(cat ro1 2>/dev/null) ro2=$(cat ro2 2>/dev/null))"
touch wt/c3 && ok "ro refcount: writable after all off" || bad "ro refcount: still read-only"; rm -f wt/c3; eq "ro refcount: counter back to 0" "$(cat run/.ro.count)" 0
# settle: invalid-only BLOCKING -> one re-prompt -> APPROVE with WARN
cp $LABDIR/runs/t11/spec.md $LABDIR/runs/t11/acceptance.md run/
agent_step() { printf 'still bad\nBLOCKING: [x] (ref: Q99) made up\nVERDICT: REJECT\n' > "$8"; echo "REPROMPT $2" >> $T/reprompts; echo 0; }
printf 'BLOCKING: [x] (ref: Q7) unknown ref\nVERDICT: REJECT\n' > run/s5-review-1.md
v=$(settle pA s5-review-1 droid glm high run/s5-review-1.md 2>/dev/null)
eq "settle: final APPROVE after re-prompt" "$v" APPROVE; eq "settle: exactly one re-prompt" "$(wc -l < reprompts)" 1
has "settle: WARN logged in file" "$(cat run/s5-review-1.md)" "^WARN: \[orchestrator\]"; has "settle: downgraded kept as SUGGESTION" "$(cat run/s5-review-1.md)" "^SUGGESTION: \[x\] \(ref: Q99\)"
printf 'BLOCKING: [correctness] (ref: A4) real\nVERDICT: REJECT\n' > run/s6.md; rm -f reprompts
eq "settle: valid BLOCKING stays REJECT" "$(settle pB s6 droid q x run/s6.md 2>/dev/null)" REJECT; [ ! -f reprompts ] && ok "settle: no re-prompt when valid" || bad "settle: unexpected re-prompt"
# resume checkpoint decision
awk '/RESUME_AT=\$\{RESUME_FROM/{f=1;next} f&&/^PY$/{exit} f' "$P" > rs.py
printf 'S4-mutation\tscore=0.80 (x)\th0\nS5-review-1\tREJECT\th2\nS6-security-1\tAPPROVE\th2\nS5-review-2\tAPPROVE\th3\nS6-security-2\tAPPROVE (parallel)\th3\nS7-docs\tPASS\th4\n' > ck.tsv
eq "resume: matching hash -> after S7 (S4.5 optional absent)" "$(python3 rs.py ck.tsv h4)" S8
eq "resume: hash mismatch -> S4 re-check" "$(python3 rs.py ck.tsv zz)" S4
printf 'S4-mutation\tscore=n/a\th1\nS4.5-prereview\tPASS\th1\nS5-review-1\tAPPROVE\th2\nS6-security-1\tREJECT\th2\n' > ck2.tsv
eq "resume: S6 REJECT -> S5" "$(python3 rs.py ck2.tsv h1)" S5
eq "resume: no checkpoints -> S4" "$(python3 rs.py nofile h1)" S4
# incremental re-review pack
B=$(git -C wt rev-parse HEAD); printf 'def f(x):\n    return x\n' > wt/a.py; printf 'import unittest\n' > wt/test_new.py
printf 'BLOCKING: [validation] (ref: L1) neg [REDACTED_HIDDEN_DETAIL]\nVERDICT: REJECT\n' > run/s8-judge-1.md; TEST_FILES=test_m.py
incr_pack j1 "$B"; o=$(cat run/incr-context-j1.md)
has "incr: blockers" "$o" "^BLOCKING: \[validation\] \(ref: L1\)"; has "incr: fix diff" "$o" "^\+def f"; has "incr: touched test" "$o" "#### test_new.py"; hasnt "incr: no full-diff invitation" "$o" "git diff \\\$BASE|full change"
# S1 gate
cp $T/../$(basename $T)/run/spec.md /dev/null 2>&1; printf '## Requirements\n1. report per year\n## Interface\n- report --year YYYY\n## test PLAN\n- test_report_year_basic\n## Limits & Input domain\n- year: 4 ASCII digits\n## Interface Stubs\n- NONE (existing entrypoint only)\n' > run/spec.md
spec_ok; eq "spec_ok: case-insensitive headers" $? 0
# t12 regressions: S1 amp must be time-bounded and counted against the AMP budget
s1=$(awk '/for mode in "\$SPEC_MODE"/{f=1} f{print} /^  done/{if(f)exit}' "$P")
has "S1: amp wrapped in timeout" "$s1" "timeout -k 30 %s amp"; has "S1: amp call counted" "$s1" "count_call amp"
finish
