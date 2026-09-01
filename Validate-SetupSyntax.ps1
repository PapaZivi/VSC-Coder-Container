param(
    [string]$ScriptPath = (Join-Path $PSScriptRoot "Setup-NewCodexComputer.ps1")
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $ScriptPath)) {
    Write-Host "SETUP-SYNTAXCHECK FEHLER" -ForegroundColor Red
    Write-Host "Datei nicht gefunden: $ScriptPath"
    exit 2
}

$rawBytes = [System.IO.File]::ReadAllBytes($ScriptPath)
$hasUtf8Bom = (
    $rawBytes.Length -ge 3 -and
    $rawBytes[0] -eq 0xEF -and
    $rawBytes[1] -eq 0xBB -and
    $rawBytes[2] -eq 0xBF
)

if (-not $hasUtf8Bom) {
    Write-Host ""
    Write-Host "SETUP-ENCODINGCHECK FEHLER" -ForegroundColor Red
    Write-Host "=========================="
    Write-Host ""
    Write-Host "Setup-NewCodexComputer.ps1 ist nicht als UTF-8 mit BOM gespeichert." -ForegroundColor Red
    Write-Host "Windows PowerShell 5.1 kann UTF-8 ohne BOM bei Umlauten falsch parsen."
    Write-Host "Das eigentliche Setup wurde NICHT gestartet."
    exit 4
}

$tokens = $null
$errors = $null

[void][System.Management.Automation.Language.Parser]::ParseFile(
    $ScriptPath,
    [ref]$tokens,
    [ref]$errors
)

if ($errors.Count -gt 0) {
    Write-Host ""
    Write-Host "SETUP-SYNTAXCHECK FEHLER" -ForegroundColor Red
    Write-Host "========================"
    Write-Host ""

    foreach ($e in $errors) {
        Write-Host ("Zeile {0}, Zeichen {1}: {2}" -f `
            $e.Extent.StartLineNumber, `
            $e.Extent.StartColumnNumber, `
            $e.Message) -ForegroundColor Red

        if ($e.Extent.Text) {
            Write-Host ("  " + $e.Extent.Text)
        }
    }

    Write-Host ""
    Write-Host "Das eigentliche Setup wurde NICHT gestartet."
    exit 3
}

$helperPath = Join-Path $PSScriptRoot "tools\Import-CodexChatsHelper.py"
$expectedHelperSha256 = "9099F2671970CA0ACF29AF6DE0964F287767420C880FA8D84B7F4DA6FA5388C5"

if (-not (Test-Path -LiteralPath $helperPath -PathType Leaf)) {
    Write-Host ""
    Write-Host "SETUP-INTEGRITYCHECK FEHLER" -ForegroundColor Red
    Write-Host "==========================="
    Write-Host ""
    Write-Host "Chatimport-Helper fehlt: $helperPath" -ForegroundColor Red
    Write-Host "Das eigentliche Setup wurde NICHT gestartet."
    exit 5
}

$helperHash = (Get-FileHash -LiteralPath $helperPath -Algorithm SHA256).Hash.ToUpperInvariant()
if ($helperHash -ne $expectedHelperSha256) {
    Write-Host ""
    Write-Host "SETUP-INTEGRITYCHECK FEHLER" -ForegroundColor Red
    Write-Host "==========================="
    Write-Host ""
    Write-Host "Chatimport-Helper hat eine unerwartete SHA-256-Prüfsumme." -ForegroundColor Red
    Write-Host "Erwartet: $expectedHelperSha256"
    Write-Host "Gefunden: $helperHash"
    Write-Host "Das eigentliche Setup wurde NICHT gestartet."
    exit 6
}

Write-Host "PowerShell-Syntaxcheck: OK" -ForegroundColor Green
Write-Host "Chatimport-Helper Integrität: OK" -ForegroundColor Green
exit 0
