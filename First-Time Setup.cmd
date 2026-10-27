@echo off
setlocal DisableDelayedExpansion
title Gocam First-Time Setup - Administrator approval required
echo Gocam First-Time Setup
echo This opens Windows administrator approval automatically. You do not need to restart it as administrator.
echo.
set "GoProPowerShell=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "GoProPowerShell=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
"%GoProPowerShell%" -NoLogo -NoProfile -Command "if (([Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { exit 1 }; exit 0"
set "GoProLaunchAllowed=%errorlevel%"
"%GoProPowerShell%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup\Setup-Camera.ps1" -Action Setup
set "GoProSetupExit=%errorlevel%"
if "%GoProSetupExit%"=="0" (
    if "%GoProLaunchAllowed%"=="0" (
        echo Setup succeeded. Opening Gocam...
        start "" "%~dp0Gocam.exe"
    ) else (
        echo Setup succeeded. The app was not started with administrator privileges.
        echo Close this administrator window, then open Gocam.exe normally.
    )
)
echo.
pause
exit /b %GoProSetupExit%
