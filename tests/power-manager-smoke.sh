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
count=0
[ -f "$PM_TEST_SUB_COUNT" ] && count=$(cat "$PM_TEST_SUB_COUNT")
count=$((count + 1)); printf '%s' "$count" >"$PM_TEST_SUB_COUNT"
if [ "$count" = 1 ]; then printf '%s wake\n' "$PM_TEST_COMMAND_TOPIC"; fi
if [ "$count" = 2 ]; then printf '%s idle\n' "$PM_TEST_PLAYBACK_TOPIC"; fi
if [ "$count" = 3 ]; then printf '%s idle\n' "$PM_TEST_PLAYBACK_TOPIC"; fi
EOF
cat >"$tmp/bin/date" <<'EOF'
#!/usr/bin/env bash
value=100
[ -f "$PM_TEST_CLOCK" ] && value=$(cat "$PM_TEST_CLOCK")
printf '%s' "$((value + 1))" >"$PM_TEST_CLOCK"
printf '%s\n' "$value"
EOF
cat >"$tmp/bin/bluetoothctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$PM_TEST_LOG"
if [ "${1:-}" = info ]; then exit 0; fi
cat >>"$PM_TEST_LOG" || true
EOF
chmod +x "$tmp/bin"/*
PM_TEST_LOG="$tmp/log" PM_TEST_SUB_COUNT="$tmp/sub-count" PM_TEST_CLOCK="$tmp/clock" \
PM_TEST_COMMAND_TOPIC='bluetooth_audio_bridge/c0288d82f7bb/power/command' \
PM_TEST_PLAYBACK_TOPIC='bluetooth_audio_bridge/c0288d82f7bb/power/playback' PATH="$tmp/bin:$PATH" \
PM_MAC=C0:28:8D:82:F7:BB PM_NAME='UE BOOM 2' PM_ENABLED=true PM_IDLE_TIMEOUT=2 PM_STOP_DEBOUNCE=1 \
PM_BLE_WAKE=true PM_ADAPTER_MAC=8C:68:AB:E0:3F:F6 PM_MQTT_HOST=test \
"$root/lib/power-manager.sh" >>"$tmp/log" 2>&1 &
pid=$!
for _ in 1 2 3 4 5; do
  grep -q 'write "140 104 171 224 63 246 1"' "$tmp/log" 2>/dev/null && break
  sleep 1
done
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  grep -q 'disconnect C0:28:8D:82:F7:BB' "$tmp/log" 2>/dev/null && break
  sleep 1
done
grep -q 'connect C0:28:8D:82:F7:BB' "$tmp/log"
grep -q 'write "140 104 171 224 63 246 1"' "$tmp/log"
grep -q 'idle timer already running; repeated player state idle ignored' "$tmp/log"
grep -q '^block C0:28:8D:82:F7:BB' "$tmp/log"
grep -q 'disconnect C0:28:8D:82:F7:BB' "$tmp/log"
marker_line=$(grep -n 'reconnect pause marker set before idle disconnect' "$tmp/log" | head -n1 | cut -d: -f1)
disconnect_line=$(grep -n 'disconnect C0:28:8D:82:F7:BB' "$tmp/log" | head -n1 | cut -d: -f1)
block_line=$(grep -n '^block C0:28:8D:82:F7:BB' "$tmp/log" | head -n1 | cut -d: -f1)
[ "$marker_line" -lt "$disconnect_line" ] && [ "$disconnect_line" -lt "$block_line" ]
echo 'power-manager smoke test: PASS'
