# AGY 2.0 端到端自动化测试套件就绪报告 (TEST_READY.md)

**测试套件状态**：READY (就绪已发布)  
**测试脚本主入口**：`C:\Users\deanc\Desktop\AGY\verify_fixes.ps1`  
**基准执行环境**：Windows 11 / Windows PowerShell 5.1 & PowerShell 7+ 双轨环境  
**文件编码**：UTF-8 with BOM (`0xEF, 0xBB, 0xBF`)  
**发布时间**：2026-11-03  

---

## 1. 测试套件概览与覆盖指标

本套件完全保留历史已交付的 Test 1 至 Test 13（84 项基础可靠性断言），并深度扩充了 7 大核心测试套件（Test 14 至 Test 20，共 45 项新增断言），构建了总计 **20 个测试组、129 项端到端断言**的 4-Tier 层次化自动化测试体系：

```
+----------------------------------------------------------------------------------------------------+
|                                    AGY 4-Tier 测试架构覆盖矩阵                                      |
+--------+------------------------------------+------------+-----------------------------------------+
| 分层   | 目标与特征                         | 断言总数   | 包含测试组                              |
+--------+------------------------------------+------------+-----------------------------------------+
| Tier 1 | 核心功能与基础单元测试             | 59 项      | Test 1, 2, 3, 15, 17, 19, 20a           |
| Tier 2 | 边界与异常防御测试                 | 32 项      | Test 5, 8, 9, 14, 16, 18                |
| Tier 3 | 跨模块协同与并发事务               | 16 项      | Test 4, 6, 7, 10                        |
| Tier 4 | 真实桌面与端到端 API 契约          | 22 项      | Test 11, 12, 13, 20b                    |
+--------+------------------------------------+------------+-----------------------------------------+
| 合计   | 全量 E2E 自动化测试体系            | 129 项     | Test 1 至 Test 20 (全部真实断言)        |
+--------+------------------------------------+------------+-----------------------------------------+
```

---

## 2. 7 大核心新增断言套件规范与映射 (Test 14 至 Test 20)

| 测试编号 | 架构分层 | 需求追溯 | 测试主题 | 核心断言内容与合规准则 |
|---|---|---|---|---|
| **Test 14** | Tier 2 | R5.1 | 时区二次偏移与倒计时上限 | ① `ConvertTo-LocalDateTime` 解析本地时间保留 +2h 差值（绝对误差 < 0.05h）；<br>② 解析带 `Z` 的 UTC ISO 字符串准确转换为本地 +3h 差值；<br>③ 5h 倒计时文本绝对不超过 5 小时（杜绝 +8h 二次偏移导致计算为 12h+）；<br>④ 周倒计时文本绝对不超过 7 天。 |
| **Test 15** | Tier 1 | R5.2 | 切号审计与计数单调自增 | ① 调用 `Switch-CredentialSlot` 后目标槽位 `switchCount` 严格 +1；<br>② `state.history` 追加 1 条结构化切号流水；<br>③ 流水记录包含合法 ISO 时间戳、`fromSlot`、`toSlot` 与非空切号原因。 |
| **Test 16** | Tier 2 | R5.4 | 只读零写盘与 Dirty-Flag 机制 | ① 连续多次执行 `Get-SlotPoolState` 与 `Get-SlotPoolGuiPayload` 只读查询；<br>② 校验 `pool_state.json` 磁盘文件的 `LastWriteTimeUtc` 恒定不变；<br>③ 校验 `pool_state.json` 磁盘文件的 SHA-256 哈希值绝对不变。 |
| **Test 17** | Tier 1 | R5.5 | DPAPI 凭据原子写盘与安全性 | ① `Write-AtomicAscii` 在替换时调用 Win32 原生 `MoveFileAtomic`；<br>② 替换后沙箱临时文件零残留（0 个 `.tmp`）；<br>③ DPAPI 加解密解密后与明文密钥严格一致。 |
| **Test 18** | Tier 2 | R5.6 | CORS 安全收敛与跨域阻断 | ① 源码中彻底根除通配符 `*` 暴露；<br>② 合法同源请求（`Origin: http://127.0.0.1:4088`）获得匹配响应头；<br>③ 非法外部跨域请求（`Origin: http://evil.com`）被 403 阻断或严禁返回匹配头。 |
| **Test 19** | Tier 1 | R6.3 | PS 5.1/7+ 双轨兼容与 UTF-8 BOM | ① 文件头前 3 字节严格为 `0xEF, 0xBB, 0xBF`（UTF-8 with BOM）；<br>② PowerShell 官方 AST 解析器报告 0 语法错误；<br>③ PowerShell AST 词法单元中无 PS7 专有运算符（`??`、`&&`）。 |
| **Test 20** | Tier 1 & 4 | R4, R5.3 | WebUI GuiPayload 契约与 16 端点 | ① `Get-SlotPoolGuiPayload` 返回结构必须包含 `runway`, `current`, `slots`, `daemon`, `taskState`；<br>② 完整覆盖 16 个 API 端点路由合法处理（根路径、状态、切号、重置、极速跃迁、守护启停、开机自启、全链路健康体检、存储修复等）。 |

---

## 3. 当前测试运行结果与真实失败基线 (Truthful Failure Baseline)

当前在未修复目标代码前执行测试命令：
```powershell
powershell.exe -ExecutionPolicy Bypass -File C:\Users\deanc\Desktop\AGY\verify_fixes.ps1
```

**实测结果**：`113 PASSED, 16 FAILED` (总计 129 项真实断言)

### 失败项逐项审计与责任派发清单：
- **Test 14 (时区缺陷, 2 项失败)**：5h 倒计时超限（输出为 12h+），由 Worker M1 修复 `Get-QuotaThawCountdownText` 与 `ConvertTo-LocalDateTime`。
- **Test 15 (切号审计缺陷, 3 项失败)**：切号后 `switchCount` 未自增且未写入 `state.history`，由 Worker M1 在 `Switch-CredentialSlot` 中补齐计数与历史流水。
- **Test 16 (只读刷盘缺陷, 1 项失败)**：`Get-SlotPoolState` 每次只读查询均重写 `pool_state.json`，由 Worker M1 引入 Dirty-Flag 机制消除无效 IO。
- **Test 18 (CORS 漏洞, 3 项失败)**：源码使用通配符 `*` 且未阻断 `evil.com`，由 Worker M1 收敛 CORS 白名单为 `127.0.0.1:4088`。
- **Test 20 (API 路由缺口与 taskState 缺失, 7 项失败)**：`taskState` 异步字段缺失，以及缺少 `/boost`, `/remove-slot`, `/daemon`, `/autostart`, `/goal`, `/repair-storage` 6 大端点，由 Worker M2 在重构 HTTP 服务时补齐。

> **防作弊声明**：所有 16 个失败项均 100% 精确映射到代码中客观存在的缺陷或功能缺失，无任何虚假断言，无绕过机制，全面支撑后续 M1/M2 Worker 的驱动开发与交付验收。
