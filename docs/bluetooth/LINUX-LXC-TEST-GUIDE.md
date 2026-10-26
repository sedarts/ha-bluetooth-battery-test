# Linux-Prozesstests im isolierten Debian-LXC

Stand: 2026-10-26. Ausschließlich `sedarts/ha-bluetooth-battery-test`, lokaler
Arbeitsstand für 2.6.2-test.13 einschließlich der lokalen Korrekturen.
Ergänzung zu [RESOURCE-BUSY-ANALYSIS.md](RESOURCE-BUSY-ANALYSIS.md).
Diese Anleitung verändert weder Bridge-Code noch Versionsnummer. Kein Deployment,
kein Bluetooth-Hardwaretest. Der separate test.13-Lauf auf Debian CT 215 mit
Python 3.13.5 bestand anschließend alle 20 Tests ohne Fehler oder Skips in
74,702 Sekunden (`OK`); das frühere test.12-Ergebnis wurde nicht wiederverwendet.

## 1. Voraussetzungen und geprüfte Isolation

Geprüft wurden `tests/linux-process-lifecycle.py`, `lib/bluetooth-process.py`,
`lib/bluetooth-ops.sh`, `lib/power-manager.sh` und `lib/gatt-discovery.sh`.

| Voraussetzung | Zweck / Berechtigung |
| --- | --- |
| Unprivilegierter, frischer Debian-12- oder Debian-13-LXC | Eigener PID-/Mount-Namensraum; keine produktiven Prozesse im Container |
| Python 3.11 (Debian 12) oder 3.13 (Debian 13) | Nur Standardbibliothek; kein pip, venv oder Compiler |
| `bash`, `util-linux`, `coreutils`, `grep` | Echte Bash, `flock`, `timeout`, `mktemp`, `sleep`, Dateiverwaltung und Textprüfung |
| `tar`, `gzip`, `procps` | Übertragung, Entpacken, Prozessbestandsaufnahme |
| Normaler Benutzer `boomtest` | Darf eigene Prozesse starten, signalisieren und abwarten; eigene temporäre Dateien anlegen |
| Linux `/proc` | Lesbare eigene `stat`-/`fd`-Einträge; `/proc/self/task/<pid>/children` ist optional und wird nur als Hinweis verwendet |
| Kernel-Funktionen | `fork`, `setsid`, `waitid` mit `WNOWAIT`, `waitpid`, `flock`, `prctl(PR_SET_CHILD_SUBREAPER)` |
| Ausführbares temporäres Dateisystem | Test-Fixtures werden mit Modus 0700 gestartet; kein `noexec` auf dem Test-TMPDIR |

`Path.unlink(missing_ok=True)` setzt mindestens Python 3.8 voraus. Das ist keine
Zusicherung für jede Version ab 3.8: insbesondere nutzt das Test-Teardown interne
unittest-Ergebnisdaten. Die vorgesehenen Debian-Versionen müssen tatsächlich
getestet werden. Paketversionen im Ergebnisprotokoll festhalten, nicht ungeprüft
als kompatibel ausgeben. Quellen: [Debian 12 Python](https://packages.debian.org/bookworm/python3),
[Debian 13 Python](https://packages.debian.org/trixie/python3),
[util-linux](https://packages.debian.org/trixie/util-linux).

Die Suite prüft selbst nur Linux-/proc sowie `bash` und `flock`; bei deren Fehlen
überspringt sie Tests. Deshalb reichen Exitcode 0 und das Wort `OK` allein nicht.

**Kein echter Adapter, BlueZ-Dienst, Home Assistant, MQTT-Broker oder Audio-Server
erforderlich.** `gatttool`, `bluetoothctl`, `pactl`, `mosquitto_pub` und
`mosquitto_sub` werden durch ausführbare Python-Fixtures ersetzt und im PATH
vorgezogen. Die MAC-Adressen sind ausschließlich Fixture-Eingaben. Echte Bash,
Locks, Signale und der lokale Prozesswächter bleiben aktiv. `run.sh`, WebUI,
Renderer und Add-on-Dienste werden nicht gestartet.

Lock-, Pause-, Wake- und Fixture-Dateien liegen in einem eigenen temporären
Verzeichnis. Die bereinigte Startumgebung unten verhindert geerbte PM-/BT-Variablen,
MQTT-Zugangsdaten, `BASH_ENV` und abweichende Python-Suchpfade.

**Grenze:** Tests erzeugen absichtlich TERM/INT ignorierende Prozesse und einen
Enkel mit eigener Session. Bei einem Fehler des getesteten Wächters kann dieser
Enkel dem sessionbasierten Test-Teardown entgehen. SIGKILL kann Marker hinterlassen.
Deshalb ausschließlich Wegwerf-LXC und eigener Benutzer, niemals Proxmox-Host oder
produktiver Container. Die abschließende Container-Beendigung ist die äußere
Sicherheitsgrenze; kein `pkill`, `killall` oder Bluetooth-Disconnect auf dem Host.

## 2. Vollständigen lokalen Stand paketieren (Windows PowerShell)

Während der Paketierung keine Dateien bearbeiten. Kein Clone und kein
`git archive HEAD`: Beide würden lokale Änderungen/neue Dateien verlieren.
Das Archiv enthält den gesamten aktuellen Arbeitsbaum einschließlich ignorierter
Dateien, aber keine `.git`-Daten. Vorher Dateiliste auf Schlüssel, Zugangsdaten und
private Dateien prüfen; bei solchen Funden Übertragung stoppen und Umfang klären.
Nicht stillschweigend benötigte Dateien ausschließen.

```powershell
$repo = 'C:\Users\bodyl\.codex\.chatgpt-projects\g-p-6a1f3eca8e048191a4ca1e31627805ca\battery-test-repo-inspect-sedarts'
git -C $repo remote get-url origin
git -C $repo status --short
git -C $repo ls-files --others --exclude-standard
git -C $repo ls-files --others --ignored --exclude-standard
# Nur fortfahren, wenn origin sedarts/ha-bluetooth-battery-test ist.
Get-Command tar.exe, scp.exe
$bundle = Join-Path (Split-Path $repo -Parent) ('ue-boom-linux-package-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $bundle -ErrorAction Stop | Out-Null
git -C $repo rev-parse HEAD | Set-Content -Encoding ascii (Join-Path $bundle 'HEAD.txt')
git -C $repo status --short | Set-Content -Encoding utf8 (Join-Path $bundle 'status.txt')
tar.exe -czf (Join-Path $bundle 'working-tree.tar.gz') --exclude=.git -C $repo .
if ($LASTEXITCODE -ne 0) { throw 'Archivierung fehlgeschlagen' }
tar.exe -tzf (Join-Path $bundle 'working-tree.tar.gz')
$hash = (Get-FileHash (Join-Path $bundle 'working-tree.tar.gz') -Algorithm SHA256).Hash.ToLowerInvariant()
"$hash  working-tree.tar.gz" | Set-Content -Encoding ascii (Join-Path $bundle 'SHA256SUMS')
$bundle
```

Die Archivliste muss insbesondere `lib/bluetooth-process.py`,
`tests/linux-process-lifecycle.py`, alle geänderten Shell-Dateien und die neuen
Dokumente enthalten. Der Archiv-Hash identifiziert den getesteten lokalen Stand,
nicht allein die Commit-ID. `.git` wird für die Tests nicht benötigt.

Auf dem separaten Proxmox-Host in einer administrativen Bash ein neues Verzeichnis
anlegen und dessen ausgegebenen absoluten Pfad notieren:

```bash
PACKAGE_DIR=$(mktemp -d /var/tmp/ue-boom-package.XXXXXX)
chmod 700 "$PACKAGE_DIR"
printf '%s\n' "$PACKAGE_DIR"
```

In Windows bekannte SSH-Hostidentität prüfen; keine Hostkey-Prüfung deaktivieren.
Den tatsächlichen Benutzer, Host und soeben ausgegebenen Pfad einsetzen:

```powershell
$destination = Read-Host 'SSH-Ziel BENUTZER@PROXMOX:/var/tmp/ue-boom-package.XXXXXX/'
scp.exe (Join-Path $bundle 'working-tree.tar.gz') (Join-Path $bundle 'SHA256SUMS') (Join-Path $bundle 'HEAD.txt') (Join-Path $bundle 'status.txt') $destination
if ($LASTEXITCODE -ne 0) { throw 'Übertragung fehlgeschlagen' }
```

## 3. Wegwerf-Container vorbereiten (Proxmox-Host)

In der Proxmox-Oberfläche einen **neuen** Debian-12/13-Standard-LXC erstellen:
unprivilegiert, 2 vCPU, 1 GiB RAM, mindestens 4 GiB Disk, kein Autostart.
Für die Paketinstallation ausschließlich temporären Test-Netzzugang verwenden.
Keine USB-/Bluetooth-Geräte, Host-Verzeichnisse, Host-/proc, D-Bus-Sockets oder
produktiven Datenträger durchreichen. Kein privileged, nesting oder zusätzliche
Capabilities erforderlich. Keine AppArmor-/Seccomp-Regeln aufweichen, falls ein
Kernel-Aufruf abgelehnt wird: als Umgebungsfehler dokumentieren.
Siehe [offizielle Proxmox-LXC-Dokumentation](https://github.com/proxmox/pve-docs/blob/master/pct.adoc).

Die folgenden Befehle betreffen nur die **vorher manuell geprüfte neue CT-ID**.
`PACKAGE_DIR` stammt aus Abschnitt 2; in neuer SSH-Sitzung erneut auf genau diesen
Pfad setzen. Niemals die ID von Home Assistant oder eines vorhandenen Dienstes verwenden.

```bash
read -r -p 'CT-ID des NEUEN Wegwerf-LXC: ' CTID
[[ "$CTID" =~ ^[0-9]+$ ]] || exit 1
pct config "$CTID"
# Manuell prüfen: unprivileged: 1; keine Geräte/mpX/lxc.mount-Durchreichungen.
# Container über die Oberfläche starten, falls noch gestoppt.
pct exec "$CTID" -- bash -euxc '
  apt-get update
  apt-get install -y --no-install-recommends python3 bash util-linux coreutils grep tar gzip procps
  useradd --create-home --shell /bin/bash boomtest
  install -d -o boomtest -g boomtest -m 700 /home/boomtest/input /home/boomtest/tmp /home/boomtest/results /home/boomtest/ha-bluetooth-battery-test
'
# Jetzt einzigen temporären Netzwerkadapter entfernen; keine weiteren NICs zulassen.
pct set "$CTID" --delete net0
pct config "$CTID"
(cd "$PACKAGE_DIR" && sha256sum -c SHA256SUMS) || exit 1
for name in working-tree.tar.gz SHA256SUMS HEAD.txt status.txt; do
  pct push "$CTID" "$PACKAGE_DIR/$name" "/home/boomtest/input/$name" --perms 0644 || exit 1
done
```

Die CT-ID vor `pct set` nochmals kontrollieren. Das Entfernen des Test-Netzwerks
beeinflusst nicht `pct exec/push/pull`. Tests benötigen keine Netzwerkverbindung.

## 4. Archiv prüfen, entpacken, Vorbedingungen prüfen

Auf dem Proxmox-Host ausführen; der gesamte Block läuft **als normaler Benutzer
im Container**. Nicht mehrfach in denselben Arbeitsbaum entpacken.

```bash
pct exec "$CTID" -- runuser -u boomtest -- env -i HOME=/home/boomtest PATH=/usr/bin:/bin LANG=C.UTF-8 TMPDIR=/home/boomtest/tmp PYTHONDONTWRITEBYTECODE=1 /bin/bash --noprofile --norc -se <<'PREP'
cd /home/boomtest/input
sha256sum -c SHA256SUMS
python3 - <<'PY'
import pathlib, tarfile
with tarfile.open('working-tree.tar.gz', 'r:gz') as archive:
    for member in archive.getmembers():
        path = pathlib.PurePosixPath(member.name)
        if (path.is_absolute() or '..' in path.parts or '.git' in path.parts
                or '\\' in member.name or not (member.isfile() or member.isdir())):
            raise SystemExit('Unsicherer Archiveintrag: ' + member.name)
PY
cd /home/boomtest/ha-bluetooth-battery-test
test -z "$(ls -A)"
tar --no-same-owner --no-same-permissions -xzf /home/boomtest/input/working-tree.tar.gz
test "$(id -u)" -ne 0
for tool in python3 bash flock timeout grep mktemp; do command -v "$tool"; done
for tool in bluetoothctl gatttool pactl mosquitto_pub mosquitto_sub; do
  if command -v "$tool"; then echo "ABBRUCH: echtes $tool vorhanden"; exit 1; fi
done
python3 - <<'PY'
import ctypes, os, pathlib, sys
assert sys.platform.startswith('linux')
assert sys.version_info[:2] in ((3, 11), (3, 13)), sys.version
assert pathlib.Path('/proc/self/fd').is_dir()
children = pathlib.Path(f'/proc/self/task/{os.getpid()}/children')
print('task_children=' + ('present' if children.exists()
      else 'absent; bounded PPid fallback expected'))
assert hasattr(os, 'WNOWAIT') and hasattr(os, 'waitid')
libc = ctypes.CDLL(None, use_errno=True)
if libc.prctl(36, 1, 0, 0, 0) != 0:
    raise OSError(ctypes.get_errno(), 'PR_SET_CHILD_SUBREAPER nicht erlaubt')
for root in ('lib', 'tests'):
    for file in pathlib.Path(root).rglob('*'):
        if file.suffix in ('.sh', '.py') and b'\r\n' in file.read_bytes():
            raise SystemExit('CRLF: bytegleichen Teststand erst klaeren: ' + str(file))
PY
probe=$(mktemp)
printf '#!/bin/sh\nexit 0\n' > "$probe"
chmod 700 "$probe"
"$probe"
rm -- "$probe"
{
  cat /etc/os-release
  uname -a
  id
  python3 --version
  bash --version
  dpkg-query -W python3 bash util-linux coreutils grep tar gzip procps
  cat /home/boomtest/input/HEAD.txt /home/boomtest/input/status.txt /home/boomtest/input/SHA256SUMS
} > /home/boomtest/results/environment.txt
PREP
```

Bei einem Fehler nicht weiterlaufen und keine Quelldateien automatisch normalisieren.
Insbesondere kein `dos2unix` am lokalen Original. Fehlende Archiveinträge,
CRLF-Probleme oder restriktive Kernel-Regeln vor einem neuen Testlauf klären.

## 5. Exakter Start mit Ergebnisaufzeichnung

Auf dem Proxmox-Host, nach erfolgreichem Abschnitt 4, **einmal** ausführen:

```bash
pct exec "$CTID" -- runuser -u boomtest -- env -i HOME=/home/boomtest PATH=/usr/bin:/bin LANG=C.UTF-8 TMPDIR=/home/boomtest/tmp PYTHONDONTWRITEBYTECODE=1 /bin/bash --noprofile --norc -s <<'TEST'
set -u -o pipefail
cd /home/boomtest/ha-bluetooth-battery-test || exit 1
log=/home/boomtest/results/linux-process-lifecycle.log
test ! -e "$log" || { echo 'Ergebnis existiert bereits; neuen Testcontainer verwenden'; exit 1; }
timeout --signal=TERM --kill-after=10s 300s python3 tests/linux-process-lifecycle.py -v 2>&1 | tee "$log"
codes=("${PIPESTATUS[@]}")
printf 'test_exit=%s tee_exit=%s\n' "${codes[0]}" "${codes[1]}" | tee /home/boomtest/results/exit-status.txt
ps -u "$(id -u)" -o pid,ppid,sid,stat,args > /home/boomtest/results/processes-after.txt
test "${codes[0]}" -eq 0 && test "${codes[1]}" -eq 0 || exit 1
python3 - "$log" <<'PY'
import pathlib, re, sys
text = pathlib.Path(sys.argv[1]).read_text()
cases = re.findall(
    r'^test_\w+ \(__main__\.(?:Lifecycle|ProcEnumeration)\.test_\w+\) \.\.\. ok$',
    text, re.M)
if (len(cases) != 20 or not re.search(r'^Ran 20 tests in ', text, re.M)
        or not re.search(r'^OK$', text, re.M)
        or re.search(r'skipped|FAILED|ERROR|FAIL:', text)):
    raise SystemExit('NICHT BESTANDEN: exakt 20 erfolgreiche Tests ohne Skip erforderlich')
print('PASS: 20/20 Linux-Prozesstests, 0 skipped')
PY
TEST
```

Das Gesamtlimit ist nur eine äußere Absicherung, keine Änderung der Bridge-Retry-
oder Timeout-Limits. Ein äußerer Timeout (typisch 124 oder 137), Testfehler,
fehlende Ausgabe oder ein Skip bedeutet **nicht bestanden / nicht vollständig
ausgeführt**. Kein `expectedFailure` und kein Überspringen zur Freigabe verwenden.

## 6. Erwartete Ausgabe und Erfolgskriterien

Jede der folgenden Methoden muss mit `... ok` erscheinen:

| Test | Nachweis |
| --- | --- |
| `test_adopted_descendant_reaped` | Eigene Enkel mit neuer Session werden beendet; Manager bleibt aktiv |
| `test_adopted_descendant_reaped_with_proc_scan_fallback` | Derselbe Cleanup funktioniert ohne task-children-Datei über den PPid-Fallback |
| `test_background_manager_receives_int` | SIGINT erreicht asynchron gestarteten Manager |
| `test_busy_cleanup_and_new_wake` | Busy führt zu ERROR/Lock-Freigabe, ohne Disconnect; neuer expliziter Wake möglich |
| `test_explicit_unlock_releases_inherited_description` | Kontrollfall: explizites Unlock trotz geerbtem Descriptor |
| `test_gatt_int`, `test_gatt_term`, `test_gatt_kill` | Manager-Abbruch während GATT; Worker endet und Lock wird frei |
| `test_gatt_timeout_cleanup_and_error` | GATT-Zeitlimit, ERROR-Marker und weiterhin lebender Manager |
| `test_info_deadline` | Hängendes simuliertes `bluetoothctl info`: Status 124, Worker beendet |
| `test_info_int`, `test_info_term`, `test_info_kill` | Manager-Abbruch während Info; Worker endet und Lock wird frei |
| `test_orphan_must_not_pin_shared_lock` | Keine Lock-FD im Worker; Elternabbruch hinterlässt keinen Lock/Worker |
| `test_repeated_signals` | Wiederholtes TERM/INT mit Cleanup und Lock-Freigabe |
| `test_short_lived_processes_keep_success_status` | Kurzlebige erfolgreiche Prozesse behalten beim erzwungenen Fallback Status 0 |
| `test_connected_without_a2dp_allows_wake_without_disconnect` | `Connected: yes` ohne A2DP lässt den BlueZ-GATT-Wake zu, ohne geräteweiten Disconnect |
| `test_missing_task_children_falls_back_to_ppid_scan` | Fehlende task-children-Datei wird durch den PPid-Scan ersetzt |
| `test_task_children_omission_and_disappearing_entries_are_tolerated` | Ausgelassene und zwischenzeitlich verschwundene Proc-Einträge verursachen keinen falschen Fehler |
| `test_changed_starttime_or_parent_rejects_stale_pid` | Geänderte Prozessidentität beziehungsweise Elternschaft verhindert ein Signal an eine stale PID |

Die gruppierten Zeilen umfassen zusammen genau **20 Einzeltests**. Erwartetes Ende
(Laufzeit variabel, nicht vorab als gemessen ausgeben):

```text
Ran 20 tests in <Dauer>s

OK
test_exit=0 tee_exit=0
PASS: 20/20 Linux-Prozesstests, 0 skipped
```

Zusätzlich `processes-after.txt` prüfen: außer dem Auswertungs-Shellprozess und
`ps` dürfen keine Test-Worker, `sleep 120`, Manager oder Prozesswächter verbleiben
(auch keine zugehörigen Zombies). Die Suite behandelt Zombies bei `live()` als
nicht laufend; der zusätzliche Prozess-Snapshot ist daher wichtig. Temporäre
Marker nach absichtlichem SIGKILL sind möglich und kein alleiniger Lock-Nachweis.
Lock-Freigabe wird durch echte erneute `flock`-Versuche getestet.

Bei Assertion-Fehlern gibt die Suite ihre `process-*.log` aus; viele temporäre
Dateien werden danach entfernt. Das aufgezeichnete stdout/stderr ist deshalb
aufzubewahren. Bei äußerem Abbruch sind diese Fehlerausgaben nicht garantiert.
Keine vollständige Hardware-/D-Bus-/MQTT-Integration aus diesem Ergebnis ableiten.

## 7. Belege sichern, Container stoppen

Auf dem Proxmox-Host, auch nach fehlgeschlagenem Lauf:

```bash
RESULT_DIR=$(mktemp -d /var/tmp/ue-boom-results.XXXXXX)
chmod 700 "$RESULT_DIR"
pct config "$CTID" > "$RESULT_DIR/container-config.txt"
for name in environment.txt linux-process-lifecycle.log exit-status.txt processes-after.txt; do
  pct pull "$CTID" "/home/boomtest/results/$name" "$RESULT_DIR/$name" || echo "Fehlender Beleg: $name"
done
printf 'Ergebnisse: %s\n' "$RESULT_DIR"
# CT-ID erneut mit container-config.txt abgleichen: nur den Wegwerf-LXC stoppen.
pct stop "$CTID"
```

Ergebnisse und Archiv-Hash sichern, bevor der Container später manuell gelöscht
wird. Keine automatische Löschung. Bei einem abgebrochenen Test vor Wiederholung
frischen Container verwenden; keine verwaisten Prozesse auf dem Host suchen/töten.

Ein Debian-PASS prüft Linux-Prozess-/Lock-Verhalten unter dem Proxmox-Kernel und
glibc. Alpine/musl, s6-/Supervisor-Abbruch, WebUI/FIFO, tatsächliche BlueZ-Operationen,
BLE-Wake und Power-Off bleiben getrennt offen. Dieses Paket erteilt weder eine
Release- noch eine Hardwarefreigabe. Hier wurden nur Code und Anleitung geprüft;
der Linux-Lauf und diese Proxmox-Befehle wurden nicht ausgeführt.
