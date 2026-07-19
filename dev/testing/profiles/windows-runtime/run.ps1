[CmdletBinding(DefaultParameterSetName = 'Source')]
param(
  [Parameter(Mandatory, ParameterSetName = 'Artifact')]
  [string]$ArtifactPath,
  [Parameter(ParameterSetName = 'Source')]
  [string]$SourceDir,
  [string]$EvidencePath,
  [int]$Port = 3340,
  [switch]$SkipProviders,
  [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../../..'))
$script:SourceDir = if ($SourceDir) { [IO.Path]::GetFullPath($SourceDir) } else { $script:RepoRoot }
$script:EvidencePath = if ($EvidencePath) {
  [IO.Path]::GetFullPath($EvidencePath)
} else {
  Join-Path $script:RepoRoot '.agent_temp/windows-runtime-smoke.md'
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
$script:ProviderStubPath = $null
$script:OriginalPath = $env:PATH
$script:OriginalHomeWasSet = Test-Path Env:HOME
$script:OriginalHome = if ($script:OriginalHomeWasSet) { (Get-Item Env:HOME).Value } else { $null }
$script:ArtifactRoot = $null
$script:Version = $null
$script:SourceIdentity = $null
$script:SourceFingerprint = $null
$script:ArtifactSha256 = $null
$script:SqliteModule = $null
$script:ProviderVersions = [ordered]@{ claude = 'unavailable'; codex = 'unavailable' }
$script:DartVersion = 'unavailable'
$script:ReloadValue = 65536
$script:CurrentStage = 'environment'
$script:RequiredLayers = @(
  'windows-x64-host',
  'server-startup',
  'web-ui',
  'fts5-search',
  'config-reload'
)

function Set-LayerResult {
  param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][ValidateSet('pass', 'fail', 'skipped')][string]$Result,
    [Parameter(Mandatory)][string]$Detail
  )
  $script:Layers[$Name] = [pscustomobject]@{ Result = $Result; Detail = $Detail }
}

function Restore-EnvironmentVariable {
  param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][bool]$WasSet,
    [AllowEmptyString()][string]$Value
  )
  if ($WasSet) {
    Set-Item -LiteralPath "Env:$Name" -Value $Value
  } else {
    Remove-Item -LiteralPath "Env:$Name" -ErrorAction SilentlyContinue
  }
}

function Resolve-Verdict {
  param(
    [Parameter(Mandatory)][System.Collections.IDictionary]$Layers,
    [Parameter(Mandatory)][ValidateSet('artifact', 'source')][string]$ExecutionMode
  )
  $values = @($Layers.Values)
  if (@($values | Where-Object Result -eq 'fail').Count -gt 0) {
    return [pscustomobject]@{ Status = 'failed'; ReleaseReady = $false }
  }
  $missing = @($script:RequiredLayers | Where-Object { -not $Layers.Contains($_) })
  $skipped = @($script:RequiredLayers | Where-Object { $Layers.Contains($_) -and $Layers[$_].Result -eq 'skipped' })
  if ($missing.Count -gt 0 -or $skipped.Count -gt 0) {
    return [pscustomobject]@{ Status = 'incomplete'; ReleaseReady = $false }
  }
  if ($ExecutionMode -ne 'artifact') {
    return [pscustomobject]@{ Status = 'incomplete'; ReleaseReady = $false }
  }
  return [pscustomobject]@{ Status = 'supported'; ReleaseReady = $true }
}

function Invoke-SelfTest {
  $allPass = [ordered]@{}
  foreach ($layer in $script:RequiredLayers) {
    $allPass[$layer] = [pscustomobject]@{ Result = 'pass' }
  }
  $allPass['claude-turn'] = [pscustomobject]@{ Result = 'skipped' }
  $allPass['codex-turn'] = [pscustomobject]@{ Result = 'skipped' }
  $oneFailure = [ordered]@{}
  foreach ($entry in $allPass.GetEnumerator()) {
    $oneFailure[$entry.Key] = [pscustomobject]@{ Result = $entry.Value.Result }
  }
  $oneFailure['claude-turn'] = [pscustomobject]@{ Result = 'fail' }
  $missingRequired = [ordered]@{}
  foreach ($layer in $script:RequiredLayers | Where-Object { $_ -ne 'fts5-search' }) {
    $missingRequired[$layer] = [pscustomobject]@{ Result = 'pass' }
  }
  $cases = @(
    @{ Name = 'artifact core pass'; Mode = 'artifact'; Layers = $allPass; Status = 'supported'; Ready = $true },
    @{ Name = 'source core pass'; Mode = 'source'; Layers = $allPass; Status = 'incomplete'; Ready = $false },
    @{ Name = 'artifact missing required layer'; Mode = 'artifact'; Layers = $missingRequired; Status = 'incomplete'; Ready = $false },
    @{ Name = 'artifact attempted provider failure'; Mode = 'artifact'; Layers = $oneFailure; Status = 'failed'; Ready = $false }
  )
  foreach ($case in $cases) {
    $actual = Resolve-Verdict -Layers $case.Layers -ExecutionMode $case.Mode
    if ($actual.Status -ne $case.Status -or $actual.ReleaseReady -ne $case.Ready) {
      throw "Verdict self-test failed: $($case.Name)."
    }
  }

  $testRoot = Join-Path ([IO.Path]::GetTempPath()) "dartclaw-windows-smoke-self-test-$([guid]::NewGuid().ToString('N'))"
  New-Item -ItemType Directory -Path $testRoot | Out-Null
  $priorDataDir = $script:DataDir
  $priorConfigPath = $script:ConfigPath
  $priorProviderStubPath = $script:ProviderStubPath
  try {
    $script:DataDir = Join-Path $testRoot 'data'
    $script:ConfigPath = Join-Path $testRoot 'dartclaw.yaml'
    $script:ProviderStubPath = Join-Path $testRoot 'provider-startup-stub.exe'
    Write-SmokeConfig -Provider claude -UseProviderStub $true
    $stubConfig = Get-Content -LiteralPath $script:ConfigPath -Raw
    if ([regex]::Matches($stubConfig, '(?m)^    executable: provider-startup-stub\.exe$').Count -ne 2) {
      throw 'provider stub was not selected for both providers'
    }
    Write-SmokeConfig -Provider claude -UseProviderStub $false
    $realConfig = Get-Content -LiteralPath $script:ConfigPath -Raw
    if ($realConfig -notmatch '(?m)^    executable: claude$' -or $realConfig -notmatch '(?m)^    executable: codex$') {
      throw 'real provider executables were not preserved outside skip mode'
    }

    $stubSource = Join-Path $PSScriptRoot 'provider_startup_stub.dart'
    $versionOutput = @(& dart $stubSource --version 2>&1 | ForEach-Object ToString)
    if ($LASTEXITCODE -ne 0 -or $versionOutput[0] -ne 'dartclaw-provider-startup-stub 1.0.0') {
      throw 'provider stub version probe failed'
    }
    $authOutput = @(& dart $stubSource auth status 2>&1 | ForEach-Object ToString)
    if ($LASTEXITCODE -ne 0 -or (($authOutput -join "`n") | ConvertFrom-Json).loggedIn -ne $true) {
      throw 'provider stub auth probe failed'
    }
    $initialize = '{"type":"control_request","request_id":"self-test","request":{"subtype":"initialize"}}'
    $responseOutput = @($initialize | & dart $stubSource 2>&1 | ForEach-Object ToString)
    $response = ($responseOutput -join "`n") | ConvertFrom-Json
    if (
      $LASTEXITCODE -ne 0 -or
      $response.type -ne 'control_response' -or
      $response.response.subtype -ne 'success' -or
      $response.response.request_id -ne 'self-test'
    ) {
      throw 'provider stub initialize handshake failed'
    }

    $callerHomeWasSet = Test-Path Env:HOME
    $callerHome = if ($callerHomeWasSet) { (Get-Item Env:HOME).Value } else { $null }
    try {
      $env:HOME = 'self-test-original-home'
      try {
        $env:HOME = 'self-test-mutated-home'
      } finally {
        Restore-EnvironmentVariable -Name HOME -WasSet $true -Value 'self-test-original-home'
      }
      if ($env:HOME -ne 'self-test-original-home') { throw 'HOME value was not restored after success' }

      Remove-Item Env:HOME
      try {
        try {
          $env:HOME = 'self-test-mutated-home'
          throw 'expected HOME restoration failure path'
        } finally {
          Restore-EnvironmentVariable -Name HOME -WasSet $false
        }
      } catch {
        if ($_.Exception.Message -ne 'expected HOME restoration failure path') { throw }
      }
      if (Test-Path Env:HOME) { throw 'absent HOME was not restored after failure' }
    } finally {
      Restore-EnvironmentVariable -Name HOME -WasSet $callerHomeWasSet -Value $callerHome
    }
  } finally {
    $script:DataDir = $priorDataDir
    $script:ConfigPath = $priorConfigPath
    $script:ProviderStubPath = $priorProviderStubPath
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
  Write-Host 'Windows runtime smoke verdict table: PASS'
}

function ConvertTo-YamlSingleQuoted {
  param([Parameter(Mandatory)][string]$Value)
  return "'$($Value.Replace("'", "''"))'"
}

function Write-SmokeConfig {
  param(
    [Parameter(Mandatory)][ValidateSet('claude', 'codex')][string]$Provider,
    [bool]$UseProviderStub = [bool]$SkipProviders
  )
  $dataDir = ConvertTo-YamlSingleQuoted $script:DataDir
  if ($UseProviderStub -and -not $script:ProviderStubPath) { throw 'provider startup stub is not initialized' }
  $claudeExecutable = if ($UseProviderStub) { Split-Path -Leaf $script:ProviderStubPath } else { 'claude' }
  $codexExecutable = if ($UseProviderStub) { Split-Path -Leaf $script:ProviderStubPath } else { 'codex' }
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
    executable: $claudeExecutable
    pool_size: 1
    credentials_required: false
  codex:
    executable: $codexExecutable
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

function Initialize-ProviderStartupStub {
  $source = Join-Path $PSScriptRoot 'provider_startup_stub.dart'
  if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "provider startup stub source not found: $source" }
  $script:ProviderStubPath = Join-Path $script:TempRoot 'provider-startup-stub.exe'
  $output = & dart compile exe $source -o $script:ProviderStubPath 2>&1
  if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $script:ProviderStubPath -PathType Leaf)) {
    throw "provider startup stub compilation failed: $($output -join [Environment]::NewLine)"
  }
  $env:PATH = "$script:TempRoot;$env:PATH"
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
      $taskkill = Join-Path $env:SystemRoot 'System32\taskkill.exe'
      & $taskkill /PID $script:Server.Id /T /F 2>&1 | Out-Null
      if (-not $script:Server.WaitForExit(10000)) {
        throw "server process tree rooted at PID $($script:Server.Id) did not exit after taskkill"
      }
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

function ConvertTo-MarkdownCell {
  param([Parameter(Mandatory)][string]$Value)
  return $Value.Replace('|', '\|').Replace("`r", ' ').Replace("`n", ' ').Trim()
}

function Write-EvidenceReport {
  param([Parameter(Mandatory)]$Verdict)
  $failed = @($script:Layers.Keys | Where-Object { $script:Layers[$_].Result -eq 'fail' })
  $skipped = @($script:Layers.Keys | Where-Object { $script:Layers[$_].Result -eq 'skipped' })
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
  $lines.Add("- Release smoke input: artifact mode required; current mode: $script:ExecutionMode.")
  $lines.Add('- File-watch mechanism: gateway.reload.mode `auto`; process identity preserved by the config-reload layer.')
  $lines.Add('')
  $lines.Add('Provider turns are optional compatibility checks; an attempted provider failure still fails the smoke run.')
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
    $script:ArtifactSha256 = (Get-FileHash -LiteralPath $resolvedArtifact -Algorithm SHA256).Hash.ToLowerInvariant()
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
  if ($SkipProviders) {
    $script:ProviderVersions.claude = 'skipped'
    $script:ProviderVersions.codex = 'skipped'
    $script:CurrentStage = 'provider-stub'
    Initialize-ProviderStartupStub
  } else {
    $script:ProviderVersions.claude = Get-CommandVersion 'claude'
    $script:ProviderVersions.codex = Get-CommandVersion 'codex'
  }
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
      $finalUri = if ($null -ne $web.BaseResponse.PSObject.Properties['ResponseUri']) {
        $web.BaseResponse.ResponseUri.AbsoluteUri
      } elseif ($null -ne $web.BaseResponse.PSObject.Properties['RequestMessage']) {
        $web.BaseResponse.RequestMessage.RequestUri.AbsoluteUri
      } else {
        'unavailable'
      }
      Set-LayerResult 'web-ui' 'pass' "HTTP $($web.StatusCode), final URI $finalUri"
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
    if ($SkipProviders) {
      Set-LayerResult 'claude-turn' 'skipped' 'provider execution disabled'
    } elseif (-not $claudeAuthenticated) {
      Set-LayerResult 'claude-turn' 'fail' 'provider binary or credentials unavailable'
    } else {
      Set-LayerResult 'claude-turn' 'skipped' 'server unavailable'
    }
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
    if ($SkipProviders) {
      Set-LayerResult 'codex-turn' 'skipped' 'provider execution disabled'
    } else {
      Set-LayerResult 'codex-turn' 'fail' 'provider binary or credentials unavailable'
    }
  }

  $script:CurrentStage = 'verdict'
  $verdict = Resolve-Verdict -Layers $script:Layers -ExecutionMode $script:ExecutionMode
  $script:CurrentStage = 'evidence-report'
  Write-EvidenceReport -Verdict $verdict
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
  $verdict = [pscustomobject]@{ Status = 'failed'; ReleaseReady = $false }
  Write-EvidenceReport -Verdict $verdict
  Write-Host "Windows runtime smoke: failed at $failedStage; release-ready=false"
  Write-Host "Evidence: $script:EvidencePath"
  exit 1
} finally {
  Stop-SmokeServer
  $env:PATH = $script:OriginalPath
  Restore-EnvironmentVariable -Name HOME -WasSet $script:OriginalHomeWasSet -Value $script:OriginalHome
  if ($script:TempRoot -and (Test-Path -LiteralPath $script:TempRoot)) {
    Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}
