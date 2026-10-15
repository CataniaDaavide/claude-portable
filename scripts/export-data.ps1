<#
.SYNOPSIS
    Packs the portable folder into a zip to carry to another computer.

.DESCRIPTION
    Leaves out the login (.credentials.json) and folders that only make sense on this computer
    (caches, IDE lock files, shell snapshots, running sessions).
    The zip still contains your chats, which can include passwords and other secrets you typed or
    that commands printed: keep it private.
#>
param(
    [string]$Output = (Join-Path ([Environment]::GetFolderPath('Desktop')) ('claude-data-export-' + (Get-Date).ToString('yyyyMMdd-HHmm') + '.zip')),
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\common.ps1')
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem

$claudeDir = Get-ActiveClaudeDir
$Output = ConvertTo-NormalizedPath $Output

Write-Host ''
Write-Host 'claude-portable - export' -ForegroundColor White
Write-Info "From: $claudeDir"
Write-Info "To  : $Output"
if (-not (Test-Path -LiteralPath (Get-RegistryFile $claudeDir))) {
    Write-Warn 'No workspace registry here: run Install first, otherwise relinking on the other computer is manual.'
}
if (Test-Path -LiteralPath $Output) {
    if (-not $Force -and -not (Confirm-Choice 'The file exists. Overwrite?' $false)) { exit 1 }
    Remove-Item -LiteralPath $Output -Force
}
if (-not (Assert-ClaudeClosed -Force:$Force)) { exit 1 }

$staging = Join-Path ([System.IO.Path]::GetTempPath()) ('claude-portable-export-' + [guid]::NewGuid().ToString('N'))
try {
    Write-Step 'Collecting files'
    $excludeDirs = @('cache', 'ide', 'session-env', 'sessions', 'shell-snapshots', 'statsig', 'downloads', 'backups', 'relink-backups')
    $excludeFiles = @('.credentials.json', '*.tmp-*', 'hook-errors.log', '*.heapsnapshot')
    $ok = Invoke-Robocopy $claudeDir $staging (@('/XD') + $excludeDirs + @('/XF') + $excludeFiles)
    if (-not $ok) { throw 'Copy failed (robocopy).' }
    $globalFile = Get-GlobalConfigFile $claudeDir
    if (Test-Path -LiteralPath $globalFile) { Copy-Item -LiteralPath $globalFile -Destination (Join-Path $staging '.claude.json') -Force }

    Write-Step 'Compressing'
    # Entries are added one by one: CreateFromDirectory on .NET Framework writes '\' separators,
    # which other zip tools do not treat as folders.
    $zip = [System.IO.Compression.ZipFile]::Open($Output, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($file in (Get-ChildItem -LiteralPath $staging -Recurse -File -Force)) {
            $entryName = $file.FullName.Substring($staging.Length + 1).Replace('\', '/')
            [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $file.FullName, $entryName, [System.IO.Compression.CompressionLevel]::Optimal)
        }
    } finally { $zip.Dispose() }
} finally {
    if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
}

Write-Ok ('{0} ({1:N0} MB)' -f $Output, ((Get-Item -LiteralPath $Output).Length / 1MB))
Write-Host ''
Write-Info 'On the other computer: copy the claude-portable repository (or the zip only) and choose "Import".'
Write-Warn 'The zip contains your chats: do not publish it or put it in a git repository.'
