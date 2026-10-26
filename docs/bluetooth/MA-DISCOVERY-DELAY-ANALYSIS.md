# Music Assistant discovery delay after renderer recovery

Date: 2026-10-26

Bridge baseline: `2.6.2-test.13` (`159e41c`)

Installed Music Assistant: `2.10.8`

## Result

The observed delay is not caused by BLE, Classic Bluetooth, A2DP, the renderer
handover, or the reconnect monitor. The bridge completed those stages by
23:38:26. Music Assistant 2.10.8 discovers UPnP renderers by an active SSDP
search cycle scheduled every 300 seconds. It does not passively dispatch a
new renderer's `ssdp:alive` announcement to the DLNA provider in this code
path. A renderer that starts between two cycles therefore waits for the next
cycle. The observed 159 seconds are consistent with the remaining portion of
that 300-second interval.

## Evidence

The hardware log establishes this sequence:

- 23:38:16: wake requested.
- 23:38:19: BLE write sent.
- 23:38:24: A2DP sink ready.
- 23:38:25: renderer handover acknowledged.
- 23:38:26.086: `gmediarender` registered IPv4 at
  `192.168.2.12:49494`.
- 23:38:26.112 through 23:38:26.801: the device and service descriptions
  were fetched. This proves that the renderer was reachable and discoverable
  by at least one UPnP control point immediately. The renderer log does not
  identify that control point; Home Assistant Core's DLNA discovery is the
  likely source, but that attribution is an inference rather than a logged
  fact.
- 23:41:05: AVTransport, ConnectionManager and RenderingControl subscriptions
  were created.
- 23:41:43: a Music Assistant stream URL on port 8097 was assigned and
  playback began.

The exact Music Assistant 2.10.8 source was checked at tag `2.10.8`, commit
`24c14e8bf89de472ceb23ecbd33407bdfcccbd01`:

- `music_assistant/controllers/discovery/controller.py` defines
  `UPNP_DISCOVERY_INTERVAL = 300`.
- `_schedule_periodic_upnp_discovery()` schedules the next cycle after that
  interval.
- `_run_upnp_discovery_cycle()` calls `async_upnp_client.search.async_search`
  for provider-declared search targets.
- The controller has a persistent mDNS browser, but no equivalent passive
  SSDP NOTIFY listener.
- `music_assistant/providers/dlna/manifest.json` subscribes to
  `urn:schemas-upnp-org:device:MediaRenderer:1`.
- Enabling Music Assistant's documented network-scan option adds a broadcast
  search target to the same cycle; it does not shorten the 300-second period.

Music Assistant's public DLNA documentation explicitly warns that initial or
repeat discovery can take up to five minutes. This matches the implementation
and the measured delay.

## Bridge review

`run.sh` starts `gmediarender` only after both BlueZ and the expected PulseAudio
A2DP sink are ready. It uses host networking, a deterministic UUID derived
from the speaker MAC, and fixed port 49494 for the primary speaker. These
values do not change between renderer recoveries. The test.6 recovery change
(`30c98fb`) only removed the former reconnect-monitor delay; it did not alter
SSDP or Music Assistant behavior.

Keeping `gmediarender` alive while the physical speaker is off would avoid
rediscovery, but would reintroduce the previously fixed false-availability
bug. Restarting the renderer repeatedly cannot force Music Assistant's active
search and would add churn. The bridge also has no documented Music Assistant
API or Home Assistant service that requests an immediate DLNA discovery
cycle. Calling Music Assistant internals would be version-dependent and is
not suitable for this add-on.

No production-code change is therefore justified in this repository. The
smallest correct fix belongs in Music Assistant: either listen for SSDP
`ssdp:alive` notifications and dispatch matching devices immediately, or
provide a documented, supported command for an on-demand provider discovery
cycle. A shorter global polling interval is less desirable than either
event-driven option.

## Playback while unavailable

The current Home Assistant entity `media_player.ue_boom_2` is provided by the
Music Assistant integration. The inspected radio script issues volume and
`music_assistant.play_media` calls immediately and contains no availability
wait or retry. The Guten-Morgen automation also sends the playback command
immediately; `continue_on_error: true` lets the remaining light actions
continue but does not queue or replay the failed media command. A press during
the discovery gap must therefore be treated as not accepted, not deferred.
No automation was changed during this analysis.

## Next validation

For one controlled wake, capture the bridge and Music Assistant logs plus a
packet trace filtered to UDP port 1900 and TCP port 49494. Correlate:

1. renderer registration and initial `NOTIFY ssdp:alive` packets;
2. the source address of immediate description requests;
3. Music Assistant's next `M-SEARCH` request;
4. the renderer's response to that request;
5. description fetch, GENA subscriptions, player availability and first
   successful play command.

Success for a future fix is distinct timestamps showing the Music Assistant
player available within 10-15 seconds of renderer readiness, followed by a
successful first button press. An HTTP description fetch or GENA subscription
alone is not sufficient evidence of UI availability.

## Verification performed

- Shell syntax for `run.sh`, `lib/*.sh`, Web UI shell/CGI scripts and
  `tests/*.sh`: PASS with Git for Windows Bash.
- `tests/gatt-discovery-smoke.sh`: PASS (20 cases).
- `tests/power-manager-smoke.sh`: PASS.
- `tests/bluetooth-coordination-smoke.sh`: PASS.
- `tests/renderer-recovery-smoke.sh`: PASS.
- `tests/ble-disconnect-smoke.sh`: PASS.
- `git diff --check`: PASS for tracked changes; the untracked report itself
  also passes `git diff --no-index --check`.
- Linux process suite: not rerun locally because no local Linux/Python test
  environment is available. Its previously reported test.13 CT 215 result
  remains 20/20 PASS, but is not presented as a new run.
