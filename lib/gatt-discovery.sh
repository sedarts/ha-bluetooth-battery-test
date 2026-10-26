#!/usr/bin/env bash
# Parse the result of UUID-filtered gatttool characteristic discovery.
# Noninteractive BlueZ uses '=', interactive BlueZ uses ':'. No eval, fixed
# handles, substring UUID matches, or first-match selection is safe here.
parse_gatt_discovery() {
  local discovery="$1" expected_uuid="${2,,}" line count=0 declaration value properties uuid
  local record='^[[:space:]]*handle[[:space:]]*[:=][[:space:]]*(0x[0-9a-f]{1,4})[[:space:]]*,[[:space:]]*char[[:space:]]+properties[[:space:]]*[:=][[:space:]]*(0x[0-9a-f]{1,2})[[:space:]]*,[[:space:]]*char[[:space:]]+value[[:space:]]+handle[[:space:]]*[:=][[:space:]]*(0x[0-9a-f]{1,4})[[:space:]]*,[[:space:]]*uuid[[:space:]]*[:=][[:space:]]*([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})[[:space:]]*$'
  GATT_VALUE_HANDLE=""
  GATT_PROPERTIES=""
  GATT_PARSE_ERROR=""
  while IFS= read -r line || [ -n "${line}" ]; do
    line="${line,,}"
    [[ "${line}" =~ ^[[:space:]]*$ ]] && continue
    if [[ ! "${line}" =~ ${record} ]]; then
      GATT_PARSE_ERROR="incomplete or unexpected characteristic record"
      return 1
    fi
    declaration="${BASH_REMATCH[1]}"
    properties="${BASH_REMATCH[2]}"
    value="${BASH_REMATCH[3]}"
    uuid="${BASH_REMATCH[4]}"
    if [ "${uuid}" != "${expected_uuid}" ]; then
      GATT_PARSE_ERROR="UUID mismatch in filtered discovery"
      return 1
    fi
    if (( declaration == 0 || value <= declaration )); then
      GATT_PARSE_ERROR="invalid declaration/value handle ordering"
      return 1
    fi
    count=$((count + 1))
    if [ "${count}" -gt 1 ]; then
      GATT_PARSE_ERROR="ambiguous characteristic discovery"
      return 1
    fi
  done <<<"${discovery}"
  if [ "${count}" -ne 1 ]; then
    GATT_PARSE_ERROR="no characteristic record"
    return 1
  fi
  printf -v GATT_VALUE_HANDLE '0x%04x' "$((value))"
  printf -v GATT_PROPERTIES '0x%02x' "$((properties))"
}
