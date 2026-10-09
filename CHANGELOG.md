# Changelog

## v1.0.0 - 2026-10-09

Initial release.

- Read-only attribution for processes, PIDs, listening ports, and `.exe` paths.
- Cross-references Uninstall registry records, services, scheduled tasks, Run keys, Startup folders, parent-process chains, and network endpoints.
- Confidence-tagged evidence chain: installation record, service host, startup entry, scheduled task.
- Safety guardrails: system components are explained but never given disable commands; user-facing suggestions are reversible and are never executed by the tool.
- Shared-host handling: `svchost.exe` and `dllhost.exe` instances are analyzed per PID instead of being merged.
- Output modes: console, self-contained HTML report, and JSON export.
- Windows PowerShell 5.1 and PowerShell 7 compatible, no external dependencies.
- Self-contained test suite: 36 tests, passing on Windows PowerShell 5.1.26100 and PowerShell 7.6.5.
