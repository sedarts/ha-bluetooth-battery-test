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
sleep() { printf 'poll-delay\n' >> "$tmp/calls"; }
bt_process_run() {
  shift
  printf '%s\n' "$*" >> "$tmp/calls"
  [ "$2" != disconnect ] || { echo 'UNSAFE disconnect' >&2; return 99; }
  [ "$scenario" != timeout ] || return 124
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

# The real body must stop before discovery when teardown is unconfirmed.
scenario=busy
PM_ADAPTER_MAC=8C:68:AB:E0:3F:F6
if ble_power_command_once wake 01 > "$tmp/log"; then exit 1; fi
! grep -q 'GATT discovery start' "$tmp/log"
grep -q 'attempt-cleanup: own command processes reaped' "$tmp/log"
echo 'PASS: incomplete disconnect gates discovery and cleans up'

# Synchronous EXIT cleanup also covers early command failure / explicit exit.
for status in 1 143; do
  scenario=already
  ble_power_command_body() { exit "$status"; }
  rc=0
  ble_power_command_once wake 01 > "$tmp/log" || rc=$?
  [ "$rc" -eq "$status" ]
  grep -q 'attempt-cleanup: own command processes reaped' "$tmp/log"
done
echo 'PASS: error and explicit process-exit cleanup (not a SIGKILL test)'

scenario=busy
ble_power_command_body() { return 0; }
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
