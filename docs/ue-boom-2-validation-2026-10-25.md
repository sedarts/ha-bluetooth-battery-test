# UE BOOM 2: A2DP-to-renderer startup delay

Date: 2026-10-25. This change is local to `sedarts/ha-bluetooth-battery-test`.
No Home Assistant deployment or version bump was made.

## Build baseline

The active development checkout is `battery-test-repo-inspect-sedarts`, remote
`https://github.com/sedarts/ha-bluetooth-battery-test`. Its base commit is
`251698a10eafd6a199f70f3ddc18507121c3597f`; `config.yaml` identifies the add-on
as **Bluetooth Audio Bridge 2.6.2 Test**, version `2.6.2-test.5`, and the top
changelog entry is `2.6.2-test.5`. This is the source baseline the user
confirmed is installed on Home Assistant. The working tree already contained
the earlier local, uncommitted diagnostic and power-manager changes before
this delay fix; those were retained.

The legacy `dcybeldesign/ha-mpd-bluetooth-bridge` checkout and the separate
`sedarts/ha-mpd-bluetooth-bridge` checkout were not modified.

## Diagnosis and change

The renderer monitor sleeps for the configured reconnect interval (30 seconds
by default) before each check. The power manager already creates a per-speaker
renderer handover request after BLE/boot handling, but that request did not
wake a monitor currently in that sleep. The monitor could therefore wait nearly
30 seconds after the request, then perform its existing 2-second settling wait
before it checked the PulseAudio sink and started the renderer. This accounts
for the observed approximately 32 seconds.

The bridge now watches for that existing handover request while waiting for its
normal interval. It checks once per second, interrupts the wait when the
request is present and the speaker is not paused, and consumes the request only
once. A pending request does not cause a tight retry loop. Manual/idle pause
markers are respected; the request can interrupt after the pause is lifted.

After a `connect_speaker()` attempt, the bridge now immediately checks both
BlueZ's Classic connection state and the exact PulseAudio A2DP sink. It invokes
the existing profile recovery and retries up to five checks, one second apart
(at most four seconds of waiting). If the sink remains absent, it logs a
bounded timeout and leaves the regular reconnect monitor as fallback. Startup
uses the same bounded check instead of a fixed two-second sleep. A per-speaker
atomic lock makes recovery a single-flight operation, so two concurrent
monitor attempts cannot both connect or start a renderer.

The A2DP sink remains the readiness requirement; BlueZ `Connected: yes` by
itself does not start the renderer. The UUID, port, renderer command, BLE frame,
Music Assistant behavior, SSDP handling, and 300-second idle timeout were not
changed.

## Expected effect

When the handover request arrives and the sink is already available, renderer
startup no longer waits for the 30-second monitor cycle. Detection is bounded
by the one-second request check plus renderer process startup. If the sink is
still appearing, the bridge retries for up to four seconds before returning to
the normal monitor fallback. A reconnect without a handover request still uses
the configured monitor interval by design.

## Tests and verification

Executed with Git for Windows Bash:

- `bash -n` on `run.sh`, `lib/renderer-recovery.sh`, `lib/power-manager.sh`,
  and both smoke-test scripts: passed.
- `tests/renderer-recovery-smoke.sh`: passed. It covers first-check readiness,
  a missing sink after five bounded checks, a wake request interrupting the
  interval only after the pause clears, and two simultaneous recovery callers
  resulting in one connection and one renderer start.
- `tests/power-manager-smoke.sh`: passed, including the existing BLE handover,
  failed A2DP, and idle cancellation cases.

`git diff --check` passed. These are mocked shell tests;
they do not prove the timing of BlueZ, PulseAudio, or `gmediarender` on the
speaker hardware.

## Post-deployment timestamp check

After the next approved test build, compare these Home Assistant add-on log
timestamps for the same speaker and wake attempt:

1. `UE BOOM 2 connected.` from `connect_speaker()` (BlueZ command completion).
2. `Bluetooth and A2DP sink are ready for ...` (actual Classic and sink
   readiness).
3. `Starting the DLNA renderer for ...`.
4. `DLNA renderer handover acknowledged for ...`.

The interval from item 2 to item 3 should be within the same log second in the
normal ready-sink case; item 4 confirms the monitor acknowledged the running
renderer. The interval from item 1 to item 2 shows Bluetooth/PulseAudio
registration latency separately from bridge scheduling.
