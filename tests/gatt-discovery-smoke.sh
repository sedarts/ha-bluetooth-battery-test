#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
. "$root/lib/gatt-discovery.sh"
uuid=c6d6dc0d-07f5-47ef-9b59-630622b01fd3
original=$(<"$root/tests/fixtures/gatttool-test9-discovery.txt")
cases=0
accept() {
  parse_gatt_discovery "$1" "$uuid" || { echo "unexpected rejection: $GATT_PARSE_ERROR" >&2; exit 1; }
  [ "$GATT_VALUE_HANDLE" = 0x0003 ] && [ "$GATT_PROPERTIES" = 0x08 ]
  cases=$((cases + 1))
}
reject() {
  if parse_gatt_discovery "$1" "$uuid"; then
    echo "unsafe discovery accepted: $1" >&2; exit 1
  fi
  [ -z "$GATT_VALUE_HANDLE" ] && [ -z "$GATT_PROPERTIES" ] && [ -n "$GATT_PARSE_ERROR" ]
  cases=$((cases + 1))
}
accept "$original"
accept "${original// = /: }"
accept "${original^^}"
accept $' \thandle=0x2 , char\tproperties : 0x8 , char value handle=0x3,uuid=C6D6DC0D-07F5-47EF-9B59-630622B01FD3\r\n'
reject ''
reject "${original/b01fd3/b01fd4}"
reject "${original}0"
reject "${original}"$'\n'"${original}"
reject "${original}"$'\n'"${original/0x0003/0x0004}"
reject "${original/char value handle = 0x0003, /}"
reject "${original/char properties = 0x08, /}"
reject "${original/0x0003/0x0000}"
reject "${original/0x0003/0x0002}"
reject "${original/0x0003/0x10003}"
reject "${original/0x08/0x108}"
reject "${original/0x0003/0xGGGG}"
reject "${original}, unexpected = 1"
reject "warning: unexpected output"$'\n'"${original}"
# A previous successful parse must never leak its handle into a failed parse.
accept "$original"
reject "${original/b01fd3/b01fd4}"
printf 'gatt discovery smoke test: PASS (%s cases)\n' "$cases"
