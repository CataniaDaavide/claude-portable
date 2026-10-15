<#
.SYNOPSIS
    Moves Claude Code data into one portable folder and sets it up for relinking.

.DESCRIPTION
    1. Copies the current Claude Code data (~/.claude and ~/.claude.json, or the folder already named by
       CLAUDE_CONFIG_DIR) into -DataDir. The original stays untouched as a backup.
    2. Copies these scripts into <DataDir>\portable\scripts so the folder is self-contained.
    3. Sets cleanupPeriodDays so old chats are kept, and installs the SessionStart hook.
    4. Adds a short block to the user CLAUDE.md telling Claude how to relink workspaces.
    5. Builds portable\workspaces.json from the projects already on disk.
    6. Sets the CLAUDE_CONFIG_DIR user environment variable to -DataDir.

.PARAMETER DataDir
    The portable folder. Default: %USERPROFILE%\claude-data

.PARAMETER RetentionDays
    Days Claude Code keeps chats before deleting them. Minimum 1. Default 36500 (about 100 years).

.PARAMETER Source
    Folder to copy from. Default: the folder Claude Code uses now.

.PARAMETER Fresh
    Do not copy anything: start with an empty data folder (you will have to log in again).

.PARAMETER SkipEnvironment
    Do not set CLAUDE_CONFIG_DIR (useful for testing).

.PARAMETER Force
    Do not ask questions.
#>
param(
    [string]$DataDir = (Join-Path $env:USERPROFILE 'claude-data'),
    [ValidateRange(1, 1000000)][int]$RetentionDays = 36500,
    [string]$Source,
    [switch]$Fresh,
    [switch]$SkipEnvironment,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\common.ps1')

$DataDir = ConvertTo-NormalizedPath $DataDir
if (-not $Source) { $Source = Get-ActiveClaudeDir }
$Source = ConvertTo-NormalizedPath $Source

# The target is already a portable data folder that Claude Code does not use yet (moved or copied
# here): copying the current data over it would overwrite newer chats, so import it in place.
if (($Source -ine $DataDir) -and (Test-Path -LiteralPath (Get-RegistryFile $DataDir))) {
    Write-Host ''
    Write-Step "$DataDir is already a claude-portable data folder (moved or copied here)."
    Write-Info 'Using it as it is instead of copying over it: switching to Import.'
    & (Join-Path $PSScriptRoot 'import-data.ps1') -From $DataDir -DataDir $DataDir -SkipEnvironment:$SkipEnvironment -Force:$Force
    exit $LASTEXITCODE
}

Write-Host ''
Write-Host "claude-portable $(Get-PortableVersion) - install" -ForegroundColor White
Write-Info "Current Claude data : $Source"
Write-Info "Portable folder     : $DataDir"
Write-Info "Chat retention      : $RetentionDays days"
Write-Host ''

if ($Source -ieq $DataDir) {
    Write-Step 'The data is already in the portable folder: only settings, hook and registry will be updated.'
    $Fresh = $true
}

if (-not $Force) {
    if (-not (Confirm-Choice 'Proceed?' $true)) { Write-Info 'Nothing changed.'; exit 1 }
}

# 1. copy data -----------------------------------------------------------------
if (-not $Fresh) {
    if (-not (Assert-ClaudeClosed -Force:$Force)) { Write-Info 'Nothing changed.'; exit 1 }
    if (-not (Test-Path -LiteralPath $Source)) {
        throw "Claude data not found in $Source. If you moved the data folder, choose Import and give its new path."
    }
    if ((Test-Path -LiteralPath $DataDir) -and @(Get-ChildItem -LiteralPath $DataDir -Force).Count -gt 0) {
        Write-Warn "$DataDir is not empty. Files with the same name will be overwritten by the newer copy."
        if (-not $Force -and -not (Confirm-Choice 'Continue?' $false)) { Write-Info 'Nothing changed.'; exit 1 }
    }
    Write-Step "Copying $Source -> $DataDir"
    if (-not (Invoke-Robocopy $Source $DataDir)) { throw 'Copy failed (robocopy).' }
    $globalSrc = Get-GlobalConfigFile $Source
    $globalDst = Get-GlobalConfigFile $DataDir
    if ((Test-Path -LiteralPath $globalSrc) -and ($globalSrc -ine $globalDst)) {
        Copy-Item -LiteralPath $globalSrc -Destination $globalDst -Force
        Write-Ok 'Copied the global state file (.claude.json).'
    }
    Write-Ok 'Data copied. The original folder was not modified and stays as a backup.'
} else {
    New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
}

# 2. scripts -------------------------------------------------------------------
Write-Step 'Copying the claude-portable scripts into the data folder'
Copy-PortableScripts $DataDir
Install-DataFolderFiles $DataDir
Write-Ok "$(Get-PortableDir $DataDir)\scripts"
Write-Ok "$DataDir\claude-portable.bat (opens this menu from the data folder)"

# 3. settings ------------------------------------------------------------------
Write-Step 'Updating settings.json'
$settings = Read-Settings $DataDir
$settings['cleanupPeriodDays'] = $RetentionDays
Write-Ok "cleanupPeriodDays = $RetentionDays"
if (Add-SessionStartHook $settings) { Write-Ok 'SessionStart hook installed.' } else { Write-Ok 'SessionStart hook already present.' }
Save-Settings $DataDir $settings

# 4. CLAUDE.md -----------------------------------------------------------------
Write-Step 'Adding the relink instructions to the user CLAUDE.md'
Set-ClaudeMdBlock $DataDir
Write-Ok (Join-Path $DataDir 'CLAUDE.md')

# 5. registry ------------------------------------------------------------------
Write-Step 'Building the workspace registry'
$registry = Read-Registry $DataDir
$result = Update-RegistryFromDisk $DataDir $registry
Save-Registry $DataDir $registry
foreach ($name in $registry['workspaces'].Keys) {
    Write-Ok ("{0,-30} {1}" -f $name, $registry['workspaces'][$name]['path'])
}
foreach ($folder in $result.Unknown) {
    Write-Warn "No path found for projects\$folder (no chat inside): it will be registered the next time you open it."
}

# 6. environment ---------------------------------------------------------------
if ($SkipEnvironment) {
    Write-Warn 'CLAUDE_CONFIG_DIR not set (-SkipEnvironment).'
} else {
    Write-Step 'Setting the CLAUDE_CONFIG_DIR user environment variable'
    [Environment]::SetEnvironmentVariable('CLAUDE_CONFIG_DIR', $DataDir, 'User')
    $env:CLAUDE_CONFIG_DIR = $DataDir
    Write-Ok "CLAUDE_CONFIG_DIR = $DataDir"
}

Write-Host ''
Write-Host 'Done.' -ForegroundColor Green
Write-Info 'Next steps:'
Write-Info '  1. Close VS Code, every terminal and the Claude app completely, then reopen them'
Write-Info '     (programs read environment variables only when they start).'
Write-Info '  2. Open a project with Claude Code and run "Status" from the menu to check everything.'
if (-not $Fresh) {
    Write-Info "  3. When you are sure everything works, you can delete the old copy: $Source"
}
