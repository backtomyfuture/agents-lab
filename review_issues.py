#!/usr/bin/env python3
"""Parse reviewer issue lines and decide escalation.
Reviewer line format (one per issue):
  BLOCKING: [category] (ref: S3|A2|H?) description
  SUGGESTION: [category] description
usage: review_issues.py list FILE | escalate RUNDIR ROUND | valid FILE | disputes FILE
'valid': exit 0 unless the file's verdict is REJECT and it has no well-formed BLOCKING line with a non-empty ref (-> format-correction re-prompt).
'disputes': print well-formed 'TEST_DISPUTE: [file:line] (ref: id) reason' lines; exit 1 if none.
exit 3 from 'escalate' => ESCALATE (escalation.md written)."""
import re, sys, os, glob
CATS = {"correctness","input-domain","limits","error-handling","security","tests","docs","api","out-of-spec","other"}
RX = re.compile(r'^\s*[-*]?\s*\**BLOCKING\**:\s*\[([^\]]+)\]\s*(?:\((?:ref|spec):\s*([^)]*)\))?\s*(.*)', re.I)

def issues(f):
    out = []
    if not os.path.exists(f): return out
    for l in open(f, errors="replace"):
        m = RX.match(l)
        if m:
            cat = m.group(1).strip().lower(); ref = (m.group(2) or "").strip()
            if cat not in CATS: cat = "other"
            out.append((cat, ref, m.group(3).strip()))
    return out

def round_issues(run, r):
    res = []
    for kind in ("s5-review", "s6-security"):
        res += [(kind,) + i for i in issues(f"{run}/{kind}-{r}.md")]
    return res

DRX = re.compile(r'^\s*[-*]?\s*\**TEST_DISPUTE\**:\s*\[([^\]:]+):(\d+)\]\s*\((?:ref|spec):\s*([^)]+)\)\s*(.+)', re.I)
if sys.argv[1] == "valid":
    f = sys.argv[2]; t = open(f, errors="replace").read() if os.path.exists(f) else ""
    v = re.findall(r'VERDICT: (APPROVE|REJECT)', t)
    if v and v[-1] == "REJECT" and not any(ref and ref.lower() not in ("none", "-", "n/a") for _, ref, _ in issues(f)):
        print("REJECT without a well-formed BLOCKING line"); sys.exit(1)
    sys.exit(0)
elif sys.argv[1] == "disputes":
    f = sys.argv[2]; found = 0
    if os.path.exists(f):
        for l in open(f, errors="replace"):
            m = DRX.match(l)
            if m: found += 1; print(f"{m.group(1)}:{m.group(2)}\t{m.group(3).strip()}\t{m.group(4).strip()}")
    sys.exit(0 if found else 1)
elif sys.argv[1] == "list":
    for c, ref, d in issues(sys.argv[2]): print(f"{c}\t{ref or '-'}\t{d}")
elif sys.argv[1] == "escalate":
    run, r = sys.argv[2], int(sys.argv[3])
    cur = round_issues(run, r)
    prev = {i[1] for k in range(1, r) for i in round_issues(run, k)}
    reasons = []
    for kind, c, ref, d in cur:
        if r > 1 and c in prev: reasons.append(f"repeat category '{c}' (already fixed in earlier round) — {kind}: {d}")
        if c == "out-of-spec" or ref.lower() in ("", "none", "-", "n/a"):
            reasons.append(f"blocking issue not tied to spec/acceptance ('{c}', ref='{ref or 'none'}') — {kind}: {d}")
    if not reasons: sys.exit(0)
    with open(f"{run}/escalation.md", "w") as f:
        f.write(f"# ESCALATE (review round {r})\n\nPipeline stopped instead of another fix loop. Human decision needed: amend spec/acceptance (Limits & Input domain), accept as known limitation, or allow more rounds.\n\n## Reasons\n")
        f.writelines(f"- {x}\n" for x in reasons)
        f.write("\n## Blocking issues by round\n")
        for k in range(1, r + 1):
            f.write(f"\n### Round {k}\n")
            f.writelines(f"- [{kind}] [{c}] (ref: {ref or 'none'}) {d}\n" for kind, c, ref, d in round_issues(run, k))
        f.write(f"\nFiles: {run}/s5-review-*.md, {run}/s6-security-*.md. herdr surfaces and worktree were kept.\n")
    print("\n".join(reasons)); sys.exit(3)
