# Bluetooth test history

Hardware results below are taken only from user-provided notes/log excerpts.
Missing fields are marked unknown; local smoke tests are not hardware results.

## 2026-10-17 adapter and GATT exploration

- Date: 17 October per the current user reconstruction; exact time unknown.
- Version/commit: bridge 2.6.1 in the contemporary notes; installed SHA unknown.
- Starting state: exploration included a speaker reported physically off;
  exact state at each individual command unknown.
- Commands reported: `bluetoothctl list`, `bluetoothctl info`, `menu gatt`,
  `list-attributes`. Their complete order and raw responses are unavailable.
- Observation: NUC adapter `8C:68:AB:E0:3F:F6`; speaker `C0:28:8D:82:F7:BB`;
  power UUID `c6d6dc0d-07f5-47ef-9b59-630622b01fd3`, flag `write`, path
  `/org/bluez/hci0/dev_C0_28_8D_82_F7_BB/service0001/char0002`.
- Supporting 18 October user notes report `LE.Connected: yes`,
  `BREDR.Connected: no`, `ServicesResolved: yes`, MTU 23 and descriptor `P`.
- Result: historical adapter identity and reported off-state LE reachability;
  no synchronized raw capture found. The MAC is not merely a guessed value.
- Conclusion/open questions: pairing acceptance by this BOOM remains separate;
  exact connection-establishment command and current adapter identity still
  require the approved hardware check. No new device access occurred here.

## Earlier reported manual wake

- Date/time: 2026-10-18 per supplied project note; exact time unknown.
- Version/commit: test note predates current test.8; exact build/commit unknown.
- Configured host MAC: `8C:68:AB:E0:3F:F6`; pairing acceptance not independently
  captured. Full configuration unknown.
- Initial state: BOOM reported fully off; LEDs off.
- Sequence: `bluetoothctl` GATT menu was used in the later code record; exact
  original manual pre-write sequence is unknown. Reported write:
  `write "140 104 171 224 63 246 1"` to the characteristic UUID in
  [PROTOCOL.md](PROTOCOL.md).
- Relevant raw output: `Attempting to write .../char0002`, followed by
  `ServicesResolved: no`, `LE Public disconnected reason 3`,
  `LE.Connected: no` (supplied excerpt; exact timestamps unavailable).
- Physical response: user reported startup tone and LED lighting; test.3 note
  separately reported the speaker physically turned on.
- Result: **UNGEKLÄRT / reported success, not fully reproducible**. The sound
  is meaningful physical evidence, but absent raw synchronized logs it cannot
  be tied independently to a particular preceding BLE operation.
- Next test: after release, capture full timestamped logs while running the
  parser-corrected bounded GATT request procedure, with BLE/classic operation IDs.
- Source: project brief dated 18 October, about 13:10, attachment
  `d7c38206-8dcf-44c5-91c0-a7c421ac9a7d`, and its
  [preserved excerpt](logs/2026-10-18-manual-wake-user-excerpt.txt).
- Prelude: an existing LE connection and characteristic selection are reported;
  exact connect/disconnect/mode commands immediately before the successful
  manual write are unknown. Do not substitute a later script as that transcript.
- Afterward: the brief says starting the audio bridge restored music. The LE
  drop accompanied reported power-on; whether it was device-initiated or a local
  disconnect cannot be concluded from the bare reason number and missing trace.

## 2026-10-19 MQTT wake, test.3 and test.4

- Version/source commits: test.3 `115620c98f4ff35f01c1ae5d6222d008f032b4c5`;
  test.4 `82a15146dea0f658e3d2d96c19f1543edf57e0c9`.
- Starting state: speaker off per reported test; exact LED timestamps unknown.
- Commands: explicit MQTT `wake` on
  `bluetooth_audio_bridge/c0288d82f7bb/power/command`.
- test.3 code sequence recovered from Git: unblock; set pause; check existing
  A2DP; `timeout 12 bluetoothctl connect <MAC>`; sleep 1; pipe `menu gatt`,
  `select-attribute <power-UUID>`, `write "140 104 171 224 63 246 1"`, `quit`
  into `timeout 12 bluetoothctl`; sleep 2; Classic connect and A2DP check.
  This reconstructs the software, not the missing manual command transcript.
- Raw evidence: [test.3 excerpt](logs/2026-10-19-test3-wake-user-excerpt.txt).
  It contains no timestamps or independent ATT success callback.
- Physical observation: the user explicitly reported physical power-on without
  touching the button. Classic was not accepted and A2DP timed out after the
  configured 45 seconds. The old implementation then paused/blocked reconnect.
- test.4 user report in chat `Prüfe UE BOOM GATT Power-Off`, turn
  `01a15476-c118-7c41-a3cc-fc378c0be081`: physical on, BLE link released,
  `Paired: yes; Blocked: no; Connected: yes`, first two Classic attempts
  accepted, no A2DP sink, 45-second failure. Full raw log unavailable.
- Result: **reported physical BLE wake, failed audio handover**, not a failed
  physical wake inferred merely from absent A2DP. Strong historical evidence;
  no current reproduction and no synchronized raw ATT/LED capture.
- Open: precise installed test.3 SHA, exact times, link owner/bearer transitions,
  and whether each reported write had a successful ATT response.

## test.5 and test.6

- Dates/source commits: test.5 released 19 October,
  `251698a10eafd6a199f70f3ddc18507121c3597f`; test.6 released 25 October,
  `30c98fb` (full identity available in Git).
- test.5 software starting state: isolated Debian 13 CT104, no Bluetooth
  passthrough. Commands: Bash syntax and Power-Manager smoke suite.
  User reported `power-manager smoke test: PASS`, `TEST_EXIT_CODE=0`; archive
  SHA256 `aa2c0d8a7db1aaaa956fbcf59c3882d76589281bd889b24fa3c30964aaee24b8`.
  This was a **mock test**, not physical BLE success.
- test.5 hardware finding: user later reported a roughly 32-second renderer
  delay (30-second monitor plus 2-second wait). Full timestamped raw log and
  starting power state are unavailable in this history.
- test.6 change/result: immediate bounded A2DP readiness/recovery, retained
  monitor fallback; local smoke tests passed. User subsequently reported
  reliable renderer startup after A2DP availability. Hardware command transcript
  and precise observation time unknown; physical BLE wake was still disputed.
- Conclusion/open: renderer timing and BLE power are separate. See
  [renderer validation](../ue-boom-2-validation-2026-10-25.md). No new renderer
  changes or claimed hardware reproduction in the test.10 candidate.

## 2.6.2-test.7

Repository version mapping: `9e8ffa7`, released 26 October. Installed SHA was
not independently read back during this reconstruction.

- Date/time, exact add-on commit, and raw log timestamps: unknown in supplied
  excerpts.
- Relevant configuration, exact paired-host MAC, and full raw transcript:
  unknown.
- Starting state: BOOM reported off.
- Sequence: test attempted `bearer <MAC> le`, characteristic inspection, then
  a write using the reverse-engineered frame. Installed `bluetoothctl` rejected
  `bearer`; only `Attempting to write` was reported for the subsequent write.
- Physical response: no confirmed power-on reaction.
- Result: **FAILED / procedure not equivalent to the earlier reported manual
  procedure**; no trustworthy confirmation that the GATT write completed.
- Next test: do not repeat the unsupported bearer command; use a controlled,
  timestamped BlueZ-managed GATT session after hardware is made available.

## 2.6.2-test.8

- Date/time, raw full transcript, and exact installed add-on commit: unknown in
  supplied excerpts; repository baseline is commit
  `c1fba5835b44dcc4aa49921239d6803908865da5`.
- Relevant configuration and paired-host verification: unknown.
- Starting state: BOOM reported off.
- Sequence: `gatttool` direct ATT connect/discovery/write attempt.
- Raw reported error: `Resource busy (16)` during connection, before service
  discovery or payload write.
- Physical response: no power-on; no GATT write was reached.
- Result: **FAILED before protocol write**. Exact process/link owner causing
  busy remains unknown.
- Next test: test.9 local changes first; later hardware test records full
  add-on and BlueZ timestamps. No hardware action occurred during test.9 work.

## Local test.9 regression checks

See [KNOWN-ISSUES.md](KNOWN-ISSUES.md) for environment limitations. Shell
syntax, power-manager smoke, renderer recovery smoke, Bluetooth lock
coordination, retry/error-state checks, and `git diff --check` are software
tests only and do not establish physical wake or power-off behavior.

- Date: 2026-10-26 (local run); add-on version marker: 2.6.2-test.9; source
  commit: test.8 baseline `c1fba5835b44dcc4aa49921239d6803908865da5` plus
  uncommitted local changes; hardware state: untouched/off per user report.
- Result: **SOFTWARE TESTS PASSED**: Bash syntax for runtime/library/test
  scripts; `tests/power-manager-smoke.sh` including `Resource busy`, three-BLE
  attempt cap, ERROR followed by a new MQTT wake, ATT request/command reporting
  and idle handover; `tests/renderer-recovery-smoke.sh`; and
  `tests/bluetooth-coordination-smoke.sh` covering serialization, a pause
  arriving while a reconnect owns the lock, release, pause guard, four Classic
  maximum attempts, and stop after readiness. `git diff --check` passed.
- Docker image build: **NOT RUN**; Docker is not installed in this environment.
  Lock behavior was tested with a test-only `flock` shim, not Alpine/Linux's
  kernel lock implementation. No hardware command was issued.

## test.9 first installed wake: discovery succeeded, parser failed

- Date/time: supplied excerpt 01:03:51.474–01:03:54.877; calendar date/timezone
  unknown in excerpt. Source release 26 October, installed test.9 confirmed by
  user, commit `0ce1d246db5554ddaabff9dfda7a1dcec20a5e5b`.
- Starting state: BOOM fully off per user context; no synchronized LED recording.
- Commands: one explicit wake; existing shared lock; up to three one-shot
  `gatttool --characteristics --uuid <power-UUID>` attempts after disconnect.
- Raw evidence: [user-supplied excerpt](logs/test9-first-wake-user-excerpt.txt).
- Observation: attempts 1 and 2 report busy within 36 and 33 ms of their start
  lines; attempt 3 starts 01:03:53.553 and reports valid discovery 1.314 s later.
  It gives declaration `0x0002`, value `0x0003`, properties `0x08`, exact UUID.
- Result: **GATT discovery succeeded on attempt 3; parser rejected `=` syntax**.
  No power write was reached, so this test does not test the payload itself.
- Conclusion: transient ATT access is possible; the resource owner and exact
  release instant cannot be determined from this excerpt. The 3.403 s overall
  interval is not a measured device-specific write window.
- Open: previous BlueZ link state, competing external client, ATT teardown,
  and the next one-shot connection needed for the actual write.

## Local candidate test.10 regression checks — 2026-10-26

- Baseline: test.9 commit `0ce1d246db5554ddaabff9dfda7a1dcec20a5e5b` plus local
  changes. Add-on version remains test.9 until release approval; no new commit.
- Starting state: Windows/Git Bash, Bluetooth and MQTT replaced by test doubles;
  no hardware access. Docker executable/daemon unavailable.
- Reproduction: the original test.9 `grep -iF "uuid: ..."` rejects the stored
  equals-format fixture. Confirmed before changing the parser.
- Commands/results: syntax checked individually for all runtime, library,
  CGI and test scripts; `gatt-discovery-smoke.sh` **PASS (20 cases)**;
  `power-manager-smoke.sh` **PASS**; `bluetooth-coordination-smoke.sh` **PASS**;
  `renderer-recovery-smoke.sh` **PASS**; `git diff --check` **PASS**.
- Coverage: original discovery/value handle, colon/equal/whitespace/case,
  wrong UUID and duplicate/incomplete/unexpected fields; actual request argv;
  ATT error/timeout/missing response; bounded busy retries; lock release for
  each scenario; failed wake pause prevents repeated calls through the real
  recovery entry point; new MQTT wake after ERROR.
- These are software results only. The `flock` test double models normal release
  and ordering, not Linux process death; timeout error cases inject exit status,
  not a real BlueZ hang. No Docker image, live broker, WebUI or speaker test.
- Next action: review the [test.10 report and hardware procedure](TEST-10-REPORT.md).
