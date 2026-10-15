# claude-portable online installer and updater. Run in PowerShell:
#
#   irm https://raw.githubusercontent.com/CataniaDaavide/claude-portable/main/get.ps1 | iex
#
# Downloads the latest version from GitHub into a temporary folder, then:
# - if a claude-portable data folder is already in use, offers to update it to this version;
# - otherwise opens the menu, where "1. Install" sets everything up.
# Nothing is installed besides the data folder the menu creates; the download is removed at the end.
# CLAUDE_PORTABLE_SOURCE (a zip URL or a local zip path) overrides the download, for testing.

& {
    $ErrorActionPreference = 'Stop'
    $source = $env:CLAUDE_PORTABLE_SOURCE
    if (-not $source) { $source = 'https://github.com/CataniaDaavide/claude-portable/archive/refs/heads/main.zip' }

    $work = Join-Path ([System.IO.Path]::GetTempPath()) ('claude-portable-get-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    try {
        Write-Host 'claude-portable: downloading the latest version...' -ForegroundColor Cyan
        $zip = Join-Path $work 'claude-portable.zip'
        if (Test-Path -LiteralPath $source) {
            Copy-Item -LiteralPath $source -Destination $zip
        } else {
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri $source -OutFile $zip -UseBasicParsing
        }
        Expand-Archive -LiteralPath $zip -DestinationPath $work -Force
        $repo = Get-ChildItem -LiteralPath $work -Directory | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'start.bat') } | Select-Object -First 1
        if (-not $repo) { throw 'The download does not look like claude-portable.' }
        $scripts = Join-Path $repo.FullName 'scripts'
        $version = ([System.IO.File]::ReadAllText((Join-Path $scripts 'VERSION'))).Trim()
        Write-Host "claude-portable $version ready." -ForegroundColor Green

        $active = [Environment]::GetEnvironmentVariable('CLAUDE_CONFIG_DIR', 'User')
        $installed = $active -and (Test-Path -LiteralPath (Join-Path $active 'portable\workspaces.json'))
        $runArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File')
        if ($installed) {
            Write-Host "Data folder in use: $active"
            $answer = Read-Host "Update it to version $version? [Y/n]"
            if ([string]::IsNullOrWhiteSpace($answer) -or $answer.Trim().ToLower().StartsWith('y')) {
                & powershell.exe @runArgs (Join-Path $scripts 'install.ps1') -DataDir $active -Force
            } else {
                Write-Host 'Nothing changed.'
            }
        } else {
            & powershell.exe @runArgs (Join-Path $scripts 'claude-portable.ps1')
        }
    } finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}
