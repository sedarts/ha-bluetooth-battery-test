# UE BOOM 2 — test.11 `/proc`-Fehler und lokaler test.12-Kandidat

Datum: 2026-10-26

Basis: veröffentlichter Commit
`7838a960ac18dc4108f4aff16b1c64f6e5a82a8c` (`2.6.2-test.11`).
Die Korrektur wurde als Kandidat für `2.6.2-test.12` geprüft. Dieser Bericht
dokumentiert keine Installation auf Home Assistant und keinen Hardware-Wake.

## Hardwarebefund test.11

Nach Anwenderangabe wurde der MQTT-Wake empfangen und der gemeinsame
Bluetooth-Lock erworben. Jede BLE-Link-Prüfung endete jedoch mit Status 125 und

```text
[Errno 2] No such file or directory: '/proc/self/task/<PID>/children'
```

Es folgte kein GATT-Aufruf. Der Power-Manager räumte seinen Zustand auf, gab den
Lock frei und wechselte nach ERROR. `bluetoothctl info` hatte zugleich
`Connected: yes` gemeldet, obwohl kein betriebsbereiter A2DP-Sink existierte.

## Konkrete Fehlerursache

`lib/bluetooth-process.py` startet das externe Kommando als neue Session und
setzt sich per `PR_SET_CHILD_SUBREAPER` als Auffang-Elternprozess ein. Im
`finally`-Cleanup von test.11 geschah danach zwingend:

```python
Path(f"/proc/self/task/{os.getpid()}/children").read_text()
```

Die Datei ist keine auf jedem Linux-Kernel garantierte Schnittstelle. Ihre
Bereitstellung hängt auf neueren Kerneln von `CONFIG_PROC_CHILDREN` ab; außerdem
warnt die Kernel-Dokumentation, dass diese Liste bei gleichzeitig beendeten
Kindern Einträge auslassen kann. Siehe
[proc_tid_children(5)](https://www.kernel.org/pub/linux/docs/man-pages/book/man-pages-6.06.pdf)
und [Linux procfs](https://docs.kernel.org/6.12/filesystems/proc.html#proc-pid-task-tid-children-information-about-task-children).

Fehlt die Datei, wirft der Cleanup `ENOENT`. Diese Exception verlässt den
`finally`-Block und wird erst vom äußeren Handler in Status 125 übersetzt. Damit
wird sogar der Status eines zuvor erfolgreich beendeten `bluetoothctl` verworfen.
Der Fehler liegt vollständig vor Discovery/Write und sagt nichts über Payload,
Characteristic oder Lautsprecherreaktion aus.

### PID, Race und Container

- `os.getpid()` ist hier die PID des einthreadigen Python-Wächters. Für dessen
  Hauptthread ist die TID identisch; `/proc/self` bezieht sich auf denselben
  aufrufenden Prozess. Ein falscher PID-Bezug ist nicht erkennbar.
- Der Wächter kann nicht zwischen `os.getpid()` und seinem eigenen synchronen
  Dateizugriff verschwinden und weiter Python ausführen. Ein Self-PID-Race ist
  daher nicht die Ursache des reproduzierten `ENOENT`.
- Nachgewiesen ist nur, dass die Datei in der procfs-Sicht des Add-on-Containers
  fehlt. Plausibel ist eine HAOS-Kernelkonfiguration ohne `CONFIG_PROC_CHILDREN`;
  eine abweichende procfs-Bereitstellung ist ebenfalls möglich. Alpine oder s6
  ändern die Bedeutung von `os.getpid()` nicht. Ohne Kernelkonfiguration des
  Hosts wird keine dieser beiden Umgebungsursachen als endgültig behauptet.
- Echte PID-Races bestehen beim späteren Aufräumen kurzlebiger Kinder: Eine PID
  kann zwischen Auflistung und Signal verschwinden oder wiederverwendet werden.
  Diese Race-Klasse war in test.11 nicht ausreichend abgesichert.

## Gezielte Korrektur

Der lokale Wächter behält die bisherige Session-/Prozessgruppenarchitektur:

1. Der Befehl startet weiter mit `start_new_session=True`; seine eigene Gruppe
   erhält bei Abbruch zuerst TERM und nach 0,5 s KILL.
2. `waitid(... WNOWAIT)` hält die Leader-PID bis zum Gruppencleanup reserviert.
3. Adoptierte/aus der Session entkommene Nachkommen werden ausschließlich als
   **direkte Kinder dieses Subreapers** behandelt.

Neu ist eine von der optionalen `children`-Datei unabhängige Verifikation:

- `/proc/<pid>/stat` liefert Status, `PPid` und `starttime`.
- Die schnelle task-children-Liste wird, falls vorhanden, nur noch als Hinweis
  verwendet und immer mit einem `/proc`-Scan nach exakt passender `PPid`
  gegengeprüft.
- Fehlt die Datei, meldet der Wächter einmal den begrenzten PPid-Fallback; das
  ist kein Kommandofehler.
- Vor jedem Signal müssen Eltern-PID und `starttime` noch exakt übereinstimmen.
  Wenn Kernel und Python pidfds unterstützen, pinnt ein pidfd zusätzlich die
  Prozessidentität. Andernfalls erfolgt unmittelbar vor `kill` eine zweite
  Identitätsprüfung.
- Verschwundene oder bereits abgewartete `/proc`-Einträge sind normale Races und
  werden ignoriert. Eine geänderte PID-Identität wird nie signalisiert.
- Warten auf den Leader und Cleanup direkter Kinder teilen ein hartes
  Zwei-Sekunden-Cleanup-Budget. Ist `/proc` selbst nicht zuverlässig lesbar oder
  bleibt ein eigenes Kind bestehen, endet der Wächter sicher mit 125 statt
  unbegrenzt zu warten oder unbekannte Prozesse zu signalisieren.

Die Änderung enthält weiterhin weder `pkill`/`killall` noch Adapter-Reset,
BlueZ-Neustart oder geräteweiten Bluetooth-Disconnect. Bluetooth-/Audio-
Architektur, BLE-Payload, Discovery/Write-Transport, Locks und Retry-Limits
bleiben unverändert.

## Warum die 15 Linux-Tests test.11 bestanden

Der Debian-LXC stellte `/proc/self/task/<PID>/children` bereit. Sämtliche
Integrationsfälle liefen deshalb durch den einzigen implementierten Pfad; kein
Test entzog diese Datei oder erzwang den PPid-Scan. Die damalige Testanleitung
prüfte die Existenz des Pfads sogar ausdrücklich als Voraussetzung. Somit
belegten die 15 Fälle Signal-, Lock- und Reaping-Verhalten **bei vorhandener
Kernel-Schnittstelle**, nicht die Portabilität auf einen Kernel ohne
`CONFIG_PROC_CHILDREN`.

test.12 ergänzt fünf Fälle auf insgesamt 20:

1. fehlender task-children-Pfad fällt auf PPid-Scan zurück;
2. von task-children ausgelassene sowie während des Scans verschwundene
   `/proc`-Einträge werden korrekt behandelt;
3. geänderte `starttime` oder `PPid` verwirft eine stale PID;
4. 20 kurzlebige erfolgreiche Prozesse behalten beim erzwungenen Fallback
   Status 0;
5. ein adoptierter Enkel mit eigener Session wird auch über den erzwungenen
   PPid-Fallback beendet und abgewartet.

Die ersten drei reinen Proc-Parser-/Race-Fälle bestehen lokal unter Windows.
Die 17 Kernel-/Signaltests sind dort **nicht ausgeführt (SKIPPED)**; der
vollständige Lauf erfolgte deshalb getrennt unter Linux.

## Debian-Linux-Gate

Nach Anwenderbericht wurde das vorbereitete test.12-Testarchiv auf Proxmox
CT 215 (`dashcast`) ausgeführt:

- Debian-LXC;
- Python 3.13.5;
- 20/20 Tests bestanden;
- 0 Fehler und 0 Skips;
- Laufzeit 61,973 Sekunden;
- alle neuen `/proc`-Fallback-, PID-Race-, Kurzprozess- und
  Prozess-Cleanup-Fälle bestanden.

Damit ist das Linux-Gate für den geprüften Debian-Arbeitsstand vollständig
bestanden. Der Lauf verwendete die simulierten Bluetooth-, MQTT- und
Audio-Kommandos der Suite und ist kein Hardwaretest.

## Lokale Prüfergebnisse

Auf dem Windows-Arbeitsplatz wurden nach der Änderung ausgeführt:

- Shell-Syntax aller `run.sh`, `lib/*.sh`, `webui/*.sh`, CGI- und
  Shell-Testdateien: bestanden;
- GATT-Discovery-Parser: 20/20 Fälle bestanden;
- Power-Manager-Smoke-Test: bestanden;
- Bluetooth-Koordinations-Smoke-Test: bestanden;
- Renderer-Smoke-Test: bestanden;
- BLE-Disconnect-Smoke-Test: bestanden;
- `tests/linux-process-lifecycle.py -v`: 20 erkannt, davon die drei
  plattformunabhängigen Proc-/Race-Tests bestanden und 17 Linux-Fälle
  ausdrücklich übersprungen;
- `git diff --check`: bestanden.

Damit ist die Fehlerursache lokal reproduziert, die Fallback-Logik auf
synthetischem procfs geprüft und anschließend durch den vollständigen
Debian-Lauf bestätigt. Die aktualisierte
[LINUX-LXC-TEST-GUIDE.md](LINUX-LXC-TEST-GUIDE.md) verlangt nun 20 erfolgreiche
Fälle ohne Skip und setzt die optionale task-children-Datei nicht länger als
Vorbedingung voraus.

## Alpine-Prüfstatus

Auf dem lokalen Windows-Arbeitsplatz sind weder Docker, Podman, Rancher Desktop
noch eine installierte WSL-Distribution verfügbar. Deshalb konnten die 20
Fälle hier nicht zusätzlich in einem Alpine-Container mit der Add-on-
Python-Version ausgeführt werden. Dieser Lauf ist **nicht ausgeführt** und wird
nicht als bestanden gewertet.

Der Dockerfile installiert weiterhin `python3` aus der durch
`homeassistant/aarch64-base:3.18` vorgegebenen Alpine-Paketbasis und kopiert den
abhängigkeitsfreien Prozesswächter ausführbar nach `/opt/btui/lib`. Ein späterer
Image-/Alpine-Lauf muss die tatsächlich aufgelöste Python-Version protokollieren
und alle 20 Fälle ohne Skip ausführen.

## `Connected: yes` ist keine A2DP-Bereitschaft

BlueZ `Device1.Connected` ist ein generischer Gerätekonnektivitätsstatus. Er
beweist weder das aktive Classic-A2DP-Profil noch die Existenz des konkreten
PulseAudio-Sinks. Die
[BlueZ-Device1-Dokumentation](https://github.com/bluez/bluez/blob/master/doc/org.bluez.Device.rst)
beschreibt `Connected` nur als Gerätekonnektivität; `Connect()` behandelt
dagegen unterstützte Profile und bei Dual-Mode-Geräten die Bearer-Auswahl. Eine
LE-/GATT-Verbindung, ein anderer verbundener Bearer oder ein Übergangszustand
kann daher `Connected: yes` liefern, während Audio nicht betriebsbereit ist.

Die Bridge interpretiert das bereits korrekt für Wiedergabe: Erst
`connected && a2dp_ready`, wobei `a2dp_ready` den exakten
`bluez_sink.<MAC>.a2dp_sink` verlangt, darf Renderer-Bereitschaft bedeuten.
Diese Logik wird nicht geändert.

Für den sicheren BLE-Start ist `Connected: yes` dagegen weiterhin ein Zustand
unbekannter Eigentümerschaft. Der aktuelle Transport kann nicht beweisen, ob die
Verbindung dem eigenen vorherigen Versuch, BlueZ oder einem anderen Client
gehört. Deshalb erfolgt kein spekulativer geräteweiter Disconnect. Nach dem
Prozesswächter-Fix kann der Wake folgerichtig weiterhin vor GATT mit
`no GATT connection permitted` enden, falls BlueZ dauerhaft Connected=yes
meldet. Das wäre dann ein getrennter Transport-/Ownership-Befund, nicht erneut
der `/proc`-Fehler.

## Erwartete Logs des korrigierten Wächters

Bei fehlender Kernel-Datei und normalem kurzen `bluetoothctl info`:

```text
bluetooth-process: start pid=... owner=... limit=2.0s
bluetooth-process: task children unavailable; using bounded PPid scan
bluetooth-process: reaped pid=... status=0
```

Es darf weder `[Errno 2] ... children` noch Status 125 allein wegen der fehlenden
Datei geben. Bei nicht lesbarem `/proc`, verbleibendem eigenem Kind oder Ablauf
des Cleanup-Budgets wird dagegen weiterhin ausdrücklich Status 125 gemeldet.

## Offene Gates

- Debian/Linux: erfüllt, 20/20 ohne Skips auf CT 215.
- Dieselben Fälle bzw. mindestens Kurzprozess, Fallback-Enkel, TERM/INT und
  Lock-Freigabe im gebauten Alpine-Add-on-Image ausführen; derzeit offen.
- Hardwaretest getrennt: zuerst Linkstatus. Falls Connected=yes ohne A2DP
  bestehen bleibt, Transport-/Ownership-Strategie analysieren; keinen
  pauschalen Disconnect ergänzen.
