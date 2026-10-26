# Bluetooth power and connection state

The implementation distinguishes what can be observed from physical power:

| State | Observable meaning | Reconnect policy |
| --- | --- | --- |
| `OFF` / unknown at startup | No usable A2DP sink; physical power not inferable | If BLE wake is enabled, no automatic connect |
| `WAKING` | Explicit MQTT wake accepted; monitor paused and shared operation lock acquired | Up to 3 BLE attempts, within the global wake deadline |
| `CONNECTING` | Wake handover is active and Classic/A2DP is being recovered | Up to 4 monitor attempts; sink, not just BlueZ `Connected`, is required |
| `READY` | A2DP sink exists and the existing renderer handover is acknowledged | Existing playback behavior; idle policy unchanged |
| `POWERING_OFF` | Idle operation is sending the configured BLE off frame and cleaning up Classic | Common lock; physical outcome remains unconfirmed |
| `ERROR` | A wake series failed or exhausted its bounded attempts | Automatic reconnect suppressed until a new explicit wake; MQTT consumer remains active |
| `POWER_STATE_UNKNOWN` | Link was disconnected / power command submitted, but no physical readback exists | Do not claim the speaker is physically off |

## Serialization and timing

`lib/bluetooth-ops.sh` provides a finite-wait `flock` for bridge-owned adapter
operations. The add-on installs Alpine's `flock` utility. Classic connect,
BLE discovery/write, idle disconnect/block, and web UI scan/pair-connect paths
use the same adapter lock file. A wake pause is published before lock wait;
reconnect acquisition checks it both before and after lock acquisition. The
operating system releases the lock when a process exits. The test mock verifies
ordering and ordinary release, not Linux process-death semantics.

Wake's 90-second deadline begins when the explicit command is handled and is
shared with the monitor through the handover request. BLE GATT commands have
five-second per-command bounds, three maximum attempts, and one-second
backoff only for `Resource busy`; the wake shared-lock wait is bounded at 18 seconds
(idle teardown waits at most 20 seconds for an in-flight Classic command).
The Classic series has four maximum attempts, uses short per-command/sink
checks, and checks the same deadline before each attempt. Four attempts are a
maximum, not a promise that all four run if BLE/lock time consumes the budget.
These are software bounds, not measured speaker timing. If the device cannot
become A2DP-ready in that budget, state becomes `error` and no endless retry
follows. The configured boot delay is shortened if needed to reserve time for
Classic recovery rather than extending the global deadline.

With BLE wake enabled, add-on startup still inspects the real connection/sink
and starts the existing renderer if A2DP is already available. It does not
blindly connect an off/unknown speaker. This requires the MQTT host to be
configured for the power manager and wake button; the manager remains running
after an ERROR state.

Renderer recovery, A2DP sink naming, Music Assistant, SSDP, 300-second idle
timeout, and 10-second stop debounce are retained.

## Local test.10 candidate

No states or transition owners change. Within the shared lock, the BLE path is:
target disconnect (bounded/logged) -> one-shot discovery -> validate exactly
one complete UUID match -> write the **value** handle -> verify ATT request
response -> target release -> existing Classic/A2DP handover. The intermediate
discovery and write remain separate connections. Rejected discovery, ATT
failure or absent request confirmation returns to the existing bounded/error
path. Ordinary failures release the shared lock and leave the reconnect pause
in place; a later explicit wake may retry. Physical power remains unknown.

No Bluetooth operation or sleep is inserted between successful discovery and
write; only local parsing and timestamped log output occur there. The existing
one-second busy retry backoff is unchanged. Retaining the MQTT process after
ERROR is distinct from continuous subscription: reception gaps and the
cooperative deadline limitation are documented in [KNOWN-ISSUES.md](KNOWN-ISSUES.md).

`flock` is a small util-linux file-locker available in the Alpine 3.18 package
repository; the container image adds that package. [Alpine package record](https://pkgs.alpinelinux.org/package/v3.18/main/x86_64/flock).
