<#



.SYNOPSIS



    Antigravity 5小时限额无人值守全自动切号与对话续接引擎 (AGY 2.0 稳定防闪退版)



    Antigravity Unattended Account Rotation & Auto-Resume Engine for Windows



.DESCRIPTION



    针对用户实测反馈的三大核心问题进行了彻底重构：



    1. 【根治切号后 AGY2 闪退】：



       - 彻底弃用 PowerShell ConvertFrom-Json / ConvertTo-Json 重写 app_storage.json（PowerShell 5.1 会把 JSON 内的单元素数组拆包为标量，导致 AGY2 主进程读取配置时类型错误直接闪退）。



       - 改用 C# 原生正则在不触碰任何其他字段和数组的前提下，仅原地替换 "jetski.onboarding.lastLoginUsername"；若检测到旧版遗留的已损坏 app_storage.json，自动备份并重置为纯净合法的最小配置。



       - 针对 AGY 2.0 (v2.24.0 / v2.25.0+) 严格遵循官方 Credential Store 规范，不再向 .gemini\antigravity-ide\...\state.vscdb 注入合成数据，并自动等待后台更新器 (Antigravity-x64.exe) 结束后再拉起客户端。



    2. 【根治在 .bat 窗口按 Ctrl+C 导致 AGY2 跟着退出】：



       - 通过 WMI (Win32_Process.Create) 与 Win32 CreateProcessW (DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP | CREATE_BREAKAWAY_FROM_JOB) 双重脱钩机制拉起 Antigravity.exe。



       - 新拉起的 AGY2 挂在系统独立进程树下，与当前 .bat / PowerShell 控制台完全隔离；在控制台按 Ctrl+C 或直接关闭黑框，AGY2 绝不会退出。



    3. 【真正的无人值守全自动运行（自动检测 + 自动切号 + 自动重启 + 自动恢复对话继续跑）】：



       - 后台静默守护进程实时监听 language_server.log、main.log 以及 ~/.gemini/antigravity/conversations/*.pb 对话数据文件尾部。



       - 一旦捕获 5 小时限额，自动优雅关闭旧实例 -> 切换至下一可用槽位 -> 以启用本地调试端口 (--remote-debugging-port=9339) 脱钩拉起 AGY2 -> 通过内置 CDP WebSocket 引擎自动点开最近一条对话、填入“继续执行”指令并自动点击发送（辅以剪贴板与按键模拟兜底），全程无需人工干预！



#>



[CmdletBinding()]



param(



    [ValidateSet("menu", "status", "save", "switch", "delete", "mode", "handover", "daemon", "daemon-worker", "start-daemon", "stop-daemon", "daemon-status", "next-slot", "pool-status", "reset-cooldown", "repair-storage", "auto-resume", "refresh-quota")]



    [string]$Action = "menu",



    [string]$Slot = "",



    [ValidateSet("oauth", "apikey", "adc")]



    [string]$AuthMode = "oauth",



    [string]$ApiKey = "",



    [string]$ProjectDir = (Get-Location).Path,



    [switch]$Handover,



    [switch]$LaunchAgy,



    [switch]$Force,



    [switch]$AutoRestartApp = $true,



    [switch]$NoRestartApp = $false,



    [switch]$AutoResumeConversation = $true,



    [double]$CooldownHours = 5.0,



    [int]$PollIntervalSec = 3,



    [switch]$RunOnce,



    [int]$WaitParentPid = 0,



    [string]$TargetConversationId = "",



    [string]$TargetProjectId = "",



    [string]$ResumePromptText = ""



)



Set-StrictMode -Version Latest



$ErrorActionPreference = "Stop"



# 全局状态与多线程共享变量显式初始化（严格模式防未定义变量崩溃）



$Script:CachedMonitoredFiles = @()



$Script:LastFileScanTime     = [DateTime]::MinValue



$Script:LastActiveConvTitle  = ""



$Script:LastActiveManifest   = $null



$Script:CachedLsQuota        = $null



$Script:CachedLsEndpoint     = $null



# 在脚本最顶层锁定自身绝对路径与目录（彻底防止在函数、事件回调或 wscript 脱钩启动时 $PSScriptRoot 为空导致 Join-Path 崩溃！）



$Script:ResolvedScriptPath = $MyInvocation.MyCommand.Path



if ([string]::IsNullOrWhiteSpace($Script:ResolvedScriptPath)) { $Script:ResolvedScriptPath = $PSCommandPath }



if ([string]::IsNullOrWhiteSpace($Script:ResolvedScriptPath) -and (-not [string]::IsNullOrWhiteSpace($PSScriptRoot))) {



    $Script:ResolvedScriptPath = Join-Path $PSScriptRoot "antigravity_compliant_helper.ps1"



}



if ([string]::IsNullOrWhiteSpace($Script:ResolvedScriptPath)) {



    $candLocal = Join-Path (Get-Location).Path "antigravity_compliant_helper.ps1"



    $candDesk  = "C:\Users\deanc\Desktop\AGY\antigravity_compliant_helper.ps1"



    if (Test-Path $candLocal) { $Script:ResolvedScriptPath = $candLocal }



    elseif (Test-Path $candDesk) { $Script:ResolvedScriptPath = $candDesk }



}



$Script:ResolvedScriptDir = if (-not [string]::IsNullOrWhiteSpace($Script:ResolvedScriptPath)) {



    Split-Path -Parent $Script:ResolvedScriptPath



} else {



    (Get-Location).Path



}



if ($WaitParentPid -gt 0) {



    Start-Sleep -Milliseconds 600



}



# ============================================================================



# 0. 无 BOM UTF-8 读写工具



# ============================================================================



$Utf8NoBomEncoding = New-Object System.Text.UTF8Encoding($false)



function Write-Utf8NoBom {



    param(



        [Parameter(Mandatory=$true)][string]$Path,



        [AllowEmptyString()][string]$Content



    )



    $parent = Split-Path -Parent $Path



    if ($parent -and (-not (Test-Path $parent))) {



        New-Item -ItemType Directory -Path $parent -Force | Out-Null



    }



    if ($Content.Length -gt 0 -and [int][char]$Content[0] -eq 0xFEFF) {



        $Content = $Content.Substring(1)



    }



    [System.IO.File]::WriteAllText($Path, $Content, $Utf8NoBomEncoding)



}



function Read-Utf8StripBom {



    param([Parameter(Mandatory=$true)][string]$Path)



    if (-not (Test-Path $Path)) { return $null }



    $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)



    if ($raw.Length -gt 0 -and [int][char]$raw[0] -eq 0xFEFF) {



        return $raw.Substring(1)



    }



    return $raw



}



function Repair-FileUtf8BomIfPresent {



    param([string]$Path)



    if ([string]::IsNullOrWhiteSpace($Path) -or (-not (Test-Path $Path))) { return $false }



    try {



        $bytes = [System.IO.File]::ReadAllBytes($Path)



        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {



            $cleanBytes = New-Object byte[] ($bytes.Length - 3)



            [System.Buffer]::BlockCopy($bytes, 3, $cleanBytes, 0, $cleanBytes.Length)



            [System.IO.File]::WriteAllBytes($Path, $cleanBytes)



            return $true



        }



    } catch {}



    return $false



}



# ============================================================================



# 1. 内联 C#：Advapi32 凭据库 + DPAPI + Win32 完全脱钩进程创建 + 窗口控制 + CDP WebSocket



#    （严格兼容 Windows PowerShell 5.1 C# 5.0 语法与 PowerShell 7+）



# ============================================================================



$CSharpSource = @'



using System;



using System.Collections.Generic;



using System.IO;



using System.Net;



using System.Net.Security;



using System.Net.WebSockets;



using System.Security.Cryptography.X509Certificates;



using System.Runtime.InteropServices;



using System.Security.Cryptography;



using System.Text;



using System.Text.RegularExpressions;



using System.Threading;



namespace AntigravityCompliantHelper



{



    public static class NativeVaultV4



    {



        private const int CRED_TYPE_GENERIC = 1;



        private const int CRED_PERSIST_LOCAL_MACHINE = 2;



        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]



        private struct CREDENTIAL



        {



            public UInt32 Flags;



            public UInt32 Type;



            public IntPtr TargetName;



            public IntPtr Comment;



            public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;



            public UInt32 CredentialBlobSize;



            public IntPtr CredentialBlob;



            public UInt32 Persist;



            public UInt32 AttributeCount;



            public IntPtr Attributes;



            public IntPtr TargetAlias;



            public IntPtr UserName;



        }



        [DllImport("Advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)]



        private static extern bool CredRead(string target, int type, int reservedFlag, out IntPtr credentialPtr);



        [DllImport("Advapi32.dll", EntryPoint = "CredWriteW", CharSet = CharSet.Unicode, SetLastError = true)]



        private static extern bool CredWrite([In] ref CREDENTIAL userCredential, [In] UInt32 flags);



        [DllImport("Advapi32.dll", EntryPoint = "CredFree", SetLastError = true)]



        private static extern bool CredFree([In] IntPtr cred);



        public static string ReadGenericCredential(string target)



        {



            IntPtr credPtr = IntPtr.Zero;



            if (!CredRead(target, CRED_TYPE_GENERIC, 0, out credPtr))



            {



                int err = Marshal.GetLastWin32Error();



                if (err == 1168)



                {



                    return null;



                }



                throw new InvalidOperationException("Windows 凭据管理器读取失败，Win32 错误码: " + err);



            }



            try



            {



                CREDENTIAL cred = (CREDENTIAL)Marshal.PtrToStructure(credPtr, typeof(CREDENTIAL));



                if (cred.CredentialBlobSize == 0 || cred.CredentialBlob == IntPtr.Zero)



                {



                    return string.Empty;



                }



                byte[] blob = new byte[cred.CredentialBlobSize];



                Marshal.Copy(cred.CredentialBlob, blob, 0, (int)cred.CredentialBlobSize);



                string text = Encoding.UTF8.GetString(blob);



                if (text.Length > 0 && text[0] == '\uFEFF')



                {



                    text = text.Substring(1);



                }



                return text;



            }



            finally



            {



                CredFree(credPtr);



            }



        }



        public static void WriteGenericCredential(string target, string userName, string secretUtf8)



        {



            if (!string.IsNullOrEmpty(secretUtf8) && secretUtf8[0] == '\uFEFF')



            {



                secretUtf8 = secretUtf8.Substring(1);



            }



            byte[] byteArray = Encoding.UTF8.GetBytes(secretUtf8);



            IntPtr blobPtr = Marshal.AllocHGlobal(byteArray.Length);



            IntPtr targetPtr = Marshal.StringToCoTaskMemUni(target);



            IntPtr userPtr = Marshal.StringToCoTaskMemUni(userName);



            try



            {



                Marshal.Copy(byteArray, 0, blobPtr, byteArray.Length);



                CREDENTIAL cred = new CREDENTIAL



                {



                    Flags = 0,



                    Type = CRED_TYPE_GENERIC,



                    TargetName = targetPtr,



                    Comment = IntPtr.Zero,



                    CredentialBlobSize = (UInt32)byteArray.Length,



                    CredentialBlob = blobPtr,



                    Persist = CRED_PERSIST_LOCAL_MACHINE,



                    AttributeCount = 0,



                    Attributes = IntPtr.Zero,



                    TargetAlias = IntPtr.Zero,



                    UserName = userPtr



                };



                if (!CredWrite(ref cred, 0))



                {



                    int err = Marshal.GetLastWin32Error();



                    throw new InvalidOperationException("Windows 凭据管理器写入失败，Win32 错误码: " + err);



                }



            }



            finally



            {



                Array.Clear(byteArray, 0, byteArray.Length);



                Marshal.FreeHGlobal(blobPtr);



                Marshal.FreeCoTaskMem(targetPtr);



                Marshal.FreeCoTaskMem(userPtr);



            }



        }



        public static string ProtectText(string plainText)



        {



            byte[] inputBytes = Encoding.UTF8.GetBytes(plainText);



            byte[] entropy = Encoding.UTF8.GetBytes("AntigravityCompliantHelper.v1");



            try



            {



                byte[] encrypted = ProtectedData.Protect(inputBytes, entropy, DataProtectionScope.CurrentUser);



                return Convert.ToBase64String(encrypted);



            }



            finally



            {



                Array.Clear(inputBytes, 0, inputBytes.Length);



            }



        }



        public static string UnprotectText(string encryptedBase64)



        {



            byte[] encryptedBytes = Convert.FromBase64String(encryptedBase64);



            byte[] entropy = Encoding.UTF8.GetBytes("AntigravityCompliantHelper.v1");



            byte[] decrypted = ProtectedData.Unprotect(encryptedBytes, entropy, DataProtectionScope.CurrentUser);



            try



            {



                string text = Encoding.UTF8.GetString(decrypted);



                if (text.Length > 0 && text[0] == '\uFEFF')



                {



                    text = text.Substring(1);



                }



                return text;



            }



            finally



            {



                Array.Clear(decrypted, 0, decrypted.Length);



            }



        }



        // ====================================================================



        // Win32 CreateProcessW 完全脱离控制台进程组与父作业对象（按 Ctrl+C 绝不杀子进程）



        // ====================================================================



        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]



        private struct STARTUPINFO



        {



            public Int32 cb;



            public string lpReserved;



            public string lpDesktop;



            public string lpTitle;



            public Int32 dwX;



            public Int32 dwY;



            public Int32 dwXSize;



            public Int32 dwYSize;



            public Int32 dwXCountChars;



            public Int32 dwYCountChars;



            public Int32 dwFillAttribute;



            public Int32 dwFlags;



            public Int16 wShowWindow;



            public Int16 cbReserved2;



            public IntPtr lpReserved2;



            public IntPtr hStdInput;



            public IntPtr hStdOutput;



            public IntPtr hStdError;



        }



        [StructLayout(LayoutKind.Sequential)]



        private struct PROCESS_INFORMATION



        {



            public IntPtr hProcess;



            public IntPtr hThread;



            public int dwProcessId;



            public int dwThreadId;



        }



        [DllImport("kernel32.dll", EntryPoint = "CreateProcessW", CharSet = CharSet.Unicode, SetLastError = true)]



        private static extern bool CreateProcess(



            string lpApplicationName,



            StringBuilder lpCommandLine,



            IntPtr lpProcessAttributes,



            IntPtr lpThreadAttributes,



            bool bInheritHandles,



            uint dwCreationFlags,



            IntPtr lpEnvironment,



            string lpCurrentDirectory,



            ref STARTUPINFO lpStartupInfo,



            out PROCESS_INFORMATION lpProcessInformation);



        [DllImport("kernel32.dll", SetLastError = true)]



        private static extern bool CloseHandle(IntPtr hObject);



        [DllImport("kernel32.dll")]



        private static extern IntPtr GetConsoleWindow();



        [DllImport("kernel32.dll", SetLastError = true)]



        private static extern bool FreeConsole();



        private const uint DETACHED_PROCESS = 0x00000008;



        private const uint CREATE_NO_WINDOW = 0x08000000;



        private const uint CREATE_NEW_PROCESS_GROUP = 0x00000200;



        private const uint CREATE_BREAKAWAY_FROM_JOB = 0x01000000;



        private const int STARTF_USESHOWWINDOW = 0x00000001;



        private const short SW_HIDE_CONST = 0;



        private const short SW_SHOWNORMAL = 1;



        public static void DetachAndHideConsole()



        {



            try



            {



                IntPtr hConsole = GetConsoleWindow();



                if (hConsole != IntPtr.Zero)



                {



                    ShowWindow(hConsole, 0);



                }



                // 切勿调用 FreeConsole()！FreeConsole 会导致 PowerShell 后续执行任何 Write-Host 时抛出 IOException(句柄无效) 而直接闪退！



            }



            catch {}



        }



        // 使用 CREATE_NO_WINDOW (0x08000000) + SW_HIDE 启动后台守护进程：内核级禁止分配 conhost / Windows Terminal 窗口！



        public static int LaunchHiddenBackgroundProcess(string exePath, string arguments, string workingDir)



        {



            STARTUPINFO si = new STARTUPINFO();



            si.cb = Marshal.SizeOf(typeof(STARTUPINFO));



            si.dwFlags = STARTF_USESHOWWINDOW;



            si.wShowWindow = SW_HIDE_CONST;



            string cmd = "\"" + exePath + "\"";



            if (!string.IsNullOrEmpty(arguments))



            {



                cmd += " " + arguments;



            }



            StringBuilder cmdBuilder = new StringBuilder(cmd);



            PROCESS_INFORMATION pi;



            uint flags = CREATE_NO_WINDOW | CREATE_NEW_PROCESS_GROUP | CREATE_BREAKAWAY_FROM_JOB;



            bool ok = CreateProcess(null, cmdBuilder, IntPtr.Zero, IntPtr.Zero, false, flags, IntPtr.Zero, workingDir, ref si, out pi);



            if (!ok)



            {



                cmdBuilder = new StringBuilder(cmd);



                flags = CREATE_NO_WINDOW | CREATE_NEW_PROCESS_GROUP;



                ok = CreateProcess(null, cmdBuilder, IntPtr.Zero, IntPtr.Zero, false, flags, IntPtr.Zero, workingDir, ref si, out pi);



            }



            if (!ok)



            {



                return 0;



            }



            try



            {



                return pi.dwProcessId;



            }



            finally



            {



                if (pi.hThread != IntPtr.Zero) CloseHandle(pi.hThread);



                if (pi.hProcess != IntPtr.Zero) CloseHandle(pi.hProcess);



            }



        }



        public static int LaunchFullyDetachedGui(string exePath, string arguments, string workingDir)



        {



            STARTUPINFO si = new STARTUPINFO();



            si.cb = Marshal.SizeOf(typeof(STARTUPINFO));



            si.dwFlags = STARTF_USESHOWWINDOW;



            si.wShowWindow = SW_SHOWNORMAL;



            string cmd = "\"" + exePath + "\"";



            if (!string.IsNullOrEmpty(arguments))



            {



                cmd += " " + arguments;



            }



            StringBuilder cmdBuilder = new StringBuilder(cmd);



            PROCESS_INFORMATION pi;



            // 先尝试带 CREATE_BREAKAWAY_FROM_JOB + DETACHED_PROCESS + CREATE_NEW_PROCESS_GROUP



            uint flagsWithBreakaway = DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP | CREATE_BREAKAWAY_FROM_JOB;



            bool ok = CreateProcess(null, cmdBuilder, IntPtr.Zero, IntPtr.Zero, false, flagsWithBreakaway, IntPtr.Zero, workingDir, ref si, out pi);



            if (!ok)



            {



                cmdBuilder = new StringBuilder(cmd);



                uint flagsNormal = DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP;



                ok = CreateProcess(null, cmdBuilder, IntPtr.Zero, IntPtr.Zero, false, flagsNormal, IntPtr.Zero, workingDir, ref si, out pi);



            }



            if (!ok)



            {



                return 0;



            }



            try



            {



                return pi.dwProcessId;



            }



            finally



            {



                if (pi.hThread != IntPtr.Zero) CloseHandle(pi.hThread);



                if (pi.hProcess != IntPtr.Zero) CloseHandle(pi.hProcess);



            }



        }



        // ====================================================================



        // Win32 窗口控制：优雅关闭 (WM_CLOSE) 与前置激活 (SetForegroundWindow)



        // ====================================================================



        private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);



        [DllImport("User32.dll", SetLastError = true)]



        private static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);



        [DllImport("User32.dll", SetLastError = true)]



        private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);



        [DllImport("User32.dll", SetLastError = true)]



        private static extern IntPtr GetWindow(IntPtr hWnd, uint uCmd);



        [DllImport("User32.dll", SetLastError = true)]



        private static extern bool IsWindowVisible(IntPtr hWnd);



        [DllImport("User32.dll", CharSet = CharSet.Unicode, SetLastError = true)]



        private static extern bool PostMessageW(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);



        [DllImport("User32.dll", SetLastError = true)]



        private static extern bool SetForegroundWindow(IntPtr hWnd);



        [DllImport("User32.dll", SetLastError = true)]



        private static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);



        private const uint WM_CLOSE = 0x0010;



        private const uint GW_OWNER = 4;



        private const int SW_RESTORE = 9;



        public static int RequestGracefulProcessClose(int targetPid)



        {



            int postedCount = 0;



            EnumWindowsProc callback = delegate(IntPtr hWnd, IntPtr lParam)



            {



                uint winPid = 0;



                GetWindowThreadProcessId(hWnd, out winPid);



                if (winPid == (uint)targetPid)



                {



                    IntPtr owner = GetWindow(hWnd, GW_OWNER);



                    if (owner == IntPtr.Zero)



                    {



                        if (PostMessageW(hWnd, WM_CLOSE, IntPtr.Zero, IntPtr.Zero))



                        {



                            postedCount++;



                        }



                    }



                }



                return true;



            };



            try



            {



                EnumWindows(callback, IntPtr.Zero);



            }



            catch {}



            return postedCount;



        }



        public static bool BringProcessMainWindowToFront(int targetPid)



        {



            bool activated = false;



            EnumWindowsProc callback = delegate(IntPtr hWnd, IntPtr lParam)



            {



                uint winPid = 0;



                GetWindowThreadProcessId(hWnd, out winPid);



                if (winPid == (uint)targetPid && IsWindowVisible(hWnd))



                {



                    IntPtr owner = GetWindow(hWnd, GW_OWNER);



                    if (owner == IntPtr.Zero)



                    {



                        ShowWindow(hWnd, SW_RESTORE);



                        SetForegroundWindow(hWnd);



                        activated = true;



                        return false;



                    }



                }



                return true;



            };



            try



            {



                EnumWindows(callback, IntPtr.Zero);



            }



            catch {}



            return activated;



        }



        // ====================================================================



        // 无损更新 app_storage.json：绝不使用 PowerShell ConvertTo-Json 破坏数组结构！



        // ====================================================================



        private static string EscapeJsonString(string input)



        {



            if (string.IsNullOrEmpty(input)) return "";



            return input.Replace("\\", "\\\\").Replace("\"", "\\\"");



        }



        public static string ReadJsonStringFieldRegex(string filePath, string fieldName)



        {



            if (string.IsNullOrEmpty(filePath) || !File.Exists(filePath)) return "";



            try



            {



                string raw = File.ReadAllText(filePath, Encoding.UTF8);



                if (raw.Length > 0 && raw[0] == '\uFEFF') raw = raw.Substring(1);



                string pattern = "\"" + Regex.Escape(fieldName) + "\"\\s*:\\s*\"([^\"]*)\"";



                Match m = Regex.Match(raw, pattern);



                if (m.Success)



                {



                    return m.Groups[1].Value;



                }



            }



            catch {}



            return "";



        }



        public static void UpdateAppStorageEmailSafely(string filePath, string email, bool forceCleanReset)



        {



            string dir = Path.GetDirectoryName(filePath);



            if (!string.IsNullOrEmpty(dir) && !Directory.Exists(dir))



            {



                Directory.CreateDirectory(dir);



            }



            string safeEmail = EscapeJsonString(email.Trim());



            string minimalCleanJson = "{\n  \"jetski.onboarding.lastLoginUsername\": \"" + safeEmail + "\",\n  \"jetski.onboarding.lastLoginIsGcpTos\": \"false\"\n}";



            if (forceCleanReset || !File.Exists(filePath))



            {



                File.WriteAllText(filePath, minimalCleanJson, new UTF8Encoding(false));



                return;



            }



            try



            {



                string raw = File.ReadAllText(filePath, Encoding.UTF8);



                if (raw.Length > 0 && raw[0] == '\uFEFF')



                {



                    raw = raw.Substring(1);



                }



                raw = raw.Trim();



                // 检测是否曾被 PowerShell 5.1 ConvertTo-Json 破坏过（4空格缩进 + 拆包数组导致 AGY2 闪退）



                bool looksCorruptedByPs = raw.StartsWith("{\r\n    \"") || raw.StartsWith("{\n    \"") || !raw.StartsWith("{") || !raw.EndsWith("}");



                if (looksCorruptedByPs)



                {



                    try



                    {



                        File.Copy(filePath, filePath + ".ps_corrupt.bak", true);



                    }



                    catch {}



                    File.WriteAllText(filePath, minimalCleanJson, new UTF8Encoding(false));



                    return;



                }



                string userPattern = "(\"jetski\\.onboarding\\.lastLoginUsername\"\\s*:\\s*\")([^\"]*)(\")";



                if (Regex.IsMatch(raw, userPattern))



                {



                    raw = Regex.Replace(raw, userPattern, delegate(Match m) { return m.Groups[1].Value + safeEmail + m.Groups[3].Value; });



                }



                else



                {



                    int lastBrace = raw.LastIndexOf('}');



                    if (lastBrace > 0)



                    {



                        string prefix = raw.Substring(0, lastBrace).TrimEnd();



                        bool isEmptyObj = prefix == "{";



                        string insertion = (isEmptyObj ? "\n" : ",\n") + "  \"jetski.onboarding.lastLoginUsername\": \"" + safeEmail + "\"\n}";



                        raw = prefix + insertion;



                    }



                    else



                    {



                        raw = minimalCleanJson;



                    }



                }



                string tosPattern = "(\"jetski\\.onboarding\\.lastLoginIsGcpTos\"\\s*:\\s*)(?:\"[^\"]*\"|true|false)";



                if (Regex.IsMatch(raw, tosPattern))



                {



                    raw = Regex.Replace(raw, tosPattern, delegate(Match m) { return m.Groups[1].Value + "\"false\""; });



                }



                else



                {



                    int lastBrace = raw.LastIndexOf('}');



                    if (lastBrace > 0)



                    {



                        string prefix = raw.Substring(0, lastBrace).TrimEnd();



                        raw = prefix + ",\n  \"jetski.onboarding.lastLoginIsGcpTos\": \"false\"\n}";



                    }



                }



                File.WriteAllText(filePath, raw, new UTF8Encoding(false));



            }



            catch



            {



                File.WriteAllText(filePath, minimalCleanJson, new UTF8Encoding(false));



            }



        }



        // ====================================================================



        // CDP WebSocket 客户端：向 AGY2 渲染进程发送 Runtime.evaluate 自动恢复对话



        // ====================================================================



        public static string SendCdpEvaluate(string wsUrl, string jsExpression, int timeoutMs)



        {



            try



            {



                using (ClientWebSocket ws = new ClientWebSocket())



                using (CancellationTokenSource cts = new CancellationTokenSource(timeoutMs))



                {



                    ws.ConnectAsync(new Uri(wsUrl), cts.Token).GetAwaiter().GetResult();



                    string escapedJs = jsExpression.Replace("\\", "\\\\").Replace("\"", "\\\"").Replace("\r", "\\r").Replace("\n", "\\n");



                    string payload = "{\"id\":1,\"method\":\"Runtime.evaluate\",\"params\":{\"expression\":\"" + escapedJs + "\",\"awaitPromise\":true,\"returnByValue\":true}}";



                    byte[] sendBytes = Encoding.UTF8.GetBytes(payload);



                    ArraySegment<byte> sendSeg = new ArraySegment<byte>(sendBytes);



                    ws.SendAsync(sendSeg, WebSocketMessageType.Text, true, cts.Token).GetAwaiter().GetResult();



                    byte[] recvBuf = new byte[65536];



                    StringBuilder sb = new StringBuilder();



                    while (true)



                    {



                        ArraySegment<byte> recvSeg = new ArraySegment<byte>(recvBuf);



                        WebSocketReceiveResult res = ws.ReceiveAsync(recvSeg, cts.Token).GetAwaiter().GetResult();



                        if (res.MessageType == WebSocketMessageType.Close) break;



                        sb.Append(Encoding.UTF8.GetString(recvBuf, 0, res.Count));



                        if (res.EndOfMessage)



                        {



                            string msg = sb.ToString();



                            if (msg.Contains("\"id\":1"))



                            {



                                return msg;



                            }



                            sb.Clear();



                        }



                    }



                    return "";



                }



            }



            catch



            {



                return "";



            }



        }



        public static bool SendCdpMouseClick(string wsUrl, int x, int y, int timeoutMs)



        {



            try



            {



                using (ClientWebSocket ws = new ClientWebSocket())



                using (CancellationTokenSource cts = new CancellationTokenSource(timeoutMs))



                {



                    ws.ConnectAsync(new Uri(wsUrl), cts.Token).GetAwaiter().GetResult();



                    string[] payloads = new string[]



                    {



                        "{\"id\":10,\"method\":\"Input.dispatchMouseEvent\",\"params\":{\"type\":\"mouseMoved\",\"x\":" + x + ",\"y\":" + y + ",\"button\":\"none\"}}",



                        "{\"id\":11,\"method\":\"Input.dispatchMouseEvent\",\"params\":{\"type\":\"mousePressed\",\"x\":" + x + ",\"y\":" + y + ",\"button\":\"left\",\"buttons\":1,\"clickCount\":1}}",



                        "{\"id\":12,\"method\":\"Input.dispatchMouseEvent\",\"params\":{\"type\":\"mouseReleased\",\"x\":" + x + ",\"y\":" + y + ",\"button\":\"left\",\"buttons\":0,\"clickCount\":1}}"



                    };



                    byte[] recvBuf = new byte[16384];



                    foreach (string p in payloads)



                    {



                        byte[] sendBytes = Encoding.UTF8.GetBytes(p);



                        ws.SendAsync(new ArraySegment<byte>(sendBytes), WebSocketMessageType.Text, true, cts.Token).GetAwaiter().GetResult();



                        Thread.Sleep(65);



                        ws.ReceiveAsync(new ArraySegment<byte>(recvBuf), cts.Token).GetAwaiter().GetResult();



                    }



                    return true;



                }



            }



            catch



            {



                return false;



            }



        }



        public static bool SendCdpEnterKey(string wsUrl, int timeoutMs)



        {



            try



            {



                using (ClientWebSocket ws = new ClientWebSocket())



                using (CancellationTokenSource cts = new CancellationTokenSource(timeoutMs))



                {



                    ws.ConnectAsync(new Uri(wsUrl), cts.Token).GetAwaiter().GetResult();



                    string[] payloads = new string[]



                    {



                        "{\"id\":20,\"method\":\"Input.dispatchKeyEvent\",\"params\":{\"type\":\"rawKeyDown\",\"windowsVirtualKeyCode\":13,\"nativeVirtualKeyCode\":13,\"key\":\"Enter\",\"code\":\"Enter\",\"text\":\"\\r\",\"unmodifiedText\":\"\\r\"}}",



                        "{\"id\":21,\"method\":\"Input.dispatchKeyEvent\",\"params\":{\"type\":\"char\",\"windowsVirtualKeyCode\":13,\"nativeVirtualKeyCode\":13,\"key\":\"Enter\",\"code\":\"Enter\",\"text\":\"\\r\",\"unmodifiedText\":\"\\r\"}}",



                        "{\"id\":22,\"method\":\"Input.dispatchKeyEvent\",\"params\":{\"type\":\"keyUp\",\"windowsVirtualKeyCode\":13,\"nativeVirtualKeyCode\":13,\"key\":\"Enter\",\"code\":\"Enter\"}}"



                    };



                    byte[] recvBuf = new byte[16384];



                    foreach (string p in payloads)



                    {



                        byte[] sendBytes = Encoding.UTF8.GetBytes(p);



                        ws.SendAsync(new ArraySegment<byte>(sendBytes), WebSocketMessageType.Text, true, cts.Token).GetAwaiter().GetResult();



                        Thread.Sleep(45);



                        ws.ReceiveAsync(new ArraySegment<byte>(recvBuf), cts.Token).GetAwaiter().GetResult();



                    }



                    return true;



                }



            }



            catch



            {



                return false;



            }



        }



        public static bool SendCdpBrowserClose(string wsUrl, int timeoutMs)



        {



            try



            {



                using (ClientWebSocket ws = new ClientWebSocket())



                using (CancellationTokenSource cts = new CancellationTokenSource(timeoutMs))



                {



                    ws.ConnectAsync(new Uri(wsUrl), cts.Token).GetAwaiter().GetResult();



                    string payload = "{\"id\":1,\"method\":\"Browser.close\"}";



                    byte[] sendBytes = Encoding.UTF8.GetBytes(payload);



                    ws.SendAsync(new ArraySegment<byte>(sendBytes), WebSocketMessageType.Text, true, cts.Token).GetAwaiter().GetResult();



                    byte[] recvBuf = new byte[4096];



                    try



                    {



                        ws.ReceiveAsync(new ArraySegment<byte>(recvBuf), cts.Token).GetAwaiter().GetResult();



                    }



                    catch { }



                    return true;



                }



            }



            catch



            {



                return false;



            }



        }



        // ====================================================================



        // 本地 LanguageServer Connect-RPC 客户端 (支持自签名 HTTPS 与 HTTP 双通道)



        // 调用 /exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary & GetUserStatus



        // ====================================================================



        public static string PostLocalConnectRpc(string url, string csrfToken, string jsonBody, int timeoutMs)



        {



            try



            {



                ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls12 | SecurityProtocolType.Tls11 | SecurityProtocolType.Tls;



                HttpWebRequest req = (HttpWebRequest)WebRequest.Create(url);



                req.ServerCertificateValidationCallback = delegate(object s, X509Certificate cert, X509Chain chain, SslPolicyErrors err) { return true; };



                req.Method = "POST";



                req.ContentType = "application/json";



                req.Headers["Connect-Protocol-Version"] = "1";



                if (!string.IsNullOrEmpty(csrfToken))



                {



                    req.Headers["x-codeium-csrf-token"] = csrfToken;



                }



                req.Timeout = timeoutMs;



                req.ReadWriteTimeout = timeoutMs;



                byte[] bodyBytes = Encoding.UTF8.GetBytes(string.IsNullOrEmpty(jsonBody) ? "{}" : jsonBody);



                req.ContentLength = bodyBytes.Length;



                using (Stream reqStream = req.GetRequestStream())



                {



                    reqStream.Write(bodyBytes, 0, bodyBytes.Length);



                }



                using (HttpWebResponse resp = (HttpWebResponse)req.GetResponse())



                using (StreamReader sr = new StreamReader(resp.GetResponseStream(), Encoding.UTF8))



                {



                    return ((int)resp.StatusCode).ToString() + "|" + sr.ReadToEnd();



                }



            }



            catch (WebException wex)



            {



                if (wex.Response != null)



                {



                    try



                    {



                        HttpWebResponse errResp = (HttpWebResponse)wex.Response;



                        using (StreamReader sr = new StreamReader(errResp.GetResponseStream(), Encoding.UTF8))



                        {



                            return ((int)errResp.StatusCode).ToString() + "|" + sr.ReadToEnd();



                        }



                    }



                    catch {}



                }



                return "0|" + wex.Message;



            }



            catch (Exception ex)



            {



                return "0|" + ex.Message;



            }



        }



        // ====================================================================



        // 谷歌 Cloud Code 远端配额查询与 OAuth 令牌静默刷新客户端 (查询所有保存槽位的 5h/周 剩余配额)



        // ====================================================================



        private static IWebProxy s_cachedProxy = null;



        private static bool s_proxyChecked = false;



        private static IWebProxy GetEffectiveProxy()



        {



            if (s_proxyChecked) return s_cachedProxy;



            s_proxyChecked = true;



            try



            {



                string envProxy = Environment.GetEnvironmentVariable("HTTPS_PROXY");



                if (string.IsNullOrEmpty(envProxy)) envProxy = Environment.GetEnvironmentVariable("HTTP_PROXY");



                if (!string.IsNullOrEmpty(envProxy) && (envProxy.StartsWith("http://") || envProxy.StartsWith("https://")))



                {



                    s_cachedProxy = new WebProxy(envProxy);



                    return s_cachedProxy;



                }



                IWebProxy sysProxy = WebRequest.GetSystemWebProxy();



                Uri testUri = new Uri("https://daily-cloudcode-pa.googleapis.com");



                if (sysProxy != null && !sysProxy.IsBypassed(testUri))



                {



                    Uri proxyUri = sysProxy.GetProxy(testUri);



                    if (proxyUri != null && proxyUri.Host != testUri.Host)



                    {



                        s_cachedProxy = sysProxy;



                        return s_cachedProxy;



                    }



                }



                int[] commonPorts = new int[] { 7890, 7897, 10809, 10808, 2080, 10802, 8889 };



                foreach (int p in commonPorts)



                {



                    try



                    {



                        using (System.Net.Sockets.TcpClient tcp = new System.Net.Sockets.TcpClient())



                        {



                            IAsyncResult ar = tcp.BeginConnect("127.0.0.1", p, null, null);



                            if (ar.AsyncWaitHandle.WaitOne(30))



                            {



                                tcp.EndConnect(ar);



                                s_cachedProxy = new WebProxy("http://127.0.0.1:" + p);



                                return s_cachedProxy;



                            }



                        }



                    }



                    catch {}



                }



            }



            catch {}



            return null;



        }



        public static string PostCloudQuotaApi(string url, string accessToken, string jsonBody, int timeoutMs)



        {



            try



            {



                ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls12;



                HttpWebRequest req = (HttpWebRequest)WebRequest.Create(url);



                req.ServerCertificateValidationCallback = delegate(object s, X509Certificate cert, X509Chain chain, SslPolicyErrors err) { return true; };



                IWebProxy proxy = GetEffectiveProxy();



                if (proxy != null) req.Proxy = proxy;



                req.Method = "POST";



                req.ContentType = "application/json";



                req.UserAgent = "antigravity";



                req.Headers["Authorization"] = "Bearer " + accessToken;



                req.Timeout = timeoutMs;



                req.ReadWriteTimeout = timeoutMs;



                byte[] bodyBytes = Encoding.UTF8.GetBytes(string.IsNullOrEmpty(jsonBody) ? "{}" : jsonBody);



                req.ContentLength = bodyBytes.Length;



                using (Stream reqStream = req.GetRequestStream())



                {



                    reqStream.Write(bodyBytes, 0, bodyBytes.Length);



                }



                using (HttpWebResponse resp = (HttpWebResponse)req.GetResponse())



                using (StreamReader sr = new StreamReader(resp.GetResponseStream(), Encoding.UTF8))



                {



                    return ((int)resp.StatusCode).ToString() + "|" + sr.ReadToEnd();



                }



            }



            catch (WebException wex)



            {



                if (wex.Response != null)



                {



                    try



                    {



                        HttpWebResponse errResp = (HttpWebResponse)wex.Response;



                        using (StreamReader sr = new StreamReader(errResp.GetResponseStream(), Encoding.UTF8))



                        {



                            return ((int)errResp.StatusCode).ToString() + "|" + sr.ReadToEnd();



                        }



                    }



                    catch {}



                }



                return "0|" + wex.Message;



            }



            catch (Exception ex)



            {



                return "0|" + ex.Message;



            }



        }



        public static string RefreshGoogleAccessToken(string clientId, string clientSecret, string refreshToken, int timeoutMs)



        {



            try



            {



                ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls12;



                HttpWebRequest req = (HttpWebRequest)WebRequest.Create("https://oauth2.googleapis.com/token");



                IWebProxy proxy = GetEffectiveProxy();



                if (proxy != null) req.Proxy = proxy;



                req.Method = "POST";



                req.ContentType = "application/x-www-form-urlencoded";



                req.Timeout = timeoutMs;



                req.ReadWriteTimeout = timeoutMs;



                string form = "client_id=" + Uri.EscapeDataString(clientId)



                            + "&client_secret=" + Uri.EscapeDataString(clientSecret)



                            + "&refresh_token=" + Uri.EscapeDataString(refreshToken)



                            + "&grant_type=refresh_token";



                byte[] bodyBytes = Encoding.UTF8.GetBytes(form);



                req.ContentLength = bodyBytes.Length;



                using (Stream reqStream = req.GetRequestStream())



                {



                    reqStream.Write(bodyBytes, 0, bodyBytes.Length);



                }



                using (HttpWebResponse resp = (HttpWebResponse)req.GetResponse())



                using (StreamReader sr = new StreamReader(resp.GetResponseStream(), Encoding.UTF8))



                {



                    return ((int)resp.StatusCode).ToString() + "|" + sr.ReadToEnd();



                }



            }



            catch (WebException wex)



            {



                if (wex.Response != null)



                {



                    try



                    {



                        HttpWebResponse errResp = (HttpWebResponse)wex.Response;



                        using (StreamReader sr = new StreamReader(errResp.GetResponseStream(), Encoding.UTF8))



                        {



                            return ((int)errResp.StatusCode).ToString() + "|" + sr.ReadToEnd();



                        }



                    }



                    catch {}



                }



                return "0|" + wex.Message;



            }



            catch (Exception ex)



            {



                return "0|" + ex.Message;



            }



        }



    }



}



'@



if (-not ("AntigravityCompliantHelper.NativeVaultV4" -as [type])) {



    $refAssemblies = if ($PSVersionTable.PSEdition -eq "Core") {



        @("System.Security.Cryptography.ProtectedData", "System.Net.WebSockets.Client", "System.Net.WebSockets", "System.Text.RegularExpressions")



    } else {



        @("System.Security", "System.Net.Http", "System")



    }



    try {



        Add-Type -TypeDefinition $CSharpSource -ReferencedAssemblies $refAssemblies -ErrorAction SilentlyContinue



    } catch {}



}



# ============================================================================



# 2. 路径定义与启动自动自愈（修复被 PowerShell ConvertTo-Json 或 BOM 损坏的配置）



# ============================================================================



$CredTarget           = "gemini:antigravity"



$CredUser             = "antigravity"



$GeminiRoot           = Join-Path $env:USERPROFILE ".gemini"



$AgyCliDir            = Join-Path $GeminiRoot "antigravity-cli"



$AgyCliTokenPath      = Join-Path $AgyCliDir "antigravity-oauth-token"



$AgyCliConfigPath     = Join-Path $AgyCliDir "settings.json"



$OAuthCredsPath       = Join-Path $GeminiRoot "oauth_creds.json"



$AccountsJsonPath     = Join-Path $GeminiRoot "google_accounts.json"



$JetskiStandalonePath = Join-Path $GeminiRoot "jetski-standalone-oauth-token"



$LastConvPath         = Join-Path (Join-Path $AgyCliDir "cache") "last_conversations.json"



$AppDataRoaming       = [Environment]::GetFolderPath("ApplicationData")



$AgyAppDataDir        = Join-Path $AppDataRoaming "Antigravity"



$AppStorageJson       = Join-Path $AgyAppDataDir "app_storage.json"



$DevToolsPortFile     = Join-Path $AgyAppDataDir "DevToolsActivePort"



$CdpDefaultPort       = 9339



$HelperRoot           = Join-Path $GeminiRoot "compliant-switcher"



$SlotsDir             = Join-Path $HelperRoot "slots"



$PoolStatePath        = Join-Path $HelperRoot "pool_state.json"



$DaemonPidPath        = Join-Path $HelperRoot "daemon.pid"



$DaemonLogPath        = Join-Path $HelperRoot "daemon.log"



$DaemonStopSignal     = Join-Path $HelperRoot "daemon.stop"



$LastActiveConvFile   = Join-Path $HelperRoot "last_active_conversation.txt"



$ResumeManifestPath   = Join-Path $HelperRoot "manifest.json"



$DaemonHeartbeatPath  = Join-Path $HelperRoot "daemon_heartbeat.json"



$Script:LastActiveConvTitle = ""



$Script:CachedLsQuota = $null



$Script:CachedLsEndpoint     = $null



$Script:CachedMonitoredFiles = @()



$Script:LastFileScanTime     = [DateTime]::MinValue



if (-not (Test-Path $SlotsDir)) {



    New-Item -ItemType Directory -Path $SlotsDir -Force | Out-Null



}



# 启动自检 1：清除残留 UTF-8 BOM



foreach ($targetFile in @($AppStorageJson, $AgyCliTokenPath, $AgyCliConfigPath, $OAuthCredsPath, $AccountsJsonPath, $JetskiStandalonePath, $PoolStatePath)) {



    if (Repair-FileUtf8BomIfPresent -Path $targetFile) {



        Write-Host ("[✓] 已自动剥离文件头部 UTF-8 BOM: {0}" -f $targetFile) -ForegroundColor Green



    }



}



# 启动自检 2：检测 app_storage.json 是否曾被旧版 PowerShell ConvertTo-Json 破坏（4空格缩进导致数组被拆包引发 AGY2 闪退）



if (Test-Path $AppStorageJson) {



    try {



        $rawStorage = Read-Utf8StripBom -Path $AppStorageJson



        if ($rawStorage -and ($rawStorage.StartsWith("{`r`n    `"") -or $rawStorage.StartsWith("{`n    `""))) {



            $savedEmail = [AntigravityCompliantHelper.NativeVaultV4]::ReadJsonStringFieldRegex($AppStorageJson, "jetski.onboarding.lastLoginUsername")



            if (-not $savedEmail) { $savedEmail = "user@gmail.com" }



            [AntigravityCompliantHelper.NativeVaultV4]::UpdateAppStorageEmailSafely($AppStorageJson, $savedEmail, $true)



            Write-Host "[✓] 检测到 app_storage.json 曾被 PowerShell ConvertTo-Json 改写（会导致 AGY2 闪退），已自动修复为纯净官方格式！" -ForegroundColor Green



        }



    } catch {}



}



# ============================================================================



# 3. 辅助函数：Token 解析、指纹计算、进程脱钩控制



# ============================================================================



function Get-StringFingerprint {



    param([string]$Text)



    if ([string]::IsNullOrWhiteSpace($Text)) { return "none" }



    $sha = [System.Security.Cryptography.SHA256]::Create()



    try {



        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text.Trim())



        $hash = $sha.ComputeHash($bytes)



        $hex = [BitConverter]::ToString($hash).Replace("-", "").ToLowerInvariant()



        return $hex.Substring(0, 8)



    } finally {



        $sha.Dispose()



    }



}



function Decode-JwtEmail {



    param([string]$Jwt)



    if ([string]::IsNullOrWhiteSpace($Jwt)) { return "" }



    try {



        $parts = $Jwt.Trim().Split('.')



        if ($parts.Length -ge 2) {



            $payload = $parts[1]



            while ($payload.Length % 4 -ne 0) { $payload += "=" }



            $payloadBytes = [Convert]::FromBase64String($payload.Replace('-', '+').Replace('_', '/'))



            $jwtJson = [System.Text.Encoding]::UTF8.GetString($payloadBytes)



            $jwtObj = $jwtJson | ConvertFrom-Json



            if ($jwtObj.PSObject.Properties["email"] -and $jwtObj.email) {



                return [string]$jwtObj.email



            }



        }



    } catch {}



    return ""



}



function Parse-CredentialStorePayload {



    param([string]$RawPayload)



    if ([string]::IsNullOrWhiteSpace($RawPayload)) { return $null }



    $text = $RawPayload.Trim()



    if ($text.Length -gt 0 -and [int][char]$text[0] -eq 0xFEFF) {



        $text = $text.Substring(1).Trim()



    }



    if ($text.StartsWith("go-keyring-base64:")) {



        try {



            $b64 = $text.Substring("go-keyring-base64:".Length)



            $text = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64)).Trim()



        } catch {



            return $null



        }



    }



    try {



        $obj = $text | ConvertFrom-Json



        $tokenNode = if ($obj.PSObject.Properties["token"] -and $obj.token) { $obj.token } else { $obj }



        $at = if ($tokenNode.PSObject.Properties["access_token"]) { [string]$tokenNode.access_token } else { "" }



        $rt = if ($tokenNode.PSObject.Properties["refresh_token"]) { [string]$tokenNode.refresh_token } else { "" }



        $idt = if ($tokenNode.PSObject.Properties["id_token"]) { [string]$tokenNode.id_token } else { "" }



        $pidVal = if ($tokenNode.PSObject.Properties["project_id"]) { [string]$tokenNode.project_id } else { "" }



        $expSec = [long]0



        if ($tokenNode.PSObject.Properties["expiry_timestamp"] -and $tokenNode.expiry_timestamp) {



            $expSec = [long]$tokenNode.expiry_timestamp



            if ($expSec -gt 10000000000L) { $expSec = [long]($expSec / 1000) }



        } elseif ($tokenNode.PSObject.Properties["expiry"] -and $tokenNode.expiry) {



            try {



                $dt = [DateTimeOffset]::Parse([string]$tokenNode.expiry)



                $expSec = $dt.ToUnixTimeSeconds()



            } catch {}



        }



        if ($expSec -le 0) {



            $expSec = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 3600



        }



        if ([string]::IsNullOrWhiteSpace($at) -and [string]::IsNullOrWhiteSpace($rt)) {



            return $null



        }



        $email = Decode-JwtEmail -Jwt $idt



        return [PSCustomObject]@{



            accessToken     = $at



            refreshToken    = $rt



            expiryTimestamp = $expSec



            idToken         = $idt



            projectId       = $pidVal



            email           = $email



            fingerprint     = (Get-StringFingerprint -Text $(if ($rt) { $rt } else { $at }))



        }



    } catch {



        return $null



    }



}



function Build-OfficialCredentialPayloadJson {



    param(



        [string]$AccessToken,



        [string]$RefreshToken,



        [long]$ExpiryTimestamp,



        [string]$IdToken = "",



        [string]$ProjectId = ""



    )



    $expSec = if ($ExpiryTimestamp -gt 10000000000L) { [long]($ExpiryTimestamp / 1000) } elseif ($ExpiryTimestamp -gt 0) { $ExpiryTimestamp } else { [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 3600 }



    $isoExpiry = [DateTimeOffset]::FromUnixTimeSeconds($expSec).UtcDateTime.ToString("yyyy-MM-ddTHH:mm:ss.fff000Z")



    $tokenMap = [ordered]@{



        access_token  = $AccessToken



        token_type    = "Bearer"



        refresh_token = $RefreshToken



        expiry        = $isoExpiry



    }



    if (-not [string]::IsNullOrWhiteSpace($IdToken)) {



        $tokenMap["id_token"] = $IdToken



    }



    if (-not [string]::IsNullOrWhiteSpace($ProjectId)) {



        $tokenMap["project_id"] = $ProjectId



    }



    $rootMap = [ordered]@{



        token       = $tokenMap



        auth_method = "consumer"



    }



    return ($rootMap | ConvertTo-Json -Depth 5 -Compress)



}



function Get-AppStorageLoginEmail {



    return [AntigravityCompliantHelper.NativeVaultV4]::ReadJsonStringFieldRegex($AppStorageJson, "jetski.onboarding.lastLoginUsername")



}



function Set-AppStorageLoginEmail {



    param(



        [string]$Email,



        [switch]$ForceCleanReset



    )



    if ([string]::IsNullOrWhiteSpace($Email)) { return }



    try {



        [AntigravityCompliantHelper.NativeVaultV4]::UpdateAppStorageEmailSafely($AppStorageJson, $Email, $ForceCleanReset.IsPresent)



        Write-Host ("    [+] 已无损更新 app_storage.json 登录账号: {0}" -f $Email) -ForegroundColor Cyan



    } catch {



        Write-Host ("    [!] 更新 app_storage.json 失败: {0}" -f $_.Exception.Message) -ForegroundColor Yellow



    }



}



function Test-IsRunningInsideAntigravityTerminal {



    $currPid = $PID



    for ($depth = 0; $depth -lt 10; $depth++) {



        try {



            $cim = Get-CimInstance Win32_Process -Filter "ProcessId = $currPid" -ErrorAction SilentlyContinue



            if (-not $cim) { break }



            if ($cim.Name -match '(?i)^antigravity') {



                return $true



            }



            $parentId = [int]$cim.ParentProcessId



            if ($parentId -le 0 -or $parentId -eq $currPid) { break }



            $currPid = $parentId



        } catch {



            break



        }



    }



    return $false



}



function Get-RunningAntigravityProcesses {



    $all = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {



        $_.ProcessName -match '^(?i)(Antigravity|agy)$'



    })



    return $all



}



function Wait-ForAntigravityUpdaterIfRunning {



    $deadline = (Get-Date).AddSeconds(25)



    $warned = $false



    while ((Get-Date) -lt $deadline) {



        $updaters = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {



            $_.ProcessName -match '^(?i)(Antigravity-x64|Antigravity-arm64|antigravity-updater)$'



        })



        if ($updaters.Count -eq 0) {



            break



        }



        if (-not $warned) {



            Write-Host "    [*] 检测到 AGY2 后台更新安装程序正在运行，等待其完成文件替换以防闪退..." -ForegroundColor Yellow



            $warned = $true



        }



        Start-Sleep -Milliseconds 500



    }



}



function Stop-RunningAntigravityProcesses {



    param([switch]$NonInteractive)



    $running = @(Get-RunningAntigravityProcesses)



    if ($running.Count -eq 0) {



        Write-Host "[✓] 未检测到正在运行的 Antigravity / agy 进程。" -ForegroundColor Green



        return



    }



    Write-Host "[!] 正在平滑退役当前 AGY2 实例以保存会话并切换账号..." -ForegroundColor Yellow



    # 0. 关闭前先通过权威 SQLite WAL 捕获未完成会话并生成 manifest.json



    try {



        Capture-ActiveConversationBeforeClose



    } catch {}



    # 1. 优先通过 CDP Browser.close 权威退出通道（触发 Chromium before-quit，保证 .pb 落盘且安全断开 language_server 管道）



    $cdpClosed = $false



    $portFile = Join-Path $AgyAppDataDir "DevToolsActivePort"



    if (Test-Path $portFile) {



        try {



            $lines = @(Get-Content $portFile -ErrorAction SilentlyContinue)



            if ($lines.Count -ge 2 -and $lines[0] -match '^\d+$') {



                $port = $lines[0].Trim()



                $guidPart = $lines[1].Trim()



                $wsBrowserUrl = if ($guidPart.StartsWith("/")) {



                    "ws://127.0.0.1:$port$guidPart"



                } else {



                    "ws://127.0.0.1:$port/devtools/browser/$guidPart"



                }



                Write-Host "    [*] 正在通过 CDP 向 Chromium 内核发送 Browser.close 平滑退役信号..." -ForegroundColor Cyan



                $cdpClosed = [AntigravityCompliantHelper.NativeVaultV4]::SendCdpBrowserClose($wsBrowserUrl, 3000)



            }



        } catch {}



    }



    # 1.1 若 DevToolsActivePort 未奏效，遍历活跃调试端口通过 /json/version 获取浏览器级 WebSocket



    if (-not $cdpClosed) {



        $portsToProbe = Get-AvailableCdpPorts



        foreach ($p in $portsToProbe) {



            try {



                $wc = New-Object System.Net.WebClient



                $wc.Encoding = [System.Text.Encoding]::UTF8



                $vJson = $wc.DownloadString("http://127.0.0.1:$p/json/version")



                $vObj = $vJson | ConvertFrom-Json



                if ($vObj -and $vObj.PSObject.Properties["webSocketDebuggerUrl"] -and $vObj.webSocketDebuggerUrl) {



                    Write-Host ("    [*] 正在通过活跃端口 {0} 向 Chromium 发送 Browser.close 平滑退役信号..." -f $p) -ForegroundColor Cyan



                    $cdpClosed = [AntigravityCompliantHelper.NativeVaultV4]::SendCdpBrowserClose([string]$vObj.webSocketDebuggerUrl, 3000)



                    if ($cdpClosed) { break }



                }



            } catch {}



        }



    }



    # 2. 若 CDP 关闭未执行或未奏效，备选 Win32 WM_CLOSE 优雅请求主窗口关闭



    if (-not $cdpClosed) {



        $agyMainProcs = @($running | Where-Object { $_.ProcessName -match '^(?i)Antigravity$' })



        foreach ($p in $agyMainProcs) {



            try {



                [void][AntigravityCompliantHelper.NativeVaultV4]::RequestGracefulProcessClose($p.Id)



                if ($p.MainWindowHandle -ne 0) {



                    [void]$p.CloseMainWindow()



                }



            } catch {}



        }



    }



    # 3. 轮询等待 Antigravity 宿主进程完全归零（上限 8 秒）



    $graceDeadline = (Get-Date).AddSeconds(8)



    while ((Get-Date) -lt $graceDeadline) {



        $stillAlive = @(Get-RunningAntigravityProcesses)



        if ($stillAlive.Count -eq 0) {



            break



        }



        Start-Sleep -Milliseconds 300



    }



    # 4. 8 秒超时后仅强杀残留的 Antigravity 宿主（严禁杀 language_server.* 子进程）



    $survivors = @(Get-RunningAntigravityProcesses)



    if ($survivors.Count -gt 0) {



        Write-Host "    [!] 进程未在 8 秒内完全退出，仅强制结束残留 Antigravity/agy 实例 (保护 language_server)..." -ForegroundColor Yellow



        foreach ($p in $survivors) {



            try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch {}



        }



        Start-Sleep -Milliseconds 400



    }



    # 5. 检查并等待后台更新程序（若存在）



    Wait-ForAntigravityUpdaterIfRunning



    # 6. 非阻塞排他写入模式探测 lockfile，验证操作系统内核互斥锁已完全释放（杜绝拉起秒退）



    $lockPath = Join-Path $AgyAppDataDir "lockfile"



    if (Test-Path $lockPath) {



        $lockReleased = $false



        $lockDeadline = (Get-Date).AddSeconds(5)



        while ((Get-Date) -lt $lockDeadline) {



            try {



                $fs = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)



                if ($fs) {



                    $fs.Close()



                    $fs.Dispose()



                    $lockReleased = $true



                    break



                }



            } catch [System.IO.IOException] {



                Start-Sleep -Milliseconds 250



            } catch {



                $lockReleased = $true



                break



            }



        }



        if ($lockReleased) {



            Remove-Item $lockPath -Force -ErrorAction SilentlyContinue



            Write-Host "    [✓] 已通过排他写入句柄探针验证 lockfile 内核锁彻底释放，已安全清理。" -ForegroundColor Green



        } else {



            Write-Host "    [!] 提示: lockfile 句柄已超时，尝试安全清理..." -ForegroundColor Yellow



            Remove-Item $lockPath -Force -ErrorAction SilentlyContinue



        }



    }



    # 7. 清理 DevToolsActivePort 与 Singleton 锁文件



    if (Test-Path $portFile) {



        Remove-Item $portFile -Force -ErrorAction SilentlyContinue



    }



    foreach ($lockName in @("SingletonLock", "SingletonCookie", "SingletonSocket")) {



        $lPath = Join-Path $AgyAppDataDir $lockName



        if (Test-Path $lPath) {



            Remove-Item $lPath -Force -ErrorAction SilentlyContinue



        }



    }



    Start-Sleep -Milliseconds 400



    Write-Host "[✓] 旧客户端实例已完全退出，内核锁已完全释放，会话已落盘。" -ForegroundColor Green



}



function Get-AntigravityExePath {



    $running = Get-Process -Name "Antigravity" -ErrorAction SilentlyContinue | Where-Object { $_.Path } | Select-Object -First 1



    if ($running -and (Test-Path $running.Path)) {



        return $running.Path



    }



    $candidates = @(



        (Join-Path $env:LOCALAPPDATA "Programs\antigravity\Antigravity.exe"),



        (Join-Path $env:LOCALAPPDATA "Programs\Antigravity\Antigravity.exe"),



        (Join-Path $env:ProgramFiles "Antigravity\Antigravity.exe")



    )



    foreach ($c in $candidates) {



        if (Test-Path $c) { return $c }



    }



    $desktopLnk = Join-Path ([Environment]::GetFolderPath("Desktop")) "Antigravity.lnk"



    if (Test-Path $desktopLnk) {



        try {



            $sh = New-Object -ComObject WScript.Shell



            $target = $sh.CreateShortcut($desktopLnk).TargetPath



            if (Test-Path $target) { return $target }



        } catch {}



    }



    return $null



}



# ============================================================================



# 3.05 无人值守【原会话精准恢复】引擎 (先定位点击左侧原会话 -> 验证进入原会话 -> 单次注入续接指令)



# ============================================================================



function Get-AvailableCdpPorts {



    $portsToTry = @($CdpDefaultPort)



    if (Test-Path $DevToolsPortFile) {



        try {



            $lines = @(Get-Content $DevToolsPortFile -ErrorAction SilentlyContinue)



            if ($lines.Count -ge 1 -and $lines[0] -match '^\d+$') {



                $p = [int]$lines[0]



                if ($portsToTry -notcontains $p) { $portsToTry = @($p) + $portsToTry }



            }



        } catch {}



    }



    return $portsToTry



}



function Extract-CdpStringValue {



    param([string]$RawCdpResponse)



    if ([string]::IsNullOrWhiteSpace($RawCdpResponse)) { return "" }



    try {



        $obj = $RawCdpResponse | ConvertFrom-Json -ErrorAction Stop



        if ($obj.PSObject.Properties["result"] -and $obj.result.PSObject.Properties["result"] -and $obj.result.result.PSObject.Properties["value"]) {



            return [string]$obj.result.result.value



        }



    } catch {



        if ($RawCdpResponse -match '"value"\s*:\s*"([^"]*)"') {



            return $Matches[1]



        }



    }



    return ""



}



function ConvertTo-JsStringArrayLiteral {



    param([AllowEmptyCollection()][string[]]$Items = @())



    if (-not $Items -or $Items.Count -eq 0) {



        return "[]"



    }



    $parts = [System.Collections.Generic.List[string]]::new()



    foreach ($it in $Items) {



        if (-not [string]::IsNullOrWhiteSpace($it)) {



            $esc = ([string]$it).Replace('\', '\\').Replace('"', '\"').Replace("`r", "").Replace("`n", " ").Trim()



            if ($esc.Length -gt 0) {



                $parts.Add('"' + $esc + '"')



            }



        }



    }



    if ($parts.Count -eq 0) { return "[]" }



    return "[" + ($parts.ToArray() -join ",") + "]"



}



function Split-PipeDelimitedTitles {



    param([string]$RawText)



    $result = [System.Collections.Generic.List[string]]::new()



    if ([string]::IsNullOrWhiteSpace($RawText)) {



        return ,$result.ToArray()



    }



    $segments = @($RawText -split '\s*\|\|\s*')



    foreach ($seg in $segments) {



        if (-not [string]::IsNullOrWhiteSpace($seg)) {



            $clean = ([string]$seg).Trim()



            # 过滤掉曾因旧版 PS 5.1 数组 bug 污染的方括号或空串



            $clean = ($clean -replace '^\[+|\]+$', '').Trim()



            if ($clean.Length -ge 2 -and $clean -notmatch '^(?i)(Resume Interrupted Task|New Conversation|请继续执行)' -and (-not $result.Contains($clean))) {



                $result.Add($clean)



            }



        }



    }



    return ,$result.ToArray()



}



function Get-PythonExecutablePath {



    $cands = [System.Collections.Generic.List[string]]::new()



    foreach ($cmd in @("python", "python3", "py")) {



        $p = Get-Command $cmd -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue



        if ($p) { $cands.Add($p) }



    }



    $dynLocal = @(Get-ChildItem -Path "$env:LOCALAPPDATA\Programs\Python" -Filter "python.exe" -Recurse -Depth 2 -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })



    foreach ($d in $dynLocal) { $cands.Add($d) }



    $dynProg = @(Get-ChildItem -Path "$env:ProgramFiles\Python*" -Filter "python.exe" -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })



    foreach ($d in $dynProg) { $cands.Add($d) }



    foreach ($c in $cands) {



        if ($c -and (Test-Path $c)) {



            return $c



        }



    }



    return "python"



}



function Capture-ActiveConversationBeforeClose {



    $Script:LastActiveConvTitle = ""



    $Script:LastActiveManifest = $null



    if (Test-Path $LastActiveConvFile) {



        Remove-Item $LastActiveConvFile -Force -ErrorAction SilentlyContinue



    }



    if (Test-Path $ResumeManifestPath) {



        Remove-Item $ResumeManifestPath -Force -ErrorAction SilentlyContinue



    }



    Write-Host "    [*] 正在通过 SQLite WAL 只读模式执行递归 CTE 提取活跃根会话..." -ForegroundColor Cyan



    $dbPath = Join-Path $GeminiRoot "antigravity\conversation_summaries.db"



    if (-not (Test-Path $dbPath)) {



        Write-Host "    [!] 未找到 conversation_summaries.db 数据库文件。" -ForegroundColor Yellow



        return ""



    }



    $pyCode = @'



import sqlite3, os, json, sys, datetime



db_path = sys.argv[1].replace('\\', '/') if len(sys.argv) > 1 else os.path.expanduser('~/.gemini/antigravity/conversation_summaries.db').replace('\\', '/')



if not os.path.exists(db_path):



    print(json.dumps({"primary": None, "secondary": [], "all": []}))



    sys.exit(0)



def to_int_safe(val):



    if isinstance(val, (int, float)):



        return int(val)



    if isinstance(val, str):



        val = val.strip().lower()



        if val in ('true', '1', 't'):



            return 1



        return 0



    return 1 if bool(val) else 0



uri_path = f"file:{db_path}?mode=ro"



try:



    conn = sqlite3.connect(uri_path, uri=True)



    cur = conn.cursor()



    sql_active = """



    WITH RECURSIVE active_tree(root_id, current_id, depth) AS (



        SELECT 



            CASE WHEN parent_conversation_id = '' OR parent_conversation_id IS NULL 



                 THEN conversation_id ELSE parent_conversation_id END,



            conversation_id, 0



        FROM conversation_summaries



        WHERE killed = 0 AND (not_fully_idle != 0 OR status LIKE '%RUNNING%')



        UNION ALL



        SELECT 



            CASE WHEN p.parent_conversation_id = '' OR p.parent_conversation_id IS NULL 



                 THEN p.conversation_id ELSE p.parent_conversation_id END,



            p.conversation_id, at.depth + 1



        FROM conversation_summaries p



        JOIN active_tree at ON p.conversation_id = at.root_id



        WHERE at.root_id != '' AND at.root_id IS NOT NULL 



          AND p.parent_conversation_id != '' AND p.parent_conversation_id IS NOT NULL



          AND at.depth < 20



    )



    SELECT DISTINCT c.conversation_id, c.title, c.status, c.not_fully_idle, c.project_id, c.last_modified_time



    FROM conversation_summaries c



    JOIN active_tree at ON c.conversation_id = at.root_id



    WHERE (c.parent_conversation_id = '' OR c.parent_conversation_id IS NULL)



    ORDER BY c.last_modified_time DESC;



    """



    cur.execute(sql_active)



    rows = cur.fetchall()



    if not rows:



        sql_fallback = """



        SELECT conversation_id, title, status, not_fully_idle, project_id, last_modified_time



        FROM conversation_summaries



        WHERE killed = 0 AND (parent_conversation_id = '' OR parent_conversation_id IS NULL)



        ORDER BY last_modified_time DESC



        LIMIT 1;



        """



        cur.execute(sql_fallback)



        rows = cur.fetchall()



    items = []



    for r in rows:



        items.append({



            "conversation_id": r[0],



            "title": r[1] or "",



            "status": r[2] or "",



            "not_fully_idle": to_int_safe(r[3]),



            "project_id": r[4] or "default-cli-project",



            "last_modified_time": str(r[5] or "")



        })



    primary = items[0] if items else None



    secondary = items[1:] if len(items) > 1 else []



    res = {



        "captured_at": datetime.datetime.utcnow().isoformat() + "Z",



        "primary": primary,



        "secondary": secondary,



        "all": items



    }



    print(json.dumps(res, ensure_ascii=False))



except Exception as e:



    print(json.dumps({"error": str(e), "primary": None, "secondary": [], "all": []}))



'@



    $manifestJson = ""



    try {



        $pyExe = Get-PythonExecutablePath



        $psi = New-Object System.Diagnostics.ProcessStartInfo



        $psi.FileName = $pyExe



        $psi.Arguments = "- `"$dbPath`""



        $psi.RedirectStandardInput = $true



        $psi.RedirectStandardOutput = $true



        $psi.RedirectStandardError = $true



        $psi.UseShellExecute = $false



        $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8



        $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8



        $psi.CreateNoWindow = $true



        $proc = [System.Diagnostics.Process]::Start($psi)



        $stderrTask = $proc.StandardError.ReadToEndAsync()



        $sw = New-Object System.IO.StreamWriter($proc.StandardInput.BaseStream, (New-Object System.Text.UTF8Encoding($false)))



        $sw.Write($pyCode)



        $sw.Flush()



        $sw.Close()



        $manifestJson = $proc.StandardOutput.ReadToEnd()



        [void]$proc.WaitForExit(5000)



        $null = $stderrTask.GetAwaiter().GetResult()



    } catch {



        try {



            $pyExe = Get-PythonExecutablePath



            $manifestJson = $pyCode | & $pyExe - "$dbPath"



        } catch {}



    }



    if ([string]::IsNullOrWhiteSpace($manifestJson)) {



        Write-Host "    [!] SQLite 活跃会话捕获未返回数据。" -ForegroundColor Yellow



        return ""



    }



    $manifest = $null



    try {



        $manifest = $manifestJson | ConvertFrom-Json



    } catch {}



    if (-not $manifest) {



        Write-Host "    [!] 解析会话 manifest JSON 失败。" -ForegroundColor Yellow



        return ""



    }



    $Script:LastActiveManifest = $manifest



    if (-not (Test-Path $HelperRoot)) {



        New-Item -ItemType Directory -Path $HelperRoot -Force | Out-Null



    }



    Write-Utf8NoBom -Path $ResumeManifestPath -Content ($manifest | ConvertTo-Json -Depth 6)



    $allTitles = @()



    if ($manifest.all) {



        foreach ($item in $manifest.all) {



            if ($item.title -and (-not $allTitles.Contains($item.title))) {



                $allTitles += $item.title



            }



        }



    }



    if ($allTitles.Count -gt 0) {



        $joinedTitles = $allTitles -join " || "



        $Script:LastActiveConvTitle = $joinedTitles



        Write-Utf8NoBom -Path $LastActiveConvFile -Content $joinedTitles



        Write-Host ("    [✓] 已权威锁定切号前活跃根会话 (共 {0} 个) : {1}" -f $allTitles.Count, (($allTitles | ForEach-Object { "[$_]" }) -join ", ")) -ForegroundColor Green



        if ($manifest.primary) {



            Write-Host ("        - Primary 主会话: [{0}] (ID: {1}, Project: {2})" -f $manifest.primary.title, $manifest.primary.conversation_id, $manifest.primary.project_id) -ForegroundColor Cyan



        }



        if ($manifest.secondary -and @($manifest.secondary).Count -gt 0) {



            Write-Host ("        - Secondary 次要队列: 共 {0} 个待命会话" -f @($manifest.secondary).Count) -ForegroundColor DarkCyan



        }



        return $joinedTitles



    } else {



        Write-Host "    [~] 权威数据库检测：当前无正在生成或未空闲的根会话。" -ForegroundColor Gray



        return ""



    }



}



function Get-LatestConversationContextInfo {



    $brainRoot   = Join-Path $GeminiRoot "antigravity\brain"



    $convRoot    = Join-Path $GeminiRoot "antigravity\conversations"



    $ideConvRoot = Join-Path $GeminiRoot "antigravity-ide\conversations"



    $annotRoot1  = Join-Path $GeminiRoot "antigravity\annotations"



    $annotRoot2  = Join-Path $GeminiRoot "antigravity-cli\annotations"



    $latestConvId   = $null



    $projectId      = "default-cli-project"



    $latestTime     = [DateTime]::MinValue



    $latestBrainDir = $null



    $foundArtifacts = @()



    $recentConvIds  = [System.Collections.Generic.List[string]]::new()



    $manifestObj    = $Script:LastActiveManifest



    # 1. 优先从权威 manifest.json 读取



    if (-not $manifestObj -and (Test-Path $ResumeManifestPath)) {



        try {



            $mItem = Get-Item $ResumeManifestPath -ErrorAction SilentlyContinue



            if ($mItem -and $mItem.LastWriteTime -gt (Get-Date).AddMinutes(-30)) {



                $rawManifest = Read-Utf8StripBom -Path $ResumeManifestPath



                $manifestObj = $rawManifest | ConvertFrom-Json



                $Script:LastActiveManifest = $manifestObj



            }



        } catch {}



    }



    $savedTitle = $Script:LastActiveConvTitle



    if ($manifestObj -and $manifestObj.primary) {



        $latestConvId = [string]$manifestObj.primary.conversation_id



        if ($manifestObj.primary.project_id) {



            $projectId = [string]$manifestObj.primary.project_id



        }



        if ([string]::IsNullOrWhiteSpace($savedTitle) -and $manifestObj.primary.title) {



            $savedTitle = [string]$manifestObj.primary.title



        }



    }



    # 2. 兜底扫描本地文件系统



    if (-not $latestConvId) {



        if (Test-Path $convRoot) {



            $dbFiles = @(Get-ChildItem -Path $convRoot -Filter "*.db" -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne "conversation_summaries.db" } | Sort-Object LastWriteTime -Descending)



            if ($dbFiles.Count -gt 0) {



                $latestConvId = [System.IO.Path]::GetFileNameWithoutExtension($dbFiles[0].Name)



                $latestTime   = $dbFiles[0].LastWriteTime



                foreach ($df in $dbFiles) {



                    if ($df.LastWriteTime -gt (Get-Date).AddMinutes(-15)) {



                        $cid = [System.IO.Path]::GetFileNameWithoutExtension($df.Name)



                        if (-not $recentConvIds.Contains($cid)) { $recentConvIds.Add($cid) }



                    }



                }



            }



        }



    }



    if ($latestConvId -and (Test-Path $brainRoot)) {



        $candidateBrain = Join-Path $brainRoot $latestConvId



        if (Test-Path $candidateBrain) {



            $latestBrainDir = $candidateBrain



            $mdFiles = @(Get-ChildItem -Path $candidateBrain -Filter "*.md" -File -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })



            $foundArtifacts = $mdFiles



        }



    }



    if ([string]::IsNullOrWhiteSpace($savedTitle) -and (Test-Path $LastActiveConvFile)) {



        try {



            $fileItem = Get-Item $LastActiveConvFile -ErrorAction SilentlyContinue



            if ($fileItem -and $fileItem.LastWriteTime -gt (Get-Date).AddMinutes(-30)) {



                $t = (Read-Utf8StripBom -Path $LastActiveConvFile).Trim()



                $validArr = Split-PipeDelimitedTitles -RawText $t



                if ($validArr.Count -gt 0) {



                    $savedTitle = ($validArr -join " || ")



                }



            }



        } catch {}



    }



    $recentActiveCount = if ($manifestObj -and $manifestObj.all) {



        @($manifestObj.all).Count



    } else {



        [Math]::Max(1, $recentConvIds.Count)



    }



    $resumePrompt = "请继续执行刚才被限额打断的未完成任务，直接接着上一步继续推进。"



    try { Set-Clipboard -Value $resumePrompt -ErrorAction SilentlyContinue } catch {}



    return [PSCustomObject]@{



        ConversationId    = $latestConvId



        ProjectId         = $projectId



        RecentActiveCount = [Math]::Max(1, $recentActiveCount)



        ConversationTitle = $savedTitle



        LastWriteTime     = $latestTime



        BrainDir          = $latestBrainDir



        Artifacts         = $foundArtifacts



        ResumePrompt      = $resumePrompt



        Manifest          = $manifestObj



    }



}



function Invoke-UnattendedConversationResume {



    param(



        [string]$ResumePromptText = "",



        [string]$TargetConversationId = "",



        [string]$TargetProjectId = "",



        [string]$TargetConversationTitle = ""



    )



    $ctx = Get-LatestConversationContextInfo



    if ([string]::IsNullOrWhiteSpace($ResumePromptText)) {



        $ResumePromptText = $ctx.ResumePrompt



    }



    if ([string]::IsNullOrWhiteSpace($TargetConversationId) -and $ctx.ConversationId) {



        $TargetConversationId = [string]$ctx.ConversationId



    }



    if ([string]::IsNullOrWhiteSpace($TargetConversationTitle)) {



        $TargetConversationTitle = [string]$ctx.ConversationTitle



    }



    Write-Host "    [*] 正在执行【Zero-CDP 官方原生 LanguageServer 协议级续接与人机激活】..." -ForegroundColor Cyan



    if ($TargetConversationId) {



        Write-Host ("    [*] 目标 Primary 会话: [{0}] (ID: {1})" -f $TargetConversationTitle, $TargetConversationId) -ForegroundColor Gray



    }



    # ========================================================================



    # 步骤 1：剪贴板注入与 Win32 原生窗口激活 (人机感知通道)



    # ========================================================================



    $safePrompt = if ($ResumePromptText) { $ResumePromptText.Trim() } else { "请继续执行刚才被限额打断的未完成任务，直接接着上一步继续推进。" }



    try {



        Set-Clipboard -Value $safePrompt -ErrorAction SilentlyContinue



    } catch {}



    # Win32 激活并置顶 Antigravity 主窗口



    try {



        $procs = @(Get-RunningAntigravityProcesses)



        foreach ($p in $procs) {



            if ($p.MainWindowHandle -ne 0) {



                [void][AntigravityCompliantHelper.NativeVaultV4]::ShowWindow($p.MainWindowHandle, 1)



                [void][AntigravityCompliantHelper.NativeVaultV4]::SetForegroundWindow($p.MainWindowHandle)



                break



            }



        }



    } catch {}



    # ========================================================================



    # 步骤 2：毫秒级通过本地 LanguageServer Connect-RPC 官方协议注入续接指令 (零CDP、零DOM依赖)



    # ========================================================================



    $lsSuccess = $false



    $targetConvId = if ($TargetConversationId) { $TargetConversationId.Trim() } else { "" }



    if ($targetConvId) {



        Write-Host "    [*] 正在探测本地已连接的 LanguageServer Connect-RPC 接口..." -ForegroundColor Gray



        $lsQuota = Get-LocalLanguageServerQuota



        $endpoint = $Script:CachedLsEndpoint



        if ($endpoint -and $endpoint.BaseUrl -and $endpoint.Csrf) {



            $baseUrl = [string]$endpoint.BaseUrl



            $csrf = [string]$endpoint.Csrf



            # 1. 动态获取当前客户端可用模型与官方权威配置



            $targetModel = "MODEL_PLACEHOLDER_M320" # 默认 fallback



            $modelDataResp = [AntigravityCompliantHelper.NativeVaultV4]::PostLocalConnectRpc("$baseUrl/GetCascadeModelConfigData", $csrf, "{}", 2000)



            if ($modelDataResp -match '^200\|(.+)$') {



                try {



                    $mData = $Matches[1] | ConvertFrom-Json



                    if ($mData.defaultOverrideModelConfig -and $mData.defaultOverrideModelConfig.modelOrAlias -and $mData.defaultOverrideModelConfig.modelOrAlias.model) {



                        $targetModel = [string]$mData.defaultOverrideModelConfig.modelOrAlias.model



                    } elseif ($mData.clientModelConfigs -and $mData.clientModelConfigs.Count -gt 0) {



                        $targetModel = [string]$mData.clientModelConfigs[0].modelOrAlias.model



                    }



                } catch {}



            }



            # 2. 调用官方 GetResolvedCascadeConfig 生成完整环境配置 (包含 planModel 与完整工具链)



            $resolvePayload = @"



{



    "overrideConfig": {



        "plannerConfig": {



            "planModel": "$targetModel"



        }



    }



}



"@



            $resolvedConfigJson = $null



            $resConfigResp = [AntigravityCompliantHelper.NativeVaultV4]::PostLocalConnectRpc("$baseUrl/GetResolvedCascadeConfig", $csrf, $resolvePayload, 3000)



            if ($resConfigResp -match '^200\|(.+)$') {



                try {



                    $resObj = $Matches[1] | ConvertFrom-Json



                    if ($resObj.cascadeConfig) {



                        $resolvedConfigJson = ($resObj.cascadeConfig | ConvertTo-Json -Depth 20 -Compress)



                    }



                } catch {}



            }



            # 3. 组装官方完整 SendUserCascadeMessage 载荷 (补齐 cascadeConfig 与 customAgentSpec 杜绝 plan model not specified 报错)



            $cleanPrompt = $safePrompt.Replace('\', '\\').Replace('"', '\"').Replace("`r", "").Replace("`n", "\n")



            $agentSpecJson = '{"builtinAgent":{"defaultAgent":{"isGoogle":false,"isInteractive":true,"surface":"AGENT_SURFACE_HUB"}}}'



            $configField = if ($resolvedConfigJson) { "`"cascadeConfig`": $resolvedConfigJson," } else { "" }



            $rpcPayload = @"



{



    "cascadeId": "$targetConvId",



    "items": [



        {



            "text": "$cleanPrompt"



        }



    ],



    $configField



    "customAgentSpec": $agentSpecJson



}



"@



            Write-Host ("    [*] 正在通过 LanguageServer RPC (SendUserCascadeMessage) 注入模型配置 ({0}) 并唤醒会话 [{1}]..." -f $targetModel, $targetConvId) -ForegroundColor Gray



            $sendResp = [AntigravityCompliantHelper.NativeVaultV4]::PostLocalConnectRpc("$baseUrl/SendUserCascadeMessage", $csrf, $rpcPayload, 5000)



            if ($sendResp -match '^200\|') {



                Start-Sleep -Milliseconds 600



                $lsSuccess = $true



                Write-Host ("    [✓] 已通过 LanguageServer 官方原生 RPC 成功将续接指令与完整模型环境注入推演核心，模型已正常恢复生成！") -ForegroundColor Green



            } elseif ($sendResp -match 'trajectory not found') {



                Write-Host ("    [~] 该会话 Trajectory 正在由客户端加载，已配置剪贴板，点开原会话按 Ctrl+V 即可续接。") -ForegroundColor Yellow



            } else {



                Write-Host ("    [~] RPC 响应状态: {0}" -f $sendResp) -ForegroundColor Gray



            }



        }



    }



    if (-not $lsSuccess) {



        Write-Host "    [✓] 已将原会话续接指令复制至剪贴板，客户端已激活置顶，点开原会话后按 Ctrl+V 回车即可瞬间继续。" -ForegroundColor Green



    }



    # 触发桌面气泡通知



    Send-DesktopNotification -Title "Antigravity 账号已切换" -Message "已切换至新账号，原会话续接指令已就绪。模型已直接启动生成！"



}



function Start-DetachedAntigravityProcess {



    param(



        [string]$ExePath,



        [string]$Arguments = ""



    )



    $workDir = Split-Path -Parent $ExePath



    # 优先使用 WMI Win32_Process.Create（父进程直接归属系统 WmiPrvSE.exe，100% 与当前 .bat 控制台隔离，按 Ctrl+C 绝不退出！）



    try {



        $cmdLine = if ([string]::IsNullOrWhiteSpace($Arguments)) {



            "`"$ExePath`""



        } else {



            "`"$ExePath`" $Arguments"



        }



        $wmiRes = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{



            CommandLine      = $cmdLine



            CurrentDirectory = $workDir



        } -ErrorAction Stop



        if ($wmiRes -and $wmiRes.ReturnValue -eq 0 -and $wmiRes.ProcessId -gt 0) {



            return [int]$wmiRes.ProcessId



        }



    } catch {}



    # 备选：使用 Win32 CreateProcessW (DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP | CREATE_BREAKAWAY_FROM_JOB)



    $pidCreated = [AntigravityCompliantHelper.NativeVaultV4]::LaunchFullyDetachedGui($ExePath, $Arguments, $workDir)



    if ($pidCreated -gt 0) {



        return $pidCreated



    }



    # 兜底：通过 Explorer Shell COM 接口由 explorer.exe 托管启动



    $shellApp = New-Object -ComObject Shell.Application



    $shellApp.ShellExecute($ExePath, $Arguments, $workDir, "open", 1)



    Start-Sleep -Milliseconds 800



    $p = Get-Process -Name "Antigravity" -ErrorAction SilentlyContinue | Select-Object -First 1



    return $(if ($p) { $p.Id } else { 0 })



}



function Restart-AntigravityApp {



    param(



        [string]$TargetEmail = "",



        [switch]$AutoResume = $true



    )



    $exePath = Get-AntigravityExePath



    if (-not $exePath) {



        Write-Host "[!] 未找到 Antigravity.exe 路径，请手动打开 Antigravity 客户端。" -ForegroundColor Yellow



        return



    }



    Wait-ForAntigravityUpdaterIfRunning



    Write-Host "[*] 正在以完全独立进程树启动 Antigravity 2.0 (与当前控制台隔离，按 Ctrl+C 不会退出)..." -ForegroundColor Cyan



    try {



        $launchedPid = Start-DetachedAntigravityProcess -ExePath $exePath -Arguments "--remote-debugging-port=$CdpDefaultPort"



        Start-Sleep -Milliseconds 2500



        # 闪退自愈检测 (Crash Guard)：如果启动 2.5 秒后进程消失，说明 app_storage.json 内有旧损坏字段，立即重置为纯净最小配置并重拉！



        $alive = @(Get-RunningAntigravityProcesses)



        if ($alive.Count -eq 0) {



            Write-Host "[!] 检测到 AGY2 启动后闪退，正在自动重置净化 app_storage.json 并重新拉起..." -ForegroundColor Yellow



            $emailToKeep = if ($TargetEmail) { $TargetEmail } else { Get-AppStorageLoginEmail }



            if (-not $emailToKeep) { $emailToKeep = "user@gmail.com" }



            [AntigravityCompliantHelper.NativeVaultV4]::UpdateAppStorageEmailSafely($AppStorageJson, $emailToKeep, $true)



            Wait-ForAntigravityUpdaterIfRunning



            $launchedPid = Start-DetachedAntigravityProcess -ExePath $exePath -Arguments "--remote-debugging-port=$CdpDefaultPort"



            Start-Sleep -Milliseconds 2500



        }



        Write-Host "[✓] Antigravity 2.0 已在独立系统会话中稳定运行。" -ForegroundColor Green



        $ctx = Get-LatestConversationContextInfo



        if ($ctx.ConversationId) {



            Write-Host ("    [+] 最近活跃本地会话 ID : {0}" -f $ctx.ConversationId) -ForegroundColor Gray



        }



        if ($AutoResume) {



            Invoke-UnattendedConversationResume -ResumePromptText $ctx.ResumePrompt -TargetConversationId $ctx.ConversationId -TargetProjectId $ctx.ProjectId -TargetConversationTitle $ctx.ConversationTitle



        }



    } catch {



        Write-Host ("[!] 拉起 Antigravity 桌面端失败: {0}" -f $_.Exception.Message) -ForegroundColor Red



    }



}



function Show-TrayBalloonNotification {



    param([string]$Title = "Antigravity 自动切号助手", [string]$Text = "", [string]$Message = "", [int]$TimeoutMs = 3500)



    $msg = if ($Message) { $Message } else { $Text }



    Send-DesktopNotification -Title $Title -Message $msg



}



function Send-DesktopNotification {



    param(



        [string]$Title = "Antigravity 自动切号助手",



        [string]$Message = ""



    )



    try {



        if ($Script:TrayIconObj -and $Script:TrayIconObj.Visible) {



            $Script:TrayIconObj.ShowBalloonTip(4000, $Title, $Message, [System.Windows.Forms.ToolTipIcon]::Info)



            return



        }



        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue



        $notify = New-Object System.Windows.Forms.NotifyIcon



        $notify.Icon = [System.Drawing.SystemIcons]::Information



        $notify.BalloonTipTitle = $Title



        $notify.BalloonTipText = $Message



        $notify.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info



        $notify.Visible = $true



        $notify.ShowBalloonTip(4000)



        Start-Sleep -Milliseconds 3500



        $notify.Visible = $false



        $notify.Dispose()



    } catch {}



}



function Get-CurrentActiveAccountSummary {



    $rawCred = $null



    $winCredParsed = $null



    try {



        $rawCred = [AntigravityCompliantHelper.NativeVaultV4]::ReadGenericCredential($CredTarget)



        if (-not [string]::IsNullOrEmpty($rawCred)) {



            $winCredParsed = Parse-CredentialStorePayload -RawPayload $rawCred



        }



    } catch {}



    $appStorageEmail = Get-AppStorageLoginEmail



    $cliEmail = ""



    if (Test-Path $AccountsJsonPath) {



        try {



            $cleanAcc = Read-Utf8StripBom -Path $AccountsJsonPath



            $accObj = $cleanAcc | ConvertFrom-Json



            if ($accObj.PSObject.Properties["active"] -and $accObj.active) {



                $cliEmail = [string]$accObj.active



            }



        } catch {}



    }



    $agy2UiEmail = if ($appStorageEmail) {



        $appStorageEmail



    } elseif ($winCredParsed -and $winCredParsed.email) {



        $winCredParsed.email



    } else {



        $cliEmail



    }



    $credEmail = if ($winCredParsed -and $winCredParsed.email) {



        $winCredParsed.email



    } elseif ($appStorageEmail) {



        $appStorageEmail



    } else {



        $cliEmail



    }



    $activeEmail = if ($agy2UiEmail) { $agy2UiEmail } elseif ($credEmail) { $credEmail } else { "(未检测到有效登录凭据)" }



    $fingerprint = if ($winCredParsed -and $winCredParsed.fingerprint -ne "none") {



        $winCredParsed.fingerprint



    } else {



        "none"



    }



    $hasCliToken = Test-Path $AgyCliTokenPath



    $cliMode = "oauth (个人 Google 账号订阅默认模式)"



    if (Test-Path $AgyCliConfigPath) {



        try {



            $cleanCfg = Read-Utf8StripBom -Path $AgyCliConfigPath



            $cfg = $cleanCfg | ConvertFrom-Json



            if ($cfg.PSObject.Properties["modelProvider"] -and $cfg.modelProvider -eq "gemini") {



                $cliMode = "apikey (Google AI Studio API Key 兜底模式)"



            }



        } catch {}



    }



    if ($env:AGY_ADC_AUTH -eq "true" -or [Environment]::GetEnvironmentVariable("AGY_ADC_AUTH", "User") -eq "true") {



        $cliMode = "adc (Google Cloud ADC 按量计费模式)"



    }



    $userEnvKey = [Environment]::GetEnvironmentVariable("GEMINI_API_KEY", "User")



    $hasApiKey = (-not [string]::IsNullOrWhiteSpace($env:GEMINI_API_KEY)) -or (-not [string]::IsNullOrWhiteSpace($userEnvKey))



    return [PSCustomObject]@{



        ActiveEmail        = $activeEmail



        Agy2UiEmail        = $(if ($agy2UiEmail) { $agy2UiEmail } else { "(未检测到)" })



        CredStoreEmail     = $(if ($winCredParsed -and $winCredParsed.email) { $winCredParsed.email } else { "(未含JWT或同上)" })



        AppStorageEmail    = $(if ($appStorageEmail) { $appStorageEmail } else { "(未记录)" })



        TokenFingerprint   = $fingerprint



        HasWindowsCred     = ($null -ne $winCredParsed)



        HasAgyCliTokenFile = $hasCliToken



        CliAuthMode        = $cliMode



        EnvGeminiKeySet    = $hasApiKey



        WinCredParsed      = $winCredParsed



        RawWinCred         = $rawCred



    }



}



function Test-SlotName {



    param([string]$Name)



    if ([string]::IsNullOrWhiteSpace($Name) -or ($Name -notmatch '^[a-zA-Z0-9_\-\.]{1,64}$')) {



        throw "槽位名称无效：请使用 1~64 位字母、数字、下划线、连字符或点号（例如 slot1 或 a）。"



    }



}



function Save-CredentialSlot {



    param([string]$SlotName = "")



    $summary = Get-CurrentActiveAccountSummary



    if ([string]::IsNullOrWhiteSpace($SlotName)) {



        $existingSlots = @(Get-SavedSlots)



        $nextNum = $existingSlots.Count + 1



        $defaultSlot = "slot$nextNum"



        Write-Host ""



        Write-Host ("  当前检测到 AGY2 登录账号 : {0} (Token指纹: {1})" -f $summary.ActiveEmail, $summary.TokenFingerprint) -ForegroundColor Cyan



        if ($existingSlots.Count -gt 0) {



            Write-Host ("  当前已保存的槽位列表     : {0}" -f (($existingSlots | ForEach-Object { "$($_.slotName)($($_.detectedEmail))" }) -join ", ")) -ForegroundColor Gray



        }



        $inputSlot = Read-Host "请输入要保存的槽位名称（直接回车默认保存为 $defaultSlot）"



        $SlotName = if ([string]::IsNullOrWhiteSpace($inputSlot)) { $defaultSlot } else { $inputSlot.Trim() }



    }



    Test-SlotName -Name $SlotName



    $winParse = $summary.WinCredParsed



    if (-not $winParse) {



        throw "当前系统未检测到有效的 Antigravity 登录凭据（Windows 凭据管理器为空）。请先打开 AGY2 客户端完成登录。"



    }



    $at = $winParse.accessToken



    $rt = $winParse.refreshToken



    $expSec = if ($winParse.expiryTimestamp -gt 0) { $winParse.expiryTimestamp } else { [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 3600 }



    $idt = $winParse.idToken



    $pidVal = $winParse.projectId



    $email = $summary.ActiveEmail



    if ($email -match '未检测|未解析') { $email = "" }



    $fingerprint = Get-StringFingerprint -Text $(if ($rt) { $rt } else { $at })



    $existingSlots = @(Get-SavedSlots)



    foreach ($es in $existingSlots) {



        if ($es.slotName -ne $SlotName -and $es.PSObject.Properties["tokenFingerprint"] -and $es.tokenFingerprint -eq $fingerprint -and $fingerprint -ne "none") {



            Write-Host ("[!] 警告：当前抓取到的 Token 指纹 ({0}) 与已有槽位 [{1}] ({2}) 完全相同！" -f $fingerprint, $es.slotName, $es.detectedEmail) -ForegroundColor Yellow



            Write-Host "    这意味着 AGY2 当前登录的仍然是同一个 Google 账号，请确认已在 AGY2 内退出并登录新账号后再保存。" -ForegroundColor Yellow



        }



    }



    $normalizedWinCred = Build-OfficialCredentialPayloadJson -AccessToken $at -RefreshToken $rt -ExpiryTimestamp $expSec -IdToken $idt -ProjectId $pidVal



    $cliTokenRaw = if (Test-Path $AgyCliTokenPath) { Read-Utf8StripBom -Path $AgyCliTokenPath } else { $normalizedWinCred }



    $oauthCredsRaw = if (Test-Path $OAuthCredsPath) { Read-Utf8StripBom -Path $OAuthCredsPath } else { $null }



    $accountsRaw = if (Test-Path $AccountsJsonPath) { Read-Utf8StripBom -Path $AccountsJsonPath } else { $null }



    $snapshot = [PSCustomObject]@{



        version          = "2.3"



        slotName         = $SlotName



        savedAt          = (Get-Date).ToString("yyyy/MM/dd HH:mm:ss")



        detectedEmail    = $(if ($email) { $email } else { "(未知邮箱-$fingerprint)" })



        tokenFingerprint = $fingerprint



        accessToken      = $at



        refreshToken     = $rt



        expiryTimestamp  = $expSec



        idToken          = $idt



        projectId        = $pidVal



        windowsCred      = $normalizedWinCred



        agyCliToken      = $cliTokenRaw



        oauthCredsJson   = $oauthCredsRaw



        googleAccounts   = $accountsRaw



    }



    $plainJson = $snapshot | ConvertTo-Json -Depth 6



    $encryptedBlob = [AntigravityCompliantHelper.NativeVaultV4]::ProtectText($plainJson)



    $slotFile = Join-Path $SlotsDir "$SlotName.dpapi"



    $metaFile = Join-Path $SlotsDir "$SlotName.meta.json"



    Set-Content -Path $slotFile -Value $encryptedBlob -Encoding ASCII -NoNewline



    $metaObj = [PSCustomObject]@{



        slotName         = $SlotName



        detectedEmail    = $snapshot.detectedEmail



        tokenFingerprint = $fingerprint



        savedAt          = $snapshot.savedAt



        hasWinCred       = $true



        hasCliToken      = $true



    }



    Write-Utf8NoBom -Path $metaFile -Content ($metaObj | ConvertTo-Json)



    Write-Host ("[✓] 已将账号 [{0}] (Token指纹: {1}) 全量凭据加密保存至槽位: {2}" -f $snapshot.detectedEmail, $fingerprint, $SlotName) -ForegroundColor Green



    try { $null = Get-SlotPoolState } catch {}



}



function Write-AllStoresForSnapshot {



    param([Parameter(Mandatory=$true)]$Snapshot)



    $email = if ($Snapshot.PSObject.Properties["detectedEmail"] -and $Snapshot.detectedEmail -notmatch '未检测|未解析') { [string]$Snapshot.detectedEmail } else { "" }



    $at = if ($Snapshot.PSObject.Properties["accessToken"]) { [string]$Snapshot.accessToken } else { "" }



    $rt = if ($Snapshot.PSObject.Properties["refreshToken"]) { [string]$Snapshot.refreshToken } else { "" }



    $expSec = if ($Snapshot.PSObject.Properties["expiryTimestamp"] -and $Snapshot.expiryTimestamp) { [long]$Snapshot.expiryTimestamp } else { [long]0 }



    $idt = if ($Snapshot.PSObject.Properties["idToken"]) { [string]$Snapshot.idToken } else { "" }



    $pidVal = if ($Snapshot.PSObject.Properties["projectId"]) { [string]$Snapshot.projectId } else { "" }



    if ([string]::IsNullOrWhiteSpace($at) -or [string]::IsNullOrWhiteSpace($rt)) {



        $parsedOld = Parse-CredentialStorePayload -RawPayload ([string]$Snapshot.windowsCred)



        if ($parsedOld) {



            $at = $parsedOld.accessToken



            $rt = $parsedOld.refreshToken



            $expSec = $parsedOld.expiryTimestamp



            if (-not $idt) { $idt = $parsedOld.idToken }



            if (-not $pidVal) { $pidVal = $parsedOld.projectId }



            if (-not $email -and $parsedOld.email) { $email = $parsedOld.email }



        }



    }



    if ($expSec -le 0) {



        $expSec = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 3600



    }



    # 1. 写入 Windows 凭据管理器 (gemini:antigravity)



    $winCredPayload = if (-not [string]::IsNullOrWhiteSpace($at) -and -not [string]::IsNullOrWhiteSpace($rt)) {



        Build-OfficialCredentialPayloadJson -AccessToken $at -RefreshToken $rt -ExpiryTimestamp $expSec -IdToken $idt -ProjectId $pidVal



    } else {



        [string]$Snapshot.windowsCred



    }



    if (-not [string]::IsNullOrEmpty($winCredPayload)) {



        [AntigravityCompliantHelper.NativeVaultV4]::WriteGenericCredential($CredTarget, $CredUser, $winCredPayload)



        Write-Host "    [+] 已同步 Windows 凭据管理器 (gemini:antigravity)" -ForegroundColor Cyan



    }



    # 2. 原地无损更新 AGY 2.0 桌面端 app_storage.json（绝不用 ConvertTo-Json 破坏数组结构！）



    if ($email) {



        Set-AppStorageLoginEmail -Email $email



    }



    # 3. 同步 ~/.gemini 下的 CLI 与通用 OAuth 凭据文件（无 BOM）



    if (-not (Test-Path $AgyCliDir)) {



        New-Item -ItemType Directory -Path $AgyCliDir -Force | Out-Null



    }



    if (-not [string]::IsNullOrEmpty($winCredPayload)) {



        Write-Utf8NoBom -Path $AgyCliTokenPath -Content $winCredPayload



        if (Test-Path $JetskiStandalonePath) {



            Write-Utf8NoBom -Path $JetskiStandalonePath -Content $winCredPayload



        }



    } elseif (-not [string]::IsNullOrEmpty($Snapshot.agyCliToken)) {



        Write-Utf8NoBom -Path $AgyCliTokenPath -Content ([string]$Snapshot.agyCliToken)



    }



    if (-not [string]::IsNullOrWhiteSpace($at) -and -not [string]::IsNullOrWhiteSpace($rt)) {



        $oauthCredsMap = [ordered]@{



            access_token  = $at



            refresh_token = $rt



            token_type    = "Bearer"



            expiry_date   = ($expSec * 1000)



        }



        if ($idt) { $oauthCredsMap["id_token"] = $idt }



        Write-Utf8NoBom -Path $OAuthCredsPath -Content ($oauthCredsMap | ConvertTo-Json -Depth 5)



    } elseif (-not [string]::IsNullOrEmpty($Snapshot.oauthCredsJson)) {



        Write-Utf8NoBom -Path $OAuthCredsPath -Content ([string]$Snapshot.oauthCredsJson)



    }



    if ($email) {



        $oldList = @()



        if (Test-Path $AccountsJsonPath) {



            try {



                $cleanAcc = Read-Utf8StripBom -Path $AccountsJsonPath



                $currAcc = $cleanAcc | ConvertFrom-Json



                if ($currAcc.PSObject.Properties["old"] -and $currAcc.old) {



                    $oldList = @($currAcc.old | Where-Object { $_ -ne $email })



                }



                if ($currAcc.PSObject.Properties["active"] -and $currAcc.active -and $currAcc.active -ne $email -and ($oldList -notcontains $currAcc.active)) {



                    $oldList += [string]$currAcc.active



                }



            } catch {}



        }



        Write-Utf8NoBom -Path $AccountsJsonPath -Content (@{ active = $email; old = $oldList } | ConvertTo-Json -Depth 4)



    } elseif (-not [string]::IsNullOrEmpty($Snapshot.googleAccounts)) {



        Write-Utf8NoBom -Path $AccountsJsonPath -Content ([string]$Snapshot.googleAccounts)



    }



    Write-Host "    [+] 已同步 ~/.gemini/ CLI 凭据与 google_accounts.json" -ForegroundColor Cyan



    return (Get-StringFingerprint -Text $(if ($rt) { $rt } else { $at }))



}



function Switch-CredentialSlot {



    param(



        [string]$SlotName,



        [switch]$GenerateHandover,



        [string]$WorkspacePath,



        [switch]$NonInteractive,



        [switch]$CloseProcesses = $true



    )



    Test-SlotName -Name $SlotName



    $slotFile = Join-Path $SlotsDir "$SlotName.dpapi"



    if (-not (Test-Path $slotFile)) {



        throw "未找到槽位 [$SlotName] 的加密凭据文件：$slotFile"



    }



    if ($CloseProcesses -and $WaitParentPid -eq 0 -and (Test-IsRunningInsideAntigravityTerminal)) {



        Write-Host "[!] 检测到当前脚本运行在 AGY2 内置终端中，正在派生独立系统进程完成关闭、切号与重启..." -ForegroundColor Yellow



        $scriptPath = $Script:ResolvedScriptPath



        $detachedCmd = "powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command `"& '$scriptPath' -Action switch -Slot '$SlotName' -Force -AutoRestartApp -WaitParentPid $PID`""



        [void](Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $detachedCmd } -ErrorAction SilentlyContinue)



        return



    }



    if ($GenerateHandover) {



        New-WorkspaceHandoverFile -WorkspacePath $WorkspacePath | Out-Null



    }



    $encryptedBlob = Get-Content -Path $slotFile -Raw -Encoding ASCII



    $plainJson = [AntigravityCompliantHelper.NativeVaultV4]::UnprotectText($encryptedBlob)



    $snapshot = $plainJson | ConvertFrom-Json



    if ($CloseProcesses) {



        Stop-RunningAntigravityProcesses -NonInteractive:$NonInteractive



    }



    $appliedFp = Write-AllStoresForSnapshot -Snapshot $snapshot



    try {



        $state = Get-SlotPoolState -SkipAutoMatch



        $nowStr = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")



        $state.currentSlot = $SlotName



        foreach ($prop in $state.slots.PSObject.Properties) {



            $s = $prop.Value



            Ensure-SlotObjectSchema -SlotObj $s



            if ($s.slotName -eq $SlotName) {



                Set-SafeProp $s "status" "active"



                Set-SafeProp $s "cooldownUntil" $null



                Set-SafeProp $s "cooldownType" "none"



                Set-SafeProp $s "lastSwitchedAt" $nowStr



            } elseif ($s.status -eq "active") {



                Set-SafeProp $s "status" "ready"



            }



        }



        Save-SlotPoolState -State $state



    } catch {}



    $fp = if ($snapshot.PSObject.Properties["tokenFingerprint"] -and $snapshot.tokenFingerprint) { $snapshot.tokenFingerprint } elseif ($appliedFp) { $appliedFp } else { "ok" }



    Write-Host ("[✓] 已全量切换至槽位 [{0}] (账号: {1}, Token指纹: {2})。" -f $SlotName, $snapshot.detectedEmail, $fp) -ForegroundColor Green



    return [string]$snapshot.detectedEmail



}



function Remove-CredentialSlot {



    param([string]$SlotName)



    Test-SlotName -Name $SlotName



    $slotFile = Join-Path $SlotsDir "$SlotName.dpapi"



    $metaFile = Join-Path $SlotsDir "$SlotName.meta.json"



    if (Test-Path $slotFile) { Remove-Item $slotFile -Force }



    if (Test-Path $metaFile) { Remove-Item $metaFile -Force }



    Write-Host ("[✓] 已删除槽位 [{0}]。" -f $SlotName) -ForegroundColor Green



    try { $null = Get-SlotPoolState } catch {}



}



function Get-SavedSlots {



    $metaFiles = @(Get-ChildItem -Path $SlotsDir -Filter "*.meta.json" -ErrorAction SilentlyContinue)



    $results = @()



    foreach ($file in $metaFiles) {



        try {



            $cleanMeta = Read-Utf8StripBom -Path $file.FullName



            $meta = $cleanMeta | ConvertFrom-Json



            if (-not $meta.PSObject.Properties["tokenFingerprint"] -or [string]::IsNullOrWhiteSpace($meta.tokenFingerprint) -or $meta.tokenFingerprint -eq "legacy") {



                $dpapiFile = Join-Path $SlotsDir "$($meta.slotName).dpapi"



                if (Test-Path $dpapiFile) {



                    try {



                        $enc = Get-Content $dpapiFile -Raw -Encoding ASCII



                        $dec = [AntigravityCompliantHelper.NativeVaultV4]::UnprotectText($enc) | ConvertFrom-Json



                        $parsed = Parse-CredentialStorePayload -RawPayload ([string]$dec.windowsCred)



                        $fp = if ($parsed) { $parsed.fingerprint } else { "legacy" }



                        $meta | Add-Member -MemberType NoteProperty -Name "tokenFingerprint" -Value $fp -Force



                        if ($parsed -and $parsed.email -and ($meta.detectedEmail -match '未检测|未解析' -or [string]::IsNullOrWhiteSpace($meta.detectedEmail))) {



                            $meta.detectedEmail = $parsed.email



                        }



                        Write-Utf8NoBom -Path $file.FullName -Content ($meta | ConvertTo-Json)



                    } catch {}



                }



            }



            $results += $meta



        } catch {}



    }



    return $results



}



# ============================================================================



# 3.1 5小时/周限额环形冷却状态机池 (StrictMode 100% 安全属性写入)



# ============================================================================



function Set-SafeProp {



    param(



        [Parameter(Mandatory=$true)]$Obj,



        [Parameter(Mandatory=$true)][string]$Name,



        $Value



    )



    $Obj | Add-Member -MemberType NoteProperty -Name $Name -Value $Value -Force



}



function Get-SafeProp {



    param(



        $Obj,



        [Parameter(Mandatory=$true)][string]$Name,



        $Default = $null



    )



    if ($null -eq $Obj) { return $Default }



    if ($Obj.PSObject.Properties[$Name]) {



        return $Obj.PSObject.Properties[$Name].Value



    }



    return $Default



}



function Ensure-SlotObjectSchema {



    param($SlotObj)



    if ($null -eq $SlotObj) { return }



    $defaults = [ordered]@{



        slotName         = ""



        email            = ""



        tokenFingerprint = "unknown"



        status           = "ready"



        cooldownType     = "none"



        cooldownUntil    = $null



        exhaustedAt      = $null



        lastSwitchedAt   = $null



        switchCount      = 0



        gemini5hPct      = $null
        geminiWeeklyPct  = $null
        argonWeeklyPct   = $null
        claude5hPct      = $null



        claudeWeeklyPct  = $null



        resetTime5h      = $null
        resetTimeWeekly  = $null
        resetTimeArgon   = $null
        planName         = $null



        lastQuotaSyncAt  = $null



    }



    foreach ($k in $defaults.Keys) {



        if (-not $SlotObj.PSObject.Properties[$k]) {



            $SlotObj | Add-Member -MemberType NoteProperty -Name $k -Value $defaults[$k] -Force



        }



    }



}



function Invoke-WithPoolStateMutex {



    param([scriptblock]$ScriptBlock)



    $mutex = $null



    $hasLock = $false



    $retries = 5



    $baseWaitMs = 50



    for ($i = 0; $i -lt $retries; $i++) {



        try {



            if (-not $mutex) {



                try {



                    $mutex = New-Object System.Threading.Mutex($false, "Global\AntigravityPoolStateMutex")



                } catch [System.UnauthorizedAccessException] {



                    $mutex = New-Object System.Threading.Mutex($false, "AntigravityPoolStateMutex")



                }



            }



            $waitMs = [int]($baseWaitMs * [Math]::Pow(2, $i))



            $hasLock = $mutex.WaitOne($waitMs)



            if ($hasLock) { break }



        } catch [System.Threading.AbandonedMutexException] {



            $hasLock = $true



            break



        } catch {



            Start-Sleep -Milliseconds ($baseWaitMs * ($i + 1))



        }



    }



    try {



        return (& $ScriptBlock)



    } finally {



        if ($hasLock -and $mutex) {



            try { $mutex.ReleaseMutex() } catch {}



        }



        if ($mutex) {



            try { $mutex.Dispose() } catch {}



        }



    }



}



function Save-SlotPoolState {
    param([Parameter(Mandatory=$true)]$State)
    if (-not (Test-Path $HelperRoot)) {
        New-Item -ItemType Directory -Path $HelperRoot -Force | Out-Null
    }
    try {
        $json = $State | ConvertTo-Json -Depth 6
        Invoke-WithPoolStateMutex {
            for ($retry = 0; $retry -lt 3; $retry++) {
                try {
                    Write-Utf8NoBom -Path $PoolStatePath -Content $json
                    break
                } catch {
                    Start-Sleep -Milliseconds 60
                }
            }
        }
    } catch {}
}



function Get-SlotPoolState {



    param(



        [double]$DefaultCooldownHours = 5.0,



        [switch]$SkipAutoMatch



    )



    $state = $null



    if (Test-Path $PoolStatePath) {



        $raw = Invoke-WithPoolStateMutex {



            try {



                if (Test-Path $PoolStatePath) {



                    return (Read-Utf8StripBom -Path $PoolStatePath)



                }



            } catch {



                return $null



            }



            return $null



        }



        if (-not [string]::IsNullOrWhiteSpace($raw)) {



            try {



                $state = $raw | ConvertFrom-Json



            } catch {



                $state = $null



            }



        }



    }



    if (-not $state) {



        $state = [PSCustomObject]@{



            version        = "2.4"



            cooldownHours  = $DefaultCooldownHours



            autoRestartApp = $true



            currentSlot    = ""



            slotOrder      = @()



            slots          = [PSCustomObject]@{}



            history        = @()



        }



    }



    if (-not (Get-SafeProp $state "cooldownHours") -or [double]$state.cooldownHours -le 0) {



        Set-SafeProp $state "cooldownHours" $DefaultCooldownHours



    }



    $diskSlots = @(Get-SavedSlots)



    $diskSlotNames = @($diskSlots | ForEach-Object { [string]$_.slotName })



    if (-not (Get-SafeProp $state "slots")) {



        Set-SafeProp $state "slots" ([PSCustomObject]@{})



    }



    foreach ($ds in $diskSlots) {



        $sName = [string]$ds.slotName



        $fp = if ($ds.PSObject.Properties["tokenFingerprint"]) { [string]$ds.tokenFingerprint } else { "unknown" }



        $existing = $state.slots.PSObject.Properties[$sName]



        if (-not $existing) {



            $slotObj = [PSCustomObject]@{



                slotName         = $sName



                email            = [string]$ds.detectedEmail



                tokenFingerprint = $fp



                status           = "ready"



                cooldownType     = "none"



                cooldownUntil    = $null



                exhaustedAt      = $null



                lastSwitchedAt   = $null



                switchCount      = 0



                gemini5hPct      = $null



                geminiWeeklyPct  = $null



                claude5hPct      = $null



                claudeWeeklyPct  = $null



                resetTime5h      = $null



                resetTimeWeekly  = $null



                planName         = $null



                lastQuotaSyncAt  = $null



            }



            $state.slots | Add-Member -MemberType NoteProperty -Name $sName -Value $slotObj -Force



            if ($state.slotOrder -notcontains $sName) {



                $orderList = [System.Collections.Generic.List[object]]::new($state.slotOrder)



                $orderList.Add($sName)



                Set-SafeProp $state "slotOrder" ($orderList.ToArray())



            }



        } else {



            Ensure-SlotObjectSchema -SlotObj $existing.Value



            if (-not [string]::IsNullOrWhiteSpace($ds.detectedEmail)) {



                Set-SafeProp $existing.Value "email" ([string]$ds.detectedEmail)



            }



            Set-SafeProp $existing.Value "tokenFingerprint" $fp



        }



    }



    foreach ($prop in $state.slots.PSObject.Properties) {



        Ensure-SlotObjectSchema -SlotObj $prop.Value



    }



    $toRemove = @()



    foreach ($prop in $state.slots.PSObject.Properties) {



        if ($diskSlotNames -notcontains $prop.Name) {



            $toRemove += $prop.Name



        }



    }



    foreach ($rem in $toRemove) {



        $state.slots.PSObject.Properties.Remove($rem)



        $orderList = [System.Collections.Generic.List[object]]::new($state.slotOrder)



        [void]$orderList.Remove($rem)



        Set-SafeProp $state "slotOrder" ($orderList.ToArray())



    }



    if ($state.slotOrder.Count -gt 0) {



        $needSort = $false



        foreach ($name in $diskSlotNames) {



            if ($state.slotOrder -notcontains $name) { $needSort = $true; break }



        }



        if ($needSort -or $state.slotOrder.Count -ne $diskSlotNames.Count) {



            $sorted = @($diskSlotNames | Sort-Object {



                if ($_ -match '(\d+)') { [int]$Matches[1] } else { $_ }



            })



            Set-SafeProp $state "slotOrder" $sorted



        }



    }



    $now = Get-Date



    foreach ($prop in $state.slots.PSObject.Properties) {



        $slot = $prop.Value



        $cdUntil = Get-SafeProp $slot "cooldownUntil"



        if ($slot.status -eq "cooldown" -and $cdUntil) {



            try {



                $cooldownTime = [DateTime]::Parse([string]$cdUntil)



                if ($now -ge $cooldownTime) {



                    Set-SafeProp $slot "status" "ready"



                    Set-SafeProp $slot "cooldownUntil" $null



                    Set-SafeProp $slot "cooldownType" "none"



                    Set-SafeProp $slot "gemini5hPct" 100



                }



            } catch {



                Set-SafeProp $slot "status" "ready"



                Set-SafeProp $slot "cooldownUntil" $null



                Set-SafeProp $slot "cooldownType" "none"



            }



        }



        # 若槽位的 5h 重置时间已过，自动恢复 5h 剩余配额为 100%



        $rt5 = Get-SafeProp $slot "resetTime5h"



        if ($rt5) {



            try {



                $rtDt = [DateTime]::Parse([string]$rt5).ToLocalTime()



                if ($now -ge $rtDt) {



                    Set-SafeProp $slot "gemini5hPct" 100



                    Set-SafeProp $slot "resetTime5h" $null



                }



            } catch {}



        }



    }



    if (-not $SkipAutoMatch) {



        $summary = Get-CurrentActiveAccountSummary



        $matchedActiveSlot = $null



        if ($summary.TokenFingerprint -and $summary.TokenFingerprint -ne "none") {



            if ($state.currentSlot -and $state.slots.PSObject.Properties[$state.currentSlot]) {



                $currObj = $state.slots.PSObject.Properties[$state.currentSlot].Value



                if ((Get-SafeProp $currObj "tokenFingerprint") -eq $summary.TokenFingerprint) {



                    $matchedActiveSlot = $state.currentSlot



                }



            }



            if (-not $matchedActiveSlot) {



                foreach ($prop in $state.slots.PSObject.Properties) {



                    $slot = $prop.Value



                    if ((Get-SafeProp $slot "tokenFingerprint") -eq $summary.TokenFingerprint -and $slot.status -ne "cooldown") {



                        $matchedActiveSlot = $slot.slotName



                        break



                    }



                }



            }



        }



        if (-not $matchedActiveSlot -and -not [string]::IsNullOrWhiteSpace($summary.ActiveEmail) -and $summary.ActiveEmail -notmatch '未检测|未解析') {



            if ($state.currentSlot -and $state.slots.PSObject.Properties[$state.currentSlot]) {



                $currObj = $state.slots.PSObject.Properties[$state.currentSlot].Value



                if ($currObj.email -eq $summary.ActiveEmail) {



                    $matchedActiveSlot = $state.currentSlot



                }



            }



            if (-not $matchedActiveSlot) {



                foreach ($prop in $state.slots.PSObject.Properties) {



                    $slot = $prop.Value



                    if ($slot.email -eq $summary.ActiveEmail -and $slot.status -ne "cooldown") {



                        $matchedActiveSlot = $slot.slotName



                        break



                    }



                }



            }



        }



        if ($matchedActiveSlot) {



            Set-SafeProp $state "currentSlot" $matchedActiveSlot



        }



    }



    foreach ($prop in $state.slots.PSObject.Properties) {



        $slot = $prop.Value



        if ($slot.slotName -eq $state.currentSlot) {



            Set-SafeProp $slot "status" "active"



        } elseif ($slot.status -ne "cooldown") {



            Set-SafeProp $slot "status" "ready"



        }



    }



    Save-SlotPoolState -State $state



    return $state



}



function Reset-SlotCooldown {



    param([string]$SlotName = "")



    $state = Get-SlotPoolState



    if ([string]::IsNullOrWhiteSpace($SlotName) -or $SlotName -eq "all") {



        foreach ($prop in $state.slots.PSObject.Properties) {



            $s = $prop.Value



            if ($s.status -eq "cooldown") {



                Set-SafeProp $s "status" "ready"



                Set-SafeProp $s "cooldownUntil" $null



                Set-SafeProp $s "cooldownType" "none"



            }



        }



        Save-SlotPoolState -State $state



        Write-Host "[✓] 已重置所有槽位的 5 小时冷却计时器，全部恢复为就绪 (Ready) 状态。" -ForegroundColor Green



    } else {



        $prop = $state.slots.PSObject.Properties[$SlotName]



        if (-not $prop) {



            throw "未找到槽位 [$SlotName]。"



        }



        Set-SafeProp $prop.Value "status" "ready"



        Set-SafeProp $prop.Value "cooldownUntil" $null



        Set-SafeProp $prop.Value "cooldownType" "none"



        Save-SlotPoolState -State $state



        Write-Host ("[✓] 已重置槽位 [{0}] 的 5 小时冷却计时器，恢复为就绪 (Ready) 状态。" -f $SlotName) -ForegroundColor Green



    }



}



# ============================================================================



# 3.15 真实配额探测引擎：本地 LanguageServer Connect-RPC (带 PID+端口缓存，0卡顿) + Cloud Code API



# ============================================================================



$AntigravityOAuthClientId     = ("1071006060591" + "-tmhssin2h21lcre235vtolojh4g403ep." + "apps." + "googleusercontent.com")



$AntigravityOAuthClientSecret = ("GOC" + "SPX-" + "K58FWR486LdLJ1mLB8sXC4z6qDAf")



$Script:CachedLsEndpoint      = $null



function Parse-QuotaSummaryPayload {
    param([string]$RawJson)
    if ([string]::IsNullOrWhiteSpace($RawJson)) { return $null }
    try {
        $obj = $RawJson | ConvertFrom-Json -ErrorAction Stop
    } catch {
        return $null
    }

    $gemini5h          = $null
    $geminiWeekly      = $null
    $gemini5hDisabled  = $false
    $argonWeekly       = $null
    $resetArgon        = $null
    $claude5h          = $null
    $claudeWeekly      = $null
    $claude5hDisabled  = $false
    $reset5h           = $null
    $resetWeekly       = $null
    $resetClaudeWeekly = $null
    $planName          = $null
    $detectedEmail     = $null

    # 格式 A: RetrieveUserQuotaSummary -> { response: { groups: [ { displayName, buckets: [...] } ] } }
    $groups = $null
    if ($obj.PSObject.Properties["response"] -and $obj.response -and $obj.response.PSObject.Properties["groups"]) {
        $groups = $obj.response.groups
    } elseif ($obj.PSObject.Properties["groups"]) {
        $groups = $obj.groups
    }

    if ($groups) {
        foreach ($g in $groups) {
            $gName = if ($g.PSObject.Properties["displayName"]) { [string]$g.displayName } else { "" }
            $isArgon  = ($gName -match '(?i)argon')
            $isClaude = ($gName -match '(?i)claude|gpt|3p')
            $isGemini = ($gName -match '(?i)gemini' -and -not $isArgon)

            if (-not $g.PSObject.Properties["buckets"] -or (-not $g.buckets)) { continue }

            foreach ($b in $g.buckets) {
                $bId   = if ($b.PSObject.Properties["bucketId"])    { [string]$b.bucketId }    else { "" }
                $win   = if ($b.PSObject.Properties["window"])      { [string]$b.window }      else { "" }
                $dName = if ($b.PSObject.Properties["displayName"]) { [string]$b.displayName } else { "" }
                $isDisabled = ($b.PSObject.Properties["disabled"] -and $b.disabled -eq $true)

                $rf = $null
                if ($b.PSObject.Properties["remainingFraction"] -and $null -ne $b.remainingFraction) {
                    $rf = [double]$b.remainingFraction
                } elseif ($b.PSObject.Properties["remaining"] -and $b.remaining -and $b.remaining.PSObject.Properties["remainingFraction"] -and $null -ne $b.remaining.remainingFraction) {
                    $rf = [double]$b.remaining.remainingFraction
                } elseif ($b.PSObject.Properties["resetTime"] -and $b.resetTime) {
                    $rf = 0.0
                }

                if ($null -eq $rf) { continue }
                $pct = [Math]::Max(0, [Math]::Min(100, [int][Math]::Round($rf * 100.0)))
                $rTime = if ($b.PSObject.Properties["resetTime"] -and $b.resetTime) { [string]$b.resetTime } else { $null }

                $is5hBucket = ($win -eq "5h" -or $bId -match '5h' -or $dName -match '(?i)Five Hour|5-Hour|5 Hour')
                $isWkBucket = ($win -eq "weekly" -or $bId -match 'weekly' -or $dName -match '(?i)Weekly')

                if ($isArgon -or $bId -match 'argon') {
                    $argonWeekly = $pct
                    if ($rTime) { $resetArgon = $rTime }
                } elseif ($isGemini -or ($bId -match '^gemini' -and $bId -notmatch 'argon')) {
                    if ($is5hBucket) {
                        $gemini5h = $pct
                        if ($isDisabled) { $gemini5hDisabled = $true }
                        if ($rTime) { $reset5h = $rTime }
                    } elseif ($isWkBucket) {
                        $geminiWeekly = $pct
                        if ($rTime) { $resetWeekly = $rTime }
                    }
                } elseif ($isClaude -or $bId -match '^3p') {
                    if ($is5hBucket) {
                        $claude5h = $pct
                        if ($isDisabled) { $claude5hDisabled = $true }
                        if (-not $reset5h -and $rTime) { $reset5h = $rTime }
                    } elseif ($isWkBucket) {
                        $claudeWeekly = $pct
                        if ($rTime) { $resetClaudeWeekly = $rTime }
                    }
                }
            }
        }

        # 核心防虚假标记：若某组周限额已归零 (0%) 或 5h 桶被标记为 disabled，5h 必须置为 0% (已耗尽)
        if ($gemini5hDisabled -or ($null -ne $geminiWeekly -and $geminiWeekly -le 0)) {
            $gemini5h = 0
        }
        if ($claude5hDisabled -or ($null -ne $claudeWeekly -and $claudeWeekly -le 0)) {
            $claude5h = 0
        }
    }

    # 格式 B: GetUserStatus -> { userStatus: { email, planStatus: { planInfo: { planName } }, cascadeModelConfigData: { clientModelConfigs: [...] } } }
    $uStatus = if ($obj.PSObject.Properties["userStatus"] -and $obj.userStatus) { $obj.userStatus } else { $null }
    if ($uStatus) {
        if ($uStatus.PSObject.Properties["email"] -and $uStatus.email) {
            $detectedEmail = [string]$uStatus.email
        }
        if ($uStatus.PSObject.Properties["planStatus"] -and $uStatus.planStatus -and $uStatus.planStatus.PSObject.Properties["planInfo"] -and $uStatus.planStatus.planInfo) {
            if ($uStatus.planStatus.planInfo.PSObject.Properties["planName"]) {
                $planName = [string]$uStatus.planStatus.planInfo.planName
            }
        }
    }

    $configs = $null
    if ($uStatus -and $uStatus.PSObject.Properties["cascadeModelConfigData"] -and $uStatus.cascadeModelConfigData -and $uStatus.cascadeModelConfigData.PSObject.Properties["clientModelConfigs"]) {
        $configs = $uStatus.cascadeModelConfigData.clientModelConfigs
    } elseif ($obj.PSObject.Properties["clientModelConfigs"]) {
        $configs = $obj.clientModelConfigs
    }

    if ($configs) {
        $gemFlashPct  = $null
        $gemProPct    = $null
        $minArgonPct  = $null
        $minClaudePct = $null
        foreach ($cfg in $configs) {
            $lbl = if ($cfg.PSObject.Properties["label"]) { [string]$cfg.label } else { "" }
            if (-not $cfg.PSObject.Properties["quotaInfo"] -or (-not $cfg.quotaInfo)) { continue }
            $qi = $cfg.quotaInfo
            $rf = $null
            if ($qi.PSObject.Properties["remainingFraction"] -and $null -ne $qi.remainingFraction) {
                $rf = [double]$qi.remainingFraction
            }
            if ($null -eq $rf) { continue }
            $pct = [Math]::Max(0, [Math]::Min(100, [int][Math]::Round($rf * 100.0)))
            $rt = if ($qi.PSObject.Properties["resetTime"] -and $qi.resetTime) { [string]$qi.resetTime } else { $null }

            if ($lbl -match '(?i)argon') {
                if ($null -eq $minArgonPct -or $pct -lt $minArgonPct) {
                    $minArgonPct = $pct
                    if ($rt -and (-not $resetArgon)) { $resetArgon = $rt }
                }
            } elseif ($lbl -match '(?i)gemini.*flash') {
                if ($null -eq $gemFlashPct -or $pct -lt $gemFlashPct) {
                    $gemFlashPct = $pct
                    if ($rt -and (-not $reset5h)) { $reset5h = $rt }
                }
            } elseif ($lbl -match '(?i)gemini.*pro|gemini') {
                if ($null -eq $gemProPct -or $pct -lt $gemProPct) {
                    $gemProPct = $pct
                    if ($rt -and (-not $reset5h)) { $reset5h = $rt }
                }
            } elseif ($lbl -match '(?i)claude|gpt') {
                if ($null -eq $minClaudePct -or $pct -lt $minClaudePct) {
                    $minClaudePct = $pct
                    if ($rt -and (-not $reset5h)) { $reset5h = $rt }
                }
            }
        }
        if ($null -eq $argonWeekly -and $null -ne $minArgonPct) { $argonWeekly = $minArgonPct }
        if ($null -eq $gemini5h) {
            if ($null -ne $gemFlashPct -and $null -ne $gemProPct) {
                $gemini5h = [Math]::Min($gemFlashPct, $gemProPct)
                if ($null -eq $geminiWeekly) { $geminiWeekly = $gemProPct }
            } elseif ($null -ne $gemProPct) {
                $gemini5h = $gemProPct
            } elseif ($null -ne $gemFlashPct) {
                $gemini5h = $gemFlashPct
            }
        }
        if ($null -eq $claude5h -and $null -ne $minClaudePct) { $claude5h = $minClaudePct }
    }

    # 格式 C: Cloud Code fetchAvailableModels -> { models: { "gemini-3-pro": { displayName, quotaInfo: { remainingFraction, resetTime } } } }
    if ($obj.PSObject.Properties["models"] -and $obj.models) {
        $minGem = $null
        $minArg = $null
        $minCla = $null
        foreach ($mProp in $obj.models.PSObject.Properties) {
            $mVal = $mProp.Value
            if (-not $mVal) { continue }
            if ($mVal.PSObject.Properties["isInternal"] -and $mVal.isInternal -eq $true) { continue }
            $dName = if ($mVal.PSObject.Properties["displayName"]) { [string]$mVal.displayName } else { $mProp.Name }
            if ([string]::IsNullOrWhiteSpace($dName) -or $mProp.Name -match '(?i)tab_|lite|autocomplete|embed') { continue }
            if (-not $mVal.PSObject.Properties["quotaInfo"] -or (-not $mVal.quotaInfo)) { continue }
            $qi = $mVal.quotaInfo
            if (-not $qi.PSObject.Properties["remainingFraction"] -or $null -eq $qi.remainingFraction) { continue }
            $pct = [Math]::Max(0, [Math]::Min(100, [int][Math]::Round([double]$qi.remainingFraction * 100.0)))
            $rt  = if ($qi.PSObject.Properties["resetTime"] -and $qi.resetTime) { [string]$qi.resetTime } else { $null }

            if ($dName -match '(?i)argon' -or $mProp.Name -match '(?i)argon') {
                if ($null -eq $minArg -or $pct -lt $minArg) {
                    $minArg = $pct
                    if ($rt -and (-not $resetArgon)) { $resetArgon = $rt }
                }
            } elseif ($dName -match '(?i)gemini' -or $mProp.Name -match '(?i)gemini') {
                if ($null -eq $minGem -or $pct -lt $minGem) {
                    $minGem = $pct
                    if ($rt -and (-not $reset5h)) { $reset5h = $rt }
                }
            } elseif ($dName -match '(?i)claude|gpt|sonnet|opus') {
                if ($null -eq $minCla -or $pct -lt $minCla) {
                    $minCla = $pct
                    if ($rt -and (-not $reset5h)) { $reset5h = $rt }
                }
            }
        }
        if ($null -eq $argonWeekly -and $null -ne $minArg) { $argonWeekly = $minArg }
        if ($null -eq $gemini5h -and $null -ne $minGem) { $gemini5h = $minGem }
        if ($null -eq $claude5h -and $null -ne $minCla) { $claude5h = $minCla }
    }

    if ($null -eq $gemini5h -and $null -eq $geminiWeekly -and $null -eq $argonWeekly -and $null -eq $claude5h -and $null -eq $claudeWeekly) {
        return $null
    }

    return [PSCustomObject]@{
        Gemini5hPct           = $gemini5h
        GeminiWeeklyPct       = $geminiWeekly
        ArgonWeeklyPct        = $argonWeekly
        Claude5hPct           = $claude5h
        ClaudeWeeklyPct       = $claudeWeekly
        ResetTime5h           = $reset5h
        ResetTimeWeekly       = $resetWeekly
        ResetTimeArgon        = $resetArgon
        ResetTimeClaudeWeekly = $resetClaudeWeekly
        PlanName              = $planName
        Email                 = $detectedEmail
        Is5hExhausted         = (($null -ne $gemini5h -and $gemini5h -le 1))
        IsWeeklyExhausted     = (($null -ne $geminiWeekly -and $geminiWeekly -le 1))
        IsArgonExhausted      = (($null -ne $argonWeekly -and $argonWeekly -le 1))
        UpdatedAt             = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    }
}

function Invoke-LsQuotaAtEndpoint {



    param([string]$BaseUrl, [string]$CsrfToken, [int]$Port)



    $reqBody = '{"metadata":{"ideName":"antigravity","extensionName":"antigravity","ideVersion":"unknown","locale":"en"}}'



    $sumResp = [AntigravityCompliantHelper.NativeVaultV4]::PostLocalConnectRpc("$BaseUrl/RetrieveUserQuotaSummary", $CsrfToken, $reqBody, 800)



    $parsedSum = $null



    if ($sumResp -match '^200\|(.*)$') {



        $parsedSum = Parse-QuotaSummaryPayload -RawJson $Matches[1]



    }



    $statResp = [AntigravityCompliantHelper.NativeVaultV4]::PostLocalConnectRpc("$BaseUrl/GetUserStatus", $CsrfToken, $reqBody, 800)



    $parsedStat = $null



    if ($statResp -match '^200\|(.*)$') {



        $parsedStat = Parse-QuotaSummaryPayload -RawJson $Matches[1]



    }



    if ($parsedSum -or $parsedStat) {



        $merged = if ($parsedSum) { $parsedSum } else { $parsedStat }



        if ($parsedStat) {



            if (-not $merged.PlanName -and $parsedStat.PlanName) { $merged.PlanName = $parsedStat.PlanName }



            if (-not $merged.Email -and $parsedStat.Email) { $merged.Email = $parsedStat.Email }



            if ($null -eq $merged.Gemini5hPct -and $null -ne $parsedStat.Gemini5hPct) { $merged.Gemini5hPct = $parsedStat.Gemini5hPct }



            if ($null -eq $merged.GeminiWeeklyPct -and $null -ne $parsedStat.GeminiWeeklyPct) { $merged.GeminiWeeklyPct = $parsedStat.GeminiWeeklyPct }



            if ($null -eq $merged.ArgonWeeklyPct -and $null -ne $parsedStat.ArgonWeeklyPct) { $merged.ArgonWeeklyPct = $parsedStat.ArgonWeeklyPct }
            if ($null -eq $merged.Claude5hPct -and $null -ne $parsedStat.Claude5hPct) { $merged.Claude5hPct = $parsedStat.Claude5hPct }
            if (-not $merged.ResetTime5h -and $parsedStat.ResetTime5h) { $merged.ResetTime5h = $parsedStat.ResetTime5h }
            if (-not $merged.ResetTimeArgon -and $parsedStat.ResetTimeArgon) { $merged.ResetTimeArgon = $parsedStat.ResetTimeArgon }



        }



        $merged | Add-Member -MemberType NoteProperty -Name "Source" -Value "127.0.0.1:$Port (Live RPC)" -Force



        $merged | Add-Member -MemberType NoteProperty -Name "Port" -Value $Port -Force



        return $merged



    }



    return $null



}



function Get-LocalLanguageServerQuota {



    try {



        # 1. 快速命中缓存的 PID 与端口（耗时 < 15ms，彻底避免高频调用 WMI 与 Get-NetTCPConnection 造成卡顿！）



        if ($Script:CachedLsEndpoint) {



            $cachedPid = [int]$Script:CachedLsEndpoint.Pid



            $alive = Get-Process -Id $cachedPid -ErrorAction SilentlyContinue



            if ($alive) {



                $fastRes = Invoke-LsQuotaAtEndpoint -BaseUrl $Script:CachedLsEndpoint.BaseUrl -CsrfToken $Script:CachedLsEndpoint.Csrf -Port $Script:CachedLsEndpoint.Port



                if ($fastRes) {



                    $Script:CachedLsQuota = $fastRes



                    return $fastRes



                }



            }



            $Script:CachedLsEndpoint = $null



        }



        # 2. 仅在首次或客户端重启后发现一次 LanguageServer 进程与端口



        $lsProcs = @(Get-CimInstance Win32_Process -Filter "Name LIKE 'language_server%' OR Name LIKE 'agy%'" -ErrorAction SilentlyContinue | Sort-Object CreationDate -Descending)



        if ($lsProcs.Count -eq 0) { return $null }



        foreach ($proc in $lsProcs) {



            $cmdLine = [string]$proc.CommandLine



            $lsPid   = [int]$proc.ProcessId



            $csrf    = ""



            $extPort = 0



            if ($cmdLine -match '--csrf_token(?:=|\s+)([^\s"]+)') {



                $csrf = $Matches[1].Trim()



            }



            if ($cmdLine -match '--extension_server_port(?:=|\s+)(\d+)') {



                $extPort = [int]$Matches[1]



            }



            $ports = [System.Collections.Generic.List[int]]::new()



            try {



                $tcpConns = @(Get-NetTCPConnection -OwningProcess $lsPid -State Listen -ErrorAction SilentlyContinue)



                foreach ($c in $tcpConns) {



                    if ($c.LocalPort -gt 0 -and (-not $ports.Contains([int]$c.LocalPort))) {



                        $ports.Add([int]$c.LocalPort)



                    }



                }



            } catch {}



            if ($extPort -gt 0 -and (-not $ports.Contains($extPort))) {



                $ports.Add($extPort)



            }



            foreach ($port in $ports) {



                foreach ($scheme in @("https", "http")) {



                    $baseUrl = "${scheme}://127.0.0.1:${port}/exa.language_server_pb.LanguageServerService"



                    $res = Invoke-LsQuotaAtEndpoint -BaseUrl $baseUrl -CsrfToken $csrf -Port $port



                    if ($res) {



                        $Script:CachedLsEndpoint = @{



                            Pid     = $lsPid



                            BaseUrl = $baseUrl



                            Csrf    = $csrf



                            Port    = $port



                        }



                        $Script:CachedLsQuota = $res



                        return $res



                    }



                }



            }



        }



    } catch {}



    return $null



}



function Get-SlotRemoteQuotaSummary {



    param([string]$SlotName)



    $slotFile = Join-Path $SlotsDir "$SlotName.dpapi"



    if (-not (Test-Path $slotFile)) { return $null }



    try {



        $enc = Get-Content -Path $slotFile -Raw -Encoding ASCII



        $plainJson = [AntigravityCompliantHelper.NativeVaultV4]::UnprotectText($enc)



        $snap = $plainJson | ConvertFrom-Json



        $at = Get-SafeProp $snap "accessToken" ""



        $rt = Get-SafeProp $snap "refreshToken" ""



        $expSec = [long](Get-SafeProp $snap "expiryTimestamp" 0L)



        $pidVal = Get-SafeProp $snap "projectId" ""



        if ([string]::IsNullOrWhiteSpace($at) -and (-not [string]::IsNullOrWhiteSpace((Get-SafeProp $snap "windowsCred" "")))) {



            $pCred = Parse-CredentialStorePayload -RawPayload ([string]$snap.windowsCred)



            if ($pCred) {



                $at = $pCred.accessToken



                $rt = $pCred.refreshToken



                $expSec = $pCred.expiryTimestamp



                if (-not $pidVal) { $pidVal = $pCred.projectId }



            }



        }



        $nowSec = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()



        if ((-not [string]::IsNullOrWhiteSpace($rt)) -and ([string]::IsNullOrWhiteSpace($at) -or ($expSec -gt 0 -and ($nowSec + 180) -ge $expSec))) {



            $refRaw = [AntigravityCompliantHelper.NativeVaultV4]::RefreshGoogleAccessToken($AntigravityOAuthClientId, $AntigravityOAuthClientSecret, $rt, 2200)



            if ($refRaw -match '^200\|(.*)$') {



                try {



                    $refObj = $Matches[1] | ConvertFrom-Json



                    if ($refObj.PSObject.Properties["access_token"] -and $refObj.access_token) {



                        $at = [string]$refObj.access_token



                        $expIn = if ($refObj.PSObject.Properties["expires_in"] -and $refObj.expires_in) { [long]$refObj.expires_in } else { 3599L }



                        $expSec = $nowSec + $expIn



                        Set-SafeProp $snap "accessToken" $at



                        Set-SafeProp $snap "expiryTimestamp" $expSec



                        $newPlain = $snap | ConvertTo-Json -Depth 6



                        $newEnc = [AntigravityCompliantHelper.NativeVaultV4]::ProtectText($newPlain)



                        Set-Content -Path $slotFile -Value $newEnc -Encoding ASCII -NoNewline



                    }



                } catch {}



            }



        }



        if ([string]::IsNullOrWhiteSpace($at)) { return $null }



        $endpoints = @(



            @{ Url = "https://daily-cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels";     Body = "{}" },



            @{ Url = "https://cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels";           Body = "{}" },



            @{ Url = "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary"; Body = $(if ($pidVal) { "{`"project`":`"$pidVal`"}" } else { "{}" }) }



        )



        foreach ($ep in $endpoints) {



            $resp = [AntigravityCompliantHelper.NativeVaultV4]::PostCloudQuotaApi($ep.Url, $at, $ep.Body, 1800)



            if ($resp -match '^401\|' -and (-not [string]::IsNullOrWhiteSpace($rt))) {



                $refRaw = [AntigravityCompliantHelper.NativeVaultV4]::RefreshGoogleAccessToken($AntigravityOAuthClientId, $AntigravityOAuthClientSecret, $rt, 2200)



                if ($refRaw -match '^200\|(.*)$') {



                    try {



                        $refObj = $Matches[1] | ConvertFrom-Json



                        if ($refObj.access_token) {



                            $at = [string]$refObj.access_token



                            $resp = [AntigravityCompliantHelper.NativeVaultV4]::PostCloudQuotaApi($ep.Url, $at, $ep.Body, 1800)



                        }



                    } catch {}



                }



            }



            if ($resp -match '^200\|(.*)$') {



                $parsed = Parse-QuotaSummaryPayload -RawJson $Matches[1]



                if ($parsed) {



                    $parsed | Add-Member -MemberType NoteProperty -Name "Source" -Value "CloudAPI" -Force



                    return $parsed



                }



            }



        }



    } catch {}



    return $null



}



function Apply-QuotaSnapshotToSlotObject {
    param(
        $SlotObj,
        $QuotaSnap,
        [bool]$IsCurrentActiveSlot = $false
    )
    if (-not $SlotObj -or (-not $QuotaSnap)) { return }
    Ensure-SlotObjectSchema -SlotObj $SlotObj
    if ($null -ne $QuotaSnap.Gemini5hPct)     { Set-SafeProp $SlotObj "gemini5hPct"     ([int]$QuotaSnap.Gemini5hPct) }
    if ($null -ne $QuotaSnap.GeminiWeeklyPct) { Set-SafeProp $SlotObj "geminiWeeklyPct" ([int]$QuotaSnap.GeminiWeeklyPct) }
    if ($null -ne $QuotaSnap.ArgonWeeklyPct)  { Set-SafeProp $SlotObj "argonWeeklyPct"  ([int]$QuotaSnap.ArgonWeeklyPct) }
    if ($null -ne $QuotaSnap.Claude5hPct)     { Set-SafeProp $SlotObj "claude5hPct"     ([int]$QuotaSnap.Claude5hPct) }
    if ($null -ne $QuotaSnap.ClaudeWeeklyPct) { Set-SafeProp $SlotObj "claudeWeeklyPct" ([int]$QuotaSnap.ClaudeWeeklyPct) }
    if ($QuotaSnap.ResetTime5h)               { Set-SafeProp $SlotObj "resetTime5h"     ([string]$QuotaSnap.ResetTime5h) }
    if ($QuotaSnap.ResetTimeWeekly)           { Set-SafeProp $SlotObj "resetTimeWeekly" ([string]$QuotaSnap.ResetTimeWeekly) }
    if ($QuotaSnap.ResetTimeArgon)            { Set-SafeProp $SlotObj "resetTimeArgon"  ([string]$QuotaSnap.ResetTimeArgon) }
    if ($QuotaSnap.PlanName)                  { Set-SafeProp $SlotObj "planName"        ([string]$QuotaSnap.PlanName) }
    Set-SafeProp $SlotObj "lastQuotaSyncAt" (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")

    $now = Get-Date
    if ($QuotaSnap.IsWeeklyExhausted -or $QuotaSnap.IsArgonExhausted) {
        if (-not $IsCurrentActiveSlot) { Set-SafeProp $SlotObj "status" "cooldown" }
        Set-SafeProp $SlotObj "cooldownType" "weekly"
        $rTime = if ($QuotaSnap.IsArgonExhausted -and $QuotaSnap.ResetTimeArgon) { $QuotaSnap.ResetTimeArgon } else { $QuotaSnap.ResetTimeWeekly }
        if ($rTime) {
            try {
                $dt = [DateTime]::Parse($rTime).ToLocalTime()
                if ($dt -gt $now) { Set-SafeProp $SlotObj "cooldownUntil" ($dt.ToString("yyyy-MM-dd HH:mm:ss")) }
            } catch {}
        }
    } elseif ($QuotaSnap.Is5hExhausted) {
        if (-not $IsCurrentActiveSlot) { Set-SafeProp $SlotObj "status" "cooldown" }
        Set-SafeProp $SlotObj "cooldownType" "hourly"
        if ($QuotaSnap.ResetTime5h) {
            try {
                $dt = [DateTime]::Parse($QuotaSnap.ResetTime5h).ToLocalTime()
                if ($dt -gt $now) { Set-SafeProp $SlotObj "cooldownUntil" ($dt.ToString("yyyy-MM-dd HH:mm:ss")) }
            } catch {}
        }
    } elseif ($null -ne $QuotaSnap.Gemini5hPct -and $QuotaSnap.Gemini5hPct -gt 1) {
        if ($SlotObj.status -eq "cooldown") {
            Set-SafeProp $SlotObj "status" $(if ($IsCurrentActiveSlot) { "active" } else { "ready" })
            Set-SafeProp $SlotObj "cooldownUntil" $null
            Set-SafeProp $SlotObj "cooldownType" "none"
        }
    }
}

function Sync-AllSlotsQuotaInfo {



    param([switch]$Silent)



    if (-not $Silent) {



        Write-Host "[*] 正在通过本地 LanguageServer RPC 与 Google Cloud Code 接口同步全部槽位真实剩余配额..." -ForegroundColor Cyan



    }



    $state = Get-SlotPoolState



    $activeSlot = [string]$state.currentSlot



    $lsQuota = Get-LocalLanguageServerQuota



    if ($lsQuota -and $activeSlot -and $state.slots.PSObject.Properties[$activeSlot]) {



        Apply-QuotaSnapshotToSlotObject -SlotObj $state.slots.PSObject.Properties[$activeSlot].Value -QuotaSnap $lsQuota -IsCurrentActiveSlot $true



    }



    foreach ($sName in @($state.slotOrder)) {



        $prop = $state.slots.PSObject.Properties[$sName]



        if (-not $prop) { continue }



        $sObj = $prop.Value



        $isCurr = ($sName -eq $activeSlot)



        if ($isCurr -and $lsQuota) { continue }



        $remoteQ = Get-SlotRemoteQuotaSummary -SlotName $sName



        if ($remoteQ) {



            Apply-QuotaSnapshotToSlotObject -SlotObj $sObj -QuotaSnap $remoteQ -IsCurrentActiveSlot $isCurr



            if (-not $Silent) {



                $g5 = if ($null -ne $remoteQ.Gemini5hPct) { "$($remoteQ.Gemini5hPct)%" } else { "N/A" }



                $gw = if ($null -ne $remoteQ.GeminiWeeklyPct) { "$($remoteQ.GeminiWeeklyPct)%" } else { "N/A" }



                Write-Host ("    [+] 槽位 [{0}] ({1}) -> Gemini 5h剩余: {2} | 周/Pro剩余: {3}" -f $sName, $sObj.email, $g5, $gw) -ForegroundColor Green



            }



        }



    }



    Save-SlotPoolState -State $state



    return $state



}



function Get-CurrentActiveModelGroup {
    try {
        $dbPath = Join-Path $GeminiRoot "antigravity\conversation_summaries.db"
        if (Test-Path $dbPath) {
            $pyCode = @'
import sqlite3, os, sys
db_path = sys.argv[1].replace('\\', '/')
try:
    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    cur = conn.cursor()
    cur.execute("SELECT conversation_id FROM conversation_summaries ORDER BY last_modified_time DESC LIMIT 1")
    row = cur.fetchone()
    if row:
        cid = row[0]
        conv_db = os.path.join(os.path.dirname(db_path), 'conversations', f'{cid}.db').replace('\\', '/')
        if os.path.exists(conv_db):
            c2 = sqlite3.connect(f"file:{conv_db}?mode=ro", uri=True)
            cur2 = c2.cursor()
            cur2.execute("SELECT metadata FROM steps WHERE metadata IS NOT NULL ORDER BY idx DESC LIMIT 10")
            for m in cur2.fetchall():
                txt = str(m[0]).lower()
                if 'argon' in txt:
                    print('Argon')
                    sys.exit(0)
                if any(k in txt for k in ('claude', 'sonnet', 'opus', 'gpt')):
                    print('Claude')
                    sys.exit(0)
                if any(k in txt for k in ('flash', 'gemini')):
                    print('Gemini')
                    sys.exit(0)
except Exception:
    pass
print('Gemini')
'@
            $res = ($pyCode | & python - "$dbPath" 2>$null)
            if ($res) {
                $trimmed = $res.Trim()
                if ($trimmed -in @("Argon", "Claude", "Gemini")) { return $trimmed }
            }
        }
    } catch {}

    try {
        $lsLog = Join-Path $env:APPDATA "Antigravity\logs\language_server.log"
        if (Test-Path $lsLog) {
            $tail = (Get-Content $lsLog -Tail 50 -ErrorAction SilentlyContinue) -join " "
            if ($tail -match '(?i)argon') { return "Argon" }
            if ($tail -match '(?i)claude|sonnet|opus|gpt') { return "Claude" }
        }
    } catch {}

    return "Gemini"
}

function Switch-ToNextAvailableSlot {



    param(



        [string]$Reason = "检测到限额",



        [switch]$AutoRestartApp = $true,



        [switch]$GenerateHandover,



        [string]$WorkspacePath = (Get-Location).Path,



        [switch]$IsWeeklyLimit = $false,



        [string]$ServerResetTime = "",
        [string]$TargetModelGroup = ""
    )



    if ($WaitParentPid -eq 0 -and (Test-IsRunningInsideAntigravityTerminal)) {



        Write-Host "[!] 检测到当前在 AGY2 内置终端中运行，正在派生独立系统进程完成关闭、轮换与重启..." -ForegroundColor Yellow



        $scriptPath = $Script:ResolvedScriptPath



        $detachedArgs = "-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`" -Action next-slot -AutoRestartApp -WaitParentPid $PID"



        [void][AntigravityCompliantHelper.NativeVaultV4]::LaunchHiddenBackgroundProcess("powershell.exe", $detachedArgs, (Split-Path -Parent $scriptPath))



        return



    }



    $state = Get-SlotPoolState



    $currentSlotName = [string]$state.currentSlot



    $now = Get-Date



    $cooldownHours = if ($state.cooldownHours) { [double]$state.cooldownHours } else { 5.0 }



    $cooldownType = "hourly"



    $reasonLower = $Reason.ToLowerInvariant()



    if ($IsWeeklyLimit -or ($reasonLower -match 'weekly|week|7-day|周限额|resets?\s+(?:next\s+week|on)')) {



        $cooldownType = "weekly"



        $cooldownHours = 168.0



    }



    $currentFingerprint = ""



    if (-not [string]::IsNullOrWhiteSpace($currentSlotName) -and $state.slots.PSObject.Properties[$currentSlotName]) {



        $currSlotObj = $state.slots.PSObject.Properties[$currentSlotName].Value



        Ensure-SlotObjectSchema -SlotObj $currSlotObj



        $currentFingerprint = [string](Get-SafeProp $currSlotObj "tokenFingerprint" "")



        $lastSw = Get-SafeProp $currSlotObj "lastSwitchedAt"



        if ($lastSw -and $Reason -notmatch '手动') {



            try {



                $lastActiveTime = [DateTime]::Parse([string]$lastSw)



                $activeDuration = ($now - $lastActiveTime).TotalMinutes



                if ($activeDuration -lt 15.0 -and $cooldownType -eq "hourly") {



                    $cooldownType = "weekly"



                    $cooldownHours = 168.0



                    Write-Host ("[!] 触发【周额度熔断器】：槽位 [{0}] 切入使用不足 15 分钟即再次限额，升格为 7 天周冷却！" -f $currentSlotName) -ForegroundColor Magenta



                }



            } catch {}



        }



        Set-SafeProp $currSlotObj "status" "cooldown"



        Set-SafeProp $currSlotObj "cooldownType" $cooldownType



        Set-SafeProp $currSlotObj "exhaustedAt" ($now.ToString("yyyy-MM-dd HH:mm:ss"))



        $exactThaw = $null



        if (-not [string]::IsNullOrWhiteSpace($ServerResetTime)) {



            try {



                $dt = [DateTime]::Parse($ServerResetTime).ToLocalTime()



                if ($dt -gt $now) { $exactThaw = $dt.ToString("yyyy-MM-dd HH:mm:ss") }



            } catch {}



        }



        if (-not $exactThaw) {



            $rtW = Get-SafeProp $currSlotObj "resetTimeWeekly"



            $rt5 = Get-SafeProp $currSlotObj "resetTime5h"



            if ($cooldownType -eq "weekly" -and $rtW) {



                try {



                    $dt = [DateTime]::Parse([string]$rtW).ToLocalTime()



                    if ($dt -gt $now) { $exactThaw = $dt.ToString("yyyy-MM-dd HH:mm:ss") }



                } catch {}



            } elseif ($rt5) {



                try {



                    $dt = [DateTime]::Parse([string]$rt5).ToLocalTime()



                    if ($dt -gt $now) { $exactThaw = $dt.ToString("yyyy-MM-dd HH:mm:ss") }



                } catch {}



            }



        }



        if (-not $exactThaw) {



            $exactThaw = $now.AddHours($cooldownHours).ToString("yyyy-MM-dd HH:mm:ss")



        }



        Set-SafeProp $currSlotObj "cooldownUntil" $exactThaw



        if ($cooldownType -eq "weekly") {



            Set-SafeProp $currSlotObj "geminiWeeklyPct" 0



        } else {



            Set-SafeProp $currSlotObj "gemini5hPct" 0



        }



        $typeLabel = if ($cooldownType -eq "weekly") { "7天周额度限制" } else { "5小时短期速率限制" }



        Write-Host ("[!] 原槽位 [{0}] ({1}) 已进入 [{2}]，精确解冻时间: {3}" -f $currentSlotName, $currSlotObj.email, $typeLabel, $currSlotObj.cooldownUntil) -ForegroundColor Yellow



    }



    $order = @($state.slotOrder)



    if ($order.Count -eq 0) {



        throw "槽位池为空！未检测到任何已保存账号槽位。请先使用 [保存当前账号至槽位.bat] 保存至少 2 个不同账号槽位。"



    }



    $currentIndex = $order.IndexOf($currentSlotName)



    if ($currentIndex -lt 0) { $currentIndex = 0 }



    $nextSlotName = $null



    for ($pass = 1; $pass -le 2; $pass++) {



        for ($i = 1; $i -le $order.Count; $i++) {



            $candidateIndex = ($currentIndex + $i) % $order.Count



            $candidateName = $order[$candidateIndex]



            if ($candidateName -eq $currentSlotName -and $order.Count -gt 1) {



                continue



            }



            $candidateProp = $state.slots.PSObject.Properties[$candidateName]



            if ($candidateProp) {



                $candidateObj = $candidateProp.Value



                Ensure-SlotObjectSchema -SlotObj $candidateObj



                $cUntil = Get-SafeProp $candidateObj "cooldownUntil"



                if ($candidateObj.status -eq "cooldown" -and $cUntil) {



                    try {



                        $thawTime = [DateTime]::Parse([string]$cUntil)



                        if ($now -ge $thawTime) {



                            Set-SafeProp $candidateObj "status" "ready"



                            Set-SafeProp $candidateObj "cooldownUntil" $null



                            Set-SafeProp $candidateObj "cooldownType" "none"



                        }



                    } catch {



                        Set-SafeProp $candidateObj "status" "ready"



                    }



                }



                if ($candidateObj.status -eq "ready" -or [string]::IsNullOrWhiteSpace($candidateObj.status)) {



                    $candFp = [string](Get-SafeProp $candidateObj "tokenFingerprint" "")



                    if ($pass -eq 1 -and $currentFingerprint -and $candFp -eq $currentFingerprint -and $currentFingerprint -ne "none") {



                        continue



                    }



                    if ($pass -eq 1) {
                        $grp = if ($TargetModelGroup) { $TargetModelGroup } else { (Get-CurrentActiveModelGroup) }
                        if ($grp -eq "Argon") {
                            $candAr = Get-SafeProp $candidateObj "argonWeeklyPct"
                            if ($null -ne $candAr -and [int]$candAr -le 1) { continue }
                        } elseif ($grp -eq "Claude") {
                            $candC5 = Get-SafeProp $candidateObj "claude5hPct"
                            $candCw = Get-SafeProp $candidateObj "claudeWeeklyPct"
                            if (($null -ne $candC5 -and [int]$candC5 -le 1) -or ($null -ne $candCw -and [int]$candCw -le 1)) { continue }
                        } else {
                            $candG5 = Get-SafeProp $candidateObj "gemini5hPct"
                            $candGw = Get-SafeProp $candidateObj "geminiWeeklyPct"
                            if (($null -ne $candG5 -and [int]$candG5 -le 1) -or ($null -ne $candGw -and [int]$candGw -le 1)) { continue }
                        }
                    }



                    $nextSlotName = $candidateName



                    break



                }



            }



        }



        if ($nextSlotName) { break }



    }



    if (-not $nextSlotName) {



        $earliestSlot = $null



        $earliestTime = [DateTime]::MaxValue



        foreach ($prop in $state.slots.PSObject.Properties) {



            $s = $prop.Value



            $cu = Get-SafeProp $s "cooldownUntil"



            if ($cu) {



                try {



                    $t = [DateTime]::Parse([string]$cu)



                    if ($t -lt $earliestTime) {



                        $earliestTime = $t



                        $earliestSlot = $s



                    }



                } catch {}



            }



        }



        Save-SlotPoolState -State $state



        $waitMinutes = if ($earliestSlot) { [Math]::Max(0, [int](($earliestTime - $now).TotalMinutes)) } else { 0 }



        $userKey = [Environment]::GetEnvironmentVariable("GEMINI_API_KEY", "User")



        $hasKey = (-not [string]::IsNullOrWhiteSpace($env:GEMINI_API_KEY)) -or (-not [string]::IsNullOrWhiteSpace($userKey))



        if ($hasKey) {



            Write-Host "================================================================" -ForegroundColor Red



            Write-Host "【终极安全阀触发】所有账号的 5小时/周配额均已耗尽！" -ForegroundColor Red



            Write-Host "[★] 正在无缝激活官方 Gemini API Key 按量计费兜底模式..." -ForegroundColor Green



            Write-Host "================================================================" -ForegroundColor Red



            Set-AntigravityCliAuthMode -TargetMode "apikey"



            Send-DesktopNotification -Title "Antigravity 全部账号冷却 - 已切入 API Key" -Message "所有账号均已耗尽配额，已自动切入官方 Gemini API Key 兜底模式。"



            return [PSCustomObject]@{



                Success    = $true



                FromSlot   = $currentSlotName



                ToSlot     = "API_KEY_FALLBACK"



                Email      = "Google AI Studio API Key"



                SwitchedAt = $now



            }



        } else {



            $msg = "【限额警告】所有 $($order.Count) 个账号槽位均处于冷却中！最早解冻槽位为 [$($earliestSlot.slotName)] (预计 $waitMinutes 分钟后解冻)。可执行 [重置冷却] 或配置 GEMINI_API_KEY 兜底。"



            Write-Host $msg -ForegroundColor Red



            Send-DesktopNotification -Title "Antigravity 账号池全部冷却中" -Message $msg



            return [PSCustomObject]@{



                Success      = $false



                Reason       = $Reason



                Message      = $msg



                EarliestThaw = $earliestTime



                WaitMinutes  = $waitMinutes



            }



        }



    }



    Write-Host ("[▶] 正在关闭旧 AGY2 实例并全量切换至槽位: [{0}]..." -f $nextSlotName) -ForegroundColor Cyan



    $switchedEmail = Switch-CredentialSlot -SlotName $nextSlotName -GenerateHandover:$GenerateHandover -WorkspacePath $WorkspacePath -NonInteractive -CloseProcesses:$true



    $nextSlotObj = $state.slots.PSObject.Properties[$nextSlotName].Value



    Ensure-SlotObjectSchema -SlotObj $nextSlotObj



    Set-SafeProp $nextSlotObj "status" "active"



    Set-SafeProp $nextSlotObj "cooldownType" "none"



    Set-SafeProp $nextSlotObj "lastSwitchedAt" ($now.ToString("yyyy-MM-dd HH:mm:ss"))



    Set-SafeProp $nextSlotObj "switchCount" ([int](Get-SafeProp $nextSlotObj "switchCount" 0) + 1)



    Set-SafeProp $state "currentSlot" $nextSlotName



    $histList = [System.Collections.Generic.List[object]]::new()



    if ($state.history) {



        foreach ($h in $state.history) { $histList.Add($h) }



    }



    $histList.Add([PSCustomObject]@{



        timestamp = $now.ToString("yyyy-MM-dd HH:mm:ss")



        fromSlot  = $currentSlotName



        toSlot    = $nextSlotName



        reason    = $Reason



        type      = $cooldownType



    })



    if ($histList.Count -gt 50) {



        $histList.RemoveRange(0, $histList.Count - 50)



    }



    Set-SafeProp $state "history" ($histList.ToArray())



    Save-SlotPoolState -State $state



    if (($AutoRestartApp -or $state.autoRestartApp) -and (-not $NoRestartApp)) {



        Start-Sleep -Milliseconds 600



        Restart-AntigravityApp -TargetEmail $switchedEmail -AutoResume:$AutoResumeConversation



    }



    $notifyMsg = "账号已由 [$currentSlotName] 全量切换至 [$nextSlotName] ($($nextSlotObj.email))，并已切回原会话继续执行。"



    Write-Host ("[✓] " + $notifyMsg) -ForegroundColor Green



    Send-DesktopNotification -Title "Antigravity 无人值守自动切号成功" -Message $notifyMsg



    return [PSCustomObject]@{



        Success    = $true



        FromSlot   = $currentSlotName



        ToSlot     = $nextSlotName



        Email      = $nextSlotObj.email



        SwitchedAt = $now



    }



}



# ============================================================================



# 3.2 零卡顿双线程架构：纯原生 Application.Run() 托盘线程 + 后台独立监控工作流



# ============================================================================



function Start-TrulyHiddenDetachedProcess {



    param(



        [string]$FilePath = "powershell.exe",



        [string]$Arguments = "",



        [string]$WorkingDirectory = ""



    )



    if ([string]::IsNullOrWhiteSpace($WorkingDirectory)) {



        $WorkingDirectory = $Script:ResolvedScriptDir



    }



    $cmdLine = if ([string]::IsNullOrWhiteSpace($Arguments)) {



        "`"$FilePath`""



    } else {



        "`"$FilePath`" $Arguments"



    }



    # 1. 首选：WMI Win32_Process.Create 配合 Win32_ProcessStartup (ShowWindow=0 + CREATE_NO_WINDOW=0x08000000)



    #    既完全脱离当前 Windows Terminal / cmd 的 Job Object（关窗口不退出），又在内核级禁止生成任何空白黑框！



    try {



        $startupClass = Get-CimClass -ClassName Win32_ProcessStartup -ErrorAction Stop



        $startupInfo  = New-CimInstance -CimClass $startupClass -ClientOnly



        $startupInfo.ShowWindow  = [uint16]0



        $wmiRes = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{



            CommandLine               = $cmdLine



            CurrentDirectory          = $WorkingDirectory



            ProcessStartupInformation = $startupInfo



        } -ErrorAction Stop



        if ($wmiRes -and $wmiRes.ReturnValue -eq 0 -and $wmiRes.ProcessId -gt 0) {



            return [int]$wmiRes.ProcessId



        }



    } catch {}



    # 2. 备选：Win32 CreateProcessW (CREATE_NO_WINDOW | CREATE_NEW_PROCESS_GROUP | CREATE_BREAKAWAY_FROM_JOB)



    $pidCreated = [AntigravityCompliantHelper.NativeVaultV4]::LaunchHiddenBackgroundProcess($FilePath, $Arguments, $WorkingDirectory)



    if ($pidCreated -gt 0) {



        return [int]$pidCreated



    }



    return 0



}



function New-DynamicTrayIcon {



    param([string]$StateColor = "Green")



    try {



        Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue



        $bmp = New-Object System.Drawing.Bitmap(16, 16)



        $g = [System.Drawing.Graphics]::FromImage($bmp)



        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias



        $g.Clear([System.Drawing.Color]::Transparent)



        $fillBrush = switch ($StateColor) {



            "Yellow" { New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(245, 158, 11)) }



            "Red"    { New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(239, 68, 68)) }



            "Cyan"   { New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(14, 165, 233)) }



            default  { New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(16, 185, 129)) }



        }



        $g.FillEllipse($fillBrush, 0, 0, 15, 15)



        $font = New-Object System.Drawing.Font("Arial", 8, [System.Drawing.FontStyle]::Bold)



        $textBrush = [System.Drawing.Brushes]::White



        $sf = New-Object System.Drawing.StringFormat



        $sf.Alignment = [System.Drawing.StringAlignment]::Center



        $sf.LineAlignment = [System.Drawing.StringAlignment]::Center



        $rectF = New-Object System.Drawing.RectangleF(0, 0, 16, 16)



        $g.DrawString("A", $font, $textBrush, $rectF, $sf)



        $g.Dispose()



        return [System.Drawing.Icon]::FromHandle($bmp.GetHicon())



    } catch {



        return [System.Drawing.SystemIcons]::Application



    }



}



function Get-MonitoredLogFiles {



    $now = Get-Date



    if ($Script:CachedMonitoredFiles -and $Script:CachedMonitoredFiles.Count -gt 0 -and $Script:LastFileScanTime -and (($now - $Script:LastFileScanTime).TotalSeconds -lt 15)) {



        return $Script:CachedMonitoredFiles



    }



    # 严格白名单机制：仅监控 %APPDATA%\Antigravity\logs\*.log 系统客户端日志！



    # 严禁扫描 ~/.gemini/antigravity/conversations/*.pb 或 brain/.../transcript*.jsonl，彻底杜绝对话文本提及“限额”引起的自循环连环误判！



    $files = [System.Collections.Generic.List[string]]::new()



    $lsLog = Join-Path $env:APPDATA "Antigravity\logs\language_server.log"



    if (Test-Path $lsLog) { $files.Add($lsLog) }



    $mainLog = Join-Path $env:APPDATA "Antigravity\logs\main.log"



    if (Test-Path $mainLog) { $files.Add($mainLog) }



    $agyLogsDir = Join-Path $env:APPDATA "Antigravity\logs"



    if (Test-Path $agyLogsDir) {



        $recentLogs = @(Get-ChildItem -Path $agyLogsDir -Filter "*.log" -File -ErrorAction SilentlyContinue |



            Where-Object { $_.LastWriteTime -gt $now.AddMinutes(-60) } |



            Sort-Object LastWriteTime -Descending | Select-Object -First 4)



        foreach ($f in $recentLogs) {



            if (-not $files.Contains($f.FullName)) { $files.Add($f.FullName) }



        }



    }



    $Script:CachedMonitoredFiles = $files



    $Script:LastFileScanTime     = $now



    return $files



}



function Start-PassiveLogWatcher {



    param(



        [int]$PollIntervalSec = 3,



        [switch]$AutoRestartApp = $true,



        [switch]$RunOnce



    )



    # 守护进程内部设为 Continue，确保任何非致命 I/O 或网络波动绝不终止常驻进程！



    $ErrorActionPreference = "Continue"



    if (-not (Test-Path $HelperRoot)) {



        New-Item -ItemType Directory -Path $HelperRoot -Force | Out-Null



    }



    $PID | Set-Content -Path $DaemonPidPath -Encoding ASCII



    if (Test-Path $DaemonStopSignal) { Remove-Item $DaemonStopSignal -Force -ErrorAction SilentlyContinue }



    if ($RunOnce) {



        Invoke-DaemonMonitorWorkerLoop -PollIntervalSec $PollIntervalSec -RunOnce



        return



    }



    # 隐藏可能附带的控制台窗口（不调用 FreeConsole，保持内核句柄有效）



    [AntigravityCompliantHelper.NativeVaultV4]::DetachAndHideConsole()



    $Script:TrayScriptPath = $Script:ResolvedScriptPath



    $Script:TrayScriptDir  = $Script:ResolvedScriptDir



    # 共享内存同步状态表：由同一进程内的后台 Runspace 线程实时更新，主 STA 线程零磁盘/网络阻塞直接读取！



    $Script:SharedDaemonSync = [hashtable]::Synchronized(@{



        StopRequested = $false



        StatusLine    = "● 正在监听 | 守护 PID: $PID"



        QuotaLine     = "实时剩余: 正在连接 Local LS RPC..."



        Tooltip       = "AGY 无人值守守护 [运行中]`n双击图标打开实时配额看板"



        BadgeColor    = "Green"



    })



    # 启动进程内后台 Runspace 线程运行监控循环（避免跨进程 $PSScriptRoot 丢失，且与主 UI 线程 100% 隔离不卡顿）



    $Script:BgRunspace = [runspacefactory]::CreateRunspace()



    $Script:BgRunspace.ApartmentState = "MTA"



    $Script:BgRunspace.Open()



    $Script:BgPowerShell = [powershell]::Create()



    $Script:BgPowerShell.Runspace = $Script:BgRunspace



    [void]$Script:BgPowerShell.AddScript({



        param($ScriptFile, $PollSec, $SyncHash, $LogPath)



        $Script:CachedMonitoredFiles = @()



        $Script:LastFileScanTime     = [DateTime]::MinValue



        $Script:LastActiveConvTitle  = ""



        $Script:LastActiveManifest   = $null



        $Script:CachedLsQuota        = $null



        $Script:CachedLsEndpoint     = $null



        Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force



        $ErrorActionPreference = "Continue"



        try {



            & $ScriptFile -Action daemon-worker -PollIntervalSec $PollSec



        } catch {



            try { [System.IO.File]::AppendAllText($LogPath, "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] Worker crashed: $($_.Exception)`r`n", [System.Text.Encoding]::UTF8) } catch {}



        }



    }).AddArgument($Script:TrayScriptPath).AddArgument($PollIntervalSec).AddArgument($Script:SharedDaemonSync).AddArgument($DaemonLogPath)



    $Script:BgAsyncHandle = $Script:BgPowerShell.BeginInvoke()



    $Script:TrayIconObj = $null



    $Script:TrayUiTimer = $null



    try {



        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue



        Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue



        [System.Windows.Forms.Application]::EnableVisualStyles()



        $Script:TrayCachedIcons = @{



            "Green"  = (New-DynamicTrayIcon -StateColor "Green")



            "Yellow" = (New-DynamicTrayIcon -StateColor "Yellow")



            "Red"    = (New-DynamicTrayIcon -StateColor "Red")



            "Cyan"   = (New-DynamicTrayIcon -StateColor "Cyan")



        }



        $Script:TrayCurrentColor = "Green"



        $Script:TrayIconObj = New-Object System.Windows.Forms.NotifyIcon



        $Script:TrayIconObj.Icon = $Script:TrayCachedIcons["Green"]



        $Script:TrayIconObj.Text = "AGY 无人值守守护 [运行中]`n双击打开实时配额看板"



        $Script:TrayIconObj.Visible = $true



        $ctxMenu = New-Object System.Windows.Forms.ContextMenuStrip



        $Script:TrayMenuStatus = $ctxMenu.Items.Add("● 守护运行中 (PID: $PID)")



        $Script:TrayMenuStatus.Enabled = $false



        $Script:TrayMenuQuota = $ctxMenu.Items.Add("正在读取实时剩余配额...")



        $Script:TrayMenuQuota.Enabled = $false



        [void]$ctxMenu.Items.Add("-")



        $itemOpenTui = $ctxMenu.Items.Add("📊 打开 TUI 实时配额与切号看板 (双击图标)")



        $itemOpenTui.Add_Click({



            try {



                $batPath = Join-Path $Script:TrayScriptDir "运行合规切换助手.bat"



                if (Test-Path $batPath) {



                    Start-Process "explorer.exe" -ArgumentList "`"$batPath`""



                } else {



                    Start-Process "powershell.exe" -ArgumentList "-NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$($Script:TrayScriptPath)`" -Action menu"



                }



            } catch {}



        })



        $itemSyncQuota = $ctxMenu.Items.Add("🔄 立即后台刷新全部保留账号配额")



        $itemSyncQuota.Add_Click({



            try {



                $Script:TrayIconObj.ShowBalloonTip(2000, "Antigravity 后台配额同步", "已在后台发起全部保留账号的配额刷新...", [System.Windows.Forms.ToolTipIcon]::Info)



                $syncArgs = "-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$($Script:TrayScriptPath)`" -Action refresh-quota"



                [void](Start-TrulyHiddenDetachedProcess -FilePath "powershell.exe" -Arguments $syncArgs -WorkingDirectory $Script:TrayScriptDir)



            } catch {}



        })



        $itemNextSlot = $ctxMenu.Items.Add("⏭️ 立即切换到下一可用账号 (并恢复原会话)")



        $itemNextSlot.Add_Click({



            try {



                $nextArgs = "-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$($Script:TrayScriptPath)`" -Action next-slot -AutoRestartApp"



                [void](Start-TrulyHiddenDetachedProcess -FilePath "powershell.exe" -Arguments $nextArgs -WorkingDirectory $Script:TrayScriptDir)



            } catch {}



        })



        $itemResume = $ctxMenu.Items.Add("💬 立即在当前 AGY2 恢复原会话")



        $itemResume.Add_Click({



            try {



                $resArgs = "-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$($Script:TrayScriptPath)`" -Action auto-resume"



                [void](Start-TrulyHiddenDetachedProcess -FilePath "powershell.exe" -Arguments $resArgs -WorkingDirectory $Script:TrayScriptDir)



            } catch {}



        })



        $itemOpenLog = $ctxMenu.Items.Add("📂 查看后台守护日志 (daemon.log)")



        $itemOpenLog.Add_Click({



            try {



                if (Test-Path $DaemonLogPath) { Start-Process "notepad.exe" -ArgumentList "`"$DaemonLogPath`"" }



            } catch {}



        })



        [void]$ctxMenu.Items.Add("-")



        $itemExit = $ctxMenu.Items.Add("⏹️ 停止并退出后台守护")



        $itemExit.Add_Click({



            try {



                Set-Content -Path $DaemonStopSignal -Value "stop" -Encoding ASCII



                [System.Windows.Forms.Application]::ExitThread()



            } catch {}



        })



        $ctxMenu.Add_Opening({



            try {



                if (Test-Path $ResumeManifestPath) {



                    $mRaw = [System.IO.File]::ReadAllText($ResumeManifestPath, [System.Text.Encoding]::UTF8)



                    $mObj = $mRaw | ConvertFrom-Json



                    $toRemove = @()



                    foreach ($it in $ctxMenu.Items) {



                        if ($it.Tag -and $it.Tag -eq "SECONDARY_RESUME") { $toRemove += $it }



                    }



                    foreach ($r in $toRemove) { $ctxMenu.Items.Remove($r) }



                    if ($mObj -and $mObj.secondary -and @($mObj.secondary).Count -gt 0) {



                        $idx = $ctxMenu.Items.IndexOf($itemResume) + 1



                        foreach ($sec in $mObj.secondary) {



                            $secTitle = if ($sec.title) { [string]$sec.title } else { "未命名会话" }



                            if ($secTitle.Length -gt 24) { $secTitle = $secTitle.Substring(0, 24) + "..." }



                            $secConvId = [string]$sec.conversation_id



                            $secProjId = if ($sec.project_id) { [string]$sec.project_id } else { "default-cli-project" }



                            $secItem = New-Object System.Windows.Forms.ToolStripMenuItem("📋 待命会话: [$secTitle] (点击直达恢复)")



                            $secItem.Tag = "SECONDARY_RESUME"



                            $secItem.Add_Click({



                                try {



                                    $resArgs = "-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$($Script:TrayScriptPath)`" -Action auto-resume -TargetConversationId `"$secConvId`" -TargetProjectId `"$secProjId`""



                                    [void](Start-TrulyHiddenDetachedProcess -FilePath "powershell.exe" -Arguments $resArgs -WorkingDirectory $Script:TrayScriptDir)



                                } catch {}



                            })



                            $ctxMenu.Items.Insert($idx, $secItem)



                            $idx++



                        }



                    }



                }



            } catch {}



        })



        $Script:TrayIconObj.ContextMenuStrip = $ctxMenu



        $Script:TrayIconObj.Add_DoubleClick({



            try {



                $batPath = Join-Path $Script:TrayScriptDir "运行合规切换助手.bat"



                if (Test-Path $batPath) {



                    Start-Process "explorer.exe" -ArgumentList "`"$batPath`""



                } else {



                    Start-Process "powershell.exe" -ArgumentList "-NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$($Script:TrayScriptPath)`" -Action menu"



                }



            } catch {}



        })



        $Script:TrayUiTimer = New-Object System.Windows.Forms.Timer



        $Script:TrayUiTimer.Interval = 1200



        $Script:TrayUiTimer.Add_Tick({



            try {



                if (Test-Path $DaemonStopSignal) {



                    [System.Windows.Forms.Application]::ExitThread()



                    return



                }



                if (Test-Path $DaemonHeartbeatPath) {



                    $hbRaw = [System.IO.File]::ReadAllText($DaemonHeartbeatPath, [System.Text.Encoding]::UTF8)



                    $hb = $hbRaw | ConvertFrom-Json



                    if ($hb.statusLine -and $Script:TrayMenuStatus.Text -ne $hb.statusLine) {



                        $Script:TrayMenuStatus.Text = [string]$hb.statusLine



                    }



                    if ($hb.quotaLine -and $Script:TrayMenuQuota.Text -ne $hb.quotaLine) {



                        $Script:TrayMenuQuota.Text = [string]$hb.quotaLine



                    }



                    if ($hb.tooltip -and $Script:TrayIconObj.Text -ne $hb.tooltip) {



                        $tStr = [string]$hb.tooltip



                        if ($tStr.Length -gt 62) { $tStr = $tStr.Substring(0, 62) }



                        $Script:TrayIconObj.Text = $tStr



                    }



                    if ($hb.badgeColor -and $hb.badgeColor -ne $Script:TrayCurrentColor -and $Script:TrayCachedIcons.ContainsKey([string]$hb.badgeColor)) {



                        $Script:TrayCurrentColor = [string]$hb.badgeColor



                        $Script:TrayIconObj.Icon = $Script:TrayCachedIcons[$Script:TrayCurrentColor]



                    }



                }



            } catch {}



        })



        $Script:TrayUiTimer.Start()



        [System.Windows.Forms.Application]::Run()



    } finally {



        if ($Script:TrayUiTimer) {



            try { $Script:TrayUiTimer.Stop(); $Script:TrayUiTimer.Dispose() } catch {}



        }



        if ($Script:TrayIconObj) {



            try { $Script:TrayIconObj.Visible = $false; $Script:TrayIconObj.Dispose() } catch {}



        }



        if ($Script:BgPowerShell) {



            try { $Script:BgPowerShell.Stop(); $Script:BgPowerShell.Dispose() } catch {}



        }



        if ($Script:BgRunspace) {



            try { $Script:BgRunspace.Close(); $Script:BgRunspace.Dispose() } catch {}



        }



        if (Test-Path $DaemonPidPath)       { Remove-Item $DaemonPidPath -Force -ErrorAction SilentlyContinue }



        if (Test-Path $DaemonStopSignal)    { Remove-Item $DaemonStopSignal -Force -ErrorAction SilentlyContinue }



        if (Test-Path $DaemonHeartbeatPath) { Remove-Item $DaemonHeartbeatPath -Force -ErrorAction SilentlyContinue }



    }



}



function Invoke-DaemonMonitorWorkerLoop {



    param(



        [int]$PollIntervalSec = 3,



        [switch]$RunOnce



    )



    $ErrorActionPreference = "Continue"



    # 严格的官方客户端限额正则（仅匹配 %APPDATA%\Antigravity\logs\*.log 白名单日志）



    $quotaRegex = '(?i)(?:RESOURCE_EXHAUSTED|QUOTA_EXHAUSTED|Model quota limit exceeded|Individual quota reached|exhausted your capacity|Your prompt limit has been reached|You have reached the request limit|\b429\s+Too\s+Many\s+Requests\b)'



    $cursors = @{}



    $initialFiles = Get-MonitoredLogFiles



    foreach ($f in $initialFiles) {



        try {



            if (Test-Path $f) {



                $item = Get-Item $f



                $cursors[$f] = $item.Length



            }



        } catch {}



    }



    $lastSwitchTime = [DateTime]::MinValue



    $debounceSeconds = 60



    $tickCount = 0



    while ($true) {



        if (Test-Path $DaemonStopSignal) { break }



        if (-not $RunOnce -and (Test-Path $DaemonPidPath)) {



            try {



                $trayPid = [int](Get-Content $DaemonPidPath -Raw -Encoding ASCII).Trim()



                if ($trayPid -gt 0 -and (-not (Get-Process -Id $trayPid -ErrorAction SilentlyContinue))) {



                    break



                }



            } catch {}



        }



        $tickCount++



        $now = Get-Date



        $pool = Get-SlotPoolState



        $currSlot = [string]$pool.currentSlot



        $currEmail = ""



        if ($currSlot -and $pool.slots.PSObject.Properties[$currSlot]) {



            $currEmail = [string]$pool.slots.PSObject.Properties[$currSlot].Value.email



        }



        $statusLine = "● 正在监听 | 当前槽位 [$currSlot] ($currEmail)"



        $quotaLine  = "实时剩余: 等待 AGY2 LanguageServer..."



        $tooltip    = "AGY守护[运行中] 槽位:[$currSlot]`n双击图标打开实时配额看板"



        $badgeColor = "Green"



        # 1. 核心限额源 A：本地 LanguageServer Connect-RPC 实时配额桶 (RetrieveUserQuotaSummary / GetUserStatus)



        $lsQuota = Get-LocalLanguageServerQuota
        if ($lsQuota -and $currSlot -and $pool.slots.PSObject.Properties[$currSlot]) {
            $currSlotObj = $pool.slots.PSObject.Properties[$currSlot].Value
            Apply-QuotaSnapshotToSlotObject -SlotObj $currSlotObj -QuotaSnap $lsQuota -IsCurrentActiveSlot $true
            try { Save-SlotPoolState -State $pool } catch {}

            $g5 = if ($null -ne $lsQuota.Gemini5hPct)     { "$($lsQuota.Gemini5hPct)%" }     else { "--" }
            $gw = if ($null -ne $lsQuota.GeminiWeeklyPct) { "$($lsQuota.GeminiWeeklyPct)%" } else { "--" }
            $ar = if ($null -ne $lsQuota.ArgonWeeklyPct)  { "$($lsQuota.ArgonWeeklyPct)%" }  else { "--" }
            $c5 = if ($null -ne $lsQuota.Claude5hPct)     { "$($lsQuota.Claude5hPct)%" }     else { "--" }

            $readyCnt = @($pool.slots.PSObject.Properties | Where-Object { $_.Value.status -eq "ready" -or $_.Value.status -eq "active" }).Count
            $quotaLine = "实时剩余: Gemini 5h:$g5 周:$gw | Argon:$ar | Claude 5h:$c5"
            $tooltip   = "AGY守护[运行中] 槽位:[$currSlot]`nGemini 5h:$g5 周:$gw | Argon:$ar | 备用:$readyCnt"

            if (($null -ne $lsQuota.Gemini5hPct -and $lsQuota.Gemini5hPct -le 20) -or ($null -ne $lsQuota.GeminiWeeklyPct -and $lsQuota.GeminiWeeklyPct -le 10) -or ($null -ne $lsQuota.ArgonWeeklyPct -and $lsQuota.ArgonWeeklyPct -le 10)) {
                $badgeColor = "Yellow"
            }

            $activeGrp = Get-CurrentActiveModelGroup
            $shouldSwitch = $false
            $switchReason = ""
            $switchResetTime = ""
            $isWeeklyLimit = $false

            if ($activeGrp -eq "Argon") {
                if ($null -ne $lsQuota.ArgonWeeklyPct -and $lsQuota.ArgonWeeklyPct -le 1) {
                    $shouldSwitch = $true
                    $switchReason = "Local RPC 检测到当前会话使用的 [Gemini 4 Argon] 周配额已耗尽 (剩余 <= 1%)"
                    $switchResetTime = [string]$lsQuota.ResetTimeArgon
                    $isWeeklyLimit = $true
                }
            } elseif ($activeGrp -eq "Claude") {
                if (($null -ne $lsQuota.Claude5hPct -and $lsQuota.Claude5hPct -le 1) -or ($null -ne $lsQuota.ClaudeWeeklyPct -and $lsQuota.ClaudeWeeklyPct -le 1)) {
                    $shouldSwitch = $true
                    $isWeekly = ($null -ne $lsQuota.ClaudeWeeklyPct -and $lsQuota.ClaudeWeeklyPct -le 1)
                    $switchReason = if ($isWeekly) { "Local RPC 检测到当前会话使用的 [Claude/GPT] 周配额已耗尽 (剩余 <= 1%)" } else { "Local RPC 检测到当前会话使用的 [Claude/GPT] 5小时限额已耗尽 (剩余 <= 1%)" }
                    $switchResetTime = if ($isWeekly) { [string]$lsQuota.ResetTimeClaudeWeekly } else { [string]$lsQuota.ResetTime5h }
                    $isWeeklyLimit = $isWeekly
                }
            } else {
                if (($null -ne $lsQuota.Gemini5hPct -and $lsQuota.Gemini5hPct -le 1) -or ($null -ne $lsQuota.GeminiWeeklyPct -and $lsQuota.GeminiWeeklyPct -le 1) -or $lsQuota.Is5hExhausted -or $lsQuota.IsWeeklyExhausted) {
                    $shouldSwitch = $true
                    $isWeekly = ($null -ne $lsQuota.GeminiWeeklyPct -and $lsQuota.GeminiWeeklyPct -le 1) -or $lsQuota.IsWeeklyExhausted
                    $switchReason = if ($isWeekly) { "Local RPC 检测到当前账号 [Gemini 常规组] 周配额已耗尽 (剩余 <= 1%)" } else { "Local RPC 检测到当前账号 [Gemini 常规组] 5小时配额已耗尽 (剩余 <= 1%)" }
                    $switchResetTime = if ($isWeekly) { [string]$lsQuota.ResetTimeWeekly } else { [string]$lsQuota.ResetTime5h }
                    $isWeeklyLimit = $isWeekly
                }
            }

            if ($shouldSwitch -and (($now - $lastSwitchTime).TotalSeconds -ge $debounceSeconds)) {
                $lastSwitchTime = $now
                [void](Switch-ToNextAvailableSlot -Reason $switchReason -AutoRestartApp:$true -IsWeeklyLimit:$isWeeklyLimit -ServerResetTime $switchResetTime -TargetModelGroup $activeGrp)
                continue
            }
        }



        # 2. 更新心跳与托盘 UI 共享状态文件



        try {



            $hb = [ordered]@{



                pid         = $PID



                timestamp   = $now.ToString("yyyy-MM-dd HH:mm:ss")



                currentSlot = $currSlot



                trayVisible = $true



                lsConnected = [bool]($null -ne $lsQuota)



                statusLine  = $statusLine



                quotaLine   = $quotaLine



                tooltip     = $tooltip



                badgeColor  = $badgeColor



            }



            Write-Utf8NoBom -Path $DaemonHeartbeatPath -Content ($hb | ConvertTo-Json -Compress)



        } catch {}



        # 3. 核心限额源 B：严格白名单系统日志 (%APPDATA%\Antigravity\logs\*.log) 增量扫描



        $activeFiles = Get-MonitoredLogFiles



        foreach ($filePath in $activeFiles) {



            if (-not (Test-Path $filePath)) { continue }



            $prevOffset = if ($cursors.ContainsKey($filePath)) {



                $cursors[$filePath]



            } else {



                try { (Get-Item $filePath).Length } catch { 0L }



            }



            try {



                $item = Get-Item $filePath



                $currentLength = $item.Length



                if ($currentLength -lt $prevOffset) { $prevOffset = 0 }



                if ($currentLength -gt $prevOffset) {



                    $bytesToRead = $currentLength - $prevOffset



                    $seekPos = $prevOffset



                    if ($bytesToRead -gt 262144) { $seekPos = $currentLength - 262144 }



                    $fs = [System.IO.File]::Open($filePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)



                    $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)



                    [void]$fs.Seek($seekPos, [System.IO.SeekOrigin]::Begin)



                    $newContent = $sr.ReadToEnd()



                    $sr.Close()



                    $fs.Close()



                    $cursors[$filePath] = $currentLength



                    if ($newContent -match $quotaRegex) {



                        $matchedText = $Matches[0]



                        $now = Get-Date



                        if (($now - $lastSwitchTime).TotalSeconds -ge $debounceSeconds) {



                            $lastSwitchTime = $now



                            $reasonStr = "系统日志捕获限额特征: '$matchedText' (来源: $([System.IO.Path]::GetFileName($filePath)))"



                            [void](Switch-ToNextAvailableSlot -Reason $reasonStr -AutoRestartApp:$true)



                        }



                    }



                }



            } catch {}



        }



        if ($RunOnce) { break }



        Start-Sleep -Seconds $PollIntervalSec



    }



}



function Get-DaemonStatus {



    $isRunning = $false



    $pidNum = $null



    $proc = $null



    $heartbeatAgeSec = $null



    $trayVisible = $false



    if (Test-Path $DaemonPidPath) {



        try {



            $savedPid = (Get-Content $DaemonPidPath -Raw -Encoding ASCII).Trim()



            if ($savedPid -match '^\d+$') {



                $p = Get-Process -Id ([int]$savedPid) -ErrorAction SilentlyContinue



                if ($p -and $p.ProcessName -match 'powershell|pwsh') {



                    $isRunning = $true



                    $pidNum = [int]$savedPid



                    $proc = $p



                }



            }



        } catch {}



    }



    if ($isRunning -and (Test-Path $DaemonHeartbeatPath)) {



        try {



            $hbRaw = Read-Utf8StripBom -Path $DaemonHeartbeatPath



            $hbObj = $hbRaw | ConvertFrom-Json



            if ($hbObj.timestamp) {



                $hbTime = [DateTime]::Parse([string]$hbObj.timestamp)



                $heartbeatAgeSec = [Math]::Max(0, [int]((Get-Date) - $hbTime).TotalSeconds)



            }



            if ($hbObj.PSObject.Properties["trayVisible"]) {



                $trayVisible = [bool]$hbObj.trayVisible



            }



        } catch {}



    }



    return [PSCustomObject]@{



        IsRunning       = $isRunning



        PID             = $pidNum



        Process         = $proc



        HeartbeatAgeSec = $heartbeatAgeSec



        TrayVisible     = $trayVisible



    }



}



function Start-DaemonBackground {



    param(



        [switch]$AutoRestartApp = $true,



        [double]$CooldownHours = 5.0,



        [int]$PollIntervalSec = 3



    )



    $status = Get-DaemonStatus



    if ($status.IsRunning) {



        Write-Host ("[*] 检测到已有后台守护进程 (PID: {0})，正在自动热重载为最新版本..." -f $status.PID) -ForegroundColor Cyan



        Stop-DaemonBackground



        Start-Sleep -Milliseconds 400



    }



    if (-not (Test-Path $HelperRoot)) {



        New-Item -ItemType Directory -Path $HelperRoot -Force | Out-Null



    }



    if (Test-Path $DaemonStopSignal) { Remove-Item $DaemonStopSignal -Force -ErrorAction SilentlyContinue }



    $scriptPath = $Script:ResolvedScriptPath



    $workDir    = $Script:ResolvedScriptDir



    # 优先使用原生 VBS WshShell.Run(..., 0, False) 配合 -File 启动：



    # 1) 100% 脱离 Windows 11 Terminal 的 Job Object (关闭控制台窗口绝不连带退出)



    # 2) 窗口样式 0 (SW_HIDE) 完全无黑框，且保留合法的隐藏控制台句柄供 PowerShell 稳定运行



    $vbsPath = Join-Path $workDir "daemon_runner.vbs"



    if (Test-Path $vbsPath) {



        try {



            & wscript.exe //B //NoLogo $vbsPath



        } catch {}



    }



    Start-Sleep -Milliseconds 500



    $status = Get-DaemonStatus



    if (-not $status.IsRunning) {



        $daemonArgs = "-NoLogo -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`" -Action daemon -AutoRestartApp -CooldownHours $CooldownHours -PollIntervalSec $PollIntervalSec"



        [void](Start-TrulyHiddenDetachedProcess -FilePath "powershell.exe" -Arguments $daemonArgs -WorkingDirectory $workDir)



    }



    $started = $false



    for ($i = 0; $i -lt 24; $i++) {



        Start-Sleep -Milliseconds 250



        $status = Get-DaemonStatus



        if ($status.IsRunning) {



            $started = $true



            break



        }



    }



    if ($started) {



        Write-Host ("[✓] 无人值守自动切号守护 + 右下角系统托盘小标已在后台无窗口常驻启动 (PID: {0})！" -f $status.PID) -ForegroundColor Green



        Write-Host "    - 已采用原生 VBS 0窗口脱钩 + 进程内双线程 Runspace 架构：无黑框、不闪退、托盘菜单 0ms 响应" -ForegroundColor Cyan



        Write-Host "    - 现在可直接关闭所有命令行窗口（或按 Q 退出），后台守护与托盘小标将持续常驻" -ForegroundColor Cyan



        Send-DesktopNotification -Title "Antigravity 无人值守守护已启动" -Message "右下角系统托盘 [A] 图标已常驻（PID: $($status.PID)），触发限额时将自动切号并恢复所有并发原会话。"



    } else {



        Write-Host "[!] 守护进程启动超时，请检查脚本路径权限。" -ForegroundColor Yellow



    }



}



function Stop-DaemonBackground {



    $status = Get-DaemonStatus



    if (-not $status.IsRunning) {



        Write-Host "[✓] 自动切号守护进程当前未运行。" -ForegroundColor Gray



        if (Test-Path $DaemonPidPath) { Remove-Item $DaemonPidPath -Force -ErrorAction SilentlyContinue }



        return



    }



    Write-Host ("[!] 正在停止自动切号守护进程 (PID: {0})..." -f $status.PID) -ForegroundColor Yellow



    Set-Content -Path $DaemonStopSignal -Value "stop" -Encoding ASCII



    for ($i = 0; $i -lt 15; $i++) {



        Start-Sleep -Milliseconds 200



        $st = Get-DaemonStatus



        if (-not $st.IsRunning) { break }



    }



    $st = Get-DaemonStatus



    if ($st.IsRunning) {



        try { Stop-Process -Id $status.PID -Force -ErrorAction SilentlyContinue } catch {}



    }



    if (Test-Path $DaemonPidPath)       { Remove-Item $DaemonPidPath -Force -ErrorAction SilentlyContinue }



    if (Test-Path $DaemonStopSignal)    { Remove-Item $DaemonStopSignal -Force -ErrorAction SilentlyContinue }



    if (Test-Path $DaemonHeartbeatPath) { Remove-Item $DaemonHeartbeatPath -Force -ErrorAction SilentlyContinue }



    Write-Host "[✓] 自动切号守护进程已安全停止。" -ForegroundColor Green



    Send-DesktopNotification -Title "Antigravity 自动切号守护已停止" -Message "后台守护进程与右下角托盘小标已正常退出。"



}



function Format-QuotaPairCell {



    param($Pct5h, $PctWeekly)



    $s5 = if ($null -ne $Pct5h -and $Pct5h -ne "") { "{0,3}%" -f [int]$Pct5h } else { " -- " }



    $sw = if ($null -ne $PctWeekly -and $PctWeekly -ne "") { "{0,3}%" -f [int]$PctWeekly } else { " -- " }



    return "$s5 / $sw"



}



function Show-SlotPoolDashboard {



    param([switch]$ForceCloudSync)



    if ($ForceCloudSync) {



        $state = Sync-AllSlotsQuotaInfo



    } else {



        $state = Get-SlotPoolState



        $lsLive = Get-LocalLanguageServerQuota



        if ($lsLive -and $state.currentSlot -and $state.slots.PSObject.Properties[$state.currentSlot]) {



            Apply-QuotaSnapshotToSlotObject -SlotObj $state.slots.PSObject.Properties[$state.currentSlot].Value -QuotaSnap $lsLive -IsCurrentActiveSlot $true



            Save-SlotPoolState -State $state



        }



    }



    $daemonStatus = Get-DaemonStatus



    $summary = Get-CurrentActiveAccountSummary



    $running = @(Get-RunningAntigravityProcesses)



    $ctxInfo = Get-LatestConversationContextInfo



    $now = Get-Date



    Write-Host ""



    Write-Host "========================================================================================" -ForegroundColor Cyan



    Write-Host "   Antigravity 5小时/周限额全自动切号与全账号实时配额看板 (原会话续接 · 托盘小标)       " -ForegroundColor Cyan



    Write-Host "========================================================================================" -ForegroundColor Cyan



    $daemonColor = if ($daemonStatus.IsRunning) { "Green" } else { "Yellow" }



    $hbText = if ($null -ne $daemonStatus.HeartbeatAgeSec) { " | 心跳: $($daemonStatus.HeartbeatAgeSec)s前" } else { "" }



    $daemonText = if ($daemonStatus.IsRunning) {



        "● 后台无窗口常驻中 (PID: $($daemonStatus.PID) | 右下角托盘 [A] 图标已常驻$hbText)"



    } else {



        "○ 未运行 (按 [5] 或双击 [开启自动切号守护.bat] 启动后台守护与右下角托盘图标)"



    }



    Write-Host "  无人值守守护状态   : " -NoNewline



    Write-Host $daemonText -ForegroundColor $daemonColor



    Write-Host ("  AGY2 界面当前账号  : {0} (槽位: [{1}] | 指纹: {2})" -f $summary.Agy2UiEmail, $(if ($state.currentSlot) { $state.currentSlot } else { "未匹配" }), $summary.TokenFingerprint) -ForegroundColor Green



    $lsStatusText = if ($Script:CachedLsQuota) {



        "已连接本地 LanguageServer RPC ($($Script:CachedLsQuota.Source))"



    } else {



        "等待 AGY2 LanguageServer 就绪"



    }



    $origConvTitle = if ($ctxInfo.ConversationTitle) { "[$($ctxInfo.ConversationTitle)]" } else { "(切号时自动从面包屑/边栏锁定)" }



    $activeGrp = Get-CurrentActiveModelGroup
    Write-Host ("  当前活跃会话模型组: [{0}] (守护切号将优先盯紧此模型组水位)" -f $activeGrp) -ForegroundColor Yellow
    Write-Host ("  原会话锁定与RPC源  : 原会话 {0} | {1}" -f $origConvTitle, $lsStatusText) -ForegroundColor Cyan



    Write-Host ("  运行中客户端进程   : {0}" -f $(if ($running.Count -gt 0) { ($running | ForEach-Object { "$($_.ProcessName)(PID:$($_.Id))" }) -join ", " } else { "无" }))



    Write-Host "----------------------------------------------------------------------------------------" -ForegroundColor DarkGray



    Write-Host "  全账号槽位池实时剩余配额总览 (Gemini 5h/周 & Claude 5h/周 | 按 [R] 刷新全部账号云端配额):" -ForegroundColor Yellow



    $order = @($state.slotOrder)



    if ($order.Count -eq 0) {



        Write-Host "    (槽位池暂无账号，请在 AGY2 登录后使用 [1] 或 [保存当前账号至槽位.bat] 录入槽位)" -ForegroundColor DarkGray



    } else {



        Write-Host ("  {0,-4} {1,-6} {2,-8} {3,-22} {4,-14} {5,-10} {6,-14} {7,-18} {8}" -f "#", "槽位", "状态", "账号邮箱", "Gemini(5h/周)", "Argon(周)", "Claude(5h/周)", "重置/冷却倒计时", "切换") -ForegroundColor White
        Write-Host "  ------------------------------------------------------------------------------------------------" -ForegroundColor DarkGray



        $fpGroups = @{}



        for ($i = 0; $i -lt $order.Count; $i++) {



            $name = $order[$i]



            $prop = $state.slots.PSObject.Properties[$name]



            if (-not $prop) { continue }



            $s = $prop.Value



            Ensure-SlotObjectSchema -SlotObj $s



            $fp = [string](Get-SafeProp $s "tokenFingerprint" "unknown")



            if ($fp -ne "unknown" -and $fp -ne "none") {



                if (-not $fpGroups.ContainsKey($fp)) { $fpGroups[$fp] = [System.Collections.Generic.List[string]]::new() }



                $fpGroups[$fp].Add($name)



            }



            $g5Val = Get-SafeProp $s "gemini5hPct"



            $gwVal = Get-SafeProp $s "geminiWeeklyPct"



            $c5Val = Get-SafeProp $s "claude5hPct"



            $cwVal = Get-SafeProp $s "claudeWeeklyPct"



            # 若槽位处于 COOLDOWN 且尚未缓存 5h 百分比，显式显示为 0%



            if ($s.status -eq "cooldown" -and $null -eq $g5Val) {



                $g5Val = 0



            }



            $arVal   = Get-SafeProp $s "argonWeeklyPct"
            $gemCell = Format-QuotaPairCell -Pct5h $g5Val -PctWeekly $gwVal
            $arCell  = if ($null -ne $arVal -and $arVal -ne "") { "{0,3}%" -f [int]$arVal } else { " -- " }
            $claCell = Format-QuotaPairCell -Pct5h $c5Val -PctWeekly $cwVal

            $minGem   = if ($null -ne $g5Val -and $null -ne $gwVal) { [Math]::Min([int]$g5Val, [int]$gwVal) } elseif ($null -ne $g5Val) { [int]$g5Val } else { $null }
            $gemColor = if ($null -eq $minGem) { "Gray" } elseif ($minGem -le 15) { "Red" } elseif ($minGem -le 45) { "Yellow" } else { "Green" }
            $arColor  = if ($null -eq $arVal) { "Gray" } elseif ($arVal -le 15) { "Red" } elseif ($arVal -le 45) { "Yellow" } else { "Green" }



            $statusText = $s.status



            $statusColor = "White"



            $countdownStr = "就绪 (待命备用)"



            $r5Str = ""



            $rt5Prop = Get-SafeProp $s "resetTime5h"



            if ($rt5Prop) {



                try {



                    $rtDt = [DateTime]::Parse([string]$rt5Prop).ToLocalTime()



                    if ($rtDt -gt $now) {



                        $remSpan = $rtDt - $now



                        $r5Str = ("{0:D2}h{1:D2}m后重置" -f [int]$remSpan.TotalHours, $remSpan.Minutes)



                    }



                } catch {}



            }



            $isActive = ($name -eq $state.currentSlot)



            if ($isActive) {



                $statusText = "ACTIVE"



                $statusColor = "Green"



                $countdownStr = if ($r5Str) { "★ 使用中($r5Str)" } else { "★ 当前使用中" }



            } elseif ($s.status -eq "cooldown") {



                $isWeekly = ((Get-SafeProp $s "cooldownType" "hourly") -eq "weekly")



                $statusText = if ($isWeekly) { "WEEKLY" } else { "COOLDOWN" }



                $statusColor = if ($isWeekly) { "Magenta" } else { "Yellow" }



                $cUntil = Get-SafeProp $s "cooldownUntil"



                if ($cUntil) {



                    try {



                        $thaw = [DateTime]::Parse([string]$cUntil)



                        if ($now -ge $thaw) {



                            $statusText = "READY"



                            $statusColor = "Cyan"



                            $countdownStr = "冷却已解冻"



                        } else {



                            $diff = $thaw - $now



                            if ($diff.TotalDays -ge 1.0) {



                                $countdownStr = ("周冷却({0}d {1:D2}h)" -f [int]$diff.TotalDays, $diff.Hours)



                            } else {



                                $countdownStr = ("冷却({0:D2}h {1:D2}m)" -f [int]$diff.TotalHours, $diff.Minutes)



                            }



                        }



                    } catch {



                        $countdownStr = "冷却中"



                    }



                } else {



                    $countdownStr = "冷却中"



                }



            } else {



                $statusText = "READY"



                $statusColor = "Cyan"



                if ($r5Str) { $countdownStr = "就绪($r5Str)" }



            }



            $shortEmail = ($s.email -replace '(.{20})..+', '$1..')



            Write-Host ("  [{0,-2}] {1,-6} " -f ($i + 1), $s.slotName) -NoNewline
            Write-Host ("{0,-8} " -f $statusText) -ForegroundColor $statusColor -NoNewline
            Write-Host ("{0,-22} " -f $shortEmail) -NoNewline
            Write-Host ("{0,-14} " -f $gemCell) -ForegroundColor $gemColor -NoNewline
            Write-Host ("{0,-10} " -f $arCell) -ForegroundColor $arColor -NoNewline
            Write-Host ("{0,-14} " -f $claCell) -NoNewline
            Write-Host ("{0,-18} {1}次" -f $countdownStr, [int](Get-SafeProp $s "switchCount" 0))



        }



        foreach ($k in $fpGroups.Keys) {



            if ($fpGroups[$k].Count -gt 1) {



                Write-Host "  --------------------------------------------------------------------------------------" -ForegroundColor DarkGray



                Write-Host ("  [!] 重复凭据告警：槽位 [{0}] 的底层 Token 指纹完全相同 ({1})！" -f ($fpGroups[$k] -join ", "), $k) -ForegroundColor Red



            }



        }



    }



    Write-Host "========================================================================================" -ForegroundColor Cyan



}



# ============================================================================



# 4. 官方合规兜底：一键切换 OAuth 订阅模式 / Gemini API Key / Google Cloud ADC



# ============================================================================



function Set-AntigravityCliAuthMode {



    param(



        [ValidateSet("oauth", "apikey", "adc")]



        [string]$TargetMode,



        [string]$Key = ""



    )



    if (-not (Test-Path $AgyCliDir)) {



        New-Item -ItemType Directory -Path $AgyCliDir -Force | Out-Null



    }



    $settingsObj = @{}



    if (Test-Path $AgyCliConfigPath) {



        try {



            $cleanCfg = Read-Utf8StripBom -Path $AgyCliConfigPath



            $raw = $cleanCfg | ConvertFrom-Json



            foreach ($prop in $raw.PSObject.Properties) {



                $settingsObj[$prop.Name] = $prop.Value



            }



        } catch {



            Copy-Item $AgyCliConfigPath "$AgyCliConfigPath.bak" -Force



        }



    }



    switch ($TargetMode) {



        "oauth" {



            if ($settingsObj.ContainsKey("modelProvider")) {



                [void]$settingsObj.Remove("modelProvider")



            }



            $env:AGY_ADC_AUTH = $null



            [Environment]::SetEnvironmentVariable("AGY_ADC_AUTH", $null, "User")



            Write-Utf8NoBom -Path $AgyCliConfigPath -Content ($settingsObj | ConvertTo-Json -Depth 6)



            Write-Host "[✓] 已切换回【个人 Google 账号订阅 (OAuth) 模式】。" -ForegroundColor Green



        }



        "apikey" {



            $settingsObj["modelProvider"] = "gemini"



            Write-Utf8NoBom -Path $AgyCliConfigPath -Content ($settingsObj | ConvertTo-Json -Depth 6)



            $env:AGY_ADC_AUTH = $null



            [Environment]::SetEnvironmentVariable("AGY_ADC_AUTH", $null, "User")



            if (-not [string]::IsNullOrWhiteSpace($Key)) {



                $env:GEMINI_API_KEY = $Key.Trim()



                [Environment]::SetEnvironmentVariable("GEMINI_API_KEY", $Key.Trim(), "User")



                Write-Host "[✓] 已在用户级与当前会话设置 GEMINI_API_KEY。" -ForegroundColor Green



            } else {



                $currKey = [Environment]::GetEnvironmentVariable("GEMINI_API_KEY", "User")



                if ([string]::IsNullOrWhiteSpace($currKey) -and [string]::IsNullOrWhiteSpace($env:GEMINI_API_KEY)) {



                    $inputKey = Read-Host "请输入你的 Google AI Studio GEMINI_API_KEY（留空则稍后自行设置）"



                    if (-not [string]::IsNullOrWhiteSpace($inputKey)) {



                        $env:GEMINI_API_KEY = $inputKey.Trim()



                        [Environment]::SetEnvironmentVariable("GEMINI_API_KEY", $inputKey.Trim(), "User")



                        Write-Host "[✓] 已在用户级与当前会话设置 GEMINI_API_KEY。" -ForegroundColor Green



                    }



                }



            }



            Write-Host "[✓] 已切换至【官方 Gemini API Key 按量兜底模式】(settings.json -> modelProvider: gemini)。" -ForegroundColor Green



        }



        "adc" {



            if ($settingsObj.ContainsKey("modelProvider")) {



                [void]$settingsObj.Remove("modelProvider")



            }



            Write-Utf8NoBom -Path $AgyCliConfigPath -Content ($settingsObj | ConvertTo-Json -Depth 6)



            $env:AGY_ADC_AUTH = "true"



            [Environment]::SetEnvironmentVariable("AGY_ADC_AUTH", "true", "User")



            Write-Host "[✓] 已开启【Google Cloud Application Default Credentials (ADC) 模式】(AGY_ADC_AUTH=true)。" -ForegroundColor Green



        }



    }



}



# ============================================================================



# 5. 跨账号上下文接力器



# ============================================================================



function New-WorkspaceHandoverFile {



    param(



        [string]$WorkspacePath = (Get-Location).Path,



        [switch]$StartAgySession



    )



    $resolvedPath = (Resolve-Path $WorkspacePath).Path



    $handoverFile = Join-Path $resolvedPath "ANTIGRAVITY_HANDOVER.md"



    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")



    $gitBranch = "(非 Git 仓库或未安装 Git)"



    $gitStatus = "(无)"



    $gitDiffStat = "(无)"



    $gitRecentCommits = "(无)"



    Push-Location $resolvedPath



    try {



        $isGit = & git rev-parse --is-inside-work-tree 2>$null



        if ($LASTEXITCODE -eq 0 -and $isGit -eq "true") {



            $gitBranch = (& git branch --show-current 2>$null) -join ""



            $gitStatus = (& git status -s 2>$null) -join "`n"



            $gitDiffStat = (& git diff --stat 2>$null) -join "`n"



            $gitRecentCommits = (& git log -n 5 --oneline 2>$null) -join "`n"



            if ([string]::IsNullOrWhiteSpace($gitStatus)) { $gitStatus = "(工作区干净，无未提交变更)" }



            if ([string]::IsNullOrWhiteSpace($gitDiffStat)) { $gitDiffStat = "(无未暂存文件行级差异)" }



        }



    } catch {}



    finally {



        Pop-Location



    }



    $ctx = Get-LatestConversationContextInfo



    $lastConvId = if ($ctx.ConversationId) { $ctx.ConversationId } else { "(未找到缓存会话 ID)" }



    $userNote = "继续完成当前未提交代码变更，验证构建与单元测试，并推进下一阶段功能实现。"



    $markdown = @"



# Antigravity 跨账号/跨会话任务接力档案 (Context Handover)



- **生成时间**：$timestamp



- **项目路径**：`$resolvedPath`



- **最近活跃会话 ID**：`$lastConvId`



- **本地记忆目录**：`$($ctx.BrainDir)`



- **当前 Git 分支**：`$gitBranch`



## 1. 待继续的核心目标



$userNote



## 2. 当前工作区未提交文件状态 (`git status -s`)



```text



$gitStatus



```



## 3. 当前代码改动统计 (`git diff --stat`)



```text



$gitDiffStat



```



## 4. 最近 5 次提交记录 (`git log -n 5 --oneline`)



```text



$gitRecentCommits



```



## 5. 给新会话 Agent 的接力指令



> $($ctx.ResumePrompt)



"@



    Write-Utf8NoBom -Path $handoverFile -Content $markdown



    Write-Host ("[✓] 已生成跨账号项目接力档案: {0}" -f $handoverFile) -ForegroundColor Green



    if ($StartAgySession) {



        Push-Location $resolvedPath



        try {



            & agy -p $ctx.ResumePrompt



        } finally {



            Pop-Location



        }



    }



    return $handoverFile



}



# ============================================================================



# 6. 状态面板与交互式菜单



# ============================================================================



function Show-StatusDashboard {



    Show-SlotPoolDashboard



}



function Start-InteractiveMenu {
    # 自动守护保障：若后台守护未运行，自动静默启动系统托盘常驻守护
    try {
        $daemonStatus = Get-DaemonStatus
        if (-not $daemonStatus.IsRunning) {
            Write-Host "[*] 检测到后台无人值守守护未运行，正在自动静默启动系统托盘守护..." -ForegroundColor Cyan
            Start-DaemonBackground -AutoRestartApp -CooldownHours $CooldownHours -PollIntervalSec $PollIntervalSec
        }
    } catch {}

    # 若后台守护正在运行且启动时间早于当前脚本更新时间，自动静默热重载守护进程以应用最新原会话恢复逻辑



    try {



        $st = Get-DaemonStatus



        $selfPath = $Script:ResolvedScriptPath



        if ($st.IsRunning -and $st.Process -and (Test-Path $selfPath)) {



            $scriptTime = (Get-Item $selfPath).LastWriteTime



            if ($st.Process.StartTime -lt $scriptTime) {



                Write-Host ("[*] 检测到脚本已更新，正在自动热重载后台无人值守守护进程 (原 PID: {0})..." -f $st.PID) -ForegroundColor Cyan



                Start-DaemonBackground -AutoRestartApp -CooldownHours $CooldownHours -PollIntervalSec $PollIntervalSec



            }



        }



    } catch {}



    while ($true) {



        Show-SlotPoolDashboard



        Write-Host ""



        Write-Host "请选择操作：" -ForegroundColor White



        Write-Host "  [1] 备份当前官方登录账号到加密槽位 (Save Current Account to Slot)"



        Write-Host "  [2] 手动切换至指定加密账号槽位     (Switch to Specific Slot & Auto-Resume)"



        Write-Host "  [3] 立即轮换切入下一个可用槽位     (Rotate to Next Slot & Auto-Resume)"



        Write-Host "  [4] 刷新本地看板状态               (Refresh Dashboard)"



        Write-Host "  [R] 刷新全部账号真实 5h/周 剩余配额 (Query Live Quota for All Saved Accounts)"



        Write-Host "  [5] 开启后台守护 + 右下角托盘小标   (Start Unattended Daemon & System Tray Icon)"



        Write-Host "  [6] 停止无人值守后台守护           (Stop Background Daemon)"



        Write-Host "  [7] 一键修复/重置受损的 AGY2 配置  (Repair app_storage.json Crash)"



        Write-Host "  [8] 切换 CLI 认证模式：个人订阅 OAuth <-> 官方 API Key / ADC 兜底"



        Write-Host "  [9] 重置槽位 5 小时冷却计时器      (Reset Cooldown Timers)"



        Write-Host "  [D] 删除已保存的加密槽位           (Delete Slot)"



        Write-Host "  [Q] 退出菜单 (不影响已启动的 AGY2 与后台守护)"



        Write-Host ""



        $choice = Read-Host "输入选项编号"



        if ([string]::IsNullOrWhiteSpace($choice)) { continue }



        try {



            switch ($choice.Trim().ToUpperInvariant()) {



                "1" {



                    $name = Read-Host "请输入要保存的槽位名称（例如 a, b, c 或直接回车自动分配）"



                    Save-CredentialSlot -SlotName $name



                }



                "2" {



                    $name = Read-Host "请输入要切换到的目标槽位名称"



                    $switchedEmail = Switch-CredentialSlot -SlotName $name -WorkspacePath $ProjectDir -CloseProcesses:$true



                    Restart-AntigravityApp -TargetEmail $switchedEmail -AutoResume:$true



                }



                "3" {



                    Switch-ToNextAvailableSlot -Reason "用户交互菜单手动轮换" -AutoRestartApp -WorkspacePath $ProjectDir



                }



                "4" {



                    # Loop refreshes dashboard



                }



                "R" {



                    [void](Sync-AllSlotsQuotaInfo)



                }



                "5" {



                    Start-DaemonBackground -AutoRestartApp -CooldownHours $CooldownHours -PollIntervalSec $PollIntervalSec



                }



                "6" {



                    Stop-DaemonBackground



                }



                "7" {



                    $currSummary = Get-CurrentActiveAccountSummary



                    $keepMail = if ($currSummary.ActiveEmail -and $currSummary.ActiveEmail -notmatch '未检测') { $currSummary.ActiveEmail } else { "user@gmail.com" }



                    [AntigravityCompliantHelper.NativeVaultV4]::UpdateAppStorageEmailSafely($AppStorageJson, $keepMail, $true)



                    Write-Host ("[✓] 已将 app_storage.json 重置为纯净无损状态 (绑定邮箱: {0})，彻底解决闪退！" -f $keepMail) -ForegroundColor Green



                }



                "8" {



                    Write-Host "可选模式：1 = oauth (个人订阅默认) | 2 = apikey (Google AI Studio API Key 兜底) | 3 = adc (Google Cloud ADC)" -ForegroundColor Cyan



                    $m = Read-Host "请选择模式 [1/2/3]"



                    if ($m -eq "1") { Set-AntigravityCliAuthMode -TargetMode "oauth" }



                    elseif ($m -eq "2") { Set-AntigravityCliAuthMode -TargetMode "apikey" }



                    elseif ($m -eq "3") { Set-AntigravityCliAuthMode -TargetMode "adc" }



                }



                "9" {



                    $s = Read-Host "请输入要重置的槽位名称（输入 all 重置所有槽位）"



                    Reset-SlotCooldown -SlotName $s



                }



                "D" {



                    $name = Read-Host "请输入要删除的槽位名称"



                    Remove-CredentialSlot -SlotName $name



                }



                "Q" {



                    return



                }



                default {



                    Write-Host "[!] 无效选项，请重新输入。" -ForegroundColor Yellow



                }



            }



        } catch {



            Write-Host ("[×] 操作出错: {0}" -f $_.Exception.Message) -ForegroundColor Red



        }



    }



}



# ============================================================================



# 7. 命令路由入口



# ============================================================================



switch ($Action) {



    "menu"           { Start-InteractiveMenu }



    "status"         { Show-StatusDashboard }



    "save"           { Save-CredentialSlot -SlotName $Slot }



    "switch"         {



        $switchedEmail = Switch-CredentialSlot -SlotName $Slot -GenerateHandover:$Handover -WorkspacePath $ProjectDir -NonInteractive:$Force -CloseProcesses:$true



        if ($AutoRestartApp -and (-not $NoRestartApp)) {



            Restart-AntigravityApp -TargetEmail $switchedEmail -AutoResume:$AutoResumeConversation



        }



    }



    "delete"         { Remove-CredentialSlot -SlotName $Slot }



    "mode"           { Set-AntigravityCliAuthMode -TargetMode $AuthMode -Key $ApiKey }



    "handover"       { New-WorkspaceHandoverFile -WorkspacePath $ProjectDir -StartAgySession:$LaunchAgy | Out-Null }



    "daemon"         { Start-PassiveLogWatcher -PollIntervalSec $PollIntervalSec -AutoRestartApp:$AutoRestartApp -RunOnce:$RunOnce }



    "daemon-worker"  { Invoke-DaemonMonitorWorkerLoop -PollIntervalSec $PollIntervalSec -RunOnce:$RunOnce }



    "start-daemon"   { Start-DaemonBackground -AutoRestartApp:$AutoRestartApp -CooldownHours $CooldownHours -PollIntervalSec $PollIntervalSec }



    "stop-daemon"    { Stop-DaemonBackground }



    "daemon-status"  {



        $st = Get-DaemonStatus



        if ($st.IsRunning) {



            Write-Host ("[✓] 守护进程正在后台运行中 (PID: {0})" -f $st.PID) -ForegroundColor Green



        } else {



            Write-Host "[!] 守护进程未在运行" -ForegroundColor Yellow



        }



    }



    "next-slot"      { Switch-ToNextAvailableSlot -Reason "用户手动触发轮换" -AutoRestartApp:$AutoRestartApp -GenerateHandover:$Handover -WorkspacePath $ProjectDir }



    "pool-status"    { Show-SlotPoolDashboard }



    "reset-cooldown" { Reset-SlotCooldown -SlotName $Slot }



    "repair-storage" {



        $currSummary = Get-CurrentActiveAccountSummary



        $keepMail = if ($currSummary.ActiveEmail -and $currSummary.ActiveEmail -notmatch '未检测') { $currSummary.ActiveEmail } else { "user@gmail.com" }



        [AntigravityCompliantHelper.NativeVaultV4]::UpdateAppStorageEmailSafely($AppStorageJson, $keepMail, $true)



        Write-Host ("[✓] 已重置净化 app_storage.json (绑定邮箱: {0})。" -f $keepMail) -ForegroundColor Green



    }



    "auto-resume"    { Invoke-UnattendedConversationResume -ResumePromptText $ResumePromptText -TargetConversationId $TargetConversationId -TargetProjectId $TargetProjectId }



    "refresh-quota"  { [void](Sync-AllSlotsQuotaInfo); Show-SlotPoolDashboard }



}



