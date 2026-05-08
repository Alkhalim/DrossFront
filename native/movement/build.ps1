# Wrapper: load MSVC environment, run scons. Pass any scons args through.
# Usage:
#   pwsh -File native/movement/build.ps1                                 # default: this dir, debug
#   pwsh -File native/movement/build.ps1 platform=windows target=template_release
#   pwsh -File native/movement/build.ps1 -WorkDir native/movement/tests  # build tests
#   pwsh -File native/movement/build.ps1 -c                              # clean

param(
    [string]$WorkDir = $null,
    [Parameter(ValueFromRemainingArguments=$true)][string[]]$SconsArgs
)
$ErrorActionPreference = "Stop"
$vcvars = "D:\Programme\Virtual Studio Build Tools\VC\Auxiliary\Build\vcvars64.bat"
if (-not (Test-Path $vcvars)) {
    Write-Error "vcvars64.bat not found at $vcvars. Install MSVC Build Tools or update this path."
    exit 1
}
if (-not $WorkDir) { $WorkDir = $PSScriptRoot }
$WorkDir = (Resolve-Path $WorkDir).Path
$argString = if ($SconsArgs) { $SconsArgs -join ' ' } else { "platform=windows target=template_debug" }
cmd /c "`"$vcvars`" && cd /d `"$WorkDir`" && scons $argString"
exit $LASTEXITCODE
