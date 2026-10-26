#!/usr/bin/env bash
# MQTT controlled, opt-in power manager for one primary speaker.
# Power state remains unknown unless independently observed; idle performs the
# configured BLE-off attempt (when enabled) and then cleans up Classic audio.
set -u -o pipefail
. "${PM_BT_OPS_LIB:-/opt/btui/lib/bluetooth-ops.sh}"
. "${PM_GATT_DISCOVERY_LIB:-/opt/btui/lib/gatt-discovery.sh}"

: "${PM_MAC:?}" "${PM_NAME:?}" "${PM_ENABLED:=false}" "${PM_IDLE_TIMEOUT:=300}" "${PM_STOP_DEBOUNCE:=10}"
: "${PM_BLE_WAKE:=false}" "${PM_ADAPTER_MAC:=}" "${PM_MQTT_HOST:=}"
: "${PM_MQTT_PORT:=1883}" "${PM_MQTT_USER:=}" "${PM_MQTT_PASS:=}"
: "${PM_WAKE_TIMEOUT:=90}"
: "${PM_WAKE_BOOT_DELAY:=5}"
: "${PM_TEST_MAX_LOOPS:=0}"
: "${PM_PAUSE_DIR:=/tmp/btui/paused}"
: "${PM_RENDERER_DIR:=/tmp/btui/wake}"

[[ "${PM_IDLE_TIMEOUT}" =~ ^[0-9]+$ ]] || PM_IDLE_TIMEOUT=300
[[ "${PM_STOP_DEBOUNCE}" =~ ^[0-9]+$ ]] || PM_STOP_DEBOUNCE=10
[[ "${PM_WAKE_TIMEOUT}" =~ ^[0-9]+$ ]] || PM_WAKE_TIMEOUT=90
[[ "${PM_WAKE_BOOT_DELAY}" =~ ^[0-9]+$ ]] || PM_WAKE_BOOT_DELAY=5
[[ "${PM_TEST_MAX_LOOPS}" =~ ^[0-9]+$ ]] || PM_TEST_MAX_LOOPS=0

id=${PM_MAC//:/}; id=${id,,}
prefix="bluetooth_audio_bridge/${id}/power"
command_topic="${prefix}/command"
playback_topic="${prefix}/playback"
state_topic="${prefix}/state"
management_topic="${prefix}/management"
idle_deadline=0
stop_debounce_deadline=0
stop_candidate=""
mode="disabled"
PM_CURRENT_WAKE_DEADLINE=0

mqtt_args=(-h "${PM_MQTT_HOST}" -p "${PM_MQTT_PORT}")
[ -n "${PM_MQTT_USER}" ] && mqtt_args+=(-u "${PM_MQTT_USER}")
[ -n "${PM_MQTT_PASS}" ] && mqtt_args+=(-P "${PM_MQTT_PASS}")

log() { printf '[%s][power-manager][op=%s] %s\n' "$(bt_ops_timestamp)" "${PM_CURRENT_OPERATION_ID:-${BT_OP_ID:-none}}" "$*"; }
publish() { timeout 8 mosquitto_pub "${mqtt_args[@]}" -t "${state_topic}" -m "$1" -r >/dev/null 2>&1 || log "MQTT status publish failed"; }
publish_management() { timeout 8 mosquitto_pub "${mqtt_args[@]}" -t "${management_topic}" -m "$1" -r >/dev/null 2>&1 || log "MQTT management-state publish failed"; }
connected() {
  local info
  info=$(bt_process_run 3 bluetoothctl info "${PM_MAC}" 2>/dev/null) || return 1
  grep -q '^[[:space:]]*Connected: yes' <<<"${info}"
}
a2dp_ready() {
  local sink="bluez_sink.${PM_MAC//:/_}.a2dp_sink" sinks
  sinks=$(pactl list short sinks 2>/dev/null) || return 1
  grep -Fq "${sink}" <<<"${sinks}"
}
request_renderer_handover() {
  local renderer_request="$1" renderer_ready="${1}.renderer_ready"
  rm -f "${renderer_ready}"
  rm -f "${renderer_request}.error"
  if mkdir -p "${PM_RENDERER_DIR}" && printf '%s %s\n' "${PM_CURRENT_OPERATION_ID:-wake-$(date +%s)-$$}" "${PM_CURRENT_WAKE_DEADLINE}" > "${renderer_request}"; then
    log "renderer handover requested; normal reconnect monitor owns Classic/A2DP connection"
  else
    log "could not request renderer handover"
    return 1
  fi
}

# The BOOM power characteristic is written with the ATT procedure advertised
# by its discovered properties. gatttool is used because this BlueZ 5.66 image's
# bluetoothctl has no `bearer` command and exits before its async WriteValue
# result can be observed. The final byte is 01 (on) or 02 (off).
ble_run() {
  local seconds="$1" remaining
  shift
  if [ "${PM_BLE_END:-0}" -gt 0 ]; then
    remaining=$((PM_BLE_END - SECONDS))
    [ "${remaining}" -gt 0 ] || return 124
    [ "${seconds}" -le "${remaining}" ] || seconds="${remaining}"
  fi
  # The supervisor terminates/reaps only its own command tree.
  bt_process_run "${seconds}" "$@"
}

ble_release_link() {
  local phase="$1" check
  # This synchronous helper must never run after its caller releases the lock.
  [ -n "${BT_OPS_FD:-}" ] || { log "BLE cleanup skipped: no operation lock"; return 1; }
  log "BLE link release start phase=${phase} device=${PM_MAC}"
  if ble_link_is_disconnected "${phase}-before"; then
    log "BLE link already disconnected according to BlueZ; direct ATT ownership remains unknown"
    return 0
  fi
  log "BLE link ownership unknown phase=${phase}; no device-wide disconnect; bounded observation only"
  for check in 1 2 3 4; do
    if ble_link_is_disconnected "${phase}-after-${check}"; then
      log "BLE link disconnected according to BlueZ phase=${phase}; direct ATT ownership remains unknown"
      return 0
    fi
    [ "${PM_BLE_END:-0}" -eq 0 ] || [ "${SECONDS}" -lt "${PM_BLE_END}" ] || break
    [ "${check}" -eq 4 ] || sleep 1
  done
  log "BLE link release unconfirmed phase=${phase}; no GATT connection permitted"
  return 1
}

ble_link_is_disconnected() {
  local output status=0
  output=$(ble_run 2 bluetoothctl info "${PM_MAC}" 2>&1) || status=$?
  log "BLE link state phase=$1 exit=${status}: ${output//$'\n'/; }"
  [ "${status}" -eq 0 ] &&
    grep -Eq '^[[:space:]]*Connected: no[[:space:]]*$' <<<"${output}" &&
    ! grep -Eq '^[[:space:]]*Connected: yes[[:space:]]*$' <<<"${output}"
}

ble_power_command_once() (
  # EXIT runs synchronously before the waiting parent can release its lock or
  # start a newer wake. Never schedule a delayed/background disconnect.
  trap 'rc=$?; trap - EXIT; log "BLE attempt-cleanup: own command processes reaped; no device-wide disconnect"; exit "$rc"' EXIT
  ble_power_command_body "$@"
)

ble_power_command_body() {
  local action="$1" command_byte="$2" hex="" octet discovery status=0 uuid="c6d6dc0d-07f5-47ef-9b59-630622b01fd3"
  local handle properties write_flag write_flag_name write_args output
  [ -n "${PM_ADAPTER_MAC}" ] || { log "BLE power command unavailable: paired-host MAC is not configured"; return 1; }
  [ "${action}" = wake ] || [ "${action}" = off ] || return 1
  for octet in ${PM_ADAPTER_MAC//:/ }; do printf -v octet '%02x' "$((16#${octet}))"; hex+="${octet}"; done
  printf -v octet '%02x' "$((16#${command_byte}))"; hex+="${octet}"

  # Observe a disconnected state; do not evict an unknown connection owner.
  ble_release_link "before-${action}-discovery" || return 1
  log "BLE ${action} GATT discovery start device=${PM_MAC} uuid=${uuid}"
  discovery=$(ble_run 5 gatttool --adapter hci0 --device "${PM_MAC}" --characteristics --uuid "${uuid}" 2>&1) || status=$?
  log "BLE ${action} GATT discovery process exited status=${status}: ${discovery//$'\n'/; }"
  if [ "${status}" -ne 0 ] || grep -Eqi 'failed|error|not connected|not found' <<<"${discovery}"; then
    log "BLE ${action} GATT discovery failed (gatttool exit ${status}): ${discovery//$'\n'/; }"
    return 1
  fi
  if ! parse_gatt_discovery "${discovery}" "${uuid}"; then
    log "BLE ${action} GATT discovery rejected: ${GATT_PARSE_ERROR}; no write sent"
    return 1
  fi
  handle="${GATT_VALUE_HANDLE}"
  properties="${GATT_PROPERTIES}"
  log "BLE ${action} GATT characteristic selected uuid=${uuid} value_handle=${handle} properties=${properties}"
  write_flag=$((properties))
  if (( write_flag & 8 )); then
    write_args=(--char-write-req)
    write_flag_name="request"
  elif (( write_flag & 4 )); then
    write_args=(--char-write)
    write_flag_name="command"
  else
    log "BLE ${action} not sent: characteristic does not advertise a supported write property (properties ${properties})"
    return 1
  fi
  status=0
  # Separate one-shot processes reconnect for the write. Do not insert a sleep
  # or another BlueZ operation between discovery and this ATT request.
  log "BLE ${action} GATT write ${write_flag_name} start value_handle=${handle}"
  output=$(ble_run 5 gatttool --adapter hci0 --device "${PM_MAC}" "${write_args[@]}" --handle "${handle}" --value="${hex}" 2>&1) || status=$?
  log "BLE ${action} GATT write process exited status=${status}: ${output//$'\n'/; }"
  if [ "${status}" -ne 0 ] || grep -Eqi 'failed|error|protocol error|not permitted|not authorized' <<<"${output}"; then
    log "BLE ${action} GATT write ${write_flag_name} failed (gatttool exit ${status}): ${output//$'\n'/; }"
    return 1
  fi
  if [ "${write_flag_name}" = request ]; then
    if ! grep -Eqi 'Characteristic value was written suc?cessfully' <<<"${output}"; then
      log "BLE ${action} GATT write request was not confirmed (gatttool exit ${status}): ${output//$'\n'/; }"
      return 1
    fi
    log "BLE ${action} GATT write request confirmed by ATT response; physical speaker action remains unconfirmed"
  else
    log "BLE ${action} GATT write command submitted; ATT confirmation is not defined for Write Command, physical speaker action remains unconfirmed"
  fi
  # The supervisor has reaped the command; no device-wide disconnect follows.
  return 0
}

ble_power_command_locked() {
  local action="$1" command_byte="$2" attempt rc=1 output state_label=POWERING_OFF
  local PM_BLE_END=0 remaining
  if [ "${action}" = wake ]; then
    remaining=$((PM_CURRENT_WAKE_DEADLINE - $(date +%s)))
    [ "${remaining}" -gt 0 ] || return 1
    PM_BLE_END=$((SECONDS + remaining))
  fi
  [ "${action}" = wake ] && state_label=WAKING
  for attempt in 1 2 3; do
    [ "${PM_BLE_END}" -eq 0 ] || [ "${SECONDS}" -lt "${PM_BLE_END}" ] || break
    log "state=${state_label} operation=ble-${action} attempt=${attempt}/3 start"
    output=$(ble_power_command_once "${action}" "${command_byte}" 2>&1) && rc=0 || rc=$?
    printf '%s\n' "${output}"
    [ "${rc}" -eq 0 ] && break
    if grep -Eqi 'Resource busy \(16\)|resource busy' <<<"${output}" && [ "${attempt}" -lt 3 ]; then
      log "BLE ${action} resource busy; bounded retry ${attempt}/3 after 1s"
      sleep 1
    else
      break
    fi
  done
  log "BLE ${action} series ended attempts=${attempt}/3 result=$([ "${rc}" -eq 0 ] && echo submitted || echo failed)"
  return "${rc}"
}

wait_for_renderer_ready() {
  local renderer_request="$1" renderer_ready="${1}.renderer_ready" deadline="$2"
  while [ "$(date +%s)" -lt "${deadline}" ]; do
    if [ -f "${renderer_request}.error" ]; then
      log "wake failed: reconnect monitor exhausted its bounded Classic/A2DP series"
      return 1
    fi
    if [ -f "${renderer_ready}" ]; then
      rm -f "${renderer_request}" "${renderer_ready}"
      mode="ready"; publish "${mode}"
      log "wake_success: A2DP sink and DLNA renderer are ready"
      return 0
    fi
    sleep 1
  done
  log "wake timed out: DLNA renderer did not confirm readiness within ${PM_WAKE_TIMEOUT}s"
  rm -f "${renderer_request}" "${renderer_ready}"
  return 1
}
fail_wake() {
  local renderer_request="$1"
  mkdir -p "$(dirname "${renderer_request}")"
  rm -f "${renderer_request}" "${renderer_request}.renderer_ready"
  mkdir -p "${PM_PAUSE_DIR}"
  printf '0\n' > "${PM_PAUSE_DIR}/${PM_MAC^^}"
  : > "${renderer_request}.error"
  log "state=ERROR wake failed; reconnect remains suppressed until a new explicit wake"
  mode="error"; publish "${mode}"
}

publish_discovery() {
  # IDs are stable per Bluetooth MAC. Discovery messages are retained; all
  # device actions use a small, documented command vocabulary.
  local base="homeassistant" cfg
  cfg=$(printf '{"name":"%s power management","unique_id":"bluetooth_audio_bridge_%s_power_management","state_topic":"%s","command_topic":"%s","payload_on":"enable","payload_off":"disable","state_on":"enabled","state_off":"disabled","device":{"identifiers":["bluetooth_audio_bridge_%s"],"name":"%s","manufacturer":"Bluetooth Audio Bridge"}}' "${PM_NAME}" "${id}" "${management_topic}" "${command_topic}" "${id}" "${PM_NAME}")
  timeout 8 mosquitto_pub "${mqtt_args[@]}" -r -t "${base}/switch/bluetooth_audio_bridge_${id}_power_management/config" -m "${cfg}" >/dev/null 2>&1 || true
  cfg=$(printf '{"name":"%s wake","unique_id":"bluetooth_audio_bridge_%s_wake","command_topic":"%s","payload_press":"wake","device":{"identifiers":["bluetooth_audio_bridge_%s"]}}' "${PM_NAME}" "${id}" "${command_topic}" "${id}")
  timeout 8 mosquitto_pub "${mqtt_args[@]}" -r -t "${base}/button/bluetooth_audio_bridge_${id}_wake/config" -m "${cfg}" >/dev/null 2>&1 || true
  cfg=$(printf '{"name":"%s disconnect audio","unique_id":"bluetooth_audio_bridge_%s_idle","command_topic":"%s","payload_press":"idle","device":{"identifiers":["bluetooth_audio_bridge_%s"]}}' "${PM_NAME}" "${id}" "${command_topic}" "${id}")
  timeout 8 mosquitto_pub "${mqtt_args[@]}" -r -t "${base}/button/bluetooth_audio_bridge_${id}_idle/config" -m "${cfg}" >/dev/null 2>&1 || true
  cfg=$(printf '{"name":"%s connection state","unique_id":"bluetooth_audio_bridge_%s_connection_state","state_topic":"%s","device":{"identifiers":["bluetooth_audio_bridge_%s"]}}' "${PM_NAME}" "${id}" "${state_topic}" "${id}")
  timeout 8 mosquitto_pub "${mqtt_args[@]}" -r -t "${base}/sensor/bluetooth_audio_bridge_${id}_connection_state/config" -m "${cfg}" >/dev/null 2>&1 || true
}

clear_discovery() {
  # A normal add-on stop/update must not leave retained buttons or switches
  # behind when rolling back to a version that does not publish them.
  local base="homeassistant" component
  for component in \
    "switch/bluetooth_audio_bridge_${id}_power_management" \
    "button/bluetooth_audio_bridge_${id}_wake" \
    "button/bluetooth_audio_bridge_${id}_idle" \
    "sensor/bluetooth_audio_bridge_${id}_connection_state"; do
    timeout 8 mosquitto_pub "${mqtt_args[@]}" -r -n -t "${base}/${component}/config" >/dev/null 2>&1 || true
  done
}

wake_impl() {
  local pause_marker renderer_request deadline remaining boot_delay classic_reserve=47
  deadline=$(( $(date +%s) + PM_WAKE_TIMEOUT ))
  PM_CURRENT_WAKE_DEADLINE="${deadline}"
  pause_marker="${PM_PAUSE_DIR}/${PM_MAC^^}"
  renderer_request="${PM_RENDERER_DIR}/${PM_MAC^^}"
  log "wake command received"
  if [ "${idle_deadline}" -gt 0 ] || [ "${stop_debounce_deadline}" -gt 0 ]; then
    log "idle timer cancelled by wake/resume"
  fi
  idle_deadline=0
  stop_debounce_deadline=0
  stop_candidate=""
  # Publish the pause before waiting on the shared operation lock. An already
  # running Classic command finishes first; no queued monitor call can pass
  # the post-lock pause check and race the BLE session.
  if mkdir -p "${PM_PAUSE_DIR}" && printf '%s\n' "$(( $(date +%s) + PM_WAKE_TIMEOUT + 15 ))" > "${pause_marker}"; then
    log "state=WAKING reconnect pause set before waiting for shared Bluetooth lock"
  else
    log "failed to pause reconnect monitor during wake"
  fi
  if ! bt_ops_acquire "wake-${PM_MAC}" 18; then
    fail_wake "${renderer_request}"; return
  fi
  if bt_ops_unblock_locked "${PM_MAC}" >/dev/null 2>&1; then
    log "Bluetooth reconnect block cleared"
  else
    log "Bluetooth unblock request failed or device was already unblocked"
  fi
  if connected && a2dp_ready; then
    bt_ops_release
    log "A2DP is already available; requesting renderer readiness"
    request_renderer_handover "${renderer_request}" || { fail_wake "${renderer_request}"; return; }
    rm -f "${pause_marker}" || log "failed to clear reconnect pause marker after A2DP wake"
    mode="renderer_starting"; publish "${mode}"
    wait_for_renderer_ready "${renderer_request}" "${deadline}" || fail_wake "${renderer_request}"
    return
  fi
  if [ "${PM_BLE_WAKE}" = true ] && [ -n "${PM_ADAPTER_MAC}" ]; then
    mode="ble_waking"; publish "${mode}"
    if ble_power_command_locked wake 01; then
      log "BLE wake command submitted; waiting for the speaker to switch to Classic audio"
    else
      bt_ops_release
      fail_wake "${renderer_request}"
      return
    fi
    bt_ops_release
    # The speaker needs time to boot its Classic radio after accepting the
    # GATT frame. The normal reconnect monitor subsequently asks BlueZ for
    # the missing bearer using its established connect_speaker() routine.
    remaining=$(( deadline - $(date +%s) ))
    boot_delay="${PM_WAKE_BOOT_DELAY}"
    # Reserve enough of the original 90s window for four short bounded
    # Classic/A2DP attempts. Never extend the deadline for the boot delay.
    if (( remaining - classic_reserve < boot_delay )); then
      boot_delay=$(( remaining - classic_reserve ))
      (( boot_delay < 0 )) && boot_delay=0
    fi
    log "waiting ${boot_delay}s (configured ${PM_WAKE_BOOT_DELAY}s, deadline-bounded) for Classic audio boot"
    sleep "${boot_delay}"
  else
    bt_ops_release
    log "BLE wake skipped (ble_wake_enabled=${PM_BLE_WAKE}, adapter MAC configured=$([ -n "${PM_ADAPTER_MAC}" ] && echo yes || echo no))"
  fi
  request_renderer_handover "${renderer_request}" || { fail_wake "${renderer_request}"; return; }
  # An explicit wake/resume is the only power-manager action that lifts an
  # idle/manual pause. Once removed, monitor_speaker() alone reconnects.
  if rm -f "${pause_marker}"; then
    log "normal reconnect monitor released after BLE wake"
  else
    log "failed to release normal reconnect monitor after BLE wake"
  fi
  mode="waiting_for_classic"; publish "${mode}"
  while [ "$(date +%s)" -lt "${deadline}" ]; do
    if connected; then
      if a2dp_ready; then
        mode="waiting_for_a2dp"; publish "${mode}"
        log "A2DP sink is ready; waiting for the DLNA renderer handover"
        mode="renderer_starting"; publish "${mode}"
        wait_for_renderer_ready "${renderer_request}" "${deadline}" || fail_wake "${renderer_request}"
        return
      else
        mode="a2dp_unavailable"; publish "${mode}"
      fi
    fi
    sleep 1
  done
    log "wake timed out: no A2DP sink became available within ${PM_WAKE_TIMEOUT}s"
  fail_wake "${renderer_request}"
}

wake() {
  PM_CURRENT_OPERATION_ID="wake-$$-$(date +%s)"
  wake_impl "$@"
  PM_CURRENT_OPERATION_ID=""
}

enter_idle() {
  [ "${PM_ENABLED}" = true ] || { publish "disabled"; return; }
  idle_deadline=$(( $(date +%s) + PM_IDLE_TIMEOUT ))
  mode="idle_pending"; publish "${mode}"
  log "idle timer started for ${PM_IDLE_TIMEOUT}s after player state ${1:-explicit}"
}

handle_playback() {
  local playback_state="$1"
  log "player state received: ${playback_state}"
  case "${playback_state}" in
    playing)
      if [ "${idle_deadline}" -gt 0 ] || [ "${stop_debounce_deadline}" -gt 0 ]; then
        log "idle timer cancelled because player is playing"
      fi
      idle_deadline=0
      stop_debounce_deadline=0
      stop_candidate=""
      mode="connected"; publish "${mode}"
      ;;
    paused|idle|off|stopped)
      [ "${PM_ENABLED}" = true ] || { log "player stop state ignored: power management is disabled"; return; }
      if [ "${idle_deadline}" -gt 0 ]; then
        log "idle timer already running; repeated player state ${playback_state} ignored"
        return
      fi
      if [ "${stop_debounce_deadline}" -gt 0 ]; then
        log "stop debounce already active; repeated player state ${playback_state} ignored"
        return
      fi
      stop_candidate="${playback_state}"
      stop_debounce_deadline=$(( $(date +%s) + PM_STOP_DEBOUNCE ))
      log "player is ${playback_state}; waiting ${PM_STOP_DEBOUNCE}s before starting idle timer"
      ;;
    unavailable|unknown)
      log "player state ${playback_state} ignored; it is not evidence that playback stopped"
      ;;
    *) log "ignored unsupported player state: ${playback_state}" ;;
  esac
}

handle() {
  log "command received: $1"
  case "$1" in
    wake|resume) wake ;;
    idle|disconnect) enter_idle explicit_command ;;
    enable) PM_ENABLED=true; publish_management enabled; mode="connected"; publish "${mode}" ;;
    disable) PM_ENABLED=false; idle_deadline=0; stop_debounce_deadline=0; stop_candidate=""; publish_management disabled; mode="disabled"; publish "${mode}" ;;
    *) log "ignored unknown command" ;;
  esac
}

if [ -z "${PM_MQTT_HOST}" ]; then log "MQTT not configured; power management unavailable"; exit 0; fi
PM_PROCESS_DIR=$(mktemp -d) || exit 1
BT_OPS_STOP_FILE="${PM_PROCESS_DIR}/stop"
PM_CLEANED=false
cleanup() {
  [ "${PM_CLEANED}" = false ] || return 0
  PM_CLEANED=true
  trap '' INT TERM
  : > "${BT_OPS_STOP_FILE}"
  log "process cleanup: stop requested; waiting for owned commands"
  while compgen -G "${PM_PROCESS_DIR}/child-*" >/dev/null; do sleep 0.05; done
  if [[ "${PM_CURRENT_OPERATION_ID:-}" == wake-* ]]; then
    mkdir -p "${PM_PAUSE_DIR}" "${PM_RENDERER_DIR}"
    printf '0\n' > "${PM_PAUSE_DIR}/${PM_MAC^^}"
    rm -f "${PM_RENDERER_DIR}/${PM_MAC^^}" "${PM_RENDERER_DIR}/${PM_MAC^^}.renderer_ready"
    : > "${PM_RENDERER_DIR}/${PM_MAC^^}.error"
  fi
  bt_ops_release
  log "process cleanup: owned commands ended; lock released; no disconnect"
  [ "${PM_TEST_MAX_LOOPS}" -ne 0 ] || clear_discovery
  # Keep stop visible until all command substitutions have unwound; only the
  # stopped root process removes its private directory at final exit.
  rm -f "${BT_OPS_STOP_FILE}"
  rmdir "${PM_PROCESS_DIR}" 2>/dev/null || true
}
trap cleanup EXIT
trap 'cleanup; exit 143' TERM
trap 'cleanup; exit 130' INT
publish_discovery
[ "${PM_ENABLED}" = true ] && publish_management enabled || publish_management disabled

loop_count=0
while true; do
  message=$(timeout 1 mosquitto_sub "${mqtt_args[@]}" -t "${command_topic}" -t "${playback_topic}" -v -C 1 2>/dev/null || true)
  case "${message}" in
    "${command_topic} "*) handle "${message#"${command_topic} "}" ;;
    "${playback_topic} "*) handle_playback "${message#"${playback_topic} "}" ;;
    "") ;;
    *) log "ignored malformed MQTT message" ;;
  esac
  if [ "${stop_debounce_deadline}" -gt 0 ] && [ "$(date +%s)" -ge "${stop_debounce_deadline}" ]; then
    stop_debounce_deadline=0
    enter_idle "${stop_candidate}"
    stop_candidate=""
  fi
  if [ "${idle_deadline}" -gt 0 ] && [ "$(date +%s)" -ge "${idle_deadline}" ]; then
    idle_deadline=0
    PM_CURRENT_OPERATION_ID="idle-$$-$(date +%s)"
    mkdir -p "${PM_PAUSE_DIR}"
    printf '0\n' > "${PM_PAUSE_DIR}/${PM_MAC^^}"
    log "reconnect pause marker set before idle disconnect"
    if bt_ops_acquire "idle-poweroff-${PM_MAC}" 20; then
      if [ "${PM_BLE_WAKE}" = true ] && [ -n "${PM_ADAPTER_MAC}" ]; then
        mode="powering_off"; publish "${mode}"
        if ble_power_command_locked off 02; then
          mode="power_state_unknown"; publish "${mode}"
          log "BLE power-off command submitted after idle; physical power state remains unknown until independently observed"
        else
          mode="power_state_unknown"; publish "${mode}"
          log "BLE power-off could not be submitted; physical power state remains unknown"
        fi
      else
        mode="power_state_unknown"; publish "${mode}"
        log "idle disconnect only; BLE power-off disabled or paired-host MAC missing; physical power state unknown"
      fi
      if bt_ops_disconnect_locked "${PM_MAC}" >/dev/null 2>&1; then
        log "A2DP disconnected after idle timeout"
      else
        log "A2DP disconnect request failed or speaker was already disconnected"
      fi
      # Blocking remains paired; wake() reverses the block before reconnect.
      if bt_ops_block_locked "${PM_MAC}" >/dev/null 2>&1; then
        log "reconnect blocked after idle timeout"
      else
        log "failed to block reconnect after idle timeout"
      fi
      bt_ops_release
    else
      mode="power_state_unknown"; publish "${mode}"
      log "idle Bluetooth operation skipped: shared lock unavailable; physical power state unknown"
    fi
    # Link teardown proves only that the Bluetooth connection was dropped;
    # the BLE power characteristic has no response or status readback.
    mode="power_state_unknown"; publish "${mode}"
    PM_CURRENT_OPERATION_ID=""
  fi
  loop_count=$((loop_count + 1))
  if [ "${PM_TEST_MAX_LOOPS}" -gt 0 ] && [ "${loop_count}" -ge "${PM_TEST_MAX_LOOPS}" ]; then
    log "test loop limit reached; exiting"
    exit 0
  fi
done
