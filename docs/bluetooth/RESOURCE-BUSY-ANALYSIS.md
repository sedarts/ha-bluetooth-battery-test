# test.10: Resource busy — lokale Analyse und begrenzte Korrektur

**Aktueller Implementierungsstand:** siehe Abschnitt „Prozessverwaltung
abgesichert“. Die vorangehenden Abschnitte dokumentieren die Entwicklung;
insbesondere die frühere geräteweite Cleanup-Trennung wurde inzwischen entfernt.

Stand: 2026-10-26. Basis: `b13a19f87e54bb82e0158861a9ef5293597ee457`,
Version unverändert `2.6.2-test.10`, ausschließlich
`sedarts/ha-bluetooth-battery-test`. Kein Commit, Push, Deployment oder Gerätetest
durch den Agenten. Dies ist keine Freigabe einer neuen Testversion.

## Hardwarebefund des Nutzers: FEHLGESCHLAGEN

Drei BLE-Versuche, dreimal `connect to C0:28:8D:82:F7:BB: Resource busy (16)`.
Keine erfolgreiche Discovery, kein ATT-Write, kein Einschaltton, keine
LED-Reaktion; BOOM vollständig ausgeschaltet. Grundlage ist der Nutzerbericht,
nicht ein hier selbst erhobener vollständiger Trace.

Übermittelter Ausschnitt (keine ergänzten oder rekonstruierten Logzeilen):

```text
1792974741.146 BLE link release start
1792974741.172 BLE link release returned exit=0
1792974741.173 BLE wake GATT discovery start
1792974741.177 Resource busy (16)
```

Disconnect-Aufruf bis Rückkehr: 26 ms. Rückkehr bis Discovery-Start: 1 ms.
Discovery-Start bis Busy: 4 ms. Der berichtete Text `Attempting to disconnect`
ist keine Abschlussbestätigung. Ein tatsächlicher Disconnect-Status wurde
nicht erfasst; aus diesen Zeiten allein lässt sich kein Verursacher bestimmen.

## Nachweisbare Codefehler und Quellen

- test.10 prüfte nach Disconnect ausschließlich den Prozessrücklauf für das Log
  und begann unabhängig davon Discovery. Keine Statusprüfung, kein Gate.
- Vorzeitige Rückgaben bei Discovery-/Parser-/Write-Fehlern übersprangen den
  bisherigen nachgelagerten Link-Release.
- Die ursprünglichen `timeout 5` hatten keine zusätzliche Kill-Eskalation.
  Das beweist keinen realen hängenden Prozess, zeigt aber eine Absicherungslücke.

BlueZ 5.66 `cmd_disconn` sendet einen asynchronen D-Bus-Aufruf. Erst
`disconn_reply` verarbeitet dessen Antwort und meldet Erfolg/Fehler. Regulär
wartet der nichtinteraktive Pfad auf diesen Callback. **Nicht behaupten, dass
bluetoothctl generell vor dem Callback erfolgreich endet.** Warum hier nur
die Anfangsmeldung bei Exit 0 vorlag, ist ohne vollständige Ausgabe,
Aufrufumgebung und konkrete Binary-Version ungeklärt.
[Quellcode client/main.c](https://github.com/bluez/bluez/blob/5.66/client/main.c)

Device1.Disconnect beendet Profile und ACL und kann ein laufendes Connect
abbrechen. Connected und ServicesResolved sind verschiedene Eigenschaften:
keine Service-Auflösung ist weder ein Beweis für ausgeschaltete Hardware noch
für einen freien ATT-Socket. Die Statusabfrage hier nutzt bluetoothctl info
als Sicht auf BlueZ; sie ist keine direkte Socket-Inventur.
[Device API](https://github.com/bluez/bluez/blob/5.66/doc/device-api.txt)

One-shot gatttool startet für Discovery und Write jeweils eine eigene direkte
ATT-Verbindung. Beim normalen Prozessende schließt das Betriebssystem dessen
Deskriptoren; die Controller-Freigabe muss damit nicht gleichzeitig beobachtbar
sein. Eine absichtlich persistente GATT-Session gibt es im aktuellen Code nicht.
[gatttool.c](https://github.com/bluez/bluez/blob/5.66/attrib/gatttool.c)

## Hypothesen — nicht bewiesen

Die konkrete Meldungsform `connect to <Adresse>: Resource busy (16)` wird in
BlueZs [btio.c](https://github.com/bluez/bluez/blob/5.66/btio/btio.c) aus dem
Socket-Connect-Fehler bzw. SO_ERROR erzeugt, nicht aus einer ATT-Write-Antwort.
[gatt_connect](https://github.com/bluez/bluez/blob/5.66/attrib/utils.c) verwendet
hier LE/L2CAP mit festem ATT-CID. Damit ist die Fehlerphase eingegrenzt:
Verbindungsaufbau vor Discovery, nicht Parser oder Power-Payload. Welcher
Kernel-/Controllerzustand EBUSY auslöst, ist damit noch nicht identifiziert.

1. Noch laufender BlueZ-Disconnect bzw. Controller-Abbau.
2. BlueZ oder ein anderer Client hält/erstellt parallel eine LE-/ATT-Verbindung.
3. Direkter ATT-Zugriff konkurriert mit BlueZ; Connected=no ist kein umfassender
   Freigabenachweis für externe oder direkte Sockets.
4. Eigener überlebender Prozess nach Abbruch; bisher kein Prozess-/FD-Beleg.
5. Scan-/Adapteraktivität oder eine andere HA-Komponente. Ein Scan allein ist
   kein nachgewiesener Busy-Auslöser und wird nicht pauschal beendet.

Der Add-on-Lock koordiniert eigene kooperierende Aufrufer, nicht HA oder fremde
Clients. Ein zielgerichtetes Device1.Disconnect kann dennoch fremde Profile
**derselben BOOM** trennen; Prozessbesitz ist aus Device1 nicht ableitbar.
Andere Geräte werden nicht angesprochen, Adapter/Daemon/Pairings nicht verändert.

## Lokal vorbereitet

Nur `lib/power-manager.sh` wurde im Laufzeitcode geändert:

- Vor Disconnect aktuellen Status lesen. Bei eindeutigem Connected=no keinen
  unnötigen Disconnect senden. Bei unbekanntem Zustand keinen Erfolg behaupten.
- Nach Disconnect bis zu vier Statusproben, jeweils höchstens zwei Sekunden;
  nur zwischen nicht erfolgreichen Proben eine Sekunde Abstand. Disconnect
  selbst höchstens fünf Sekunden. Ein Exit 0 ersetzt keine Zustandsprobe.
- Bleibt der Status yes/unknown, kein GATT-Aufbau. Ein Disconnect-Timeout kann
  nur bei anschließend tatsächlich beobachtetem Connected=no überwunden werden.
- Vor-/Nachzustand, Rücklauf und Cleanup-Ergebnis protokollieren.
- Synchroner EXIT-Cleanup pro BLE-Versuch, auch bei vorzeitiger Rückgabe und
  explizitem Prozess-Exit. Er beendet sich vor Rückkehr zum Lock-Besitzer.
  Kein Hintergrund-Cleanup, kein späteres Wiedererlangen des Locks und kein
  Disconnect ohne vorhandenen Lock-Kontext. Der Elternprozess gibt den Lock frei.
- BLE-Kommandos mit begrenzter TERM/KILL-Eskalation (`timeout -k 1`), auf den
  eigenen Aufruf beschränkt. Keine Suche/Beendigung nach globalem Prozessnamen.
- Neue BLE-Statusproben und Aufrufe berücksichtigen das verbleibende bestehende
  Wake-Budget über eine lokale SECONDS-Frist. Cleanup startet nach Fristablauf
  keine Bluetooth-Kommandos; meldet dann unbekannten/unvollständigen Zustand.
  Die Kill-Nachfrist beträgt bis zu eine Sekunde. Der gesamte bisherige MQTT-/
  Wake-Pfad ist weiterhin kein harter Echtzeit-90s-Watchdog (z.B. Statuspublikation).

Maximal drei BLE- und vier Classic-Versuche bleiben bestehen. Cleanup setzt
keinen Zähler zurück. Kein Sleep zwischen erfolgreicher Discovery und Write.
Payload, UUID, Parser, Discovery-/Write-Transport, Renderer, A2DP, Music Assistant,
SSDP und 300s-Idle-Konfiguration bleiben unverändert.

## Grenzen des Cleanups — noch nicht als vollständig gelöst deklarieren

Ein EXIT-Trap ist keine Garantie bei SIGKILL. Die direkte Beendigung des
Power-Managers während einer verschachtelten Command-Substitution sowie
vererbte Lock-FDs müssen auf Linux/Alpine untersucht werden. Ein noch lebender
Kindprozess kann einen geerbten flock-Deskriptor halten; ein Shell-Exit allein
beweist nicht, dass alle Kindprozesse beendet sind. Kein eigener FD-/Socket-
Owner-Tracker wurde auf Verdacht eingebaut. Die neuen Tests simulieren
Status-/Fehlerrückläufe, nicht diesen Kernel-/BlueZ-Lebenszyklus.

Auch das Rennen mit einem fremden Client derselben BOOM wird durch den Lock
nicht ausgeschlossen. Ein striktes besitzbasiertes Cleanup braucht eine eindeutig
eigene Session. Das bleibt vor einer Release-Freigabe offen. Im bestehenden
Normalfehlerpfad erzeugt fail_wake weiterhin ERROR, entfernt Handover-Marker und
setzt die dauerhafte Reconnect-Sperre. Ein vollständiger Signalabbruch dieses
Pfads einschließlich Marker-/MQTT-Verhalten ist noch separat zu testen.

## Transportvergleich (keine Umsetzung)

| Ansatz | Verbindung / Bestätigung | Ressourcen / Zuverlässigkeit | HAOS / Alpine / Audio |
|---|---|---|---|
| Bisherige zwei gatttool-Prozesse | Zwei ATT-Verbindungen; Write Request wird auf Antwort geprüft | Einfach begrenzbar, aber zusätzliche Verbindungsübergänge und Konflikte mit BlueZ möglich | Bestehendes bluez-deprecated; Audio-Handover unverändert |
| Eine interaktive gatttool-Session | connect, Discovery, Write Request auf derselben Session möglich | Weniger Übergänge, eindeutiger eigener Prozess; benötigt zustandsabhängiges Dialog-/EOF-/Timeout-Handling | Bestehendes Paket; eventuell zusätzlicher Dialogtreiber. Direkter ATT-Konflikt bleibt möglich; vor Classic schließen |
| BlueZ D-Bus GATT | Connect, ServicesResolved, UUID-Auflösung, WriteValue(type=request) | Strukturierte Fehler, BlueZ besitzt Transport; Verbindung kann mit anderen Clients geteilt sein | Systembus-Zugriff und geeigneter Client/Binding im Alpine-Image prüfen; kein Host-Python voraussetzen. Größerer Umbau mit Audio-Regressionsrisiko |

Interaktive Session und gezieltes Schließen sind im
[interactive.c](https://github.com/bluez/bluez/blob/5.66/attrib/interactive.c)
belegt. BlueZ bietet WriteValue mit request/command und strukturierten Fehlern
über die [GATT API](https://github.com/bluez/bluez/blob/5.66/doc/gatt-api.txt).
Keine dieser Optionen beweist BOOM-Power-On/Off. Zuerst den tatsächlichen
Busy-Verursacher messen; noch keinen Transportwechsel beschließen.

## Nächster gemeinsamer Test — nur nach Freigabe

1. Vollständige Add-on-Logs mit Operations-ID sowie Binary-/Image-Versionen
   sichern; BOOM-LEDs und Töne zeitlich separat notieren.
2. Zeitgleich passiv BlueZ PropertiesChanged (Connected, ServicesResolved),
   Adapter Discovering/Powered und verfügbare HCI-Ereignisse erfassen. btmon
   nur gezielt/lokal; Aufzeichnungen können fremde Gerätedaten enthalten.
3. Vor, während und nach genau einem expliziten Wake die relevanten eigenen
   PID/PPID/Prozessgruppen und offenen FDs erfassen; externe Bluetooth-Clients
   inventarisieren, aber nicht beenden. Keine parallelen manuellen Connects.
4. Disconnect-Anfang, D-Bus-Antwort, Connected=no, HCI-Disconnect-Complete,
   Discovery-Start und Busy zeitlich vergleichen. Erst das trennt die Hypothesen.
5. Nach ERROR prüfen: keine eigenen verbleibenden GATT-Prozesse, Lock frei,
   kein automatischer Classic-Reconnect; WebUI/MQTT erreichbar. Neuer expliziter
   Wake bleibt möglich. Keine Aussage „physisch aus“ aus Disconnect ableiten.
6. Prozess-/Timeout-/Signaltests zunächst mit Fake-Kommandos im Linux/Alpine-
   Container ohne Bluetooth-Gerät durchführen, insbesondere geerbte FDs,
   TERM/KILL, ausgeschöpftes Budget und verspätetes Cleanup/neue Operation.

## Lokale Tests

Abschließender vollständiger Lauf unter Git Bash/Windows: Exit 0.

| Prüfung | Ergebnis |
|---|---|
| Shell-Syntax: run.sh, lib/*.sh, webui/lib/*.sh, CGI und tests/*.sh | PASS |
| GATT-Parser | PASS, alle 20 Fälle |
| Power-Manager | PASS |
| Bluetooth-Koordination | PASS |
| Renderer-Recovery | PASS |
| Neue BLE-Disconnect-Suite | PASS |
| git diff --check | PASS |

Die neue Suite deckt bereits getrennt, sofort/delayed getrennt, Disconnect-
Timeout, dauerhaft verbunden, unbekannten Status, unterdrückte Discovery nach
unvollständiger Trennung, synchronen Fehler-/Exit-Cleanup, fehlschlagendes Cleanup
trotz erfolgreichem Befehl, keinen Disconnect ohne Lock-Kontext und abgelaufenes
Wake-Budget ab. Der Fall „busy“ simuliert eine weiterhin verbundene Gegenstelle;
echtes EBUSY nach einem Connect ist separat in der bestehenden Power-Suite
gemockt. Prozess-Exit 143 ist **kein** real gesendetes Signal.

Die Power-Suite prüft weiterhin drei Busy-Versuche, GATT-/Write-Fehler,
Lock-Freigabe, ERROR-Marker, unterdrückte automatische Recovery und einen neuen
expliziten Wake. Bestehende Mocks bilden jetzt Disconnect und neues Unblock als
Zustandswechsel ab. Ein erster Lauf zeigte einen unvollständigen Mock für den
zweiten Wake; dieser wurde korrigiert. Ein während einer Testdateiänderung
laufender Zwischenlauf wurde verworfen. Der oben berichtete finale Lauf erfolgte
ohne weitere Änderungen an Code oder Testdateien.

Der Guard ohne Lock und die synchrone Reihenfolge testen nur einen Teil des
Schutzes vor verspätetem Cleanup. Ein echter konkurrierender neuer Prozess nach
Abbruch muss noch im Linux-Integrationstest geprüft werden.

Nicht ausführbar hier: echte BlueZ-/ATT-/HCI-Tests, Docker-/Alpine-Integration,
Linux-Kernel-flock-/Prozessgruppen-Abbruchtests sowie echte MQTT-/WebUI-Verfügbarkeit
unter Bluetooth-Störung. Keine dieser Lücken als bestandenen Hardwaretest werten.

Geänderte/neue Dateien: `lib/power-manager.sh`, `tests/power-manager-smoke.sh`,
`tests/ble-disconnect-smoke.sh` und dieser Bericht. Gegen HEAD zusätzlich geprüft:
run.sh, Renderer-Recovery, Wake-Retries, GATT-Parser, WebUI, Dockerfile,
Add-on-Metadaten und Changelog unverändert. HEAD bleibt `b13a19f`.

## Abschlussprüfung vor test.11 (2026-10-26)

**Entscheidung: noch keine Freigabe für einen begrenzten Hardwaretest.**
Die bisherigen lokalen Änderungen bleiben erhalten. In dieser Abschlussprüfung
wurde kein Laufzeitcode weiter verändert, insbesondere kein Transportwechsel.
Neu ist `tests/linux-process-lifecycle.py`; dieser Bericht wurde ergänzt.

### Prozess- und Signalprüfung: Codebefund versus Laufzeitnachweis

Die tatsächliche Linux-Signalwirkung konnte hier nicht gemessen werden:
`wsl --list --quiet` meldet, dass WSL nicht installiert ist; Docker und Podman
sind nicht verfügbar. Git Bash/MSYS ersetzt keinen Linux-Kernel-Test. Keine
Linux-Installation, kein externer Runner und kein HA-Host wurden benutzt.

Im Code besteht folgender Ausführungspfad (vereinfachtes Besitzdiagramm, nicht
ein gemessener Linux-Prozessbaum):

```text
run.sh -> power-manager.sh (im Hintergrund gestartet)
  -> output=$(ble_power_command_once ...) -> BLE-Subshell mit EXIT-Trap
     -> discovery=$(ble_run ...) / output=$(ble_run ...)
        -> timeout -> gatttool bzw. bluetoothctl
```

| Situation | Nachgewiesener Codepfad / verbleibende Unsicherheit |
|---|---|
| Normaler GATT-Fehler | Befehl kehrt zurück, synchroner EXIT-Cleanup, Elternprozess gibt Lock frei, fail_wake setzt ERROR; Mocktests bestehen |
| GATT-Timeout | `-k 1` eskaliert nach TERM; die Wirkung auf Nachkommen hängt vom timeout-Programm und dessen Lebensdauer ab; Linux-Test offen |
| SIGTERM an Power-Manager | Äußerer Trap ruft nur clear_discovery und exit auf. Keine Kind-PID-Verwaltung, kein kill/wait für Bluetooth-Kommandos. Die Trap-Ausführung kann durch wartende Shell-Kommandos verzögert werden |
| SIGINT | Derselbe programmierte Handler, aber run.sh startet den Manager asynchron; geerbte Signaldisposition und tatsächliche Zustellung müssen im Image geprüft werden |
| SIGKILL / unerwartetes hartes Ende | Kein EXIT-/Signal-Trap garantiert; Unterprozesse können weiterleben. Das Schließen des Eltern-FDs allein genügt nicht für Lock-Freigabe |

Zusätzlich ist `connected()` vor dem BLE-Pfad weiterhin ein **unbegrenztes**
`bluetoothctl info | grep`. Auch unblock/block und andere bestehende Aufrufe
verwenden nicht durchgängig dieselbe neue BLE-Timeout-Hülle. Der Schutz der
BLE-Hülle darf daher nicht auf den gesamten Power-Manager übertragen werden.
Der äußere INT/TERM-Handler führt cleanup aus und löst durch exit anschließend
erneut den EXIT-Handler aus: doppelte Discovery-Bereinigung ist möglich; das
beendet noch keine Bluetooth-Kinder. Dieser Befund wurde nicht durch einen
ungeprüften zusätzlichen Trap- oder MQTT-Umbau überdeckt.

BusyBox 1.36 `timeout` erzeugt einen Wächter und signalisiert eine einzelne
überwachte PID; es garantiert keine rekursive Beendigung eines beliebigen
Prozessbaums. Der konkrete Anbieter von `timeout` im fertig gebauten Image
muss festgestellt werden (das Dockerfile pinnt ihn nicht ausdrücklich).
Eine auf GNU beobachtete Gruppenwirkung ist keine Alpine-Garantie.
[BusyBox timeout-Quellcode](https://github.com/mirror/busybox/blob/1_36_stable/coreutils/timeout.c)

### flock und verspätetes Cleanup

`bt_ops_acquire` öffnet einen dynamischen Shell-FD, sperrt genau diesen und
speichert seine Nummer. Die Aufrufer schließen ihn nicht vor jeder Kindausführung.
`bt_ops_release` führt dagegen explizit `flock -u` aus und schließt danach den FD.
Ein Lock gehört unter Linux zur gemeinsamen offenen Dateibeschreibung: fork/exec
können ihn erhalten. Ohne explizites Unlock müssen **alle** geerbten FDs schließen.
Umgekehrt löst ein Unlock über einen geerbten FD die gemeinsame Sperre auch dann,
wenn ein anderes Kind noch lebt. Ein bloßes frühes Unlock ist daher keine sichere
Reparatur: Es könnte eine neue Operation neben ein altes Bluetooth-Kind lassen.
[Linux flock(2)](https://man7.org/linux/man-pages/man2/flock.2.html)

Der Kommentar im bestehenden Lock-Helfer zur automatischen Freigabe bei Exit
ist nur mit dieser Einschränkung korrekt. Im normalen synchronen Ablauf bleibt
der Lock bis nach Cleanup gehalten. Der Guard `BT_OPS_FD` prüft jedoch lediglich
einen Variablenwert — keine aktuelle Kernel-Sperre, Generation oder nachgewiesene
Session-Eigentümerschaft. Nach einem Abbruch genügt das nicht als Sicherheitsbeweis.

Device1.Disconnect ist geräteweit, nicht auf einen bestimmten eigenen
gatttool-Prozess beschränkt. Ein fremder Client derselben BOOM wird durch unseren
Lock nicht koordiniert. Damit ist „ausschließlich eigene Ressourcen“ derzeit
**nicht vollständig sichergestellt**. Keine zusätzlichen Disconnects oder globalen
Kills wurden zur scheinbaren Behebung eingebaut.

Vor Freigabe erforderlich: eindeutig beaufsichtigte eigene Kinder, begrenztes
Beenden **und** Einsammeln vor Lock-Freigabe, überprüfbare Lock-/Operations-
Eigentümerschaft sowie kein nachträglicher geräteweiter Disconnect einer alten
Operation. Das bloße Schließen geerbter FDs löst nur das Lock-Leak, nicht die
Lebensdauer des noch laufenden Bluetooth-Prozesses. Diese Änderungen sollten mit
den Linux-Gates entwickelt und geprüft werden, nicht blind unter Windows.

### Getrennte ATT-Verbindungen

Ein erfolgreicher Durchlauf startet zwei verschiedene gatttool-Prozesse, jeder
mit eigenem gatt_connect. Somit gibt es tatsächlich einen zusätzlichen
Verbindungsaufbau zwischen Discovery und Write. Für GATT an sich ist dieser
Wechsel nicht erforderlich (interaktive Session kann beide Schritte tragen).
Er kann eine weitere Konfliktstelle schaffen, erklärt aber **nicht** den bisher
beobachteten test.10-Fehler vor der ersten erfolgreichen Discovery. Keine neue
Wartezeit zwischen Discovery und Write und kein Transportwechsel implementiert.

### Linux-Test-Gate und Ausführung

```sh
python3 tests/linux-process-lifecycle.py -v
```

Voraussetzungen: isolierte Linux-Testumgebung, /proc, Python 3, Bash, flock,
timeout. Python ist nur Testabhängigkeit, nicht neue Add-on-Abhängigkeit.
Kein Bluetooth-Gerät und kein D-Bus-/Netzwerkzugriff erforderlich. Die Suite
ersetzt gatttool, bluetoothctl, pactl und MQTT-Programme durch lokale Fakes;
Shell, Kernel-Locks, timeout und Signale bleiben echt. Sie startet den echten
Power-Manager mit seinen produktiven Traps (`PM_TEST_MAX_LOOPS=0`). Signale gehen
gezielt an die Manager-PID, nicht pauschal an alle Kinder. Jeder Test erhält eine
eigene Sitzung; Test-Aufräumen beendet ausschließlich Prozesse dieser Sitzung.

Neun Fälle: explizites Unlock mit geerbtem FD; Lock nach hartem Elternabbruch;
TERM/INT/KILL während unbegrenzter info-Abfrage; TERM/INT/KILL während GATT;
GATT-Timeout mit Lock-Freigabe, ERROR-Marker und weiterlebendem MQTT-Loop.
Für Signal-/Timeout-Fälle wird eine 10s-Beobachtungsgrenze verwendet (Testgrenze,
keine Änderung des 90s-Wake-Limits). Der Lock-Vererbungsfall ist bewusst ein
Freigabe-Gate, kein expectedFailure: Der derzeitige Helfer dürfte ihn nicht
erfüllen. Das ist aus dem Code abgeleitet, **kein ausgeführtes Linux-Ergebnis**.

Lokaler Python-Aufruf: neun Fälle erkannt, **alle neun SKIPPED** wegen fehlendem
Linux. Kein Linux-PASS. Der Testcode wurde geladen und syntaktisch verarbeitet,
seine Linux-Ausführung ist noch unvalidiert. Auch GNU- und BusyBox-Läufe müssen
getrennt protokolliert werden. BusyBox-Wächter können eigene Sitzungen verwenden;
deren Ende und mögliche geerbte FDs müssen zusätzlich im Alpine-Prozess-/FD-Trace
geprüft werden. Der Test simuliert noch nicht den s6-/Supervisor-Stop oder den
asynchronen run.sh-Start, keinen echten Gerätebesitz und keine tatsächliche
neuere Bluetooth-Verbindung. Dafür ist ein zusätzlicher Integrationstest nötig.

### Erwartete Logfolge beim nächsten freigegebenen Hardwaretest

Vorlage, **kein aufgezeichneter Test**. Zeit und op-ID müssen pro Durchlauf
korrelieren. BLE-Ausgaben werden noch per Command-Substitution gesammelt und
können daher später sichtbar werden; die eingebetteten Zeitstempel auswerten.
Bluetooth-Lock-Logs verwenden eine eigene ID, Power-Manager-Logs die Wake-ID.

```text
[t0][power-manager][op=none] command received: wake
[t1][power-manager][op=wake-...] wake command received
[t2][power-manager][op=wake-...] state=WAKING reconnect pause set before waiting for shared Bluetooth lock
[t3][bluetooth][op=wake-...] lock requested operation=wake-... wait=18s
[t4][bluetooth][op=wake-...] lock acquired operation=wake-...
[t5][power-manager][op=wake-...] Bluetooth reconnect block cleared
[t6][power-manager][op=wake-...] state=WAKING operation=ble-wake attempt=1/3 start
[t7][power-manager][op=wake-...] BLE link release start phase=before-wake-discovery device=C0:28:8D:82:F7:BB
[t8][power-manager][op=wake-...] BLE link state phase=before-wake-discovery-before exit=0: ... Connected: no ...
[t9][power-manager][op=wake-...] BLE link already disconnected according to BlueZ; direct ATT ownership remains unknown
[t10][power-manager][op=wake-...] BLE wake GATT discovery start device=... uuid=...
[t11][power-manager][op=wake-...] BLE wake GATT discovery process exited status=0: handle = ...
[t12][power-manager][op=wake-...] BLE wake GATT characteristic selected uuid=... value_handle=... properties=...
[t13][power-manager][op=wake-...] BLE wake GATT write request start value_handle=...
[t14][power-manager][op=wake-...] BLE wake GATT write process exited status=0: Characteristic value was written successfully
[t15][power-manager][op=wake-...] BLE wake GATT write request confirmed by ATT response; physical speaker action remains unconfirmed
[t16][power-manager][op=wake-...] BLE link release start phase=attempt-cleanup device=...
[t17][power-manager][op=wake-...] BLE link state phase=attempt-cleanup-before exit=0: ... Connected: no ...
[t18][power-manager][op=wake-...] BLE link already disconnected according to BlueZ; direct ATT ownership remains unknown
[t19][power-manager][op=wake-...] BLE wake series ended attempts=1/3 result=submitted
[t20][power-manager][op=wake-...] BLE wake command submitted; waiting for the speaker to switch to Classic audio
[t21][bluetooth][op=wake-...] lock released operation=wake-...
```

Danach unverändert: `waiting ... for Classic audio boot`, `renderer handover
requested`, `normal reconnect monitor released after BLE wake`, gegebenenfalls
`A2DP sink is ready`, schließlich nur bei Renderer-Bestätigung `wake_success`.
Ton/LED-Reaktion müssen getrennt beobachtet werden. Bei Eigenschaft Write Command
statt Request gelten die bereits bestehenden alternativen Write-Logs ohne ACK.

Falls bei t8 Connected=yes/unknown: zwischen t8 und Discovery müssen
`BLE link release returned ... checking BlueZ state`, ein oder mehrere
`BLE link state phase=before-wake-discovery-after-N ...` und danach
`BLE link disconnected according to BlueZ ...` erscheinen. Bleibt die Prüfung
erfolglos: `BLE link release unconfirmed ... no GATT connection permitted`,
Cleanup, `series ended ... failed`, Lock-Freigabe, `state=ERROR wake failed`.
In diesem Zweig darf kein Discovery-/Write-Start folgen.

Bei erneutem EBUSY nach bestätigtem BlueZ-Status: Discovery-Fehler, synchroner
`attempt-cleanup`, gegebenenfalls `resource busy; bounded retry N/3 after 1s`,
höchstens drei Versuche. Nach Ausschöpfung: `result=failed`, Lock-Freigabe und
ERROR, **kein** Renderer-Handover und keine automatische Classic-Serie.
`BLE cleanup incomplete; link state unknown` ist kein Freigabenachweis und
verhindert einen erfolgreichen Gesamtrücklauf. Nach Signalabbruch ist diese
Folge derzeit nicht garantiert — genau deshalb bleibt die Freigabe gesperrt.

### Wiederholte Bestandsprüfung dieser Abschlussrunde

Alle fünf bisherigen Smoke-Suiten erneut PASS: BLE-Disconnect,
Bluetooth-Koordination, GATT-Discovery (20 Fälle), Power-Manager und
Renderer-Recovery. Shell-Syntax aller bisherigen Shell-/CGI-/Testdateien PASS;
`git diff --check` PASS. Die neue Linux-Suite ist davon getrennt: 9 SKIPPED.
Keine tatsächlichen Signalabbrüche unter Linux oder Hardwaretests ausgeführt.
Kein Commit, Push, Deployment oder Versionswechsel; Ausgangs-HEAD weiterhin
`b13a19f87e54bb82e0158861a9ef5293597ee457`.

## Prozessverwaltung abgesichert — lokale Implementierung, keine Release-Freigabe

Dieses Arbeitspaket ersetzt die früheren pauschalen Cleanup-Disconnects und die
Bluetooth-timeout-Aufrufe. Audio-/Renderer-Algorithmen, MQTT-Themen/Payloads,
BLE-Payload, zwei getrennte ATT-Aufrufe und Retry-Zähler wurden nicht umgebaut.
Version bleibt test.10, keine Veröffentlichung. Die Änderungen sind noch nicht
auf einem Linux-Kernel oder im Add-on-Image validiert.

### Ein gemeinsamer Prozesswächter

`lib/bluetooth-process.py` startet genau den angeforderten Befehl in einer eigenen
Session/Prozessgruppe, ohne geerbte zusätzliche FDs. Der Shell-Einstieg
`bt_process_run` schließt insbesondere den gemeinsamen Lock-FD **ohne Unlock**
vor exec; die aufrufende Shell behält den Lock bis zum Ende der Operation.
Verschachteltes Lock-Acquire wird jetzt abgewiesen statt einen zweiten Lock-FD
zu öffnen. Die bestehenden Lock-Dateien und Aufrufreihenfolgen bleiben erhalten.

Der Wächter prüft mit monotoner Zeit das Limit und alle 50 ms Lebensdauer/
Startzeit des Besitzers, Stop-Marker und eigene TERM/INT-Signale. Bei Abbruch
sendet er TERM an die eigene Gruppe, nach bis zu 0,5 s KILL, wartet das direkte
Kind ab und sammelt adoptierte Nachkommen ein. Linux PR_SET_CHILD_SUBREAPER
ermöglicht dies auch für verwaiste Enkel. waitid(WNOWAIT) hält die Leader-PID
bis nach dem Gruppensignal reserviert; keine verspäteten Signale an eine
wiederverwendete Gruppe. Adoptierte Kinder werden nur als eigene, noch nicht
abgewartete Kinder signalisiert. Kein pkill/killall, keine Suche nach fremden
Bluetooth-Prozessnamen, kein Adapter-/Daemon-Reset.

Nach einem normalen Kommandoende gibt es **keine pauschale 0,5-s-Pause** zwischen
Discovery und Write. Eventuell hinterlassene eigene Nachkommen werden trotzdem
beendet. Die Halbsekunde ist ausschließlich die Abbruch-Eskalationsfrist.
Rückgabewerte: 124 Timeout, 125 Abbruch/fehlender Besitzer/Startfehler; sonst
Status des Befehls. ACK- und Parser-Prüfungen bleiben bestehen.

Python 3 ist dafür eine neue explizite Laufzeitabhängigkeit im Dockerfile.
Der neue Helfer wird kopiert und ausführbar gemacht. Keine externen Python-
Pakete nötig. Das ist eine Prozessaufsicht, kein neuer Bluetooth-Transport.

Systemgrundlagen: [Linux Subreaper](https://man7.org/linux/man-pages/man2/PR_SET_CHILD_SUBREAPER.2const.html)
und [Python waitid](https://docs.python.org/3/library/os.html#os.waitid).

### Audit sämtlicher Bluetooth-Aufrufe

Alle Aufrufe in run.sh, Power-Manager und WebUI wurden geprüft. Die gemeinsame
Bibliothek definiert `bluetoothctl` für bisher direkte Abfragen als begrenzten
Wrapper. Vorhandene `timeout ... bluetoothctl` wurden auf den Wächter umgestellt;
kein externer timeout-Aufruf darf die Shell-Funktion umgehen.

| Aufruf | Kommando-Budget (plus ggf. Abbruch-Eskalation) |
|---|---|
| Power-Manager initiales Connected/info | 3 s |
| BLE-Zustandsprobe | 2 s |
| GATT Discovery / Write | je 5 s, zusätzlich auf verbleibendes Wake-Budget begrenzt |
| Allgemeines bluetoothctl info/devices, WebUI remove/block/unblock | 5 s |
| Classic power/connect | bisher übergebenes Limit, normalerweise 8 s |
| Lock-Helfer disconnect/unblock/block | bisher 5 s |
| WebUI trust/connect | 8 s |
| WebUI expliziter Hintergrund-Connect | 20 s |
| WebUI Scan-/Pair-Sitzung | 70 s |

Renderer-Recovery selbst wurde nicht editiert; seine info-Abfrage verwendet zur
Laufzeit den gemeinsamen Wrapper. Hintergrund-Monitor und WebUI-Jobs erhalten
ihre eigene Besitzer-PID, damit das Ende des ursprünglichen CGI nicht einen
beabsichtigten Hintergrundjob beendet. Die FIFO-Sitzung der WebUI bleibt bestehen.

### Signal- und Lock-Lebensdauer

Der Manager legt ein privates temporäres Verzeichnis an. Aktive Wächter melden
sich dort mit einer eigenen child-PID-Datei an, bevor sie einen Befehl starten,
und entfernen sie erst nach Prozessbereinigung. Der erste TERM/INT-Handler setzt
den Stop-Marker, ignoriert weitere TERM/INT während der Bereinigung, wartet auf
alle angemeldeten Wächter und gibt erst danach den Lock frei. Laufender Wake
hinterlässt ERROR-Marker und dauerhafte Reconnect-Sperre. EXIT-Cleanup ist
idempotent; kein doppeltes clear_discovery mehr. Ein Start nach Stop wird sowohl
in der Shell als auch vom Wächter abgewiesen. Temp-Verzeichnis wird nur vom
zugehörigen Lauf entfernt, nicht per globaler Bereinigung.

run.sh startet den Manager über den exec-Modus des Helfers: Dieser setzt INT/
TERM vor exec auf Standard zurück, damit der asynchrone Shell-Start kein
dauerhaft ignoriertes SIGINT in den Manager trägt. MQTT-Protokoll und normale
Fehlerbehandlung bleiben unverändert.

Bei SIGKILL des Managers ist kein Shell-Cleanup möglich. Die separaten Wächter
erkennen den fehlenden/zombifizierten Besitzer und beenden ihre Kinder; leere
eigene Temp-Verzeichnisse werden anschließend entfernt. Bluetooth-Executables
erben den Lock-FD nicht. Kurzlebige Bash-Command-Substitutions können den FD noch
halten, bis der Wächter zurückkehrt; „keinerlei FD-Vererbung an irgendeine Shell“
wird nicht behauptet. Nicht beaufsichtigte beliebige Prozesse dürfen weiterhin
**nicht** unter gehaltenem Lock gestartet werden. Der Linux-Test hält einen
rohen sleep als Negativ-/Kontrollfall für die Kernel-Vererbungssemantik bei;
der Orphan-Gate-Fall nutzt dagegen den produktiven beaufsichtigten Aufruf.

### Eigentümerschaft statt geräteweitem Cleanup

- Eigene Ressource: die tatsächlich gestartete Kommando-Prozessgruppe und deren
  Nachkommen. Sie werden geschlossen/beendet und abgewartet.
- Bestehende Verbindung mit Connected=yes: Herkunft unbekannt. Nur begrenzt
  beobachten, **kein Disconnect** zur Erzwingung einer freien Leitung.
- Neuere oder fremde Verbindung: Cleanup führt überhaupt keine Geräteoperation
  aus und kann diese daher nicht geräteweit trennen.
- Connected=no: Voraussetzung für den GATT-Versuch, aber weiterhin kein Beweis
  eines freien Controllers oder einer physisch ausgeschalteten BOOM.

Der Funktionsname ble_release_link bleibt für den kleinen Diff erhalten, bedeutet
jetzt ausschließlich Statusprüfung/Abwarten. Nach höchstens vier erfolglosen
Proben wird ohne GATT-Start abgebrochen. Nach GATT endet Cleanup mit Reaping;
keine erneute Geräteabfrage/Disconnect-Serie. Dadurch kann ein Wake bei einer
bereits verbundenen BLE-BOOM ohne A2DP künftig kontrolliert scheitern statt diese
Verbindung aktiv wegzutrennen. Das ist die beabsichtigte Sicherheitsgrenze.

Die bestehende explizite **Idle-Aktion** (300 s Inaktivität) sowie ausdrücklich
angeforderte WebUI-Geräteaktionen sind keine Fehler-Cleanup-Operationen; deren
bisherige Disconnect/Block/Remove-Funktion bleibt erhalten und ist nun begrenzt.
Ein echtes geräteweites BLE-Link-Cleanup lässt sich mit zwei unabhängigen
gatttool-Prozessen nicht eindeutig als exklusiv eigenes Device1-Objekt beweisen.
Wenn das Gerät dauerhaft eine fremd gehaltene Verbindung meldet, ist als nächste
Stufe eine durchgehende eigene ATT-Session oder ein koordinierter BlueZ-D-Bus-
Client zu untersuchen. Auch D-Bus Disconnect ist nicht automatisch exklusiv.
Kein solcher Transportwechsel in diesem Arbeitspaket.

### Aktualisierte erwartete Logs (ersetzen die frühere Disconnect-Vorlage)

Vor jedem Versuch weiterhin Wake-Pause, Lock-Acquire und `attempt=N/3`.
Dann bei Connected=no:

```text
BLE link release start phase=before-wake-discovery ...
BLE link state phase=before-wake-discovery-before exit=0: ... Connected: no ...
BLE link already disconnected according to BlueZ; direct ATT ownership remains unknown
BLE wake GATT discovery start ...
BLE wake GATT discovery process exited status=0: bluetooth-process: start pid=... owner=... limit=5.0s; handle = ...; bluetooth-process: reaped pid=... status=0
BLE wake GATT characteristic selected ...
BLE wake GATT write request start ...
BLE wake GATT write process exited status=0: ... Characteristic value was written successfully ...
BLE wake GATT write request confirmed by ATT response; physical speaker action remains unconfirmed
BLE attempt-cleanup: own command processes reaped; no device-wide disconnect
BLE wake series ended attempts=1/3 result=submitted
```

Danach unverändert Lock-Freigabe, Boot-Wartebudget, Handover, A2DP und Renderer.
Die Reihenfolge innerhalb zusammengefasster stdout/stderr-Ausgaben kann durch
Pufferung variieren. BLE-Zeitstempel werden weiterhin gepuffert ausgegeben.
Bei unbekannter Verbindung zusätzlich `BLE link ownership unknown ... no
device-wide disconnect; bounded observation only`, Statusproben und bei weiter
unklarem Zustand `no GATT connection permitted`, Cleanup, ERROR.
Bei Busy: Discovery-Fehler, Cleanup ohne Disconnect, höchstens drei Versuche,
danach ERROR ohne Classic-Handover. Bei Timeout: `bluetooth-process: timeout`,
`reaped ... status=124`; bei Besitzer-/Signalabbruch `abort ... status=125`.
Ein Manager-Signal protokolliert `process cleanup: stop requested; waiting for
owned commands` und erst nach Reaping `owned commands ended; lock released;
no disconnect`. Physische LED-/Ton-Beobachtungen bleiben separat erforderlich.

### Tests und ausdrücklich offene Grenzen

Die neun Linux-Prüffälle wurden weiterverwendet und auf **15** erweitert:
zusätzlich info-Timeout, wiederholte Signale, unbekannte Verbindung ohne
Disconnect und Resource-busy-Cleanup mit erneutem expliziten Wake, adoptierte
Enkel mit eigener Session und SIGINT beim asynchronen Manager-Start. Der Lock-Test
prüft zusätzlich die FDs des eigentlichen Bluetooth-Kindes. Echter Wächter und
Kernel-fcntl/flock werden dabei nicht gemockt, Bluetooth/MQTT dagegen vollständig.

Hier sind **alle 15 Linux-Tests NICHT AUSGEFÜHRT (SKIPPED)**. Windows/Git Bash
kann /proc, prctl, Subreaper, waitid und Linux-Signale nicht validieren. Der neue
Python-Code wurde syntaktisch geprüft. Die bisherigen fünf Smoke-Suiten inkl.
20 Parser-Fällen bestanden; deren Power-Manager-Prozesswächter ist bewusst ein
Mock. Sie beweisen Zustands-/Retry-Verhalten, nicht Prozessbereinigung.

Vor Freigabe zwingend: die 15 Tests auf Linux sowie im tatsächlichen Alpine-
Image ausführen, dann asynchronen run.sh-Start/SIGINT, s6-/Supervisor-Stop,
WebUI-Hintergrundjob/FIFO und wiederholte Signale im Image prüfen. Docker-Build
und Linux-Lauf waren hier nicht möglich. Kernel-ununterbrechbarer D-Zustand kann
auch KILL/wait verzögern; bewusst wird dann nicht voreilig Lock-Freigabe und
vollständige Bereinigung behauptet. Ein SIGKILL des **Wächters selbst** oder ein
gleichzeitiger Container-/Kernelabbruch ist nicht durch dessen Python-finally
absicherbar; hierfür bleibt cgroup-/Supervisor-Bereinigung nötig. Unter SIGKILL
können außerdem Shell-Marker übrig bleiben. Diese Fälle sind keine bestandenen
Abbruchtests. Ein beendeter bluetoothctl-Prozess nimmt außerdem keine bereits
an bluetoothd gesendete asynchrone D-Bus-Operation zurück; Connected-Status und
externe Client-Aktivität müssen weiterhin separat beobachtet werden.

**Weiterhin keine Hardwaretest-/Release-Freigabe ohne Linux-/Alpine-Nachweis.**

Geänderte Dateien dieses Arbeitspakets: `lib/bluetooth-process.py` (neu),
`lib/bluetooth-ops.sh`, `lib/power-manager.sh`, `run.sh`, `Dockerfile`,
`webui/lib/btui.sh`, `webui/www/cgi-bin/action.cgi`, die drei Testdateien
`tests/power-manager-smoke.sh`, `tests/ble-disconnect-smoke.sh`,
`tests/linux-process-lifecycle.py` und dieser Bericht. Vorhandene lokale
Änderungen wurden darauf aufbauend erhalten/gezielt weiterentwickelt.
Unverändert gegen HEAD geprüft: Renderer-Recovery, Wake-Retry-Helfer,
GATT-Parser, Add-on-Konfiguration, Build-Metadaten und Changelog.
Abschließender Bestandslauf: alle fünf Smoke-Suiten PASS, 20 Parser-Fälle PASS,
Shell- und Python-Syntax PASS, `git diff --check` PASS; Linux-Suite 15 SKIPPED.
Kein Commit, Push, Deployment, Versionswechsel oder Hardwaretest.

## Linux-Prozess-Gate bestanden und Abschlussbewertung für test.11

### Extern ausgeführter Linux-Lauf

Am 26. Oktober 2026 wurde der vollständige Stand der Linux-Prozesstests nach
Angabe des Anwenders in einer echten Linux-Umgebung ausgeführt:

- Proxmox CT 215 (`dashcast`), Debian;
- Python 3.13.5, Testbenutzer `prakti`;
- kein Bluetooth-Adapter, kein BlueZ-Dienst und kein Home Assistant;
- Aufruf: `python3 tests/linux-process-lifecycle.py -v`;
- Laufzeit: 53,830 Sekunden;
- Ergebnis: `Ran 15 tests`, `OK`, keine Skips.

Damit sind folgende 15 Einzelprüfungen unter echtem Linux-`/proc`, echten
Signalen, echtem Kernel-`flock`, `waitid` und Subreaper-Verhalten bestanden:

1. `test_adopted_descendant_reaped`
2. `test_background_manager_receives_int`
3. `test_busy_cleanup_and_new_wake`
4. `test_explicit_unlock_releases_inherited_description`
5. `test_gatt_int`
6. `test_gatt_kill`
7. `test_gatt_term`
8. `test_gatt_timeout_cleanup_and_error`
9. `test_info_deadline`
10. `test_info_int`
11. `test_info_kill`
12. `test_info_term`
13. `test_orphan_must_not_pin_shared_lock`
14. `test_repeated_signals`
15. `test_unknown_connection_is_never_disconnected`

Der Lauf ist ein vom Anwender übermittelter externer Testnachweis; in diesem
Arbeitsverzeichnis liegt kein vollständiges Rohlog des LXC-Laufs. Der Test
benutzt absichtlich simulierte `bluetoothctl`-, `gatttool`-, Audio- und
MQTT-Prozesse. Er belegt Prozess-, Signal-, Timeout- und Lock-Verhalten, aber
weder einen echten BlueZ-/ATT-Transport noch eine physische BOOM-Reaktion.

Die frühere Aussage in diesem Dokument, alle Linux-Fälle seien übersprungen,
beschreibt den damaligen Windows-Bestand und wird durch diesen späteren
Linux-Nachweis für den aktuellen Kandidaten ersetzt. Alpine/Add-on-Image,
s6-/Supervisor-Stop und Hardware bleiben separate Integrationsstufen.

### Erneute lokale Abschlussprüfung

Auf demselben lokalen Kandidaten wurden anschließend erneut ausgeführt:

| Prüfung | Ergebnis |
|---|---|
| Shell-Syntax: `run.sh`, `lib/*.sh`, `webui/lib/*.sh`, CGI, `tests/*.sh` | PASS |
| Python-Syntax: Prozesswächter und Linux-Testdatei | PASS |
| `tests/gatt-discovery-smoke.sh` | PASS — 20 Parser-Fälle |
| `tests/power-manager-smoke.sh` | PASS |
| `tests/bluetooth-coordination-smoke.sh` | PASS |
| `tests/renderer-recovery-smoke.sh` | PASS |
| `tests/ble-disconnect-smoke.sh` | PASS |
| `git diff --check` | PASS |

Docker/Podman steht in der lokalen Windows-Umgebung nicht zur Verfügung; ein
Image-Build wurde daher **nicht ausgeführt**. Die statische Dockerfile-Prüfung
bestätigt `python3`, `flock`, `bluez-deprecated`/`gatttool`, das Kopieren von
`lib/bluetooth-process.py` nach `/opt/btui/lib/` und dessen Ausführungsrecht.
Der Helfer benötigt ausschließlich die Python-Standardbibliothek.

### Timeouts, Retry-Limits und Locks

Die Abschlussprüfung ergab keine unbeabsichtigte Änderung der fachlichen
Grenzen: `bluetoothctl info` im Power-Manager 3 s, BLE-Zustandsprobe 2 s,
Discovery und Write je 5 s, BLE höchstens drei Versuche mit 1 s Pause, Classic/
A2DP höchstens vier Versuche innerhalb des unveränderten globalen Wake-Deadlines,
Renderer-Recovery begrenzt und 300 s Idle unverändert. Die 0,5 s im
Prozesswächter sind nur die TERM-zu-KILL-Eskalation bei Abbruch, kein zusätzlicher
Normalpfad-Delay.

Die für Wake, Idle, Classic-Reconnect, Startup, Scan und Pairing bereits
koordinierten Pfade benutzen weiterhin den gemeinsamen Lock. Verschachteltes
Acquire wird abgewiesen. `bt_process_run` schließt den geerbten Lock-FD im Kind,
während der Besitzer den Lock bis zum synchronen Operationsende hält.
Stop-Marker verhindern neue Kommandos während Manager-Cleanup. Die
Linux-Prüfungen bestätigen Lock-Freigabe nach Timeout, TERM, INT, KILL,
Resource-busy und Besitzerabbruch sowie einen neuen Wake nach Fehlerzustand.

Die Abschlussprüfung fand eine bestehende Grenze, die in den früheren
Zusammenfassungen zu pauschal beschrieben war: die ausdrücklich angeforderten
WebUI-Aktionen Forget (`remove`), Pause (`block`) und Resume (`unblock` plus
Hintergrund-`connect`) laufen über den neuen begrenzten Prozesswächter, erwerben
aber keinen gemeinsamen Adapter-Lock. `require_idle` serialisiert sie nur gegen
WebUI-Scan/Pairing, nicht gegen Power-Manager oder Reconnect-Monitor. Das ist
keine durch dieses Arbeitspaket eingeführte Entsperrung, bleibt aber ein realer
Konkurrenzpfad und eine mögliche, nicht bewiesene Mitursache für Controller-/ATT-
Busy. Eine nachträgliche Lock-Änderung würde den auf Debian bestandenen Kandidaten
funktional verändern und benötigt eigene Regressionstests; sie wurde hier nicht
ungeprüft vorgenommen. Beim kontrollierten Hardwaretest dürfen diese WebUI-
Aktionen nicht parallel zum Wake/Power-Off ausgelöst werden.

### Ursache von `Resource busy` bleibt offen

Nachgewiesen ist nur, dass der reale Fehler im direkten ATT-Aufbau von
`gatttool` vor erfolgreicher Discovery bzw. vor dem Write auftrat. Nicht
nachgewiesen ist, welcher Prozess oder BlueZ-/Controller-Zustand die ATT-Ressource
zu diesem Zeitpunkt hielt. Plausible, aber **nicht bestätigte** Ursachen bleiben
eine bereits bestehende Device1-/ATT-Verbindung, ein anderer Bluetooth-Client,
ein noch nicht vollständig abgebauter vorheriger ATT-Versuch oder der Wechsel
zwischen den getrennten Discovery- und Write-Verbindungen. Auch eine gleichzeitig
ausgelöste, bisher nicht am gemeinsamen Lock beteiligte WebUI-Aktion ist als
Software-Konkurrenzpfad möglich, für den beobachteten Fehler aber nicht belegt.
Die simulierten
Linux- und Smoke-Tests können diese reale Besitz-/Controller-Ursache nicht
bestimmen.

Der Kandidat behebt deshalb nicht behauptet die physische Ursache. Er begrenzt
die Folgen: maximal drei Versuche, vollständiges Reaping eigener Prozesse,
Lock-Freigabe, kein pauschaler geräteweiter Disconnect unbekannter Herkunft,
ERROR ohne Classic-Handover und ein neuer Wake nur nach neuem explizitem Befehl.
Eine durchgehende ATT-Session oder ein koordinierter BlueZ-D-Bus-Client bleibt
eine spätere, getrennt zu entwerfende Transportänderung.

### Freigabeentscheidung

**Der lokale Kandidat ist für einen kontrollierten test.11-Hardwaretest
freigabefähig, nicht für eine Produktionsfreigabe.** Vor dem Hardwaretest sind
noch der ausdrücklich freizugebende Versions-/Changelog-Schritt, Image-Build und
Deployment nötig. Der Hardwaretest muss Resource-busy, reale BLE-Discovery/
Write-Bestätigung, LED/Ton, A2DP/Renderer und den 300-s-Power-Off getrennt
protokollieren. Kein Commit, Push, Versionswechsel, Build, Deployment oder
Hardwaretest erfolgte in dieser Abschlussrunde.
