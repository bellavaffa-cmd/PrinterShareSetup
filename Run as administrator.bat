@echo off
rem Launches Printer Share Setup. The script raises its own UAC prompt.
setlocal
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
start "" "%PS%" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0PrinterShareSetup.ps1"
endlocal
