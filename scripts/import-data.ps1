<#
.SYNOPSIS
    Restores a portable folder on a new computer and relinks every workspace.

.DESCRIPTION
    Accepts the zip made by export-data.ps1 or a portable folder copied as is.
    Then sets CLAUDE_CONFIG_DIR and asks, workspace by workspace, where each project lives now.
#>
param(
    [Parameter(Mandatory = $true)][string]$From,
    [string]$DataDir = (Join-Path $env:USERPROFILE 'claude-data'),
    [switch]$SkipEnvironment,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\common.ps1')
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem

$From = ConvertTo-NormalizedPath $From
$DataDir = ConvertTo-NormalizedPath $DataDir

Write-Host ''
Write-Host 'claude-portable - import' -ForegroundColor White
Write-Info "From: $From"
Write-Info "To  : $DataDir"
if (-not (Test-Path -LiteralPath $From)) { throw "Not found: $From" }

$copyInPlace = (Test-Path -LiteralPath $From -PathType Container) -and ($From -ieq $DataDir)
if (-not $copyInPlace -and (Test-Path -LiteralPath $DataDir) -and @(Get-ChildItem -LiteralPath $DataDir -Force).Count -gt 0) {
    Write-Warn "$DataDir is not empty."
    if (-not $Force -and -not (Confirm-Choice 'Merge into it (existing files are overwritten)?' $false)) { exit 1 }
}
if (-not (Assert-ClaudeClosed -Force:$Force)) { exit 1 }

# 1. files ---------------------------------------------------------------------
if (-not $copyInPlace) {
    Write-Step 'Copying files'
    if (Test-Path -LiteralPath $From -PathType Leaf) {
        New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
        $zip = [System.IO.Compression.ZipFile]::OpenRead($From)
        try {
            foreach ($entry in $zip.Entries) {
                $target = [System.IO.Path]::GetFullPath((Join-Path $DataDir $entry.FullName.Replace('/', '\')))
                if (-not $target.StartsWith($DataDir + '\', [StringComparison]::OrdinalIgnoreCase)) { throw "Unsafe path in zip: $($entry.FullName)" }
                if ($entry.FullName.EndsWith('/') -or $entry.FullName.EndsWith('\')) { New-Item -ItemType Directory -Path $target -Force | Out-Null; continue }
                New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
            }
        } finally { $zip.Dispose() }
    } else {
        if (-not (Invoke-Robocopy $From $DataDir @('/XF', '.credentials.json'))) { throw 'Copy failed (robocopy).' }
    }
    Write-Ok 'Files copied.'
}

# A folder copied as is brings the login of the old computer with it.
$credentials = Join-Path $DataDir '.credentials.json'
$loginKept = $false
if ($copyInPlace -and (Test-Path -LiteralPath $credentials)) {
    Write-Step 'Login found'
    Write-Info 'This folder contains the Claude login (.credentials.json) copied from the other computer.'
    Write-Info 'Removing it is safer: you log in again with /login and the old copy is gone.'
    if ($Force) {
        $loginKept = $true
        Write-Warn 'Login kept (-Force: no questions).'
    } elseif (Confirm-Choice 'Keep the copied login?' $false) {
        $loginKept = $true
        Write-Ok 'Login kept.'
    } else {
        Remove-Item -LiteralPath $credentials -Force
        Write-Ok 'Login removed: log in again with /login.'
    }
}

# 2. scripts, settings, CLAUDE.md (refresh to this version) -------------------
Copy-PortableScripts $DataDir
Install-DataFolderFiles $DataDir
$settings = Read-Settings $DataDir
if (-not (Get-DictValue $settings 'cleanupPeriodDays')) { $settings['cleanupPeriodDays'] = 36500 }
[void](Add-SessionStartHook $settings)
Save-Settings $DataDir $settings
Set-ClaudeMdBlock $DataDir
Write-Ok 'Settings, hook and instructions checked.'

# 3. environment ---------------------------------------------------------------
if (-not $SkipEnvironment) {
    [Environment]::SetEnvironmentVariable('CLAUDE_CONFIG_DIR', $DataDir, 'User')
    Write-Ok "CLAUDE_CONFIG_DIR = $DataDir"
}
$env:CLAUDE_CONFIG_DIR = $DataDir

# 4. relink --------------------------------------------------------------------
$registry = Read-Registry $DataDir
$names = @($registry['workspaces'].Keys | Sort-Object)
Write-Step "Workspaces to reconnect: $($names.Count)"
foreach ($name in $names) {
    # Read again: relinking a workspace also moves the ones registered inside it.
    $registry = Read-Registry $DataDir
    if (-not $registry['workspaces'].ContainsKey($name)) { continue }
    $old = [string]$registry['workspaces'][$name]['path']
    Write-Host ''
    Write-Host "  $name" -ForegroundColor White
    Write-Info "  was in: $old"
    if (Test-Path -LiteralPath $old) {
        Write-Ok '  same path exists on this computer: nothing to do'
        continue
    }
    if ($Force) { Write-Info '  skipped (-Force: no questions)'; continue }
    $new = Read-Host '  New path of the project (Enter = skip, you can relink it later)'
    if ([string]::IsNullOrWhiteSpace($new)) { continue }
    & (Join-Path $PSScriptRoot 'relink-workspace.ps1') -Name $name -NewPath $new.Trim('"', ' ') -Force
}

Write-Host ''
Write-Host 'Done.' -ForegroundColor Green
Write-Info 'Next steps:'
Write-Info '  1. Close and reopen VS Code / terminals so they read CLAUDE_CONFIG_DIR.'
if ($loginKept) {
    Write-Info '  2. You are still logged in with the copied login.'
} else {
    Write-Info '  2. Log in again in Claude Code (/login): the login is never exported.'
}
Write-Info '  3. Skipped workspaces: use "Relink" from the menu whenever you know their new path.'
