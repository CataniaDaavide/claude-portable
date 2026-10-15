# claude-portable

Keep everything [Claude Code](https://code.claude.com) knows about your projects (chats, auto memory,
settings, skills) in **one folder** that you can carry to another computer, and reconnect each
project to its chats even when it lives at a different path.

Windows only (PowerShell 5.1, already part of Windows). [Guida in italiano](README.it.md).

## The problem

Claude Code stores its data in `%USERPROFILE%\.claude`. Each project gets a folder under `projects\`
whose name is the project path with every non-alphanumeric character replaced by `-`:

```
C:\Users\me\Desktop\my-app  ->  .claude\projects\C--Users-me-Desktop-my-app\
```

That folder holds the project's chats (`*.jsonl`) and its auto memory (`memory\`). Move the project,
or open it on a computer with a different user name, and the path changes: Claude Code starts from
zero even if you copied the data. On top of that, chats older than 30 days are deleted by default.

## What claude-portable does

| Piece | What it does |
|---|---|
| **One data folder** | Sets the official `CLAUDE_CONFIG_DIR` variable, so Claude Code keeps all its data in a folder you choose (default `%USERPROFILE%\claude-data`). |
| **Chats are kept** | Sets `cleanupPeriodDays` to 36500 (about 100 years). Claude Code does not allow turning the cleanup off (`0` is rejected), so a very long period is the way to keep everything. |
| **Workspace registry** | `portable\workspaces.json` maps every project path to its folder under `projects\`. A `SessionStart` hook updates it each time you open a project. |
| **Relink** | When a project moves, one command renames (or merges) its folder to match the new path, so `/resume` and memory work again. |
| **Claude knows how** | A short block in the user `CLAUDE.md` tells Claude about the registry, so you can just say *"studio-app is now in D:\work\studio-app"*. |
| **Export / Import** | A zip without your login to carry to another computer, and a guided import that asks where each project lives now. |

The scripts are copied into the data folder (`portable\scripts`), together with a
`claude-portable.bat` launcher, a short readme and these full guides (`portable\docs`), so the
folder works on its own, even offline: on a new
computer you do not need this repository (see [Only the data folder](#only-the-data-folder)).

## Quick start

1. Download this repository (green **Code** button, **Download ZIP**) or clone it:
   ```
   git clone https://github.com/CataniaDaavide/claude-portable.git
   ```
2. Close VS Code, every Claude Code terminal and the Claude desktop app.
3. Double-click **`start.bat`** and choose **1. Install**.
4. Reopen VS Code / your terminal and choose **2. Status** to check.

Install **copies** your data, it does not move it: the old `%USERPROFILE%\.claude` stays as a
backup until you delete it.

## Menu

| Option | Script | When |
|---|---|---|
| 1. Install | `scripts\install.ps1` | Once per computer |
| 2. Status | `scripts\status.ps1` | Any time: shows folder, retention, hook and every workspace |
| 3. Relink | `scripts\relink-workspace.ps1` | A project moved to a new path |
| 4. Export | `scripts\export-data.ps1` | Before moving to another computer |
| 5. Import | `scripts\import-data.ps1` | On the new computer |
| 6. Uninstall | `scripts\uninstall.ps1` | Go back to the default `~/.claude` |

Every script also works from the command line, for example:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\relink-workspace.ps1 -Name my-app -NewPath "D:\work\my-app" -DryRun
```

## Moving to another computer

**Old computer**: menu **4. Export**. You get `claude-data-export-<date>.zip` on the Desktop.

**New computer**:
1. Install Claude Code, then copy the zip (and this repository, or just the zip).
2. Run `start.bat`, choose **5. Import**, give the zip and the new data folder.
3. For each workspace whose path does not exist here, type the new path (or press Enter to do it later).
4. Restart VS Code / terminals and log in again (`/login`).

Copying the whole data folder (USB drive, sync tool) instead of the zip also works: see the next
section.

## Only the data folder

If on the new computer you have just the data folder (no repository, no zip):

1. Install Claude Code and copy the data folder where you want it, e.g. `C:\Users\<you>\claude-data`.
2. Double-click **`claude-portable.bat`** inside the copied folder and choose **5. Import**.
3. As the folder to import give the copied folder itself, then press Enter to keep it where it is.
4. The folder contains the login of the old computer (`.credentials.json`): the import asks whether
   to keep it. Removing it and logging in again with `/login` is the safer choice.
5. Type the new path of each project (or press Enter to relink it later), then restart VS Code.

Without the launcher (older data folders), open the menu with:

```powershell
powershell -ExecutionPolicy Bypass -File "C:\Users\<you>\claude-data\portable\scripts\claude-portable.ps1"
```

## Moving a project on the same computer

Close Claude Code in that project, move the folder, then either:
- menu **3. Relink**, or
- ask Claude from any other project: *"my-app moved to D:\work\my-app, relink it"*.

## What is not portable

- **Your login** (`.credentials.json`) is never put in the export zip: log in again on the new
  computer. A data folder copied as is does contain it, and the import asks whether to keep it.
- **Folder trust and per-project permissions** are keyed by path inside `.claude.json`: Claude Code
  asks again to trust a moved project. That is expected.
- **Checkpoints** (`file-history`) refer to old file paths and are not useful after a move.

## Privacy

Chats contain everything you typed and everything commands printed, which may include passwords,
tokens or customer data. Keep the data folder and the export zip private, never commit them to git,
and do not put them in a public cloud folder without encryption.

## How it works (details)

- `CLAUDE_CONFIG_DIR` is set as a user environment variable. With it, Claude Code reads settings,
  chats, memory, plugins, skills, `.claude.json` and `.credentials.json` from that folder.
- The hook command resolves the script from `CLAUDE_CONFIG_DIR` at run time and works in Git Bash and
  PowerShell alike, so it keeps working after the folder moves:
  ```
  powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command '& (Join-Path $env:CLAUDE_CONFIG_DIR portable\scripts\register-workspace.ps1)'
  ```
  It prints nothing (hook output would be added to Claude's context) and never fails the session;
  errors go to `portable\hook-errors.log`.
- Relink merges into an existing folder without overwriting anything: `MEMORY.md` indexes are merged
  line by line, files that exist on both sides keep the newer location's copy, and the old folder is
  moved to `portable\relink-backups\`.
- Project folder names longer than 200 characters get a hash suffix from Claude Code; relink finds
  those by prefix.
- Auto memory follows the git repository root. If you open a sub-folder of a repository as its own
  workspace, relinking the repository also relinks the registered sub-folders.

## Requirements

- Windows 10/11 with Windows PowerShell 5.1 (preinstalled)
- Claude Code (CLI, VS Code extension or desktop app)

## License

MIT, see [LICENSE](LICENSE).
