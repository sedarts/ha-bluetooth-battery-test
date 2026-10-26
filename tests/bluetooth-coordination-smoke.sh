#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat >"$tmp/bin/flock" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = -u ]; then rmdir "${BT_OPS_LOCK_FILE}.held" 2>/dev/null || true; exit 0; fi
limit=0
if [ "${1:-}" = -w ]; then limit="$2"; shift 2; else shift; fi
start=$SECONDS
while ! mkdir "${BT_OPS_LOCK_FILE}.held" 2>/dev/null; do
  [ "$((SECONDS - start))" -ge "$limit" ] && exit 1
  command sleep 0.02
done
EOF
chmod +x "$tmp/bin/flock"
PATH="$tmp/bin:$PATH"
export PATH BT_OPS_LOCK_FILE="$tmp/hci0.lock"
. "$root/lib/bluetooth-ops.sh"
. "$root/lib/wake-retries.sh"

# A queued Classic operation must wait for the BLE owner, and the trace proves
# that the second owner only enters after the first one releases.
(
  bt_ops_acquire ble-test 2
  printf 'ble-start\n' >>"$tmp/order"
  command sleep 0.2
  printf 'ble-end\n' >>"$tmp/order"
  bt_ops_release
) &
first=$!
while [ ! -e "${BT_OPS_LOCK_FILE}.held" ]; do command sleep 0.01; done
bt_ops_acquire classic-test 2
printf 'classic-start\n' >>"$tmp/order"
bt_ops_release
wait "$first"
[ "$(tr '\n' ' ' <"$tmp/order")" = 'ble-start ble-end classic-start ' ]

# A wake pause may arrive while a reconnect is already holding the shared
# lock. The queued operation obtains and releases the lock, then must yield.
rm -f "${BT_OPS_LOCK_FILE}.held"
(
  bt_ops_acquire running-classic 2
  : >"$tmp/classic-held"
  command sleep 0.3
  bt_ops_release
) &
first=$!
while [ ! -e "$tmp/classic-held" ]; do command sleep 0.01; done
(command sleep 0.1; : >"$tmp/late-pause") &
pause_writer=$!
if bt_ops_acquire queued-reconnect 2 "$tmp/late-pause"; then
  echo 'queued reconnect ignored pause that arrived while waiting' >&2
  exit 1
else
  [ "$?" -eq 2 ]
fi
wait "$first"
wait "$pause_writer"

# Pause is checked both before and after waiting; lock is released after an
# operation failure when the caller runs its normal cleanup path.
: >"$tmp/paused"
if bt_ops_acquire paused-test 0 "$tmp/paused"; then
  echo 'pause guard unexpectedly acquired the Bluetooth lock' >&2
  exit 1
else
  [ "$?" -eq 2 ]
fi
rm -f "$tmp/paused"
bt_ops_acquire failure-test 1
false || failure_status=$?
bt_ops_release
[ "${failure_status:-1}" -eq 1 ]
[ ! -e "${BT_OPS_LOCK_FILE}.held" ]

retry_count=0
retry_attempt() { retry_count=$((retry_count + 1)); }
retry_not_ready() { return 1; }
retry_failed() { [ "$1" -eq 4 ] && [ "$2" -eq 4 ]; }
if run_classic_wake_retries 4 0 retry_attempt retry_not_ready retry_failed; then
  echo 'Classic wake retry series unexpectedly succeeded' >&2
  exit 1
fi
[ "$retry_count" -eq 4 ]
retry_count=0
retry_ready_after_two() { [ "$retry_count" -ge 2 ]; }
if ! run_classic_wake_retries 4 0 retry_attempt retry_ready_after_two retry_failed; then
  echo 'Classic wake retry series did not stop on A2DP readiness' >&2
  exit 1
fi
[ "$retry_count" -eq 2 ]
echo 'bluetooth coordination smoke test: PASS'
