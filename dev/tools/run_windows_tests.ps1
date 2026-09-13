Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '../..')
$exitCode = 1
Push-Location $repoRoot
try {
  & dart test --reporter=failures-only @args
  $exitCode = $LASTEXITCODE
} finally {
  Pop-Location
}

exit ${exitCode}
