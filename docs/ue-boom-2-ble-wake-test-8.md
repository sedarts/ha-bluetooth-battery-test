# UE BOOM 2 BLE wake correction (2.6.2-test.8)

## Finding

The hardware log proves that the installed `bluetoothctl` rejected
`bearer <MAC> le`. Its process exit code did not represent success of every
interactive command. In addition, the prior script immediately sent `quit`
after `write`, so it could not reliably observe the asynchronous result.
The payload conversion itself remains unchanged: host MAC
`8C:68:AB:E0:3F:F6` becomes bytes `8c 68 ab e0 3f f6`; `01` is wake and `02`
is the existing off frame.

The add-on is based on Alpine 3.18 / BlueZ 5.66. The fix no longer invokes
`bluetoothctl bearer` or uses its interactive GATT menu. It discovers the
existing power characteristic using BlueZ `gatttool`, then chooses ATT Write
Request when the characteristic advertises `write` (BlueZ characteristic
property bit `0x08`) or Write Command only when it advertises
`write-without-response` (bit `0x04`). The reported hardware flags `write`
therefore select Write Request. The ATT success response is required for a
“confirmed” log; that confirms the GATT procedure, not that the speaker
physically powered on/off.

The image adds Alpine's `bluez-deprecated` package because Alpine packages
`gatttool` there while `bluetoothctl` remains supplied by `bluez`. This is a
BlueZ utility, not a new protocol or payload. ATT requests are short-lived;
each discovery/write is bounded by 15 seconds. The existing idle timeout
(300 seconds) and wake timeout (90 seconds) are unchanged.

## Hardware validation still required

After installing test.8, use the configured paired-host MAC and inspect the
power-manager log. Expected sequence:

```text
[power-manager] BLE wake GATT write request confirmed by ATT response; physical speaker action remains unconfirmed
[power-manager] wake timed out: ...
```

The second line should instead be the existing A2DP/renderer readiness path if
the speaker actually wakes. If the ATT write is rejected or cannot be
confirmed, expect `BLE wake GATT write request was not confirmed ...`; do not
interpret that as a successful wake. Verify the physical power LED, startup
tone, A2DP availability, and renderer separately. Do not test power-off until
wake and basic GATT communication have been validated. No hardware test,
deployment, or Home Assistant operation was performed while preparing this
build.
