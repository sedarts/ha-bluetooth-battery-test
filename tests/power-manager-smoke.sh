#!/usr/bin/env bash
# Dependency-free behavioural smoke test for the opt-in MQTT controller.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'kill "${pid:-}" 2>/dev/null || true; rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat >"$tmp/bin/timeout" <<'EOF'
#!/usr/bin/env bash
shift; exec "$@"
EOF
cat >"$tmp/bin/mosquitto_pub" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$PM_TEST_LOG"
EOF
cat >"$tmp/bin/mosquitto_sub" <<'EOF'
#!/usr/bin/env bash
if [ ! -e "$PM_TEST_ONCE" ]; then touch "$PM_TEST_ONCE"; printf wake; fi
EOF
cat >"$tmp/bin/bluetoothctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$PM_TEST_LOG"
if [ "${1:-}" = info ]; then exit 0; fi
cat >>"$PM_TEST_LOG" || true
EOF
chmod +x "$tmp/bin"/*
PM_TEST_LOG="$tmp/log" PM_TEST_ONCE="$tmp/once" PATH="$tmp/bin:$PATH" \
PM_MAC=C0:28:8D:82:F7:BB PM_NAME='UE BOOM 2' PM_ENABLED=true PM_IDLE_TIMEOUT=60 \
PM_BLE_WAKE=true PM_ADAPTER_MAC=8C:68:AB:E0:3F:F6 PM_MQTT_HOST=test \
"$root/lib/power-manager.sh" &
pid=$!
for _ in 1 2 3 4 5; do
  grep -q 'write "140 104 171 224 63 246 1"' "$tmp/log" 2>/dev/null && break
  sleep 1
done
grep -q 'connect C0:28:8D:82:F7:BB' "$tmp/log"
grep -q 'write "140 104 171 224 63 246 1"' "$tmp/log"
echo 'power-manager smoke test: PASS'
