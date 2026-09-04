param(
    [string]$InstallDirectory = "$env:USERPROFILE\Documents\Codex-Container",
    [string]$UbuntuDistro = "",
    [string]$VolumePrefix = "codex-sandbox",
    [switch]$LogFile,
    [switch]$Validated
)

$ErrorActionPreference = "Stop"

function Test-SetupAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-SetupFiles {
    $scriptPath = Join-Path $PSScriptRoot "Setup-NewCodexComputer.ps1"
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
        throw "Setup-NewCodexComputer.ps1 fehlt: $scriptPath"
    }

    $rawBytes = [System.IO.File]::ReadAllBytes($scriptPath)
    $hasUtf8Bom = (
        $rawBytes.Length -ge 3 -and
        $rawBytes[0] -eq 0xEF -and
        $rawBytes[1] -eq 0xBB -and
        $rawBytes[2] -eq 0xBF
    )

    if (-not $hasUtf8Bom) {
        throw "Setup-NewCodexComputer.ps1 ist nicht als UTF-8 mit BOM gespeichert."
    }

    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile(
        $scriptPath,
        [ref]$tokens,
        [ref]$errors
    )

    if ($errors.Count -gt 0) {
        foreach ($e in $errors) {
            Write-Host ("Zeile {0}, Zeichen {1}: {2}" -f $e.Extent.StartLineNumber, $e.Extent.StartColumnNumber, $e.Message) -ForegroundColor Red
        }
        throw "PowerShell-Syntaxcheck fehlgeschlagen."
    }

    $helperPath = Join-Path $PSScriptRoot "tools\Import-CodexChatsHelper.py"
    $expectedHelperSha256 = "9099F2671970CA0ACF29AF6DE0964F287767420C880FA8D84B7F4DA6FA5388C5"

    if (-not (Test-Path -LiteralPath $helperPath -PathType Leaf)) {
        throw "Chatimport-Helper fehlt: $helperPath"
    }

    $helperHash = (Get-FileHash -LiteralPath $helperPath -Algorithm SHA256).Hash.ToUpperInvariant()
    if ($helperHash -ne $expectedHelperSha256) {
        throw "Chatimport-Helper hat eine unerwartete SHA-256-Pruefsumme."
    }

    Write-Host "PowerShell-Syntaxcheck: OK" -ForegroundColor Green
    Write-Host "Chatimport-Helper Integritaet: OK" -ForegroundColor Green
}

try {
    if (-not $Validated) {
        Test-SetupFiles
    }

    if (-not (Test-SetupAdmin)) {
        Write-Host "Setup wird mit Administratorrechten neu gestartet..." -ForegroundColor Yellow

        $argLine = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Validated -InstallDirectory `"$InstallDirectory`" -VolumePrefix `"$VolumePrefix`""
        if (-not [string]::IsNullOrWhiteSpace($UbuntuDistro)) {
            $argLine += " -UbuntuDistro `"$UbuntuDistro`""
        }
        if ($LogFile) {
            $argLine += " -LogFile"
        }

        Start-Process powershell.exe -Verb RunAs -ArgumentList $argLine
        exit 0
    }

    $setupPath = Join-Path $PSScriptRoot "Setup-NewCodexComputer.ps1"
    $setupArgs = @{
        InstallDirectory = $InstallDirectory
        VolumePrefix = $VolumePrefix
    }
    if (-not [string]::IsNullOrWhiteSpace($UbuntuDistro)) {
        $setupArgs.UbuntuDistro = $UbuntuDistro
    }
    if ($LogFile) {
        $setupArgs.LogFile = $true
    }

    & $setupPath @setupArgs
    exit 0
}
catch {
    Write-Host ""
    Write-Host "SETUP-START FEHLER" -ForegroundColor Red
    Write-Host "==================" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}
