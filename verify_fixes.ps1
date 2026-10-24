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
# Test 4: Set-AppStorageLoginEmail Throws on Error
# ------------------------------------------------------------------------------
Write-Host "`n--- Test 4: Set-AppStorageLoginEmail Throws on Error ---" -ForegroundColor Yellow
$threw = $false
try {
    [AntigravityCompliantHelper.NativeVaultV4]::UpdateAppStorageEmailSafely("C:\Invalid:\Path\app_storage.json", "fail@gmail.com", $false)
} catch {
    $threw = $true
}
Assert-Test "NativeVaultV4 throws on invalid path" $threw

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

# 5d: Gemini with expired 5h reset -> auto unfreezes to 100%
$slotGemini = [PSCustomObject]@{
    slotName        = "slot_gem"
    status          = "ready"
    gemini5hPct     = 0
    geminiWeeklyPct = 80
    resetTime5h     = $pastTime
}
$availGem = Test-SlotGroupAvailable -SlotObj $slotGemini -ModelGroup "Gemini" -Now $now
Assert-Test "Gemini expired 5h reset auto-unfreezes to 100%" ($slotGemini.gemini5hPct -eq 100)
Assert-Test "Gemini slot is available" $availGem

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
$pyOut = & python -c $pyScript | ConvertFrom-Json
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

# Clean up test sandbox
Remove-Item $testDir -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "`n=======================================================" -ForegroundColor Cyan
Write-Host "Test Results: $passCount PASSED, $failCount FAILED" -ForegroundColor $(if ($failCount -eq 0) { "Green" } else { "Red" })
Write-Host "=======================================================" -ForegroundColor Cyan

if ($failCount -gt 0) { exit 1 } else { exit 0 }
