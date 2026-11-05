#!/usr/bin/env bash
# Model-free Windows backend checks that also run on Linux/macOS (.NET 10 SDK only):
# language/model switch stress against a protocol-faithful fake native worker, and the on-demand CUDA runtime installer.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1
fake="$root/.bootstrap/fake-native"
dotnet build "$root/windows/Recorder.FakeNative" -c Release -o "$fake" -p:EnableWindowsTargeting=true
dotnet build "$root/windows/Recorder.PortableTests" -c Release -p:EnableWindowsTargeting=true
dotnet "$root/windows/Recorder.PortableTests/bin/Release/net10.0-windows/Recorder.PortableTests.dll" "$fake" "$root" "$@"
