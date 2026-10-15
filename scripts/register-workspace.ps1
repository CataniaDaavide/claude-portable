# SessionStart hook: records the current workspace in portable\workspaces.json.
# Runs at every session start, so it must stay silent and never fail the session:
# anything printed on stdout would be added to Claude's context.

try {
    . (Join-Path $PSScriptRoot 'lib\common.ps1')

    $claudeDir = $env:CLAUDE_CONFIG_DIR
    if ([string]::IsNullOrWhiteSpace($claudeDir)) { exit 0 }
    $claudeDir = $claudeDir.TrimEnd('\')

    $project = $env:CLAUDE_PROJECT_DIR
    if ([string]::IsNullOrWhiteSpace($project)) { $project = (Get-Location).Path }

    # Two sessions can start at the same time: serialize writes with a named mutex.
    $mutex = New-Object System.Threading.Mutex($false, 'Global\claude-portable-registry')
    if ($mutex.WaitOne(10000)) {
        try {
            $registry = Read-Registry $claudeDir
            [void](Register-Workspace $claudeDir $registry $project $null)
            Save-Registry $claudeDir $registry
        } finally {
            $mutex.ReleaseMutex()
        }
    }
} catch {
    try {
        $log = Join-Path $env:CLAUDE_CONFIG_DIR 'portable\hook-errors.log'
        Add-Content -LiteralPath $log -Value ((Get-Date).ToString('s') + ' ' + $_.Exception.Message)
    } catch { }
}
exit 0
