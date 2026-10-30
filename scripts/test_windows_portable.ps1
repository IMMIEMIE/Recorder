[CmdletBinding()]
param([int]$Rounds = 60)
# Model-free checks: language/model switch stress against Recorder.FakeNative and the on-demand CUDA runtime installer.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$dotnet = Join-Path $root '.bootstrap/dotnet10/dotnet.exe'
if (-not (Test-Path -LiteralPath $dotnet)) { $dotnet = (Get-Command dotnet -ErrorAction Stop).Source }
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$fake = Join-Path $root '.bootstrap/fake-native'
& $dotnet build (Join-Path $root 'windows/Recorder.FakeNative') -c Release -o $fake
if ($LASTEXITCODE -ne 0) { throw 'Build fake native worker failed' }
& $dotnet build (Join-Path $root 'windows/Recorder.PortableTests') -c Release
if ($LASTEXITCODE -ne 0) { throw 'Build portable tests failed' }
& $dotnet (Join-Path $root 'windows/Recorder.PortableTests/bin/Release/net10.0-windows/Recorder.PortableTests.dll') $fake $root --rounds $Rounds
if ($LASTEXITCODE -ne 0) { throw 'Portable checks failed' }
