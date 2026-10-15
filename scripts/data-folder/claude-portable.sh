#!/bin/sh
# claude-portable menu (macOS/Linux), launched from inside the data folder (no repository needed).
exec python3 "$(dirname "$0")/portable/unix/claude_portable.py" menu
