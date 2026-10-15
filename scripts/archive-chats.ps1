<#
.SYNOPSIS
    Moves chats you have not touched for a while into compressed archives.

.DESCRIPTION
    Chats (*.jsonl, with their subagent and tool-result folders) older than -OlderThanDays are
    packed into portable\archive\<project folder>.zip and removed from projects\, so the data folder
    stays light and /resume lists only recent chats. Memory is never archived. Nothing is lost:
    restore-chats.ps1 puts them back with their original dates. The archives travel with Export.
#>
param(
    [ValidateRange(1, 100000)][int]$OlderThanDays = 180,
    [switch]$DryRun,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\common.ps1')
Add-CompressionTypes

$claudeDir = Get-ActiveClaudeDir
$projectsDir = Join-Path $claudeDir 'projects'
$cutoff = (Get-Date).AddDays(-$OlderThanDays)

Write-Host ''
Write-Host 'claude-portable - archive old chats' -ForegroundColor White
Write-Info "Claude data: $claudeDir"
Write-Info "Chats not changed since $($cutoff.ToString('yyyy-MM-dd')) ($OlderThanDays days)"

$registry = Read-Registry $claudeDir
$plan = @()
foreach ($dir in (Get-ChildItem -LiteralPath $projectsDir -Directory -ErrorAction SilentlyContinue)) {
    $chats = @(Get-ChildItem -LiteralPath $dir.FullName -Filter '*.jsonl' -File | Where-Object { $_.LastWriteTime -lt $cutoff })
    if ($chats.Count -eq 0) { continue }
    $size = 0
    foreach ($c in $chats) {
        $size += $c.Length
        $companion = Join-Path $dir.FullName $c.BaseName
        if (Test-Path -LiteralPath $companion) {
            $size += (Get-ChildItem -LiteralPath $companion -Recurse -File | Measure-Object Length -Sum).Sum
        }
    }
    $name = $dir.Name
    foreach ($n in $registry['workspaces'].Keys) { if (([string]$registry['workspaces'][$n]['folder']) -ieq $dir.Name) { $name = $n } }
    $plan += [pscustomobject]@{ Name = $name; Folder = $dir; Chats = $chats; Size = $size }
}

if ($plan.Count -eq 0) { Write-Host ''; Write-Ok 'No chat is that old: nothing to archive.'; exit 0 }
Write-Host ''
foreach ($p in $plan) { Write-Info ('{0,-30} {1,4} chats  {2,8:N1} MB' -f $p.Name, $p.Chats.Count, ($p.Size / 1MB)) }
$total = ($plan | Measure-Object Size -Sum).Sum
Write-Info ('Total: {0:N1} MB, compressed to roughly a tenth.' -f ($total / 1MB))

if ($DryRun) { Write-Host ''; Write-Info 'Dry run: nothing changed.'; exit 0 }
if (-not $Force -and -not (Confirm-Choice 'Archive them?' $true)) { Write-Info 'Nothing changed.'; exit 1 }

New-Item -ItemType Directory -Path (Get-ArchiveDir $claudeDir) -Force | Out-Null
foreach ($p in $plan) {
    $zipFile = Get-ArchiveFile $claudeDir $p.Folder.Name
    $added = @()
    $zip = [System.IO.Compression.ZipFile]::Open($zipFile, [System.IO.Compression.ZipArchiveMode]::Update)
    try {
        foreach ($chat in $p.Chats) {
            $files = @($chat)
            $companion = Join-Path $p.Folder.FullName $chat.BaseName
            if (Test-Path -LiteralPath $companion) { $files += @(Get-ChildItem -LiteralPath $companion -Recurse -File) }
            foreach ($f in $files) {
                $entryName = $f.FullName.Substring($p.Folder.FullName.Length + 1).Replace('\', '/')
                $existing = $zip.GetEntry($entryName)
                if ($existing) { $existing.Delete() }
                # CreateEntryFromFile keeps the file date, so restored chats keep their order in /resume.
                [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $f.FullName, $entryName, [System.IO.Compression.CompressionLevel]::Optimal)
            }
            $added += $chat
        }
    } finally { $zip.Dispose() }

    # Remove the originals only once the archive is written and readable.
    $check = [System.IO.Compression.ZipFile]::OpenRead($zipFile)
    try { $inside = @{}; foreach ($e in $check.Entries) { $inside[$e.FullName] = $true } } finally { $check.Dispose() }
    foreach ($chat in $added) {
        if (-not $inside.ContainsKey($chat.Name)) { throw "Archive check failed for $($chat.Name): originals kept." }
        Remove-Item -LiteralPath $chat.FullName -Force
        $companion = Join-Path $p.Folder.FullName $chat.BaseName
        if (Test-Path -LiteralPath $companion) { Remove-Item -LiteralPath $companion -Recurse -Force }
    }
    Write-Ok ('{0}: {1} chats archived ({2:N1} MB on disk)' -f $p.Name, $added.Count, ((Get-Item -LiteralPath $zipFile).Length / 1MB))
}
Write-Host ''
Write-Host 'Done.' -ForegroundColor Green
Write-Info 'Restore them any time with "Restore archived chats" in the menu.'
