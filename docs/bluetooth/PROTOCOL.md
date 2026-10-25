# UE BOOM 2 Bluetooth protocol notes

Scope: reverse-engineered protocol facts for the existing UE BOOM 2 only. The
speaker is not contacted by these software tests. Keep the host MAC
`8C:68:AB:E0:3F:F6` as an unverified configuration value until the HA host's
actual pairing is checked.

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
speaker's current pairing or successful test. The requested `skilo-sh` source
could not be retrieved during this run; no claim is attributed to it.

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
- [Requested Reversing-UE-Boom repository](https://github.com/skilo-sh/Reversing-UE-Boom) — unavailable to inspect in this run.
- [BlueZ GattCharacteristic D-Bus API](https://github.com/bluez/bluez/blob/master/doc/org.bluez.GattCharacteristic.rst)
