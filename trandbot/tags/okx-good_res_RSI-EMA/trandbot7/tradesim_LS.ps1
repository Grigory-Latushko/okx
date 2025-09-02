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
$evaluate_candle_period = $config.evaluate_candle_period

# Добавляем глобальные счетчики для винрейта по инструментам
$global:instrumentTotal = @{}
$global:instrumentWins = @{}

# === UTILS ===
function Get-Timestamp { return [int][double]::Parse((Get-Date -UFormat %s)) }
function Format-Time { return (Get-Date -Format "yyyy-MM-dd HH:mm:ss") }
function Format-Time-FromTS($ts) { return ([DateTimeOffset]::FromUnixTimeSeconds($ts)).LocalDateTime.ToString("yyyy-MM-dd HH:mm:ss") }

function LogConsole($msg, $type = "INFO") {
    $ts = Format-Time
    $full = "[$ts][$type] $msg"
    Write-Host $full
}

# function LogTradeWithWinRate($pos, $reason, $winRate) {
#     # $openedAtStr = Format-Time-FromTS $pos.OpenedAt
#     # $closedAtStr = Format-Time-FromTS $pos.ClosedAt
#     $timestamp = Format-Time

#     $logEntry = "[${timestamp}][TRADE] Закрыта позиция $($pos.Symbol) $($pos.Side) PnL: $($pos.PnL) Причина: $reason Баланс: $($global:balance) WinRate инструмента: $winRate%`n" +
#                 # "  Открытие:     $openedAtStr`n" +
#                 # "  Закрытие:     $closedAtStr`n" +
#                 # "  Цена входа:   $($pos.EntryPrice)`n" +
#                 # "  Цена выхода:  $($pos.ExitPrice)`n" +
#                 "🔄 Баланс: $($global:balance)$ | PnL: $($global:totalPnL) 💵 | Сделок: $global:totalClosed"

#     Add-Content -Path $logFile -Value $logEntry
# }

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

        if (-not $res.data) {
            LogConsole "Пустые данные по свечам $symbol" "ERROR"
            return @()
        }

        $candles = $res.data | ForEach-Object {
            [PSCustomObject]@{
                Timestamp = [long]($_[0]) / 1000   # UNIX timestamp в секундах
                Open      = [double]$_[1]
                High      = [double]$_[2]
                Low       = [double]$_[3]
                Close     = [double]$_[4]
                Volume    = [double]$_[5]
            }
        }

        # Разворачиваем в правильный порядок (от старых к новым)
        return $candles | Sort-Object Timestamp
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
function Get-RSI {
    param(
        [double[]]$prices,
        [int]$period = 14
    )

    if ($prices.Count -lt ($period + 1)) { return @() }

    $gains = @()
    $losses = @()

    # считаем изменения
    for ($i = 1; $i -lt $prices.Count; $i++) {
        $change = $prices[$i] - $prices[$i - 1]
        if ($change -gt 0) {
            $gains += $change
            $losses += 0
        } else {
            $gains += 0
            $losses += [Math]::Abs($change)
        }
    }

    # начальные средние (простое среднее за первые N изменений)
    $avgGain = ($gains[0..($period-1)] | Measure-Object -Sum).Sum / $period
    $avgLoss = ($losses[0..($period-1)] | Measure-Object -Sum).Sum / $period

    $rsi = @()

    # первое значение RSI
    $rs = if ($avgLoss -eq 0) { [double]::PositiveInfinity } else { $avgGain / $avgLoss }
    $rsi += [Math]::Round(100 - (100 / (1 + $rs)), 2)

    # далее по формуле Уайлдера
    for ($i = $period; $i -lt $gains.Count; $i++) {
        $avgGain = (($avgGain * ($period - 1)) + $gains[$i]) / $period
        $avgLoss = (($avgLoss * ($period - 1)) + $losses[$i]) / $period

        $rs = if ($avgLoss -eq 0) { [double]::PositiveInfinity } else { $avgGain / $avgLoss }
        $rsi += [Math]::Round(100 - (100 / (1 + $rs)), 2)
    }

    return $rsi
}

function Get-Trend {
    param (
        [array]$candles,
        [int]$atrPeriod,
        [int]$trend_candles,
        [double]$trendsize = 1.0
    )

    # Проверка, есть ли достаточно свечей
    if (-not $candles -or $candles.Count -lt $trend_candles) {
        return "NEUTRAL"
    }

    # Рассчитываем ATR
    $atrArr = Calculate-ATR $candles $atrPeriod
    if (-not $atrArr -or $atrArr.Count -eq 0) {
        return "NEUTRAL"
    }
    $lastAtr = $atrArr[-1]

    # Берём закрытия последних свечей
    $lastCloses = $candles | Sort-Object Timestamp | Select-Object -Last $trend_candles | ForEach-Object { $_.Close }
    if (-not $lastCloses -or $lastCloses.Count -lt 2) {
        return "NEUTRAL"
    }

    # Рассчитываем дельту
    $delta = $lastCloses[-1] - $lastCloses[0]

    # Определяем тренд с порогом 1 ATR
    if ($delta -gt $lastAtr*$trendsize) {
        return "UP"
    } elseif ($delta -lt -$lastAtr*$trendsize) {
        return "DOWN"
    } else {
        return "NEUTRAL"
    }
}

function Check-2ATR-Reversal {
    param (
        [array]$candles,
        [double]$atr
    )

    if ($candles.Count -lt 3) { return $null }

    $last2 = $candles | Sort-Object Timestamp | Select-Object -Last 2

    $candle1 = $last2[0]  # предпоследняя
    $candle2 = $last2[1]  # последняя

    $body1 = [Math]::Abs($candle1.Close - $candle1.Open)
    $body2 = [Math]::Abs($candle2.Close - $candle2.Open)

    $isBullBig = ($candle1.Close -gt $candle1.Open) -and ($body1 -ge 1.5 * $atr)
    $isBearBig = ($candle1.Close -lt $candle1.Open) -and ($body1 -ge 1.5 * $atr)

    $isBullBig2 = ($candle2.Close -gt $candle2.Open) -and ($body2 -ge $body1)
    $isBearBig2 = ($candle2.Close -lt $candle2.Open) -and ($body2 -ge $body1)

    # Сценарий SHORT
    if ($isBullBig -and $isBearBig2) {
        return "SHORT"
    }

    # Сценарий LONG
    if ($isBearBig -and $isBullBig2) {
        return "LONG"
    }

    return $null
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
    LogConsole "🚀 Открыта $side позиция ${symbol}: по $entryPrice (TP: $tp, SL: $sl, Size: $size), списано с баланса: $totalCost$" $side
}

function Close-Position($symbol, $exitPrice, $reason) {
    $pos = $global:positions[$symbol]

    if ($pos.Side -eq "LONG") {
        $pnl = ($exitPrice - $pos.EntryPrice) * $pos.Size
    } elseif ($pos.Side -eq "SHORT") {
        $pnl = ($pos.EntryPrice - $exitPrice) * $pos.Size
    } else {
        LogConsole "Unknown position side: $($pos.Side)" "ERROR"
        return
    }

    $commissionClose = $exitPrice * $pos.Size * $commissionRate

    $pnlRounded = [Math]::Round($pnl - $commissionClose, 8)

    $global:totalPnL += $pnlRounded
    # Возвращаем изначальную стоимость позиции (без комиссии открытия) и прибыль с учетом комиссии закрытия
    $global:balance += ($pos.EntryPrice * $pos.Size) + $pnlRounded

    # Обновляем статистику по инструменту
    if (-not $global:instrumentTotal.ContainsKey($symbol)) {
        $global:instrumentTotal[$symbol] = 0
        $global:instrumentWins[$symbol] = 0
    }
    $global:instrumentTotal[$symbol]++
    if ($reason -eq "TP") {
        $global:winCount++
        $global:instrumentWins[$symbol]++
    }
    $global:totalClosed++

    $pos.ExitPrice = $exitPrice
    $pos.PnL = $pnlRounded
    $pos.ClosedAt = Get-Timestamp
    $pos.Status = $reason

    # Посчитать винрейт по инструменту
    $instrumentWinRate = 0
    if ($global:instrumentTotal[$symbol] -gt 0) {
        $instrumentWinRate = [Math]::Round(($global:instrumentWins[$symbol] / $global:instrumentTotal[$symbol]) * 100, 2)
    }

    LogConsole "✅ Закрыта позиция ${symbol} ($($pos.Side)): по $exitPrice | PnL: $pnlRounded | Причина: $reason | Баланс: $($global:balance) | Сделок: $global:totalClosed | WinRate инструмента: $instrumentWinRate%" "CLOSE"
    # LogTradeWithWinRate $pos $reason $instrumentWinRate

    $global:positions.Remove($symbol)
}

function Evaluate-Position($symbol) {
    if (-not $global:positions.ContainsKey($symbol)) { return }

    $pos = $global:positions[$symbol]
    if ($pos.Status -ne "OPEN") { return }

    $candles = Get-Candles $symbol 100 $evaluate_candle_period   # 100 последних $evaluate_candle_period минутных свечей
    if ($candles.Count -eq 0) { return }

    $openedAtTimestamp = $pos.OpenedAt
    $candlesAfterOpen = $candles | Where-Object { $_.Timestamp -ge $openedAtTimestamp }

    foreach ($candle in $candlesAfterOpen) {
        if ($pos.Side -eq "LONG") {
            if ($candle.High -ge $pos.TP) {
                Close-Position $symbol $pos.TP "TP"
                break
            } elseif ($candle.Low -le $pos.SL) {
                Close-Position $symbol $pos.SL "SL"
                break
            }
        } elseif ($pos.Side -eq "SHORT") {
            if ($candle.Low -le $pos.TP) {
                Close-Position $symbol $pos.TP "TP"
                break
            } elseif ($candle.High -ge $pos.SL) {
                Close-Position $symbol $pos.SL "SL"
                break
            }
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
    $winRate = if ($global:totalClosed -gt 0) {
        [Math]::Round(($global:winCount / $global:totalClosed) * 100, 2)
    } else {
        0
    }
    $timestamp = Format-Time
    LogConsole "🔄 Новый цикл бота. Баланс: $($global:balance)$ | PnL: $($global:totalPnL) 💵 | Сделок: $global:totalClosed | WinRate: $winRate%" "INFO"

    $logEntry = "${timestamp} 🔄 Баланс: $($global:balance)$ | PnL: $($global:totalPnL) 💵 | Сделок: $global:totalClosed | WinRate: $winRate%"
    Add-Content -Path $logFile -Value $logEntry

    foreach ($symbol in $config.instruments) {
        if (CanOpenNew $symbol) {

            $candles = Get-Candles $symbol $config.candle_limit $config.candle_period
            if ($candles.Count -lt 50) { continue }

            $closes = $candles | ForEach-Object { $_.Close }

            # $ema9  = Calculate-EMA $closes 9
            $ema21 = Calculate-EMA $closes 21

            # Получаем массив RSI
            $rsiArr = Get-RSI $closes 14
            if ($rsiArr.Count -lt 2) { continue }

            # Предыдущее и текущее значение RSI
            # $rsiPrev = $rsiArr[-2]
            $rsiCurr = $rsiArr[-1]

            # Получаем массив RSI 50
            $rsi50Arr = Get-RSI $closes 50
            if ($rsi50Arr.Count -lt 2) { continue }

            # Предыдущее и текущее значение RSI
            # $rsi50Prev = $rsi50Arr[-2]
            $rsi50Curr = $rsi50Arr[-1]

            $atrArr = Calculate-ATR $candles 14
            if ($atrArr.Count -eq 0) { continue }
            $atr = $atrArr[-1]

            $price = Get-Last-Tick $symbol
            if ($null -eq $price) { continue }

            $size = [Math]::Round($config.position_size_usd / $price, 4)
            $tpMultiplier  = $config.tp_percent
            $slMultiplier  = $config.sl_percent
            $trend_candles = $config.trend_candles
            $lastEMA21     = $ema21[-1]
            $atrPeriod     = $config.atrPeriod

            $trendsize     = if ($config.trendsize) { $config.trendsize } else { 1.0 }
            $trend         = Get-Trend -candles $candles -atrPeriod $atrPeriod -trend_candles $trend_candles -trendsize $trendsize

            $patternSignal = Check-2ATR-Reversal -candles $candles -atr $atr

            # Условия входа по пересечению RSI
            $longSignal  = (($price -gt $lastEMA21) -and ($rsiCurr -ge $config.max_RSI) -and ($rsi50Curr -ge $config.max_RSI) -and ($trend -eq "UP")) -or ($patternSignal -eq "LONG")
            $shortSignal = (($price -lt $lastEMA21) -and ($rsiCurr -le $config.min_RSI) -and ($rsi50Curr -le $config.min_RSI) -and ($trend -eq "DOWN")) -or ($patternSignal -eq "SHORT")

            if ($longSignal) {
                LogConsole "$symbol → Открытие 📈 LONG: lastEMA21 = $lastEMA21; rsi14Curr = $rsiCurr; rsi50Curr = $rsi50Curr; trend = $trend" "SIGNAL"
                Open-Position $symbol $price $size $atr $tpMultiplier $slMultiplier "LONG"

            } elseif ($shortSignal) {
                LogConsole "$symbol → Открытие 📉 SHORT: lastEMA21 = $lastEMA21; rsi14Curr = $rsiCurr; rsi50Curr = $rsi50Curr; trend = $trend" "SIGNAL"
                Open-Position $symbol $price $size $atr $tpMultiplier $slMultiplier "SHORT"

            } else {
                $reasons = @()
                if (-not $longSignal -and -not $shortSignal) { $reasons += "нет пересечения RSI" }
                # LogConsole "$symbol → Сделка не открыта: $($reasons -join ', ')" "NO-TRADE"
                # Write-Host "symbol=$symbol; price=$price; EMA21=$lastEMA21; rsi14Curr=$rsiCurr; rsi50Curr=$rsi50Curr;  trend=$trend"
            }

        } else {
            Evaluate-Position $symbol
        }
        Start-Sleep -Milliseconds 100
    }
}

# === MAIN LOOP ===
if (Test-Path $logFile) { Remove-Item $logFile -Force }

while ($true) {
    Run-Bot
    Start-Sleep -Seconds $config.rerun_interval_s
}
