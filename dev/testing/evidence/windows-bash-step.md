# Native Windows Bash-Step Qualification Evidence

**Status**: QUALIFIED

**Run timestamp**: `2026-07-14T06:08:56.7025763+00:00`
**Qualification workflow**: [GitHub Actions run 29310391226](https://github.com/DartClaw/dartclaw/actions/runs/29310391226)
**Host**: Microsoft Windows 10.0.26100, native X64
**Source revision**: `6c4511409ba1b35e58d781f4dd4b111ebe25b0cb`
**Artifact/source under test**: source checkout at `D:\a\dartclaw\dartclaw`
**Dart**: 3.12.0 stable, `windows_x64`
**Resolved Bash**: `C:\Program Files\Git\bin\bash.exe`
**Git Bash**: GNU bash 5.3.9(1)-release, `x86_64-pc-cygwin`
**Native cwd**: `C:\DartClaw Bash Step Qualification\workspace with spaces`
**Workflow run**: `c64b4bf8-471f-4750-8807-6f9a36adedcc`

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

## Timeout Boundary

The same native-x64 run passed nine focused Bash-selection, timeout-state, and direct-root tests plus all 14 ownership
tests. The two observable-effect tests that require descendant containment were explicitly skipped as unsupported on
native Windows; they are not counted as passing qualification. DartClaw hard-terminates a still-running directly
managed Git Bash root, never retargets an exited PID, and does not claim descendant containment. If cleanup cannot be
confirmed, later Bash steps remain blocked until DartClaw restarts. Use POSIX for commands requiring process-tree
containment.
