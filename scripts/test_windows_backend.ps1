[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$dotnet = Join-Path $root '.bootstrap/dotnet10/dotnet.exe'
if (-not (Test-Path -LiteralPath $dotnet)) { $dotnet = (Get-Command dotnet -ErrorAction Stop).Source }
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:DOTNET_ROOT = Split-Path $dotnet -Parent
$project = Join-Path $root 'windows/Recorder.BackendTests/Recorder.BackendTests.csproj'
& $dotnet restore $project --locked-mode
if ($LASTEXITCODE -ne 0) { throw 'Restore backend test dependencies failed' }
& $dotnet run --project $project -c Release --no-restore -- $root
if ($LASTEXITCODE -ne 0) { throw 'Backend tests failed' }
