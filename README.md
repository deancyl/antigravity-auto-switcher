# Antigravity Auto Switcher (AGY 官方原生合规多账号智能轮换与原会话无损续接助手) 🚀

[![Version](https://img.shields.io/badge/Release-v0.2.0-blue.svg)](https://github.com/deancyl/antigravity-auto-switcher/releases)
[![Platform](https://img.shields.io/badge/Platform-Windows%2010%2F11-0078D6.svg)](https://microsoft.com)
[![Protocol](https://img.shields.io/badge/Protocol-Zero--CDP%20Native%20Connect--RPC-success.svg)](https://github.com/deancyl/antigravity-auto-switcher)
[![Compliance](https://img.shields.io/badge/Compliance-100%25%20Official%20Native%20(No%20Proxy)-green.svg)](https://github.com/deancyl/antigravity-auto-switcher)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

> **专为 Google Antigravity 2.0 打造的原生合规多账号无人值守守护工具**。  
> 突破传统逆向反代的高危风控与脆弱网页模拟，基于 **Zero-CDP 官方原生 LanguageServer Connect-RPC 协议**，实现 5 小时/周限额全自动平滑切号、原会话内核级无损续接与全账号实时配额看板。

---

## 🌟 核心突破：从脆弱 CDP 到 Zero-CDP 官方原生架构

市面上传统的切号工具往往采用中间人反代（API Proxy）或基于 Chromium DevTools Protocol (CDP) 的网页模拟点击，存在严重的风控隐患与稳定性死结：

```
【传统路线 A (中间人反代)】: 伪造 Token 缝合请求，极易触发 Google Cloud Armor 跨账号审计连带封号！
【传统路线 B (CDP DOM 模拟)】: 强行依赖调试端口模拟键盘打字，因 10MB 前端渲染延迟频发 90 秒超时死锁！

【本项目原生突破 (Zero-CDP Native Connect-RPC)】:
切号完成 ──> 探测本地 127.0.0.1 官方 LanguageServer ──> 毫秒级下发 SendUserCascadeMessage ──> 推演核心直接开始推理！(耗时 < 200ms)
```

| 维度 | 传统反代方案 (如部分开源工具) | 旧版 CDP DOM 模拟 | **本项目 Zero-CDP 原生方案 (v0.2.0)** |
| :--- | :--- | :--- | :--- |
| **官方合规性** | ❌ **严重违规** (逆向私有 API，跨号 Token 缝合，高危封号) | ⚠️ **脆弱网页模拟** (把桌面客户端当作网页黑盒) | ✅ **100% 官方正版原生** (基于系统 Windows Credential Keyring，零改包) |
| **续接机制** | 强行在中途替换 HTTP Token | 模拟 CDP 查找 DOM 输入框与按键 | ✅ **直连 LanguageServer Connect-RPC** (`SendUserCascadeMessage`) |
| **执行耗时** | 不断流但有封号风险 | 经常触发 25~90 秒等待甚至超时断流 | ✅ **< 200 毫秒瞬间唤醒**，推演核心直接开始吐字 |
| **界面与版本耦合** | 无法直接用于桌面 GUI | 前端改版、DPI 缩放、弹窗遮罩必挂 | ✅ **零界面耦合**，完全免疫任何前端 UI 调整与样式变化 |
| **会话状态保全** | 丢失上下文历史推演 | 容易出现多会话切换相互踩踏 | ✅ **100% 保留全部步骤历史与推演深度**，零上下文断层 |

---

## ⚡ 核心功能与演进能力

### 1. 🎯 `/goal` 目标驱动模式与全链路健康度体检
- **命令调用**：`pwsh antigravity_compliant_helper.ps1 -Action goal` 或菜单输入 **`goal` / `/goal`**；
- **全链路体检输出**：
  1. 当前活跃模型名称、模型组归属及原模型严格锁定状态；
  2. 槽位池账号规模与当前驻留槽位；
  3. 后台无人值守守护进程 PID 与存活状态；
  4. Windows 开机自启快捷方式就绪状态；
  5. 当前活跃模型组在各槽位池的真实可用配额数（如 `3 / 5 个就绪`）；
  6. 实时配额看板展示。

### 2. ⚡ `/boost` 极速提速模式与实时最优跃迁
- **命令调用**：`pwsh antigravity_compliant_helper.ps1 -Action boost` 或菜单输入 **`boost` / `/boost`**；
- **极速跃迁机制**：立即并行拉取槽位池全部账号的云端真实剩余配额，精准识别当前活跃模型组（Gemini / Claude / Argon）配额最高的最佳槽位，若当前槽位配额偏低，则 1 秒内无损切入最优账号并恢复推演。

### 3. 🔒 严格原模型组锁定 (Strict Model Group Locking)
- **细粒度多模型组监控**：完整支持并区分 **Gemini (5h/周)**、**Argon (周)**、**Claude (5h/周)** 3 大模型桶；
- **严防模型降智/漂移**：切号前严格核验候选槽位在**当前模型组**的剩余额度必须大于 1%；对于 Argon 模型，强制核验账号是否具备 Argon 权限且配额充足；
- **耗尽终极锁死**：当当前模型组的所有账号均已耗尽配额时，系统坚决**停止自动切号并声光报警**，严格保护当前复杂推演上下文，绝不跨模型组强切或降级为小模型。

### 4. 🔕 Windows 开机无感知快捷方式自启 (AV-Friendly)
- **卡巴斯基/360 零误报**：菜单 **`[A]`** 或托盘右键可一键切换开机自启；
- **纯快捷方式安全落盘**：仅在 `shell:startup`（`%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup`）创建纯桌面快捷方式，**严格禁止修改注册表 Run 键**，彻底杜绝杀软拦截；
- **彻底告别 `.vbs`**：所有守护托管全面采用 Windows 原生脱钩方式，彻底移除 `.vbs` 脚本。

### 5. 🛡️ 10 大防御性工程重构
1. **app_storage.json 非破坏性保护**：彻底移除误伤 4 空格缩进的重置逻辑，保留全部用户定制字段，写前自动 `.bak` 备份；
2. **远程 Google API 证书链强校验**：严格启用 TLS 证书校验，仅对 127.0.0.1 本地 RPC 环回地址放行，请求头统一声明 `User-Agent: antigravity/2.25.0 (windows; amd64)`；
3. **全量存储写入原子化与回滚机制**：Windows 凭据与 CLI Token 写入前自动快照；一旦发生异常自动回滚至先前状态；
4. **DPAPI 凭据即时写入深度校验**：槽位保存后即刻解密回读校验，杜绝空凭据落盘；
5. **守护进程 PID 防重用与启动时间比对**：PID 文件采用 JSON 结构 `{ pid, processName, startTime }`，严防进程退出后 PID 被系统其他进程重用；
6. **跨进程状态互斥锁超时显式拦截**：`Invoke-WithPoolStateMutex` 获取锁超时抛出明确错误，防止写冲突覆盖；
7. **PowerShell 7 (Core) 完整程序集支持**：内联 C# 编译显式引入 26 个 Core 运行时程序集并捕获明确编译报错；
8. **冷却重置与 Argon 权限识别**：`Reset-SlotCooldown` 手动重置时自动将耗尽配额恢复为 100% 并清除各模型重置时间戳；修复活跃槽位匹配时过滤冷却状态的 Bug；
9. **纯只读状态探测**：状态查看完全剔除剪贴板篡改与菜单自动拉起守护的副作用；
10. **安全密钥掩码与 Python 子进程超时防卡死**：API Key 交互输入支持 `-AsSecureString` 掩码；会话数据库读取子进程配置 5 秒硬超时与自动 Kill 保护。

---

## 📂 项目结构

```text
├── antigravity_compliant_helper.ps1   # 核心 PowerShell 5.1/7 双引擎合规切换与守护引擎
├── 开启自动切号守护.bat                 # 一键启动后台无窗口守护进程与系统托盘图标
├── 停止自动切号守护.bat                 # 一键停止后台守护进程
├── 查看自动切号状态与槽位池.bat         # 呼出实时全账号配额看板与交互式控制台
├── 运行合规切换助手.bat                 # 启动完整功能管理终端
├── 保存当前账号至槽位.bat               # 快速将当前 AGY2 登录的官方账号快照存入槽位
├── 手动切到下一账号.bat                 # 一键手动轮转至下一个可用槽位并自动续接会话
├── ANTIGRAVITY_HANDOVER.md            # 跨账号上下文接力档案模板
└── run.bat                            # 极简通用启动入口
```

---

## 🚀 常用操作指令

| 场景 | 命令行指令 | 交互菜单按键 | 说明 |
| :--- | :--- | :--- | :--- |
| **保存槽位** | `pwsh antigravity_compliant_helper.ps1 -Action save -Slot <Name>` | `[1]` | 将当前客户端登录态加密快照存入槽位 |
| **手动切号** | `pwsh antigravity_compliant_helper.ps1 -Action switch -Slot <Name>` | `[2]` | 切换至指定槽位并自动重启续接 |
| **立即轮换** | `pwsh antigravity_compliant_helper.ps1 -Action next-slot` | `[3]` | 立即轮换切入下一个可用槽位 |
| **看板状态** | `pwsh antigravity_compliant_helper.ps1 -Action status` | `[4]` | 刷新本地全账号实时配额看板状态 |
| **刷新配额** | `pwsh antigravity_compliant_helper.ps1 -Action refresh-quota` | `[R]` | 强制从云端接口同步各账号最新配额 |
| **后台守护** | `pwsh antigravity_compliant_helper.ps1 -Action start-daemon` | `[5]` | 开启后台守护与右下角托盘图标 |
| **停止守护** | `pwsh antigravity_compliant_helper.ps1 -Action stop-daemon` | `[6]` | 停止无人值守后台守护 |
| **应急修复** | `pwsh antigravity_compliant_helper.ps1 -Action repair-storage` | `[7]` | 一键应急修复/重置受损配置彻底解决闪退 |
| **重置冷却** | `pwsh antigravity_compliant_helper.ps1 -Action reset-cooldown -Slot all` | `[8]` | 重置槽位冷却计时器与配额基线 |
| **开机自启** | - | `[A]` | 一键开启/关闭 Windows 开机无感自启 |
| **删除槽位** | `pwsh antigravity_compliant_helper.ps1 -Action delete -Slot <Name>` | `[D]` | 删除已保存的加密槽位 |
| **目标体检** | `pwsh antigravity_compliant_helper.ps1 -Action goal` | 快捷指令 `goal` / `/goal` | 全链路健康度体检与可用槽位数核验 |
| **极速提速** | `pwsh antigravity_compliant_helper.ps1 -Action boost` | 快捷指令 `boost` / `/boost` | 核验云端实时配额并跃迁至最高槽位 |

---

## 🔒 隐私与安全承诺 (Air-Gapped & Native Safe)

- **零数据上报**：本项目为 100% 纯本地运行的脚本工程，绝不上报任何私有凭据、代码或对话数据到任何第三方服务器；
- **系统硬件加密**：所有 Token 均通过 Windows 原生 DPAPI 加密隔离保护，仅当前 Windows 登录用户具备解密权限；
- **零协议篡改**：完全保持官方 Electron/Chromium 网络栈与 TLS 握手指纹，绝不进行中间人代理解密或请求体篡改，确保账号绝对安全。

---

## 📄 开源许可证

本项目基于 [MIT License](LICENSE) 协议开源。
