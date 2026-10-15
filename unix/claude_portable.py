#!/usr/bin/env python3
"""claude-portable for macOS and Linux.

Same features and same data folder layout as the Windows scripts (scripts/*.ps1), so a data folder
can move between systems. Standard library only, Python 3.8 or later.

Usage: claude_portable.py [menu|install|status|relink|export|import|uninstall|forget|archive|restore|hook|register|get]
Run a command with --help for its options.
"""

import argparse
import datetime
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import urllib.request
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
PORTABLE_DIR = 'portable'
REGISTRY_FILE = 'workspaces.json'
MD_START = '<!-- claude-portable:start -->'
MD_END = '<!-- claude-portable:end -->'
ENV_START = '# >>> claude-portable >>>'
ENV_END = '# <<< claude-portable <<<'
REPO_URL = 'https://github.com/CataniaDaavide/claude-portable'
RAW_VERSION_URL = 'https://raw.githubusercontent.com/CataniaDaavide/claude-portable/main/scripts/VERSION'
GET_COMMAND = 'curl -fsSL https://raw.githubusercontent.com/CataniaDaavide/claude-portable/main/get.sh | sh'
HOOK_COMMAND = 'python3 "$CLAUDE_CONFIG_DIR/portable/unix/claude_portable.py" hook'
LAUNCH_AGENT = 'com.github.cataniadaavide.claude-portable'
IS_MAC = sys.platform == 'darwin'
EXPORT_EXCLUDE_DIRS = {'cache', 'ide', 'session-env', 'sessions', 'shell-snapshots', 'statsig',
                       'downloads', 'backups', 'relink-backups', 'forgotten', '__pycache__'}
EXPORT_EXCLUDE_FILES = {'.credentials.json', 'hook-errors.log', '.registry.lock'}


class Abort(Exception):
    """A handled stop: the message is shown and nothing else happens."""


# ------------------------------------------------------------------ output

def _color(code, text):
    return '\033[%sm%s\033[0m' % (code, text) if sys.stdout.isatty() else text


def step(text): print(_color('36', '==> ' + text))
def ok(text): print(_color('32', '    [ok] ' + text))
def warn(text): print(_color('33', '    [!] ' + text))
def info(text): print('    ' + text)
def title(text): print('\n' + _color('1', text))


def ask(question, default=''):
    try:
        answer = input(question)
    except EOFError:
        return default
    return answer.strip() or default


def confirm(question, default=False):
    answer = ask('%s %s ' % (question, '[Y/n]' if default else '[y/N]'))
    if not answer:
        return default
    return answer.lower().startswith('y')


# ------------------------------------------------------------------ paths

def home():
    return os.path.expanduser('~')


def default_claude_dir():
    return os.path.join(home(), '.claude')


def normalize(path):
    path = os.path.abspath(os.path.expanduser(path))
    return path.rstrip('/') or '/'


def same_path(a, b):
    a, b = normalize(a), normalize(b)
    return a.lower() == b.lower() if IS_MAC else a == b


def active_claude_dir():
    """The folder Claude Code uses: CLAUDE_CONFIG_DIR, else the value saved by install, else ~/.claude."""
    value = os.environ.get('CLAUDE_CONFIG_DIR') or saved_env_value()
    return normalize(value) if value else default_claude_dir()


def global_config_file(claude_dir):
    """~/.claude.json by default, <config dir>/.claude.json when CLAUDE_CONFIG_DIR is set."""
    if same_path(claude_dir, default_claude_dir()):
        return os.path.join(home(), '.claude.json')
    return os.path.join(claude_dir, '.claude.json')


def portable_dir(claude_dir):
    return os.path.join(claude_dir, PORTABLE_DIR)


def registry_file(claude_dir):
    return os.path.join(portable_dir(claude_dir), REGISTRY_FILE)


def folder_name(path):
    """Same rule Claude Code uses: every non-alphanumeric character becomes '-'."""
    return re.sub(r'[^A-Za-z0-9]', '-', path.rstrip('/') or '/')


def find_project_folder(claude_dir, path):
    """Existing folder under projects/ for path. Names over 200 characters get a hash suffix from
    Claude Code that cannot be reproduced, so those are found by prefix."""
    projects = os.path.join(claude_dir, 'projects')
    name = folder_name(path)
    if len(name) <= 200:
        return name if os.path.isdir(os.path.join(projects, name)) else None
    if os.path.isdir(projects):
        for entry in sorted(os.listdir(projects)):
            if entry.startswith(name[:200]):
                return entry
    return None


# ------------------------------------------------------------------ files

def read_text(path):
    with open(path, encoding='utf-8') as f:
        return f.read()


def read_json(path):
    try:
        with open(path, encoding='utf-8') as f:
            text = f.read()
    except FileNotFoundError:
        return None
    return json.loads(text) if text.strip() else None


def write_text(path, text):
    os.makedirs(os.path.dirname(path) or '.', exist_ok=True)
    tmp = '%s.tmp-%d' % (path, os.getpid())
    with open(tmp, 'w', encoding='utf-8', newline='\n') as f:
        f.write(text)
    os.replace(tmp, path)


def write_json(path, value):
    write_text(path, json.dumps(value, indent=2, ensure_ascii=False) + '\n')


def copy_tree(src, dst, exclude_dirs=(), exclude_files=(), overwrite=True):
    """Copies src into dst. With overwrite=False, files that already exist in dst are kept."""
    for root, dirs, files in os.walk(src):
        dirs[:] = [d for d in dirs if d not in exclude_dirs]
        target = os.path.join(dst, os.path.relpath(root, src))
        os.makedirs(target, exist_ok=True)
        for name in files:
            if name in exclude_files:
                continue
            dest = os.path.join(target, name)
            if not overwrite and os.path.exists(dest):
                continue
            shutil.copy2(os.path.join(root, name), dest)


def mirror_tree(src, dst):
    """dst becomes an exact copy of src (used for the scripts)."""
    if os.path.isdir(dst):
        shutil.rmtree(dst)
    shutil.copytree(src, dst, ignore=shutil.ignore_patterns('__pycache__'))


def now():
    return datetime.datetime.now().strftime('%Y-%m-%dT%H:%M:%S')


def stamp():
    return datetime.datetime.now().strftime('%Y%m%d-%H%M%S')


# ------------------------------------------------------------------ registry

def read_registry(claude_dir):
    reg = read_json(registry_file(claude_dir)) or {}
    reg.setdefault('version', 1)
    if not isinstance(reg.get('workspaces'), dict):
        reg['workspaces'] = {}
    return reg


def save_registry(claude_dir, reg):
    write_json(registry_file(claude_dir), reg)


def find_by_path(reg, path):
    for name, entry in reg['workspaces'].items():
        if same_path(str(entry.get('path', '')), path):
            return name
    return None


def unique_name(reg, path):
    base = re.sub(r'[^A-Za-z0-9._-]', '-', os.path.basename(path.rstrip('/'))) or folder_name(path)
    name, i = base, 2
    while name in reg['workspaces']:
        name, i = '%s-%d' % (base, i), i + 1
    return name


def register(claude_dir, reg, path, folder=None):
    """Adds or refreshes the entry for path. Returns the workspace name."""
    path = normalize(path)
    folder = folder or find_project_folder(claude_dir, path) or folder_name(path)
    name = find_by_path(reg, path)
    computer = os.uname().nodename
    if name:
        reg['workspaces'][name].update(folder=folder, computer=computer, lastUsed=now())
    else:
        name = unique_name(reg, path)
        reg['workspaces'][name] = {'path': path, 'folder': folder, 'computer': computer,
                                   'firstSeen': now(), 'lastUsed': now(), 'previousPaths': []}
    return name


def find_moved(reg, path):
    """Registered workspaces whose path is gone and whose folder name matches path's: most likely the
    same project, moved to path. Paths from another system (C:\\...) are compared the same way."""
    leaf = os.path.basename(path.rstrip('/')).lower()
    found = []
    for name, entry in reg['workspaces'].items():
        old = str(entry.get('path', ''))
        if same_path(old, path):
            continue
        if re.split(r'[\\/]', old.rstrip('\\/'))[-1].lower() != leaf:
            continue
        if os.path.exists(old):
            continue
        found.append(name)
    return found


def cwd_from_transcripts(folder):
    """The working directory recorded in a project's newest transcript."""
    try:
        files = [os.path.join(folder, f) for f in os.listdir(folder) if f.endswith('.jsonl')]
    except OSError:
        return None
    for path in sorted(files, key=os.path.getmtime, reverse=True):
        try:
            with open(path, encoding='utf-8', errors='replace') as f:
                for i, line in enumerate(f):
                    if i >= 200:
                        break
                    if '"cwd"' not in line:
                        continue
                    try:
                        cwd = json.loads(line).get('cwd')
                    except ValueError:
                        continue
                    if cwd:
                        return cwd
        except OSError:
            continue
    return None


def known_project_paths(claude_dir):
    try:
        projects = (read_json(global_config_file(claude_dir)) or {}).get('projects') or {}
    except (ValueError, OSError):
        return []
    return list(projects.keys())


def update_registry_from_disk(claude_dir, reg):
    """Registers every folder under projects/ that is not registered yet. Returns (added, unknown)."""
    projects = os.path.join(claude_dir, 'projects')
    registered = {str(e.get('folder', '')).lower() for e in reg['workspaces'].values()}
    known = known_project_paths(claude_dir)
    added, unknown = [], []
    for entry in sorted(os.listdir(projects)) if os.path.isdir(projects) else []:
        full = os.path.join(projects, entry)
        if not os.path.isdir(full) or entry.lower() in registered:
            continue
        path = cwd_from_transcripts(full)
        if not path:
            path = next((p for p in known if folder_name(p).lower() == entry.lower()), None)
        if path:
            added.append(register(claude_dir, reg, path, entry))
        else:
            unknown.append(entry)
    return added, unknown


# ------------------------------------------------------------------ project state in .claude.json

def _is_windows_path(path):
    return bool(re.match(r'^[A-Za-z]:[\\/]', path))


def copy_project_state(claude_dir, old_path, new_path, dry_run=False):
    """Copies the per-project state Claude Code keeps in .claude.json (folder trust, allowed tools,
    project MCP servers...) from the old path to the new one, so a moved project is not treated as a
    new, untrusted folder. The old entry is kept. Returns a description, or None."""
    path = global_config_file(claude_dir)
    try:
        config = read_json(path) or {}
    except (ValueError, OSError):
        return None
    projects = config.get('projects')
    if not isinstance(projects, dict):
        return None
    old_key = old_path.replace('\\', '/')
    fold = _is_windows_path(old_path) or IS_MAC
    sources = [k for k in projects if (k.lower() == old_key.lower() if fold else k == old_key)]
    if not sources:
        return None
    source = max((projects[k] for k in sources), key=lambda v: len(v) if isinstance(v, dict) else 0)
    if not isinstance(source, dict):
        return None
    new_key = new_path.replace('\\', '/')
    targets = [new_key]
    if _is_windows_path(new_key):
        targets = [new_key[0].upper() + new_key[1:], new_key[0].lower() + new_key[1:]]
    if dry_run:
        return 'trust and permissions: copied to the new path'
    backups = os.path.join(portable_dir(claude_dir), 'relink-backups')
    os.makedirs(backups, exist_ok=True)
    shutil.copy2(path, os.path.join(backups, '.claude.json-' + stamp()))
    for key in targets:
        if key not in projects or not isinstance(projects[key], dict):
            projects[key] = json.loads(json.dumps(source))
            continue
        target = projects[key]
        for field, value in source.items():
            if field not in target:
                target[field] = json.loads(json.dumps(value))
            elif field == 'hasTrustDialogAccepted' and value is True:
                target[field] = True
            elif field == 'allowedTools' and isinstance(value, list) and isinstance(target[field], list):
                target[field] = list(dict.fromkeys(target[field] + value))
    write_json(path, config)
    return 'trust and permissions copied to the new path'


# ------------------------------------------------------------------ archived chats
# Old chats go into one zip per project folder: portable/archive/<folder>.zip, with entries relative
# to the project folder (<session>.jsonl and <session>/...), so restoring puts them back.

def archive_dir(claude_dir):
    return os.path.join(portable_dir(claude_dir), 'archive')


def archive_file(claude_dir, folder):
    return os.path.join(archive_dir(claude_dir), folder + '.zip')


def archived_chat_count(claude_dir, folder):
    path = archive_file(claude_dir, folder)
    if not folder or not os.path.exists(path):
        return 0
    with zipfile.ZipFile(path) as z:
        return len([n for n in z.namelist() if '/' not in n and n.endswith('.jsonl')])


def move_chat_archive(claude_dir, old_folder, new_folder=None, destination=None):
    """Follows a project folder that was renamed (relink) or set aside (forget)."""
    old = archive_file(claude_dir, old_folder)
    if not os.path.exists(old):
        return False
    new = destination or archive_file(claude_dir, new_folder)
    if same_path(old, new):
        return False
    os.makedirs(os.path.dirname(new), exist_ok=True)
    if not os.path.exists(new):
        shutil.move(old, new)
        return True
    with zipfile.ZipFile(old) as src, zipfile.ZipFile(new, 'a', zipfile.ZIP_DEFLATED) as dst:
        existing = set(dst.namelist())
        for entry in src.infolist():
            if entry.filename not in existing:
                dst.writestr(entry, src.read(entry.filename))
    os.remove(old)
    return True


# ------------------------------------------------------------------ settings, CLAUDE.md

def is_portable_hook(command):
    return 'claude_portable.py' in command or 'register-workspace.ps1' in command


def read_settings(claude_dir):
    return read_json(os.path.join(claude_dir, 'settings.json')) or {}


def save_settings(claude_dir, settings):
    path = os.path.join(claude_dir, 'settings.json')
    if os.path.exists(path):
        shutil.copy2(path, path + '.bak')
    write_json(path, settings)


def hook_installed(settings):
    for group in (settings.get('hooks') or {}).get('SessionStart') or []:
        for hook in group.get('hooks') or []:
            if hook.get('command') == HOOK_COMMAND:
                return True
    return False


def remove_hook(settings):
    hooks = settings.get('hooks') or {}
    removed, kept = False, []
    for group in hooks.get('SessionStart') or []:
        inner = [h for h in group.get('hooks') or [] if not is_portable_hook(str(h.get('command', '')))]
        removed = removed or len(inner) != len(group.get('hooks') or [])
        if inner:
            group['hooks'] = inner
            kept.append(group)
    if 'SessionStart' in hooks:
        if kept:
            hooks['SessionStart'] = kept
        else:
            del hooks['SessionStart']
    if 'hooks' in settings and not hooks:
        del settings['hooks']
    return removed


def add_hook(settings):
    """Installs this system's hook; a hook from the other system's version is replaced."""
    if hook_installed(settings):
        return False
    remove_hook(settings)
    hooks = settings.setdefault('hooks', {})
    hooks.setdefault('SessionStart', []).append(
        {'matcher': 'startup|resume', 'hooks': [{'type': 'command', 'command': HOOK_COMMAND, 'timeout': 30}]})
    return True


def claude_md_block():
    return '\n'.join([
        MD_START,
        '## Portable Claude data (claude-portable)',
        '',
        '- All Claude Code data (settings, transcripts, auto memory) lives in the folder named by the',
        '  `CLAUDE_CONFIG_DIR` environment variable, so it can be moved to another computer.',
        '- `portable/workspaces.json` in that folder is the registry of workspaces (project path ->',
        '  folder under `projects/`). A SessionStart hook keeps it up to date; do not edit it by hand.',
        '- When the user says a project now lives at a different path (moved folder, new computer):',
        '  1. Read the registry and find the workspace by name or old path.',
        '  2. Relink it: dry run first and show the plan, then run it with the force flag once the user agrees.',
        '     - Windows: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:CLAUDE_CONFIG_DIR\\portable\\scripts\\relink-workspace.ps1" -Name <name> -NewPath "<new path>" -DryRun` (then `-Force`)',
        '     - macOS/Linux: `python3 "$CLAUDE_CONFIG_DIR/portable/unix/claude_portable.py" relink --name <name> --new-path "<new path>" --dry-run` (then `--force`)',
        '  3. If the workspace being relinked is the one of the current session, tell the user to',
        '     reopen Claude Code in the new path afterwards.',
        '- At session start the hook may add a "[claude-portable]" note saying this project looks like a',
        '  registered workspace that moved here. Tell the user right away and offer the relink above.',
        '  If the user says it is a different project, register it so it is not suggested again:',
        '     - Windows: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:CLAUDE_CONFIG_DIR\\portable\\scripts\\register-workspace.ps1" -Path "<project path>"`',
        '     - macOS/Linux: `python3 "$CLAUDE_CONFIG_DIR/portable/unix/claude_portable.py" register --path "<project path>"`',
        '- Never copy or upload `.credentials.json`; on a new computer the user logs in again.',
        MD_END,
    ])


def _md_pattern():
    return re.compile(r'\n?' + re.escape(MD_START) + r'[\s\S]*?' + re.escape(MD_END) + r'\n?')


def set_claude_md_block(claude_dir):
    path = os.path.join(claude_dir, 'CLAUDE.md')
    text = read_text(path) if os.path.exists(path) else ''
    block = claude_md_block()
    pattern = re.compile(re.escape(MD_START) + r'[\s\S]*?' + re.escape(MD_END))
    if pattern.search(text):
        text = pattern.sub(lambda m: block, text)
    else:
        if text and not text.endswith('\n'):
            text += '\n'
        text += ('\n' if text else '') + block + '\n'
    write_text(path, text)


def remove_claude_md_block(claude_dir):
    path = os.path.join(claude_dir, 'CLAUDE.md')
    if not os.path.exists(path):
        return
    text = _md_pattern().sub('', read_text(path))
    if text.strip():
        write_text(path, text)
    else:
        os.remove(path)


# ------------------------------------------------------------------ environment variable

def rc_files(create=False):
    """Shell startup files that get the export line. macOS uses zsh by default, Linux bash."""
    candidates = [os.path.join(home(), f) for f in ('.zshrc', '.bashrc', '.profile')]
    found = [f for f in candidates if os.path.exists(f)]
    if create:
        preferred = os.path.join(home(), '.zshrc' if IS_MAC else '.profile')
        if preferred not in found:
            found.append(preferred)
    return found


def _strip_env_block(text):
    return re.sub(r'\n?' + re.escape(ENV_START) + r'[\s\S]*?' + re.escape(ENV_END) + r'\n?', '\n', text).strip('\n')


def saved_env_value():
    for path in rc_files():
        try:
            m = re.search(re.escape(ENV_START) + r'\s*export CLAUDE_CONFIG_DIR=(.*)\n', read_text(path))
        except OSError:
            continue
        if m:
            parts = shlex.split(m.group(1))
            if parts:
                return parts[0]
    return None


def set_env(value):
    """Saves CLAUDE_CONFIG_DIR for terminals, desktop sessions and GUI apps (VS Code), or removes it
    when value is None. Programs read it when they start, so they need a restart."""
    done = []
    for path in rc_files(create=value is not None):
        text = read_text(path) if os.path.exists(path) else ''
        text = _strip_env_block(text)
        if value is not None:
            text += ('\n\n' if text else '') + '%s\nexport CLAUDE_CONFIG_DIR=%s\n%s' % (ENV_START, shlex.quote(value), ENV_END)
        write_text(path, text + '\n' if text else '')
        done.append(path)
    if IS_MAC:
        # Apps started from the Dock or Finder do not read shell files: launchctl sets the variable for
        # this login session, the LaunchAgent sets it again at every login.
        agent = os.path.join(home(), 'Library', 'LaunchAgents', LAUNCH_AGENT + '.plist')
        if value is None:
            subprocess.call(['launchctl', 'unsetenv', 'CLAUDE_CONFIG_DIR'])
            if os.path.exists(agent):
                os.remove(agent)
        else:
            subprocess.call(['launchctl', 'setenv', 'CLAUDE_CONFIG_DIR', value])
            write_text(agent, LAUNCH_AGENT_PLIST % {'label': LAUNCH_AGENT, 'value': _xml(value)})
            done.append(agent)
    else:
        # Desktop sessions started by systemd read environment.d at login.
        conf = os.path.join(home(), '.config', 'environment.d', 'claude-portable.conf')
        if value is None:
            if os.path.exists(conf):
                os.remove(conf)
        else:
            write_text(conf, 'CLAUDE_CONFIG_DIR=%s\n' % value)
            done.append(conf)
    return done


def _xml(text):
    return text.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')


LAUNCH_AGENT_PLIST = '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>%(label)s</string>
  <key>ProgramArguments</key>
  <array><string>/bin/launchctl</string><string>setenv</string><string>CLAUDE_CONFIG_DIR</string><string>%(value)s</string></array>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
'''


# ------------------------------------------------------------------ misc

def portable_version():
    try:
        return read_text(os.path.join(os.path.dirname(HERE), 'scripts', 'VERSION')).strip()
    except OSError:
        return 'unknown'


def latest_version():
    try:
        with urllib.request.urlopen(RAW_VERSION_URL, timeout=5) as r:
            return r.read().decode('utf-8').strip()
    except Exception:
        return None


def version_tuple(text):
    try:
        return tuple(int(x) for x in text.split('.'))
    except (ValueError, AttributeError):
        return None


def claude_running():
    try:
        out = subprocess.run(['ps', '-A', '-o', 'comm='], capture_output=True, text=True).stdout
    except OSError:
        return []
    names = {os.path.basename(line.strip()) for line in out.splitlines()}
    return sorted(n for n in names if n in ('claude', 'Claude', 'code', 'Code', 'Electron'))


def assert_claude_closed(force):
    # Set by the test suite, so the questions do not depend on what runs on the machine.
    if os.environ.get('CLAUDE_PORTABLE_SKIP_PROCESS_CHECK') == '1':
        return
    running = claude_running()
    if not running:
        return
    warn('Claude Code or VS Code is running: ' + ', '.join(running))
    info('Close every Claude Code terminal, the Claude desktop app and VS Code, so no file is being written.')
    if force:
        warn('Continuing anyway (--force).')
    elif not confirm('Continue anyway?'):
        raise Abort('Nothing changed.')


def repo_root():
    """The repository folder when running from it, else None (running from a data folder)."""
    root = os.path.dirname(HERE)
    if os.path.exists(os.path.join(root, 'start.bat')) and os.path.exists(os.path.join(root, 'README.it.md')):
        return root
    return None


def install_portable_files(claude_dir):
    """Scripts for both systems, launchers, readme and full guides into the data folder."""
    source_root = os.path.dirname(HERE)
    target = portable_dir(claude_dir)
    os.makedirs(target, exist_ok=True)
    for name in ('scripts', 'unix'):
        src = os.path.join(source_root, name)
        dst = os.path.join(target, name)
        if os.path.isdir(src) and not same_path(src, dst):
            mirror_tree(src, dst)
    templates = os.path.join(target, 'scripts', 'data-folder')
    for name in ('claude-portable.bat', 'claude-portable.sh'):
        src = os.path.join(templates, name)
        if os.path.exists(src):
            shutil.copy2(src, os.path.join(claude_dir, name))
    sh = os.path.join(claude_dir, 'claude-portable.sh')
    if os.path.exists(sh):
        os.chmod(sh, 0o755)
    if os.path.exists(os.path.join(templates, 'README.md')):
        shutil.copy2(os.path.join(templates, 'README.md'), os.path.join(target, 'README.md'))
    root = repo_root()
    if root:
        docs = os.path.join(target, 'docs')
        os.makedirs(docs, exist_ok=True)
        for name in ('README.md', 'README.it.md', 'CHANGELOG.md'):
            src = os.path.join(root, name)
            if os.path.exists(src):
                # The guides point to docs/images/ in the repository; here the images sit next to them.
                text = read_text(src).replace('docs/images/', 'images/')
                write_text(os.path.join(docs, name), text)
        if os.path.exists(os.path.join(root, 'LICENSE')):
            shutil.copy2(os.path.join(root, 'LICENSE'), os.path.join(docs, 'LICENSE'))
        images = os.path.join(root, 'docs', 'images')
        if os.path.isdir(images):
            mirror_tree(images, os.path.join(docs, 'images'))


# ------------------------------------------------------------------ compatibility

def compatibility_report(claude_dir, reg):
    """Checks, on the data already on disk, the Claude Code behaviour claude-portable relies on.
    Returns a list of (level, text) with level ok|warn|info."""
    report = []
    projects = os.path.join(claude_dir, 'projects')
    matched, mismatched = 0, []
    for entry in sorted(os.listdir(projects)) if os.path.isdir(projects) else []:
        full = os.path.join(projects, entry)
        cwd = cwd_from_transcripts(full) if os.path.isdir(full) else None
        if not cwd:
            continue
        expected = folder_name(cwd)
        same = entry.lower() == expected.lower() if len(expected) <= 200 else entry.startswith(expected[:200])
        if same:
            matched += 1
            continue
        relinked = any(str(e.get('folder', '')).lower() == entry.lower() and cwd in (e.get('previousPaths') or [])
                       for e in reg['workspaces'].values())
        if not relinked:
            mismatched.append(entry)
    if not matched and not mismatched:
        report.append(('info', 'Project folder names: nothing to check yet (no chats).'))
    elif not mismatched:
        report.append(('ok', 'Project folder names follow the expected rule (%d checked).' % matched))
    elif not matched:
        report.append(('warn', 'Project folder names do NOT follow the expected rule: Claude Code changed how it names them, relink will not work.'))
    else:
        report.append(('warn', "Some project folders do not match their chats' path: " + ', '.join(mismatched)))

    if not same_path(claude_dir, default_claude_dir()):
        inside = os.path.join(claude_dir, '.claude.json')
        home_file = os.path.join(home(), '.claude.json')
        t_inside = os.path.getmtime(inside) if os.path.exists(inside) else 0
        t_home = os.path.getmtime(home_file) if os.path.exists(home_file) else 0
        if not t_inside and not t_home:
            report.append(('info', 'Global state file: not written yet.'))
        elif t_home > t_inside + 60:
            report.append(('warn', 'Claude Code writes its state to %s, not to the data folder: that file would not travel with it.' % home_file))
        else:
            report.append(('ok', 'Global state file is kept in the data folder.'))

    last_chat = 0
    for root, _, files in os.walk(projects):
        for name in files:
            if name.endswith('.jsonl'):
                last_chat = max(last_chat, os.path.getmtime(os.path.join(root, name)))
    last_used = 0
    for e in reg['workspaces'].values():
        try:
            last_used = max(last_used, datetime.datetime.strptime(e.get('lastUsed', ''), '%Y-%m-%dT%H:%M:%S').timestamp())
        except ValueError:
            pass
    if not last_chat:
        report.append(('info', 'Hook: nothing to check yet (no chats).'))
    elif last_chat > last_used + 3 * 86400:
        report.append(('warn', 'The SessionStart hook does not seem to run: the registry is older than your latest chats.'))
    else:
        report.append(('ok', 'The SessionStart hook runs.'))
    return report


# ------------------------------------------------------------------ commands

def cmd_install(a):
    data = normalize(a.data_dir or os.path.join(home(), 'claude-data'))
    source = normalize(a.source or active_claude_dir())
    if not same_path(source, data) and os.path.exists(registry_file(data)):
        print()
        step('%s is already a claude-portable data folder (moved or copied here).' % data)
        info('Using it as it is instead of copying over it: switching to Import.')
        a.source_dir, a.data_dir = data, data
        return cmd_import(a)

    title('claude-portable %s - install' % portable_version())
    info('Current Claude data : ' + source)
    info('Portable folder     : ' + data)
    info('Chat retention      : %d days' % a.retention_days)
    print()
    fresh = a.fresh
    if same_path(source, data):
        step('The data is already in the portable folder: only settings, hook and registry will be updated.')
        fresh = True
    if not a.force and not confirm('Proceed?', True):
        raise Abort('Nothing changed.')

    if not fresh:
        assert_claude_closed(a.force)
        if not os.path.isdir(source):
            raise Abort('Claude data not found in %s. If you moved the data folder, choose Import and give its new path.' % source)
        if os.path.isdir(data) and os.listdir(data):
            warn('%s is not empty. Files with the same name will be overwritten.' % data)
            if not a.force and not confirm('Continue?'):
                raise Abort('Nothing changed.')
        step('Copying %s -> %s' % (source, data))
        copy_tree(source, data)
        g_src, g_dst = global_config_file(source), global_config_file(data)
        if os.path.exists(g_src) and not same_path(g_src, g_dst):
            shutil.copy2(g_src, g_dst)
            ok('Copied the global state file (.claude.json).')
        ok('Data copied. The original folder was not modified and stays as a backup.')
    else:
        os.makedirs(data, exist_ok=True)

    step('Copying the claude-portable scripts into the data folder')
    install_portable_files(data)
    ok(os.path.join(portable_dir(data), 'unix'))
    ok(os.path.join(data, 'claude-portable.sh') + ' (opens this menu from the data folder)')

    step('Updating settings.json')
    settings = read_settings(data)
    settings['cleanupPeriodDays'] = a.retention_days
    ok('cleanupPeriodDays = %d' % a.retention_days)
    ok('SessionStart hook installed.' if add_hook(settings) else 'SessionStart hook already present.')
    save_settings(data, settings)

    step('Adding the relink instructions to the user CLAUDE.md')
    set_claude_md_block(data)
    ok(os.path.join(data, 'CLAUDE.md'))

    step('Building the workspace registry')
    reg = read_registry(data)
    _, unknown = update_registry_from_disk(data, reg)
    save_registry(data, reg)
    for name in sorted(reg['workspaces']):
        ok('%-30s %s' % (name, reg['workspaces'][name]['path']))
    for folder in unknown:
        warn('No path found for projects/%s (no chat inside): it will be registered the next time you open it.' % folder)

    if a.skip_environment:
        warn('CLAUDE_CONFIG_DIR not set (--skip-environment).')
    else:
        step('Saving CLAUDE_CONFIG_DIR')
        for path in set_env(data):
            ok(path)
        os.environ['CLAUDE_CONFIG_DIR'] = data

    print()
    print(_color('32', 'Done.'))
    info('Next steps:')
    info('  1. Close VS Code, every terminal and the Claude app, then reopen them (on Linux desktops,')
    info('     log out and in again so apps started from the menu see CLAUDE_CONFIG_DIR).')
    if IS_MAC:
        info('  2. Log in again in Claude Code (/login): on macOS the login is kept per data folder.')
    info('  %d. Run "Status" from the menu to check everything.' % (3 if IS_MAC else 2))
    if not fresh:
        info('  When you are sure everything works, you can delete the old copy: ' + source)


def cmd_status(a):
    claude_dir = active_claude_dir()
    projects = os.path.join(claude_dir, 'projects')
    title('claude-portable - status')

    step('Version')
    current, latest = portable_version(), latest_version()
    if not latest:
        info('%s (could not check GitHub for updates)' % current)
    elif (version_tuple(latest) or ()) > (version_tuple(current) or ()):
        warn('%s installed, %s available. To update, run:' % (current, latest))
        info('  ' + GET_COMMAND)
    else:
        ok('%s (up to date)' % current)

    step('Data folder')
    saved = saved_env_value()
    if saved:
        ok('CLAUDE_CONFIG_DIR saved in your shell files = ' + saved)
    else:
        warn('CLAUDE_CONFIG_DIR is not saved: Claude Code uses the default ~/.claude')
    env = os.environ.get('CLAUDE_CONFIG_DIR')
    if saved and env and not same_path(env, saved):
        warn('This terminal still sees an old value (%s): open a new one.' % env)
    info('In use: ' + claude_dir)
    if not os.path.isdir(claude_dir):
        warn('The folder does not exist.')
        return 1
    size = sum(os.path.getsize(os.path.join(r, f)) for r, _, fs in os.walk(claude_dir) for f in fs
               if os.path.isfile(os.path.join(r, f)))
    info('Size  : %d MB' % (size // (1024 * 1024)))
    if os.path.exists(os.path.join(claude_dir, '.credentials.json')):
        ok('Logged in (.credentials.json present)')
    elif IS_MAC:
        info('Login: kept in the macOS Keychain (run /login if Claude Code asks).')
    else:
        warn('No .credentials.json: log in with /login')

    step('Settings')
    settings = read_settings(claude_dir)
    if settings.get('cleanupPeriodDays'):
        ok('cleanupPeriodDays = %s' % settings['cleanupPeriodDays'])
    else:
        warn('cleanupPeriodDays not set: chats older than 30 days are deleted')
    if hook_installed(settings):
        ok('SessionStart hook installed')
    else:
        warn('SessionStart hook missing (or the Windows one): run Install again')
    log = os.path.join(portable_dir(claude_dir), 'hook-errors.log')
    if os.path.exists(log):
        warn('The hook reported errors, see ' + log)

    step('Workspaces')
    reg = read_registry(claude_dir)
    missing = False
    if not reg['workspaces']:
        info('(none yet)')
    print('    %-26s %5s %8s %8s %6s  %-19s  %s' % ('Name', 'Chats', 'Memories', 'Archived', 'PathOk', 'LastUsed', 'Path'))
    for name in sorted(reg['workspaces'], key=str.lower):
        e = reg['workspaces'][name]
        folder = os.path.join(projects, str(e.get('folder', '')))
        chats = len([f for f in os.listdir(folder) if f.endswith('.jsonl')]) if os.path.isdir(folder) else 0
        mem = os.path.join(folder, 'memory')
        memories = len([f for f in os.listdir(mem) if f.endswith('.md') and f != 'MEMORY.md']) if os.path.isdir(mem) else 0
        path_ok = 'yes' if os.path.exists(str(e.get('path', ''))) else 'NO'
        missing = missing or path_ok == 'NO'
        archived = archived_chat_count(claude_dir, str(e.get('folder', '')))
        print('    %-26s %5d %8d %8d %6s  %-19s  %s' % (name, chats, memories, archived, path_ok, e.get('lastUsed', ''), e.get('path', '')))
    if missing:
        warn('Workspaces marked NO point to a path that does not exist here: use "Relink" if the project moved,')
        info('    or "Forget" if you deleted it.')

    step('Compatibility with this Claude Code version')
    problems = 0
    for level, text in compatibility_report(claude_dir, reg):
        if level == 'ok':
            ok(text)
        elif level == 'warn':
            warn(text)
            problems += 1
        else:
            info(text)
    if problems:
        info('If a check fails after a Claude Code update, please open an issue: %s/issues' % REPO_URL)

    registered = {str(e.get('folder', '')).lower() for e in reg['workspaces'].values()}
    orphans = [d for d in sorted(os.listdir(projects)) if os.path.isdir(os.path.join(projects, d))
               and d.lower() not in registered] if os.path.isdir(projects) else []
    if orphans:
        step('Folders not in the registry')
        for d in orphans:
            info('projects/' + d)
        info('They are added automatically the next time you open that project (or run Install again).')
    return 0


def _merge_folder(claude_dir, src, dst):
    """Merges src into dst without overwriting anything; MEMORY.md indexes are merged line by line."""
    src_mem, dst_mem = os.path.join(src, 'memory', 'MEMORY.md'), os.path.join(dst, 'memory', 'MEMORY.md')
    merged = None
    if os.path.exists(src_mem) and os.path.exists(dst_mem):
        existing = read_text(dst_mem).splitlines()
        extra = [l for l in read_text(src_mem).splitlines() if l.strip() and l not in existing]
        merged = '\n'.join(existing + extra) + '\n'
    copy_tree(src, dst, overwrite=False)
    if merged:
        write_text(dst_mem, merged)
    backups = os.path.join(portable_dir(claude_dir), 'relink-backups')
    os.makedirs(backups, exist_ok=True)
    backup = os.path.join(backups, os.path.basename(src) + '-' + stamp())
    shutil.move(src, backup)
    ok('Old folder kept as backup: ' + backup)


def cmd_relink(a):
    claude_dir = active_claude_dir()
    projects = os.path.join(claude_dir, 'projects')
    reg = read_registry(claude_dir)
    ws = reg['workspaces']
    name, old_path = a.name, a.old_path
    if not name and not old_path:
        raise Abort('Pass --name (from the registry) or --old-path.')
    if name and name not in ws:
        raise Abort("Workspace '%s' is not in the registry. Known names: %s" % (name, ', '.join(sorted(ws))))
    if not name:
        old_path = old_path if re.match(r'^[A-Za-z]:\\', old_path) else normalize(old_path)
        name = find_by_path(reg, old_path)
    if name:
        old_path = str(ws[name]['path'])
    new_path = normalize(a.new_path)
    if not os.path.exists(new_path):
        warn('The new path does not exist (yet): ' + new_path)
        if not a.force and not a.dry_run and not confirm('Relink anyway?'):
            raise Abort('Nothing changed.')

    # The workspace plus registered workspaces inside it. Old paths may come from Windows (C:\...).
    sep = '\\' if re.match(r'^[A-Za-z]:\\', old_path) else '/'
    plan = [{'name': name, 'old': old_path, 'new': new_path}]
    for other, entry in ws.items():
        p = str(entry.get('path', ''))
        if other != name and p.lower().startswith(old_path.lower() + sep):
            plan.append({'name': other, 'old': p, 'new': new_path + p[len(old_path):].replace('\\', '/')})

    title('claude-portable - relink')
    info('Claude data: ' + claude_dir)
    for item in plan:
        folder = str(ws[item['name']].get('folder', '')) if item['name'] else ''
        if not folder or not os.path.isdir(os.path.join(projects, folder)):
            folder = find_project_folder(claude_dir, item['old'])
        item['old_folder'], item['new_folder'] = folder, folder_name(item['new'])
        step(item['name'] or '(not registered)')
        info('path   : ' + item['old'])
        info('      -> ' + item['new'])
        if not folder:
            info('folder : nothing stored for the old path (only the registry is updated)')
        elif folder.lower() == item['new_folder'].lower():
            info('folder : %s (unchanged)' % folder)
        elif os.path.isdir(os.path.join(projects, item['new_folder'])):
            info('folder : ' + folder)
            info('      -> merge into existing ' + item['new_folder'])
        else:
            info('folder : ' + folder)
            info('      -> rename to ' + item['new_folder'])
        state = copy_project_state(claude_dir, item['old'], item['new'], dry_run=True)
        if state:
            info('state  : ' + state)
        if folder and os.path.exists(archive_file(claude_dir, folder)):
            info('archive: archived chats follow the folder')
    if a.dry_run:
        print()
        info('Dry run: nothing changed.')
        return 0
    if not a.force:
        print()
        info('Make sure no Claude Code session is open in these projects.')
        if not confirm('Apply?', True):
            raise Abort('Nothing changed.')

    for item in plan:
        if item['old_folder'] and item['old_folder'].lower() != item['new_folder'].lower():
            src = os.path.join(projects, item['old_folder'])
            dst = os.path.join(projects, item['new_folder'])
            if os.path.isdir(dst):
                _merge_folder(claude_dir, src, dst)
                ok('Merged %s into %s' % (item['old_folder'], item['new_folder']))
            else:
                os.rename(src, dst)
                ok('Renamed %s -> %s' % (item['old_folder'], item['new_folder']))
            if move_chat_archive(claude_dir, item['old_folder'], item['new_folder']):
                ok('Archived chats moved along.')
        # Folder trust and permissions. Claude Code may rewrite .claude.json while it runs, so this is
        # best done with Claude Code closed; the old entry is kept and a backup is made first.
        try:
            state = copy_project_state(claude_dir, item['old'], item['new'])
            if state:
                ok('State: ' + state)
        except (OSError, ValueError) as e:
            warn('Could not copy trust and permissions: %s' % e)
        if item['name']:
            entry = ws[item['name']]
            previous = list(entry.get('previousPaths') or [])
            if item['old'] != item['new'] and item['old'] not in previous:
                previous.append(item['old'])
            entry.update(previousPaths=previous, path=item['new'], folder=item['new_folder'],
                         computer=os.uname().nodename)
        else:
            register(claude_dir, reg, item['new'], item['new_folder'])
    save_registry(claude_dir, reg)
    print()
    print(_color('32', 'Done.'))
    info('Open Claude Code in %s and use /resume to find the old chats.' % new_path)
    info('If Claude Code was open during the relink and asks again to trust the folder, just accept.')
    return 0


def cmd_export(a):
    claude_dir = active_claude_dir()
    output = normalize(a.output or os.path.join(home(), 'claude-data-export-%s.zip' % stamp()[:13]))
    title('claude-portable - export')
    info('From: ' + claude_dir)
    info('To  : ' + output)
    if not os.path.exists(registry_file(claude_dir)):
        warn('No workspace registry here: run Install first, otherwise relinking on the other computer is manual.')
    if os.path.exists(output):
        if not a.force and not confirm('The file exists. Overwrite?'):
            raise Abort('Nothing changed.')
        os.remove(output)
    assert_claude_closed(a.force)
    step('Compressing')
    with zipfile.ZipFile(output, 'w', zipfile.ZIP_DEFLATED) as z:
        for root, dirs, files in os.walk(claude_dir):
            dirs[:] = [d for d in dirs if d not in EXPORT_EXCLUDE_DIRS]
            for name in files:
                if name in EXPORT_EXCLUDE_FILES or '.tmp-' in name or name.endswith('.heapsnapshot'):
                    continue
                full = os.path.join(root, name)
                z.write(full, os.path.relpath(full, claude_dir).replace(os.sep, '/'))
        g = global_config_file(claude_dir)
        if os.path.exists(g) and not os.path.dirname(g) == claude_dir:
            z.write(g, '.claude.json')
    os.chmod(output, 0o600)
    ok('%s (%d MB)' % (output, os.path.getsize(output) // (1024 * 1024)))
    print()
    info('On the other computer: copy the zip and choose "Import" (or run the one-line installer).')
    warn('The zip contains your chats: do not publish it or put it in a git repository.')
    return 0


def cmd_import(a):
    source = normalize(a.source_dir)
    data = normalize(a.data_dir or os.path.join(home(), 'claude-data'))
    title('claude-portable - import')
    info('From: ' + source)
    info('To  : ' + data)
    if not os.path.exists(source):
        raise Abort('Not found: ' + source)
    in_place = os.path.isdir(source) and same_path(source, data)
    if not in_place and os.path.isdir(data) and os.listdir(data):
        warn(data + ' is not empty.')
        if not a.force and not confirm('Merge into it (existing files are overwritten)?'):
            raise Abort('Nothing changed.')
    assert_claude_closed(a.force)

    if not in_place:
        step('Copying files')
        os.makedirs(data, exist_ok=True)
        if os.path.isfile(source):
            with zipfile.ZipFile(source) as z:
                for member in z.infolist():
                    target = os.path.normpath(os.path.join(data, member.filename.replace('\\', '/')))
                    if not (target + os.sep).startswith(data + os.sep):
                        raise Abort('Unsafe path in zip: ' + member.filename)
                    if member.filename.endswith(('/', '\\')):
                        os.makedirs(target, exist_ok=True)
                        continue
                    os.makedirs(os.path.dirname(target), exist_ok=True)
                    with z.open(member) as src, open(target, 'wb') as dst:
                        shutil.copyfileobj(src, dst)
        else:
            copy_tree(source, data, exclude_files={'.credentials.json'})
        ok('Files copied.')

    # A folder copied as is brings the login of the old computer with it.
    login_kept = False
    credentials = os.path.join(data, '.credentials.json')
    if in_place and os.path.exists(credentials):
        step('Login found')
        info('This folder contains the Claude login (.credentials.json) copied from the other computer.')
        info('Removing it is safer: you log in again with /login and the old copy is gone.')
        if a.force:
            login_kept = True
            warn('Login kept (--force: no questions).')
        elif confirm('Keep the copied login?'):
            login_kept = True
            ok('Login kept.')
        else:
            os.remove(credentials)
            ok('Login removed: log in again with /login.')

    install_portable_files(data)
    settings = read_settings(data)
    settings.setdefault('cleanupPeriodDays', 36500)
    add_hook(settings)
    save_settings(data, settings)
    set_claude_md_block(data)
    ok('Settings, hook and instructions checked.')

    if not a.skip_environment:
        for path in set_env(data):
            ok('CLAUDE_CONFIG_DIR saved in ' + path)
    os.environ['CLAUDE_CONFIG_DIR'] = data

    reg = read_registry(data)
    names = sorted(reg['workspaces'], key=str.lower)
    step('Workspaces to reconnect: %d' % len(names))
    for name in names:
        # Read again: relinking a workspace also moves the ones registered inside it.
        reg = read_registry(data)
        if name not in reg['workspaces']:
            continue
        old = str(reg['workspaces'][name]['path'])
        print('\n  ' + name)
        info('  was in: ' + old)
        if os.path.exists(old):
            ok('  same path exists on this computer: nothing to do')
            continue
        if a.force:
            info('  skipped (--force: no questions)')
            continue
        new = ask('  New path of the project (Enter = skip, you can relink it later): ').strip('"\' ')
        if new:
            try:
                cmd_relink(argparse.Namespace(name=name, old_path=None, new_path=new, dry_run=False, force=True))
            except Abort as e:
                warn(str(e))

    print()
    print(_color('32', 'Done.'))
    info('Next steps:')
    info('  1. Close and reopen VS Code / terminals so they read CLAUDE_CONFIG_DIR.')
    info('  2. You are still logged in with the copied login.' if login_kept
         else '  2. Log in again in Claude Code (/login): the login is never exported.')
    info('  3. Skipped workspaces: use "Relink" from the menu whenever you know their new path.')
    return 0


def cmd_uninstall(a):
    claude_dir = active_claude_dir()
    default = default_claude_dir()
    title('claude-portable - uninstall')
    if same_path(claude_dir, default):
        warn('Claude Code already uses ~/.claude: nothing to undo.')
        return 0
    info('Portable folder: %s (it will not be deleted)' % claude_dir)
    info('Back to        : ' + default)
    if a.copy_back:
        info('Data is copied back first (--copy-back).')
    if not a.force and not confirm('Proceed?'):
        raise Abort('Nothing changed.')
    assert_claude_closed(a.force)
    settings = read_settings(claude_dir)
    if remove_hook(settings):
        save_settings(claude_dir, settings)
        ok('Hook removed.')
    remove_claude_md_block(claude_dir)
    ok('CLAUDE.md block removed.')
    if a.copy_back:
        step('Copying %s -> %s' % (claude_dir, default))
        copy_tree(claude_dir, default, exclude_dirs={PORTABLE_DIR}, exclude_files={'claude-portable.bat', 'claude-portable.sh'})
        g = os.path.join(claude_dir, '.claude.json')
        if os.path.exists(g):
            shutil.copy2(g, os.path.join(home(), '.claude.json'))
        ok('Copied.')
    if not a.skip_environment:
        set_env(None)
        ok('CLAUDE_CONFIG_DIR removed from your shell files.')
    info('Open a new terminal and restart VS Code to apply.')
    return 0


def cmd_archive(a):
    claude_dir = active_claude_dir()
    projects = os.path.join(claude_dir, 'projects')
    cutoff = datetime.datetime.now() - datetime.timedelta(days=a.older_than_days)
    title('claude-portable - archive old chats')
    info('Claude data: ' + claude_dir)
    info('Chats not changed since %s (%d days)' % (cutoff.strftime('%Y-%m-%d'), a.older_than_days))
    reg = read_registry(claude_dir)
    names = {str(e.get('folder', '')).lower(): n for n, e in reg['workspaces'].items()}
    plan = []
    for folder in sorted(os.listdir(projects)) if os.path.isdir(projects) else []:
        full = os.path.join(projects, folder)
        if not os.path.isdir(full):
            continue
        chats = [f for f in sorted(os.listdir(full)) if f.endswith('.jsonl')
                 and os.path.getmtime(os.path.join(full, f)) < cutoff.timestamp()]
        if not chats:
            continue
        size = 0
        for c in chats:
            size += os.path.getsize(os.path.join(full, c))
            for root, _, files in os.walk(os.path.join(full, c[:-6])):
                size += sum(os.path.getsize(os.path.join(root, f)) for f in files)
        plan.append((names.get(folder.lower(), folder), folder, chats, size))
    if not plan:
        print()
        ok('No chat is that old: nothing to archive.')
        return 0
    print()
    for name, _, chats, size in plan:
        info('%-30s %4d chats  %8.1f MB' % (name, len(chats), size / 1048576.0))
    info('Total: %.1f MB, compressed to roughly a tenth.' % (sum(p[3] for p in plan) / 1048576.0))
    if a.dry_run:
        print()
        info('Dry run: nothing changed.')
        return 0
    if not a.force and not confirm('Archive them?', True):
        raise Abort('Nothing changed.')
    os.makedirs(archive_dir(claude_dir), exist_ok=True)
    for name, folder, chats, _ in plan:
        full = os.path.join(projects, folder)
        zpath = archive_file(claude_dir, folder)
        entries = {}
        for c in chats:
            entries[c] = os.path.join(full, c)
            for root, _, files in os.walk(os.path.join(full, c[:-6])):
                for f in files:
                    path = os.path.join(root, f)
                    entries[os.path.relpath(path, full).replace(os.sep, '/')] = path
        # Rewrite the archive with the new entries replacing older copies of the same name.
        tmp = zpath + '.tmp'
        with zipfile.ZipFile(tmp, 'w', zipfile.ZIP_DEFLATED) as out:
            if os.path.exists(zpath):
                with zipfile.ZipFile(zpath) as old:
                    for entry in old.infolist():
                        if entry.filename not in entries:
                            out.writestr(entry, old.read(entry.filename))
            for entry_name, path in entries.items():
                out.write(path, entry_name)  # keeps the file date, so /resume keeps the order
        with zipfile.ZipFile(tmp) as check:
            if check.testzip() is not None or not set(entries) <= set(check.namelist()):
                os.remove(tmp)
                raise Abort('Archive check failed for %s: originals kept.' % name)
        os.replace(tmp, zpath)
        # Remove the originals only once the archive is written and checked.
        for c in chats:
            os.remove(os.path.join(full, c))
            if os.path.isdir(os.path.join(full, c[:-6])):
                shutil.rmtree(os.path.join(full, c[:-6]))
        ok('%s: %d chats archived (%.1f MB on disk)' % (name, len(chats), os.path.getsize(zpath) / 1048576.0))
    print()
    print(_color('32', 'Done.'))
    info('Restore them any time with "Restore archived chats" in the menu.')
    return 0


def cmd_restore(a):
    claude_dir = active_claude_dir()
    projects = os.path.join(claude_dir, 'projects')
    reg = read_registry(claude_dir)
    if not a.name and not a.all:
        raise Abort('Pass --name <workspace> or --all.')
    if a.all:
        adir = archive_dir(claude_dir)
        zips = sorted(os.path.join(adir, f) for f in os.listdir(adir) if f.endswith('.zip')) if os.path.isdir(adir) else []
    else:
        if a.name not in reg['workspaces']:
            raise Abort("Workspace '%s' is not in the registry." % a.name)
        path = archive_file(claude_dir, str(reg['workspaces'][a.name].get('folder', '')))
        zips = [path] if os.path.exists(path) else []
    title('claude-portable - restore archived chats')
    if not zips:
        ok('No archived chats to restore.')
        return 0
    for z in zips:
        folder = os.path.basename(z)[:-4]
        info('%s (%d chats)' % (folder, archived_chat_count(claude_dir, folder)))
    if not a.force and not confirm('Restore them?', True):
        raise Abort('Nothing changed.')
    for z in zips:
        folder = os.path.basename(z)[:-4]
        target = os.path.join(projects, folder)
        os.makedirs(target, exist_ok=True)
        restored = 0
        with zipfile.ZipFile(z) as archive:
            for entry in archive.infolist():
                if entry.is_dir():
                    continue
                path = os.path.normpath(os.path.join(target, entry.filename))
                if not path.startswith(target + os.sep):
                    raise Abort('Unsafe path in archive: ' + entry.filename)
                if os.path.exists(path):
                    continue
                os.makedirs(os.path.dirname(path), exist_ok=True)
                with archive.open(entry) as src, open(path, 'wb') as dst:
                    shutil.copyfileobj(src, dst)
                when = datetime.datetime(*entry.date_time).timestamp()
                os.utime(path, (when, when))
                if '/' not in entry.filename and entry.filename.endswith('.jsonl'):
                    restored += 1
        os.remove(z)
        ok('%s: %d chats restored' % (folder, restored))
    print()
    print(_color('32', 'Done.'))
    return 0


def cmd_forget(a):
    claude_dir = active_claude_dir()
    reg = read_registry(claude_dir)
    if a.name not in reg['workspaces']:
        raise Abort("Workspace '%s' is not in the registry. Known names: %s" % (a.name, ', '.join(sorted(reg['workspaces']))))
    entry = reg['workspaces'][a.name]
    title('claude-portable - forget')
    info('Workspace : ' + a.name)
    info('Path      : ' + str(entry.get('path')))
    info('Its chats and memory move to %s (nothing is deleted).' % os.path.join(portable_dir(claude_dir), 'forgotten'))
    if os.path.exists(str(entry.get('path'))):
        warn('This path still exists on this computer.')
    if not a.force and not confirm('Forget it?'):
        raise Abort('Nothing changed.')
    folder = str(entry.get('folder', ''))
    src = os.path.join(claude_dir, 'projects', folder)
    del reg['workspaces'][a.name]
    if folder and os.path.isdir(src):
        target = os.path.join(portable_dir(claude_dir), 'forgotten')
        os.makedirs(target, exist_ok=True)
        moved = os.path.join(target, folder + '-' + stamp())
        shutil.move(src, moved)
        ok('Chats and memory kept in ' + moved)
    zip_target = os.path.join(portable_dir(claude_dir), 'forgotten', '%s-archive-%s.zip' % (folder, stamp()))
    if folder and move_chat_archive(claude_dir, folder, destination=zip_target):
        ok('Archived chats kept in ' + zip_target)
    save_registry(claude_dir, reg)
    ok("Removed '%s' from the registry." % a.name)
    return 0


def _with_registry_lock(claude_dir, action):
    import fcntl
    os.makedirs(portable_dir(claude_dir), exist_ok=True)
    with open(os.path.join(portable_dir(claude_dir), '.registry.lock'), 'w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            return action()
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)


def cmd_hook(a, manual_path=None):
    """SessionStart hook (no path) or manual registration (path). In hook mode it never fails the
    session and prints only the moved-project note, which Claude Code adds to the context."""
    claude_dir = os.environ.get('CLAUDE_CONFIG_DIR')
    if not claude_dir:
        if manual_path:
            print('CLAUDE_CONFIG_DIR is not set: run Install first.')
        return 0
    claude_dir = normalize(claude_dir)
    try:
        project = normalize(manual_path or os.environ.get('CLAUDE_PROJECT_DIR') or os.getcwd())

        def work():
            reg = read_registry(claude_dir)
            moved = [] if manual_path or find_by_path(reg, project) else find_moved(reg, project)
            if moved:
                lines = ['[claude-portable] This project (%s) is not in the workspace registry, but it looks '
                         'like a registered workspace that was moved here:' % project]
                for name in moved:
                    lines.append("- '%s', last seen at %s (that path no longer exists)" % (name, reg['workspaces'][name]['path']))
                lines.append('Tell the user and offer to relink it, so its chats and memory come back '
                             '(see the claude-portable section of the user CLAUDE.md).')
                return '\n'.join(lines)
            name = register(claude_dir, reg, project)
            save_registry(claude_dir, reg)
            if manual_path:
                print("Registered '%s' -> %s" % (name, project))
            return None

        note = _with_registry_lock(claude_dir, work)
        if note:
            print(note)
    except Exception as e:
        try:
            with open(os.path.join(portable_dir(claude_dir), 'hook-errors.log'), 'a') as f:
                f.write('%s %s\n' % (now(), e))
        except OSError:
            pass
        if manual_path:
            print('Error: %s' % e)
    return 0


def cmd_get(a):
    """Used by get.sh: update the data folder in use, or open the menu for a first install."""
    active = active_claude_dir()
    if os.path.exists(registry_file(active)):
        print('Data folder in use: ' + active)
        if confirm('Update it to version %s?' % portable_version(), True):
            return cmd_install(argparse.Namespace(data_dir=active, source=active, retention_days=36500, fresh=False,
                                                  skip_environment=False, force=True))
        print('Nothing changed.')
        return 0
    return cmd_menu(a)


def _pick_workspace():
    reg = read_registry(active_claude_dir())
    names = sorted(reg['workspaces'], key=str.lower)
    if not names:
        warn('The registry is empty: run Install first.')
        return None
    for i, name in enumerate(names, 1):
        path = str(reg['workspaces'][name]['path'])
        print(' %2d. %-30s %s%s' % (i, name, path, '' if os.path.exists(path) else '  (path not found)'))
    n = ask('Workspace number: ')
    if not n.isdigit() or not 1 <= int(n) <= len(names):
        warn('Invalid number.')
        return None
    return names[int(n) - 1]


def cmd_menu(a):
    def run(fn, **kw):
        try:
            fn(argparse.Namespace(**kw))
        except Abort as e:
            info(str(e))
        except Exception as e:
            print(_color('31', '\nError: %s' % e))

    while True:
        active = active_claude_dir()
        print('\n' + '=' * 40)
        print(_color('1', ' claude-portable %s' % portable_version()))
        print(' Claude data in use: ' + active)
        print('=' * 40)
        print(' 1. Install or update on this computer')
        print(' 2. Status (data folder, settings, workspaces, updates)')
        print(' 3. Relink a workspace (a project moved to a new path)')
        print(' 4. Export (zip to carry to another computer)')
        print(' 5. Import (on the new computer, or after moving the data folder)')
        print(' 6. Uninstall (back to the default ~/.claude)')
        print(' 7. Forget a workspace (a project you deleted)')
        print(' 8. Archive old chats (keep the data folder light)')
        print(' 9. Restore archived chats')
        print(' 0. Exit')
        choice = ask('Choice: ', '0' if not sys.stdin.isatty() else '')
        if choice == '1':
            default = active if os.path.exists(registry_file(active)) else os.path.join(home(), 'claude-data')
            data = ask('Portable folder [%s]: ' % default, default).strip('"\'')
            run(cmd_install, data_dir=data, source=None, retention_days=36500, fresh=False, skip_environment=False, force=False)
        elif choice == '2':
            run(cmd_status)
        elif choice == '3':
            name = _pick_workspace()
            new = ask('New path of the project: ').strip('"\'') if name else ''
            if name and new:
                run(cmd_relink, name=name, old_path=None, new_path=new, dry_run=False, force=False)
        elif choice == '4':
            run(cmd_export, output=None, force=False)
        elif choice == '5':
            source = ask('Zip file or folder to import: ').strip('"\'')
            if source:
                default = source if os.path.isdir(os.path.expanduser(source)) else os.path.join(home(), 'claude-data')
                data = ask('Portable folder on this computer [%s]: ' % default, default).strip('"\'')
                run(cmd_import, source_dir=source, data_dir=data, skip_environment=False, force=False)
        elif choice == '6':
            back = confirm('Copy the data back to ~/.claude first (keeps recent chats)?', True)
            run(cmd_uninstall, copy_back=back, skip_environment=False, force=False)
        elif choice == '7':
            name = _pick_workspace()
            if name:
                run(cmd_forget, name=name, force=False)
        elif choice == '8':
            days = ask('Archive chats not changed for how many days? [180]: ', '180')
            if days.isdigit() and int(days) >= 1:
                run(cmd_archive, older_than_days=int(days), dry_run=False, force=False)
            else:
                warn('Invalid number.')
        elif choice == '9':
            answer = ask('Restore all archived chats (a) or one workspace (w)? [a/w]: ').lower()
            if answer.startswith('a'):
                run(cmd_restore, name=None, all=True, force=False)
            elif answer.startswith('w'):
                name = _pick_workspace()
                if name:
                    run(cmd_restore, name=name, all=False, force=False)
        elif choice == '0':
            return 0
        else:
            warn('Unknown choice.')


def main(argv=None):
    p = argparse.ArgumentParser(prog='claude_portable.py', description='claude-portable for macOS and Linux')
    sub = p.add_subparsers(dest='command')
    sub.add_parser('menu', help='guided menu (default)')
    s = sub.add_parser('install', help='move Claude data into a portable folder, or update it')
    s.add_argument('--data-dir')
    s.add_argument('--retention-days', type=int, default=36500)
    s.add_argument('--source')
    s.add_argument('--fresh', action='store_true')
    s.add_argument('--skip-environment', action='store_true')
    s.add_argument('--force', action='store_true')
    sub.add_parser('status', help='data folder, settings, workspaces, compatibility')
    s = sub.add_parser('relink', help='reconnect a workspace that moved to a new path')
    s.add_argument('--name')
    s.add_argument('--old-path')
    s.add_argument('--new-path', required=True)
    s.add_argument('--dry-run', action='store_true')
    s.add_argument('--force', action='store_true')
    s = sub.add_parser('export', help='zip to carry to another computer (no login inside)')
    s.add_argument('--output')
    s.add_argument('--force', action='store_true')
    s = sub.add_parser('import', help='restore a zip or a copied folder and relink workspaces')
    s.add_argument('--from', dest='source_dir', required=True)
    s.add_argument('--data-dir')
    s.add_argument('--skip-environment', action='store_true')
    s.add_argument('--force', action='store_true')
    s = sub.add_parser('uninstall', help='go back to the default ~/.claude')
    s.add_argument('--copy-back', action='store_true')
    s.add_argument('--skip-environment', action='store_true')
    s.add_argument('--force', action='store_true')
    s = sub.add_parser('forget', help='remove a workspace from the registry (chats kept aside)')
    s.add_argument('--name', required=True)
    s.add_argument('--force', action='store_true')
    s = sub.add_parser('archive', help='move old chats into compressed archives')
    s.add_argument('--older-than-days', type=int, default=180)
    s.add_argument('--dry-run', action='store_true')
    s.add_argument('--force', action='store_true')
    s = sub.add_parser('restore', help='put archived chats back')
    s.add_argument('--name')
    s.add_argument('--all', action='store_true')
    s.add_argument('--force', action='store_true')
    sub.add_parser('hook', help='SessionStart hook (used by Claude Code)')
    s = sub.add_parser('register', help='register a path as its own workspace')
    s.add_argument('--path', required=True)
    sub.add_parser('get', help='used by get.sh')
    a = p.parse_args(argv)
    if a.command == 'archive' and a.older_than_days < 1:
        p.error('--older-than-days must be at least 1')
    if a.command == 'install' and a.retention_days < 1:
        p.error('--retention-days must be at least 1')
    commands = {
        None: cmd_menu, 'menu': cmd_menu, 'install': cmd_install, 'status': cmd_status, 'relink': cmd_relink,
        'export': cmd_export, 'import': cmd_import, 'uninstall': cmd_uninstall, 'forget': cmd_forget,
        'hook': cmd_hook, 'get': cmd_get, 'archive': cmd_archive, 'restore': cmd_restore,
        'register': lambda args: cmd_hook(args, manual_path=args.path),
    }
    try:
        return commands[a.command](a) or 0
    except Abort as e:
        info(str(e))
        return 1
    except KeyboardInterrupt:
        return 130


if __name__ == '__main__':
    sys.exit(main())
