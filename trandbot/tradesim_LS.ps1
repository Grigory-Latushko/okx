# === CONFIG ===
param(
    [string]$configPath = ".\config.json"
)

# Имя лог-файла формируется на основе имени файла конфига
$logFileName = [IO.Path]::GetFileNameWithoutExtension($configPath)
$logFile = ".\${logFileName}_trades.log"

$config = Get-Content $configPath | ConvertFrom-Json

# === STATE ===
$global:positions = @{}
$global:balance = $config.max_balance
$global:totalPnL = 0
$global:winCount = 0
$global:totalClosed = 0
$commissionRate = 0.0009  # 0.09%

# Добавляем счётчики для Long/Short
$global:longTotal = 0
$global:longWins = 0
$global:shortTotal = 0
$global:shortWins = 0

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

    $logEntry = "[${timestamp}][TRADE] Закрыта позиция $($pos.Symbol) $($pos.Side) PnL: $($pos.PnL) Причина: $reason Баланс: $($global:balance)`n" +
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

function Get-Candles($symbol, $limit, $period) {
    try {
        $url = "https://www.okx.com/api/v5/market/candles?instId=$symbol&bar=$period&limit=$limit"
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

function Calculate-ATR($candles, $period = 14) {
    $trs = @()
    for ($i = 1; $i -lt $candles.Count; $i++) {
        $high = $candles[$i].High
        $low = $candles[$i].Low
        $prevClose = $candles[$i - 1].Close

        $tr = [Math]::Max(
            $high - $low,
            [Math]::Max(
                [Math]::Abs($high - $prevClose),
                [Math]::Abs($low - $prevClose)
            )
        )
        $trs += $tr
    }

    $atr = @()
    $initialSMA = ($trs[0..($period-1)] | Measure-Object -Sum).Sum / $period
    $atr += $initialSMA

    $k = 2 / ($period + 1)
    for ($i = $period; $i -lt $trs.Count; $i++) {
        $value = $trs[$i] * $k + $atr[-1] * (1 - $k)
        $atr += $value
    }
    return $atr
}

function Get-EMA {
    param (
        [double[]]$prices,
        [int]$period
    )

    if ($prices.Count -lt $period) {
        return @()
    }

    $k = 2 / ($period + 1)
    $ema = @()
    $ema += ($prices[0..($period-1)] | Measure-Object -Average).Average  # начальное значение SMA

    for ($i = $period; $i -lt $prices.Count; $i++) {
        $emaValue = ($prices[$i] * $k) + ($ema[-1] * (1 - $k))
        $ema += $emaValue
    }

    return $ema
}


# === TRADE LOGIC ===
$commissionRate = 0.0009  # 0.09%

function Open-Position($symbol, $entryPrice, $size, $atr, $tpMultiplier, $slMultiplier, $side = "LONG") {
    if ($side -eq "LONG") {
        $tp = [Math]::Round($entryPrice + $atr * $tpMultiplier, 8)
        $sl = [Math]::Round($entryPrice - $atr * $slMultiplier, 8)
    } elseif ($side -eq "SHORT") {
        $tp = [Math]::Round($entryPrice - $atr * $tpMultiplier, 8)
        $sl = [Math]::Round($entryPrice + $atr * $slMultiplier, 8)
    } else {
        LogConsole "Unknown position side: $side" "ERROR"
        return
    }

    $positionCost = $entryPrice * $size
    $commissionOpen = $positionCost * $commissionRate
    $totalCost = $positionCost + $commissionOpen

    if ($global:balance -lt $totalCost) {
        LogConsole "Недостаточно баланса для открытия позиции $symbol требуется $totalCost$, доступно $($global:balance)$" "WARN"
        return
    }
    $global:balance -= $totalCost

    $position = [PSCustomObject]@{
        Symbol = $symbol
        EntryPrice = $entryPrice
        TP = $tp
        SL = $sl
        Size = $size
        Side = $side
        Status = "OPEN"
        OpenedAt = Get-Timestamp

        ExitPrice = $null
        PnL = $null
        ClosedAt = $null
    }

    $global:positions[$symbol] = $position
    LogConsole "Открыта $side позиция ${symbol}: по $entryPrice (TP: $tp, SL: $sl, Size: $size), списано с баланса: $totalCost$" $side
}

function Close-Position($symbol, $exitPrice, $reason) {
    $pos = $global:positions[$symbol]

    if ($pos.Side -eq "LONG") {
        $pnl = ($exitPrice - $pos.EntryPrice) * $pos.Size
        $global:longTotal++
        if ($reason -eq "TP") { $global:longWins++ }
    } elseif ($pos.Side -eq "SHORT") {
        $pnl = ($pos.EntryPrice - $exitPrice) * $pos.Size
        $global:shortTotal++
        if ($reason -eq "TP") { $global:shortWins++ }
    } else {
        LogConsole "Unknown position side: $($pos.Side)" "ERROR"
        return
    }

    $commissionClose = $exitPrice * $pos.Size * $commissionRate
    $pnlRounded = [Math]::Round($pnl - $commissionClose, 8)

    $global:totalPnL += $pnlRounded
    $global:balance += ($pos.EntryPrice * $pos.Size) + $pnlRounded

    $pos.ExitPrice = $exitPrice
    $pos.PnL = $pnlRounded
    $pos.ClosedAt = Get-Timestamp
    $pos.Status = $reason

    if ($reason -eq "TP") {
        $global:winCount++
    }
    $global:totalClosed++

    LogConsole "Закрыта позиция ${symbol} ($($pos.Side)): по $exitPrice | PnL: $pnlRounded | Причина: $reason | Баланс: $($global:balance)" "CLOSE"
    LogTrade $pos $reason

    $global:positions.Remove($symbol)
}

function Evaluate-Position {
    param(
        [string]$symbol,       # тикер
        [string]$side,         # "buy" или "sell"
        [array]$candles_M15,   # свечи M15 (рабочий ТФ)
        [array]$candles_H1     # свечи H1 (старший ТФ)
    )

    $score = 0

    # === 1. Мульти-таймфрейм подтверждение тренда ===
    $emaH1_fast = (Get-EMA $candles_H1.Close 20)[-1]
    $emaH1_slow = (Get-EMA $candles_H1.Close 50)[-1]

    if (
        ($side -eq "buy"  -and $emaH1_fast -gt $emaH1_slow) -or
        ($side -eq "sell" -and $emaH1_fast -lt $emaH1_slow)
    ) {
        $score++
    }

    # === 2. Пересечение EMA на M15 ===
    $emaM15_fast = (Get-EMA $candles_M15.Close 20)[-1]
    $emaM15_slow = (Get-EMA $candles_M15.Close 50)[-1]

    if (
        ($side -eq "buy"  -and $emaM15_fast -gt $emaM15_slow) -or
        ($side -eq "sell" -and $emaM15_fast -lt $emaM15_slow)
    ) {
        $score++
    }

    # === 3. Паттерн свечей ===
    $lastCandle = $candles_M15[-1]

    if (
        ($side -eq "buy"  -and $lastCandle.Close -gt $lastCandle.Open) -or
        ($side -eq "sell" -and $lastCandle.Close -lt $lastCandle.Open)
    ) {
        $score++
    }

    # === Итог ===
    if ($score -ge 2) {
        Write-Host "[INFO] $symbol | $side | Сигнал подтверждён ($score/3) — открываем сделку"
        return $true
    }
    else {
        Write-Host "[INFO] $symbol | $side | Сигнал слабый ($score/3) — пропуск"
        return $false
    }
}


function CanOpenNew($symbol) {
    return (-not $global:positions.ContainsKey($symbol)) -and ($global:balance -ge $config.position_size_usd)
}

function Run-Bot {
    $winRate = if ($global:totalClosed -gt 0) { [Math]::Round(($global:winCount / $global:totalClosed) * 100, 2) } else { 0 }
    $longWinRate = if ($global:longTotal -gt 0) { [Math]::Round(($global:longWins / $global:longTotal) * 100, 2) } else { 0 }
    $shortWinRate = if ($global:shortTotal -gt 0) { [Math]::Round(($global:shortWins / $global:shortTotal) * 100, 2) } else { 0 }

    $logMsg = "🔄 Новый цикл бота. Баланс: $($global:balance)$ | PnL: $($global:totalPnL) 💵 | WinRate: $winRate% | LongWinRate: ${longWinRate}% | ShortWinRate: ${shortWinRate}%"
    LogConsole $logMsg "INFO"
    Add-Content -Path $logFile -Value ("[$(Format-Time)][STATS] " + $logMsg)

    foreach ($symbol in $config.instruments) {
        if (CanOpenNew $symbol) {
            $candles = Get-Candles $symbol $config.candle_limit $config.candle_period
            if ($candles.Count -lt 50) { continue }

            $closes = $candles | ForEach-Object { $_.Close }

            $ema9 = Calculate-EMA $closes 9
            $ema21 = Calculate-EMA $closes 21

            $atrArr = Calculate-ATR $candles 14
            if ($atrArr.Count -eq 0) { continue }
            $atr = $atrArr[-1]

            $emaCrossUp = ($ema9[-1] -gt $ema21[-1]) -and ($ema9[-2] -le $ema21[-2])
            $ema21TrendUp = $ema21[-1] -gt $ema21[-6]

            $emaCrossDown = ($ema9[-1] -lt $ema21[-1]) -and ($ema9[-2] -ge $ema21[-2])
            $ema21TrendDown = $ema21[-1] -lt $ema21[-6]

            $price = Get-Last-Tick $symbol
            if ($null -eq $price) { continue }

            $size = [Math]::Round($config.position_size_usd / $price, 4)
            $tpMultiplier = 2
            $slMultiplier = 1

            if ($emaCrossUp -and $ema21TrendUp) {
                Open-Position $symbol $price $size $atr $tpMultiplier $slMultiplier "LONG"
            } elseif ($emaCrossDown -and $ema21TrendDown) {
                Open-Position $symbol $price $size $atr $tpMultiplier $slMultiplier "SHORT"
            }
        } else {
            Evaluate-Position $symbol
        }
        Start-Sleep -Milliseconds 200
    }
}

# === MAIN LOOP ===
if (Test-Path $logFile) { Remove-Item $logFile -Force }

while ($true) {
    Run-Bot
    Start-Sleep -Seconds $config.rerun_interval_s
}
