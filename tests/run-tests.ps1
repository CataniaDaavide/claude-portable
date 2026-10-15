<#
.SYNOPSIS
    Test suite for the Windows scripts. Windows PowerShell 5.1, no dependencies.

.DESCRIPTION
    Every test works on fake Claude data in a temporary folder and runs the scripts as separate
    processes, the way the menu does. The real Claude data, the real CLAUDE_CONFIG_DIR and the user
    profile are never touched: every script runs with -SkipEnvironment and a fake folder.
    Exit code 0 when every test passes. Run: powershell -ExecutionPolicy Bypass -File tests\run-tests.ps1
#>
param([switch]$KeepTemp)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$Scripts = Join-Path $Root 'scripts'
$Work = Join-Path ([System.IO.Path]::GetTempPath()) ('claude-portable-tests-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $Work -Force | Out-Null
. (Join-Path $Scripts 'lib\common.ps1')
# Anything that falls back to "the data folder in use" lands on an empty fake folder, never on real data.
$SavedConfigDir = $env:CLAUDE_CONFIG_DIR
$env:CLAUDE_CONFIG_DIR = Join-Path $Work 'no-data-folder'

$script:Passed = 0
$script:Failed = 0

function Test-Case([string]$Name, [scriptblock]$Body) {
    try {
        & $Body
        Write-Host "  PASS  $Name" -ForegroundColor Green
        $script:Passed++
    } catch {
        Write-Host "  FAIL  $Name" -ForegroundColor Red
        Write-Host "        $($_.Exception.Message)" -ForegroundColor Red
        $script:Failed++
    }
}

function Assert-True($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Assert-Equal($Expected, $Actual, [string]$Message) {
    if ($Expected -ne $Actual) { throw "$Message (expected '$Expected', got '$Actual')" }
}
function Assert-Contains([string]$Text, [string]$Part, [string]$Message) {
    if (-not $Text.Contains($Part)) { throw "$Message (missing '$Part')`n$Text" }
}

# Runs a script in its own process with extra environment variables and optional typed answers.
function Invoke-Child([string]$Script, [string[]]$Arguments = @(), [string]$Answers = '', [hashtable]$Environment = @{}) {
    $Environment['CLAUDE_PORTABLE_SKIP_PROCESS_CHECK'] = '1'
    $saved = @{}
    foreach ($key in @($Environment.Keys)) {
        $saved[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
        [Environment]::SetEnvironmentVariable($key, $Environment[$key], 'Process')
    }
    try {
        $all = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Script) + $Arguments
        $output = $Answers | & powershell.exe @all 2>&1 | Out-String
        return [pscustomobject]@{ Output = $output; ExitCode = $LASTEXITCODE }
    } finally {
        foreach ($key in $saved.Keys) { [Environment]::SetEnvironmentVariable($key, $saved[$key], 'Process') }
    }
}

function Write-Json([string]$Path, [string]$Text) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function ConvertTo-JsonLine([string]$Cwd) { return '{"type":"user","cwd":' + (ConvertTo-JsonString $Cwd) + '}' }

# Fake ~/.claude: two workspaces with chats (one inside the other), one known only from .claude.json,
# an existing user hook and user notes that must survive, a login and a cache that must not travel.
function New-Fixture([string]$Dir) {
    Write-Json "$Dir\projects\C--Old-App\a.jsonl" ('{"type":"summary"}' + "`n" + (ConvertTo-JsonLine 'C:\Old\App'))
    Write-Json "$Dir\projects\C--Old-App\memory\MEMORY.md" "- [One](one.md) - first`n"
    Write-Json "$Dir\projects\C--Old-App\memory\one.md" 'one'
    Write-Json "$Dir\projects\C--Old-App-api\b.jsonl" (ConvertTo-JsonLine 'C:\Old\App\api')
    New-Item -ItemType Directory -Path "$Dir\projects\C--Old-NoChat\memory" -Force | Out-Null
    Write-Json "$Dir\settings.json" '{"theme":"dark","hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"echo hi"}]}]}}'
    Write-Json "$Dir\CLAUDE.md" "# my notes`n"
    Write-Json "$Dir\.credentials.json" 'secret'
    Write-Json "$Dir\cache\x.txt" 'cache'
    # Keys that differ only by case: Windows PowerShell's ConvertFrom-Json rejects them.
    Write-Json "$Dir\.claude.json" ('{"projects":{"C:/Old/NoChat":{"a":1},"c:/Old/NoChat":{"a":2},' +
        '"C:/Old/App":{"hasTrustDialogAccepted":true,"allowedTools":["Bash(npm test)"],"lastCost":0.25}},"userID":"x"}')
}

# A data folder installed from the fixture.
function New-Installed([string]$Name) {
    $src = Join-Path $Work "$Name-src"
    $data = Join-Path $Work "$Name-data"
    New-Fixture $src
    $r = Invoke-Child "$Scripts\install.ps1" @('-Source', $src, '-DataDir', $data, '-SkipEnvironment', '-Force')
    Assert-Equal 0 $r.ExitCode "install failed: $($r.Output)"
    return $data
}

function Get-HookCommandFrom([string]$Data) {
    $settings = Read-JsonFile (Join-Path $Data 'settings.json')
    foreach ($group in @($settings['hooks']['SessionStart'])) {
        foreach ($h in @($group['hooks'])) { if (Test-PortableHookCommand $h['command']) { return $h['command'] } }
    }
    throw 'hook not found'
}

$GitBash = $null
$git = Get-Command git -ErrorAction SilentlyContinue
if ($git) {
    $candidate = Join-Path (Split-Path -Parent (Split-Path -Parent $git.Source)) 'bin\bash.exe'
    if (Test-Path -LiteralPath $candidate) { $GitBash = $candidate }
}

# Runs the installed hook exactly as Claude Code does: through Git Bash, or PowerShell without it.
function Invoke-Hook([string]$Data, [string]$Project, [string]$Shell = 'bash') {
    $command = Get-HookCommandFrom $Data
    $saved = @($env:CLAUDE_CONFIG_DIR, $env:CLAUDE_PROJECT_DIR)
    $env:CLAUDE_CONFIG_DIR = $Data
    $env:CLAUDE_PROJECT_DIR = $Project
    try {
        if ($Shell -eq 'bash') {
            $file = Join-Path $Work 'hook.sh'
            [System.IO.File]::WriteAllText($file, $command + "`n")
            return ((& $GitBash $file 2>&1) | Out-String).Trim()
        }
        return ((& powershell.exe -NoProfile -Command $command 2>&1) | Out-String).Trim()
    } finally {
        $env:CLAUDE_CONFIG_DIR = $saved[0]
        $env:CLAUDE_PROJECT_DIR = $saved[1]
    }
}

Write-Host ''
Write-Host "claude-portable tests ($(Get-PortableVersion)) in $Work" -ForegroundColor White

# ---------------------------------------------------------------- helpers

Test-Case 'project folder name follows the Claude Code rule' {
    Assert-Equal 'C--Users-me-Desktop-my-app' (Get-ProjectFolderName 'C:\Users\me\Desktop\my-app') 'folder name'
    Assert-Equal 'c--Users-Davide-Catania-Desktop-estensione-semiautoclick' (Get-ProjectFolderName 'c:\Users\Davide Catania\Desktop\estensione,semiautoclick') 'spaces and commas'
}

Test-Case 'short 8.3 paths are expanded to the long form' {
    $long = Join-Path $Work 'A long folder name'
    New-Item -ItemType Directory -Path $long -Force | Out-Null
    $fso = New-Object -ComObject Scripting.FileSystemObject
    $short = $fso.GetFolder($long).ShortPath
    if ($short -eq $long) { Write-Host '        (8.3 names disabled on this volume: nothing to expand)' -ForegroundColor DarkGray; return }
    Assert-Equal (ConvertTo-NormalizedPath $long) (ConvertTo-NormalizedPath $short) 'short path not expanded'
}

Test-Case 'JSON with keys that differ only by case is read and written back' {
    $file = Join-Path $Work 'case.json'
    Write-Json $file '{"a":{"C:/x":1,"c:/x":2},"s":"it''s & <ok>"}'
    $value = Read-JsonFile $file
    Write-JsonFile $file $value
    $text = [System.IO.File]::ReadAllText($file)
    Assert-Contains $text '"C:/x": 1' 'upper-case key'
    Assert-Contains $text '"c:/x": 2' 'lower-case key'
    Assert-Contains $text "it's & <ok>" 'strings stay readable'
    $bytes = [System.IO.File]::ReadAllBytes($file)
    Assert-True (-not ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB)) 'file written with a BOM'
}

Test-Case 'version numbers compare numerically' {
    Assert-True ((Compare-Version '1.10.0' '1.9.0') -gt 0) '1.10.0 > 1.9.0'
    Assert-True ((Compare-Version '1.1.0' '1.1.0') -eq 0) 'equal versions'
}

# ---------------------------------------------------------------- install

$data = $null
Test-Case 'install copies the data and sets up settings, hook, CLAUDE.md, registry, launchers, docs' {
    $script:data = New-Installed 'main'
    $d = $script:data
    Assert-True (Test-Path "$d\projects\C--Old-App\a.jsonl") 'chats copied'
    Assert-True (Test-Path "$d\.claude.json") '.claude.json copied'
    $settings = Read-JsonFile "$d\settings.json"
    Assert-Equal 36500 $settings['cleanupPeriodDays'] 'retention'
    Assert-Equal 'dark' $settings['theme'] 'existing settings kept'
    Assert-Equal 'echo hi' $settings['hooks']['PreToolUse'][0]['hooks'][0]['command'] 'existing hook kept'
    Assert-True (Test-HookInstalled $settings) 'hook installed'
    $md = [System.IO.File]::ReadAllText("$d\CLAUDE.md")
    Assert-Contains $md '# my notes' 'user notes kept'
    Assert-Contains $md 'claude-portable:start' 'block added'
    $reg = Read-Registry $d
    Assert-Equal 'C:\Old\App' $reg['workspaces']['App']['path'] 'path from transcripts'
    Assert-Equal 'C:\Old\App\api' $reg['workspaces']['api']['path'] 'nested workspace'
    Assert-True ($reg['workspaces'].ContainsKey('NoChat')) 'path from .claude.json'
    foreach ($f in @('claude-portable.bat', 'claude-portable.sh', 'portable\README.md', 'portable\scripts\VERSION',
                     'portable\unix\claude_portable.py', 'portable\docs\README.md', 'portable\docs\CHANGELOG.md')) {
        Assert-True (Test-Path "$d\$f") "missing $f"
    }
    $docs = [System.IO.File]::ReadAllText("$d\portable\docs\README.md")
    Assert-True (-not $docs.Contains('docs/images/')) 'image links not rewritten for the data folder'
}

Test-Case 'install again on the folder in use changes nothing but scripts and settings' {
    $d = $script:data
    $env:CLAUDE_CONFIG_DIR = $d
    try { $r = Invoke-Child "$Scripts\install.ps1" @('-DataDir', $d, '-SkipEnvironment', '-Force') } finally { $env:CLAUDE_CONFIG_DIR = $null }
    Assert-Equal 0 $r.ExitCode $r.Output
    Assert-Contains $r.Output 'already in the portable folder' 'update path'
    $settings = Read-JsonFile "$d\settings.json"
    Assert-Equal 1 @($settings['hooks']['SessionStart']).Count 'hook duplicated'
    $md = [System.IO.File]::ReadAllText("$d\CLAUDE.md")
    Assert-Equal 1 ([regex]::Matches($md, 'claude-portable:start')).Count 'CLAUDE.md block duplicated'
}

Test-Case 'the macOS/Linux hook of a data folder coming from another system is replaced' {
    $settings = New-Dict
    $settings['hooks'] = New-Dict
    $old = New-Dict; $old['type'] = 'command'; $old['command'] = 'python3 "$CLAUDE_CONFIG_DIR/portable/unix/claude_portable.py" hook'
    $group = New-Dict; $group['matcher'] = 'startup|resume'; $group['hooks'] = @($old)
    $settings['hooks']['SessionStart'] = @($group)
    Assert-True (-not (Test-HookInstalled $settings)) 'unix hook counted as installed'
    Assert-True (Add-SessionStartHook $settings) 'hook not added'
    $commands = @($settings['hooks']['SessionStart'] | ForEach-Object { $_['hooks'] } | ForEach-Object { $_['command'] })
    Assert-Equal 1 $commands.Count 'old hook kept'
    Assert-Equal (Get-HookCommand) $commands[0] 'windows hook'
}

Test-Case 'install on a data folder that was moved switches to import and keeps its newer data' {
    $moved = New-Installed 'moved'
    $target = Join-Path $Work 'moved-new-place'
    Move-Item $moved $target
    Write-Json "$target\projects\C--Old-App\newer.jsonl" (ConvertTo-JsonLine 'C:\Old\App')
    $r = Invoke-Child "$Scripts\install.ps1" @('-DataDir', $target, '-SkipEnvironment', '-Force') -Environment @{ CLAUDE_CONFIG_DIR = $moved }
    Assert-Equal 0 $r.ExitCode $r.Output
    Assert-Contains $r.Output 'switching to Import' 'no switch to import'
    Assert-True (Test-Path "$target\projects\C--Old-App\newer.jsonl") 'newer chat lost'
}

# ---------------------------------------------------------------- hook

Test-Case 'hook through Git Bash registers a new project silently' {
    if (-not $GitBash) { Write-Host '        (Git Bash not found: skipped)' -ForegroundColor DarkGray; return }
    $project = Join-Path $Work 'projects-on-disk\Zeta'
    New-Item -ItemType Directory -Path $project -Force | Out-Null
    $out = Invoke-Hook $script:data $project 'bash'
    Assert-Equal '' $out 'the hook printed something'
    Assert-True ((Read-Registry $script:data)['workspaces'].ContainsKey('Zeta')) 'not registered'
}

Test-Case 'hook through PowerShell notices a moved project and does not register it' {
    $project = Join-Path $Work 'projects-on-disk\App'
    New-Item -ItemType Directory -Path $project -Force | Out-Null
    $out = Invoke-Hook $script:data $project 'powershell'
    Assert-Contains $out '[claude-portable]' 'no note'
    Assert-Contains $out "'App', last seen at C:\Old\App" 'candidate missing'
    Assert-True (-not (Find-WorkspaceByPath (Read-Registry $script:data) $project)) 'moved project registered'
}

Test-Case 'register -Path stops the note for a project that is a different one' {
    $project = Join-Path $Work 'other\App'
    New-Item -ItemType Directory -Path $project -Force | Out-Null
    $r = Invoke-Child "$($script:data)\portable\scripts\register-workspace.ps1" @('-Path', $project) -Environment @{ CLAUDE_CONFIG_DIR = $script:data }
    Assert-Contains $r.Output 'Registered' $r.Output
    Assert-Equal '' (Invoke-Hook $script:data $project 'powershell') 'note still printed'
}

# ---------------------------------------------------------------- relink, forget

Test-Case 'relink renames the folder and moves the nested workspace too' {
    $new = Join-Path $Work 'projects-on-disk\App'
    $r = Invoke-Child "$Scripts\relink-workspace.ps1" @('-Name', 'App', '-NewPath', $new, '-Force') -Environment @{ CLAUDE_CONFIG_DIR = $script:data }
    Assert-Equal 0 $r.ExitCode $r.Output
    $reg = Read-Registry $script:data
    Assert-Equal $new $reg['workspaces']['App']['path'] 'path'
    Assert-Equal "$new\api" $reg['workspaces']['api']['path'] 'nested path'
    Assert-True (@($reg['workspaces']['App']['previousPaths']) -contains 'C:\Old\App') 'previous path'
    Assert-True (Test-Path "$($script:data)\projects\$(Get-ProjectFolderName $new)\a.jsonl") 'chats not moved'
    Assert-Equal '' (Invoke-Hook $script:data $new 'powershell') 'note after relink'
}

Test-Case 'relink copies folder trust and permissions to the new path and keeps the rest of .claude.json' {
    $new = Join-Path $Work 'projects-on-disk\App'
    $config = Read-JsonFile "$($script:data)\.claude.json"
    $projects = $config['projects']
    $key = ConvertTo-ConfigKey $new
    $upper = $key.Substring(0, 1).ToUpper() + $key.Substring(1)
    $lower = $key.Substring(0, 1).ToLower() + $key.Substring(1)
    foreach ($k in @($upper, $lower)) {
        Assert-True ($projects.ContainsKey($k)) "no entry for $k"
        Assert-Equal $true $projects[$k]['hasTrustDialogAccepted'] 'trust not copied'
        Assert-Equal 'Bash(npm test)' @($projects[$k]['allowedTools'])[0] 'allowed tools not copied'
    }
    Assert-True ($projects.ContainsKey('C:/Old/App')) 'old entry removed'
    Assert-True ($projects.ContainsKey('C:/Old/NoChat') -and $projects.ContainsKey('c:/Old/NoChat')) 'case-only keys lost'
    Assert-Equal 'x' $config['userID'] 'other settings lost'
    Assert-True (@(Get-ChildItem "$($script:data)\portable\relink-backups" -Filter '.claude.json-*').Count -ge 1) 'no backup of .claude.json'
}

Test-Case 'old chats are archived with their subfolders, memory stays, archive follows a relink and restores' {
    $d = New-Installed 'archive'
    $folder = "$d\projects\C--Old-App"
    $old = (Get-Date).AddDays(-400)
    (Get-Item "$folder\a.jsonl").LastWriteTime = $old
    Write-Json "$folder\a\subagents\agent-1.jsonl" '{}'
    Write-Json "$folder\recent.jsonl" (ConvertTo-JsonLine 'C:\Old\App')
    $r = Invoke-Child "$Scripts\archive-chats.ps1" @('-OlderThanDays', '180', '-Force') -Environment @{ CLAUDE_CONFIG_DIR = $d }
    Assert-Equal 0 $r.ExitCode $r.Output
    Assert-True (-not (Test-Path "$folder\a.jsonl")) 'old chat still there'
    Assert-True (-not (Test-Path "$folder\a")) 'companion folder still there'
    Assert-True (Test-Path "$folder\recent.jsonl") 'recent chat archived'
    Assert-True (Test-Path "$folder\memory\one.md") 'memory archived'
    Assert-Equal 1 (Get-ArchivedChatCount $d 'C--Old-App') 'archived count'

    $status = Invoke-Child "$Scripts\status.ps1" -Environment @{ CLAUDE_CONFIG_DIR = $d }
    Assert-Contains $status.Output 'Archived' 'status column'

    $new = Join-Path $Work 'archive-moved\App'
    New-Item -ItemType Directory -Path $new -Force | Out-Null
    $r = Invoke-Child "$Scripts\relink-workspace.ps1" @('-Name', 'App', '-NewPath', $new, '-Force') -Environment @{ CLAUDE_CONFIG_DIR = $d }
    Assert-Equal 0 $r.ExitCode $r.Output
    $newFolder = Get-ProjectFolderName $new
    Assert-Equal 1 (Get-ArchivedChatCount $d $newFolder) 'archive did not follow the relink'

    $r = Invoke-Child "$Scripts\restore-chats.ps1" @('-Name', 'App', '-Force') -Environment @{ CLAUDE_CONFIG_DIR = $d }
    Assert-Equal 0 $r.ExitCode $r.Output
    $restored = "$d\projects\$newFolder\a.jsonl"
    Assert-True (Test-Path $restored) 'chat not restored'
    Assert-True (Test-Path "$d\projects\$newFolder\a\subagents\agent-1.jsonl") 'companion not restored'
    Assert-True ([math]::Abs(((Get-Item $restored).LastWriteTime - $old).TotalMinutes) -lt 2) 'original date lost'
    Assert-True (-not (Test-Path (Get-ArchiveFile $d $newFolder))) 'archive not removed after restore'
}

Test-Case 'relink into an existing folder merges without losing anything' {
    $d = New-Installed 'merge'
    $new = Join-Path $Work 'merge-target\App'
    New-Item -ItemType Directory -Path $new -Force | Out-Null
    $target = "$d\projects\$(Get-ProjectFolderName $new)"
    Write-Json "$target\new.jsonl" (ConvertTo-JsonLine $new)
    Write-Json "$target\memory\MEMORY.md" "- [New](new.md) - n`n"
    Write-Json "$target\memory\one.md" 'NEW'
    $r = Invoke-Child "$Scripts\relink-workspace.ps1" @('-Name', 'App', '-NewPath', $new, '-Force') -Environment @{ CLAUDE_CONFIG_DIR = $d }
    Assert-Equal 0 $r.ExitCode $r.Output
    Assert-True ((Test-Path "$target\a.jsonl") -and (Test-Path "$target\new.jsonl")) 'chats from both sides'
    $index = [System.IO.File]::ReadAllText("$target\memory\MEMORY.md")
    Assert-Contains $index '[New]' 'new index line'
    Assert-Contains $index '[One]' 'old index line'
    Assert-Equal 'NEW' ([System.IO.File]::ReadAllText("$target\memory\one.md")) 'newer file overwritten'
    Assert-True (@(Get-ChildItem "$d\portable\relink-backups" -Directory).Count -eq 1) 'old folder not kept as backup'
}

Test-Case 'forget moves the chats aside and removes the workspace' {
    $r = Invoke-Child "$Scripts\forget-workspace.ps1" @('-Name', 'NoChat', '-Force') -Environment @{ CLAUDE_CONFIG_DIR = $script:data }
    Assert-Equal 0 $r.ExitCode $r.Output
    Assert-True (-not (Read-Registry $script:data)['workspaces'].ContainsKey('NoChat')) 'still registered'
    Assert-True (-not (Test-Path "$($script:data)\projects\C--Old-NoChat")) 'folder still in projects'
    Assert-True (@(Get-ChildItem "$($script:data)\portable\forgotten").Count -eq 1) 'folder not kept'
}

# ---------------------------------------------------------------- export, import

$zip = Join-Path $Work 'export.zip'
Test-Case 'export leaves out the login and the caches and uses standard zip paths' {
    $r = Invoke-Child "$Scripts\export-data.ps1" @('-Output', $zip, '-Force') -Environment @{ CLAUDE_CONFIG_DIR = $script:data }
    Assert-Equal 0 $r.ExitCode $r.Output
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($zip)
    try { $names = @($archive.Entries | ForEach-Object { $_.FullName }) } finally { $archive.Dispose() }
    Assert-True ($names -contains 'portable/workspaces.json') 'registry missing'
    Assert-True ($names -contains '.claude.json') '.claude.json missing'
    Assert-True (-not ($names -contains '.credentials.json')) 'login exported'
    Assert-True (-not ($names | Where-Object { $_ -like 'cache/*' -or $_ -like '*forgotten*' })) 'cache or forgotten exported'
    Assert-True (-not ($names | Where-Object { $_.Contains('\') })) 'backslash in zip paths'
}

Test-Case 'import of the zip on a new computer asks for each moved project' {
    $newData = Join-Path $Work 'pc2-data'
    $newProject = Join-Path $Work 'pc2\Zeta'
    New-Item -ItemType Directory -Path $newProject -Force | Out-Null
    Remove-Item (Join-Path $Work 'projects-on-disk') -Recurse -Force
    # Workspaces in name order: api and App (their paths are gone: skip), App-2 (exists), Zeta (new path).
    $answers = "`n`n$newProject`n"
    $r = Invoke-Child "$Scripts\import-data.ps1" @('-From', $zip, '-DataDir', $newData, '-SkipEnvironment') -Answers $answers
    Assert-Equal 0 $r.ExitCode $r.Output
    Assert-True (-not (Test-Path "$newData\.credentials.json")) 'login appeared'
    Assert-Equal $newProject (Read-Registry $newData)['workspaces']['Zeta']['path'] 'Zeta not relinked'
    Assert-Contains $r.Output 'Log in again' 'login reminder'
}

Test-Case 'import of a copied folder in place asks about the copied login' {
    $copy = Join-Path $Work 'usb-copy'
    $null = Invoke-Robocopy $script:data $copy
    Write-Json "$copy\.credentials.json" 'secret'
    $r = Invoke-Child "$copy\portable\scripts\import-data.ps1" @('-From', $copy, '-DataDir', $copy, '-SkipEnvironment') -Answers "n`n`n`n`n`n"
    Assert-Equal 0 $r.ExitCode $r.Output
    Assert-Contains $r.Output 'Login removed' 'login question'
    Assert-True (-not (Test-Path "$copy\.credentials.json")) 'login still there'
}

# ---------------------------------------------------------------- status, uninstall, get

Test-Case 'status runs and the compatibility checks pass on real-shaped data' {
    # A chat written by "Claude Code" for a project at its current path.
    $zeta = (Read-Registry $script:data)['workspaces']['Zeta']['path']
    Write-Json "$($script:data)\projects\$(Get-ProjectFolderName $zeta)\z.jsonl" (ConvertTo-JsonLine $zeta)
    $r = Invoke-Child "$Scripts\status.ps1" -Environment @{ CLAUDE_CONFIG_DIR = $script:data }
    Assert-Equal 0 $r.ExitCode $r.Output
    Assert-Contains $r.Output 'Project folder names follow the expected rule' 'naming check'
    Assert-Contains $r.Output 'The SessionStart hook runs' 'hook check'
    Assert-True (-not $r.Output.Contains('do NOT follow')) 'naming check failed'
}

Test-Case 'uninstall removes hook and block and copies the data back to a fake profile' {
    $fakeHome = Join-Path $Work 'fake-home'
    New-Item -ItemType Directory -Path $fakeHome -Force | Out-Null
    $r = Invoke-Child "$Scripts\uninstall.ps1" @('-CopyBack', '-SkipEnvironment', '-Force') -Environment @{ CLAUDE_CONFIG_DIR = $script:data; USERPROFILE = $fakeHome }
    Assert-Equal 0 $r.ExitCode $r.Output
    Assert-True (-not (Test-HookInstalled (Read-JsonFile "$($script:data)\settings.json"))) 'hook still there'
    Assert-True (Test-Path "$fakeHome\.claude\projects") 'data not copied back'
    Assert-True (Test-Path "$fakeHome\.claude.json") '.claude.json not copied back'
    Assert-True (-not (Test-Path "$fakeHome\.claude\portable")) 'portable folder copied back'
    Assert-True (-not (Test-Path "$fakeHome\.claude\claude-portable.bat")) 'launcher copied back'
}

Test-Case 'one-command installer downloads, extracts and starts' {
    $stage = Join-Path $Work 'gh\claude-portable-main'
    $null = Invoke-Robocopy $Root $stage @('/XD', '.git', 'tests')
    $ghZip = Join-Path $Work 'gh.zip'
    Compress-Archive -Path $stage -DestinationPath $ghZip -Force
    $saved = $env:CLAUDE_PORTABLE_SOURCE
    $env:CLAUDE_PORTABLE_SOURCE = $ghZip
    try {
        # Installed: "n" declines the update. Not installed: the menu opens and "0" exits.
        $out = ("n`n0`n" | & powershell.exe -NoProfile -Command "iex (Get-Content -Raw '$Root\get.ps1')" 2>&1 | Out-String)
    } finally { $env:CLAUDE_PORTABLE_SOURCE = $saved }
    Assert-Contains $out "claude-portable $(Get-PortableVersion) ready" $out
    Assert-True (@(Get-ChildItem ([System.IO.Path]::GetTempPath()) -Directory -Filter 'claude-portable-get-*').Count -eq 0) 'download not cleaned up'
}

# ---------------------------------------------------------------- summary

Write-Host ''
$color = if ($script:Failed -eq 0) { 'Green' } else { 'Red' }
Write-Host "$($script:Passed) passed, $($script:Failed) failed" -ForegroundColor $color
$env:CLAUDE_CONFIG_DIR = $SavedConfigDir
if ($KeepTemp) { Write-Host "Test data kept in $Work" } else { Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue }
exit ([int]($script:Failed -gt 0))
