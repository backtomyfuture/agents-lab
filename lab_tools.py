#!/usr/bin/env python3
"""agents-lab helpers (v3.2).
  stubs_check SPEC                           -> exit 0 iff spec has a valid '## Interface Stubs' section
  gen_stubs SPEC WT                          -> create NotImplementedError stubs listed in Interface Stubs (prints files)
  s2ctx SPEC WT                              -> public signatures of stub target modules + head of one existing test file
  family AGENT MODEL                         -> model family
  s1chain --impl A:M --paid 0|1              -> ordered S1 fallback candidates (agent:model:effort), impl family excluded
  resolve --impl A:M --s1 A:M --tests A:M:E --impl2 A:M:E --reviewers M,M,M --paid 0|1
                                             -> shell assignments (TESTS_*, IMPL2_*, RESOLVE_*) honouring family rules
  adjudicator --s2 A:M --impl A:M --impl2 A:M --cands A:M:E,...   -> first candidate of a third family
  redact HIDDEN IN OUT [N]                   -> copy IN to OUT, redacting lines sharing an N-word n-gram (default 6) with HIDDEN
  leftovers SHELLPID                         -> descendants of the pane shell other than the agent process tree's long-lived helpers (pid<TAB>cmd)
  redcheck LOG                               -> exit 0 iff red run has >=1 failure and only AssertionError/NotImplementedError
"""
import re, sys

FAMILIES = [  # (regex on model id, family)
    (r'^gemini', 'gemini'), (r'^grok', 'xai'), (r'^(gpt|o\d|codex)', 'openai'), (r'^claude', 'anthropic'),
    (r'^glm', 'zhipu'), (r'^qwen', 'qwen'), (r'^kimi', 'moonshot'), (r'^deepseek', 'deepseek'),
    (r'^minimax', 'minimax')]
def family(agent, model):
    if agent == 'amp': return 'anthropic'   # Amp smart modes route to Claude by default (assumption, see DESIGN)
    for rx, f in FAMILIES:
        if re.match(rx, model or ''): return f
    return 'gemini' if agent == 'agy' else 'unknown:' + (model or agent)

import os
def _models(var, default):  # model ids live in pipeline.conf (exported); built-in defaults only if unset
    v = os.environ.get(var)
    if not v: print(f'lab_tools: {var} not set, using built-in default', file=sys.stderr)
    return (v or default).split()
PAID = [('droid', m, 'high') for m in _models('LAB_PAID_MODELS', 'claude-sonnet-5-5 gpt-6.1-sol')]
CORE = [('droid', m, 'high') for m in _models('LAB_CORE_MODELS', 'kimi-k3 glm-5.3')]
GROK_ID = _models('LAB_GROK_MODEL', 'grok-4.7')[0]
GROK = [('grok', GROK_ID, 'high')]
EXTRA_IMPL2 = [('droid', m, '') for m in _models('LAB_EXTRA_IMPL2_MODELS', 'deepseek-v4.1-flash')]

def parse(s, n=3):
    p = (s or '').split(':'); p += [''] * (n - len(p)); return tuple(p[:n])

def args(argv):
    d = {}; i = 0
    while i < len(argv):
        if argv[i].startswith('--'): d[argv[i][2:]] = argv[i + 1]; i += 2
        else: i += 1
    return d

def s1chain(a):
    imp = family(*parse(a['impl'], 2)); paid = a.get('paid', '1') == '1'
    for c in (PAID if paid else []) + CORE + GROK:
        if family(c[0], c[1]) != imp: print(':'.join(c))

def resolve(a):
    imp = family(*parse(a['impl'], 2)); s1 = family(*parse(a['s1'], 2)); paid = a.get('paid', '1') == '1'
    revs = {family('droid', m) for m in a.get('reviewers', '').split(',') if m}
    out, notes = {}, []
    t_cfg = parse(a['tests']); t_eff = t_cfg[2] or 'medium'
    tests_pool = [t_cfg] + [(x[0], x[1], t_eff) for x in CORE + (PAID if paid else []) + GROK]
    i2_cfg = parse(a['impl2'])
    i2_pool = [i2_cfg, ('grok', GROK_ID, 'xhigh')] + [(x[0], x[1], 'high') for x in (PAID[::-1] if paid else []) + CORE] + EXTRA_IMPL2
    def pick(pool, hard, soft):
        ok = [c for c in pool if family(c[0], c[1]) not in hard]
        best = [c for c in ok if family(c[0], c[1]) not in soft]
        return (best or ok or [None])[0], bool(best)
    t, clean = pick(tests_pool, {imp}, {s1})   # hard: S2 != S3
    if t is None: print('RESOLVE_FAIL=1'); print("RESOLVE_NOTE='no S2 candidate outside implementer family'"); return
    if t != t_cfg: notes.append(f'S2 {":".join(t_cfg[:2])} -> {":".join(t[:2])} (family rule)')
    if not clean: notes.append('S2 shares family with S1 (soft rule relaxed)')
    tf = family(t[0], t[1])
    # v3.2: hard = IMPL2 != implementer and != every reviewer/judge family (S5/S6/S8); soft = != S1/S2.
    # Pool order is the preference (configured, then grok xhigh), so the first hard-eligible candidate wins.
    hard_ok = [c for c in i2_pool if family(c[0], c[1]) not in ({imp} | revs)]
    i2 = hard_ok[0] if hard_ok else None
    clean2 = bool(i2) and family(i2[0], i2[1]) not in {s1, tf}
    if i2 is None:
        notes.append('no escalation implementer outside {impl,S5,S6,S8} families -> escalation goes to human')
        out.update(IMPL2_AGENT='none', IMPL2_MODEL='none', IMPL2_EFFORT='')
    else:
        if i2 != i2_cfg: notes.append(f'IMPL2 {":".join(i2_cfg[:2])} -> {":".join(i2[:2])} (family rule)')
        if not clean2: notes.append('IMPL2 shares family with S1/S2 (soft rule relaxed)')
        out.update(IMPL2_AGENT=i2[0], IMPL2_MODEL=i2[1], IMPL2_EFFORT=i2[2])
    out.update(TESTS_AGENT=t[0], TESTS_MODEL=t[1], TESTS_EFFORT=t[2])
    fams = {'S1': s1, 'S2': tf, 'S3': imp, 'S3-escalation': family(out['IMPL2_AGENT'], out['IMPL2_MODEL']) if i2 else 'human', 'reviewers': ','.join(sorted(revs))}
    for k, v in out.items(): print(f"{k}='{v}'")
    print(f"RESOLVE_FAMILIES='{' '.join(f'{k}={v}' for k, v in fams.items())}'")
    print(f"RESOLVE_NOTE='{'; '.join(notes) or 'configured assignment satisfies all family rules'}'"); print('RESOLVE_FAIL=0')

def adjudicator(a):
    bad = {family(*parse(a[k], 2)) for k in ('s2', 'impl', 'impl2') if a.get(k)}
    for c in a['cands'].split(','):
        p = parse(c)
        if p[1] and family(p[0], p[1]) not in bad: print(':'.join(p)); return
    sys.exit(1)

def words(t): return re.findall(r'[\w\u4e00-\u9fff]+', t.lower())
PREFIX = re.compile(r'^\s*(?:BLOCKING|SUGGESTION):\s*\[[^\]]*\]\s*\(ref:[^)]*\)\s*')
def redact(hidden, inp, outp, n=6, public=()):
    """n-grams = hidden minus (spec U acceptance); keep the 'BLOCKING: [cat] (ref: id)' prefix, replace only leaked spans."""
    def grams(t):
        w = words(t); return {tuple(w[i:i + n]) for i in range(len(w) - n + 1)}
    pub = set()
    for f in public:
        try: pub |= grams(open(f, encoding='utf-8', errors='replace').read())
        except OSError: pass
    hg = grams(open(hidden, encoding='utf-8', errors='replace').read()) - pub
    out, cnt = [], 0
    for line in open(inp, encoding='utf-8', errors='replace'):
        m = PREFIX.match(line); start = m.end() if m else 0
        toks = [(x.start() + start, x.end() + start, x.group().lower()) for x in re.finditer(r'[\w\u4e00-\u9fff]+', line[start:])]
        cover = [False] * len(toks)
        for i in range(len(toks) - n + 1):
            if tuple(t[2] for t in toks[i:i + n]) in hg:
                for j in range(i, i + n): cover[j] = True
        if not any(cover): out.append(line); continue
        cnt += 1; res, pos, i = [], 0, 0
        while i < len(toks):
            if cover[i]:
                j = i
                while j + 1 < len(toks) and cover[j + 1]: j += 1
                res.append(line[pos:toks[i][0]]); res.append('[REDACTED_HIDDEN_DETAIL]'); pos = toks[j][1]; i = j + 1
            else: i += 1
        res.append(line[pos:]); out.append(''.join(res))
    open(outp, 'w', encoding='utf-8').writelines(out); print(cnt)

def redcheck(log):
    t = open(log, encoding='utf-8', errors='replace').read()
    excs = re.findall(r'^(\w+(?:\.\w+)*(?:Error|Exception|Exit)):?', t, re.M)
    excs = [e.split('.')[-1] for e in excs]
    nfail = len(re.findall(r'^(FAIL|ERROR): ', t, re.M))
    # semantics: run must be RED (nonzero exit), >=1 failure, only Assertion/NotImplemented, 0 collection errors.
    # NOT 'all tests fail': passing tests (e.g. for existing behaviour) are allowed.
    nonzero = re.search(r'^FAILED \(', t, re.M) or re.search(r'^tests_rc=[1-9]', t, re.M)
    bad = [e for e in excs if e not in ('AssertionError', 'NotImplementedError')]
    collection = re.search(r'^ERROR: .*(unittest\.loader|_FailedTest)', t, re.M) or 'ImportError' in excs or 'ModuleNotFoundError' in excs
    print(f'failures={nfail} exceptions={sorted(set(excs))} bad={sorted(set(bad))}')
    sys.exit(0 if nonzero and nfail > 0 and not bad and not collection else 1)

STUB_LINE = re.compile(r'^-\s+`?([\w./-]+\.py)`?\s*::\s*`?((?:async\s+)?def\s+\w+\s*\(.*\)(?:\s*->\s*[^:`]+)?|class\s+\w+(?:\([^)]*\))?)\s*:?`?\s*$')
def stub_section(spec):
    t = open(spec, encoding='utf-8', errors='replace').read()
    m = re.search(r'^##\s*Interface Stubs\s*$(.*?)(?=^##\s|\Z)', t, re.M | re.S | re.I)
    if not m: return None, ['missing section ## Interface Stubs']
    lines = [l.strip() for l in m.group(1).splitlines() if l.strip()]
    if lines and all(re.match(r'^-\s*NONE\b', l, re.I) for l in lines): return [], []
    items, errs = [], []
    for l in lines:
        x = STUB_LINE.match(l)
        if not x: errs.append(f'bad stub line: {l[:100]}'); continue
        path, sig = x.group(1), x.group(2).strip()
        if path.startswith('/') or '..' in path.split('/'): errs.append(f'path not relative/safe: {path}'); continue
        try: stub_code(sig)
        except SyntaxError as e: errs.append(f'stub signature does not parse: {sig[:80]} ({e.msg})'); continue
        items.append((path, sig))
    if not items and not errs: errs.append('empty Interface Stubs section (use "- NONE (existing entrypoint only)")')
    return items, errs
def stubs_check(spec):
    items, errs = stub_section(spec)
    for e in errs: print(e)
    sys.exit(1 if errs else 0)
def stub_code(sig):
    import ast
    if sig.startswith('class'):
        code = f'{sig}:\n    def __init__(self, *args, **kwargs):\n        raise NotImplementedError\n'
    else:
        code = f'{sig}:\n    raise NotImplementedError\n'
    ast.parse(code); return code
def gen_stubs(spec, wt):
    import ast, os
    items, errs = stub_section(spec)
    if errs: [print(e, file=sys.stderr) for e in errs]; sys.exit(1)
    touched = []
    for path, sig in items:
        f = os.path.join(wt, path); name = re.search(r'(?:def|class)\s+(\w+)', sig).group(1)
        src = open(f, encoding='utf-8').read() if os.path.exists(f) else ''
        if src:
            tree = ast.parse(src)
            if any(getattr(n, 'name', None) == name for n in tree.body): continue
        os.makedirs(os.path.dirname(f) or '.', exist_ok=True)
        new = (src.rstrip('\n') + '\n\n\n' if src else '') + stub_code(sig)
        ast.parse(new); open(f, 'w', encoding='utf-8').write(new)
        if path not in touched: touched.append(path)
    print(' '.join(touched))
def s2ctx(spec, wt):
    import ast, os, subprocess
    items, _ = stub_section(spec)
    mods = sorted({p for p, _ in (items or [])})
    for p in mods:
        f = os.path.join(wt, p)
        if not os.path.exists(f): continue
        print(f'### public signatures: {p}')
        for n in ast.parse(open(f, encoding='utf-8').read()).body:
            if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)) and not n.name.startswith('_'):
                print(ast.get_source_segment(open(f, encoding='utf-8').read(), n).split('\n')[0])
    tf = [l for l in subprocess.run(['git', '-C', wt, 'ls-files'], capture_output=True, text=True).stdout.split() if re.search(r'(^|/)test[^/]*\.py$', l)]
    if tf:
        print(f'### existing test style: head of {tf[0]}')
        print(''.join(open(os.path.join(wt, tf[0]), encoding='utf-8').readlines()[:40]))

# ---------------- v3.3 ----------------
REQ_SECTIONS = ['Requirements', 'Interface', 'Test plan', 'Limits & Input domain', 'Interface Stubs']
def spec_sections(spec):
    """exit 1 if a required section is missing or has no content line (empty sections no longer pass)."""
    t = open(spec, encoding='utf-8', errors='replace').read(); errs = []
    for name in REQ_SECTIONS:
        m = re.search(r'^##\s*' + re.escape(name) + r'(?![\w ]*Stubs)[^\n]*\n(.*?)(?=^##\s|\Z)', t, re.M | re.S | re.I) if name == 'Interface' else \
            re.search(r'^##\s*' + re.escape(name) + r'[^\n]*\n(.*?)(?=^##\s|\Z)', t, re.M | re.S | re.I)
        if not m: errs.append(f'missing section: {name}'); continue
        # heuristic: placeholder-only lines (EN + ZH) do not count; >= SPEC_MIN_CHARS non-space chars required
        ph = r'\s*(?:[-*]\s*)?(?:TBD|TODO|N/?A|none|\.\.\.|…|待定|待补充|暂无|无)?\s*[.。]?\s*'
        body = [l for l in m.group(1).splitlines() if l.strip() and not re.fullmatch(ph, l, re.I)]
        if not body or len(re.sub(r'\s', '', ''.join(body))) < int(os.environ.get('SPEC_MIN_CHARS', '15')): errs.append(f'empty section: {name}')
    for e in errs: print(e)
    sys.exit(1 if errs else 0)

def public_ids(spec, acc):
    ids = set()
    for f in (spec, acc):
        try: t = open(f, encoding='utf-8', errors='replace').read()
        except OSError: continue
        ids |= set(re.findall(r'^\s*(?:[-*]\s*)?\**([A-Z]{1,3}\d+)\b', t, re.M))
        if f == spec:
            m = re.search(r'^##\s*Requirements[^\n]*\n(.*?)(?=^##\s|\Z)', t, re.M | re.S | re.I)
            if m: ids |= {f'R{n}' for n in re.findall(r'^\s*(\d+)\.', m.group(1), re.M)}
    return ids

BLK = re.compile(r'^(\s*)BLOCKING:\s*\[([^\]]*)\]\s*\(ref:\s*([^)]*)\)\s*(.*)$')
REPRO = re.compile(r'repro(?:duce)?[^`]*`([^`]+)`', re.I)
SANDBOX_RO = ['/usr', '/bin', '/sbin', '/lib', '/lib64', '/etc/alternatives', '/etc/ld.so.cache', '/etc/localtime', '/etc/passwd', '/etc/group']
def sandbox_cmd(src, cmd, timeout=30):
    """bubblewrap: ONLY system dirs read-only + SRC read-only at /work, writable tmpfs /tmp, no $HOME, no private dir, no network.
    Returns None when bwrap is unavailable -> callers must fail closed (never run unsandboxed)."""
    import shutil
    if not shutil.which('bwrap'): return None
    a = ['timeout', str(timeout), 'bwrap', '--unshare-all', '--die-with-parent', '--new-session', '--clearenv',
         '--setenv', 'PATH', '/usr/bin:/bin', '--setenv', 'HOME', '/tmp', '--setenv', 'PYTHONDONTWRITEBYTECODE', '1',
         '--proc', '/proc', '--dev', '/dev', '--tmpfs', '/tmp']
    for d in SANDBOX_RO: a += ['--ro-bind-try', d, d]
    return a + ['--ro-bind', src, '/work', '--chdir', '/work', 'bash', '-c', cmd]

def _snapshot(wt):
    """read-only snapshot copy of the worktree (tracked + untracked, no .git/__pycache__) outside /tmp."""
    import tempfile, shutil
    d = tempfile.mkdtemp(prefix='lab-sbx-', dir=os.environ.get('LAB_SANDBOX_DIR', '/var/tmp'))
    cp = os.path.join(d, 'wt'); shutil.copytree(wt, cp, ignore=shutil.ignore_patterns('.git', '__pycache__')); return d, cp

ENV_FAIL = re.compile(r'^bwrap:|No such file or directory: .bwrap|Operation not permitted|Permission denied.*(?:/proc|namespace)', re.M)
def sandbox_run(wt, cmd, timeout=30):
    """-> (status, rc, output); status in ok | unverified (bwrap missing/failed to start, env error, timeout)."""
    import subprocess, shutil
    d, cp = _snapshot(wt)
    try:
        a = sandbox_cmd(cp, cmd, timeout)
        if a is None: return 'unverified', None, 'bwrap not available (fail-closed: not run)'
        p = subprocess.run(a, capture_output=True, text=True, timeout=timeout + 15)
        out = p.stdout + p.stderr
        if p.returncode in (124, 125, 126, 127) or ENV_FAIL.search(p.stderr): return 'unverified', p.returncode, out
        return 'ok', p.returncode, out
    except Exception as e: return 'unverified', None, str(e)
    finally: shutil.rmtree(d, ignore_errors=True)

def ground(review, spec, acc, wt, run_repro='1'):
    """BLOCKING refs must be public spec/acceptance ids (else -> SUGGESTION); run each repro once in the sandbox and attach the result."""
    import subprocess
    ids = public_ids(spec, acc); lines = open(review, encoding='utf-8', errors='replace').read().splitlines(True)
    res, down, ran = [], 0, 0
    for l in lines:
        m = BLK.match(l.rstrip('\n'))
        if not m or '[orchestrator' in l: res.append(l); continue
        refs = [r.strip() for r in re.split(r'[,/ ]+', m.group(3)) if r.strip()]
        if not [r for r in refs if r in ids]:
            res.append(f'{m.group(1)}SUGGESTION: [{m.group(2)}] (ref: {m.group(3)}) {m.group(4)}  [orchestrator: downgraded from BLOCKING - ref not a public spec/acceptance id]\n'); down += 1; continue
        res.append(l if l.endswith('\n') else l + '\n')
        r = REPRO.search(m.group(4))
        if r and run_repro == '1':  # informational only: a repro result never changes BLOCKING status (fail-closed)
            st, rc, out = sandbox_run(wt, r.group(1))
            o = ' | '.join(out.strip().splitlines()[-4:])[:300]
            if st == 'ok': res.append(f'{m.group(1)}  [orchestrator repro rc={rc} (bwrap: snapshot ro, no HOME/private dir, no network, 30s)]: {o}\n')
            else: res.append(f'{m.group(1)}  [orchestrator: repro unverified ({o[:160]}) - finding stays BLOCKING]\n')
            ran += 1
    open(review, 'w', encoding='utf-8').writelines(res)
    print(f'downgraded={down} repro_ran={ran} known_ids={len(ids)}')

def parse_verdict(f):
    """Structured ```json {verdict, blocking:[{ref,category,desc,repro}]}``` (last block) preferred and validated.
    Text fallback: 'VERDICT: X' must be the LAST non-empty line (a VERDICT quoted mid-text, e.g. from tool output, is ignored)."""
    import json
    t = open(f, encoding='utf-8', errors='replace').read() if os.path.exists(f) else ''
    blocks = re.findall(r'```json\s*(\{.*?\})\s*```', t, re.S)
    if blocks:
        try:
            d = json.loads(blocks[-1]); v = str(d.get('verdict', '')).upper(); b = d.get('blocking', [])
            ok = v in ('APPROVE', 'REJECT') and isinstance(b, list) and all(isinstance(x, dict) and x.get('ref') and x.get('desc') for x in b) \
                 and ((v == 'REJECT') == bool(b))
            if ok:
                add = [f"BLOCKING: [{x.get('category', 'general')}] (ref: {x['ref']}) {x['desc']}" + (f" repro: `{x['repro']}`" if x.get('repro') else '')
                       for x in b if f"(ref: {x['ref']}) {x['desc']}" not in t]
                if add or not re.search(r'VERDICT:\s*' + v + r'\s*$', t.strip()):
                    open(f, 'w', encoding='utf-8').write(t.rstrip('\n') + '\n' + ''.join(a + '\n' for a in add) + f'VERDICT: {v}\n')
                print(v); return
            print('invalid json verdict block -> text fallback', file=sys.stderr)
        except Exception as e: print(f'json verdict parse error ({e}) -> text fallback', file=sys.stderr)
    last = [l.strip() for l in t.splitlines() if l.strip()]
    m = re.fullmatch(r'[*`]*VERDICT:\s*(APPROVE|REJECT)[*`.]*', last[-1]) if last else None
    print(m.group(1) if m else '')

MUTS = [(r'<=', '<'), (r'>=', '>'), (r'(?<![<>=!-])<(?![<=])', '<='), (r'(?<![<>=!-])>(?![>=])', '>='), (r'==', '!='), (r'!=', '=='),
        (r'\bTrue\b', 'False'), (r'\bFalse\b', 'True'), (r'(?<![+\-*/=])\+(?![+=])', '-'), (r'\band\b', 'or'), (r'\bor\b', 'and')]
def mutate(wt, base, test_cmd, n='8', timeout='120'):
    """cheap mutation sampling on lines ADDED since BASE in non-test .py files, in a throwaway sandboxed copy (never the worktree)."""
    import subprocess, tempfile, shutil, random
    n, timeout = int(n), int(timeout)
    diff = subprocess.run(['git', '-C', wt, 'diff', '-U0', base, '--', '*.py'], capture_output=True, text=True).stdout
    cands, cur, ln = [], None, 0
    for l in diff.splitlines():
        if l.startswith('+++ '): cur = l[6:] if l.startswith('+++ b/') else None; continue
        h = re.match(r'^@@ -\S+ \+(\d+)', l)
        if h: ln = int(h.group(1)); continue
        if l.startswith('+') and cur and not re.search(r'(^|/)test[^/]*\.py$|^tests/', cur):
            code = l[1:].split('#')[0]; st = code.strip()
            if st and not st.startswith(('def ', 'class ', 'import ', 'from ', '"', "'", '@')):
                for i, (a, b) in enumerate(MUTS):
                    if re.search(a, code): cands.append((cur, ln, i))
            ln += 1
    random.Random(42).shuffle(cands); cands = cands[:n]
    if not cands: print('mutants=0 killed=0 score=n/a'); return
    killed, survived = 0, []
    with tempfile.TemporaryDirectory() as d:
        cp = os.path.join(d, 'wt'); shutil.copytree(wt, cp, ignore=shutil.ignore_patterns('.git', '__pycache__'))
        for f, ln, i in cands:
            path = os.path.join(cp, f); orig = open(path, encoding='utf-8').read(); L = orig.splitlines(True)
            a, b = MUTS[i]; L[ln - 1] = re.sub(a, b, L[ln - 1], count=1)
            try:
                open(path, 'w', encoding='utf-8').write(''.join(L))
                rc = subprocess.run(['timeout', str(timeout), 'bash', '-c', f'cd "{cp}" && PYTHONDONTWRITEBYTECODE=1 {test_cmd}'], capture_output=True).returncode
            finally: open(path, 'w', encoding='utf-8').write(orig)
            if rc != 0: killed += 1
            else: survived.append(f'{f}:{ln} {a} -> {b}')
    print(f'mutants={len(cands)} killed={killed} score={killed / len(cands):.2f}')
    for x in survived: print(f'survived {x}')

def hidden_tests(wt, tests, full_out, timeout='300'):
    """run private executable hidden tests on a sandboxed snapshot; full output -> private file, summary -> stdout. rc 2 = could not run (fail-closed)."""
    import shutil, tempfile
    d = tempfile.mkdtemp(prefix='lab-hid-', dir=os.environ.get('LAB_SANDBOX_DIR', '/var/tmp'))
    try:
        cp = os.path.join(d, 'wt'); shutil.copytree(wt, cp, ignore=shutil.ignore_patterns('.git', '__pycache__'))
        shutil.copy(tests, os.path.join(cp, 'test_zz_hidden_private.py'))
        st, rc, out = sandbox_run(cp, 'python3 -m unittest test_zz_hidden_private -v', int(timeout))
    finally: shutil.rmtree(d, ignore_errors=True)
    open(full_out, 'w').write(out)
    if st != 'ok': print('HIDDEN_TESTS unverified (sandbox could not run them)'); sys.exit(2)
    ran = re.search(r'^Ran (\d+) test', out, re.M); fails = re.search(r'^FAILED \((.*)\)', out, re.M)
    print(f'HIDDEN_TESTS rc={rc} ran={ran.group(1) if ran else 0} ' + (f'failed({fails.group(1)})' if fails else 'passed' if rc == 0 else 'error'))
    sys.exit(0 if rc == 0 else 1)

def rules_merge(store, retro, today, expire_after='10', cap='30'):
    """deterministic rule store for AGENTS.md proposals: dedupe (normalized), flag always/never conflicts, expire rules not re-proposed in N merges, cap."""
    import json
    rules = json.load(open(store)) if os.path.exists(store) else {'merges': 0, 'rules': []}
    rules['merges'] += 1; m = rules['merges']
    t = open(retro, encoding='utf-8', errors='replace').read()
    sec = re.search(r'^##\s*Proposed AGENTS\.md rules[^\n]*\n(.*?)(?=^##\s|\Z)', t, re.M | re.S | re.I)
    new = [re.sub(r'^\s*(?:[-*]|\d+\.)\s*', '', l).strip() for l in (sec.group(1).splitlines() if sec else []) if re.match(r'^\s*(?:[-*]|\d+\.)\s+\S', l)]
    neg = re.compile(r"\b(never|do not|don't|must not|avoid)\b", re.I)
    norm = lambda x: ' '.join(w for w in words(neg.sub(' ', x)) if w not in ('always', 'must', 'should', 'the', 'a', 'an'))
    added = dup = conf = 0
    for r in new:
        k = norm(r); hit = next((x for x in rules['rules'] if x['key'] == k), None)
        ks = set(k.split())
        for x in rules['rules']:  # conflict: near-identical subject (Jaccard >= 0.6) with opposite polarity
            xs = set(x['key'].split())
            if x is not hit and ks and xs and len(ks & xs) / len(ks | xs) >= 0.6 and bool(neg.search(r)) != bool(neg.search(x['text'])):
                x['conflict'] = r; conf += 1
        if hit:
            hit['last_merge'] = m; hit['count'] += 1; dup += 1
            if bool(neg.search(r)) != bool(neg.search(hit['text'])): hit['conflict'] = r; conf += 1
        else: rules['rules'].append({'key': k, 'text': r, 'first': today, 'last_merge': m, 'count': 1}); added += 1
    exp = 0  # no auto-deletion: rules not re-proposed in N merges are only FLAGGED stale for a human
    for x in rules['rules']:
        x['stale'] = m - x['last_merge'] >= int(expire_after); exp += x['stale']
    rules['rules'].sort(key=lambda x: (x['stale'], -x['count'], x['first']))
    json.dump(rules, open(store, 'w'), indent=1)
    open(os.path.splitext(store)[0] + '.md', 'w').write(
        f'# Proposed AGENTS.md rules (lab_tools.py rules_merge: dedupe, conflicts + stale flagged for a human, top {cap} shown, nothing auto-deleted)\n'
        + ''.join(f"- {x['text']}" + (f"  <!-- CONFLICT: {x['conflict']} -->" if x.get('conflict') else '') + ('  <!-- STALE: not re-proposed in %s merges -->' % expire_after if x['stale'] else '') + '\n' for x in rules['rules'][:int(cap)]))
    print(f'proposed={len(new)} added={added} duplicates={dup} conflicts={conf} stale={exp} total={len(rules["rules"])}')

def orphans(lab, protected='t1 t2 t6 t7'):
    """report (never delete) pipeline worktrees whose run never finished and has no live pipeline process."""
    import subprocess
    prot = set(protected.split()); ps = subprocess.run(['ps', '-eo', 'args='], capture_output=True, text=True).stdout
    wts = subprocess.run(['git', '-C', os.path.join(lab, 'sample-repo'), 'worktree', 'list', '--porcelain'], capture_output=True, text=True).stdout
    for wt in re.findall(r'^worktree (.*)$', wts, re.M):
        name = os.path.basename(wt)
        if '/wt/' not in wt and not name.startswith('agent-'): continue
        task = re.sub(r'^agent-(droid|agy|amp)-', '', name)
        tr = os.path.join(lab, 'runs', name, 'trace.md')
        done = os.path.exists(tr) and '## Result' in open(tr, errors='replace').read()
        live = re.search(r'pipeline\.sh \S+ ' + re.escape(name) + r'(\s|$)', ps)
        state = 'running' if live else 'finished' if done else 'ORPHAN'
        print(f'{wt}\t{state}\t{"protected" if task in prot else "-"}')

HELPER = re.compile(r'(^|/)(grok|droid|agy|amp|antigravity)(\s|$)|leader|daemon|mcp|language[_-]server|lsp|node .*(amp|droid|grok)|gopls|pyright', re.I)
def leftovers(shell, ps_text=None):
    import subprocess
    ps_text = ps_text or subprocess.run(['ps', '-eo', 'pid=,ppid=,args='], capture_output=True, text=True).stdout
    kids = {}
    for l in ps_text.splitlines():
        p = l.split(None, 2)
        if len(p) >= 2: kids.setdefault(p[1], []).append((p[0], p[2] if len(p) > 2 else ''))
    out = []
    agents = []
    for pid, cmd in kids.get(str(shell), []):
        (agents if HELPER.search(cmd) else out).append(pid if HELPER.search(cmd) else (pid, cmd))
    def walk(pid):
        for c, cmd in kids.get(pid, []):
            if not HELPER.search(cmd): out.append((c, cmd))
            walk(c)
    for a in agents: walk(a)
    for c, cmd in out: print(f'{c}\t{cmd[:120]}')

if __name__ == '__main__':
    c, a = sys.argv[1], args(sys.argv[2:])
    if c == 'family': print(family(sys.argv[2], sys.argv[3]))
    elif c == 's1chain': s1chain(a)
    elif c == 'resolve': resolve(a)
    elif c == 'adjudicator': adjudicator(a)
    elif c == 'redact': redact(sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5]) if len(sys.argv) > 5 else 6, tuple(sys.argv[6:]))
    elif c == 'stubs_check': stubs_check(sys.argv[2])
    elif c == 'spec_sections': spec_sections(sys.argv[2])
    elif c == 'ground': ground(*sys.argv[2:])
    elif c == 'parse_verdict': parse_verdict(sys.argv[2])
    elif c == 'mutate': mutate(*sys.argv[2:])
    elif c == 'hidden_tests': hidden_tests(*sys.argv[2:])
    elif c == 'rules_merge': rules_merge(*sys.argv[2:])
    elif c == 'orphans': orphans(*sys.argv[2:])
    elif c == 'gen_stubs': gen_stubs(sys.argv[2], sys.argv[3])
    elif c == 's2ctx': s2ctx(sys.argv[2], sys.argv[3])
    elif c == 'redcheck': redcheck(sys.argv[2])
    elif c == 'leftovers': leftovers(sys.argv[2], open(sys.argv[3]).read() if len(sys.argv) > 3 else None)
