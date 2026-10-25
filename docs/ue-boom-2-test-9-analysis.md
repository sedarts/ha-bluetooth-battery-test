# UE BOOM 2 BLE history and connection-contention analysis

Status: local test.9 analysis and implementation, based on active repository
commit `c1fba5835b44dcc4aa49921239d6803908865da5` (`2.6.2-test.8`). The local
worktree is modified and uncommitted; no push or deployment was performed. No
command was sent to the currently powered-off speaker. The implementation and
test record are summarized below; the protocol history above is retained.

## Historical wake evidence

The 2026-10-18 user-provided project brief records a successful wake while the
BOOM was off. It identifies `bluetoothctl` and the GATT characteristic path
`/org/bluez/hci0/dev_C0_28_8D_82_F7_BB/service0001/char0002`, UUID
`c6d6dc0d-07f5-47ef-9b59-630622b01fd3`, and reports the command:

```text
write "140 104 171 224 63 246 1"
```

The brief says the startup tone played, the LED lit, and the speaker was then
on. It also records BlueZ output immediately after the write:

```text
Attempting to write .../char0002
ServicesResolved: no
LE Public disconnected with reason 3
LE.Connected: no
```

This is meaningful physical evidence that a BLE-triggered wake succeeded at
least once. The most likely command linked to it is the GATT `write`, because
the brief says the disconnect followed the write and reports the physical
reaction in the same test narrative. But the underlying timestamped terminal
transcript/audio timestamp is not present in the repository or attachment
record, so exact causality and timing cannot be independently reconstructed.
The disconnect is consistent with a successful wake transition; alone, it
would not prove one.

The exact preceding manual connection sequence is not recorded in that brief:
it does not say whether a Classic/BLE disconnect, explicit `connect`, scan, or
bearer selection happened first. The first implementation committed later on
2026-10-18 shows the sequence the software then used, based on that earlier
successful finding: `bluetoothctl connect <speaker>`, wait 1 second, enter
`menu gatt`, select the characteristic by UUID, issue the decimal `write`,
`quit`, wait 2 seconds, then issue another `bluetoothctl connect` for the
post-wake audio transition. This is evidence of the implementation sequence,
not a raw transcript proving every preceding manual action in the original
successful hardware test.

A later test.3 user-provided report records these power-manager logs:

```text
Bluetooth connection request for BLE wake accepted
BLE wake write accepted by bluetoothctl; waiting for the speaker to switch to Classic audio
```

and explicitly says the BOOM physically turned on without pressing its power
button. That supports the earlier result, but the software log lines by
themselves are not proof: the old implementation inferred acceptance from a
zero process status and no matching error text, and the actual physical
observation is the separate user statement.

## Comparison with later attempts

The successful historical record uses the interactive BlueZ-managed
`bluetoothctl` GATT menu and a `write` with no explicit write type (BlueZ's
default is a Write Request). No explicit `bearer` command or pre-write
disconnect is documented there.

The later test.7 implementation added a pre-disconnect, an explicit
`bearer <MAC> le`, `attribute-info`, and `write ... 0 command`. In the actual
test.7 hardware output, `bearer` was rejected by that installed CLI, while the
characteristic was found with `Flags: write`; only `Attempting to write ...`
was seen and the speaker stayed off. This was not the same procedure as the
earlier reported success: it selected a different write type and attempted an
unsupported bearer command.

Test.8 replaced the GATT-menu write with `gatttool` discovery/write. The
reported failure is before characteristic discovery or payload transmission:
`connect ... Resource busy (16)`. Thus test.8 provides no evidence for or
against the wake payload's physical effect; it failed to establish the
connection needed to send it.

## Connection and race analysis in test.8 source

Verified from the current source:

- `run.sh:223-239` defines `connect_speaker()` and calls `bluetoothctl power on`
  and `bluetoothctl connect`. At startup, `run.sh` invokes it synchronously
  before starting the power manager and monitor (`run.sh:331-340`). It then
  checks A2DP readiness (`run.sh:341-342`). The log `UE BOOM 2 connected.` only
  means the `bluetoothctl connect` command returned success; it is not proof
  that A2DP exists.
- The background `monitor_speaker()` retries on its configured reconnect
  interval. If `Connected: yes` plus the A2DP sink is not present, it calls
  `recover_renderer_after_connect()` (`run.sh:460-484`). That function uses an
  atomic directory lock for monitor recovery only (`lib/renderer-recovery.sh:69-97`).
- The power manager writes its pause marker before invoking `ble_power_command`
  (`lib/power-manager.sh:191-207`). The monitor checks the pause marker before
  starting recovery, and the recovery helper checks it before and after taking
  its own lock. This closes the normal monitor path when the marker is already
  visible.
- The pause marker is not a shared Bluetooth-operation lock. If a monitor
  recovery has already passed its second pause check and started
  `connect_speaker()`, the BLE wake can proceed while that call is in flight.
  The initial synchronous startup connection is also outside the monitor's
  recovery lock. The current lock does not cover power-manager `gatttool`.
- `ble_power_command()` calls `bluetoothctl disconnect` and immediately starts
  `gatttool` (`lib/power-manager.sh:61-72`). It does not wait until BlueZ
  reports the link disconnected, and no shared lock prevents a concurrent
  connect. `gatttool` is the deprecated direct ATT client, unlike
  `bluetoothctl`'s BlueZ D-Bus path; using it while BlueZ owns or is changing a
  connection is a plausible explanation for `Resource busy (16)`, but that
  error alone does not identify which process or link state caused `EBUSY`.
- `bluetoothctl info` and PulseAudio sink checks run in the monitors and
  power-manager readiness loop. These are status reads, not themselves proof
  of a competing connection attempt. The battery monitor is documented as
  read-only for Bluetooth connections. Web UI pairing/discovery activity and
  other Home Assistant Bluetooth clients were not captured in the supplied
  logs.

## Evidence classification and next test.9 work

**Nachgewiesen:** a historical `bluetoothctl` GATT-menu `write` was reported
alongside the BOOM's startup tone and lit LED; test.7's `bearer` command was
rejected; test.8's `gatttool` failed with `Resource busy (16)` before a write;
the add-on has a startup connection and a periodic reconnect path; the
reconnect lock is not shared with BLE operations.

**Plausible, not established:** test.8's raw ATT connection encountered an
existing/in-flight connection or controller ownership conflict. A monitor
reconnect may overlap the BLE attempt in the narrow window after its pause
check. The startup Classic connection explains why an initial `Connected`
message can appear with no A2DP, but does not prove that it caused the later
`EBUSY`.

**Requires hardware/log capture:** identify the owner/state at the exact
`Resource busy` timestamp; determine whether a monitor `bluetoothctl connect`
was in flight; verify whether an explicit disconnect had completed in BlueZ;
and repeat the historical BlueZ-managed GATT Request only after the currently
off BOOM's status and a controlled test window are confirmed. Preserve a
timestamped full add-on log and, if available, BlueZ/btmon connection events.
Do not send an unverified command merely to reproduce the old tone.

The resulting test.9 direction is a single adapter-operation lock shared by
startup/reconnect and BLE wake, with an explicit handoff that waits a bounded
time for an in-flight Classic operation before GATT starts. A BlueZ-managed
GATT Write Request remains preferable if the project can report its result
reliably; this change retains `gatttool` pending hardware validation. The
implementation does not stop `bluetoothd`, reset the adapter, or infer physical
ON/OFF from A2DP or `Connected` alone. It observes an already-on speaker at
startup without auto-connecting an off/unknown speaker when BLE wake is
enabled.

## Local test.9 implementation and validation

Implemented locally:

- New shared `lib/bluetooth-ops.sh` adapter lock with bounded wait, pause checks
  both before and after lock acquisition, per-operation ID, millisecond log
  timestamp, and explicit acquired/released/timeout messages. `flock` is added
  to the Alpine image.
- The lock now covers startup and monitor Classic connect, the complete
  BLE/GATT operation, idle BLE/disconnect/block sequence, web pairing/scan
  sessions, and web pairing trust/connect. The existing renderer recovery
  lock and renderer code remain in place.
- BLE-enabled startup observes an already-present A2DP sink but suppresses
  blind auto-connect to an off/unknown speaker. Automatic reconnects are
  suppressed without an explicit wake; wake gets at most three BLE attempts
  (retries only for reported Resource busy) and four Classic/A2DP monitor
  attempts against one 90-second deadline. Sink presence, not `Connected: yes`
  alone, gates readiness. Exhaustion enters `error`; later explicit MQTT wake
  clears the error and starts a new series.
- GATT Write Request requires the returned confirmation text; Write Command is
  logged only as submitted because that ATT procedure has no response.
  `POWER_STATE_UNKNOWN` remains the only physical power-off conclusion absent
  independent observation. Idle timeout remains 300 seconds.
- Added Git-tracked protocol, state-machine, historical test, and known-issue
  docs. The earlier Plong report is preserved as a reported but not fully
  reproducible success; test.7/test.8 gaps remain explicit.

Automated tests run locally: shell syntax, power-manager smoke (including
Resource busy retries and a new wake after ERROR), renderer recovery smoke,
Bluetooth operation serialization/pause/release smoke, and `git diff --check`.
The lock test uses a local shim because Windows/Git Bash has no `flock`; it does
not verify Alpine/Linux kernel lock behavior or process-death release. Docker
is unavailable in this environment, so image build/package validation remains
open. No result here is a hardware result. See `docs/bluetooth/` for protocols,
test-history entries, risks, and the next controlled hardware check.
