[CmdletBinding()]
param([switch]$SkipNative, [switch]$SkipTests, [switch]$SkipInstaller, [string]$InnoCompiler)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$bootstrap = Join-Path $repoRoot '.bootstrap'
$publish = Join-Path $repoRoot 'dist/windows-x64'
$dotnet = Join-Path $bootstrap 'dotnet10/dotnet.exe'
if (-not (Test-Path -LiteralPath $dotnet)) { $dotnet = (Get-Command dotnet -ErrorAction Stop).Source }
function Run([string]$Name, [scriptblock]$Action) { & $Action; if ($LASTEXITCODE -ne 0) { throw "$Name failed ($LASTEXITCODE)" } }
function Assert-X64([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    try { $reader = [IO.BinaryReader]::new($stream); $stream.Position = 0x3c; $offset = $reader.ReadInt32(); $stream.Position = $offset; if ($reader.ReadUInt32() -ne 0x4550 -or $reader.ReadUInt16() -ne 0x8664) { throw "Not an x64 PE: $Path" } } finally { $stream.Dispose() }
}
Push-Location $repoRoot
try {
    $env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
    if (-not $SkipNative) { & "$PSScriptRoot/build_windows_native.ps1" }
    foreach ($device in @('cpu','cuda')) { foreach ($binary in @('recorder-native.exe','recorder-whisper.dll','recorder-vad.dll','recorder-audio.dll')) { Assert-X64 (Join-Path $bootstrap "runtime-x64/$device/$binary") } }
    $redist = Get-ChildItem -Path 'C:/Program Files (x86)/Microsoft Visual Studio/2022/BuildTools/VC/Redist/MSVC' -Directory | Where-Object Name -Match '^14\.' | Sort-Object Name -Descending | Select-Object -First 1
    if (-not $redist) { throw 'VC x64 app-local redistributables not found.' }
    Get-ChildItem -LiteralPath (Join-Path $redist.FullName 'x64/Microsoft.VC143.CRT') -Filter '*.dll' | Copy-Item -Destination (Join-Path $bootstrap 'runtime-x64/cuda')
    Run 'Restore locked x64 packages' { & $dotnet restore windows/Recorder.Full --locked-mode }
    if (-not $SkipTests) {
        & "$PSScriptRoot/test_windows_backend.ps1"
        Run 'Restore x64 desktop tests' { & $dotnet restore windows/Recorder.FullTests --locked-mode }
        Run 'Build x64 desktop tests' { & $dotnet build windows/Recorder.FullTests -c Release --no-restore -o (Join-Path $bootstrap 'release-tests') }
        Run 'Run x64 desktop tests' { & (Join-Path $bootstrap 'release-tests/Recorder.FullTests.exe') }
    }
    Run 'Publish self-contained x64 app' { & $dotnet publish windows/Recorder.Full -c Release --no-restore -o $publish }
    Copy-Item -LiteralPath LICENSE -Destination $publish
    Copy-Item -LiteralPath windows/INSTALL-NOTES-x64.txt -Destination (Join-Path $publish 'INSTALL-NOTES.txt')
    Copy-Item -LiteralPath windows/WINDOWS-VALIDATION.md,windows/THIRD-PARTY-NOTICES-x64.txt -Destination $publish
    Copy-Item -LiteralPath .bootstrap/llama.cpp/LICENSE -Destination (Join-Path $publish 'LLAMA-LICENSE.txt')
    Copy-Item -LiteralPath .bootstrap/whisper.cpp/LICENSE -Destination (Join-Path $publish 'WHISPER-LICENSE.txt')
    Copy-Item -Path windows/licenses/*.txt -Destination $publish
    Copy-Item -Path windows/licenses/x64/*.txt -Destination $publish
    Copy-Item -LiteralPath 'C:/Program Files/NVIDIA GPU Computing Toolkit/CUDA/v12.8/EULA.txt' -Destination (Join-Path $publish 'CUDA-EULA.txt')
    Assert-X64 (Join-Path $publish 'Shengjian.exe')
    $manifest = Get-ChildItem -LiteralPath $publish -File -Recurse | Where-Object Name -NE 'FILES.sha256' | Sort-Object FullName | ForEach-Object { (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() + '  ' + [IO.Path]::GetRelativePath($publish, $_.FullName).Replace('\','/') }
    $manifest | Set-Content -LiteralPath (Join-Path $publish 'FILES.sha256') -Encoding utf8
    $zip = Join-Path $repoRoot 'dist/Shengjian-0.6.0-windows-x64-preview-portable.zip'
    Compress-Archive -Path (Join-Path $publish '*') -DestinationPath $zip -Force
    $artifacts = @($zip)
    if (-not $SkipInstaller) {
        if (-not $InnoCompiler) { $InnoCompiler = Join-Path $bootstrap 'inno/ISCC.exe' }
        Run 'Build x64 installer' { & $InnoCompiler "/DPublishDir=$publish" "/DOutputDir=$(Join-Path $repoRoot 'dist')" windows/installer/Recorder-x64.iss }
        $artifacts += Join-Path $repoRoot 'dist/Shengjian-0.6.0-windows-x64-preview-setup.exe'
    }
    foreach ($artifact in $artifacts) { (Get-FileHash -LiteralPath $artifact -Algorithm SHA256).Hash.ToLowerInvariant() + '  ' + [IO.Path]::GetFileName($artifact) | Set-Content -LiteralPath ($artifact + '.sha256') -Encoding ascii; Write-Output $artifact }
} finally { Pop-Location }
