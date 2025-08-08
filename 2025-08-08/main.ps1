# === CONFIG ===
$configPath = ".\config.json"
$logFile = ".\trades.log"
$config = Get-Content $configPath | ConvertFrom-Json

# === STATE ===
$global:positions = @{}
$global:balance = $config.max_balance
$global:totalPnL = 0
$global:winCount = 0          # Добавлено: счетчик выигрышных сделок (TP)
$global:totalClosed = 0       # Добавлено: общее количество закрытых сделок

# === UTILS ===
function Get-Timestamp { return [int][double]::Parse((Get-Date -UFormat %s)) }
function Format-Time { return (Get-Date -Format "yyyy-MM-dd HH:mm:ss") }
function Format-Time-FromTS($ts) { return ([DateTimeOffset]::FromUnixTimeSeconds($ts)).LocalDateTime.ToString("yyyy-MM-dd HH:mm:ss") }

function LogConsole($msg, $type = "INFO") {
    $ts = Format-Time
    $full = "[$ts][$type] $msg"
    Write-Host $full
}

function LogTrade($pos, $reason) {
    $openedAtStr = Format-Time-FromTS $pos.OpenedAt
    $closedAtStr = Format-Time-FromTS $pos.ClosedAt
    $timestamp = Format-Time

    $logEntry = "[${timestamp}][TRADE] Закрыта позиция $($pos.Symbol) PnL: $($pos.PnL) Причина: $reason Баланс: $($global:balance)`n" +
                "  Открытие:     $openedAtStr`n" +
                "  Закрытие:     $closedAtStr`n" +
                "  Цена входа:   $($pos.EntryPrice)`n" +
                "  Цена выхода:  $($pos.ExitPrice)`n"

    Add-Content -Path $logFile -Value $logEntry
}

# === DATA FETCH ===
function Get-Last-Tick($symbol) {
    try {
        $url = "https://www.okx.com/api/v5/market/ticker?instId=$symbol"
        $res = Invoke-RestMethod -Uri $url -Method Get
        return [double]$res.data[0].last
    } catch {
        LogConsole "Ошибка получения тика для ${symbol}: $($_)" "ERROR"
        return $null
    }
}

function Get-MinuteCandles($symbol, $limit) {
    try {
        $url = "https://www.okx.com/api/v5/market/candles?instId=$symbol&bar=1m&limit=$limit"
        $res = Invoke-RestMethod -Uri $url -Method Get
        return $res.data | ForEach-Object {
            [PSCustomObject]@{
                Timestamp = [long]($_[0] / 1000)
                Open = [double]$_[1]
                High = [double]$_[2]
                Low  = [double]$_[3]
                Close = [double]$_[4]
                Volume = [double]$_[5]
            }
        }
    } catch {
        LogConsole "Ошибка получения свечей для ${symbol}: $($_)" "ERROR"
        return @()
    }
}

# === INDICATORS ===
function Calculate-EMA($prices, $period) {
    $k = 2 / ($period + 1)
    $ema = @()
    $ema += $prices[0]

    for ($i = 1; $i -lt $prices.Count; $i++) {
        $value = $prices[$i] * $k + $ema[$i-1] * (1 - $k)
        $ema += $value
    }
    return $ema
}

function Calculate-RSI($prices, $period) {
    $gains = @()
    $losses = @()

    for ($i=1; $i -lt $prices.Count; $i++) {
        $diff = $prices[$i] - $prices[$i-1]
        if ($diff -gt 0) {
            $gains += $diff
            $losses += 0
        } else {
            $gains += 0
            $losses += [math]::Abs($diff)
        }
    }

    $avgGain = ($gains[0..($period-1)] | Measure-Object -Sum).Sum / $period
    $avgLoss = ($losses[0..($period-1)] | Measure-Object -Sum).Sum / $period

    $rs = if ($avgLoss -eq 0) { 100 } else { $avgGain / $avgLoss }
    $rsi = @()
    $rsi += 100 - (100 / (1 + $rs))

    for ($i = $period; $i -lt $gains.Count; $i++) {
        $avgGain = (($avgGain * ($period - 1)) + $gains[$i]) / $period
        $avgLoss = (($avgLoss * ($period - 1)) + $losses[$i]) / $period

        $rs = if ($avgLoss -eq 0) { 100 } else { $avgGain / $avgLoss }
        $rsi += 100 - (100 / (1 + $rs))
    }
    return $rsi
}

# === TRADE LOGIC ===
function Open-Position($symbol, $entryPrice, $size, $tpPercent, $slPercent) {
    $positionCost = $entryPrice * $size
    if ($global:balance -lt $positionCost) {
        LogConsole "Недостаточно баланса для открытия позиции $symbol требуется $positionCost$, доступно $($global:balance)$" "WARN"
        return
    }
    $global:balance -= $positionCost

    $tp = [Math]::Round($entryPrice * (1 + $tpPercent / 100), 8)
    $sl = [Math]::Round($entryPrice * (1 - $slPercent / 100), 8)

    $position = [PSCustomObject]@{
        Symbol = $symbol
        EntryPrice = $entryPrice
        TP = $tp
        SL = $sl
        Size = $size
        Status = "OPEN"
        OpenedAt = Get-Timestamp

        ExitPrice = $null
        PnL = $null
        ClosedAt = $null
    }

    $global:positions[$symbol] = $position
    LogConsole "Открыта LONG позиция ${symbol}: по $entryPrice (TP: $tp, SL: $sl, Size: $size), списано с баланса: $positionCost$" "LONG"
}

function Close-Position($symbol, $exitPrice, $reason) {
    $pos = $global:positions[$symbol]
    $pnl = ($exitPrice - $pos.EntryPrice) * $pos.Size
    $pnlRounded = [Math]::Round($pnl, 8)

    $global:totalPnL += $pnlRounded
    $global:balance += ($pos.EntryPrice * $pos.Size) + $pnlRounded

    $pos.ExitPrice = $exitPrice
    $pos.PnL = $pnlRounded
    $pos.ClosedAt = Get-Timestamp
    $pos.Status = $reason

    # Добавлено: обновляем счетчики для винрейта
    if ($reason -eq "TP") {
        $global:winCount++
    }
    $global:totalClosed++

    LogConsole "Закрыта позиция ${symbol}: по $exitPrice | PnL: $pnlRounded | Причина: $reason | Баланс: $($global:balance)" "CLOSE"
    LogTrade $pos $reason

    $global:positions.Remove($symbol)
}


function Evaluate-Position($symbol) {
    if (-not $global:positions.ContainsKey($symbol)) { return }

    $pos = $global:positions[$symbol]
    if ($pos.Status -ne "OPEN") { return }

    $candles = Get-MinuteCandles $symbol $config.candle_limit
    if ($candles.Count -eq 0) { return }

    $openedAtTimestamp = $pos.OpenedAt
    $candlesAfterOpen = $candles | Where-Object { $_.Timestamp -ge $openedAtTimestamp }

    foreach ($candle in $candlesAfterOpen) {
        if ($candle.High -ge $pos.TP) {
            Close-Position $symbol $pos.TP "TP"
            break
        } elseif ($candle.Low -le $pos.SL) {
            Close-Position $symbol $pos.SL "SL"
            break
        }
    }

    if ($global:positions.ContainsKey($symbol)) {
        $currentPrice = Get-Last-Tick $symbol
        if ($null -ne $currentPrice) {
            LogConsole "${symbol}: [Price: $currentPrice] → TP: $($pos.TP), SL: $($pos.SL)" "MONITOR"
        }
}

}

function CanOpenNew($symbol) {
    return (-not $global:positions.ContainsKey($symbol)) -and ($global:balance -ge $config.position_size_usd)
}

function Run-Bot {
    # Добавлено: считаем винрейт
    $winRate = 0
    if ($global:totalClosed -gt 0) {
        $winRate = [Math]::Round(($global:winCount / $global:totalClosed) * 100, 2)
    }
    
    LogConsole "🔄 Новый цикл бота. Баланс: $($global:balance)$ | PnL: $($global:totalPnL) 💵 | WinRate: $winRate`%" "INFO" 
    
    foreach ($symbol in $config.instruments) {
        if (CanOpenNew $symbol) {
            $candles = Get-MinuteCandles $symbol $config.candle_limit
            if ($candles.Count -lt 21) { continue }

            $closes = $candles | ForEach-Object { $_.Close }
            $ema9 = Calculate-EMA $closes 9
            $ema21 = Calculate-EMA $closes 21
            $rsi = Calculate-RSI $closes 14

            if (($ema9[-1] -gt $ema21[-1]) -and ($ema9[-2] -le $ema21[-2]) -and ($rsi[-1] -lt 70)) {
                $price = Get-Last-Tick $symbol
                $size = [Math]::Round($config.position_size_usd / $price, 4)
                Open-Position $symbol $price $size $config.tp_percent $config.sl_percent
            }
        } else {
            Evaluate-Position $symbol
        }
    }
}

# === MAIN LOOP ===
if (Test-Path $logFile) { Remove-Item $logFile -Force }

while ($true) {
    Run-Bot
    Start-Sleep -Seconds $config.rerun_interval_s
}
