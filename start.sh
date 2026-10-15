#!/bin/sh
# Opens the claude-portable guided menu on macOS and Linux (requires python3).
command -v python3 >/dev/null 2>&1 || { echo "claude-portable needs python3. On macOS run: xcode-select --install"; exit 1; }
exec python3 "$(dirname "$0")/unix/claude_portable.py" menu
