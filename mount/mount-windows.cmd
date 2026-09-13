@echo off
setlocal DisableDelayedExpansion
set "sshSwitchPowerShell=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "sshSwitchPowerShell=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
"%sshSwitchPowerShell%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0mount-windows.ps1"
set "sshSwitchExit=%errorlevel%"
if "%sshSwitchExit%"=="0" exit /b 0
echo.
echo Press any key to close.
pause >nul
exit /b %sshSwitchExit%
