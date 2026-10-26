#!/usr/bin/env bash
# Local state-machine tests; no Bluetooth access or Linux process assumptions.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# Load only the BLE functions, never the MQTT main loop.
source <(sed -n '/^ble_run()/,/^wait_for_renderer_ready()/p' "$root/lib/power-manager.sh" | sed '$d')
PM_MAC=C0:28:8D:82:F7:BB
BT_OPS_FD=99
log() { printf '%s\n' "$*"; }
flow_log() { local category="$1"; shift; log "[${category}] $*"; }
sleep() { printf 'poll-delay\n' >> "$tmp/calls"; }
bt_process_run() {
  shift
  printf '%s\n' "$*" >> "$tmp/calls"
  [ "$2" != disconnect ] || { echo 'UNSAFE disconnect' >&2; return 99; }
  [ "$scenario" != timeout ] || return 124
  if [ "$1" = bluetoothctl ] && [ "${2:-}" = show ]; then echo 'Powered: yes'; return 0; fi
  if [ "$1" = bluetoothctl ] && [ "${2:-}" = connect ]; then echo 'Connection successful'; return 0; fi
  if [ "$1" = bash ]; then echo 'Attempting to write /org/bluez/hci0/dev_C0_28_8D_82_F7_BB/service0001/char0002'; return 0; fi
  local n=0
  [ ! -f "$tmp/count" ] || n=$(<"$tmp/count")
  n=$((n + 1)); printf '%s' "$n" > "$tmp/count"
  case "$scenario" in
    already) echo 'Connected: no' ;;
    immediate) [ "$n" -eq 1 ] && echo 'Connected: yes' || echo 'Connected: no' ;;
    delayed) [ "$n" -lt 3 ] && echo 'Connected: yes' || echo 'Connected: no' ;;
    unknown) echo 'Device unavailable' ;;
    *) echo 'Connected: yes' ;;
  esac
}
for scenario in already immediate delayed timeout busy unknown; do
  rm -f "$tmp/count"
  : > "$tmp/calls"
  rc=0
  ble_release_link test > "$tmp/log" || rc=$?
  case "$scenario" in
    already|immediate|delayed) [ "$rc" -eq 0 ] ;;
    *) [ "$rc" -ne 0 ]; grep -q 'no GATT connection permitted' "$tmp/log" ;;
  esac
  ! grep -q disconnect "$tmp/calls"
  if [ "$scenario" = delayed ]; then grep -q poll-delay "$tmp/calls"; fi
  if [ "$scenario" = timeout ]; then grep -q 'exit=124' "$tmp/log"; fi
  echo "PASS: $scenario"
done

# Connected=yes is no longer an ownership veto for the historical BlueZ GATT
# wake. It must proceed without a blanket device-wide disconnect.
scenario=busy
PM_ADAPTER_MAC=8C:68:AB:E0:3F:F6
ble_power_command_once wake 01 > "$tmp/log"
grep -q 'Write result=request-submitted' "$tmp/log"
grep -q '^bash -c' "$tmp/calls"
! grep -q 'bluetoothctl disconnect' "$tmp/calls"
grep -q 'attempt-cleanup: own command processes reaped' "$tmp/log"
echo 'PASS: connected state does not gate BlueZ wake and cleanup is scoped'

# The same generic Connected=yes state must not veto the separate BlueZ
# power-off path. It targets the known UUID with the paired-host payload ending
# in 02 and does not disconnect the device before the write.
: > "$tmp/calls"
ble_power_command_once off 02 > "$tmp/log"
grep -q 'Power-off write result=request-submitted' "$tmp/log"
grep -q 'c6d6dc0d-07f5-47ef-9b59-630622b01fd3 140 104 171 224 63 246 2' "$tmp/calls"
! grep -q 'bluetoothctl disconnect' "$tmp/calls"
grep -q 'attempt-cleanup: own command processes reaped' "$tmp/log"
echo 'PASS: connected state allows scoped BlueZ power-off without pre-write disconnect'

# Synchronous EXIT cleanup also covers early command failure / explicit exit.
for status in 1 143; do
  scenario=already
  ble_wake_bluez_body() { exit "$status"; }
  rc=0
  ble_power_command_once wake 01 > "$tmp/log" || rc=$?
  [ "$rc" -eq "$status" ]
  grep -q 'attempt-cleanup: own command processes reaped' "$tmp/log"
done
echo 'PASS: error and explicit process-exit cleanup (not a SIGKILL test)'

scenario=busy
ble_wake_bluez_body() { return 0; }
: > "$tmp/calls"
ble_power_command_once wake 01 > "$tmp/log"
[ ! -s "$tmp/calls" ]
echo 'PASS: cleanup touches no newer or unknown connection'

BT_OPS_FD=''
: > "$tmp/calls"
if ble_release_link stale > "$tmp/log"; then exit 1; fi
[ ! -s "$tmp/calls" ]
echo 'PASS: no post-lock disconnect'
PM_BLE_END=$SECONDS
[ "$PM_BLE_END" -gt 0 ] || PM_BLE_END=1
SECONDS=$PM_BLE_END
: > "$tmp/calls"
rc=0
ble_run 5 bluetoothctl info "$PM_MAC" || rc=$?
[ "$rc" -eq 124 ] && [ ! -s "$tmp/calls" ]
echo 'PASS: expired wake budget starts no command'
echo 'BLE disconnect smoke test: PASS'
