[CmdletBinding()]
param([string[]]$Models = @('qwen-asr','whisper-turbo','qwen-translate','hunyuan-translate'))
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$catalog = Get-Content -Raw (Join-Path $root 'windows/models.lock.json') | ConvertFrom-Json
foreach ($id in $Models) {
    $model = $catalog.models | Where-Object id -EQ $id
    if (-not $model) { throw "Unknown model: $id" }
    $cache = Join-Path $root ('.bootstrap/verification-models/' + $id)
    New-Item -ItemType Directory -Force $cache | Out-Null
    foreach ($file in $model.files) {
        $path = Join-Path $cache $file.name
        if (Test-Path -LiteralPath $path) {
            if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -eq $file.sha256) { continue }
            throw "Existing model checksum mismatch: $path"
        }
        $url = 'https://huggingface.co/' + $model.repo + '/resolve/' + $model.revision + '/' + $file.name
        & curl.exe --fail --location --retry 3 --continue-at - --output ($path + '.incomplete') $url
        if ($LASTEXITCODE -ne 0) { throw "Download failed: $url" }
        if ((Get-Item -LiteralPath ($path + '.incomplete')).Length -ne $file.size) { throw 'Model size mismatch' }
        if ((Get-FileHash -LiteralPath ($path + '.incomplete') -Algorithm SHA256).Hash.ToLowerInvariant() -ne $file.sha256) { throw 'Model SHA256 mismatch' }
        Move-Item -LiteralPath ($path + '.incomplete') -Destination $path
        Write-Output $path
    }
}
