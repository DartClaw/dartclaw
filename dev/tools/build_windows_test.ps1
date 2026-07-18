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

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) "dartclaw-windows-build-test-$([guid]::NewGuid())"
New-Item -ItemType Directory -Path (Join-Path $tempRoot 'bin') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $tempRoot 'lib') -Force | Out-Null
Set-Content -LiteralPath (Join-Path $tempRoot 'VERSION') -Value '0.0.0'
Set-Content -LiteralPath (Join-Path $tempRoot 'bin/dartclaw.exe') -Value 'placeholder'
Set-Content -LiteralPath (Join-Path $tempRoot 'lib/sqlite3.dll') -Value 'placeholder'

try {
  Assert-WindowsReleaseLayout -Root $tempRoot

  $rawBundle = Join-Path $tempRoot 'raw-bundle'
  New-Item -ItemType Directory -Path (Join-Path $rawBundle 'bin') -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $rawBundle 'lib') -Force | Out-Null
  Set-Content -LiteralPath (Join-Path $rawBundle 'bin/dartclaw.exe') -Value 'placeholder'
  Set-Content -LiteralPath (Join-Path $rawBundle 'lib/sqlite3.dll') -Value 'placeholder'
  Assert-WindowsBuildBundle -Root $rawBundle

  foreach ($case in @(
      @{ Path = 'VERSION'; Message = 'missing VERSION' },
      @{ Path = 'bin/dartclaw.exe'; Message = 'missing bin/dartclaw.exe' },
      @{ Path = 'lib/sqlite3.dll'; Message = 'missing lib/sqlite3.dll' }
    )) {
    $path = Join-Path $tempRoot $case.Path
    $backup = "$path.bak"
    Move-Item -LiteralPath $path -Destination $backup
    Assert-FailsWith -Message $case.Message -Action { Assert-WindowsReleaseLayout -Root $tempRoot }
    Move-Item -LiteralPath $backup -Destination $path
  }

  New-Item -ItemType Directory -Path (Join-Path $tempRoot 'share') | Out-Null
  Assert-FailsWith -Message 'unexpected share/ sidecar' -Action { Assert-WindowsReleaseLayout -Root $tempRoot }
  Remove-Item -LiteralPath (Join-Path $tempRoot 'share') -Recurse

  $badSmoke = Join-Path $tempRoot 'bad-smoke.cmd'
  Set-Content -LiteralPath $badSmoke -Value '@exit /b 7'
  Assert-FailsWith -Message 'dartclaw.exe --help smoke failed' -Action {
    Invoke-WindowsExecutableSmoke -Executable $badSmoke
  }
  Assert-FailsWith -Message 'bundled SQLite module/FTS5 check failed' -Action {
    Invoke-WindowsSqliteCheck -Executable $badSmoke -SqliteModule (Join-Path $tempRoot 'lib/sqlite3.dll')
  }
} finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force
}

Write-Output 'Windows build validation failure-path tests passed.'
exit 0
