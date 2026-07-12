[CmdletBinding(DefaultParameterSetName = 'Source')]
param(
  [Parameter(Mandatory, ParameterSetName = 'Artifact')]
  [string]$ArtifactPath,
  [Parameter(ParameterSetName = 'Source')]
  [string]$SourceDir,
  [string]$ProviderEvidencePath,
  [string]$EvidencePath,
  [int]$Port = 3340,
  [int]$MaxEvidenceAgeDays = 7,
  [switch]$SkipProviders,
  [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../../..'))
$script:SourceDir = if ($SourceDir) { [IO.Path]::GetFullPath($SourceDir) } else { $script:RepoRoot }
$script:ProviderEvidencePath = if ($ProviderEvidencePath) {
  [IO.Path]::GetFullPath($ProviderEvidencePath)
} else {
  Join-Path $script:RepoRoot 'dev/testing/evidence/windows-harness-turns.md'
}
$script:EvidencePath = if ($EvidencePath) {
  [IO.Path]::GetFullPath($EvidencePath)
} else {
  Join-Path $script:RepoRoot 'dev/testing/evidence/windows-runtime-smoke.md'
}
$script:Layers = [ordered]@{}
$script:Server = $null
$script:ServerStdout = $null
$script:ServerStderr = $null
$script:TempRoot = $null
$script:DataDir = $null
$script:ConfigPath = $null
$script:ExecutionMode = $null
$script:Executable = $null
$script:ArtifactRoot = $null
$script:Version = $null
$script:SourceIdentity = $null
$script:SourceFingerprint = $null
$script:SqliteModule = $null
$script:ProviderVersions = [ordered]@{ claude = 'unavailable'; codex = 'unavailable' }
$script:DartVersion = 'unavailable'
$script:ReloadValue = 65536
$script:CurrentStage = 'environment'

function Set-LayerResult {
  param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][ValidateSet('pass', 'fail', 'skipped')][string]$Result,
    [Parameter(Mandatory)][string]$Detail
  )
  $script:Layers[$Name] = [pscustomobject]@{ Result = $Result; Detail = $Detail }
}

function Resolve-Verdict {
  param(
    [Parameter(Mandatory)][System.Collections.IDictionary]$Layers,
    [Parameter(Mandatory)][bool]$ReplacementEvidenceValid
  )
  $values = @($Layers.Values)
  if (@($values | Where-Object Result -eq 'fail').Count -gt 0) {
    return [pscustomobject]@{ Status = 'failed'; ReleaseReady = $false }
  }
  $skipped = @($Layers.Keys | Where-Object { $Layers[$_].Result -eq 'skipped' })
  $uncovered = @($skipped | Where-Object { $_ -notin @('claude-turn', 'codex-turn') -or -not $ReplacementEvidenceValid })
  if ($uncovered.Count -gt 0) {
    return [pscustomobject]@{ Status = 'incomplete'; ReleaseReady = $false }
  }
  return [pscustomobject]@{ Status = 'supported'; ReleaseReady = $true }
}

function Invoke-SelfTest {
  $allPass = [ordered]@{ a = [pscustomobject]@{ Result = 'pass' }; b = [pscustomobject]@{ Result = 'pass' } }
  $providerSkips = [ordered]@{
    a = [pscustomobject]@{ Result = 'pass' }
    'claude-turn' = [pscustomobject]@{ Result = 'skipped' }
    'codex-turn' = [pscustomobject]@{ Result = 'skipped' }
  }
  $oneFailure = [ordered]@{ a = [pscustomobject]@{ Result = 'pass' }; b = [pscustomobject]@{ Result = 'fail' } }
  $cases = @(
    @{ Name = 'all pass'; Layers = $allPass; Evidence = $false; Status = 'supported'; Ready = $true },
    @{ Name = 'provider skips with matching evidence'; Layers = $providerSkips; Evidence = $true; Status = 'supported'; Ready = $true },
    @{ Name = 'provider skips without evidence'; Layers = $providerSkips; Evidence = $false; Status = 'incomplete'; Ready = $false },
    @{ Name = 'executed failure'; Layers = $oneFailure; Evidence = $true; Status = 'failed'; Ready = $false }
  )
  foreach ($case in $cases) {
    $actual = Resolve-Verdict -Layers $case.Layers -ReplacementEvidenceValid $case.Evidence
    if ($actual.Status -ne $case.Status -or $actual.ReleaseReady -ne $case.Ready) {
      throw "Verdict self-test failed: $($case.Name)."
    }
  }

  $testRoot = Join-Path ([IO.Path]::GetTempPath()) "dartclaw-windows-smoke-self-test-$([guid]::NewGuid().ToString('N'))"
  New-Item -ItemType Directory -Path $testRoot | Out-Null
  $priorMode = $script:ExecutionMode
  $priorIdentity = $script:SourceIdentity
  $priorFingerprint = $script:SourceFingerprint
  $priorVersion = $script:Version
  $priorVersions = $script:ProviderVersions
  try {
    $script:ExecutionMode = 'source'
    $script:SourceIdentity = '0123456789abcdef'
    $script:SourceFingerprint = 'feedfacefeedfacefeedfacefeedfacefeedfacefeedfacefeedfacefeedface'
    $script:ProviderVersions = [ordered]@{ claude = '2.1.207 (Claude Code)'; codex = 'codex-cli 0.139.0' }
    $fresh = [DateTimeOffset]::Now.ToString('o')
    $stale = [DateTimeOffset]::Now.AddDays(-($MaxEvidenceAgeDays + 1)).ToString('o')
    $template = @'
**Status**: QUALIFIED
**Run timestamps**: Claude `{0}`; Codex `{1}`
**Host**: Windows 11, x64
**DartClaw under test**: source 0123456789abcdef
**Source fingerprint**: feedfacefeedfacefeedfacefeedfacefeedfacefeedfacefeedfacefeedface
**Claude**: Claude Code 2.1.207
**Codex**: codex-cli 0.139.0
## Claude Result
Qualification: **PASS**
## Codex Result
Qualification: **PASS**
'@
    $validPath = Join-Path $testRoot 'valid.md'
    [IO.File]::WriteAllText($validPath, ($template -f $fresh, $fresh))
    $validEvidence = Test-ProviderEvidence -Path $validPath
    if (-not $validEvidence.Valid) { throw "matching evidence was rejected: $($validEvidence.Detail)" }
    $stalePath = Join-Path $testRoot 'stale-provider.md'
    [IO.File]::WriteAllText($stalePath, ($template -f $stale, $fresh))
    if ((Test-ProviderEvidence -Path $stalePath).Valid) { throw 'one fresh timestamp covered a stale provider' }
    $mismatchPath = Join-Path $testRoot 'mismatched-version.md'
    [IO.File]::WriteAllText($mismatchPath, (($template -f $fresh, $fresh).Replace('0.139.0', '0.138.0')))
    if ((Test-ProviderEvidence -Path $mismatchPath).Valid) { throw 'provider version mismatch was accepted' }
    $providerSuperstringPath = Join-Path $testRoot 'provider-version-superstring.md'
    [IO.File]::WriteAllText(
      $providerSuperstringPath,
      (($template -f $fresh, $fresh).Replace('**Claude**: Claude Code 2.1.207', '**Claude**: Claude Code 12.1.207'))
    )
    if ((Test-ProviderEvidence -Path $providerSuperstringPath).Valid) { throw 'provider version superstring was accepted' }
    $wrongIdentityPath = Join-Path $testRoot 'wrong-identity.md'
    $wrongIdentity = ($template -f $fresh, $fresh).Replace(
      '**DartClaw under test**: source 0123456789abcdef',
      "**DartClaw under test**: source deadbeef`nExpected elsewhere: 0123456789abcdef"
    )
    [IO.File]::WriteAllText($wrongIdentityPath, $wrongIdentity)
    if ((Test-ProviderEvidence -Path $wrongIdentityPath).Valid) { throw 'stray source revision satisfied identity matching' }
    $sourceSuperstringPath = Join-Path $testRoot 'source-revision-superstring.md'
    [IO.File]::WriteAllText(
      $sourceSuperstringPath,
      (($template -f $fresh, $fresh).Replace(
          '**DartClaw under test**: source 0123456789abcdef',
          '**DartClaw under test**: source f0123456789abcdef0'
        ))
    )
    if ((Test-ProviderEvidence -Path $sourceSuperstringPath).Valid) { throw 'source revision superstring was accepted' }
    $wrongFingerprintPath = Join-Path $testRoot 'wrong-fingerprint.md'
    $zeroFingerprint = ('0' * 64) -join ''
    [IO.File]::WriteAllText(
      $wrongFingerprintPath,
      (($template -f $fresh, $fresh).Replace($script:SourceFingerprint, $zeroFingerprint))
    )
    if ((Test-ProviderEvidence -Path $wrongFingerprintPath).Valid) { throw 'source fingerprint mismatch was accepted' }
    $script:ExecutionMode = 'artifact'
    $script:Version = '0.20.1'
    $artifactMismatch = ($template -f $fresh, $fresh).Replace(
      '**DartClaw under test**: source 0123456789abcdef',
      "**DartClaw under test**: release artifact 10.20.10`nExpected elsewhere: 0.20.1"
    )
    $artifactMismatchPath = Join-Path $testRoot 'wrong-artifact-version.md'
    [IO.File]::WriteAllText($artifactMismatchPath, $artifactMismatch)
    if ((Test-ProviderEvidence -Path $artifactMismatchPath).Valid) { throw 'stray release version satisfied identity matching' }
    if ((Test-ProviderEvidence -Path (Join-Path $testRoot 'absent.md')).Valid) { throw 'absent evidence was accepted' }
  } finally {
    $script:ExecutionMode = $priorMode
    $script:SourceIdentity = $priorIdentity
    $script:SourceFingerprint = $priorFingerprint
    $script:Version = $priorVersion
    $script:ProviderVersions = $priorVersions
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
  Write-Host 'Windows runtime smoke verdict table: PASS'
}

function ConvertTo-YamlSingleQuoted {
  param([Parameter(Mandatory)][string]$Value)
  return "'$($Value.Replace("'", "''"))'"
}

function Write-SmokeConfig {
  param([Parameter(Mandatory)][ValidateSet('claude', 'codex')][string]$Provider)
  $dataDir = ConvertTo-YamlSingleQuoted $script:DataDir
  $config = @"
data_dir: $dataDir
host: 127.0.0.1
port: $Port
dev_mode: true

gateway:
  auth_mode: none
  reload:
    mode: auto
    debounce_ms: 100

guards:
  enabled: false

search:
  backend: fts5

context:
  max_result_bytes: $script:ReloadValue

scheduling:
  heartbeat:
    enabled: false
  jobs: []

workspace:
  git_sync:
    enabled: false

logging:
  level: FINE

agent:
  provider: $Provider

providers:
  claude:
    executable: claude
    pool_size: 1
    credentials_required: false
  codex:
    executable: codex
    pool_size: 1
    credentials_required: false
    approval: never
    sandbox: danger-full-access
"@
  $tempConfig = "$script:ConfigPath.tmp"
  [IO.File]::WriteAllText($tempConfig, $config, [Text.UTF8Encoding]::new($false))
  if (Test-Path -LiteralPath $script:ConfigPath) {
    Move-Item -LiteralPath $tempConfig -Destination $script:ConfigPath -Force
  } else {
    Move-Item -LiteralPath $tempConfig -Destination $script:ConfigPath
  }
}

function Invoke-DartClaw {
  param([Parameter(Mandatory)][string[]]$Arguments)
  Push-Location $(if ($script:ExecutionMode -eq 'source') { $script:SourceDir } else { $script:DataDir })
  $priorErrorAction = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    if ($script:ExecutionMode -eq 'source') {
      $allArguments = @('run', 'dartclaw_cli:dartclaw') + $Arguments
      $output = & dart @allArguments 2>&1
    } else {
      $output = & $script:Executable @Arguments 2>&1
    }
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
      throw "DartClaw command failed ($exitCode): $($output -join [Environment]::NewLine)"
    }
    return @($output | ForEach-Object ToString)
  } finally {
    $ErrorActionPreference = $priorErrorAction
    Pop-Location
  }
}

function ConvertTo-ProcessArgument {
  param([Parameter(Mandatory)][string]$Value)
  return '"' + $Value.Replace('"', '\"') + '"'
}

function Start-SmokeServer {
  param([Parameter(Mandatory)][ValidateSet('claude', 'codex')][string]$Provider)
  Stop-SmokeServer
  $script:ServerStdout = Join-Path $script:TempRoot "$Provider-server.stdout.log"
  $script:ServerStderr = Join-Path $script:TempRoot "$Provider-server.stderr.log"
  Remove-Item $script:ServerStdout, $script:ServerStderr -Force -ErrorAction SilentlyContinue

  $workingDirectory = if ($script:ExecutionMode -eq 'source') { $script:SourceDir } else { $script:DataDir }
  if ($script:ExecutionMode -eq 'source') {
    $filePath = 'dart.exe'
    $arguments = @('run', 'dartclaw_cli:dartclaw', '--config', $script:ConfigPath, 'serve')
  } else {
    $filePath = $script:Executable
    $arguments = @('--config', $script:ConfigPath, 'serve')
  }
  $argumentLine = ($arguments | ForEach-Object { ConvertTo-ProcessArgument $_ }) -join ' '
  $script:Server = Start-Process -FilePath $filePath -ArgumentList $argumentLine -WorkingDirectory $workingDirectory `
    -RedirectStandardOutput $script:ServerStdout -RedirectStandardError $script:ServerStderr -PassThru
}

function Stop-SmokeServer {
  if ($null -ne $script:Server) {
    if (-not $script:Server.HasExited) {
      Stop-Process -Id $script:Server.Id -Force -ErrorAction SilentlyContinue
      $script:Server.WaitForExit()
    }
    $script:Server = $null
  }
}

function Wait-SmokeServer {
  $deadline = (Get-Date).AddMinutes(3)
  do {
    if ($script:Server.HasExited) {
      $stderr = if (Test-Path $script:ServerStderr) { Get-Content $script:ServerStderr -Raw } else { '' }
      throw "server exited early with code $($script:Server.ExitCode): $stderr"
    }
    try {
      $health = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/health" -TimeoutSec 3
      if ($health.status -eq 'healthy') { return $health }
    } catch {
      Start-Sleep -Milliseconds 250
    }
  } while ((Get-Date) -lt $deadline)
  throw 'server did not report healthy within three minutes'
}

function Get-CommandVersion {
  param([Parameter(Mandatory)][string]$Command)
  if ($null -eq (Get-Command $Command -ErrorAction SilentlyContinue)) { return 'unavailable' }
  $output = & $Command --version 2>&1
  if ($LASTEXITCODE -ne 0) { return 'unavailable' }
  return (($output | Select-Object -First 1).ToString()).Trim()
}

function Get-SourceFingerprint {
  $runtimePaths = @('apps', 'packages', 'pubspec.yaml', 'pubspec.lock')
  $safeDirectory = "safe.directory=$script:SourceDir"
  $priorErrorAction = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    $diffArguments = @('-c', $safeDirectory, '-C', $script:SourceDir, 'diff', '--binary', 'HEAD', '--') + $runtimePaths
    $diff = & git @diffArguments 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'unable to fingerprint tracked runtime source changes' }
    $untrackedArguments = @('-c', $safeDirectory, '-C', $script:SourceDir, 'ls-files', '--others', '--exclude-standard', '--') + $runtimePaths
    $untracked = @(& git @untrackedArguments 2>$null)
    if ($LASTEXITCODE -ne 0) { throw 'unable to fingerprint untracked runtime source files' }
  } finally {
    $ErrorActionPreference = $priorErrorAction
  }

  $material = [Text.StringBuilder]::new()
  [void]$material.Append(($diff -join "`n"))
  foreach ($relativePath in @($untracked | ForEach-Object ToString | Sort-Object)) {
    $filePath = Join-Path $script:SourceDir $relativePath
    [void]$material.Append("`nuntracked:${relativePath}:")
    [void]$material.Append((Get-FileHash -LiteralPath $filePath -Algorithm SHA256).Hash.ToLowerInvariant())
  }
  $bytes = [Text.UTF8Encoding]::new($false).GetBytes($material.ToString())
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
  } finally {
    $sha.Dispose()
  }
}

function Test-ClaudeAuthentication {
  if ($SkipProviders -or $script:ProviderVersions.claude -eq 'unavailable') { return $false }
  try {
    $raw = & claude auth status 2>$null
    if ($LASTEXITCODE -ne 0) { return $false }
    return (($raw -join "`n") | ConvertFrom-Json).loggedIn -eq $true
  } catch {
    return $false
  }
}

function Test-CodexAuthentication {
  if ($SkipProviders -or $script:ProviderVersions.codex -eq 'unavailable') { return $false }
  $priorErrorAction = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    $raw = & codex login status 2>&1
    return $LASTEXITCODE -eq 0 -and ($raw -join "`n") -match 'Logged in'
  } catch {
    return $false
  } finally {
    $ErrorActionPreference = $priorErrorAction
  }
}

function Invoke-HarnessTurn {
  param([Parameter(Mandatory)][ValidateSet('claude', 'codex')][string]$Provider)
  $session = Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:$Port/api/sessions" `
    -ContentType 'application/json' -Body '{}'
  Invoke-WebRequest -UseBasicParsing -Method Post -Uri "http://127.0.0.1:$Port/api/sessions/$($session.id)/send" `
    -ContentType 'application/json' -Body '{"message":"Reply with exactly: pong"}' | Out-Null
  $deadline = (Get-Date).AddMinutes(5)
  do {
    Start-Sleep -Milliseconds 250
    $status = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/api/sessions/$($session.id)/turn-status"
  } while ($status.state -in @('running', 'waiting', 'stuck') -and (Get-Date) -lt $deadline)
  if ($status.state -ne 'completed') {
    throw "$Provider turn ended in state '$($status.state)'"
  }
  $messages = @(Invoke-RestMethod -Uri "http://127.0.0.1:$Port/api/sessions/$($session.id)/messages")
  $assistant = @($messages | Where-Object { $_.role -eq 'assistant' -and $_.content.Trim() -eq 'pong' })
  if ($assistant.Count -eq 0) {
    throw "$Provider turn completed without a stored assistant pong"
  }
  return "session $($session.id), turn $($status.turn_id), completed with stored assistant pong"
}

function Test-ProviderEvidence {
  param([Parameter(Mandatory)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return [pscustomobject]@{ Valid = $false; Detail = 'provider evidence file is absent' }
  }
  try {
    $content = Get-Content -LiteralPath $Path -Raw
  } catch {
    return [pscustomobject]@{ Valid = $false; Detail = "provider evidence is unreadable: $($_.Exception.Message)" }
  }
  $failures = [Collections.Generic.List[string]]::new()
  if ($content -notmatch '(?m)^\*\*Status\*\*:\s*QUALIFIED\s*$') { $failures.Add('status is not QUALIFIED') }
  if ($content -notmatch '(?m)^\*\*Host\*\*:\s*.*Windows.*(?:x64|ARM64)') { $failures.Add('Windows OS/architecture missing') }
  $identity = [regex]::Match($content, '(?mi)^\*\*DartClaw under test\*\*:\s*(.+)$').Groups[1].Value
  if ($script:ExecutionMode -eq 'source') {
    $sourcePattern = '(?i)(?<![0-9a-f])' + [regex]::Escape($script:SourceIdentity) + '(?![0-9a-f])'
    if (-not $identity -or $identity -notmatch $sourcePattern) {
      $failures.Add('DartClaw source revision does not match')
    }
    $fingerprintMatch = [regex]::Match($content, '(?mi)^\*\*Source fingerprint\*\*:\s*([0-9a-f]{64})\s*$')
    if (-not $fingerprintMatch.Success -or $fingerprintMatch.Groups[1].Value -ne $script:SourceFingerprint) {
      $failures.Add('DartClaw runtime source fingerprint does not match')
    }
  } else {
    $releasePattern = '(?<![0-9A-Za-z.-])' + [regex]::Escape($script:Version) + '(?![0-9A-Za-z.-])'
    if (-not $identity -or $identity -notmatch 'release artifact' -or $identity -notmatch $releasePattern) {
      $failures.Add('DartClaw release version does not match')
    }
  }

  foreach ($provider in @('Claude', 'Codex')) {
    $version = $script:ProviderVersions[$provider.ToLowerInvariant()]
    $versionNumber = [regex]::Match($version, '\d+(?:\.\d+){1,3}').Value
    $section = [regex]::Match(
      $content,
      "(?ms)^## $provider Result\s*(.*?)(?=^## |\z)"
    ).Groups[1].Value
    if (-not $section -or $section -notmatch 'Qualification:\s*\*\*PASS\*\*') {
      $failures.Add("$provider result is not PASS")
    }
    $metadata = [regex]::Match($content, "(?mi)^\*\*$provider\*\*:\s*(.+)$").Groups[1].Value
    $metadataVersion = [regex]::Match($metadata, '\d+(?:\.\d+){1,3}').Value
    if (-not $versionNumber -or -not $metadata -or $metadataVersion -ne $versionNumber) {
      $failures.Add("$provider version does not match")
    }
  }

  foreach ($provider in @('Claude', 'Codex')) {
    $timestampMatch = [regex]::Match(
      $content,
      ('(?mi)^\*\*Run timestamps\*\*:.*{0}\s+`([^`]+)`' -f [regex]::Escape($provider))
    )
    $timestamp = $null
    try {
      if ($timestampMatch.Success) { $timestamp = [DateTimeOffset]::Parse($timestampMatch.Groups[1].Value) }
    } catch {}
    if ($null -eq $timestamp -or $timestamp -lt [DateTimeOffset]::Now.AddDays(-$MaxEvidenceAgeDays)) {
      $failures.Add("$provider evidence is older than $MaxEvidenceAgeDays days or lacks its timestamp")
    }
  }
  if ($failures.Count -gt 0) {
    return [pscustomobject]@{ Valid = $false; Detail = ($failures -join '; ') }
  }
  return [pscustomobject]@{ Valid = $true; Detail = "matching both-provider evidence: $Path" }
}

function ConvertTo-MarkdownCell {
  param([Parameter(Mandatory)][string]$Value)
  return $Value.Replace('|', '\|').Replace("`r", ' ').Replace("`n", ' ').Trim()
}

function Write-EvidenceReport {
  param(
    [Parameter(Mandatory)]$Verdict,
    [Parameter(Mandatory)]$ProviderEvidence
  )
  $failed = @($script:Layers.Keys | Where-Object { $script:Layers[$_].Result -eq 'fail' })
  $skipped = @($script:Layers.Keys | Where-Object { $script:Layers[$_].Result -eq 'skipped' })
  $replacement = @(if ($ProviderEvidence.Valid) {
    $skipped | Where-Object { $_ -in @('claude-turn', 'codex-turn') }
  })
  $lines = [Collections.Generic.List[string]]::new()
  $lines.Add('# Windows Runtime Smoke Evidence')
  $lines.Add('')
  $lines.Add("**Run timestamp**: $([DateTimeOffset]::Now.ToString('o'))")
  $lines.Add("**Overall status**: $($Verdict.Status)")
  $lines.Add("**Release ready**: $($Verdict.ReleaseReady.ToString().ToLowerInvariant())")
  $lines.Add("**OS/architecture**: $([Runtime.InteropServices.RuntimeInformation]::OSDescription.Trim()), $([Runtime.InteropServices.RuntimeInformation]::OSArchitecture)")
  $lines.Add("**Dart SDK**: $script:DartVersion")
  $lines.Add("**DartClaw version**: $script:Version")
  $lines.Add("**Artifact/source under test**: $script:SourceIdentity ($script:ExecutionMode)")
  $lines.Add("**Source fingerprint**: $(if ($script:SourceFingerprint) { $script:SourceFingerprint } else { 'not applicable' })")
  $lines.Add("**Claude**: $($script:ProviderVersions.claude)")
  $lines.Add("**Codex**: $($script:ProviderVersions.codex)")
  $lines.Add("**Loaded SQLite module**: $script:SqliteModule")
  $lines.Add("**Replacement provider evidence**: $($ProviderEvidence.Detail)")
  $lines.Add('')
  $lines.Add('## Layer Results')
  $lines.Add('')
  $lines.Add('| Layer | Result | Detail |')
  $lines.Add('|---|---|---|')
  foreach ($name in $script:Layers.Keys) {
    $layer = $script:Layers[$name]
    $lines.Add("| $name | $($layer.Result) | $(ConvertTo-MarkdownCell $layer.Detail) |")
  }
  $lines.Add('')
  $lines.Add('## Verdict Inputs')
  $lines.Add('')
  $lines.Add("- Failed layers: $(if (@($failed).Count) { $failed -join ', ' } else { 'none' })")
  $lines.Add("- Skipped layers: $(if (@($skipped).Count) { $skipped -join ', ' } else { 'none' })")
  $lines.Add("- Replacement-evidence-backed layers: $(if (@($replacement).Count) { $replacement -join ', ' } else { 'none' })")
  $lines.Add('- File-watch mechanism: gateway.reload.mode `auto`; process identity preserved by the config-reload layer.')
  $lines.Add('')
  $lines.Add('A `failed` or `incomplete` verdict is not Windows release-ready and must not be reported as supported.')
  $directory = Split-Path -Parent $script:EvidencePath
  New-Item -ItemType Directory -Path $directory -Force | Out-Null
  [IO.File]::WriteAllLines($script:EvidencePath, $lines, [Text.UTF8Encoding]::new($false))
}

if ($SelfTest) {
  Invoke-SelfTest
  exit 0
}

if (-not [Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {
  throw 'Windows runtime smoke must run on native Windows.'
}

$script:TempRoot = Join-Path ([IO.Path]::GetTempPath()) "dartclaw-windows-smoke-$([guid]::NewGuid().ToString('N'))"
$script:DataDir = Join-Path $script:TempRoot 'data'
$script:ConfigPath = Join-Path $script:TempRoot 'dartclaw.yaml'
New-Item -ItemType Directory -Path (Join-Path $script:DataDir 'workspace') -Force | Out-Null

try {
  $script:DartVersion = Get-CommandVersion 'dart'
  if ($PSCmdlet.ParameterSetName -eq 'Artifact') {
    $script:CurrentStage = 'artifact-layout'
    $resolvedArtifact = [IO.Path]::GetFullPath($ArtifactPath)
    if (-not (Test-Path -LiteralPath $resolvedArtifact -PathType Leaf)) { throw "artifact not found: $resolvedArtifact" }
    if ([IO.Path]::GetFileName($resolvedArtifact) -notmatch '^dartclaw-v(.+)-windows-x64\.zip$') {
      throw 'artifact name must match dartclaw-v<version>-windows-x64.zip'
    }
    $script:Version = $Matches[1]
    $script:ArtifactRoot = Join-Path $script:TempRoot 'artifact'
    Expand-Archive -LiteralPath $resolvedArtifact -DestinationPath $script:ArtifactRoot
    foreach ($relative in @('VERSION', 'bin/dartclaw.exe', 'lib/sqlite3.dll')) {
      if (-not (Test-Path -LiteralPath (Join-Path $script:ArtifactRoot $relative) -PathType Leaf)) {
        throw "artifact layout missing $relative"
      }
    }
    $bundledVersion = (Get-Content -LiteralPath (Join-Path $script:ArtifactRoot 'VERSION') -Raw).Trim()
    if ($bundledVersion -ne $script:Version) {
      throw "artifact VERSION '$bundledVersion' does not match archive version '$script:Version'"
    }
    if (Test-Path -LiteralPath (Join-Path $script:ArtifactRoot 'share')) { throw 'artifact layout contains obsolete share/ sidecar' }
    $artifactPrefix = $script:ArtifactRoot.TrimEnd('\') + '\'
    $actualFiles = @(Get-ChildItem -LiteralPath $script:ArtifactRoot -Recurse -File | ForEach-Object {
      $_.FullName.Substring($artifactPrefix.Length).Replace('\', '/')
    })
    $unexpected = @($actualFiles | Where-Object { $_ -notin @('VERSION', 'bin/dartclaw.exe', 'lib/sqlite3.dll') })
    if ($unexpected.Count -gt 0) { throw "artifact layout has unexpected files: $($unexpected -join ', ')" }
    $script:ExecutionMode = 'artifact'
    $script:Executable = Join-Path $script:ArtifactRoot 'bin/dartclaw.exe'
    $script:SqliteModule = Join-Path $script:ArtifactRoot 'lib/sqlite3.dll'
    $script:SourceIdentity = "release $script:Version"
  } else {
    $script:CurrentStage = 'source-setup'
    if (-not (Test-Path -LiteralPath (Join-Path $script:SourceDir 'apps/dartclaw_cli') -PathType Container)) {
      throw "source checkout not found: $script:SourceDir"
    }
    $script:ExecutionMode = 'source'
    $script:Executable = 'dart.exe'
    $script:SqliteModule = Join-Path $script:SourceDir '.dart_tool/lib/sqlite3.dll'
    if (-not (Test-Path -LiteralPath $script:SqliteModule -PathType Leaf)) {
      throw "source SQLite module not found: $script:SqliteModule (run dart pub get on Windows)"
    }
    $script:SourceIdentity = (& git -c "safe.directory=$script:SourceDir" -C $script:SourceDir rev-parse HEAD | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'unable to resolve source revision' }
    $script:SourceFingerprint = Get-SourceFingerprint
    $versionLine = Select-String -LiteralPath (Join-Path $script:SourceDir 'packages/dartclaw_server/lib/src/version.dart') `
      -Pattern "dartclawVersion = '([^']+)'" | Select-Object -First 1
    $script:Version = $versionLine.Matches[0].Groups[1].Value
  }

  $env:HOME = $env:USERPROFILE
  $script:CurrentStage = 'provider-preflight'
  $script:ProviderVersions.claude = Get-CommandVersion 'claude'
  $script:ProviderVersions.codex = Get-CommandVersion 'codex'
  $claudeAuthenticated = Test-ClaudeAuthentication
  $codexAuthenticated = Test-CodexAuthentication

  if ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq [Runtime.InteropServices.Architecture]::X64) {
    Set-LayerResult 'windows-x64-host' 'pass' 'native Windows x64 host'
  } else {
    Set-LayerResult 'windows-x64-host' 'skipped' `
      "$([Runtime.InteropServices.RuntimeInformation]::OSArchitecture) host cannot qualify x64 artifact, SQLite, installer, or core runtime"
  }

  $seedTimestamp = Get-Date -Format 'yyyy-MM-dd HH:mm'
  $seed = "## smoke`r`n- [$seedTimestamp] windowsfts5smokeseed layered runtime proof`r`n"
  [IO.File]::WriteAllText((Join-Path $script:DataDir 'workspace/MEMORY.md'), $seed, [Text.UTF8Encoding]::new($false))
  Write-SmokeConfig -Provider claude
  $script:CurrentStage = 'fts5-index'
  Invoke-DartClaw -Arguments @('--config', $script:ConfigPath, 'rebuild-index') | Out-Null

  $script:CurrentStage = 'sqlite-module'
  $sqliteOutput = Invoke-DartClaw -Arguments @('release-sqlite-check', '--expected-module', $script:SqliteModule)
  $reportedModule = @($sqliteOutput | Where-Object { $_ -match '^SQLite module:\s*(.+)$' } | Select-Object -First 1)
  if ($reportedModule.Count -eq 0) { throw 'SQLite identity check did not report the loaded module path' }
  $script:SqliteModule = ([regex]::Match($reportedModule[0], '^SQLite module:\s*(.+)$')).Groups[1].Value.Trim()

  $script:CurrentStage = 'server-startup'
  Start-SmokeServer -Provider claude
  try {
    $health = Wait-SmokeServer
    Set-LayerResult 'server-startup' 'pass' "healthy on 127.0.0.1:$Port; process $($script:Server.Id); worker $($health.worker_state)"
  } catch {
    Set-LayerResult 'server-startup' 'fail' $_.Exception.Message
  }

  if ($script:Layers['server-startup'].Result -eq 'pass') {
    try {
      $web = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$Port/" -MaximumRedirection 10
      if ($web.StatusCode -ne 200 -or $web.Content -notmatch 'DartClaw') { throw 'root page did not render DartClaw HTML' }
      Set-LayerResult 'web-ui' 'pass' "HTTP $($web.StatusCode), final URI $($web.BaseResponse.ResponseUri.AbsoluteUri)"
    } catch {
      Set-LayerResult 'web-ui' 'fail' $_.Exception.Message
    }

    try {
      $search = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$Port/knowledge?q=windowsfts5smokeseed&layer=memory"
      if ($search.StatusCode -ne 200 -or $search.Content -notmatch 'layered runtime proof') {
        throw 'live FTS5 query did not return the seeded record'
      }
      Set-LayerResult 'fts5-search' 'pass' "MATCH returned windowsfts5smokeseed; loaded module $script:SqliteModule"
    } catch {
      Set-LayerResult 'fts5-search' 'fail' $_.Exception.Message
    }

    try {
      $originalPid = $script:Server.Id
      $script:ReloadValue++
      Write-SmokeConfig -Provider claude
      $deadline = (Get-Date).AddSeconds(20)
      do {
        Start-Sleep -Milliseconds 200
        $stdoutLog = if (Test-Path $script:ServerStdout) { Get-Content $script:ServerStdout -Raw } else { '' }
        $stderrLog = if (Test-Path $script:ServerStderr) { Get-Content $script:ServerStderr -Raw } else { '' }
        $log = "$stdoutLog`n$stderrLog"
        $applied = $log -match 'ReloadTriggerService: reload applied.*changed sections: context\.\*'
      } while (-not $applied -and (Get-Date) -lt $deadline)
      if (-not $applied) {
        $tail = (($log -split "`r?`n") | Select-Object -Last 12) -join '; '
        throw "file-watch reload did not log an applied context change; log tail: $tail"
      }
      if ($script:Server.HasExited -or $script:Server.Id -ne $originalPid) { throw 'server process changed during reload' }
      $null = Wait-SmokeServer
      Set-LayerResult 'config-reload' 'pass' "file-watch (auto) applied context.*; process $originalPid remained healthy"
    } catch {
      Set-LayerResult 'config-reload' 'fail' $_.Exception.Message
    }
  } else {
    foreach ($layer in @('web-ui', 'fts5-search', 'config-reload')) {
      Set-LayerResult $layer 'skipped' 'server-startup failed'
    }
  }

  if ($claudeAuthenticated -and $script:Layers['server-startup'].Result -eq 'pass') {
    try {
      $detail = Invoke-HarnessTurn -Provider claude
      Set-LayerResult 'claude-turn' 'pass' "$detail; $($script:ProviderVersions.claude)"
    } catch {
      Set-LayerResult 'claude-turn' 'fail' $_.Exception.Message
    }
  } else {
    $reason = if ($SkipProviders) { 'provider execution disabled' } elseif (-not $claudeAuthenticated) { 'credentials unavailable' } else { 'server unavailable' }
    Set-LayerResult 'claude-turn' 'skipped' $reason
  }

  Stop-SmokeServer
  if ($codexAuthenticated) {
    try {
      Write-SmokeConfig -Provider codex
      Start-SmokeServer -Provider codex
      $null = Wait-SmokeServer
      $detail = Invoke-HarnessTurn -Provider codex
      Set-LayerResult 'codex-turn' 'pass' "$detail; $($script:ProviderVersions.codex)"
    } catch {
      Set-LayerResult 'codex-turn' 'fail' $_.Exception.Message
    }
  } else {
    $reason = if ($SkipProviders) { 'provider execution disabled' } else { 'credentials unavailable' }
    Set-LayerResult 'codex-turn' 'skipped' $reason
  }

  $script:CurrentStage = 'provider-evidence'
  $providerEvidence = Test-ProviderEvidence -Path $script:ProviderEvidencePath
  $verdict = Resolve-Verdict -Layers $script:Layers -ReplacementEvidenceValid $providerEvidence.Valid
  $script:CurrentStage = 'evidence-report'
  Write-EvidenceReport -Verdict $verdict -ProviderEvidence $providerEvidence
  Write-Host "Windows runtime smoke: $($verdict.Status); release-ready=$($verdict.ReleaseReady.ToString().ToLowerInvariant())"
  Write-Host "Evidence: $script:EvidencePath"
  switch ($verdict.Status) {
    'supported' { exit 0 }
    'failed' { exit 1 }
    default { exit 2 }
  }
} catch {
  $failedStage = $script:CurrentStage
  Set-LayerResult $failedStage 'fail' $_.Exception.Message
  foreach ($layer in @('server-startup', 'web-ui', 'fts5-search', 'config-reload', 'claude-turn', 'codex-turn')) {
    if (-not $script:Layers.Contains($layer)) { Set-LayerResult $layer 'skipped' "blocked by $failedStage" }
  }
  if (-not $script:Layers.Contains('windows-x64-host')) {
    $architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture
    $hostResult = if ($architecture -eq [Runtime.InteropServices.Architecture]::X64) { 'pass' } else { 'skipped' }
    Set-LayerResult 'windows-x64-host' $hostResult "$architecture host"
  }
  if (-not $script:Version) { $script:Version = 'unresolved' }
  if (-not $script:SourceIdentity) { $script:SourceIdentity = 'unresolved' }
  if (-not $script:SqliteModule) { $script:SqliteModule = 'unresolved' }
  $providerEvidence = [pscustomobject]@{ Valid = $false; Detail = "not evaluated because $failedStage failed" }
  $verdict = [pscustomobject]@{ Status = 'failed'; ReleaseReady = $false }
  Write-EvidenceReport -Verdict $verdict -ProviderEvidence $providerEvidence
  Write-Host "Windows runtime smoke: failed at $failedStage; release-ready=false"
  Write-Host "Evidence: $script:EvidencePath"
  exit 1
} finally {
  Stop-SmokeServer
  if ($script:TempRoot -and (Test-Path -LiteralPath $script:TempRoot)) {
    Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}
