# UE BOOM 2 power-off readiness: 2.6.2-test.14

Date: 2026-10-27

## Root cause

The successful test.13 wake uses a bounded BlueZ `bluetoothctl` GATT session.
Power-off still used the older direct `gatttool` path. That path first required
BlueZ to report `Connected: no`, because the bridge could not prove ownership
of a reported connection and was correctly forbidden from disconnecting it.
During normal playback the Classic/A2DP bearer keeps `Device1.Connected: yes`,
so power-off always stopped at the ownership gate before any GATT write.

## Targeted correction

- The test.13 wake function, UUID, handle, `01` payload and Classic/A2DP
  handover are unchanged.
- Power-off now opens a bounded BlueZ-managed GATT session, selects the same
  known characteristic and submits the paired-controller payload ending in
  `02`. `Connected: yes` is logged but is not treated as a GATT veto.
- No device-wide disconnect occurs before the write. Classic disconnect and
  reconnect blocking occur only after the write transcript confirms that the
  request reached `/service0001/char0002`.
- A failed or unconfirmed write publishes `power_off_failed`, keeps A2DP
  connected, removes the reconnect pause and does not block reconnection.
- Existing resource-busy retries remain limited to three attempts. Other
  failures are not repeated because repeated unknown power writes have not
  been proven safe.
- The idle timeout is 30 seconds with the existing 10-second debounce. Since
  Supervisor retains old option values, the former persisted default of 300
  seconds is migrated to 30 seconds at runtime for this test release.

## Software verification

- Shell syntax: `run.sh`, `lib/*.sh`, Web UI shell/CGI and `tests/*.sh` PASS.
- GATT discovery parser: 20/20 cases PASS.
- Power-manager smoke suite PASS, including unchanged wake `01`, new off `02`,
  no pre-write disconnect, failed-off A2DP preservation, reconnect-pause
  removal and playback cancellation of the pending idle sequence.
- Bluetooth coordination smoke PASS.
- Renderer recovery smoke PASS.
- BLE disconnect/ownership smoke PASS.
- `git diff --check` PASS.

The Linux process suite is not executable in the local Windows environment.
Its existing test.13 CT 215 result must not be presented as a new test.14 run.
The new code continues to use the already tested bounded process supervisor,
but Alpine process behavior and physical BLE behavior remain hardware gates.

## Hardware gate

After installation, leave playback continuously idle and verify:

1. the 10-second debounce log;
2. `idle timer started for 30s`;
3. a BlueZ GATT write with the unchanged UUID and payload ending `02` at about
   40 seconds after the original idle transition;
4. the physical power-off tone and all BOOM LEDs turning off;
5. Classic cleanup and reconnect blocking only after the submitted write;
6. a subsequent Home Assistant wake still produces PLONG, A2DP and renderer
   readiness.

Also force one controlled write failure. The expected result is
`power_off_failed`, no Classic disconnect, no `block`, a cleared reconnect
pause, and continued usability. A submitted write is not proof of physical
shutdown; LED and tone observation are required.
