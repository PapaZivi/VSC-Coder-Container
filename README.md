# Fresh Codex + Claude Dev-Container Setup 2.0

Komplett neuer Aufbau einer isolierten VS-Code-/KI-Dev-Container-Umgebung. Es wird keine
Konfiguration eines anderen Rechners benötigt.

## Neu in 2.0: Codex und Claude Code

Das Setup erkennt vor den Assistenten-Rückfragen, ob **OpenAI/Codex** und/oder **Claude Code** bereits verwendet werden. Als Signale dienen die vorhandene `devcontainer.json`, installierte VS-Code-Erweiterungen, ein vorhandener Dev Container, lokale Benutzerzustände (`.codex`, `.claude`/`.claude.json`) sowie die konfigurierte bzw. bereits laufende Arbeits-WSL.

Die Auswahl folgt dieser Logik:

- nur Codex erkannt → fragt, ob Claude Code zusätzlich eingerichtet werden soll;
- nur Claude Code erkannt → fragt, ob Codex zusätzlich eingerichtet werden soll;
- beide erkannt → beide werden beibehalten;
- nichts erkannt → Auswahl zwischen Codex, Claude Code oder beiden.

Für Codex wird `openai.chatgpt`, für Claude Code `anthropic.claude-code` in der Dev-Container-Konfiguration eingetragen. Beide Erweiterungen liegen im gemeinsamen persistenten VS-Code-Extensions-Volume. Claude Code erhält zusätzlich das Volume `<prefix>-claude-home` unter `/home/vscode/.claude`; `CLAUDE_CONFIG_DIR=/home/vscode/.claude` sorgt dafür, dass Konfiguration, Sitzungen und Zugangsdaten einen Rebuild überleben. Eine bestehende lokale Claude-Historie wird in 2.0 bewusst **nicht automatisch kopiert**.

Claude Code wird über die offizielle VS-Code-Erweiterung eingerichtet. Deren Chat-Oberfläche bringt ihre eigene interne CLI mit; ein zusätzliches systemweites `claude` im Terminal-PATH wird von diesem Setup nicht installiert. Eine bereits vorhandene Standalone-CLI wird jedoch bei der Erkennung berücksichtigt.

Die Mount-Sicherheitsprüfung blockiert zusätzlich `.claude` und `.claude.json` als Projekt-Mounts. Enthalten ist **Codex Mount Manager 1.0.0**.

## Übernommene Stabilitäts-/ATC-Mitigationen aus v1.0.1

Die in v1.0.1 erprobten Stabilitäts- und Antivirus-Mitigationen sind auch in diesem v2-Alpha-Stand enthalten. Die grundlegende v2-Funktion – Erkennung und Auswahl von Codex, Claude Code oder beiden – bleibt unverändert.

- `Setup-NewCodexComputer.cmd` verwendet `Run-Setup.ps1`, sodass Syntax-/Integritätsprüfung und Setup nicht mehr in zwei getrennten PowerShell-Prozessen laufen.
- Docker Desktop wird nicht mehr automatisch als PowerShell-Kindprozess gestartet. Falls die Engine nicht läuft, fordert das Setup zu einem manuellen Start auf und wartet anschließend weiter.
- Installierte VS-Code-Erweiterungen werden direkt aus den lokalen Extension-Verzeichnissen gelesen; ein zusätzlicher `code --list-extensions --show-versions`-Prozess entfällt.
- Fehlende Erweiterungen – Dev Containers, je nach Auswahl Codex und/oder Claude Code sowie der Codex Mount Manager – werden in einem einzigen gebündelten VS-Code-CLI-Aufruf installiert.
- VS Code wird beim Bootstrap automatisch mit dem tatsächlich erkannten Workspace geöffnet. Nach `Dev Containers: Reopen in Container` wird derselbe offene Workspace weiterverwendet, statt am Ende unnötig ein zweites VS-Code-Fenster zu starten.
- Temporäre Setup-Dateien liegen paketlokal unter `logs\temp` und werden defensiv über .NET-Dateioperationen entfernt. Dadurch werden problematische `%TEMP%`-/8.3-Kurzpfade vermieden.
- Zusätzliche ATC-Diagnosepunkte markieren Docker-Start, Extension-Installation, VS-Code-Workspace-Start und Dev-Container-Bootstrap.
- Der isolierte, inkrementelle Codex-Chatimport bleibt unverändert. Für Claude Code wird weiterhin keine lokale Historie automatisch importiert.



## Empfohlener Start mit komplettem Logfile

In PowerShell oder CMD:

```text
.\Setup-NewCodexComputer.cmd --logfile
```

Das Log landet in:

```text
logs\Setup-NewCodexComputer-RECHNERNAME.log
```

Der Dateiname bleibt für diesen Rechner gleich. Wenn das Setup wegen eines
Windows-Neustarts mehrfach ausgeführt wird, wird bei jedem erneuten Start mit
`--logfile` an dieselbe Datei angehängt.

Damit kann anschließend genau diese eine Datei zur Fehlersuche weitergegeben
werden.

Direkter Start der PS1 ist ebenfalls möglich:

```powershell
.\Setup-NewCodexComputer.ps1 -LogFile
```

Für die ATC-Mitigation ist der Start über `Setup-NewCodexComputer.cmd` empfohlen. Der CMD-Launcher verwendet `Run-Setup.ps1`, sodass Syntax-/Integritätsprüfung und das eigentliche Setup nicht mehr in zwei getrennten PowerShell-Prozessen laufen.

Hinweis: In Windows PowerShell hat `--` eine besondere Bedeutung. Deshalb wird
für die gewünschte Schreibweise `--logfile` der mitgelieferte CMD-Launcher
verwendet.

## Grundaufbau

Installiert bzw. prüft:

- Git
- Visual Studio Code
- Docker Desktop
- WSL2
- Ubuntu 24.04
- Dev Containers
- je nach Erkennung/Auswahl OpenAI/Codex, Claude Code oder beide
- Codex Mount Manager 1.0.0

Fehlende normale Anwendungen werden soweit möglich mit `winget` installiert.

## Container

Der Container benutzt genau einen VS-Code-Root:

```text
/workspaces
```

Persistente Docker-Volumes:

```text
codex-sandbox-workspaces
codex-sandbox-home                 # nur bei Codex
codex-sandbox-claude-home          # nur bei Claude Code
codex-sandbox-vscode-extensions
```

`/home/vscode/.codex` und `/home/vscode/.claude` werden – sofern der jeweilige
Assistent ausgewählt ist – dem Benutzer `vscode` zugeordnet. Für Claude Code setzt
die Konfiguration zusätzlich `CLAUDE_CONFIG_DIR=/home/vscode/.claude`.

Zusätzlich liegt `/home/vscode/.vscode-server/extensions` auf dem persistenten
Volume `codex-sandbox-vscode-extensions`. Dadurch bleiben auch Erweiterungen,
die innerhalb des Dev Containers manuell installiert wurden, bei einem
Container-Rebuild erhalten. Persistiert wird bewusst nur das Extension-Verzeichnis,
nicht der komplette VS-Code-Server.

Damit VS Code schon **vor** `postCreateCommand` seine Verzeichnisse `data` und `bin` anlegen kann, wird `/home/vscode/.vscode-server` bereits beim Image-Build als `vscode:vscode` vorbereitet.

Das Dev-Container-Basisimage wird auf `mcr.microsoft.com/devcontainers/base:ubuntu-24.04`
gepinnt. Dadurch wechselt der Container bei einem späteren Rebuild nicht unbemerkt
auf eine neue Ubuntu-Hauptversion.

Noch keine persönlichen Projektpfade werden in die Grundkonfiguration
eingetragen.

## Einheitlicher Dev-Containers-Hostmodus

Auf Windows wird Dev Containers verbindlich **in der ausgewählten WSL-Distro** ausgeführt.
Das Setup setzt dafür auf VS-Code-Benutzerebene:

```json
"dev.containers.executeInWSL": true,
"dev.containers.executeInWSLDistro": "<ausgewählte Distro>",
"dev.containers.mountWaylandSocket": false
```

Die ausgewählte WSL wird zugleich als WSL-Standarddistribution gesetzt und ihre
Docker-Desktop-Integration wird geprüft. Damit läuft die Dev-Containers-CLI auf
allen Fresh-Setup-Rechnern aus derselben Umgebung.

Bind-Mounts haben dadurch ebenfalls immer dieselbe Form:

```text
C:\Users\Name\Projekt  -> /mnt/c/Users/Name/Projekt
O:\                      -> /mnt/o
V:\html                  -> /mnt/v/html
```

Lokale Windows-Laufwerke sind in WSL unter `/mnt/<laufwerk>` verfügbar. Gemappte
Windows-Netzlaufwerke richtet das Setup zusätzlich per `drvfs` in derselben WSL
ein. Das ist wichtig, weil Docker Desktop gemappte Windows-Netzlaufwerke nicht
zuverlässig direkt über Laufwerksbuchstaben wie `O:\` in Linux-Container bindet.

Ältere `C:\...`, `O:\` oder `V:\...`-Mounts migriert der mitgelieferte Codex
Mount Manager automatisch zurück auf die einheitlichen WSL-Pfade.

## Entwicklungsumgebungen

Auf einem neuen Rechner wird abgefragt, welche Entwicklungsumgebungen dauerhaft
in den Dev Container eingebaut werden sollen. Bei einem Wiederholungslauf liest
das Setup die vorhandenen Build-Argumente aus `.devcontainer/devcontainer.json`
und übernimmt eine eindeutige bestehende Auswahl ohne erneute Rückfrage. Die
Auswahl wird in `.devcontainer/Dockerfile.codex` und den Build-Argumenten der
`devcontainer.json` gespeichert und überlebt dadurch jeden Container-Rebuild.

Als Basiswerkzeug wird immer installiert:

- `sqlite3`

Optional auswählbar sind:

- **PHP**: ausschließlich CLI, zusätzlich Composer sowie `curl`, `mbstring`,
  XML, ZIP, intl, GD, SQLite, MySQL, PostgreSQL, bcmath und SOAP. OPcache wird
  je nach PHP-/Ubuntu-Version über CLI/Common mitgebracht oder versionsspezifisch
  nachinstalliert. Apache und PHP-FPM werden nicht installiert.
- **C/C++**: `gcc`, `g++`, `make`, CMake, GDB, Ninja und `pkg-config`.
- **Python**: Python 3, `pip`, `venv`, `pytest`, Development-Header,
  setuptools, wheel und `pipx`.
- **Node.js**: wahlweise **20** oder **22**, jeweils inklusive npm. Es kann
  immer nur eine Node.js-Version ausgewählt werden.
- **.NET SDK**: wahlweise **10** oder **11**. Es kann immer nur eine
  .NET-Version ausgewählt werden. .NET 11 wird erst angeboten, sobald Microsoft
  ein stabiles GA-Release für den 11.0-Kanal veröffentlicht hat. Preview- und
  RC-Versionen werden nicht installiert.

Dieselbe Auswahl kann später direkt in **Codex Mounts → Entwicklungsumgebungen**
per Checkbox geändert werden. Nach mehreren Änderungen genügt ein gemeinsamer
Klick auf **Container neu erstellen**.

## Vorhandene Chats auf dem jeweiligen Rechner

Noch vor regulären Rückfragen führt das Setup eine Bestandsaufnahme durch. Dabei
werden unter anderem ein vorhandener Dev Container, das persistente
`codex-sandbox-home`-Volume und die lokale Historie unter

```text
%USERPROFILE%\.codex
```

geprüft. Ab 1.0.51 erhält ein erfolgreicher Import im persistenten `.codex`-Volume
einen kleinen Fingerprint-Marker `.fresh-codex-import.json`. Der Fingerprint
besteht aus Metadaten der lokalen Codex-Datenbank, Session-Dateien, Attachments
und des Session-Indexes. Solange sich die Quelle nicht geändert hat, reicht
anschließend dieser Marker: **Es gibt weder eine erneute Importfrage noch einen
erneuten Datenimport.**

Bei älteren bereits erfolgreichen Imports ohne Marker versucht das Setup einmalig
eine isolierte Verifikation. Ist der vorhandene Zielbestand vollständig, wird nur
der Marker ergänzt und kein erneuter Vollimport durchgeführt.

Der eigentliche Import läuft nicht mehr in einer zweiten Windows-PowerShell und
verwendet keine großen `docker cp`-Transfers mehr. Stattdessen startet das Setup
einen kurzlebigen Helper-Container aus dem bereits vorhandenen Dev-Container-Image.
Dieser Helper erhält ausschließlich:

- `%USERPROFILE%\.codex` als **read-only** Quelle,
- das persistente `codex-sandbox-home`-Volume als Ziel,
- den statischen Import-Helper read-only,
- **kein Netzwerk** (`--network none`),
- **keinen Docker-Socket**,
- Ausführung als unprivilegierter Benutzer `vscode`, keine zusätzlichen Linux-Capabilities und `no-new-privileges`.

Session-/Attachment-Dateien werden inkrementell kopiert: bereits identische
Dateien werden nicht erneut bewegt. Die alte Datenbank wird nicht über die neue
kopiert. Stattdessen wird eine konsistente temporäre SQLite-Kopie erzeugt, das
Schema der aktuellen Codex-Datenbank beibehalten und nur kompatible Threads
werden zusammengeführt. Alte Windows-Rollout-Pfade und `//?//home/...` werden
dabei korrigiert.

Der mitgelieferte Python-Helper wird vor jedem Start per fest hinterlegter
SHA-256-Prüfsumme verifiziert. `auth.json` wird weiterhin nicht kopiert.

## Erster Dev-Container-Start

Wenn VS Code vom Setup geöffnet wird, läuft die Dev-Containers-CLI verbindlich in der ausgewählten WSL-Distro:

1. `Strg+Shift+P`
2. `Dev Containers: Reopen in Container`
3. vollständig aufbauen lassen
4. unten links muss `Dev Container: Codex Sandbox` stehen
5. `Ctrl+Shift+X` öffnen
6. prüfen:
   - Dev Containers: lokal installiert
   - Codex Mount Manager: lokal installiert
   - OpenAI / `openai.chatgpt`: unter **DEV CONTAINER: Codex Sandbox** installiert
7. optional im Container-Terminal:

   ```bash
   ls ~/.vscode-server/extensions | grep -i openai
   ```

   oder:

   ```bash
   code --list-extensions --show-versions | grep -i openai
   ```

8. Codex/Chat noch nicht öffnen
9. VS Code wieder schließen
10. im Setup ENTER drücken

Das Setup prüft anschließend selbst noch einmal, ob `openai.chatgpt` wirklich
in der Remote-/Container-Extension-Installation vorhanden ist.

Danach werden ggf. alte Chats importiert.

## Projekte freigeben

Nach dem Grundsetup über **Codex Mounts** nur die gewünschten Verzeichnisse
einbinden. Ein Target kann z. B. heißen:

```text
/workspaces/python/beispiel programm
```

Leerzeichen sind erlaubt.

## Isolation prüfen

```powershell
.\Verify-CodexSandbox.ps1
```

Die Prüfung ermittelt das Windows-Systemlaufwerk und das Laufwerk des aktuellen Benutzerprofils dynamisch. Deren WSL-Laufwerkswurzeln sowie Host-Durchgriffe wie `/host`, `/run/desktop/mnt/host`, `/mnt/wsl` und der Docker-Socket dürfen im Container nicht sichtbar sein. Andere Daten-/Netzlaufwerke wie Y:, O: oder V: werden nicht pauschal gesperrt.

Zusätzlich wird die `devcontainer.json` auf kritische Bind-Mount-Quellen geprüft. Systemverzeichnisse und sensible Benutzerbereiche werden unabhängig vom Laufwerksbuchstaben blockiert. Projektordner innerhalb des eigenen Profils, z. B. `Documents\dev`, bleiben erlaubt.

# Versionsenticklung



## Neu in 1.0.51

- Der Chatimport startet **keine zweite Windows-PowerShell** mehr. Damit entfällt die bisherige `powershell.exe -ExecutionPolicy Bypass -File Import-ExistingCodexChats.ps1`-Verhaltenskette, die reproduzierbar Bitdefender Advanced Threat Control ausgelöst hat.
- Große `docker cp`-Transfers für Datenbank, Sessions, Attachments und ein zur Laufzeit erzeugtes `merge.py` entfallen. Der Import läuft stattdessen in einem kurzlebigen, isolierten Helper-Container.
- Der Helper sieht ausschließlich die lokale `.codex`-Quelle read-only und das persistente `.codex`-Zielvolume, läuft als `vscode`, hat `--network none`, keinen Docker-Socket, `--cap-drop ALL`, `no-new-privileges` und ein read-only Root-Dateisystem mit separatem `/tmp`.
- Der Python-Helper liegt statisch unter `tools/Import-CodexChatsHelper.py` und wird vor Verwendung gegen eine im Setup fest hinterlegte SHA-256-Prüfsumme geprüft.
- Session-/Attachment-Dateien werden inkrementell kopiert. Unveränderte Dateien werden nicht erneut übertragen.
- Ein erfolgreicher Import schreibt `.fresh-codex-import.json` in das persistente Codex-Home. Passt dessen Fingerprint zur lokalen Historie, entfallen bei späteren Setup-Läufen sowohl die Importfrage als auch der Import selbst.
- Bereits vor 1.0.51 erfolgreich importierte Daten können einmalig vom isolierten Helper verifiziert und anschließend nur mit diesem Marker versehen werden, ohne den kompletten Datenbestand erneut zu kopieren.

## Neu in 1.0.50

- Behebt den Abbruch direkt nach einem erfolgreichen `docker rm -f`: Das erwartete `No such container` aus der bisherigen `docker inspect`-Nachprüfung wird nicht mehr als Setup-Fehler behandelt.
- Die Entfernung wird jetzt über `docker ps -a -q --filter id=...` verifiziert; kein Treffer bedeutet ausdrücklich Erfolg.
- Verwaltete `Dockerfile.codex` wird unter Windows PowerShell 5.1 explizit als UTF-8 gelesen. Dadurch führen Umlaute im Kommentar nicht mehr zu einem falschen Inhaltsvergleich und unnötigen Rebuilds bei jedem Setup-Lauf.

## Neu in 1.0.49

- Wenn `devcontainer.json` oder die vom Setup verwaltete `Dockerfile.codex` geändert wurde, wird ein vorhandener Dev Container nicht mehr still weiterverwendet.
- Nach einer notwendigen Extension-Migration wird nur der veraltete Container entfernt; die benannten Volumes für Workspaces, `.codex` und VS-Code-Erweiterungen bleiben erhalten.
- Anschließend führt der normale Bootstrap-Pfad zwingend über einen neu erzeugten Container, sodass Dockerfile-Änderungen (insbesondere die Rechte für `/home/vscode/.vscode-server`) tatsächlich wirksam werden.
- Bei einem bereits parallel laufenden Dev-Containers-Abbau wartet das Setup auf das Ende der Entfernung, statt `docker rm -f` wiederholt aufzurufen.

## Neu in 1.0.48

- Behebt `Permission denied` unter `/home/vscode/.vscode-server/data` bzw. `/home/vscode/.vscode-server/bin` bei aktiviertem persistentem Extensions-Volume.
- Ursache: Ein älteres vom Mount Manager erzeugtes `Dockerfile.codex` legte `/home/vscode/.vscode-server` nicht vor dem Containerstart als `vscode:vscode` an. Der verschachtelte Volume-Mount konnte dadurch das Elternverzeichnis als `root:root` entstehen lassen, während VS Code seine Server-Verzeichnisse noch vor `postCreateCommand` anlegt.
- Das Setup aktualisiert eine vorhandene **verwaltete** `Dockerfile.codex` jetzt gezielt auf den aktuellen Stand und legt vorher `.bak` an. Fremde Dockerfiles werden weiterhin nicht überschrieben.
- Enthält Codex Mount Manager **0.3.8**. Dessen verwaltetes Dockerfile enthält dieselbe Verzeichnisvorbereitung, damit spätere Änderungen an PHP/C++/Python/Node/.NET den Fix nicht wieder entfernen.

## Neu in 1.0.47

- Wiederholte Setup-Läufe sind ATC-ärmer: bereits installierte `ms-vscode-remote.remote-containers`- und `openai.chatgpt`-Erweiterungen werden nicht mehr mit `--force` erneut installiert.
- Codex Mount Manager 0.3.7 wurde nur neu installiert, wenn die installierte Version nicht bereits 0.3.7 war.
- Die Chat-Migrationsprüfung protokolliert jetzt den konkreten Prüfgrund sowie ATC-Checkpoints vor und nach der Rückfrage.
- Der eigentliche Chatimport hat zusätzliche ATC-Checkpoints vor/nach Datenbankinitialisierung und Child-PowerShell.

## Neu in 1.0.46

Fix für Windows PowerShell 5.1: `Setup-NewCodexComputer.ps1` und alle weiteren mitgelieferten PowerShell-Dateien werden konsequent als UTF-8 mit BOM ausgeliefert. Version 1.0.45 enthielt das Hauptskript versehentlich als UTF-8 ohne BOM. Dadurch konnte Windows PowerShell 5.1 Umlaute wie das `Ä` in „Änderungen“ als PowerShell-Anführungszeichen fehlinterpretieren und der vorgeschaltete Syntaxcheck brach unter anderem bei Zeile 735 mit `Unerwartetes Token "nderungen"` ab.

`Validate-SetupSyntax.ps1` prüft jetzt zusätzlich vor dem Parserlauf, dass das Hauptskript tatsächlich mit UTF-8-BOM gespeichert ist, und meldet einen Encodingfehler künftig eindeutig statt eines irreführenden Syntaxfehlers.

## Neu in 1.0.45

Enthält **Codex Mount Manager 0.3.7**. Die Mount-Sicherheit verwendet keine feste Laufwerksbuchstabenliste mehr. Das Setup und der Mount Manager ermitteln dynamisch das Windows-Systemlaufwerk sowie das Laufwerk des aktuellen Benutzerprofils. Nur deren Laufwerkswurzeln werden pauschal als Voll-Mount blockiert; andere Laufwerke wie Y:, O: oder V: bleiben erlaubt.

Zusätzlich werden sensible Quellen bereits vor einem Rebuild abgewiesen: Windows, Program Files, ProgramData, Recovery, System Volume Information, das komplette Benutzerprofil, AppData sowie `.ssh`, `.gnupg`, `.aws`, `.azure`, `.kube`, `.docker`, `.codex`, `.vscode` und `.config`. Andere Windows-Benutzerprofile, Docker-Socket, Docker-Desktop-Hostdurchgriff und kritische Linux-/WSL-Hostpfade sind ebenfalls gesperrt.

Eine bereits manuell eingetragene unsichere Bind-Mount-Quelle wird bei der Bestandsaufnahme angezeigt und stoppt das Setup vor weiteren Einrichtungsfragen. Der Mount Manager verweigert solche Quellen beim Hinzufügen und blockiert außerdem einen Rebuild, solange sie in `devcontainer.json` vorhanden sind.

Die abschließende Sandbox-Prüfung kontrolliert nur noch die dynamisch ermittelten System-/User-Laufwerkswurzeln und die festen Host-Durchgriffe. Damit kann z. B. `/mnt/y` ausdrücklich als Projektquelle verwendet werden, solange Y: nicht selbst System- oder User-Laufwerk ist.

## Neu in 1.0.44

Regression in der Sandbox-Pruefung korrigiert: Die allgemeine Hostpfad-Pruefung
verwendet wieder die festgelegte Liste `/mnt/c`, `/mnt/d`, `/mnt/e`, `/mnt/y`,
`/host`, `/run/desktop/mnt/host` und `/var/run/docker.sock`. `/mnt/o` und
`/mnt/v` werden nicht mehr pauschal als unerwuenschte Hostpfade geprueft, da
solche Laufwerke explizit als Projektquellen eingebunden sein koennen.

## Neu in 1.0.43

Bitdefender Advanced Threat Control beendete den Setup-Prozess
reproduzierbar unmittelbar beim Beginn der TAR-basierten Extension-Migration aus
1.0.42. Die Migration verwendet deshalb wieder ein kurzlebiges lokales
`docker commit`-Image, schreibt aber kein TAR-Archiv mehr auf den Windows-Host.

Der eigentliche Kopiervorgang laeuft vollstaendig innerhalb eines temporaeren
Docker-Containers direkt in das persistente Extensions-Volume. Dabei wird
absichtlich `cp -R` statt `cp -a` verwendet; Ownership wird danach gezielt auf
`vscode:vscode` gesetzt. Damit werden die fuer VS-Code-Extensions relevanten
Dateien, Verzeichnisse, Symlinks und Ausfuehrungsbits uebernommen, ohne
problematische Zusatzattribute erzwingen zu wollen.

Zusaetzlich schreibt das ATC-Diagnoselog jetzt synchrone Checkpoints direkt vor
und nach `docker commit`, dem eigentlichen Migrations-`docker run` und dem
Aufraeumen des temporaeren Images. Falls eine Endpoint-Security den Prozess
erneut hart beendet, ist damit der konkrete Docker-Schritt eindeutig sichtbar.

## Neu in 1.0.42

Die Migration bereits installierter VS-Code-Container-Erweiterungen verwendet
nicht mehr `docker commit` plus `cp -a` aus einem temporaeren Image. Stattdessen
werden die Erweiterungen im laufenden alten Container als TAR-Archiv gepackt,
dieses Archiv als undurchsichtige Datei ueber `docker cp` transportiert und in
einem temporaeren Docker-Helfer direkt in das neue persistente Extensions-Volume
entpackt. Linux-Dateirechte und Symlinks bleiben dadurch im TAR erhalten, ohne
sie ueber das Windows-Dateisystem nachbilden zu muessen.

Alle Docker-Schritte dieser Migration erfassen jetzt stdout/stderr und geben bei
einem Fehler die konkrete Docker-Ausgabe im Setup-Log aus. Temporaere Archive
und Helfer-Container werden auch bei Fehlern aufgeraeumt.

Bestehende Konfigurationen mit dem frueheren unversionierten
`mcr.microsoft.com/devcontainers/base:ubuntu` werden gezielt auf
`mcr.microsoft.com/devcontainers/base:ubuntu-24.04` angeheftet. Andere explizit
konfigurierte Base-Images werden nicht veraendert.

## Neu in 1.0.41

Diese Version erweitert gezielt die Diagnose fuer den von Bitdefender Advanced
Threat Control beendeten PowerShell-Setup-Prozess. Direkt vor und nach jedem
VS-Code-CLI-Aufruf zur Extension-Installation wird jetzt ein eindeutiger
Checkpoint geschrieben.

Neben dem normalen Transcript entsteht dabei zusaetzlich:

```text
logs\Setup-ATC-Diagnose-RECHNERNAME.log
```

Die Checkpoints werden jeweils mit Millisekunden-Zeitstempel, Setup-PID und
konkreter Aktion unmittelbar in diese Datei geschrieben. Erfasst werden:

- Aufloesung des verwendeten `code.cmd`
- direkt vor/nach Installation von `ms-vscode-remote.remote-containers`
- direkt vor/nach Installation von `openai.chatgpt`
- Pfad und SHA256 des lokalen Codex-Mount-Manager-VSIX
- direkt vor/nach Installation des Codex Mount Managers
- Beginn und Ende des gesamten Extension-Abschnitts

Wird die PowerShell durch Endpoint-Schutz hart beendet, ist der letzte
`ATC-DIAG`-Eintrag damit die letzte vom Setup nachweislich erreichte Aktion.
Die Diagnose veraendert die bestehende Installationsreihenfolge nicht und
fuegt keine zusaetzlichen `code`-Aufrufe hinzu.

## Neu in 1.0.40

Die Docker-/WSL-Pruefung behandelt eine fehlende oder falsche WSL-Integration
jetzt als **manuell zu korrigierende Docker-Desktop-Einstellung**. Das Setup
versucht nicht mehr, diese Einstellung durch Neustarts scheinbar selbst zu
reparieren.

Wenn Docker in der gewaehlten WSL-Distro nicht erreichbar ist oder auf eine
andere Docker Engine zeigt, nennt das Setup den exakten Weg:

`Settings -> Resources -> WSL integration`

Dort muss der Schalter fuer die gewaehlte Distribution aktiviert werden. Nach
einer Aenderung weist das Setup ausdruecklich auf den Docker-Desktop-Button
**`Apply & restart`** hin, wartet auf ENTER, danach auf den Docker-Neustart und
prueft Docker-Zugriff sowie Engine-Konsistenz erneut.

Ausserdem werden bei der Suche unter `Documents` fremde `devcontainer.json`-
Dateien vor dem JSON-Parsing auf Codex-Merkmale vorgefiltert. Dadurch sollen
unbeteiligte oder JSONC-basierte Dev-Container waehrend der stillen
Bestandsaufnahme keine `ConvertFrom-Json`-Fehlermeldung mehr erzeugen.

## Neu in 1.0.39

Das Setup sucht jetzt **vor allen regulären Rückfragen** nach bereits vorhandenen
Codex-Devcontainer-Konfigurationen unter dem Windows-Dokumente-Ordner. Als
Codex-Umgebung gelten dabei nur `devcontainer.json`-Dateien mit den verwalteten
`CODEX_*`-Build-Argumenten oder einem Mount auf `/home/vscode/.codex`.

Regeln bei der Erkennung:

1. **Kein Treffer**
   - der angegebene `-InstallDirectory` wird als neue Umgebung verwendet
2. **Genau ein Treffer**
   - diese bestehende Umgebung wird automatisch verwendet
   - ihr tatsächlicher Installationsordner und Volume-Präfix werden übernommen
3. **Mehrere Treffer**
   - alle Treffer werden zunächst ohne Rückfrage vorgeprüft
   - danach werden Name, Pfad, Volume-Präfix, erkannte Entwicklungsumgebungen und
     ggf. die gefundene Container-ID angezeigt
   - erst dann wird gefragt, welche Umgebung verwendet werden soll

Damit wird z. B. eine bestehende Umgebung unter
`Documents\HighText-Codex-Container\.devcontainer\devcontainer.json` auch dann
erkannt, wenn das Setup mit dem bisherigen Standardziel `Documents\Codex-Container`
und `codex-sandbox` gestartet wurde. Aus `hightext-codex-workspaces` bzw.
`hightext-codex-home` wird automatisch der vorhandene Präfix `hightext-codex`
abgeleitet.

Ist eine vorhandene `devcontainer.json` gewählt, wird sie **nicht mehr neu
erzeugt**. Bestehende Bind-Mounts, `customizations.vscode.settings`,
`files.associations`, Name und Build-Argumente bleiben erhalten. Das Setup ergänzt
nur den fehlenden persistenten Mount für
`/home/vscode/.vscode-server/extensions` und die dazugehörigen Besitzrechte.

Sind die Build-Argumente `CODEX_INSTALL_PHP`, `CODEX_INSTALL_CPP`,
`CODEX_INSTALL_PYTHON`, `CODEX_NODE_VERSION` und `CODEX_DOTNET_VERSION` bereits
vorhanden, werden sie ohne Rückfrage übernommen. Eine erneute PHP-/C++-/Python-/
Node-/.NET-Auswahl findet dann nicht statt.

## Neu in 1.0.38

Wiederholungsläufe beginnen jetzt mit einer **Bestandsaufnahme ohne Rückfragen**.
Das Setup prüft zuerst soweit technisch möglich:

- vorhandene `devcontainer.json` und deren Entwicklungsumgebungen
- gespeicherte Dev-Containers-WSL-Distro sowie installierte/aktive normale WSL-Distros
- verbundene Windows-Netzlaufwerke
- Docker-Verfügbarkeit
- vorhandenen passenden Dev Container
- `workspaces`- und `.codex`-Volume-Mounts
- vorhandenen Codex-Binary
- vorhandene Container-Extensions und Zustand des persistenten Extensions-Volumes
- lokale Codex-Historie und ob diese bereits im persistenten Container-Home enthalten ist

Erst nach dieser Bestandsaufnahme können noch wirklich notwendige Rückfragen
folgen. Dadurch wird insbesondere bei einem bereits eingerichteten Rechner die
Frage zum Chatimport nicht mehr allein deshalb erneut gestellt, weil unter
`%USERPROFILE%\.codex` noch die alte Windows-Historie liegt.

Für die Erkennung eines bereits erledigten Chatimports werden die lokalen
Rollout-Dateien gegen `/home/vscode/.codex` geprüft. Ziel-Dateien dürfen größer
sein, damit im Container später fortgesetzte Chats nicht fälschlich als
"nicht importiert" gelten. Existierende IDs aus `session_index.jsonl` werden
ebenfalls abgeglichen.

Eine bereits in den VS-Code-Einstellungen gespeicherte
`dev.containers.executeInWSLDistro` wird bei Wiederholungsläufen weiterverwendet.
Bereits in `/etc/fstab` konfigurierte Windows-Netzlaufwerke werden nur geprüft
und bei Bedarf gemountet, aber nicht erneut abgefragt.

Die vorhandene Auswahl für PHP, C/C++, Python, Node.js und .NET wird aus der
vorhandenen `devcontainer.json` übernommen, statt sie bei jedem Setup-Lauf neu
abzufragen.

## Neu in 1.0.37

Beim Umstieg von einer Version ohne persistentes VS-Code-Extensions-Volume erkennt
das Setup jetzt einen vorhandenen passenden Dev Container und prüft dessen
`/home/vscode/.vscode-server/extensions`.

Sind dort Erweiterungen vorhanden und ist das neue Volume
`codex-sandbox-vscode-extensions` noch leer, fragt das Setup ausdrücklich:

```text
Diese vorhandenen Container-Erweiterungen in das neue persistente Volume übernehmen? [J/n]
```

Bei **Ja** werden die vorhandenen Extension-Dateien vor dem nächsten Rebuild in
das persistente Volume kopiert. Dafür wird nur kurzzeitig ein lokales
Migrations-Image des bestehenden Containers erzeugt und danach wieder entfernt.

Bei **Nein** bleibt das neue Volume leer. Beim nächsten Rebuild installiert VS Code
die in `devcontainer.json` deklarierten Erweiterungen erneut; andere bisher nur
manuell installierte Container-Erweiterungen werden dann nicht übernommen.

Ist das Ziel-Volume bereits befüllt, wird keine Migration angeboten und nichts
überschrieben.

## Neu in 1.0.36

VS-Code-Erweiterungen, die **im Dev Container** installiert werden, liegen jetzt
auf dem persistenten Docker-Volume `codex-sandbox-vscode-extensions`.
Gemountet wird ausschließlich:

```text
/home/vscode/.vscode-server/extensions
```

Damit bleiben auch manuell installierte Container-Erweiterungen nach
**Dev Containers: Rebuild Container** erhalten. Der eigentliche VS-Code-Server
unter `.vscode-server` bleibt weiterhin kurzlebig und kann von VS Code bei einem
Versionswechsel sauber neu aufgebaut werden.

Das Setup legt den Mountpunkt im Image mit dem Benutzer `vscode` an und korrigiert
beim ersten Containerstart zusätzlich die Besitzrechte des Volume-Wurzelverzeichnisses.
Die sichere Container-Erkennung über Setup-Volumes berücksichtigt ab dieser Version
alle drei persistenten Volumes.

## Neu in 1.0.35

Enthält **Codex Mount Manager 0.3.6**.

Der verbindliche Dev-Containers-Hostmodus wird von Windows zurück auf die
ausgewählte WSL-Distro standardisiert. Der vorherige Windows-Modus funktionierte
für lokale Laufwerke, scheiterte aber bei gemappten SMB-/Netzlaufwerken wie
`O:\` und `V:\` mit Docker-Desktop-Fehlern der Form:

```text
bind source path does not exist: /run/desktop/mnt/host/uC/<server>/<share>
```

Das Setup setzt `dev.containers.executeInWSL = true` jetzt **korrekt auf
VS-Code-Benutzerebene** und pinnt `dev.containers.executeInWSLDistro` auf die
vorher ausgewählte WSL. Damit ist das Verhalten auf unterschiedlichen
Rechnern identisch.

Windows-Laufwerke werden wieder als `/mnt/<laufwerk>/...` verwendet. Gemappte
Netzlaufwerke werden wie bisher vom Setup per `drvfs` in dieser WSL bereitgestellt.
`dev.containers.mountWaylandSocket = false` bleibt aktiv.


## Neu in 1.0.34

Enthält **Codex Mount Manager 0.3.5**.

Zusätzlich zur verbindlichen Windows-Ausführung von Dev Containers wird jetzt
auch `dev.containers.mountWaylandSocket = false` auf Benutzerebene gesetzt. Der
Codex-Container ist headless und benötigt kein WSLg. Damit erzeugt Dev Containers
keinen automatischen `\\wsl.localhost\<Distro>\mnt\wslg\...\wayland-0`-Mount
mehr. Das verhindert Fehler wie:

```text
accessing specified distro mount service: stat /run/guest-services/distro-services/<distro>.sock: no such file or directory
```

## Neu in 1.0.33

Enthält **Codex Mount Manager 0.3.4**.

Der Dev-Containers-Hostmodus wird jetzt auf allen Windows-Rechnern verbindlich
vereinheitlicht. `dev.containers.executeInWSL` wird nicht mehr fälschlich als
Workspace-Einstellung gesetzt, sondern auf **VS-Code-Benutzerebene** explizit
auf `false` gestellt. Ein alter globaler `dev.containers.executeInWSLDistro`-Wert
wird entfernt.

Damit läuft die Dev-Containers-CLI konsistent auf unterschiedlichen Rechnern
gleich unter Windows; Docker Desktop kann intern weiterhin WSL2 verwenden.
Bind-Mounts verwenden deshalb überall echte Windows-Hostpfade wie `C:\\...`,
`O:\\` oder `V:\\html`. Der Mount Manager migriert alte `/mnt/<laufwerk>/...`-
Quellen automatisch.

Dies behebt den Widerspruch zwischen `/mnt/c/...`- und `C:\\...`-Pfaden:
Ursache war die unterschiedlich gestartete Dev-Containers-CLI, nicht Ubuntu oder Docker Desktop selbst.

## Neu in 1.0.32

Enthält **Codex Mount Manager 0.3.3**.

Fix für Bind-Mounts, wenn Dev Containers wie im Fresh-Setup über
`dev.containers.executeInWSL = true` in der ausgewählten WSL-Distro ausgeführt
wird. In diesem Modus muss Docker die Quellpfade aus Sicht von WSL erhalten:

```text
C:\Users\Name\Projekt  ->  /mnt/c/Users/Name/Projekt
O:\                    ->  /mnt/o
V:\html                ->  /mnt/v/html
```

Die Versionen 0.2.4 bis 0.3.2 des Mount Managers hatten Windows-Pfade wie
`C:\...` gespeichert. Das funktioniert nur, wenn Docker direkt über Windows
ausgeführt wird. Läuft die Dev-Containers-CLI in WSL, führt das zu:

```text
invalid mount path: 'C:/...' mount path must be absolute
```

Der Mount Manager erkennt jetzt den tatsächlichen Ausführungsmodus. Bestehende
Bind-Mounts werden vor dem Rebuild automatisch in die passende Richtung
normalisiert. Ohne `executeInWSL` bleiben echte Windows-Hostpfade weiterhin
unterstützt.

## Neu in 1.0.31

Enthält **Codex Mount Manager 0.3.2**.

Fix für PHP-Builds auf Ubuntu 26.04 / PHP 8.5: Das frühere Meta-Paket
`php-opcache` besitzt dort keinen Installationskandidaten mehr, weil OPcache bei
PHP 8.5 mit dem CLI/Common-Paket ausgeliefert wird. Das Setup installiert deshalb
kein distributionsabhängiges `php-opcache` mehr. Falls OPcache auf einer älteren
Distribution separat benötigt wird, wird das passende versionsspezifische Paket
(z. B. `php8.3-opcache`) nur dann nachinstalliert, wenn es tatsächlich verfügbar
ist.

Neue Fresh-Setups pinnen das Dev-Container-Basisimage außerdem auf
`mcr.microsoft.com/devcontainers/base:ubuntu-24.04`. Der bisherige gleitende Tag
`:ubuntu` konnte bei einem Rebuild auf eine neue Ubuntu-Hauptversion wechseln.

## Neu in 1.0.30

Enthält **Codex Mount Manager 0.3.1**.

Das Fresh-Setup fragt jetzt die dauerhaft benötigten Entwicklungsumgebungen ab
und erzeugt von Anfang an eine verwaltete `Dockerfile.codex`-Buildkonfiguration.
Dadurch bleiben die Werkzeuge auch nach **Dev Containers: Rebuild Container**
erhalten.

Auswählbar sind:

- PHP CLI + Composer + wichtige Module
- C/C++ mit GCC/G++, Make, CMake, GDB, Ninja und pkg-config
- Python 3 mit pip, venv, pytest und Entwicklungswerkzeugen
- Node.js 20 oder 22 inklusive npm; gegenseitig ausschließend
- .NET 10 oder 11; gegenseitig ausschließend

.NET 11 wird sowohl im Setup als auch im Mount Manager erst zugelassen, wenn
der Microsoft-Releasekanal ein stabiles GA-Release meldet. Preview/RC werden
nicht installiert.

`sqlite3` gehört jetzt zu den immer vorhandenen Basiswerkzeugen.

Der bisherige `postCreateCommand` installiert Python und SQLite nicht mehr
ungefragt nach. Er kümmert sich nur noch um die Rechte des persistenten
Codex-Home-Verzeichnisses. Wenn für einen Chatimport Python benötigt wird, nutzt
das Setup weiterhin seine vorhandene bedarfsgesteuerte Prerequisite-Installation.

Codex Mount Manager 0.3.1 enthält außerdem weiterhin die Mount-Korrekturen aus
0.2.4: neue Bind-Mounts werden als strukturierte Objekte mit echten
Windows-Hostpfaden gespeichert, und ältere `/mnt/<laufwerk>/...`-Quellen werden
unter Windows automatisch migriert.

## Neu in 1.0.29

Enthält **Codex Mount Manager 0.2.4**.

Lokale Windows-Ordner werden jetzt mit ihrem tatsächlichen Windows-Hostpfad in
`devcontainer.json` eingetragen:

```json
{
  "source": "C:\\Users\\Name\\Documents\\Arduino",
  "target": "/workspaces/Arduino",
  "type": "bind"
}
```

Ältere, vom Mount Manager erzeugte Quellen wie `/mnt/c/Users/...` werden unter
Windows automatisch korrigiert.


## Neu in 1.0.28

Enthält **Codex Mount Manager 0.2.3**.

Neue `mounts`-Einträge werden nicht mehr als kommagetrennte Strings erzeugt,
sondern als strukturierte Dev-Container-Objekte:

```json
{
  "source": "/mnt/c/Users/Sven Noherr/Documents/Arduino",
  "target": "/workspaces/Arduino",
  "type": "bind"
}
```

Damit sind insbesondere Windows-/WSL-Hostpfade mit Leerzeichen robuster.

Der Mount Manager bleibt rückwärtskompatibel und kann bestehende String-Mounts
weiter anzeigen, umbenennen und entfernen.

Auch der persistente Codex-Home-Mount der neu erzeugten `devcontainer.json`
wird jetzt als Objekt geschrieben.


## Neu in 1.0.27

Fix für Dev Container, die während der Setup-Prüfungen durch VS Codes
`shutdownAction` gestoppt werden.

Der Fehler zeigte sich z.B. beim Sandbox-Test erst im Cleanup:

```text
Error response from daemon: container ... is not running
```

obwohl der eigentliche Setup-Schritt bereits weitgehend erfolgreich war.

Der generische Container-Script-Runner ist jetzt stop/start-fest:

- Docker-Aufrufe für Steuer-/Prüfzwecke laufen über einen nicht-terminierenden
  Wrapper für Windows PowerShell 5.1
- vor `docker exec` wird geprüft, ob der Container läuft
- ein gestoppter Container wird automatisch erneut gestartet
- auf `docker exec` wird bis zu 20 Sekunden gewartet
- wenn der Container exakt zwischen `docker cp` und `docker exec` gestoppt
  wird, wird er erneut gestartet
- wenn er exakt während des ersten Scriptstarts gestoppt wurde, wird der
  Scriptlauf einmal wiederholt
- das Entfernen der temporären `.sh`-Datei im Container ist nur noch
  Best-Effort
- ein gestoppter Container beim Cleanup kann den eigentlichen Setup-Erfolg
  nicht mehr überschreiben

Der manuelle Erst-Bootstrap wurde ebenfalls geändert:

```text
VS Code GEÖFFNET LASSEN
```

Statt VS Code vor den anschließenden Prüfungen zu schließen, bleibt das
Dev-Container-Fenster offen. Dadurch wird ein automatisches Stoppen des
Containers während des Setups von vornherein vermieden.


## Neu in 1.0.26

Fix für die Codex-Binary-Suche auf Rechnern, auf denen nicht alle möglichen
VS-Code-Server-Verzeichnisse existieren.

Beispiel:

```text
/home/vscode/.vscode-server/extensions
/home/vscode/.vscode-server-insiders/extensions
/vscode/vscode-server/extensions
```

`vscode-server-insiders` ist bei einer normalen VS-Code-Installation
üblicherweise nicht vorhanden. `find` lieferte dafür stderr und Windows
PowerShell 5.1 konnte diesen nativen stderr bei `ErrorActionPreference=Stop`
als Terminierungsfehler behandeln.

Version 1.0.26:

1. prüft jeden möglichen Root zunächst einzeln mit `test -d`
2. startet `find` nur auf tatsächlich vorhandenen Verzeichnissen
3. behandelt fehlende optionale VS-Code-Pfade als normalen Zustand
4. puffert eventuellen `find`-stderr in eine temporäre Datei
5. lässt einen einzelnen nicht erfolgreichen Suchpfad nicht mehr das komplette
   Setup abbrechen

Die eigentliche Prüfung bleibt streng: Als installiert zählt weiterhin nur ein
echter:

```text
.../openai.chatgpt-.../bin/linux-.../codex
```

und kein bloßer Downloadcache.


## Neu in 1.0.25

Zwei Fixes für wirklich frische Rechner:

### 1. `.codex` bedeutet nicht automatisch "alte Chats vorhanden"

Die lokal installierte OpenAI-Erweiterung kann bereits einen `.codex`-Ordner
und eine `state_5.sqlite` erzeugen, obwohl der Benutzer auf diesem Rechner noch
keine alten Chats besitzt.

Als **importierbare Historie** gilt jetzt nur noch:

- `state_5.sqlite` ist vorhanden und nicht leer
- UND unter `sessions` oder `archived_sessions` existiert mindestens eine
  echte `.jsonl`-Rollout-Datei

Ein nur frisch angelegter `.codex`-Ordner führt nicht mehr zu einer Importfrage.

### 2. Downloadcache zählt nicht mehr als installierte Codex-Extension

OpenAI/Codex gilt nur noch als vollständig installiert, wenn der echte Binary
gefunden wird:

```text
.../.vscode-server/extensions/openai.chatgpt-.../bin/linux-.../codex
```

Bei einem bereits vorhandenen Dev Container versucht das Setup automatisch:

1. VS Code direkt per `vscode-remote://dev-container+...` zu öffnen
2. bis zu 120 Sekunden auf die vollständige Remote-Extension-Installation zu warten
3. erst danach auf den manuellen Bootstrap zurückzufallen

Damit führen Zwischenzustände während des Extension-Downloads nicht mehr zu
falschen Erfolgsmeldungen oder unnötigen Chatimport-Schritten.


## Neu in 1.0.24

Die Codex-Datenbank wird auf einem wirklich frischen Rechner nicht mehr
unnötig vorab erzeugt.

`state_5.sqlite` wird vom Setup nur benötigt, wenn vorhandene lokale Codex-Chats
in das aktuelle Container-Schema importiert werden sollen.

Deshalb gilt jetzt:

- **kein vorhandener Chatimport**:
  - keine künstliche DB-Initialisierung
  - Codex erzeugt `state_5.sqlite` beim ersten normalen Start selbst
- **Chatimport gewählt**:
  - aktuelle Ziel-DB wird weiterhin vor dem Merge initialisiert

Zusätzlich wurde `Ensure-FreshCodexDb` vollständig vom fehleranfälligen:

```text
docker exec ... sh -lc <mehrzeiliges Skript>
```

befreit.

Die Initialisierung wird jetzt als echte UTF-8/LF-`.sh`-Datei per `docker cp`
in den Container kopiert und dort mit `/bin/sh` ausgeführt.

Der Sandbox-Isolationstest verwendet vorsorglich dieselbe robuste Technik.

Damit sind die letzten mehrzeiligen Docker-`sh -lc`-Aufrufe aus diesen beiden
kritischen Setup-Schritten entfernt.

## Neu in 1.0.23

Fix für WSL-Ausgaben mit eingebetteten NUL-Zeichen unter Windows PowerShell 5.1.

Auf manchen Windows-10-Systemen liefert `wsl.exe --version` beim
programmgesteuerten Einlesen eine UTF-16-artige Ausgabe, bei der zwischen den
sichtbaren Zeichen NUL-Zeichen stehen. Dadurch konnte die Prüfung auf
`WSL-Version:` nicht matchen, obwohl moderne WSL bereits korrekt aktiv war.

Version 1.0.23 normalisiert native Prozessausgaben jetzt zentral:

- NUL-Zeichen werden entfernt
- BOM/FEFF wird entfernt
- WSL-Versionserkennung verwendet normalisierten Text
- WSL-Distro-Listen werden ebenfalls defensiv normalisiert

Damit wird eine normale Ausgabe wie:

```text
WSL-Version: 2.7.12.0
Kernelversion: 6.18.33.2-2
```

korrekt erkannt und es wird kein unnötiger Neustart verlangt.


## Neu in 1.0.22

WSL-Updates führen nicht mehr vorschnell zu einer Neustartaufforderung.

Nach:

```text
winget install --id Microsoft.WSL --exact
```

prüft das Setup die moderne WSL-Version jetzt bis zu 15-mal im Abstand von
2 Sekunden.

Als moderne WSL-Version gelten erfolgreiche Ausgaben mit z. B.:

```text
WSL-Version:
Kernelversion:
```

Wenn WSL nach dieser Wartezeit noch nicht sichtbar ist, wird zunächst einmal:

```text
wsl --shutdown
```

ausgeführt und erneut geprüft.

Erst wenn auch das nicht hilft, fordert das Setup tatsächlich einen
Windows-Neustart an.

Damit wird der Zustand vermieden, bei dem `Microsoft.WSL` bereits korrekt
installiert ist und wenige Sekunden später funktioniert, das Setup aber trotzdem
unnötig einen Reboot verlangt.


## Neu in 1.0.21

Fix für den Zustand:

```text
Wsl/WSL_E_WSL_OPTIONAL_COMPONENT_REQUIRED
```

Dabei ist `wsl.exe` bereits vorhanden, aber die benötigten optionalen
Windows-Komponenten sind noch deaktiviert.

Das Setup prüft jetzt **vor jeder WSL-Distro-Erkennung**:

```text
Microsoft-Windows-Subsystem-Linux
VirtualMachinePlatform
```

über `Get-WindowsOptionalFeature`.

Fehlende Komponenten werden automatisch als Administrator mit
`Enable-WindowsOptionalFeature` aktiviert.

Nach einer erstmaligen Aktivierung beendet sich das Setup absichtlich mit:

```text
WINDOWS-NEUSTART ERFORDERLICH
```

und wartet auf ENTER.

Nach dem Windows-Neustart wird dasselbe Setup erneut gestartet. Bereits
erledigte Schritte sind weiterhin wiederholbar/idempotent.

Die Prüfung auf eine alte Inbox-Version von `wsl.exe` unterscheidet jetzt
zusätzlich explizit zwischen:

- alte WSL-Version
- WSL-App vorhanden, Windows-Komponente aber deaktiviert

damit `WSL_E_WSL_OPTIONAL_COMPONENT_REQUIRED` nicht mehr falsch klassifiziert
wird.


## Neu in 1.0.20

Fix für frische Windows-10-Rechner mit alter Inbox-Version von `wsl.exe`.

Alte WSL-Versionen verstehen unter Umständen noch nicht:

```text
wsl --list --quiet --running
```

und geben bei unbekannten Optionen stattdessen ihre komplette Hilfe aus.
Frühere Setup-Versionen konnten diese Hilfezeilen irrtümlich als Namen von
WSL-Distributionen behandeln.

Das ist jetzt grundsätzlich ausgeschlossen:

- installierte WSL-Distributionen werden primär sprachneutral aus
  `HKCU\Software\Microsoft\Windows\CurrentVersion\Lxss` gelesen
- die `--running`-Ausgabe wird nur akzeptiert, wenn die zurückgegebenen Namen
  tatsächlich als Distribution registriert sind
- Copyright-, Usage-, Argument- und Hilfezeilen können niemals mehr als
  Distribution ausgewählt werden
- wenn die alte WSL-Version den Aktivstatus nicht bestimmen kann, wird
  ausdrücklich `Status unbekannt` angezeigt

Nach dem `winget`-Check prüft das Setup außerdem:

```text
wsl --version
```

Wenn nur die alte Inbox-Version vorhanden ist, wird automatisch die aktuelle
WSL-Version über:

```text
winget install --id Microsoft.WSL --exact
```

installiert/aktualisiert.

Falls Windows danach einen Neustart benötigt, beendet sich das Setup mit einer
klaren Neustartmeldung und kann anschließend gefahrlos erneut ausgeführt werden.


## Neu in 1.0.19

Nach einem erfolgreichen Setup startet VS Code jetzt automatisch direkt im
bestehenden Codex Dev Container.

Dafür verwendet das Setup eine Dev-Containers-Remote-URI:

```text
vscode-remote://dev-container+<hex-kodierter Hostpfad>/workspaces
```

Der Container wird unmittelbar vor dem Start nochmals sichergestellt/gestartet.

Damit entfällt am Ende:

```text
VS Code öffnen
Dev Containers: Reopen in Container
```

Falls der direkte Remote-Aufruf einen Fehlercode liefert, öffnet das Setup als
Fallback den lokalen Codex-Container-Workspace.

Zusätzlich wurde der Abschlussblock aus 1.0.18 bereinigt: Erfolgsmeldung,
Logausgabe, ENTER-Wartepunkt und `Stop-Transcript` stehen jetzt unabhängig vom
`-LogFile`-Schalter in der richtigen Reihenfolge.


## Neu in 1.0.18

Erfolgreiche Setup-Läufe schließen das Fenster nicht mehr kommentarlos.

Nach einem vollständig erfolgreichen Lauf erscheint jetzt:

```text
========================================
 SETUP ERFOLGREICH ABGESCHLOSSEN
========================================

Codex-Dev-Container, Erweiterungen, Chatimport und Sandbox-Prüfung
wurden ohne Fehler abgeschlossen.

ENTER drücken, um dieses Fenster zu schließen:
```

Das Fenster bleibt stehen, bis ENTER gedrückt wird.

Fehlerläufe verwenden weiterhin den bestehenden Fehlerdialog und werden
nicht fälschlich als erfolgreich gemeldet.


## Neu in 1.0.17

Fix für:

```text
sqlite3.OperationalError: attempt to write a readonly database
```

Die konsistente Quell-Datenbank wird vor dem Import per `docker cp` nach
`/tmp/codex-import` kopiert. `docker cp` legt diese Dateien als `root` an,
während der eigentliche Merge absichtlich als Benutzer `vscode` läuft.

SQLite kann auch beim Öffnen einer Datenbank Lock-/Journal-Dateien im selben
Verzeichnis benötigen. Deshalb wird vor dem Merge jetzt:

```text
chown -R vscode:vscode /tmp/codex-import
chmod -R u+rwX /tmp/codex-import
```

ausgeführt.

Außerdem wird die bereits separat erzeugte, wegwerfbare Backup-Kopie der alten
Codex-Datenbank nicht mehr mit `mode=ro` geöffnet. Die originale
Windows-Datenbank bleibt weiterhin vollständig unangetastet.

Das Merge-Log zeigt zusätzlich Quell-/Zieldatenbank und deren
`journal_mode`, falls noch ein SQLite-spezifisches Problem auftaucht.


## Neu in 1.0.16

Fix für die automatische Installation von `python3` und `sqlite3`.

Unter Windows PowerShell 5.1 war die Übergabe eines mehrzeiligen Shell-Skripts
direkt als Argument an:

```text
docker exec ... sh -c <mehrzeiliges Skript>
```

nicht zuverlässig. Das Skript konnte dadurch nur teilweise bzw. gar nicht
ausgeführt werden, obwohl der Docker-Aufruf keinen brauchbaren Installationsfehler
lieferte.

Version 1.0.16 verwendet deshalb kein mehrzeiliges `sh -c` mehr.

Stattdessen:

### Im Dev Container

1. temporäre `.sh`-Datei unter Windows erzeugen
2. UTF-8 ohne BOM und nur LF-Zeilenenden
3. per `docker cp` in den Container kopieren
4. mit `/bin/sh` als `root` ausführen
5. Datei wieder löschen
6. `python3 --version` und `sqlite3 --version` tatsächlich testen

### In WSL

1. dieselbe temporäre `.sh`-Datei erzeugen
2. Windows-Pfad in `/mnt/...` umsetzen
3. Datei mit `/bin/sh` als `root` in der ausgewählten WSL-Distro ausführen
4. danach beide Programme tatsächlich testen

Damit entfällt das problematische PowerShell -> Docker/WSL -> `sh -c` Quoting
für die Paketinstallation vollständig.


## Neu in 1.0.15

Fix für den PowerShell-Parserfehler aus 1.0.14.

Die `postCreateCommand`-Zeile verwendete irrtümlich `\"` innerhalb eines
PowerShell-Strings. PowerShell verwendet Backslash nicht zum Escapen von
Anführungszeichen. Dadurch konnte das gesamte Setup-Skript nicht geparst werden.

Die Zeile verwendet jetzt einen einfachen PowerShell-String und benötigt keine
problematische Quote-Escaperei mehr:

```text
if ! command -v python3 ... || ! command -v sqlite3 ...; then ...
```

Zusätzlich enthält das Paket jetzt:

```text
Validate-SetupSyntax.ps1
```

Der empfohlene Starter:

```text
Setup-NewCodexComputer.cmd
```

führt diesen PowerShell-Parsercheck **vor jedem Setup-Start** aus. Bei einem
Syntaxfehler wird das eigentliche Setup gar nicht erst gestartet.

Für den Logmodus weiterhin:

```text
Setup-NewCodexComputer.cmd --logfile
```

Dadurch ist auch kein vorheriges `Set-ExecutionPolicy` nötig, weil der Starter
PowerShell bereits mit `-ExecutionPolicy Bypass` aufruft.


## Neu in 1.0.14

Der Chatimport prüft jetzt zusätzlich `sqlite3`.

Vor dem Import werden in beiden Umgebungen geprüft:

- `python3`
- `sqlite3`

und zwar:

- in der ausgewählten WSL-Distribution
- im Dev Container

Fehlende Pakete werden nur bei einem tatsächlich gewünschten Chatimport
automatisch über den vorhandenen Paketmanager installiert.

Unterstützt werden weiterhin:

- `apt-get`
- `apk`
- `dnf`
- `microdnf`
- `yum`
- `pacman`
- `zypper`

Bei Alpine heißt das Paket für die SQLite-CLI `sqlite`, bei Debian/Ubuntu
`sqlite3`.

Neue Ubuntu-basierte Dev Container bekommen bei Bedarf beide Werkzeuge bereits
über `postCreateCommand`.


## Neu in 1.0.13

Fix für den Chatimport:

Der Dev-Containers-Basiscontainer enthält nicht zwingend `python3`. Der
Chatimport benötigt Python für den sicheren SQLite-Backup-/Merge-Vorgang.

Das Setup prüft Python jetzt automatisch:

- in der ausgewählten WSL-Distribution
- im Dev Container

Nur wenn Chats importiert werden sollen und Python fehlt, wird es automatisch
installiert.

Unterstützte Paketmanager:

- `apt-get` (Ubuntu/Debian)
- `apk` (Alpine)
- `dnf` / `microdnf` / `yum`
- `pacman`
- `zypper`

Damit bleibt die WSL-Auswahl distributionsunabhängig.

Neue Ubuntu-basierte Dev Container installieren Python zusätzlich bereits über
`postCreateCommand`, falls es im Basisimage fehlt.

Außerdem ist die im Log ausgegebene Setup-Version jetzt fest auf `1.0.13`
korrigiert.


## Neu in 1.0.12

Korrektur des Wiederholungsablaufs:

Die in 1.0.11 angekündigte Vorabprüfung war noch nicht an der richtigen Stelle
im Skript. Dadurch wurde VS Code weiterhin vor jeder Container-/Codex-Prüfung
geöffnet.

Jetzt ist die Reihenfolge tatsächlich:

1. vorhandenen Dev Container suchen
2. vorhandenen Container starten
3. prüfen, ob `openai.chatgpt` bereits darin vorhanden ist
4. wenn ja:
   - VS-Code-Bootstrap vollständig überspringen
5. nur wenn Container oder Codex fehlen:
   - VS Code öffnen
   - einmal `Dev Containers: Reopen in Container`
   - anschließend prüft das Skript Codex selbst

Die wiederholte manuelle Kontrolle von `openai.chatgpt` in der
VS-Code-Extensions-Ansicht wurde aus dem Bootstrap-Schritt entfernt.

## Neu in 1.0.11

Wiederholte Setup-Läufe öffnen VS Code nicht mehr unnötig.

Vor dem manuellen VS-Code-Schritt prüft das Setup jetzt:

1. Existiert bereits ein passender Dev Container?
2. Kann dieser Container gestartet werden?
3. Ist `openai.chatgpt` darin bereits vorhanden?

Wenn alle drei Punkte erfüllt sind:

```text
OpenAI/Codex ist im vorhandenen Dev Container bereits installiert.
Der manuelle VS-Code-/Extension-Prüfschritt wird übersprungen.
```

Erst wenn:

- noch kein Dev Container existiert oder
- die OpenAI/Codex-Remote-Extension darin noch fehlt,

wird VS Code geöffnet.

Auf einem komplett neuen Rechner muss VS Code weiterhin genau einmal den
Dev Container erzeugen. Danach sind spätere Setup-Läufe vollständig
automatisch prüfbar.

## Neu in 1.0.10

Fix für den Schritt nach dem Schließen von VS Code:

- Dev Containers kann den Container automatisch stoppen, wenn das letzte
  VS-Code-Fenster geschlossen wird.
- Das Setup startet den gefundenen Container deshalb vor weiteren Prüfungen
  ausdrücklich erneut.
- Vor `docker exec` wird geprüft, ob der Container wirklich Befehle annimmt.
- Die problematische Prüfung über `code --list-extensions` wurde entfernt.
  Das Quoting über Windows PowerShell -> Docker -> `sh -lc` konnte zu
  `Syntax error: end of file unexpected` führen.
- `openai.chatgpt` wird jetzt über:
  - tatsächliche VS-Code-Server-Extension-Pfade und
  - `extensions.json`
  erkannt.
- Falls der Container während der Prüfung wieder stoppt, wird er erneut
  gestartet.

## Neu in 1.0.9

Die Dev-Container-Erkennung funktioniert jetzt; der nächste gefundene Fehler
lag nur noch in der Prüfung der OpenAI/Codex-Remote-Extension.

Die bisherige Prüfung suchte ausschließlich nach einem Verzeichnis
`openai.chatgpt-*` unter einem festen VS-Code-Server-Pfad. Das ist zu eng.

Version 1.0.9 prüft jetzt in dieser Reihenfolge:

1. VS-Code-Server-eigene Extension-Liste (`--list-extensions --show-versions`)
2. `~/.vscode-server/extensions`
3. `~/.vscode-server/extensionsCache`
4. entsprechende Insiders-Pfade
5. das gemeinsam gemountete `/vscode/vscode-server/...`

Zusätzlich wartet das Setup bis zu 90 Sekunden auf eine noch laufende
Remote-Extension-Installation.

Falls OpenAI danach weiterhin nicht erkannt wird, werden die tatsächlich
vorhandenen OpenAI-/ChatGPT-Pfade im VS-Code-Server in das Setup-Log geschrieben.

## Neu in 1.0.8

Fix für die WSL-Auswahl unter Windows PowerShell 5.1:

`wsl --list --quiet` kann je nach System unsichtbare Steuer-/NUL-Zeichen in den
Distro-Namen liefern. Dadurch konnte `docker-desktop` in 1.0.7 trotz Filterung
versehentlich wie eine normale WSL-Distro erscheinen.

Version 1.0.8:

- normalisiert WSL-Distro-Namen vor jedem Vergleich
- entfernt NUL-, BOM- und Steuerzeichen
- behandelt diese Namen hart als Runtime-Hilfsdistributionen:
  - `docker-desktop`
  - `docker-desktop-data`
  - `rancher-desktop`
  - `rancher-desktop-data`
  - `podman-machine-default`
- Runtime-Hilfsdistributionen dürfen:
  - nicht ausgewählt werden
  - nicht als "mehrere aktive WSLs" zählen
  - niemals per `wsl --terminate` vom Setup beendet werden
- vor jedem tatsächlichen `wsl --terminate` gibt es eine zweite Schutzprüfung
- nur echte Benutzer-/Arbeitsdistributionen wie Ubuntu, Debian, Alpine, Fedora
  usw. werden beim Aufräumen berücksichtigt

Docker Desktop bleibt dadurch während der WSL-Auswahl unangetastet.

## Neu in 1.0.7

Die WSL-Distribution ist nicht mehr fest auf Ubuntu 24.04 verdrahtet.

### Auswahl der WSL-Distribution

Ganz am Anfang des Setups werden vorhandene normale WSL-Distributionen geprüft.
Runtime-Hilfsdistributionen wie `docker-desktop` werden dabei ignoriert.

Regeln:

1. **Genau eine normale WSL-Distro läuft bereits**
   - diese wird automatisch verwendet
   - Name und Linux-Distribution sind egal, z. B. Ubuntu, Debian, Alpine oder Fedora

2. **Mehrere normale WSL-Distros laufen**
   - vor dem weiteren Setup muss aufgeräumt werden
   - Benutzer wählt eine Distro aus
   - die übrigen laufenden Distros können per `wsl --terminate` beendet werden
   - sie werden **nicht gelöscht**

3. **Keine läuft, aber genau eine ist installiert**
   - diese vorhandene Distro wird verwendet und gestartet

4. **Keine läuft und mehrere sind installiert**
   - Benutzer wählt die gewünschte Distro

5. **Gar keine normale WSL-Distro ist installiert**
   - erst dann wird `Ubuntu-24.04` als Fallback installiert

Die gewählte Distro wird außerdem als WSL-Standarddistribution gesetzt und in den
Workspace-Einstellungen für Dev Containers hinterlegt:

```json
{
  "dev.containers.executeInWSL": true,
  "dev.containers.executeInWSLDistro": "<ausgewählte Distro>"
}
```

Damit sollen VS Code, Docker Desktop, das Setup und der Codex Mount Manager
immer dieselbe WSL-/Docker-Umgebung benutzen.

## Neu in 1.0.6

Ursache des zuvor unsichtbaren Containers gefunden:

VS Code hatte seine Dev-Containers-CLI in der **default WSL-Distro `Ubuntu`**
ausgeführt, obwohl das Setup Docker Desktop mit `Ubuntu-24.04` vorbereitet
hatte. In `Ubuntu` lief ein eigener Docker-Daemon. Dadurch existierte der
Dev Container auf einer anderen Docker Engine und war für Windows-Docker und
`Ubuntu-24.04` unsichtbar.

Version 1.0.6 standardisiert den Docker-Host deshalb verbindlich:

```json
{
  "dev.containers.executeInWSL": true,
  "dev.containers.executeInWSLDistro": "Ubuntu-24.04"
}
```

Diese Einstellungen werden als Workspace-Einstellungen unter:

```text
Codex-Container\.vscode\settings.json
```

erzeugt.

Zusätzlich vergleicht das Setup vor dem ersten Dev-Container-Start die Docker
Engine-ID von:

- Windows / Docker Desktop
- `Ubuntu-24.04`

Beide müssen dieselbe Docker Engine sehen. Andernfalls stoppt das Setup, bevor
VS Code einen Container auf dem falschen Daemon anlegt.

Das ist auch für den Codex Mount Manager wichtig, weil Windows-Pfade dort als
WSL-Pfade wie `/mnt/c/...` in die Dev-Container-Konfiguration geschrieben
werden.

## Neu in 1.0.5

- der manuelle VS-Code-Schritt erklärt jetzt ausdrücklich, wie man erkennt,
  dass VS Code wirklich im Dev Container läuft
- unten links muss `Dev Container: Codex Sandbox` stehen
- die Extension-Aufteilung wird erklärt:
  - **lokal:** Dev Containers
  - **lokal:** Codex Mount Manager
  - **im Dev Container:** OpenAI / `openai.chatgpt`
- zwei Terminal-Prüfungen für `openai.chatgpt` sind direkt in den
  Setup-Anweisungen enthalten
- nach Erkennung des Containers prüft das Setup `openai.chatgpt`
  zusätzlich selbst per `docker exec`
- fehlt die Remote-Extension, stoppt das Setup mit einer konkreten
  Installationsanweisung statt später an einer unklaren Codex-Initialisierung
  zu scheitern

## Neu in 1.0.4

- robustere Erkennung des von VS Code erzeugten Dev Containers:
  1. `devcontainer.local_folder`
  2. `devcontainer.config_file`
  3. als sichere Rückfallebene die beiden eindeutigen Volumes
     `codex-sandbox-workspaces` und `codex-sandbox-home`
- nach dem VS-Code-Schritt wird bis zu 60 Sekunden auf den Container gewartet
- wenn er trotzdem nicht gefunden wird, schreibt das Log jetzt:
  - alle Docker-Container
  - Status
  - Dev-Container-Labels
  - relevante Mounts
- Ja/Nein-Entscheidungen werden nun ausdrücklich ins Log geschrieben
- der Chatimport bekommt die bereits gefundene Container-ID direkt übergeben

## Neu in 1.0.3

- fortlaufendes Setup-Log per `--logfile`
- Log über mehrere Setup-Läufe hinweg in derselben Datei
- UAC-Neustart behält den Logmodus bei
- Docker-Startprüfungen werfen während der normalen Startphase keinen
  PowerShell-Abbruch mehr
- Docker Desktop wird bis zu 5 Minuten auf seine Engine gewartet
- bei fehlender Docker-Integration in Ubuntu:
  - Docker Desktop sauber beenden
  - `wsl --shutdown`
  - Docker Desktop neu starten
  - Docker Engine abwarten
  - WSL-Integration erneut prüfen
- wenn das weiterhin nicht funktioniert, wird die echte stdout/stderr-Ausgabe
  von `docker version` ins Log geschrieben
- nach einer frischen Docker-Desktop-Installation wird ein Windows-Neustart
  verlangt
- `.ps1`-Dateien sind UTF-8 mit BOM für Windows PowerShell 5.1
- die erzeugte `devcontainer.json` bleibt UTF-8 ohne BOM
