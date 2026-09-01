param(
    [string]$InstallDirectory = "$env:USERPROFILE\Documents\Codex-Container"
)

$ErrorActionPreference = "Stop"

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

function Find-DevContainer([string]$Docker, [string]$Folder) {
    $wanted = [IO.Path]::GetFullPath($Folder).TrimEnd("\").ToLowerInvariant()

    foreach ($id in (& $Docker ps -a --filter "label=devcontainer.local_folder" --format "{{.ID}}")) {
        $label = (& $Docker inspect -f '{{ index .Config.Labels "devcontainer.local_folder" }}' $id 2>$null).Trim()
        if (-not $label) { continue }

        try { $norm = [IO.Path]::GetFullPath($label).TrimEnd("\").ToLowerInvariant() }
        catch { $norm = $label.TrimEnd("\").ToLowerInvariant() }

        if ($norm -eq $wanted) { return $id }
    }

    return $null
}

function Get-MountValue([object]$Mount, [string]$Name) {
    if ($null -eq $Mount) { return $null }
    if ($Mount -is [string]) {
        foreach ($part in ([string]$Mount -split ',')) {
            $pair = @($part -split '=', 2)
            if ($pair.Count -eq 2 -and $pair[0].Trim() -eq $Name) { return $pair[1].Trim() }
        }
        return $null
    }
    $property = $Mount.PSObject.Properties[$Name]
    if ($property) { return [string]$property.Value }
    return $null
}

function Convert-WslDriveSource([string]$Source) {
    if ([string]::IsNullOrWhiteSpace($Source)) { return $null }
    if ($Source.Trim() -match '^/mnt/([A-Za-z])(?:/(.*))?$') {
        $drive = $Matches[1].ToUpperInvariant()
        $tail = [string]$Matches[2]
        if ([string]::IsNullOrWhiteSpace($tail)) { return "${drive}:\" }
        return "${drive}:\$($tail -replace '/', '\')"
    }
    return $null
}

function Normalize-WinPath([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    try { return ([IO.Path]::GetFullPath($Value.Trim())).TrimEnd('\','/').ToLowerInvariant() }
    catch { return $null }
}

function Test-PathEqual([string]$Candidate, [string]$ProtectedPath) {
    $a = Normalize-WinPath $Candidate
    $b = Normalize-WinPath $ProtectedPath
    return ($a -and $b -and $a -eq $b)
}

function Test-PathInside([string]$Candidate, [string]$ProtectedPath) {
    $a = Normalize-WinPath $Candidate
    $b = Normalize-WinPath $ProtectedPath
    if (-not $a -or -not $b) { return $false }
    return ($a -eq $b -or $a.StartsWith($b + '\', [StringComparison]::OrdinalIgnoreCase))
}

function Get-DriveRoot([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    try { return [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Value.Trim())) }
    catch { return $null }
}

function Get-SecurityContext {
    $systemRoot = if ($env:SystemRoot) { $env:SystemRoot } elseif ($env:WINDIR) { $env:WINDIR } elseif ($env:SystemDrive) { "$($env:SystemDrive)\Windows" } else { $null }
    $userProfile = $env:USERPROFILE
    $systemDriveSource = if ($systemRoot) { $systemRoot } else { $env:SystemDrive }
    $userDriveSource = if ($userProfile) { $userProfile } else { $env:HOMEDRIVE }
    $systemDrive = Get-DriveRoot $systemDriveSource
    $userDrive = Get-DriveRoot $userDriveSource
    $usersRoot = if ($userProfile) { Split-Path -Parent ([IO.Path]::GetFullPath($userProfile)) } else { $null }

    $exact = @(
        [pscustomobject]@{ Path=$systemDrive; Reason='Windows-Systemlaufwerk als Ganzes' },
        [pscustomobject]@{ Path=$userDrive; Reason='Laufwerk des Benutzerprofils als Ganzes' },
        [pscustomobject]@{ Path=$usersRoot; Reason='Benutzerverzeichnis-Stamm' },
        [pscustomobject]@{ Path=$userProfile; Reason='komplettes Benutzerprofil' }
    ) | Where-Object { $_.Path }

    $subtree = @(
        [pscustomobject]@{ Path=$systemRoot; Reason='Windows-Systemverzeichnis' },
        [pscustomobject]@{ Path=$env:ProgramFiles; Reason='Program Files' },
        [pscustomobject]@{ Path=${env:ProgramFiles(x86)}; Reason='Program Files (x86)' },
        [pscustomobject]@{ Path=$env:ProgramData; Reason='ProgramData' }
    ) | Where-Object { $_.Path }

    if ($systemDrive) {
        $subtree += [pscustomobject]@{ Path=(Join-Path $systemDrive 'Recovery'); Reason='Recovery' }
        $subtree += [pscustomobject]@{ Path=(Join-Path $systemDrive 'System Volume Information'); Reason='System Volume Information' }
        $subtree += [pscustomobject]@{ Path=(Join-Path $systemDrive '$Recycle.Bin'); Reason='$Recycle.Bin' }
        $subtree += [pscustomobject]@{ Path=(Join-Path $systemDrive 'Boot'); Reason='Boot' }
        $subtree += [pscustomobject]@{ Path=(Join-Path $systemDrive 'Windows.old'); Reason='Windows.old' }
        $subtree += [pscustomobject]@{ Path=(Join-Path $systemDrive 'Documents and Settings'); Reason='Documents and Settings' }
    }
    if ($userProfile) {
        foreach ($name in @('AppData','.ssh','.gnupg','.aws','.azure','.kube','.docker','.codex','.vscode','.config')) {
            $subtree += [pscustomobject]@{ Path=(Join-Path $userProfile $name); Reason="sensibles Benutzerverzeichnis $name" }
        }
    }

    return [pscustomobject]@{
        Exact=$exact; Subtree=$subtree; UsersRoot=$usersRoot; UserProfile=$userProfile;
        SystemDrive=$systemDrive; UserDrive=$userDrive
    }
}

function Get-SecurityViolation([string]$Source) {
    if ([string]::IsNullOrWhiteSpace($Source)) { return 'leere Quelle' }
    $raw = $Source.Trim()
    $candidate = Convert-WslDriveSource $raw
    if (-not $candidate -and $raw -match '^[A-Za-z]:(?:[\\/]|$)') { $candidate = $raw }

    if ($candidate) {
        $ctx = Get-SecurityContext
        foreach ($rule in $ctx.Exact) { if (Test-PathEqual $candidate $rule.Path) { return $rule.Reason } }
        foreach ($rule in $ctx.Subtree) { if (Test-PathInside $candidate $rule.Path) { return $rule.Reason } }
        if ($ctx.UsersRoot -and ([IO.Path]::GetFileName($ctx.UsersRoot.TrimEnd('\')) -ieq 'Users') -and
            (Test-PathInside $candidate $ctx.UsersRoot) -and $ctx.UserProfile -and -not (Test-PathInside $candidate $ctx.UserProfile)) {
            return 'anderes Windows-Benutzerprofil'
        }
        return $null
    }

    $linux = ($raw -replace '\\','/').TrimEnd('/')
    if (-not $linux) { $linux = '/' }
    if ($linux -eq '/var/run/docker.sock' -or $linux -eq '/run/docker.sock') { return 'Docker-Socket' }
    foreach ($prefix in @('/etc','/root','/proc','/sys','/dev','/boot','/var/lib/docker','/run/desktop/mnt/host','/mnt/wsl','/host')) {
        if ($linux -eq $prefix -or $linux.StartsWith($prefix + '/', [StringComparison]::Ordinal)) { return "geschützter Hostpfad $prefix" }
    }
    if ($linux -eq '/') { return 'Host-Wurzeldateisystem' }
    return $null
}

$configFile = Join-Path $InstallDirectory '.devcontainer\devcontainer.json'
if (Test-Path -LiteralPath $configFile -PathType Leaf) {
    $cfg = (Get-Content -LiteralPath $configFile -Raw) | ConvertFrom-Json
    $unsafe = @()
    $allMounts = @()
    if ($cfg.workspaceMount) { $allMounts += $cfg.workspaceMount }
    $allMounts += @($cfg.mounts)
    foreach ($mount in $allMounts) {
        $type = Get-MountValue $mount 'type'
        if ($type -ne 'bind') { continue }
        $source = Get-MountValue $mount 'source'
        if (-not $source) { $source = Get-MountValue $mount 'src' }
        $target = Get-MountValue $mount 'target'
        if (-not $target) { $target = Get-MountValue $mount 'dst' }
        $reason = Get-SecurityViolation $source
        if ($reason) { $unsafe += [pscustomobject]@{ Source=$source; Target=$target; Reason=$reason } }
    }
    if ($unsafe.Count -gt 0) {
        Write-Host 'Sicherheitskritische Bind-Mounts gefunden:' -ForegroundColor Red
        $unsafe | ForEach-Object { Write-Host "  $($_.Source) -> $($_.Target): $($_.Reason)" -ForegroundColor Red }
        throw 'Sandbox-Prüfung abgebrochen: devcontainer.json enthält sicherheitskritische Bind-Mounts.'
    }
}

$docker = Get-Docker
$id = Find-DevContainer $docker $InstallDirectory
if (-not $id) { throw "Dev Container nicht gefunden." }

& $docker start $id | Out-Null

$ctx = Get-SecurityContext
$runtimePaths = @()
$driveRoots = @($ctx.SystemDrive,$ctx.UserDrive) | Where-Object { $_ } | Select-Object -Unique
foreach ($driveRoot in $driveRoots) {
    $letter = ([IO.Path]::GetPathRoot($driveRoot)).Substring(0,1).ToLowerInvariant()
    $runtimePaths += "/mnt/$letter"
}
$runtimePaths += @('/host','/run/desktop/mnt/host','/var/run/docker.sock','/run/docker.sock','/mnt/wsl')
$runtimePaths = @($runtimePaths | Select-Object -Unique)
$runtimeList = ($runtimePaths | ForEach-Object { "'$_'" }) -join ' '

$checkScript = @"
echo "=== /workspaces ==="
ls -la /workspaces
echo
echo "=== Unerwünschte Host-Pfade ==="
bad=0
for p in $runtimeList; do
  if [ -e "`$p" ]; then
    echo "SICHTBAR: `$p"
    bad=1
  else
    echo "NICHT VORHANDEN: `$p"
  fi
done
exit `$bad
"@

& $docker exec $id sh -lc $checkScript

if ($LASTEXITCODE -eq 0) {
    Write-Host ""
    Write-Host "Sandbox-Prüfung bestanden." -ForegroundColor Green
} else {
    Write-Warning "Mindestens ein unerwünschter Host-Pfad ist sichtbar."
}
