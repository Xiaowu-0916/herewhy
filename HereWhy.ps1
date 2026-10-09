#Requires -Version 5.1
<#
.SYNOPSIS
    HereWhy - Windows 后台项溯源解释器（只读）。

.DESCRIPTION
    输入进程名、PID、端口或 exe 路径，回答四个问题：
      1. 它是什么（产品、公司、版本、签名）？
      2. 它属于哪个已安装软件（安装记录归因）？
      3. 它为什么在这里（服务 / 计划任务 / 注册表启动项 / 启动文件夹 / 父进程链）？
      4. 想关掉时怎么做才安全（可回滚的操作建议，本工具绝不执行）？

    只依赖 Windows PowerShell 5.1 自带组件，只读，不修改系统。
.LINK
    https://github.com/Xiaowu-0916/herewhy
#>
[CmdletBinding(DefaultParameterSetName = 'Help')]
param(
    [Parameter(ParameterSetName = 'Name', Mandatory = $true, Position = 0)]
    [string]$Name,

    [Parameter(ParameterSetName = 'Id', Mandatory = $true)]
    [int[]]$Id,

    [Parameter(ParameterSetName = 'Port', Mandatory = $true)]
    [int[]]$Port,

    [Parameter(ParameterSetName = 'Path', Mandatory = $true)]
    [string]$Path,

    [Parameter(ParameterSetName = 'List', Mandatory = $true)]
    [switch]$List,

    [Parameter(ParameterSetName = 'Help')]
    [switch]$Help,

    [Parameter(ParameterSetName = 'Help')]
    [switch]$Version,

    [switch]$Deep,
    [string]$HtmlReport,
    [string]$Json,
    [ValidateRange(1, 50)]
    [int]$MaxSubjects = 5,
    [switch]$NoColor
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$script:HereWhyVersion = '1.0.0'
$script:UseColor = -not $NoColor
$script:Warnings = New-Object System.Collections.ArrayList
$script:IsListMode = [bool]$List

# ---------------------------------------------------------------------------
# 基础工具
# ---------------------------------------------------------------------------

function Add-Warning {
    param([string]$Message)
    if (-not [string]::IsNullOrWhiteSpace($Message)) {
        [void]$script:Warnings.Add($Message)
    }
}

function ConvertTo-HtmlSafe {
    param([AllowNull()][string]$Text)
    if ($null -eq $Text) { return '' }
    $value = $Text
    $value = $value.Replace('&', '&amp;')
    $value = $value.Replace('<', '&lt;')
    $value = $value.Replace('>', '&gt;')
    $value = $value.Replace('"', '&quot;')
    return $value
}

function Get-PropValue {
    param($Object, [string]$PropertyName)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$PropertyName]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Convert-RegistryPathForDisplay {
    param([string]$ProviderPath)
    if ([string]::IsNullOrWhiteSpace($ProviderPath)) { return $ProviderPath }
    $value = $ProviderPath
    $value = $value -replace '^Microsoft\.PowerShell\.Core\\Registry::HKEY_LOCAL_MACHINE', 'HKLM:'
    $value = $value -replace '^Microsoft\.PowerShell\.Core\\Registry::HKEY_CURRENT_USER', 'HKCU:'
    $value = $value -replace '^HKEY_LOCAL_MACHINE', 'HKLM:'
    $value = $value -replace '^HKEY_CURRENT_USER', 'HKCU:'
    return $value
}

function ConvertTo-NormalizedPath {
    param([AllowNull()][string]$Raw)
    if ([string]::IsNullOrWhiteSpace($Raw)) { return $null }

    $value = $Raw.Trim()
    if ($value.StartsWith('"')) {
        $end = $value.IndexOf('"', 1)
        if ($end -gt 1) { $value = $value.Substring(1, $end - 1) }
        else { $value = $value.Substring(1) }
    }

    $value = [Environment]::ExpandEnvironmentVariables($value)
    if ($value.StartsWith('\??\')) { $value = $value.Substring(4) }
    $value = $value.Trim().Trim('"')
    if ($value -match '^[A-Za-z]:/') { $value = $value.Replace('/', '\') }

    try {
        if ($value -match '^[A-Za-z]:\\') { return [System.IO.Path]::GetFullPath($value) }
    } catch { }
    return $value
}

function Resolve-ExecutablePath {
    param([AllowNull()][string]$CommandLine)
    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return $null }

    $command = $CommandLine.Trim()
    if ($command.StartsWith('"')) {
        $end = $command.IndexOf('"', 1)
        if ($end -gt 1) {
            return (ConvertTo-NormalizedPath $command.Substring(1, $end - 1))
        }
    }

    $expanded = [Environment]::ExpandEnvironmentVariables($command)
    if ($expanded.StartsWith('\??\')) { $expanded = $expanded.Substring(4) }

    $tokens = @($expanded -split '\s+' | Where-Object { $_ -ne '' })
    if ($tokens.Count -eq 0) { return $null }

    # 对未加引号且路径带空格的命令行，从最长前缀开始找真实存在的文件。
    for ($i = $tokens.Count; $i -ge 1; $i--) {
        $candidate = ($tokens[0..($i - 1)] -join ' ').Trim('"')
        if (Test-Path -LiteralPath $candidate -PathType Leaf -ErrorAction SilentlyContinue) {
            return (ConvertTo-NormalizedPath $candidate)
        }
    }

    if ($expanded -match '^(?<p>[A-Za-z]:\\[^"]*?\.(?:exe|com|bat|cmd))(?=\s|$)') {
        return (ConvertTo-NormalizedPath $Matches['p'])
    }

    return (ConvertTo-NormalizedPath $tokens[0])
}

function Get-PathKey {
    param([AllowNull()][string]$PathValue)
    if ([string]::IsNullOrWhiteSpace($PathValue)) { return $null }
    $normalized = ConvertTo-NormalizedPath $PathValue
    if ([string]::IsNullOrWhiteSpace($normalized)) { return $null }
    $normalized = $normalized.TrimEnd('\', '/')
    if ($normalized -match '^[A-Za-z]:$') { return $normalized.ToLowerInvariant() }
    return $normalized.ToLowerInvariant()
}

function Test-PathWithin {
    param([AllowNull()][string]$Child, [AllowNull()][string]$Parent)
    $childKey = Get-PathKey $Child
    $parentKey = Get-PathKey $Parent
    if (-not $childKey -or -not $parentKey) { return $false }
    if ($childKey -eq $parentKey) { return $true }
    return $childKey.StartsWith($parentKey + '\')
}

function Get-ProcessExecutablePath {
    param($Process)
    if ($null -eq $Process) { return $null }

    $pathValue = ConvertTo-NormalizedPath $Process.ExecutablePath
    if ([string]::IsNullOrWhiteSpace($pathValue) -and -not [string]::IsNullOrWhiteSpace([string]$Process.CommandLine)) {
        $pathValue = Resolve-ExecutablePath $Process.CommandLine
    }
    # 受保护的系统进程经常读不到 ExecutablePath，用 System32 下的同名文件兜底。
    if ([string]::IsNullOrWhiteSpace($pathValue) -and -not [string]::IsNullOrWhiteSpace([string]$Process.Name) -and $env:SystemRoot) {
        $candidates = @(
            (Join-Path (Join-Path $env:SystemRoot 'System32') $Process.Name),
            (Join-Path $env:SystemRoot $Process.Name)
        )
        foreach ($candidate in $candidates) {
            if (Test-Path -LiteralPath $candidate -PathType Leaf -ErrorAction SilentlyContinue) {
                return (ConvertTo-NormalizedPath $candidate)
            }
        }
    }
    return $pathValue
}

function Get-SubjectGroupKey {
    param($Process)
    $pathValue = Get-ProcessExecutablePath $Process
    $key = Get-PathKey $pathValue
    if ([string]::IsNullOrWhiteSpace($key)) { return ('pid:' + $Process.Pid) }
    # svchost/dllhost 每个实例承载的服务不同，必须按 PID 分开分析。
    $fileName = [System.IO.Path]::GetFileName($pathValue).ToLowerInvariant()
    if ($fileName -eq 'svchost.exe' -or $fileName -eq 'dllhost.exe') { return ('pid:' + $Process.Pid) }
    return $key
}

function Format-NetworkEndpoint {
    param([AllowNull()][string]$Address, [int]$PortValue)
    if ([string]::IsNullOrWhiteSpace($Address)) { return [string]$PortValue }
    if ($Address.Contains(':')) { return ('[' + $Address + ']:' + $PortValue) }
    return ($Address + ':' + $PortValue)
}

function Format-ShortText {
    param([AllowNull()][string]$Text, [int]$MaxLength = 90)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    if ($Text.Length -le $MaxLength) { return $Text }
    $head = [int][Math]::Floor($MaxLength / 2) - 2
    $tail = $MaxLength - $head - 3
    return ($Text.Substring(0, $head) + '...' + $Text.Substring($Text.Length - $tail))
}

function Write-ColorLine {
    param([AllowNull()][string]$Text, [string]$Color = 'Gray')
    if ($script:UseColor) { Write-Host $Text -ForegroundColor $Color }
    else { Write-Host $Text }
}

function Write-KeyValue {
    param([string]$Label, [AllowNull()][string]$Value, [string]$ValueColor = 'Gray')
    if ([string]::IsNullOrWhiteSpace($Value)) { $Value = '(未知)' }
    if ($script:UseColor) {
        Write-Host ('  {0,-6}: ' -f $Label) -NoNewline -ForegroundColor DarkGray
        Write-Host $Value -ForegroundColor $ValueColor
    } else {
        Write-Host ('  {0,-6}: {1}' -f $Label, $Value)
    }
}

function Resolve-OutputPath {
    param([string]$PathValue)
    if ([string]::IsNullOrWhiteSpace($PathValue)) { return $null }
    if ([System.IO.Path]::IsPathRooted($PathValue)) {
        $full = [System.IO.Path]::GetFullPath($PathValue)
    } else {
        $full = [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $PathValue))
    }
    $dir = Split-Path -Parent $full
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        [void](New-Item -ItemType Directory -Path $dir -Force)
    }
    return $full
}

# ---------------------------------------------------------------------------
# 数据采集（全部只读）
# ---------------------------------------------------------------------------

function Get-ProcessTable {
    $result = New-Object System.Collections.ArrayList
    try {
        $processes = Get-CimInstance -ClassName Win32_Process -ErrorAction Stop
    } catch {
        Add-Warning ('Win32_Process 查询失败，改用 Get-Process 降级模式：' + $_.Exception.Message)
        Get-Process -ErrorAction SilentlyContinue | ForEach-Object {
            [void]$result.Add([pscustomobject]@{
                Pid             = [int]$_.Id
                Name            = [string]$_.ProcessName
                ExecutablePath  = [string]$_.Path
                CommandLine     = $null
                ParentProcessId = $null
                CreationDate    = $null
            })
        }
        return @($result)
    }

    foreach ($process in $processes) {
        $parentId = $null
        if ($null -ne $process.ParentProcessId) { $parentId = [int]$process.ParentProcessId }
        [void]$result.Add([pscustomobject]@{
            Pid             = [int]$process.ProcessId
            Name            = [string]$process.Name
            ExecutablePath  = [string]$process.ExecutablePath
            CommandLine     = [string]$process.CommandLine
            ParentProcessId = $parentId
            CreationDate    = $process.CreationDate
        })
    }
    return @($result)
}

function Get-InstalledPrograms {
    $result = New-Object System.Collections.ArrayList
    $bases = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    $options = [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames

    foreach ($base in $bases) {
        if (-not (Test-Path -LiteralPath $base)) { continue }
        $keys = Get-ChildItem -LiteralPath $base -ErrorAction SilentlyContinue
        foreach ($key in $keys) {
            $displayName = $null
            try { $displayName = [string]$key.GetValue('DisplayName', $null, $options) } catch { }
            if ([string]::IsNullOrWhiteSpace($displayName)) { continue }

            $installLocation = $null
            $displayIcon = $null
            $uninstallString = $null
            $publisher = $null
            $version = $null
            $systemComponent = 0
            $parentKeyName = $null
            try { $installLocation = [string]$key.GetValue('InstallLocation', $null, $options) } catch { }
            try { $displayIcon = [string]$key.GetValue('DisplayIcon', $null, $options) } catch { }
            try { $uninstallString = [string]$key.GetValue('UninstallString', $null, $options) } catch { }
            try { $publisher = [string]$key.GetValue('Publisher', $null, $options) } catch { }
            try { $version = [string]$key.GetValue('DisplayVersion', $null, $options) } catch { }
            try { $systemComponent = [int]$key.GetValue('SystemComponent', 0, $options) } catch { }
            try { $parentKeyName = [string]$key.GetValue('ParentKeyName', $null, $options) } catch { }

            $iconPath = $null
            if (-not [string]::IsNullOrWhiteSpace($displayIcon)) {
                $iconPath = ($displayIcon -split ',')[0].Trim()
            }

            [void]$result.Add([pscustomobject]@{
                Name             = $displayName
                Publisher        = $publisher
                Version          = $version
                InstallLocation  = (ConvertTo-NormalizedPath $installLocation)
                DisplayIcon      = (ConvertTo-NormalizedPath $iconPath)
                UninstallString  = $uninstallString
                RegistryPath     = (Convert-RegistryPathForDisplay $key.PSPath)
                SystemComponent  = $systemComponent
                IsUpdate         = [bool]$parentKeyName
            })
        }
    }
    return @($result)
}

function Resolve-ShortcutTarget {
    param([string]$LinkPath)
    $shell = $null
    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($LinkPath)
        return $shortcut.TargetPath
    } catch {
        return $null
    } finally {
        if ($shell) {
            try { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) } catch { }
        }
    }
}

function Get-AutostartEntries {
    $result = New-Object System.Collections.ArrayList
    $runBases = @(
        [pscustomobject]@{ Label = 'HKLM Run';      Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' },
        [pscustomobject]@{ Label = 'HKLM RunOnce';  Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' },
        [pscustomobject]@{ Label = 'HKLM Run (32)'; Path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run' },
        [pscustomobject]@{ Label = 'HKCU Run';      Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' },
        [pscustomobject]@{ Label = 'HKCU RunOnce';  Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' },
        [pscustomobject]@{ Label = 'HKCU Run (32)'; Path = 'HKCU:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run' }
    )
    $options = [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames

    foreach ($base in $runBases) {
        if (-not (Test-Path -LiteralPath $base.Path)) { continue }
        $key = Get-Item -LiteralPath $base.Path -ErrorAction SilentlyContinue
        if ($null -eq $key) { continue }
        foreach ($valueName in $key.GetValueNames()) {
            $command = $null
            try { $command = [string]$key.GetValue($valueName, $null, $options) } catch { }
            if ([string]::IsNullOrWhiteSpace($command)) { continue }
            [void]$result.Add([pscustomobject]@{
                Kind         = 'RegistryRun'
                SourceLabel  = $base.Label
                Location     = $base.Path
                Name         = $valueName
                Command      = $command
                ResolvedPath = (Resolve-ExecutablePath $command)
            })
        }
    }

    $folders = New-Object System.Collections.ArrayList
    try { [void]$folders.Add([Environment]::GetFolderPath([Environment+SpecialFolder]::Startup)) } catch { }
    try { [void]$folders.Add([Environment]::GetFolderPath([Environment+SpecialFolder]::CommonStartup)) } catch { }

    foreach ($folder in @($folders | Where-Object { $_ } | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $folder)) { continue }
        $files = Get-ChildItem -LiteralPath $folder -File -ErrorAction SilentlyContinue
        foreach ($file in $files) {
            $target = $file.FullName
            if ($file.Extension -ieq '.lnk') {
                $resolved = Resolve-ShortcutTarget $file.FullName
                if (-not [string]::IsNullOrWhiteSpace($resolved)) { $target = $resolved }
            }
            [void]$result.Add([pscustomobject]@{
                Kind         = 'StartupFolder'
                SourceLabel  = '启动文件夹'
                Location     = $file.FullName
                Name         = $file.Name
                Command      = $target
                ResolvedPath = (ConvertTo-NormalizedPath $target)
            })
        }
    }
    return @($result)
}

function Get-ServiceTable {
    $result = New-Object System.Collections.ArrayList
    $services = Get-CimInstance -ClassName Win32_Service -ErrorAction SilentlyContinue
    if ($null -eq $services) {
        Add-Warning '服务列表读取失败（Win32_Service 不可用）。'
        return @()
    }
    foreach ($service in $services) {
        $processId = 0
        if ($null -ne $service.ProcessId) { $processId = [int]$service.ProcessId }
        [void]$result.Add([pscustomobject]@{
            Name        = [string]$service.Name
            DisplayName = [string]$service.DisplayName
            State       = [string]$service.State
            StartMode   = [string]$service.StartMode
            PathName    = [string]$service.PathName
            Executable  = (Resolve-ExecutablePath ([string]$service.PathName))
            ProcessId   = $processId
            StartName   = [string]$service.StartName
            Description = [string]$service.Description
        })
    }
    return @($result)
}

function Get-ScheduledTaskTable {
    $result = New-Object System.Collections.ArrayList
    try {
        $tasks = Get-ScheduledTask -ErrorAction Stop
    } catch {
        Add-Warning ('计划任务读取失败：' + $_.Exception.Message)
        return @()
    }
    foreach ($task in $tasks) {
        $targets = New-Object System.Collections.ArrayList
        foreach ($action in @($task.Actions)) {
            $execute = [string](Get-PropValue $action 'Execute')
            if ([string]::IsNullOrWhiteSpace($execute)) { continue }
            $arguments = [string](Get-PropValue $action 'Arguments')
            $workingDirectory = [string](Get-PropValue $action 'WorkingDirectory')
            $command = (@($execute, $arguments) | Where-Object { $_ }) -join ' '
            [void]$targets.Add([pscustomobject]@{
                Execute          = $execute
                Arguments        = $arguments
                WorkingDirectory = $workingDirectory
                ResolvedPath     = (Resolve-ExecutablePath $execute)
                Command          = $command
            })
        }
        if ($targets.Count -eq 0) { continue }
        [void]$result.Add([pscustomobject]@{
            TaskName = [string]$task.TaskName
            TaskPath = [string]$task.TaskPath
            State    = [string]$task.State
            Author   = [string]$task.Author
            Targets  = @($targets)
        })
    }
    return @($result)
}

function Get-NetworkFromNetstat {
    $result = New-Object System.Collections.ArrayList
    $lines = & netstat -ano 2>$null
    foreach ($line in $lines) {
        $parts = @(($line.Trim() -split '\s+') | Where-Object { $_ -ne '' })
        if ($parts.Count -lt 4) { continue }
        $protocol = $parts[0]
        if ($protocol -ne 'TCP' -and $protocol -ne 'UDP') { continue }
        $local = $parts[1]
        $remote = $parts[2]
        $state = ''
        $pidText = $parts[3]
        if ($protocol -eq 'TCP' -and $parts.Count -ge 5) {
            $state = $parts[3]
            $pidText = $parts[4]
        }
        $localPort = 0
        if ($local -match ':(\d+)$') { $localPort = [int]$Matches[1] }
        $remotePort = 0
        if ($remote -match ':(\d+)$') { $remotePort = [int]$Matches[1] }
        $processId = 0
        [void][int]::TryParse($pidText, [ref]$processId)
        [void]$result.Add([pscustomobject]@{
            Protocol      = $protocol
            State         = $state
            LocalAddress  = ($local -replace ':\d+$', '')
            LocalPort     = $localPort
            RemoteAddress = ($remote -replace ':\d+$', '')
            RemotePort    = $remotePort
            Pid           = $processId
        })
    }
    return @($result)
}

function Get-NetworkTable {
    $result = New-Object System.Collections.ArrayList
    $usedFallback = $false
    try {
        $tcp = Get-NetTCPConnection -ErrorAction Stop
        foreach ($connection in $tcp) {
            if ($null -eq $connection.OwningProcess) { continue }
            [void]$result.Add([pscustomobject]@{
                Protocol      = 'TCP'
                State         = [string]$connection.State
                LocalAddress  = [string]$connection.LocalAddress
                LocalPort     = [int]$connection.LocalPort
                RemoteAddress = [string]$connection.RemoteAddress
                RemotePort    = [int]$connection.RemotePort
                Pid           = [int]$connection.OwningProcess
            })
        }
    } catch {
        $usedFallback = $true
        foreach ($endpoint in (Get-NetworkFromNetstat)) {
            if ($endpoint.Protocol -eq 'TCP') { [void]$result.Add($endpoint) }
        }
        Add-Warning 'Get-NetTCPConnection 不可用，TCP 结果由 netstat 降级提供。'
    }

    try {
        $udp = Get-NetUDPEndpoint -ErrorAction Stop
        foreach ($endpoint in $udp) {
            if ($null -eq $endpoint.OwningProcess) { continue }
            [void]$result.Add([pscustomobject]@{
                Protocol      = 'UDP'
                State         = ''
                LocalAddress  = [string]$endpoint.LocalAddress
                LocalPort     = [int]$endpoint.LocalPort
                RemoteAddress = ''
                RemotePort    = 0
                Pid           = [int]$endpoint.OwningProcess
            })
        }
    } catch {
        if (-not $usedFallback) { Add-Warning 'Get-NetUDPEndpoint 不可用，UDP 结果可能不完整。' }
    }
    return @($result)
}

function Get-HereWhyContext {
    param([switch]$SkipTasks)

    $context = [pscustomobject]@{
        Processes = @(Get-ProcessTable)
        Installed = @(Get-InstalledPrograms)
        Autostart = @(Get-AutostartEntries)
        Services  = @(Get-ServiceTable)
        Tasks     = @()
        Network   = @(Get-NetworkTable)
    }
    if (-not $SkipTasks) {
        $context.Tasks = @(Get-ScheduledTaskTable)
    }
    return $context
}

# ---------------------------------------------------------------------------
# 归因逻辑
# ---------------------------------------------------------------------------

function Get-FileFacts {
    param([AllowNull()][string]$PathValue)
    $facts = [pscustomobject]@{
        Exists      = $false
        Company     = $null
        Product     = $null
        FileVersion = $null
        Description = $null
    }
    if ([string]::IsNullOrWhiteSpace($PathValue)) { return $facts }
    if (-not (Test-Path -LiteralPath $PathValue -PathType Leaf -ErrorAction SilentlyContinue)) { return $facts }
    try {
        $info = (Get-Item -LiteralPath $PathValue -ErrorAction Stop).VersionInfo
        $facts.Exists = $true
        $facts.Company = [string]$info.CompanyName
        $facts.Product = [string]$info.ProductName
        $facts.FileVersion = [string]$info.FileVersion
        $facts.Description = [string]$info.FileDescription
    } catch { }
    return $facts
}

function Get-SignatureFacts {
    param([AllowNull()][string]$PathValue)
    if ([string]::IsNullOrWhiteSpace($PathValue)) { return $null }
    if (-not (Test-Path -LiteralPath $PathValue -PathType Leaf -ErrorAction SilentlyContinue)) { return $null }
    try {
        $signature = Get-AuthenticodeSignature -LiteralPath $PathValue -ErrorAction Stop
        $signer = $null
        if ($signature.SignerCertificate) {
            $signer = ($signature.SignerCertificate.Subject -split ',')[0] -replace '^CN=', ''
        }
        return [pscustomobject]@{
            Status = [string]$signature.Status
            Signer = $signer
        }
    } catch {
        return $null
    }
}

function Get-InstallOwnership {
    param(
        [AllowNull()][string]$SubjectPath,
        [AllowNull()][object[]]$Installed
    )
    if ([string]::IsNullOrWhiteSpace($SubjectPath) -or $null -eq $Installed) { return $null }

    $best = $null
    $bestLength = -1
    $bestBase = $null
    foreach ($app in $Installed) {
        $candidates = @($app.InstallLocation, $app.DisplayIcon)
        foreach ($candidate in $candidates) {
            if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
            if (-not (Test-PathWithin $SubjectPath $candidate)) { continue }
            $key = Get-PathKey $candidate
            if ($null -eq $key) { continue }
            if ($key.Length -gt $bestLength) {
                $best = $app
                $bestLength = $key.Length
                $bestBase = $candidate
            }
        }
    }
    if ($null -eq $best) { return $null }

    $baseKey = Get-PathKey $bestBase
    return [pscustomobject]@{
        Name         = $best.Name
        Publisher    = $best.Publisher
        Version      = $best.Version
        MatchBase    = $bestBase
        RegistryPath = $best.RegistryPath
        IsDriveRoot  = ($baseKey -match '^[a-z]:$')
        Confidence   = 'High'
    }
}

function New-Action {
    param([string]$Title, [string]$Command, [string]$Note)
    return [pscustomobject]@{
        Title   = $Title
        Command = $Command
        Note    = $Note
    }
}

function New-RegistryAction {
    param($Entry)
    $hivePath = $Entry.Location -replace '^HKLM:\\', 'HKLM\' -replace '^HKCU:\\', 'HKCU\'
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backup = Join-Path $env:USERPROFILE ('Desktop\HereWhy-backup-' + $stamp + '.reg')
    $command = ('reg export "{0}" "{1}" /y; Remove-ItemProperty -Path ''{2}'' -Name ''{3}''' -f $hivePath, $backup, $Entry.Location, $Entry.Name)
    $note = '先备份再移除；也可在「任务管理器 -> 启动应用」里直接禁用。'
    if ($Entry.Location -like 'HKLM*') { $note += ' HKLM 启动项需要管理员权限。' }
    return New-Action -Title ('移除启动项 ' + $Entry.Name) -Command $command -Note $note
}

function New-StartupFolderAction {
    param($Entry)
    $backupDir = Join-Path $env:USERPROFILE 'Desktop\HereWhy-backup'
    $command = ('New-Item -ItemType Directory -Force -Path ''{0}'' | Out-Null; Move-Item -LiteralPath ''{1}'' -Destination ''{0}'' -Force' -f $backupDir, $Entry.Location)
    return New-Action -Title ('移出启动文件夹：' + $Entry.Name) -Command $command -Note '文件只是移到桌面备份目录，随时可以放回。'
}

function New-ServiceAction {
    param($Service, [int]$SharedCount = 0)
    $note = '保留服务本体，只停止并改成手动启动，便于随时回滚。'
    if ($SharedCount -gt 1) {
        $note = ('同一进程还承载 {0} 个服务，整个进程不能随便停；优先单独停用本服务。' -f $SharedCount)
    }
    $command = ('Set-Service -Name ''{0}'' -StartupType Manual' -f $Service.Name)
    if ($Service.State -eq 'Running') {
        $command = ('Stop-Service -Name ''{0}'' -ErrorAction SilentlyContinue; ' -f $Service.Name) + $command
    }
    return New-Action -Title ('停用服务 ' + $Service.Name) -Command $command -Note $note
}

function New-TaskAction {
    param($Task)
    $command = ('Disable-ScheduledTask -TaskPath ''{0}'' -TaskName ''{1}''' -f $Task.TaskPath, $Task.TaskName)
    return New-Action -Title ('禁用计划任务 ' + $Task.TaskPath + $Task.TaskName) -Command $command -Note '禁用可随时用 Enable-ScheduledTask 恢复，不删除任务。'
}

function Get-ParentChain {
    param($Process, [object[]]$ProcessTable)
    $chain = New-Object System.Collections.ArrayList
    if ($null -eq $Process -or $null -eq $ProcessTable) { return @() }

    $byId = @{}
    foreach ($item in $ProcessTable) { $byId[[int]$item.Pid] = $item }

    $seen = @{}
    $current = $Process
    $depth = 0
    while ($null -ne $current -and $depth -lt 6) {
        $parentId = $current.ParentProcessId
        if ($null -eq $parentId) { break }
        $parentId = [int]$parentId
        if ($seen.ContainsKey($parentId)) { break }
        $seen[$parentId] = $true

        if (-not $byId.ContainsKey($parentId)) {
            [void]$chain.Add([pscustomobject]@{ Pid = $parentId; Name = '(已退出)'; Path = $null })
            break
        }
        $parent = $byId[$parentId]
        [void]$chain.Add([pscustomobject]@{
            Pid  = [int]$parent.Pid
            Name = [string]$parent.Name
            Path = (Get-ProcessExecutablePath $parent)
        })
        $current = $parent
        $depth++
    }
    return @($chain)
}

function New-EvidenceList {
    param(
        $Context,
        $Ownership,
        [AllowNull()][string]$SubjectPath,
        [int[]]$Pids,
        [AllowNull()][string]$CommandLine
    )
    $evidence = New-Object System.Collections.ArrayList
    $subjectKey = Get-PathKey $SubjectPath
    $systemSubject = $false
    if ($SubjectPath -and $env:SystemRoot -and (Test-PathWithin $SubjectPath (Join-Path $env:SystemRoot 'System32'))) {
        $systemSubject = $true
    }
    $subjectFileName = $null
    if (-not [string]::IsNullOrWhiteSpace($SubjectPath)) {
        $subjectFileName = [System.IO.Path]::GetFileName($SubjectPath)
    }

    if ($null -ne $Ownership) {
        $detail = ('安装记录「{0}」的安装位置/图标路径匹配 {1}' -f $Ownership.Name, $Ownership.MatchBase)
        if ($Ownership.Version) { $detail += ('（版本 {0}）' -f $Ownership.Version) }
        [void]$evidence.Add([pscustomobject]@{
            Type        = 'Ownership'
            TypeLabel   = '安装归属'
            Confidence  = 'High'
            SourceLabel = ('安装记录：' + $Ownership.Name)
            Detail      = $detail
            Action      = $null
        })
    }

    $sharedHostNames = @('svchost.exe', 'services.exe', 'lsass.exe', 'dllhost.exe')
    $services = @($Context.Services)
    $matchingServices = @($services | Where-Object {
        ($_.ProcessId -gt 0 -and ($Pids -contains [int]$_.ProcessId)) -or
        ($subjectKey -and $_.Executable -and -not ($sharedHostNames -contains ([System.IO.Path]::GetFileName($_.Executable).ToLowerInvariant())) -and ((Get-PathKey $_.Executable) -eq $subjectKey))
    })
    $hostSharedCount = @($matchingServices).Count

    foreach ($service in $matchingServices) {
        $isHosted = ($service.ProcessId -gt 0 -and ($Pids -contains [int]$service.ProcessId))
        $type = 'Service'
        $typeLabel = '服务'
        $serviceFileName = $null
        if ($service.Executable) { $serviceFileName = [System.IO.Path]::GetFileName($service.Executable).ToLowerInvariant() }
        if ($isHosted -and $serviceFileName -and -not ($sharedHostNames -contains $serviceFileName) -and $subjectKey -and ((Get-PathKey $service.Executable) -eq $subjectKey)) {
            $typeLabel = '服务本体'
        } elseif ($isHosted) {
            $typeLabel = '宿主服务'
        }
        $detail = ('服务 {0}（{1}，{2}，启动方式 {3}）' -f $service.Name, $service.DisplayName, $service.State, $service.StartMode)
        $action = $null
        if ($systemSubject) {
            $detail += '；属于 Windows 系统组件，这里只解释，不建议停用'
        } else {
            $action = New-ServiceAction -Service $service -SharedCount $hostSharedCount
        }
        [void]$evidence.Add([pscustomobject]@{
            Type        = $type
            TypeLabel   = $typeLabel
            Confidence  = 'High'
            SourceLabel = ('服务：' + $service.Name)
            Detail      = $detail
            Action      = $action
        })
    }

    foreach ($entry in @($Context.Autostart)) {
        if (-not $subjectKey) { continue }
        $entryKey = Get-PathKey $entry.ResolvedPath
        $matched = $false
        $confidence = 'High'
        $detail = $null
        if ($entryKey -and $entryKey -eq $subjectKey) {
            $matched = $true
            $detail = ('{0}「{1}」指向 {2}' -f $entry.SourceLabel, $entry.Name, $entry.ResolvedPath)
        } elseif (-not [string]::IsNullOrWhiteSpace($CommandLine) -and -not [string]::IsNullOrWhiteSpace($entry.Command) -and $entry.Command.IndexOf($SubjectPath, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $matched = $true
            $detail = ('{0}「{1}」的命令行包含该路径：{2}' -f $entry.SourceLabel, $entry.Name, (Format-ShortText $entry.Command 120))
        } elseif ($subjectFileName -and -not [string]::IsNullOrWhiteSpace($entry.Command) -and $entry.Command.IndexOf($subjectFileName, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $matched = $true
            $confidence = 'Medium'
            $detail = ('{0}「{1}」的命令行中出现同名程序 {2}，但完整路径不一致。' -f $entry.SourceLabel, $entry.Name, $subjectFileName)
        }
        if (-not $matched) { continue }

        $action = $null
        if ($entry.Kind -eq 'RegistryRun') { $action = New-RegistryAction -Entry $entry }
        if ($entry.Kind -eq 'StartupFolder') { $action = New-StartupFolderAction -Entry $entry }
        [void]$evidence.Add([pscustomobject]@{
            Type        = 'Startup'
            TypeLabel   = '启动项'
            Confidence  = $confidence
            SourceLabel = ($entry.SourceLabel + '：' + $entry.Name)
            Detail      = $detail
            Action      = $action
        })
    }

    foreach ($task in @($Context.Tasks)) {
        if (-not $subjectKey) { continue }
        foreach ($target in @($task.Targets)) {
            $targetKey = Get-PathKey $target.ResolvedPath
            $matched = $false
            $confidence = 'High'
            $detail = $null
            if ($targetKey -and $targetKey -eq $subjectKey) {
                $matched = $true
                $detail = ('计划任务 {0}{1} 直接执行该程序（状态 {2}）' -f $task.TaskPath, $task.TaskName, $task.State)
            } elseif ($subjectFileName -and $target.Command -and $target.Command.IndexOf($subjectFileName, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                $matched = $true
                $confidence = 'Medium'
                $detail = ('计划任务 {0}{1} 的命令行中出现 {2}：{3}' -f $task.TaskPath, $task.TaskName, $subjectFileName, (Format-ShortText $target.Command 120))
            }
            if (-not $matched) { continue }
            [void]$evidence.Add([pscustomobject]@{
                Type        = 'ScheduledTask'
                TypeLabel   = '计划任务'
                Confidence  = $confidence
                SourceLabel = ('计划任务：' + $task.TaskPath + $task.TaskName)
                Detail      = $detail
                Action      = (New-TaskAction -Task $task)
            })
        }
    }
    return @($evidence)
}

function Get-SubjectVerdict {
    param(
        $Ownership,
        [AllowNull()][object[]]$Evidence,
        [AllowNull()][string]$PathValue,
        [AllowNull()][string]$Company
    )
    $parts = @()
    $level = 'unknown'
    if ($null -ne $Ownership) {
        $level = 'installed'
        $parts += ('属于已安装软件「{0}」' -f $Ownership.Name)
    } elseif ($PathValue -and $env:SystemRoot -and (Test-PathWithin $PathValue (Join-Path $env:SystemRoot 'System32'))) {
        $level = 'system'
        $parts += '位于 Windows 系统目录'
    } elseif ($Company -and $Company -match 'Microsoft') {
        $level = 'system'
        $parts += 'Microsoft 系统组件'
    } elseif ($PathValue) {
        $level = 'thirdparty'
        $parts += '未匹配到安装记录，属于独立可执行文件'
    } else {
        $parts += '信息不足，无法确认归属'
    }

    $startupEvidence = @($Evidence | Where-Object { $_.Type -in @('Service', 'HostedService', 'Startup', 'ScheduledTask') })
    if ($startupEvidence.Count -gt 0) {
        $labels = @($startupEvidence | ForEach-Object { $_.SourceLabel } | Select-Object -Unique)
        $parts += ('启动来源：' + ($labels -join '、'))
    } else {
        $parts += '未发现持久化自启项（可能是按需启动）'
    }

    return [pscustomobject]@{
        Level             = $level
        Summary           = ($parts -join '；')
        StartupSourceCount = $startupEvidence.Count
    }
}

function New-SubjectCautions {
    param($SubjectPath, $Facts, $Ownership, $Verdict, [object[]]$HostedServices, $Signature, [object[]]$Evidence)
    $cautions = New-Object System.Collections.ArrayList
    $serviceEvidence = @($Evidence | Where-Object { $_.Type -eq 'Service' -or $_.Type -eq 'HostedService' })
    if ($Verdict.Level -eq 'system' -and $serviceEvidence.Count -gt 0) {
        [void]$cautions.Add('这些系统服务是 Windows 正常运作的一部分（例如 RPC、DCOM、安全中心）。不要按通用教程随意停用；只有确认存在具体故障时才单独处理。')
    }

    if ($Verdict.Level -eq 'system') {
        [void]$cautions.Add('这是 Windows 系统组件。不要直接删除文件；如果没有明确问题，建议保持启用。')
    }
    if ($null -ne $Ownership -and $Ownership.IsDriveRoot) {
        [void]$cautions.Add(('安装记录把整个 {0} 标成安装目录（例如把软件装在磁盘根目录）。因此「它属于哪个软件」可信，但不能据此删除该目录。' -f (Get-PathKey $Ownership.MatchBase).ToUpperInvariant()))
    }
    if ($HostedServices.Count -gt 1 -and $SubjectPath -and ([System.IO.Path]::GetFileName($SubjectPath).ToLowerInvariant() -eq 'svchost.exe')) {
        [void]$cautions.Add(('当前 svchost 实例承载 {0} 个服务，停止整个进程会一起影响它们；只应针对具体服务处理。' -f $HostedServices.Count))
    }
    if ($null -ne $Signature -and $Signature.Status -ne 'Valid') {
        [void]$cautions.Add(('数字签名状态：{0}。签名异常可能只是自编译/开源软件，也可能是风险线索，应结合来源判断。' -f (Get-SignatureStatusLabel $Signature.Status)))
    }
    return @($cautions)
}

function New-SubjectFromPath {
    param([string]$PathValue, $Context, [switch]$Deep)

    $normalized = ConvertTo-NormalizedPath $PathValue
    $facts = Get-FileFacts $normalized
    $signature = $null
    if ($Deep) { $signature = Get-SignatureFacts $normalized }
    $ownership = Get-InstallOwnership -SubjectPath $normalized -Installed $Context.Installed
    $evidence = New-EvidenceList -Context $Context -Ownership $ownership -SubjectPath $normalized -Pids @() -CommandLine $null
    $verdict = Get-SubjectVerdict -Ownership $ownership -Evidence $evidence -PathValue $normalized -Company $facts.Company

    $started = $null
    if ($facts.Exists) {
        try { $started = (Get-Item -LiteralPath $normalized).LastWriteTime } catch { }
    }
    $cautions = New-SubjectCautions -SubjectPath $normalized -Facts $facts -Ownership $ownership -Verdict $verdict -HostedServices @() -Signature $signature -Evidence @($evidence)
    $actions = @($evidence | Where-Object { $null -ne $_.Action } | ForEach-Object { $_.Action })

    return [pscustomobject]@{
        Scope          = 'file'
        Pid            = $null
        Pids           = @()
        Name           = [System.IO.Path]::GetFileName($normalized)
        Path           = $normalized
        Exists         = $facts.Exists
        Company        = $facts.Company
        Product        = $facts.Product
        FileVersion    = $facts.FileVersion
        Description    = $facts.Description
        Signature      = $signature
        CommandLine    = $null
        Started        = $started
        LastWriteTime  = $started
        ParentChain    = @()
        HostedServices = @()
        Network        = @()
        Ownership      = $ownership
        Evidence       = @($evidence)
        Verdict        = $verdict
        Cautions       = @($cautions)
        Actions        = @($actions)
    }
}

function New-SubjectFromProcesses {
    param([object[]]$Processes, $Context, [switch]$Deep)
    if ($null -eq $Processes -or $Processes.Count -eq 0) { return $null }

    $first = $Processes[0]
    $pids = @($Processes | ForEach-Object { [int]$_.Pid })
    $path = Get-ProcessExecutablePath $first
    if ([string]::IsNullOrWhiteSpace($path)) {
        $servicePath = @($Context.Services | Where-Object { $_.ProcessId -gt 0 -and ($pids -contains [int]$_.ProcessId) -and $_.Executable } | Select-Object -First 1)
        if ($servicePath.Count -gt 0) { $path = $servicePath[0].Executable }
    }
    $facts = Get-FileFacts $path
    $signature = $null
    if ($Deep) { $signature = Get-SignatureFacts $path }
    $ownership = Get-InstallOwnership -SubjectPath $path -Installed $Context.Installed
    $evidence = New-EvidenceList -Context $Context -Ownership $ownership -SubjectPath $path -Pids $pids -CommandLine $first.CommandLine
    $verdict = Get-SubjectVerdict -Ownership $ownership -Evidence $evidence -PathValue $path -Company $facts.Company
    $parentChain = Get-ParentChain -Process $first -ProcessTable $Context.Processes
    $hostedServices = @($Context.Services | Where-Object { $_.ProcessId -gt 0 -and ($pids -contains [int]$_.ProcessId) })
    $network = @($Context.Network | Where-Object { $pids -contains [int]$_.Pid })
    $cautions = New-SubjectCautions -SubjectPath $path -Facts $facts -Ownership $ownership -Verdict $verdict -HostedServices $hostedServices -Signature $signature -Evidence @($evidence)

    $actions = New-Object System.Collections.ArrayList
    $seenCommands = @{}
    foreach ($item in @($evidence)) {
        if ($null -eq $item.Action) { continue }
        if ($seenCommands.ContainsKey($item.Action.Command)) { continue }
        $seenCommands[$item.Action.Command] = $true
        [void]$actions.Add($item.Action)
    }

    $pidDisplay = [string]$first.Pid
    if ($pids.Count -gt 1) { $pidDisplay = ('{0} 等 {1} 个进程' -f $first.Pid, $pids.Count) }

    return [pscustomobject]@{
        Scope          = 'process'
        Pid            = [int]$first.Pid
        Pids           = $pids
        PidDisplay     = $pidDisplay
        Name           = [string]$first.Name
        Path           = $path
        Exists         = $facts.Exists
        Company        = $facts.Company
        Product        = $facts.Product
        FileVersion    = $facts.FileVersion
        Description    = $facts.Description
        Signature      = $signature
        CommandLine    = [string]$first.CommandLine
        Started        = $first.CreationDate
        LastWriteTime  = $null
        ParentChain    = @($parentChain)
        HostedServices = @($hostedServices)
        Network        = @($network)
        Ownership      = $ownership
        Evidence       = @($evidence)
        Verdict        = $verdict
        Cautions       = @($cautions)
        Actions        = @($actions)
    }
}

function Get-ProcessMatch {
    param([string]$Pattern, [object[]]$ProcessTable)
    if ([string]::IsNullOrWhiteSpace($Pattern)) { return @() }

    $value = $Pattern.Trim()
    $regex = $null
    if ($value.Length -gt 2 -and $value.StartsWith('/') -and $value.EndsWith('/')) {
        $regex = $value.Substring(1, $value.Length - 2)
    } elseif ($value -match '[\*\?]') {
        $escaped = [Regex]::Escape($value)
        $regex = '^' + $escaped.Replace('\*', '.*').Replace('\?', '.') + '$'
    } else {
        $regex = [Regex]::Escape($value)
    }

    $result = New-Object System.Collections.ArrayList
    foreach ($process in $ProcessTable) {
        if ([string]$process.Name -match $regex) { [void]$result.Add($process) }
    }
    return @($result)
}

# ---------------------------------------------------------------------------
# 报告渲染
# ---------------------------------------------------------------------------

function Get-ConfidenceLabel {
    param([string]$Confidence)
    switch ($Confidence) {
        'High'   { return '高' }
        'Medium' { return '中' }
        default  { return '低' }
    }
}

function Get-SignatureStatusLabel {
    param([AllowNull()][string]$Status)
    switch ($Status) {
        'Valid'        { return '有效' }
        'NotSigned'    { return '未签名' }
        'HashMismatch' { return '哈希不匹配' }
        'NotTrusted'   { return '不受信任' }
        'UnknownError' { return '未知错误' }
        default {
            if ([string]::IsNullOrWhiteSpace($Status)) { return '未知' }
            return $Status
        }
    }
}

function Get-NetworkStateLabel {
    param([AllowNull()][string]$State)
    switch ($State) {
        'Listen'     { return '监听' }
        'Established'{ return '已建立' }
        'Bound'      { return '已绑定' }
        'TimeWait'   { return '等待关闭' }
        'CloseWait'  { return '待本端关闭' }
        'SynSent'    { return '正在连接' }
        default {
            if ([string]::IsNullOrWhiteSpace($State)) { return '' }
            return $State
        }
    }
}

function Write-ConsoleReport {
    param($Report)

    Write-Host ''
    Write-ColorLine ('=' * 68) 'DarkGray'
    Write-ColorLine (' HereWhy 为何在此 v{0} | 后台项溯源报告' -f $Report.Version) 'Cyan'
    Write-ColorLine (' 目标：{0} = {1}' -f $Report.Target.Kind, $Report.Target.Value) 'Gray'
    Write-ColorLine (' 时间：{0}    只读诊断，不会修改系统' -f $Report.GeneratedAt) 'DarkGray'
    Write-ColorLine ('=' * 68) 'DarkGray'

    if ($Report.Subjects.Count -eq 0) {
        Write-ColorLine '没有找到可分析的目标。' 'Yellow'
        return
    }

    $index = 0
    foreach ($subject in $Report.Subjects) {
        $index++
        Write-Host ''
        $pidText = ''
        if ($subject.Scope -eq 'process') { $pidText = ('  PID {0}' -f $subject.PidDisplay) }
        Write-ColorLine ('[{0}/{1}] {2}{3}' -f $index, $Report.Subjects.Count, $subject.Name, $pidText) 'White'
        Write-ColorLine ('-' * 68) 'DarkGray'

        Write-KeyValue '位置' (Format-ShortText $subject.Path 110)
        if ($subject.Scope -eq 'process' -and $subject.Started) {
            try { Write-KeyValue '启动于' ([string]$subject.Started.ToString('yyyy-MM-dd HH:mm:ss')) }
            catch { Write-KeyValue '启动于' ([string]$subject.Started) }
        }

        $identity = @()
        if ($subject.Company) { $identity += $subject.Company }
        if ($subject.Product -and $subject.Product -ne $subject.Company) { $identity += $subject.Product }
        if ($subject.FileVersion) { $identity += ('v' + $subject.FileVersion) }
        if ($identity.Count -gt 0) { Write-KeyValue '身份' ($identity -join ' | ') }

        if ($null -ne $subject.Signature) {
            $signerText = ''
            if ($subject.Signature.Signer) { $signerText = '，签名者 ' + $subject.Signature.Signer }
            $color = 'Green'
            if ($subject.Signature.Status -ne 'Valid') { $color = 'Yellow' }
            Write-KeyValue '签名' ((Get-SignatureStatusLabel $subject.Signature.Status) + $signerText) $color
        } else {
            Write-KeyValue '签名' '未检查（加 -Deep 开启）' 'DarkGray'
        }

        if ($subject.Scope -eq 'process' -and @($subject.ParentChain).Count -gt 0) {
            $chainText = @($subject.ParentChain | ForEach-Object { ('{0}({1})' -f $_.Name, $_.Pid) }) -join ' <- '
            Write-KeyValue '父链' (Format-ShortText $chainText 100)
        }
        if ($subject.Scope -eq 'file') {
            Write-KeyValue '状态' '当前没有运行中的进程；按文件与自启配置分析' 'DarkGray'
        }

        $networkText = @()
        $listening = @($subject.Network | Where-Object { ($_.Protocol -eq 'TCP' -and $_.State -eq 'Listen') -or $_.Protocol -eq 'UDP' })
        if ($listening.Count -gt 0) {
            foreach ($endpoint in ($listening | Select-Object -First 6)) {
                $protocol = $endpoint.Protocol
                if ($endpoint.Protocol -eq 'TCP') { $state = 'LISTEN' } else { $state = 'BOUND' }
                $networkText += ('{0} {1} {2}' -f $endpoint.Protocol, $state, (Format-NetworkEndpoint $endpoint.LocalAddress $endpoint.LocalPort))
            }
            if ($listening.Count -gt 6) { $networkText += ('... 另有 {0} 个' -f ($listening.Count - 6)) }
        }
        $established = @($subject.Network | Where-Object { $_.Protocol -eq 'TCP' -and $_.State -eq 'Established' })
        if ($established.Count -gt 0) { $networkText += ('已建立连接 {0} 条' -f $established.Count) }
        if ($networkText.Count -gt 0) { Write-KeyValue '网络' ($networkText -join '; ') }

        $verdictColor = 'Gray'
        if ($subject.Verdict.Level -eq 'installed') { $verdictColor = 'Green' }
        elseif ($subject.Verdict.Level -eq 'system') { $verdictColor = 'Cyan' }
        elseif ($subject.Verdict.Level -eq 'thirdparty') { $verdictColor = 'Yellow' }
        Write-KeyValue '结论' $subject.Verdict.Summary $verdictColor

        $hostedAll = @($subject.HostedServices)
        if ($hostedAll.Count -gt 0) {
            $serviceNames = @($hostedAll | Select-Object -First 6 | ForEach-Object { $_.Name }) -join ', '
            if ($hostedAll.Count -gt 6) { $serviceNames += (' ... 另有 {0} 个' -f ($hostedAll.Count - 6)) }
            Write-KeyValue '承载服务' $serviceNames
        }

        if (@($subject.Evidence).Count -gt 0) {
            Write-Host ''
            Write-ColorLine '  依据：' 'DarkGray'
            $evidenceItems = @($subject.Evidence)
            if ($evidenceItems.Count -gt 20) {
                Write-ColorLine ('   （共 {0} 条依据，只显示前 20 条；完整内容见 JSON 报告）' -f $evidenceItems.Count) 'DarkGray'
            }
            foreach ($item in @($evidenceItems | Select-Object -First 20)) {
                $confidence = Get-ConfidenceLabel $item.Confidence
                $color = 'Gray'
                if ($item.Confidence -eq 'High') { $color = 'Green' }
                elseif ($item.Confidence -eq 'Medium') { $color = 'Yellow' }
                if ($script:UseColor) {
                    Write-Host ('   - [{0}] {1}：' -f $confidence, $item.TypeLabel) -NoNewline -ForegroundColor $color
                    Write-Host $item.Detail -ForegroundColor Gray
                } else {
                    Write-Host ('   - [{0}] {1}：{2}' -f $confidence, $item.TypeLabel, $item.Detail)
                }
            }
        }

        if (@($subject.Actions).Count -gt 0) {
            Write-Host ''
            Write-ColorLine '  安全操作建议（工具不会执行，请你确认后手动操作）：' 'DarkGray'
            $step = 0
            foreach ($action in $subject.Actions) {
                $step++
                Write-ColorLine ('   {0}) {1}' -f $step, $action.Title) 'Yellow'
                Write-ColorLine ('      {0}' -f $action.Command) 'Gray'
                if ($action.Note) { Write-ColorLine ('      注意：{0}' -f $action.Note) 'DarkGray' }
            }
        }

        if (@($subject.Cautions).Count -gt 0) {
            Write-Host ''
            foreach ($caution in $subject.Cautions) {
                Write-ColorLine ('  ! ' + $caution) 'Magenta'
            }
        }
    }

    Write-Host ''
    Write-ColorLine ('-' * 68) 'DarkGray'
    Write-ColorLine (' 扫描统计：进程 {0} / 安装记录 {1} / 自启项 {2} / 服务 {3} / 计划任务 {4} / 网络端点 {5}' -f `
        $Report.ScanStats.Processes, $Report.ScanStats.Installed, $Report.ScanStats.Autostart, `
        $Report.ScanStats.Services, $Report.ScanStats.Tasks, $Report.ScanStats.Network) 'DarkGray'

    if (@($Report.Warnings).Count -gt 0) {
        Write-Host ''
        foreach ($warning in $Report.Warnings) { Write-ColorLine ('  警告：' + $warning) 'Yellow' }
    }
    Write-ColorLine ' 说明：结论来自本机注册表、服务、任务、启动项和进程数据的交叉比对；' 'DarkGray'
    Write-ColorLine '       间接启动（脚本/批处理转发）可能只能给出中低置信度线索。' 'DarkGray'
}

function Get-HtmlSubjectSection {
    param($Subject, [int]$Index = 0)

    $esc = { param([AllowNull()][string]$Text) ConvertTo-HtmlSafe $Text }
    $sb = New-Object System.Text.StringBuilder

    $pidText = ''
    if ($Subject.Scope -eq 'process') { $pidText = 'PID ' + $Subject.PidDisplay }
    $levelClass = 'level-' + $Subject.Verdict.Level
    $levelLabel = '未归类'
    switch ($Subject.Verdict.Level) {
        'installed'  { $levelLabel = '已安装软件' }
        'system'     { $levelLabel = '系统组件' }
        'thirdparty' { $levelLabel = '独立程序' }
        'unknown'    { $levelLabel = '来源未知' }
    }

    [void]$sb.AppendLine('<section class="subject">')
    [void]$sb.AppendLine('<div class="subject-head">')
    [void]$sb.AppendLine('<div class="subject-title">')
    if ($Index -gt 0) {
        [void]$sb.AppendLine(('<span class="subject-index">{0:00}</span>' -f $Index))
    }
    [void]$sb.AppendLine(('<div><h2 class="subject-name">{0}</h2><p class="subject-pid">{1}</p></div>' -f (& $esc $Subject.Name), (& $esc $pidText)))
    [void]$sb.AppendLine('</div>')
    [void]$sb.AppendLine(('<div class="stamp {0}">{1}</div>' -f $levelClass, $levelLabel))
    [void]$sb.AppendLine('</div>')
    [void]$sb.AppendLine(('<p class="subject-path">{0}</p>' -f (& $esc $Subject.Path)))
    [void]$sb.AppendLine(('<div class="verdict {0}"><span class="verdict-label">结论</span><p>{1}</p></div>' -f $levelClass, (& $esc $Subject.Verdict.Summary)))

    $rows = @()
    if ($Subject.Scope -eq 'process' -and $Subject.Started) {
        try { $rows += @('启动时间', [string]$Subject.Started.ToString('yyyy-MM-dd HH:mm:ss')) } catch { $rows += @('启动时间', [string]$Subject.Started) }
    }
    if ($Subject.Company) { $rows += @('公司', $Subject.Company) }
    if ($Subject.Product) { $rows += @('产品', $Subject.Product) }
    if ($Subject.FileVersion) { $rows += @('版本', $Subject.FileVersion) }
    if ($Subject.Description) { $rows += @('文件说明', $Subject.Description) }
    if ($null -ne $Subject.Signature) {
        $signer = Get-SignatureStatusLabel $Subject.Signature.Status
        if ($Subject.Signature.Signer) { $signer += ' / ' + $Subject.Signature.Signer }
        $rows += @('数字签名', $signer)
    } else {
        $rows += @('数字签名', '未检查（使用 -Deep 开启）')
    }
    if (@($Subject.ParentChain).Count -gt 0) {
        $rows += @('父进程链', (@($Subject.ParentChain | ForEach-Object { '{0}({1})' -f $_.Name, $_.Pid }) -join ' <- '))
    }
    if (@($Subject.HostedServices).Count -gt 0) {
        $rows += @('承载服务', (@($Subject.HostedServices | Select-Object -First 20 | ForEach-Object { $_.Name }) -join ', '))
    }
    if ($rows.Count -gt 0) {
        [void]$sb.AppendLine('<h3 class="section-title">身份与运行信息</h3><table class="data">')
        foreach ($pair in (0..([Math]::Floor(($rows.Count - 1) / 2)))) {
            $nameIndex = $pair * 2
            if ($nameIndex -ge $rows.Count) { continue }
            $valueClass = ''
            if ($rows[$nameIndex] -in @('父进程链', '承载服务')) { $valueClass = ' class="mono"' }
            [void]$sb.AppendLine(('<tr><th class="rowlabel">{0}</th><td{1}>{2}</td></tr>' -f (& $esc $rows[$nameIndex]), $valueClass, (& $esc $rows[$nameIndex + 1])))
        }
        [void]$sb.AppendLine('</table>')
    }

    if (@($Subject.Network).Count -gt 0) {
        [void]$sb.AppendLine('<h3 class="section-title">网络端点</h3><table class="data"><thead><tr><th>协议</th><th>状态</th><th>本地地址</th><th>远程地址</th></tr></thead><tbody>')
        foreach ($endpoint in (@($Subject.Network) | Select-Object -First 25)) {
            $local = Format-NetworkEndpoint $endpoint.LocalAddress $endpoint.LocalPort
            $remote = ''
            if ($endpoint.RemoteAddress) { $remote = Format-NetworkEndpoint $endpoint.RemoteAddress $endpoint.RemotePort }
            [void]$sb.AppendLine(('<tr><td>{0}</td><td>{1}</td><td class="mono">{2}</td><td class="mono">{3}</td></tr>' -f (& $esc $endpoint.Protocol), (& $esc (Get-NetworkStateLabel $endpoint.State)), (& $esc $local), (& $esc $remote)))
        }
        [void]$sb.AppendLine('</tbody></table>')
    }

    if (@($Subject.Evidence).Count -gt 0) {
        [void]$sb.AppendLine('<h3 class="section-title">溯源依据</h3><table class="data"><thead><tr><th>类型</th><th>置信度</th><th>来源</th><th>说明</th></tr></thead><tbody>')
        $evidenceItems = @($Subject.Evidence)
        if ($evidenceItems.Count -gt 25) {
            [void]$sb.AppendLine(('<tr><td colspan="4">共 {0} 条依据，只显示前 25 条；完整内容见 JSON 报告</td></tr>' -f $evidenceItems.Count))
        }
        foreach ($item in @($evidenceItems | Select-Object -First 25)) {
            $confClass = 'low'
            if ($item.Confidence -eq 'High') { $confClass = 'high' }
            elseif ($item.Confidence -eq 'Medium') { $confClass = 'med' }
            [void]$sb.AppendLine(('<tr><td>{0}</td><td><span class="conf {1}">{2}</span></td><td>{3}</td><td>{4}</td></tr>' -f `
                (& $esc $item.TypeLabel), $confClass, (Get-ConfidenceLabel $item.Confidence), (& $esc $item.SourceLabel), (& $esc $item.Detail)))
        }
        [void]$sb.AppendLine('</tbody></table>')
    }

    if (@($Subject.Actions).Count -gt 0) {
        [void]$sb.AppendLine('<h3 class="section-title">建议操作</h3><p class="action-note">以下命令不会被 HereWhy 自动执行，请确认后再手动运行。</p><ol class="actions">')
        foreach ($action in $Subject.Actions) {
            [void]$sb.AppendLine(('<li><p class="action-title">{0}</p><pre>{1}</pre><p class="action-note">{2}</p></li>' -f (& $esc $action.Title), (& $esc $action.Command), (& $esc $action.Note)))
        }
        [void]$sb.AppendLine('</ol>')
    }

    if (@($Subject.Cautions).Count -gt 0) {
        [void]$sb.AppendLine('<h3 class="section-title">注意事项</h3><ul class="notes">')
        foreach ($caution in $Subject.Cautions) {
            [void]$sb.AppendLine(('<li>{0}</li>' -f (& $esc $caution)))
        }
        [void]$sb.AppendLine('</ul>')
    }

    [void]$sb.AppendLine('</section>')
    return $sb.ToString()
}

function New-HtmlReport {
    param($Report, [string]$OutPath)

    $css = @'
:root { --ink:#191b1e; --muted:#5f666d; --hair:#d5d9dc; --soft:#f5f6f7; --ok:#1f5f46; --note:#8a5a00; --alert:#7a1f1f; }
* { box-sizing:border-box; }
html, body { margin:0; padding:0; }
body { background:#eef0f1; color:var(--ink); font:14px/1.65 "Segoe UI","Microsoft YaHei","PingFang SC",sans-serif; }
.page { max-width:1040px; margin:26px auto; background:#fff; border:1px solid #c9ced2; }
.masthead { padding:26px 38px 20px; border-bottom:2px solid var(--ink); }
.masthead .kicker { margin:0 0 8px; font:600 11px/1 Consolas,"Cascadia Mono",monospace; color:var(--muted); }
.masthead h1 { margin:0; font-size:23px; font-weight:650; }
.masthead .subtitle { margin:6px 0 0; color:var(--muted); font-size:13px; }
table.manifest, table.data { width:100%; border-collapse:collapse; }
table.manifest { border-bottom:1px solid var(--hair); }
table.manifest th, table.manifest td { padding:8px 12px; border-right:1px solid var(--hair); text-align:left; font-size:13px; }
table.manifest th { width:112px; background:var(--soft); color:var(--muted); font-weight:600; }
table.manifest tr + tr th, table.manifest tr + tr td { border-top:1px solid var(--hair); }
.body { padding:0 38px 34px; }
.section-heading { display:flex; align-items:center; gap:10px; margin:30px 0 10px; font-size:15px; font-weight:650; border-bottom:1px solid var(--ink); padding-bottom:7px; }
.section-heading span { font:600 12px/1 Consolas,monospace; color:var(--muted); }
table.data th, table.data td { padding:7px 10px; border-bottom:1px solid var(--hair); text-align:left; vertical-align:top; }
table.data thead th { background:var(--soft); border-top:1px solid #c1c7cb; border-bottom:1px solid #c1c7cb; font-weight:600; white-space:nowrap; }
table.data td:first-child { white-space:nowrap; }
table.data th.rowlabel { width:150px; background:#fbfbfb; color:var(--muted); font-weight:600; }
td.mono, .mono { font-family:Consolas,"Cascadia Mono",monospace; font-size:13px; }
.subject { border-top:1px solid var(--ink); margin-top:34px; padding-top:18px; }
.subject-head { display:flex; align-items:flex-start; justify-content:space-between; gap:18px; }
.subject-title { display:flex; align-items:flex-start; gap:12px; }
.subject-index { font:600 12px/1.8 Consolas,monospace; color:var(--muted); }
.subject-name { margin:0; font-size:20px; font-weight:650; word-break:break-all; }
.subject-pid { margin:2px 0 0; color:var(--muted); font:12px/1.5 Consolas,monospace; }
.stamp { border:1px solid var(--muted); color:var(--muted); padding:4px 10px; font-size:12px; font-weight:600; white-space:nowrap; }
.stamp.level-installed { border-color:var(--ok); color:var(--ok); }
.stamp.level-system { border-color:#41474d; color:#41474d; }
.stamp.level-thirdparty { border-color:var(--note); color:var(--note); }
.stamp.level-unknown { border-color:#8b9095; color:#5f666d; }
.subject-path { margin:8px 0 0; color:var(--muted); font:12px/1.6 Consolas,"Cascadia Mono",monospace; word-break:break-all; }
.verdict { border:1px solid var(--hair); border-left:4px solid var(--muted); padding:9px 14px; margin:14px 0 0; }
.verdict.level-installed { border-left-color:var(--ok); }
.verdict.level-system { border-left-color:#41474d; }
.verdict.level-thirdparty { border-left-color:var(--note); }
.verdict.level-unknown { border-left-color:#8b9095; }
.verdict-label { display:block; color:var(--muted); font-size:12px; font-weight:600; }
.verdict p { margin:2px 0 0; }
.section-title { margin:22px 0 8px; font-size:13px; font-weight:650; color:#3a3f45; }
.conf { font-family:Consolas,monospace; font-size:12px; font-weight:600; }
.conf.high { color:var(--ok); }
.conf.med { color:var(--note); }
.conf.low { color:var(--muted); }
.actions { margin:0; padding-left:22px; }
.actions li { margin:0 0 14px; }
.action-title { margin:0 0 6px; font-weight:600; }
.actions pre { margin:0; padding:10px 12px; background:var(--soft); border:1px solid var(--hair); font:12px/1.6 Consolas,"Cascadia Mono",monospace; white-space:pre-wrap; word-break:break-all; }
.action-note { margin:5px 0 0; color:var(--muted); }
.notes { margin:0; padding-left:16px; }
.notes li { margin:0 0 6px; color:#5a4a1f; }
.report-footer { margin-top:34px; padding-top:12px; border-top:1px solid var(--hair); color:var(--muted); font-size:12px; }
@media print {
  body { background:#fff; }
  .page { margin:0; border:0; max-width:none; }
  .subject { break-inside:avoid; }
  .actions pre { background:#fff; }
}
@media (max-width:760px) {
  .page { margin:0; border-left:0; border-right:0; }
  .masthead, .body { padding-left:20px; padding-right:20px; }
  table.manifest th { width:88px; }
  .subject-head { flex-direction:column; }
}
'@

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<!DOCTYPE html>')
    [void]$sb.AppendLine('<html lang="zh-CN"><head><meta charset="utf-8">')
    [void]$sb.AppendLine('<meta name="viewport" content="width=device-width, initial-scale=1">')
    [void]$sb.AppendLine('<title>HereWhy 诊断报告</title>')
    [void]$sb.AppendLine('<style>' + $css + '</style></head><body>')
    [void]$sb.AppendLine('<div class="page">')

    [void]$sb.AppendLine('<header class="masthead">')
    [void]$sb.AppendLine(('<p class="kicker">HEREWHY / DIAGNOSTIC REPORT / v{0}</p>' -f (ConvertTo-HtmlSafe $Report.Version)))
    [void]$sb.AppendLine('<h1>Windows 后台项溯源报告</h1>')
    [void]$sb.AppendLine('<p class="subtitle">只读诊断，不修改注册表、服务、计划任务或文件</p>')
    [void]$sb.AppendLine('</header>')

    [void]$sb.AppendLine('<table class="manifest">')
    [void]$sb.AppendLine(('<tr><th>目标</th><td colspan="3">{0} = {1}</td></tr>' -f (ConvertTo-HtmlSafe $Report.Target.Kind), (ConvertTo-HtmlSafe $Report.Target.Value)))
    [void]$sb.AppendLine(('<tr><th>生成时间</th><td>{0}</td><th>工具版本</th><td>HereWhy {1}</td></tr>' -f (ConvertTo-HtmlSafe $Report.GeneratedAt), (ConvertTo-HtmlSafe $Report.Version)))
    [void]$sb.AppendLine(('<tr><th>扫描范围</th><td colspan="3">进程 {0} / 安装记录 {1} / 自启项 {2} / 服务 {3} / 计划任务 {4} / 网络端点 {5}</td></tr>' -f `
        $Report.ScanStats.Processes, $Report.ScanStats.Installed, $Report.ScanStats.Autostart, `
        $Report.ScanStats.Services, $Report.ScanStats.Tasks, $Report.ScanStats.Network))
    [void]$sb.AppendLine('</table>')

    [void]$sb.AppendLine('<main class="body">')
    [void]$sb.AppendLine('<h2 class="section-heading"><span>01</span>总览</h2>')
    [void]$sb.AppendLine('<table class="data overview"><thead><tr><th>目标</th><th>PID</th><th>判定</th><th>结论摘要</th></tr></thead><tbody>')
    foreach ($subject in @($Report.Subjects)) {
        $pidText = ''
        if ($subject.Scope -eq 'process') { $pidText = [string]$subject.PidDisplay }
        $levelLabel = '未归类'
        switch ($subject.Verdict.Level) {
            'installed'  { $levelLabel = '已安装软件' }
            'system'     { $levelLabel = '系统组件' }
            'thirdparty' { $levelLabel = '独立程序' }
            'unknown'    { $levelLabel = '来源未知' }
        }
        [void]$sb.AppendLine(('<tr><td class="mono">{0}</td><td class="mono">{1}</td><td>{2}</td><td>{3}</td></tr>' -f `
            (ConvertTo-HtmlSafe $subject.Name), (ConvertTo-HtmlSafe $pidText), $levelLabel, (ConvertTo-HtmlSafe $subject.Verdict.Summary)))
    }
    [void]$sb.AppendLine('</tbody></table>')

    if (@($Report.Warnings).Count -gt 0) {
        [void]$sb.AppendLine('<h2 class="section-heading"><span>!</span>扫描警告</h2><ul class="notes">')
        foreach ($warning in $Report.Warnings) {
            [void]$sb.AppendLine(('<li>{0}</li>' -f (ConvertTo-HtmlSafe $warning)))
        }
        [void]$sb.AppendLine('</ul>')
    }

    $subjectIndex = 1
    foreach ($subject in @($Report.Subjects)) {
        $subjectIndex++
        [void]$sb.AppendLine((Get-HtmlSubjectSection -Subject $subject -Index $subjectIndex))
    }

    [void]$sb.AppendLine('<footer class="report-footer">')
    [void]$sb.AppendLine(('本报告由 HereWhy {0} 生成于 {1}。结论来自本机注册表、服务、计划任务、启动项与进程数据的交叉比对；间接启动（脚本或批处理转发）可能只能给出中低置信度线索。工具只读，不执行任何修复操作。' -f `
        (ConvertTo-HtmlSafe $Report.Version), (ConvertTo-HtmlSafe $Report.GeneratedAt)))
    [void]$sb.AppendLine('</footer>')
    [void]$sb.AppendLine('</main></div></body></html>')

    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($OutPath, $sb.ToString(), $encoding)
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------

function Show-Usage {
    Write-Host ''
    Write-ColorLine ('HereWhy 为何在此 v{0} - Windows 后台项溯源解释器（只读）' -f $script:HereWhyVersion) 'Cyan'
    Write-Host ''
    Write-Host '用法：'
    Write-Host '  .\HereWhy.ps1 -List                         先看看有哪些可疑后台项'
    Write-Host '  .\HereWhy.ps1 -Name <名称关键字|通配符|/正则/>'
    Write-Host '  .\HereWhy.ps1 -Id <PID>'
    Write-Host '  .\HereWhy.ps1 -Port <本地端口>'
    Write-Host '  .\HereWhy.ps1 -Path <exe文件路径>'
    Write-Host ''
    Write-Host '常用选项：'
    Write-Host '  -Deep              校验数字签名（较慢）'
    Write-Host '  -HtmlReport <路径> 生成自包含 HTML 报告'
    Write-Host '  -Json <路径>       导出 JSON（便于自动化）'
    Write-Host '  -MaxSubjects <n>   最多分析几个目标（默认 5）'
    Write-Host '  -NoColor           关闭彩色输出'
    Write-Host ''
    Write-Host '示例：'
    Write-Host '  .\HereWhy.ps1 -List'
    Write-Host '  .\HereWhy.ps1 -Name node -Deep'
    Write-Host '  .\HereWhy.ps1 -Port 3000 -HtmlReport .\report.html'
    Write-Host '  .\HereWhy.ps1 -Path "D:\Tools\agent.exe" -Json .\agent.json'
    Write-Host ''
    Write-ColorLine ' 本工具只读：不会修改注册表、服务、计划任务或文件。' 'DarkGray'
}

function Invoke-ListMode {
    param($Context)

    Write-Host ''
    Write-ColorLine ('HereWhy 为何在此 v{0} | 后台候选清单' -f $script:HereWhyVersion) 'Cyan'
    Write-ColorLine ('扫描：进程 {0} / 自启项 {1} / 网络端点 {2}' -f @($Context.Processes).Count, @($Context.Autostart).Count, @($Context.Network).Count) 'DarkGray'

    $processById = @{}
    foreach ($process in @($Context.Processes)) { $processById[[int]$process.Pid] = $process }

    $listenerEndpoints = @($Context.Network | Where-Object { ($_.Protocol -eq 'TCP' -and $_.State -eq 'Listen') -or $_.Protocol -eq 'UDP' })
    $byPid = @{}
    foreach ($endpoint in $listenerEndpoints) {
        $owningPid = [int]$endpoint.Pid
        if (-not $byPid.ContainsKey($owningPid)) { $byPid[$owningPid] = New-Object System.Collections.ArrayList }
        [void]$byPid[$owningPid].Add($endpoint)
    }

    $servicePathByPid = @{}
    foreach ($service in @($Context.Services)) {
        if ($service.ProcessId -gt 0 -and $service.Executable -and -not $servicePathByPid.ContainsKey([int]$service.ProcessId)) {
            $servicePathByPid[[int]$service.ProcessId] = $service.Executable
        }
    }

    $candidates = New-Object System.Collections.ArrayList
    foreach ($owningPid in @($byPid.Keys)) {
        $process = $null
        if ($processById.ContainsKey($owningPid)) { $process = $processById[$owningPid] }
        $path = $null
        $name = '(未知)'
        if ($null -ne $process) {
            $name = [string]$process.Name
            $path = Get-ProcessExecutablePath $process
            if ([string]::IsNullOrWhiteSpace($path) -and $servicePathByPid.ContainsKey($owningPid)) {
                $path = $servicePathByPid[$owningPid]
            }
        }
        $ports = @($byPid[$owningPid] | ForEach-Object { [string]$_.LocalPort } | Select-Object -Unique | Sort-Object { [int]$_ })
        $isSystem = $false
        if ($path -and $env:SystemRoot -and (Test-PathWithin $path (Join-Path $env:SystemRoot 'System32'))) { $isSystem = $true }
        if (-not $path -and $name -match '^(System|Registry|Memory Compression|svchost|services|lsass|wininit|winlogon|csrss|smss|spoolsv|dwm|fontdrvhost)$') { $isSystem = $true }
        [void]$candidates.Add([pscustomobject]@{
            Pid      = $owningPid
            Name     = $name
            Path     = $path
            Ports    = $ports
            IsSystem = $isSystem
        })
    }
    $candidates = @($candidates | Sort-Object IsSystem, Name, Pid)

    Write-Host ''
    Write-ColorLine '监听端口 / 占用进程（第三方优先）：' 'White'
    foreach ($candidate in @($candidates | Select-Object -First 30)) {
        $marker = '  '
        $color = 'Gray'
        if ($candidate.IsSystem) { $marker = 'S '; $color = 'DarkGray' }
        else { $marker = '* '; $color = 'Yellow' }
        $pathText = Format-ShortText $candidate.Path 32
        if ([string]::IsNullOrWhiteSpace($pathText) -and $candidate.Pid -eq 4) { $pathText = '(Windows 内核 System)' }
        elseif ([string]::IsNullOrWhiteSpace($pathText)) { $pathText = '(路径不可读)' }
        $line = ('{0}{1,-7} {2,-26} {3,-34} {4}' -f $marker, $candidate.Pid, (Format-ShortText $candidate.Name 24), $pathText, ('端口 ' + ($candidate.Ports -join ',')))
        Write-ColorLine $line $color
    }
    if ($candidates.Count -gt 30) { Write-ColorLine ('  ... 另有 {0} 个，本页只显示前 30 个' -f ($candidates.Count - 30)) 'DarkGray' }

    $userEntries = @($Context.Autostart | Where-Object { $_.Location -like 'HKCU*' -or $_.Kind -eq 'StartupFolder' })
    Write-Host ''
    Write-ColorLine '当前用户自启项：' 'White'
    foreach ($entry in @($userEntries | Select-Object -First 15)) {
        $line = ('  - [{0}] {1} -> {2}' -f $entry.SourceLabel, $entry.Name, (Format-ShortText $entry.Command 80))
        Write-ColorLine $line 'Gray'
    }
    if ($userEntries.Count -gt 15) { Write-ColorLine ('  ... 另有 {0} 个' -f ($userEntries.Count - 15)) 'DarkGray' }
    if ($userEntries.Count -eq 0) { Write-ColorLine '  （没有当前用户级自启项）' 'DarkGray' }

    Write-Host ''
    Write-ColorLine '下一步：用 -Id <PID> / -Name <名称> / -Port <端口> 查看完整溯源。' 'Cyan'

    return [pscustomobject]@{
        GeneratedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        Listeners   = @($candidates)
        UserAutostart = @($userEntries)
        Warnings    = @($script:Warnings)
    }
}

function Invoke-HereWhyMain {
    if ($Version) {
        Write-Host ('HereWhy {0}' -f $script:HereWhyVersion)
        return
    }
    if ($Help -or ($null -eq $Id -and $null -eq $Port -and [string]::IsNullOrWhiteSpace($Name) -and [string]::IsNullOrWhiteSpace($Path) -and -not $List)) {
        Show-Usage
        return
    }

    $targetKind = ''
    $targetValue = ''
    if ($List) { $targetKind = '清单'; $targetValue = '后台候选' }
    elseif ($null -ne $Id) { $targetKind = 'PID'; $targetValue = ($Id -join ', ') }
    elseif ($null -ne $Port) { $targetKind = '端口'; $targetValue = ($Port -join ', ') }
    elseif (-not [string]::IsNullOrWhiteSpace($Name)) { $targetKind = '进程名'; $targetValue = $Name }
    else { $targetKind = '文件路径'; $targetValue = $Path }

    $context = Get-HereWhyContext -SkipTasks:$List

    if ($List) {
        $listResult = Invoke-ListMode -Context $context
        if (-not [string]::IsNullOrWhiteSpace($Json)) {
            $jsonPath = Resolve-OutputPath $Json
            $encoding = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($jsonPath, ($listResult | ConvertTo-Json -Depth 6), $encoding)
            Write-Host ''
            Write-ColorLine ('JSON 已写入：' + $jsonPath) 'Green'
        }
        if (-not [string]::IsNullOrWhiteSpace($HtmlReport)) {
            Add-Warning '清单模式暂不支持 HTML 报告，请改用 -Json 或指定具体目标。'
            Write-ColorLine '注意：清单模式暂不支持 HTML 报告。' 'Yellow'
        }
        return
    }

    $subjects = New-Object System.Collections.ArrayList

    if ($null -ne $Id) {
        $processById = @{}
        foreach ($process in @($context.Processes)) { $processById[[int]$process.Pid] = $process }
        foreach ($requestedId in $Id) {
            if (-not $processById.ContainsKey([int]$requestedId)) {
                Add-Warning ('PID {0} 不存在（进程可能已退出）。' -f $requestedId)
                continue
            }
            $subject = New-SubjectFromProcesses -Processes @($processById[[int]$requestedId]) -Context $context -Deep:$Deep
            if ($null -ne $subject) { [void]$subjects.Add($subject) }
        }
    } elseif ($null -ne $Port) {
        $ownerPids = @($context.Network | Where-Object { $Port -contains [int]$_.LocalPort } | ForEach-Object { [int]$_.Pid } | Select-Object -Unique)
        if ($ownerPids.Count -eq 0) {
            Add-Warning ('没有发现使用端口 {0} 的进程。' -f ($Port -join ', '))
        }
        $processById = @{}
        foreach ($process in @($context.Processes)) { $processById[[int]$process.Pid] = $process }
        $matchedProcesses = @($ownerPids | Where-Object { $processById.ContainsKey([int]$_) } | ForEach-Object { $processById[[int]$_] })
        $groups = @($matchedProcesses | Group-Object { Get-SubjectGroupKey $_ } | Select-Object -First $MaxSubjects)
        foreach ($group in $groups) {
            $subject = New-SubjectFromProcesses -Processes @($group.Group) -Context $context -Deep:$Deep
            if ($null -ne $subject) { [void]$subjects.Add($subject) }
        }
    } elseif (-not [string]::IsNullOrWhiteSpace($Name)) {
        $matchedProcesses = @(Get-ProcessMatch -Pattern $Name -ProcessTable @($context.Processes))
        if ($matchedProcesses.Count -eq 0) {
            Add-Warning ('没有找到名称匹配「{0}」的进程。' -f $Name)
        }
        $groups = @($matchedProcesses | Group-Object { Get-SubjectGroupKey $_ } | Select-Object -First $MaxSubjects)
        foreach ($group in $groups) {
            $subject = New-SubjectFromProcesses -Processes @($group.Group) -Context $context -Deep:$Deep
            if ($null -ne $subject) { [void]$subjects.Add($subject) }
        }
    } else {
        $normalized = ConvertTo-NormalizedPath $Path
        $matchedProcesses = @($context.Processes | Where-Object {
            $processPath = Get-ProcessExecutablePath $_
            $processPath -and $normalized -and ((Get-PathKey $processPath) -eq (Get-PathKey $normalized) -or (Test-PathWithin $processPath $normalized))
        })
        if ($matchedProcesses.Count -gt 0) {
            $groups = @($matchedProcesses | Group-Object { Get-SubjectGroupKey $_ } | Select-Object -First $MaxSubjects)
            foreach ($group in $groups) {
                $subject = New-SubjectFromProcesses -Processes @($group.Group) -Context $context -Deep:$Deep
                if ($null -ne $subject) { [void]$subjects.Add($subject) }
            }
        } elseif (Test-Path -LiteralPath $normalized -PathType Leaf -ErrorAction SilentlyContinue) {
            $subject = New-SubjectFromPath -PathValue $normalized -Context $context -Deep:$Deep
            if ($null -ne $subject) { [void]$subjects.Add($subject) }
        } else {
            Add-Warning ('路径不存在：{0}' -f $Path)
        }
    }

    $report = [pscustomobject]@{
        Tool        = 'HereWhy'
        Version     = $script:HereWhyVersion
        GeneratedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        Target      = [pscustomobject]@{ Kind = $targetKind; Value = $targetValue }
        Subjects    = @($subjects)
        ScanStats   = [pscustomobject]@{
            Processes = @($context.Processes).Count
            Installed = @($context.Installed).Count
            Autostart = @($context.Autostart).Count
            Services  = @($context.Services).Count
            Tasks     = @($context.Tasks).Count
            Network   = @($context.Network).Count
        }
        Warnings    = @($script:Warnings)
    }

    Write-ConsoleReport -Report $report

    if (-not [string]::IsNullOrWhiteSpace($HtmlReport)) {
        $htmlPath = Resolve-OutputPath $HtmlReport
        New-HtmlReport -Report $report -OutPath $htmlPath
        Write-Host ''
        Write-ColorLine ('HTML 报告已写入：' + $htmlPath) 'Green'
    }
    if (-not [string]::IsNullOrWhiteSpace($Json)) {
        $jsonPath = Resolve-OutputPath $Json
        $encoding = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($jsonPath, ($report | ConvertTo-Json -Depth 8), $encoding)
        Write-Host ''
        Write-ColorLine ('JSON 已写入：' + $jsonPath) 'Green'
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-HereWhyMain
}
