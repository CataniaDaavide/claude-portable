@echo off
rem claude-portable menu, launched from inside the data folder (no repository needed).
rem Bypass applies only to this process.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0portable\scripts\claude-portable.ps1"
pause
