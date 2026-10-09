# HereWhy

**Stop guessing why that background process exists.**

HereWhy is a read-only Windows diagnostic tool for one everyday question:

> "Something is running on my PC. What is it, who installed it, why does it start, and can I turn it off safely?"

Give it a process name, PID, listening port, or an `.exe` path. It cross-references live processes, installed-program records, services, scheduled tasks, startup entries, parent-process chains, and network endpoints, then writes a report a normal person can read.

## What it answers

1. **What is it?** Company, product, version, file description, and optional Authenticode signature check.
2. **Who installed it?** Matched against Uninstall registry records (`InstallLocation` / `DisplayIcon`), including the awkward case where an installer claims a whole drive root.
3. **Why does it start?** Service, scheduled task, registry Run key, Startup folder, or on-demand launch from a parent process.
4. **How do I turn it off safely?** Reversible, copy-pasteable commands with notes. HereWhy never executes them.

## Why another process tool?

Task Manager lists. Autoruns dumps. Process Explorer inspects. None of them answer "why is this here, and what is the safe next step?" in one pass.

| Tool | What is it | Who installed it | Why it starts | Reversible action plan | Zero-install |
| --- | --- | --- | --- | --- | --- |
| Task Manager | Partial | No | No | Partial | Yes |
| Autoruns | No | No | Lists entries, you interpret | No | Yes |
| Process Explorer | Partial | No | No | No | Yes |
| **HereWhy** | **Yes** | **Yes** | **Yes** | **Yes** | **Yes** |

## Requirements

- Windows 10 or Windows 11.
- Windows PowerShell 5.1 (built in) or PowerShell 7+.
- No installation, no admin rights required for normal use. Some protected system details are richer when run as administrator.

## Quick start

```powershell
# See what is listening and which third-party processes own ports
.\HereWhy.ps1 -List

# Trace a process by name (substring by default)
.\HereWhy.ps1 -Name cc-switch

# Trace whatever is listening on a port
.\HereWhy.ps1 -Port 135

# Trace a PID, with signature verification
.\HereWhy.ps1 -Id 21968 -Deep

# Analyze an executable that is not running right now
.\HereWhy.ps1 -Path "D:\Tools\agent.exe"

# Produce self-contained HTML and machine-readable JSON
.\HereWhy.ps1 -Name cc-switch -Deep -HtmlReport .\report.html -Json .\report.json
```

If you prefer a launcher, double-click `Run-HereWhy.cmd` or run:

```cmd
Run-HereWhy.cmd -List
```

## Sample output

```text
====================================================================
 HereWhy v1.0.0 | Windows launch provenance report
 Target: process name = ExampleAgent
 Time: 2026-10-09 12:00:00    read-only, no system changes
====================================================================

[1/1] ExampleAgent.exe  PID 4212
--------------------------------------------------------------------
  Path    : C:\Program Files\Example Agent\ExampleAgent.exe
  Started : 2026-10-09 09:15:22
  Identity: Example Software Ltd. | Example Agent | v4.2.1
  Signed  : valid
  Parent  : services.exe(712) <- wininit.exe(688)
  Network : TCP LISTEN 127.0.0.1:41000
  Verdict : installed software "Example Agent"; started by scheduled task \Example\AgentUpdate

  Evidence:
   - [high] install record: Example Agent matches C:\Program Files\Example Agent\ (version 4.2.1)
   - [high] scheduled task: \Example\AgentUpdate executes this program
```

A synthetic HTML preview is available at `samples/sample-report.png`; it contains no real machine data.

## Data sources

All checks are local and read-only:

| Source | Used for |
| --- | --- |
| `Win32_Process` | live processes, command lines, parent chain, start time |
| Uninstall registry keys | installed product ownership and version |
| `Win32_Service` | service host and startup relationship |
| `Get-ScheduledTask` | scheduled-task launch relationship |
| Run / RunOnce keys | per-user and machine startup entries |
| Startup folders | shortcut and script autostart entries |
| `Get-NetTCPConnection` / `Get-NetUDPEndpoint` | listening ports and owning PID (falls back to `netstat`) |
| `Get-AuthenticodeSignature` | optional signature check with `-Deep` |

## Confidence model

HereWhy does not pretend every match is equal:

- **High**: exact executable-path match in an installation record, service, scheduled task, or startup entry.
- **Medium**: a command line mentions the executable name, but the path does not fully match. This is common for scripts and batch wrappers.
- **Low**: reserved for weak signals; always inspect the evidence yourself.

Indirect launches (a script starts a launcher, which starts the real program) are the hardest case. HereWhy reports what it can prove and labels the rest as uncertain.

## Safety and privacy

- Read-only: it never deletes files, edits the registry, stops services, disables tasks, or changes configuration.
- No network calls: everything is collected and rendered on your machine.
- Suggestions are output only. You decide whether to run them.
- System components get explanations, not disable commands.
- Shared hosts such as `svchost.exe` are analyzed per PID, so services from different instances are not mixed together.

## Options

| Option | Meaning |
| --- | --- |
| `-List` | show listening processes and current-user autostart entries |
| `-Name <pattern>` | match process name; substring, `*` wildcard, or `/regex/` |
| `-Id <pid>` | analyze one or more PIDs |
| `-Port <port>` | find and analyze the process owning a local port |
| `-Path <exe>` | analyze a file, whether running or not |
| `-Deep` | verify Authenticode signature (slower) |
| `-HtmlReport <path>` | write a self-contained HTML report |
| `-Json <path>` | export the full report as JSON |
| `-MaxSubjects <n>` | cap the number of analyzed process groups (default 5) |
| `-NoColor` | plain console output |

## Limitations

- Protected processes can hide their executable path; HereWhy falls back to the service table, `System32` name matching, and `CommandLine` when possible.
- Scheduled-task and startup matching is path-based. A script that computes a path at runtime is reported as a medium-confidence lead, not a proof.
- `-Deep` signature checks can take a moment on cold files.
- This is a diagnostic tool, not an antivirus. It does not score files as malicious.

## Development

```powershell
# Windows PowerShell 5.1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-HereWhy.ps1

# PowerShell 7
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-HereWhy.ps1
```

The suite has 36 tests and no Pester dependency. It covers path parsing, wildcard and regex matching, install-record attribution, evidence-chain generation, system-service guardrails, HTML escaping, and report generation.

Verified on 2026-10-09 with Windows PowerShell 5.1.26100 and PowerShell 7.6.5 on Windows 11: `36 passed, 0 failed` on both engines.

## License

MIT. See [LICENSE](LICENSE).
