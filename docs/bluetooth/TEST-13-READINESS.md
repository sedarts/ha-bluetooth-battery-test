# UE BOOM 2 — test.13 BLE-Wake-Readiness

Stand: 2026-10-26. Dieser Bericht beschreibt den lokalen Kandidaten
`2.6.2-test.13`. Er ist weder veröffentlicht noch auf Home Assistant
installiert und enthält keinen Hardwaretest.

## Historische Regression

Der Vergleich der veröffentlichten Stände bestätigt zwei voneinander
getrennte Regressionen:

- `251698a` (test.5) verwendete nach einem begrenzten
  `bluetoothctl connect C0:28:8D:82:F7:BB` eine einzelne interaktive
  BlueZ-GATT-Sitzung. Darin wurden die UUID
  `c6d6dc0d-07f5-47ef-9b59-630622b01fd3` gewählt und die Dezimalbytes
  `140 104 171 224 63 246 1` geschrieben. Zu diesem Stand wurde am echten
  Lautsprecher ein Einschaltton beobachtet; später waren A2DP und Renderer
  verfügbar.
- `c1fba58` (test.8) ersetzte diese Sitzung durch zwei unabhängige
  `gatttool`-Verbindungen für Discovery und Write. Die später dokumentierten
  `Resource busy (16)`-Fehler liegen auf diesem zweifachen ATT-Pfad.
- `7838a96` (test.11) stellte vor jede direkte ATT-Operation ein Ownership-Gate.
  Weil BlueZ `Connected: yes` auch ohne A2DP meldet und keine Bearer- oder
  Eigentumsaussage liefert, verhinderte das Gate im Hardwaretest von test.12
  jeden GATT-Zugriff.
- `d7a644a` (test.12) reparierte ausschließlich die Prozessüberwachung bei
  fehlendem `/proc/self/task/.../children`; es änderte den blockierten
  Wake-Transport nicht.

## Lokale Korrektur

`lib/power-manager.sh` verwendet für **Wake** wieder den test.5-Transport:

1. Adapterzustand begrenzt prüfen.
2. `bluetoothctl info` nur protokollieren. `Connected: yes` ist kein Abbruch.
3. Den bekannten Lautsprecher über BlueZ ansprechen.
4. In einer einzigen überwachten `bluetoothctl`-GATT-Sitzung die bekannte UUID
   auswählen und genau `8C68ABE03FF601` als Dezimalbytes schreiben.
5. Nur eigene Prozesse beenden und abwarten; keine geräteweite Trennung senden.
6. Erst nach abgeschlossenem Cleanup den unveränderten Classic/A2DP- und
   Renderer-Handover freigeben.

Es gibt keinen neuen direkten ATT-Fallback. Der bestehende `gatttool`-Pfad
bleibt auf den Power-Off-Versuch begrenzt. Seine offene Hardwaretauglichkeit
ist nicht Gegenstand dieser Wake-Korrektur.

Ein `bluetoothctl`-Transcript mit `Attempting to write .../char0002` belegt nur,
dass die Anfrage an das gewählte BlueZ-Attribut übergeben wurde. Es ist weder
eine zweifelsfreie ATT-Write-Response noch ein Nachweis des physischen
Einschaltens. Der Zustand bleibt bis zum A2DP-Sink unbekannt.

## Logging

Alle neuen Stufen tragen dieselbe Wake-ID und eine verstrichene Zeit:

- `[BLE]`: Adapter, Gerätezustand, GATT-Verbindungsanfrage,
  Characteristic-Auswahl, Write-Ergebnis und eigenes Cleanup;
- `[POWER]`: Wake-Eingang und Warten auf den physischen Start;
- `[CLASSIC]`: Übergabe und einzelne Classic/A2DP-Versuche;
- `[AUDIO]`: vorhandener A2DP-Sink oder begrenztes Scheitern;
- `[HA]`: Renderer-Start und bestätigte Bereitschaft.

## Automatisierte Prüfstrategie

Die lokalen Mock-Tests prüfen insbesondere:

- `Connected: yes` ohne A2DP lässt den BlueZ-GATT-Wake zu;
- UUID, Value Handle und Payload sind exakt;
- im Wake wird kein `bluetoothctl disconnect` ausgeführt;
- Adapter-, Write-, Timeout- und fehlende-Bestätigungsfehler enden in `ERROR`;
- Classic/A2DP beginnt erst nach synchronem BLE-Cleanup;
- Locks und eigene Kindprozesse werden auch im Fehlerpfad freigegeben;
- Parser-, Renderer-, Koordinations- und Idle-Verhalten bleiben abgedeckt.

Die 20 Linux-Prozesstests benötigen weder Bluetooth, BlueZ noch Home Assistant.
Der frühere Ownership-Fall erwartet nun ausdrücklich den BlueZ-Wake ohne
Geräte-Disconnect; Prozess-, Signal- und Lock-Fälle bleiben erhalten. Die
erfolgreichen test.12-Ergebnisse wurden nicht als test.13-Ergebnis
wiederverwendet.

Der neue test.13-Lauf wurde anschließend vom Anwender auf Proxmox CT 215
(`dashcast`) unter Debian mit Python 3.13.5 ausgeführt. Ergebnis: 20/20 Tests
bestanden, 0 Fehler, 0 Skips, 74,702 Sekunden, Abschluss `OK`. Darunter waren
`test_connected_without_a2dp_allows_wake_without_disconnect`,
`test_gatt_timeout_cleanup_and_error` sowie die Prozesswächter-, Signal-, Lock-
und Cleanup-Fälle.

## Verbleibende Hardware- und Alpine-Risiken

- Nur der echte UE BOOM 2 kann bestätigen, ob die restaurierte Sequenz erneut
  Einschaltton, LED und anschließenden A2DP-Sink auslöst.
- BlueZ 5.66 im Add-on kann den zeitlichen Ablauf oder das interaktive
  `bluetoothctl`-Transcript anders darstellen als die Mocks. Die Sitzung ist
  begrenzt; eine fehlende `char0002`-Write-Zeile wird sicher als unbestätigt
  behandelt.
- Der Write-Request darf im Hardwarebericht nicht als physischer Power-On
  gewertet werden. Erst A2DP und Renderer belegen den nutzbaren Audiopfad.
- Die Ursache früherer `Resource busy (16)`-Fehler bleibt für die getrennten
  Power-Off-ATT-Verbindungen offen. Der test.13-Wake benutzt diesen Pfad nicht.
- Der Linux-Prozess-Gate ist auf CT 215 mit 20/20 Fällen bestanden. Ein
  Alpine/Add-on-Image-Lauf und der echte Lautsprecher bleiben getrennte Gates.

## Kontrollierter Hardwaretest nach separater Freigabe

Erwartete Reihenfolge: `[POWER] Wake requested`, `[BLE] Adapter ready`,
`[BLE] Device state`, `[BLE] Connecting GATT`, `[BLE] Characteristic ...`,
`[BLE] Wake write requested`, `[BLE] Write result`, `[BLE] Cleanup`,
`[POWER] Waiting for startup`, `[CLASSIC] Connecting A2DP`, `[AUDIO] Sink
ready`, `[HA] Renderer ready`.

Der Test ist nur dann funktional erfolgreich, wenn die Box physisch reagiert
und anschließend A2DP-Sink und Renderer bereit werden. Logs allein ersetzen
diese Hardwarebeobachtung nicht.
