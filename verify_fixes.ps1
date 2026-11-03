# ==============================================================================
# Comprehensive Verification Test Suite for Antigravity Helper Core Reliability
# ==============================================================================

$ErrorActionPreference = "Stop"
Write-Host ">>> Starting Core Reliability & UI Verification Suite..." -ForegroundColor Cyan

# 1. Dot-source the modified script to load types and functions
. (Join-Path $PSScriptRoot "antigravity_compliant_helper.ps1") -Action load-only

$passCount = 0
$failCount = 0

function Assert-Test([string]$Name, [bool]$Condition, [string]$Details = "") {
    if ($Condition) {
        Write-Host "  [PASS] $Name" -ForegroundColor Green
        $script:passCount++
    } else {
        Write-Host "  [FAIL] $Name : $Details" -ForegroundColor Red
        $script:failCount++
    }
}

# ------------------------------------------------------------------------------
# Test 1: ConvertTo-SafeInt
# ------------------------------------------------------------------------------
Write-Host "`n--- Test 1: ConvertTo-SafeInt Robustness ---" -ForegroundColor Yellow
Assert-Test "Null input safely returns default" ((ConvertTo-SafeInt $null -Default -1) -eq -1)
Assert-Test "Empty string safely returns default" ((ConvertTo-SafeInt "" -Default -1) -eq -1)
Assert-Test "'--' string safely returns default" ((ConvertTo-SafeInt "--" -Default -1) -eq -1)
Assert-Test "'  --  ' string safely returns default" ((ConvertTo-SafeInt "  --  " -Default -1) -eq -1)
Assert-Test "Valid string '95' returns 95" ((ConvertTo-SafeInt "95") -eq 95)
Assert-Test "Valid int 0 returns 0" ((ConvertTo-SafeInt 0) -eq 0)
Assert-Test "Invalid alphanumeric 'abc' safely returns default" ((ConvertTo-SafeInt "abc" -Default 42) -eq 42)

# ------------------------------------------------------------------------------
# Test 2: Kernel-level Atomic File Replacement (MoveFileExW)
# ------------------------------------------------------------------------------
Write-Host "`n--- Test 2: Kernel-level MoveFileAtomic ---" -ForegroundColor Yellow
$testDir = Join-Path $PSScriptRoot "test_atomic_sandbox"
if (Test-Path $testDir) { Remove-Item $testDir -Recurse -Force }
New-Item -ItemType Directory -Path $testDir -Force | Out-Null

$targetFile = Join-Path $testDir "target.json"
$tmpFile = Join-Path $testDir "source.tmp"

[System.IO.File]::WriteAllText($targetFile, '{"state": "initial"}')
[System.IO.File]::WriteAllText($tmpFile, '{"state": "atomic_updated"}')

[AntigravityCompliantHelper.NativeVaultV4]::MoveFileAtomic($tmpFile, $targetFile)

$content = [System.IO.File]::ReadAllText($targetFile)
Assert-Test "Atomic replacement successfully overwrote target" ($content -eq '{"state": "atomic_updated"}')
Assert-Test "Temp file cleanly removed after MoveFileAtomic" (-not (Test-Path $tmpFile))

# Test Write-AtomicUtf8NoBom & Write-AtomicAscii
Write-AtomicUtf8NoBom -Path $targetFile -Content '{"utf8": "中文测试"}'
$utf8Content = [System.IO.File]::ReadAllText($targetFile, [System.Text.Encoding]::UTF8)
Assert-Test "Write-AtomicUtf8NoBom correctly replaces file" ($utf8Content -eq '{"utf8": "中文测试"}')

# ------------------------------------------------------------------------------
# Test 3: True JSON Parsing & UpdateAppStorageEmailSafely
# ------------------------------------------------------------------------------
Write-Host "`n--- Test 3: True JSON Parsing & UpdateAppStorageEmailSafely ---" -ForegroundColor Yellow

# Test 3a: IsValidJsonObject
Assert-Test "Valid empty JSON obj" ([AntigravityCompliantHelper.NativeVaultV4]::IsValidJsonObject("{}"))
Assert-Test "Valid nested JSON obj" ([AntigravityCompliantHelper.NativeVaultV4]::IsValidJsonObject('{"a": [1, 2, "str", true, null], "b": {"x": 12.34}}'))
Assert-Test "Valid JSON with UTF-8 BOM" ([AntigravityCompliantHelper.NativeVaultV4]::IsValidJsonObject([char]0xFEFF + '{"bom": true}'))
Assert-Test "Invalid JSON: unclosed brace" (-not [AntigravityCompliantHelper.NativeVaultV4]::IsValidJsonObject('{"a": 1'))
Assert-Test "Invalid JSON: trailing comma or brace" (-not [AntigravityCompliantHelper.NativeVaultV4]::IsValidJsonObject('{"a": 1, }'))
Assert-Test "Invalid JSON: array at root" (-not [AntigravityCompliantHelper.NativeVaultV4]::IsValidJsonObject('[1, 2, 3]'))
Assert-Test "Invalid JSON: garbage around braces" (-not [AntigravityCompliantHelper.NativeVaultV4]::IsValidJsonObject('{bad json}'))

# Test 3b: UpdateAppStorageEmailSafely on valid file
$appStorageTest = Join-Path $testDir "app_storage_test.json"
$origJson = @"
{
  "custom.setting": "keep_this",
  "jetski.onboarding.lastLoginUsername": "old@gmail.com"
}
"@
[System.IO.File]::WriteAllText($appStorageTest, $origJson)

[AntigravityCompliantHelper.NativeVaultV4]::UpdateAppStorageEmailSafely($appStorageTest, "new_user@gmail.com", $false)
$updated = [System.IO.File]::ReadAllText($appStorageTest)
$bakExists = Test-Path "$appStorageTest.bak"

Assert-Test "UpdateAppStorageEmailSafely created .bak backup before modifying" $bakExists
Assert-Test "UpdateAppStorageEmailSafely preserved custom.setting" ($updated -match '"custom\.setting":\s*"keep_this"')
Assert-Test "UpdateAppStorageEmailSafely updated email" ($updated -match '"jetski\.onboarding\.lastLoginUsername":\s*"new_user@gmail\.com"')

# Test 3c: UpdateAppStorageEmailSafely on corrupt file
[System.IO.File]::WriteAllText($appStorageTest, '{ this is corrupted json')
[AntigravityCompliantHelper.NativeVaultV4]::UpdateAppStorageEmailSafely($appStorageTest, "recovered@gmail.com", $false)
$corruptBaks = @(Get-ChildItem -Path $testDir -Filter "*.corrupt.*.bak")
$recoveredContent = [System.IO.File]::ReadAllText($appStorageTest)

Assert-Test "Corrupt app_storage preserved to .corrupt.<timestamp>.bak" ($corruptBaks.Count -ge 1)
Assert-Test "Corrupt app_storage safely healed to valid JSON" ([AntigravityCompliantHelper.NativeVaultV4]::IsValidJsonObject($recoveredContent))
Assert-Test "Healed file contains target email" ($recoveredContent -match "recovered@gmail\.com")

# Test 3d: forceCleanReset creates .bak before resetting
[AntigravityCompliantHelper.NativeVaultV4]::UpdateAppStorageEmailSafely($appStorageTest, "clean_reset@gmail.com", $true)
Assert-Test "forceCleanReset preserved prior version in .bak" (Test-Path "$appStorageTest.bak")

# ------------------------------------------------------------------------------
# Test 4: Set-AppStorageLoginEmail & Write-AllStoresForSnapshot Strong Consistency & Rollback
# ------------------------------------------------------------------------------
Write-Host "`n--- Test 4: Set-AppStorageLoginEmail & Write-AllStoresForSnapshot Strong Consistency & Rollback ---" -ForegroundColor Yellow
$threw = $false
try {
    [AntigravityCompliantHelper.NativeVaultV4]::UpdateAppStorageEmailSafely("C:\Invalid:\Path\app_storage.json", "fail@gmail.com", $false)
} catch {
    $threw = $true
}
Assert-Test "NativeVaultV4 throws on invalid path" $threw

# Test 4b: DeleteGenericCredential
$testCredTarget = "gemini:antigravity:test_nonexistent"
$delRes = [AntigravityCompliantHelper.NativeVaultV4]::DeleteGenericCredential($testCredTarget)
Assert-Test "DeleteGenericCredential returns bool without throwing" ($delRes -is [bool])

# Test 4c: Write-AllStoresForSnapshot Consistency Assertion & Rollback
$savedAppStoragePath = $AppStorageJson
$savedCliTokenPath = $AgyCliTokenPath
$savedCredTarget = $CredTarget
$sandboxAppStorage = Join-Path $testDir "app_storage_rollback.json"
$sandboxCliToken = Join-Path $testDir "cli_token_rollback.json"

[System.IO.File]::WriteAllText($sandboxAppStorage, '{"jetski.onboarding.lastLoginUsername": "prior_good@gmail.com"}')

# Point helper paths to sandbox
$script:AppStorageJson = $sandboxAppStorage
$script:AgyCliTokenPath = $sandboxCliToken
$script:CredTarget = "gemini:antigravity:verify_rollback_test"

$rollbackTriggered = $false
$rollbackMsg = ""
try {
    # Provide a snapshot with mismatched tokenFingerprint to intentionally trigger consistency assertion failure
    $badSnap = [PSCustomObject]@{
        detectedEmail    = "prior_good@gmail.com"
        accessToken      = "dummy_at_value"
        refreshToken     = "dummy_rt_value"
        tokenFingerprint = "expected_fingerprint_that_will_mismatch"
    }
    Write-AllStoresForSnapshot -Snapshot $badSnap | Out-Null
} catch {
    $rollbackTriggered = $true
    $rollbackMsg = $_.Exception.Message
} finally {
    # Clean up test credential
    [AntigravityCompliantHelper.NativeVaultV4]::DeleteGenericCredential($script:CredTarget) | Out-Null
    $script:AppStorageJson = $savedAppStoragePath
    $script:AgyCliTokenPath = $savedCliTokenPath
    $script:CredTarget = $savedCredTarget
}

Assert-Test "Write-AllStoresForSnapshot throws on consistency assertion failure" $rollbackTriggered
Assert-Test "Rollback error message confirms rollback occurred" ($rollbackMsg -match "全量凭据同步失败且已安全回滚")

$recoveredAppStorage = [System.IO.File]::ReadAllText($sandboxAppStorage)
Assert-Test "Rollback restored app_storage.json to prior state" ($recoveredAppStorage -match "prior_good@gmail\.com")

# ------------------------------------------------------------------------------
# Test 5: Test-SlotGroupAvailable Timing & Argon Handling
# ------------------------------------------------------------------------------
Write-Host "`n--- Test 5: Test-SlotGroupAvailable Timing & Argon Handling ---" -ForegroundColor Yellow

$now = Get-Date
$pastTime = $now.AddHours(-1).ToString("yyyy-MM-dd HH:mm:ss")
$futureTime = $now.AddHours(2).ToString("yyyy-MM-dd HH:mm:ss")

# 5a: Argon with resetTime in the past -> must auto unfreeze to 100% and return true
$slotPast = [PSCustomObject]@{
    slotName       = "slot_past"
    status         = "cooldown"
    argonWeeklyPct = 0
    resetTimeArgon = $pastTime
}
$availPast = Test-SlotGroupAvailable -SlotObj $slotPast -ModelGroup "Argon" -Now $now
Assert-Test "Argon expired resetTime auto-unfreezes to 100%" ($slotPast.argonWeeklyPct -eq 100)
Assert-Test "Argon expired resetTime clears resetTime" ($null -eq $slotPast.resetTimeArgon)
Assert-Test "Argon expired resetTime slot becomes available" $availPast

# 5b: Argon with resetTime in the future -> must return false
$slotFuture = [PSCustomObject]@{
    slotName       = "slot_future"
    status         = "cooldown"
    argonWeeklyPct = 0
    resetTimeArgon = $futureTime
}
$availFuture = Test-SlotGroupAvailable -SlotObj $slotFuture -ModelGroup "Argon" -Now $now
Assert-Test "Argon future resetTime slot is unavailable" (-not $availFuture)

# 5c: Account without Argon (argonWeeklyPct = "--" or $null) -> must return false without exception
$slotNoArgon = [PSCustomObject]@{
    slotName       = "slot_no_argon"
    status         = "ready"
    argonWeeklyPct = "--"
}
$availNoArgon = $false
$noArgonThrew = $false
try {
    $availNoArgon = Test-SlotGroupAvailable -SlotObj $slotNoArgon -ModelGroup "Argon" -Now $now
} catch {
    $noArgonThrew = $true
}
Assert-Test "Argon with '--' does not throw int conversion error" (-not $noArgonThrew)
Assert-Test "Argon with '--' returns false (unsupported)" (-not $availNoArgon)

# 5d: Gemini with expired 5h reset -> auto unfreezes to 100% and restores ready status
$slotGemini = [PSCustomObject]@{
    slotName        = "slot_gem"
    status          = "cooldown"
    cooldownUntil   = $pastTime
    gemini5hPct     = 0
    geminiWeeklyPct = 80
    resetTime5h     = $pastTime
}
$availGem = Test-SlotGroupAvailable -SlotObj $slotGemini -ModelGroup "Gemini" -Now $now
Assert-Test "Gemini expired 5h reset auto-unfreezes to 100%" ($slotGemini.gemini5hPct -eq 100)
Assert-Test "Gemini expired 5h reset unfreezes status to ready" ($slotGemini.status -eq "ready")
Assert-Test "Gemini slot is available" $availGem

# 5e: Claude with unsupported '--' returns false
$slotClaudeNo = [PSCustomObject]@{
    slotName        = "slot_cla_no"
    status          = "ready"
    claude5hPct     = "--"
    claudeWeeklyPct = "--"
}
$availClaNo = Test-SlotGroupAvailable -SlotObj $slotClaudeNo -ModelGroup "Claude" -Now $now
Assert-Test "Claude with '--' returns false (unsupported)" (-not $availClaNo)

# 5f: Claude with expired 5h reset -> auto unfreezes to 100% and restores ready status
$slotClaudeThaw = [PSCustomObject]@{
    slotName        = "slot_cla_thaw"
    status          = "cooldown"
    cooldownUntil   = $pastTime
    claude5hPct     = 0
    claudeWeeklyPct = 90
    resetTime5h     = $pastTime
}
$availClaThaw = Test-SlotGroupAvailable -SlotObj $slotClaudeThaw -ModelGroup "Claude" -Now $now
Assert-Test "Claude expired 5h reset auto-unfreezes to 100%" ($slotClaudeThaw.claude5hPct -eq 100)
Assert-Test "Claude expired 5h reset unfreezes status to ready" ($slotClaudeThaw.status -eq "ready")
Assert-Test "Claude slot is available" $availClaThaw

# 5g: Apply-QuotaSnapshotToSlotObject handles '--' without int casting crash
$slotSnapTest = [PSCustomObject]@{ slotName = "slot_snap_test" }
$quotaSnapWithDash = [PSCustomObject]@{
    Gemini5hPct     = 100
    GeminiWeeklyPct = 100
    ArgonWeeklyPct  = "--"
    Claude5hPct     = "--"
    ClaudeWeeklyPct = "--"
}
$snapThrew = $false
try {
    Apply-QuotaSnapshotToSlotObject -SlotObj $slotSnapTest -QuotaSnap $quotaSnapWithDash
} catch {
    $snapThrew = $true
}
Assert-Test "Apply-QuotaSnapshotToSlotObject does not throw on '--' quota values" (-not $snapThrew)
Assert-Test "Slot cleared unsupported '--' Argon value safely" ($null -eq $slotSnapTest.argonWeeklyPct -or $slotSnapTest.argonWeeklyPct -eq "--")

# ------------------------------------------------------------------------------
# Test 6: SQLite Conversation Tree Traversal
# ------------------------------------------------------------------------------
Write-Host "`n--- Test 6: SQLite Conversation Tree Traversal ---" -ForegroundColor Yellow
$pyScript = @'
import sqlite3, os, json, sys

db_path = os.path.expanduser('~/.gemini/antigravity/conversation_summaries.db')
if not os.path.exists(db_path):
    print(json.dumps({'status': 'not_found', 'active_count': 0}))
    sys.exit(0)

conn = sqlite3.connect(f'file:{db_path}?mode=ro', uri=True)
cur = conn.cursor()
cur.execute('SELECT conversation_id, title, status, not_fully_idle, project_id, last_modified_time, parent_conversation_id, killed FROM conversation_summaries')
rows = cur.fetchall()

def to_int_safe(val):
    if isinstance(val, (int, float)): return int(val)
    if isinstance(val, str): return 1 if val.strip().lower() in ('true', '1', 't') else 0
    return 1 if bool(val) else 0

all_convs = {}
parent_map = {}
for r in rows:
    cid, title, st, nfi, pid, lmt, parent_id, killed = r
    all_convs[cid] = {
        'conversation_id': cid,
        'title': title or '',
        'status': st or '',
        'not_fully_idle': to_int_safe(nfi),
        'parent_id': parent_id or '',
        'killed': to_int_safe(killed)
    }
    parent_map[cid] = parent_id or ''

def find_root(cid):
    curr = cid
    visited = set()
    while curr and curr in parent_map and parent_map[curr]:
        visited.add(curr)
        nxt = parent_map[curr]
        if nxt in visited: break
        curr = nxt
    return curr

active_roots = {}
for cid, c in all_convs.items():
    if c['killed'] == 0:
        if (c['not_fully_idle'] != 0) or ('RUNNING' in (c['status'] or '').upper()):
            root_id = find_root(cid)
            if root_id in all_convs:
                active_roots[root_id] = all_convs[root_id]

print(json.dumps({'active_count': len(active_roots), 'roots': list(active_roots.keys())}))
'@
$pyExe = Get-PythonExecutablePath
$pyOut = & $pyExe -c $pyScript | ConvertFrom-Json
Assert-Test "SQLite conversation tree recursive resolution found active root task" ($pyOut.active_count -ge 1)
Write-Host "    Active root found: $($pyOut.roots -join ', ')" -ForegroundColor DarkGray

# ------------------------------------------------------------------------------
# Test 7: Handover File Generation & Markdown Formatting
# ------------------------------------------------------------------------------
Write-Host "`n--- Test 7: Handover File Generation & Formatting ---" -ForegroundColor Yellow
$handoverDir = Join-Path $testDir "handover_test"
New-Item -ItemType Directory -Path $handoverDir -Force | Out-Null
$generatedFile = New-WorkspaceHandoverFile -WorkspacePath $handoverDir
Assert-Test "Handover file was created" (Test-Path (Join-Path $handoverDir "ANTIGRAVITY_HANDOVER.md"))

$hoText = [System.IO.File]::ReadAllText((Join-Path $handoverDir "ANTIGRAVITY_HANDOVER.md"))
Assert-Test "No literal `"`$resolvedPath`" in generated markdown" ($hoText -notmatch '\$resolvedPath')
Assert-Test "No literal `"`$lastConvId`" in generated markdown" ($hoText -notmatch '\$lastConvId')
Assert-Test "No literal `"`$gitBranch`" in generated markdown" ($hoText -notmatch '\$gitBranch')
Assert-Test "No corrupted tab character before 'ext'" ($hoText -notmatch "`\text")
Assert-Test "Valid code fences present" ($hoText -match '```text')

# ------------------------------------------------------------------------------
# Test 8: Format-QuotaPairCell & Dashboard Formatting
# ------------------------------------------------------------------------------
Write-Host "`n--- Test 8: Format-QuotaPairCell & Dashboard Width ---" -ForegroundColor Yellow
$cell1 = Format-QuotaPairCell -Pct5h 99 -PctWeekly 25
Assert-Test "Cell format matches '5h: 99% · 周: 25%'" ($cell1 -eq "5h:  99% · 周:  25%")

$cell2 = Format-QuotaPairCell -Pct5h "--" -PctWeekly 100
Assert-Test "Cell format handles '--' gracefully" ($cell2 -eq "5h:   -- · 周: 100%")

# ------------------------------------------------------------------------------
# Test 9: Write-DaemonLog ValidateSet Extensibility (RESUME & AUTH)
# ------------------------------------------------------------------------------
Write-Host "`n--- Test 9: Write-DaemonLog ValidateSet Extensibility ---" -ForegroundColor Yellow
$logResumeThrew = $false
try {
    Write-DaemonLog "测试 RESUME 级别日志输出" "RESUME"
} catch {
    $logResumeThrew = $true
}
Assert-Test "Write-DaemonLog supports 'RESUME' level without throwing" (-not $logResumeThrew)

$logAuthThrew = $false
try {
    Write-DaemonLog "测试 AUTH 级别日志输出" "AUTH"
} catch {
    $logAuthThrew = $true
}
Assert-Test "Write-DaemonLog supports 'AUTH' level without throwing" (-not $logAuthThrew)

# ------------------------------------------------------------------------------
# Test 10: Anti-False-Resume and Idle Session Protection
# ------------------------------------------------------------------------------
Write-Host "`n--- Test 10: Anti-False-Resume and Idle Session Protection ---" -ForegroundColor Yellow

# 10a: Test-HasRunningConversations with idle manifest returns false
$origScriptManifest = $Script:LastActiveManifest
$idleManifest = [PSCustomObject]@{
    captured_at = "2026-10-27T00:00:00Z"
    primary = [PSCustomObject]@{
        conversation_id = "idle_conv_1"
        title = "Idle Conv"
        project_id = "proj_1"
        status = "CASCADE_RUN_STATUS_IDLE"
        not_fully_idle = 0
    }
    all = @(
        [PSCustomObject]@{
            conversation_id = "idle_conv_1"
            title = "Idle Conv"
            project_id = "proj_1"
            status = "CASCADE_RUN_STATUS_IDLE"
            not_fully_idle = 0
        }
    )
}
$Script:LastActiveManifest = $idleManifest
$hasRunningIdle = Test-HasRunningConversations
Assert-Test "Test-HasRunningConversations returns false for idle manifest" (-not $hasRunningIdle)

# 10b: Test-HasRunningConversations with running manifest returns true
$runningManifest = [PSCustomObject]@{
    captured_at = "2026-10-27T00:00:00Z"
    primary = [PSCustomObject]@{
        conversation_id = "running_conv_1"
        title = "Running Conv"
        project_id = "proj_1"
        status = "CASCADE_RUN_STATUS_RUNNING"
        not_fully_idle = 1
    }
    all = @(
        [PSCustomObject]@{
            conversation_id = "running_conv_1"
            title = "Running Conv"
            project_id = "proj_1"
            status = "CASCADE_RUN_STATUS_RUNNING"
            not_fully_idle = 1
        }
    )
}
$Script:LastActiveManifest = $runningManifest
$hasRunningActive = Test-HasRunningConversations
Assert-Test "Test-HasRunningConversations returns true for running manifest" $hasRunningActive

# 10c: Clean up manifest and verify absent manifest returns false
$Script:LastActiveManifest = $null
if (Test-Path $ResumeManifestPath) { Remove-Item $ResumeManifestPath -Force -ErrorAction SilentlyContinue }
$hasRunningNull = Test-HasRunningConversations
Assert-Test "Test-HasRunningConversations returns false when manifest is absent" (-not $hasRunningNull)

# Restore original manifest state
$Script:LastActiveManifest = $origScriptManifest

# 10d: SQLite extraction on pure idle conversations returns 0 active roots (no false fallback)
$mockDbDir = Join-Path $testDir "mock_db_test"
New-Item -ItemType Directory -Path $mockDbDir -Force | Out-Null
$mockDbPath = (Join-Path $mockDbDir "mock_conversations.db").Replace('\', '/')

$pyMockTest = @"
import sqlite3, json

conn = sqlite3.connect('$mockDbPath')
cur = conn.cursor()
cur.execute('''CREATE TABLE conversation_summaries (
    conversation_id TEXT, title TEXT, status TEXT, not_fully_idle INTEGER,
    project_id TEXT, last_modified_time TEXT, parent_conversation_id TEXT, killed INTEGER
)''')
cur.execute('''INSERT INTO conversation_summaries VALUES 
    ('idle_1', 'Idle Task 1', 'CASCADE_RUN_STATUS_IDLE', 0, 'proj1', '2026-10-27 10:00:00', '', 0),
    ('idle_2', 'Idle Task 2', 'CASCADE_RUN_STATUS_IDLE', 0, 'proj1', '2026-10-27 09:00:00', '', 0)
''')
conn.commit()

cur.execute('SELECT conversation_id, title, status, not_fully_idle, project_id, last_modified_time, parent_conversation_id, killed FROM conversation_summaries')
rows = cur.fetchall()

def to_int_safe(val):
    if isinstance(val, (int, float)): return int(val)
    if isinstance(val, str): return 1 if val.strip().lower() in ('true', '1', 't') else 0
    return 1 if bool(val) else 0

all_convs = {}
parent_map = {}
for r in rows:
    cid, title, st, nfi, pid, lmt, parent_id, killed = r
    all_convs[cid] = {
        'conversation_id': cid,
        'title': title or '',
        'status': st or '',
        'not_fully_idle': to_int_safe(nfi),
        'parent_id': parent_id or '',
        'killed': to_int_safe(killed),
        'last_modified_time': str(lmt or '')
    }
    parent_map[cid] = parent_id or ''

active_roots = {}
for cid, c in all_convs.items():
    if c['killed'] == 0:
        if (c['not_fully_idle'] != 0) or ('RUNNING' in (c['status'] or '').upper()):
            active_roots[cid] = c

active_list = sorted(active_roots.values(), key=lambda x: x['last_modified_time'], reverse=True)
print(json.dumps({'count': len(active_list)}))
"@

$pyExe = Get-PythonExecutablePath
$mockOut = & $pyExe -c $pyMockTest | ConvertFrom-Json
Assert-Test "SQLite extraction on pure idle conversations returns 0 active roots (no false fallback)" ($mockOut.count -eq 0)

# ------------------------------------------------------------------------------
# Test 11: Desktop Explorer COM Process Decoupling (Rule 4 & Rule 14)
# ------------------------------------------------------------------------------
Write-Host "`n--- Test 11: Desktop Explorer COM Process Decoupling ---" -ForegroundColor Yellow
$testExe = "powershell.exe"
$beforePowershellPids = @(Get-Process -Name "powershell" -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
$launchedPid = Start-DetachedAntigravityProcess -ExePath $testExe -Arguments "-NoProfile -Command Start-Sleep -Seconds 5"

Start-Sleep -Milliseconds 800
$childProc = if ($launchedPid -and $launchedPid -gt 0) { Get-Process -Id $launchedPid -ErrorAction SilentlyContinue } else { Get-Process -Name "powershell" -ErrorAction SilentlyContinue | Where-Object { -not $beforePowershellPids.Contains($_.Id) } | Select-Object -First 1 }

$isDecoupled = $false
$parentProcName = ""
if ($childProc) {
    try {
        $parentPid = (Get-CimInstance Win32_Process -Filter "ProcessId = $($childProc.Id)").ParentProcessId
        $parentProcName = (Get-Process -Id $parentPid -ErrorAction SilentlyContinue).ProcessName
        if ($parentProcName -eq "explorer") {
            $isDecoupled = $true
        }
    } catch {}
    try { Stop-Process -Id $childProc.Id -Force -ErrorAction SilentlyContinue } catch {}
}
Assert-Test "Start-DetachedAntigravityProcess delegates to explorer.exe parent (immune to Ctrl+C/console close)" $isDecoupled ("Parent: " + $parentProcName)

# ------------------------------------------------------------------------------
# Test 12: Dual-Track Web GUI Architecture & Payload Contract Verification
# ------------------------------------------------------------------------------
Write-Host "`n--- Test 12: Dual-Track Web GUI Architecture & Payload Contract ---" -ForegroundColor Yellow

# 12a: Get-SlotPoolGuiPayload Contract & Dual-Track Independent Countdowns
$guiPayload = Get-SlotPoolGuiPayload
Assert-Test "Get-SlotPoolGuiPayload executes successfully" ($guiPayload -and $guiPayload.success -eq $true)
Assert-Test "GuiPayload contains non-empty slot pool" ($guiPayload.slots -and $guiPayload.slots.Count -gt 0)
Assert-Test "GuiPayload contains current slot information" ($guiPayload.current -and $guiPayload.current.slotName)
Assert-Test "GuiPayload slot items have valid quota fields" ($null -ne $guiPayload.slots[0]["gemini5hPct"] -or $null -ne $guiPayload.slots[0].gemini5hPct)
Assert-Test "GuiPayload slot items have independent 5h and weekly countdowns" ($null -ne $guiPayload.slots[0].gemini5hCountdown -and $null -ne $guiPayload.slots[0].geminiWeeklyCountdown)
Assert-Test "GuiPayload current slot has independent 5h and weekly countdowns" ($null -ne $guiPayload.current.gemini5hCountdown -and $null -ne $guiPayload.current.geminiWeeklyCountdown)
Assert-Test "Get-QuotaThawCountdownText helper executes correctly" ((Get-QuotaThawCountdownText -Pct 100) -eq "就绪可用" -and (Get-QuotaThawCountdownText -Pct 0 -Type "weekly") -eq "周限额冷却中")
Assert-Test "Get-QuotaThawCountdownText compact format functions properly" ((Get-QuotaThawCountdownText -Pct 100 -Compact) -eq "就绪" -and (Get-QuotaThawCountdownText -Pct 0 -Type "weekly" -Compact) -eq "周限额")

# 12b: Dual-Track Files Existence & Air-Gapped Verification
$dashHtml = Join-Path $PSScriptRoot "dashboard.html"
$launchVbs = Join-Path $PSScriptRoot "launch-gui.vbs"
$launchBat = Join-Path $PSScriptRoot "启动现代桌面控制面板.bat"

Assert-Test "Dashboard HTML exists in AGY folder" (Test-Path $dashHtml)
Assert-Test "launch-gui.vbs exists in AGY folder" (Test-Path $launchVbs)
Assert-Test "启动现代桌面控制面板.bat exists in AGY folder" (Test-Path $launchBat)

$htmlContent = [System.IO.File]::ReadAllText($dashHtml)
Assert-Test "Dashboard HTML is 100% offline air-gapped (no cdn/remote scripts)" ($htmlContent -notmatch "https?://(?!127\.0\.0\.1|localhost)")
Assert-Test "Dashboard HTML has independent 5h and weekly countdown badges" ($htmlContent -match "hero5hCountdown" -and $htmlContent -match "heroWeeklyCountdown")
Assert-Test "Dashboard HTML card metrics embed quota countdowns" ($htmlContent -match "metric-countdown")

# 12c: Pure Isolated Desktop Sandbox (--disable-extensions & --disable-plugins)
$helperContent = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot "antigravity_compliant_helper.ps1"))
Assert-Test "GUI launch flags enforce --disable-extensions" ($helperContent -match "--disable-extensions")
Assert-Test "GUI launch flags enforce --disable-plugins" ($helperContent -match "--disable-plugins")
Assert-Test "GUI launch flags enforce --disable-sync" ($helperContent -match "--disable-sync")

# ------------------------------------------------------------------------------
# Test 13: Slot Index Resolution, Argon Accuracy & Multi-Model Quota Extraction
# ------------------------------------------------------------------------------
Write-Host "`n--- Test 13: Slot Index Resolution, Argon Accuracy & Multi-Model Extraction ---" -ForegroundColor Yellow
$poolState = Get-SlotPoolState -SkipAutoMatch
$firstSlotInOrder = $poolState.slotOrder[0]
$fifthSlotInOrder = $poolState.slotOrder[4]
Assert-Test "Resolve-SlotNameFromInput maps '1' to 1st slot ($firstSlotInOrder)" ((Resolve-SlotNameFromInput -UserInput "1" -State $poolState) -eq $firstSlotInOrder)
Assert-Test "Resolve-SlotNameFromInput maps '[5]' to 5th slot ($fifthSlotInOrder)" ((Resolve-SlotNameFromInput -UserInput "[5]" -State $poolState) -eq $fifthSlotInOrder)
Assert-Test "Resolve-SlotNameFromInput preserves literal slot name 'a'" ((Resolve-SlotNameFromInput -UserInput "a" -State $poolState) -eq "a")

$slotB = $poolState.slots.b
$slotA = $poolState.slots.a
Assert-Test "Slot [b] does NOT falsely report Argon support" ($null -eq $slotB.argonWeeklyPct -and $slotB.supportsArgon -eq $false)
Assert-Test "Slot [a] accurately reports Argon support" ($null -ne $slotA.argonWeeklyPct -and $slotA.supportsArgon -eq $true)
Assert-Test "All slots have populated supportedModels list" (@($slotB.supportedModels).Count -ge 3 -and @($slotA.supportedModels).Count -ge 4)
Assert-Test "GuiPayload includes slotIndex and supportedModels" ($guiPayload.slots[0].slotIndex -eq 1 -and @($guiPayload.slots[0].supportedModels).Count -ge 3)

# Clean up test sandbox
Remove-Item $testDir -Recurse -Force -ErrorAction SilentlyContinue

# ------------------------------------------------------------------------------
# Test 14: Timezone Double-Offset Immunity & Upper Bounds (Tier 2)
# ------------------------------------------------------------------------------
Write-Host "`n--- Test 14: Timezone Double-Offset Immunity & Upper Bounds (Tier 2) ---" -ForegroundColor Yellow

$nowTz = Get-Date

# 14a: Naive local string (Must NOT add timezone offset again, e.g. +8h)
$naiveLocalStr = $nowTz.AddHours(2).ToString("yyyy-MM-dd HH:mm:ss")
$parsedLocal = ConvertTo-LocalDateTime $naiveLocalStr
$spanLocal = $parsedLocal - $nowTz
Assert-Test "Naive local string retains exact +2h difference" ([Math]::Abs($spanLocal.TotalHours - 2.0) -lt 0.05)

# 14b: UTC ISO string with 'Z'
$utcStr = $nowTz.ToUniversalTime().AddHours(3).ToString("yyyy-MM-ddTHH:mm:ssZ")
$parsedUtc = ConvertTo-LocalDateTime $utcStr
$spanUtc = $parsedUtc - $nowTz
Assert-Test "UTC ISO string with 'Z' correctly converted to local +3h difference" ([Math]::Abs($spanUtc.TotalHours - 3.0) -lt 0.05)

# 14c: 5h countdown upper bounds verification (absolute limit <= 5 hours)
$slot5hTestReset = $nowTz.AddHours(4).ToString("yyyy-MM-dd HH:mm:ss")
$cd5hText = Get-QuotaThawCountdownText -ResetTimeStr $slot5hTestReset -Pct 0 -Type "5h" -Now $nowTz
Assert-Test "5h countdown text does not exceed 5 hours (no timezone double-offset)" ($cd5hText -notmatch "(?:[5-9]|[1-9]\d+)h\d{2,}m后重置")
Assert-Test "5h countdown matches expected 03h/04h window" ($cd5hText -match "0[34]h\d{2}m后重置")

# 14d: Weekly countdown upper bounds verification (absolute limit <= 7 days)
$slotWkTestReset = $nowTz.AddDays(5).ToString("yyyy-MM-dd HH:mm:ss")
$cdWkText = Get-QuotaThawCountdownText -ResetTimeStr $slotWkTestReset -Pct 0 -Type "weekly" -Now $nowTz
Assert-Test "Weekly countdown text does not exceed 7 days" ($cdWkText -notmatch "([8-9]|\d{2,})d")
Assert-Test "Weekly countdown matches expected ~5d window" ($cdWkText -match "5d\s+\d{2}h后重置")

# ------------------------------------------------------------------------------
# Test 15: Switch Account Audit & switchCount Increment (Tier 1)
# ------------------------------------------------------------------------------
Write-Host "`n--- Test 15: Switch Account Audit & switchCount Increment (Tier 1) ---" -ForegroundColor Yellow

$poolStateBefore = Get-SlotPoolState -SkipAutoMatch
$targetSwitchSlot = $poolStateBefore.slotOrder[0]
$prevSwitchCount = ConvertTo-SafeInt $poolStateBefore.slots.$targetSwitchSlot.switchCount -Default 0
$prevHistoryCount = if ($poolStateBefore.history) { @($poolStateBefore.history).Count } else { 0 }

# Execute switch without killing processes
$switchedEmail = $null
try {
    $switchedEmail = Switch-CredentialSlot -SlotName $targetSwitchSlot -WorkspacePath $PSScriptRoot -NonInteractive -CloseProcesses:$false
} catch {
    Write-Host "    Switch execution notice: $($_.Exception.Message)" -ForegroundColor DarkGray
}

$poolStateAfter = Get-SlotPoolState -SkipAutoMatch
$newSwitchCount = ConvertTo-SafeInt $poolStateAfter.slots.$targetSwitchSlot.switchCount -Default 0
$newHistory = if ($poolStateAfter.history) { @($poolStateAfter.history) } else { @() }

Assert-Test "Switch-CredentialSlot increments target slot switchCount strictly by 1" ($newSwitchCount -eq ($prevSwitchCount + 1))
Assert-Test "state.history records new entry after switch" ($newHistory.Count -eq [Math]::Min(50, $prevHistoryCount + 1))

if ($newHistory.Count -gt 0) {
    $lastAudit = $newHistory[-1]
    Assert-Test "Audit history entry has valid timestamp" ([DateTime]::TryParse($lastAudit.timestamp, [ref](Get-Date)))
    Assert-Test "Audit history entry toSlot matches target slot" ($lastAudit.toSlot -eq $targetSwitchSlot)
    Assert-Test "Audit history entry has non-empty reason" (-not [string]::IsNullOrWhiteSpace($lastAudit.reason))
} else {
    Assert-Test "Audit history entry has valid timestamp" $false "state.history is empty"
    Assert-Test "Audit history entry toSlot matches target slot" $false "state.history is empty"
    Assert-Test "Audit history entry has non-empty reason" $false "state.history is empty"
}

# ------------------------------------------------------------------------------
# Test 16: Read-Only Zero Disk Write & Dirty-Flag Mechanism (Tier 2)
# ------------------------------------------------------------------------------
Write-Host "`n--- Test 16: Read-Only Zero Disk Write & Dirty-Flag Mechanism (Tier 2) ---" -ForegroundColor Yellow

$stateFilePath = $PoolStatePath
if (-not (Test-Path $stateFilePath)) {
    $null = Get-SlotPoolState -SkipAutoMatch
}

# 16a: Record initial timestamp ticks and SHA256 hash
$beforeItem = Get-Item $stateFilePath
$beforeWriteTime = $beforeItem.LastWriteTimeUtc.Ticks
$beforeHash = (Get-FileHash -Path $stateFilePath -Algorithm SHA256).Hash

# Sleep slightly to allow any potential file timestamp update to be measurable
Start-Sleep -Milliseconds 100

# 16b: Perform 10 consecutive read-only queries
for ($rIdx = 0; $rIdx -lt 10; $rIdx++) {
    $null = Get-SlotPoolState -SkipAutoMatch
    $null = Get-SlotPoolGuiPayload
}

# 16c: Verify LastWriteTimeUtc and SHA256 hash remain strictly identical
$afterItem = Get-Item $stateFilePath
$afterWriteTime = $afterItem.LastWriteTimeUtc.Ticks
$afterHash = (Get-FileHash -Path $stateFilePath -Algorithm SHA256).Hash

Assert-Test "Read-only queries do NOT modify pool_state.json LastWriteTimeUtc (Dirty-Flag)" ($beforeWriteTime -eq $afterWriteTime)
Assert-Test "Read-only queries do NOT alter pool_state.json SHA256 hash" ($beforeHash -eq $afterHash)

# ------------------------------------------------------------------------------
# Test 17: DPAPI Credential Atomic Write & Security (Tier 1)
# ------------------------------------------------------------------------------
Write-Host "`n--- Test 17: DPAPI Credential Atomic Write & Security (Tier 1) ---" -ForegroundColor Yellow

$testAtomicDir = Join-Path $PSScriptRoot "test_dpapi_sandbox"
if (Test-Path $testAtomicDir) { Remove-Item $testAtomicDir -Recurse -Force }
New-Item -ItemType Directory -Path $testAtomicDir -Force | Out-Null

$atomicTarget = Join-Path $testAtomicDir "credential.dpapi"
$initialSecret = "INITIAL_SECRET_DATA_12345"
$updatedSecret = "UPDATED_SECRET_DATA_67890"

# Protect data using DPAPI
$encryptedInitial = [AntigravityCompliantHelper.NativeVaultV4]::ProtectText($initialSecret)
$encryptedUpdated = [AntigravityCompliantHelper.NativeVaultV4]::ProtectText($updatedSecret)

# 17a: Initial atomic write
Write-AtomicAscii -Path $atomicTarget -Content $encryptedInitial
$readInitial = [System.IO.File]::ReadAllText($atomicTarget, [System.Text.Encoding]::ASCII)
Assert-Test "Write-AtomicAscii writes valid DPAPI content" ($readInitial -eq $encryptedInitial)

# 17b: Overwrite atomically using Win32 MoveFileAtomic
Write-AtomicAscii -Path $atomicTarget -Content $encryptedUpdated
$readUpdated = [System.IO.File]::ReadAllText($atomicTarget, [System.Text.Encoding]::ASCII)
Assert-Test "Write-AtomicAscii cleanly overwrites target with MoveFileAtomic" ($readUpdated -eq $encryptedUpdated)

# 17c: Verify DPAPI decrypts to original plaintext
$decrypted = [AntigravityCompliantHelper.NativeVaultV4]::UnprotectText($readUpdated)
Assert-Test "Decrypted payload matches updated plaintext secret" ($decrypted -eq $updatedSecret)

# 17d: No leftover .tmp files
$leftoverTmp = @(Get-ChildItem -Path $testAtomicDir -Filter "*.tmp")
Assert-Test "No leftover temporary files remain in directory after atomic write" ($leftoverTmp.Count -eq 0)

# Clean up sandbox
Remove-Item $testAtomicDir -Recurse -Force -ErrorAction SilentlyContinue

# ------------------------------------------------------------------------------
# Test 18: CORS Origin Security Convergence (Tier 2)
# ------------------------------------------------------------------------------
Write-Host "`n--- Test 18: CORS Origin Security Convergence (Tier 2) ---" -ForegroundColor Yellow

$helperFilePath = Join-Path $PSScriptRoot "antigravity_compliant_helper.ps1"
$helperCode = [System.IO.File]::ReadAllText($helperFilePath, [System.Text.Encoding]::UTF8)

# 18a: Source code must not expose wildcard CORS header
$hasWildcardCors = $helperCode -match 'Access-Control-Allow-Origin",\s*"\*"'
Assert-Test "Start-SlotPoolHttpServer source code has NO wildcard '*' CORS header" (-not $hasWildcardCors)

# 18b: Dynamic HTTP server Origin verification
$corsTestPort = 4096
$corsServerJob = $null
try {
    $corsServerJob = Start-Job -ScriptBlock {
        param($p, $scriptP)
        . $scriptP -Action load-only
        Start-SlotPoolHttpServer -Port $p
    } -ArgumentList $corsTestPort, $helperFilePath

    Start-Sleep -Seconds 2

    # Legitimate Origin (http://127.0.0.1:4088)
    $legitReq = [System.Net.HttpWebRequest]::Create("http://127.0.0.1:$corsTestPort/api/status")
    $legitReq.Headers.Add("Origin", "http://127.0.0.1:4088")
    $legitReq.Timeout = 5000
    $legitCors = ""
    try {
        $legitResp = $legitReq.GetResponse()
        $legitCors = $legitResp.Headers["Access-Control-Allow-Origin"]
        $legitResp.Close()
    } catch {}
    Assert-Test "Legitimate Origin 127.0.0.1:4088 receives expected CORS header" ($legitCors -eq "http://127.0.0.1:4088")

    # Malicious Origin (http://evil.com)
    $evilReq = [System.Net.HttpWebRequest]::Create("http://127.0.0.1:$corsTestPort/api/status")
    $evilReq.Headers.Add("Origin", "http://evil.com")
    $evilReq.Timeout = 5000
    $evilCors = ""
    $evilBlocked = $false
    try {
        $evilResp = $evilReq.GetResponse()
        $evilCors = $evilResp.Headers["Access-Control-Allow-Origin"]
        $evilResp.Close()
    } catch [System.Net.WebException] {
        if ($_.Exception -and $_.Exception.Response) {
            $webResp = $_.Exception.Response -as [System.Net.HttpWebResponse]
            if ($webResp -and [int]$webResp.StatusCode -eq 403) {
                $evilBlocked = $true
            }
        }
    } catch {}
    Assert-Test "Malicious Origin (evil.com) is blocked with 403 or denied matching CORS header" ($evilBlocked -or ($evilCors -ne "*" -and $evilCors -ne "http://evil.com"))
} finally {
    if ($corsServerJob) {
        Stop-Job $corsServerJob -ErrorAction SilentlyContinue
        Remove-Job $corsServerJob -Force -ErrorAction SilentlyContinue
    }
}

# ------------------------------------------------------------------------------
# Test 19: PowerShell 5.1 & 7+ Dual Compatibility & UTF-8 BOM (Tier 1)
# ------------------------------------------------------------------------------
Write-Host "`n--- Test 19: PowerShell 5.1 & 7+ Dual Compatibility & UTF-8 BOM (Tier 1) ---" -ForegroundColor Yellow

$scriptBytes = [System.IO.File]::ReadAllBytes($helperFilePath)

# 19a: UTF-8 BOM verification (0xEF, 0xBB, 0xBF)
$hasBomHeader = ($scriptBytes.Length -ge 3 -and $scriptBytes[0] -eq 0xEF -and $scriptBytes[1] -eq 0xBB -and $scriptBytes[2] -eq 0xBF)
Assert-Test "antigravity_compliant_helper.ps1 strictly possesses UTF-8 BOM header (0xEF, 0xBB, 0xBF)" $hasBomHeader

# 19b: PowerShell AST parser reports 0 syntax errors
$astTokens = $null
$astErrors = $null
$scriptAst = [System.Management.Automation.Language.Parser]::ParseFile($helperFilePath, [ref]$astTokens, [ref]$astErrors)
Assert-Test "PowerShell AST parser reports exactly 0 syntax errors" ($astErrors.Count -eq 0)

# 19c: No unquoted PS7-exclusive operators (??, &&) in PowerShell AST tokens
$ps7Tokens = @($astTokens | Where-Object { $_.Text -in @('??', '&&') -and $_.Kind -ne [System.Management.Automation.Language.TokenKind]::StringLiteral })
$hasPs7NullCoalesce = ($ps7Tokens | Where-Object { $_.Text -eq '??' })
$hasPs7PipelineAnd = ($ps7Tokens | Where-Object { $_.Text -eq '&&' })
Assert-Test "No unquoted PS7 null-coalescing '??' in helper code" ($null -eq $hasPs7NullCoalesce)
Assert-Test "No unquoted PS7 pipeline chaining '&&' in helper code" ($null -eq $hasPs7PipelineAnd)

# ------------------------------------------------------------------------------
# Test 20: WebUI GuiPayload Schema Contract & 16 API Endpoints (Tier 1 & 4)
# ------------------------------------------------------------------------------
Write-Host "`n--- Test 20: WebUI GuiPayload Schema Contract & 16 API Endpoints (Tier 1 & 4) ---" -ForegroundColor Yellow

# 20a: GuiPayload Schema completeness
$guiPayloadV2 = Get-SlotPoolGuiPayload
Assert-Test "GuiPayload contains 'runway' object" ($null -ne $guiPayloadV2["runway"])
Assert-Test "GuiPayload contains 'current' object" ($null -ne $guiPayloadV2["current"])
Assert-Test "GuiPayload contains 'slots' array" ($null -ne $guiPayloadV2["slots"])
Assert-Test "GuiPayload contains 'daemon' object" ($null -ne $guiPayloadV2["daemon"])
$hasTaskState = ($null -ne $guiPayloadV2 -and ($guiPayloadV2.Contains("taskState") -or $null -ne $guiPayloadV2["taskState"]))
Assert-Test "GuiPayload contains 'taskState' field (async progress tracking)" $hasTaskState

# 20b: All 16 API endpoints verified in HTTP server router
$requiredEndpoints = @(
    @{ Path = "/"; Method = "GET"; Desc = "WebUI Root HTML" },
    @{ Path = "/api/status"; Method = "GET"; Desc = "Aggregated Status API" },
    @{ Path = "/api/action/switch"; Method = "POST"; Desc = "Switch Slot API" },
    @{ Path = "/api/action/next"; Method = "POST"; Desc = "Next Slot API" },
    @{ Path = "/api/action/resume"; Method = "POST"; Desc = "Resume Session API" },
    @{ Path = "/api/action/reset-cooldown"; Method = "POST"; Desc = "Reset Cooldown API" },
    @{ Path = "/api/action/refresh-slot"; Method = "POST"; Desc = "Refresh Slot Quota API" },
    @{ Path = "/api/action/toggle-skip"; Method = "POST"; Desc = "Toggle Skip API" },
    @{ Path = "/api/action/save-current"; Method = "POST"; Desc = "Save Current Slot API" },
    @{ Path = "/api/action/open-tui"; Method = "POST"; Desc = "Open Console TUI API" },
    @{ Path = "/api/action/boost"; Method = "POST"; Desc = "R4 Boost Action API" },
    @{ Path = "/api/action/remove-slot"; Method = "POST"; Desc = "R4 Remove Slot API" },
    @{ Path = "/api/action/daemon"; Method = "POST"; Desc = "R4 Daemon Control API" },
    @{ Path = "/api/action/autostart"; Method = "POST"; Desc = "R4 Autostart Toggle API" },
    @{ Path = "/api/action/goal"; Method = "POST"; Desc = "R4 Goal Healthcheck API" },
    @{ Path = "/api/action/repair-storage"; Method = "POST"; Desc = "R4 Storage Repair API" }
)

$serverFuncDef = (Get-Command Start-SlotPoolHttpServer).Definition
foreach ($ep in $requiredEndpoints) {
    $hasRoute = $serverFuncDef -match [regex]::Escape($ep.Path)
    Assert-Test "HTTP Server handles endpoint $($ep.Method) $($ep.Path) ($($ep.Desc))" $hasRoute
}

Write-Host "`n=======================================================" -ForegroundColor Cyan
Write-Host "Test Results: $passCount PASSED, $failCount FAILED" -ForegroundColor $(if ($failCount -eq 0) { "Green" } else { "Red" })
Write-Host "=======================================================" -ForegroundColor Cyan

if ($failCount -gt 0) { exit 1 } else { exit 0 }
