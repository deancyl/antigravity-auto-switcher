# Antigravity Auto Switcher (AGY 官方原生合规多账号智能轮换与原会话无损续接助手) 🚀

[![Version](https://img.shields.io/badge/Release-v0.1.0-blue.svg)](https://github.com/deancyl/antigravity-auto-switcher/releases)
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

| 维度 | 传统反代方案 (如部分开源工具) | 旧版 CDP DOM 模拟 | **本项目 Zero-CDP 原生方案 (v0.1.0)** |
| :--- | :--- | :--- | :--- |
| **官方合规性** | ❌ **严重违规** (逆向私有 API，跨号 Token 缝合，高危封号) | ⚠️ **脆弱网页模拟** (把桌面客户端当作网页黑盒) | ✅ **100% 官方正版原生** (基于系统 Windows Credential Keyring，零改包) |
| **续接机制** | 强行在中途替换 HTTP Token | 模拟 CDP 查找 DOM 输入框与按键 | ✅ **直连 LanguageServer Connect-RPC** (`SendUserCascadeMessage`) |
| **执行耗时** | 不断流但有封号风险 | 经常触发 25~90 秒等待甚至超时断流 | ✅ **< 200 毫秒瞬间唤醒**，推演核心直接开始吐字 |
| **界面与版本耦合** | 无法直接用于桌面 GUI | 前端改版、DPI 缩放、弹窗遮罩必挂 | ✅ **零界面耦合**，完全免疫任何前端 UI 调整与样式变化 |
| **会话状态保全** | 丢失上下文历史推演 | 容易出现多会话切换相互踩踏 | ✅ **100% 保留全部步骤历史与推演深度**，零上下文断层 |

---

## ⚡ 核心功能与特性

### 1. 🔄 5小时/周限额环形冷却槽位池 (Slot Pool)
- 支持任意多个 Google 账号（如 `slot1`, `slot2`, `a`, `b`, `c` 等）；
- 本地 Windows DPAPI 硬件级加密保存凭据（位于 `~/.gemini/compliant-switcher/slots/`），严禁明文落地；
- 具备 5 小时解冻计时器与重置倒计时算法，当当前槽位触发 5 小时限额时，自动无缝切入下一个就绪槽位。

### 2. 🧠 SQLite WAL 递归 CTE 权威会话状态捕获
- 彻底废除前端 DOM 文本抓取与英文时间猜解；
- 直读本地 [`conversation_summaries.db`](file:///C:/Users/deanc/.gemini/antigravity/conversation_summaries.db) 权威数据，通过递归公共表表达式（CTE）算法，100% 精准识别当前处于运行态（`status = RUNNING` 或 `not_fully_idle = 1`）的活跃根会话。

### 3. 🛡️ 彻底防闪退平滑退役 (Zero-Crash Teardown)
- **绝对杜绝强杀子进程**：严禁杀 `language_server.exe`，彻底根除 Windows 11 下破坏 ConPTY/Stdio 管道导致的 Electron `0x800700e8` 级联闪退；
- **CDP `Browser.close` 权威退役**：通过 Chromium 内核级接口通知平滑落盘与安全退出；
- **内核锁排他检测**：以非阻塞写权限尝试打开 `lockfile`，物理确认句柄完全释放后再拉起新实例，彻底杜绝单实例锁（`SingleInstanceLock`）造成的秒退。

### 4. 🚀 毫秒级原生 RPC 续接 (Zero-CDP Auto-Resume)
- 调用官方 `GetCascadeModelConfigData` 提取新账号可用模型；
- 调用官方 `GetResolvedCascadeConfig` 原生合成权威 `cascadeConfig` 环境；
- 携带完整模型参数调用 `SendUserCascadeMessage`，推演核心直接恢复运行，并通过已建立的 Reactive 流向界面实时广播。

### 5. 🎛️ 桌面托盘常驻与极简交互
- 支持后台静默常驻，并在右下角系统托盘显示状态小图标 `[A]`；
- 托盘右键菜单动态集成各账号实时配额概览与待命会话一键直达入口；
- 配套全套免配置 Windows 批处理入口（`.bat`），开箱即用。

---

## 📂 项目结构

```text
├── antigravity_compliant_helper.ps1   # 核心 PowerShell 5.1/7 双引擎合规切换与守护引擎
├── daemon_runner.vbs                  # Windows 原生无黑框内核级静默后台托管脚本
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

## 🚀 快速上手

### 1. 下载安装
从 [GitHub Releases](https://github.com/deancyl/antigravity-auto-switcher/releases) 下载最新版本的 `Antigravity-Auto-Switcher-v0.1.0.zip`，解压至任意目录（建议存放在固定目录，如 `C:\Users\<YourUser>\Desktop\AGY`）。

### 2. 录入您的多账号槽位
1. 打开官方 **Google Antigravity 2.0** 桌面客户端，正常登录您的第 1 个 Google 账号；
2. 双击运行 `保存当前账号至槽位.bat`，根据提示输入槽位名称（例如 `a` 或 `slot1`）；
3. 在 Antigravity 中登出并登录第 2 个 Google 账号，再次双击 `保存当前账号至槽位.bat` 保存为 `b`；
4. 重复以上步骤，录入全部备用账号（建议 3~5 个账号组成高可用矩阵）。

### 3. 一键开启后台无人值守守护
- 双击运行 **`开启自动切号守护.bat`**：
  - 控制台将瞬间无黑框退出，右下角系统托盘出现 `[A]` 图标；
  - 守护进程将在后台静默监听 5 小时配额与限额信号；
  - 一旦触发限额，自动优雅退出旧实例、轮换凭据、拉起新账号，并通过官方 RPC **自动唤醒原会话继续推演**，全程无需人工干预！

### 4. 管理与查看看板
- 双击 **`查看自动切号状态与槽位池.bat`** 随时唤出实时配额看板，查看所有账号的 5h/周 真实剩余配额与重置倒计时：
```text
========================================================================================
   Antigravity 5小时/周限额全自动切号与全账号实时配额看板 (原会话续接 · 托盘小标)
========================================================================================
  无人值守守护状态   : ● 后台无窗口常驻中 (PID: 28412 | 右下角托盘 [A] 图标已常驻)
  AGY2 界面当前账号  : user_a@gmail.com (槽位: [a] | 指纹: 01e02e6a)
  原会话锁定与RPC源  : 原会话 [项目重构与优化] | 已连接本地 LanguageServer RPC (127.0.0.1:13006 (Live RPC))
----------------------------------------------------------------------------------------
  全账号槽位池实时剩余配额总览 (Gemini 5h/周 & Claude 5h/周 | 按 [R] 刷新全部账号云端配额):
  #    槽位     状态       账号邮箱                   Gemini(5h/周)   Claude(5h/周)   重置/冷却倒计时           切换
  --------------------------------------------------------------------------------------
  [1 ] a      ACTIVE   user_a@gmail.com        74% /  36%    100% /  --     ★ 使用中(03h06m后重置)   1次
  [2 ] b      READY    user_b@gmail.com       100% /   1%    100% /  --     就绪 (待命备用)          2次
  [3 ] c      READY    user_c@gmail.com        86% /  15%    100% /  --     就绪(01h23m后重置)      2次
========================================================================================
```

---

## 🔒 隐私与安全承诺 (Air-Gapped & Native Safe)

- **零数据上报**：本项目为 100% 纯本地运行的脚本工程，绝不上报任何私有凭据、代码或对话数据到任何第三方服务器；
- **系统硬件加密**：所有 Token 均通过 Windows 原生 DPAPI 加密隔离保护，仅当前 Windows 登录用户具备解密权限；
- **零协议篡改**：完全保持官方 Electron/Chromium 网络栈与 TLS 握手指纹，绝不进行中间人代理解密或请求体篡改，确保账号绝对安全。

---

## 📄 开源许可证

本项目基于 [MIT License](LICENSE) 协议开源。
