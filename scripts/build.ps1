param(
  [ValidateSet('debug','release')][string]$BuildMode = 'debug',
  [string]$DevEcoRoot = $env:DEVECO_ROOT
)
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($DevEcoRoot) -or -not (Test-Path -LiteralPath $DevEcoRoot)) {
  throw 'Set DEVECO_ROOT or pass -DevEcoRoot with your DevEco Studio installation directory.'
}
$projectRoot = Split-Path -Parent $PSScriptRoot
$env:npm_config_cache = Join-Path $projectRoot '.npm-cache'
$env:DEVECO_SDK_HOME = Join-Path $DevEcoRoot 'sdk'
$env:OHOS_SDK_HOME = Join-Path $DevEcoRoot 'sdk\default\openharmony'
$env:PATH = (Join-Path $DevEcoRoot 'tools\node') + ';' +
  (Join-Path $DevEcoRoot 'tools\ohpm\bin') + ';' +
  (Join-Path $DevEcoRoot 'tools\hvigor\bin') + ';' + $env:PATH
$buildArguments = @('--mode','module','-p','product=default','-p','module=entry@default',
  '-p',"buildMode=$BuildMode",'assembleHap','--no-daemon')
Push-Location $projectRoot
try {
  & (Join-Path $DevEcoRoot 'tools\hvigor\bin\hvigorw.bat') @buildArguments
  if ($LASTEXITCODE -ne 0) { throw "Hvigor build failed: $LASTEXITCODE" }
} finally { Pop-Location }
