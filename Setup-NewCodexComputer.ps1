param(
    [string]$InstallDirectory = "$env:USERPROFILE\Documents\Codex-Container",
    [string]$UbuntuDistro = "",
    [string]$VolumePrefix = "codex-sandbox",
    [switch]$LogFile
)

$ErrorActionPreference = "Stop"
$script:TranscriptStarted = $false
$script:LogPath = $null
$script:AtcDiagPath = $null
$script:SetupVersion = "1.0.1"
$script:ChatImportHelperSha256 = "9099F2671970CA0ACF29AF6DE0964F287767420C880FA8D84B7F4DA6FA5388C5"

function Initialize-AtcDiagnosticLog {
    try {
        $logDir = Join-Path $PSScriptRoot "logs"
        New-Item -ItemType Directory -Force -Path $logDir | Out-Null
        $script:AtcDiagPath = Join-Path $logDir ("Setup-ATC-Diagnose-{0}.log" -f $env:COMPUTERNAME)

        $lines = @(
            "",
            "================================================================",
            ("ATC-Diagnose Setup {0} | {1}" -f $script:SetupVersion, (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff zzz')),
            ("Computer={0} Benutzer={1} PID={2}" -f $env:COMPUTERNAME, $env:USERNAME, $PID),
            ("PowerShell={0}" -f $PSVersionTable.PSVersion),
            ("CommandLine={0}" -f [Environment]::CommandLine),
            "================================================================"
        )

        [System.IO.File]::AppendAllText(
            $script:AtcDiagPath,
            (($lines -join [Environment]::NewLine) + [Environment]::NewLine),
            (New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false)
        )
        Write-Host "ATC-Diagnoselog: $script:AtcDiagPath" -ForegroundColor DarkGray
    }
    catch {
        # Diagnose darf das eigentliche Setup niemals blockieren.
        $script:AtcDiagPath = $null
    }
}

function Write-AtcCheckpoint([string]$Text) {
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff zzz'
    $line = "[$stamp] PID=$PID $Text"

    # Auch auf der Konsole ausgeben, damit der normale Transcript-Log denselben
    # Marker enthaelt. Zusaetzlich wird synchron in eine eigene Datei geschrieben.
    Write-Host "ATC-DIAG: $Text" -ForegroundColor DarkGray

    if ([string]::IsNullOrWhiteSpace($script:AtcDiagPath)) { return }

    try {
        [System.IO.File]::AppendAllText(
            $script:AtcDiagPath,
            ($line + [Environment]::NewLine),
            (New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false)
        )
    }
    catch {
        # Ein Diagnose-Schreibfehler darf das Setup nicht abbrechen.
    }
}

function Start-SetupLog {
    if (-not $LogFile) { return }

    $logDir = Join-Path $PSScriptRoot "logs"
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null

    # Bewusst ein fester Dateiname pro Rechner: Wiederholte Läufe nach Reboot
    # werden an dieselbe Datei angehängt.
    $script:LogPath = Join-Path $logDir ("Setup-NewCodexComputer-{0}.log" -f $env:COMPUTERNAME)

    Start-Transcript -Path $script:LogPath -Append -Force | Out-Null
    $script:TranscriptStarted = $true

    Write-Host ""
    Write-Host "LOGFILE AKTIV: $script:LogPath" -ForegroundColor Green
}

function Stop-SetupLog {
    if ($script:TranscriptStarted) {
        try { Stop-Transcript | Out-Null } catch {}
        $script:TranscriptStarted = $false
    }
}

trap {
    Write-Host ""
    Write-Host "SETUP-FEHLER" -ForegroundColor Red
    Write-Host "============"
    Write-Host $_.Exception.Message -ForegroundColor Red

    if ($_.InvocationInfo -and $_.InvocationInfo.PositionMessage) {
        Write-Host ""
        Write-Host $_.InvocationInfo.PositionMessage
    }

    if ($script:LogPath) {
        Write-Host ""
        Write-Host "Logfile: $script:LogPath" -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "Das Setup ist wiederholbar. Nach Behebung des Fehlers kann"
    Write-Host "Setup-NewCodexComputer erneut gestartet werden."

    Stop-SetupLog
    Read-Host "ENTER drücken, um dieses Fenster zu schließen"
    exit 1
}

function Step([string]$Text) {
    Write-Host ""
    Write-Host "==> $Text" -ForegroundColor Cyan
}

function Ask-YesNo([string]$Question, [bool]$DefaultYes = $true) {
    $suffix = if ($DefaultYes) { "[J/n]" } else { "[j/N]" }
    $answer = Read-Host "$Question $suffix"

    if ([string]::IsNullOrWhiteSpace($answer)) {
        $result = $DefaultYes
    } else {
        $result = ($answer -match '^[JjYy]')
    }

    Write-Host ("Auswahl: " + $(if ($result) { "Ja" } else { "Nein" }))
    return $result
}


function Test-DotNet11GaAvailable {
    $url = "https://dotnetcli.blob.core.windows.net/dotnet/release-metadata/11.0/releases.json"

    try {
        $response = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 10
        $data = $response.Content | ConvertFrom-Json
        $latest = [string]$data.'latest-release'

        if ($latest -match '^11\.0\.\d+$') {
            Write-Host ".NET $latest ist als stabiles GA-Release verfügbar." -ForegroundColor Green
            return $true
        }

        Write-Host ".NET 11 ist noch nicht als stabiles GA-Release verfügbar; Preview/RC werden nicht angeboten." -ForegroundColor Yellow
        return $false
    }
    catch {
        Write-Warning ".NET-11-Release-Status konnte nicht geprüft werden: $($_.Exception.Message)"
        Write-Host ".NET 11 wird in diesem Setup-Lauf vorsichtshalber nicht angeboten." -ForegroundColor Yellow
        return $false
    }
}

function Select-DevelopmentEnvironments {
    Step "Entwicklungsumgebungen auswählen"

    Write-Host "Die Auswahl wird in Dockerfile.codex eingebaut und überlebt Container-Rebuilds."
    Write-Host "sqlite3 wird als Basiswerkzeug immer installiert."
    Write-Host ""

    $installPhp = Ask-YesNo "PHP CLI + Composer + wichtige PHP-Module installieren?" $false
    $installCpp = Ask-YesNo "C/C++-Werkzeuge (GCC/G++, Make, CMake, GDB, Ninja, pkg-config) installieren?" $false
    $installPython = Ask-YesNo "Python 3 + pip + venv + pytest + Entwicklungswerkzeuge installieren?" $false

    $nodeVersion = "none"
    while ($true) {
        $answer = (Read-Host "Node.js auswählen: [0] keines  [20] Node.js 20  [22] Node.js 22  (Standard: 0)").Trim()
        if ([string]::IsNullOrWhiteSpace($answer) -or $answer -eq "0") {
            $nodeVersion = "none"
            break
        }
        if ($answer -eq "20" -or $answer -eq "22") {
            $nodeVersion = $answer
            break
        }
        Write-Host "Bitte 0, 20 oder 22 eingeben." -ForegroundColor Yellow
    }
    Write-Host ("Auswahl Node.js: " + $(if ($nodeVersion -eq "none") { "keines" } else { $nodeVersion }))

    $dotnet11Available = Test-DotNet11GaAvailable
    $dotnetVersion = "none"
    while ($true) {
        if ($dotnet11Available) {
            $answer = (Read-Host ".NET SDK auswählen: [0] keines  [10] .NET 10  [11] .NET 11  (Standard: 0)").Trim()
        } else {
            $answer = (Read-Host ".NET SDK auswählen: [0] keines  [10] .NET 10  (Standard: 0)").Trim()
        }

        if ([string]::IsNullOrWhiteSpace($answer) -or $answer -eq "0") {
            $dotnetVersion = "none"
            break
        }
        if ($answer -eq "10") {
            $dotnetVersion = "10"
            break
        }
        if ($answer -eq "11" -and $dotnet11Available) {
            $dotnetVersion = "11"
            break
        }

        if ($answer -eq "11" -and -not $dotnet11Available) {
            Write-Host ".NET 11 ist noch nicht als stabiles GA-Release freigegeben." -ForegroundColor Yellow
        } else {
            Write-Host ("Bitte " + $(if ($dotnet11Available) { "0, 10 oder 11" } else { "0 oder 10" }) + " eingeben.") -ForegroundColor Yellow
        }
    }
    Write-Host ("Auswahl .NET: " + $(if ($dotnetVersion -eq "none") { "keines" } else { $dotnetVersion }))

    Write-Host ""
    Write-Host "Gewählte Entwicklungsumgebungen:" -ForegroundColor Cyan
    Write-Host ("  PHP:     " + $(if ($installPhp) { "Ja" } else { "Nein" }))
    Write-Host ("  C/C++:   " + $(if ($installCpp) { "Ja" } else { "Nein" }))
    Write-Host ("  Python:  " + $(if ($installPython) { "Ja" } else { "Nein" }))
    Write-Host ("  Node.js: " + $(if ($nodeVersion -eq "none") { "Nein" } else { $nodeVersion }))
    Write-Host ("  .NET:    " + $(if ($dotnetVersion -eq "none") { "Nein" } else { $dotnetVersion }))

    return [pscustomobject]@{
        Php = $installPhp
        Cpp = $installCpp
        Python = $installPython
        NodeVersion = $nodeVersion
        DotNetVersion = $dotnetVersion
    }
}

function Get-ManagedDockerfileContent {
    return @'
# Managed by Codex Mount Manager
# Änderungen an den CODEX_* Build-Argumenten erfolgen über das Setup oder die VS-Code-Erweiterung.
ARG CODEX_BASE_IMAGE=mcr.microsoft.com/devcontainers/base:ubuntu-24.04
FROM ${CODEX_BASE_IMAGE}

ARG CODEX_INSTALL_PHP=false
ARG CODEX_INSTALL_CPP=false
ARG CODEX_INSTALL_PYTHON=false
ARG CODEX_NODE_VERSION=none
ARG CODEX_DOTNET_VERSION=none

ARG DEBIAN_FRONTEND=noninteractive
ENV DOTNET_ROOT=/usr/local/share/dotnet
ENV PATH="/usr/local/share/dotnet:${PATH}"

USER root

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl gnupg sqlite3; \
    if [ "${CODEX_INSTALL_CPP}" = "true" ]; then \
      apt-get install -y --no-install-recommends build-essential cmake gdb ninja-build pkg-config; \
    fi; \
    if [ "${CODEX_INSTALL_PYTHON}" = "true" ]; then \
      apt-get install -y --no-install-recommends python3 python3-pip python3-venv python3-pytest python3-dev python3-setuptools python3-wheel pipx; \
    fi; \
    if [ "${CODEX_INSTALL_PHP}" = "true" ]; then \
      apt-get install -y --no-install-recommends php-cli php-common php-curl php-mbstring php-xml php-zip php-intl php-bcmath php-gd php-sqlite3 php-mysql php-pgsql php-soap composer zip unzip; \
      if ! php -v 2>&1 | grep -q "Zend OPcache"; then \
        php_mm="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')"; \
        if apt-cache show "php${php_mm}-opcache" >/dev/null 2>&1; then apt-get install -y --no-install-recommends "php${php_mm}-opcache"; fi; \
      fi; \
    fi; \
    if [ "${CODEX_NODE_VERSION}" != "none" ]; then \
      mkdir -p /etc/apt/keyrings; \
      curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor --batch --yes -o /etc/apt/keyrings/nodesource.gpg; \
      echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${CODEX_NODE_VERSION}.x nodistro main" > /etc/apt/sources.list.d/nodesource.list; \
      printf 'Package: nodejs\nPin: origin deb.nodesource.com\nPin-Priority: 1001\n' > /etc/apt/preferences.d/nodejs; \
      apt-get update; \
      apt-get install -y --no-install-recommends --allow-downgrades nodejs; \
    fi; \
    if [ "${CODEX_DOTNET_VERSION}" != "none" ]; then \
      apt-get install -y --no-install-recommends libicu-dev libssl-dev zlib1g libgssapi-krb5-2; \
      curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh; \
      chmod +x /tmp/dotnet-install.sh; \
      /tmp/dotnet-install.sh --channel "${CODEX_DOTNET_VERSION}.0" --quality GA --install-dir /usr/local/share/dotnet; \
      ln -sf /usr/local/share/dotnet/dotnet /usr/local/bin/dotnet; \
      rm -f /tmp/dotnet-install.sh; \
    fi; \
    mkdir -p /home/vscode/.vscode-server/extensions; \
    chown -R vscode:vscode /home/vscode/.vscode-server; \
    rm -rf /var/lib/apt/lists/*
'@
}

function Is-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Quote-Argument([string]$Value) {
    if ($Value -notmatch '[\s"]') { return $Value }
    return '"' + ($Value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}


function Normalize-NativeOutput([string]$Text) {
    if ($null -eq $Text) {
        return ""
    }

    $clean = [string]$Text

    # wsl.exe can be captured by Windows PowerShell 5.1 with NUL characters
    # between visible characters (UTF-16-style output). Remove them before
    # any regex/text comparison.
    $clean = $clean -replace [char]0, ""

    # Remove BOM / zero-width no-break space if present.
    $clean = $clean -replace [char]0xFEFF, ""

    return $clean
}

function Invoke-Probe {
    param(
        [Parameter(Mandatory=$true)][string]$FilePath,
        [string[]]$Arguments = @()
    )

    $outFile = [IO.Path]::GetTempFileName()
    $errFile = [IO.Path]::GetTempFileName()

    try {
        $argLine = ($Arguments | ForEach-Object { Quote-Argument ([string]$_) }) -join " "

        try {
            $p = Start-Process `
                -FilePath $FilePath `
                -ArgumentList $argLine `
                -Wait `
                -PassThru `
                -NoNewWindow `
                -RedirectStandardOutput $outFile `
                -RedirectStandardError $errFile `
                -ErrorAction Stop

            $exitCode = $p.ExitCode
        }
        catch {
            return [pscustomobject]@{
                ExitCode = -9999
                StdOut = ""
                StdErr = $_.Exception.Message
            }
        }

        $stdout = ""
        $stderr = ""

        if (Test-Path -LiteralPath $outFile) {
            $stdout = [IO.File]::ReadAllText($outFile)
        }
        if (Test-Path -LiteralPath $errFile) {
            $stderr = [IO.File]::ReadAllText($errFile)
        }

        return [pscustomobject]@{
            ExitCode = $exitCode
            StdOut = (Normalize-NativeOutput $stdout).Trim()
            StdErr = (Normalize-NativeOutput $stderr).Trim()
        }
    }
    finally {
        Remove-Item -LiteralPath $outFile,$errFile -Force -ErrorAction SilentlyContinue
    }
}

function Show-ProbeFailure([string]$Title, $Probe) {
    Write-Host ""
    Write-Host "$Title (Exitcode $($Probe.ExitCode))" -ForegroundColor Yellow
    if ($Probe.StdOut) {
        Write-Host "--- stdout ---"
        Write-Host $Probe.StdOut
    }
    if ($Probe.StdErr) {
        Write-Host "--- stderr ---"
        Write-Host $Probe.StdErr
    }
}



function Ensure-WslWindowsFeatures {
    Step "Windows-WSL-Komponenten prüfen"

    $requiredFeatures = @(
        "Microsoft-Windows-Subsystem-Linux",
        "VirtualMachinePlatform"
    )

    $disabled = @()

    foreach ($featureName in $requiredFeatures) {
        try {
            $feature = Get-WindowsOptionalFeature `
                -Online `
                -FeatureName $featureName `
                -ErrorAction Stop

            Write-Host ("{0}: {1}" -f $featureName, $feature.State)

            if ($feature.State -ne "Enabled") {
                $disabled += $featureName
            }
        }
        catch {
            throw "Windows-Feature '$featureName' konnte nicht geprüft werden: $($_.Exception.Message)"
        }
    }

    if ($disabled.Count -eq 0) {
        Write-Host "Alle für WSL2 benötigten Windows-Komponenten sind aktiviert." -ForegroundColor Green
        return $false
    }

    Write-Host ""
    Write-Host "Folgende für WSL2 benötigte Windows-Komponenten sind noch nicht aktiviert:" -ForegroundColor Yellow
    foreach ($featureName in $disabled) {
        Write-Host "  $featureName"
    }

    Write-Host ""
    Write-Host "Die fehlenden Windows-Komponenten werden jetzt aktiviert."

    $restartRequired = $false

    foreach ($featureName in $disabled) {
        Write-Host "Aktiviere: $featureName"

        try {
            $result = Enable-WindowsOptionalFeature `
                -Online `
                -FeatureName $featureName `
                -All `
                -NoRestart `
                -ErrorAction Stop

            if ($result.RestartNeeded) {
                $restartRequired = $true
            }
        }
        catch {
            throw "Windows-Feature '$featureName' konnte nicht aktiviert werden: $($_.Exception.Message)"
        }
    }

    # Nach einer erstmaligen Feature-Aktivierung ist ein Neustart die sichere
    # Variante, auch wenn ein einzelner Cmdlet-Returnwert RestartNeeded=False
    # meldet. WSL/VirtualMachinePlatform werden erst nach dem Boot vollständig
    # verfügbar.
    $restartRequired = $true

    Write-Host ""
    Write-Host "Die WSL-Windows-Komponenten wurden aktiviert." -ForegroundColor Green
    Write-Host ""
    Write-Host "WINDOWS-NEUSTART ERFORDERLICH" -ForegroundColor Yellow
    Write-Host "============================"
    Write-Host ""
    Write-Host "Nach dem Neustart dasselbe Setup erneut starten."
    Write-Host "Bereits erledigte Schritte werden automatisch erkannt und übersprungen."
    Write-Host ""

    Stop-SetupLog
    [void](Read-Host "ENTER drücken; anschließend Windows neu starten")
    exit 11
}

function Normalize-WslDistroName([string]$Name) {
    if ($null -eq $Name) { return "" }

    # WSL-Ausgaben können unter Windows PowerShell 5.1 unsichtbare NUL-,
    # BOM- oder andere Steuerzeichen enthalten. Diese müssen VOR jedem
    # Vergleich entfernt werden.
    $clean = [string]$Name
    $clean = $clean -replace "`0", ""
    $clean = $clean -replace [char]0xFEFF, ""
    $clean = $clean -replace '[\x00-\x1F\x7F]', ''
    $clean = $clean.Trim()

    # Bei manchen Darstellungen kann ein Default-Marker mitkommen.
    if ($clean.StartsWith("*")) {
        $clean = $clean.Substring(1).Trim()
    }

    return $clean
}

function Test-SystemWslDistro([string]$Name) {
    $clean = Normalize-WslDistroName $Name
    if ([string]::IsNullOrWhiteSpace($clean)) { return $true }

    $lower = $clean.ToLowerInvariant()

    # Harte Ausschlussliste für von Container-Runtimes verwaltete
    # Hilfsdistributionen. Diese dürfen NIEMALS als Arbeits-WSL ausgewählt
    # oder per wsl --terminate "aufgeräumt" werden.
    $exactSystemDistros = @(
        "docker-desktop",
        "docker-desktop-data",
        "rancher-desktop",
        "rancher-desktop-data",
        "podman-machine-default"
    )

    if ($exactSystemDistros -contains $lower) {
        return $true
    }

    # Zusätzlich typische runtime-generierte Namen abfangen.
    if (
        $lower.StartsWith("docker-desktop-") -or
        $lower.StartsWith("rancher-desktop-") -or
        $lower.StartsWith("podman-machine-")
    ) {
        return $true
    }

    return $false
}

$script:WslRunningQuerySupported = $null

function Get-WslInstalledDistroNamesFromRegistry {
    $base = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss"
    $names = @()

    if (-not (Test-Path -LiteralPath $base)) {
        return @()
    }

    foreach ($key in @(Get-ChildItem -LiteralPath $base -ErrorAction SilentlyContinue)) {
        try {
            $p = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop
            $name = Normalize-WslDistroName ([string]$p.DistributionName)

            if ([string]::IsNullOrWhiteSpace($name)) {
                continue
            }

            if (Test-SystemWslDistro $name) {
                continue
            }

            if ($names -notcontains $name) {
                $names += $name
            }
        }
        catch {
            # Defekte/unvollständige Registry-Einträge ignorieren.
        }
    }

    return @($names)
}

function Get-WslDistroNames([switch]$RunningOnly) {
    $wsl = "$env:WINDIR\System32\wsl.exe"
    if (-not (Test-Path -LiteralPath $wsl)) {
        if ($RunningOnly) {
            $script:WslRunningQuerySupported = $false
        }
        return @()
    }

    # Installierte Distributionen werden nicht aus frei formatiertem
    # wsl.exe-Text geparst. Alte Inbox-Versionen von WSL geben bei unbekannten
    # Optionen die komplette Hilfe aus, teilweise sogar mit Exitcode 0.
    # Die Registry liefert die registrierten Distributionen sprachneutral.
    $installed = @(Get-WslInstalledDistroNamesFromRegistry)

    if (-not $RunningOnly) {
        return @($installed)
    }

    if ($installed.Count -eq 0) {
        # Es gibt keine normale registrierte Distribution. Damit ist auch
        # keine normale Distribution aktiv.
        $script:WslRunningQuerySupported = $true
        return @()
    }

    $probe = Invoke-Probe $wsl @("--list","--quiet","--running")

    if ($probe.ExitCode -ne 0) {
        $script:WslRunningQuerySupported = $false
        return @()
    }

    $normalizedWslList = Normalize-NativeOutput $probe.StdOut
    $rawLines = @(($normalizedWslList -split "`r?`n"))
    $running = @()
    $unexpectedText = $false

    foreach ($line in $rawLines) {
        $name = Normalize-WslDistroName ([string]$line)

        if ([string]::IsNullOrWhiteSpace($name)) {
            continue
        }

        # Docker Desktop & Co. dürfen auftauchen, zählen aber nicht.
        if (Test-SystemWslDistro $name) {
            continue
        }

        # Nur Namen akzeptieren, die wirklich als WSL-Distro registriert sind.
        # Hilfe-/Copyright-/Usage-Zeilen können dadurch niemals durchrutschen.
        if ($installed -contains $name) {
            if ($running -notcontains $name) {
                $running += $name
            }
            continue
        }

        $unexpectedText = $true
    }

    if ($unexpectedText) {
        # Die vorhandene wsl.exe versteht die moderne Query offenbar noch nicht.
        $script:WslRunningQuerySupported = $false
        return @()
    }

    $script:WslRunningQuerySupported = $true
    return @($running)
}

function Show-WslDistros {
    $installed = @(Get-WslDistroNames)
    $running = @(Get-WslDistroNames -RunningOnly)

    Write-Host ""
    Write-Host "Normale installierte WSL-Distributionen:"

    if ($installed.Count -eq 0) {
        Write-Host "  keine"
    } else {
        foreach ($d in $installed) {
            if ($script:WslRunningQuerySupported -eq $false) {
                $state = "Status unbekannt (alte WSL-Version)"
            } else {
                $state = if ($running -contains $d) { "RUNNING" } else { "stopped" }
            }
            Write-Host ("  {0,-30} {1}" -f $d,$state)
        }
    }

    if ($script:WslRunningQuerySupported -eq $false) {
        Write-Host ""
        Write-Host "Hinweis: Die vorhandene wsl.exe unterstützt die moderne Statusabfrage"
        Write-Host "noch nicht. Es werden deshalb KEINE Hilfezeilen als Distributionen interpretiert."
    }

    Write-Host ""
    Write-Host "Runtime-Hilfsdistributionen wie docker-desktop werden getrennt behandelt"
    Write-Host "und NIEMALS für Auswahl oder WSL-Aufräumen berücksichtigt."
}

function Select-WslDistroInteractive(
    [string[]]$Distros,
    [string]$Question
) {
    if (-not $Distros -or $Distros.Count -eq 0) {
        return $null
    }

    if ($Distros.Count -eq 1) {
        return $Distros[0]
    }

    Write-Host ""
    Write-Host $Question -ForegroundColor Yellow

    for ($i = 0; $i -lt $Distros.Count; $i++) {
        Write-Host ("  [{0}] {1}" -f ($i + 1),$Distros[$i])
    }

    while ($true) {
        $answer = Read-Host "Nummer der WSL-Distribution"

        $n = 0
        if ([int]::TryParse($answer,[ref]$n)) {
            if ($n -ge 1 -and $n -le $Distros.Count) {
                $selected = $Distros[$n - 1]
                Write-Host "Ausgewählt: $selected"
                return $selected
            }
        }

        Write-Warning "Bitte eine Zahl zwischen 1 und $($Distros.Count) eingeben."
    }
}

function Resolve-WorkingWslDistro([string]$PreferredDistro) {
    [void](Ensure-WslWindowsFeatures)

Step "Vorhandene WSL-Distributionen prüfen"

    Show-WslDistros

    $installed = @(Get-WslDistroNames)
    $running = @(Get-WslDistroNames -RunningOnly)

    # Bei Wiederholungsläufen ist eine explizit übergebene bzw. aus den
    # bestehenden VS-Code-Einstellungen erkannte Distro maßgeblich. Dadurch
    # wird nicht erneut nach der Arbeits-Distro gefragt, nur weil weitere
    # Distros installiert sind.
    if (
        -not [string]::IsNullOrWhiteSpace($PreferredDistro) -and
        $installed -contains $PreferredDistro
    ) {
        $selected = $PreferredDistro
        Write-Host ""
        Write-Host "Bereits konfigurierte WSL-Distribution wird weiterverwendet: $selected" -ForegroundColor Green

        $others = @(
            $running |
                Where-Object { $_ -ne $selected } |
                Where-Object { -not (Test-SystemWslDistro $_) }
        )

        if ($others.Count -eq 0) {
            return $selected
        }

        Write-Host "Zusätzlich aktive normale WSL-Distributionen:"
        foreach ($d in $others) {
            Write-Host "  $d"
        }

        if (-not (Ask-YesNo "Andere aktive normale WSL-Distributionen jetzt mit 'wsl --terminate' beenden?" $true)) {
            throw "Mehrere aktive normale WSL-Distributionen. Setup wird vor weiteren Änderungen beendet."
        }

        foreach ($d in $others) {
            Write-Host "Beende normale WSL-Distribution: $d"
            & "$env:WINDIR\System32\wsl.exe" --terminate $d
            if ($LASTEXITCODE -ne 0) {
                throw "WSL-Distribution '$d' konnte nicht beendet werden."
            }
        }

        return $selected
    }

    if ($running.Count -eq 1) {
        $selected = $running[0]
        Write-Host ""
        Write-Host "Genau eine aktive WSL-Distribution gefunden: $selected" -ForegroundColor Green
        Write-Host "Diese Distribution wird für Dev Containers verwendet."
        return $selected
    }

    if ($running.Count -gt 1) {
        Write-Host ""
        Write-Warning "Mehrere aktive WSL-Distributionen gefunden."
        Write-Host "Vor dem Codex-/Dev-Container-Setup muss hier aufgeräumt werden."

        $selected = Select-WslDistroInteractive `
            $running `
            "Welche aktive WSL-Distribution soll für Codex/Dev Containers weiterlaufen?"

        if (Test-SystemWslDistro $selected) {
            throw "Interner Schutz: Runtime-Hilfsdistribution '$selected' darf nicht ausgewählt werden."
        }

        # Zweite Schutzschicht: selbst wenn eine Runtime-Distro durch eine
        # ungewöhnliche WSL-Ausgabe in $running geraten sollte, wird sie hier
        # nochmals explizit ausgeschlossen.
        $others = @(
            $running |
                Where-Object { $_ -ne $selected } |
                Where-Object { -not (Test-SystemWslDistro $_) }
        )

        Write-Host ""
        Write-Host "Beibehalten:"
        Write-Host "  $selected"

        if ($others.Count -eq 0) {
            Write-Host "Keine weitere normale WSL-Distribution muss beendet werden."
            return $selected
        }

        Write-Host "Diese aktiven normalen WSL-Distributionen würden nur beendet (NICHT gelöscht):"
        foreach ($d in $others) {
            Write-Host "  $d"
        }

        Write-Host ""
        Write-Host "Docker-Desktop-Hilfsdistributionen werden hierbei grundsätzlich NICHT beendet."

        if (-not (Ask-YesNo "Andere aktive normale WSL-Distributionen jetzt mit 'wsl --terminate' beenden?" $true)) {
            throw "Mehrere aktive normale WSL-Distributionen. Setup wird vor weiteren Änderungen beendet."
        }

        foreach ($d in $others) {
            if (Test-SystemWslDistro $d) {
                throw "Sicherheitsabbruch: Runtime-Hilfsdistribution '$d' sollte beendet werden."
            }

            Write-Host "Beende normale WSL-Distribution: $d"
            & "$env:WINDIR\System32\wsl.exe" --terminate $d
            if ($LASTEXITCODE -ne 0) {
                throw "WSL-Distribution '$d' konnte nicht beendet werden."
            }
        }

        Start-Sleep -Seconds 2

        $stillRunning = @(Get-WslDistroNames -RunningOnly)
        $unexpected = @($stillRunning | Where-Object { $_ -ne $selected })

        if ($unexpected.Count -gt 0) {
            throw "WSL-Aufräumen fehlgeschlagen. Weiterhin zusätzlich aktiv: $($unexpected -join ', ')"
        }

        Write-Host "WSL-Aufräumen abgeschlossen." -ForegroundColor Green
        return $selected
    }

    if ($installed.Count -eq 1) {
        $selected = $installed[0]
        Write-Host ""

        if ($script:WslRunningQuerySupported -eq $false) {
            Write-Host "Aktivstatus konnte mit der vorhandenen alten WSL-Version noch nicht bestimmt werden."
        } else {
            Write-Host "Keine WSL-Distribution läuft derzeit."
        }

        Write-Host "Genau eine normale Distribution ist installiert: $selected"
        Write-Host "Diese wird verwendet."
        return $selected
    }

    if ($installed.Count -gt 1) {
        $question = if ($script:WslRunningQuerySupported -eq $false) {
            "Mehrere WSL-Distributionen sind installiert. Die alte WSL-Version kann deren Aktivstatus noch nicht sicher liefern. Welche soll für Codex verwendet werden?"
        } else {
            "Mehrere WSL-Distributionen sind installiert, aber keine ist aktiv. Welche soll verwendet werden?"
        }

        $selected = Select-WslDistroInteractive $installed $question
        return $selected
    }

    if (-not [string]::IsNullOrWhiteSpace($PreferredDistro)) {
        Write-Host ""
        Write-Host "Keine normale WSL-Distribution gefunden."
        Write-Host "Explizit gewünschte Distribution wird installiert/verwendet: $PreferredDistro"
        return $PreferredDistro
    }

    Write-Host ""
    Write-Host "Keine normale WSL-Distribution gefunden."
    Write-Host "Als Fallback wird Ubuntu-24.04 neu installiert."
    return "Ubuntu-24.04"
}

function Test-WingetPackageInstalled([string]$Id) {
    switch ($Id) {
        "Docker.DockerDesktop" {
            if (Test-Path -LiteralPath "$env:ProgramFiles\Docker\Docker\Docker Desktop.exe") { return $true }
        }
        "Microsoft.VisualStudioCode" {
            if (
                (Test-Path -LiteralPath "$env:LOCALAPPDATA\Programs\Microsoft VS Code\Code.exe") -or
                (Test-Path -LiteralPath "$env:ProgramFiles\Microsoft VS Code\Code.exe")
            ) { return $true }
        }
        "Git.Git" {
            if (
                (Get-Command git.exe -ErrorAction SilentlyContinue) -or
                (Test-Path -LiteralPath "$env:ProgramFiles\Git\cmd\git.exe")
            ) { return $true }
        }
    }

    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $winget) { return $false }

    $probe = Invoke-Probe $winget.Source @("list","--id",$Id,"--exact","--accept-source-agreements")
    return ($probe.ExitCode -eq 0 -and (($probe.StdOut + "`n" + $probe.StdErr) -match [regex]::Escape($Id)))
}

function Ensure-WingetPackage([string]$Id, [string]$Name) {
    if (Test-WingetPackageInstalled $Id) {
        Write-Host "$Name ist bereits installiert."
        return $false
    }

    Write-Host "$Name wird per winget installiert..."
    winget install --id $Id --exact --silent --accept-package-agreements --accept-source-agreements
    $installExit = $LASTEXITCODE

    Start-Sleep -Seconds 2

    if (Test-WingetPackageInstalled $Id) {
        if ($installExit -ne 0) {
            Write-Warning "$Name wurde installiert; winget meldete Exitcode $installExit."
        } else {
            Write-Host "$Name wurde installiert."
        }
        return $true
    }

    throw "Installation von $Name fehlgeschlagen (winget Exitcode $installExit)."
}

function Test-ModernWslAvailable {
    $wslExe = "$env:WINDIR\System32\wsl.exe"

    if (-not (Test-Path -LiteralPath $wslExe)) {
        return [pscustomobject]@{
            Available = $false
            Output    = "wsl.exe fehlt"
        }
    }

    $probe = Invoke-Probe $wslExe @("--version")
    $combined = Normalize-NativeOutput ((($probe.StdOut + "`n" + $probe.StdErr) | Out-String).Trim())

    # Moderne Store/MSIX-Versionen liefern mindestens eine dieser Angaben.
    $modern = (
        $probe.ExitCode -eq 0 -and (
            $combined -match "(?i)WSL[- ]?Version\s*:" -or
            $combined -match "(?i)Kernelversion\s*:" -or
            $combined -match "(?i)Kernel version\s*:"
        )
    )

    return [pscustomobject]@{
        Available = $modern
        Output    = $combined
    }
}

function Ensure-ModernWsl([string]$WingetPath) {
    Step "Aktuelle WSL-Version sicherstellen"

    $initial = Test-ModernWslAvailable

    if ($initial.Available) {
        Write-Host "Moderne WSL-Version ist bereits aktiv." -ForegroundColor Green
        if ($initial.Output) {
            ($initial.Output -split "`r?`n" | Select-Object -First 2) | ForEach-Object {
                Write-Host "  $_"
            }
        }
        $script:WslRunningQuerySupported = $null
        return $false
    }

    if (
        $initial.Output -match "WSL_E_WSL_OPTIONAL_COMPONENT_REQUIRED" -or
        $initial.Output -match "optionale Komponente" -or
        $initial.Output -match "optional component"
    ) {
        throw @"
wsl.exe ist installiert, aber die Windows-WSL-Komponenten sind noch nicht aktiv.

Das Setup hat die Features bereits geprüft/aktiviert. Falls sie gerade erst
aktiviert wurden, Windows neu starten und danach das Setup erneut ausführen.
"@
    }

    Write-Host "Moderne WSL-Version ist noch nicht aktiv."
    Write-Host "Installiere/aktualisiere Microsoft.WSL über winget..."

    & $WingetPath install `
        --id Microsoft.WSL `
        --exact `
        --silent `
        --accept-package-agreements `
        --accept-source-agreements

    $installExit = $LASTEXITCODE

    Write-Host ""
    Write-Host "Warte darauf, dass die neue WSL-Version verfügbar wird..."

    $modern = $null

    for ($i = 1; $i -le 15; $i++) {
        Start-Sleep -Seconds 2

        $modern = Test-ModernWslAvailable

        if ($modern.Available) {
            Write-Host "Moderne WSL-Version ist jetzt aktiv." -ForegroundColor Green
            if ($modern.Output) {
                ($modern.Output -split "`r?`n" | Select-Object -First 3) | ForEach-Object {
                    Write-Host "  $_"
                }
            }

            if ($installExit -ne 0) {
                Write-Warning "winget meldete Exitcode $installExit, WSL ist anschließend aber korrekt verfügbar."
            }

            $script:WslRunningQuerySupported = $null
            return $true
        }

        Write-Host ("  Versuch {0}/15: noch nicht verfügbar..." -f $i)
    }

    # Ein einmaliger WSL-Reset kann nach einem MSIX/Store-Update helfen,
    # ohne dass Windows neu gestartet werden muss.
    Write-Host ""
    Write-Host "WSL ist noch nicht sichtbar. Führe einmal 'wsl --shutdown' aus und prüfe erneut..."
    & "$env:WINDIR\System32\wsl.exe" --shutdown 2>$null
    Start-Sleep -Seconds 3

    $modern = Test-ModernWslAvailable

    if ($modern.Available) {
        Write-Host "Moderne WSL-Version ist nach dem WSL-Neustart aktiv." -ForegroundColor Green
        $script:WslRunningQuerySupported = $null
        return $true
    }

    Write-Host ""
    Write-Host "WSL wurde installiert/aktualisiert, ist aber nach ca. 30 Sekunden" -ForegroundColor Yellow
    Write-Host "und einem WSL-Neustart noch nicht als moderne Version sichtbar." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "JETZT ist ein Windows-Neustart sinnvoll."
    Write-Host "Nach dem Neustart dasselbe Setup erneut starten."
    Write-Host ""

    if ($modern.Output) {
        Write-Host "Letzte WSL-Ausgabe:"
        Write-Host $modern.Output
        Write-Host ""
    }

    Stop-SetupLog
    [void](Read-Host "ENTER drücken; anschließend Windows neu starten")
    exit 12
}

function Get-Code {
    foreach ($name in @("code.cmd","code")) {
        $c = Get-Command $name -ErrorAction SilentlyContinue
        if ($c) { return $c.Source }
    }

    foreach ($p in @(
        "$env:LOCALAPPDATA\Programs\Microsoft VS Code\bin\code.cmd",
        "$env:ProgramFiles\Microsoft VS Code\bin\code.cmd"
    )) {
        if (Test-Path -LiteralPath $p) { return $p }
    }

    throw "VS-Code-CLI wurde nicht gefunden."
}

function Get-InstalledVsCodeExtensionVersions {
    $result = @{}
    $roots = @()

    if (-not [string]::IsNullOrWhiteSpace($env:VSCODE_EXTENSIONS)) {
        $roots += $env:VSCODE_EXTENSIONS
    }
    $roots += (Join-Path $env:USERPROFILE ".vscode\extensions")

    foreach ($extensionRoot in ($roots | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $extensionRoot -PathType Container)) { continue }

        foreach ($dir in @(Get-ChildItem -LiteralPath $extensionRoot -Directory -ErrorAction SilentlyContinue)) {
            $packageJson = Join-Path $dir.FullName "package.json"
            if (-not (Test-Path -LiteralPath $packageJson -PathType Leaf)) { continue }

            try {
                $pkg = ([System.IO.File]::ReadAllText($packageJson, [System.Text.Encoding]::UTF8) | ConvertFrom-Json)
                if (-not $pkg.publisher -or -not $pkg.name) { continue }

                $id = (("{0}.{1}" -f $pkg.publisher, $pkg.name).ToLowerInvariant())
                $version = if ($pkg.version) { [string]$pkg.version } else { "" }

                if (-not $result.ContainsKey($id)) {
                    $result[$id] = $version
                }
                else {
                    try {
                        if ([version]$version -gt [version]($result[$id])) { $result[$id] = $version }
                    }
                    catch {
                        if ($version -gt $result[$id]) { $result[$id] = $version }
                    }
                }
            }
            catch {
                # Eine defekte/teilweise Extension darf die Bestandsaufnahme nicht blockieren.
            }
        }
    }

    return $result
}

function Get-Docker {
    $c = Get-Command docker.exe -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }

    foreach ($p in @(
        "$env:ProgramFiles\Docker\Docker\resources\bin\docker.exe",
        "$env:ProgramFiles\Docker\Docker\resources\docker.exe"
    )) {
        if (Test-Path -LiteralPath $p) { return $p }
    }

    throw "docker.exe wurde nicht gefunden."
}

function Test-DockerReady([string]$Docker) {
    $probe = Invoke-Probe $Docker @("info")
    return ($probe.ExitCode -eq 0)
}

function Test-WslDockerReady([string]$Distro) {
    $probe = Invoke-Probe "$env:WINDIR\System32\wsl.exe" @("-d",$Distro,"--","docker","version")
    return ($probe.ExitCode -eq 0)
}

function Get-WindowsDockerEngineId([string]$Docker) {
    $probe = Invoke-Probe $Docker @("info","--format","{{.ID}}")
    if ($probe.ExitCode -eq 0) {
        return $probe.StdOut.Trim()
    }
    return $null
}

function Get-WslDockerEngineId([string]$Distro) {
    $probe = Invoke-Probe "$env:WINDIR\System32\wsl.exe" @(
        "-d",$Distro,"--","docker","info","--format","{{.ID}}"
    )

    if ($probe.ExitCode -eq 0) {
        return $probe.StdOut.Trim()
    }

    return $null
}

function Test-SameDockerBackend([string]$Docker, [string]$Distro) {
    $winId = Get-WindowsDockerEngineId $Docker
    $wslId = Get-WslDockerEngineId $Distro

    Write-Host "Docker Engine-ID Windows: $winId"
    Write-Host "Docker Engine-ID $Distro`: $wslId"

    if (-not $winId -or -not $wslId) {
        return $false
    }

    return ($winId -eq $wslId)
}

function Wait-DockerReady([string]$Docker, [int]$Seconds = 300) {
    $deadline = (Get-Date).AddSeconds($Seconds)

    while ((Get-Date) -lt $deadline) {
        if (Test-DockerReady $Docker) { return $true }
        Start-Sleep -Seconds 5
    }

    return $false
}

function Wait-WslDockerReady([string]$Distro, [int]$Seconds = 120) {
    $deadline = (Get-Date).AddSeconds($Seconds)

    while ((Get-Date) -lt $deadline) {
        if (Test-WslDockerReady $Distro) { return $true }
        Start-Sleep -Seconds 5
    }

    return $false
}

function Stop-DockerDesktopCleanly([string]$Docker) {
    Write-Host "Docker Desktop wird beendet..."

    # Neuere Docker-Desktop-Versionen haben 'docker desktop stop'.
    $probe = Invoke-Probe $Docker @("desktop","stop")

    if ($probe.ExitCode -ne 0) {
        Write-Host "'docker desktop stop' war nicht verfügbar/erfolgreich; Prozess-Fallback wird verwendet."

        @("Docker Desktop","com.docker.backend") | ForEach-Object {
            Get-Process -Name $_ -ErrorAction SilentlyContinue |
                Stop-Process -Force -ErrorAction SilentlyContinue
        }
    }

    Start-Sleep -Seconds 5
}

function Start-DockerDesktopAndWait([string]$Docker, [string]$DockerDesktopExe) {
    if (-not (Test-Path -LiteralPath $DockerDesktopExe)) {
        throw "Docker Desktop.exe wurde nicht gefunden: $DockerDesktopExe"
    }

    # ATC-Hotfix 1.0.1: Docker Desktop bewusst NICHT aus PowerShell starten.
    # Bei einer ATC-Remediation können neben dem Setup auch beteiligte
    # Docker-Desktop-Datendateien quarantänisiert werden. Ein manueller Start
    # trennt den langlebigen Docker-Desktop-Prozess vom PowerShell-Prozessbaum.
    Write-AtcCheckpoint "Docker Engine nicht bereit; manueller Docker-Desktop-Start erforderlich"
    Write-Host "Docker Desktop läuft noch nicht." -ForegroundColor Yellow
    Write-Host "ATC-Mitigation: Docker Desktop bitte jetzt MANUELL starten." -ForegroundColor Yellow
    Write-Host "Das Setup startet Docker Desktop absichtlich nicht mehr als PowerShell-Kindprozess."
    [void](Read-Host "Wenn Docker Desktop gestartet ist, ENTER drücken")

    Write-Host "Warte auf Docker Engine..."
    if (-not (Wait-DockerReady $Docker 300)) {
        $probe = Invoke-Probe $Docker @("info")
        Show-ProbeFailure "Docker Engine wurde nicht bereit" $probe
        return $false
    }

    Write-AtcCheckpoint "Docker Engine nach manuellem Start bereit"
    Write-Host "Docker Engine läuft."
    return $true
}

function Repair-DockerWslIntegration([string]$Docker, [string]$DockerDesktopExe, [string]$Distro) {
    Step "Docker-/WSL-Integration neu initialisieren"

    Stop-DockerDesktopCleanly $Docker

    Write-Host "WSL wird vollständig beendet: wsl --shutdown"
    $shutdown = Invoke-Probe "$env:WINDIR\System32\wsl.exe" @("--shutdown")
    if ($shutdown.ExitCode -ne 0) {
        Show-ProbeFailure "wsl --shutdown meldete einen Fehler" $shutdown
    }

    Start-Sleep -Seconds 3

    if (-not (Start-DockerDesktopAndWait $Docker $DockerDesktopExe)) {
        return $false
    }

    Write-Host "Warte auf Docker-Integration in $Distro..."
    if (Wait-WslDockerReady $Distro 120) {
        Write-Host "Docker-WSL-Integration funktioniert." -ForegroundColor Green
        return $true
    }

    $probe = Invoke-Probe "$env:WINDIR\System32\wsl.exe" @("-d",$Distro,"--","docker","version")
    Show-ProbeFailure "Docker ist in $Distro weiterhin nicht erreichbar" $probe
    return $false
}

function Normalize-ComparablePath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }

    $p = $Path.Trim().Trim('"')

    if ($p.StartsWith("\\?\")) {
        $p = $p.Substring(4)
    }

    # Falls ein Dev-Containers-Build den Hostpfad als WSL-Pfad labelt.
    if ($p -match '^/mnt/([A-Za-z])/(.*)$') {
        $drive = $Matches[1].ToUpperInvariant()
        $rest = $Matches[2] -replace '/', '\'
        $p = "${drive}:\$rest"
    } else {
        $p = $p -replace '/', '\'
    }

    try {
        return [IO.Path]::GetFullPath($p).TrimEnd('\').ToLowerInvariant()
    }
    catch {
        return $p.TrimEnd('\').ToLowerInvariant()
    }
}

function Get-DockerContainers([string]$Docker) {
    $probe = Invoke-Probe $Docker @("ps","-a","--format","{{.ID}}")

    if ($probe.ExitCode -ne 0) {
        Show-ProbeFailure "docker ps -a fehlgeschlagen" $probe
        return @()
    }

    $ids = @($probe.StdOut -split "`r?`n" | Where-Object { $_ })

    $result = @()

    foreach ($id in $ids) {
        $inspect = Invoke-Probe $Docker @("inspect",$id)

        if ($inspect.ExitCode -ne 0 -or -not $inspect.StdOut) {
            continue
        }

        try {
            $data = @($inspect.StdOut | ConvertFrom-Json)[0]
        }
        catch {
            Write-Warning "docker inspect für $id konnte nicht als JSON gelesen werden."
            continue
        }

        $labels = $data.Config.Labels
        $localFolder = $null
        $configFile = $null

        if ($labels) {
            $localFolder = $labels.'devcontainer.local_folder'
            $configFile = $labels.'devcontainer.config_file'
        }

        $mounts = @()
        foreach ($m in @($data.Mounts)) {
            $mounts += [pscustomobject]@{
                Type        = [string]$m.Type
                Name        = [string]$m.Name
                Source      = [string]$m.Source
                Destination = [string]$m.Destination
            }
        }

        $result += [pscustomobject]@{
            Id          = [string]$data.Id
            ShortId     = [string]$id
            Name        = ([string]$data.Name).TrimStart("/")
            Status      = [string]$data.State.Status
            LocalFolder = [string]$localFolder
            ConfigFile  = [string]$configFile
            Mounts      = $mounts
        }
    }

    return @($result)
}

function Write-DevContainerDiagnostics([object[]]$Containers) {
    Write-Host ""
    Write-Host "=== Gefundene Docker-Container / Dev-Container-Diagnose ==="

    if (-not $Containers -or $Containers.Count -eq 0) {
        Write-Host "Keine Docker-Container gefunden."
        return
    }

    foreach ($c in $Containers) {
        Write-Host ""
        Write-Host ("Container: {0}  Name: {1}  Status: {2}" -f $c.ShortId,$c.Name,$c.Status)

        if ($c.LocalFolder) {
            Write-Host "  devcontainer.local_folder: $($c.LocalFolder)"
        }

        if ($c.ConfigFile) {
            Write-Host "  devcontainer.config_file:  $($c.ConfigFile)"
        }

        foreach ($m in @($c.Mounts)) {
            if (
                $m.Destination -eq "/workspaces" -or
                $m.Destination -eq "/home/vscode/.codex" -or
                $m.Destination -eq "/home/vscode/.vscode-server/extensions" -or
                $m.Name -like "*codex*" -or
                $m.Source -like "*codex*"
            ) {
                Write-Host ("  mount: type={0} name={1} source={2} -> {3}" -f $m.Type,$m.Name,$m.Source,$m.Destination)
            }
        }
    }

    Write-Host ""
    Write-Host "=== Ende Dev-Container-Diagnose ==="
}

function Find-DevContainer(
    [string]$Docker,
    [string]$Folder,
    [string]$WorkspaceVolume,
    [string]$HomeVolume,
    [string]$ExtensionVolume
) {
    $wantedFolder = Normalize-ComparablePath $Folder
    $wantedConfig = Normalize-ComparablePath (Join-Path $Folder ".devcontainer\devcontainer.json")

    $containers = @(Get-DockerContainers $Docker)

    # 1. Bevorzugt: exakt der Workspace-Ordner.
    foreach ($c in $containers) {
        if ((Normalize-ComparablePath $c.LocalFolder) -eq $wantedFolder) {
            Write-Host "Dev Container über devcontainer.local_folder erkannt."
            return $c.ShortId
        }
    }

    # 2. Ebenfalls eindeutig: exakt die verwendete devcontainer.json.
    foreach ($c in $containers) {
        if ((Normalize-ComparablePath $c.ConfigFile) -eq $wantedConfig) {
            Write-Host "Dev Container über devcontainer.config_file erkannt."
            return $c.ShortId
        }
    }

    # 3. Sichere Rückfallebene für dieses Setup:
    #    genau ein Container besitzt ALLE von uns eigens angelegten Kern-Volumes.
    $volumeMatches = @()

    foreach ($c in $containers) {
        $hasWorkspace = $false
        $hasHome = $false
        $hasExtensions = $false

        foreach ($m in @($c.Mounts)) {
            if (
                $m.Destination -eq "/workspaces" -and
                ($m.Name -eq $WorkspaceVolume -or $m.Source -eq $WorkspaceVolume -or $m.Source -like "*\$WorkspaceVolume")
            ) {
                $hasWorkspace = $true
            }

            if (
                $m.Destination -eq "/home/vscode/.codex" -and
                ($m.Name -eq $HomeVolume -or $m.Source -eq $HomeVolume -or $m.Source -like "*\$HomeVolume")
            ) {
                $hasHome = $true
            }

            if (
                $m.Destination -eq "/home/vscode/.vscode-server/extensions" -and
                ($m.Name -eq $ExtensionVolume -or $m.Source -eq $ExtensionVolume -or $m.Source -like "*\$ExtensionVolume")
            ) {
                $hasExtensions = $true
            }
        }

        if ($hasWorkspace -and $hasHome -and $hasExtensions) {
            $volumeMatches += $c
        }
    }

    if ($volumeMatches.Count -eq 1) {
        Write-Host "Dev Container über die drei eindeutigen Codex-Volumes erkannt."
        return $volumeMatches[0].ShortId
    }

    # Wenn keine eindeutige Zuordnung möglich war, alles Relevante ins Log schreiben.
    Write-DevContainerDiagnostics $containers

    if ($volumeMatches.Count -gt 1) {
        Write-Warning "Mehrere Container verwenden dieselben Codex-Volumes; automatische Auswahl wäre unsicher."
    }

    return $null
}

function Write-Utf8NoBom([string]$Path, [string]$Text) {
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false))
}

function Set-VsCodeDevContainersWslHost([string]$Distro) {
    Step "Dev Containers auf WSL-Host standardisieren"

    # dev.containers.executeInWSL ist eine Benutzer-/Anwendungseinstellung.
    # Das Fresh-Setup setzt sie deshalb auf VS-Code-Benutzerebene und pinnt
    # zugleich die zuvor ausgewählte WSL-Distro. Damit läuft die Dev-Containers-
    # CLI auf jedem Rechner gleich aus WSL und Bind-Mount-Quellen haben eine
    # einheitliche Sicht (/mnt/c, /mnt/d, /mnt/e, /mnt/y ...).
    $settingsDir = Join-Path $env:APPDATA "Code\User"
    $settingsPath = Join-Path $settingsDir "settings.json"
    New-Item -ItemType Directory -Force -Path $settingsDir | Out-Null

    if (Test-Path -LiteralPath $settingsPath) {
        $text = [System.IO.File]::ReadAllText($settingsPath)
    } else {
        $text = "{}"
    }

    if ([string]::IsNullOrWhiteSpace($text)) {
        $text = "{}"
    }

    $executePattern = '(?m)("dev\.containers\.executeInWSL"\s*:\s*)(true|false)'
    if ([regex]::IsMatch($text, $executePattern)) {
        $text = [regex]::Replace($text, $executePattern, '${1}true')
    } else {
        $open = $text.IndexOf('{')
        if ($open -lt 0) {
            throw "VS-Code-Benutzereinstellungen sind kein JSON/JSONC-Objekt: $settingsPath"
        }
        $insert = [Environment]::NewLine + '  "dev.containers.executeInWSL": true,'
        $text = $text.Insert($open + 1, $insert)
    }

    $distroJson = ConvertTo-Json ([string]$Distro) -Compress
    $distroPattern = '(?m)("dev\.containers\.executeInWSLDistro"\s*:\s*)("(?:\\.|[^"])*"|[^,}\r\n]+)'
    if ([regex]::IsMatch($text, $distroPattern)) {
        $text = [regex]::Replace($text, $distroPattern, ('${1}' + $distroJson))
    } else {
        $open = $text.IndexOf('{')
        if ($open -lt 0) {
            throw "VS-Code-Benutzereinstellungen sind kein JSON/JSONC-Objekt: $settingsPath"
        }
        $insert = [Environment]::NewLine + '  "dev.containers.executeInWSLDistro": ' + $distroJson + ','
        $text = $text.Insert($open + 1, $insert)
    }

    # Der Codex-Container benötigt keine Linux-GUI-Ausgabe. Ohne Wayland-Mount
    # bleibt der Start unabhängig von WSLg-/GUI-Komponenten.
    $waylandPattern = '(?m)("dev\.containers\.mountWaylandSocket"\s*:\s*)(true|false)'
    if ([regex]::IsMatch($text, $waylandPattern)) {
        $text = [regex]::Replace($text, $waylandPattern, '${1}false')
    } else {
        $open = $text.IndexOf('{')
        if ($open -lt 0) {
            throw "VS-Code-Benutzereinstellungen sind kein JSON/JSONC-Objekt: $settingsPath"
        }
        $insert = [Environment]::NewLine + '  "dev.containers.mountWaylandSocket": false,'
        $text = $text.Insert($open + 1, $insert)
    }

    Write-Utf8NoBom $settingsPath $text
    Write-Host "VS-Code-Benutzereinstellungen gesetzt:"
    Write-Host "  dev.containers.executeInWSL = true"
    Write-Host "  dev.containers.executeInWSLDistro = $Distro"
    Write-Host "  dev.containers.mountWaylandSocket = false"
    Write-Host "Datei: $settingsPath"
    Write-Host "Dev Containers wird damit auf jedem Fresh-Setup-Rechner in '$Distro' gestartet."
}

function Setup-NetworkDrives([string]$Distro) {
    Step "Windows-Netzlaufwerke für WSL prüfen"

    $drives = Get-CimInstance Win32_LogicalDisk -ErrorAction SilentlyContinue |
        Where-Object { $_.DriveType -eq 4 -and $_.DeviceID }

    if (-not $drives) {
        Write-Host "Keine verbundenen Windows-Netzlaufwerke gefunden."
        return
    }

    foreach ($d in $drives) {
        $drive = $d.DeviceID
        $letter = $drive.Substring(0,1).ToLowerInvariant()
        $mount = "/mnt/$letter"
        $fstabLine = "$drive $mount drvfs defaults,nofail 0 0"

        # Wiederholungsläufe fragen bereits konfigurierte Netzlaufwerke nicht
        # erneut ab. Zuerst wird der Ist-Zustand in der gewählten WSL-Distro
        # geprüft und ein vorhandener fstab-Eintrag bei Bedarf nur gemountet.
        $checkCmd = "grep -Fqx '$fstabLine' /etc/fstab 2>/dev/null"
        wsl -d $Distro -u root -- sh -lc $checkCmd *> $null
        $alreadyConfigured = ($LASTEXITCODE -eq 0)

        if ($alreadyConfigured) {
            Write-Host "$drive ist für WSL bereits als $mount konfiguriert." -ForegroundColor Green
            $mountCmd = "mkdir -p '$mount'; mountpoint -q '$mount' || mount '$mount' || mount -a"
            wsl -d $Distro -u root -- sh -lc $mountCmd

            if ($LASTEXITCODE -ne 0) {
                Write-Warning "$drive ist konfiguriert, konnte aber aktuell nicht als $mount gemountet werden."
            }
            continue
        }

        if (-not (Ask-YesNo "$drive auch in WSL als $mount bereitstellen?" $true)) { continue }

        $cmd = "mkdir -p '$mount'; echo '$fstabLine' >> /etc/fstab; mountpoint -q '$mount' || mount '$mount' || mount -a"
        wsl -d $Distro -u root -- sh -lc $cmd

        if ($LASTEXITCODE -ne 0) {
            Write-Warning "$drive konnte nicht in WSL eingebunden werden."
        }
    }
}


function Invoke-DockerNoThrow(
    [string]$Docker,
    [string[]]$Arguments
) {
    $oldPreference = $ErrorActionPreference

    try {
        # Windows PowerShell 5.1 kann nativen stderr bei
        # ErrorActionPreference=Stop als Terminierungsfehler behandeln.
        $ErrorActionPreference = "Continue"

        $output = @(& $Docker @Arguments 2>&1)
        $rc = $LASTEXITCODE

        return [pscustomobject]@{
            ExitCode = $rc
            Output   = @($output)
        }
    }
    finally {
        $ErrorActionPreference = $oldPreference
    }
}

function Wait-ContainerExecReady(
    [string]$Docker,
    [string]$ContainerId,
    [int]$TimeoutSeconds = 20
) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    while ((Get-Date) -lt $deadline) {
        $state = Invoke-DockerNoThrow $Docker @(
            "inspect", "-f", "{{.State.Running}}", $ContainerId
        )

        $running = (($state.Output | ForEach-Object { "$_" }) -join "`n").Trim()

        if ($state.ExitCode -ne 0) {
            return $false
        }

        if ($running -ne "true") {
            $startResult = Invoke-DockerNoThrow $Docker @("start", $ContainerId)

            if ($startResult.ExitCode -ne 0) {
                Start-Sleep -Seconds 1
                continue
            }

            Start-Sleep -Milliseconds 750
        }

        $execProbe = Invoke-DockerNoThrow $Docker @(
            "exec", $ContainerId, "sh", "-c", "true"
        )

        if ($execProbe.ExitCode -eq 0) {
            return $true
        }

        Start-Sleep -Seconds 1
    }

    return $false
}

function Invoke-ContainerShellScript(
    [string]$Docker,
    [string]$ContainerId,
    [string]$ScriptText,
    [string]$RunAsUser = "root",
    [string]$Purpose = "container-script"
) {
    $localScript = Join-Path $env:TEMP (
        "codex-" + $Purpose + "-" + [guid]::NewGuid().ToString("N") + ".sh"
    )
    $remoteScript = "/tmp/" + [IO.Path]::GetFileName($localScript)

    $normalized = ($ScriptText -replace "`r`n", "`n")
    [IO.File]::WriteAllText(
        $localScript,
        $normalized + "`n",
        (New-Object Text.UTF8Encoding($false))
    )

    try {
        if (-not (Wait-ContainerExecReady $Docker $ContainerId 20)) {
            Write-Warning "Container '$ContainerId' ist für '$Purpose' nicht ausführbar."
            return 125
        }

        $copyResult = Invoke-DockerNoThrow $Docker @(
            "cp", $localScript, "${ContainerId}:$remoteScript"
        )

        foreach ($line in $copyResult.Output) {
            if ("$line".Trim()) {
                Write-Host "$line"
            }
        }

        if ($copyResult.ExitCode -ne 0) {
            return $copyResult.ExitCode
        }

        # Der letzte VS-Code-Dev-Container-Client kann den Container genau
        # zwischen "cp" und "exec" stoppen. Deshalb nochmals sicherstellen.
        if (-not (Wait-ContainerExecReady $Docker $ContainerId 20)) {
            Write-Warning "Container '$ContainerId' wurde vor '$Purpose' gestoppt und konnte nicht erneut gestartet werden."
            return 125
        }

        $runArgs = @(
            "exec", "-u", $RunAsUser,
            $ContainerId,
            "sh", $remoteScript
        )

        $runResult = Invoke-DockerNoThrow $Docker $runArgs

        # Ein asynchrones shutdownAction=stopContainer kann auch exakt beim
        # docker-exec eintreten. Einmal neu starten und denselben Scriptlauf
        # erneut versuchen.
        if (
            $runResult.ExitCode -ne 0 -and
            (
                (($runResult.Output | ForEach-Object { "$_" }) -join "`n") -match
                "(?i)container .* is not running|is not running"
            )
        ) {
            Write-Host "Dev Container wurde während '$Purpose' gestoppt; starte ihn erneut und wiederhole den Schritt..."

            if (Wait-ContainerExecReady $Docker $ContainerId 20) {
                $runResult = Invoke-DockerNoThrow $Docker $runArgs
            }
        }

        foreach ($line in $runResult.Output) {
            if ("$line".Trim()) {
                Write-Host "$line"
            }
        }

        return $runResult.ExitCode
    }
    finally {
        # Cleanup ist Best Effort. Ein inzwischen gestoppter Container ist
        # KEIN Setup-Fehler und darf den eigentlichen Rückgabecode niemals
        # überschreiben.
        try {
            $state = Invoke-DockerNoThrow $Docker @(
                "inspect", "-f", "{{.State.Running}}", $ContainerId
            )

            $running = (($state.Output | ForEach-Object { "$_" }) -join "`n").Trim()

            if ($state.ExitCode -eq 0 -and $running -eq "true") {
                [void](Invoke-DockerNoThrow $Docker @(
                    "exec", "-u", "root", $ContainerId,
                    "rm", "-f", $remoteScript
                ))
            }
        }
        catch {
            Write-Verbose "Remote-Cleanup für '$Purpose' übersprungen: $($_.Exception.Message)"
        }

        Remove-Item -LiteralPath $localScript -Force -ErrorAction SilentlyContinue
    }
}

function Ensure-FreshCodexDb([string]$Docker, [string]$ContainerId) {
    Step "Frische Codex-Datenbank für Chatimport sicherstellen"

    & $Docker start $ContainerId | Out-Null

    & $Docker exec $ContainerId sh -c "test -s /home/vscode/.codex/state_5.sqlite"
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Frische Codex-Datenbank ist vorhanden."
        return
    }

    Write-Host "Noch keine Codex-Datenbank vorhanden."
    Write-Host "Initialisiere das aktuelle Schema über den Codex-Binary..."

    $scriptText = @'
set -eu

find_codex() {
    for base in \
        /home/vscode/.vscode-server/extensions \
        /home/vscode/.vscode-server-insiders/extensions \
        /vscode/vscode-server/extensions
    do
        if [ -d "$base" ]; then
            found="$(find "$base" -type f -path '*/openai.chatgpt-*/bin/linux-*/codex' 2>/dev/null | sort | tail -n 1)"
            if [ -n "$found" ]; then
                printf '%s\n' "$found"
                return 0
            fi
        fi
    done
    return 1
}

CODEX=""

i=0
while [ "$i" -lt 30 ]; do
    CODEX="$(find_codex || true)"
    if [ -n "$CODEX" ]; then
        break
    fi
    i=$((i + 1))
    sleep 2
done

if [ -z "$CODEX" ]; then
    echo "Codex-Binary wurde in den installierten VS-Code-Extensions nicht gefunden." >&2
    exit 31
fi

echo "Codex-Binary: $CODEX"
chmod +x "$CODEX" || true

if command -v timeout >/dev/null 2>&1; then
    timeout 8s "$CODEX" app-server --listen stdio </dev/null >/tmp/codex-init.log 2>&1 || true
else
    "$CODEX" app-server --listen stdio </dev/null >/tmp/codex-init.log 2>&1 &
    pid=$!
    sleep 8
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
fi

if [ ! -s /home/vscode/.codex/state_5.sqlite ]; then
    echo "Codex hat keine state_5.sqlite erzeugt." >&2
    if [ -f /tmp/codex-init.log ]; then
        echo "=== codex-init.log ===" >&2
        tail -n 100 /tmp/codex-init.log >&2 || true
    fi
    exit 32
fi

echo "Codex-Datenbank wurde initialisiert."
'@

    $rc = Invoke-ContainerShellScript `
        $Docker `
        $ContainerId `
        $scriptText `
        "vscode" `
        "init-codex-db"

    if ($rc -ne 0) {
        throw "Codex-Datenbank konnte nicht automatisch initialisiert werden (Exitcode $rc)."
    }

    & $Docker exec $ContainerId sh -c "test -s /home/vscode/.codex/state_5.sqlite"
    if ($LASTEXITCODE -ne 0) {
        throw "Codex-Datenbank wurde nach der Initialisierung nicht gefunden."
    }

    Write-Host "Frische Codex-Datenbank ist vorhanden." -ForegroundColor Green
}


function Get-Sha256HexFromText([string]$Text) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        $hash = $sha.ComputeHash($bytes)
        return (($hash | ForEach-Object { $_.ToString("x2") }) -join "").ToUpperInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Get-CodexHistoryFingerprint([string]$CodexHome) {
    $resolved = (Resolve-Path -LiteralPath $CodexHome -ErrorAction Stop).Path.TrimEnd('\')
    $lines = New-Object System.Collections.Generic.List[string]
    $fileCount = 0
    [Int64]$totalBytes = 0

    foreach ($name in @("state_5.sqlite", "state_5.sqlite-wal", "session_index.jsonl")) {
        $path = Join-Path $resolved $name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        $item = Get-Item -LiteralPath $path -ErrorAction Stop
        $lines.Add(("ROOT/{0}|{1}|{2}" -f $name.ToLowerInvariant(), $item.Length, $item.LastWriteTimeUtc.Ticks))
        $fileCount++
        $totalBytes += [Int64]$item.Length
    }

    foreach ($folderName in @("sessions", "archived_sessions", "attachments")) {
        $folder = Join-Path $resolved $folderName
        if (-not (Test-Path -LiteralPath $folder -PathType Container)) { continue }

        $files = @(
            Get-ChildItem -LiteralPath $folder -Recurse -File -ErrorAction SilentlyContinue |
                Sort-Object FullName
        )

        foreach ($item in $files) {
            $relative = $item.FullName.Substring($resolved.Length).TrimStart('\','/').Replace('\','/')
            $lines.Add(("FILE/{0}|{1}|{2}" -f $relative.ToLowerInvariant(), $item.Length, $item.LastWriteTimeUtc.Ticks))
            $fileCount++
            $totalBytes += [Int64]$item.Length
        }
    }

    $payload = [string]::Join("`n", $lines)
    return [pscustomobject]@{
        Fingerprint = Get-Sha256HexFromText $payload
        FileCount   = $fileCount
        TotalBytes  = $totalBytes
    }
}

function Get-CodexImportMarkerFromContainer(
    [string]$Docker,
    [string]$ContainerId
) {
    if (-not (Wait-ContainerExecReady $Docker $ContainerId 20)) {
        return $null
    }

    $result = Invoke-DockerNoThrow $Docker @(
        "exec", "-u", "vscode", $ContainerId,
        "cat", "/home/vscode/.codex/.fresh-codex-import.json"
    )

    if ($result.ExitCode -ne 0) {
        return $null
    }

    $text = (($result.Output | ForEach-Object { "$_" }) -join "`n").Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    try {
        return ($text | ConvertFrom-Json -ErrorAction Stop)
    }
    catch {
        return $null
    }
}

function Get-ContainerImageId([string]$Docker, [string]$ContainerId) {
    $result = Invoke-DockerNoThrow $Docker @(
        "inspect", "-f", "{{.Image}}", $ContainerId
    )
    if ($result.ExitCode -ne 0) {
        return $null
    }
    return (($result.Output | ForEach-Object { "$_" }) -join "`n").Trim()
}

function Invoke-CodexChatImportHelper(
    [string]$Docker,
    [string]$ContainerId,
    [string]$SourceCodexHome,
    [string]$HomeVolume,
    [string]$SourceFingerprint,
    [ValidateSet("verify","import")][string]$Mode = "import"
) {
    $helperPath = Join-Path $PSScriptRoot "tools\Import-CodexChatsHelper.py"
    if (-not (Test-Path -LiteralPath $helperPath -PathType Leaf)) {
        return [pscustomobject]@{
            ExitCode = 97
            Output = @("Chatimport-Helper fehlt: $helperPath")
        }
    }

    $helperHash = (Get-FileHash -LiteralPath $helperPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToUpperInvariant()
    if ($helperHash -ne $script:ChatImportHelperSha256) {
        return [pscustomobject]@{
            ExitCode = 98
            Output = @("Chatimport-Helper hat eine unerwartete SHA256-Prüfsumme: $helperHash")
        }
    }

    $sourcePath = (Resolve-Path -LiteralPath $SourceCodexHome -ErrorAction Stop).Path
    $helperResolved = (Resolve-Path -LiteralPath $helperPath -ErrorAction Stop).Path

    # Docker --mount verwendet Kommas als Trenner. Ein Komma in einem Hostpfad
    # kann dort nicht eindeutig dargestellt werden. Das ist selten, wird aber
    # lieber explizit abgelehnt als still falsch gemountet.
    foreach ($candidate in @($sourcePath, $helperResolved)) {
        if ($candidate.Contains(',')) {
            return [pscustomobject]@{
                ExitCode = 96
                Output = @("Chatimport-Helper kann Hostpfade mit Komma nicht sicher mounten: $candidate")
            }
        }
    }

    $imageId = Get-ContainerImageId $Docker $ContainerId
    if ([string]::IsNullOrWhiteSpace($imageId)) {
        return [pscustomobject]@{
            ExitCode = 95
            Output = @("Image-ID des Dev Containers konnte nicht ermittelt werden.")
        }
    }

    $args = @(
        "run", "--rm",
        "--label", "com.hightext.codex.role=chat-import-helper",
        "--network", "none",
        "--cap-drop", "ALL",
        "--security-opt", "no-new-privileges",
        "--user", "vscode",
        "--read-only",
        "--tmpfs", "/tmp:rw,nosuid,nodev,mode=1777,size=256m",
        "--pids-limit", "128",
        "-e", "PYTHONDONTWRITEBYTECODE=1",
        "--mount", ("type=bind,source={0},target=/source,readonly" -f $sourcePath),
        "--mount", ("type=volume,source={0},target=/target" -f $HomeVolume),
        "--mount", ("type=bind,source={0},target=/opt/Import-CodexChatsHelper.py,readonly" -f $helperResolved),
        "--entrypoint", "python3",
        $imageId,
        "/opt/Import-CodexChatsHelper.py",
        "--mode", $Mode,
        "--source", "/source",
        "--target", "/target",
        "--fingerprint", $SourceFingerprint
    )

    return Invoke-DockerNoThrow $Docker $args
}


function Get-FirstCodexRolloutFile([string]$CodexHome) {
    foreach ($folderName in @("sessions", "archived_sessions")) {
        $folder = Join-Path $CodexHome $folderName

        if (-not (Test-Path -LiteralPath $folder -PathType Container)) {
            continue
        }

        try {
            $first = Get-ChildItem `
                -LiteralPath $folder `
                -Recurse `
                -File `
                -Filter "*.jsonl" `
                -ErrorAction SilentlyContinue |
                Select-Object -First 1

            if ($first) {
                return $first.FullName
            }
        }
        catch {}
    }

    return $null
}

function Test-ImportableCodexHistory([string]$CodexHome) {
    $db = Join-Path $CodexHome "state_5.sqlite"

    if (-not (Test-Path -LiteralPath $db -PathType Leaf)) {
        return [pscustomobject]@{
            Importable = $false
            Reason     = "state_5.sqlite fehlt"
            Rollout    = $null
        }
    }

    $dbInfo = Get-Item -LiteralPath $db -ErrorAction SilentlyContinue
    if (-not $dbInfo -or $dbInfo.Length -le 0) {
        return [pscustomobject]@{
            Importable = $false
            Reason     = "state_5.sqlite ist leer"
            Rollout    = $null
        }
    }

    $rollout = Get-FirstCodexRolloutFile $CodexHome

    if (-not $rollout) {
        return [pscustomobject]@{
            Importable = $false
            Reason     = "keine Session-/Rollout-Dateien vorhanden"
            Rollout    = $null
        }
    }

    return [pscustomobject]@{
        Importable = $true
        Reason     = "Datenbank und Session-/Rollout-Dateien vorhanden"
        Rollout    = $rollout
    }
}

function Get-ExistingDevelopmentEnvironments([string]$ConfigPath) {
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        return $null
    }

    try {
        $raw = Get-Content -LiteralPath $ConfigPath -Raw -ErrorAction Stop
        $cfg = $raw | ConvertFrom-Json -ErrorAction Stop
        $buildArgs = $cfg.build.args

        if (-not $buildArgs) {
            return $null
        }

        $required = @(
            "CODEX_INSTALL_PHP",
            "CODEX_INSTALL_CPP",
            "CODEX_INSTALL_PYTHON",
            "CODEX_NODE_VERSION",
            "CODEX_DOTNET_VERSION"
        )

        foreach ($name in $required) {
            if ($null -eq $buildArgs.$name) {
                return $null
            }
        }

        return [pscustomobject]@{
            Php = ([string]$buildArgs.CODEX_INSTALL_PHP -eq "true")
            Cpp = ([string]$buildArgs.CODEX_INSTALL_CPP -eq "true")
            Python = ([string]$buildArgs.CODEX_INSTALL_PYTHON -eq "true")
            NodeVersion = [string]$buildArgs.CODEX_NODE_VERSION
            DotNetVersion = [string]$buildArgs.CODEX_DOTNET_VERSION
        }
    }
    catch {
        Write-Warning "Vorhandene Entwicklungsumgebungen konnten aus '$ConfigPath' nicht gelesen werden: $($_.Exception.Message)"
        return $null
    }
}

function Show-DevelopmentEnvironments([object]$Environment, [string]$Prefix = "Vorhandene Auswahl") {
    if (-not $Environment) { return }

    Write-Host "$Prefix`:" -ForegroundColor Cyan
    Write-Host ("  PHP:     " + $(if ($Environment.Php) { "Ja" } else { "Nein" }))
    Write-Host ("  C/C++:   " + $(if ($Environment.Cpp) { "Ja" } else { "Nein" }))
    Write-Host ("  Python:  " + $(if ($Environment.Python) { "Ja" } else { "Nein" }))
    Write-Host ("  Node.js: " + $(if ($Environment.NodeVersion -eq "none") { "Nein" } else { $Environment.NodeVersion }))
    Write-Host ("  .NET:    " + $(if ($Environment.DotNetVersion -eq "none") { "Nein" } else { $Environment.DotNetVersion }))
}

function Get-ConfiguredDevContainersWslDistro {
    $settingsPath = Join-Path $env:APPDATA "Code\User\settings.json"

    if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) {
        return $null
    }

    try {
        $text = Get-Content -LiteralPath $settingsPath -Raw -ErrorAction Stop
        $match = [regex]::Match(
            $text,
            '"dev\.containers\.executeInWSLDistro"\s*:\s*"(?<distro>(?:\\.|[^"\\])*)"'
        )

        if (-not $match.Success) {
            return $null
        }

        $jsonString = '"' + $match.Groups['distro'].Value + '"'
        return [string]($jsonString | ConvertFrom-Json)
    }
    catch {
        Write-Verbose "Gespeicherte Dev-Containers-WSL-Distro konnte nicht gelesen werden: $($_.Exception.Message)"
        return $null
    }
}

function Find-ExistingCodexContainerForPreflight(
    [string]$Docker,
    [string]$Folder,
    [string]$WorkspaceVolume,
    [string]$HomeVolume
) {
    $wantedFolder = Normalize-ComparablePath $Folder
    $wantedConfig = Normalize-ComparablePath (Join-Path $Folder ".devcontainer\devcontainer.json")
    $containers = @(Get-DockerContainers $Docker)

    foreach ($c in $containers) {
        if ($c.LocalFolder -and (Normalize-ComparablePath $c.LocalFolder) -eq $wantedFolder) {
            return $c.ShortId
        }
    }

    foreach ($c in $containers) {
        if ($c.ConfigFile -and (Normalize-ComparablePath $c.ConfigFile) -eq $wantedConfig) {
            return $c.ShortId
        }
    }

    $matches = @()

    foreach ($c in $containers) {
        $hasWorkspace = $false
        $hasHome = $false

        foreach ($m in $c.Mounts) {
            if (
                $m.Destination -eq "/workspaces" -and
                ($m.Name -eq $WorkspaceVolume -or $m.Source -eq $WorkspaceVolume -or $m.Source -like "*\$WorkspaceVolume")
            ) {
                $hasWorkspace = $true
            }

            if (
                $m.Destination -eq "/home/vscode/.codex" -and
                ($m.Name -eq $HomeVolume -or $m.Source -eq $HomeVolume -or $m.Source -like "*\$HomeVolume")
            ) {
                $hasHome = $true
            }
        }

        if ($hasWorkspace -and $hasHome) {
            $matches += $c
        }
    }

    if ($matches.Count -eq 1) {
        return $matches[0].ShortId
    }

    return $null
}

function Get-ContainerPreflightMountState(
    [string]$Docker,
    [string]$ContainerId,
    [string]$WorkspaceVolume,
    [string]$HomeVolume,
    [string]$ExtensionVolume
) {
    $containers = @(Get-DockerContainers $Docker)
    $container = $containers | Where-Object { $_.ShortId -eq $ContainerId -or $_.Id -eq $ContainerId } | Select-Object -First 1

    $state = [ordered]@{
        HasWorkspaceVolume = $false
        HasHomeVolume = $false
        HasExtensionVolume = $false
    }

    if (-not $container) {
        return [pscustomobject]$state
    }

    foreach ($m in $container.Mounts) {
        if (
            $m.Destination -eq "/workspaces" -and
            ($m.Name -eq $WorkspaceVolume -or $m.Source -eq $WorkspaceVolume -or $m.Source -like "*\$WorkspaceVolume")
        ) {
            $state.HasWorkspaceVolume = $true
        }

        if (
            $m.Destination -eq "/home/vscode/.codex" -and
            ($m.Name -eq $HomeVolume -or $m.Source -eq $HomeVolume -or $m.Source -like "*\$HomeVolume")
        ) {
            $state.HasHomeVolume = $true
        }

        if (
            $m.Destination -eq "/home/vscode/.vscode-server/extensions" -and
            ($m.Name -eq $ExtensionVolume -or $m.Source -eq $ExtensionVolume -or $m.Source -like "*\$ExtensionVolume")
        ) {
            $state.HasExtensionVolume = $true
        }
    }

    return [pscustomobject]$state
}

function Get-ContainerExtensionDirectoryNamesPreflight(
    [string]$Docker,
    [string]$ContainerId
) {
    if (-not (Wait-ContainerExecReady $Docker $ContainerId 20)) {
        return @()
    }

    $rootPath = "/home/vscode/.vscode-server/extensions"
    $result = Invoke-DockerNoThrow $Docker @(
        "exec", "-u", "vscode", $ContainerId,
        "find", $rootPath, "-mindepth", "1", "-maxdepth", "1", "-type", "d", "-printf", "%f\n"
    )

    if ($result.ExitCode -ne 0) {
        return @()
    }

    return @(
        $result.Output |
            ForEach-Object { ([string]$_).Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Sort-Object -Unique
    )
}

function Test-SourceCodexHistoryPresentInContainer(
    [string]$Docker,
    [string]$ContainerId,
    [string]$SourceCodexHome,
    [string]$HomeVolume
) {
    $history = Test-ImportableCodexHistory $SourceCodexHome

    if (-not $history.Importable) {
        return [pscustomobject]@{
            AlreadyPresent = $false
            Reason = $history.Reason
            SourceFiles = 0
            MissingFiles = 0
            SmallerTargetFiles = 0
            SourceIndexIds = 0
            MissingIndexIds = 0
        }
    }

    if (-not (Wait-ContainerExecReady $Docker $ContainerId 20)) {
        return [pscustomobject]@{
            AlreadyPresent = $false
            Reason = "vorhandener Dev Container ist nicht ausführbar"
            SourceFiles = 0
            MissingFiles = 0
            SmallerTargetFiles = 0
            SourceIndexIds = 0
            MissingIndexIds = 0
        }
    }

    $dbCheck = Invoke-DockerNoThrow $Docker @(
        "exec", "-u", "vscode", $ContainerId,
        "sh", "-c", "test -s /home/vscode/.codex/state_5.sqlite"
    )

    if ($dbCheck.ExitCode -ne 0) {
        return [pscustomobject]@{
            AlreadyPresent = $false
            Reason = "Ziel enthält keine nichtleere state_5.sqlite"
            SourceFiles = 0
            MissingFiles = 0
            SmallerTargetFiles = 0
            SourceIndexIds = 0
            MissingIndexIds = 0
        }
    }

    # Ab 1.0.51 ist ein erfolgreicher Import durch einen Fingerprint-Marker im
    # persistenten .codex-Volume gekennzeichnet. Das ist die billigste und
    # verlässlichste Wiederholungsprüfung und verhindert, dass bei jedem
    # Setup-Lauf hunderte MB erneut durch docker cp bewegt werden.
    $fingerprint = Get-CodexHistoryFingerprint $SourceCodexHome
    $marker = Get-CodexImportMarkerFromContainer $Docker $ContainerId

    if ($marker -and [string]$marker.sourceFingerprint -eq $fingerprint.Fingerprint) {
        return [pscustomobject]@{
            AlreadyPresent = $true
            Reason = "persistenter Chatimport-Marker passt zur aktuellen lokalen Historie"
            SourceFiles = $fingerprint.FileCount
            MissingFiles = 0
            SmallerTargetFiles = 0
            SourceIndexIds = 0
            MissingIndexIds = 0
        }
    }

    # Für ältere erfolgreiche Imports ohne Marker wird einmalig ein stark
    # eingeschränkter Helper-Container verwendet. Er sieht ausschließlich die
    # lokale .codex-Quelle read-only und das persistente Ziel-Volume, hat kein
    # Netzwerk und keinen Docker-Socket. Erkennt er den Bestand als vollständig,
    # schreibt er den Marker nachträglich. Dadurch ist schon der nächste Lauf
    # vollständig markerbasiert.
    if (-not [string]::IsNullOrWhiteSpace($HomeVolume)) {
        $verify = Invoke-CodexChatImportHelper `
            $Docker `
            $ContainerId `
            $SourceCodexHome `
            $HomeVolume `
            $fingerprint.Fingerprint `
            "verify"

        $verifyText = (($verify.Output | ForEach-Object { "$_" }) -join "`n").Trim()

        if ($verify.ExitCode -eq 0) {
            return [pscustomobject]@{
                AlreadyPresent = $true
                Reason = $(if ($verifyText -match "RESULT=VERIFIED_EXISTING") {
                    "bestehender Import wurde isoliert verifiziert und mit Marker versehen"
                } else {
                    "persistenter Chatimport-Marker wurde vom Helper bestätigt"
                })
                SourceFiles = $fingerprint.FileCount
                MissingFiles = 0
                SmallerTargetFiles = 0
                SourceIndexIds = 0
                MissingIndexIds = 0
            }
        }

        if ($verify.ExitCode -eq 10) {
            return [pscustomobject]@{
                AlreadyPresent = $false
                Reason = "isolierte Vorprüfung meldet noch nicht vollständig importierte Historie"
                SourceFiles = $fingerprint.FileCount
                MissingFiles = 0
                SmallerTargetFiles = 0
                SourceIndexIds = 0
                MissingIndexIds = 0
            }
        }

        Write-Warning ("Isolierte Chatimport-Vorprüfung war nicht möglich (Exitcode {0}); verwende die ältere Dateiprüfung." -f $verify.ExitCode)
        foreach ($line in $verify.Output) {
            if ("$line".Trim()) { Write-Host "  $line" -ForegroundColor DarkGray }
        }
    }

    $rollouts = @()
    foreach ($folderName in @("sessions", "archived_sessions")) {
        $folder = Join-Path $SourceCodexHome $folderName
        if (-not (Test-Path -LiteralPath $folder -PathType Container)) { continue }

        $rollouts += @(
            Get-ChildItem -LiteralPath $folder -Recurse -File -Filter "*.jsonl" -ErrorAction SilentlyContinue
        )
    }

    if ($rollouts.Count -eq 0) {
        return [pscustomobject]@{
            AlreadyPresent = $false
            Reason = "Quelle enthält keine Rollout-Dateien"
            SourceFiles = 0
            MissingFiles = 0
            SmallerTargetFiles = 0
            SourceIndexIds = 0
            MissingIndexIds = 0
        }
    }

    $lines = foreach ($file in $rollouts) {
        $relative = $file.FullName.Substring($SourceCodexHome.Length).TrimStart('\','/').Replace('\','/')
        "{0}`t{1}" -f $relative, $file.Length
    }

    $tempList = Join-Path $env:TEMP ("codex-preflight-rollouts-" + [guid]::NewGuid().ToString("N") + ".txt")
    $remoteList = "/tmp/codex-preflight-rollouts.txt"

    try {
        $content = ($lines -join "`n") + "`n"
        [IO.File]::WriteAllText($tempList, $content, (New-Object Text.UTF8Encoding($false)))

        $copyResult = Invoke-DockerNoThrow $Docker @("cp", $tempList, "${ContainerId}:$remoteList")
        if ($copyResult.ExitCode -ne 0) {
            return [pscustomobject]@{
                AlreadyPresent = $false
                Reason = "Rollout-Prüfliste konnte nicht in den Container kopiert werden"
                SourceFiles = $rollouts.Count
                MissingFiles = 0
                SmallerTargetFiles = 0
            }
        }

        $checkScript = @'
total=0
missing=0
smaller=0
while IFS="	" read -r rel srcsize; do
    [ -n "$rel" ] || continue
    total=$((total + 1))
    target="/home/vscode/.codex/$rel"
    if [ ! -f "$target" ]; then
        missing=$((missing + 1))
        continue
    fi
    dstsize=$(wc -c < "$target" | tr -d ' ')
    if [ "$dstsize" -lt "$srcsize" ]; then
        smaller=$((smaller + 1))
    fi
done < /tmp/codex-preflight-rollouts.txt
printf 'TOTAL=%s\nMISSING=%s\nSMALLER=%s\n' "$total" "$missing" "$smaller"
rm -f /tmp/codex-preflight-rollouts.txt
'@

        $check = Invoke-DockerNoThrow $Docker @(
            "exec", "-u", "vscode", $ContainerId,
            "sh", "-c", $checkScript
        )

        if ($check.ExitCode -ne 0) {
            return [pscustomobject]@{
                AlreadyPresent = $false
                Reason = "Rollout-Dateien im Ziel konnten nicht vollständig geprüft werden"
                SourceFiles = $rollouts.Count
                MissingFiles = 0
                SmallerTargetFiles = 0
            }
        }

        $total = 0
        $missing = 0
        $smaller = 0

        foreach ($line in $check.Output) {
            $s = ([string]$line).Trim()
            if ($s -match '^TOTAL=(\d+)$') { $total = [int]$Matches[1] }
            elseif ($s -match '^MISSING=(\d+)$') { $missing = [int]$Matches[1] }
            elseif ($s -match '^SMALLER=(\d+)$') { $smaller = [int]$Matches[1] }
        }

        $sourceIndexIds = @()
        $missingIndexIds = 0
        $sourceIndex = Join-Path $SourceCodexHome "session_index.jsonl"

        if (Test-Path -LiteralPath $sourceIndex -PathType Leaf) {
            foreach ($line in Get-Content -LiteralPath $sourceIndex -ErrorAction SilentlyContinue) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                try {
                    $obj = $line | ConvertFrom-Json -ErrorAction Stop
                    if ($obj.id) {
                        $sourceIndexIds += [string]$obj.id
                    }
                }
                catch {}
            }
            $sourceIndexIds = @($sourceIndexIds | Sort-Object -Unique)
        }

        if ($sourceIndexIds.Count -gt 0) {
            $targetIndexTemp = Join-Path $env:TEMP ("codex-preflight-target-index-" + [guid]::NewGuid().ToString("N") + ".jsonl")
            try {
                $indexCopy = Invoke-DockerNoThrow $Docker @(
                    "cp",
                    "${ContainerId}:/home/vscode/.codex/session_index.jsonl",
                    $targetIndexTemp
                )

                if ($indexCopy.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $targetIndexTemp -PathType Leaf)) {
                    $missingIndexIds = $sourceIndexIds.Count
                }
                else {
                    $targetIds = @{}
                    foreach ($line in Get-Content -LiteralPath $targetIndexTemp -ErrorAction SilentlyContinue) {
                        if ([string]::IsNullOrWhiteSpace($line)) { continue }
                        try {
                            $obj = $line | ConvertFrom-Json -ErrorAction Stop
                            if ($obj.id) {
                                $targetIds[[string]$obj.id] = $true
                            }
                        }
                        catch {}
                    }

                    foreach ($id in $sourceIndexIds) {
                        if (-not $targetIds.ContainsKey($id)) {
                            $missingIndexIds++
                        }
                    }
                }
            }
            finally {
                Remove-Item -LiteralPath $targetIndexTemp -Force -ErrorAction SilentlyContinue
            }
        }

        $present = (
            $total -gt 0 -and
            $missing -eq 0 -and
            $smaller -eq 0 -and
            $missingIndexIds -eq 0
        )
        $reason = if ($present) {
            "alle vorhandenen lokalen Rollout-Dateien sind im persistenten Codex-Home bereits enthalten"
        } else {
            "im Ziel fehlen Rollout-Dateien oder dortige Dateien sind kleiner als die lokale Quelle"
        }

        return [pscustomobject]@{
            AlreadyPresent = $present
            Reason = $reason
            SourceFiles = $total
            MissingFiles = $missing
            SmallerTargetFiles = $smaller
            SourceIndexIds = $sourceIndexIds.Count
            MissingIndexIds = $missingIndexIds
        }
    }
    finally {
        Remove-Item -LiteralPath $tempList -Force -ErrorAction SilentlyContinue
        Invoke-DockerNoThrow $Docker @(
            "exec", "-u", "vscode", $ContainerId,
            "rm", "-f", $remoteList
        ) | Out-Null
    }
}

function Test-DockerVolumeExistsPreflight([string]$Docker, [string]$VolumeName) {
    $result = Invoke-DockerNoThrow $Docker @("volume", "inspect", $VolumeName)
    return ($result.ExitCode -eq 0)
}

function Test-DockerVolumeHasContentPreflight(
    [string]$Docker,
    [string]$VolumeName,
    [string]$ContainerId
) {
    if (-not (Test-DockerVolumeExistsPreflight $Docker $VolumeName)) {
        return $false
    }

    $image = (& $Docker inspect -f "{{.Image}}" $ContainerId 2>$null).Trim()
    if (-not $image) {
        return $null
    }

    $result = Invoke-DockerNoThrow $Docker @(
        "run", "--rm", "--entrypoint", "sh",
        "-v", "${VolumeName}:/target",
        $image,
        "-c", "find /target -mindepth 1 -print -quit | grep -q ."
    )

    if ($result.ExitCode -eq 0) { return $true }
    if ($result.ExitCode -eq 1) { return $false }
    return $null
}

function Test-CodexBinaryPresentPreflight(
    [string]$Docker,
    [string]$ContainerId
) {
    if (-not (Wait-ContainerExecReady $Docker $ContainerId 20)) {
        return $false
    }

    $script = @'
for base in /home/vscode/.vscode-server/extensions /vscode/vscode-server/extensions; do
    [ -d "$base" ] || continue
    if find "$base" -type f -path '*/openai.chatgpt-*/bin/linux-*/codex' -print -quit 2>/dev/null | grep -q .; then
        exit 0
    fi
done
exit 1
'@

    $result = Invoke-DockerNoThrow $Docker @(
        "exec", "-u", "vscode", $ContainerId,
        "sh", "-c", $script
    )

    return ($result.ExitCode -eq 0)
}

function Get-DevContainerMountValue([object]$Mount, [string]$Name) {
    if ($null -eq $Mount) { return $null }

    if ($Mount -is [string]) {
        foreach ($part in ([string]$Mount -split ',')) {
            $pair = @($part -split '=', 2)
            if ($pair.Count -eq 2 -and $pair[0].Trim() -eq $Name) {
                return $pair[1].Trim()
            }
        }
        return $null
    }

    $property = $Mount.PSObject.Properties[$Name]
    if ($property) {
        return [string]$property.Value
    }

    return $null
}

function Convert-WslDriveMountSourceToWindowsPath([string]$Source) {
    if ([string]::IsNullOrWhiteSpace($Source)) { return $null }
    $raw = $Source.Trim()
    if ($raw -match '^/mnt/([A-Za-z])(?:/(.*))?$') {
        $drive = $Matches[1].ToUpperInvariant()
        $tail = [string]$Matches[2]
        if ([string]::IsNullOrWhiteSpace($tail)) { return "${drive}:\" }
        return "${drive}:\$($tail -replace '/', '\')"
    }
    return $null
}

function Normalize-WindowsSecurityPath([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    try {
        return ([IO.Path]::GetFullPath($Value.Trim())).TrimEnd('\','/').ToLowerInvariant()
    }
    catch {
        return $null
    }
}

function Test-WindowsSecurityPathEqual([string]$Candidate, [string]$ProtectedPath) {
    $a = Normalize-WindowsSecurityPath $Candidate
    $b = Normalize-WindowsSecurityPath $ProtectedPath
    return ($a -and $b -and $a -eq $b)
}

function Test-WindowsSecurityPathInside([string]$Candidate, [string]$ProtectedPath) {
    $a = Normalize-WindowsSecurityPath $Candidate
    $b = Normalize-WindowsSecurityPath $ProtectedPath
    if (-not $a -or -not $b) { return $false }
    return ($a -eq $b -or $a.StartsWith($b + '\', [StringComparison]::OrdinalIgnoreCase))
}

function Get-WindowsDriveRoot([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    try {
        return [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Value.Trim()))
    }
    catch {
        return $null
    }
}

function Get-ProtectedWindowsMountRules {
    $systemRoot = if ($env:SystemRoot) { $env:SystemRoot } elseif ($env:WINDIR) { $env:WINDIR } elseif ($env:SystemDrive) { "$($env:SystemDrive)\Windows" } else { $null }
    $userProfile = $env:USERPROFILE
    $systemDriveSource = if ($systemRoot) { $systemRoot } else { $env:SystemDrive }
    $userDriveSource = if ($userProfile) { $userProfile } else { $env:HOMEDRIVE }
    $systemDrive = Get-WindowsDriveRoot $systemDriveSource
    $userDrive = Get-WindowsDriveRoot $userDriveSource
    $usersRoot = if ($userProfile) { Split-Path -Parent ([IO.Path]::GetFullPath($userProfile)) } else { $null }

    $exact = New-Object System.Collections.ArrayList
    $subtree = New-Object System.Collections.ArrayList

    function Add-ExactRule([string]$PathValue, [string]$Reason) {
        if (-not [string]::IsNullOrWhiteSpace($PathValue)) {
            [void]$exact.Add([pscustomobject]@{ Path = $PathValue; Reason = $Reason })
        }
    }
    function Add-SubtreeRule([string]$PathValue, [string]$Reason) {
        if (-not [string]::IsNullOrWhiteSpace($PathValue)) {
            [void]$subtree.Add([pscustomobject]@{ Path = $PathValue; Reason = $Reason })
        }
    }

    Add-ExactRule $systemDrive 'Das Windows-Systemlaufwerk darf nicht als Ganzes gemountet werden.'
    Add-ExactRule $userDrive 'Das Laufwerk mit dem Benutzerprofil darf nicht als Ganzes gemountet werden.'
    Add-ExactRule $usersRoot 'Das Benutzerverzeichnis-Stammverzeichnis darf nicht als Ganzes gemountet werden.'
    Add-ExactRule $userProfile 'Das komplette Benutzerprofil darf nicht gemountet werden.'

    Add-SubtreeRule $systemRoot 'Windows-Systemverzeichnisse sind geschützt.'
    Add-SubtreeRule $env:ProgramFiles 'Programmverzeichnisse sind geschützt.'
    Add-SubtreeRule ${env:ProgramFiles(x86)} 'Programmverzeichnisse sind geschützt.'
    Add-SubtreeRule $env:ProgramData 'ProgramData kann systemweite Konfigurationen und Zugangsdaten enthalten.'

    if ($systemDrive) {
        Add-SubtreeRule (Join-Path $systemDrive 'Recovery') 'Windows-Recovery ist geschützt.'
        Add-SubtreeRule (Join-Path $systemDrive 'System Volume Information') 'System Volume Information ist geschützt.'
        Add-SubtreeRule (Join-Path $systemDrive '$Recycle.Bin') 'Der Windows-Papierkorb ist geschützt.'
        Add-SubtreeRule (Join-Path $systemDrive 'Boot') 'Windows-Bootdateien sind geschützt.'
        Add-SubtreeRule (Join-Path $systemDrive 'Windows.old') 'Alte Windows-Installationen sind geschützt.'
        Add-SubtreeRule (Join-Path $systemDrive 'Documents and Settings') 'Legacy-Benutzerprofilpfade sind geschützt.'
    }

    if ($userProfile) {
        $sensitive = @(
            @('AppData', 'AppData enthält Anwendungsdaten, Tokens und Zugangsinformationen.'),
            @('.ssh', 'SSH-Schlüssel dürfen nicht als Projekt-Mount freigegeben werden.'),
            @('.gnupg', 'GnuPG-Schlüssel dürfen nicht als Projekt-Mount freigegeben werden.'),
            @('.aws', 'AWS-Zugangsdaten dürfen nicht als Projekt-Mount freigegeben werden.'),
            @('.azure', 'Azure-Zugangsdaten dürfen nicht als Projekt-Mount freigegeben werden.'),
            @('.kube', 'Kubernetes-Konfigurationen und Tokens dürfen nicht als Projekt-Mount freigegeben werden.'),
            @('.docker', 'Docker-Konfigurationen können Registry-Zugangsdaten enthalten.'),
            @('.codex', 'Lokale Codex-Daten und Anmeldedaten dürfen nicht als Projekt-Mount freigegeben werden.'),
            @('.vscode', 'VS-Code-Benutzerdaten sollen nicht als Projekt-Mount freigegeben werden.'),
            @('.config', 'Benutzerspezifische Konfigurationen können Zugangsdaten enthalten.')
        )
        foreach ($item in $sensitive) {
            Add-SubtreeRule (Join-Path $userProfile $item[0]) $item[1]
        }
    }

    return [pscustomobject]@{
        Exact = @($exact)
        Subtree = @($subtree)
        UsersRoot = $usersRoot
        UserProfile = $userProfile
        SystemDrive = $systemDrive
        UserDrive = $userDrive
    }
}

function Get-MountSecurityViolation([string]$Source) {
    if ([string]::IsNullOrWhiteSpace($Source)) { return 'Leere Mount-Quelle.' }
    $raw = $Source.Trim()
    $candidate = Convert-WslDriveMountSourceToWindowsPath $raw
    if (-not $candidate -and $raw -match '^[A-Za-z]:(?:[\\/]|$)') {
        $candidate = $raw
    }

    if ($candidate) {
        $rules = Get-ProtectedWindowsMountRules
        foreach ($rule in @($rules.Exact)) {
            if (Test-WindowsSecurityPathEqual $candidate $rule.Path) { return [string]$rule.Reason }
        }
        foreach ($rule in @($rules.Subtree)) {
            if (Test-WindowsSecurityPathInside $candidate $rule.Path) { return [string]$rule.Reason }
        }

        if ($rules.UsersRoot -and ([IO.Path]::GetFileName($rules.UsersRoot.TrimEnd('\')) -ieq 'Users') -and
            (Test-WindowsSecurityPathInside $candidate $rules.UsersRoot) -and
            $rules.UserProfile -and -not (Test-WindowsSecurityPathInside $candidate $rules.UserProfile)) {
            return 'Andere Windows-Benutzerprofile dürfen nicht in den Codex-Container gemountet werden.'
        }
        return $null
    }

    $linux = ($raw -replace '\\','/').TrimEnd('/')
    if (-not $linux) { $linux = '/' }
    if ($linux -eq '/var/run/docker.sock' -or $linux -eq '/run/docker.sock') {
        return 'Der Docker-Socket darf nicht in den Codex-Container gemountet werden.'
    }

    $linuxRules = @(
        @('/', 'Das Host-Wurzeldateisystem darf nicht gemountet werden.', $true),
        @('/etc', 'Host-Systemkonfigurationen unter /etc sind geschützt.', $false),
        @('/root', 'Das Root-Benutzerprofil ist geschützt.', $false),
        @('/proc', 'Host-Prozessinformationen unter /proc sind geschützt.', $false),
        @('/sys', 'Host-Kernelinformationen unter /sys sind geschützt.', $false),
        @('/dev', 'Host-Geräte unter /dev sind geschützt.', $false),
        @('/boot', 'Host-Bootdateien sind geschützt.', $false),
        @('/var/lib/docker', 'Docker-interne Daten sind geschützt.', $false),
        @('/run/desktop/mnt/host', 'Docker-Desktop-Hostdurchgriff ist geschützt.', $false),
        @('/mnt/wsl', 'WSL-interne Hostpfade sind geschützt.', $false),
        @('/host', 'Direkter Hostdurchgriff ist geschützt.', $false)
    )
    foreach ($rule in $linuxRules) {
        $prefix = [string]$rule[0]
        if ([bool]$rule[2]) {
            if ($linux -eq $prefix) { return [string]$rule[1] }
        }
        elseif ($linux -eq $prefix -or $linux.StartsWith($prefix + '/', [StringComparison]::Ordinal)) {
            return [string]$rule[1]
        }
    }

    return $null
}

function Get-UnsafeDevContainerBindMounts([string]$ConfigPath) {
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { return @() }
    try {
        $cfg = (Get-Content -LiteralPath $ConfigPath -Raw -ErrorAction Stop) | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        return @([pscustomobject]@{ Source = $ConfigPath; Target = ''; Reason = "devcontainer.json konnte für die Sicherheitsprüfung nicht gelesen werden: $($_.Exception.Message)" })
    }

    $unsafe = New-Object System.Collections.ArrayList
    $allMounts = @()
    if ($cfg.workspaceMount) { $allMounts += $cfg.workspaceMount }
    $allMounts += @($cfg.mounts)

    foreach ($mount in $allMounts) {
        $type = Get-DevContainerMountValue $mount 'type'
        if (-not $type) { continue }
        if ($type -ne 'bind') { continue }
        $source = Get-DevContainerMountValue $mount 'source'
        if (-not $source) { $source = Get-DevContainerMountValue $mount 'src' }
        $target = Get-DevContainerMountValue $mount 'target'
        if (-not $target) { $target = Get-DevContainerMountValue $mount 'dst' }
        if (-not $source) { continue }

        $reason = Get-MountSecurityViolation $source
        if ($reason) {
            [void]$unsafe.Add([pscustomobject]@{ Source = [string]$source; Target = [string]$target; Reason = [string]$reason })
        }
    }

    return @($unsafe)
}

function Get-ProtectedRuntimeHostPaths {
    $rules = Get-ProtectedWindowsMountRules
    $paths = New-Object System.Collections.ArrayList
    $driveRoots = @($rules.SystemDrive, $rules.UserDrive) | Where-Object { $_ } | Select-Object -Unique
    foreach ($driveRoot in $driveRoots) {
        $letter = ([IO.Path]::GetPathRoot($driveRoot)).Substring(0,1).ToLowerInvariant()
        [void]$paths.Add("/mnt/$letter")
    }
    foreach ($fixed in @('/host','/run/desktop/mnt/host','/var/run/docker.sock','/run/docker.sock','/mnt/wsl')) {
        [void]$paths.Add($fixed)
    }
    return @($paths | Select-Object -Unique)
}

function Get-DevContainerVolumePrefix([string]$ConfigPath) {
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        return $null
    }

    try {
        $cfg = (Get-Content -LiteralPath $ConfigPath -Raw -ErrorAction Stop) | ConvertFrom-Json -ErrorAction Stop
        $sources = @()

        if ($cfg.workspaceMount) {
            $workspaceSource = Get-DevContainerMountValue $cfg.workspaceMount "source"
            $workspaceTarget = Get-DevContainerMountValue $cfg.workspaceMount "target"
            if ($workspaceSource -and $workspaceTarget -eq "/workspaces") {
                $sources += [string]$workspaceSource
            }
        }

        foreach ($mount in @($cfg.mounts)) {
            $source = Get-DevContainerMountValue $mount "source"
            $target = Get-DevContainerMountValue $mount "target"
            if ($source -and ($target -eq "/workspaces" -or $target -eq "/home/vscode/.codex" -or $target -eq "/home/vscode/.vscode-server/extensions")) {
                $sources += [string]$source
            }
        }

        foreach ($source in @($sources | Select-Object -Unique)) {
            foreach ($suffix in @("-workspaces", "-home", "-vscode-extensions")) {
                if ($source.EndsWith($suffix, [StringComparison]::OrdinalIgnoreCase)) {
                    return $source.Substring(0, $source.Length - $suffix.Length)
                }
            }
        }
    }
    catch {
        Write-Verbose "Volume-Präfix konnte aus '$ConfigPath' nicht gelesen werden: $($_.Exception.Message)"
    }

    return $null
}

function Test-CodexDevContainerConfiguration([string]$ConfigPath) {
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        return $false
    }

    try {
        # Unter "Dokumente" koennen auch voellig fremde Dev-Container liegen.
        # Erst nach eindeutigen Codex-Merkmalen suchen und nur dann JSON parsen.
        # So erzeugen unbeteiligte JSON/JSONC-Dateien keine ConvertFrom-Json-
        # Fehlermeldungen waehrend der stillen Bestandsaufnahme.
        $raw = Get-Content -LiteralPath $ConfigPath -Raw -ErrorAction Stop
        if ($raw -notmatch 'CODEX_' -and $raw -notmatch '/home/vscode/\.codex') {
            return $false
        }

        $cfg = $raw | ConvertFrom-Json -ErrorAction Stop

        if ($cfg.build -and $cfg.build.args) {
            foreach ($property in @($cfg.build.args.PSObject.Properties)) {
                if ([string]$property.Name -like "CODEX_*") {
                    return $true
                }
            }
        }

        foreach ($mount in @($cfg.mounts)) {
            $target = Get-DevContainerMountValue $mount "target"
            if ($target -eq "/home/vscode/.codex") {
                return $true
            }
        }
    }
    catch {
        return $false
    }

    return $false
}

function Get-CodexDevContainerCandidates(
    [string]$RequestedInstallDirectory,
    [string]$DefaultVolumePrefix
) {
    $paths = @()
    $requestedConfig = Join-Path $RequestedInstallDirectory ".devcontainer\devcontainer.json"

    if (Test-Path -LiteralPath $requestedConfig -PathType Leaf) {
        $paths += (Get-Item -LiteralPath $requestedConfig).FullName
    }

    $documents = [Environment]::GetFolderPath("MyDocuments")
    if ([string]::IsNullOrWhiteSpace($documents)) {
        $documents = Join-Path $env:USERPROFILE "Documents"
    }

    if (Test-Path -LiteralPath $documents -PathType Container) {
        try {
            $paths += @(
                Get-ChildItem -LiteralPath $documents -Recurse -Depth 4 -File -Filter "devcontainer.json" -ErrorAction SilentlyContinue |
                    Where-Object { $_.Directory -and $_.Directory.Name -eq ".devcontainer" } |
                    ForEach-Object { $_.FullName }
            )
        }
        catch {
            Write-Host "Dev-Container-Suche unter '$documents' konnte nicht vollständig durchgeführt werden: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    $seen = @{}
    $candidates = @()

    foreach ($path in @($paths)) {
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        $normalized = Normalize-ComparablePath $path
        if ($seen.ContainsKey($normalized)) { continue }
        $seen[$normalized] = $true

        if (-not (Test-CodexDevContainerConfiguration $path)) { continue }

        try {
            $cfg = (Get-Content -LiteralPath $path -Raw -ErrorAction Stop) | ConvertFrom-Json -ErrorAction Stop
            $devDir = Split-Path -Parent $path
            $installDir = Split-Path -Parent $devDir
            $detectedPrefix = Get-DevContainerVolumePrefix $path
            $effectivePrefix = if ([string]::IsNullOrWhiteSpace($detectedPrefix)) { $DefaultVolumePrefix } else { $detectedPrefix }
            $name = [string]$cfg.name
            if ([string]::IsNullOrWhiteSpace($name)) {
                $name = Split-Path -Leaf $installDir
            }

            $candidates += [pscustomobject]@{
                Name = $name
                InstallDirectory = $installDir
                ConfigPath = $path
                DetectedVolumePrefix = $detectedPrefix
                EffectiveVolumePrefix = $effectivePrefix
                DevelopmentEnvironment = Get-ExistingDevelopmentEnvironments $path
                Preflight = $null
            }
        }
        catch {
            Write-Host "Codex-Konfiguration '$path' konnte nicht ausgewertet werden: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    return @($candidates | Sort-Object InstallDirectory)
}

function Show-CodexDevContainerCandidate([object]$Candidate, [int]$Number = 0) {
    $prefix = if ($Number -gt 0) { "[$Number] " } else { "" }
    Write-Host ("{0}{1}" -f $prefix, $Candidate.Name) -ForegroundColor Cyan
    Write-Host "    Ordner:        $($Candidate.InstallDirectory)"
    Write-Host "    Konfiguration: $($Candidate.ConfigPath)"
    Write-Host "    Volume-Präfix: $($Candidate.EffectiveVolumePrefix)"
    if ($Candidate.DevelopmentEnvironment) {
        $e = $Candidate.DevelopmentEnvironment
        Write-Host ("    Build: PHP={0}, C/C++={1}, Python={2}, Node={3}, .NET={4}" -f `
            $(if ($e.Php) { "Ja" } else { "Nein" }),
            $(if ($e.Cpp) { "Ja" } else { "Nein" }),
            $(if ($e.Python) { "Ja" } else { "Nein" }),
            $e.NodeVersion,
            $e.DotNetVersion)
    }
    if ($Candidate.Preflight -and $Candidate.Preflight.ContainerId) {
        Write-Host "    Dev Container: $($Candidate.Preflight.ContainerId)"
    }
}

function Select-CodexDevContainerCandidate([object[]]$Candidates) {
    Step "Vorhandene Codex-Umgebung auswählen"
    Write-Host "Mehrere bestehende Codex-Devcontainer wurden vollständig vorgeprüft."
    Write-Host "Welche Umgebung soll dieses Setup verwenden?"
    Write-Host ""

    for ($i = 0; $i -lt $Candidates.Count; $i++) {
        Show-CodexDevContainerCandidate $Candidates[$i] ($i + 1)
        Write-Host ""
    }

    while ($true) {
        $answer = (Read-Host "Nummer auswählen [1-$($Candidates.Count)]").Trim()
        $number = 0
        if ([int]::TryParse($answer, [ref]$number) -and $number -ge 1 -and $number -le $Candidates.Count) {
            Write-Host "Auswahl: $number - $($Candidates[$number - 1].InstallDirectory)"
            return $Candidates[$number - 1]
        }
        Write-Host "Bitte eine Nummer zwischen 1 und $($Candidates.Count) eingeben." -ForegroundColor Yellow
    }
}

function Update-ExistingDevContainerForExtensionPersistence(
    [string]$ConfigPath,
    [string]$ExtensionVolume
) {
    $raw = Get-Content -LiteralPath $ConfigPath -Raw -ErrorAction Stop
    $cfg = $raw | ConvertFrom-Json -ErrorAction Stop
    $changed = $false

    $mounts = @($cfg.mounts)
    $hasExtensionMount = $false

    foreach ($mount in $mounts) {
        if ((Get-DevContainerMountValue $mount "target") -eq "/home/vscode/.vscode-server/extensions") {
            $hasExtensionMount = $true
            break
        }
    }

    if (-not $hasExtensionMount) {
        $mounts += "source=$ExtensionVolume,target=/home/vscode/.vscode-server/extensions,type=volume"
        if ($cfg.PSObject.Properties["mounts"]) {
            $cfg.mounts = @($mounts)
        } else {
            $cfg | Add-Member -NotePropertyName "mounts" -NotePropertyValue @($mounts)
        }
        $changed = $true
    }

    if (
        $cfg.PSObject.Properties["build"] -and
        $cfg.build -and
        $cfg.build.PSObject.Properties["args"] -and
        $cfg.build.args -and
        $cfg.build.args.PSObject.Properties["CODEX_BASE_IMAGE"] -and
        ([string]$cfg.build.args.CODEX_BASE_IMAGE) -eq "mcr.microsoft.com/devcontainers/base:ubuntu"
    ) {
        $cfg.build.args.CODEX_BASE_IMAGE = "mcr.microsoft.com/devcontainers/base:ubuntu-24.04"
        Write-Host "Legacy-Base-Image ':ubuntu' wurde auf das festgelegte ':ubuntu-24.04' angeheftet." -ForegroundColor Green
        $changed = $true
    }

    $permissionCommand = 'sudo chown vscode:vscode /home/vscode/.vscode-server/extensions && chmod 755 /home/vscode/.vscode-server/extensions'
    $postCreateProperty = $cfg.PSObject.Properties["postCreateCommand"]

    if (-not $postCreateProperty) {
        $cfg | Add-Member -NotePropertyName "postCreateCommand" -NotePropertyValue $permissionCommand
        $changed = $true
    }
    elseif ($cfg.postCreateCommand -is [string]) {
        if ([string]$cfg.postCreateCommand -notlike "*/home/vscode/.vscode-server/extensions*") {
            $cfg.postCreateCommand = ([string]$cfg.postCreateCommand).Trim() + " && " + $permissionCommand
            $changed = $true
        }
    }
    else {
        $postObject = $cfg.postCreateCommand
        if (-not $postObject.PSObject.Properties["codexExtensionVolumePermissions"]) {
            $postObject | Add-Member -NotePropertyName "codexExtensionVolumePermissions" -NotePropertyValue $permissionCommand
            $changed = $true
        }
    }

    if ($changed) {
        Write-Utf8NoBom $ConfigPath ($cfg | ConvertTo-Json -Depth 30)
    }

    return $changed
}

function Get-SetupPreflightState(
    [string]$InstallDirectory,
    [string]$VolumePrefix
) {
    Step "Bestehende Umgebung vollständig prüfen (noch ohne Rückfragen)"
    Write-Host "Prüfe Installationsordner: $InstallDirectory"
    Write-Host "Prüfe Volume-Präfix:      $VolumePrefix"

    $configPath = Join-Path $InstallDirectory ".devcontainer\devcontainer.json"
    $workspaceVolume = "$VolumePrefix-workspaces"
    $homeVolume = "$VolumePrefix-home"
    $extensionVolume = "$VolumePrefix-vscode-extensions"
    $oldCodexHome = Join-Path $env:USERPROFILE ".codex"

    $state = [ordered]@{
        ConfigPath = $configPath
        ExistingConfig = (Test-Path -LiteralPath $configPath -PathType Leaf)
        ExistingDevelopmentEnvironment = Get-ExistingDevelopmentEnvironments $configPath
        ConfiguredWslDistro = Get-ConfiguredDevContainersWslDistro
        InstalledWslDistros = @()
        RunningWslDistros = @()
        NetworkDrives = @()
        LocalCodexHome = $oldCodexHome
        LocalHistory = Test-ImportableCodexHistory $oldCodexHome
        DockerCli = $null
        DockerReady = $false
        ContainerId = $null
        ContainerMounts = $null
        CodexBinaryPresent = $false
        LocalHistoryAlreadyPresent = $false
        LocalHistoryComparison = $null
        ExistingExtensionNames = @()
        ExtensionVolumeExists = $false
        ExtensionVolumeHasContent = $false
        ExtensionVolumeContentKnown = $true
        UnsafeBindMounts = @()
    }

    if ($state.ExistingConfig) {
        $state.UnsafeBindMounts = @(Get-UnsafeDevContainerBindMounts $configPath)
    }

    Write-Host "Dev-Container-Konfiguration: " -NoNewline
    if ($state.ExistingConfig) {
        Write-Host "vorhanden" -ForegroundColor Green
    } else {
        Write-Host "nicht vorhanden"
    }

    if ($state.UnsafeBindMounts.Count -gt 0) {
        Write-Host "SICHERHEITSFEHLER: Kritische Bind-Mount-Quelle(n) gefunden:" -ForegroundColor Red
        foreach ($unsafeMount in $state.UnsafeBindMounts) {
            Write-Host ("  {0} -> {1}: {2}" -f $unsafeMount.Source, $unsafeMount.Target, $unsafeMount.Reason) -ForegroundColor Red
        }
    }
    elseif ($state.ExistingConfig) {
        Write-Host "Bind-Mount-Sicherheitsprüfung: keine kritischen Quellen gefunden" -ForegroundColor Green
    }

    if ($state.ExistingDevelopmentEnvironment) {
        Show-DevelopmentEnvironments $state.ExistingDevelopmentEnvironment "Aus vorhandener devcontainer.json erkannt"
    }

    if ($state.ConfiguredWslDistro) {
        Write-Host "Gespeicherte Dev-Containers-WSL-Distro: $($state.ConfiguredWslDistro)" -ForegroundColor Green
    } else {
        Write-Host "Keine gespeicherte Dev-Containers-WSL-Distro erkannt."
    }

    try {
        $state.InstalledWslDistros = @(Get-WslDistroNames)
        $state.RunningWslDistros = @(Get-WslDistroNames -RunningOnly)
        Write-Host ("Installierte normale WSL-Distros: " + $(if ($state.InstalledWslDistros.Count -gt 0) { $state.InstalledWslDistros -join ", " } else { "keine" }))
        Write-Host ("Aktive normale WSL-Distros:      " + $(if ($state.RunningWslDistros.Count -gt 0) { $state.RunningWslDistros -join ", " } else { "keine" }))
    }
    catch {
        Write-Host "WSL-Bestand konnte in der frühen Prüfung noch nicht vollständig gelesen werden: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    try {
        $state.NetworkDrives = @(
            Get-CimInstance Win32_LogicalDisk -ErrorAction Stop |
                Where-Object { $_.DriveType -eq 4 -and $_.DeviceID } |
                ForEach-Object { [string]$_.DeviceID }
        )
        Write-Host ("Verbundene Windows-Netzlaufwerke: " + $(if ($state.NetworkDrives.Count -gt 0) { $state.NetworkDrives -join ", " } else { "keine" }))
    }
    catch {
        Write-Host "Windows-Netzlaufwerke konnten in der frühen Prüfung nicht vollständig gelesen werden: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    if ($state.LocalHistory.Importable) {
        Write-Host "Lokale Codex-Historie: importierbar ($($state.LocalHistory.Reason))"
    } elseif (Test-Path -LiteralPath $oldCodexHome) {
        Write-Host "Lokale Codex-Historie: nicht importierbar ($($state.LocalHistory.Reason))"
    } else {
        Write-Host "Lokale Codex-Historie: nicht vorhanden"
    }

    try {
        $docker = Get-Docker
        $state.DockerCli = $docker
        Write-Host "Docker CLI: $docker"

        if (-not (Test-DockerReady $docker)) {
            $dockerDesktop = "$env:ProgramFiles\Docker\Docker\Docker Desktop.exe"
            Write-Host "Docker Engine läuft noch nicht; starte Docker Desktop für die Bestandsaufnahme..."
            if (Test-Path -LiteralPath $dockerDesktop) {
                [void](Start-DockerDesktopAndWait $docker $dockerDesktop)
            }
        }

        $state.DockerReady = Test-DockerReady $docker
    }
    catch {
        Write-Host "Docker ist für die Bestandsaufnahme noch nicht verfügbar: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    if (-not $state.DockerReady) {
        Write-Host "Vorhandene Docker-Container/Volumes können in dieser frühen Bestandsaufnahme noch nicht geprüft werden." -ForegroundColor Yellow
        return [pscustomobject]$state
    }

    $docker = $state.DockerCli
    $state.ExtensionVolumeExists = Test-DockerVolumeExistsPreflight $docker $extensionVolume
    $state.ContainerId = Find-ExistingCodexContainerForPreflight `
        $docker `
        $InstallDirectory `
        $workspaceVolume `
        $homeVolume

    if (-not $state.ContainerId) {
        Write-Host "Passender bestehender Dev Container: nicht gefunden"
        Write-Host ("Persistentes Extensions-Volume: " + $(if ($state.ExtensionVolumeExists) { "vorhanden" } else { "nicht vorhanden" }))
        return [pscustomobject]$state
    }

    Write-Host "Passender bestehender Dev Container: $($state.ContainerId)" -ForegroundColor Green

    $state.ContainerMounts = Get-ContainerPreflightMountState `
        $docker `
        $state.ContainerId `
        $workspaceVolume `
        $homeVolume `
        $extensionVolume

    Write-Host ("  workspaces-Volume: " + $(if ($state.ContainerMounts.HasWorkspaceVolume) { "Ja" } else { "Nein" }))
    Write-Host ("  .codex-Volume:     " + $(if ($state.ContainerMounts.HasHomeVolume) { "Ja" } else { "Nein" }))
    Write-Host ("  Extensions-Volume: " + $(if ($state.ContainerMounts.HasExtensionVolume) { "Ja" } else { "Nein" }))

    if (Wait-ContainerExecReady $docker $state.ContainerId 20) {
        $state.CodexBinaryPresent = Test-CodexBinaryPresentPreflight $docker $state.ContainerId
        Write-Host ("  Codex-Binary:      " + $(if ($state.CodexBinaryPresent) { "vorhanden" } else { "nicht gefunden" }))

        if ($state.LocalHistory.Importable -and $state.ContainerMounts.HasHomeVolume) {
            $state.LocalHistoryComparison = Test-SourceCodexHistoryPresentInContainer `
                $docker `
                $state.ContainerId `
                $oldCodexHome `
                $homeVolume

            $state.LocalHistoryAlreadyPresent = $state.LocalHistoryComparison.AlreadyPresent

            if ($state.LocalHistoryAlreadyPresent) {
                Write-Host "  Alte lokale Chats: bereits im persistenten Container-Home enthalten" -ForegroundColor Green
                Write-Host ("    Prüfgrund: {0}" -f $state.LocalHistoryComparison.Reason)
            } else {
                Write-Host "  Alte lokale Chats: noch nicht vollständig im Container-Home nachweisbar" -ForegroundColor Yellow
                Write-Host ("    Prüfgrund: {0}" -f $state.LocalHistoryComparison.Reason) -ForegroundColor Yellow
                Write-Host ("    Rollouts Quelle: {0}, fehlend: {1}, Ziel kleiner: {2}, fehlende Index-IDs: {3}" -f `
                    $state.LocalHistoryComparison.SourceFiles,
                    $state.LocalHistoryComparison.MissingFiles,
                    $state.LocalHistoryComparison.SmallerTargetFiles,
                    $state.LocalHistoryComparison.MissingIndexIds)
            }
        }

        $state.ExistingExtensionNames = @(
            Get-ContainerExtensionDirectoryNamesPreflight $docker $state.ContainerId
        )
        Write-Host "  Container-Extensions: $($state.ExistingExtensionNames.Count)"
    }
    else {
        Write-Host "  Container konnte für Detailprüfungen nicht gestartet werden." -ForegroundColor Yellow
    }

    if ($state.ExtensionVolumeExists) {
        if ($state.ContainerMounts.HasExtensionVolume) {
            $state.ExtensionVolumeHasContent = ($state.ExistingExtensionNames.Count -gt 0)
        } else {
            $contentState = Test-DockerVolumeHasContentPreflight $docker $extensionVolume $state.ContainerId
            if ($null -eq $contentState) {
                $state.ExtensionVolumeContentKnown = $false
                Write-Host "  Inhalt des Extensions-Volumes konnte nicht sicher geprüft werden." -ForegroundColor Yellow
            } else {
                $state.ExtensionVolumeHasContent = [bool]$contentState
            }
        }
    }

    Write-Host ("Persistentes Extensions-Volume: " + $(if (-not $state.ExtensionVolumeExists) {
        "nicht vorhanden"
    } elseif (-not $state.ExtensionVolumeContentKnown) {
        "vorhanden, Inhalt unbekannt"
    } elseif ($state.ExtensionVolumeHasContent) {
        "vorhanden und befüllt"
    } else {
        "vorhanden und leer"
    }))

    Write-Host "Bestandsaufnahme abgeschlossen. Erst ab jetzt können erforderliche Rückfragen folgen." -ForegroundColor Green
    return [pscustomobject]$state
}

# Bei UAC-Neustart den Log-Switch mitnehmen.
if (-not (Is-Admin)) {
    Write-Host "Setup wird mit Administratorrechten neu gestartet..." -ForegroundColor Yellow

    $argLine = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -InstallDirectory `"$InstallDirectory`" -VolumePrefix `"$VolumePrefix`""
    if (-not [string]::IsNullOrWhiteSpace($UbuntuDistro)) {
        $argLine += " -UbuntuDistro `"$UbuntuDistro`""
    }
    if ($LogFile) { $argLine += " -LogFile" }

    Start-Process powershell.exe -Verb RunAs -ArgumentList $argLine
    exit
}

Start-SetupLog
Initialize-AtcDiagnosticLog
Write-AtcCheckpoint "Setup-Prozess gestartet"

Write-Host ""
Write-Host "Fresh Codex Dev-Container Setup $script:SetupVersion" -ForegroundColor Green
Write-Host "========================================"
Write-Host "Start:       $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')"
Write-Host "Computer:    $env:COMPUTERNAME"
Write-Host "Benutzer:    $env:USERNAME"
Write-Host "PowerShell:  $($PSVersionTable.PSVersion)"
Write-Host "Windows:     $([Environment]::OSVersion.VersionString)"
Write-Host "Aufruf-Zielordner: $InstallDirectory"

# Vor der ersten regulären Setup-Rückfrage werden zunächst alle vorhandenen
# Codex-Devcontainer unter "Dokumente" gesucht. Jede gefundene Umgebung wird
# soweit technisch möglich vollständig vorgeprüft. Genau ein Treffer wird
# automatisch verwendet; nur bei mehreren Treffern ist danach eine Auswahl
# erforderlich.
$requestedInstallDirectory = $InstallDirectory
$requestedVolumePrefix = $VolumePrefix
$candidates = @(Get-CodexDevContainerCandidates $requestedInstallDirectory $requestedVolumePrefix)
$selectedCandidate = $null
$preflight = $null

if ($candidates.Count -eq 0) {
    Write-Host ""
    Write-Host "Keine bestehende Codex-Devcontainer-Konfiguration unter 'Dokumente' gefunden."
    $preflight = Get-SetupPreflightState $InstallDirectory $VolumePrefix
}
else {
    Write-Host ""
    Write-Host "Gefundene bestehende Codex-Devcontainer: $($candidates.Count)" -ForegroundColor Green

    foreach ($candidate in $candidates) {
        Write-Host ""
        Show-CodexDevContainerCandidate $candidate
        $candidate.Preflight = Get-SetupPreflightState $candidate.InstallDirectory $candidate.EffectiveVolumePrefix
    }

    if ($candidates.Count -eq 1) {
        $selectedCandidate = $candidates[0]
        Write-Host ""
        Write-Host "Genau eine bestehende Codex-Umgebung gefunden; sie wird automatisch verwendet:" -ForegroundColor Green
        Show-CodexDevContainerCandidate $selectedCandidate
    }
    else {
        $selectedCandidate = Select-CodexDevContainerCandidate $candidates
    }

    $InstallDirectory = $selectedCandidate.InstallDirectory
    $VolumePrefix = $selectedCandidate.EffectiveVolumePrefix
    $preflight = $selectedCandidate.Preflight
}

Write-Host ""
Write-Host "Effektiver Zielordner:  $InstallDirectory" -ForegroundColor Green
Write-Host "Effektiver Volume-Präfix: $VolumePrefix" -ForegroundColor Green

if ($preflight.UnsafeBindMounts -and $preflight.UnsafeBindMounts.Count -gt 0) {
    $details = ($preflight.UnsafeBindMounts | ForEach-Object { "  $($_.Source) -> $($_.Target): $($_.Reason)" }) -join "`r`n"
    throw @"
Die ausgewählte devcontainer.json enthält sicherheitskritische Bind-Mounts.
Der Container wird nicht weiter eingerichtet oder neu gebaut, solange diese Einträge vorhanden sind.

$details
"@
}

# Eine bereits von Dev Containers verwendete WSL-Distro ist bei Wiederholung
# des Setups die beste Vorgabe. Ein expliziter Parameter hat weiterhin Vorrang.
if ([string]::IsNullOrWhiteSpace($UbuntuDistro) -and $preflight.ConfiguredWslDistro) {
    $UbuntuDistro = $preflight.ConfiguredWslDistro
}

# Bereits vorhandene WSL-Umgebung wird VOR allen Installationen bestimmt.
# Ubuntu ist nur noch Fallback, wenn gar keine normale Distro existiert.
$UbuntuDistro = Resolve-WorkingWslDistro $UbuntuDistro

if (Test-SystemWslDistro $UbuntuDistro) {
    throw "Runtime-Hilfsdistribution '$UbuntuDistro' darf nicht als Arbeits-WSL verwendet werden."
}

Write-Host ""
Write-Host "Für dieses Setup gewählte WSL-Distribution: $UbuntuDistro" -ForegroundColor Green

$oldCodexHome = $preflight.LocalCodexHome
$oldCodexDb = Join-Path $oldCodexHome "state_5.sqlite"
$historyState = $preflight.LocalHistory
$importChats = $false
$offerChatImport = ($historyState.Importable -and -not $preflight.LocalHistoryAlreadyPresent)

if ($historyState.Importable -and $preflight.LocalHistoryAlreadyPresent) {
    Write-Host "Vorhandene lokale Codex-Chats wurden bereits im persistenten Container-Home nachgewiesen." -ForegroundColor Green
    Write-Host "Ein erneuter Chatimport wird deshalb nicht angeboten." -ForegroundColor Green
}
elseif ($historyState.Importable) {
    Write-Host "Lokale importierbare Codex-Historie ist vorhanden und noch nicht vollständig im Ziel nachgewiesen."
}
elseif (Test-Path -LiteralPath $oldCodexHome) {
    Write-Host "Codex-Ordner vorhanden, aber keine importierbare Chat-Historie." -ForegroundColor Yellow
    Write-Host "Grund: $($historyState.Reason)"
}
else {
    Write-Host "Keine bestehende lokale Codex-Historie gefunden."
}

Step "winget prüfen"

$winget = Get-Command winget.exe -ErrorAction SilentlyContinue
if (-not $winget) {
    throw "winget fehlt. Microsoft 'App Installer' installieren und Setup danach erneut starten."
}

Write-Host "winget: $($winget.Source)"

[void](Ensure-ModernWsl $winget.Source)

Step "Grundsoftware installieren"

$gitInstalledNow = Ensure-WingetPackage "Git.Git" "Git"
$vscodeInstalledNow = Ensure-WingetPackage "Microsoft.VisualStudioCode" "Visual Studio Code"
$dockerInstalledNow = Ensure-WingetPackage "Docker.DockerDesktop" "Docker Desktop"

if ($dockerInstalledNow) {
    Step "Windows-Neustart nach Docker-Desktop-Installation"

    Write-Host ""
    Write-Host "Docker Desktop wurde gerade neu installiert." -ForegroundColor Yellow
    Write-Host "Für die zuverlässige WSL2-Integration wird Windows einmal neu gestartet."
    Write-Host "Danach dasselbe Setup erneut starten."
    Write-Host "Bereits installierte Komponenten werden übersprungen."

    if ($script:LogPath) {
        Write-Host "Der nächste Lauf mit --logfile wird an dieselbe Datei anhängen:"
        Write-Host "  $script:LogPath"
    }

    if (Ask-YesNo "Windows jetzt neu starten?" $true) {
        Stop-SetupLog
        Restart-Computer -Force
        exit
    }

    Stop-SetupLog
    Write-Host "Bitte Windows manuell neu starten und danach das Setup erneut ausführen."
    Read-Host "ENTER drücken"
    exit 11
}

Step "WSL2 und ausgewählte Distribution einrichten"

$wslUpdate = Invoke-Probe "$env:WINDIR\System32\wsl.exe" @("--update")
if ($wslUpdate.ExitCode -ne 0) {
    Write-Warning "wsl --update meldete Exitcode $($wslUpdate.ExitCode)."
    if ($wslUpdate.StdErr) {
        Write-Host $wslUpdate.StdErr
    }
}

wsl --set-default-version 2

$distros = @(Get-WslDistroNames)

if ($distros -notcontains $UbuntuDistro) {
    Write-Host "$UbuntuDistro ist noch nicht installiert."
    Write-Host "WSL-Installation wird gestartet..."

    wsl --install -d $UbuntuDistro --no-launch

    $distros = @(Get-WslDistroNames)

    if ($distros -notcontains $UbuntuDistro) {
        Write-Host ""
        Write-Host "Windows muss die WSL-Installation erst abschließen." -ForegroundColor Yellow
        Write-Host "Bitte Windows neu starten und danach dasselbe Setup erneut ausführen."

        Stop-SetupLog
        Read-Host "ENTER drücken"
        exit 10
    }
}

Write-Host "Stelle sicher, dass '$UbuntuDistro' WSL2 verwendet..."
wsl --set-version $UbuntuDistro 2 | Out-Null

Write-Host "Setze '$UbuntuDistro' als WSL-Standarddistribution..."
wsl --set-default $UbuntuDistro
if ($LASTEXITCODE -ne 0) {
    throw "'$UbuntuDistro' konnte nicht als WSL-Standarddistribution gesetzt werden."
}

# Nicht bash voraussetzen: auch Alpine besitzt /bin/sh.
wsl -d $UbuntuDistro -u root -- sh -lc "true"
if ($LASTEXITCODE -ne 0) {
    throw "WSL-Distribution '$UbuntuDistro' konnte nicht gestartet werden."
}

Write-Host ""
Write-Host "WSL-Distributionen:"
wsl -l -v

$runningAfterSetup = @(Get-WslDistroNames -RunningOnly)
$otherRunning = @($runningAfterSetup | Where-Object { $_ -ne $UbuntuDistro })

if ($otherRunning.Count -gt 0) {
    throw @"
Nach der WSL-Einrichtung laufen wieder mehrere normale WSL-Distributionen:
  $($otherRunning -join ', ')

Für ein eindeutiges Docker-/Dev-Container-Backend darf neben '$UbuntuDistro'
keine weitere normale WSL-Distribution aktiv sein.
"@
}

Setup-NetworkDrives $UbuntuDistro

if ($preflight.ExistingDevelopmentEnvironment) {
    Step "Vorhandene Entwicklungsumgebungen übernehmen"
    $devEnvironment = $preflight.ExistingDevelopmentEnvironment
    Show-DevelopmentEnvironments $devEnvironment "Ohne Rückfrage übernommen"
} else {
    $devEnvironment = Select-DevelopmentEnvironments
}

$devDir = Join-Path $InstallDirectory ".devcontainer"
$configPath = Join-Path $devDir "devcontainer.json"
New-Item -ItemType Directory -Force -Path $devDir | Out-Null

$homeVolume = "$VolumePrefix-home"
$workspaceVolume = "$VolumePrefix-workspaces"
$extensionVolume = "$VolumePrefix-vscode-extensions"
$devContainerDefinitionChanged = $false
$forceDevContainerRebuild = $false

if ($preflight.ExistingConfig) {
    Step "Vorhandene Dev-Container-Konfiguration beibehalten"
    Write-Host "Vorhandene Konfiguration wird nicht neu erzeugt:"
    Write-Host "  $configPath" -ForegroundColor Green
    Write-Host "Bestehende Mounts, VS-Code-Einstellungen und Build-Args bleiben erhalten."

    $configChanged = Update-ExistingDevContainerForExtensionPersistence $configPath $extensionVolume
    if ($configChanged) {
        $devContainerDefinitionChanged = $true
        Write-Host "Vorhandene Konfiguration wurde gezielt aktualisiert (Extensions-Persistenz und/oder feste Base-Image-Version)." -ForegroundColor Green
    } else {
        Write-Host "Extensions-Persistenz ist bereits vollständig konfiguriert." -ForegroundColor Green
    }

    $dockerfilePath = Join-Path $devDir "Dockerfile.codex"
    if (-not (Test-Path -LiteralPath $dockerfilePath -PathType Leaf)) {
        Write-Utf8NoBom $dockerfilePath (Get-ManagedDockerfileContent)
        $devContainerDefinitionChanged = $true
        Write-Host "Fehlende Dockerfile.codex wurde ergänzt: $dockerfilePath"
    } else {
        # Windows PowerShell 5.1 liest UTF-8 ohne BOM bei Get-Content ohne
        # explizites Encoding als ANSI. Das würde den Umlaut im verwalteten
        # Dockerfile-Kommentar verfälschen und bei jedem Setup-Lauf fälschlich
        # eine Änderung/Rebuild erkennen. Deshalb explizit als UTF-8 lesen.
        $existingDockerfile = [System.IO.File]::ReadAllText($dockerfilePath, [System.Text.Encoding]::UTF8)
        $existingDockerfileNoBom = $existingDockerfile.TrimStart([char]0xFEFF)
        if ($existingDockerfileNoBom.StartsWith("# Managed by Codex Mount Manager")) {
            $managedDockerfile = Get-ManagedDockerfileContent
            $normalizeExisting = ($existingDockerfileNoBom -replace "`r`n", "`n").TrimEnd()
            $normalizeManaged = ($managedDockerfile -replace "`r`n", "`n").TrimEnd()
            if ($normalizeExisting -ne $normalizeManaged) {
                Copy-Item -LiteralPath $dockerfilePath -Destination ($dockerfilePath + ".bak") -Force
                Write-Utf8NoBom $dockerfilePath $managedDockerfile
                $devContainerDefinitionChanged = $true
                Write-Host "Verwaltete Dockerfile.codex wurde auf den aktuellen Setup-Stand gebracht." -ForegroundColor Green
                Write-Host "  Backup: $dockerfilePath.bak"
            } else {
                Write-Host "Verwaltete Dockerfile.codex ist bereits aktuell: $dockerfilePath"
            }
        } else {
            Write-Host "Fremde vorhandene Dockerfile bleibt unverändert: $dockerfilePath" -ForegroundColor Yellow
            Write-Host "Hinweis: Für das persistente Extensions-Volume muss /home/vscode/.vscode-server vor dem VS-Code-Start vscode:vscode gehören." -ForegroundColor Yellow
        }
    }
}
else {
    Step "Neue Dev-Container-Konfiguration erzeugen"

    $installPhpArg = if ($devEnvironment.Php) { "true" } else { "false" }
    $installCppArg = if ($devEnvironment.Cpp) { "true" } else { "false" }
    $installPythonArg = if ($devEnvironment.Python) { "true" } else { "false" }

    $dockerfilePath = Join-Path $devDir "Dockerfile.codex"
    Write-Utf8NoBom $dockerfilePath (Get-ManagedDockerfileContent)
    $devContainerDefinitionChanged = $true

    $config = [ordered]@{
        name = "Codex Sandbox"
        build = [ordered]@{
            dockerfile = "Dockerfile.codex"
            args = [ordered]@{
                CODEX_BASE_IMAGE = "mcr.microsoft.com/devcontainers/base:ubuntu-24.04"
                CODEX_INSTALL_PHP = $installPhpArg
                CODEX_INSTALL_CPP = $installCppArg
                CODEX_INSTALL_PYTHON = $installPythonArg
                CODEX_NODE_VERSION = $devEnvironment.NodeVersion
                CODEX_DOTNET_VERSION = $devEnvironment.DotNetVersion
            }
        }
        workspaceMount = "source=$workspaceVolume,target=/workspaces,type=volume"
        workspaceFolder = "/workspaces"
        mounts = @(
            [ordered]@{
                source = $homeVolume
                target = "/home/vscode/.codex"
                type = "volume"
            }
            [ordered]@{
                source = $extensionVolume
                target = "/home/vscode/.vscode-server/extensions"
                type = "volume"
            }
        )
        remoteUser = "vscode"
        customizations = [ordered]@{
            vscode = [ordered]@{
                extensions = @("openai.chatgpt")
                settings = [ordered]@{
                    "files.exclude" = [ordered]@{ "/env/" = $true }
                    "editor.codeActionsOnSave" = [ordered]@{}
                }
            }
        }
        postCreateCommand = 'sudo chown -R vscode:vscode /home/vscode/.codex && chmod 700 /home/vscode/.codex && sudo chown vscode:vscode /home/vscode/.vscode-server/extensions && chmod 755 /home/vscode/.vscode-server/extensions'
    }

    Write-Utf8NoBom $configPath ($config | ConvertTo-Json -Depth 20)
    Write-Host "Erstellt: $dockerfilePath"
    Write-Host "Erstellt: $configPath"
    Write-Host "Noch keine Projektordner eingebunden; das erledigt später Codex Mount Manager."
}

# Für reproduzierbare Mount-Pfade wird Dev Containers verbindlich in der zuvor
# ausgewählten WSL-Distro ausgeführt. Lokale Windows-Laufwerke erscheinen dort
# unter /mnt/<laufwerk>; gemappte Netzlaufwerke werden vom Setup per drvfs an
# derselben Stelle bereitgestellt.
Set-VsCodeDevContainersWslHost $UbuntuDistro

Write-Host ""
Write-Host "Dev Containers Hostmodus: WSL (verbindlich)"
Write-Host "Dev-Containers-WSL: $UbuntuDistro"
Write-Host ""
Write-Host "Bind-Mounts werden dadurch auf allen Rechnern aus Sicht von WSL"
Write-Host "(z.B. /mnt/c/..., /mnt/d/..., /mnt/e/..., /mnt/y/...) gespeichert."
Step "Docker Desktop sicherstellen"

$docker = Get-Docker
$dockerDesktop = "$env:ProgramFiles\Docker\Docker\Docker Desktop.exe"

Write-Host "Docker CLI: $docker"

if (-not (Test-DockerReady $docker)) {
    if (-not (Start-DockerDesktopAndWait $docker $dockerDesktop)) {
        throw "Docker Desktop wurde nicht bereit."
    }
} else {
    Write-Host "Docker Engine läuft bereits."
}

Step "Docker aus WSL prüfen"

if (Test-WslDockerReady $UbuntuDistro) {
    Write-Host "Docker ist in $UbuntuDistro erreichbar." -ForegroundColor Green
} else {
    $firstProbe = Invoke-Probe "$env:WINDIR\System32\wsl.exe" @("-d",$UbuntuDistro,"--","docker","version")
    Show-ProbeFailure "Erster WSL-Docker-Test fehlgeschlagen" $firstProbe

    Write-Host ""
    Write-Warning "Docker ist in $UbuntuDistro nicht ueber Docker Desktop erreichbar."
    Write-Host "Bitte jetzt in Docker Desktop die WSL-Integration aktivieren:" -ForegroundColor Yellow
    Write-Host "  Settings -> Resources -> WSL integration"
    Write-Host "  Schalter bei '$UbuntuDistro' einschalten"
    Write-Host "  Danach unten rechts 'Apply & restart' anklicken"
    Write-Host ""
    Write-Host "Das Setup veraendert diese Docker-Desktop-Einstellung bewusst nicht automatisch."

    try { Start-Process -FilePath $dockerDesktop -ErrorAction SilentlyContinue | Out-Null } catch {}
    Read-Host "Nach 'Apply & restart' und abgeschlossenem Docker-Neustart ENTER druecken"

    Write-Host "Warte auf Docker Desktop..."
    if (-not (Wait-DockerReady $docker 300)) {
        throw "Docker Desktop wurde nach 'Apply & restart' nicht wieder bereit."
    }

    Write-Host "Pruefe Docker-Zugriff aus $UbuntuDistro erneut..."
    if (-not (Wait-WslDockerReady $UbuntuDistro 120)) {
        throw @"
Docker ist in '$UbuntuDistro' weiterhin nicht erreichbar.

Bitte in Docker Desktop unter
Settings -> Resources -> WSL integration
pruefen, ob der Schalter fuer '$UbuntuDistro' wirklich aktiviert ist und
'Apply & restart' ausgefuehrt wurde.
"@
    }
}

Step "Docker-Backend-Konsistenz pruefen"

if (-not (Test-SameDockerBackend $docker $UbuntuDistro)) {
    Write-Host ""
    Write-Warning "Der Docker-Befehl in $UbuntuDistro zeigt auf eine andere Docker Engine als Docker Desktop."
    Write-Host "Das spricht typischerweise dafuer, dass die Docker-Desktop-WSL-Integration fuer diese Distro nicht aktiv ist." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Bitte jetzt in Docker Desktop:" -ForegroundColor Yellow
    Write-Host "  Settings -> Resources -> WSL integration"
    Write-Host "  Schalter bei '$UbuntuDistro' einschalten"
    Write-Host "  Danach unten rechts 'Apply & restart' anklicken"
    Write-Host ""
    Write-Host "Falls der Schalter bereits eingeschaltet ist, einmal aus- und wieder einschalten und anschliessend 'Apply & restart' verwenden."

    try { Start-Process -FilePath $dockerDesktop -ErrorAction SilentlyContinue | Out-Null } catch {}
    Read-Host "Nach 'Apply & restart' und abgeschlossenem Docker-Neustart ENTER druecken"

    Write-Host "Warte auf Docker Desktop..."
    if (-not (Wait-DockerReady $docker 300)) {
        throw "Docker Desktop wurde nach 'Apply & restart' nicht wieder bereit."
    }

    Write-Host "Warte auf Docker-Integration in $UbuntuDistro..."
    if (-not (Wait-WslDockerReady $UbuntuDistro 120)) {
        throw "Docker-Zugriff aus '$UbuntuDistro' funktioniert nach 'Apply & restart' weiterhin nicht."
    }

    if (-not (Test-SameDockerBackend $docker $UbuntuDistro)) {
        throw @"
Windows-Docker und Docker in '$UbuntuDistro' verwenden weiterhin unterschiedliche
Docker Engines.

Bitte kontrollieren, ob in Docker Desktop unter
Settings -> Resources -> WSL integration
der Schalter fuer '$UbuntuDistro' aktiv ist. Nach einer Aenderung muss
'Apply & restart' ausgefuehrt werden.
"@
    }
}

Write-Host "Docker Desktop und $UbuntuDistro verwenden dieselbe Docker Engine." -ForegroundColor Green

Step "Persistente Docker-Volumes anlegen"

& $docker volume create $homeVolume
if ($LASTEXITCODE -ne 0) { throw "Docker-Volume $homeVolume konnte nicht angelegt werden." }

& $docker volume create $workspaceVolume
if ($LASTEXITCODE -ne 0) { throw "Docker-Volume $workspaceVolume konnte nicht angelegt werden." }

& $docker volume create $extensionVolume
if ($LASTEXITCODE -ne 0) { throw "Docker-Volume $extensionVolume konnte nicht angelegt werden." }

Step "VS-Code-Erweiterungen installieren"

Write-AtcCheckpoint "BEGIN Abschnitt VS-Code-Erweiterungen installieren"
$code = Get-Code
Write-Host "VS-Code-CLI: $code"
Write-AtcCheckpoint ("VS-Code-CLI aufgeloest: {0}" -f $code)

# ATC-Hotfix: Den Ist-Zustand direkt aus den installierten Extension-Verzeichnissen
# lesen. Dadurch entfaellt ein kompletter code.cmd-Prozess nur fuer
# --list-extensions. Falls mehrere Erweiterungen fehlen, werden sie in EINEM
# einzigen CLI-Aufruf installiert.
$installedVsCodeExtensions = Get-InstalledVsCodeExtensionVersions
Write-AtcCheckpoint ("VS-Code-Extensions ohne CLI ermittelt: {0}" -f $installedVsCodeExtensions.Count)

$pendingExtensionInstalls = New-Object System.Collections.ArrayList

function Queue-VsCodeMarketplaceExtension([string]$Id, [string]$Label) {
    $key = $Id.ToLowerInvariant()
    if ($installedVsCodeExtensions.ContainsKey($key)) {
        Write-Host "$Label ist bereits installiert; keine erneute Installation erforderlich." -ForegroundColor Green
        Write-AtcCheckpoint ("SKIP code --install-extension {0}; bereits installiert Version={1}" -f $Id, $installedVsCodeExtensions[$key])
        return
    }

    [void]$pendingExtensionInstalls.Add([pscustomobject]@{
        Argument = $Id
        Label = $Label
        Id = $key
        ExpectedVersion = ""
    })
}

Queue-VsCodeMarketplaceExtension "ms-vscode-remote.remote-containers" "Dev Containers"
Queue-VsCodeMarketplaceExtension "openai.chatgpt" "OpenAI/Codex"

$mountVsix = Join-Path $PSScriptRoot "tools\codex-mount-manager-0.3.8.vsix"
$mountManagerId = "zivi-local.codex-mount-manager"
$mountManagerVersion = "0.3.8"
Write-AtcCheckpoint ("Codex Mount Manager VSIX pruefen: {0}" -f $mountVsix)

if ($installedVsCodeExtensions.ContainsKey($mountManagerId) -and $installedVsCodeExtensions[$mountManagerId] -eq $mountManagerVersion) {
    Write-Host "Codex Mount Manager $mountManagerVersion ist bereits installiert; keine erneute Installation erforderlich." -ForegroundColor Green
    Write-AtcCheckpoint ("SKIP Codex Mount Manager; bereits installiert Version={0}" -f $mountManagerVersion)
}
elseif (Test-Path -LiteralPath $mountVsix) {
    try {
        $mountVsixHash = (Get-FileHash -LiteralPath $mountVsix -Algorithm SHA256).Hash
        Write-AtcCheckpoint ("Codex Mount Manager VSIX SHA256={0}" -f $mountVsixHash)
    } catch {
        Write-AtcCheckpoint ("Codex Mount Manager VSIX Hash nicht lesbar: {0}" -f $_.Exception.Message)
    }

    [void]$pendingExtensionInstalls.Add([pscustomobject]@{
        Argument = $mountVsix
        Label = "Codex Mount Manager"
        Id = $mountManagerId
        ExpectedVersion = $mountManagerVersion
    })
}
else {
    Write-AtcCheckpoint "Codex Mount Manager VSIX fehlt; Installationsaufruf wird uebersprungen"
    Write-Warning "Codex Mount Manager VSIX fehlt: $mountVsix"
}

if ($pendingExtensionInstalls.Count -gt 0) {
    $installArgs = @()
    foreach ($item in $pendingExtensionInstalls) {
        $installArgs += "--install-extension"
        $installArgs += [string]$item.Argument
    }
    $installArgs += "--force"

    Write-AtcCheckpoint ("BEFORE gebuendelter code --install-extension Aufruf Count={0}" -f $pendingExtensionInstalls.Count)
    & $code @installArgs
    $extensionInstallExit = $LASTEXITCODE
    Write-AtcCheckpoint ("AFTER gebuendelter code --install-extension Aufruf ExitCode={0}" -f $extensionInstallExit)

    if ($extensionInstallExit -ne 0) {
        throw "Mindestens eine erforderliche VS-Code-Erweiterung konnte nicht installiert werden."
    }

    $installedVsCodeExtensions = Get-InstalledVsCodeExtensionVersions
    foreach ($item in $pendingExtensionInstalls) {
        if (-not $installedVsCodeExtensions.ContainsKey($item.Id)) {
            throw ("{0} wurde nach dem VS-Code-CLI-Aufruf nicht als installiert erkannt." -f $item.Label)
        }
        if ($item.ExpectedVersion -and $installedVsCodeExtensions[$item.Id] -ne $item.ExpectedVersion) {
            throw ("{0}: erwartet Version {1}, gefunden {2}." -f $item.Label, $item.ExpectedVersion, $installedVsCodeExtensions[$item.Id])
        }
        Write-Host ("{0} ist installiert (Version {1})." -f $item.Label, $installedVsCodeExtensions[$item.Id]) -ForegroundColor Green
    }
}
else {
    Write-AtcCheckpoint "SKIP VS-Code-CLI Extension-Installation; alles bereits vorhanden"
}

Write-AtcCheckpoint "END Abschnitt VS-Code-Erweiterungen installieren"



function Get-CodexBinaryPathsInContainer([string]$Docker, [string]$ContainerId) {
    $roots = @(
        "/home/vscode/.vscode-server/extensions",
        "/home/vscode/.vscode-server-insiders/extensions",
        "/vscode/vscode-server/extensions"
    )

    $found = @()

    foreach ($rootPath in $roots) {
        # Fehlende optionale VS-Code-Server-Pfade sind normal.
        # Vor "find" deshalb immer explizit prüfen, ob der Pfad existiert.
        & $Docker exec -u vscode $ContainerId test -d $rootPath 2>$null
        if ($LASTEXITCODE -ne 0) {
            continue
        }

        # Nur auf einem nachweislich vorhandenen Verzeichnis suchen.
        # stderr wird in eine normale Stringvariable umgeleitet, damit
        # Windows PowerShell 5.1 + ErrorActionPreference=Stop einen
        # harmlosen nativen stderr-Text nicht als Terminierungsfehler behandelt.
        $tempErr = Join-Path $env:TEMP (
            "codex-find-" + [guid]::NewGuid().ToString("N") + ".err"
        )

        try {
            $result = @(
                & $Docker exec -u vscode $ContainerId `
                    find $rootPath `
                    -type f `
                    -path "*/openai.chatgpt-*/bin/linux-*/codex" `
                    2>$tempErr
            )

            $rc = $LASTEXITCODE

            if ($rc -ne 0) {
                $errText = ""
                if (Test-Path -LiteralPath $tempErr) {
                    $errText = (Get-Content -LiteralPath $tempErr -Raw -ErrorAction SilentlyContinue).Trim()
                }

                if ($errText) {
                    Write-Verbose "Codex-Binary-Suche unter '$rootPath' meldete: $errText"
                }

                continue
            }

            foreach ($line in $result) {
                $candidate = ([string]$line).Trim()

                if ($candidate -and $found -notcontains $candidate) {
                    $found += $candidate
                }
            }
        }
        finally {
            Remove-Item -LiteralPath $tempErr -Force -ErrorAction SilentlyContinue
        }
    }

    return @($found)
}

function Test-CodexBinaryInContainer([string]$Docker, [string]$ContainerId) {
    $paths = @(Get-CodexBinaryPathsInContainer $Docker $ContainerId)

    return [pscustomobject]@{
        Found  = ($paths.Count -gt 0)
        Detail = (($paths -join "`n").Trim())
    }
}

function Convert-WorkspacePathToDevContainerUri(
    [string]$HostWorkspace,
    [string]$ContainerWorkspace = "/workspaces"
) {
    $bytes = [Text.Encoding]::UTF8.GetBytes($HostWorkspace)
    $hex = (($bytes | ForEach-Object { $_.ToString("x2") }) -join "")
    return "vscode-remote://dev-container+$hex$ContainerWorkspace"
}

function Wait-ForCodexBinaryInContainer(
    [string]$Docker,
    [string]$ContainerId,
    [int]$TimeoutSeconds = 120
) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    while ((Get-Date) -lt $deadline) {
        $running = (& $Docker inspect -f "{{.State.Running}}" $ContainerId 2>$null).Trim()
        if ($running -ne "true") {
            & $Docker start $ContainerId | Out-Null
            Start-Sleep -Seconds 2
        }

        $check = Test-CodexBinaryInContainer $Docker $ContainerId
        if ($check.Found) {
            return $check
        }

        Start-Sleep -Seconds 2
    }

    return [pscustomobject]@{
        Found  = $false
        Detail = ""
    }
}

function Try-CompleteOpenAiRemoteInstall(
    [string]$CodeCli,
    [string]$Docker,
    [string]$ContainerId,
    [string]$HostWorkspace
) {
    Write-Host ""
    Write-Host "Der Codex-Binary fehlt noch im Dev Container."
    Write-Host "Öffne VS Code direkt im vorhandenen Dev Container und warte auf die"
    Write-Host "vollständige Remote-Extension-Installation..."

    $remoteUri = Convert-WorkspacePathToDevContainerUri $HostWorkspace "/workspaces"

    try {
        & $CodeCli --new-window --folder-uri $remoteUri
    }
    catch {
        Write-Warning "VS Code konnte nicht direkt im Dev Container geöffnet werden: $($_.Exception.Message)"
        return [pscustomobject]@{ Found = $false; Detail = "" }
    }

    $result = Wait-ForCodexBinaryInContainer $Docker $ContainerId 120

    if ($result.Found) {
        Write-Host "OpenAI/Codex wurde vollständig im Dev Container installiert." -ForegroundColor Green
    }

    return $result
}

function Test-OpenAiPresentForBootstrap([string]$Docker, [string]$ContainerId) {
    return Test-CodexBinaryInContainer $Docker $ContainerId
}

function Start-ContainerAndWaitForExec([string]$Docker, [string]$ContainerId) {
    & $Docker start $ContainerId | Out-Null
    if ($LASTEXITCODE -ne 0) {
        return $false
    }

    for ($i = 0; $i -lt 20; $i++) {
        & $Docker exec $ContainerId sh -c "true" *> $null
        if ($LASTEXITCODE -eq 0) {
            return $true
        }
        Start-Sleep -Seconds 1
    }

    return $false
}

function Find-DevContainerForExtensionMigration(
    [string]$Docker,
    [string]$Folder
) {
    $wantedFolder = Normalize-ComparablePath $Folder
    $wantedConfig = Normalize-ComparablePath (Join-Path $Folder ".devcontainer\devcontainer.json")
    $containers = @(Get-DockerContainers $Docker)

    foreach ($c in $containers) {
        if ((Normalize-ComparablePath $c.LocalFolder) -eq $wantedFolder) {
            return $c.ShortId
        }
    }

    foreach ($c in $containers) {
        if ((Normalize-ComparablePath $c.ConfigFile) -eq $wantedConfig) {
            return $c.ShortId
        }
    }

    return $null
}

function Test-ContainerUsesExtensionVolume(
    [string]$Docker,
    [string]$ContainerId,
    [string]$ExtensionVolume
) {
    $containers = @(Get-DockerContainers $Docker)

    foreach ($c in $containers) {
        if ($c.ShortId -ne $ContainerId -and $c.Id -ne $ContainerId) {
            continue
        }

        foreach ($m in @($c.Mounts)) {
            if (
                $m.Destination -eq "/home/vscode/.vscode-server/extensions" -and
                ($m.Name -eq $ExtensionVolume -or $m.Source -eq $ExtensionVolume -or $m.Source -like "*\$ExtensionVolume")
            ) {
                return $true
            }
        }
    }

    return $false
}

function Get-ContainerExtensionDirectoryNames(
    [string]$Docker,
    [string]$ContainerId
) {
    $rootPath = "/home/vscode/.vscode-server/extensions"

    & $Docker exec -u vscode $ContainerId test -d $rootPath *> $null
    if ($LASTEXITCODE -ne 0) {
        return @()
    }

    $result = @(
        & $Docker exec -u vscode $ContainerId `
            find $rootPath -mindepth 1 -maxdepth 1 -type d
    )

    if ($LASTEXITCODE -ne 0) {
        throw "VS-Code-Container-Erweiterungen konnten im vorhandenen Container nicht aufgelistet werden."
    }

    $names = @()

    foreach ($line in $result) {
        $candidate = ([string]$line).Trim()
        if (-not $candidate) {
            continue
        }

        $parts = @($candidate -split "/")
        $name = [string]$parts[$parts.Count - 1]

        if ($name -and $names -notcontains $name) {
            $names += $name
        }
    }

    return @($names | Sort-Object)
}

function Get-ContainerImageId(
    [string]$Docker,
    [string]$ContainerId
) {
    $imageId = (& $Docker inspect -f "{{.Image}}" $ContainerId).Trim()

    if ($LASTEXITCODE -ne 0 -or -not $imageId) {
        throw "Docker-Image des vorhandenen Dev Containers konnte nicht ermittelt werden."
    }

    return $imageId
}

function Test-DockerVolumeHasContent(
    [string]$Docker,
    [string]$VolumeName,
    [string]$HelperImage
) {
    $probeScript = 'if find /target -mindepth 1 -print -quit | grep -q .; then exit 0; else exit 1; fi'

    & $Docker run --rm --user root --entrypoint sh `
        -v "${VolumeName}:/target" `
        $HelperImage -c $probeScript *> $null

    $rc = $LASTEXITCODE

    if ($rc -eq 0) { return $true }
    if ($rc -eq 1) { return $false }

    throw "Inhalt des Docker-Volumes '$VolumeName' konnte nicht geprüft werden."
}

function Copy-ContainerExtensionsToPersistentVolume(
    [string]$Docker,
    [string]$ContainerId,
    [string]$ExtensionVolume
) {
    $token = ([guid]::NewGuid().ToString("N").ToLowerInvariant())
    $tempImage = "codex-extension-migration-$token"
    $imageCreated = $false

    function Get-DockerResultText($Result) {
        return (($Result.Output | ForEach-Object { [string]$_ }) -join "`n").Trim()
    }

    Write-Host "Erzeuge kurzzeitig ein lokales Migrations-Image aus dem vorhandenen Dev Container..."
    Write-AtcCheckpoint ("BEGIN Extension-Migration Container={0} Volume={1}" -f $ContainerId, $ExtensionVolume)

    try {
        Write-AtcCheckpoint ("BEFORE docker commit {0} {1}" -f $ContainerId, $tempImage)
        $commitResult = Invoke-DockerNoThrow $Docker @(
            "commit", $ContainerId, $tempImage
        )
        Write-AtcCheckpoint ("AFTER docker commit ExitCode={0}" -f $commitResult.ExitCode)

        if ($commitResult.ExitCode -ne 0) {
            $detail = Get-DockerResultText $commitResult
            throw ("Temporaeres Docker-Image fuer die Extension-Migration konnte nicht erzeugt werden." + $(if ($detail) { " Docker: $detail" } else { "" }))
        }
        $imageCreated = $true

        $copyScript = @'
set -eu
source=/home/vscode/.vscode-server/extensions
target=/target

if [ ! -d "$source" ]; then
    echo "SOURCE_MISSING"
    exit 41
fi

mkdir -p "$target"

if find "$target" -mindepth 1 -print -quit | grep -q .; then
    echo "TARGET_NOT_EMPTY"
    exit 42
fi

# Kein cp -a: Das Archiv-Attribut-/Ownership-Verhalten war auf einzelnen
# Docker-/Dateisystemkombinationen unnoetig empfindlich. Fuer VS-Code-
# Extensions muessen Inhalt, Symlinks und Ausfuehrungsbits erhalten bleiben;
# Besitzrechte werden anschliessend gezielt auf vscode:vscode gesetzt.
cp -R "$source"/. "$target"/
chown -R vscode:vscode "$target"
find "$target" -mindepth 1 -maxdepth 1 -type d | wc -l
'@

        Write-Host "Kopiere Erweiterungen direkt aus dem lokalen Migrations-Image in das persistente Docker-Volume..."
        Write-AtcCheckpoint ("BEFORE docker run Extension-Migration Image={0} Volume={1}" -f $tempImage, $ExtensionVolume)
        $copyResult = Invoke-DockerNoThrow $Docker @(
            "run", "--rm",
            "--user", "root",
            "--entrypoint", "sh",
            "-v", "${ExtensionVolume}:/target",
            $tempImage,
            "-c", $copyScript
        )
        Write-AtcCheckpoint ("AFTER docker run Extension-Migration ExitCode={0}" -f $copyResult.ExitCode)

        if ($copyResult.ExitCode -eq 41) {
            throw "Das bisherige VS-Code-Extensions-Verzeichnis ist im Migrations-Image nicht vorhanden."
        }
        if ($copyResult.ExitCode -eq 42) {
            throw "Das persistente Extensions-Volume ist nicht leer. Die Migration wurde zum Schutz vorhandener Daten abgebrochen."
        }
        if ($copyResult.ExitCode -ne 0) {
            $detail = Get-DockerResultText $copyResult
            throw ("VS-Code-Container-Erweiterungen konnten nicht in das persistente Docker-Volume kopiert werden." + $(if ($detail) { " Docker: $detail" } else { "" }))
        }

        $copiedCount = 0
        foreach ($line in $copyResult.Output) {
            $candidate = ([string]$line).Trim()
            if ($candidate -match '^\d+$') {
                $copiedCount = [int]$candidate
            }
        }

        Write-AtcCheckpoint ("END Extension-Migration Erfolg KopierteVerzeichnisse={0}" -f $copiedCount)
        return $copiedCount
    }
    finally {
        if ($imageCreated) {
            Write-AtcCheckpoint ("BEFORE docker image rm {0}" -f $tempImage)
            $removeImage = Invoke-DockerNoThrow $Docker @("image", "rm", "-f", $tempImage)
            Write-AtcCheckpoint ("AFTER docker image rm ExitCode={0}" -f $removeImage.ExitCode)
            if ($removeImage.ExitCode -ne 0) {
                Write-Warning "Temporaeres Extension-Migrations-Image '$tempImage' konnte nicht entfernt werden."
            }
        }
    }
}

Step "Vorhandene VS-Code-Container-Erweiterungen prüfen"

$migrationContainerId = $preflight.ContainerId

if (-not $migrationContainerId) {
    # Falls Docker bei der frühen Bestandsaufnahme noch nicht bereit war, jetzt
    # nach der Installation/Reparatur genau einmal nachholen.
    $migrationContainerId = Find-DevContainerForExtensionMigration $docker $InstallDirectory
}

if (-not $migrationContainerId) {
    Write-Host "Kein vorhandener Dev Container für eine Extension-Migration gefunden."
}
elseif ($preflight.ContainerId -eq $migrationContainerId -and $preflight.ContainerMounts -and $preflight.ContainerMounts.HasExtensionVolume) {
    Write-Host "Der vorhandene Dev Container verwendet das persistente Extensions-Volume bereits." -ForegroundColor Green
}
elseif (Test-ContainerUsesExtensionVolume $docker $migrationContainerId $extensionVolume) {
    Write-Host "Der vorhandene Dev Container verwendet das persistente Extensions-Volume bereits." -ForegroundColor Green
}
elseif (-not (Start-ContainerAndWaitForExec $docker $migrationContainerId)) {
    Write-Warning "Der vorhandene Dev Container konnte für die Extension-Migrationsprüfung nicht gestartet werden."
}
else {
    $existingExtensionNames = @()

    if ($preflight.ContainerId -eq $migrationContainerId -and $preflight.ExistingExtensionNames) {
        $existingExtensionNames = @($preflight.ExistingExtensionNames)
    }

    if ($existingExtensionNames.Count -eq 0) {
        $existingExtensionNames = @(Get-ContainerExtensionDirectoryNames $docker $migrationContainerId)
    }

    if ($existingExtensionNames.Count -eq 0) {
        Write-Host "Im bisherigen Container wurden keine VS-Code-Extension-Verzeichnisse gefunden."
    }
    else {
        $targetHasContent = $false
        $targetContentKnown = $false

        if (
            $preflight.ContainerId -eq $migrationContainerId -and
            $preflight.ExtensionVolumeExists -and
            $preflight.ExtensionVolumeContentKnown
        ) {
            $targetHasContent = [bool]$preflight.ExtensionVolumeHasContent
            $targetContentKnown = $true
        }

        if (-not $targetContentKnown) {
            $helperImage = Get-ContainerImageId $docker $migrationContainerId
            $targetHasContent = Test-DockerVolumeHasContent $docker $extensionVolume $helperImage
            $targetContentKnown = $true
        }

        if ($targetHasContent) {
            Write-Host "Das persistente Extensions-Volume enthält bereits Daten; eine erneute Migration wird nicht angeboten." -ForegroundColor Green
        }
        else {
            Write-Host ""
            Write-Host ("Im bisherigen Dev Container wurden {0} VS-Code-Erweiterung(en) gefunden:" -f $existingExtensionNames.Count) -ForegroundColor Cyan

            $maxShown = 20
            foreach ($name in @($existingExtensionNames | Select-Object -First $maxShown)) {
                Write-Host "  $name"
            }

            if ($existingExtensionNames.Count -gt $maxShown) {
                Write-Host ("  ... und {0} weitere" -f ($existingExtensionNames.Count - $maxShown))
            }

            Write-Host ""
            $takeOverExtensions = Ask-YesNo "Diese vorhandenen Container-Erweiterungen in das neue persistente Volume übernehmen?" $true

            if ($takeOverExtensions) {
                $copiedCount = Copy-ContainerExtensionsToPersistentVolume `
                    $docker `
                    $migrationContainerId `
                    $extensionVolume

                Write-Host ("Vorhandene VS-Code-Container-Erweiterungen wurden in '$extensionVolume' übernommen ({0} Verzeichnisse)." -f $copiedCount) -ForegroundColor Green
            }
            else {
                Write-Host "Vorhandene VS-Code-Container-Erweiterungen werden nicht übernommen." -ForegroundColor Yellow
                Write-Host "Beim nächsten Rebuild startet das persistente Extensions-Volume daher leer; deklarierte Extensions werden von VS Code erneut installiert."
            }
        }
    }
}

# Wenn devcontainer.json oder die verwaltete Dockerfile geändert wurde, darf ein
# bereits existierender Container nicht weiterverwendet werden. Die
# Extension-Migration ist zu diesem Zeitpunkt bereits abgeschlossen, daher kann
# der alte Container jetzt sicher entfernt werden. Benannte Volumes bleiben
# bestehen; entfernt wird nur der Container selbst.
if ($devContainerDefinitionChanged -and $preflight.ContainerId) {
    Step "Veralteten Dev Container für Rebuild entfernen"

    $oldContainerId = $preflight.ContainerId
    Write-Host "Dev-Container-Konfiguration wurde geändert." -ForegroundColor Yellow
    Write-Host "Der vorhandene Container '$oldContainerId' darf deshalb nicht weiterverwendet werden."
    Write-Host "Entferne nur den Container; die benannten Persistenz-Volumes bleiben erhalten."

    $removeOutput = @(& $docker rm -f $oldContainerId 2>&1)
    $removeRc = $LASTEXITCODE

    if ($removeOutput.Count -gt 0) {
        $removeOutput | ForEach-Object { Write-Host "  $_" }
    }

    # docker rm kann bei einem parallel laufenden Dev-Containers-Abbau bereits
    # "removal in progress" melden. Dann nicht wiederholt rm aufrufen, sondern
    # auf das tatsächliche Verschwinden des Containers warten.
    #
    # Wichtig: Ein anschließendes `docker inspect` auf einen erfolgreich
    # entfernten Container schreibt erwartungsgemäß "No such container" auf
    # stderr. Unter Windows PowerShell 5.1 kann das bei ErrorActionPreference=Stop
    # als terminierender Fehler behandelt werden. Deshalb prüfen wir die
    # Existenz über `docker ps -a -q --filter id=...`; ein leerer Treffer ist
    # hier der gewünschte Erfolgszustand.
    $removed = $false
    for ($i = 0; $i -lt 30; $i++) {
        $containerMatches = @(& $docker ps -a -q --no-trunc --filter "id=$oldContainerId")
        $psRc = $LASTEXITCODE

        if ($psRc -eq 0 -and @($containerMatches | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count -eq 0) {
            $removed = $true
            break
        }

        Start-Sleep -Seconds 1
    }

    if (-not $removed) {
        throw "Der veraltete Dev Container '$oldContainerId' konnte für den erforderlichen Rebuild nicht entfernt werden."
    }

    if ($removeRc -ne 0) {
        Write-Host "Der erste docker-rm-Aufruf meldete einen Fehler, der Container ist inzwischen aber entfernt." -ForegroundColor Yellow
    }

    Write-Host "Alter Dev Container entfernt. Der nächste Dev-Containers-Start erzeugt ihn aus der aktuellen Konfiguration neu." -ForegroundColor Green
    $forceDevContainerRebuild = $true
}

Step "Offene Chat-Migration prüfen"
Write-AtcCheckpoint "BEGIN Abschnitt Offene Chat-Migration pruefen"

if ($offerChatImport) {
    Write-Host "Importierbare Codex-Historie gefunden: $oldCodexHome"
    if ($historyState.Rollout) {
        Write-Host "Beispiel-Rollout:"
        Write-Host "  $($historyState.Rollout)"
    }
    if ($preflight.LocalHistoryComparison) {
        Write-Host ("Prüfgrund für die noch offene Migration: {0}" -f $preflight.LocalHistoryComparison.Reason) -ForegroundColor Yellow
    }
    Write-AtcCheckpoint "BEFORE Chat-Migrationsfrage"
    $importChats = Ask-YesNo "Sollen diese vorhandenen Chats in die Container-Umgebung übernommen werden?" $true
    Write-AtcCheckpoint ("AFTER Chat-Migrationsfrage Auswahl={0}" -f $(if ($importChats) { "Ja" } else { "Nein" }))
} elseif ($historyState.Importable -and $preflight.LocalHistoryAlreadyPresent) {
    Write-Host "Chatimport bereits erledigt; keine Rückfrage erforderlich." -ForegroundColor Green
    Write-AtcCheckpoint "SKIP Chat-Migrationsfrage; Historie bereits nachgewiesen"
} else {
    Write-Host "Kein Chatimport erforderlich oder möglich; keine Rückfrage erforderlich."
    Write-AtcCheckpoint "SKIP Chat-Migrationsfrage; keine importierbare/offene Historie"
}
Write-AtcCheckpoint "END Abschnitt Offene Chat-Migration pruefen"

Step "Vorhandenen Dev Container und Codex prüfen"

$containerId = if ($forceDevContainerRebuild) { $null } else { $preflight.ContainerId }
if (-not $containerId -and -not $forceDevContainerRebuild) {
    $containerId = Find-DevContainer $docker $InstallDirectory $workspaceVolume $homeVolume $extensionVolume
}
$needsVsCodeBootstrap = $true

if ($containerId) {
    Write-Host "Vorhandener Dev Container gefunden: $containerId"

    if (Start-ContainerAndWaitForExec $docker $containerId) {
        $existingOpenAi = Test-OpenAiPresentForBootstrap $docker $containerId

        if ($existingOpenAi.Found) {
            Write-Host "OpenAI/Codex ist im vorhandenen Dev Container bereits vorhanden." -ForegroundColor Green

            if ($existingOpenAi.Detail) {
                Write-Host "Erkannt über:"
                $existingOpenAi.Detail -split "`r?`n" | ForEach-Object {
                    Write-Host "  $_"
                }
            }

            Write-Host ""
            Write-Host "VS Code muss NICHT erneut für den Container-Aufbau geöffnet werden." -ForegroundColor Green
            $needsVsCodeBootstrap = $false
        }
        else {
            Write-Host "Der Dev Container existiert bereits, aber der echte Codex-Binary wurde darin noch nicht gefunden."
            Write-Host "Ein Download/Cache-Eintrag allein zählt nicht als vollständige Installation."
            Write-Host "Fehlende optionale VS-Code-Server-Verzeichnisse (z.B. Insiders) werden ignoriert."

            $autoOpenAi = Try-CompleteOpenAiRemoteInstall `
                $code `
                $docker `
                $containerId `
                $InstallDirectory

            if ($autoOpenAi.Found) {
                Write-Host "Codex-Binary:"
                Write-Host "  $($autoOpenAi.Detail)"
                Write-Host "Der manuelle Bootstrap-Schritt wird übersprungen." -ForegroundColor Green
                $needsVsCodeBootstrap = $false
            }
            else {
                Write-Host "Die automatische Remote-Installation wurde nicht innerhalb von 120 Sekunden abgeschlossen."
                Write-Host "Es folgt der manuelle Bootstrap als Fallback."
            }
        }
    }
    else {
        Write-Warning "Der vorhandene Dev Container konnte nicht gestartet werden."
        Write-Host "VS Code wird deshalb für den Neuaufbau geöffnet."
        $containerId = $null
    }
}
else {
    if ($forceDevContainerRebuild) {
        Write-Host "Der bisherige Dev Container wurde wegen geänderter Konfiguration entfernt." -ForegroundColor Yellow
        Write-Host "VS Code muss ihn jetzt einmal vollständig neu aufbauen."
    } else {
        Write-Host "Noch kein passender Dev Container vorhanden."
        Write-Host "Auf einem neuen Rechner muss VS Code ihn einmal erzeugen."
    }
}

if ($needsVsCodeBootstrap) {
    Step $(if ($forceDevContainerRebuild) { "Dev Container nach Konfigurationsänderung neu bauen" } else { "Dev Container erstmalig bauen" })

    $bootstrapReason = if ($forceDevContainerRebuild) {
        "Die Dev-Container-Konfiguration wurde geändert und der alte Container wurde entfernt."
    } else {
        "Es wurde noch kein vollständig vorbereiteter Dev Container mit OpenAI/Codex erkannt."
    }

    Write-Host @"

VS Code muss jetzt geöffnet werden.
Grund: $bootstrapReason

1. Strg+Shift+P

2. Ausführen:
     Dev Containers: Reopen in Container

3. Warten, bis VS Code vollständig im Container geöffnet ist.

4. Unten links muss sinngemäß stehen:
     Dev Container: Codex Sandbox

5. Codex/Chat NOCH NICHT öffnen.

6. VS Code GEÖFFNET LASSEN.

7. Zu diesem PowerShell-Fenster wechseln und ENTER drücken.

Die OpenAI/Codex-Extension musst du NICHT mehr manuell kontrollieren.
Das prüft das Setup anschließend selbst.

Wichtig: VS Code bleibt während der restlichen Setup-Prüfungen geöffnet,
damit Dev Containers den Container nicht durch shutdownAction stoppt.

"@

    Write-AtcCheckpoint "WAITING manueller VS-Code-/Dev-Container-Bootstrap"
    Write-Host "ATC-Mitigation: VS Code bitte MANUELL öffnen." -ForegroundColor Yellow
    Write-Host "Workspace: $InstallDirectory"
    Write-Host "Danach wie oben beschrieben 'Dev Containers: Reopen in Container' ausführen."
    Read-Host "Wenn der Dev Container vollständig geöffnet ist, VS Code GEÖFFNET LASSEN und hier ENTER drücken"
    Write-AtcCheckpoint "AFTER manueller VS-Code-/Dev-Container-Bootstrap"
    Write-Host "VS-Code-/Dev-Container-Aufbau wurde vom Benutzer bestätigt."

    Write-Host "Suche den erzeugten Dev Container..."

    $containerId = $null
    $deadline = (Get-Date).AddSeconds(60)

    while (-not $containerId -and (Get-Date) -lt $deadline) {
        $containerId = Find-DevContainer $docker $InstallDirectory $workspaceVolume $homeVolume $extensionVolume

        if (-not $containerId) {
            Start-Sleep -Seconds 3
        }
    }

    if (-not $containerId) {
        throw @"
Dev Container wurde nach dem VS-Code-Schritt nicht gefunden.

Das Log enthält direkt davor eine Liste aller Docker-Container,
der Dev-Container-Labels und der relevanten Mounts.

Falls in VS Code 'Dev Containers: Reopen in Container' einen Fehler gezeigt hat,
bitte zusätzlich diese VS-Code-Fehlermeldung bzw. das Dev-Containers-Log mitsenden.
"@
    }
}

Write-Host "Dev-Container-ID: $containerId"

Step "Dev Container für weitere Prüfungen starten"

& $docker start $containerId | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Dev Container '$containerId' konnte nicht gestartet werden."
}

# Kurz warten, bis docker exec zuverlässig möglich ist.
$containerReady = $false
for ($i = 0; $i -lt 20; $i++) {
    & $docker exec $containerId sh -c "true" *> $null
    if ($LASTEXITCODE -eq 0) {
        $containerReady = $true
        break
    }
    Start-Sleep -Seconds 1
}

if (-not $containerReady) {
    throw "Dev Container '$containerId' läuft, akzeptiert aber noch keine docker-exec-Aufrufe."
}

Step "OpenAI/Codex-Extension im Dev Container prüfen"

function Test-OpenAiExtensionInContainer([string]$Docker, [string]$ContainerId) {
    return Test-CodexBinaryInContainer $Docker $ContainerId
}

Write-Host "Prüfe den tatsächlich installierten Codex-Binary..."

$openaiResult = $null
$deadline = (Get-Date).AddSeconds(30)

while ((Get-Date) -lt $deadline) {
    # Der Container kann nach dem Schließen des letzten VS-Code-Fensters
    # automatisch wieder gestoppt worden sein. Dann erneut starten.
    $running = (& $docker inspect -f "{{.State.Running}}" $containerId 2>$null).Trim()

    if ($running -ne "true") {
        Write-Host "Dev Container wurde gestoppt; starte ihn erneut..."
        & $docker start $containerId | Out-Null
        Start-Sleep -Seconds 2
    }

    $openaiResult = Test-OpenAiExtensionInContainer $docker $containerId

    if ($openaiResult.Found) {
        break
    }

    Start-Sleep -Seconds 2
}

if (-not $openaiResult -or -not $openaiResult.Found) {
    Write-Host ""
    Write-Host "Codex-Binary fehlt noch. Versuche einmal die automatische Remote-Installation..." -ForegroundColor Yellow

    $openaiResult = Try-CompleteOpenAiRemoteInstall `
        $code `
        $docker `
        $containerId `
        $InstallDirectory

    if (-not $openaiResult.Found) {
        Write-Host ""
        Write-Host "Diagnose der VS-Code-Server-Verzeichnisse:" -ForegroundColor Yellow

        & $docker exec -u vscode $containerId sh -c `
            "find /home/vscode/.vscode-server /vscode/vscode-server -maxdepth 4 -iname '*openai*' 2>/dev/null | head -n 100"

        throw @"
OpenAI/Codex wurde möglicherweise bereits heruntergeladen, aber der tatsächliche
Codex-Binary ist im Dev Container noch nicht installiert.

Erwartet wird ein Pfad ähnlich:

  /home/vscode/.vscode-server/extensions/openai.chatgpt-.../bin/linux-.../codex

Ein Eintrag im VS-Code-Downloadcache reicht nicht aus.

Bitte VS Code direkt im Dev Container geöffnet lassen, bis die
OpenAI-Erweiterung vollständig installiert wurde. Danach Setup erneut starten.
"@
    }
}

Write-Host "OpenAI/Codex-Binary ist im Dev Container vollständig installiert." -ForegroundColor Green
if ($openaiResult.Detail) {
    Write-Host "Erkannt über:"
    $openaiResult.Detail -split "`r?`n" | ForEach-Object {
        Write-Host "  $_"
    }
}

if (-not $importChats) {
    Step "Codex-Datenbank vorab initialisieren"
    Write-Host "Kein Chatimport angefordert."
    Write-Host "Eine Codex-Datenbank wird deshalb jetzt noch NICHT künstlich erzeugt."
    Write-Host "Codex legt sein aktuelles Schema beim ersten normalen Start selbst an."
}

if ($importChats) {
    Write-AtcCheckpoint "BEGIN Abschnitt Chat-Import"
    Write-AtcCheckpoint "BEFORE Ensure-FreshCodexDb"
    Ensure-FreshCodexDb $docker $containerId
    Write-AtcCheckpoint "AFTER Ensure-FreshCodexDb"

    Step "Vorhandene Codex-Chats isoliert importieren"
    Write-Host "Der Import läuft nicht mehr in einer zweiten Windows-PowerShell." -ForegroundColor Green
    Write-Host "Ein kurzlebiger Helper-Container erhält nur:"
    Write-Host "  - die lokale .codex-Quelle read-only"
    Write-Host "  - das persistente .codex-Zielvolume read/write"
    Write-Host "  - keinen Netzwerkzugriff"
    Write-Host "  - keinen Docker-Socket"

    $chatFingerprint = Get-CodexHistoryFingerprint $oldCodexHome
    Write-Host ("Quell-Fingerprint: {0} ({1} Dateien, {2:N0} Bytes)" -f `
        $chatFingerprint.Fingerprint,
        $chatFingerprint.FileCount,
        $chatFingerprint.TotalBytes)

    Write-AtcCheckpoint "BEFORE isolated docker chat-import helper"
    $chatImport = Invoke-CodexChatImportHelper `
        $docker `
        $containerId `
        $oldCodexHome `
        $homeVolume `
        $chatFingerprint.Fingerprint `
        "import"
    Write-AtcCheckpoint ("AFTER isolated docker chat-import helper ExitCode={0}" -f $chatImport.ExitCode)

    foreach ($line in $chatImport.Output) {
        if ("$line".Trim()) { Write-Host "$line" }
    }

    if ($chatImport.ExitCode -ne 0) {
        throw ("Isolierter Chat-Import fehlgeschlagen (Exitcode {0})." -f $chatImport.ExitCode)
    }

    Write-Host "Vorhandene Codex-Chats wurden übernommen bzw. waren bereits vorhanden." -ForegroundColor Green
    Write-Host "auth.json wurde absichtlich nicht übernommen."
    Write-AtcCheckpoint "END Abschnitt Chat-Import"
}

Step "Sandbox prüfen"

if (-not (Wait-ContainerExecReady $docker $containerId 20)) {
    throw "Dev Container '$containerId' konnte für den Sandbox-Test nicht gestartet werden."
}

$protectedRuntimeHostPaths = @(Get-ProtectedRuntimeHostPaths)
$protectedRuntimeHostPathList = ($protectedRuntimeHostPaths | ForEach-Object { "'" + ($_ -replace "'", "'\''") + "'" }) -join ' '

$sandboxScript = @"
set -u

echo "=== /workspaces ==="
ls -la /workspaces
echo
echo "=== Unerwünschte Host-Pfade ==="

bad=0
for p in $protectedRuntimeHostPathList
do
    if [ -e "`$p" ]; then
        echo "SICHTBAR: `$p"
        bad=1
    else
        echo "NICHT VORHANDEN: `$p"
    fi
done

exit "`$bad"
"@

$sandboxRc = Invoke-ContainerShellScript `
    $docker `
    $containerId `
    $sandboxScript `
    "vscode" `
    "sandbox-check"

if ($sandboxRc -ne 0) {
    Write-Warning "Mindestens ein unerwünschter Host-Pfad ist sichtbar. Vor Codex-Nutzung prüfen."
} else {
    Write-Host "Isolationstest bestanden." -ForegroundColor Green
}


function Convert-StringToHex([string]$Value) {
    $bytes = [Text.Encoding]::UTF8.GetBytes($Value)
    return (($bytes | ForEach-Object { $_.ToString("x2") }) -join "")
}

function Open-VsCodeInDevContainer(
    [string]$CodeCli,
    [string]$HostWorkspace,
    [string]$ContainerWorkspace = "/workspaces"
) {
    Step "VS Code direkt im Dev Container starten"

    if (-not $CodeCli -or -not (Test-Path -LiteralPath $CodeCli)) {
        Write-Warning "VS-Code-CLI nicht gefunden. VS Code konnte nicht automatisch gestartet werden."
        return $false
    }

    # Dev Containers kann über vscode-remote:// direkt geöffnet werden.
    # Die Authority verwendet den UTF-8-hexkodierten lokalen Workspace-Pfad.
    $hostHex = Convert-StringToHex $HostWorkspace
    $remoteUri = "vscode-remote://dev-container+$hostHex$ContainerWorkspace"

    # Der Container kann durch shutdownAction zwischenzeitlich gestoppt worden
    # sein. Vor dem finalen VS-Code-Start robust wieder ausführbar machen.
    if (-not (Wait-ContainerExecReady $docker $containerId 20)) {
        Write-Warning "Dev Container konnte vor dem VS-Code-Start nicht zuverlässig gestartet werden."
    }

    Write-Host "Öffne VS Code direkt im Dev Container:"
    Write-Host "  $ContainerWorkspace"

    try {
        & $CodeCli --new-window --folder-uri $remoteUri

        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Direkter Dev-Container-Start lieferte Exitcode $LASTEXITCODE."
            Write-Host "Fallback: Öffne den lokalen Codex-Container-Workspace."
            & $CodeCli --new-window $HostWorkspace
            return $false
        }

        Write-Host "VS Code wurde für den Dev Container gestartet." -ForegroundColor Green
        return $true
    }
    catch {
        Write-Warning "Direkter VS-Code-Start fehlgeschlagen: $($_.Exception.Message)"
        Write-Host "Fallback: Öffne den lokalen Codex-Container-Workspace."
        & $CodeCli --new-window $HostWorkspace
        return $false
    }
}

Step "Fertig"

Write-Host ""
Write-Host "Das technische Setup ist abgeschlossen." -ForegroundColor Green
Write-Host ""

Write-AtcCheckpoint "SKIP automatischer finaler VS-Code-Start; ATC-Mitigation aktiv"
$vsCodeDirect = $false
Write-Host "ATC-Mitigation: VS Code wird am Ende nicht aus PowerShell gestartet." -ForegroundColor Yellow
Write-Host "Falls es nicht mehr offen ist, VS Code bitte manuell mit dem Codex-Workspace öffnen."

Write-Host ""
Write-Host "In VS Code anschließend:"
Write-Host "  1. Links 'Codex Mounts' öffnen."
Write-Host "  2. Nur die benötigten Projektordner per + oder Drag&Drop einbinden."
Write-Host "  3. Gewünschten Target-Namen unter /workspaces vergeben."
Write-Host "     Leerzeichen sind erlaubt."
Write-Host "  4. Falls Mounts geändert wurden: Container über Codex Mount Manager neu erstellen."
Write-Host "  5. Danach Codex öffnen und anmelden."

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host " SETUP ERFOLGREICH ABGESCHLOSSEN" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Write-Host "Codex-Dev-Container, Erweiterungen, Chatimport und Sandbox-Prüfung"
Write-Host "wurden ohne Fehler abgeschlossen."

Write-Host "VS Code wurde aus ATC-Gründen nicht automatisch gestartet." -ForegroundColor Yellow

if ($script:LogPath) {
    Write-Host ""
    Write-Host "Logfile:"
    Write-Host "  $script:LogPath" -ForegroundColor Green
}

Write-Host ""
[void](Read-Host "ENTER drücken, um dieses Fenster zu schließen")

Stop-SetupLog
exit 0
