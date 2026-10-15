#!/bin/sh
# claude-portable online installer and updater for macOS and Linux:
#
#   curl -fsSL https://raw.githubusercontent.com/CataniaDaavide/claude-portable/main/get.sh | sh
#
# Downloads the latest version into a temporary folder, then updates the data folder in use or opens
# the menu for a first install. The download is removed at the end.
# CLAUDE_PORTABLE_SOURCE (a zip URL or a local zip path) overrides the download, for testing.
set -e

command -v python3 >/dev/null 2>&1 || { echo "claude-portable needs python3. On macOS run: xcode-select --install"; exit 1; }
SOURCE="${CLAUDE_PORTABLE_SOURCE:-https://github.com/CataniaDaavide/claude-portable/archive/refs/heads/main.zip}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "claude-portable: downloading the latest version..."
if [ -f "$SOURCE" ]; then
    cp "$SOURCE" "$WORK/claude-portable.zip"
else
    curl -fsSL "$SOURCE" -o "$WORK/claude-portable.zip"
fi
python3 -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' "$WORK/claude-portable.zip" "$WORK"
SCRIPT="$(ls "$WORK"/*/unix/claude_portable.py | head -n 1)"
[ -n "$SCRIPT" ] || { echo "The download does not look like claude-portable."; exit 1; }

# With "curl | sh" the keyboard is not stdin: read the answers from the terminal when there is one.
if [ -t 1 ] && [ -r /dev/tty ]; then
    python3 "$SCRIPT" get < /dev/tty
else
    python3 "$SCRIPT" get
fi
