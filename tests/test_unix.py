#!/usr/bin/env python3
"""Test suite for the macOS/Linux version (unix/claude_portable.py). Standard library only.

Every test runs the script as a separate process with a fake HOME in a temporary folder, so the real
Claude data and the real shell files are never touched. Run: python3 tests/test_unix.py -v
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(ROOT, 'unix', 'claude_portable.py')
sys.path.insert(0, os.path.join(ROOT, 'unix'))
import claude_portable as cp  # noqa: E402


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w', encoding='utf-8') as f:
        f.write(text)


def read(path):
    with open(path, encoding='utf-8') as f:
        return f.read()


def load(path):
    return json.loads(read(path))


def chat_line(cwd):
    return json.dumps({'type': 'user', 'cwd': cwd}) + '\n'


class Sandbox(unittest.TestCase):
    """A fake HOME with a fake ~/.claude like the one Claude Code leaves behind."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix='claude-portable-tests-')
        self.home = os.path.join(self.tmp, 'home')
        claude = os.path.join(self.home, '.claude')
        write(os.path.join(claude, 'projects', '-old-app', 'a.jsonl'), '{"type":"summary"}\n' + chat_line('/old/app'))
        write(os.path.join(claude, 'projects', '-old-app', 'memory', 'MEMORY.md'), '- [One](one.md) - first\n')
        write(os.path.join(claude, 'projects', '-old-app', 'memory', 'one.md'), 'one')
        write(os.path.join(claude, 'projects', '-old-app-api', 'b.jsonl'), chat_line('/old/app/api'))
        os.makedirs(os.path.join(claude, 'projects', '-old-nochat', 'memory'))
        write(os.path.join(claude, 'settings.json'), json.dumps(
            {'theme': 'dark', 'hooks': {'PreToolUse': [{'matcher': 'Bash', 'hooks': [{'type': 'command', 'command': 'echo hi'}]}]}}))
        write(os.path.join(claude, 'CLAUDE.md'), '# my notes\n')
        write(os.path.join(claude, '.credentials.json'), 'secret')
        write(os.path.join(claude, 'cache', 'x.txt'), 'cache')
        write(os.path.join(self.home, '.claude.json'), json.dumps({'projects': {
            '/old/nochat': {},
            '/old/app': {'hasTrustDialogAccepted': True, 'allowedTools': ['Bash(npm test)'], 'lastCost': 0.25}},
            'userID': 'x'}))
        write(os.path.join(self.home, '.bashrc'), '# existing\nalias ll="ls -l"\n')
        self.data = os.path.join(self.home, 'claude-data')

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def run_cp(self, *args, answers='', config_dir=None, project=None, expect=0):
        env = dict(os.environ, HOME=self.home, CLAUDE_PORTABLE_SKIP_PROCESS_CHECK='1')
        env.pop('CLAUDE_CONFIG_DIR', None)
        if config_dir:
            env['CLAUDE_CONFIG_DIR'] = config_dir
        if project:
            env['CLAUDE_PROJECT_DIR'] = project
        r = subprocess.run([sys.executable, SCRIPT] + list(args), input=answers, capture_output=True,
                           text=True, env=env, cwd=self.tmp)
        out = r.stdout + r.stderr
        if expect is not None:
            self.assertEqual(expect, r.returncode, out)
        return out

    def install(self, *extra):
        return self.run_cp('install', '--data-dir', self.data, '--force', '--skip-environment', *extra)

    def registry(self, data=None):
        return load(os.path.join(data or self.data, 'portable', 'workspaces.json'))

    def run_hook(self, project, data=None):
        """Runs the hook command from settings.json through sh, as Claude Code does."""
        data = data or self.data
        settings = load(os.path.join(data, 'settings.json'))
        command = settings['hooks']['SessionStart'][0]['hooks'][0]['command']
        env = dict(os.environ, HOME=self.home, CLAUDE_CONFIG_DIR=data, CLAUDE_PROJECT_DIR=project)
        return subprocess.run(['sh', '-c', command], capture_output=True, text=True, env=env).stdout.strip()


class Helpers(unittest.TestCase):
    def test_folder_name_rule(self):
        self.assertEqual('-home-me-my-app', cp.folder_name('/home/me/my-app'))
        self.assertEqual('C--Users-me-my-app', cp.folder_name('C:\\Users\\me\\my-app'))
        self.assertEqual('-Users-me-my-app-v2', cp.folder_name('/Users/me/my app v2'))

    def test_moved_detection_with_a_windows_path(self):
        reg = {'workspaces': {'my-app': {'path': 'C:\\Users\\me\\my-app'}, 'other': {'path': '/'}}}
        self.assertEqual(['my-app'], cp.find_moved(reg, '/home/me/work/my-app'))
        self.assertEqual([], cp.find_moved(reg, '/home/me/work/something-else'))


class Install(Sandbox):
    def test_install_sets_everything_up(self):
        out = self.install()
        d = self.data
        self.assertTrue(os.path.exists(os.path.join(d, 'projects', '-old-app', 'a.jsonl')), out)
        self.assertTrue(os.path.exists(os.path.join(d, '.claude.json')))
        settings = load(os.path.join(d, 'settings.json'))
        self.assertEqual(36500, settings['cleanupPeriodDays'])
        self.assertEqual('dark', settings['theme'])
        self.assertEqual('echo hi', settings['hooks']['PreToolUse'][0]['hooks'][0]['command'])
        self.assertTrue(cp.hook_installed(settings))
        md = read(os.path.join(d, 'CLAUDE.md'))
        self.assertIn('# my notes', md)
        self.assertIn(cp.MD_START, md)
        ws = self.registry()['workspaces']
        self.assertEqual('/old/app', ws['app']['path'])
        self.assertEqual('/old/app/api', ws['api']['path'])
        self.assertEqual('/old/nochat', ws['nochat']['path'])
        for f in ('claude-portable.sh', 'claude-portable.bat', 'portable/README.md', 'portable/unix/claude_portable.py',
                  'portable/scripts/VERSION', 'portable/docs/README.md', 'portable/docs/CHANGELOG.md'):
            self.assertTrue(os.path.exists(os.path.join(d, f)), f)
        self.assertTrue(os.access(os.path.join(d, 'claude-portable.sh'), os.X_OK))
        self.assertNotIn('docs/images/', read(os.path.join(d, 'portable', 'docs', 'README.md')))

    def test_install_again_does_not_duplicate(self):
        self.install()
        out = self.run_cp('install', '--data-dir', self.data, '--force', '--skip-environment', config_dir=self.data)
        self.assertIn('already in the portable folder', out)
        settings = load(os.path.join(self.data, 'settings.json'))
        self.assertEqual(1, len(settings['hooks']['SessionStart']))
        self.assertEqual(1, read(os.path.join(self.data, 'CLAUDE.md')).count(cp.MD_START))

    def test_claude_md_block_is_identical_to_the_windows_one(self):
        ps = read(os.path.join(ROOT, 'scripts', 'lib', 'common.ps1'))
        for line in cp.claude_md_block().splitlines()[1:-1]:
            if line:
                self.assertIn("'" + line.replace("'", "''") + "'", ps, line)

    def test_windows_hook_is_replaced(self):
        settings = {'hooks': {'SessionStart': [{'matcher': 'startup|resume', 'hooks': [
            {'type': 'command', 'command': "powershell.exe -Command '& (Join-Path $env:CLAUDE_CONFIG_DIR portable\\scripts\\register-workspace.ps1)'"}]}]}}
        self.assertFalse(cp.hook_installed(settings))
        self.assertTrue(cp.add_hook(settings))
        commands = [h['command'] for g in settings['hooks']['SessionStart'] for h in g['hooks']]
        self.assertEqual([cp.HOOK_COMMAND], commands)

    def test_install_on_a_moved_data_folder_switches_to_import(self):
        self.install()
        moved = os.path.join(self.home, 'elsewhere', 'claude-data')
        shutil.move(self.data, moved)
        write(os.path.join(moved, 'projects', '-old-app', 'newer.jsonl'), chat_line('/old/app'))
        out = self.run_cp('install', '--data-dir', moved, '--force', '--skip-environment', config_dir=self.data)
        self.assertIn('switching to Import', out)
        self.assertTrue(os.path.exists(os.path.join(moved, 'projects', '-old-app', 'newer.jsonl')))

    @unittest.skipIf(cp.IS_MAC, 'on macOS this would call launchctl for the real login session')
    def test_environment_variable_is_saved_and_removed(self):
        self.run_cp('install', '--data-dir', self.data, '--force')
        bashrc = read(os.path.join(self.home, '.bashrc'))
        self.assertIn('alias ll="ls -l"', bashrc)
        self.assertIn('export CLAUDE_CONFIG_DIR=' + self.data, bashrc)
        self.assertTrue(os.path.exists(os.path.join(self.home, '.config', 'environment.d', 'claude-portable.conf')))
        self.run_cp('install', '--data-dir', self.data, '--force')
        self.assertEqual(1, read(os.path.join(self.home, '.bashrc')).count(cp.ENV_START))
        self.run_cp('uninstall', '--force', config_dir=self.data)
        bashrc = read(os.path.join(self.home, '.bashrc'))
        self.assertNotIn(cp.ENV_START, bashrc)
        self.assertIn('alias ll="ls -l"', bashrc)
        self.assertFalse(os.path.exists(os.path.join(self.home, '.config', 'environment.d', 'claude-portable.conf')))


class HookRelinkForget(Sandbox):
    def setUp(self):
        super().setUp()
        self.install()
        self.projects = os.path.join(self.tmp, 'work')

    def test_hook_registers_a_new_project_silently(self):
        project = os.path.join(self.projects, 'zeta')
        os.makedirs(project)
        self.assertEqual('', self.run_hook(project))
        self.assertIn('zeta', self.registry()['workspaces'])

    def test_hook_notices_a_moved_project(self):
        project = os.path.join(self.projects, 'app')
        os.makedirs(project)
        out = self.run_hook(project)
        self.assertIn('[claude-portable]', out)
        self.assertIn("'app', last seen at /old/app", out)
        self.assertIsNone(cp.find_by_path(self.registry(), project))
        self.run_cp('register', '--path', project, config_dir=self.data)
        self.assertEqual('', self.run_hook(project))

    def test_relink_renames_and_moves_nested_workspaces(self):
        new = os.path.join(self.projects, 'app')
        os.makedirs(new)
        self.run_cp('relink', '--name', 'app', '--new-path', new, '--force', config_dir=self.data)
        ws = self.registry()['workspaces']
        self.assertEqual(new, ws['app']['path'])
        self.assertEqual(new + '/api', ws['api']['path'])
        self.assertIn('/old/app', ws['app']['previousPaths'])
        self.assertTrue(os.path.exists(os.path.join(self.data, 'projects', cp.folder_name(new), 'a.jsonl')))
        self.assertEqual('', self.run_hook(new))

    def test_relink_copies_trust_and_permissions(self):
        new = os.path.join(self.projects, 'app')
        os.makedirs(new)
        self.run_cp('relink', '--name', 'app', '--new-path', new, '--force', config_dir=self.data)
        config = load(os.path.join(self.data, '.claude.json'))
        self.assertTrue(config['projects'][new]['hasTrustDialogAccepted'])
        self.assertEqual(['Bash(npm test)'], config['projects'][new]['allowedTools'])
        self.assertIn('/old/app', config['projects'])
        self.assertEqual('x', config['userID'])
        backups = os.listdir(os.path.join(self.data, 'portable', 'relink-backups'))
        self.assertTrue([b for b in backups if b.startswith('.claude.json-')])

    def test_archive_follow_relink_and_restore(self):
        folder = os.path.join(self.data, 'projects', '-old-app')
        old = os.path.join(folder, 'a.jsonl')
        when = os.path.getmtime(old) - 400 * 86400
        os.utime(old, (when, when))
        write(os.path.join(folder, 'a', 'subagents', 'agent-1.jsonl'), '{}')
        write(os.path.join(folder, 'recent.jsonl'), chat_line('/old/app'))
        self.run_cp('archive', '--older-than-days', '180', '--force', config_dir=self.data)
        self.assertFalse(os.path.exists(old))
        self.assertFalse(os.path.exists(os.path.join(folder, 'a')))
        self.assertTrue(os.path.exists(os.path.join(folder, 'recent.jsonl')))
        self.assertTrue(os.path.exists(os.path.join(folder, 'memory', 'one.md')))
        self.assertEqual(1, cp.archived_chat_count(self.data, '-old-app'))
        self.assertIn('Archived', self.run_cp('status', config_dir=self.data))
        new = os.path.join(self.projects, 'app')
        os.makedirs(new)
        self.run_cp('relink', '--name', 'app', '--new-path', new, '--force', config_dir=self.data)
        self.assertEqual(1, cp.archived_chat_count(self.data, cp.folder_name(new)))
        self.run_cp('restore', '--name', 'app', '--force', config_dir=self.data)
        restored = os.path.join(self.data, 'projects', cp.folder_name(new), 'a.jsonl')
        self.assertTrue(os.path.exists(restored))
        self.assertTrue(os.path.exists(os.path.join(self.data, 'projects', cp.folder_name(new), 'a', 'subagents', 'agent-1.jsonl')))
        self.assertLess(abs(os.path.getmtime(restored) - when), 120)
        self.assertFalse(os.path.exists(cp.archive_file(self.data, cp.folder_name(new))))

    def test_relink_merges_into_an_existing_folder(self):
        new = os.path.join(self.projects, 'app')
        os.makedirs(new)
        target = os.path.join(self.data, 'projects', cp.folder_name(new))
        write(os.path.join(target, 'new.jsonl'), chat_line(new))
        write(os.path.join(target, 'memory', 'MEMORY.md'), '- [New](new.md) - n\n')
        write(os.path.join(target, 'memory', 'one.md'), 'NEW')
        self.run_cp('relink', '--name', 'app', '--new-path', new, '--force', config_dir=self.data)
        self.assertTrue(os.path.exists(os.path.join(target, 'a.jsonl')))
        self.assertTrue(os.path.exists(os.path.join(target, 'new.jsonl')))
        index = read(os.path.join(target, 'memory', 'MEMORY.md'))
        self.assertIn('[New]', index)
        self.assertIn('[One]', index)
        self.assertEqual('NEW', read(os.path.join(target, 'memory', 'one.md')))
        backups = os.path.join(self.data, 'portable', 'relink-backups')
        self.assertEqual(1, len([d for d in os.listdir(backups) if os.path.isdir(os.path.join(backups, d))]))

    def test_relink_from_a_windows_path(self):
        reg = self.registry()
        reg['workspaces']['win'] = {'path': 'C:\\Users\\me\\win-app', 'folder': 'C--Users-me-win-app', 'previousPaths': []}
        write(os.path.join(self.data, 'portable', 'workspaces.json'), json.dumps(reg))
        write(os.path.join(self.data, 'projects', 'C--Users-me-win-app', 'w.jsonl'), chat_line('C:\\Users\\me\\win-app'))
        new = os.path.join(self.projects, 'win-app')
        os.makedirs(new)
        self.assertIn("'win'", self.run_hook(new))
        self.run_cp('relink', '--name', 'win', '--new-path', new, '--force', config_dir=self.data)
        self.assertTrue(os.path.exists(os.path.join(self.data, 'projects', cp.folder_name(new), 'w.jsonl')))

    def test_forget(self):
        self.run_cp('forget', '--name', 'nochat', '--force', config_dir=self.data)
        self.assertNotIn('nochat', self.registry()['workspaces'])
        self.assertFalse(os.path.exists(os.path.join(self.data, 'projects', '-old-nochat')))
        self.assertEqual(1, len(os.listdir(os.path.join(self.data, 'portable', 'forgotten'))))

    def test_status_and_compatibility(self):
        project = os.path.join(self.projects, 'zeta')
        os.makedirs(project)
        self.run_hook(project)
        write(os.path.join(self.data, 'projects', cp.folder_name(project), 'z.jsonl'), chat_line(project))
        out = self.run_cp('status', config_dir=self.data)
        self.assertIn('Project folder names follow the expected rule', out)
        self.assertIn('The SessionStart hook runs', out)
        self.assertNotIn('do NOT follow', out)


class ExportImport(Sandbox):
    def setUp(self):
        super().setUp()
        self.install()
        self.zip = os.path.join(self.tmp, 'export.zip')

    def test_export_leaves_out_login_and_caches(self):
        self.run_cp('export', '--output', self.zip, '--force', config_dir=self.data)
        names = zipfile.ZipFile(self.zip).namelist()
        self.assertIn('portable/workspaces.json', names)
        self.assertIn('.claude.json', names)
        self.assertNotIn('.credentials.json', names)
        self.assertFalse([n for n in names if n.startswith('cache/')])

    def test_import_zip_relinks_projects(self):
        self.run_cp('export', '--output', self.zip, '--force', config_dir=self.data)
        new_data = os.path.join(self.tmp, 'pc2-data')
        new_app = os.path.join(self.tmp, 'pc2', 'app')
        os.makedirs(new_app)
        # Workspaces in name order: api (skip), app (new path; moves api too), nochat (skip).
        out = self.run_cp('import', '--from', self.zip, '--data-dir', new_data, '--skip-environment',
                          answers='\n%s\n\n' % new_app)
        ws = self.registry(new_data)['workspaces']
        self.assertEqual(new_app, ws['app']['path'], out)
        self.assertEqual(new_app + '/api', ws['api']['path'])
        self.assertFalse(os.path.exists(os.path.join(new_data, '.credentials.json')))

    def test_import_of_a_windows_export(self):
        """A zip made on Windows: registry with C:\\ paths and the Windows hook."""
        stage = os.path.join(self.tmp, 'win-stage')
        write(os.path.join(stage, 'projects', 'C--Users-me-app', 'a.jsonl'), chat_line('C:\\Users\\me\\app'))
        write(os.path.join(stage, 'portable', 'workspaces.json'), json.dumps({'version': 1, 'workspaces': {
            'app': {'path': 'C:\\Users\\me\\app', 'folder': 'C--Users-me-app', 'previousPaths': []}}}))
        write(os.path.join(stage, 'settings.json'), json.dumps({'hooks': {'SessionStart': [{'hooks': [
            {'type': 'command', 'command': "powershell.exe -Command '& (Join-Path $env:CLAUDE_CONFIG_DIR portable\\scripts\\register-workspace.ps1)'"}]}]}}))
        win_zip = os.path.join(self.tmp, 'win.zip')
        with zipfile.ZipFile(win_zip, 'w') as z:
            for root, _, files in os.walk(stage):
                for f in files:
                    full = os.path.join(root, f)
                    z.write(full, os.path.relpath(full, stage).replace(os.sep, '/'))
        new_data = os.path.join(self.tmp, 'mac-data')
        new_app = os.path.join(self.tmp, 'code', 'app')
        os.makedirs(new_app)
        self.run_cp('import', '--from', win_zip, '--data-dir', new_data, '--skip-environment', answers=new_app + '\n')
        settings = load(os.path.join(new_data, 'settings.json'))
        self.assertTrue(cp.hook_installed(settings))
        self.assertNotIn('powershell', json.dumps(settings))
        self.assertTrue(os.path.exists(os.path.join(new_data, 'projects', cp.folder_name(new_app), 'a.jsonl')))

    def test_import_in_place_asks_about_the_login(self):
        copy = os.path.join(self.tmp, 'usb', 'claude-data')
        shutil.copytree(self.data, copy)
        write(os.path.join(copy, '.credentials.json'), 'secret')
        out = self.run_cp('import', '--from', copy, '--data-dir', copy, '--skip-environment', answers='n\n\n\n\n')
        self.assertIn('Login removed', out)
        self.assertFalse(os.path.exists(os.path.join(copy, '.credentials.json')))

    def test_uninstall_copies_back(self):
        self.run_cp('uninstall', '--copy-back', '--skip-environment', '--force', config_dir=self.data)
        self.assertFalse(cp.hook_installed(load(os.path.join(self.data, 'settings.json'))))
        claude = os.path.join(self.home, '.claude')
        self.assertTrue(os.path.isdir(os.path.join(claude, 'projects')))
        self.assertFalse(os.path.exists(os.path.join(claude, 'portable')))
        self.assertFalse(os.path.exists(os.path.join(claude, 'claude-portable.sh')))


class GetScript(Sandbox):
    def test_get_sh_downloads_and_starts(self):
        stage = os.path.join(self.tmp, 'gh')
        shutil.copytree(ROOT, os.path.join(stage, 'claude-portable-main'),
                        ignore=shutil.ignore_patterns('.git', 'tests', '__pycache__'))
        gh_zip = os.path.join(self.tmp, 'gh.zip')
        with zipfile.ZipFile(gh_zip, 'w') as z:
            for root, _, files in os.walk(stage):
                for f in files:
                    full = os.path.join(root, f)
                    z.write(full, os.path.relpath(full, stage))
        env = dict(os.environ, HOME=self.home, CLAUDE_PORTABLE_SOURCE=gh_zip, CLAUDE_PORTABLE_SKIP_PROCESS_CHECK='1')
        env.pop('CLAUDE_CONFIG_DIR', None)
        r = subprocess.run(['sh', os.path.join(ROOT, 'get.sh')], input='0\n', capture_output=True, text=True, env=env)
        self.assertEqual(0, r.returncode, r.stdout + r.stderr)
        self.assertIn('claude-portable %s' % cp.portable_version(), r.stdout)


if __name__ == '__main__':
    unittest.main()
