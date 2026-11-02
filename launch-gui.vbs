Set WshShell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
psScript = scriptDir & "\antigravity_compliant_helper.ps1"

' 遵循 Windows 桌面交互准则：内核级无黑框静默拉起现代桌面面板 (0 = 隐藏控制台，False = 异步脱钩)
WshShell.Run "powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & psScript & """ -Action gui", 0, False
