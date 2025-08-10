# === CONFIGURATION ===
$configPath = ".\config_15m.json"
$config = Get-Content $configPath | ConvertFrom-Json
$instruments = $config.instruments
$bar = "15m"
$targetCandles = 96 * 365  # например, 1 год = 96 свечей в день
$delayMs = 200

function Get-HistoricalCandles {
    param($symbol, $count)
    $all = @()
    $before = ""
    while ($all.Count -lt $count) {
        $limit = [math]::Min(1440, $count - $all.Count)
        $url = "https://www.okx.com/api/v5/market/candles?instId=$symbol&bar=$bar&limit=$limit"
        if ($before) { $url += "&before=$before" }
        $res = Invoke-RestMethod -Uri $url -Method Get
        if (-not $res.data -or $res.data.Count -eq 0) { break }
        $batch = $res.data | ForEach-Object {
            [PSCustomObject]@{
                Timestamp = [long]($_[0] / 1000)
                Open = [double]$_[1]
                High = [double]$_[2]
                Low = [double]$_[3]
                Close = [double]$_[4]
            }
        }
        $all += $batch
        # Берём метку первой свечи (максимальное время), в миллисекундах
        $before = [long]$res.data[0][0]
        Start-Sleep -Milliseconds $delayMs
    }
    return $all | Sort-Object Timestamp
}


function Simulate-TP-SL {
    param($candles, $tpPercent, $slPercent)
    $p = 0; $wins = 0; $losses = 0
    foreach ($c in $candles) {
        $entry = $c.Open
        $tp = $entry * (1 + $tpPercent / 100)
        $sl = $entry * (1 - $slPercent / 100)
        if ($c.High -ge $tp) { $p += $tp - $entry; $wins++ }
        elseif ($c.Low -le $sl) { $p += $sl - $entry; $losses++ }
    }
    [PSCustomObject]@{
        Profit = [math]::Round($p, 8)
        WinRate = if ($wins+$losses -gt 0) { [math]::Round($wins/($wins+$losses)*100,2) } else { 0 }
    }
}

# === MAIN PROCESS ===
$tpRange = @(For ($i = 5; $i -le 30; $i++) { [math]::Round($i / 10, 2) })
$slRange = @(For ($i = 5; $i -le 30; $i++) { [math]::Round($i / 10, 2) })
$results = @()

foreach ($symbol in $instruments) {
    Write-Host "Loading $symbol..."
    $candles = Get-HistoricalCandles $symbol $targetCandles
    if ($candles.Count -lt 50) {
        Write-Warning "Too few candles for $symbol ($($candles.Count))"
        continue
    }
    $best = $null
    foreach ($tp in $tpRange) {
        foreach ($sl in $slRange) {
            $res = Simulate-TP-SL $candles $tp $sl
            if ($best -eq $null -or $res.Profit -gt $best.Profit) {
                $best = [PSCustomObject]@{TP=$tp; SL=$sl; Profit=$res.Profit; WinRate=$res.WinRate}
            }
        }
    }
    if ($best) {
        $results += [PSCustomObject]@{
            Symbol=$symbol; BestTP=$best.TP; BestSL=$best.SL; Profit=$best.Profit; WinRate=$best.WinRate
        }
    }
}

$results | Sort-Object Profit -Descending | Tee-Object -Variable final | Format-Table -AutoSize
$final | Export-Csv ".\best_tp_sl_full.csv" -NoTypeInformation -Encoding UTF8

