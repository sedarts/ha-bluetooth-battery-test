# Bluetooth Audio Bridge 2.6.2-test.11 — Release-Readiness

Datum: 2026-10-26

Repository: `sedarts/ha-bluetooth-battery-test`, Branch `master`

Ausgangs-HEAD: `b13a19f87e54bb82e0158861a9ef5293597ee457`
(`2.6.2-test.10`) plus geprüfte lokale Änderungen

## Ergebnis

Der lokale Kandidat wurde **für die Veröffentlichung als test.11 und danach für
einen kontrollierten Hardwaretest freigegeben**. Er ist nicht als
Produktionsrelease freigegeben. Die nachfolgende Veröffentlichung setzt Version
und Changelog auf test.11; ein Deployment oder Hardwaretest ist damit nicht
verbunden.

Die Freigabe beruht auf zwei getrennten Nachweisen:

1. Alle 15 Prozess-/Signal-/Lock-Tests bestanden nach Anwenderangabe auf Debian,
   Python 3.13.5, Proxmox CT 215, ohne Adapter/BlueZ/Home Assistant, in 53,830 s,
   Ergebnis `OK`, keine Skips.
2. Alle fünf lokalen Smoke-Suiten, 20 Parser-Fälle, Shell-/Python-Syntax und
   `git diff --check` bestanden erneut.

Der Debian-Lauf ersetzt die zuvor fehlende Linux-Kernel-Prüfung. Er ersetzt
nicht den Build und Lauf im tatsächlichen Alpine-Add-on-Image und nicht den
Gerätetest.

## Geprüfter Änderungsumfang

- `lib/bluetooth-process.py`: begrenzter, Linux-spezifischer Wächter für eigene
  Prozessgruppen und adoptierte Nachkommen.
- `lib/bluetooth-ops.sh`: gemeinsamer Aufrufpfad, Lock-FD-Schließung im Kind,
  Stop-Guard und Ablehnung verschachtelter Locks.
- `lib/power-manager.sh`: begrenztes `bluetoothctl info`, sichere Signal-
  Bereinigung, keine aggressive Trennung unbekannter Verbindungseigentümer.
- `run.sh`, WebUI-Bibliothek und CGI: bestehende Bluetooth-Aufrufe über den
  begrenzten Wächter; eigene Besitzer-PID für absichtliche Hintergrundjobs.
- `Dockerfile`: Laufzeitpakete `flock` und `python3`; `bluez-deprecated` stellt
  weiterhin `gatttool`; Prozesswächter wird kopiert und ausführbar gemacht.
- Regressionstests und Prozessanalyse-Dokumentation.

Audio-, Renderer-, Music-Assistant- und SSDP-Logik wurden nicht umgebaut. BLE-
Payload, Characteristic-Auswahl, getrennte Discovery-/Write-Aufrufe, Idle 300 s
und bestehende fachliche Retry-Grenzen bleiben erhalten.

## Testmatrix

| Gate | Ergebnis | Aussagegrenze |
|---|---|---|
| Linux-Prozesssuite, 15 Fälle | PASS, extern gemeldet | Echter Debian-Kernel; Bluetooth/MQTT/Audio simuliert |
| GATT-Parser | PASS, 20 Fälle | Parser und Handle-/Property-Auswahl, keine Hardware |
| Power-Manager-Smoke | PASS | Zustände, Retry-/Fehlerpfade mit Testdoubles |
| Bluetooth-Koordination | PASS | Serialisierung/Pause; lokaler flock-Shim |
| Renderer-Recovery | PASS | Unveränderte A2DP-/Renderer-Recovery |
| BLE-Disconnect-Smoke | PASS | Eigentums-/Cleanup-Gates, keine echte Verbindung |
| Shell- und Python-Syntax | PASS | Keine Laufzeitintegration |
| `git diff --check` | PASS | Formatprüfung |
| Add-on-Image-Build | NICHT AUSGEFÜHRT | Docker/Podman lokal nicht vorhanden |
| Alpine/s6/host-D-Bus | OFFEN | Erst im gebauten Add-on prüfbar |
| UE BOOM 2 Hardware | OFFEN | Ziel des kontrollierten Tests |

Vollständige Namen der bestandenen Linux-Fälle stehen im Abschnitt
„Linux-Prozess-Gate bestanden“ von
[RESOURCE-BUSY-ANALYSIS.md](RESOURCE-BUSY-ANALYSIS.md).

## Abhängigkeiten und Laufzeit

Das Dockerfile installiert `python3` als Laufzeitabhängigkeit, kopiert
`lib/bluetooth-process.py` in den erwarteten Pfad und setzt das Ausführungsrecht.
Der Wächter verwendet nur `ctypes`, `os`, `pathlib`, `signal`, `subprocess`,
`sys` und `time`. Zusätzlich bleiben `flock`, `bluez`, `bluez-deprecated` und
die vorhandenen Shell-/MQTT-/Audio-Pakete installiert. Die statische Zuordnung
ist vollständig. Ein erfolgreicher Docker-Build sowie `python3 --version` und
ein Wächter-Start im resultierenden Alpine-Image sind dennoch Release-Gates vor
dem Deployment.

## Zeit-, Retry- und Lock-Invarianten

- Power-Manager `info`: 3 s; BLE-Link-Probe: 2 s.
- GATT Discovery/Write: je 5 s, beim Wake zusätzlich vom globalen Deadline
  begrenzt.
- BLE: höchstens 3 Versuche, nur bei Resource-busy 1 s zwischen Versuchen.
- Classic/A2DP: höchstens 4 Versuche innerhalb des bestehenden Wake-Deadlines.
- Renderer-Recovery und 30-s-Monitor-Fallback bleiben unverändert.
- Idle-Abschaltung bleibt 300 s; MQTT-Publish bleibt 8 s, Subscribe 1 s.
- Gemeinsamer Lock bleibt bis zum synchronen Ende der Operation im Besitzer;
  externe Kinder erben ihn nicht. Kein Nested Acquire.
- TERM/INT/Timeout: eigene Gruppe TERM, 0,5 s Gnadenfrist nur bei Abbruch,
  anschließend KILL/Reaping; keine fremden Prozesse und kein globaler
  Geräte-Disconnect.

Lock-Audit-Grenze: explizite WebUI-Aktionen Forget, Pause und Resume sind zwar
prozessseitig begrenzt, erwerben historisch aber keinen gemeinsamen Adapter-
Lock; ihr `require_idle` schützt nur gegen WebUI-Scan/Pairing. Sie dürfen im
kontrollierten Hardwaretest nicht parallel zu Wake, Idle oder Reconnect benutzt
werden. Eine Lock-Nachrüstung ist ein eigenes funktionales Arbeitspaket und
würde eine Wiederholung der Linux-/Smoke-Gates erfordern.

## Verbleibende Risiken

Die genaue reale Ursache von ATT `Resource busy (16)` ist nicht ermittelt. Das
Verhalten ist jetzt begrenzt und räumt nur eigene Ressourcen auf, doch zwei
separate `gatttool`-Sitzungen können weiterhin an BlueZ-/Controllerzuständen
oder einem fremden ATT-Besitzer scheitern. Parallel ausgelöste, nicht am
gemeinsamen Lock beteiligte WebUI-Aktionen sind ebenfalls ein offener
Konkurrenzpfad, ohne dass sie als Ursache des bisherigen Fehlers belegt wären.
Der Linux-Test beweist den Umgang mit dem Fehler, nicht seine Vermeidung.

Weiter offen sind Alpine/musl und s6-Signalweitergabe, Host-D-Bus-Asynchronität,
SIGKILL des Wächters selbst bzw. Container-/Kernelabbruch, ununterbrechbarer
Kernel-D-Zustand sowie tatsächlicher BLE-Wake/Power-Off. Ein beendetes
`bluetoothctl` kann eine bereits an `bluetoothd` übergebene asynchrone Operation
nicht zurücknehmen. Diese Grenzen müssen in Logs und Hardwarebeobachtung
sichtbar bleiben; ein eingereichter ATT-Write ist kein physischer Power-Nachweis.

## Gates für den kontrollierten Hardwaretest

1. Version/Metadaten/Changelog müssen konsistent test.11 ausweisen.
2. Add-on-Image nach Möglichkeit erfolgreich bauen; darin Python,
   Prozesswächter, `flock`,
   `gatttool` und Shell-Syntax prüfen.
3. Vor Deployment test.10 als Rollback-Ausgangspunkt erhalten.
4. Während Wake/Power-Off keine Forget-/Pause-/Resume-Aktion der WebUI auslösen.
5. Beim ersten Wake vollständige Add-on-/BlueZ-Zeitstempel erfassen und LEDs/
   Einschaltton separat beobachten.
6. Bei `Resource busy`: höchstens drei Versuche, ERROR, Lock-Freigabe, kein
   Classic-Handover; anschließend genau einen neuen expliziten Wake prüfen.
7. Erfolgsfall getrennt bestätigen: ATT-Antwort, physischer Start, A2DP,
   Renderer. Danach eigener 300-s-Idle-/Power-Off-Test.

Unter diesen Grenzen ist ein kontrollierter Hardwaretest fachlich vertretbar.
Das Ergebnis darf erst danach zur Produktions- oder Hardwarebestätigung
hochgestuft werden.
