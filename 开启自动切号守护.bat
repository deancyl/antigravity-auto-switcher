@echo off
title Antigravity Start Unattended Daemon
cd /d "%~dp0"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0antigravity_compliant_helper.ps1" -Action start-daemon -AutoRestartApp
pause
