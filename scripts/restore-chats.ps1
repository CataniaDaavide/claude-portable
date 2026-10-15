<#
.SYNOPSIS
    Puts archived chats back, with their original dates, so /resume shows them again.

.EXAMPLE
    .\restore-chats.ps1 -Name studio-bona-web-app
.EXAMPLE
    .\restore-chats.ps1 -All
#>
param(
    [string]$Name,
    [switch]$All,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\common.ps1')
Add-CompressionTypes

$claudeDir = Get-ActiveClaudeDir
$projectsDir = Join-Path $claudeDir 'projects'
$archiveDir = Get-ArchiveDir $claudeDir
$registry = Read-Registry $claudeDir

if (-not $Name -and -not $All) { throw 'Pass -Name <workspace> or -All.' }
$zips = @()
if ($All) {
    $zips = @(Get-ChildItem -LiteralPath $archiveDir -Filter '*.zip' -File -ErrorAction SilentlyContinue)
} else {
    if (-not $registry['workspaces'].ContainsKey($Name)) { throw "Workspace '$Name' is not in the registry." }
    $file = Get-ArchiveFile $claudeDir ([string]$registry['workspaces'][$Name]['folder'])
    if (Test-Path -LiteralPath $file) { $zips = @(Get-Item -LiteralPath $file) }
}

Write-Host ''
Write-Host 'claude-portable - restore archived chats' -ForegroundColor White
if ($zips.Count -eq 0) { Write-Ok 'No archived chats to restore.'; exit 0 }
foreach ($z in $zips) { Write-Info ('{0} ({1} chats)' -f $z.BaseName, (Get-ArchivedChatCount $claudeDir $z.BaseName)) }
if (-not $Force -and -not (Confirm-Choice 'Restore them?' $true)) { Write-Info 'Nothing changed.'; exit 1 }

foreach ($z in $zips) {
    $target = Join-Path $projectsDir $z.BaseName
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    $restored = 0
    $zip = [System.IO.Compression.ZipFile]::OpenRead($z.FullName)
    try {
        foreach ($entry in $zip.Entries) {
            if ($entry.FullName.EndsWith('/')) { continue }
            $path = [System.IO.Path]::GetFullPath((Join-Path $target $entry.FullName.Replace('/', '\')))
            if (-not $path.StartsWith($target + '\', [StringComparison]::OrdinalIgnoreCase)) { throw "Unsafe path in archive: $($entry.FullName)" }
            if (Test-Path -LiteralPath $path) { continue }
            New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $path, $false)
            (Get-Item -LiteralPath $path).LastWriteTime = $entry.LastWriteTime.LocalDateTime
            if ($entry.FullName -notmatch '/' -and $entry.FullName.EndsWith('.jsonl')) { $restored++ }
        }
    } finally { $zip.Dispose() }
    Remove-Item -LiteralPath $z.FullName -Force
    Write-Ok "$($z.BaseName): $restored chats restored"
}
Write-Host ''
Write-Host 'Done.' -ForegroundColor Green
