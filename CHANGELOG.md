# Changelog

## 1.1.0

- Added: **macOS and Linux** version (`unix/claude_portable.py`, Python 3, standard library only),
  with `start.sh`, the same menu and the same data folder layout. A data folder can move between
  Windows, macOS and Linux: the hook is switched to the right one and paths are relinked.
- Added: automatic relink suggestion. When you open a project that is not registered but looks like
  a registered workspace whose path no longer exists (same folder name), Claude tells you at the
  start of the session and offers to reconnect its chats and memory.
- Added: "7. Forget a workspace" for projects you deleted. Their chats move to `portable/forgotten`,
  nothing is deleted.
- Added: one-command install and update
  (`irm .../get.ps1 | iex` on Windows, `curl -fsSL .../get.sh | sh` on macOS/Linux).
- Added: version number in the menu; Status checks GitHub for a newer version.
- Added: compatibility checks in Status, to notice when a Claude Code update changes the behaviour
  claude-portable relies on.
- Added: automated tests on Windows, Linux and macOS (GitHub Actions).
- Added: diagrams in `docs/images`, full guides copied to `portable/docs` in the data folder.
- Fixed: Install on a data folder that was moved or copied no longer fails or copies old data over
  it: it switches to Import.
- Fixed: Windows short paths (`C:\Users\DAVIDE~1\...`) are expanded, so they map to the right
  project folder.
- Added: relink also carries the project's folder trust and permissions (`.claude.json`) to the
  new path, so a moved project is not treated as a new, untrusted folder.
- Added: "8. Archive old chats" and "9. Restore archived chats": chats untouched for months are
  zipped (about a tenth of the size) and leave `/resume`; restoring brings them back with their dates.
- Fixed: Import no longer asks again for a workspace already moved together with its parent.

## 1.0.0

- First release: portable data folder (`CLAUDE_CONFIG_DIR`), chat retention, workspace registry
  kept by a SessionStart hook, relink, export, import, uninstall, guided menu.
