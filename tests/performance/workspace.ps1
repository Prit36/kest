# A deterministic startup workload: forty restored drafts, each with one
# 256 KiB body and one hundred header pairs. Never touches an existing folder.
param([Parameter(Mandatory)][string]$Data)
$ErrorActionPreference = 'Stop'
if (Test-Path -LiteralPath $Data) { throw "Choose a new scratch data folder: $Data already exists" }
[void](New-Item -ItemType Directory -Path (Join-Path $Data 'drafts'))
$tabs = @()
$headers = @(for ($row = 0; $row -lt 100; $row++) {
    @{ key = "X-Bench-$row"; value = "value-$row" }
})
$body = 'x' * (256 * 1024)
for ($tab = 0; $tab -lt 40; $tab++) {
    $id = '{0:x16}' -f $tab
    $tabs += @{ draft = $id }
    $request = @{ name = "Benchmark $tab"; method = 'POST'; url = 'http://127.0.0.1:1/benchmark'; headers = $headers; body = @{ kind = 'text'; text = $body } }
    $text = $request | ConvertTo-Json -Depth 8 -Compress
    [IO.File]::WriteAllText((Join-Path $Data "drafts/$id.json"), $text)
}
[IO.File]::WriteAllText((Join-Path $Data 'workspace.json'), (@{ openTabs = $tabs; activeTab = 0 } | ConvertTo-Json -Depth 8))
