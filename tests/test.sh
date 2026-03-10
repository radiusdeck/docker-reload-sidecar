#!/usr/bin/env bash
set -euo pipefail

# ── resolve project root (works from any directory) ───────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

IMAGE="reload-sidecar:local"
TARGET="test-target-$$"
SIDECAR="reload-sidecar-$$"
TOKEN="test-token-$$"
PASS=0
FAIL=0

# ── helpers ───────────────────────────────────────────────
cleanup() {
    docker rm -f "$SIDECAR" "$TARGET" 2>/dev/null || true
}
trap cleanup EXIT

ok()   { PASS=$((PASS + 1)); echo "  ✅ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }

assert_eq() {
    local actual="$1" expected="$2" msg="$3"
    if [ "$actual" = "$expected" ]; then
        ok "$msg"
    else
        fail "$msg (expected='$expected', got='$actual')"
    fi
}

http_json() {
    local method="$1" url="$2" ; shift 2
    curl -s -X "$method" "$@" "$url" 2>/dev/null || echo '{"error":"curl_failed"}'
}

jq_val() { echo "$1" | python3 -c "import sys,json; print(json.load(sys.stdin).get('$2',''))"; }

# ── build ─────────────────────────────────────────────────
echo "=== Building image ==="
docker build -t "$IMAGE" "$PROJECT_ROOT" -q

# ── test 1: restart mode ─────────────────────────────────
echo ""
echo "=== Test 1: restart mode ==="
docker run -d --name "$TARGET" nginx:alpine > /dev/null
sleep 1
UPTIME_BEFORE=$(docker inspect --format '{{.State.StartedAt}}' "$TARGET")

docker run -d --name "$SIDECAR" \
  -p 9090:9090 \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  -e TARGET_CONTAINER="$TARGET" \
  -e RELOAD_MODE=restart \
  -e RELOAD_TOKEN="$TOKEN" \
  "$IMAGE" > /dev/null
sleep 1

# health
RESP=$(http_json GET http://localhost:9090/health)
assert_eq "$(jq_val "$RESP" status)" "ok" "health returns ok"
assert_eq "$(jq_val "$RESP" target_running)" "True" "target is running"

# reload without token
RESP=$(http_json POST http://localhost:9090/reload)
assert_eq "$(jq_val "$RESP" error)" "forbidden" "no token → 403"

# reload with token
RESP=$(http_json POST http://localhost:9090/reload -H "Authorization: Bearer $TOKEN")
assert_eq "$(jq_val "$RESP" ok)" "True" "reload succeeds"
sleep 2

UPTIME_AFTER=$(docker inspect --format '{{.State.StartedAt}}' "$TARGET")
if [ "$UPTIME_BEFORE" != "$UPTIME_AFTER" ]; then
    ok "container was restarted (StartedAt changed)"
else
    fail "container was NOT restarted"
fi

cleanup

# ── test 2: signal mode ──────────────────────────────────
echo ""
echo "=== Test 2: signal mode ==="
docker run -d --name "$TARGET" nginx:alpine > /dev/null
sleep 1

docker run -d --name "$SIDECAR" \
  -p 9090:9090 \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  -e TARGET_CONTAINER="$TARGET" \
  -e RELOAD_MODE=signal \
  -e RELOAD_SIGNAL=HUP \
  "$IMAGE" > /dev/null
sleep 1

RESP=$(http_json POST http://localhost:9090/reload)
assert_eq "$(jq_val "$RESP" ok)" "True" "signal reload succeeds"
assert_eq "$(jq_val "$RESP" detail)" "signal HUP sent" "detail says HUP"

cleanup

# ── test 3: missing target ───────────────────────────────
echo ""
echo "=== Test 3: missing target ==="
docker run -d --name "$SIDECAR" \
  -p 9090:9090 \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  -e TARGET_CONTAINER=does-not-exist \
  "$IMAGE" > /dev/null
sleep 1

RESP=$(http_json GET http://localhost:9090/health)
assert_eq "$(jq_val "$RESP" target_running)" "False" "missing target → not running"

RESP=$(http_json POST http://localhost:9090/reload)
assert_eq "$(jq_val "$RESP" ok)" "False" "reload fails for missing target"

cleanup

# ── results ───────────────────────────────────────────────
echo ""
echo "==================================="
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
echo "==================================="

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi