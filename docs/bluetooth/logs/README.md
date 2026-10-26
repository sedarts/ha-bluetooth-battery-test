# Hardware log archive

Place full, timestamped, unedited hardware test captures here, with filenames
including date, add-on version, and test ID. Redact MQTT credentials and
tokens, but retain Bluetooth operation IDs and relevant BlueZ error text.
No raw timestamped test.7/test.8 capture was supplied for this task, so no
synthetic log files are included. Their available excerpts and unknown fields
are summarized in [TEST-HISTORY.md](../TEST-HISTORY.md).

## Excerpt provenance added for the test.10 candidate

These are transcriptions of user-supplied excerpts, **not complete raw captures**.
No missing line, timestamp, ATT reply, or device observation has been invented.

- `2026-10-18-manual-wake-user-excerpt.txt`: the four lines in the project
  brief dated 18 October, about 13:10, attachment ID
  `d7c38206-8dcf-44c5-91c0-a7c421ac9a7d`. The brief separately reports tone,
  LEDs and later music. No raw command prelude or timestamp was attached.
- `2026-10-19-test3-wake-user-excerpt.txt`: two log blocks from attachment ID
  `1995a89a-4744-410f-a7c6-d3aba5d1285e`, discussed on 19 October. The blank
  separator joins those blocks; it does not establish their elapsed time.
- `test9-first-wake-user-excerpt.txt`: the log block in the current test.10
  request, attachment ID `9ca14c30-c9b9-4b21-b150-c0b5ccdb93e9`. Date and timezone
  are not supplied in that block; clock times are preserved exactly.
- `tests/fixtures/gatttool-test9-discovery.txt` (repository root): the same
  reported four discovery fields joined to the single-line format emitted by
  noninteractive BlueZ 5.66 `gatttool`. This is a regression fixture, not a
  claim to possess the missing original terminal file.
