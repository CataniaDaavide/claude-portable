<#
.SYNOPSIS
    Removes a workspace from the registry, for example a project you deleted.

.DESCRIPTION
    Its chats and memory are moved to portable\forgotten (so they are not registered again and do
    not show in /resume). Nothing is deleted: delete that folder yourself to free the space, or move
    a folder back to projects\ to restore it.
#>
param(
    [Parameter(Mandatory = $true)][string]$Name,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\common.ps1')

$claudeDir = Get-ActiveClaudeDir
$registry = Read-Registry $claudeDir
if (-not $registry['workspaces'].ContainsKey($Name)) {
    throw "Workspace '$Name' is not in the registry. Known names: " + (($registry['workspaces'].Keys | Sort-Object) -join ', ')
}
$entry = $registry['workspaces'][$Name]

Write-Host ''
Write-Host 'claude-portable - forget' -ForegroundColor White
Write-Info "Workspace : $Name"
Write-Info "Path      : $($entry['path'])"
Write-Info "Its chats and memory move to $(Get-PortableDir $claudeDir)\forgotten (nothing is deleted)."
if (Test-Path -LiteralPath ([string]$entry['path'])) { Write-Warn 'This path still exists on this computer.' }
if (-not $Force -and -not (Confirm-Choice 'Forget it?' $false)) { Write-Info 'Nothing changed.'; exit 1 }

$moved = Remove-Workspace $claudeDir $registry $Name
Save-Registry $claudeDir $registry
Write-Ok "Removed '$Name' from the registry."
if ($moved) { Write-Ok "Chats and memory kept in $moved" }
