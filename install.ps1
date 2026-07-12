[CmdletBinding()]
param(
  [string]$Version,
  [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'Programs\DartClaw'),
  [string]$BaseUrl = 'https://github.com/DartClaw/dartclaw/releases/download',
  [string]$LocalArtifactPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-DartClawInstallerArchitecture {
  $hostArchitecture = $env:PROCESSOR_ARCHITECTURE
  if (-not [string]::IsNullOrWhiteSpace($env:PROCESSOR_ARCHITEW6432)) {
    $hostArchitecture = $env:PROCESSOR_ARCHITEW6432
  }
  if ($hostArchitecture -ne 'AMD64') {
    if ([string]::IsNullOrWhiteSpace($hostArchitecture)) {
      $hostArchitecture = 'unknown'
    }
    throw "Unsupported architecture '$hostArchitecture'. DartClaw releases currently support Windows x64 only."
  }
}

function Resolve-DartClawReleaseVersion {
  param(
    [string]$RequestedVersion,
    [string]$ArtifactPath
  )

  if (-not [string]::IsNullOrWhiteSpace($RequestedVersion)) {
    return $RequestedVersion.Trim().TrimStart('v')
  }

  if (-not [string]::IsNullOrWhiteSpace($ArtifactPath)) {
    $artifactName = Split-Path -Leaf $ArtifactPath
    if ($artifactName -match '^dartclaw-v(?<version>.+)-windows-x64\.zip$') {
      return $Matches.version
    }
    throw "Unable to infer a release version from local artifact '$artifactName'. Pass -Version explicitly."
  }

  try {
    $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/DartClaw/dartclaw/releases/latest'
  } catch {
    throw "Unable to resolve the latest DartClaw release: $($_.Exception.Message)"
  }
  if ($release.tag_name -notmatch '^v(?<version>.+)$') {
    throw "Latest release returned an invalid tag '$($release.tag_name)'."
  }
  return $Matches.version
}

function Assert-DartClawInstallLayout {
  param([Parameter(Mandatory)][string]$Root)

  foreach ($relativePath in @('VERSION', 'bin/dartclaw.exe', 'lib/sqlite3.dll')) {
    if (-not (Test-Path -LiteralPath (Join-Path $Root $relativePath) -PathType Leaf)) {
      throw "Downloaded archive is missing required file '$relativePath'."
    }
  }
  if (Test-Path -LiteralPath (Join-Path $Root 'share')) {
    throw "Downloaded archive contains an unsupported 'share' sidecar."
  }
}

function Add-DartClawUserPath {
  param([Parameter(Mandatory)][string]$BinPath)

  $current = [Environment]::GetEnvironmentVariable('Path', 'User')
  $entries = @($current -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  $normalizedBin = $BinPath.TrimEnd('\')
  $alreadyPresent = @($entries | Where-Object { $_.Trim().TrimEnd('\') -ieq $normalizedBin })
  if ($alreadyPresent.Count -gt 0) {
    return
  }

  $updated = if ($entries.Count -eq 0) { $BinPath } else { "$($entries -join ';');$BinPath" }
  [Environment]::SetEnvironmentVariable('Path', $updated, 'User')
}

function Invoke-DartClawInstall {
  param(
    [string]$ReleaseVersion,
    [Parameter(Mandatory)][string]$TargetRoot,
    [Parameter(Mandatory)][string]$ReleaseBaseUrl,
    [string]$ArtifactPath
  )

  Assert-DartClawInstallerArchitecture
  $resolvedVersion = Resolve-DartClawReleaseVersion -RequestedVersion $ReleaseVersion -ArtifactPath $ArtifactPath
  $resolvedRoot = [IO.Path]::GetFullPath($TargetRoot)
  $installParent = Split-Path -Parent $resolvedRoot
  if ([string]::IsNullOrWhiteSpace($installParent)) {
    throw "Install root '$TargetRoot' has no parent directory."
  }
  New-Item -ItemType Directory -Path $installParent -Force | Out-Null

  $archiveName = "dartclaw-v$resolvedVersion-windows-x64.zip"
  $workingRoot = Join-Path $installParent ".dartclaw-install-$([guid]::NewGuid())"
  $archive = Join-Path $workingRoot $archiveName
  $checksum = "$archive.sha256"
  $stage = Join-Path $workingRoot 'stage'
  New-Item -ItemType Directory -Path $workingRoot | Out-Null

  try {
    if (-not [string]::IsNullOrWhiteSpace($ArtifactPath)) {
      if (-not (Test-Path -LiteralPath $ArtifactPath -PathType Leaf)) {
        throw "Local DartClaw artifact not found: '$ArtifactPath'."
      }
      $localChecksum = "$ArtifactPath.sha256"
      if (-not (Test-Path -LiteralPath $localChecksum -PathType Leaf)) {
        throw "Local DartClaw checksum not found: '$localChecksum'."
      }
      Copy-Item -LiteralPath $ArtifactPath -Destination $archive
      Copy-Item -LiteralPath $localChecksum -Destination $checksum
    } else {
      $releaseUrl = "$($ReleaseBaseUrl.TrimEnd('/'))/v$resolvedVersion"
      try {
        Invoke-WebRequest -Uri "$releaseUrl/$archiveName" -OutFile $archive
        Invoke-WebRequest -Uri "$releaseUrl/$archiveName.sha256" -OutFile $checksum
      } catch {
        throw "Failed to download DartClaw $resolvedVersion from '$releaseUrl': $($_.Exception.Message)"
      }
    }

    $checksumText = Get-Content -LiteralPath $checksum -Raw
    $expectedMatch = [regex]::Match($checksumText, '(?i)\b[0-9a-f]{64}\b')
    if (-not $expectedMatch.Success) {
      throw "Published checksum file does not contain a valid SHA256 digest."
    }
    $expected = $expectedMatch.Value.ToLowerInvariant()
    $actual = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $expected) {
      throw "Checksum mismatch for '$archiveName': expected $expected, actual $actual. No installation was activated."
    }

    Expand-Archive -LiteralPath $archive -DestinationPath $stage
    Assert-DartClawInstallLayout -Root $stage

    if ((Test-Path -LiteralPath $resolvedRoot) -and -not (Test-Path -LiteralPath $resolvedRoot -PathType Container)) {
      throw "Install root '$resolvedRoot' exists but is not a directory."
    }
    $backup = Join-Path $installParent ".dartclaw-backup-$([guid]::NewGuid())"
    $backupCreated = $false
    try {
      if (Test-Path -LiteralPath $resolvedRoot) {
        Move-Item -LiteralPath $resolvedRoot -Destination $backup
        $backupCreated = $true
      }
      Move-Item -LiteralPath $stage -Destination $resolvedRoot
    } catch {
      $activationError = $_.Exception.Message
      if ($backupCreated -and -not (Test-Path -LiteralPath $resolvedRoot)) {
        try {
          Move-Item -LiteralPath $backup -Destination $resolvedRoot
          $backupCreated = $false
        } catch {
          throw "Failed to activate DartClaw and failed to restore the previous install at '$resolvedRoot': $activationError; rollback: $($_.Exception.Message)"
        }
      }
      throw "Failed to activate DartClaw at '$resolvedRoot'; the previous install was left unchanged: $activationError"
    }

    if ($backupCreated) {
      try {
        Remove-Item -LiteralPath $backup -Recurse -Force
      } catch {
        Write-Warning "DartClaw was upgraded, but the previous install could not be removed from '$backup': $($_.Exception.Message)"
      }
    }

    $binPath = Join-Path $resolvedRoot 'bin'
    try {
      Add-DartClawUserPath -BinPath $binPath
    } catch {
      throw "DartClaw was installed at '$resolvedRoot', but the persistent user PATH update failed: $($_.Exception.Message) Add '$binPath' to your user PATH manually."
    }

    Write-Output "DartClaw $resolvedVersion installed at '$resolvedRoot'."
    Write-Output "Open a new terminal and run 'dartclaw --version'."
  } finally {
    if (Test-Path -LiteralPath $workingRoot) {
      try {
        Remove-Item -LiteralPath $workingRoot -Recurse -Force
      } catch {
        Write-Warning "Temporary installer files could not be removed from '$workingRoot': $($_.Exception.Message)"
      }
    }
  }
}

if ($MyInvocation.InvocationName -ne '.') {
  Invoke-DartClawInstall -ReleaseVersion $Version -TargetRoot $InstallRoot -ReleaseBaseUrl $BaseUrl -ArtifactPath $LocalArtifactPath
}
