[CmdletBinding()]
param(
  [string]$ReleaseTarget = 'windows-x64'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:RootDir = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

function Assert-NoSystemSqliteOverride {
  $matches = & git -C $script:RootDir grep -n -E 'source:[[:space:]]*system' -- '*pubspec.yaml' 2>$null
  $exitCode = $LASTEXITCODE
  if ($exitCode -eq 0) {
    throw "Windows artifact validation failed: committed SQLite source: system override found:`n$($matches -join "`n")"
  }
  if ($exitCode -ne 1) {
    throw "Windows artifact validation failed: unable to inspect pubspecs for SQLite source overrides."
  }
}

function Assert-WindowsReleaseLayout {
  param([Parameter(Mandatory)][string]$Root)

  foreach ($relativePath in @('VERSION', 'bin/dartclaw.exe', 'lib/sqlite3.dll')) {
    if (-not (Test-Path -LiteralPath (Join-Path $Root $relativePath) -PathType Leaf)) {
      throw "Windows artifact validation failed: missing $relativePath."
    }
  }
  if (Test-Path -LiteralPath (Join-Path $Root 'share')) {
    throw 'Windows artifact validation failed: unexpected share/ sidecar.'
  }

  $expected = @('VERSION', 'bin/dartclaw.exe', 'lib/sqlite3.dll')
  $actual = @(Get-ChildItem -LiteralPath $Root -Recurse -File | ForEach-Object {
      [IO.Path]::GetRelativePath($Root, $_.FullName).Replace('\', '/')
    })
  $unexpected = @($actual | Where-Object { $_ -notin $expected })
  if ($unexpected.Count -gt 0) {
    throw "Windows artifact validation failed: unexpected artifact file(s): $($unexpected -join ', ')."
  }
}

function Assert-WindowsBuildBundle {
  param([Parameter(Mandatory)][string]$Root)

  foreach ($relativePath in @('bin/dartclaw.exe', 'lib/sqlite3.dll')) {
    if (-not (Test-Path -LiteralPath (Join-Path $Root $relativePath) -PathType Leaf)) {
      throw "Windows build validation failed: missing $relativePath."
    }
  }
}

function Invoke-WindowsExecutableSmoke {
  param([Parameter(Mandatory)][string]$Executable)

  try {
    & $Executable --help *> $null
    if ($LASTEXITCODE -ne 0) {
      throw "exit code $LASTEXITCODE"
    }
  } catch {
    throw "Windows artifact validation failed: dartclaw.exe --help smoke failed ($($_.Exception.Message))."
  }
}

function Invoke-WindowsSqliteCheck {
  param(
    [Parameter(Mandatory)][string]$Executable,
    [Parameter(Mandatory)][string]$SqliteModule
  )

  & $Executable release-sqlite-check --expected-module $SqliteModule
  if ($LASTEXITCODE -ne 0) {
    throw "Windows artifact validation failed: bundled SQLite module/FTS5 check failed with exit code $LASTEXITCODE."
  }
}

if ($MyInvocation.InvocationName -ne '.') {
  if ($ReleaseTarget -ne 'windows-x64') {
    throw "Windows artifacts support only windows-x64, got $ReleaseTarget."
  }

  Assert-NoSystemSqliteOverride

  $versionFile = Join-Path $script:RootDir 'packages/dartclaw_server/lib/src/version.dart'
  $versionMatch = Select-String -LiteralPath $versionFile -Pattern "dartclawVersion = '([^']+)'" | Select-Object -First 1
  if ($null -eq $versionMatch) {
    throw "Unable to determine dartclawVersion from $versionFile."
  }
  $version = $versionMatch.Matches[0].Groups[1].Value

  $cliDir = Join-Path $script:RootDir 'apps/dartclaw_cli'
  Push-Location $cliDir
  try {
    & dart build cli -t bin/dartclaw.dart
    if ($LASTEXITCODE -ne 0) {
      throw "Windows release build failed with exit code $LASTEXITCODE."
    }
  } finally {
    Pop-Location
  }

  $bundle = Join-Path $cliDir 'build/cli/windows_x64/bundle'
  Assert-WindowsBuildBundle -Root $bundle
  Invoke-WindowsExecutableSmoke -Executable (Join-Path $bundle 'bin/dartclaw.exe')
  Invoke-WindowsSqliteCheck -Executable (Join-Path $bundle 'bin/dartclaw.exe') -SqliteModule (Join-Path $bundle 'lib/sqlite3.dll')

  $buildDir = Join-Path $script:RootDir 'build'
  if (Test-Path -LiteralPath $buildDir) {
    Remove-Item -LiteralPath $buildDir -Recurse -Force
  }
  New-Item -ItemType Directory -Path $buildDir | Out-Null

  $tempRoot = Join-Path ([IO.Path]::GetTempPath()) "dartclaw-windows-build-$([guid]::NewGuid())"
  $stage = Join-Path $tempRoot 'stage'
  $extracted = Join-Path $tempRoot 'extracted'
  New-Item -ItemType Directory -Path (Join-Path $stage 'bin') -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $stage 'lib') -Force | Out-Null
  try {
    Set-Content -LiteralPath (Join-Path $stage 'VERSION') -Value $version -NoNewline
    Copy-Item -LiteralPath (Join-Path $bundle 'bin/dartclaw.exe') -Destination (Join-Path $stage 'bin/dartclaw.exe')
    Copy-Item -LiteralPath (Join-Path $bundle 'lib/sqlite3.dll') -Destination (Join-Path $stage 'lib/sqlite3.dll')
    Assert-WindowsReleaseLayout -Root $stage

    $archiveName = "dartclaw-v$version-windows-x64.zip"
    $archive = Join-Path $buildDir $archiveName
    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $archive
    Expand-Archive -LiteralPath $archive -DestinationPath $extracted

    Assert-WindowsReleaseLayout -Root $extracted
    Invoke-WindowsExecutableSmoke -Executable (Join-Path $extracted 'bin/dartclaw.exe')
    Invoke-WindowsSqliteCheck -Executable (Join-Path $extracted 'bin/dartclaw.exe') -SqliteModule (Join-Path $extracted 'lib/sqlite3.dll')

    $hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    Set-Content -LiteralPath "$archive.sha256" -Value "$hash  $archiveName"
  } finally {
    if (Test-Path -LiteralPath $tempRoot) {
      Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
  }
}
