[CmdletBinding()]
param([ValidateSet('cpu','cuda','all')][string]$Device = 'all', [int]$Jobs = 4)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$bootstrap = Join-Path $root '.bootstrap'
$llamaCommit = 'f74e2fa6a31cc33ab4ee4ae516641cfe62df3924'
$whisperCommit = 'a8d002cfd879315632a579e73f0148d06959de36'
function Run([string]$Name, [scriptblock]$Action) { & $Action; if ($LASTEXITCODE -ne 0) { throw "$Name failed ($LASTEXITCODE)" } }
foreach ($dep in @(@('llama.cpp',$llamaCommit,'https://github.com/ggml-org/llama.cpp.git'), @('whisper.cpp',$whisperCommit,'https://github.com/ggml-org/whisper.cpp.git'))) {
    $directory = Join-Path $bootstrap $dep[0]
    if (-not (Test-Path -LiteralPath (Join-Path $directory '.git'))) {
        Run 'Initialize native dependency' { git init $directory }
        Run 'Set native dependency remote' { git -C $directory remote add origin $dep[2] }
        Run 'Fetch native dependency' { git -C $directory fetch --depth 1 origin $dep[1] }
        Run 'Checkout native dependency' { git -C $directory checkout --detach $dep[1] }
    }
    $revision = (& git -C $directory rev-parse HEAD).Trim()
    if ($revision -ne $dep[1]) { throw "Expected $($dep[0]) $($dep[1]), found $revision. Dependency checkouts are never overwritten automatically." }
}
$env:VSLANG = '1033'
foreach ($variant in @('cpu','cuda') | Where-Object { $Device -eq 'all' -or $_ -eq $Device }) {
    $gpu = $variant -eq 'cuda'
    $options = @('-G','Visual Studio 17 2022','-A','x64')
    if ($gpu) {
        $nvcc = (Get-Command nvcc -ErrorAction Stop).Source
        $toolkit = Split-Path (Split-Path $nvcc -Parent) -Parent
        $options += @('-T',('cuda=' + $toolkit.Replace('\','/')), '-DRECORDER_CUDA=ON', '-DCMAKE_CUDA_ARCHITECTURES=75;80;86;89;120')
    }
    $hostBuild = Join-Path $bootstrap ('host-' + $variant)
    $whisperBuild = Join-Path $bootstrap ('native-x64-' + $variant)
    Run 'Configure native host' { cmake -S (Join-Path $root 'windows/native-host') -B $hostBuild @options "-DLLAMA_SOURCE=$($bootstrap.Replace('\','/'))/llama.cpp" }
    Run 'Build native host' { cmake --build $hostBuild --config Release --target recorder-native recorder-vad --parallel $Jobs -- /p:UseStructuredOutput=false }
    Run 'Configure Whisper' { cmake -S (Join-Path $root 'windows/native') -B $whisperBuild @options -DRECORDER_AVX2=ON "-DWHISPER_SOURCE=$($bootstrap.Replace('\','/'))/whisper.cpp" }
    Run 'Build Whisper' { cmake --build $whisperBuild --config Release --target recorder-whisper --parallel $Jobs -- /p:UseStructuredOutput=false }
    $destination = Join-Path $bootstrap ('runtime-x64/' + $variant)
    New-Item -ItemType Directory -Force $destination | Out-Null
    Copy-Item -LiteralPath (Join-Path $hostBuild 'Release/recorder-native.exe') -Destination $destination
    Copy-Item -LiteralPath (Join-Path $hostBuild 'Release/recorder-vad.dll') -Destination $destination
    Copy-Item -LiteralPath (Join-Path $whisperBuild 'Release/recorder-whisper.dll') -Destination $destination
    if ($gpu) {
        foreach ($pattern in @('cublas64_*.dll','cublasLt64_*.dll','cudart64_*.dll')) {
            Get-ChildItem -LiteralPath (Join-Path $toolkit 'bin') -Filter $pattern | Copy-Item -Destination $destination
        }
    }
    Write-Output $destination
}
