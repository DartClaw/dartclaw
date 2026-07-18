[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$ArtifactPath,
  [Parameter(Mandatory)][string]$Version,
  [string]$HostArchitectureOverride,
  [switch]$TestDownloadPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:RootDir = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$script:Installer = Join-Path $script:RootDir 'install.ps1'
$script:PowerShell = (Get-Process -Id $PID).Path

function Invoke-InstallerProcess {
  param(
    [Parameter(Mandatory)][string]$InstallRoot,
    [string]$LocalArtifact,
    [string]$RequestedVersion = $Version,
    [string]$BaseUrl,
    [hashtable]$Environment = @{}
  )

  $start = [Diagnostics.ProcessStartInfo]::new()
  $start.FileName = $script:PowerShell
  $start.UseShellExecute = $false
  $start.RedirectStandardOutput = $true
  $start.RedirectStandardError = $true
  $start.Arguments = '-NoProfile -NonInteractive -Command "if ($env:DARTCLAW_INSTALL_TEST_ARCH) { $env:PROCESSOR_ARCHITECTURE = $env:DARTCLAW_INSTALL_TEST_ARCH; $env:PROCESSOR_ARCHITEW6432 = $env:DARTCLAW_INSTALL_TEST_ARCH }; if ($env:DARTCLAW_INSTALL_TEST_ARTIFACT) { & $env:DARTCLAW_INSTALL_TEST_SCRIPT -Version $env:DARTCLAW_INSTALL_TEST_VERSION -InstallRoot $env:DARTCLAW_INSTALL_TEST_ROOT -LocalArtifactPath $env:DARTCLAW_INSTALL_TEST_ARTIFACT } else { & $env:DARTCLAW_INSTALL_TEST_SCRIPT -Version $env:DARTCLAW_INSTALL_TEST_VERSION -InstallRoot $env:DARTCLAW_INSTALL_TEST_ROOT -BaseUrl $env:DARTCLAW_INSTALL_TEST_BASE_URL }"'
  $start.EnvironmentVariables['DARTCLAW_INSTALL_TEST_SCRIPT'] = $script:Installer
  $start.EnvironmentVariables['DARTCLAW_INSTALL_TEST_VERSION'] = $RequestedVersion
  $start.EnvironmentVariables['DARTCLAW_INSTALL_TEST_ROOT'] = $InstallRoot
  if (-not [string]::IsNullOrWhiteSpace($LocalArtifact)) {
    $start.EnvironmentVariables['DARTCLAW_INSTALL_TEST_ARTIFACT'] = $LocalArtifact
  }
  if (-not [string]::IsNullOrWhiteSpace($BaseUrl)) {
    $start.EnvironmentVariables['DARTCLAW_INSTALL_TEST_BASE_URL'] = $BaseUrl
  }
  $effectiveArchitecture = if ($Environment.ContainsKey('PROCESSOR_ARCHITEW6432')) {
    $Environment['PROCESSOR_ARCHITEW6432']
  } elseif ($Environment.ContainsKey('PROCESSOR_ARCHITECTURE')) {
    $Environment['PROCESSOR_ARCHITECTURE']
  } else {
    $HostArchitectureOverride
  }
  if (-not [string]::IsNullOrWhiteSpace($effectiveArchitecture)) {
    $start.EnvironmentVariables['DARTCLAW_INSTALL_TEST_ARCH'] = $effectiveArchitecture
  }
  foreach ($entry in $Environment.GetEnumerator()) {
    $start.EnvironmentVariables[$entry.Key] = $entry.Value
  }
  $process = [Diagnostics.Process]::Start($start)
  $stdout = $process.StandardOutput.ReadToEndAsync()
  $stderr = $process.StandardError.ReadToEndAsync()
  $process.WaitForExit()
  return @{
    ExitCode = $process.ExitCode
    Stdout = $stdout.Result
    Stderr = $stderr.Result
  }
}

function Assert-InstallerPassed {
  param([Parameter(Mandatory)][hashtable]$Result)

  if ($Result.ExitCode -ne 0) {
    throw "Installer failed with exit code $($Result.ExitCode): $($Result.Stdout)`n$($Result.Stderr)"
  }
}

function Assert-InstallerFailed {
  param(
    [Parameter(Mandatory)][hashtable]$Result,
    [Parameter(Mandatory)][string]$Message
  )

  if ($Result.ExitCode -eq 0) {
    throw "Expected installer failure containing '$Message', but it passed."
  }
  if ("$($Result.Stdout)`n$($Result.Stderr)" -notlike "*$Message*") {
    throw "Expected installer failure containing '$Message', got: $($Result.Stdout)`n$($Result.Stderr)"
  }
}

function Assert-InstalledLayout {
  param([Parameter(Mandatory)][string]$InstallRoot)

  foreach ($relativePath in @('VERSION', 'bin/dartclaw.exe', 'lib/sqlite3.dll')) {
    if (-not (Test-Path -LiteralPath (Join-Path $InstallRoot $relativePath) -PathType Leaf)) {
      throw "Installed layout is missing '$relativePath'."
    }
  }
  if (Test-Path -LiteralPath (Join-Path $InstallRoot 'share')) {
    throw 'Installed layout contains an unexpected share sidecar.'
  }
}

function Assert-PathExcludes {
  param([Parameter(Mandatory)][string]$BinPath)

  $persistentPath = [Environment]::GetEnvironmentVariable('Path', 'User')
  $matches = @($persistentPath -split ';' | Where-Object { $_.Trim().TrimEnd('\') -ieq $BinPath.TrimEnd('\') })
  if ($matches.Count -ne 0) {
    throw "Persistent user PATH unexpectedly contains '$BinPath'."
  }
}

function Assert-TreeHashesEqual {
  param(
    [Parameter(Mandatory)][string]$ExpectedRoot,
    [Parameter(Mandatory)][string]$ActualRoot
  )

  foreach ($relativePath in @('VERSION', 'bin/dartclaw.exe', 'lib/sqlite3.dll')) {
    $expected = (Get-FileHash -LiteralPath (Join-Path $ExpectedRoot $relativePath) -Algorithm SHA256).Hash
    $actual = (Get-FileHash -LiteralPath (Join-Path $ActualRoot $relativePath) -Algorithm SHA256).Hash
    if ($actual -ne $expected) {
      throw "Installed '$relativePath' does not match the expected tree."
    }
  }
}

function Remove-TestTree {
  param([Parameter(Mandatory)][string]$Path)

  for ($attempt = 1; $attempt -le 20; $attempt++) {
    try {
      Microsoft.PowerShell.Management\Remove-Item -LiteralPath $Path -Recurse -Force
      return
    } catch {
      if ($attempt -eq 20) {
        throw
      }
      Start-Sleep -Milliseconds 100
    }
  }
}

function Wait-TestFileUnlocked {
  param([Parameter(Mandatory)][string]$Path)

  for ($attempt = 1; $attempt -le 20; $attempt++) {
    try {
      $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
      $stream.Dispose()
      return
    } catch {
      if ($attempt -eq 20) {
        throw
      }
      Start-Sleep -Milliseconds 100
    }
  }
}

$artifact = [IO.Path]::GetFullPath($ArtifactPath)
$originalUserPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$originalProcessorArchitecture = $env:PROCESSOR_ARCHITECTURE
$originalProcessorArchitectureW6432 = $env:PROCESSOR_ARCHITEW6432
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) "dartclaw-installer-test-$([guid]::NewGuid())"
New-Item -ItemType Directory -Path $tempRoot | Out-Null

if (-not [string]::IsNullOrWhiteSpace($HostArchitectureOverride)) {
  $env:PROCESSOR_ARCHITECTURE = $HostArchitectureOverride
  $env:PROCESSOR_ARCHITEW6432 = $HostArchitectureOverride
}

try {
  $expectedRoot = Join-Path $tempRoot 'expected'
  Expand-Archive -LiteralPath $artifact -DestinationPath $expectedRoot
  Assert-InstalledLayout -InstallRoot $expectedRoot

  $testVersion = $Version
  . $script:Installer -Version $testVersion
  $originalDirectoryMover = (Get-Command Move-DartClawDirectory).ScriptBlock

  $installRoot = Join-Path $tempRoot 'DartClaw'
  $result = Invoke-InstallerProcess -InstallRoot $installRoot -LocalArtifact $artifact
  Assert-InstallerPassed -Result $result
  Assert-InstalledLayout -InstallRoot $installRoot

  $binPath = Join-Path $installRoot 'bin'
  $persistentPath = [Environment]::GetEnvironmentVariable('Path', 'User')
  $matches = @($persistentPath -split ';' | Where-Object { $_.Trim().TrimEnd('\') -ieq $binPath.TrimEnd('\') })
  if ($matches.Count -ne 1) {
    throw "Expected one persistent user PATH entry for '$binPath', found $($matches.Count)."
  }

  $versionOutput = & (Join-Path $binPath 'dartclaw.exe') --version
  if ($LASTEXITCODE -ne 0 -or $versionOutput.Trim() -ne $Version) {
    throw "Installed executable version check failed: '$versionOutput'."
  }

  $newTerminal = [Diagnostics.ProcessStartInfo]::new()
  $newTerminal.FileName = 'cmd.exe'
  $newTerminal.Arguments = '/d /c "dartclaw --version"'
  $newTerminal.UseShellExecute = $false
  $newTerminal.RedirectStandardOutput = $true
  $newTerminal.RedirectStandardError = $true
  $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
  $newTerminal.EnvironmentVariables['Path'] = "$persistentPath;$machinePath"
  $terminalProcess = [Diagnostics.Process]::Start($newTerminal)
  $terminalOutput = $terminalProcess.StandardOutput.ReadToEnd()
  $terminalError = $terminalProcess.StandardError.ReadToEnd()
  $terminalProcess.WaitForExit()
  if ($terminalProcess.ExitCode -ne 0 -or $terminalOutput.Trim() -ne $Version) {
    throw "Fresh-terminal PATH resolution failed: $terminalOutput $terminalError"
  }

  $installedExecutable = Join-Path $installRoot 'bin/dartclaw.exe'
  Wait-TestFileUnlocked -Path $installedExecutable
  Set-Content -LiteralPath (Join-Path $installRoot 'VERSION') -Value 'older-version' -NoNewline
  Set-Content -LiteralPath $installedExecutable -Value 'older-executable' -NoNewline
  Set-Content -LiteralPath (Join-Path $installRoot 'lib/sqlite3.dll') -Value 'older-library' -NoNewline
  $result = Invoke-InstallerProcess -InstallRoot $installRoot -LocalArtifact $artifact
  Assert-InstallerPassed -Result $result
  Assert-TreeHashesEqual -ExpectedRoot $expectedRoot -ActualRoot $installRoot
  $versionOutput = & (Join-Path $installRoot 'bin/dartclaw.exe') --version
  if ($LASTEXITCODE -ne 0 -or $versionOutput.Trim() -ne $Version) {
    throw "Upgraded executable version check failed: '$versionOutput'."
  }

  $badArtifact = Join-Path $tempRoot 'tampered.zip'
  Copy-Item -LiteralPath $artifact -Destination $badArtifact
  Set-Content -LiteralPath "$badArtifact.sha256" -Value "$('0' * 64)  tampered.zip"
  $badRoot = Join-Path $tempRoot 'checksum-failure'
  $result = Invoke-InstallerProcess -InstallRoot $badRoot -LocalArtifact $badArtifact
  Assert-InstallerFailed -Result $result -Message 'Checksum mismatch'
  $actualBadDigest = (Get-FileHash -LiteralPath $badArtifact -Algorithm SHA256).Hash.ToLowerInvariant()
  if ("$($result.Stdout)`n$($result.Stderr)" -notlike "*$('0' * 64)*$actualBadDigest*") {
    throw 'Checksum failure did not report both expected and actual digests.'
  }
  if (Test-Path -LiteralPath $badRoot) {
    throw 'Checksum failure activated an install.'
  }
  Assert-PathExcludes -BinPath (Join-Path $badRoot 'bin')

  $downloadFailureRoot = Join-Path $tempRoot 'download-failure'
  $result = Invoke-InstallerProcess -InstallRoot $downloadFailureRoot -LocalArtifact (Join-Path $tempRoot 'missing.zip')
  Assert-InstallerFailed -Result $result -Message 'Local DartClaw artifact not found'
  if (Test-Path -LiteralPath $downloadFailureRoot) {
    throw 'Download failure activated an install.'
  }
  Assert-PathExcludes -BinPath (Join-Path $downloadFailureRoot 'bin')

  $traversalSentinel = Join-Path $tempRoot 'escaped-windows-x64.zip'
  Set-Content -LiteralPath $traversalSentinel -Value 'preserve-me' -NoNewline
  $traversalRoot = Join-Path $tempRoot 'version-traversal'
  $result = Invoke-InstallerProcess -InstallRoot $traversalRoot -LocalArtifact $artifact `
    -RequestedVersion '..\..\escaped'
  Assert-InstallerFailed -Result $result -Message 'Invalid DartClaw release version'
  if ((Get-Content -LiteralPath $traversalSentinel -Raw) -ne 'preserve-me') {
    throw 'Invalid version escaped installer staging and modified an outside file.'
  }
  if (Test-Path -LiteralPath $traversalRoot) {
    throw 'Invalid version activated an install.'
  }

  $pathInjectionRoot = Join-Path $tempRoot 'path-injection;C:\attacker'
  $pathBeforeInjectionAttempt = [Environment]::GetEnvironmentVariable('Path', 'User')
  $result = Invoke-InstallerProcess -InstallRoot $pathInjectionRoot -LocalArtifact $artifact
  Assert-InstallerFailed -Result $result -Message 'PATH delimiter'
  if ([Environment]::GetEnvironmentVariable('Path', 'User') -ne $pathBeforeInjectionAttempt) {
    throw 'Invalid install root modified the persistent user PATH.'
  }

  $unsupportedRoot = Join-Path $tempRoot 'unsupported-architecture'
  $result = Invoke-InstallerProcess -InstallRoot $unsupportedRoot -LocalArtifact $artifact -Environment @{
    PROCESSOR_ARCHITECTURE = 'ARM64'
    PROCESSOR_ARCHITEW6432 = ''
  }
  Assert-InstallerFailed -Result $result -Message 'Windows x64 only'
  if (Test-Path -LiteralPath $unsupportedRoot) {
    throw 'Unsupported architecture activated an install.'
  }
  Assert-PathExcludes -BinPath (Join-Path $unsupportedRoot 'bin')

  $wow64Root = Join-Path $tempRoot 'x64-host-from-32-bit-powershell'
  $result = Invoke-InstallerProcess -InstallRoot $wow64Root -LocalArtifact $artifact -Environment @{
    PROCESSOR_ARCHITECTURE = 'x86'
    PROCESSOR_ARCHITEW6432 = 'AMD64'
  }
  Assert-InstallerPassed -Result $result
  Assert-TreeHashesEqual -ExpectedRoot $expectedRoot -ActualRoot $wow64Root

  if ($TestDownloadPath) {
    $releaseRoot = Join-Path $tempRoot 'release-server'
    $releaseDir = Join-Path $releaseRoot "v$Version"
    New-Item -ItemType Directory -Path $releaseDir -Force | Out-Null
    Copy-Item -LiteralPath $artifact -Destination (Join-Path $releaseDir (Split-Path -Leaf $artifact))
    Copy-Item -LiteralPath "$artifact.sha256" -Destination (Join-Path $releaseDir "$(Split-Path -Leaf $artifact).sha256")
    $port = Get-Random -Minimum 20000 -Maximum 45000
    $server = Start-Process -FilePath 'python' -ArgumentList @('-m', 'http.server', "$port", '--bind', '127.0.0.1') `
      -WorkingDirectory $releaseRoot -PassThru -WindowStyle Hidden
    try {
      $baseUrl = "http://127.0.0.1:$port"
      $ready = $false
      for ($attempt = 1; $attempt -le 30; $attempt++) {
        try {
          Invoke-WebRequest -UseBasicParsing -Uri "$baseUrl/v$Version/$(Split-Path -Leaf $artifact).sha256" | Out-Null
          $ready = $true
          break
        } catch {
          Start-Sleep -Milliseconds 100
        }
      }
      if (-not $ready) {
        throw 'Local release server did not become ready.'
      }
      $downloadRoot = Join-Path $tempRoot 'download-install'
      $result = Invoke-InstallerProcess -InstallRoot $downloadRoot -RequestedVersion $Version -BaseUrl $baseUrl
      Assert-InstallerPassed -Result $result
      Assert-TreeHashesEqual -ExpectedRoot $expectedRoot -ActualRoot $downloadRoot
    } finally {
      if (-not $server.HasExited) {
        Stop-Process -Id $server.Id -Force
      }
    }
  }

  Wait-TestFileUnlocked -Path $installedExecutable
  Set-Content -LiteralPath (Join-Path $installRoot 'VERSION') -Value 'older-version' -NoNewline
  Set-Content -LiteralPath $installedExecutable -Value 'older-executable' -NoNewline
  Set-Content -LiteralPath (Join-Path $installRoot 'lib/sqlite3.dll') -Value 'older-library' -NoNewline
  $preservedRoot = Join-Path $tempRoot 'preserved-old-install'
  Copy-Item -LiteralPath $installRoot -Destination $preservedRoot -Recurse
  $script:BackupFailureSource = $installRoot
  function Move-DartClawDirectory {
    param(
      [Parameter(Mandatory)][string]$Source,
      [Parameter(Mandatory)][string]$Destination
    )

    if ($Source -ieq $script:BackupFailureSource) {
      throw 'simulated backup creation failure'
    }
    [IO.Directory]::Move($Source, $Destination)
  }
  try {
    try {
      Invoke-DartClawInstall -ReleaseVersion $testVersion -TargetRoot $installRoot -ReleaseBaseUrl 'unused' -ArtifactPath $artifact
      throw 'Expected backup creation to fail.'
    } catch {
      if ($_.Exception.Message -notlike '*previous install was left unchanged*simulated backup creation failure*') {
        throw
      }
    }
  } finally {
    Set-Item Function:Move-DartClawDirectory $originalDirectoryMover
  }
  Assert-TreeHashesEqual -ExpectedRoot $preservedRoot -ActualRoot $installRoot

  Set-Content -LiteralPath (Join-Path $preservedRoot 'previous-install-sentinel.txt') -Value 'preserve-me' -NoNewline
  $postBackupRoot = Join-Path $tempRoot 'post-backup-rollback'
  Copy-Item -LiteralPath $preservedRoot -Destination $postBackupRoot -Recurse
  $script:ActivationFailureTarget = $postBackupRoot
  function Move-DartClawDirectory {
    param(
      [Parameter(Mandatory)][string]$Source,
      [Parameter(Mandatory)][string]$Destination
    )

    if ((Split-Path -Leaf $Source) -eq 'stage' -and $Destination -ieq $script:ActivationFailureTarget) {
      throw 'simulated stage activation failure'
    }
    [IO.Directory]::Move($Source, $Destination)
  }
  try {
    try {
      Invoke-DartClawInstall -ReleaseVersion $testVersion -TargetRoot $postBackupRoot -ReleaseBaseUrl 'unused' -ArtifactPath $artifact
      throw 'Expected post-backup activation to fail.'
    } catch {
      if ($_.Exception.Message -notlike '*previous install was left unchanged*simulated stage activation failure*') {
        throw
      }
    }
  } finally {
    Set-Item Function:Move-DartClawDirectory $originalDirectoryMover
  }
  Assert-TreeHashesEqual -ExpectedRoot $preservedRoot -ActualRoot $postBackupRoot
  $sentinel = Join-Path $postBackupRoot 'previous-install-sentinel.txt'
  if (-not (Test-Path -LiteralPath $sentinel -PathType Leaf) -or (Get-Content -LiteralPath $sentinel -Raw) -ne 'preserve-me') {
    throw 'Post-backup rollback did not restore the complete previous install tree.'
  }

  function Invoke-WebRequest { throw 'simulated network outage' }
  $networkFailureRoot = Join-Path $tempRoot 'network-failure'
  try {
    try {
      Invoke-DartClawInstall -ReleaseVersion $testVersion -TargetRoot $networkFailureRoot -ReleaseBaseUrl 'https://invalid.example' -ArtifactPath $null
      throw 'Expected the simulated network failure to fail.'
    } catch {
      if ($_.Exception.Message -notlike '*Failed to download DartClaw*simulated network outage*') {
        throw
      }
    }
  } finally {
    Microsoft.PowerShell.Management\Remove-Item -Path Function:Invoke-WebRequest
  }
  if (Test-Path -LiteralPath $networkFailureRoot) {
    throw 'Network failure activated an install.'
  }
  Assert-PathExcludes -BinPath (Join-Path $networkFailureRoot 'bin')

  function Remove-Item {
    param(
      [string]$LiteralPath,
      [switch]$Recurse,
      [switch]$Force
    )

    if ((Split-Path -Leaf $LiteralPath) -like '.dartclaw-install-*') {
      throw 'simulated cleanup denial'
    }
    Microsoft.PowerShell.Management\Remove-Item -LiteralPath $LiteralPath -Recurse:$Recurse -Force:$Force
  }
  $cleanupFailureRoot = Join-Path $tempRoot 'cleanup-failure'
  try {
    try {
      Invoke-DartClawInstall -ReleaseVersion $testVersion -TargetRoot $cleanupFailureRoot -ReleaseBaseUrl 'unused' -ArtifactPath $badArtifact
      throw 'Expected checksum mismatch with cleanup failure to fail.'
    } catch {
      if ($_.Exception.Message -notlike '*Checksum mismatch*') {
        throw
      }
    }
  } finally {
    Microsoft.PowerShell.Management\Remove-Item -Path Function:Remove-Item
  }

  $originalPathWriter = (Get-Command Add-DartClawUserPath).ScriptBlock
  function Add-DartClawUserPath { throw 'simulated PATH write denial' }
  $pathFailureRoot = Join-Path $tempRoot 'path-failure'
  try {
    try {
      Invoke-DartClawInstall -ReleaseVersion $testVersion -TargetRoot $pathFailureRoot -ReleaseBaseUrl 'unused' -ArtifactPath $artifact
      throw 'Expected the simulated PATH write denial to fail.'
    } catch {
      if ($_.Exception.Message -notlike "*installed at '$pathFailureRoot'*PATH update failed*Add '*\bin'*") {
        throw
      }
    }
    Assert-InstalledLayout -InstallRoot $pathFailureRoot
  } finally {
    Set-Item Function:Add-DartClawUserPath $originalPathWriter
  }
} finally {
  [Environment]::SetEnvironmentVariable('Path', $originalUserPath, 'User')
  $env:PROCESSOR_ARCHITECTURE = $originalProcessorArchitecture
  $env:PROCESSOR_ARCHITEW6432 = $originalProcessorArchitectureW6432
  if (Test-Path -LiteralPath $tempRoot) {
    Remove-TestTree -Path $tempRoot
  }
}

Write-Output 'Windows installer acceptance tests passed.'
