@echo off
setlocal DisableDelayedExpansion
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0mount-windows.ps1"
set "sshSwitchExit=%errorlevel%"
if "%sshSwitchExit%"=="0" exit /b 0
echo.
echo Press any key to close.
pause >nul
exit /b %sshSwitchExit%
