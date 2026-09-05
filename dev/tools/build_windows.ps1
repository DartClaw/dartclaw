[CmdletBinding()]
param(
  [string]$ReleaseTarget = 'windows-x64'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:RootDir = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

function Assert-NoSystemSqliteOverride {
  $previousErrorActionPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    $pubspecs = @(& git -C $script:RootDir ls-files -- '*pubspec.yaml' 2>$null)
    $gitExitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previousErrorActionPreference
  }
  if ($gitExitCode -ne 0) {
    throw "Windows artifact validation failed: unable to inspect pubspecs for SQLite source overrides."
  }

  $checker = Join-Path $script:RootDir 'apps/dartclaw_cli/tool/check_system_sqlite_override.dart'
  $paths = @($pubspecs | ForEach-Object { Join-Path $script:RootDir $_ })
  try {
    $ErrorActionPreference = 'Continue'
    $output = @(& dart run $checker @paths 2>&1)
    $exitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previousErrorActionPreference
  }
  if ($exitCode -eq 1) {
    throw "Windows artifact validation failed: committed SQLite source: system override found:`n$($output -join "`n")"
  }
  if ($exitCode -ne 0) {
    throw "Windows artifact validation failed: unable to parse pubspecs for SQLite source overrides:`n$($output -join "`n")"
  }
}

function Assert-WindowsReleaseLayout {
  param(
    [Parameter(Mandatory)][string]$Root,
    [string]$BinaryName = 'dartclaw'
  )

  $expected = @('VERSION', "bin/$BinaryName.exe", 'lib/sqlite3.dll')
  foreach ($relativePath in $expected) {
    if (-not (Test-Path -LiteralPath (Join-Path $Root $relativePath) -PathType Leaf)) {
      throw "Windows artifact validation failed: missing $relativePath."
    }
  }
  if (Test-Path -LiteralPath (Join-Path $Root 'share')) {
    throw 'Windows artifact validation failed: unexpected share/ sidecar.'
  }

  $rootPrefix = $Root.TrimEnd('\') + '\'
  $actual = @(Get-ChildItem -LiteralPath $Root -Recurse -File | ForEach-Object {
      $_.FullName.Substring($rootPrefix.Length).Replace('\', '/')
    })
  $unexpected = @($actual | Where-Object { $_ -notin $expected })
  if ($unexpected.Count -gt 0) {
    throw "Windows artifact validation failed: unexpected artifact file(s): $($unexpected -join ', ')."
  }
}

function Assert-WindowsBuildBundle {
  param(
    [Parameter(Mandatory)][string]$Root,
    [string]$BinaryName = 'dartclaw'
  )

  foreach ($relativePath in @("bin/$BinaryName.exe", 'lib/sqlite3.dll')) {
    if (-not (Test-Path -LiteralPath (Join-Path $Root $relativePath) -PathType Leaf)) {
      throw "Windows build validation failed: missing $relativePath."
    }
  }
}

function Invoke-WindowsExecutableSmoke {
  param(
    [Parameter(Mandatory)][string]$Executable,
    [string]$BinaryName = 'dartclaw'
  )

  try {
    & $Executable --help *> $null
    if ($LASTEXITCODE -ne 0) {
      throw "exit code $LASTEXITCODE"
    }
  } catch {
    throw "Windows artifact validation failed: $BinaryName.exe --help smoke failed ($($_.Exception.Message))."
  }
}

function Invoke-WindowsBundledSqliteCheck {
  param(
    [Parameter(Mandatory)][string]$Executable,
    [string]$BinaryName = 'dartclaw'
  )

  # Drives FTS5 through the artifact's own binary: rebuild-index issues
  # CREATE VIRTUAL TABLE ... USING fts5 on every run, and Windows' system
  # winsqlite3.dll ships no fts5 module (ADR-048), so reaching a rebuilt index
  # proves the bundled lib/sqlite3.dll was loaded. The workspace stays empty on
  # purpose: the canonical corpus dialect belongs to dartclaw_core, and a copy
  # of it here rots into a preflight refusal the moment that dialect moves.
  # The probe writes only into a temp instance, never the artifact.
  $probeRoot = Join-Path ([IO.Path]::GetTempPath()) "dartclaw-sqlite-probe-$([guid]::NewGuid())"
  New-Item -ItemType Directory -Path (Join-Path $probeRoot 'workspace') -Force | Out-Null
  try {
    $quotedDataDir = "'" + ($probeRoot -replace "'", "''") + "'"
    $configPath = Join-Path $probeRoot 'dartclaw.yaml'
    Set-Content -LiteralPath $configPath -Value "data_dir: $quotedDataDir"

    $previousErrorActionPreference = $ErrorActionPreference
    try {
      $ErrorActionPreference = 'Continue'
      $output = @(& $Executable --config $configPath rebuild-index 2>&1)
      $exitCode = $LASTEXITCODE
    } finally {
      $ErrorActionPreference = $previousErrorActionPreference
    }

    if ($exitCode -ne 0) {
      throw "Windows artifact validation failed: $BinaryName bundled SQLite FTS5 check failed with exit code ${exitCode}:`n$($output -join "`n")"
    }
    if (-not ($output -match 'Rebuilt index:')) {
      throw "Windows artifact validation failed: $BinaryName bundled SQLite FTS5 check did not rebuild the index:`n$($output -join "`n")"
    }
  } finally {
    if (Test-Path -LiteralPath $probeRoot) {
      Remove-Item -LiteralPath $probeRoot -Recurse -Force
    }
  }
}

function Write-ChecksumSidecar {
  param([Parameter(Mandatory)][string]$Artifact)

  $archiveName = [IO.Path]::GetFileName($Artifact)
  $hash = (Get-FileHash -LiteralPath $Artifact -Algorithm SHA256).Hash.ToLowerInvariant()
  [IO.File]::WriteAllText(
    "$Artifact.sha256",
    "$hash  $archiveName`n",
    [Text.UTF8Encoding]::new($false)
  )
}

if ($MyInvocation.InvocationName -ne '.') {
  if ($ReleaseTarget -ne 'windows-x64') {
    throw "Windows artifacts support only windows-x64, got $ReleaseTarget."
  }

  Assert-NoSystemSqliteOverride

  $versionFile = Join-Path $script:RootDir 'packages/dartclaw_runtime/lib/src/version.dart'
  $versionMatch = Select-String -LiteralPath $versionFile -Pattern "dartclawVersion = '([^']+)'" | Select-Object -First 1
  if ($null -eq $versionMatch) {
    throw "Unable to determine dartclawVersion from $versionFile."
  }
  $version = $versionMatch.Matches[0].Groups[1].Value

  $cliDir = Join-Path $script:RootDir 'apps/dartclaw_cli'
  $buildDir = Join-Path $script:RootDir 'build'
  if (Test-Path -LiteralPath $buildDir) {
    Remove-Item -LiteralPath $buildDir -Recurse -Force
  }
  New-Item -ItemType Directory -Path $buildDir | Out-Null

  $tempRoot = Join-Path ([IO.Path]::GetTempPath()) "dartclaw-windows-build-$([guid]::NewGuid())"
  try {
    foreach ($binary in @(
        @{ Name = 'dartclaw'; Entry = 'dartclaw' },
        @{ Name = 'dartclaw-workflow'; Entry = 'dartclaw_workflow' }
      )) {
      $binaryName = $binary.Name
      $entryName = $binary.Entry
      $cliStage = Join-Path $tempRoot "$binaryName-cli"
      Push-Location $cliDir
      try {
        & dart build cli -t "bin/$entryName.dart" -o $cliStage
        if ($LASTEXITCODE -ne 0) {
          throw "Windows $binaryName release build failed with exit code $LASTEXITCODE."
        }
      } finally {
        Pop-Location
      }

      $bundle = Join-Path $cliStage 'bundle'
      $compiledExecutable = Join-Path $bundle "bin/$entryName.exe"
      Assert-WindowsBuildBundle -Root $bundle -BinaryName $entryName
      Invoke-WindowsExecutableSmoke -Executable $compiledExecutable -BinaryName $binaryName
      Invoke-WindowsBundledSqliteCheck -Executable $compiledExecutable -BinaryName $binaryName

      $stage = Join-Path $tempRoot "$binaryName-stage"
      $extracted = Join-Path $tempRoot "$binaryName-extracted"
      New-Item -ItemType Directory -Path (Join-Path $stage 'bin') -Force | Out-Null
      New-Item -ItemType Directory -Path (Join-Path $stage 'lib') -Force | Out-Null
      Set-Content -LiteralPath (Join-Path $stage 'VERSION') -Value $version -NoNewline
      Copy-Item -LiteralPath $compiledExecutable -Destination (Join-Path $stage "bin/$binaryName.exe")
      Copy-Item -LiteralPath (Join-Path $bundle 'lib/sqlite3.dll') -Destination (Join-Path $stage 'lib/sqlite3.dll')
      Assert-WindowsReleaseLayout -Root $stage -BinaryName $binaryName

      $archiveName = "$binaryName-v$version-windows-x64.zip"
      $archive = Join-Path $buildDir $archiveName
      Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $archive
      Expand-Archive -LiteralPath $archive -DestinationPath $extracted

      Assert-WindowsReleaseLayout -Root $extracted -BinaryName $binaryName
      $extractedExecutable = Join-Path $extracted "bin/$binaryName.exe"
      Invoke-WindowsExecutableSmoke -Executable $extractedExecutable -BinaryName $binaryName
      Invoke-WindowsBundledSqliteCheck -Executable $extractedExecutable -BinaryName $binaryName
      Write-ChecksumSidecar -Artifact $archive
    }
  } finally {
    if (Test-Path -LiteralPath $tempRoot) {
      Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
  }
}
