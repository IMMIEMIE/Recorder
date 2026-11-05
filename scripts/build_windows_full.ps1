[CmdletBinding()]
param(
    [switch]$SkipNative, [switch]$SkipTests, [switch]$SkipInstaller, [string]$InnoCompiler,
    # Offline package: also ship NVIDIA cudart/cuBLAS (~790 MB). By default the app downloads them on first CUDA use.
    [switch]$BundleCudaRuntime,
    # Smaller self-contained edition for CPU/cloud use; no NVIDIA acceleration kernels.
    [switch]$CpuOnly,
    # Uncompressed size budget for the default package; exceeding it fails the build so regressions are noticed.
    [int]$MaxPackageMiB = 300
)
$version = '0.6.12'
if ($CpuOnly -and $BundleCudaRuntime) { throw '-CpuOnly cannot be combined with -BundleCudaRuntime.' }
$suffix = if ($CpuOnly) { 'preview-cpu' } elseif ($BundleCudaRuntime) { 'preview-offline' } else { 'preview' }
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$bootstrap = Join-Path $repoRoot '.bootstrap'
$publish = [IO.Path]::GetFullPath((Join-Path $repoRoot $(if ($CpuOnly) { 'dist/windows-x64-cpu' } else { 'dist/windows-x64' })))
$expectedPublishRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot 'dist')) + [IO.Path]::DirectorySeparatorChar
if (-not $publish.StartsWith($expectedPublishRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Publish directory must be inside this repository/dist.' }
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
    & "$PSScriptRoot/make_windows_icon.ps1"
    if (-not $SkipNative) { & "$PSScriptRoot/build_windows_native.ps1" -Device $(if ($CpuOnly) { 'cpu' } else { 'all' }) -BundleCudaRuntime:$BundleCudaRuntime }
    $devices = if ($CpuOnly) { @('cpu') } else { @('cpu','cuda') }
    foreach ($device in $devices) { foreach ($binary in @('recorder-native.exe','recorder-whisper.dll','recorder-vad.dll','recorder-audio.dll')) { Assert-X64 (Join-Path $bootstrap "runtime-x64/$device/$binary") } }
    if ($BundleCudaRuntime -and -not (Test-Path -LiteralPath (Join-Path $bootstrap 'runtime-x64/cuda/cublasLt64_12.dll'))) { throw 'Offline package requested but runtime-x64/cuda has no CUDA libraries; rerun with native build.' }
    if (-not $CpuOnly) {
        $redist = Get-ChildItem -Path 'C:/Program Files (x86)/Microsoft Visual Studio/2022/BuildTools/VC/Redist/MSVC' -Directory | Where-Object Name -Match '^14\.' | Sort-Object Name -Descending | Select-Object -First 1
        if (-not $redist) { throw 'VC x64 app-local redistributables not found.' }
        Get-ChildItem -LiteralPath (Join-Path $redist.FullName 'x64/Microsoft.VC143.CRT') -Filter '*.dll' | Copy-Item -Destination (Join-Path $bootstrap 'runtime-x64/cuda')
    }
    Run 'Restore locked x64 packages' { & $dotnet restore windows/Recorder.Full --locked-mode }
    if (-not $SkipTests) {
        & "$PSScriptRoot/test_windows_backend.ps1"
        Run 'Restore x64 desktop tests' { & $dotnet restore windows/Recorder.FullTests --locked-mode }
        Run 'Build x64 desktop tests' { & $dotnet build windows/Recorder.FullTests -c Release --no-restore -o (Join-Path $bootstrap 'release-tests') }
        Run 'Run x64 desktop tests' { & (Join-Path $bootstrap 'release-tests/Recorder.FullTests.exe') }
        & "$PSScriptRoot/test_windows_portable.ps1"
    }
    if (Test-Path -LiteralPath $publish) { Remove-Item -LiteralPath $publish -Recurse -Force }
    Run 'Publish self-contained x64 app' { & $dotnet publish windows/Recorder.Full -c Release --no-restore -o $publish "-p:BundleCudaRuntime=$($BundleCudaRuntime.IsPresent.ToString().ToLowerInvariant())" "-p:IncludeCudaKernels=$((!$CpuOnly.IsPresent).ToString().ToLowerInvariant())" }
    Copy-Item -LiteralPath LICENSE -Destination $publish
    Copy-Item -LiteralPath windows/INSTALL-NOTES-x64.txt -Destination (Join-Path $publish 'INSTALL-NOTES.txt')
    if ($CpuOnly) { "此包为 CPU 精简版：支持 CPU 本地推理及云端服务，不含 NVIDIA GPU 推理内核。需要 GPU 加速请安装标准版。`r`n`r`n" + (Get-Content -LiteralPath (Join-Path $publish 'INSTALL-NOTES.txt') -Raw) | Set-Content -LiteralPath (Join-Path $publish 'INSTALL-NOTES.txt') -Encoding utf8 }
    Copy-Item -LiteralPath windows/WINDOWS-VALIDATION.md,windows/THIRD-PARTY-NOTICES-x64.txt -Destination $publish
    Copy-Item -LiteralPath .bootstrap/llama.cpp/LICENSE -Destination (Join-Path $publish 'LLAMA-LICENSE.txt')
    Copy-Item -LiteralPath .bootstrap/whisper.cpp/LICENSE -Destination (Join-Path $publish 'WHISPER-LICENSE.txt')
    Copy-Item -Path windows/licenses/*.txt -Destination $publish
    Copy-Item -Path windows/licenses/x64/*.txt -Destination $publish
    if ($BundleCudaRuntime) { Copy-Item -LiteralPath 'C:/Program Files/NVIDIA GPU Computing Toolkit/CUDA/v12.8/EULA.txt' -Destination (Join-Path $publish 'CUDA-EULA.txt') }
    Assert-X64 (Join-Path $publish 'Shengjian.exe')
    $vendor = @(Get-ChildItem -LiteralPath $publish -Recurse -File -Include 'cublas*.dll','cudart*.dll','nvblas*.dll')
    if (-not $BundleCudaRuntime -and $vendor.Count -gt 0) { throw "Default package must not contain CUDA vendor libraries: $($vendor.Name -join ', ')" }
    $files = Get-ChildItem -LiteralPath $publish -Recurse -File
    $totalMiB = [math]::Round(($files | Measure-Object Length -Sum).Sum / 1MB, 1)
    Write-Output "Package size: $totalMiB MiB uncompressed. Largest files:"
    $files | Sort-Object Length -Descending | Select-Object -First 12 | ForEach-Object { '{0,10:N1} MiB  {1}' -f ($_.Length / 1MB), [IO.Path]::GetRelativePath($publish, $_.FullName) }
    if (-not $BundleCudaRuntime -and $totalMiB -gt $MaxPackageMiB) { throw "Package is $totalMiB MiB, above the $MaxPackageMiB MiB budget. Check CUDA architectures and bundled files." }
    $manifest = Get-ChildItem -LiteralPath $publish -File -Recurse | Where-Object Name -NE 'FILES.sha256' | Sort-Object FullName | ForEach-Object { (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() + '  ' + [IO.Path]::GetRelativePath($publish, $_.FullName).Replace('\','/') }
    $manifest | Set-Content -LiteralPath (Join-Path $publish 'FILES.sha256') -Encoding utf8
    $zip = Join-Path $repoRoot "dist/Shengjian-$version-windows-x64-$suffix-portable.zip"
    # .NET's smallest-size deflate saves download bytes without changing the runtime layout.
    if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
    [IO.Compression.ZipFile]::CreateFromDirectory($publish, $zip, [IO.Compression.CompressionLevel]::SmallestSize, $false)
    $artifacts = @($zip)
    if (-not $SkipInstaller) {
        if (-not $InnoCompiler) { $InnoCompiler = Join-Path $bootstrap 'inno/ISCC.exe' }
        Run 'Build x64 installer' { & $InnoCompiler "/DPublishDir=$publish" "/DOutputDir=$(Join-Path $repoRoot 'dist')" "/DAppVersion=$version" "/DOutputName=Shengjian-$version-windows-x64-$suffix-setup" "/DCpuOnly=$([int]$CpuOnly.IsPresent)" windows/installer/Recorder-x64.iss }
        $artifacts += Join-Path $repoRoot "dist/Shengjian-$version-windows-x64-$suffix-setup.exe"
    }
    foreach ($artifact in $artifacts) { (Get-FileHash -LiteralPath $artifact -Algorithm SHA256).Hash.ToLowerInvariant() + '  ' + [IO.Path]::GetFileName($artifact) | Set-Content -LiteralPath ($artifact + '.sha256') -Encoding ascii; Write-Output $artifact }
} finally { Pop-Location }
