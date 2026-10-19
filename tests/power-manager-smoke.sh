#!/usr/bin/env bash
# Dependency-free behavioural test for the opt-in MQTT controller.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
show_failure_logs() {
  local status="$1" log
  [ "${status}" -eq 0 ] && return
  printf '\nSMOKE TEST FAILED (exit %s). Scenario logs follow:\n' "${status}" >&2
  for log in "$tmp"/*.log; do
    [ -e "${log}" ] || continue
    printf '\n----- %s -----\n' "$(basename "${log}")" >&2
    cat "${log}" >&2 || true
  done
}
cleanup() {
  local status=$?
  show_failure_logs "${status}"
  rm -rf "$tmp"
  exit "${status}"
}
trap cleanup EXIT
mkdir -p "$tmp/bin"

assert_log_contains() {
  local scenario="$1" log="$2" expected="$3"
  if ! grep -Fq -- "${expected}" "${log}"; then
    printf 'ASSERTION FAILED [%s]: expected log line: %s\n' "${scenario}" "${expected}" >&2
    return 1
  fi
}
assert_log_excludes() {
  local scenario="$1" log="$2" unexpected="$3"
  if grep -Fq -- "${unexpected}" "${log}"; then
    printf 'ASSERTION FAILED [%s]: unexpected log line: %s\n' "${scenario}" "${unexpected}" >&2
    return 1
  fi
}
assert_wake_processed() {
  local scenario="$1" log="$2"
  assert_log_contains "${scenario}" "${log}" 'command received: wake'
}

cat >"$tmp/bin/timeout" <<'EOF'
#!/usr/bin/env bash
shift; exec "$@"
EOF
cat >"$tmp/bin/sleep" <<'EOF'
#!/usr/bin/env bash
if [ "${PM_TEST_RENDERER_ACK:-no}" = yes ] && [ -f "${PM_TEST_RENDERER_REQUEST:-}" ]; then
  printf 'ready\n' > "${PM_TEST_RENDERER_REQUEST}.renderer_ready"
fi
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
  success:1|ble_only:1|gatt_error:1|monitor_handover:1) printf '%s wake\n' "$PM_TEST_COMMAND_TOPIC" ;;
  success:2|success:3) printf '%s idle\n' "$PM_TEST_PLAYBACK_TOPIC" ;;
esac
EOF
cat >"$tmp/bin/pactl" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = list ]; then
  count=0; [ -f "$PM_TEST_PACTL_COUNT" ] && count=$(cat "$PM_TEST_PACTL_COUNT")
  count=$((count + 1)); printf '%s' "$count" >"$PM_TEST_PACTL_COUNT"
  if [ "${PM_TEST_A2DP:-no}" = yes ] && [ "$count" -ge "${PM_TEST_A2DP_AFTER:-1}" ]; then
    printf '1\tbluez_sink.C0_28_8D_82_F7_BB.a2dp_sink\tmodule-bluez5-device.c\n'
  fi
fi
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
  local scenario="$1" a2dp="$2" loops="$3" ble_error="${4:-no}" a2dp_after="${5:-1}" renderer_ack="${6:-no}" log renderer_dir
  log="$tmp/${scenario}.log"
  renderer_dir="$tmp/${scenario}.renderer"
  PM_TEST_LOG="$log" PM_TEST_SCENARIO="$scenario" PM_TEST_A2DP="$a2dp" PM_TEST_BLE_ERROR="$ble_error" \
  PM_TEST_A2DP_AFTER="$a2dp_after" PM_TEST_RENDERER_ACK="$renderer_ack" PM_TEST_RENDERER_REQUEST="$renderer_dir/C0:28:8D:82:F7:BB" \
  PM_TEST_SUB_COUNT="$tmp/${scenario}.sub" PM_TEST_INFO_COUNT="$tmp/${scenario}.info" PM_TEST_PACTL_COUNT="$tmp/${scenario}.pactl" PM_TEST_CLOCK="$tmp/${scenario}.clock" \
  PM_PAUSE_DIR="$tmp/${scenario}.paused" \
  PM_TEST_COMMAND_TOPIC='bluetooth_audio_bridge/c0288d82f7bb/power/command' \
  PM_TEST_PLAYBACK_TOPIC='bluetooth_audio_bridge/c0288d82f7bb/power/playback' PATH="$tmp/bin:$PATH" \
  PM_TEST_MAX_LOOPS="$loops" PM_MAC=C0:28:8D:82:F7:BB PM_NAME='UE BOOM 2' PM_ENABLED=true \
  PM_IDLE_TIMEOUT=2 PM_STOP_DEBOUNCE=1 PM_BLE_WAKE=true PM_ADAPTER_MAC=8C:68:AB:E0:3F:F6 \
  PM_RENDERER_DIR="$renderer_dir" PM_WAKE_TIMEOUT=20 PM_WAKE_BOOT_DELAY=1 PM_MQTT_HOST=test "$root/lib/power-manager.sh" >>"$log" 2>&1
}

run_case success yes 4 no 2 yes
success_log="$tmp/success.log"
assert_wake_processed success "$success_log"
assert_log_contains success "$success_log" 'wake command received'
assert_log_contains success "$success_log" 'Bluetooth reconnect block cleared'
assert_log_contains success "$success_log" 'write "140 104 171 224 63 246 1"'
assert_log_contains success "$success_log" 'BLE wake write accepted by bluetoothctl'
assert_log_contains success "$success_log" 'normal reconnect monitor released after BLE wake'
assert_log_contains success "$success_log" 'A2DP sink is ready; waiting for the DLNA renderer handover'
assert_log_contains success "$success_log" 'wake_success: A2DP sink and DLNA renderer are ready'
assert_log_contains success "$success_log" 'idle timer already running; repeated player state idle ignored'
# Wake must release the prior BlueZ block, temporarily pause the legacy
# monitor only for BLE/boot, then release it before waiting for A2DP. The
# later marker/block pair belongs solely to the independently tested idle path.
unblock_line=$(grep -n '^unblock C0:28:8D:82:F7:BB' "$success_log" | head -n1 | cut -d: -f1)
wake_pause_line=$(grep -n 'reconnect monitor paused while wake waits for A2DP' "$success_log" | head -n1 | cut -d: -f1)
wake_release_line=$(grep -n 'normal reconnect monitor released after BLE wake' "$success_log" | head -n1 | cut -d: -f1)
waiting_classic_line=$(grep -n -- '-m waiting_for_classic' "$success_log" | head -n1 | cut -d: -f1)
[ "$unblock_line" -lt "$wake_pause_line" ] && [ "$wake_pause_line" -lt "$wake_release_line" ] && [ "$wake_release_line" -lt "$waiting_classic_line" ]
marker_line=$(grep -n 'reconnect pause marker set before idle disconnect' "$success_log" | head -n1 | cut -d: -f1)
disconnect_line=$(grep -n 'disconnect C0:28:8D:82:F7:BB' "$success_log" | tail -n1 | cut -d: -f1)
block_line=$(grep -n '^block C0:28:8D:82:F7:BB' "$success_log" | head -n1 | cut -d: -f1)
[ "$marker_line" -lt "$disconnect_line" ] && [ "$disconnect_line" -lt "$block_line" ]

run_case ble_only no 1
ble_only_log="$tmp/ble_only.log"
assert_wake_processed ble_only "$ble_only_log"
assert_log_contains ble_only "$ble_only_log" 'BLE wake write accepted by bluetoothctl'
assert_log_contains ble_only "$ble_only_log" 'wake timed out: no A2DP sink became available within 20s'
assert_log_excludes ble_only "$ble_only_log" 'wake_success: A2DP sink and DLNA renderer are ready'
assert_log_contains ble_only "$ble_only_log" '-m wake_failed'
assert_log_contains ble_only "$ble_only_log" 'wake failed without re-blocking Bluetooth; normal reconnect monitor remains available'
[ ! -e "$tmp/ble_only.paused/C0:28:8D:82:F7:BB" ]

run_case gatt_error no 1 yes
gatt_error_log="$tmp/gatt_error.log"
assert_wake_processed gatt_error "$gatt_error_log"
assert_log_contains gatt_error "$gatt_error_log" 'BLE wake write was rejected or timed out (bluetoothctl exit 1)'
assert_log_contains gatt_error "$gatt_error_log" 'wake timed out: no A2DP sink became available within 20s'
assert_log_contains gatt_error "$gatt_error_log" '-m wake_failed'
assert_log_contains gatt_error "$gatt_error_log" 'wake failed without re-blocking Bluetooth; normal reconnect monitor remains available'

run_case monitor_handover yes 1 no 4 yes
monitor_handover_log="$tmp/monitor_handover.log"
assert_wake_processed monitor_handover "$monitor_handover_log"
assert_log_contains monitor_handover "$monitor_handover_log" 'normal reconnect monitor released after BLE wake'
assert_log_contains monitor_handover "$monitor_handover_log" 'wake_success: A2DP sink and DLNA renderer are ready'
assert_log_excludes monitor_handover "$monitor_handover_log" 'Classic audio connection attempt'

echo 'power-manager smoke test: PASS'
