#!/usr/bin/env bash
# Dependency-free behavioural test for the opt-in MQTT controller.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

cat >"$tmp/bin/timeout" <<'EOF'
#!/usr/bin/env bash
shift; exec "$@"
EOF
cat >"$tmp/bin/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$tmp/bin/mosquitto_pub" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$PM_TEST_LOG"
EOF
cat >"$tmp/bin/mosquitto_sub" <<'EOF'
#!/usr/bin/env bash
count=0; [ -f "$PM_TEST_SUB_COUNT" ] && count=$(cat "$PM_TEST_SUB_COUNT")
count=$((count + 1)); printf '%s' "$count" >"$PM_TEST_SUB_COUNT"
case "${PM_TEST_SCENARIO}:${count}" in
  success:1|ble_only:1|gatt_error:1) printf '%s wake\n' "$PM_TEST_COMMAND_TOPIC" ;;
  success:2|success:3) printf '%s idle\n' "$PM_TEST_PLAYBACK_TOPIC" ;;
esac
EOF
cat >"$tmp/bin/pactl" <<'EOF'
#!/usr/bin/env bash
[ "${PM_TEST_A2DP:-no}" = yes ] && printf '1\tbluez_sink.C0_28_8D_82_F7_BB.a2dp_sink\tmodule-bluez5-device.c\n'
EOF
cat >"$tmp/bin/date" <<'EOF'
#!/usr/bin/env bash
value=100; [ -f "$PM_TEST_CLOCK" ] && value=$(cat "$PM_TEST_CLOCK")
printf '%s' "$((value + 1))" >"$PM_TEST_CLOCK"; printf '%s\n' "$value"
EOF
cat >"$tmp/bin/bluetoothctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$PM_TEST_LOG"
if [ "${1:-}" = info ]; then
  count=0; [ -f "$PM_TEST_INFO_COUNT" ] && count=$(cat "$PM_TEST_INFO_COUNT")
  count=$((count + 1)); printf '%s' "$count" >"$PM_TEST_INFO_COUNT"
  [ "$count" -ge 2 ] && printf 'Connected: yes\n'; exit 0
fi
if [ "$#" -eq 0 ]; then
  cat >>"$PM_TEST_LOG" || true
  if [ "${PM_TEST_BLE_ERROR:-no}" = yes ]; then
    printf 'Failed to write value\n'
    exit 1
  fi
fi
EOF
chmod +x "$tmp/bin"/*

run_case() {
  local scenario="$1" a2dp="$2" loops="$3" ble_error="${4:-no}" log
  log="$tmp/${scenario}.log"
  PM_TEST_LOG="$log" PM_TEST_SCENARIO="$scenario" PM_TEST_A2DP="$a2dp" PM_TEST_BLE_ERROR="$ble_error" \
  PM_TEST_SUB_COUNT="$tmp/${scenario}.sub" PM_TEST_INFO_COUNT="$tmp/${scenario}.info" PM_TEST_CLOCK="$tmp/${scenario}.clock" \
  PM_PAUSE_DIR="$tmp/${scenario}.paused" \
  PM_TEST_COMMAND_TOPIC='bluetooth_audio_bridge/c0288d82f7bb/power/command' \
  PM_TEST_PLAYBACK_TOPIC='bluetooth_audio_bridge/c0288d82f7bb/power/playback' PATH="$tmp/bin:$PATH" \
  PM_TEST_MAX_LOOPS="$loops" PM_MAC=C0:28:8D:82:F7:BB PM_NAME='UE BOOM 2' PM_ENABLED=true \
  PM_IDLE_TIMEOUT=2 PM_STOP_DEBOUNCE=1 PM_BLE_WAKE=true PM_ADAPTER_MAC=8C:68:AB:E0:3F:F6 \
  PM_WAKE_TIMEOUT=3 PM_MQTT_HOST=test "$root/lib/power-manager.sh" >>"$log" 2>&1
}

run_case success yes 4
success_log="$tmp/success.log"
grep -q 'wake command received' "$success_log"
grep -q 'reconnect pause marker cleared\|reconnect pause marker was not present' "$success_log"
grep -q 'Bluetooth reconnect block cleared' "$success_log"
grep -q 'write "140 104 171 224 63 246 1"' "$success_log"
grep -q 'BLE wake write accepted by bluetoothctl' "$success_log"
grep -q 'A2DP sink is ready; renderer monitor can publish the DLNA player' "$success_log"
grep -q 'reconnect pause marker cleared after A2DP wake' "$success_log"
grep -q 'idle timer already running; repeated player state idle ignored' "$success_log"
marker_line=$(grep -n 'reconnect pause marker set before idle disconnect' "$success_log" | head -n1 | cut -d: -f1)
disconnect_line=$(grep -n 'disconnect C0:28:8D:82:F7:BB' "$success_log" | tail -n1 | cut -d: -f1)
block_line=$(grep -n '^block C0:28:8D:82:F7:BB' "$success_log" | head -n1 | cut -d: -f1)
[ "$marker_line" -lt "$disconnect_line" ] && [ "$disconnect_line" -lt "$block_line" ]

run_case ble_only no 1
ble_only_log="$tmp/ble_only.log"
grep -q 'BLE wake write accepted by bluetoothctl' "$ble_only_log"
grep -q 'wake timed out: no A2DP sink became available within 3s' "$ble_only_log"
! grep -q 'A2DP sink is ready; renderer monitor can publish the DLNA player' "$ble_only_log"
grep -q -- '-m wake_failed' "$ble_only_log"
grep -q 'Bluetooth reconnect remains blocked after failed wake' "$ble_only_log"
[ "$(cat "$tmp/ble_only.paused/C0:28:8D:82:F7:BB")" = 0 ]

run_case gatt_error no 1 yes
gatt_error_log="$tmp/gatt_error.log"
grep -q 'BLE wake write was rejected or timed out (bluetoothctl exit 1)' "$gatt_error_log"
grep -q 'wake timed out: no A2DP sink became available within 3s' "$gatt_error_log"
grep -q -- '-m wake_failed' "$gatt_error_log"
grep -q 'Bluetooth reconnect remains blocked after failed wake' "$gatt_error_log"

echo 'power-manager smoke test: PASS'
