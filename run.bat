@echo off
title Antigravity Helper
cd /d "%~dp0"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0antigravity_compliant_helper.ps1" -Action menu
