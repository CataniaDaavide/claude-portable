<#
.SYNOPSIS
    Goes back to the default ~/.claude folder.

.DESCRIPTION
    Removes the SessionStart hook and the CLAUDE.md block, then clears CLAUDE_CONFIG_DIR.
    With -CopyBack the portable data is first copied back to ~/.claude and ~/.claude.json,
    so the chats made in the meantime are not lost. The portable folder itself is never deleted.
#>
param(
    [switch]$CopyBack,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\common.ps1')

$claudeDir = Get-ActiveClaudeDir
$default = Get-DefaultClaudeDir

Write-Host ''
Write-Host 'claude-portable - uninstall' -ForegroundColor White
if ($claudeDir -ieq $default) { Write-Warn 'Claude Code already uses ~/.claude: nothing to undo.'; exit 0 }
Write-Info "Portable folder: $claudeDir (it will not be deleted)"
Write-Info "Back to        : $default"
if ($CopyBack) { Write-Info 'Data is copied back first (-CopyBack).' }
if (-not $Force -and -not (Confirm-Choice 'Proceed?' $false)) { exit 1 }
if (-not (Assert-ClaudeClosed -Force:$Force)) { exit 1 }

$settings = Read-Settings $claudeDir
if (Remove-SessionStartHook $settings) { Save-Settings $claudeDir $settings; Write-Ok 'Hook removed.' }
Remove-ClaudeMdBlock $claudeDir
Write-Ok 'CLAUDE.md block removed.'

if ($CopyBack) {
    Write-Step "Copying $claudeDir -> $default"
    if (-not (Invoke-Robocopy $claudeDir $default @('/XD', (Get-PortableDir $claudeDir), '/XF', 'claude-portable.bat'))) { throw 'Copy failed (robocopy).' }
    $global = Get-GlobalConfigFile $claudeDir
    if (Test-Path -LiteralPath $global) { Copy-Item -LiteralPath $global -Destination (Join-Path $env:USERPROFILE '.claude.json') -Force }
    Write-Ok 'Copied.'
}

[Environment]::SetEnvironmentVariable('CLAUDE_CONFIG_DIR', $null, 'User')
Write-Ok 'CLAUDE_CONFIG_DIR removed.'
Write-Info 'Restart VS Code and terminals to apply.'
