@rem Starts the operator-facing wake recorder; capture logic belongs in src.
@echo off
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0src\Start-WakeTrace.ps1"
set "recording_exit=%errorlevel%"
echo.
pause
exit /b %recording_exit%
