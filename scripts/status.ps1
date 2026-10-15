<#
.SYNOPSIS
    Shows where Claude Code keeps its data and the state of every registered workspace.
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\common.ps1')

$userVar = [Environment]::GetEnvironmentVariable('CLAUDE_CONFIG_DIR', 'User')
$claudeDir = Get-ActiveClaudeDir
$projectsDir = Join-Path $claudeDir 'projects'

Write-Host ''
Write-Host 'claude-portable - status' -ForegroundColor White

Write-Step 'Version'
$current = Get-PortableVersion
$latest = Get-LatestVersion
if (-not $latest) {
    Write-Info "$current (could not check GitHub for updates)"
} elseif ((Compare-Version $latest $current) -gt 0) {
    Write-Warn "$current installed, $latest available. To update, run in PowerShell:"
    Write-Info "  irm https://raw.githubusercontent.com/CataniaDaavide/claude-portable/main/get.ps1 | iex"
} else {
    Write-Ok "$current (up to date)"
}

Write-Step 'Data folder'
if ($userVar) { Write-Ok "CLAUDE_CONFIG_DIR (user) = $userVar" } else { Write-Warn 'CLAUDE_CONFIG_DIR is not set: Claude Code uses the default ~/.claude' }
if ($env:CLAUDE_CONFIG_DIR -and $userVar -and ($env:CLAUDE_CONFIG_DIR.TrimEnd('\') -ine $userVar.TrimEnd('\'))) {
    Write-Warn "This window still sees an old value ($env:CLAUDE_CONFIG_DIR): restart the programs."
}
Write-Info "In use: $claudeDir"
if (-not (Test-Path -LiteralPath $claudeDir)) { Write-Warn 'The folder does not exist.'; exit 1 }
$size = (Get-ChildItem -LiteralPath $claudeDir -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
Write-Info ('Size  : {0:N0} MB' -f ($size / 1MB))
if (Test-Path -LiteralPath (Join-Path $claudeDir '.credentials.json')) { Write-Ok 'Logged in (.credentials.json present)' } else { Write-Warn 'No .credentials.json: log in with /login' }
$globalFile = Get-GlobalConfigFile $claudeDir
if (Test-Path -LiteralPath $globalFile) {
    Write-Ok ('Global state file: {0} (updated {1})' -f $globalFile, (Get-Item -LiteralPath $globalFile).LastWriteTime.ToString('yyyy-MM-dd HH:mm'))
} else {
    Write-Warn "Global state file not found yet: $globalFile"
}

Write-Step 'Settings'
$settings = Read-Settings $claudeDir
$retention = Get-DictValue $settings 'cleanupPeriodDays'
if ($retention) { Write-Ok "cleanupPeriodDays = $retention" } else { Write-Warn 'cleanupPeriodDays not set: chats older than 30 days are deleted' }
if (Test-HookInstalled $settings) { Write-Ok 'SessionStart hook installed' } else { Write-Warn 'SessionStart hook missing: run Install again' }
$hookLog = Join-Path (Get-PortableDir $claudeDir) 'hook-errors.log'
if (Test-Path -LiteralPath $hookLog) { Write-Warn "The hook reported errors, see $hookLog" }

Write-Step 'Workspaces'
$registry = Read-Registry $claudeDir
$rows = foreach ($name in ($registry['workspaces'].Keys | Sort-Object)) {
    $e = $registry['workspaces'][$name]
    $folder = Join-Path $projectsDir ([string]$e['folder'])
    $hasFolder = Test-Path -LiteralPath $folder
    [pscustomobject]@{
        Name     = $name
        Chats    = if ($hasFolder) { @(Get-ChildItem -LiteralPath $folder -Filter '*.jsonl' -File).Count } else { 0 }
        Memories = if ($hasFolder -and (Test-Path -LiteralPath (Join-Path $folder 'memory'))) { @(Get-ChildItem -LiteralPath (Join-Path $folder 'memory') -Filter '*.md' -File | Where-Object { $_.Name -ne 'MEMORY.md' }).Count } else { 0 }
        Archived = Get-ArchivedChatCount $claudeDir ([string]$e['folder'])
        PathOk   = if (Test-Path -LiteralPath ([string]$e['path'])) { 'yes' } else { 'NO' }
        LastUsed = [string]$e['lastUsed']
        Path     = [string]$e['path']
    }
}
if ($rows) { $rows | Format-Table -AutoSize | Out-String -Width 220 | Write-Host } else { Write-Info '(none yet)' }
if (@($rows | Where-Object { $_.PathOk -eq 'NO' }).Count -gt 0) {
    Write-Warn 'Workspaces marked NO point to a path that does not exist here: use "Relink" if the project moved,'
    Write-Info '    or "Forget" if you deleted it.'
}

Write-Step 'Compatibility with this Claude Code version'
$problems = 0
foreach ($line in (Get-CompatibilityReport $claudeDir $registry)) {
    switch ($line.Level) {
        'ok' { Write-Ok $line.Text }
        'warn' { Write-Warn $line.Text; $problems++ }
        default { Write-Info $line.Text }
    }
}
if ($problems -gt 0) {
    Write-Info "If a check fails after a Claude Code update, please open an issue: $($script:RepoUrl)/issues"
}

$registered = @{}
foreach ($e in $registry['workspaces'].Values) { $registered[([string]$e['folder']).ToLower()] = $true }
$orphans = @(Get-ChildItem -LiteralPath $projectsDir -Directory -ErrorAction SilentlyContinue | Where-Object { -not $registered.ContainsKey($_.Name.ToLower()) })
if ($orphans.Count -gt 0) {
    Write-Step 'Folders not in the registry'
    foreach ($o in $orphans) { Write-Info "projects\$($o.Name)" }
    Write-Info 'They are added automatically the next time you open that project (or run Install again).'
}
