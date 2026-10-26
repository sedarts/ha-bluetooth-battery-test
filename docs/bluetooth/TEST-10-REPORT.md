# UE BOOM 2 — test.10 investigation and release review

Investigation date: 2026-10-26. Active repository only:
`sedarts/ha-bluetooth-battery-test`, branch `master`, baseline
`0ce1d246db5554ddaabff9dfda7a1dcec20a5e5b` (test.9). The user reports test.9
installed on HA. No live installed-build readback was performed in this task.
The baseline was clean before edits. The initial investigation was local only,
with metadata kept at test.9. The user subsequently approved publication of
the reviewed candidate as **2.6.2-test.10** on the existing master branch.
Only release metadata/documentation changes followed that approval; the
reviewed discovery/write implementation is retained. No deployment, package
installation or Bluetooth/MQTT hardware action was performed.

## A. Historical findings

Sources inspected: active-repository Git history and all Bluetooth reports;
the relevant turns in `Prüfe UE BOOM GATT Power-Off`
(`01a14b43-3667-7f92-93f5-049a761655dd`); the available referenced
`HomeAssistant MCP Connection` preview; the original 18 October brief and
19 October test.3 report attachments; the current test.10 request. The local
`sources/` mirror was empty. The current ChatGPT preview exposes no complete
17–19 October terminal history: assistant content is represented by reference
placeholders. Historical instructions were treated as evidence, not new authority.

| Event | Evidence recovered | Limit of the conclusion |
| --- | --- | --- |
| 17 October | User reconstruction identifies NUC `8C:68:AB:E0:3F:F6`, target `C0:28:8D:82:F7:BB`, list/info/GATT exploration | No complete raw `bluetoothctl list` transcript; current pairing acceptance is separate |
| 18 October | Contemporary brief dated about 13:10 reports off -> quoted decimal GATT write -> tone/LED -> later bridge/music; four disconnect-related log lines preserved | Exact pre-write connect/mode sequence and synchronized ATT/LED timestamps missing |
| 19 October test.3 | MQTT/log excerpt, explicit physical-on report, then 45-second A2DP timeout; source commit `115620c` | Write acceptance log was based on CLI exit/error-text checks, not a separately captured ATT reply |
| 19 October test.4 | User identifies commit `82a1514`, reports physical on, BLE release, accepted Classic attempts, no A2DP | Report, not a complete raw transport capture |
| test.5 / test.6 | Monitor ownership and renderer-readiness changes recovered; CT104 mock result and later reported good renderer timing | Mock success and renderer recovery are not physical BLE validation |
| test.7 / test.8 | Unsupported `bearer`, then direct ATT `Resource busy` before write | Neither invalidates the earlier reported physical on |
| test.9 | Two busy attempts followed by valid equals-format discovery | Confirmed parser failure before any payload write |

The test.3 Git implementation gives a concrete **software** sequence:
unblock -> pause monitor -> check existing A2DP -> `bluetoothctl connect` ->
one-second delay -> `menu gatt` -> select power UUID -> quoted decimal write ->
`quit` -> two-second delay -> Classic connect -> A2DP check. It uses the same
forward MAC bytes plus `01` as today. That does not reconstruct the exact
manual LE connection setup on 18 October. No evidence establishes that Python,
gatttool, a bearer command, or an extra authentication step caused that manual
success. The LE disconnect accompanied a reported on event; its cause and
whether it is universally normal for this model remain unproven.

Detailed dates, source commits, initial states, commands, observations, raw-log
availability and open questions are in [TEST-HISTORY.md](TEST-HISTORY.md).

### Historical MQTT request

The manual action publishes `wake` to the same MAC-derived topic used by the
bridge's discovered MQTT Wake button. It is an explicit control request, not
an initialization handshake. With BLE enabled it enters the BLE path unless
A2DP is already available; with BLE disabled it only unblocks/releases recovery.
The test.2 note explicitly had BLE disabled and reported renderer startup
without visible physical on. That must not be merged with test.3's reported wake.

The test.3 `command received: wake` proves the consumer was active for that
request. Its exact startup/subscription time is unknown. Current test.9
publishes discovery before entering a repeated one-message subscriber loop;
startup logs do not acknowledge broker subscription. A manual QoS-0,
non-retained publish during startup or synchronous wake handling can be lost.
The discovered button follows the same topic/payload semantics. The actual
dashboard card configuration was not retrieved from HA; an unrelated play or
script action cannot be assumed equivalent. No automatic startup wake is added.

## B. Windows Python trail

Read-only discovery found the registered per-user interpreter:
`C:\Users\bodyl\AppData\Local\Programs\Python\Python312\python.exe`,
version **3.12.10**. `python -m pip show bleak bluepy pybluez dbus-python`
reports all four packages absent in this interpreter.

Relevant PowerShell history: lines 653–664 show version checks and installation
of Python 3.12; lines 672 onward invoke `C:\techo5\tools\install-show.py` and
related Echo Show scripts. No `BleakClient`, `write_gatt_char`, BLE package
installation or BOOM Python command was found in this history. The history
has no timestamps, so installation date cannot be proved from line order.
Only relevant findings are recorded here; the private history is not copied.

Locations checked: current project/repository, `Documents\Codex`, Desktop,
actual redirected `E:\User\Downloads`, `E:\User\Dokumente\ChatGPT`, known
`C:\Users\bodyl\ha-coding` workspace, and `C:\techo5\tools`. Python files found
under techo5 are Echo Show tooling; the targeted BLE API/import search had no
matches. A downloaded old battery log is dated 8 October, not the requested
17–19 October experiment. No whole-disk search, interpreter installation or
test script execution was performed. Unknown virtual environments, deleted
scripts and history outside these locations are not ruled out.

Conclusion: the recovered Python evidence points to Echo Show work. A prior
Windows BLE script remains **unlocated/unproven**, rather than disproved.
Windows Bleak uses [WinRT](https://bleak.readthedocs.io/en/latest/backends/windows.html);
it would not reproduce Linux's BlueZ/direct-ATT connection ownership.

## C. Confirmed parser fault and correction

test.9 searched the literal `uuid: <UUID>` and extracted colon-separated value
handle/properties. Its mock emitted that same format. Actual noninteractive
BlueZ output uses `=`, so the correct record was discarded as "not found".
The old UUID filter was run against the stored fixture and failed as expected.

The dependency-free parser now validates one entire UUID-filtered record,
accepts `=`/`:` and whitespace/case variation, extracts the **value handle**,
checks hex ranges and handle ordering, and rejects missing, duplicate, wrong
UUID or unexpected records before setting any write target. For the reported
record it selects `0x0003`, properties `0x08`; the existing request branch sends
the unchanged `8c68abe03ff601` frame and checks the ATT-success text. No fixed
value handle, substring UUID selection or "first matching record" fallback.

Both formats are backed by the [BlueZ 5.66 noninteractive source](https://github.com/bluez/bluez/blob/5.66/attrib/gatttool.c)
and [interactive source](https://github.com/bluez/bluez/blob/5.66/attrib/interactive.c).
Known community protocol evidence and its limitations are in [PROTOCOL.md](PROTOCOL.md).

## D. Resource busy and timing

Proved: test.9 reached discovery on attempt 3. Busy happened before discovery
on attempts 1/2; the excerpt does not identify the link/process owner. There is
no captured pre-wake `Connected`/`ServicesResolved`, D-Bus monitor, adapter trace
or process list. Startup skips automatic Classic connect for the BLE-enabled
primary speaker and uses the common lock for its unblock operation. No own
competing process is demonstrated by this log; external clients remain possible.

The synchronous one-shot gatttool calls finish before another attempt starts.
There is no persistent gatttool child intentionally retained between attempts.
However discovery and write each open a separate ATT connection, and process
exit does not timestamp controller teardown. A BlueZ-held LE connection,
pending disconnect, external client, or rapid reacquisition is a hypothesis;
none is identified as the root cause. No evidence proves a device-specific
short write window. The 5-second command timeout can also terminate a slow
attempt, but the supplied third discovery completed in about 1.314 seconds.

The patch logs existing target disconnect return/output, discovery raw result,
parse result and write return/output with millisecond timestamps; it bounds the
previously unbounded disconnect calls at five seconds. It adds no delay or
Bluetooth command between successful discovery and write. Busy backoff, common
lock, three BLE attempts and four Classic attempts remain. The 90-second shared
deadline is retained with its existing cooperative checks; it is not a hard
watchdog over every status read/publication (see [KNOWN-ISSUES.md](KNOWN-ISSUES.md)).

All four requested external repositories/documents were reachable during this
investigation, including `skilo-sh`, whose earlier fetch had failed. Its Linux
D-Bus implementation is a separate option, not a tested solution for this host.
A BlueZ-owned UUID-resolved `WriteValue(type=request)` could avoid the second
direct ATT connection; it needs its own transport/lifecycle validation. No
Python/Bleak runtime dependency or BLE transport replacement is introduced.

## E. Code and file changes

- `lib/gatt-discovery.sh`: small pure parser, no network/device access.
- `lib/power-manager.sh`: use parser; log selected value/properties and command
  phases/results; bound/log existing disconnect calls. Payload and command
  selection are unchanged.
- `Dockerfile`: copy the sourced parser into the existing runtime library path;
  no package/image change. Existing flock/gatttool dependencies remain.
- `tests/fixtures/gatttool-test9-discovery.txt`, `tests/gatt-discovery-smoke.sh`:
  reproduce the real format and reject unsafe records.
- `tests/power-manager-smoke.sh`: exercise the real fixture through the actual
  write argv; parse/ATT failures, lock release and reconnect pause checks.
- `tests/bluetooth-coordination-smoke.sh` and the Power-Manager mock: fix test
  flock option parsing to use the requested wait rather than the descriptor.
- `CHANGELOG.md`: completed test.10 release entry and corrected already-published
  test.9 heading. `config.yaml`: version 2.6.2-test.10 following release approval;
  existing add-on name and slug remain unchanged.
- `docs/bluetooth/`: protocol, state machine, history, known issues, this report,
  provenance README and three user-supplied excerpts.

`run.sh`, renderer recovery, Music Assistant, SSDP, idle timing and other
repositories were not edited. No new speculative payload or startup wake.

## F. Local tests

All listed checks completed with exit code 0 on Windows/Git Bash:

| Check | Result |
| --- | --- |
| Individual `bash -n` on run.sh, lib/*.sh, webui/lib/*.sh, CGI and tests/*.sh | PASS |
| `bash tests/gatt-discovery-smoke.sh` | PASS — 20 cases |
| `bash tests/power-manager-smoke.sh` | PASS |
| `bash tests/bluetooth-coordination-smoke.sh` | PASS |
| `bash tests/renderer-recovery-smoke.sh` | PASS |
| `git diff --check` | PASS |

Power tests assert request handle `0x0003`/unchanged bytes, reject wrong or
ambiguous discovery without writing, simulate ATT errors and absent response,
cap busy retries at three, check lock release after every scenario, and invoke
the real recovery entry point repeatedly against each failed-wake pause marker
to verify **zero Classic calls**. ERROR followed by another MQTT wake still works.

Not run: Docker image build (Docker executable unavailable), Alpine kernel
flock lifecycle, real gatttool/BlueZ timeouts, actual broker delivery/WebUI
integration, or any speaker test. Mock timeout errors inject exit status 124;
they do not reproduce an actual blocked system call. Test output is recorded
as software evidence, not fabricated hardware raw logs.

### Release validation after approval — 2026-10-26

The user approved publication as test.10. All checks in the table above were
rerun against the release working tree and passed with exit code 0, including
all 20 parser cases and all three existing smoke suites. The runtime candidate
was not changed further; only version/changelog/report metadata was finalized.
The new parser is copied by Dockerfile, and the fixture and complete report are
included in the release. Add-on name and slug remain unchanged. Remote master
was checked against baseline `0ce1d246db5554ddaabff9dfda7a1dcec20a5e5b` before
publication. Docker and hardware limitations above still apply. Publication
does not verify physical BLE wake or power-off and does not deploy to HA.

## G. Durable documentation

[TEST-HISTORY.md](TEST-HISTORY.md) now covers 17/18/19 October, test.5/.6,
test.7/.8, the installed test.9 failure and local test.10 results. Each entry
separates source version from observed hardware, marks missing raw logs/time/
commit information, and names open questions. [logs/README.md](logs/README.md)
records excerpt provenance and the fixture's line-joining normalization.
Historical contradictory physical-off reports remain observations, not a newly
validated power-off protocol. No unrelated private history or credentials added.

## H. Next hardware test (not executed)

After separate release/deployment/test approval, capture one explicit Wake:

1. Record installed version/commit and configured host/target MAC. Verify the
   current NUC adapter and pairing read-only; keep the baseline test.9 recoverable.
   Record speaker LEDs off, power state and observer clock/video before the test.
2. Save add-on logs from startup, plus available existing BlueZ/D-Bus events and
   target-only `bluetoothctl info C0:28:8D:82:F7:BB` before the wake. Record active
   Bluetooth clients and whether the WebUI scan is running. Do not change other
   devices, reset Bluetooth or kill processes. No new diagnostic dependency.
3. Once the MQTT consumer is actually running, press the discovered Wake button
   once, or issue the equivalent action below once. Do not also press Play/Radio.
   A missing `command received: wake` is a delivery issue; do not classify it as
   a failed BLE attempt or immediately send a burst of commands.
4. Capture the entire bounded series and physical tone/LED times, including
   errors. Expected BLE sequence is shown below. Stop judging success at the
   physical-on checkpoint first; ATT success alone is insufficient.
5. The unchanged bridge automatically hands over to Classic after accepted BLE.
   Record that activity separately: this MQTT test is not a strictly BLE-only
   transport session. No additional manual Classic/A2DP, radio or power-off
   trial is part of this first test. If zero Classic activity is required,
   agree a separate isolated BLE-only harness before testing; do not bypass the
   coordinator with ad-hoc gatttool writes.
6. If BLE fails, expect lock release, `state=ERROR`, no renderer handover and no
   Classic reconnect. Save evidence; no second wake in this first controlled
   test. A2DP, radio and the 300-second physical-off test get separate approval
   after reviewing the BLE result.

```yaml
action: mqtt.publish
data:
  topic: bluetooth_audio_bridge/c0288d82f7bb/power/command
  payload: wake
  qos: 0
  retain: false
```

Expected messages (placeholders below are a plan, not a captured hardware log):

```text
command received: wake
state=WAKING reconnect pause set before waiting for shared Bluetooth lock
lock requested ... / lock acquired ...
state=WAKING operation=ble-wake attempt=1/3 start
BLE link release start phase=before-wake-discovery ...
BLE link release returned ... exit=<status> ...
BLE wake GATT discovery start ...
BLE wake GATT discovery process exited status=0: handle = ...
BLE wake GATT characteristic selected uuid=c6d6dc0d-07f5-47ef-9b59-630622b01fd3 value_handle=0x0003 properties=0x08
BLE wake GATT write request start value_handle=0x0003
BLE wake GATT write process exited status=0: Characteristic value was written sucessfully
BLE wake GATT write request confirmed by ATT response; physical speaker action remains unconfirmed
BLE link release start phase=after-wake-write ...
BLE wake series ended attempts=1/3 result=submitted
lock released ...
```

Busy can precede this sequence, with at most three attempts. Compare the recorded
disconnect, discovery start/end and write start/end timestamps against BlueZ
events and the observer record. New logs do not independently identify the
owner of a conflicting ATT socket. A physically on BOOM followed by an A2DP
timeout must be recorded as **BLE physical response observed / audio failure**.
