# Guided menu for claude-portable. Started by start.bat or by claude-portable.bat in the data folder.

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

# Lists the registered workspaces and returns the chosen name, or $null.
function Select-Workspace {
    $registry = Read-Registry (Get-ActiveClaudeDir)
    $names = @($registry['workspaces'].Keys | Sort-Object)
    if ($names.Count -eq 0) { Write-Warn 'The registry is empty: run Install first.'; return $null }
    for ($i = 0; $i -lt $names.Count; $i++) {
        $path = [string]$registry['workspaces'][$names[$i]]['path']
        $mark = if (Test-Path -LiteralPath $path) { '' } else { '  (path not found)' }
        Write-Host (" {0,2}. {1,-30} {2}{3}" -f ($i + 1), $names[$i], $path, $mark)
    }
    $n = Read-Host 'Workspace number'
    $index = 0
    if (-not [int]::TryParse($n, [ref]$index) -or $index -lt 1 -or $index -gt $names.Count) { Write-Warn 'Invalid number.'; return $null }
    return $names[$index - 1]
}

while ($true) {
    $active = Get-ActiveClaudeDir
    Write-Host ''
    Write-Host '========================================' -ForegroundColor DarkGray
    Write-Host " claude-portable $(Get-PortableVersion)" -ForegroundColor White
    Write-Host " Claude data in use: $active" -ForegroundColor DarkGray
    Write-Host '========================================' -ForegroundColor DarkGray
    Write-Host ' 1. Install or update on this computer'
    Write-Host ' 2. Status (data folder, settings, workspaces, updates)'
    Write-Host ' 3. Relink a workspace (a project moved to a new path)'
    Write-Host ' 4. Export (zip to carry to another computer)'
    Write-Host ' 5. Import (on the new computer, or after moving the data folder)'
    Write-Host ' 6. Uninstall (back to the default ~/.claude)'
    Write-Host ' 7. Forget a workspace (a project you deleted)'
    Write-Host ' 8. Archive old chats (keep the data folder light)'
    Write-Host ' 9. Restore archived chats'
    Write-Host ' 0. Exit'
    $choice = Read-Host 'Choice'
    switch ($choice) {
        '1' {
            # Already installed: the default is the folder in use, which updates it in place.
            $default = Join-Path $env:USERPROFILE 'claude-data'
            if (Test-Path -LiteralPath (Get-RegistryFile $active)) { $default = $active }
            $dir = Read-PathAnswer 'Portable folder' $default
            Invoke-Script 'install.ps1' @{ DataDir = $dir }
        }
        '2' { Invoke-Script 'status.ps1' }
        '3' {
            $name = Select-Workspace
            if (-not $name) { break }
            $new = Read-PathAnswer 'New path of the project' $null
            if (-not $new) { break }
            Invoke-Script 'relink-workspace.ps1' @{ Name = $name; NewPath = $new }
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
        '7' {
            $name = Select-Workspace
            if (-not $name) { break }
            Invoke-Script 'forget-workspace.ps1' @{ Name = $name }
        }
        '8' {
            $days = Read-PathAnswer 'Archive chats not changed for how many days?' '180'
            $n = 0
            if (-not [int]::TryParse($days, [ref]$n) -or $n -lt 1) { Write-Warn 'Invalid number.'; break }
            Invoke-Script 'archive-chats.ps1' @{ OlderThanDays = $n }
        }
        '9' {
            $answer = Read-Host 'Restore all archived chats (a) or one workspace (w)? [a/w]'
            if ($answer -match '^\s*a') {
                Invoke-Script 'restore-chats.ps1' @{ All = $true }
            } elseif ($answer -match '^\s*w') {
                $name = Select-Workspace
                if ($name) { Invoke-Script 'restore-chats.ps1' @{ Name = $name } }
            }
        }
        '0' { return }
        default { Write-Warn 'Unknown choice.' }
    }
}
