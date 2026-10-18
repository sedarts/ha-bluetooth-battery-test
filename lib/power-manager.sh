#!/usr/bin/env bash
# MQTT controlled, opt-in power manager for one primary speaker.
# It deliberately never sends a BLE power-off command: idle means A2DP
# disconnect only, allowing speakers with their own sleep timer to power down.
set -u -o pipefail

: "${PM_MAC:?}" "${PM_NAME:?}" "${PM_ENABLED:=false}" "${PM_IDLE_TIMEOUT:=300}" "${PM_STOP_DEBOUNCE:=10}"
: "${PM_BLE_WAKE:=false}" "${PM_ADAPTER_MAC:=}" "${PM_MQTT_HOST:=}"
: "${PM_MQTT_PORT:=1883}" "${PM_MQTT_USER:=}" "${PM_MQTT_PASS:=}"

[[ "${PM_IDLE_TIMEOUT}" =~ ^[0-9]+$ ]] || PM_IDLE_TIMEOUT=300
[[ "${PM_STOP_DEBOUNCE}" =~ ^[0-9]+$ ]] || PM_STOP_DEBOUNCE=10

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
  if [ "${idle_deadline}" -gt 0 ] || [ "${stop_debounce_deadline}" -gt 0 ]; then
    log "idle timer cancelled by wake/resume"
  fi
  idle_deadline=0
  stop_debounce_deadline=0
  stop_candidate=""
  # run.sh recognises this existing pause marker and will therefore not race
  # our deliberate disconnect with its legacy reconnect loop.
  rm -f "/tmp/btui/paused/${PM_MAC^^}"
  bluetoothctl unblock "${PM_MAC}" >/dev/null 2>&1 || true
  if connected; then mode="connected"; publish "${mode}"; return; fi
  if [ "${PM_BLE_WAKE}" = true ] && [ -n "${PM_ADAPTER_MAC}" ]; then
    # Verified UE BOOM 2 frame: controlling adapter MAC in forward order + 01.
    # Convert explicitly to decimal because bluetoothctl's gatt menu expects
    # one quoted argument whose tokens are C-style integer values.
    local bytes=""
    local octet
    for octet in ${PM_ADAPTER_MAC//:/ }; do bytes+="$((16#${octet})) "; done
    bytes+="1"
    log "sending configured BLE wake request"
    bluetoothctl connect "${PM_MAC}" >/dev/null 2>&1 || true
    sleep 1
    printf 'menu gatt\nselect-attribute c6d6dc0d-07f5-47ef-9b59-630622b01fd3\nwrite "%s"\nquit\n' "${bytes}" | bluetoothctl >/dev/null 2>&1 || log "BLE wake request was not accepted"
    # A successful UE BOOM 2 wake commonly drops the BLE link; do not treat
    # that disconnect as failure. The following Classic connection verifies it.
    sleep 2
  fi
  if bluetoothctl connect "${PM_MAC}" >/dev/null 2>&1; then mode="connected"; else mode="wake_failed"; fi
  publish "${mode}"
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
  case "$1" in
    wake|resume) wake ;;
    idle|disconnect) enter_idle explicit_command ;;
    enable) PM_ENABLED=true; publish_management enabled; mode="connected"; publish "${mode}" ;;
    disable) PM_ENABLED=false; idle_deadline=0; stop_debounce_deadline=0; stop_candidate=""; publish_management disabled; mode="disabled"; publish "${mode}" ;;
    *) log "ignored unknown command" ;;
  esac
}

if [ -z "${PM_MQTT_HOST}" ]; then log "MQTT not configured; power management unavailable"; exit 0; fi
trap clear_discovery EXIT INT TERM
publish_discovery
[ "${PM_ENABLED}" = true ] && publish_management enabled || publish_management disabled

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
    mkdir -p /tmp/btui/paused
    printf '0\n' > "/tmp/btui/paused/${PM_MAC^^}"
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
done
