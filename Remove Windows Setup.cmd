@echo off
setlocal DisableDelayedExpansion
title Gocam Remove Windows Setup - Administrator approval required
echo Gocam Remove Windows Setup
echo The GoPro does not need to be connected. Administrator approval opens automatically.
echo.
set "GoProPowerShell=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "GoProPowerShell=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
"%GoProPowerShell%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup\Setup-Camera.ps1" -Action Remove
set "GoProSetupExit=%errorlevel%"
echo.
pause
exit /b %GoProSetupExit%
