#!/usr/bin/env bash
# MQTT controlled, opt-in power manager for one primary speaker.
# It deliberately never sends a BLE power-off command: idle means A2DP
# disconnect only, allowing speakers with their own sleep timer to power down.
set -u -o pipefail

: "${PM_MAC:?}" "${PM_NAME:?}" "${PM_ENABLED:=false}" "${PM_IDLE_TIMEOUT:=300}" "${PM_STOP_DEBOUNCE:=10}"
: "${PM_BLE_WAKE:=false}" "${PM_ADAPTER_MAC:=}" "${PM_MQTT_HOST:=}"
: "${PM_MQTT_PORT:=1883}" "${PM_MQTT_USER:=}" "${PM_MQTT_PASS:=}"
: "${PM_WAKE_TIMEOUT:=45}"
: "${PM_WAKE_BOOT_DELAY:=5}" "${PM_WAKE_RETRY_INTERVAL:=5}" "${PM_RENDERER_TIMEOUT:=45}"
: "${PM_TEST_MAX_LOOPS:=0}"
: "${PM_PAUSE_DIR:=/tmp/btui/paused}"
: "${PM_RENDERER_DIR:=/tmp/btui/wake}"

[[ "${PM_IDLE_TIMEOUT}" =~ ^[0-9]+$ ]] || PM_IDLE_TIMEOUT=300
[[ "${PM_STOP_DEBOUNCE}" =~ ^[0-9]+$ ]] || PM_STOP_DEBOUNCE=10
[[ "${PM_WAKE_TIMEOUT}" =~ ^[0-9]+$ ]] || PM_WAKE_TIMEOUT=45
[[ "${PM_WAKE_BOOT_DELAY}" =~ ^[0-9]+$ ]] || PM_WAKE_BOOT_DELAY=5
[[ "${PM_WAKE_RETRY_INTERVAL}" =~ ^[0-9]+$ ]] || PM_WAKE_RETRY_INTERVAL=5
[[ "${PM_RENDERER_TIMEOUT}" =~ ^[0-9]+$ ]] || PM_RENDERER_TIMEOUT=45
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

mqtt_args=(-h "${PM_MQTT_HOST}" -p "${PM_MQTT_PORT}")
[ -n "${PM_MQTT_USER}" ] && mqtt_args+=(-u "${PM_MQTT_USER}")
[ -n "${PM_MQTT_PASS}" ] && mqtt_args+=(-P "${PM_MQTT_PASS}")

log() { echo "[power-manager] $*"; }
publish() { timeout 8 mosquitto_pub "${mqtt_args[@]}" -t "${state_topic}" -m "$1" -r >/dev/null 2>&1 || log "MQTT status publish failed"; }
publish_management() { timeout 8 mosquitto_pub "${mqtt_args[@]}" -t "${management_topic}" -m "$1" -r >/dev/null 2>&1 || log "MQTT management-state publish failed"; }
connected() { bluetoothctl info "${PM_MAC}" 2>/dev/null | grep -q '^[[:space:]]*Connected: yes'; }
a2dp_ready() {
  local sink="bluez_sink.${PM_MAC//:/_}.a2dp_sink" sinks
  sinks=$(pactl list short sinks 2>/dev/null) || return 1
  grep -Fq "${sink}" <<<"${sinks}"
}
bluez_state() {
  bluetoothctl info "${PM_MAC}" 2>/dev/null | awk '/^[[:space:]]*(Connected|Paired|Blocked|ServicesResolved):/ { sub(/^[[:space:]]*/, ""); printf "%s;", $0 }'
}
request_a2dp_profile() {
  local card="bluez_card.${PM_MAC//:/_}"
  if pactl set-card-profile "${card}" a2dp_sink >/dev/null 2>&1; then
    log "requested PulseAudio A2DP profile for ${card}"
  else
    log "PulseAudio A2DP profile is not available yet for ${card}"
  fi
}
finish_wake_when_renderer_ready() {
  local pause_marker="$1" renderer_request="$2" renderer_ready="${2}.renderer_ready" deadline
  rm -f "${renderer_ready}"
  if mkdir -p "${PM_RENDERER_DIR}" && printf 'requested\n' > "${renderer_request}"; then
    log "renderer start requested after A2DP readiness"
  else
    log "could not request renderer start after A2DP readiness"
    return 1
  fi
  if rm -f "${pause_marker}"; then
    log "reconnect pause marker cleared after A2DP wake"
  else
    log "failed to clear reconnect pause marker after A2DP wake"
  fi
  mode="renderer_starting"; publish "${mode}"
  deadline=$(( $(date +%s) + PM_RENDERER_TIMEOUT ))
  while [ "$(date +%s)" -lt "${deadline}" ]; do
    if [ -f "${renderer_ready}" ]; then
      rm -f "${renderer_request}" "${renderer_ready}"
      mode="ready"; publish "${mode}"
      log "wake_success: A2DP sink and DLNA renderer are ready"
      return 0
    fi
    sleep 1
  done
  log "wake timed out: DLNA renderer did not confirm readiness within ${PM_RENDERER_TIMEOUT}s"
  rm -f "${renderer_request}" "${renderer_ready}"
  return 1
}
fail_wake() {
  local pause_marker="$1"
  mkdir -p "${PM_PAUSE_DIR}"
  if printf '0\n' > "${pause_marker}"; then
    log "reconnect remains paused after failed wake"
  else
    log "failed to retain reconnect pause after failed wake"
  fi
  if timeout 10 bluetoothctl block "${PM_MAC}" >/dev/null 2>&1; then
    log "Bluetooth reconnect remains blocked after failed wake"
  else
    log "failed to keep Bluetooth reconnect blocked after failed wake"
  fi
  mode="wake_failed"; publish "${mode}"
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

wake() {
  local pause_marker renderer_request deadline attempt retry_delay state
  pause_marker="${PM_PAUSE_DIR}/${PM_MAC^^}"
  renderer_request="${PM_RENDERER_DIR}/${PM_MAC^^}"
  log "wake command received"
  if [ "${idle_deadline}" -gt 0 ] || [ "${stop_debounce_deadline}" -gt 0 ]; then
    log "idle timer cancelled by wake/resume"
  fi
  idle_deadline=0
  stop_debounce_deadline=0
  stop_candidate=""
  # run.sh recognises this existing pause marker and will therefore not race
  # our deliberate disconnect with its legacy reconnect loop.
  if [ -e "${pause_marker}" ]; then
    if rm -f "${pause_marker}"; then
      log "reconnect pause marker cleared"
    else
      log "failed to clear reconnect pause marker"
    fi
  else
    log "reconnect pause marker was not present"
  fi
  if timeout 10 bluetoothctl unblock "${PM_MAC}" >/dev/null 2>&1; then
    log "Bluetooth reconnect block cleared"
  else
    log "Bluetooth unblock request failed or device was already unblocked"
  fi
  # Keep the legacy monitor from issuing a second connect while BLE wake and
  # the Classic/A2DP transition are in progress. wake() removes this marker
  # only once it has observed the A2DP sink itself.
  if mkdir -p "${PM_PAUSE_DIR}" && printf '%s\n' "$(( $(date +%s) + PM_WAKE_TIMEOUT + 15 ))" > "${pause_marker}"; then
    log "reconnect monitor paused while wake waits for A2DP"
  else
    log "failed to pause reconnect monitor during wake"
  fi
  if connected && a2dp_ready; then
    log "A2DP is already available; requesting renderer readiness"
    finish_wake_when_renderer_ready "${pause_marker}" "${renderer_request}" || fail_wake "${pause_marker}"
    return
  fi
  if [ "${PM_BLE_WAKE}" = true ] && [ -n "${PM_ADAPTER_MAC}" ]; then
    mode="ble_waking"; publish "${mode}"
    # Verified UE BOOM 2 frame: controlling adapter MAC in forward order + 01.
    # Convert explicitly to decimal because bluetoothctl's gatt menu expects
    # one quoted argument whose tokens are C-style integer values.
    local bytes=""
    local octet
    for octet in ${PM_ADAPTER_MAC//:/ }; do bytes+="$((16#${octet})) "; done
    bytes+="1"
    log "BLE wake enabled; requesting GATT connection (payload: ${bytes})"
    if timeout 12 bluetoothctl connect "${PM_MAC}" >/dev/null 2>&1; then
      log "Bluetooth connection request for BLE wake accepted"
    else
      log "Bluetooth connection request for BLE wake failed; attempting the configured GATT write once"
    fi
    sleep 1
    local ble_output ble_status
    ble_output=$(printf 'menu gatt\nselect-attribute c6d6dc0d-07f5-47ef-9b59-630622b01fd3\nwrite "%s"\nquit\n' "${bytes}" | timeout 12 bluetoothctl 2>&1) || ble_status=$?
    ble_status=${ble_status:-0}
    if [ "${ble_status}" -eq 0 ] && ! grep -Eqi 'failed|error|invalid|too many|not available' <<<"${ble_output}"; then
      log "BLE wake write accepted by bluetoothctl; waiting for the speaker to switch to Classic audio"
    else
      log "BLE wake write was rejected or timed out (bluetoothctl exit ${ble_status})"
    fi
    # The speaker needs time to boot its Classic radio after accepting the
    # GATT frame.  Releasing a transient LE link avoids asking BlueZ to use
    # the already-connected BLE bearer for the following Classic request.
    log "waiting ${PM_WAKE_BOOT_DELAY}s for the speaker to boot Classic audio"
    sleep "${PM_WAKE_BOOT_DELAY}"
    if connected; then
      if timeout 8 bluetoothctl disconnect "${PM_MAC}" >/dev/null 2>&1; then
        log "released transient BLE connection before Classic handover"
      else
        log "transient BLE release was not accepted; continuing with Classic handover"
      fi
      sleep 1
    else
      log "BLE link already released by the speaker before Classic handover"
    fi
  else
    log "BLE wake skipped (ble_wake_enabled=${PM_BLE_WAKE}, adapter MAC configured=$([ -n "${PM_ADAPTER_MAC}" ] && echo yes || echo no))"
  fi
  mode="waiting_for_classic"; publish "${mode}"
  deadline=$(( $(date +%s) + PM_WAKE_TIMEOUT ))
  attempt=0
  while [ "$(date +%s)" -lt "${deadline}" ]; do
    attempt=$((attempt + 1))
    state=$(bluez_state)
    log "Classic handover attempt ${attempt}; BlueZ state: ${state:-unavailable}"
    if timeout 12 bluetoothctl connect "${PM_MAC}" >/dev/null 2>&1; then
      log "Classic audio connection attempt ${attempt} accepted"
    else
      log "Classic audio connection attempt ${attempt} not accepted; retrying while within ${PM_WAKE_TIMEOUT}s budget"
    fi
    request_a2dp_profile
    if connected && a2dp_ready; then
      mode="waiting_for_a2dp"; publish "${mode}"
      log "A2DP sink is ready; waiting for the DLNA renderer handover"
      finish_wake_when_renderer_ready "${pause_marker}" "${renderer_request}" || fail_wake "${pause_marker}"
      return
    fi
    retry_delay=$(( PM_WAKE_RETRY_INTERVAL * attempt ))
    [ "${retry_delay}" -gt 15 ] && retry_delay=15
    log "A2DP sink is not ready yet; next Classic attempt in ${retry_delay}s"
    sleep "${retry_delay}"
  done
  log "wake timed out: no A2DP sink became available within ${PM_WAKE_TIMEOUT}s"
  fail_wake "${pause_marker}"
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
cleanup() { clear_discovery; }
if [ "${PM_TEST_MAX_LOOPS}" -eq 0 ]; then
  trap cleanup EXIT
  trap 'cleanup; exit 0' INT TERM
fi
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
    mkdir -p "${PM_PAUSE_DIR}"
    printf '0\n' > "${PM_PAUSE_DIR}/${PM_MAC^^}"
    log "reconnect pause marker set before idle disconnect"
    if bluetoothctl disconnect "${PM_MAC}" >/dev/null 2>&1; then
      log "A2DP disconnected after idle timeout"
    else
      log "A2DP disconnect request failed or speaker was already disconnected"
    fi
    # Block after the explicit disconnect as a second line of defence against
    # the legacy monitor. Pairing remains intact and wake() reverses this.
    if bluetoothctl block "${PM_MAC}" >/dev/null 2>&1; then
      log "reconnect blocked after idle timeout"
    else
      log "failed to block reconnect after idle timeout"
    fi
    mode="idle_disconnected"; publish "${mode}"
  fi
  loop_count=$((loop_count + 1))
  if [ "${PM_TEST_MAX_LOOPS}" -gt 0 ] && [ "${loop_count}" -ge "${PM_TEST_MAX_LOOPS}" ]; then
    log "test loop limit reached; exiting"
    exit 0
  fi
done
