[CmdletBinding()]
param([Parameter(Mandatory)][int]$RecorderProcessId)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$log = Join-Path $repoRoot '.bootstrap/soak-resources.jsonl'
while (Get-Process -Id $RecorderProcessId -ErrorAction SilentlyContinue) {
    $gpu = & nvidia-smi --query-gpu=memory.used,memory.free,utilization.gpu --format=csv,noheader,nounits
    $workers = Get-CimInstance Win32_Process -Filter "ParentProcessId=$RecorderProcessId AND Name='recorder-native.exe'" | ForEach-Object { $worker = Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue; if ($worker) { @{ id=$worker.Id; private_bytes=$worker.PrivateMemorySize64; working_set_bytes=$worker.WorkingSet64 } } }
    @{ utc=[DateTimeOffset]::UtcNow.ToString('o'); gpu_mib_used_free_percent=$gpu; workers=@($workers) } | ConvertTo-Json -Compress -Depth 5 | Add-Content -LiteralPath $log -Encoding utf8
    Start-Sleep -Seconds 30
}
