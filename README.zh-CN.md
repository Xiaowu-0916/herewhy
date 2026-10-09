# HereWhy（为何在此）

**别再猜那个后台进程是干什么的了。**

HereWhy 是一个只读的 Windows 后台项溯源工具，只回答一个日常问题：

> “电脑里跑着这个东西。它是什么、谁装的、为什么启动、能不能安全关掉？”

给它一个进程名、PID、监听端口或 `.exe` 路径，它会交叉比对进程、安装记录、服务、计划任务、启动项、父进程链与网络端口，最后给出一份普通人能看懂的溯源报告。

## 它回答什么

1. **这是什么？** 公司、产品、版本、文件说明，以及可选的数字签名校验。
2. **谁装的？** 与卸载注册表记录（`InstallLocation` / `DisplayIcon`）匹配，包括“安装程序把整个磁盘根目录当成安装目录”这种糟糕情况。
3. **为什么启动？** 服务、计划任务、注册表 Run 启动项、启动文件夹，或由父进程按需拉起。
4. **怎么安全关掉？** 给出可回滚、可复制的命令与注意事项。HereWhy 自己绝不执行。

## 和现有工具的区别

任务管理器负责“列出来”，Autoruns 负责“全都倒出来”，Process Explorer 负责“看线程和句柄”。它们都不会用一次扫描回答“它为什么在这里、下一步怎么做才安全”。

| 工具 | 是什么 | 属于哪个软件 | 为什么启动 | 可回滚操作方案 | 零安装 |
| --- | --- | --- | --- | --- | --- |
| 任务管理器 | 部分 | 否 | 否 | 部分 | 是 |
| Autoruns | 否 | 否 | 只列条目，靠人判断 | 否 | 是 |
| Process Explorer | 部分 | 否 | 否 | 否 | 是 |
| **HereWhy** | **是** | **是** | **是** | **是** | **是** |

## 环境要求

- Windows 10 或 Windows 11。
- Windows PowerShell 5.1（系统自带）或 PowerShell 7+。
- 无需安装、无需额外依赖；普通权限即可使用，管理员权限能看到更多受保护系统进程的细节。

## 快速开始

```powershell
# 先看有哪些监听端口和第三方后台进程
.\HereWhy.ps1 -List

# 按进程名查（默认子串匹配）
.\HereWhy.ps1 -Name cc-switch

# 查某个端口被谁占用、为什么在这里
.\HereWhy.ps1 -Port 135

# 按 PID 查，并校验数字签名
.\HereWhy.ps1 -Id 21968 -Deep

# 查一个当前没有运行的可执行文件
.\HereWhy.ps1 -Path "D:\Tools\agent.exe"

# 同时生成自包含 HTML 报告和 JSON 数据
.\HereWhy.ps1 -Name cc-switch -Deep -HtmlReport .\report.html -Json .\report.json
```

也可以直接双击 `Run-HereWhy.cmd`，或在命令行使用：

```cmd
Run-HereWhy.cmd -List
```

## 实际输出示例

```text
====================================================================
 HereWhy 为何在此 v1.0.0 | 后台项溯源报告
 目标：进程名 = ExampleAgent
 时间：2026-10-09 12:00:00    只读诊断，不会修改系统
====================================================================

[1/1] ExampleAgent.exe  PID 4212
--------------------------------------------------------------------
  位置    : C:\Program Files\Example Agent\ExampleAgent.exe
  启动于   : 2026-10-09 09:15:22
  身份    : Example Software Ltd. | Example Agent | v4.2.1
  签名    : 有效
  父链    : services.exe(712) <- wininit.exe(688)
  网络    : TCP LISTEN 127.0.0.1:41000
  结论    : 属于已安装软件「Example Agent」；启动来源：计划任务：\Example\AgentUpdate

  依据：
   - [高] 安装归属：安装记录「Example Agent」的安装位置/图标路径匹配 C:\Program Files\Example Agent\（版本 4.2.1）
   - [高] 计划任务：\Example\AgentUpdate 直接执行该程序
```

仓库内附有一张合成数据的 HTML 预览图：`samples/sample-report.png`，不包含任何真实机器信息。

## 数据来源

全部在本地完成，全部只读：

| 来源 | 用途 |
| --- | --- |
| `Win32_Process` | 活动进程、命令行、父进程链、启动时间 |
| 卸载注册表项 | 已安装软件归属与版本 |
| `Win32_Service` | 服务宿主与启动关系 |
| `Get-ScheduledTask` | 计划任务启动关系 |
| Run / RunOnce 注册表项 | 当前用户与全机器启动项 |
| 启动文件夹 | 快捷方式与脚本自启项 |
| `Get-NetTCPConnection` / `Get-NetUDPEndpoint` | 监听端口与占用 PID（不可用时退回 `netstat`） |
| `Get-AuthenticodeSignature` | 使用 `-Deep` 时的可选签名校验 |

## 置信度模型

HereWhy 不会把不同强度的线索混为一谈：

- **高**：安装记录、服务、计划任务或启动项与可执行文件路径精确匹配。
- **中**：命令行中出现程序名，但完整路径不一致。脚本和批处理转发常见这种情况。
- **低**：弱信号，需要结合其它证据人工判断。

最难的场景是“脚本启动启动器、启动器再启动真正程序”的间接链路。HereWhy 只报告能证明的部分，其余明确标为不确定。

## 安全与隐私

- 只读：不删除文件、不改注册表、不停服务、不禁用任务、不改配置。
- 不联网：所有采集与渲染都在本机完成。
- 操作建议只输出，不执行；是否处理由你决定。
- 系统组件只解释、不提供停用命令。
- `svchost.exe` 这类共享宿主按 PID 分开分析，不会把不同实例的服务混在一起。

## 参数

| 参数 | 含义 |
| --- | --- |
| `-List` | 列出监听进程与当前用户自启项 |
| `-Name <匹配>` | 按进程名匹配；支持子串、`*` 通配符与 `/正则/` |
| `-Id <PID>` | 分析一个或多个 PID |
| `-Port <端口>` | 找到占用该本地端口的进程并分析 |
| `-Path <exe>` | 分析文件，无论当前是否在运行 |
| `-Deep` | 校验 Authenticode 数字签名（较慢） |
| `-HtmlReport <路径>` | 生成自包含 HTML 报告 |
| `-Json <路径>` | 导出完整 JSON 报告 |
| `-MaxSubjects <n>` | 最多分析几个进程组（默认 5） |
| `-NoColor` | 关闭彩色输出 |

## 已知限制

- 受保护进程可能隐藏可执行文件路径；HereWhy 会依次用服务表、`System32` 同名文件和 `CommandLine` 兜底。
- 计划任务与启动项匹配基于路径。运行时才拼出真实路径的脚本只能作为中等置信度线索。
- `-Deep` 首次校验冷文件时可能需要一点时间。
- 这是诊断工具，不是杀毒软件；它不会给文件打“恶意”分数。

## 开发与测试

```powershell
# Windows PowerShell 5.1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-HereWhy.ps1

# PowerShell 7
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-HereWhy.ps1
```

测试套件共 36 项，不依赖 Pester，覆盖路径解析、通配符与正则匹配、安装记录归因、证据链生成、系统服务保护、HTML 转义与报告生成。

2026-10-09 在 Windows 11 上实测：Windows PowerShell 5.1.26100 与 PowerShell 7.6.5 均为 `36 passed, 0 failed`。

## 许可证

MIT，详见 [LICENSE](LICENSE)。
