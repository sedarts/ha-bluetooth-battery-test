# Known issues and open hardware checks

- Host address `8C:68:AB:E0:3F:F6` plausibly supplies the paired-host suffix,
  but its actual pairing with this UE BOOM 2 has not been verified on the HA
  host. It remains an open hardware check.
- The test.8 `Resource busy (16)` error occurred before GATT discovery/write.
  The code had no shared lock and did not wait for `bluetoothctl disconnect`
  to settle. This establishes a bridge-side race window, not the identity of
  the process that caused the observed error; another BlueZ client remains
  possible.
- Test.9 serializes operations started by this add-on only. It cannot lock
  Home Assistant's Bluetooth integration, phone apps, other add-ons, or
  external processes. It does not kill those processes, reset the adapter, or
  restart `bluetoothd`.
- `flock` process-exit release follows Linux locking semantics; it is not
  exercised on this Windows/Git Bash test host. The Alpine 3.18 package index
  lists a `flock` package, but Docker is unavailable here, so installation and
  runtime command presence still need a local/container image build check.
- `gatttool` is deprecated and uses direct ATT access. A BlueZ D-Bus client is
  a possible future improvement, but is not introduced here because no tested
  project-native client is present and hardware validation is still pending.
- A successful ATT Write Request confirms the stack's write transaction, not
  physical device power state. Write Command has no ATT response. BLE power-off
  and actual power state therefore remain unverified.
- The requested `skilo-sh/Reversing-UE-Boom` repository was unavailable to
  retrieve during this run; no protocol conclusion relies on it.

## Next controlled hardware check

After approval and deployment of a test build: record add-on version and
commit; confirm speaker is off and actual paired-host MAC; capture full add-on
timestamps from MQTT wake through the BLE operation and A2DP/renderer ready;
observe the physical startup tone/LED; separately test 300-second idle and
physical off state. Do not claim success from `Connected: yes`, A2DP absence,
an ATT write, or link disconnect alone.
