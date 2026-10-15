# Shared helpers for claude-portable. Windows PowerShell 5.1, ASCII only.

Set-StrictMode -Version 2.0

Add-Type -AssemblyName System.Web.Extensions

$script:PortableDirName = 'portable'
$script:RegistryFileName = 'workspaces.json'
$script:HookMarker = 'register-workspace.ps1'
$script:ClaudeMdStart = '<!-- claude-portable:start -->'
$script:ClaudeMdEnd = '<!-- claude-portable:end -->'

# ---------------------------------------------------------------- output

function Write-Step([string]$Text) { Write-Host "==> $Text" -ForegroundColor Cyan }
function Write-Ok([string]$Text) { Write-Host "    [ok] $Text" -ForegroundColor Green }
function Write-Warn([string]$Text) { Write-Host "    [!] $Text" -ForegroundColor Yellow }
function Write-Info([string]$Text) { Write-Host "    $Text" }

function Confirm-Choice([string]$Question, [bool]$Default = $false) {
    $suffix = if ($Default) { '[Y/n]' } else { '[y/N]' }
    $answer = Read-Host "$Question $suffix"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    return $answer.Trim().ToLower().StartsWith('y')
}

# ---------------------------------------------------------------- paths

function Get-DefaultClaudeDir { return (Join-Path $env:USERPROFILE '.claude') }

# The directory Claude Code currently uses: CLAUDE_CONFIG_DIR (process, then user scope) or ~/.claude.
function Get-ActiveClaudeDir {
    $dir = $env:CLAUDE_CONFIG_DIR
    if ([string]::IsNullOrWhiteSpace($dir)) { $dir = [Environment]::GetEnvironmentVariable('CLAUDE_CONFIG_DIR', 'User') }
    if ([string]::IsNullOrWhiteSpace($dir)) { $dir = Get-DefaultClaudeDir }
    return $dir.TrimEnd('\')
}

# Global state file: ~/.claude.json by default, <config dir>\.claude.json when CLAUDE_CONFIG_DIR is set.
function Get-GlobalConfigFile([string]$ClaudeDir) {
    if ($ClaudeDir.TrimEnd('\') -ieq (Get-DefaultClaudeDir)) { return (Join-Path $env:USERPROFILE '.claude.json') }
    return (Join-Path $ClaudeDir '.claude.json')
}

function Get-PortableDir([string]$ClaudeDir) { return (Join-Path $ClaudeDir $script:PortableDirName) }
function Get-RegistryFile([string]$ClaudeDir) { return (Join-Path (Get-PortableDir $ClaudeDir) $script:RegistryFileName) }

function ConvertTo-NormalizedPath([string]$Path) {
    $full = [System.IO.Path]::GetFullPath($Path)
    if ($full.Length -gt 3) { $full = $full.TrimEnd('\') }
    if ($full -match '^[a-z]:') { $full = $full.Substring(0, 1).ToUpper() + $full.Substring(1) }
    return $full
}

# Same rule Claude Code uses: every non-alphanumeric character becomes '-'.
# Names longer than 200 characters get a hash suffix we cannot reproduce, so we fall back to a prefix search.
function Get-ProjectFolderName([string]$Path) {
    return ($Path.TrimEnd('\') -replace '[^A-Za-z0-9]', '-')
}

function Find-ProjectFolder([string]$ClaudeDir, [string]$Path) {
    $projectsDir = Join-Path $ClaudeDir 'projects'
    $name = Get-ProjectFolderName $Path
    if ($name.Length -le 200) {
        if (Test-Path -LiteralPath (Join-Path $projectsDir $name)) { return $name }
        return $null
    }
    $prefix = $name.Substring(0, 200)
    $match = Get-ChildItem -LiteralPath $projectsDir -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1
    if ($match) { return $match.Name }
    return $null
}

# ---------------------------------------------------------------- json

# JavaScriptSerializer keeps keys case-sensitive (ConvertFrom-Json in 5.1 rejects keys that differ only by case,
# which ~/.claude.json does contain).
function New-Serializer {
    $s = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $s.MaxJsonLength = [int]::MaxValue
    $s.RecursionLimit = 1000
    return $s
}

function Read-JsonFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $text = [System.IO.File]::ReadAllText($Path)
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return (New-Serializer).DeserializeObject($text)
}

# JavaScriptSerializer escapes ' & < > as \uXXXX: valid but unreadable, so strings are escaped here.
function ConvertTo-JsonString([string]$Text) {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    foreach ($c in $Text.ToCharArray()) {
        switch ($c) {
            '"' { [void]$sb.Append('\"') }
            '\' { [void]$sb.Append('\\') }
            "`n" { [void]$sb.Append('\n') }
            "`r" { [void]$sb.Append('\r') }
            "`t" { [void]$sb.Append('\t') }
            default {
                if ([int]$c -lt 32) { [void]$sb.AppendFormat('\u{0:x4}', [int]$c) } else { [void]$sb.Append($c) }
            }
        }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function ConvertTo-PrettyJson($Value, [int]$Indent = 0) {
    $pad = '  ' * ($Indent + 1)
    $end = '  ' * $Indent
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [string]) { return (ConvertTo-JsonString $Value) }
    if ($Value -is [bool]) { if ($Value) { return 'true' } else { return 'false' } }
    if ($Value -is [System.Collections.IDictionary]) {
        if ($Value.Count -eq 0) { return '{}' }
        $parts = foreach ($key in $Value.Keys) {
            $pad + (ConvertTo-JsonString ([string]$key)) + ': ' + (ConvertTo-PrettyJson $Value[$key] ($Indent + 1))
        }
        return "{`n" + ($parts -join ",`n") + "`n$end}"
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $items = @($Value)
        if ($items.Count -eq 0) { return '[]' }
        $parts = foreach ($item in $items) { $pad + (ConvertTo-PrettyJson $item ($Indent + 1)) }
        return "[`n" + ($parts -join ",`n") + "`n$end]"
    }
    if ($Value -is [System.IFormattable]) { return $Value.ToString($null, [System.Globalization.CultureInfo]::InvariantCulture) }
    return (ConvertTo-JsonString ([string]$Value))
}

# UTF-8 without BOM: Claude Code is a Node app and JSON.parse rejects a BOM.
function Write-TextFile([string]$Path, [string]$Text) {
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $tmp = "$Path.tmp-$PID"
    [System.IO.File]::WriteAllText($tmp, $Text, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Write-JsonFile([string]$Path, $Value) { Write-TextFile $Path ((ConvertTo-PrettyJson $Value) + "`n") }

function New-Dict { return (New-Object 'System.Collections.Generic.Dictionary[string,object]') }

function Get-DictValue($Dict, [string]$Key) {
    if ($null -ne $Dict -and $Dict.ContainsKey($Key)) { return $Dict[$Key] }
    return $null
}

# ---------------------------------------------------------------- registry

function Read-Registry([string]$ClaudeDir) {
    $reg = Read-JsonFile (Get-RegistryFile $ClaudeDir)
    if ($null -eq $reg) { $reg = New-Dict }
    if (-not $reg.ContainsKey('version')) { $reg['version'] = 1 }
    if (-not $reg.ContainsKey('workspaces') -or $null -eq $reg['workspaces']) { $reg['workspaces'] = New-Dict }
    return $reg
}

function Save-Registry([string]$ClaudeDir, $Registry) { Write-JsonFile (Get-RegistryFile $ClaudeDir) $Registry }

function Find-WorkspaceByPath($Registry, [string]$Path) {
    foreach ($name in @($Registry['workspaces'].Keys)) {
        if ([string]$Registry['workspaces'][$name]['path'] -ieq $Path) { return $name }
    }
    return $null
}

function Get-UniqueWorkspaceName($Registry, [string]$Path) {
    $base = Split-Path -Leaf $Path
    if ([string]::IsNullOrWhiteSpace($base)) { $base = Get-ProjectFolderName $Path }
    $base = $base -replace '[^A-Za-z0-9._-]', '-'
    $name = $base
    $i = 2
    while ($Registry['workspaces'].ContainsKey($name)) { $name = "$base-$i"; $i++ }
    return $name
}

function Get-Now { return (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss') }

# Adds or refreshes the entry for $Path. Returns the workspace name.
function Register-Workspace([string]$ClaudeDir, $Registry, [string]$Path, [string]$Folder) {
    $Path = ConvertTo-NormalizedPath $Path
    if (-not $Folder) { $Folder = Find-ProjectFolder $ClaudeDir $Path }
    if (-not $Folder) { $Folder = Get-ProjectFolderName $Path }
    $name = Find-WorkspaceByPath $Registry $Path
    if (-not $name) {
        $name = Get-UniqueWorkspaceName $Registry $Path
        $entry = New-Dict
        $entry['path'] = $Path
        $entry['folder'] = $Folder
        $entry['computer'] = $env:COMPUTERNAME
        $entry['firstSeen'] = Get-Now
        $entry['lastUsed'] = Get-Now
        $entry['previousPaths'] = @()
        $Registry['workspaces'][$name] = $entry
    } else {
        $entry = $Registry['workspaces'][$name]
        $entry['folder'] = $Folder
        $entry['computer'] = $env:COMPUTERNAME
        $entry['lastUsed'] = Get-Now
    }
    return $name
}

# Reads the working directory recorded in a project's transcripts (first "cwd" found).
function Get-CwdFromTranscripts([string]$FolderPath) {
    $files = Get-ChildItem -LiteralPath $FolderPath -Filter '*.jsonl' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending
    foreach ($file in $files) {
        $reader = $null
        try {
            $reader = New-Object System.IO.StreamReader($file.FullName)
            for ($i = 0; $i -lt 200 -and -not $reader.EndOfStream; $i++) {
                $line = $reader.ReadLine()
                $m = [regex]::Match($line, '"cwd":("(?:[^"\\]|\\.)*")')
                if ($m.Success) {
                    try { return [string](New-Serializer).DeserializeObject($m.Groups[1].Value) }
                    catch { return $m.Groups[1].Value.Trim('"').Replace('\\', '\') }
                }
            }
        } catch { } finally { if ($reader) { $reader.Dispose() } }
    }
    return $null
}

# Every project path Claude Code has recorded in its global state file (case-sensitive keys).
function Get-KnownProjectPaths([string]$ClaudeDir) {
    $paths = @()
    try {
        $cfg = Read-JsonFile (Get-GlobalConfigFile $ClaudeDir)
        $projects = Get-DictValue $cfg 'projects'
        if ($projects) { $paths += @($projects.Keys | ForEach-Object { $_ -replace '/', '\' }) }
    } catch { }
    return $paths
}

# Builds registry entries for every folder under projects\ that is not registered yet.
function Update-RegistryFromDisk([string]$ClaudeDir, $Registry) {
    $projectsDir = Join-Path $ClaudeDir 'projects'
    $known = Get-KnownProjectPaths $ClaudeDir
    $added = @()
    $unknown = @()
    $registered = @{}
    foreach ($e in $Registry['workspaces'].Values) { $registered[([string]$e['folder']).ToLower()] = $true }
    foreach ($dir in (Get-ChildItem -LiteralPath $projectsDir -Directory -ErrorAction SilentlyContinue)) {
        if ($registered.ContainsKey($dir.Name.ToLower())) { continue }
        $path = Get-CwdFromTranscripts $dir.FullName
        if (-not $path) {
            $path = $known | Where-Object { (Get-ProjectFolderName $_) -ieq $dir.Name } | Select-Object -First 1
        }
        if ($path) {
            $added += Register-Workspace $ClaudeDir $Registry $path $dir.Name
        } else {
            $unknown += $dir.Name
        }
    }
    return @{ Added = $added; Unknown = $unknown }
}

# ---------------------------------------------------------------- settings

function Get-HookCommand {
    # Valid in Git Bash and in PowerShell alike: single quotes, no inner double quotes.
    # The script path is resolved from CLAUDE_CONFIG_DIR at run time, so the data folder stays portable.
    return "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command '& (Join-Path `$env:CLAUDE_CONFIG_DIR portable\scripts\register-workspace.ps1)'"
}

function Test-HookInstalled($Settings) {
    $hooks = Get-DictValue $Settings 'hooks'
    $start = Get-DictValue $hooks 'SessionStart'
    if (-not $start) { return $false }
    foreach ($group in @($start)) {
        foreach ($h in @(Get-DictValue $group 'hooks')) {
            if ($h -and ([string](Get-DictValue $h 'command')).Contains($script:HookMarker)) { return $true }
        }
    }
    return $false
}

function Add-SessionStartHook($Settings) {
    if (Test-HookInstalled $Settings) { return $false }
    if (-not $Settings.ContainsKey('hooks') -or $null -eq $Settings['hooks']) { $Settings['hooks'] = New-Dict }
    $hooks = $Settings['hooks']
    $list = @()
    if ($hooks.ContainsKey('SessionStart') -and $hooks['SessionStart']) { $list = @($hooks['SessionStart']) }
    $hook = New-Dict
    $hook['type'] = 'command'
    $hook['command'] = Get-HookCommand
    $hook['timeout'] = 30
    $group = New-Dict
    $group['matcher'] = 'startup|resume'
    $group['hooks'] = @($hook)
    $hooks['SessionStart'] = $list + @($group)
    return $true
}

function Remove-SessionStartHook($Settings) {
    $hooks = Get-DictValue $Settings 'hooks'
    $start = Get-DictValue $hooks 'SessionStart'
    if (-not $start) { return $false }
    $kept = @()
    $removed = $false
    foreach ($group in @($start)) {
        $inner = @(@(Get-DictValue $group 'hooks') | Where-Object { -not ([string](Get-DictValue $_ 'command')).Contains($script:HookMarker) })
        if ($inner.Count -ne @(Get-DictValue $group 'hooks').Count) { $removed = $true }
        if ($inner.Count -gt 0) { $group['hooks'] = $inner; $kept += $group }
    }
    if ($kept.Count -gt 0) { $hooks['SessionStart'] = $kept } else { [void]$hooks.Remove('SessionStart') }
    if ($hooks.Count -eq 0) { [void]$Settings.Remove('hooks') }
    return $removed
}

function Read-Settings([string]$ClaudeDir) {
    $settings = Read-JsonFile (Join-Path $ClaudeDir 'settings.json')
    if ($null -eq $settings) { $settings = New-Dict }
    return $settings
}

function Save-Settings([string]$ClaudeDir, $Settings) {
    $file = Join-Path $ClaudeDir 'settings.json'
    if (Test-Path -LiteralPath $file) {
        Copy-Item -LiteralPath $file -Destination "$file.bak" -Force
    }
    Write-JsonFile $file $Settings
}

# ---------------------------------------------------------------- user CLAUDE.md block

function Get-ClaudeMdBlock {
    $lines = @(
        $script:ClaudeMdStart,
        '## Portable Claude data (claude-portable)',
        '',
        '- All Claude Code data (settings, transcripts, auto memory) lives in the folder named by the',
        '  `CLAUDE_CONFIG_DIR` environment variable, so it can be moved to another computer.',
        '- `portable\workspaces.json` in that folder is the registry of workspaces (project path ->',
        '  folder under `projects\`). A SessionStart hook keeps it up to date; do not edit it by hand.',
        '- When the user says a project now lives at a different path (moved folder, new computer):',
        '  1. Read the registry and find the workspace by name or old path.',
        '  2. Run `relink-workspace.ps1` from `portable\scripts` with `-DryRun` first, show the plan,',
        '     then run it for real after the user agrees:',
        '     `powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:CLAUDE_CONFIG_DIR\portable\scripts\relink-workspace.ps1" -Name <name> -NewPath "<new path>"`',
        '  3. If the workspace being relinked is the one of the current session, tell the user to',
        '     reopen Claude Code in the new path afterwards (the running session keeps the old folder).',
        '- Never copy or upload `.credentials.json`; on a new computer the user logs in again.',
        $script:ClaudeMdEnd
    )
    return ($lines -join "`n")
}

function Set-ClaudeMdBlock([string]$ClaudeDir) {
    $file = Join-Path $ClaudeDir 'CLAUDE.md'
    $block = Get-ClaudeMdBlock
    $text = ''
    if (Test-Path -LiteralPath $file) { $text = [System.IO.File]::ReadAllText($file) }
    $pattern = [regex]::Escape($script:ClaudeMdStart) + '[\s\S]*?' + [regex]::Escape($script:ClaudeMdEnd)
    if ($text -match $pattern) {
        $text = [regex]::Replace($text, $pattern, { param($m) $block })
    } else {
        if ($text.Length -gt 0 -and -not $text.EndsWith("`n")) { $text += "`n" }
        if ($text.Length -gt 0) { $text += "`n" }
        $text += $block + "`n"
    }
    Write-TextFile $file $text
}

function Remove-ClaudeMdBlock([string]$ClaudeDir) {
    $file = Join-Path $ClaudeDir 'CLAUDE.md'
    if (-not (Test-Path -LiteralPath $file)) { return }
    $text = [System.IO.File]::ReadAllText($file)
    $pattern = '\n?' + [regex]::Escape($script:ClaudeMdStart) + '[\s\S]*?' + [regex]::Escape($script:ClaudeMdEnd) + '\n?'
    $text = [regex]::Replace($text, $pattern, '')
    if ([string]::IsNullOrWhiteSpace($text)) { Remove-Item -LiteralPath $file -Force } else { Write-TextFile $file $text }
}

# ---------------------------------------------------------------- misc

function Get-ClaudeProcesses {
    return @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^(claude|Code|Claude)$' })
}

function Assert-ClaudeClosed([switch]$Force) {
    # @() again at the call site: a function returning 0 or 1 items does not return an array.
    $procs = @(Get-ClaudeProcesses)
    if ($procs.Count -eq 0) { return $true }
    Write-Warn ('Claude Code or VS Code is running: ' + (($procs | ForEach-Object { $_.ProcessName } | Sort-Object -Unique) -join ', '))
    Write-Info 'Close every Claude Code terminal, the Claude desktop app and VS Code, so no file is being written.'
    if ($Force) { Write-Warn 'Continuing anyway (-Force).'; return $true }
    return (Confirm-Choice 'Continue anyway?' $false)
}

# robocopy wrapper: returns $true on success (exit codes below 8).
function Invoke-Robocopy([string]$Source, [string]$Destination, [string[]]$ExtraArgs = @()) {
    $rcArgs = @($Source, $Destination, '/E', '/COPY:DAT', '/R:2', '/W:1', '/NFL', '/NDL', '/NJH', '/NJS', '/NP') + $ExtraArgs
    & robocopy.exe @rcArgs | Out-Null
    return ($LASTEXITCODE -lt 8)
}

function Copy-PortableScripts([string]$ClaudeDir) {
    # This file lives in scripts\lib, so the parent folder is scripts\.
    $source = Split-Path -Parent $PSScriptRoot
    $target = Join-Path (Get-PortableDir $ClaudeDir) 'scripts'
    if ((ConvertTo-NormalizedPath $source) -ieq (ConvertTo-NormalizedPath $target)) { return }
    if (-not (Invoke-Robocopy $source $target @('/PURGE'))) { throw "Could not copy the scripts to $target" }
}

# Launcher and readme inside the data folder, so it can be used without the repository.
$script:LauncherName = 'claude-portable.bat'

function Install-DataFolderFiles([string]$ClaudeDir) {
    $templates = Join-Path (Split-Path -Parent $PSScriptRoot) 'data-folder'
    Copy-Item -LiteralPath (Join-Path $templates $script:LauncherName) -Destination (Join-Path $ClaudeDir $script:LauncherName) -Force
    Copy-Item -LiteralPath (Join-Path $templates 'README.md') -Destination (Join-Path (Get-PortableDir $ClaudeDir) 'README.md') -Force
}
