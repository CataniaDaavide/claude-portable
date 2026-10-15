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

# Expands 8.3 short names (C:\Users\DAVIDE~1\...) to long ones: Claude Code names project folders
# after the long path, so a short one would point to the wrong folder. Only existing paths can be
# expanded; Windows matches a short name in a directory listing and returns the long name.
function Expand-ShortPath([string]$Path) {
    if ($Path -notmatch '~' -or $Path.StartsWith('\\') -or -not (Test-Path -LiteralPath $Path)) { return $Path }
    $parts = $Path.Split('\')
    $current = $parts[0] + '\'
    for ($i = 1; $i -lt $parts.Length; $i++) {
        if (-not $parts[$i]) { continue }
        $name = $parts[$i]
        if ($name.Contains('~')) {
            $match = @((New-Object System.IO.DirectoryInfo($current)).GetFileSystemInfos($name)) | Select-Object -First 1
            if ($match) { $name = $match.Name }
        }
        $current = Join-Path $current $name
    }
    return $current
}

function ConvertTo-NormalizedPath([string]$Path) {
    $full = Expand-ShortPath ([System.IO.Path]::GetFullPath($Path))
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

# Registered workspaces whose path no longer exists and whose folder name matches $Path's:
# most likely the same project, moved to $Path.
function Find-MovedWorkspaces($Registry, [string]$Path) {
    $leaf = Split-Path -Leaf $Path
    $found = @()
    foreach ($name in @($Registry['workspaces'].Keys)) {
        $old = [string]$Registry['workspaces'][$name]['path']
        if ($old -ieq $Path) { continue }
        if ((Split-Path -Leaf $old) -ine $leaf) { continue }
        if (Test-Path -LiteralPath $old) { continue }
        $found += $name
    }
    return $found
}

# Moves a workspace's folder out of projects\ and removes it from the registry.
# The folder goes to portable\forgotten so it is not registered again; deleting it frees the space.
function Remove-Workspace([string]$ClaudeDir, $Registry, [string]$Name) {
    $entry = $Registry['workspaces'][$Name]
    $folder = [string]$entry['folder']
    $moved = $null
    $source = Join-Path (Join-Path $ClaudeDir 'projects') $folder
    if ($folder -and (Test-Path -LiteralPath $source)) {
        $target = Join-Path (Get-PortableDir $ClaudeDir) 'forgotten'
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        $moved = Join-Path $target ($folder + '-' + (Get-Date).ToString('yyyyMMdd-HHmmss'))
        Move-Item -LiteralPath $source -Destination $moved
    }
    if ($folder) {
        $zipTarget = Join-Path (Join-Path (Get-PortableDir $ClaudeDir) 'forgotten') ($folder + '-archive-' + (Get-Date).ToString('yyyyMMdd-HHmmss') + '.zip')
        if (Move-ChatArchive $ClaudeDir $folder $null $zipTarget) { if (-not $moved) { $moved = $zipTarget } }
    }
    [void]$Registry['workspaces'].Remove($Name)
    return $moved
}

# ---------------------------------------------------------------- project state in .claude.json

function ConvertTo-ConfigKey([string]$Path) { return $Path.Replace('\', '/') }

# Copies the per-project state Claude Code keeps in .claude.json (folder trust, allowed tools,
# project MCP servers...) from the old path to the new one, so a moved project is not treated as a
# new, untrusted folder. Claude Code keys it by the path as it received it, so on Windows the same
# folder can appear with an upper- and a lower-case drive letter: both are written.
# The old entry is kept. Returns a description of what was (or would be) done, or $null.
function Copy-ProjectState([string]$ClaudeDir, [string]$OldPath, [string]$NewPath, [switch]$DryRun) {
    $file = Get-GlobalConfigFile $ClaudeDir
    try { $config = Read-JsonFile $file } catch { return $null }
    $projects = Get-DictValue $config 'projects'
    if (-not ($projects -is [System.Collections.IDictionary])) { return $null }
    $oldKey = ConvertTo-ConfigKey $OldPath
    $sources = @($projects.Keys | Where-Object { $_ -ieq $oldKey })
    if ($sources.Count -eq 0) { return $null }
    # The fullest entry is the one Claude Code used most.
    $source = $projects[($sources | Sort-Object { $projects[$_].Count } -Descending | Select-Object -First 1)]
    $newKey = ConvertTo-ConfigKey $NewPath
    $targets = @($newKey)
    if ($newKey -match '^[A-Za-z]:') {
        # Parentheses matter: the comma binds tighter than +.
        $targets = @(($newKey.Substring(0, 1).ToUpper() + $newKey.Substring(1)), ($newKey.Substring(0, 1).ToLower() + $newKey.Substring(1)))
    }
    if ($DryRun) { return 'trust and permissions: copied to the new path' }

    $backupDir = Join-Path (Get-PortableDir $ClaudeDir) 'relink-backups'
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    Copy-Item -LiteralPath $file -Destination (Join-Path $backupDir ('.claude.json-' + (Get-Date).ToString('yyyyMMdd-HHmmss'))) -Force
    $serializer = New-Serializer
    foreach ($key in $targets) {
        if (-not $projects.ContainsKey($key)) {
            $projects[$key] = $serializer.DeserializeObject($serializer.Serialize($source))
            continue
        }
        # Already opened at the new path: add what is missing, keep what is there.
        $target = $projects[$key]
        foreach ($field in @($source.Keys)) {
            if (-not $target.ContainsKey($field)) {
                $target[$field] = $serializer.DeserializeObject($serializer.Serialize($source[$field]))
            } elseif ($field -eq 'hasTrustDialogAccepted' -and $source[$field] -eq $true) {
                $target[$field] = $true
            } elseif ($field -eq 'allowedTools') {
                $target[$field] = @(@($target[$field]) + @($source[$field]) | Where-Object { $_ } | Select-Object -Unique)
            }
        }
    }
    Write-JsonFile $file $config
    return 'trust and permissions copied to the new path'
}

# ---------------------------------------------------------------- archived chats

# Old chats are moved into one zip per project folder: portable\archive\<folder>.zip. Entries are
# relative to the project folder (<session>.jsonl and <session>\...), so restoring puts them back.
function Get-ArchiveDir([string]$ClaudeDir) { return (Join-Path (Get-PortableDir $ClaudeDir) 'archive') }
function Get-ArchiveFile([string]$ClaudeDir, [string]$Folder) { return (Join-Path (Get-ArchiveDir $ClaudeDir) ($Folder + '.zip')) }

function Add-CompressionTypes { Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem }

# Number of archived chats in a project's archive.
function Get-ArchivedChatCount([string]$ClaudeDir, [string]$Folder) {
    $file = Get-ArchiveFile $ClaudeDir $Folder
    if (-not (Test-Path -LiteralPath $file)) { return 0 }
    Add-CompressionTypes
    $zip = [System.IO.Compression.ZipFile]::OpenRead($file)
    try { return @($zip.Entries | Where-Object { $_.FullName -notmatch '/' -and $_.FullName.EndsWith('.jsonl') }).Count } finally { $zip.Dispose() }
}

# Follows a project folder that was renamed (relink) or set aside (forget). Returns $true when moved.
function Move-ChatArchive([string]$ClaudeDir, [string]$OldFolder, [string]$NewFolder, [string]$Destination) {
    $old = Get-ArchiveFile $ClaudeDir $OldFolder
    if (-not (Test-Path -LiteralPath $old)) { return $false }
    $new = if ($Destination) { $Destination } else { Get-ArchiveFile $ClaudeDir $NewFolder }
    if ($old -ieq $new) { return $false }
    if (-not (Test-Path -LiteralPath $new)) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $new) -Force | Out-Null
        Move-Item -LiteralPath $old -Destination $new
        return $true
    }
    Add-CompressionTypes
    $from = [System.IO.Compression.ZipFile]::OpenRead($old)
    $to = [System.IO.Compression.ZipFile]::Open($new, [System.IO.Compression.ZipArchiveMode]::Update)
    try {
        $names = @{}
        foreach ($e in $to.Entries) { $names[$e.FullName] = $true }
        foreach ($e in $from.Entries) {
            if ($names.ContainsKey($e.FullName)) { continue }
            $copy = $to.CreateEntry($e.FullName, [System.IO.Compression.CompressionLevel]::Optimal)
            $copy.LastWriteTime = $e.LastWriteTime
            $in = $e.Open(); $out = $copy.Open()
            try { $in.CopyTo($out) } finally { $out.Dispose(); $in.Dispose() }
        }
    } finally { $to.Dispose(); $from.Dispose() }
    Remove-Item -LiteralPath $old -Force
    return $true
}

# ---------------------------------------------------------------- version

function Get-PortableVersion {
    $file = Join-Path (Split-Path -Parent $PSScriptRoot) 'VERSION'
    if (Test-Path -LiteralPath $file) { return ([System.IO.File]::ReadAllText($file)).Trim() }
    return 'unknown'
}

$script:RepoUrl = 'https://github.com/CataniaDaavide/claude-portable'
$script:RawVersionUrl = 'https://raw.githubusercontent.com/CataniaDaavide/claude-portable/main/scripts/VERSION'

# Latest version published on GitHub, or $null when offline / not reachable within a few seconds.
function Get-LatestVersion {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $text = (Invoke-WebRequest -Uri $script:RawVersionUrl -UseBasicParsing -TimeoutSec 5).Content
        if ($text -is [byte[]]) { $text = [System.Text.Encoding]::UTF8.GetString($text) }
        return ([string]$text).Trim()
    } catch { return $null }
}

function Compare-Version([string]$A, [string]$B) {
    $va = $null; $vb = $null
    if (-not [version]::TryParse($A, [ref]$va) -or -not [version]::TryParse($B, [ref]$vb)) { return 0 }
    return $va.CompareTo($vb)
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

# ---------------------------------------------------------------- compatibility

# claude-portable relies on Claude Code behaviour that is not a documented contract. These checks use
# the data already on disk to tell whether it still holds, so a Claude Code update that changes it
# shows up here instead of silently breaking relink. Returns objects with Level (ok|warn|info) and Text.
function Get-CompatibilityReport([string]$ClaudeDir, $Registry) {
    $report = @()
    $projectsDir = Join-Path $ClaudeDir 'projects'

    # 1. Project folders are named after the working directory (non-alphanumerics -> '-').
    $matched = 0
    $mismatched = @()
    foreach ($dir in (Get-ChildItem -LiteralPath $projectsDir -Directory -ErrorAction SilentlyContinue)) {
        $cwd = Get-CwdFromTranscripts $dir.FullName
        if (-not $cwd) { continue }
        $expected = Get-ProjectFolderName $cwd
        $same = if ($expected.Length -le 200) { $dir.Name -ieq $expected } else { $dir.Name.StartsWith($expected.Substring(0, 200), [StringComparison]::OrdinalIgnoreCase) }
        if ($same) { $matched++; continue }
        # A relinked folder still holds chats that recorded the old path.
        $relinked = $false
        foreach ($e in $Registry['workspaces'].Values) {
            if (([string]$e['folder']) -ieq $dir.Name -and (@($e['previousPaths']) -contains $cwd)) { $relinked = $true }
        }
        if (-not $relinked) { $mismatched += $dir.Name }
    }
    if ($matched -eq 0 -and $mismatched.Count -eq 0) {
        $report += [pscustomobject]@{ Level = 'info'; Text = 'Project folder names: nothing to check yet (no chats).' }
    } elseif ($mismatched.Count -eq 0) {
        $report += [pscustomobject]@{ Level = 'ok'; Text = "Project folder names follow the expected rule ($matched checked)." }
    } elseif ($matched -eq 0) {
        $report += [pscustomobject]@{ Level = 'warn'; Text = 'Project folder names do NOT follow the expected rule: Claude Code changed how it names them, relink will not work.' }
    } else {
        $report += [pscustomobject]@{ Level = 'warn'; Text = ('Some project folders do not match their chats'' path: ' + ($mismatched -join ', ')) }
    }

    # 2. With CLAUDE_CONFIG_DIR set, the global state file lives inside the data folder.
    if ($ClaudeDir.TrimEnd('\') -ine (Get-DefaultClaudeDir)) {
        $inside = Join-Path $ClaudeDir '.claude.json'
        $homeFile = Join-Path $env:USERPROFILE '.claude.json'
        $insideTime = if (Test-Path -LiteralPath $inside) { (Get-Item -LiteralPath $inside).LastWriteTime } else { [datetime]::MinValue }
        $homeTime = if (Test-Path -LiteralPath $homeFile) { (Get-Item -LiteralPath $homeFile).LastWriteTime } else { [datetime]::MinValue }
        if ($insideTime -eq [datetime]::MinValue -and $homeTime -eq [datetime]::MinValue) {
            $report += [pscustomobject]@{ Level = 'info'; Text = 'Global state file: not written yet.' }
        } elseif ($homeTime -gt $insideTime.AddMinutes(1)) {
            $report += [pscustomobject]@{ Level = 'warn'; Text = "Claude Code writes its state to $homeFile, not to the data folder: that file would not travel with it." }
        } else {
            $report += [pscustomobject]@{ Level = 'ok'; Text = 'Global state file is kept in the data folder.' }
        }
    }

    # 3. The SessionStart hook runs: the registry is refreshed whenever a session starts.
    $lastChat = Get-ChildItem -LiteralPath $projectsDir -Filter '*.jsonl' -File -Recurse -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    $lastUsed = [datetime]::MinValue
    foreach ($e in $Registry['workspaces'].Values) {
        $t = [datetime]::MinValue
        if ([datetime]::TryParse([string]$e['lastUsed'], [ref]$t) -and $t -gt $lastUsed) { $lastUsed = $t }
    }
    if (-not $lastChat) {
        $report += [pscustomobject]@{ Level = 'info'; Text = 'Hook: nothing to check yet (no chats).' }
    } elseif ($lastChat.LastWriteTime -gt $lastUsed.AddDays(3)) {
        $report += [pscustomobject]@{ Level = 'warn'; Text = 'The SessionStart hook does not seem to run: the registry is older than your latest chats.' }
    } else {
        $report += [pscustomobject]@{ Level = 'ok'; Text = 'The SessionStart hook runs.' }
    }
    return $report
}

# ---------------------------------------------------------------- settings

function Get-HookCommand {
    # Valid in Git Bash and in PowerShell alike: single quotes, no inner double quotes.
    # The script path is resolved from CLAUDE_CONFIG_DIR at run time, so the data folder stays portable.
    return "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command '& (Join-Path `$env:CLAUDE_CONFIG_DIR portable\scripts\register-workspace.ps1)'"
}

# A claude-portable hook from either version: Windows (this file) or macOS/Linux (unix\claude_portable.py).
# A data folder can move between systems, so the other system's hook is replaced, never kept.
function Test-PortableHookCommand([string]$Command) {
    return ($Command.Contains($script:HookMarker) -or $Command.Contains('claude_portable.py'))
}

# True only when this system's hook is installed.
function Test-HookInstalled($Settings) {
    $hooks = Get-DictValue $Settings 'hooks'
    $start = Get-DictValue $hooks 'SessionStart'
    if (-not $start) { return $false }
    foreach ($group in @($start)) {
        foreach ($h in @(Get-DictValue $group 'hooks')) {
            if ($h -and ([string](Get-DictValue $h 'command')) -eq (Get-HookCommand)) { return $true }
        }
    }
    return $false
}

function Add-SessionStartHook($Settings) {
    if (Test-HookInstalled $Settings) { return $false }
    [void](Remove-SessionStartHook $Settings)
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
        $inner = @(@(Get-DictValue $group 'hooks') | Where-Object { -not (Test-PortableHookCommand ([string](Get-DictValue $_ 'command'))) })
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

# Identical in unix\claude_portable.py, so the block does not change when a data folder moves
# between Windows and macOS/Linux.
function Get-ClaudeMdBlock {
    $lines = @(
        $script:ClaudeMdStart,
        '## Portable Claude data (claude-portable)',
        '',
        '- All Claude Code data (settings, transcripts, auto memory) lives in the folder named by the',
        '  `CLAUDE_CONFIG_DIR` environment variable, so it can be moved to another computer.',
        '- `portable/workspaces.json` in that folder is the registry of workspaces (project path ->',
        '  folder under `projects/`). A SessionStart hook keeps it up to date; do not edit it by hand.',
        '- When the user says a project now lives at a different path (moved folder, new computer):',
        '  1. Read the registry and find the workspace by name or old path.',
        '  2. Relink it: dry run first and show the plan, then run it with the force flag once the user agrees.',
        '     - Windows: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:CLAUDE_CONFIG_DIR\portable\scripts\relink-workspace.ps1" -Name <name> -NewPath "<new path>" -DryRun` (then `-Force`)',
        '     - macOS/Linux: `python3 "$CLAUDE_CONFIG_DIR/portable/unix/claude_portable.py" relink --name <name> --new-path "<new path>" --dry-run` (then `--force`)',
        '  3. If the workspace being relinked is the one of the current session, tell the user to',
        '     reopen Claude Code in the new path afterwards.',
        '- At session start the hook may add a "[claude-portable]" note saying this project looks like a',
        '  registered workspace that moved here. Tell the user right away and offer the relink above.',
        '  If the user says it is a different project, register it so it is not suggested again:',
        '     - Windows: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:CLAUDE_CONFIG_DIR\portable\scripts\register-workspace.ps1" -Path "<project path>"`',
        '     - macOS/Linux: `python3 "$CLAUDE_CONFIG_DIR/portable/unix/claude_portable.py" register --path "<project path>"`',
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
    # Set by the test suite, so the questions do not depend on what runs on the machine.
    if ($env:CLAUDE_PORTABLE_SKIP_PROCESS_CHECK -eq '1') { return $true }
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
    # The macOS/Linux version travels too, so the data folder works on either system.
    $unixSource = Join-Path (Split-Path -Parent $source) 'unix'
    $unixTarget = Join-Path (Get-PortableDir $ClaudeDir) 'unix'
    if ((Test-Path -LiteralPath $unixSource) -and ((ConvertTo-NormalizedPath $unixSource) -ine (ConvertTo-NormalizedPath $unixTarget))) {
        if (-not (Invoke-Robocopy $unixSource $unixTarget @('/PURGE', '/XD', '__pycache__'))) { throw "Could not copy the scripts to $unixTarget" }
    }
}

# Launcher and readme inside the data folder, so it can be used without the repository.
$script:LauncherName = 'claude-portable.bat'

function Install-DataFolderFiles([string]$ClaudeDir) {
    $scriptsDir = Split-Path -Parent $PSScriptRoot
    $templates = Join-Path $scriptsDir 'data-folder'
    # Both launchers: the folder may be opened on macOS/Linux too.
    foreach ($name in @($script:LauncherName, 'claude-portable.sh')) {
        $file = Join-Path $templates $name
        if (Test-Path -LiteralPath $file) { Copy-Item -LiteralPath $file -Destination (Join-Path $ClaudeDir $name) -Force }
    }
    Copy-Item -LiteralPath (Join-Path $templates 'README.md') -Destination (Join-Path (Get-PortableDir $ClaudeDir) 'README.md') -Force

    # Full guides go to portable\docs. Only when running from the repository: run from the data
    # folder, the parent of scripts\ is portable\ itself and the docs are already in place.
    $repoRoot = Split-Path -Parent $scriptsDir
    if ((Test-Path -LiteralPath (Join-Path $repoRoot 'start.bat')) -and (Test-Path -LiteralPath (Join-Path $repoRoot 'README.it.md'))) {
        $docs = Join-Path (Get-PortableDir $ClaudeDir) 'docs'
        New-Item -ItemType Directory -Path $docs -Force | Out-Null
        foreach ($name in @('README.md', 'README.it.md', 'CHANGELOG.md')) {
            $file = Join-Path $repoRoot $name
            # The guides point to docs/images/ in the repository; here the images sit next to them.
            if (Test-Path -LiteralPath $file) {
                Write-TextFile (Join-Path $docs $name) ([System.IO.File]::ReadAllText($file).Replace('docs/images/', 'images/'))
            }
        }
        $license = Join-Path $repoRoot 'LICENSE'
        if (Test-Path -LiteralPath $license) { Copy-Item -LiteralPath $license -Destination (Join-Path $docs 'LICENSE') -Force }
        $images = Join-Path $repoRoot 'docs\images'
        if (Test-Path -LiteralPath $images) {
            if (-not (Invoke-Robocopy $images (Join-Path $docs 'images') @('/PURGE'))) { throw 'Could not copy the images.' }
        }
    }
}
