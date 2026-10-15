#!/usr/bin/env bash
# stub-test runner for agents-lab (no LLM calls, no herdr). Usage: tests/run.sh [pattern]
cd "$(dirname "$0")"; rc=0
for t in test_*.sh; do [[ -n "${1:-}" && "$t" != *"$1"* ]] && continue; echo "== $t"; bash "$t" || rc=1; done
bash -n ../pipeline.sh && python3 -m py_compile ../lab_tools.py ../review_issues.py && echo "== syntax ok" || rc=1
[ $rc = 0 ] && echo "ALL PASSED" || echo "SOME FAILED"; exit $rc
