param(
  [Parameter(Mandatory=$true)][string]$Target,
  [string]$DevEcoRoot = $env:DEVECO_ROOT,
  [switch]$SkipBuild
)
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($DevEcoRoot) -or -not (Test-Path -LiteralPath $DevEcoRoot)) {
  throw 'Set DEVECO_ROOT or pass -DevEcoRoot with your DevEco Studio installation directory.'
}
$projectRoot = Split-Path -Parent $PSScriptRoot
$hap = Join-Path $projectRoot 'entry\build\default\outputs\default\entry-default-signed.hap'
if (-not $SkipBuild) {
  & (Join-Path $PSScriptRoot 'build.ps1') -DevEcoRoot $DevEcoRoot
}
if (-not (Test-Path -LiteralPath $hap)) {
  throw 'No signed HAP. Open this project in DevEco Studio, enable automatic signing for com.mz.sonyremote, then build again.'
}
$hdc = Join-Path $DevEcoRoot 'sdk\default\openharmony\toolchains\hdc.exe'
& $hdc tconn $Target
if ($LASTEXITCODE -ne 0) { throw 'HDC connection failed' }
& $hdc -t $Target install -r $hap
if ($LASTEXITCODE -ne 0) { throw 'HAP installation failed' }
& $hdc -t $Target shell aa start -a EntryAbility -b com.mz.sonyremote
if ($LASTEXITCODE -ne 0) { throw 'App launch failed' }
