# Native Windows Bash-Step Qualification Evidence

**Status**: QUALIFIED

**Run timestamp**: `2026-07-12T05:51:29.5672121+00:00`
**Qualification workflow**: [GitHub Actions run 29181756146](https://github.com/DartClaw/dartclaw/actions/runs/29181756146)
**Host**: Microsoft Windows 10.0.26100, native X64
**Source revision**: `d9b2e9d612fd0fdef1305553dccc15f43b2fd32e`
**Artifact/source under test**: source checkout at `D:\a\dartclaw\dartclaw`
**Dart**: 3.12.0 stable, `windows_x64`
**Resolved Bash**: `C:\Program Files\Git\bin\bash.exe`
**Git Bash**: GNU bash 5.3.9(1)-release, `x86_64-pc-cygwin`
**Native cwd**: `C:\DartClaw Bash Step Qualification\workspace with spaces`
**Workflow run**: `988ace7c-5ad2-4fd8-b415-a75db222cb21`

## Result

- Workflow status: `completed`.
- `qualify-bash.status`: `success`.
- `qualify-bash.exitCode`: `0`.
- Git Bash cwd: `/c/DartClaw Bash Step Qualification/workspace with spaces`.
- Quoted relative file: `relative_file=relative-file-ok`.
- Allowlisted environment: `allowlisted_env=allowlist-ok`.
- Basic POSIX pipeline: `posix_result=2`.

The resolved executable path proves Git Bash was selected. The result qualifies native cwd mapping, spaces in the cwd
and filename, quoted relative access, configured environment propagation, version capture, and basic POSIX commands.
It does not claim arbitrary Windows path translation inside command arguments.
