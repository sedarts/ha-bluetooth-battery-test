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
[ "${1:-}" != -k ] || shift 2
shift; exec "$@"
EOF
cat >"$tmp/bin/process-runner" <<'EOF'
#!/usr/bin/env bash
# Behaviour suite only; real process supervision is tested on Linux.
shift 3
exec "$@"
EOF
cat >"$tmp/bin/flock" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = -u ]; then rmdir "${BT_OPS_LOCK_FILE}.held" 2>/dev/null || true; exit 0; fi
limit=0
if [ "${1:-}" = -w ]; then limit="$2"; shift 2; else shift; fi
start=$SECONDS
while ! mkdir "${BT_OPS_LOCK_FILE}.held" 2>/dev/null; do
  [ "$((SECONDS - start))" -ge "$limit" ] && exit 1
  sleep 0.05
done
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
  success:1|ble_only:1|connected_yes_no_a2dp:1|gatt_error:1|monitor_handover:1|missing_confirmation:1|error_then_new_wake:1|error_then_new_wake:2|resource_busy:1|resource_busy_exhausted:1|adapter_error:1|write_exit_failure:1|write_timeout:1) printf '%s wake\n' "$PM_TEST_COMMAND_TOPIC" ;;
  success:2|success:3) printf '%s idle\n' "$PM_TEST_PLAYBACK_TOPIC" ;;
  playing_cancels_idle:1|idle_off_failure:1) printf '%s idle\n' "$PM_TEST_PLAYBACK_TOPIC" ;;
  playing_cancels_idle:2) printf '%s playing\n' "$PM_TEST_PLAYBACK_TOPIC" ;;
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
if [ "${1:-}" = disconnect ]; then
  : > "${PM_TEST_INFO_COUNT}.disconnected"
fi
if [ "${1:-}" = unblock ]; then
  rm -f "${PM_TEST_INFO_COUNT}.disconnected"
fi
if [ "${1:-}" = info ]; then
  count=0; [ -f "$PM_TEST_INFO_COUNT" ] && count=$(cat "$PM_TEST_INFO_COUNT")
  count=$((count + 1)); printf '%s' "$count" >"$PM_TEST_INFO_COUNT"
  sub_count=$(cat "$PM_TEST_SUB_COUNT")
  if [ "${PM_TEST_SCENARIO}" = connected_yes_no_a2dp ] || [ -f "${PM_TEST_RENDERER_REQUEST}" ] || { [ "${PM_TEST_SCENARIO}" = error_then_new_wake ] && [ "$sub_count" -ge 2 ]; }; then
    printf 'Connected: yes\n'
  else
    printf 'Connected: no\n'
  fi
  exit 0
fi
if [ "${1:-}" = show ]; then
  [ "${PM_TEST_SCENARIO}" != adapter_error ] || exit 124
  printf 'Controller 8C:68:AB:E0:3F:F6\n\tPowered: yes\n'
  exit 0
fi
if [ "${1:-}" = connect ]; then
  printf 'Connection successful\n'
  exit 0
fi
if [ "$#" -eq 0 ]; then
  input=$(cat)
  printf '%s\n' "$input" >>"$PM_TEST_LOG"
  if [ "${PM_TEST_SCENARIO}" = resource_busy ] || [ "${PM_TEST_SCENARIO}" = resource_busy_exhausted ]; then
    count=0; [ -f "$PM_TEST_GATT_COUNT" ] && count=$(cat "$PM_TEST_GATT_COUNT")
    count=$((count + 1)); printf '%s' "$count" >"$PM_TEST_GATT_COUNT"
    if [ "$count" -lt 3 ] || [ "${PM_TEST_SCENARIO}" = resource_busy_exhausted ]; then
      printf 'Failed to write: Resource busy (16)\n'
      exit 1
    fi
  fi
  if [ "${PM_TEST_BLE_ERROR:-no}" = yes ] || [ "${PM_TEST_SCENARIO}" = gatt_error ]; then
    printf 'Failed to write value\n'
    exit 1
  fi
  [ "${PM_TEST_SCENARIO}" != write_exit_failure ] || exit 1
  [ "${PM_TEST_SCENARIO}" != write_timeout ] || exit 124
  if [ "${PM_TEST_SCENARIO}" = missing_confirmation ] || { [ "${PM_TEST_SCENARIO}" = error_then_new_wake ] && [ "$(cat "$PM_TEST_SUB_COUNT")" -lt 2 ]; }; then
    printf 'Characteristic - UE Boom power\n'
    exit 0
  fi
  printf 'Characteristic c6d6dc0d-07f5-47ef-9b59-630622b01fd3\nAttempting to write /org/bluez/hci0/dev_C0_28_8D_82_F7_BB/service0001/char0002\n'
fi
EOF
cat >"$tmp/bin/gatttool" <<'EOF'
#!/usr/bin/env bash
printf 'gatttool %s\n' "$*" >>"$PM_TEST_LOG"
if [[ " $* " == *' --characteristics '* ]]; then
  [ "${PM_TEST_GATT_DISCOVERY_FAIL:-no}" = yes ] && { echo 'Connection failed'; exit 0; }
  original=$(<"$PM_TEST_DISCOVERY_FIXTURE")
  case "${PM_TEST_SCENARIO}" in
    original_discovery|resource_busy) printf '%s\n' "$original" ;;
    invalid_uuid) printf '%s\n' "${original/b01fd3/b01fd4}" ;;
    invalid_ambiguous) printf '%s\n%s\n' "$original" "$original" ;;
    invalid_incomplete) printf '%s\n' "${original/char value handle = 0x0003, /}" ;;
    invalid_properties) printf '%s\n' "${original/0x08/0x02}" ;;
    *) printf 'handle: 0x0002, char properties: %s, char value handle: 0x0003, uuid: c6d6dc0d-07f5-47ef-9b59-630622b01fd3\n' "${PM_TEST_GATT_PROPERTIES:-0x08}" ;;
  esac
  exit 0
fi
[ "${PM_TEST_SCENARIO}" = write_exit_failure ] && exit 1
[ "${PM_TEST_SCENARIO}" = write_timeout ] && exit 124
if [ "${PM_TEST_GATT_WRITE_FAIL:-no}" = yes ]; then
  echo 'Characteristic Write Request failed: Insufficient authentication'
  exit 0
fi
[ "${PM_TEST_GATT_WRITE_NO_ACK:-no}" = yes ] && exit 0
echo 'Characteristic value was written sucessfully'
EOF
chmod +x "$tmp/bin"/*

run_case() {
  local scenario="$1" a2dp="$2" loops="$3" ble_error="${4:-no}" a2dp_after="${5:-1}" renderer_ack="${6:-no}" log renderer_dir gatt_properties="${7:-0x08}" gatt_write_fail="${8:-${4:-no}}" gatt_write_no_ack="${9:-no}"
  log="$tmp/${scenario}.log"
  renderer_dir="$tmp/${scenario}.renderer"
  PM_TEST_LOG="$log" PM_TEST_SCENARIO="$scenario" PM_TEST_A2DP="$a2dp" PM_TEST_BLE_ERROR="$ble_error" \
  PM_TEST_GATT_PROPERTIES="$gatt_properties" PM_TEST_GATT_WRITE_FAIL="$gatt_write_fail" \
  PM_TEST_GATT_WRITE_NO_ACK="$gatt_write_no_ack" \
  PM_TEST_GATT_COUNT="$tmp/${scenario}.gatt" \
  PM_TEST_A2DP_AFTER="$a2dp_after" PM_TEST_RENDERER_ACK="$renderer_ack" PM_TEST_RENDERER_REQUEST="$renderer_dir/C0:28:8D:82:F7:BB" \
  PM_TEST_SUB_COUNT="$tmp/${scenario}.sub" PM_TEST_INFO_COUNT="$tmp/${scenario}.info" PM_TEST_PACTL_COUNT="$tmp/${scenario}.pactl" PM_TEST_CLOCK="$tmp/${scenario}.clock" \
  PM_PAUSE_DIR="$tmp/${scenario}.paused" \
  PM_BT_OPS_LIB="$root/lib/bluetooth-ops.sh" BT_OPS_LOCK_FILE="$tmp/${scenario}.bt.lock" \
  BT_PROCESS_RUNNER="$tmp/bin/process-runner" \
  PM_GATT_DISCOVERY_LIB="$root/lib/gatt-discovery.sh" PM_TEST_DISCOVERY_FIXTURE="$root/tests/fixtures/gatttool-test9-discovery.txt" \
  PM_TEST_COMMAND_TOPIC='bluetooth_audio_bridge/c0288d82f7bb/power/command' \
  PM_TEST_PLAYBACK_TOPIC='bluetooth_audio_bridge/c0288d82f7bb/power/playback' PATH="$tmp/bin:$PATH" \
  PM_TEST_MAX_LOOPS="$loops" PM_MAC=C0:28:8D:82:F7:BB PM_NAME='UE BOOM 2' PM_ENABLED=true \
  PM_IDLE_TIMEOUT=2 PM_STOP_DEBOUNCE=1 PM_BLE_WAKE=true PM_ADAPTER_MAC=8C:68:AB:E0:3F:F6 \
  PM_RENDERER_DIR="$renderer_dir" PM_WAKE_TIMEOUT=20 PM_WAKE_BOOT_DELAY=1 PM_MQTT_HOST=test "$root/lib/power-manager.sh" >>"$log" 2>&1
  # Applies to every success, parse/ATT error, timeout, retry exhaustion, and
  # ERROR -> new wake scenario, not just an isolated lock-helper invocation.
  [ ! -e "$tmp/${scenario}.bt.lock.held" ] || { echo "lock leaked in $scenario" >&2; return 1; }
}

run_case success yes 4 no 2 yes
success_log="$tmp/success.log"
assert_wake_processed success "$success_log"
assert_log_contains success "$success_log" 'wake command received'
assert_log_contains success "$success_log" 'Bluetooth reconnect block cleared'
assert_log_contains success "$success_log" 'select-attribute c6d6dc0d-07f5-47ef-9b59-630622b01fd3'
assert_log_contains success "$success_log" 'write "140 104 171 224 63 246 1"'
assert_log_contains success "$success_log" '[BLE][op='
assert_log_contains success "$success_log" 'Write result=request-submitted att_response=unconfirmed physical_power=unconfirmed'
assert_log_contains success "$success_log" 'write "140 104 171 224 63 246 2"'
assert_log_contains success "$success_log" 'Power-off write result=request-submitted att_response=unconfirmed physical_power=unconfirmed'
assert_log_excludes success "$success_log" 'gatttool --adapter hci0 --device C0:28:8D:82:F7:BB --char-write'
assert_log_excludes success "$success_log" 'bearer'
assert_log_contains success "$success_log" 'physical power state remains unknown until independently observed'
assert_log_contains success "$success_log" 'normal reconnect monitor released after BLE wake'
assert_log_contains success "$success_log" 'A2DP sink is ready; waiting for the DLNA renderer handover'
assert_log_contains success "$success_log" 'wake_success: A2DP sink and DLNA renderer are ready'
assert_log_contains success "$success_log" '[POWER][op='
assert_log_contains success "$success_log" '[CLASSIC][op='
assert_log_contains success "$success_log" '[AUDIO][op='
assert_log_contains success "$success_log" '[HA][op='
assert_log_contains success "$success_log" 'idle timer already running; repeated player state idle ignored'
cleanup_line=$(grep -n 'Cleanup result=own-processes-reaped status=0' "$success_log" | head -n1 | cut -d: -f1)
classic_handover_line=$(grep -n 'Connecting A2DP result=handover-requested' "$success_log" | head -n1 | cut -d: -f1)
[ "$cleanup_line" -lt "$classic_handover_line" ]
assert_log_excludes success "$success_log" '--value=8c68abe03ff601'
# Wake must release the prior BlueZ block, temporarily pause the legacy
# monitor only for BLE/boot, then release it before waiting for A2DP. The
# later marker/block pair belongs solely to the independently tested idle path.
unblock_line=$(grep -n '^unblock C0:28:8D:82:F7:BB' "$success_log" | head -n1 | cut -d: -f1)
wake_pause_line=$(grep -n 'reconnect pause set before waiting for shared Bluetooth lock' "$success_log" | head -n1 | cut -d: -f1)
wake_release_line=$(grep -n 'normal reconnect monitor released after BLE wake' "$success_log" | head -n1 | cut -d: -f1)
waiting_classic_line=$(grep -n -- '-m waiting_for_classic' "$success_log" | head -n1 | cut -d: -f1)
[ "$wake_pause_line" -lt "$unblock_line" ] && [ "$unblock_line" -lt "$wake_release_line" ] && [ "$wake_release_line" -lt "$waiting_classic_line" ]
marker_line=$(grep -n 'reconnect pause marker set before idle power-off' "$success_log" | head -n1 | cut -d: -f1)
disconnect_line=$(grep -n 'disconnect C0:28:8D:82:F7:BB' "$success_log" | tail -n1 | cut -d: -f1)
block_line=$(grep -n '^block C0:28:8D:82:F7:BB' "$success_log" | head -n1 | cut -d: -f1)
[ "$marker_line" -lt "$disconnect_line" ] && [ "$disconnect_line" -lt "$block_line" ]

run_case ble_only no 1
ble_only_log="$tmp/ble_only.log"
assert_wake_processed ble_only "$ble_only_log"
assert_log_contains ble_only "$ble_only_log" 'Write result=request-submitted att_response=unconfirmed physical_power=unconfirmed'
assert_log_contains ble_only "$ble_only_log" 'state=ERROR wake failed; reconnect remains suppressed until a new explicit wake'
assert_log_excludes ble_only "$ble_only_log" 'wake_success: A2DP sink and DLNA renderer are ready'
assert_log_contains ble_only "$ble_only_log" '-m error'
[ -e "$tmp/ble_only.paused/C0:28:8D:82:F7:BB" ]

# A generic BlueZ Connected=yes with no PulseAudio A2DP sink is diagnostic,
# not an ownership veto. The historical GATT wake must still be attempted and
# must not issue a device-wide disconnect.
run_case connected_yes_no_a2dp no 1
connected_log="$tmp/connected_yes_no_a2dp.log"
assert_log_contains connected_yes_no_a2dp "$connected_log" 'Device state result=observed'
assert_log_contains connected_yes_no_a2dp "$connected_log" 'details=Connected: yes'
assert_log_contains connected_yes_no_a2dp "$connected_log" 'write "140 104 171 224 63 246 1"'
assert_log_excludes connected_yes_no_a2dp "$connected_log" 'disconnect C0:28:8D:82:F7:BB'

run_case gatt_error no 1 yes
gatt_error_log="$tmp/gatt_error.log"
assert_wake_processed gatt_error "$gatt_error_log"
assert_log_contains gatt_error "$gatt_error_log" 'Write result=error exit=1'
assert_log_contains gatt_error "$gatt_error_log" '-m error'
assert_log_contains gatt_error "$gatt_error_log" 'state=ERROR wake failed; reconnect remains suppressed until a new explicit wake'

run_case monitor_handover yes 1 no 4 yes
monitor_handover_log="$tmp/monitor_handover.log"
assert_wake_processed monitor_handover "$monitor_handover_log"
assert_log_contains monitor_handover "$monitor_handover_log" 'normal reconnect monitor released after BLE wake'
assert_log_contains monitor_handover "$monitor_handover_log" 'wake_success: A2DP sink and DLNA renderer are ready'
assert_log_excludes monitor_handover "$monitor_handover_log" 'Classic audio connection attempt'

run_case missing_confirmation no 1 no 1 no 0x08 no yes
assert_log_contains missing_confirmation "$tmp/missing_confirmation.log" 'Write result=unconfirmed exit=0 reason=write-attempt-not-observed'
assert_log_excludes missing_confirmation "$tmp/missing_confirmation.log" 'Write result=request-submitted'

run_case resource_busy yes 1 no 1 yes
assert_log_contains resource_busy "$tmp/resource_busy.log" 'BLE wake resource busy; bounded retry 1/3 after 1s'
assert_log_contains resource_busy "$tmp/resource_busy.log" 'BLE wake resource busy; bounded retry 2/3 after 1s'
[ "$(cat "$tmp/resource_busy.gatt")" -eq 3 ]
assert_log_contains resource_busy "$tmp/resource_busy.log" 'write "140 104 171 224 63 246 1"'
run_case resource_busy_exhausted no 1
assert_log_contains resource_busy_exhausted "$tmp/resource_busy_exhausted.log" 'BLE wake series ended attempts=3/3 result=failed'
assert_log_contains resource_busy_exhausted "$tmp/resource_busy_exhausted.log" 'state=ERROR wake failed; reconnect remains suppressed until a new explicit wake'
[ "$(cat "$tmp/resource_busy_exhausted.gatt")" -eq 3 ]

# ERROR must not terminate the MQTT consumer: a later explicit wake starts a
# fresh session and can succeed when the speaker is already A2DP-ready.
run_case error_then_new_wake yes 3 no 1 yes 0x08 yes
assert_log_contains error_then_new_wake "$tmp/error_then_new_wake.log" 'state=ERROR wake failed; reconnect remains suppressed until a new explicit wake'
[ "$(grep -c 'wake command received' "$tmp/error_then_new_wake.log")" -eq 2 ]
assert_log_contains error_then_new_wake "$tmp/error_then_new_wake.log" 'wake_success: A2DP sink and DLNA renderer are ready'

. "$root/lib/renderer-recovery.sh"
bashio::log.info() { :; }
connect_speaker() { classic_calls=$((classic_calls + 1)); }
for scenario in adapter_error write_exit_failure write_timeout; do
  run_case "$scenario" no 1
done
for scenario in adapter_error write_exit_failure write_timeout gatt_error missing_confirmation resource_busy_exhausted; do
  log="$tmp/${scenario}.log"
  assert_wake_processed "$scenario" "$log"
  assert_log_contains "$scenario" "$log" 'state=ERROR wake failed'
  assert_log_excludes "$scenario" "$log" 'renderer handover requested'
  assert_log_excludes "$scenario" "$log" 'normal reconnect monitor released after BLE wake'
  [ -f "$tmp/${scenario}.renderer/C0:28:8D:82:F7:BB.error" ]
  pause="$tmp/${scenario}.paused/C0:28:8D:82:F7:BB"
  [ "$(<"$pause")" = 0 ]
  # Invoke the real recovery entry point with the actual failed-wake marker.
  # It must refuse the automatic Classic call on repeated monitor passes.
  classic_calls=0
  for pass in 1 2 3; do
    if recover_renderer_after_connect C0:28:8D:82:F7:BB BOOM sink card "$pause" "$tmp/reconnect-$scenario" 1; then
      echo "failed wake allowed recovery in $scenario" >&2; exit 1
    else
      [ "$?" -eq 2 ]
    fi
  done
  [ "$classic_calls" -eq 0 ]
done
assert_log_contains adapter_error "$tmp/adapter_error.log" 'Adapter ready result=error exit=124'
assert_log_contains write_exit_failure "$tmp/write_exit_failure.log" 'Write result=error exit=1'
assert_log_contains write_timeout "$tmp/write_timeout.log" 'Write result=error exit=124'

# A stale idle notification may arrive immediately before playback is reported.
# The later playing state must clear both the debounce and any pending idle
# deadline before the disconnect/block sequence can run.
run_case playing_cancels_idle no 4
playing_cancels_idle_log="$tmp/playing_cancels_idle.log"
assert_log_contains playing_cancels_idle "$playing_cancels_idle_log" 'player is idle; waiting 1s before starting idle timer'
assert_log_contains playing_cancels_idle "$playing_cancels_idle_log" 'idle timer cancelled because player is playing'
assert_log_excludes playing_cancels_idle "$playing_cancels_idle_log" 'reconnect pause marker set before idle power-off'
assert_log_excludes playing_cancels_idle "$playing_cancels_idle_log" 'reconnect blocked after submitted BLE power-off'

# A failed power-off write must not tear down working audio or leave the
# reconnect monitor paused/blocked. The failure remains visible to MQTT.
run_case idle_off_failure no 5 yes
idle_off_failure_log="$tmp/idle_off_failure.log"
assert_log_contains idle_off_failure "$idle_off_failure_log" 'Power-off write result=error exit=1'
assert_log_contains idle_off_failure "$idle_off_failure_log" 'BLE power-off could not be submitted; keeping A2DP and automatic reconnect available'
assert_log_contains idle_off_failure "$idle_off_failure_log" 'reconnect pause cleared after failed BLE power-off'
assert_log_contains idle_off_failure "$idle_off_failure_log" '-m power_off_failed'
assert_log_excludes idle_off_failure "$idle_off_failure_log" 'disconnect C0:28:8D:82:F7:BB'
assert_log_excludes idle_off_failure "$idle_off_failure_log" 'block C0:28:8D:82:F7:BB'
[ ! -e "$tmp/idle_off_failure.paused/C0:28:8D:82:F7:BB" ]

echo 'power-manager smoke test: PASS'
