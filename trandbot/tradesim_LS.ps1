param(
    [string]$configPath = ".\config.json"
)

# --- Загрузка конфига ---
$config = Get-Content $configPath | ConvertFrom-Json

# --- Глобальные переменные ---
$global:positions = @{}
$global:balance = $config.max_balance
$global:totalPnL = 0
$global:winCount = 0
$global:totalClosed = 0
$commissionRate = 0.0009

$tpSlParams = @{}

# --- Параметры для оптимизации ---
$bar = $config.candle_period
$targetCandles = 96 * 365  # примерно 1 год при 15m свечах
$delayMs = 200

# --- Функция загрузки исторических свечей ---
function Get-HistoricalCandles {
    param($symbol, $count)
    $all = @()
    $before = ""
    while ($all.Count -lt $count) {
        $limit = [math]::Min(1440, $count - $all.Count)
        $url = "https://www.okx.com/api/v5/market/candles?instId=$symbol&bar=$bar&limit=$limit"
        if ($before) { $url += "&before=$before" }
        try {
            $res = Invoke-RestMethod -Uri $url -Method Get
        } catch {
            Write-Warning "Ошибка запроса исторических данных для $symbol $_"
            break
        }
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
        $before = [long]$res.data[0][0]
        Start-Sleep -Milliseconds $delayMs
    }
    return $all | Sort-Object Timestamp
}

# --- Симуляция TP/SL ---
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
        WinRate = if ($wins + $losses -gt 0) { [math]::Round($wins / ($wins + $losses) * 100, 2) } else { 0 }
    }
}

# --- Поиск лучших TP/SL ---
function Find-Best-TP-SL($symbol) {
    Write-Host "Оптимизация TP/SL для $symbol..."

    # Загрузка свечей и оптимизация как у тебя
    $candles = Get-HistoricalCandles $symbol $targetCandles
    if ($candles.Count -lt 50) {
        Write-Warning "Недостаточно данных для $symbol ($($candles.Count) свечей)"
        return @{ tp_percent = 1.0; sl_percent = 1.0 }
    }

    $tpRange = @(For ($i = 5; $i -le 30; $i++) { [math]::Round($i / 10, 2) })
    $slRange = @(For ($i = 5; $i -le 30; $i++) { [math]::Round($i / 10, 2) })
    $best = $null

    foreach ($tp in $tpRange) {
        foreach ($sl in $slRange) {
            $res = Simulate-TP-SL $candles $tp $sl
            if ($best -eq $null -or $res.Profit -gt $best.Profit) {
                $best = [PSCustomObject]@{TP=$tp; SL=$sl; Profit=$res.Profit; WinRate=$res.WinRate}
            }
        }
    }

    if ($best.Profit -eq 0 -or $best.WinRate -eq 0) {
        Write-Host "Результаты оптимизации для $symbol равны 0, ставим TP=1.8%, SL=0.8%"
        $best.TP = 1.8
        $best.SL = 0.8
    }

    Write-Host "Лучший TP=$($best.TP)%, SL=$($best.SL)% для $symbol (Profit=$($best.Profit), WinRate=$($best.WinRate)%)"
    return @{ tp_percent = $best.TP; sl_percent = $best.SL }
}

# --- Функции получения рыночных данных ---
function Get-Last-Tick($symbol) {
    try {
        $url = "https://www.okx.com/api/v5/market/ticker?instId=$symbol"
        $res = Invoke-RestMethod -Uri $url -Method Get
        return [double]$res.data[0].last
    } catch {
        Write-Warning "Ошибка получения тика для $symbol $_"
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
                Volume = if ($_.Count -gt 5) { [double]$_[5] } else { 0 }
            }
        }
    } catch {
        Write-Warning "Ошибка получения свечей для $symbol $_"
        return @()
    }
}

# --- Индикаторы ---
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

# --- Открытие и закрытие позиций ---
function Open-Position($symbol, $entryPrice, $size, $atr, $tpMultiplier, $slMultiplier, $side = "LONG") {
    if ($side -eq "LONG") {
        $tp = [Math]::Round($entryPrice + $atr * $tpMultiplier, 8)
        $sl = [Math]::Round($entryPrice - $atr * $slMultiplier, 8)
    } elseif ($side -eq "SHORT") {
        $tp = [Math]::Round($entryPrice - $atr * $tpMultiplier, 8)
        $sl = [Math]::Round($entryPrice + $atr * $slMultiplier, 8)
    } else {
        Write-Warning "Unknown position side: $side"
        return
    }

    $positionCost = $entryPrice * $size
    $commissionOpen = $positionCost * $commissionRate
    $totalCost = $positionCost + $commissionOpen
    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")

    if ($global:balance -lt $totalCost) {
        Write-Warning "Недостаточно баланса для открытия позиции $symbol требуется $totalCost$, доступно $($global:balance)$"
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
        OpenedAt = [int][double]::Parse((Get-Date -UFormat %s))

        ExitPrice = $null
        PnL = $null
        ClosedAt = $null
    }

    $global:positions[$symbol] = $position
    Write-Host [$timestamp] "[TRADE] Открыта $side позиция $symbol по $entryPrice (TP: $tp, SL: $sl, Size: $size), списано с баланса: $totalCost$"
}

function Close-Position($symbol, $exitPrice, $reason) {
    if (-not $global:positions.ContainsKey($symbol)) { return }

    $pos = $global:positions[$symbol]

    if ($pos.Side -eq "LONG") {
        $pnl = ($exitPrice - $pos.EntryPrice) * $pos.Size
    } elseif ($pos.Side -eq "SHORT") {
        $pnl = ($pos.EntryPrice - $exitPrice) * $pos.Size
    } else {
        Write-Warning "Unknown position side: $($pos.Side)"
        return
    }

    $commissionClose = $exitPrice * $pos.Size * $commissionRate
    $pnlRounded = [Math]::Round($pnl - $commissionClose, 8)
    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")

    $global:totalPnL += $pnlRounded
    $global:balance += ($pos.EntryPrice * $pos.Size) + $pnlRounded

    # Статистика по инструменту
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
    $pos.ClosedAt = [int][double]::Parse((Get-Date -UFormat %s))
    $pos.Status = $reason

    $instrumentWinRate = 0
    if ($global:instrumentTotal[$symbol] -gt 0) {
        $instrumentWinRate = [Math]::Round(($global:instrumentWins[$symbol] / $global:instrumentTotal[$symbol]) * 100, 2)
    }

    Write-Host [$timestamp] "[CLOSE] Закрыта позиция $symbol ($($pos.Side)): по $exitPrice | PnL: $pnlRounded | Причина: $reason | Баланс: $($global:balance) | Сделок: $($global:instrumentTotal[$symbol]) | WinRate инструмента: $instrumentWinRate%"
    $global:positions.Remove($symbol)
}

function Evaluate-Position($symbol) {
    if (-not $global:positions.ContainsKey($symbol)) { return }

    $pos = $global:positions[$symbol]
    if ($pos.Status -ne "OPEN") { return }

    $candles = Get-Candles $symbol 100 "5m"
    if ($candles.Count -eq 0) { return }

    $openedAtTimestamp = $pos.OpenedAt
    $candlesAfterOpen = $candles | Where-Object { $_.Timestamp -ge $openedAtTimestamp }
    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")

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
            Write-Host [$timestamp] "[Monitor] $symbol [Price: $currentPrice] → TP: $($pos.TP), SL: $($pos.SL)"
        }
    }
}

function CanOpenNew($symbol) {
    return (-not $global:positions.ContainsKey($symbol)) -and ($global:balance -ge $config.position_size_usd)
}

# --- Инициализация статистики ---
$global:instrumentTotal = @{}
$global:instrumentWins = @{}

# --- Оптимизация TP/SL для каждого инструмента ---
Write-Host "Запуск оптимизации TP/SL для инструментов..."
foreach ($symbol in $config.instruments) {
    $params = Find-Best-TP-SL $symbol
    $tpSlParams[$symbol] = $params
}
Write-Host "Оптимизация завершена. Запуск торгового бота..."

# --- Главный цикл торговли ---
function Run-Bot {
    $winRate = if ($global:totalClosed -gt 0) {
        [Math]::Round(($global:winCount / $global:totalClosed) * 100, 2)
    } else {
        0
    }

    Write-Host "🔄 Новый цикл бота. Баланс: $($global:balance)$ | PnL: $($global:totalPnL) | Сделок: $global:totalClosed | WinRate: $winRate%"

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

            # Используем оптимизированные TP/SL
            if ($tpSlParams.ContainsKey($symbol)) {
                $tpPercent = $tpSlParams[$symbol].tp_percent
                $slPercent = $tpSlParams[$symbol].sl_percent
            } else {
                $tpPercent = $config.tp_percent
                $slPercent = $config.sl_percent
            }

            # Перевод процентов TP/SL в множители ATR
            $tpMultiplier = ($price * $tpPercent / 100) / $atr
            $slMultiplier = ($price * $slPercent / 100) / $atr

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

# --- Запуск ---
while ($true) {
    Run-Bot
    Start-Sleep -Seconds $config.rerun_interval_s
}
