# === CONFIG ===
param(
    [string]$configPath = ".\config.json"
)

# Имя лог-файла формируется на основе имени файла конфига
$logFileName = [IO.Path]::GetFileNameWithoutExtension($configPath)
$logFile = ".\${logFileName}_trades_EMA+RSI_LIMITED.log"

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

function LogTradeWithWinRate($pos, $reason, $winRate) {
    # $openedAtStr = Format-Time-FromTS $pos.OpenedAt
    # $closedAtStr = Format-Time-FromTS $pos.ClosedAt
    $timestamp = Format-Time

    $logEntry = "[${timestamp}][TRADE] Закрыта позиция $($pos.Symbol) $($pos.Side) PnL: $($pos.PnL) Причина: $reason Баланс: $($global:balance) WinRate инструмента: $winRate%`n" +
                # "  Открытие:     $openedAtStr`n" +
                # "  Закрытие:     $closedAtStr`n" +
                # "  Цена входа:   $($pos.EntryPrice)`n" +
                # "  Цена выхода:  $($pos.ExitPrice)`n" +
                "🔄 Баланс: $($global:balance)$ | PnL: $($global:totalPnL) 💵 | Сделок: $global:totalClosed"

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

function Calculate-RSI($prices, $period = 14) {
    if ($prices.Count -le $period) { return @() }

    $gains = @()
    $losses = @()

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

    $avgGain = ($gains[0..($period-1)] | Measure-Object -Sum).Sum / $period
    $avgLoss = ($losses[0..($period-1)] | Measure-Object -Sum).Sum / $period

    $rsi = @()
    $rsi += [Math]::Round(100 - (100 / (1 + ($avgGain / [Math]::Max($avgLoss, 0.0000001)))), 3)

    for ($i = $period; $i -lt $gains.Count; $i++) {
        $avgGain = (($avgGain * ($period - 1)) + $gains[$i]) / $period
        $avgLoss = (($avgLoss * ($period - 1)) + $losses[$i]) / $period

        if ($avgLoss -eq 0) {
            $rs = [double]::PositiveInfinity
        } else {
            $rs = $avgGain / $avgLoss
        }

        $rsi += [Math]::Round(100 - (100 / (1 + $rs)), 3)
    }

    return $rsi
}

function Calculate-ConnorsRSI {
    param(
        [double[]]$closes,
        [int]$rsiPeriod = 3,        # RSI по цене
        [int]$streakPeriod = 2,     # RSI по стрику
        [int]$rankPeriod = 100      # PercentRank
    )

    if ($closes.Count -lt ($rankPeriod + 2)) {
        return @()
    }

    # === 1. RSI по цене ===
    $rsiPrice = Calculate-RSI $closes $rsiPeriod

    # === 2. Streak (подсчет последовательных свечей роста/падения) ===
    $streaks = @()
    $streak = 0
    for ($i = 1; $i -lt $closes.Count; $i++) {
        if ($closes[$i] -gt $closes[$i-1]) {
            $streak = if ($streak -ge 0) { $streak + 1 } else { 1 }
        } elseif ($closes[$i] -lt $closes[$i-1]) {
            $streak = if ($streak -le 0) { $streak - 1 } else { -1 }
        } else {
            $streak = 0
        }
        $streaks += $streak
    }

    # для стрика считаем RSI (по модулю изменений)
    $streakRSI = Calculate-RSI ($streaks | ForEach-Object { [math]::Abs($_) }) $streakPeriod

    # === 3. PercentRank of Change ===
    $changes = @()
    for ($i = 1; $i -lt $closes.Count; $i++) {
        $changes += (($closes[$i] - $closes[$i-1]) / $closes[$i-1]) * 100
    }

    $percentRank = @()
    for ($i = $rankPeriod; $i -lt $changes.Count; $i++) {
        $window = $changes[($i-$rankPeriod+1)..$i]
        $current = $changes[$i]
        $less = ($window | Where-Object { $_ -lt $current }).Count
        $percentRank += [math]::Round(($less / $window.Count) * 100, 2)
    }

    # === 4. Совмещаем все 3 компонента ===
    $minLen = ($rsiPrice.Count, $streakRSI.Count, $percentRank.Count | Measure-Object -Minimum).Minimum
    $crsi = @()
    for ($i = 0; $i -lt $minLen; $i++) {
        $crsi += [Math]::Round(($rsiPrice[-$minLen+$i] + $streakRSI[-$minLen+$i] + $percentRank[-$minLen+$i]) / 3, 2)
    }

    return $crsi
}

function Get-Trend($candles, $atrPeriod = 14, $trend_candles) {
    if ($candles.Count -lt 14) { return "FLAT" }

    # Берём 4 последних свечей
    $lastCloses = ($candles | Sort-Object Timestamp | Select-Object -Last $trend_candles | ForEach-Object { $_.Close })

    # Разница между последней и trend_candles с конца
    $delta = $lastCloses[-1] - $lastCloses[0]

    # ATR для тренда (можно взять последний ATR)
    $atrArr = Calculate-ATR $candles $atrPeriod
    if ($atrArr.Count -eq 0) { return "FLAT" }
    $atr = $atrArr[-1]

    if ($delta -gt $atr) {
        return "UP"
    } elseif ($delta -lt -$atr) {
        return "DOWN"
    } else {
        return "FLAT"
    }
}

# === TRADE LOGIC ===

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

    $positionCost   = $entryPrice * $size
    $commissionOpen = $positionCost * $commissionRate
    $totalCost      = $positionCost + $commissionOpen

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
    LogTradeWithWinRate $pos $reason $instrumentWinRate

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

    LogConsole "🔄 Новый цикл бота. Баланс: $($global:balance)$ | PnL: $($global:totalPnL) 💵 | Сделок: $global:totalClosed | WinRate: $winRate%" "INFO"

    foreach ($symbol in $config.instruments) {
        if (CanOpenNew $symbol) {
            $candles = Get-Candles $symbol $config.candle_limit $config.candle_period
            if ($candles.Count -lt 50) { continue }

            # $closes = $candles | ForEach-Object { $_.Close }
            $closes = ($candles | Sort-Object Timestamp) | ForEach-Object { $_.Close }

            $ema9  = Calculate-EMA $closes 9
            $ema21 = Calculate-EMA $closes 21

        # Получаем массив RSI
            # $rsiArr = Calculate-RSI $closes 14
            # if ($rsiArr.Count -lt 2) { continue }

            # # Предыдущее и текущее значение RSI
            # $rsiPrev = $rsiArr[-2]
            # $rsiCurr = $rsiArr[-1]

        # Connors RSI вместо обычного RSI
            $rsiArr = Calculate-ConnorsRSI -closes $closes -rsiPeriod 3 -streakPeriod 2 -rankPeriod 100
            if ($rsiArr.Count -lt 2) { continue }

            $rsiPrev = $rsiArr[-2]
            $rsiCurr = $rsiArr[-1]

            $atrArr = Calculate-ATR $candles 14
            if ($atrArr.Count -eq 0) { continue }
            $atr = $atrArr[-1]

            $price = Get-Last-Tick $symbol
            if ($null -eq $price) { continue }

            $size = [Math]::Round($config.position_size_usd / $price, 4)
            $tpMultiplier = $config.tp_percent
            $slMultiplier = $config.sl_percent
            $lastEMA21 = $ema21[-1]
            $min_RSI = $config.min_RSI
            $max_RSI = $config.max_RSI
            $trend_candles = $config.trend_candles

        # Условия входа по пересечению RSI

            $trend = Get-Trend -candles $candles -atrPeriod 14 -trend_candles $trend_candles
            $longSignal  = $price -gt $ema21[-1] -and ($rsiCurr -le $min_RSI) -and ($trend -eq "UP")
            $shortSignal = $price -lt $ema21[-1] -and ($rsiCurr -ge $max_RSI) -and ($trend -eq "DOWN")

            if ($longSignal) {
                # LogConsole "$symbol → Открытие 📈 LONG: RSI пересек min_RSI ($($config.min_RSI)) снизу вверх: $rsiPrev → $rsiCurr EMA21 = $lastEMA21" "SIGNAL"
                LogConsole "$symbol → Открытие 📈 LONG: RSI = $rsiCurr EMA21 = $lastEMA21" "SIGNAL"
                Open-Position $symbol $price $size $atr $tpMultiplier $slMultiplier "LONG"

            } elseif ($shortSignal) {
                # LogConsole "$symbol → Открытие 📉 SHORT: RSI пересек max_RSI ($($config.max_RSI)) сверху вниз: $rsiPrev → $rsiCurr EMA21 = $lastEMA21" "SIGNAL"
                LogConsole "$symbol → Открытие 📉 SHORT: RSI = $rsiCurr EMA21 = $lastEMA21" "SIGNAL"
                Open-Position $symbol $price $size $atr $tpMultiplier $slMultiplier "SHORT"

            } else {
                $reasons = @()
                if (-not $longSignal -and -not $shortSignal) { $reasons += "нет пересечения RSI" }
                if ($price -le $lastEMA21 -and $rsiCurr -ge $min_RSI) { $reasons += "цена ниже EMA21 для LONG" }
                if ($price -ge $lastEMA21 -and $rsiCurr -le $max_RSI) { $reasons += "цена выше EMA21 для SHORT" }

                if ($reasons.Count -gt 0) {
                    # LogConsole "$symbol → Сделка не открыта: $($reasons -join ', ')" "NO-TRADE"
                    # Write-Host "price= $price lastEMA21= $lastEMA21 rsiCurr= $rsiCurr rsiPrev= $rsiPrev"
                }
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
