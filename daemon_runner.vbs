' ============================================================================
' Antigravity 5小时限额无人值守全自动切号守护 - Windows 原生静默脱钩启动器
' ============================================================================
Option Explicit

Dim WshShell, fso, scriptDir, psScript, cmd

Set WshShell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
psScript = scriptDir & "\antigravity_compliant_helper.ps1"
WshShell.CurrentDirectory = scriptDir

cmd = "powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & psScript & """ -Action daemon -AutoRestartApp"
WshShell.Run cmd, 0, False
