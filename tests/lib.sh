# shared helpers for agents-lab stub tests
LABDIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd); L="$LABDIR/lab_tools.py"; P="$LABDIR/pipeline.sh"
T=$(mktemp -d /tmp/labtest.XXXXXX); trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT
set -a; source "$LABDIR/pipeline.conf" >/dev/null 2>&1; set +a
PASS=0; FAILN=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAILN=$((FAILN+1)); echo "  FAIL $1"; }
eq()  { [ "$2" = "$3" ] && ok "$1" || bad "$1 (got '$2', want '$3')"; }
has() { grep -qE -- "$3" <<< "$2" && ok "$1" || bad "$1 (missing /$3/)"; }
hasnt() { grep -qE -- "$3" <<< "$2" && bad "$1 (unexpected /$3/)" || ok "$1"; }
fx()  { awk -v s="$1" 'index($0,s)==1{f=1} f{print} f&&/^}$/{exit}' "$P"; }   # extract a top-level bash function from pipeline.sh
mkrepo() { mkdir -p "$1" && git -C "$1" init -q && (cd "$1" && eval "$2") && git -C "$1" add -A && git -C "$1" -c user.email=t@t -c user.name=t commit -qm base; }
finish() { echo "  -> $PASS passed, $FAILN failed"; [ "$FAILN" = 0 ]; }
