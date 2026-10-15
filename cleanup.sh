#!/usr/bin/env python3
"""Clean up herdr surfaces of a pipeline task; keeps runs/<task>/ artifacts.
Usage: cleanup.sh <task-id> [--delete-branch] [--dry-run]
       cleanup.sh --all [--include-legacy] [--delete-branch] [--dry-run]
Only closes IDs recorded in runs/<task>/herdr-ids.json (or derived from runs/<task>/trace.md),
and only after verifying each live surface still matches (label / worktree path)."""
import json, os, re, subprocess, sys
LAB = os.path.dirname(os.path.realpath(__file__))
os.environ["PATH"] = os.path.expanduser("~/.local/bin") + ":" + os.environ["PATH"]
args = sys.argv[1:]
DRY, DELB, ALL, LEG = "--dry-run" in args, "--delete-branch" in args, "--all" in args, "--include-legacy" in args
tasks = [a for a in args if not a.startswith("--")]
if LEG and not ALL: sys.exit("--include-legacy requires --all")
if not tasks and not ALL: sys.exit(__doc__)

def herdr(*a, check=False):
    r = subprocess.run(["herdr", *a], capture_output=True, text=True)
    try: return json.loads(r.stdout)
    except Exception: return {"error": (r.stdout + r.stderr).strip()}
def act(desc, cmd):
    print(("[dry-run] " if DRY else "") + desc)
    if not DRY:
        r = subprocess.run(cmd, capture_output=True, text=True)
        out = (r.stdout + r.stderr).strip()
        print("   ->", "ok" if r.returncode == 0 else f"rc={r.returncode}", out[:200])
def git(repo, *a): return subprocess.run(["git", "-C", repo, *a], capture_output=True, text=True).stdout

def live():
    ws = {w["workspace_id"]: w for w in herdr("workspace", "list").get("result", {}).get("workspaces", [])}
    panes, tabs = {}, {}
    for wid in ws:
        for p in herdr("pane", "list", "--workspace", wid).get("result", {}).get("panes", []): panes[p["pane_id"]] = p
        for t in herdr("tab", "list", "--workspace", wid).get("result", {}).get("tabs", []): tabs[t["tab_id"]] = t
    return ws, panes, tabs

def load_ids(task):
    f = os.path.join(LAB, "runs", task, "herdr-ids.json")
    if os.path.exists(f): return json.load(open(f))
    tr = os.path.join(LAB, "runs", task, "trace.md")
    if not os.path.exists(tr): return None
    t = open(tr).read(); ids = {"task": task, "derived_from": "trace.md", "agent_name": None}
    m = re.search(r"orchestrator context: workspace=(\S+) tab=(\S+) pane=(\S+)", t)
    if m: ids.update(orchestrator_workspace=m[1], orchestrator_tab=m[2], orchestrator_pane=m[3])
    m = re.search(r"workspace (\S+) worktree (\S+) panes planner=(\S+) implementer=(\S+) verifier=(\S+)", t)
    if not m: return None
    ids.update(worktree_workspace=m[1], worktree_path=m[2], planner_pane=m[3], impl_pane=m[4], verifier_pane=m[5])
    m = re.search(r"agent '([a-z][a-z0-9_-]*)' still live", t); ids["agent_name"] = m[1] if m else "implementer"
    ids["branch"] = f"agent/pipe-{task}"; ids["repo"] = os.path.join(LAB, "sample-repo")
    if ids.get("orchestrator_tab"): ids["orchestrator_tab_created_by_launcher"] = True
    return ids

def agy_untrust(path):
    f = os.path.expanduser("~/.gemini/antigravity-cli/settings.json")
    if not os.path.exists(f): return
    d = json.load(open(f)); l = d.get("trustedWorkspaces", [])
    if path in l:
        print(("[dry-run] " if DRY else "") + f"remove agy trustedWorkspaces entry {path}")
        if not DRY: d["trustedWorkspaces"] = [x for x in l if x != path]; json.dump(d, open(f, "w"), indent=2)

def clean_task(task):
    ids = load_ids(task)
    if not ids: print(f"== {task}: no herdr-ids.json or parsable trace.md; skipping"); return
    print(f"== {task} (ids from {ids.get('derived_from','herdr-ids.json')})")
    ws, panes, tabs = live(); wt = ids["worktree_path"]
    # 1. stop agent (no 'agent stop' in herdr 0.9.4: send ctrl+c to the named agent, only if it sits in the recorded pane)
    a = herdr("agent", "get", ids["agent_name"]).get("result", {}).get("agent") if ids.get("agent_name") else None
    if a and a.get("pane_id") == ids["impl_pane"]:
        act(f"stop agent {ids['agent_name']} in {ids['impl_pane']} (ctrl+c x2)", ["bash", "-c", f"herdr agent send-keys {ids['agent_name']} ctrl+c; sleep 0.5; herdr agent send-keys {ids['agent_name']} ctrl+c"])
    else: print(f"   agent {ids.get('agent_name')} not live in {ids['impl_pane']}; nothing to stop")
    # 2. orchestrator tab (launcher-created, label == task) or else just the planner pane
    tab = tabs.get(ids.get("orchestrator_tab") or "")
    if tab and ids.get("orchestrator_tab_created_by_launcher") and tab.get("label") == task:
        act(f"close orchestrator tab {tab['tab_id']} (label {task}; includes planner pane {ids['planner_pane']})", ["herdr", "tab", "close", tab["tab_id"]])
    else:
        p = panes.get(ids["planner_pane"])
        if p and p.get("label") in (f"planner-{task}", "planner") and p.get("cwd", "").startswith(wt):
            act(f"close planner pane {p['pane_id']}", ["herdr", "pane", "close", p["pane_id"]])
        else: print(f"   planner pane/orchestrator tab not live or not matching; skip")
    # 3. worktree workspace (verify it is linked to the recorded path)
    w = ws.get(ids["worktree_workspace"])
    if w and (w.get("worktree") or {}).get("checkout_path") == wt:
        if git(wt, "status", "--porcelain").strip():  # uncommitted work would be lost by --force: snapshot it first
            act(f"save uncommitted changes to runs/{task}/cleanup-wip.patch", ["bash", "-c",
                f"cd '{wt}' && git add -A && git diff --cached HEAD -- . ':!*__pycache__*' > '{LAB}/runs/{task}/cleanup-wip.patch'; git reset -q"])
        act(f"herdr worktree remove --workspace {w['workspace_id']} --force ({wt})", ["herdr", "worktree", "remove", "--workspace", w["workspace_id"], "--force"])
    elif os.path.isdir(wt): print(f"   workspace {ids['worktree_workspace']} not live/matching; leaving dir {wt} for manual review")
    else: print(f"   worktree {wt} already gone")
    repo = ids["repo"]
    act(f"git worktree prune in {repo}", ["git", "-C", repo, "worktree", "prune"])
    agy_untrust(wt)
    if DELB and git(repo, "branch", "--list", ids["branch"]).strip():
        act(f"delete branch {ids['branch']}", ["git", "-C", repo, "branch", "-D", ids["branch"]])
    else: print(f"   branch {ids['branch']} kept")
    print(f"   artifacts kept: {os.path.join(LAB,'runs',task)}")

def clean_legacy():
    print("== legacy t1 fanout worktrees"); ws, _, _ = live(); repo = os.path.join(LAB, "sample-repo")
    for a in ("droid", "agy", "amp"):
        path = os.path.expanduser(f"~/.herdr/worktrees/sample-repo/agent-{a}-t1")
        w = next((w for w in ws.values() if w.get("label") == f"{a}-t1" and (w.get("worktree") or {}).get("checkout_path") == path), None)
        if w: act(f"herdr worktree remove --workspace {w['workspace_id']} --force ({path})", ["herdr", "worktree", "remove", "--workspace", w["workspace_id"], "--force"])
        else: print(f"   no matching live workspace for {a}-t1")
        if DELB and git(repo, "branch", "--list", f"agent/{a}-t1").strip():
            act(f"delete branch agent/{a}-t1", ["git", "-C", repo, "branch", "-D", f"agent/{a}-t1"])
    act("git worktree prune", ["git", "-C", repo, "worktree", "prune"])

if ALL:
    tasks = sorted(d for d in os.listdir(os.path.join(LAB, "runs")) if os.path.isdir(os.path.join(LAB, "runs", d)) and
                   (os.path.exists(os.path.join(LAB, "runs", d, "herdr-ids.json")) or os.path.exists(os.path.join(LAB, "runs", d, "trace.md"))))
for t in tasks: clean_task(t)
if LEG: clean_legacy()
