<#
.SYNOPSIS
    Reconnects a workspace's chats and memory after the project moved to a new path.

.DESCRIPTION
    Claude Code names the folder under projects\ after the project path, so a moved project starts empty.
    This script renames (or merges) that folder to match the new path and updates the registry.
    Workspaces registered inside the old path (sub-folders opened on their own) are moved along.

    Run it while no Claude Code session is open in that project.

.EXAMPLE
    .\relink-workspace.ps1 -Name studio-bona-web-app -NewPath "D:\work\studio-bona-web-app" -DryRun
.EXAMPLE
    .\relink-workspace.ps1 -OldPath "C:\Users\me\Desktop\app" -NewPath "D:\work\app"
#>
param(
    [string]$Name,
    [string]$OldPath,
    [Parameter(Mandatory = $true)][string]$NewPath,
    [switch]$DryRun,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\common.ps1')

$claudeDir = Get-ActiveClaudeDir
$projectsDir = Join-Path $claudeDir 'projects'
$registry = Read-Registry $claudeDir
$workspaces = $registry['workspaces']

if (-not $Name -and -not $OldPath) { throw 'Pass -Name (from the registry) or -OldPath.' }
if ($Name -and -not $workspaces.ContainsKey($Name)) {
    $hint = ($workspaces.Keys | Sort-Object) -join ', '
    throw "Workspace '$Name' is not in the registry. Known names: $hint"
}
if (-not $Name) {
    $OldPath = ConvertTo-NormalizedPath $OldPath
    $Name = Find-WorkspaceByPath $registry $OldPath
}
if ($Name) { $OldPath = [string]$workspaces[$Name]['path'] }
$NewPath = ConvertTo-NormalizedPath $NewPath

if (-not (Test-Path -LiteralPath $NewPath)) {
    Write-Warn "The new path does not exist (yet): $NewPath"
    if (-not $Force -and -not $DryRun -and -not (Confirm-Choice 'Relink anyway?' $false)) { exit 1 }
}

# Main workspace plus any registered workspace that lives inside it.
$plan = @()
$plan += @{ Name = $Name; Old = $OldPath; New = $NewPath }
foreach ($other in @($workspaces.Keys)) {
    if ($other -eq $Name) { continue }
    $p = [string]$workspaces[$other]['path']
    if ($p.StartsWith($OldPath + '\', [StringComparison]::OrdinalIgnoreCase)) {
        $plan += @{ Name = $other; Old = $p; New = $NewPath + $p.Substring($OldPath.Length) }
    }
}

Write-Host ''
Write-Host 'claude-portable - relink' -ForegroundColor White
Write-Info "Claude data: $claudeDir"
foreach ($item in $plan) {
    $item.OldFolder = $null
    if ($item.Name) { $item.OldFolder = [string]$workspaces[$item.Name]['folder'] }
    if (-not $item.OldFolder -or -not (Test-Path -LiteralPath (Join-Path $projectsDir $item.OldFolder))) {
        $item.OldFolder = Find-ProjectFolder $claudeDir $item.Old
    }
    $item.NewFolder = Get-ProjectFolderName $item.New
    $label = if ($item.Name) { $item.Name } else { '(not registered)' }
    Write-Step $label
    Write-Info "path   : $($item.Old)"
    Write-Info "      -> $($item.New)"
    if (-not $item.OldFolder) {
        Write-Info 'folder : nothing stored for the old path (only the registry is updated)'
    } elseif ($item.OldFolder -ieq $item.NewFolder) {
        Write-Info "folder : $($item.OldFolder) (unchanged)"
    } elseif (Test-Path -LiteralPath (Join-Path $projectsDir $item.NewFolder)) {
        Write-Info "folder : $($item.OldFolder)"
        Write-Info "      -> merge into existing $($item.NewFolder)"
    } else {
        Write-Info "folder : $($item.OldFolder)"
        Write-Info "      -> rename to $($item.NewFolder)"
    }
    $state = Copy-ProjectState $claudeDir $item.Old $item.New -DryRun
    if ($state) { Write-Info "state  : $state" }
    if ($item.OldFolder -and (Test-Path -LiteralPath (Get-ArchiveFile $claudeDir $item.OldFolder))) {
        Write-Info 'archive: archived chats follow the folder'
    }
}

if ($DryRun) { Write-Host ''; Write-Info 'Dry run: nothing changed.'; exit 0 }
if (-not $Force) {
    Write-Host ''
    Write-Info 'Make sure no Claude Code session is open in these projects.'
    if (-not (Confirm-Choice 'Apply?' $true)) { Write-Info 'Nothing changed.'; exit 1 }
}

# Merges MEMORY.md line by line (keeps every pointer from both sides) and copies files that do not exist yet.
function Merge-ProjectFolder([string]$From, [string]$To) {
    $fromMemory = Join-Path $From 'memory\MEMORY.md'
    $toMemory = Join-Path $To 'memory\MEMORY.md'
    $mergedIndex = $null
    if ((Test-Path -LiteralPath $fromMemory) -and (Test-Path -LiteralPath $toMemory)) {
        $existing = [System.IO.File]::ReadAllLines($toMemory)
        $extra = @([System.IO.File]::ReadAllLines($fromMemory) | Where-Object { $_.Trim() -and ($existing -notcontains $_) })
        $mergedIndex = (@($existing) + $extra) -join "`n"
    }
    # /XC /XN /XO: never overwrite a file that already exists in the destination.
    if (-not (Invoke-Robocopy $From $To @('/XC', '/XN', '/XO'))) { throw "Merge failed: $From -> $To" }
    if ($mergedIndex) { Write-TextFile $toMemory ($mergedIndex + "`n") }
    $backupRoot = Join-Path (Get-PortableDir $claudeDir) 'relink-backups'
    New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
    $backup = Join-Path $backupRoot ((Split-Path -Leaf $From) + '-' + (Get-Date).ToString('yyyyMMdd-HHmmss'))
    Move-Item -LiteralPath $From -Destination $backup
    Write-Ok "Old folder kept as backup: $backup"
}

foreach ($item in $plan) {
    if ($item.OldFolder -and ($item.OldFolder -ine $item.NewFolder)) {
        $from = Join-Path $projectsDir $item.OldFolder
        $to = Join-Path $projectsDir $item.NewFolder
        if (Test-Path -LiteralPath $to) {
            Merge-ProjectFolder $from $to
            Write-Ok "Merged $($item.OldFolder) into $($item.NewFolder)"
        } else {
            Rename-Item -LiteralPath $from -NewName $item.NewFolder
            Write-Ok "Renamed $($item.OldFolder) -> $($item.NewFolder)"
        }
        if (Move-ChatArchive $claudeDir $item.OldFolder $item.NewFolder) { Write-Ok 'Archived chats moved along.' }
    }
    # Folder trust and permissions. Claude Code may rewrite .claude.json while it runs, so this is
    # best done with Claude Code closed; the old entry is kept and a backup is made first.
    try {
        $state = Copy-ProjectState $claudeDir $item.Old $item.New
        if ($state) { Write-Ok "State: $state" }
    } catch {
        Write-Warn "Could not copy trust and permissions: $($_.Exception.Message)"
    }
    if ($item.Name) {
        $entry = $workspaces[$item.Name]
        $previous = @($entry['previousPaths'])
        if ($item.Old -ine $item.New -and ($previous -notcontains $item.Old)) { $previous += $item.Old }
        $entry['previousPaths'] = $previous
        $entry['path'] = $item.New
        $entry['folder'] = $item.NewFolder
        $entry['computer'] = $env:COMPUTERNAME
    } else {
        [void](Register-Workspace $claudeDir $registry $item.New $item.NewFolder)
    }
}
Save-Registry $claudeDir $registry

Write-Host ''
Write-Host 'Done.' -ForegroundColor Green
Write-Info "Open Claude Code in $NewPath and use /resume to find the old chats."
Write-Info 'If Claude Code was open during the relink and asks again to trust the folder, just accept.'
