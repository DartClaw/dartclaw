[CmdletBinding()]
param(
  [string]$ReleaseTarget = 'windows-x64'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:RootDir = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

# llamadart discovers backend modules beside the executable; the wrapper helper does not belong there.
function Get-WindowsRuntimeLibraryFiles {
  param([Parameter(Mandatory)][string]$Root)

  return @(Get-ChildItem -LiteralPath $Root -Recurse -File | Where-Object { $_.Name -ne 'llamadart.dll' })
}

function Assert-WindowsReleaseLayout {
  param(
    [Parameter(Mandatory)][string]$Root,
    [string]$BinaryName = 'dartclaw',
    [string]$NativeLibraryRoot = ''
  )

  $expected = @('VERSION', "bin/$BinaryName.exe")
  if ($NativeLibraryRoot) {
    $nativePrefix = $NativeLibraryRoot.TrimEnd('\') + '\'
    $expected += @(Get-ChildItem -LiteralPath $NativeLibraryRoot -Recurse -File | ForEach-Object {
        'lib/' + $_.FullName.Substring($nativePrefix.Length).Replace('\', '/')
      })
    $expected += @(Get-WindowsRuntimeLibraryFiles -Root $NativeLibraryRoot | ForEach-Object {
        'bin/' + $_.Name
      })
  }
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

  foreach ($relativePath in @("bin/$BinaryName.exe")) {
    if (-not (Test-Path -LiteralPath (Join-Path $Root $relativePath) -PathType Leaf)) {
      throw "Windows build validation failed: missing $relativePath."
    }
  }
  $libraryRoot = Join-Path $Root 'lib'
  if (-not (Test-Path -LiteralPath $libraryRoot -PathType Container)) {
    throw 'Windows build validation failed: missing native libraries.'
  }
  $nativeLibraries = @(Get-ChildItem -LiteralPath $libraryRoot -Recurse -File)
  if ($nativeLibraries.Count -eq 0) {
    throw 'Windows build validation failed: missing native libraries.'
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

  $versionFile = Join-Path $script:RootDir 'packages/dartclaw_runtime/lib/src/version.dart'
  $versionMatch = Select-String -LiteralPath $versionFile -Pattern "dartclawVersion = '([^']+)'" | Select-Object -First 1
  if ($null -eq $versionMatch) {
    throw "Unable to determine dartclawVersion from $versionFile."
  }
  $version = $versionMatch.Matches[0].Groups[1].Value

  $cliDir = Join-Path $script:RootDir 'apps/dartclaw_cli'
  $buildDir = Join-Path $script:RootDir 'build'

  $tempRoot = Join-Path ([IO.Path]::GetTempPath()) "dartclaw-windows-build-$([guid]::NewGuid())"
  try {
    New-Item -ItemType Directory -Path $tempRoot | Out-Null
    $cacheDirectory = if ($env:DARTCLAW_NATIVE_ARCHIVE_CACHE) {
      $env:DARTCLAW_NATIVE_ARCHIVE_CACHE
    } else {
      Join-Path $script:RootDir '.agent_temp/native-cache'
    }
    $manifestPath = if ($env:DARTCLAW_NATIVE_MANIFEST) {
      $env:DARTCLAW_NATIVE_MANIFEST
    } else {
      Join-Path $script:RootDir 'dev/native_artifacts.json'
    }
    $preparer = Join-Path $script:RootDir 'apps/dartclaw_cli/tool/native_artifact_preparation.dart'
    $prepareArgs = @(
      'run', $preparer,
      '--manifest', $manifestPath,
      '--target', $ReleaseTarget,
      '--cache', $cacheDirectory,
      '--stage-parent', $tempRoot,
      '--hook-root-only'
    )
    if ($env:DARTCLAW_NATIVE_ALLOW_DOWNLOAD -eq '1') {
      $prepareArgs += '--allow-download'
    }
    $nativeHookRoot = (& dart @prepareArgs | Select-Object -Last 1).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $nativeHookRoot) {
      throw 'Windows native archive preparation failed.'
    }

    $releaseWorkspace = Join-Path $tempRoot 'workspace'
    & dart run (Join-Path $script:RootDir 'dev/tools/stage_native_build_workspace.dart') `
      --source $script:RootDir `
      --destination $releaseWorkspace `
      --hook-root $nativeHookRoot `
      --manifest $manifestPath
    if ($LASTEXITCODE -ne 0) {
      throw 'Windows release workspace staging failed.'
    }
    Push-Location $releaseWorkspace
    try {
      & dart pub get --offline --enforce-lockfile
      if ($LASTEXITCODE -ne 0) {
        throw 'Windows staged release dependency resolution failed.'
      }
    } finally {
      Pop-Location
    }
    $cliDir = Join-Path $releaseWorkspace 'apps/dartclaw_cli'
    $nativeLibraryRoot = Join-Path $tempRoot 'native-libraries'

    if (Test-Path -LiteralPath $buildDir) {
      Remove-Item -LiteralPath $buildDir -Recurse -Force
    }
    New-Item -ItemType Directory -Path $buildDir | Out-Null

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
      if (-not (Test-Path -LiteralPath $nativeLibraryRoot)) {
        Copy-Item -LiteralPath (Join-Path $bundle 'lib') -Destination $nativeLibraryRoot -Recurse
      }
      Invoke-WindowsExecutableSmoke -Executable $compiledExecutable -BinaryName $binaryName

      $stage = Join-Path $tempRoot "$binaryName-stage"
      $extracted = Join-Path $tempRoot "$binaryName-extracted"
      New-Item -ItemType Directory -Path (Join-Path $stage 'bin') -Force | Out-Null
      Set-Content -LiteralPath (Join-Path $stage 'VERSION') -Value $version -NoNewline
      Copy-Item -LiteralPath $compiledExecutable -Destination (Join-Path $stage "bin/$binaryName.exe")
      Copy-Item -LiteralPath $nativeLibraryRoot -Destination (Join-Path $stage 'lib') -Recurse
      foreach ($runtimeLibrary in @(Get-WindowsRuntimeLibraryFiles -Root $nativeLibraryRoot)) {
        Copy-Item -LiteralPath $runtimeLibrary.FullName -Destination (Join-Path $stage 'bin')
      }
      Assert-WindowsReleaseLayout -Root $stage -BinaryName $binaryName -NativeLibraryRoot $nativeLibraryRoot

      $archiveName = "$binaryName-v$version-windows-x64.zip"
      $archive = Join-Path $buildDir $archiveName
      Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $archive
      Expand-Archive -LiteralPath $archive -DestinationPath $extracted

      Assert-WindowsReleaseLayout -Root $extracted -BinaryName $binaryName -NativeLibraryRoot $nativeLibraryRoot
      $extractedExecutable = Join-Path $extracted "bin/$binaryName.exe"
      Invoke-WindowsExecutableSmoke -Executable $extractedExecutable -BinaryName $binaryName
      Write-ChecksumSidecar -Artifact $archive
    }
  } finally {
    if (Test-Path -LiteralPath $tempRoot) {
      Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
  }
}
