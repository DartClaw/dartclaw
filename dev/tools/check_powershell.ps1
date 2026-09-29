[CmdletBinding()]
param(
  [switch]$InstallAnalyzer
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:RootDir = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$script:RequiredAnalyzerVersion = [version]'1.25.0'

$previousErrorActionPreference = $ErrorActionPreference
try {
  $ErrorActionPreference = 'Continue'
  $scripts = @(& git -C $script:RootDir ls-files -- '*.ps1' 2>$null)
  $gitExitCode = $LASTEXITCODE
} finally {
  $ErrorActionPreference = $previousErrorActionPreference
}

if ($gitExitCode -ne 0) {
  throw "Unable to list tracked PowerShell scripts from '$script:RootDir'."
}
if ($scripts.Count -eq 0) {
  throw 'No tracked .ps1 files found.'
}

$parseFailures = @()
foreach ($scriptPath in $scripts) {
  $absolutePath = Join-Path $script:RootDir $scriptPath
  if (-not (Test-Path -LiteralPath $absolutePath -PathType Leaf)) {
    throw "Tracked PowerShell script is missing: $scriptPath"
  }

  $parseErrors = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile(
    $absolutePath, [ref]$null, [ref]$parseErrors)
  $parseErrors = @($parseErrors)
  if ($parseErrors.Count -gt 0) {
    $parseFailures += $scriptPath
    foreach ($parseError in $parseErrors) {
      Write-Host "$scriptPath`:$($parseError.Extent.StartLineNumber): $($parseError.Message)"
    }
  }
}

Write-Host "Parsed $($scripts.Count) tracked PowerShell script(s)."
if ($parseFailures.Count -gt 0) {
  throw "Parse errors in: $($parseFailures -join ', ')"
}

$analyzerModule = Get-Module -ListAvailable -Name PSScriptAnalyzer |
  Where-Object { $_.Version -eq $script:RequiredAnalyzerVersion } |
  Select-Object -First 1
if ($null -eq $analyzerModule -and $InstallAnalyzer) {
  Install-Module PSScriptAnalyzer `
    -RequiredVersion $script:RequiredAnalyzerVersion `
    -Force `
    -Scope CurrentUser `
    -Repository PSGallery
  $analyzerModule = Get-Module -ListAvailable -Name PSScriptAnalyzer |
    Where-Object { $_.Version -eq $script:RequiredAnalyzerVersion } |
    Select-Object -First 1
}
if ($null -eq $analyzerModule) {
  throw "PSScriptAnalyzer $script:RequiredAnalyzerVersion is required. Run this script with -InstallAnalyzer."
}
$loadedAnalyzer = Import-Module $analyzerModule.Path -Force -PassThru -ErrorAction Stop
if ($loadedAnalyzer.Version -ne $script:RequiredAnalyzerVersion) {
  throw "Loaded PSScriptAnalyzer $($loadedAnalyzer.Version), expected $script:RequiredAnalyzerVersion."
}

$findings = @()
foreach ($scriptPath in $scripts) {
  $absolutePath = Join-Path $script:RootDir $scriptPath
  $findings += @(Invoke-ScriptAnalyzer -Path $absolutePath -Severity Error)
}

if ($findings.Count -gt 0) {
  $findings | Format-Table -AutoSize | Out-String | Write-Host
  throw "PSScriptAnalyzer reported $($findings.Count) error-severity finding(s)."
}
Write-Host "PSScriptAnalyzer $($script:RequiredAnalyzerVersion): no error-severity findings."
