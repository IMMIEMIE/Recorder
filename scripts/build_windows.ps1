[CmdletBinding()]
param([switch]$SkipTests, [switch]$SkipInstaller, [string]$InnoCompiler)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$bootstrap = Join-Path $repoRoot '.bootstrap'
$whisper = Join-Path $bootstrap 'whisper.cpp'
$native = Join-Path $bootstrap 'native-x86'
$publish = Join-Path $repoRoot 'dist\windows-x86'
$whisperCommit = 'a8d002cfd879315632a579e73f0148d06959de36'

function Check-Exit([string]$action) { if ($LASTEXITCODE -ne 0) { throw "$action failed with exit code $LASTEXITCODE" } }
function Assert-X86([string]$path) {
    $stream = [IO.File]::OpenRead($path)
    try {
        $reader = [IO.BinaryReader]::new($stream)
        $stream.Position = 0x3c
        $offset = $reader.ReadInt32()
        $stream.Position = $offset
        if ($reader.ReadUInt32() -ne 0x4550 -or $reader.ReadUInt16() -ne 0x14c) { throw "Not an x86 PE: $path" }
    } finally { $stream.Dispose() }
}
Push-Location $repoRoot
try {
    $env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
    New-Item -ItemType Directory -Force $bootstrap, $publish | Out-Null
    if (-not (Test-Path (Join-Path $whisper '.git'))) {
        & git clone --depth 1 --branch v1.7.6 https://github.com/ggml-org/whisper.cpp.git $whisper
        Check-Exit 'Clone whisper.cpp'
    }
    $actual = (& git -C $whisper rev-parse HEAD).Trim()
    Check-Exit 'Read whisper revision'
    if ($actual -ne $whisperCommit) { throw "Expected whisper.cpp $whisperCommit, got $actual" }
    & cmake -S windows/native -B $native -G 'Visual Studio 17 2022' -A Win32 "-DWHISPER_SOURCE=$($whisper.Replace('\','/'))"
    Check-Exit 'Configure native x86 engine'
    & cmake --build $native --config Release --parallel
    Check-Exit 'Build native x86 engine'
    & dotnet restore windows/Recorder.Windows --locked-mode
    Check-Exit 'Restore locked application packages'
    if (-not $SkipTests) {
        & dotnet restore windows/Recorder.Tests --locked-mode
        Check-Exit 'Restore locked test packages'
        & dotnet build windows/Recorder.Tests -c Release --no-restore
        Check-Exit 'Build tests'
        & '.\windows\Recorder.Tests\bin\Release\net8.0-windows\win-x86\Recorder.Tests.exe'
        Check-Exit 'Run Windows tests'
    }
    & dotnet publish windows/Recorder.Windows -c Release --no-restore -o $publish
    Check-Exit 'Publish self-contained win-x86 application'
    Assert-X86 (Join-Path $publish 'Shengjian.exe')
    Assert-X86 (Join-Path $publish 'recorder-whisper.dll')
    Copy-Item -LiteralPath (Join-Path $repoRoot 'LICENSE') -Destination $publish
    Copy-Item -LiteralPath (Join-Path $repoRoot 'windows\INSTALL-NOTES.txt') -Destination $publish
    Copy-Item -LiteralPath (Join-Path $whisper 'LICENSE') -Destination (Join-Path $publish 'WHISPER-LICENSE.txt')
    Copy-Item -LiteralPath (Join-Path $repoRoot 'windows\THIRD-PARTY-NOTICES.txt') -Destination $publish
    Copy-Item -Path (Join-Path $repoRoot 'windows\licenses\*.txt') -Destination $publish
    $zip = Join-Path $repoRoot 'dist\Shengjian-0.5.0-windows-x86-portable.zip'
    Compress-Archive -Path (Join-Path $publish '*') -DestinationPath $zip -Force
    $artifacts = @($zip)
    if (-not $SkipInstaller) {
        if (-not $InnoCompiler) {
            $candidates = @((Join-Path $bootstrap 'inno\ISCC.exe'), (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'))
            $InnoCompiler = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
        }
        if (-not $InnoCompiler) { throw 'Install Inno Setup 6.5.4 and pass -InnoCompiler <ISCC.exe>, or use -SkipInstaller.' }
        & $InnoCompiler "/DPublishDir=$publish" "/DOutputDir=$(Join-Path $repoRoot 'dist')" windows/installer/Recorder.iss
        Check-Exit 'Build installer'
        $installer = Join-Path $repoRoot 'dist\Shengjian-0.5.0-windows-x86-setup.exe'
        Assert-X86 $installer
        $artifacts += $installer
    }
    foreach ($artifact in $artifacts) {
        $hash = (Get-FileHash -LiteralPath $artifact -Algorithm SHA256).Hash.ToLowerInvariant()
        "$hash  $([IO.Path]::GetFileName($artifact))" | Set-Content -LiteralPath ($artifact + '.sha256') -Encoding ascii
        Write-Output $artifact
    }
} finally { Pop-Location }
