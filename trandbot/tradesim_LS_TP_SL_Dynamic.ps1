param(
    [string]$configPath = ".\config.json"
)

# ------------------------------------------------------------------
# OKX trading bot (переписанный)
# - оптимизация TP/SL как множителей ATR
# - исправлена привязка индексов ATR
# - кеширование свечей
# - корректные комиссии
# - аккуратные логи
# ------------------------------------------------------------------

# --- Загрузка конфига ---
if (-not (Test-Path $configPath)) { throw "Config not found: $configPath" }
$config = Get-Content $configPath -Raw | ConvertFrom-Json

# --- Параметры ---
$global:positions = @{}
$global:balance = $config.max_balance
$global:totalPnL = 0.0
$global:winCount = 0
$global:totalClosed = 0
$commissionRate = if ($config.commission_rate) { [double]$config.commission_rate } else { 0.0009 }
$tpSlParams = @{}
$global:candlesCache = @{}

# ATR/EMA периоды
$atrPeriod = if ($config.atr_period) { [int]$config.atr_period } else { 14 }
$emaFast = if ($config.ema_fast) { [int]$config.ema_fast } else { 9 }
$emaSlow = if ($config.ema_slow) { [int]$config.ema_slow } else { 21 }

# таргет свечей для оптимизации (кол-во свечей)
$bar = $config.candle_period
$targetCandles = if ($config.target_candles) { [int]$config.target_candles } else { 96 * 30 } # default ~30 дней 15m
$delayMs = if ($config.request_delay_ms) { [int]$config.request_delay_ms } else { 50 }

# ---- Вспомогательные функции для работы с API (с кешем) ---
function Get-HistoricalCandles {
    param(
        [string]$symbol,
        [int]$count
    )

    if ($global:candlesCache.ContainsKey($symbol) -and $global:candlesCache[$symbol].Count -ge $count) {
        return $global:candlesCache[$symbol][0..($count-1)]
    }

    $all = New-Object System.Collections.Generic.List[object]
    $before = ""
    while ($all.Count -lt $count) {
        $limit = [math]::Min(1440, $count - $all.Count)
        $url = "https://www.okx.com/api/v5/market/candles?instId=$symbol&bar=$bar&limit=$limit"
        if ($before) { $url += "&before=$before" }
        try {
            $res = Invoke-RestMethod -Uri $url -Method Get -ErrorAction Stop
        } catch {
            Write-Warning "Ошибка запроса исторических данных для $symbol $_"
            break
        }
        if (-not $res.data -or $res.data.Count -eq 0) { break }
        foreach ($d in $res.data) {
            $obj = [PSCustomObject]@{
                Timestamp = [long]($d[0] / 1000)
                Open = [double]$d[1]
                High = [double]$d[2]
                Low = [double]$d[3]
                Close = [double]$d[4]
                Volume = if ($d.Count -gt 5) { [double]$d[5] } else { 0 }
            }
            $all.Add($obj)
        }
        $before = [long]$res.data[-1][0]
        Start-Sleep -Milliseconds $delayMs
    }

    $sorted = $all | Sort-Object Timestamp -Descending
    # OKX возвращает свечи с конца вначале — приводим к возрастающему времени
    $sorted = $sorted | Sort-Object Timestamp

    $global:candlesCache[$symbol] = $sorted
    return $sorted[0..([math]::Min($sorted.Count - 1, $count - 1))]
}

function Get-Candles {
    param(
        [string]$symbol,
        [int]$limit,
        [string]$period
    )
    # Проброс к кешу/API
    return Get-HistoricalCandles -symbol $symbol -count $limit
}

function Get-Last-Tick($symbol) {
    try {
        $url = "https://www.okx.com/api/v5/market/ticker?instId=$symbol"
        $res = Invoke-RestMethod -Uri $url -Method Get -ErrorAction Stop
        return [double]$res.data[0].last
    } catch {
        Write-Warning "Ошибка получения тика для $symbol $_"
        return $null
    }
}

# ---------------- Индикаторы ----------------
function Calculate-EMA($prices, $period) {
    $k = 2 / ($period + 1)
    $ema = @()

    if ($prices.Count -lt 1) { return $ema }

    # Инициализация: если есть хотя бы $period точек, используем SMA первого периода
    if ($prices.Count -ge $period) {
        $initialSMA = (($prices[0..($period - 1)]) | Measure-Object -Sum).Sum / $period
        for ($i = 0; $i -lt $period; $i++) { $ema += $initialSMA }
        for ($i = $period; $i -lt $prices.Count; $i++) {
            $prev = $ema[-1]
            $value = $prices[$i] * $k + $prev * (1 - $k)
            $ema += $value
        }
    } else {
        # недостаточно точек — fallback
        $ema += $prices[0]
        for ($i = 1; $i -lt $prices.Count; $i++) {
            $value = $prices[$i] * $k + $ema[$i-1] * (1 - $k)
            $ema += $value
        }
    }
    return $ema
}

function Calculate-ATR($candles, $period = 14) {
    # Возвращаем массив ATR, где atrArr[0] соответствует индексу свечи = $period (0-based)
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
    if ($trs.Count -lt $period) { return $atr }

    $initialSMA = ($trs[0..($period - 1)] | Measure-Object -Sum).Sum / $period
    $atr += $initialSMA

    $k = 2 / ($period + 1)
    for ($i = $period; $i -lt $trs.Count; $i++) {
        $value = $trs[$i] * $k + $atr[-1] * (1 - $k)
        $atr += $value
    }

    # Теперь atr.Count = trs.Count - period + 1
    # atr[0] относится к свечке с индексом = $period
    return $atr
}

# ---------------- Торговые операции ----------------
function Open-Position($symbol, $entryPrice, $units, $atr, $tpMultiplier, $slMultiplier, $side = "LONG") {
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

    $positionCost = $entryPrice * $units
    $commissionOpen = $positionCost * $commissionRate
    $totalCost = $positionCost + $commissionOpen
    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")

    if ($global:balance -lt $totalCost) {
        Write-Warning "Недостаточно баланса для открытия позиции $symbol требуется $([math]::Round($totalCost,2))$, доступно $([math]::Round($global:balance,2))$"
        return
    }
    $global:balance -= $totalCost

    $position = [PSCustomObject]@{
        Symbol = $symbol
        EntryPrice = $entryPrice
        TP = $tp
        SL = $sl
        Units = $units
        Side = $side
        Status = "OPEN"
        OpenedAt = [int][double]::Parse((Get-Date -UFormat %s))

        ExitPrice = $null
        PnL = $null
        ClosedAt = $null
    }

    $global:positions[$symbol] = $position
    Write-Host "$timestamp [TRADE] Открыта $side позиция $symbol по $entryPrice (TP: $tp, SL: $sl, Units: $units) — списано: $([math]::Round($totalCost,2))$" 
}

function Close-Position($symbol, $exitPrice, $reason) {
    if (-not $global:positions.ContainsKey($symbol)) { return }

    $pos = $global:positions[$symbol]

    if ($pos.Side -eq "LONG") {
        $pnl = ($exitPrice - $pos.EntryPrice) * $pos.Units
    } elseif ($pos.Side -eq "SHORT") {
        $pnl = ($pos.EntryPrice - $exitPrice) * $pos.Units
    } else {
        Write-Warning "Unknown position side: $($pos.Side)"
        return
    }

    $commissionClose = $exitPrice * $pos.Units * $commissionRate
    $pnlRounded = [Math]::Round($pnl - $commissionClose, 8)
    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")

    $global:totalPnL += $pnlRounded
    # возвращаем изначально заблокированную сумму плюс PnL
    $global:balance += ($pos.EntryPrice * $pos.Units) + $pnlRounded

    # статистика по инструменту
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

    Write-Host "$timestamp [CLOSE] Закрыта позиция $symbol ($($pos.Side)): по $exitPrice | PnL: $pnlRounded | Причина: $reason | Баланс: $([math]::Round($global:balance,2)) | Сделок: $($global:instrumentTotal[$symbol]) | WinRate инструмента: $instrumentWinRate%"
    $global:positions.Remove($symbol)
}

function Evaluate-Position($symbol) {
    if (-not $global:positions.ContainsKey($symbol)) { return }

    $pos = $global:positions[$symbol]
    if ($pos.Status -ne "OPEN") { return }

    $candles = Get-Candles $symbol 200 $config.candle_period
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
            Write-Host "$timestamp [Monitor] $symbol [Price: $currentPrice] → TP: $($pos.TP), SL: $($pos.SL)"
        }
    }
}

function CanOpenNew($symbol) {
    return (-not $global:positions.ContainsKey($symbol)) -and ($global:balance -ge $config.position_size_usd)
}

# --- Инициализация статистики ---
$global:instrumentTotal = @{}
$global:instrumentWins = @{}

# ---------------- Find-Best-TP-SL (оптимизация множителей ATR) ----------------
function Find-Best-TP-SL($symbol) {
    Write-Host "Оптимизация TP/SL (ATR multiples) для $symbol..."

    $candles = Get-HistoricalCandles -symbol $symbol -count $targetCandles
    if ($candles.Count -lt ($atrPeriod + $emaSlow + 5)) {
        Write-Warning "Недостаточно данных для $symbol ($($candles.Count) свечей)"
        return @{ tp_atr = 2.0; sl_atr = 1.0 }
    }

    $closes = $candles | ForEach-Object { $_.Close }
    $emaFastArr = Calculate-EMA $closes $emaFast
    $emaSlowArr = Calculate-EMA $closes $emaSlow
    $atrArr = Calculate-ATR $candles $atrPeriod

    if ($atrArr.Count -eq 0) {
        Write-Warning "Недостаточно данных ATR для $symbol"
        return @{ tp_atr = 2.0; sl_atr = 1.0 }
    }

    # Диапазоны множителей ATR (0.8 .. 3.0, шаг 0.2)
    $tpRange = @(For ($i = 8; $i -le 30; $i += 2) { [math]::Round($i / 10, 2) })  # 0.8 .. 3.0 step 0.2
    $slRange = @(For ($i = 5; $i -le 20; $i += 2) { [math]::Round($i / 10, 2) })  # 0.5 .. 2.0 step 0.2


    $best = $null

    for ($slIdx = 0; $slIdx -lt $slRange.Count; $slIdx++) {
        for ($tpIdx = 0; $tpIdx -lt $tpRange.Count; $tpIdx++) {
            $sl = $slRange[$slIdx]
            $tp = $tpRange[$tpIdx]

            if ($tp -lt $sl) { continue }

            $totalPnLUsd = 0.0
            $wins = 0; $losses = 0; $trades = 0
            $positionOpen = $null

            # начинаем с индекса, где EMA slow корректно рассчитан
            for ($i = $emaSlow; $i -lt $candles.Count; $i++) {
                # привязка ATR: atrArr[0] соответствует индексу свечи = $atrPeriod
                $atrIndex = $i - $atrPeriod
                if ($atrIndex -lt 0 -or $atrIndex -ge $atrArr.Count) { continue }
                $atr = $atrArr[$atrIndex]

                # сигналы EMA на close
                $emaCrossUp = ($emaFastArr[$i] -gt $emaSlowArr[$i]) -and ($emaFastArr[$i - 1] -le $emaSlowArr[$i - 1])
                $emaCrossDown = ($emaFastArr[$i] -lt $emaSlowArr[$i]) -and ($emaFastArr[$i - 1] -ge $emaSlowArr[$i - 1])

                if (-not $positionOpen) {
                    if ($emaCrossUp) {
                        $entry = $candles[$i].Close
                        $units = $config.position_size_usd / $entry

                        $tpPrice = [Math]::Round($entry + $atr * $tp, 8)
                        $slPrice = [Math]::Round($entry - $atr * $sl, 8)

                        $positionOpen = [PSCustomObject]@{
                            Side = "LONG"; Entry = $entry; TP = $tpPrice; SL = $slPrice; Units = $units
                        }
                        continue
                    } elseif ($emaCrossDown) {
                        $entry = $candles[$i].Close
                        $units = $config.position_size_usd / $entry

                        $tpPrice = [Math]::Round($entry - $atr * $tp, 8)
                        $slPrice = [Math]::Round($entry + $atr * $sl, 8)

                        $positionOpen = [PSCustomObject]@{
                            Side = "SHORT"; Entry = $entry; TP = $tpPrice; SL = $slPrice; Units = $units
                        }
                        continue
                    }
                } else {
                    $high = $candles[$i].High
                    $low = $candles[$i].Low
                    $exitPrice = $null; $result = $null

                    if ($positionOpen.Side -eq "LONG") {
                        if ($high -ge $positionOpen.TP) { $exitPrice = $positionOpen.TP; $result = "TP" }
                        elseif ($low -le $positionOpen.SL) { $exitPrice = $positionOpen.SL; $result = "SL" }
                    } else {
                        if ($low -le $positionOpen.TP) { $exitPrice = $positionOpen.TP; $result = "TP" }
                        elseif ($high -ge $positionOpen.SL) { $exitPrice = $positionOpen.SL; $result = "SL" }
                    }

                    if ($exitPrice -ne $null) {
                        if ($positionOpen.Side -eq "LONG") {
                            $pnlUsd = ($exitPrice - $positionOpen.Entry) * $positionOpen.Units
                        } else {
                            $pnlUsd = ($positionOpen.Entry - $exitPrice) * $positionOpen.Units
                        }

                        $commissionOpen = $positionOpen.Entry * $positionOpen.Units * $commissionRate
                        $commissionClose = $exitPrice * $positionOpen.Units * $commissionRate
                        $pnlUsd -= ($commissionOpen + $commissionClose)

                        $totalPnLUsd += $pnlUsd
                        $trades++
                        if ($result -eq "TP") { $wins++ } else { $losses++ }

                        $positionOpen = $null
                    }
                }
            }

            $winRate = 0
            if ($trades -gt 0) { $winRate = [math]::Round(($wins / $trades) * 100, 2) }

            if ($best -eq $null -or $totalPnLUsd -gt $best.Profit) {
                $best = [PSCustomObject]@{ TP = $tp; SL = $sl; Profit = $totalPnLUsd; WinRate = $winRate; Trades = $trades }
            }
        }
    }

    if (-not $best -or $best.Profit -eq 0 -or $best.WinRate -eq 0) {
        Write-Host "Результаты оптимизации для $symbol равны 0 или неубедительны, ставим дефолт TP=2.0 ATR, SL=1.0 ATR"
        return @{ tp_atr = 2.0; sl_atr = 1.0 }
    }

    Write-Host "Лучший для $symbol TP=$($best.TP) ATR, SL=$($best.SL) ATR (Profit=$([math]::Round($best.Profit,4)) USD, WinRate=$($best.WinRate)%, Trades=$($best.Trades))"
    return @{ tp_atr = $best.TP; sl_atr = $best.SL }
}

# ---------------- Оптимизация для всех инструментов ----------------
Write-Host "Запуск оптимизации TP/SL для инструментов..."
foreach ($symbol in $config.instruments) {
    $params = Find-Best-TP-SL $symbol
    $tpSlParams[$symbol] = $params
}
Write-Host "Оптимизация завершена. Результаты сохранены в памяти. Запуск торгового бота..."

# ---------------- Главный цикл торговли ----------------
function Run-Bot {
    $winRate = if ($global:totalClosed -gt 0) { [Math]::Round(($global:winCount / $global:totalClosed) * 100, 2) } else { 0 }

    Write-Host "🔄 Новый цикл бота. Баланс: $([math]::Round($global:balance,2))$ | PnL: $([math]::Round($global:totalPnL,4)) | Сделок: $global:totalClosed | WinRate: $winRate%"

    foreach ($symbol in $config.instruments) {
        try {
            if (CanOpenNew $symbol) {
                $candles = Get-Candles $symbol $config.candle_limit $config.candle_period
                if ($candles.Count -lt ($emaSlow + 5)) { continue }

                $closes = $candles | ForEach-Object { $_.Close }
                $emaFastArr = Calculate-EMA $closes $emaFast
                $emaSlowArr = Calculate-EMA $closes $emaSlow
                $atrArr = Calculate-ATR $candles $atrPeriod
                if ($atrArr.Count -eq 0) { continue }
                $atr = $atrArr[-1]

                $emaCrossUp = ($emaFastArr[-1] -gt $emaSlowArr[-1]) -and ($emaFastArr[-2] -le $emaSlowArr[-2])
                $ema21TrendUp = $emaSlowArr[-1] -gt $emaSlowArr[-6]

                $emaCrossDown = ($emaFastArr[-1] -lt $emaSlowArr[-1]) -and ($emaFastArr[-2] -ge $emaSlowArr[-2])
                $ema21TrendDown = $emaSlowArr[-1] -lt $emaSlowArr[-6]

                $price = Get-Last-Tick $symbol
                if ($null -eq $price) { continue }

                $units = [Math]::Round($config.position_size_usd / $price, 8)

                if ($tpSlParams.ContainsKey($symbol)) {
                    $tpMultiplier = $tpSlParams[$symbol].tp_atr
                    $slMultiplier = $tpSlParams[$symbol].sl_atr
                } else {
                    $tpMultiplier = 2.0; $slMultiplier = 1.0
                }

                if ($emaCrossUp -and $ema21TrendUp) {
                    Open-Position $symbol $price $units $atr $tpMultiplier $slMultiplier "LONG"
                } elseif ($emaCrossDown -and $ema21TrendDown) {
                    Open-Position $symbol $price $units $atr $tpMultiplier $slMultiplier "SHORT"
                }
            } else {
                Evaluate-Position $symbol
            }
        } catch {
            Write-Warning "Ошибка при обработке $symbol $_"
        }
        Start-Sleep -Milliseconds 200
    }
}

# --- Запуск ---
while ($true) {
    Run-Bot
    Start-Sleep -Seconds $config.rerun_interval_s
}
