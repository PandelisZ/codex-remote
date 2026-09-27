#!/usr/bin/env bash
# End-to-end test of the real provisioning pipeline against a throwaway Ubuntu container.
#
# It exercises everything except the provider API call itself: SSH bring-up, the apt and
# Node/Codex install, the systemd unit, the loopback app-server with token auth, the SSH
# tunnel, the generated launcher, and the ~/.ssh entry. Needs Docker; creates no cloud
# resources and costs nothing.
#
#   ./Scripts/integration-test.sh            run it
#   ./Scripts/integration-test.sh --keep     leave the container up afterwards
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAME="codex-remote-testbed"
MACHINE="itest"
PORT=2222
KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1

CTL="$ROOT/.build/debug/codex-remote"
pass() { printf '  \033[32m✓\033[0m %s\n' "$1"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAILURES=$((FAILURES + 1)); }
FAILURES=0

cleanup() {
  "$CTL" rm "$MACHINE" >/dev/null 2>&1 || true
  if [ "$KEEP" = "0" ]; then docker rm -f "$NAME" >/dev/null 2>&1 || true; fi
}
trap cleanup EXIT

echo "▸ build"
swift build --package-path "$ROOT" >/dev/null

echo "▸ unit tests"
swift test --package-path "$ROOT" 2>&1 | tail -2

echo "▸ testbed container"
docker build -q -t codex-remote-testbed "$ROOT/Scripts/testbed" >/dev/null
docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" --privileged --cgroupns=host \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw -p "127.0.0.1:$PORT:22" codex-remote-testbed >/dev/null

for _ in $(seq 1 30); do
  docker exec "$NAME" systemctl is-active ssh >/dev/null 2>&1 && break
  sleep 1
done

KEY="$HOME/.codex/codex-remote/keys/id_codex-remote"
[ -f "$KEY.pub" ] || { mkdir -p "$(dirname "$KEY")"; ssh-keygen -t ed25519 -N '' -C codex-remote -f "$KEY" >/dev/null; }
docker exec -i "$NAME" bash -c \
  'mkdir -p /root/.ssh && cat > /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys' < "$KEY.pub"

echo "▸ provision"
"$CTL" rm "$MACHINE" >/dev/null 2>&1 || true
"$CTL" adopt --host 127.0.0.1 --port "$PORT" --user root --name "$MACHINE" \
             --no-credential-sync --workspace /root/workspace

echo "▸ checks"
docker exec "$NAME" systemctl is-active codex-remote-codex >/dev/null 2>&1 \
  && pass "codex-remote-codex.service is active" || fail "codex-remote-codex.service is not active"

docker exec "$NAME" test -f /etc/codex-remote/appserver.token \
  && pass "app-server token is on the machine" || fail "no app-server token on the machine"

docker exec "$NAME" bash -c 'curl -fsS -m 5 http://127.0.0.1:1456/healthz >/dev/null' \
  && pass "app-server answers on the machine's loopback" || fail "app-server not answering"

docker exec "$NAME" bash -c '! curl -fsS -m 3 http://$(hostname -i):1456/healthz >/dev/null 2>&1' \
  && pass "app-server is not exposed on the machine's public interface" \
  || fail "app-server is reachable off-loopback"

LAUNCHER="$HOME/.codex/codex-remote/bin/codex-attach-$MACHINE"
[ -x "$LAUNCHER" ] && pass "launcher generated" || fail "no launcher at $LAUNCHER"
! grep -qE '[0-9a-f]{64}' "$LAUNCHER" && pass "launcher holds no token literal" \
  || fail "launcher appears to contain a token"

grep -q "Host codex-remote-$MACHINE" "$HOME/.ssh/config.d/codex-remote" \
  && pass "~/.ssh/config.d/codex-remote has the host" || fail "missing ssh host entry"
grep -q "config.d/codex-remote" "$HOME/.ssh/config" \
  && pass "~/.ssh/config includes it" || fail "~/.ssh/config does not include it"

ssh -o BatchMode=yes "codex-remote-$MACHINE" true >/dev/null 2>&1 \
  && pass "ssh codex-remote-$MACHINE works" || fail "ssh codex-remote-$MACHINE failed"

# Tunnel + bearer-token handshake, which is exactly what `codex --remote` does.
ssh -N -o ControlMaster=no -o ControlPath=none \
    -L "127.0.0.1:14999:127.0.0.1:1456" "codex-remote-$MACHINE" &
TUNNEL=$!
for _ in $(seq 1 20); do nc -z 127.0.0.1 14999 >/dev/null 2>&1 && break; sleep 0.5; done

curl -fsS -m 5 -o /dev/null "http://127.0.0.1:14999/healthz" \
  && pass "healthz answers through the tunnel" || fail "healthz did not answer through the tunnel"

# Reading the item can raise a keychain dialog when the calling binary's signature has
# changed since the item was created, and in an unattended run that blocks forever — so
# cap it and report rather than hang.
ACCOUNT="$(grep -oE 'machine\.[A-F0-9-]+\.appserver-token' "$LAUNCHER" | head -1)"
TOKEN=""
( security find-generic-password -s io.codexremote.credentials -a "$ACCOUNT" -w >"$ROOT/.token.tmp" 2>/dev/null ) &
SECPID=$!
WAITED=0
while kill -0 "$SECPID" 2>/dev/null && [ "$WAITED" -lt 15 ]; do sleep 1; WAITED=$((WAITED + 1)); done
if kill -0 "$SECPID" 2>/dev/null; then
  kill -9 "$SECPID" 2>/dev/null || true
  fail "keychain read blocked on an access dialog (sign the build — see Scripts/signing-identity.sh)"
else
  TOKEN="$(cat "$ROOT/.token.tmp" 2>/dev/null || true)"
  [ -n "$TOKEN" ] && pass "token is in the login keychain" || fail "no token in the keychain"
fi
rm -f "$ROOT/.token.tmp"

code_for() {
  curl -s -o /dev/null -w '%{http_code}' -m 5 \
    -H "Connection: Upgrade" -H "Upgrade: websocket" -H "Sec-WebSocket-Version: 13" \
    -H "Sec-WebSocket-Key: $(head -c 16 /dev/urandom | base64)" \
    -H "Authorization: Bearer $1" "http://127.0.0.1:14999/"
}
if [ -n "$TOKEN" ]; then
  [ "$(code_for "$TOKEN")" = "101" ] && pass "websocket upgrade accepted with the token" \
    || fail "websocket upgrade rejected with the real token"
fi
[ "$(code_for "not-the-token")" = "401" ] && pass "websocket upgrade rejected without it" \
  || fail "app-server accepted a bad token"

kill $TUNNEL 2>/dev/null || true

echo
if [ "$FAILURES" = "0" ]; then
  echo "All integration checks passed."
else
  echo "$FAILURES integration check(s) failed." >&2
  exit 1
fi
