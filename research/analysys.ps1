$rows = 0
$filtered = 0
$upCount = 0
$downCount = 0


.\res.ps1 .\config_60m_res.json

$ConfigPath = ".\config_60m_res.json"

try {
    $configJson = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
} catch {
    Log "Failed to parse config.json: $($_.Exception.Message)" "ERROR"
    throw $_
}

$Instruments = $configJson.instruments

 $totalup = 0
 $totaldown = 0

foreach ($inst in $Instruments) {

    $rows = import-Csv .\data\$inst.csv
    # $filtered = $rows | Where-Object {($_.RSI6 -ne "") -and ($_.RSI14 -ne "") -and ([double]$_.RSI6 -lt 30) -and ([double]$_.RSI14 -lt 50)}
    $filtered = $rows | Where-Object {($_.RSI6 -ne "") -and ($_.RSI14 -ne "") -and ([double]$_.RSI6 -lt 30) -and ([double]$_.RSI14 -gt 1 ) -and ([double]$_.RSI30 -gt 0 )}
    $filtered | Format-Table Index, Timestamp, RSI6, RSI14, RSI30, FutureReturn, FirstMove, BarsToHit, HitReturn

    # Считаем строки с FirstMove = "Up"
    $upCount = $filtered | Where-Object { $_.FirstMove -eq "Up" } | Measure-Object | Select-Object -ExpandProperty Count

    # Считаем строки с FirstMove = "Down"
    $downCount = $filtered | Where-Object { $_.FirstMove -eq "Down" } | Measure-Object | Select-Object -ExpandProperty Count

    "Up: $upCount"
    "Down: $downCount"

    $totalup = $totalup + $upCount
    $totaldown = $totaldown + $downCount
}

"Total Up: $totalup"
"Total Down: $totaldown"