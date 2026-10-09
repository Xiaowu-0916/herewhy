#Requires -Version 5.1
<#
.SYNOPSIS
    Regenerate the synthetic sample report shipped in samples/.
.DESCRIPTION
    This script uses fabricated data only. The published HTML preview, JSON, and
    console transcript must never contain real machine paths, PIDs, addresses,
    or software inventory.
#>
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'HereWhy.ps1')

$taskAction = New-Action `
    -Title '禁用计划任务 \Example\AgentUpdate' `
    -Command 'Disable-ScheduledTask -TaskPath ''\Example\'' -TaskName ''AgentUpdate''' `
    -Note '禁用可随时用 Enable-ScheduledTask 恢复，不删除任务。'

$subject = [pscustomobject]@{
    Scope          = 'process'
    Pid            = 4212
    Pids           = @(4212)
    PidDisplay     = '4212'
    Name           = 'ExampleAgent.exe'
    Path           = 'C:\Program Files\Example Agent\ExampleAgent.exe'
    Exists         = $true
    Company        = 'Example Software Ltd.'
    Product        = 'Example Agent'
    FileVersion    = '4.2.1.0'
    Description    = 'Example Agent background service'
    Signature      = [pscustomobject]@{ Status = 'Valid'; Signer = 'Example Software Ltd.' }
    CommandLine    = '"C:\Program Files\Example Agent\ExampleAgent.exe" --service'
    Started        = [datetime]'2026-10-09 09:15:22'
    LastWriteTime  = $null
    ParentChain    = @(
        [pscustomobject]@{ Pid = 712; Name = 'services.exe'; Path = 'C:\Windows\System32\services.exe' },
        [pscustomobject]@{ Pid = 688; Name = 'wininit.exe'; Path = 'C:\Windows\System32\wininit.exe' }
    )
    HostedServices = @()
    Network        = @(
        [pscustomobject]@{ Protocol = 'TCP'; State = 'Listen';      LocalAddress = '127.0.0.1';  LocalPort = 41000; RemoteAddress = '0.0.0.0';      RemotePort = 0;   Pid = 4212 },
        [pscustomobject]@{ Protocol = 'TCP'; State = 'Established'; LocalAddress = '192.0.2.10'; LocalPort = 51524; RemoteAddress = '198.51.100.20'; RemotePort = 443; Pid = 4212 }
    )
    Ownership      = [pscustomobject]@{
        Name         = 'Example Agent'
        Publisher    = 'Example Software Ltd.'
        Version      = '4.2.1'
        MatchBase    = 'C:\Program Files\Example Agent\'
        RegistryPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\ExampleAgent'
        IsDriveRoot  = $false
        Confidence   = 'High'
    }
    Evidence       = @(
        [pscustomobject]@{
            Type        = 'Ownership'
            TypeLabel   = '安装归属'
            Confidence  = 'High'
            SourceLabel = '安装记录：Example Agent'
            Detail      = '安装记录「Example Agent」的安装位置/图标路径匹配 C:\Program Files\Example Agent\（版本 4.2.1）'
            Action      = $null
        },
        [pscustomobject]@{
            Type        = 'ScheduledTask'
            TypeLabel   = '计划任务'
            Confidence  = 'High'
            SourceLabel = '计划任务：\Example\AgentUpdate'
            Detail      = '计划任务 \Example\AgentUpdate 直接执行该程序（状态 Ready）'
            Action      = $taskAction
        }
    )
    Verdict        = [pscustomobject]@{
        Level              = 'installed'
        Summary            = '属于已安装软件「Example Agent」；启动来源：计划任务：\Example\AgentUpdate'
        StartupSourceCount = 1
    }
    Cautions       = @('示例数据：此报告用于展示版式，不包含任何真实机器信息。')
    Actions        = @($taskAction)
}

$report = [pscustomobject]@{
    Tool        = 'HereWhy'
    Version     = '1.0.0'
    GeneratedAt = '2026-10-09 12:00:00'
    Target      = [pscustomobject]@{ Kind = '进程名'; Value = 'ExampleAgent' }
    Subjects    = @($subject)
    ScanStats   = [pscustomobject]@{ Processes = 180; Installed = 42; Autostart = 12; Services = 210; Tasks = 64; Network = 96 }
    Warnings    = @()
}

$sampleDir = Join-Path $root 'samples'
[void](New-Item -ItemType Directory -Path $sampleDir -Force)

$encoding = New-Object System.Text.UTF8Encoding($false)
New-HtmlReport -Report $report -OutPath (Join-Path $sampleDir 'sample-report.html')
[System.IO.File]::WriteAllText((Join-Path $sampleDir 'sample-report.json'), ($report | ConvertTo-Json -Depth 8), $encoding)

$consoleText = @'
====================================================================
 HereWhy 为何在此 v1.0.0 | 后台项溯源报告
 目标：进程名 = ExampleAgent
 时间：2026-10-09 12:00:00    只读诊断，不会修改系统
====================================================================

[1/1] ExampleAgent.exe  PID 4212
--------------------------------------------------------------------
  位置    : C:\Program Files\Example Agent\ExampleAgent.exe
  启动于   : 2026-10-09 09:15:22
  身份    : Example Software Ltd. | Example Agent | v4.2.1.0
  签名    : 有效，签名者 Example Software Ltd.
  父链    : services.exe(712) <- wininit.exe(688)
  网络    : TCP LISTEN 127.0.0.1:41000; 已建立连接 1 条
  结论    : 属于已安装软件「Example Agent」；启动来源：计划任务：\Example\AgentUpdate

  依据：
   - [高] 安装归属：安装记录「Example Agent」的安装位置/图标路径匹配 C:\Program Files\Example Agent\（版本 4.2.1）
   - [高] 计划任务：计划任务 \Example\AgentUpdate 直接执行该程序（状态 Ready）

  安全操作建议（工具不会执行，请你确认后手动操作）：
   1) 禁用计划任务 \Example\AgentUpdate
      Disable-ScheduledTask -TaskPath '\Example\' -TaskName 'AgentUpdate'
      注意：禁用可随时用 Enable-ScheduledTask 恢复，不删除任务。

  ! 示例数据：此报告用于展示版式，不包含任何真实机器信息。
'@
[System.IO.File]::WriteAllText((Join-Path $sampleDir 'sample-console.txt'), $consoleText, $encoding)

Write-Host ('Synthetic samples written to ' + $sampleDir) -ForegroundColor Green
