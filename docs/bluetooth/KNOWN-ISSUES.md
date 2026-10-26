# Known issues and open hardware checks

- Host address `8C:68:AB:E0:3F:F6` is historically documented as the NUC adapter,
  not an arbitrary candidate. Current pairing acceptance by this UE BOOM 2
  has not been independently verified on the HA host.
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
- The requested `skilo-sh/Reversing-UE-Boom` repository was unavailable during
  test.9 research, but was accessible during this test.10 investigation. See
  [PROTOCOL.md](PROTOCOL.md) for the reviewed code and limitations.

## test.10 findings

- Confirmed fixed locally: test.9 discarded equals-format discovery even with
  the correct UUID/value handle. Old mocks emitted only colon-format output.
  The new parser and original-output fixture cover this failure.
- Still unproven: the source of test.9's first two `Resource busy (16)` errors.
  Third-attempt discovery proves intermittent access, not which process owned
  the earlier conflict. No full BlueZ/D-Bus trace or process list was supplied.
- Discovery and write still use separate one-shot ATT connections. Reacquisition
  can fail even after successful discovery. The lock prevents this add-on's
  own competing operations; it cannot serialize external Home Assistant clients.
- New logs record the existing target-only disconnect's exit/output, discovery
  start/end, selected value handle/properties and write start/end, with the
  existing millisecond timestamps. Disconnect now has a five-second command
  timeout. Its return alone is not a link-state observation.
- The shared configured 90-second deadline and retry limits remain unchanged.
  This is a cooperatively checked request deadline, not a hard wall-clock
  watchdog: in-flight commands/status reads and error publication can overrun
  a boundary. No precise 90-second hardware completion guarantee is made.
- MQTT uses repeated `timeout 1 mosquitto_sub -C 1` calls and synchronous wake
  handling. Non-retained QoS-0 commands can be lost between subscriptions or
  while a wake is being processed. Discovery is sent before the receive loop,
  and "controller started" does not confirm a broker subscription. The current
  patch does not redesign the subscriber or add startup wake. A subsequent
  command after the error loop resumes is covered by the smoke test.
- Live WebUI/MQTT availability is not established by mock tests. The earlier
  release summary's broad statement about their availability should be read
  as a code-path assessment, not a live integration test result.

## Next controlled hardware check

See the staged [hardware procedure](TEST-10-REPORT.md#h-next-hardware-test-not-executed).
First establish the BLE write and physical response with one explicit wake.
Evaluate any automatic handover separately; radio/play and 300-second power-off
are later tests. No success follows from `Connected: yes`, absent A2DP, an ATT
write, or link disconnect alone.
