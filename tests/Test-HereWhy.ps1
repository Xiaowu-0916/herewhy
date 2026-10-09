#Requires -Version 5.1
<#
.SYNOPSIS
    HereWhy 自包含测试套件（不依赖 Pester）。
.DESCRIPTION
    直接点源 HereWhy.ps1，然后测试其中的纯函数与 HTML 生成逻辑。
    用法：powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-HereWhy.ps1
#>
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 1.0

$toolPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'HereWhy.ps1'
if (-not (Test-Path -LiteralPath $toolPath)) {
    Write-Host ('找不到主脚本：' + $toolPath) -ForegroundColor Red
    exit 1
}
. $toolPath

$script:PassCount = 0
$script:FailCount = 0
$script:FailureLines = New-Object System.Collections.ArrayList

function Assert-True {
    param([bool]$Condition, [string]$TestName)
    if ($Condition) {
        $script:PassCount++
        Write-Host ('PASS  ' + $TestName) -ForegroundColor Green
    } else {
        $script:FailCount++
        [void]$script:FailureLines.Add($TestName)
        Write-Host ('FAIL  ' + $TestName) -ForegroundColor Red
    }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$TestName)
    $expectedText = [string]$Expected
    $actualText = [string]$Actual
    if ($expectedText -ceq $actualText) {
        $script:PassCount++
        Write-Host ('PASS  ' + $TestName) -ForegroundColor Green
    } else {
        $script:FailCount++
        [void]$script:FailureLines.Add($TestName)
        Write-Host ('FAIL  {0} (expected=[{1}] actual=[{2}])' -f $TestName, $expectedText, $actualText) -ForegroundColor Red
    }
}

function Assert-Match {
    param([string]$Pattern, [string]$Text, [string]$TestName)
    if ($Text -match $Pattern) {
        $script:PassCount++
        Write-Host ('PASS  ' + $TestName) -ForegroundColor Green
    } else {
        $script:FailCount++
        [void]$script:FailureLines.Add($TestName)
        Write-Host ('FAIL  {0} (pattern={1} text={2})' -f $TestName, $Pattern, $Text) -ForegroundColor Red
    }
}

$fixtureRoot = Join-Path $env:TEMP ('herewhy-tests-' + [Guid]::NewGuid().ToString('N'))
$fixtureAppDir = Join-Path $fixtureRoot 'Program Files\Demo App'
$fixtureExe = Join-Path $fixtureAppDir 'demo app.exe'

try {
    [void](New-Item -ItemType Directory -Path $fixtureAppDir -Force)
    Set-Content -LiteralPath $fixtureExe -Value 'stub' -Encoding ASCII
    $env:HEREWHY_TEST_ROOT = $fixtureRoot

    # --- 路径解析 -----------------------------------------------------------
    Assert-Equal $fixtureExe (ConvertTo-NormalizedPath ('"' + $fixtureExe + '" -run')) 'NormalizePath: 去掉引号与参数'
    Assert-Equal $fixtureExe (Resolve-ExecutablePath ('"' + $fixtureExe + '" --serve')) 'ResolveExecutablePath: 带引号路径'
    Assert-Equal $fixtureExe (Resolve-ExecutablePath ($fixtureExe + ' --serve')) 'ResolveExecutablePath: 未加引号的含空格路径'
    Assert-Equal $fixtureExe (Resolve-ExecutablePath ('%HEREWHY_TEST_ROOT%\Program Files\Demo App\demo app.exe -q')) 'ResolveExecutablePath: 环境变量展开'
    Assert-Equal 'C:\Tools\missing.exe' (Resolve-ExecutablePath 'C:\Tools\missing.exe -x') 'ResolveExecutablePath: 文件不存在时回退首段'
    Assert-Equal 'c:\foo\bar' (Get-PathKey 'C:\Foo\Bar\') 'GetPathKey: 统一小写并去掉尾斜杠'
    Assert-True (Test-PathWithin 'C:\Foo\Bar\app.exe' 'C:\Foo') 'TestPathWithin: 子目录匹配'
    Assert-True (-not (Test-PathWithin 'C:\Foobar\app.exe' 'C:\Foo')) 'TestPathWithin: 前缀相近但不越界'

    # --- 进程匹配与分组 -----------------------------------------------------
    $processes = @(
        [pscustomobject]@{ Pid = 11; Name = 'chrome.exe';   ExecutablePath = 'C:\App\chrome.exe';   CommandLine = $null; ParentProcessId = $null; CreationDate = $null },
        [pscustomobject]@{ Pid = 12; Name = 'chrome.exe';   ExecutablePath = 'C:\App\chrome.exe';   CommandLine = $null; ParentProcessId = $null; CreationDate = $null },
        [pscustomobject]@{ Pid = 13; Name = 'node.exe';     ExecutablePath = 'D:\Node\node.exe';    CommandLine = $null; ParentProcessId = $null; CreationDate = $null },
        [pscustomobject]@{ Pid = 14; Name = 'svchost.exe';  ExecutablePath = 'C:\Windows\System32\svchost.exe'; CommandLine = $null; ParentProcessId = $null; CreationDate = $null }
    )
    Assert-Equal 2 @(Get-ProcessMatch -Pattern 'chrome' -ProcessTable $processes).Count 'GetProcessMatch: 子串匹配'
    Assert-Equal 1 @(Get-ProcessMatch -Pattern '*host*' -ProcessTable $processes).Count 'GetProcessMatch: 通配符匹配'
    Assert-Equal 1 @(Get-ProcessMatch -Pattern '/^node\.exe$/' -ProcessTable $processes).Count 'GetProcessMatch: 正则匹配'
    Assert-Equal 0 @(Get-ProcessMatch -Pattern 'firefox' -ProcessTable $processes).Count 'GetProcessMatch: 无匹配'
    Assert-Equal 'c:\app\chrome.exe' (Get-SubjectGroupKey $processes[0]) 'GroupKey: 普通进程按路径合并'
    Assert-Equal 'c:\app\chrome.exe' (Get-SubjectGroupKey $processes[1]) 'GroupKey: 同路径得到同一个键'
    Assert-True ((Get-SubjectGroupKey $processes[3]) -match '^pid:14$') 'GroupKey: svchost 按 PID 拆分'

    # --- 安装归属 -----------------------------------------------------------
    $installed = @(
        [pscustomobject]@{ Name = 'Generic Root App'; Publisher = 'P'; Version = '1.0'; InstallLocation = 'C:\';      DisplayIcon = ''; RegistryPath = 'HKLM:\X'; SystemComponent = 0; IsUpdate = $false },
        [pscustomobject]@{ Name = 'Demo App';         Publisher = 'P'; Version = '2.0'; InstallLocation = 'C:\Foo';   DisplayIcon = ''; RegistryPath = 'HKLM:\Y'; SystemComponent = 0; IsUpdate = $false },
        [pscustomobject]@{ Name = 'Root Disk App';    Publisher = 'P'; Version = '3.0'; InstallLocation = 'D:\';      DisplayIcon = ''; RegistryPath = 'HKLM:\Z'; SystemComponent = 0; IsUpdate = $false }
    )
    $ownership = Get-InstallOwnership -SubjectPath 'C:\Foo\bin\demo.exe' -Installed $installed
    Assert-Equal 'Demo App' $ownership.Name 'InstallOwnership: 最长安装路径优先'
    $rootOwnership = Get-InstallOwnership -SubjectPath 'D:\iTunes\iTunes.exe' -Installed $installed
    Assert-Equal 'Root Disk App' $rootOwnership.Name 'InstallOwnership: 磁盘根目录安装也能归因'
    Assert-True $rootOwnership.IsDriveRoot 'InstallOwnership: 标记磁盘根目录风险'
    Assert-True ($null -eq (Get-InstallOwnership -SubjectPath 'E:\other\x.exe' -Installed $installed)) 'InstallOwnership: 无匹配返回空'

    # --- 展示与安全建议 -----------------------------------------------------
    Assert-Equal '&lt;b&gt;a&amp;b&lt;/b&gt;' (ConvertTo-HtmlSafe '<b>a&b</b>') 'HtmlSafe: 转义 HTML'
    Assert-Equal '127.0.0.1:80' (Format-NetworkEndpoint '127.0.0.1' 80) 'Endpoint: IPv4 格式'
    Assert-Equal '[::]:135' (Format-NetworkEndpoint '::' 135) 'Endpoint: IPv6 格式'

    $runningService = [pscustomobject]@{ Name = 'DemoSvc'; State = 'Running' }
    $stoppedService = [pscustomobject]@{ Name = 'DemoSvc'; State = 'Stopped' }
    Assert-Match 'Stop-Service' (New-ServiceAction -Service $runningService).Command 'ServiceAction: 运行中的服务先停止'
    Assert-Match 'Set-Service'  (New-ServiceAction -Service $runningService).Command 'ServiceAction: 改为手动启动'
    Assert-True ((New-ServiceAction -Service $stoppedService).Command -notmatch 'Stop-Service') 'ServiceAction: 已停止的服务不重复停止'

    # --- 证据链与系统保护 ---------------------------------------------------
    $context = [pscustomobject]@{
        Services = @([pscustomobject]@{
            Name = 'DemoSvc'; DisplayName = 'Demo Service'; State = 'Running'; StartMode = 'Auto'
            PathName = '"C:\Foo\bin\demo.exe"'; Executable = 'C:\Foo\bin\demo.exe'; ProcessId = 100; StartName = 'LocalSystem'; Description = ''
        })
        Autostart = @([pscustomobject]@{
            Kind = 'RegistryRun'; SourceLabel = 'HKCU Run'; Location = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
            Name = 'Demo'; Command = '"C:\Foo\bin\demo.exe" --start'; ResolvedPath = 'C:\Foo\bin\demo.exe'
        })
        Tasks = @([pscustomobject]@{
            TaskName = 'DemoTask'; TaskPath = '\Demo\'; State = 'Ready'; Author = 'Demo'
            Targets = @([pscustomobject]@{ Execute = 'C:\Foo\bin\demo.exe'; Arguments = ''; WorkingDirectory = ''; ResolvedPath = 'C:\Foo\bin\demo.exe'; Command = 'C:\Foo\bin\demo.exe' })
        })
    }
    $evidence = New-EvidenceList -Context $context -Ownership $null -SubjectPath 'C:\Foo\bin\demo.exe' -Pids @(100) -CommandLine '"C:\Foo\bin\demo.exe" --start'
    Assert-Equal 3 $evidence.Count 'Evidence: 服务、启动项、计划任务三条证据'
    Assert-True ($null -ne ($evidence | Where-Object { $_.Type -eq 'Startup' }).Action) 'Evidence: 用户启动项提供可回滚操作'
    Assert-True ($null -ne ($evidence | Where-Object { $_.Type -eq 'ScheduledTask' }).Action) 'Evidence: 计划任务提供禁用操作'

    $systemContext = [pscustomobject]@{
        Services = @([pscustomobject]@{
            Name = 'RpcSs'; DisplayName = 'Remote Procedure Call'; State = 'Running'; StartMode = 'Auto'
            PathName = 'C:\Windows\System32\svchost.exe -k rpcss'; Executable = 'C:\Windows\System32\svchost.exe'; ProcessId = 200; StartName = 'LocalSystem'; Description = ''
        })
        Autostart = @()
        Tasks = @()
    }
    $systemEvidence = New-EvidenceList -Context $systemContext -Ownership $null -SubjectPath 'C:\Windows\System32\svchost.exe' -Pids @(200) -CommandLine $null
    Assert-True ($null -eq ($systemEvidence | Select-Object -First 1).Action) 'Evidence: 系统服务不给停用命令'
    $systemVerdict = Get-SubjectVerdict -Ownership $null -Evidence $systemEvidence -PathValue 'C:\Windows\System32\svchost.exe' -Company 'Microsoft Corporation'
    Assert-Equal 'system' $systemVerdict.Level 'Verdict: 系统目录判定'
    $systemCautions = New-SubjectCautions -SubjectPath 'C:\Windows\System32\svchost.exe' -Facts ([pscustomobject]@{ Exists = $true }) -Ownership $null -Verdict $systemVerdict -HostedServices @() -Signature $null -Evidence $systemEvidence
    Assert-Match '不要' ($systemCautions -join ' ') 'Cautions: 系统服务保护提示'

    # --- HTML 报告生成 ------------------------------------------------------
    $minimalSubject = [pscustomobject]@{
        Scope = 'file'; Pid = $null; Pids = @(); PidDisplay = ''
        Name = '<b>demo</b>'; Path = 'C:\x\demo.exe'; Exists = $true
        Company = 'Demo'; Product = 'Demo'; FileVersion = '1.0'; Description = 'Demo file'
        Signature = $null; CommandLine = $null; Started = $null; LastWriteTime = $null
        ParentChain = @(); HostedServices = @(); Network = @()
        Ownership = $null
        Evidence = @([pscustomobject]@{ Type = 'Startup'; TypeLabel = '启动项'; Confidence = 'High'; SourceLabel = 'HKCU Run'; Detail = 'demo'; Action = $null })
        Verdict = [pscustomobject]@{ Level = 'thirdparty'; Summary = '测试结论'; StartupSourceCount = 1 }
        Cautions = @('测试注意'); Actions = @()
    }
    $minimalReport = [pscustomobject]@{
        Tool = 'HereWhy'; Version = 'test'; GeneratedAt = '2026-01-01 00:00:00'
        Target = [pscustomobject]@{ Kind = '测试'; Value = '<script>alert(1)</script>' }
        Subjects = @($minimalSubject)
        ScanStats = [pscustomobject]@{ Processes = 0; Installed = 0; Autostart = 0; Services = 0; Tasks = 0; Network = 0 }
        Warnings = @()
    }
    $htmlPath = Join-Path $fixtureRoot 'report.html'
    New-HtmlReport -Report $minimalReport -OutPath $htmlPath
    $htmlText = [System.IO.File]::ReadAllText($htmlPath, [System.Text.Encoding]::UTF8)
    Assert-Match '<!DOCTYPE html>' $htmlText 'HtmlReport: 生成完整文档'
    Assert-Match '&lt;b&gt;demo&lt;/b&gt;' $htmlText 'HtmlReport: 转义进程名'
    Assert-True ($htmlText -notmatch '<b>demo</b>') 'HtmlReport: 不输出未转义内容'
    Assert-Match '&lt;script&gt;alert\(1\)&lt;/script&gt;' $htmlText 'HtmlReport: 转义目标参数'

    # --- 进程路径兜底 -------------------------------------------------------
    $fakeSystemProcess = [pscustomobject]@{ Pid = 4; Name = 'svchost.exe'; ExecutablePath = $null; CommandLine = $null; ParentProcessId = $null; CreationDate = $null }
    $fallbackPath = Get-ProcessExecutablePath $fakeSystemProcess
    Assert-Match 'svchost\.exe$' ([string]$fallbackPath) 'ProcessPath: System32 同名文件兜底'
} finally {
    if ($fixtureRoot.StartsWith([System.IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $fixtureRoot)) {
        try { [System.IO.Directory]::Delete($fixtureRoot, $true) } catch { }
    }
}

Write-Host ''
Write-Host ('PowerShell {0}' -f $PSVersionTable.PSVersion.ToString()) -ForegroundColor DarkGray
$total = $script:PassCount + $script:FailCount
if ($script:FailCount -eq 0) {
    Write-Host ('Result: {0} passed, 0 failed ({1} total)' -f $script:PassCount, $total) -ForegroundColor Green
    exit 0
} else {
    Write-Host ('Result: {0} passed, {1} failed ({2} total)' -f $script:PassCount, $script:FailCount, $total) -ForegroundColor Red
    foreach ($failure in $script:FailureLines) { Write-Host ('  failed: ' + $failure) -ForegroundColor Red }
    exit 1
}
