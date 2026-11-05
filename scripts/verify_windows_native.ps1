[CmdletBinding()]
param([ValidateSet('cpu','cuda')][string]$Device = 'cpu', [string[]]$Models = @('qwen-asr','whisper-turbo','qwen-translate','hunyuan-translate'))
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$dotnet = Join-Path $root '.bootstrap/dotnet10/dotnet.exe'
if (-not (Test-Path -LiteralPath $dotnet)) { $dotnet = (Get-Command dotnet -ErrorAction Stop).Source }
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:DOTNET_ROOT = Split-Path $dotnet -Parent
$project = Join-Path $root 'windows/Recorder.NativeVerify/Recorder.NativeVerify.csproj'
& $dotnet restore $project --locked-mode
if ($LASTEXITCODE -ne 0) { throw 'Restore locked verifier dependencies failed.' }
& $dotnet build $project -c Release --no-restore
if ($LASTEXITCODE -ne 0) { throw 'Build native verifier failed; install .NET 10 SDK and Windows Desktop runtime.' }
$assembly = Join-Path $root 'windows/Recorder.NativeVerify/bin/Release/net10.0-windows/Recorder.NativeVerify.dll'
$hostExe = Join-Path $root ('.bootstrap/runtime-x64/' + $Device + '/recorder-native.exe')
& $dotnet $assembly --transport $hostExe
if ($LASTEXITCODE -ne 0) { throw 'Native transport tests failed' }
foreach ($id in $Models) {
    & $dotnet $assembly $hostExe (Join-Path $root '.bootstrap/verification-models') $root $Device $id
    if ($LASTEXITCODE -ne 0) { throw "Native model verification failed: $id ($Device)" }
}
