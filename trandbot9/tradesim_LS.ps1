# === CONFIG ===
param(
    [string]$configPath = ".\config.json"
)

# Имя лог-файла формируется на основе имени файла конфига
$logFileName = [IO.Path]::GetFileNameWithoutExtension($configPath)
$logFile = ".\${logFileName}_trades.log"

$config = Get-Content $configPath | ConvertFrom-Json

# === STATE ===
$global:positions = @{}               # словарь: ключ = символ, значение = массив позиций
$global:balance = $config.max_balance
$global:totalPnL = 0
$global:winCount = 0
$global:totalClosed = 0
$global:candleCache = @{}
$commissionRate = $config.commission_rate # e.g. 0.0009 for 0.09%
$evaluate_candle_period = $config.evaluate_candle_period

# === UTILS ===
function Get-Timestamp { return [int][double]::Parse((Get-Date -UFormat %s)) }
function Format-Time { return (Get-Date -Format "yyyy-MM-dd HH:mm:ss") }
function Format-Time-FromTS($ts) { return ([DateTimeOffset]::FromUnixTimeSeconds($ts)).LocalDateTime.ToString("yyyy-MM-dd HH:mm:ss") }

function LogConsole($msg, $type = "INFO") {
    $ts = Format-Time
    $logLine = "[$ts][$type] $msg"
    Write-Host $logLine
    try {
        Add-Content -Path $logFile -Value $logLine
    } catch {
        Write-Host "[$ts][ERROR] Не удалось записать в лог-файл $logFile. $($_)"
    }
}

# function LogTradeWithWinRate($pos, $reason) {
#     $timestamp = Format-Time
#     $logEntry = "[${timestamp}][TRADE] Закрыта позиция $($pos.Symbol) $($pos.Side) PnL: $($pos.PnL) Причина: $reason Баланс: $($global:balance)`n" +
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
    $cacheKey = "$symbol-$period-$limit"
    
    # Проверяем, есть ли в кэше и свежие ли данные
    if ($global:candleCache.ContainsKey($cacheKey)) {
        $cached = $global:candleCache[$cacheKey]
        $age = Get-Timestamp - $cached.Timestamp
        if ($age -lt 60) {  # если кэш моложе 60 секунд
            return $cached.Candles
        }
    }

    # Получаем новые свечи с API
    try {
        $url = "https://www.okx.com/api/v5/market/candles?instId=$symbol&bar=$period&limit=$limit"
        $res = Invoke-RestMethod -Uri $url -Method Get
        if (-not $res.data) { return @() }

        $candles = $res.data | ForEach-Object {
            [PSCustomObject]@{
                Timestamp = [long]($_[0])/1000
                Open      = [double]$_[1]
                High      = [double]$_[2]
                Low       = [double]$_[3]
                Close     = [double]$_[4]
                Volume    = [double]$_[5]
            }
        } | Sort-Object Timestamp

        # Сохраняем в кэш
        $global:candleCache[$cacheKey] = @{
            Candles = $candles
            Timestamp = Get-Timestamp
        }

        return $candles
    } catch {
        LogConsole "Ошибка получения свечей для ${symbol}: $($_)" "ERROR"
        return @()
    }
}

# === INDICATORS ===
function Calculate-EMA($prices, $period) {
    $k = 2 / ($period + 1)
    $ema = @($prices[0])
    for ($i = 1; $i -lt $prices.Count; $i++) {
        $ema += $prices[$i] * $k + $ema[$i-1] * (1 - $k)
    }
    return $ema
}

function Calculate-ATR($candles, $period) {
    $trs = @()
    for ($i = 1; $i -lt $candles.Count; $i++) {
        $high = $candles[$i].High
        $low = $candles[$i].Low
        $prevClose = $candles[$i - 1].Close
        $trs += [Math]::Max($high - $low, [Math]::Max([Math]::Abs($high - $prevClose), [Math]::Abs($low - $prevClose)))
    }
    $atr = @()
    $initialSMA = ($trs[0..($period-1)] | Measure-Object -Sum).Sum / $period
    $atr += $initialSMA
    $k = 2 / ($period + 1)
    for ($i = $period; $i -lt $trs.Count; $i++) {
        $atr += $trs[$i] * $k + $atr[-1] * (1 - $k)
    }
    return $atr
}

function Get-RSI([double[]]$prices, [int]$period=14) {
    if ($prices.Count -lt ($period+1)) { return @() }
    $gains=@(); $losses=@()
    for ($i=1; $i -lt $prices.Count; $i++) {
        $change=$prices[$i]-$prices[$i-1]
        if ($change -gt 0) { $gains+=$change; $losses+=0 } else { $gains+=0; $losses+=[Math]::Abs($change) }
    }
    $avgGain=($gains[0..($period-1)]|Measure-Object -Sum).Sum/$period
    $avgLoss=($losses[0..($period-1)]|Measure-Object -Sum).Sum/$period
    $rsi=@()
    $rs=if($avgLoss-0){$avgGain/$avgLoss}else{[double]::PositiveInfinity}
    $rsi+=[Math]::Round(100-(100/(1+$rs)),2)
    for($i=$period;$i -lt $gains.Count;$i++){
        $avgGain=(($avgGain*($period-1))+$gains[$i])/$period
        $avgLoss=(($avgLoss*($period-1))+$losses[$i])/$period
        $rs=if($avgLoss-0){$avgGain/$avgLoss}else{[double]::PositiveInfinity}
        $rsi+=[Math]::Round(100-(100/(1+$rs)),2)
    }
    return $rsi
}

function Get-Trend($candles, $atrPeriod, $trend_candles, $trendsize=1.0) {
    if (-not $candles -or $candles.Count -lt $trend_candles) { return "NEUTRAL" }
    $atrArr = Calculate-ATR $candles $atrPeriod
    if (-not $atrArr -or $atrArr.Count -eq 0) { return "NEUTRAL" }
    $lastAtr=$atrArr[-1]
    $lastCloses=$candles | Sort-Object Timestamp | Select-Object -Last $trend_candles | ForEach-Object {$_.Close}
    if ($lastCloses.Count -lt 2) { return "NEUTRAL" }
    $delta = $lastCloses[-1] - $lastCloses[0]
    if ($delta -gt $lastAtr*$trendsize) { return "UP" } elseif ($delta -lt -$lastAtr*$trendsize) { return "DOWN" } else { return "NEUTRAL" }
}

function Calculate-BollingerBands($candles, $period, $stdDev) {
    if ($candles.Count -lt $period) { return $null }
    $closes = $candles.Close
    $sma = @()
    $upperBand = @()
    $lowerBand = @()

    for ($i = $period - 1; $i -lt $closes.Count; $i++) {
        $slice = $closes[($i - $period + 1)..$i]
        $avg = $slice | Measure-Object -Average | Select-Object -ExpandProperty Average
        $sumOfSquares = ($slice | ForEach-Object { [Math]::Pow($_ - $avg, 2) } | Measure-Object -Sum).Sum
        $stdDevValue = if ($period -gt 1) { [Math]::Sqrt($sumOfSquares / ($period -1)) } else { 0 }

        $sma += $avg
        $upperBand += $avg + ($stdDevValue * $stdDev)
        $lowerBand += $avg - ($stdDevValue * $stdDev)
    }

    return [PSCustomObject]@{
        SMA = $sma
        Upper = $upperBand
        Lower = $lowerBand
    }
}

function Calculate-ADX($candles, $period) {
    if ($candles.Count -lt (2 * $period)) { return $null }

    $highs = $candles.High
    $lows = $candles.Low
    $closes = $candles.Close

    $plusDMs = @()
    $minusDMs = @()
    $trs = @()

    for ($i = 1; $i -lt $candles.Count; $i++) {
        $moveUp = $highs[$i] - $highs[$i-1]
        $moveDown = $lows[$i-1] - $lows[$i]

        if ($moveUp -gt $moveDown -and $moveUp -gt 0) {
            $plusDMs += $moveUp
        } else {
            $plusDMs += 0
        }

        if ($moveDown -gt $moveUp -and $moveDown -gt 0) {
            $minusDMs += $moveDown
        } else {
            $minusDMs += 0
        }

        $tr = [Math]::Max($highs[$i] - $lows[$i], [Math]::Max([Math]::Abs($highs[$i] - $closes[$i-1]), [Math]::Abs($lows[$i] - $closes[$i-1])))
        $trs += $tr
    }

    # Wilder's smoothing
    $smooth = {
        param($values, $p)
        $smoothed = @()
        if ($values.Count -eq 0) { return $smoothed }
        $smoothed += ($values[0..($p-1)] | Measure-Object -Sum).Sum
        for ($i = $p; $i -lt $values.Count; $i++) {
            $smoothed += $smoothed[-1] - ($smoothed[-1] / $p) + $values[$i]
        }
        return $smoothed
    }

    $smoothedTRs = &$smooth $trs $period
    $smoothedPlusDMs = &$smooth $plusDMs $period
    $smoothedMinusDMs = &$smooth $minusDMs $period

    $plusDIs = @()
    $minusDIs = @()

    for ($i = 0; $i -lt $smoothedTRs.Count; $i++) {
        $plusDIs += if ($smoothedTRs[$i] -ne 0) { 100 * ($smoothedPlusDMs[$i] / $smoothedTRs[$i]) } else { 0 }
        $minusDIs += if ($smoothedTRs[$i] -ne 0) { 100 * ($smoothedMinusDMs[$i] / $smoothedTRs[$i]) } else { 0 }
    }

    $dxs = @()
    for ($i = 0; $i -lt $plusDIs.Count; $i++) {
        $diSum = $plusDIs[$i] + $minusDIs[$i]
        $dxs += if ($diSum -ne 0) { [Math]::Abs(100 * (($plusDIs[$i] - $minusDIs[$i]) / $diSum)) } else { 0 }
    }
    
    $adx = &$smooth $dxs $period

    # Pad beginning of array to match candle count
    $padding = @(0) * ($candles.Count - $adx.Count)
    return $padding + $adx
}

function Get-StopLoss($candles,$sl_candles,$direction) {
    $recentCandles = $candles | Sort-Object Timestamp | Select-Object -Last $sl_candles
    switch ($direction.ToUpper()) {
        "LONG" { return [Math]::Round(($recentCandles | Measure-Object -Property Close -Minimum).Minimum,8) }
        "SHORT"{ return [Math]::Round(($recentCandles | Measure-Object -Property Close -Maximum).Maximum,8) }
        default{ throw "Unknown direction: $direction" }
    }
}

# === POSITION LOGIC ===
# === POSITION LOGIC ===
# Determines if a new position can be opened, checking global and instrument limits.
function Get-OpenPermission($symbol, $side) {
    # 1. Проверка глобального лимита открытых позиций
    $totalOpenPositions = 0
    foreach ($key in $global:positions.Keys) {
        $totalOpenPositions += ($global:positions[$key] | Where-Object { $_.Status -eq "OPEN" }).Count
    }
    if ($totalOpenPositions -ge $config.max_open_positions) {
        return [PSCustomObject]@{ CanOpen = $false; IsCounter = $false }
    }

    $permission = [PSCustomObject]@{ CanOpen = $true; IsCounter = $false }

    # 2. Проверка лимита позиций на один инструмент (не более 2)
    if ($global:positions.ContainsKey($symbol)) {
        $instrumentPositions = ($global:positions[$symbol] | Where-Object { $_.Status -eq "OPEN" }).Count
        if ($instrumentPositions -ge 2) {
            return [PSCustomObject]@{ CanOpen = $false; IsCounter = $false }
        }
    }

    if (-not $global:positions.ContainsKey($symbol) -or $global:positions[$symbol].Count -eq 0) {
        return $permission
    }

    # 3. Блокировка, если уже есть позиция в ту же сторону
    $sameSide = $global:positions[$symbol] | Where-Object { $_.Side -eq $side }
    if ($sameSide.Count -gt 0) {
        $permission.CanOpen = $false
        return $permission
    }

    # 4. Флаг, если открывается встречная позиция
    $oppositeSide = if ($side -eq "LONG") { "SHORT" } else { "LONG" }
    $oppositePos = $global:positions[$symbol] | Where-Object { $_.Side -eq $oppositeSide }
    if ($oppositePos.Count -gt 0) {
        $permission.IsCounter = $true
    }

    return $permission
}

function Check-CandleSizeRisk {
    param (
        [array]$candles,
        [double]$atr,
        [ref]$longSignal,
        [ref]$shortSignal,
        [int]$lookback,
        [double]$multiplier
    )

    if (-not $candles -or $candles.Count -lt $lookback) { return }

    $recentCandles = $candles | Sort-Object Timestamp | Select-Object -Last $lookback

    foreach ($c in $recentCandles) {
        $body = [Math]::Abs($c.Close - $c.Open)
        if ($body -gt ($multiplier * $atr)) {
            LogConsole "🚫 Свеча слишком большая ($body > $multiplier * ATR=$atr), пропуск входа" "WARN"
            $longSignal.Value = $false
            $shortSignal.Value = $false
            return
        }
        
    }
}

function Get-Market-Regime($candles, $adxPeriod, $adxThreshold) {
    if (-not $config.use_regime_filter) { return "TREND" } # Default to trend if filter is off

    $adx = Calculate-ADX $candles $adxPeriod
    if ($null -eq $adx -or $adx.Count -eq 0) {
        LogConsole "Не удалось рассчитать ADX, используется режим TREND по умолчанию." "WARN"
        return "TREND" 
    }

    $lastAdx = $adx[-1]
    # LogConsole "ADX($adxPeriod) on $($config.higher_tf) is $lastAdx" "REGIME"
    if ($lastAdx -ge $adxThreshold) {
        return "TREND"
    } else {
        return "RANGE"
    }
}

# Универсальная функция открытия позиции с расчетом маржи
function Open-Position($symbol, $entryPrice, $size, $side, $sl, $tp, [bool]$isCounter = $false) {
    if ($size -le 0) {
        LogConsole "Размер позиции 0 или меньше для $symbol, вход отменен." "WARN"
        return
    }

    $symbolDisplay = if ($isCounter) { "⚡ $symbol" } else { $symbol }

    # Считаем номинальную стоимость, маржу и комиссию
    $notionalValue = $entryPrice * $size
    $marginCost = $notionalValue / $config.leverage
    $commissionOpen = $notionalValue * $commissionRate
    $totalCost = $marginCost + $commissionOpen # Реальная стоимость списания с баланса

    if ($global:balance -lt $totalCost) { 
        LogConsole "Недостаточно баланса для $symbol. Нужно $totalCost (маржа + комиссия), доступно $($global:balance)" "WARN"
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
        CommissionOpen = $commissionOpen
        IsCounter = [bool]$isCounter
    }

    if (-not $global:positions.ContainsKey($symbol) -or $global:positions[$symbol] -eq $null) {
        $global:positions[$symbol] = @()
    }

    $global:positions[$symbol] = @($global:positions[$symbol]) + $position

    LogConsole "🚀 Открыта $side позиция $symbolDisplay $entryPrice (TP:$tp SL:$sl Size:$size) списано:$totalCost$" $side
}

function Close-Position($symbol, $exitPrice, $reason, $side) {
    if (-not $global:positions.ContainsKey($symbol)) { return }

    $posList = $global:positions[$symbol]
    $pos = $posList | Where-Object { $_.Side -eq $side -and $_.Status -eq "OPEN" } | Select-Object -First 1
    if (-not $pos) { return }

    # PnL без учета комиссии открытия
    $pnl = if ($pos.Side -eq "LONG") { ($exitPrice - $pos.EntryPrice) * $pos.Size } else { ($pos.EntryPrice - $exitPrice) * $pos.Size }

    # Комиссия при закрытии
    $commissionClose = $exitPrice * $pos.Size * $commissionRate
    $pnlRounded = [Math]::Round($pnl - $commissionClose, 8)

    $global:totalPnL += $pnlRounded
    $global:balance += $pos.EntryPrice*$pos.Size + $pnlRounded

    if ($reason -eq "TP") { $global:winCount++ }
    $global:totalClosed++

    LogConsole "✅ Закрыта позиция $symbol ($($pos.Side)): по $exitPrice | PnL:$pnlRounded | Причина:$reason | Баланс:$($global:balance)" "CLOSE"

    # Обновляем список позиций, удаляя закрытую
    $remaining = $posList | Where-Object { $_.OpenedAt -ne $pos.OpenedAt }
    if ($remaining.Count -gt 0) {
        $global:positions[$symbol] = [System.Collections.ArrayList]@($remaining)
    } else {
        $global:positions.Remove($symbol)
    }
}

# Evaluates open positions, including new Trailing Stop logic.
function Evaluate-Position($symbol, $currentPrice, $atr) {
    if (-not $global:positions.ContainsKey($symbol) -or $null -eq $currentPrice) { return }
    
    # Создаем копию массива для безопасной итерации, т.к. Close-Position может изменять коллекцию
    $positionsToCheck = @($global:positions[$symbol])

    foreach ($pos in $positionsToCheck) {
        if ($pos.Status -ne "OPEN") { continue }

        # --- TRAILING STOP LOGIC ---
        if ($config.use_trailing_stop -and $pos.IsCounter -eq $false -and $atr -gt 0) {
            if ($pos.Side -eq "LONG" -and $currentPrice -gt $pos.EntryPrice) {
                $newSL = [Math]::Round($currentPrice - ($atr * $config.trailing_stop_atr_distance), 8)
                if ($newSL -gt $pos.SL) {
                    LogConsole "↗️ SL для $($pos.Symbol) ($($pos.Side)) подвинут на $newSL" "TRAIL"
                    $pos.SL = $newSL
                }
            } elseif ($pos.Side -eq "SHORT" -and $currentPrice -lt $pos.EntryPrice) {
                $newSL = [Math]::Round($currentPrice + ($atr * $config.trailing_stop_atr_distance), 8)
                if ($newSL -lt $pos.SL) {
                    LogConsole "↘️ SL для $($pos.Symbol) ($($pos.Side)) подвинут на $newSL" "TRAIL"
                    $pos.SL = $newSL
                }
            }
        }

        LogConsole "[$($pos.Side)] ${symbol}: [Price: $currentPrice] → TP: $($pos.TP), SL: $($pos.SL)" "MONITOR"

        # 1. Быстрая проверка по текущей цене (tick)
        if ($pos.Side -eq "LONG") {
            if ($currentPrice -ge $pos.TP) { Close-Position $symbol $pos.TP "TP" "LONG"; continue }
            if ($currentPrice -le $pos.SL) { Close-Position $symbol $pos.SL "SL" "LONG"; continue }
        } elseif ($pos.Side -eq "SHORT") {
            if ($currentPrice -le $pos.TP) { Close-Position $symbol $pos.TP "TP" "SHORT"; continue }
            if ($currentPrice -ge $pos.SL) { Close-Position $symbol $pos.SL "SL" "SHORT"; continue }
        }

        # 2. Проверка по истории свечей (на случай, если цена пробила TP/SL и вернулась внутри одной свечи)
        $candles = Get-Candles $symbol $config.candle_limit $evaluate_candle_period
        if ($candles.Count -eq 0) { continue }

        $candlesAfterOpen = $candles | Where-Object { $_.Timestamp -ge $pos.OpenedAt }
        foreach ($candle in $candlesAfterOpen) {
            # Проверяем, не закрыта ли позиция предыдущей итерацией или быстрым чеком
            $posStillExists = $global:positions.ContainsKey($symbol) -and ($global:positions[$symbol] | Where-Object { $_.OpenedAt -eq $pos.OpenedAt -and $_.Status -eq "OPEN" })
            if (-not $posStillExists) { break }

            if ($pos.Side -eq "LONG") {
                if ($candle.High -ge $pos.TP) { Close-Position $symbol $pos.TP "TP" "LONG"; break }
                if ($candle.Low -le $pos.SL) { Close-Position $symbol $pos.SL "SL" "LONG"; break }
            } elseif ($pos.Side -eq "SHORT") {
                if ($candle.Low -le $pos.TP) { Close-Position $symbol $pos.TP "TP" "SHORT"; break }
                if ($candle.High -ge $pos.SL) { Close-Position $symbol $pos.SL "SL" "SHORT"; break }
            }
        }
    }
}


# === MAIN BOT LOOP ===
function Run-Bot {
    $winRate   = if ($global:totalClosed -gt 0) { [Math]::Round(($global:winCount/$global:totalClosed)*100,2) } else { 0 }
    $timestamp = Format-Time
    
    LogConsole "🔄 Новый цикл. Баланс:$($global:balance)$ | PnL:$($global:totalPnL) 💵 | Сделок:$global:totalClosed | WinRate:$winRate%" "INFO"

    foreach ($symbol in $config.instruments) {
        # --- Получаем ключевые данные в начале итерации ---
        $price = Get-Last-Tick $symbol
        if ($null -eq $price) {
            LogConsole "Не удалось получить цену для $symbol, пропуск." "WARN"
            continue
        }

        $candles = Get-Candles $symbol $config.candle_limit $config.candle_period
        if ($candles.Count -lt 50) { continue }

        $atrArr    = Calculate-ATR $candles $config.atrPeriod
        if ($atrArr.Count -eq 0) { continue }
        $atr = $atrArr[-1]

        # --- 1. Оцениваем и возможно закрываем текущие позиции (с трейлинг-стопом) ---
        Evaluate-Position $symbol $price $atr

        # --- 2. Определяем режим рынка ---
        $regime_candles = Get-Candles $symbol $config.candle_limit $config.higher_tf
        $regime = "TREND" # Значение по умолчанию
        if ($null -ne $regime_candles) {
            $regime = Get-Market-Regime $regime_candles $config.regime_adx_period $config.regime_adx_threshold
        }
        
        # --- 3. Логика открытия новых позиций в зависимости от режима ---
        $permission = Get-OpenPermission $symbol "ANY"
        if (-not $permission.CanOpen) { continue } # Если уже есть позиция, пропускаем открытие новой

        if ($regime -eq "TREND") {
            # --- СТРАТЕГИЯ СЛЕДОВАНИЯ ТРЕНДУ ---
            LogConsole "[$symbol] Режим: TREND. Используется стратегия EMA+RSI." "STRATEGY"
            $closes   = $candles | ForEach-Object { $_.Close }
            $ema21    = Calculate-EMA $closes 21
            $rsi14Arr = Get-RSI $closes 14
            $rsi30Arr = Get-RSI $closes 30
            if ($rsi14Arr.Count -lt 2 -or $rsi30Arr.Count -lt 2) { continue }

            $rsi14Curr = $rsi14Arr[-1]
            $rsi30Curr = $rsi30Arr[-1]
            $trend     = Get-Trend $candles $config.atrPeriod $config.trend_candles $config.trendsize
            $lastEMA21 = $ema21[-1]

            $longSignal  = ($price -gt $lastEMA21) -and ($rsi14Curr -ge $config.rsi14_max) -and ($rsi30Curr -ge $config.rsi30_max) -and ($trend -eq "UP")
            $shortSignal = ($price -lt $lastEMA21) -and ($rsi14Curr -le $config.rsi14_min) -and ($rsi30Curr -le $config.rsi30_min) -and ($trend -eq "DOWN")

            if ($longSignal -or $shortSignal) {
                Check-CandleSizeRisk -candles $candles -atr $atr -longSignal ([ref]$longSignal) -shortSignal ([ref]$shortSignal) -lookback $config.candleRiskLookback -multiplier $config.candleRiskMultiplier
            }

            if ($longSignal) {
                $sl = Get-StopLoss $candles $config.sl_candles "LONG"
                $minDist = [Math]::Max($atr*0.2, $price*0.001)
                if ($sl -ge $price -or [Math]::Abs($price-$sl) -lt $minDist) { $sl = [Math]::Round($price-$minDist,8) }
                if ([Math]::Abs($price - $sl) -gt (4*$atr) -and $atr -gt 0) { $sl = [Math]::Round($price - 4*$atr, 8) }
                
                $tp = [Math]::Round($price + [Math]::Max($atr * $config.tp_ATR, $minDist), 8)

                $sl_dist_price = $price - $sl
                $risk_amount_usd = $global:balance * ($config.position_risk_percent / 100)
                $size = if ($sl_dist_price -gt 0) { [Math]::Round($risk_amount_usd / $sl_dist_price, 4) } else { 0 }

                if ($size -gt 0) {
                    Open-Position $symbol $price $size "LONG" $sl $tp $permission.IsCounter
                }
            } elseif ($shortSignal) {
                $sl = Get-StopLoss $candles $config.sl_candles "SHORT"
                $minDist = [Math]::Max($atr*0.2, $price*0.001)
                if ($sl -le $price -or [Math]::Abs($price-$sl) -lt $minDist) { $sl = [Math]::Round($price+$minDist,8) }
                if ([Math]::Abs($price - $sl) -gt (4*$atr) -and $atr -gt 0) { $sl = [Math]::Round($price + 4*$atr, 8) }

                $tp = [Math]::Round($price - [Math]::Max($atr * $config.tp_ATR, $minDist), 8)

                $sl_dist_price = $sl - $price
                $risk_amount_usd = $global:balance * ($config.position_risk_percent / 100)
                $size = if ($sl_dist_price -gt 0) { [Math]::Round($risk_amount_usd / $sl_dist_price, 4) } else { 0 }

                if ($size -gt 0) {
                    Open-Position $symbol $price $size "SHORT" $sl $tp $permission.IsCounter
                }
            }

        } else { # RANGE
            # --- СТРАТЕГИЯ ТОРГОВЛИ В КАНАЛЕ ---
            LogConsole "[$symbol] Режим: RANGE. Используется стратегия Bollinger Bands." "STRATEGY"
            $bb = Calculate-BollingerBands $candles $config.range_bb_period $config.range_bb_stddev
            if ($null -ne $bb) {
                $lowerBand = $bb.Lower[-1]
                $upperBand = $bb.Upper[-1]
                $middleBand = $bb.SMA[-1]

                $longSignal = $price -lt $lowerBand
                $shortSignal = $price -gt $upperBand

                if ($longSignal) {
                    $sl = $lowerBand - ($atr * 1.5) # SL = 1.5 ATR под нижней границей
                    $tp = $middleBand              # TP = средняя линия
                    
                    $sl_dist_price = $price - $sl
                    $risk_amount_usd = $global:balance * ($config.position_risk_percent / 100)
                    $size = if ($sl_dist_price -gt 0) { [Math]::Round($risk_amount_usd / $sl_dist_price, 4) } else { 0 }

                    # --- Жесткий лимит на максимальный размер позиции ---
                    $notional_value = $price * $size
                    if ($notional_value -gt $config.max_position_notional_usd) {
                        $size = [Math]::Round($config.max_position_notional_usd / $price, 4)
                        LogConsole "Размер позиции уменьшен до $size, чтобы не превышать лимит в $($config.max_position_notional_usd) USD" "WARN"
                    }

                    if ($size -gt 0) {
                        Open-Position $symbol $price $size "LONG" $sl $tp $permission.IsCounter
                    }
                } elseif ($shortSignal) {
                    $sl = $upperBand + ($atr * 1.5) # SL = 1.5 ATR над верхней границей
                    $tp = $middleBand              # TP = средняя линия

                    $sl_dist_price = $sl - $price
                    $risk_amount_usd = $global:balance * ($config.position_risk_percent / 100)
                    $size = if ($sl_dist_price -gt 0) { [Math]::Round($risk_amount_usd / $sl_dist_price, 4) } else { 0 }

                    # --- Жесткий лимит на максимальный размер позиции ---
                    $notional_value = $price * $size
                    if ($notional_value -gt $config.max_position_notional_usd) {
                        $size = [Math]::Round($config.max_position_notional_usd / $price, 4)
                        LogConsole "Размер позиции уменьшен до $size, чтобы не превышать лимит в $($config.max_position_notional_usd) USD" "WARN"
                    }

                    if ($size -gt 0) {
                        Open-Position $symbol $price $size "SHORT" $sl $tp $permission.IsCounter
                    }
                }
            }
        }
    }
}


# === MAIN LOOP ===
if (Test-Path $logFile) { Remove-Item $logFile -Force }
while ($true) { Run-Bot; Start-Sleep -Seconds $config.rerun_interval_s }
