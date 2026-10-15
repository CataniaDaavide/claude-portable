# Guided menu for claude-portable. Started by start.bat.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\common.ps1')

function Read-PathAnswer([string]$Question, [string]$Default) {
    $suffix = if ($Default) { " [$Default]" } else { '' }
    $answer = Read-Host "$Question$suffix"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    return $answer.Trim().Trim('"')
}

function Invoke-Script([string]$Name, [hashtable]$Params = @{}) {
    try {
        & (Join-Path $PSScriptRoot $Name) @Params
    } catch {
        Write-Host ''
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    }
}

while ($true) {
    Write-Host ''
    Write-Host '========================================' -ForegroundColor DarkGray
    Write-Host ' claude-portable' -ForegroundColor White
    Write-Host " Claude data in use: $(Get-ActiveClaudeDir)" -ForegroundColor DarkGray
    Write-Host '========================================' -ForegroundColor DarkGray
    Write-Host ' 1. Install on this computer (move data into a portable folder)'
    Write-Host ' 2. Status (data folder, settings, workspaces)'
    Write-Host ' 3. Relink a workspace (a project moved to a new path)'
    Write-Host ' 4. Export (zip to carry to another computer)'
    Write-Host ' 5. Import (on the new computer, from a zip or a folder)'
    Write-Host ' 6. Uninstall (back to the default ~/.claude)'
    Write-Host ' 0. Exit'
    $choice = Read-Host 'Choice'
    switch ($choice) {
        '1' {
            $dir = Read-PathAnswer 'Portable folder' (Join-Path $env:USERPROFILE 'claude-data')
            Invoke-Script 'install.ps1' @{ DataDir = $dir }
        }
        '2' { Invoke-Script 'status.ps1' }
        '3' {
            $registry = Read-Registry (Get-ActiveClaudeDir)
            $names = @($registry['workspaces'].Keys | Sort-Object)
            if ($names.Count -eq 0) { Write-Warn 'The registry is empty: run Install first.'; break }
            for ($i = 0; $i -lt $names.Count; $i++) {
                Write-Host (" {0,2}. {1,-30} {2}" -f ($i + 1), $names[$i], $registry['workspaces'][$names[$i]]['path'])
            }
            $n = Read-Host 'Workspace number'
            $index = 0
            if (-not [int]::TryParse($n, [ref]$index) -or $index -lt 1 -or $index -gt $names.Count) { Write-Warn 'Invalid number.'; break }
            $new = Read-PathAnswer 'New path of the project' $null
            if (-not $new) { break }
            Invoke-Script 'relink-workspace.ps1' @{ Name = $names[$index - 1]; NewPath = $new }
        }
        '4' { Invoke-Script 'export-data.ps1' }
        '5' {
            $from = Read-PathAnswer 'Zip file or folder to import' $null
            if (-not $from) { break }
            # A copied folder is used where it is unless the user picks another place.
            $defaultDir = Join-Path $env:USERPROFILE 'claude-data'
            if (Test-Path -LiteralPath $from -PathType Container) { $defaultDir = $from }
            $dir = Read-PathAnswer 'Portable folder on this computer' $defaultDir
            Invoke-Script 'import-data.ps1' @{ From = $from; DataDir = $dir }
        }
        '6' {
            $copyBack = Confirm-Choice 'Copy the data back to ~/.claude first (keeps recent chats)?' $true
            Invoke-Script 'uninstall.ps1' @{ CopyBack = $copyBack }
        }
        '0' { return }
        default { Write-Warn 'Unknown choice.' }
    }
}
