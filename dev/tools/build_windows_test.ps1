Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'build_windows.ps1')

Assert-NoSystemSqliteOverride

function Assert-FailsWith {
  param(
    [Parameter(Mandatory)][scriptblock]$Action,
    [Parameter(Mandatory)][string]$Message
  )

  try {
    & $Action
  } catch {
    if ($_.Exception.Message -notlike "*$Message*") {
      throw "Expected failure containing '$Message', got '$($_.Exception.Message)'."
    }
    return
  }
  throw "Expected failure containing '$Message', but the action passed."
}

foreach ($binaryName in @('dartclaw', 'dartclaw-workflow')) {
  $tempRoot = Join-Path ([IO.Path]::GetTempPath()) "dartclaw-windows-build-test-$([guid]::NewGuid())"
  New-Item -ItemType Directory -Path (Join-Path $tempRoot 'bin') -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $tempRoot 'lib') -Force | Out-Null
  Set-Content -LiteralPath (Join-Path $tempRoot 'VERSION') -Value '0.0.0'
  Set-Content -LiteralPath (Join-Path $tempRoot "bin/$binaryName.exe") -Value 'placeholder'
  Set-Content -LiteralPath (Join-Path $tempRoot 'lib/sqlite3.dll') -Value 'placeholder'

  $rawBundle = $null
  try {
    Assert-WindowsReleaseLayout -Root $tempRoot -BinaryName $binaryName

    $rawBundle = Join-Path ([IO.Path]::GetTempPath()) "dartclaw-raw-bundle-$([guid]::NewGuid())"
    New-Item -ItemType Directory -Path (Join-Path $rawBundle 'bin') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $rawBundle 'lib') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $rawBundle "bin/$binaryName.exe") -Value 'placeholder'
    Set-Content -LiteralPath (Join-Path $rawBundle 'lib/sqlite3.dll') -Value 'placeholder'
    Assert-WindowsBuildBundle -Root $rawBundle -BinaryName $binaryName
    if ($binaryName -eq 'dartclaw') {
      Assert-WindowsReleaseLayout -Root $tempRoot
      Assert-WindowsBuildBundle -Root $rawBundle
    }
    Remove-Item -LiteralPath (Join-Path $rawBundle 'lib/sqlite3.dll')
    Assert-FailsWith -Message 'missing lib/sqlite3.dll' -Action {
      Assert-WindowsBuildBundle -Root $rawBundle -BinaryName $binaryName
    }

    foreach ($case in @(
        @{ Path = 'VERSION'; Message = 'missing VERSION' },
        @{ Path = "bin/$binaryName.exe"; Message = "missing bin/$binaryName.exe" },
        @{ Path = 'lib/sqlite3.dll'; Message = 'missing lib/sqlite3.dll' }
      )) {
      $path = Join-Path $tempRoot $case.Path
      $backup = "$path.bak"
      Move-Item -LiteralPath $path -Destination $backup
      Assert-FailsWith -Message $case.Message -Action { Assert-WindowsReleaseLayout -Root $tempRoot -BinaryName $binaryName }
      Move-Item -LiteralPath $backup -Destination $path
    }

    New-Item -ItemType Directory -Path (Join-Path $tempRoot 'share') | Out-Null
    Assert-FailsWith -Message 'unexpected share/ sidecar' -Action { Assert-WindowsReleaseLayout -Root $tempRoot -BinaryName $binaryName }
    Remove-Item -LiteralPath (Join-Path $tempRoot 'share') -Recurse

    $badSmoke = Join-Path $tempRoot 'bad-smoke.cmd'
    Set-Content -LiteralPath $badSmoke -Value '@exit /b 7'
    Assert-FailsWith -Message "$binaryName.exe --help smoke failed" -Action {
      Invoke-WindowsExecutableSmoke -Executable $badSmoke -BinaryName $binaryName
    }
    Assert-FailsWith -Message 'bundled SQLite FTS5 check failed with exit code 7' -Action {
      Invoke-WindowsBundledSqliteCheck -Executable $badSmoke -BinaryName $binaryName
    }

    $silentPass = Join-Path $tempRoot 'silent-pass.cmd'
    Set-Content -LiteralPath $silentPass -Value '@exit /b 0'
    Assert-FailsWith -Message 'did not rebuild the index' -Action {
      Invoke-WindowsBundledSqliteCheck -Executable $silentPass -BinaryName $binaryName
    }

    $rebuilt = Join-Path $tempRoot 'rebuilt.cmd'
    Set-Content -LiteralPath $rebuilt -Value @('@echo Rebuilt index: 1 entries at collection revision 1; health=healthy', '@exit /b 0')
    Invoke-WindowsBundledSqliteCheck -Executable $rebuilt -BinaryName $binaryName

    $checksumArtifact = Join-Path $tempRoot 'checksum-test.zip'
    [IO.File]::WriteAllBytes($checksumArtifact, [byte[]](0, 1, 2, 3))
    Write-ChecksumSidecar -Artifact $checksumArtifact
    $checksumBytes = [IO.File]::ReadAllBytes("$checksumArtifact.sha256")
    $checksumText = [Text.Encoding]::UTF8.GetString($checksumBytes)
    $expectedHash = (Get-FileHash -LiteralPath $checksumArtifact -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($checksumText -cne "$expectedHash  checksum-test.zip`n") {
      throw 'Checksum sidecar must be UTF-8 without BOM and use one LF-terminated line.'
    }
    if ($checksumBytes[0] -eq 0xEF -or $checksumText.Contains("`r")) {
      throw 'Checksum sidecar contains a BOM or CRLF.'
    }
  } finally {
    if ($null -ne $rawBundle -and (Test-Path -LiteralPath $rawBundle)) {
      Remove-Item -LiteralPath $rawBundle -Recurse -Force
    }
    Remove-Item -LiteralPath $tempRoot -Recurse -Force
  }
}

Write-Output 'Windows build validation failure-path tests passed.'
exit 0
