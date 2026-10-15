<#
.SYNOPSIS
    Records a workspace in portable\workspaces.json.

.DESCRIPTION
    Hook mode (no -Path): run by Claude Code at every session start. It must never fail the session,
    and whatever it prints is added to Claude's context, so it prints only one thing: a note when the
    project is not registered yet but looks like a registered workspace whose path no longer exists
    (same folder name), i.e. a project that was moved. In that case the project is not registered,
    so the note comes back until the user relinks it or says it is a different project.

    Manual mode (-Path): registers that path as its own workspace, which also stops the note.
#>
param([string]$Path)

$manual = -not [string]::IsNullOrWhiteSpace($Path)

try {
    . (Join-Path $PSScriptRoot 'lib\common.ps1')

    $claudeDir = $env:CLAUDE_CONFIG_DIR
    if ([string]::IsNullOrWhiteSpace($claudeDir)) {
        if ($manual) { Write-Host 'CLAUDE_CONFIG_DIR is not set: run Install first.' }
        exit 0
    }
    $claudeDir = $claudeDir.TrimEnd('\')

    $project = if ($manual) { $Path } else { $env:CLAUDE_PROJECT_DIR }
    if ([string]::IsNullOrWhiteSpace($project)) { $project = (Get-Location).Path }
    $project = ConvertTo-NormalizedPath $project

    $note = $null
    # Two sessions can start at the same time: serialize writes with a named mutex.
    $mutex = New-Object System.Threading.Mutex($false, 'Global\claude-portable-registry')
    if ($mutex.WaitOne(10000)) {
        try {
            $registry = Read-Registry $claudeDir
            $known = Find-WorkspaceByPath $registry $project
            $moved = @()
            if (-not $known -and -not $manual) { $moved = @(Find-MovedWorkspaces $registry $project) }
            if ($moved.Count -gt 0) {
                $lines = @("[claude-portable] This project ($project) is not in the workspace registry, but it looks like a registered workspace that was moved here:")
                foreach ($name in $moved) {
                    $lines += "- '$name', last seen at $($registry['workspaces'][$name]['path']) (that path no longer exists)"
                }
                $lines += 'Tell the user and offer to relink it, so its chats and memory come back (see the claude-portable section of the user CLAUDE.md).'
                $note = $lines -join "`n"
            } else {
                $name = Register-Workspace $claudeDir $registry $project $null
                Save-Registry $claudeDir $registry
                if ($manual) { Write-Host "Registered '$name' -> $project" }
            }
        } finally {
            $mutex.ReleaseMutex()
        }
    }
    if ($note) {
        [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
        Write-Output $note
    }
} catch {
    try {
        $log = Join-Path $env:CLAUDE_CONFIG_DIR 'portable\hook-errors.log'
        Add-Content -LiteralPath $log -Value ((Get-Date).ToString('s') + ' ' + $_.Exception.Message)
    } catch { }
    if ($manual) { Write-Host "Error: $($_.Exception.Message)" }
}
exit 0
