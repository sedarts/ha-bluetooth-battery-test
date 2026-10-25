# Bluetooth test history

Hardware results below are taken only from user-provided notes/log excerpts.
Missing fields are marked unknown; local smoke tests are not hardware results.

## Earlier reported manual wake

- Date/time: 2026-10-18 per supplied project note; exact time unknown.
- Version/commit: test note predates current test.8; exact build/commit unknown.
- Relevant configuration and paired-host MAC: unknown.
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
  managed BlueZ GATT request procedure, with BLE/classic operation IDs.

## 2.6.2-test.7

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
