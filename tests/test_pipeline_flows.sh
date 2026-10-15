source "$(dirname "$0")/lib.sh"; cd "$T"; mkdir -p run priv
base='set -u; LAB='$LABDIR'; RUN='$T'/run; PRIV='$T'/priv; TASK=t; TEST_CMD=t; LINT_CMD=l; IMPL_AG=agy; IMPL_M=m; IMPL_MODEL=gemini-3.8-flash-high; IMPL2_AGENT=grok; IMPL2_MODEL=grok-4.7; TESTS_AGENT=grok; TESTS_MODEL=grok-4.7; TESTS_EFFORT=medium; JUDGE_AGENT=droid; JUDGE_MODEL=kimi-k3; JUDGE_EFFORT=high; SECURITY_MODEL=qwen3.8-max; SECURITY_EFFORT=xhigh; REVIEW_AGENT=droid; REVIEW_MODEL=glm-5.3; REVIEW_EFFORT=high; P_A=p; DROID_AUTO_RO=x; CTX=c
log(){ echo "LOG $*"; }; stage(){ echo "STAGE $*"; }; escalate_human(){ echo "ESCALATE $1"; FINAL=ESCALATE; }; impl(){ echo "IMPL[$2]"; }'
# --- TEST_DISPUTE: REJECTED counts 1 failure, UNCLEAR escalates
{ echo "$base"; echo 'agent_step(){ echo "$DEC" > "$8"; }'; echo 'DISPUTE_ROUNDS=0; DISPUTE_PENALTY=0'; fx 'handle_dispute() {'; fx 'impl_d() {'; } > d.sh
echo 'TEST_DISPUTE: [test_x.py:3] (ref: A4) reason; repro: python3 -m unittest' > run/s3-impl-1.dispute.md
o=$(bash -c "source d.sh; DEC='ADJUDICATION: REJECTED'; impl_d go s3-impl-1; echo PEN=\$DISPUTE_PENALTY FINAL=\${FINAL:-}")
has "dispute REJECTED: reason fed back" "$o" "IMPL\[s3-impl-1-postreject\]"; has "dispute REJECTED: counts 1 failure" "$o" "PEN=1 FINAL=$"
o=$(bash -c "source d.sh; DEC='ADJUDICATION: UNCLEAR'; impl_d go s3-impl-1; echo FINAL=\${FINAL:-}"); has "dispute UNCLEAR: escalates" "$o" "FINAL=ESCALATE"
# --- S1.8 stub generation + S2 gate (only tests allowed)
mkrepo wt 'mkdir ledger; printf "def existing():\n    return 1\n" > ledger/core.py; touch ledger/__init__.py'
printf '## Interface Stubs\n- ledger/core.py :: def validate_year(value: str) -> str\n' > run/spec.md
{ echo "$base; WT=$T/wt"; echo 'GIT(){ git -C "$WT" -c user.email=a@b -c user.name=a "$@"; }; checks(){ (cd $WT && python3 -m unittest 2>&1; echo "tests_rc=$?") > $RUN/$1.log; }'
  awk '/^# ---------- S1.8/{f=1} /^python3 "\$LAB\/lab_tools.py" s2ctx/{f=0} f' "$P"; fx 's2_gate() {'
  echo 'cd $WT; printf "import unittest\nfrom ledger.core import validate_year, existing\nclass T(unittest.TestCase):\n    def test_v(self): self.assertEqual(validate_year(\"2026\"), \"2026\")\n    def test_old(self): self.assertEqual(existing(), 1)\n" > test_new.py; printf "\ndef validate_year(v):\n    return v\n" >> ledger/core.py; echo junk > notes.txt; cd - >/dev/null'
  echo 's2_gate 1; echo "GATE=$? TF=$TEST_FILES"; git -C $WT status --short | grep -v pycache'; } > g.sh
o=$(bash g.sh 2>&1)
has "S1.8: stubs committed" "$o" "S1.8-stubs orchestrator gen_stubs .* PASS\(ledger/core.py"
has "S2 gate: non-test changes reverted" "$o" "non-test changes reverted: ledger/core.py notes.txt"
has "S2 gate: passes with partial red" "$o" "GATE=0 TF=test_new.py"
printf '## Interface Stubs\n- m.py :: def g(a b)\n' > run/spec.md; o=$(bash -c "$(echo "$base; WT=$T/wt"; echo 'GIT(){ :; }'; awk '/^# ---------- S1.8/{f=1} /^python3 "\$LAB\/lab_tools.py" s2ctx/{f=0} f' "$P"; echo 'echo NOT-REACHED')"; echo "rc=$?")
has "S1.8: bad stub -> caught FAIL, exit 1" "$o" "S1.8-stubs orchestrator gen_stubs 0 FAIL"; hasnt "S1.8: pipeline stops" "$o" "NOT-REACHED"
# --- S8 fix loop: REJECT -> fix -> checks -> incremental review -> judge again
{ echo "$base; MAX_JUDGE_LOOPS=1; IMPL_SECS=0"; echo 'escalate_impl(){ echo "ESC_IMPL $*"; }; checks(){ echo "CHECKS $1"; return 0; }; snap_take(){ mkdir -p $PRIV/snap-$1; echo deadbeef > $PRIV/snap-$1/sha; }
J=(REJECT APPROVE); ji=0; judge(){ JV=${J[$ji]}; ji=$((ji+1)); echo "JUDGE $1 -> $JV"; }; review_round(){ echo "REVIEW_ROUND $1 base=$2"; RV=APPROVE; SV=APPROVE; }; skip_until(){ return 1; }'
  awk '/^elif \[ -z "\$\{FINAL:-\}" \]; then$/{f=1; print "if true; then"; next} f{print} f&&/^fi$/{exit}' "$P"; echo 'echo "JV=$JV FINAL=${FINAL:-}"'; } > j.sh
o=$(bash j.sh 2>&1); has "S8 loop: fix + incremental review j1" "$o" "REVIEW_ROUND j1 base=deadbeef"; has "S8 loop: judged again -> APPROVE" "$o" "JV=APPROVE FINAL=$"
# --- hidden-test adjudication: INVALID -> marked, task not failed; VALID + judge APPROVE -> ESCALATE
{ echo "$base; HTESTS=$T/priv/hidden-tests.py; HT='HIDDEN_TESTS rc=1 failed'; HTRC=1"; echo 'agent_step(){ echo "$ADJ" > "$8"; }'; echo 'HT_ADJ=""'; fx 'hidden_adjudicate() {'; } > h.sh
o=$(bash -c "source h.sh; ADJ='HIDDEN_TEST: INVALID'; hidden_adjudicate 1; echo ADJ=\$HT_ADJ HT=[\$HT]"); has "hidden adj INVALID: excluded" "$o" "ADJ=INVALID HT=\[\]"
has "hidden adj INVALID: marked in private dir" "$(cat priv/hidden-tests-invalid.md)" "marked INVALID"
o=$(bash -c "source h.sh; ADJ='HIDDEN_TEST: VALID'; hidden_adjudicate 1; JV=APPROVE; r=1; $(grep -F 'if [ -n "$HT" ] && [ "${HTRC:-0}" = 1 ] && [ "${HT_ADJ:-}" = VALID ] && [ "$JV" = APPROVE ]' "$P" | sed 's/; fi$/; fi/')"; echo "FINAL=\${FINAL:-}")
has "hidden adj VALID + judge APPROVE: ESCALATE" "$o" "ESCALATE judge approved but executable hidden tests fail"
# --- v3.4 LIGHT overlay: merged single review, conf composition, resume tolerance, S1 rc description
{ echo "$base; BASE=b0; FMT=fmt; SINGLE_REVIEW=1; P_B=q"; echo 'wtstate(){ echo h; }; wt_ro(){ :; }; verdict(){ tail -n1 "$1" | sed "s/VERDICT: //"; }; settle(){ verdict "$6"; }
agent_step(){ echo "CALL $2" >> $RUN/calls; echo "VERDICT: APPROVE" > "$8"; }'; fx 'review_round() {'; echo 'review_round 1; echo "RV=$RV SV=$SV"'; } > lr.sh
o=$(bash lr.sh 2>&1); c=$(cat run/calls)
eq "light: exactly one reviewer call" "$c" "CALL s5-review-1"; has "light: S5 stage recorded" "$o" "STAGE S5-review-1"; hasnt "light: no S6 stage" "$o" "S6-security"
has "light: gate sees APPROVE for both" "$o" "RV=APPROVE SV=APPROVE"; has "light: merged prompt has security part" "$(cat run/s5-prompt-1.md)" "ALSO act as the SECURITY REVIEWER"
eq "light: merged prompt ends with one verdict line" "$(tail -n1 run/s5-prompt-1.md)" "Last line exactly 'VERDICT: APPROVE' or 'VERDICT: REJECT'."; [ ! -f run/s6-prompt-1.md ] && ok "light: no s6 prompt left" || bad "light: s6 prompt left"
rm -f run/calls; { echo "$base; BASE=b0; FMT=fmt; SINGLE_REVIEW=0; P_B=q"; echo 'wtstate(){ echo h; }; wt_ro(){ :; }; verdict(){ tail -n1 "$1" | sed "s/VERDICT: //"; }; settle(){ verdict "$6"; }
agent_step(){ echo "CALL $2" >> $RUN/calls; echo "VERDICT: APPROVE" > "$8"; }'; fx 'review_round() {'; echo 'review_round 1'; } > fr.sh
o=$(bash fr.sh 2>&1); eq "full: two reviewer calls" "$(sort run/calls | tr '\n' ' ')" "CALL s5-review-1 CALL s6-security-1 "; has "full: S6 stage recorded" "$o" "STAGE S6-security-1"
o=$(env -i bash -c "cd $LABDIR; LIGHT=1; source pipeline.conf.light; source pipeline.conf >/dev/null 2>&1; echo \$SPEC_MODE \$MUTATION_N \$PREREVIEW \$SINGLE_REVIEW \$SKIP_DOCS \$SKIP_RETRO \$MAX_CALLS_TOTAL")
eq "light overlay values" "$o" "medium 0 0 1 1 1 16"
o=$(env -i bash -c "cd $LABDIR; MUTATION_N=3; source pipeline.conf.core >/dev/null 2>&1; source pipeline.conf.light; source pipeline.conf >/dev/null 2>&1; echo \$MUTATION_N \$SINGLE_REVIEW \$REVIEW_MODEL")
has "light composes with core; env wins" "$o" "^3 1 glm"
o=$(env -i bash -c "cd $LABDIR; source pipeline.conf >/dev/null 2>&1; echo \$SINGLE_REVIEW \$SKIP_DOCS \$SKIP_RETRO \$MUTATION_N"); eq "default: full pipeline" "$o" "0 0 0 5"
awk "/<<'PY'/{f=1;next} /^PY\$/{f=0} f" "$P" > rs4.py
printf 'S4-static\tPASS\th0\nS5-review-1\tAPPROVE\th1\n' > ckl.tsv; eq "resume light: no S4m/S6/S7 -> S8" "$(python3 rs4.py ckl.tsv h1 1)" S8; eq "resume full: S7 missing is NOT skipped" "$(python3 rs4.py ckl.tsv h1 0)" S7
printf 'S5-review-1\tAPPROVE\th1\nS8-judge-1\tAPPROVE\th1\n' > ckl2.tsv; eq "resume light: after S8 -> COMMIT" "$(python3 rs4.py ckl2.tsv h1 1)" COMMIT
printf 'S4-mutation\tscore=1.00\th1\nS5-review-1\tAPPROVE\th1\nS6-security-1\tREJECT\th1\n' > ckl3.tsv; eq "resume full: S6 REJECT still blocks" "$(python3 rs4.py ckl3.tsv h1)" S5
{ fx 's1_rcdesc() {'; } > rc.sh; : > empty.md; echo x > full.md
eq "S1 rc: timeout" "$(bash -c "source rc.sh; s1_rcdesc 124 full.md")" "TIMEOUT(900s,rc=124)"
eq "S1 rc: killed" "$(bash -c "source rc.sh; s1_rcdesc 143 full.md")" "KILLED(rc=143)"
eq "S1 rc: 0 + empty output flagged" "$(bash -c "source rc.sh; s1_rcdesc 0 empty.md")" "0-EMPTY-OUTPUT(killed/hung?)"
has "S1 PASS annotated with hang/timeout note" "$(cat "$P")" 'PASS\$\{S1_NOTE:\+ \(incl\. \$S1_NOTE\)\}'
has "S7 honours SKIP_DOCS" "$(cat "$P")" 'skip_until 4 && \[ "\$\{SKIP_DOCS:-0\}" != 1 \]'; has "S9 honours SKIP_RETRO" "$(cat "$P")" 'if \[ "\$\{SKIP_RETRO:-0\}" = 1 \]; then log "S9 skipped'
finish
