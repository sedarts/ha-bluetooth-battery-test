# UE BOOM 2 Bluetooth protocol notes

Scope: reverse-engineered protocol facts for the existing UE BOOM 2 only. The
speaker is not contacted by these software tests. Host MAC
`8C:68:AB:E0:3F:F6` is historically identified as the NUC adapter in the
17–18 October user notes. Its current pairing acceptance by the BOOM is a
separate, still open hardware check.

## Known characteristic and frame

- Speaker target: `C0:28:8D:82:F7:BB`.
- Characteristic UUID: `c6d6dc0d-07f5-47ef-9b59-630622b01fd3`.
- Public reverse-engineering notes report characteristic value handle `0x0003`
  and properties `0x08` (Write Request); these are discovery results, not
  guaranteed stable handles for every firmware/database.
- Frame: paired-host Bluetooth address as six bytes without separators,
  followed by `01` for the reported wake frame or `02` for the reported off
  frame. Current configured host address converts to `8c68abe03ff6`; frames
  remain `8c68abe03ff601` / `8c68abe03ff602`.
- The payload, UUID, target address, configured idle timeout (300 seconds), and
  stop debounce (10 seconds) are unchanged in test.9.

`kancelott/ue-boom-2-bt-le-reverse-engineering` describes the UE BOOM 2 UUID,
handle, `0x08` property and interactive `gatttool` discovery. It is a community
reverse-engineering repository, not vendor documentation. `homebridge-ueboom`
documents a `gatttool --char-write-req` frame and the host-address + `01`/`02`
convention, and explicitly notes that the speaker connects to that host after
remote wake. These sources support protocol plausibility, not this individual
speaker's current pairing or successful test. The `skilo-sh` source, unavailable
during the test.9 work, was successfully inspected on 26 October for test.10.

BlueZ exposes remote GATT characteristics through `org.bluez.GattCharacteristic1`
and `WriteValue(value, options)`, with `type=request` for a write with response
and `type=command` for a write without response. A command does not provide an
ATT write response; therefore software can report submission but not a
confirmed write from that procedure. The existing test.8 implementation uses
the discovered characteristic property: `--char-write-req` for `0x08`, or
`--char-write` for `0x04`. Physical ON/OFF still requires independent
observation; `Connected`, ATT success, and a disconnect do not prove it.

## Historical wake evidence (not fully reproducible)

The user-provided 2026-10-18 project note reports the command
`write "140 104 171 224 63 246 1"`, followed by a startup tone and LED
reaction. It identifies a BlueZ GATT menu object ending in `/char0002` and the
UUID above. The raw timestamped terminal transcript and exact pre-write
sequence are missing. The earlier test.3 report separately says the physical
speaker turned on after a `bluetoothctl` GATT write. These are reported
hardware observations, not results reproduced by test.9.

The test.7 `bearer ... le` attempt was rejected by that installed
`bluetoothctl`; a later write showed only `Attempting to write` and no physical
reaction. Test.8 `gatttool` reported `Resource busy (16)` before discovery or
write. The busy message does not identify whether BlueZ, this add-on, or another
host client owned the conflicting operation.

## Sources

- [UE BOOM 2 GATT reverse-engineering notes](https://github.com/kancelott/ue-boom-2-bt-le-reverse-engineering)
- [Homebridge UE Boom implementation and protocol notes](https://github.com/alessandroaime/homebridge-ueboom)
- [Reversing-UE-Boom repository](https://github.com/skilo-sh/Reversing-UE-Boom) — available in the test.10 investigation; earlier test.9 fetch had failed.
- [BlueZ GattCharacteristic D-Bus API](https://github.com/bluez/bluez/blob/master/doc/org.bluez.GattCharacteristic.rst)

## test.10 parser correction and transport evidence

The test.9 device excerpt contains `handle = 0x0002`, `char properties = 0x08`,
`char value handle = 0x0003`, and the exact power UUID. Its parser instead
searched for colon-separated fields. This rejected discovery before any write.
BlueZ 5.66's [noninteractive gatttool source](https://github.com/bluez/bluez/blob/5.66/attrib/gatttool.c)
emits `=`; its [interactive implementation](https://github.com/bluez/bluez/blob/5.66/attrib/interactive.c)
uses `:`. Both are supported deliberately, not as guessed device protocols.

`parse_gatt_discovery` accepts exactly one complete UUID-filtered record with
validated hex ranges and an exact case-insensitive UUID. Empty, duplicate,
wrong-UUID, malformed, trailing unexpected text, or invalid handle ordering
fails closed. Only the **value handle** is passed to the write. Properties
`0x08` choose ATT Write Request and require the success response. The existing
`0x04` command-only path remains compatible but never claims ATT confirmation.
The configured payload remains `8c68abe03ff601`; no service or characteristic
is written speculatively. The known service UUID from the historical brief is
`757ed3e4-1828-4a0c-8362-c229c3a6da72`; current discovery filters the characteristic,
not the service, so no current service-discovery result is being asserted.

The existing one-shot discovery and write are **two gatttool processes**, each
establishing an ATT connection. Discovery process exit precedes parsing/write;
no artificial delay is added between them. A process exit closes its descriptors
but does not establish when controller/link teardown finishes or prevent an
external BlueZ client acquiring the link. Keep this distinction in busy diagnosis.

## Separately evaluated D-Bus option (not implemented)

[skilo-sh utils.py](https://github.com/skilo-sh/Reversing-UE-Boom/blob/main/utils.py)
uses Python `dbus`, `Device1.Connect`, and `GattCharacteristic1.WriteValue` with
forward host bytes plus `01`/`02`. It hardcodes the characteristic object path
and uses `bluetoothctl connect` specially for off. Its broad exception messages
do not prove physical state; its device/model and timing are not our validation.
The example does not justify a new Python dependency in this add-on.

A future native D-Bus client could let BlueZ own one connection, resolve the
target characteristic by UUID after `ServicesResolved`, and call `WriteValue`
with `type=request`, awaiting its reply/error under the existing lock and deadline.
That avoids gatttool's second direct-ATT connect. It still needs an available
client/runtime, host D-Bus access and hardware validation. Do not hardcode the
historical path or silently infer on/off from a D-Bus return. No replacement or
package installation is included in this candidate.
