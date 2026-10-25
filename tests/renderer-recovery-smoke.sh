#!/usr/bin/env bash
# Dependency-free tests for the short A2DP readiness path and reconnect lock.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
. "$root/lib/renderer-recovery.sh"

ensure_calls=0
renderer_starts=0
sleep_calls=0
ready_after=1

bashio::log.info() { :; }
bashio::log.warning() { :; }
ensure_audio_sink() { ensure_calls=$((ensure_calls + 1)); }
connect_speaker() { :; }
start_renderer() { renderer_starts=$((renderer_starts + 1)); }
sleep() { sleep_calls=$((sleep_calls + 1)); }
bluetoothctl() {
    if [ "$1" = info ]; then
        printf 'Connected: yes\n'
    fi
}
pactl() {
    if [ "${ready_after}" -gt 0 ] && [ "${ensure_calls}" -ge "${ready_after}" ]; then
        printf '1\tbluez_sink.C0_28_8D_82_F7_BB.a2dp_sink\tmodule-bluez5-device.c\n'
    fi
}

# A ready A2DP sink starts the existing renderer on the first check.
recover_renderer_after_connect C0:28:8D:82:F7:BB 'UE BOOM 2' \
    bluez_sink.C0_28_8D_82_F7_BB.a2dp_sink bluez_card.C0_28_8D_82_F7_BB \
    "$tmp/not-paused" "$tmp/locks/boom" 5
[ "$ensure_calls" -eq 1 ]
[ "$renderer_starts" -eq 1 ]
[ "$sleep_calls" -eq 0 ]

# A power-manager handover interrupts the normal 30-second monitor interval.
# A paused speaker does not consume the request; removing the pause lets the
# same pending wake request interrupt immediately.
mkdir -p "$tmp/wake" "$tmp/pause"
: > "$tmp/wake/request"
: > "$tmp/pause/speaker"
sleep_calls=0
wake_request_consumed=false
sleep() {
    sleep_calls=$((sleep_calls + 1))
    if [ "$sleep_calls" -eq 2 ]; then
        rm -f "$tmp/pause/speaker"
    fi
}
wait_for_reconnect_or_wake "$tmp/wake/request" "$tmp/pause/speaker" 30
[ "$sleep_calls" -eq 2 ]
[ "$wake_request_consumed" = true ]
sleep() { sleep_calls=$((sleep_calls + 1)); }

# A missing sink gets only four one-second waits for five checks, then returns
# failure so the regular reconnect monitor can retry on its normal interval.
ensure_calls=0
ready_after=999
sleep_calls=0
if recover_renderer_after_connect C0:28:8D:82:F7:BB 'UE BOOM 2' \
    bluez_sink.C0_28_8D_82_F7_BB.a2dp_sink bluez_card.C0_28_8D_82_F7_BB \
    "$tmp/not-paused" "$tmp/locks/boom" 5; then
    echo 'expected missing A2DP sink to fail bounded recovery' >&2
    exit 1
fi
[ "$ensure_calls" -eq 5 ]
[ "$sleep_calls" -eq 4 ]
[ "$renderer_starts" -eq 1 ]

# Competing monitor processes cannot both connect or start a renderer for the
# same speaker.
ensure_calls=0
ready_after=1
lock="$tmp/locks/parallel"
operations="$tmp/operations"
connect_speaker() {
    printf 'connect\n' >> "$operations"
    command sleep 0.4
}
start_renderer() { printf 'renderer\n' >> "$operations"; }
(
    recover_renderer_after_connect C0:28:8D:82:F7:BB 'UE BOOM 2' \
        bluez_sink.C0_28_8D_82_F7_BB.a2dp_sink bluez_card.C0_28_8D_82_F7_BB \
        "$tmp/not-paused" "$lock" 5
) &
first_pid=$!
for _ in {1..100}; do
    [ -s "$lock/pid" ] && break
    command sleep 0.01
done
if recover_renderer_after_connect C0:28:8D:82:F7:BB 'UE BOOM 2' \
    bluez_sink.C0_28_8D_82_F7_BB.a2dp_sink bluez_card.C0_28_8D_82_F7_BB \
    "$tmp/not-paused" "$lock" 5; then
    echo 'second reconnect unexpectedly started' >&2
    exit 1
fi
wait "$first_pid"
[ "$(wc -l < "$operations")" -eq 2 ]
[ "$(grep -c '^connect$' "$operations")" -eq 1 ]
[ "$(grep -c '^renderer$' "$operations")" -eq 1 ]

echo 'renderer recovery smoke test: PASS'
