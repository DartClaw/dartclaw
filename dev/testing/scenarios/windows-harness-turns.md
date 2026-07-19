---
profile: native-windows-harness-turns
platform: windows
providers: [claude, codex]
---
# Scenario: Native Windows Harness Turns

Validates one real Claude turn and one real Codex turn through DartClaw's HTTP session API and provider-scoped harness
pool. Run this compatibility check after relevant provider integration or protocol changes; it is not a per-release
publication gate.

## Prerequisites

- Native Windows with Dart, `claude`, and `codex` on `PATH` and authenticated.
- This checkout plus a Windows release ZIP available locally.
- No server already listening on port 3333.

For a Parallels shared-folder checkout, map the share to a drive before running Dart. Dart's native-asset build hooks
reject UNC file URIs with an authority. Codex authentication discovery also needs `HOME` on Windows:

```powershell
New-PSDrive -Name Z -PSProvider FileSystem -Root '\\Mac\Home' -Persist -Scope Global
$env:HOME = $env:USERPROFILE
Set-Location 'Z:\Repos\Libs\dartclaw\dartclaw-public'
dart pub get
```

## Capture Environment

From PowerShell at the checkout root, capture these values with the turn results. Save a local report under
`.agent_temp/` if needed:

```powershell
Get-Date -Format o
[System.Runtime.InteropServices.RuntimeInformation]::OSDescription
[System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
git rev-parse HEAD
git status --short
dart --version
claude --version
codex --version
```

Include the artifact filename, SHA256, release version, and exact source revision so the compatibility result is
traceable. The release workflow does not consume the report.

## Run Each Provider

For `claude`, create `.agent_temp/windows-harness-claude.yaml` from `examples/dev.yaml`. Replace its top-level
`data_dir` and add `host`, then append the provider settings:

```yaml
data_dir: 'C:\Users\<user>\AppData\Local\Temp\dartclaw-windows-harness-claude'
host: 127.0.0.1
agent:
  provider: claude
providers:
  claude:
    executable: claude
    pool_size: 1
```

For `codex`, use a distinct top-level `data_dir`, add the same IPv4 host, and append the equivalent provider config:

```yaml
data_dir: 'C:\Users\<user>\AppData\Local\Temp\dartclaw-windows-harness-codex'
host: 127.0.0.1
agent:
  provider: codex
providers:
  codex:
    executable: codex
    pool_size: 1
    approval: never
    sandbox: danger-full-access
```

Extract the candidate once, then start the selected server from PowerShell:

```powershell
$artifact = Resolve-Path .agent_temp\dartclaw-v<version>-windows-x64.zip
$artifactSha256 = (Get-FileHash -LiteralPath $artifact -Algorithm SHA256).Hash.ToLowerInvariant()
$artifactRoot = '.agent_temp\windows-harness-artifact'
Remove-Item -LiteralPath $artifactRoot -Recurse -Force -ErrorAction SilentlyContinue
Expand-Archive -LiteralPath $artifact -DestinationPath $artifactRoot
$dartclaw = Resolve-Path "$artifactRoot\bin\dartclaw.exe"
& $dartclaw --config .agent_temp\windows-harness-<provider>.yaml serve
```

In another PowerShell window, create a session and send the turn through the server:

```powershell
$session = Invoke-RestMethod -Method Post -Uri http://127.0.0.1:3333/api/sessions `
  -ContentType application/json -Body '{}'
Invoke-WebRequest -Method Post -Uri "http://127.0.0.1:3333/api/sessions/$($session.id)/send" `
  -ContentType application/json -Body '{"message":"Reply with exactly: pong"}'
do {
  Start-Sleep -Milliseconds 250
  $status = Invoke-RestMethod -Uri "http://127.0.0.1:3333/api/sessions/$($session.id)/turn-status"
} while ($status.state -in @('running', 'waiting', 'stuck'))
$messages = Invoke-RestMethod -Uri "http://127.0.0.1:3333/api/sessions/$($session.id)/messages"
$status | ConvertTo-Json -Depth 8
$messages | ConvertTo-Json -Depth 8
```

Stop the server before switching provider so each run proves fresh pool startup and binary lookup.

## Pass Criteria

- Claude: terminal status is `completed`, the provider result has `is_error=false`, and an assistant `pong` is stored.
- Codex: terminal status is `completed`, the wire reaches `turn/completed`, and an assistant `pong` is stored.
- Neither run logs a JSONL/JSON-RPC parse error or stdio transport error.
- Record OS/architecture, source revision or release version, provider versions, timestamp, and both results.
- Record project-trust and MCP startup warnings verbatim; warnings may coexist with a passing turn.

A credential-only failure is recorded as `NOT QUALIFIED`; do not mark the missing provider as passed or reuse a
single-provider result.
