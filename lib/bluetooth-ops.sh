#!/usr/bin/env bash
# Shared adapter-operation lock for every Bluetooth-changing process in this
# add-on. util-linux flock releases the kernel lock automatically on process
# exit, including timeout, signal, or unexpected shell failure.

: "${BT_OPS_LOCK_FILE:=/tmp/btui/bluetooth-ops/hci0.lock}"

bt_ops_timestamp() {
  local stamp="${EPOCHREALTIME:-}" seconds fraction
  if [[ "${stamp}" == *.* ]]; then
    seconds="${stamp%.*}"
    fraction="${stamp#*.}000"
    printf '%s.%s' "${seconds}" "${fraction:0:3}"
  else
    date '+%Y-%m-%dT%H:%M:%S.000%z'
  fi
}

bt_ops_log() {
  local message="$1" op_id="${BT_OP_ID:-unassigned}"
  printf '[%s][bluetooth][op=%s] %s\n' "$(bt_ops_timestamp)" "${op_id}" "${message}"
}

# bt_ops_acquire <operation> <wait-seconds> [pause-file]
# Returns 2 when a reconnect should yield to a pause/wake, 1 on lock timeout.
bt_ops_acquire() {
  local operation="$1" wait_seconds="$2" pause_file="${3:-}" fd
  BT_OP_ID="${operation//[^a-zA-Z0-9_-]/_}-$$-$(date +%s)"
  mkdir -p "$(dirname "${BT_OPS_LOCK_FILE}")" || return 1
  if [ -n "${pause_file}" ] && [ -e "${pause_file}" ]; then
    bt_ops_log "lock skipped operation=${operation}: wake/idle pause is active"
    return 2
  fi
  bt_ops_log "lock requested operation=${operation} wait=${wait_seconds}s"
  exec {fd}>"${BT_OPS_LOCK_FILE}" || return 1
  if ! flock -w "${wait_seconds}" "${fd}"; then
    exec {fd}>&-
    bt_ops_log "lock timeout operation=${operation}"
    return 1
  fi
  BT_OPS_FD="${fd}"
  BT_OPS_HELD_OPERATION="${operation}"
  if [ -n "${pause_file}" ] && [ -e "${pause_file}" ]; then
    bt_ops_release
    bt_ops_log "lock yielded operation=${operation}: pause appeared while waiting"
    return 2
  fi
  bt_ops_log "lock acquired operation=${operation}"
  return 0
}

bt_ops_release() {
  [ -n "${BT_OPS_FD:-}" ] || return 0
  local fd="${BT_OPS_FD}" operation="${BT_OPS_HELD_OPERATION:-unknown}"
  flock -u "${fd}" 2>/dev/null || true
  exec {fd}>&-
  BT_OPS_FD=""
  BT_OPS_HELD_OPERATION=""
  bt_ops_log "lock released operation=${operation}"
  BT_OP_ID=""
}

bt_ops_connect_classic_locked() {
  local mac="$1" name="$2" timeout_seconds="${3:-8}"
  bt_ops_log "state=CONNECTING Classic connect start device=${mac}"
  timeout "${timeout_seconds}" bluetoothctl power on || true
  if timeout "${timeout_seconds}" bluetoothctl connect "${mac}"; then
    bt_ops_log "state=CONNECTING Classic connect command returned success device=${mac}; A2DP not implied"
    return 0
  fi
  bt_ops_log "state=CONNECTING Classic connect failed device=${mac} name=${name}"
  return 1
}

bt_ops_disconnect_locked() {
  local mac="$1" timeout_seconds="${2:-5}"
  bt_ops_log "Classic disconnect start device=${mac}"
  timeout "${timeout_seconds}" bluetoothctl disconnect "${mac}"
}

bt_ops_unblock_locked() {
  local mac="$1" timeout_seconds="${2:-5}"
  timeout "${timeout_seconds}" bluetoothctl unblock "${mac}"
}

bt_ops_block_locked() {
  local mac="$1" timeout_seconds="${2:-5}"
  timeout "${timeout_seconds}" bluetoothctl block "${mac}"
}
