# UE BOOM 2 BLE power control analysis

## Scope and baseline

Analysis and local changes are based on the active `sedarts/ha-bluetooth-battery-test`
checkout at commit `30c98fb8c180a1b3e8e9e23e15cc49c38af3d126` (test.6), prepared
as release `2.6.2-test.7`. No push, deployment, or renderer/audio code change
was made.

## Findings

- Before this change, idle handling only called `bluetoothctl disconnect` and
  `block`. The source comment explicitly said there was no BLE power-off command.
  This explains why the power LED stayed on: the log proved a Bluetooth link
  teardown/reconnect block, not physical shutdown.
- The wake payload construction is in forward MAC byte order followed by `01`.
  For `8C:68:AB:E0:3F:F6`, the decimal bytes shown in the log (`140 104 171 224
  63 246 1`) represent `8C 68 AB E0 3F F6 01`; that conversion is correct.
- The power characteristic is `c6d6dc0d-07f5-47ef-9b59-630622b01fd3` under
  service `757ed3e4-1828-4a0c-8362-c229c3a6da72`. A UE-BOOM-2-specific reverse
  engineering repository reports characteristic properties `0x08` (write
  without response) and both suffixes `01` (on) and `02` (off). It credits a
  decompiled UE app and user traces. This is useful protocol evidence, not an
  official Logitech specification or a hardware validation of this unit.
- The old shell sequence did not select an LE bearer, while BlueZ documents
  `Device1.Connect()` for dual-mode devices as choosing a bearer based on
  current/bonded/last-used preference. It also omitted the GATT write type,
  which defaults to `request`; BlueZ maps `command` to Write Without Response.
  The old “accepted” log only checked a process status and a short list of
  output substrings, so it was not evidence that the speaker acted on the
  command.
- `bluetoothctl`'s GATT write grammar parses byte tokens as base-0 integers.
  Thus the existing decimal payload is numerically valid and the numeric
  conversion itself is not the cause. The likely failure points are bearer
  choice, write procedure, and treating submission as device acknowledgement.
- Public reports use the MAC of a host already paired with the speaker in the
  frame. The `ble_adapter_mac` value must therefore be that paired-host MAC;
  it is not safe to assume every host/controller MAC is authorized by the
  speaker.
- The configured candidate `8C:68:AB:E0:3F:F6` is syntactically a valid
  unicast MAC (six octets, unicast bit clear) and its conversion to the wake
  payload is correct. The local checkout has no access to Home Assistant's
  saved add-on options or BlueZ bond database, so it cannot prove this address
  is the HA host address or that this host is paired with this BOOM. Confirm
  that relationship on the HA host before enabling BLE power control.
- A2DP absence, `Device1.Connected` false, GATT write submission, and a BLE
  disconnect do not independently prove physical power-off. No documented
  readable characteristic in the sources provides a reliable main-power
  state. With the current public evidence, off state must remain unknown.

## Local changes

`lib/power-manager.sh` now releases any Classic link, requests the LE bearer before the GATT action, checks
the reported characteristic flags, explicitly uses the `command` write type,
and logs that the write is submitted but not acknowledged by the speaker. Wake
still becomes successful only after A2DP and the renderer are ready. When BLE
power control is enabled, idle submits the documented `02` frame, disconnects
and blocks reconnection, then publishes `power_state_unknown`; when BLE control
is disabled or configuration is missing, it also reports unknown rather than
claiming the device is off. Renderer startup, A2DP recovery, SSDP, and the
300-second idle timeout are not altered.

The `README.md` description was updated to distinguish link teardown from
physical power state and to state the paired-host MAC requirement.

## Evidence and source quality

- [UE BOOM 2 BLE reverse-engineering notes](https://github.com/kancelott/ue-boom-2-bt-le-reverse-engineering)
  contain the service/characteristic list, `0x08` property, and `01`/`02`
  example frames. The repository says the work is an attempt; treat it as
  reverse-engineering evidence, not a compatibility guarantee.
- [UE Boom Homebridge implementation](https://github.com/alessandroaime/homebridge-ueboom)
  describes tracing the official app's ATT traffic and reports the `02` suffix
  for off. Its practical reports support feasibility, but do not prove this
  HA host's pairing/bearer behavior.
- [BlueZ Device1 API](https://github.com/bluez/bluez/blob/master/doc/org.bluez.Device.rst)
  documents dual-mode bearer selection and `PreferredBearer` behavior.
- [BlueZ GATT characteristic API](https://github.com/bluez/bluez/blob/master/doc/org.bluez.GattCharacteristic.rst)
  defines `command` as Write Without Response and `request` as Write With
  Response.
- [BlueZ GATT CLI documentation](https://man.archlinux.org/man/bluetoothctl-gatt.1.en)
  documents the write syntax and that the default type is `request`.

## Required hardware validation

The simulation cannot prove the exact BOOM firmware, host pairing authorization,
BLE advertisement while fully off, host BlueZ version support for `bearer`, or
physical power-on/off behavior. Before enabling this option on the device:

1. On the HA host, confirm `8C:68:AB:E0:3F:F6` is the intended paired-host
   address and that the BOOM's BlueZ bond represents that host.
2. Capture `bluetoothctl` output for `bearer`, LE connect, `attribute-info`, and
   the command write; confirm the attribute lists `write-without-response`.
3. With the speaker fully off, press HA Wake and independently observe LEDs,
   startup tone, Classic connection, A2DP sink, and renderer. Only the last two
   are currently used as software wake-success evidence.
4. Let the real idle timer expire. Observe the power button LED and startup
   behavior after an attempted `02` command. The software must remain at
   `power_state_unknown` until a reliable physical-power signal is established.
5. Verify normal playback and the renderer handover before/after these tests.
