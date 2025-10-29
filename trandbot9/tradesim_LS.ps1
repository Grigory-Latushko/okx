# === Trading bot (rewritten) ===
# Цель: одна открытая позиция на инструмент. Запрещены встречные позиции.
# Перед запуском разместите config.json в той же папке и настройте параметры.

param(
    [string]$configPath = ".\config.json"
)

# --- Logging / state ---
$logFileName = [IO.Path]::GetFileNameWithoutExtension($configPath)
$logFile = ".\${logFileName}_trades.log"

if (Test-Path $logFile) { Remove-Item $logFile -Force }

function Get-Timestamp { return [int][double]::Parse((Get-Date -UFormat %s)) }
function Format-Time { return (Get-Date -Format "yyyy-MM-dd HH:mm:ss") }
function Format-Time-FromTS($ts) { return ([DateTimeOffset]::FromUnixTimeSeconds($ts)).LocalDateTime.ToString("yyyy-MM-dd HH:mm:ss") }

function LogConsole($msg, $type = "INFO") {
    $ts = Format-Time
    Write-Host "[$ts][$type] $msg"
}

# --- Load config & validate ---
if (-not (Test-Path $configPath)) { throw "Config not found: $configPath" }

try {
    $config = Get-Content $configPath -Raw | ConvertFrom-Json
} catch {
    throw "Error reading config.json: $_"
}

function Validate-Config($c) {
    $required = @('instruments','position_size_usd','atrPeriod','tp_ATR','candle_period','candle_limit','rerun_interval_s')
    foreach ($r in $required) {
        if (-not ($c.PSObject.Properties.Name -contains $r)) { throw "Missing config field: $r" }
    }

    if (-not $c.instruments -or $c.instruments.Count -eq 0) { throw "instruments must be a non-empty array" }
}

Validate-Config $config

# State
$global:positions = @{}               # хеш: symbol -> array of open positions (0 or 1 element)
$global:balance = if ($null -ne $config.max_balance) { [double]$config.max_balance } else { 10000.0 }
$global:totalPnL = 0.0
$global:winCount = 0
$global:totalClosed = 0
$global:candleCache = @{}

$commissionRate = if ($null -ne $config.commission_rate) { [double]$config.commission_rate } else { 0.0009 }
$evaluate_candle_period = if ($null -ne $config.evaluate_candle_period) { $config.evaluate_candle_period } else { $config.candle_period }

# --- Utilities for API and caching ---
function Get-Last-Tick($symbol) {
    try {
        $url = "https://www.okx.com/api/v5/market/ticker?instId=$symbol"
        $res = Invoke-RestMethod -Uri $url -Method Get -ErrorAction Stop
        return [double]$res.data[0].last
    } catch {
        LogConsole "Ошибка получения тика для ${symbol}: $($_)" "ERROR"
        return $null
    }
}

function Get-Candles($symbol, $limit, $period) {
    $cacheKey = "$symbol-$period-$limit"
    if ($global:candleCache.ContainsKey($cacheKey)) {
        $cached = $global:candleCache[$cacheKey]
        $age = Get-Timestamp - $cached.Timestamp
        if ($age -lt 60) { return $cached.Candles }
    }

    try {
        $url = "https://www.okx.com/api/v5/market/candles?instId=$symbol&bar=$period&limit=$limit"
        $res = Invoke-RestMethod -Uri $url -Method Get -ErrorAction Stop
        if (-not $res.data) { return @() }

        $candles = $res.data | ForEach-Object {
            [PSCustomObject]@{
                Timestamp = [long]($_[0]) / 1000
                Open      = [double]$_[1]
                High      = [double]$_[2]
                Low       = [double]$_[3]
                Close     = [double]$_[4]
                Volume    = [double]$_[5]
            }
        } | Sort-Object Timestamp

        $global:candleCache[$cacheKey] = @{ Candles = $candles; Timestamp = Get-Timestamp }
        return $candles
    } catch {
        LogConsole "Ошибка получения свечей для ${symbol}: $($_)" "ERROR"
        return @()
    }
}

# --- Indicators (robust) ---
function Calculate-EMA([double[]]$prices, [int]$period) {
    if (-not $prices -or $prices.Count -eq 0) { return @() }
    if ($prices.Count -lt 1) { return @() }
    # If not enough points - return last price as single-element EMA
    if ($prices.Count -lt $period) { return ,([double]$prices[-1]) }

    $k = 2.0 / ($period + 1)
    $ema = New-Object System.Collections.Generic.List[double]
    $ema.Add([double]$prices[0])
    for ($i = 1; $i -lt $prices.Count; $i++) {
        $prev = $ema[$i-1]
        $ema.Add(($prices[$i] * $k) + ($prev * (1 - $k)))
    }
    return $ema
}

function Calculate-ATR($candles, $period) {
    if (-not $candles -or $candles.Count -le $period) { return @() }
    $trs = @()
    for ($i = 1; $i -lt $candles.Count; $i++) {
        $high = $candles[$i].High
        $low = $candles[$i].Low
        $prevClose = $candles[$i - 1].Close
        $trs += [Math]::Max($high - $low, [Math]::Max([Math]::Abs($high - $prevClose), [Math]::Abs($low - $prevClose)))
    }

    if ($trs.Count -lt $period) { return @() }
    $atr = @()
    $initialSMA = ($trs[0..($period-1)] | Measure-Object -Sum).Sum / $period
    $atr += $initialSMA
    $k = 2.0 / ($period + 1)
    for ($i = $period; $i -lt $trs.Count; $i++) {
        $prev = $atr[-1]
        $atr += ($trs[$i] * $k + $prev * (1 - $k))
    }
    return $atr
}

function Get-RSI([double[]]$prices, [int]$period=14) {
    if (-not $prices -or $prices.Count -lt ($period + 1)) { return @() }
    $gains = New-Object System.Collections.Generic.List[double]
    $losses = New-Object System.Collections.Generic.List[double]
    for ($i = 1; $i -lt $prices.Count; $i++) {
        $change = $prices[$i] - $prices[$i-1]
        if ($change -gt 0) { $gains.Add($change); $losses.Add(0.0) } else { $gains.Add(0.0); $losses.Add([Math]::Abs($change)) }
    }
    if ($gains.Count -lt $period) { return @() }

    $avgGain = ($gains[0..($period-1)] | Measure-Object -Sum).Sum / $period
    $avgLoss = ($losses[0..($period-1)] | Measure-Object -Sum).Sum / $period

    $rsi = New-Object System.Collections.Generic.List[double]
    $rs = if ($avgLoss -ne 0) { $avgGain / $avgLoss } else { [double]::PositiveInfinity }
    $rsi.Add([Math]::Round(100 - (100 / (1 + $rs)), 2))

    for ($i = $period; $i -lt $gains.Count; $i++) {
        $avgGain = (($avgGain * ($period - 1)) + $gains[$i]) / $period
        $avgLoss = (($avgLoss * ($period - 1)) + $losses[$i]) / $period
        $rs = if ($avgLoss -ne 0) { $avgGain / $avgLoss } else { [double]::PositiveInfinity }
        $rsi.Add([Math]::Round(100 - (100 / (1 + $rs)), 2))
    }
    return $rsi
}

function Get-Trend($candles, $atrPeriod, $trend_candles, $trendsize=1.0) {
    if (-not $candles -or $candles.Count -lt $trend_candles) { return "NEUTRAL" }
    $atrArr = Calculate-ATR $candles $atrPeriod
    if (-not $atrArr -or $atrArr.Count -eq 0) { return "NEUTRAL" }
    $lastAtr = $atrArr[-1]
    $lastCloses = $candles | Sort-Object Timestamp | Select-Object -Last $trend_candles | ForEach-Object { $_.Close }
    if ($lastCloses.Count -lt 2) { return "NEUTRAL" }
    $delta = $lastCloses[-1] - $lastCloses[0]
    if ($delta -gt $lastAtr * $trendsize) { return "UP" } elseif ($delta -lt -$lastAtr * $trendsize) { return "DOWN" } else { return "NEUTRAL" }
}

function Get-StopLoss($candles, $sl_candles, $direction) {
    $recentCandles = $candles | Sort-Object Timestamp | Select-Object -Last $sl_candles
    switch ($direction.ToUpper()) {
        "LONG" { return [Math]::Round(($recentCandles | Measure-Object -Property Close -Minimum).Minimum, 8) }
        "SHORT"{ return [Math]::Round(($recentCandles | Measure-Object -Property Close -Maximum).Maximum, 8) }
        default{ throw "Unknown direction: $direction" }
    }
}

# --- Position management: ONLY ONE open position per instrument ---
function CanOpenNew($symbol, $side) {
    if (-not $global:positions.ContainsKey($symbol) -or $global:positions[$symbol].Count -eq 0) {
        return $true
    }
    # Если уже есть открытая позиция — запрещено открывать новую (включая встречные)
    return $false
}

# --- Risk checks ---
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

# --- Open / Close positions (accounting for commissions correctly) ---
function Open-Position(
    $symbol, 
    $entryPrice, 
    $size, 
    $atr, 
    $tpMultiplier, 
    $trendCandles, 
    $side, 
    $candles
) {
    if (-not (CanOpenNew $symbol $side)) { LogConsole "Уже есть открытая позиция для $symbol — пропуск" "DEBUG"; return }

    if ($atr -le 0 -or [double]::IsNaN($atr)) { $atr = [Math]::Max(0.01 * $entryPrice, 0.0001) }

    try { $sl = Get-StopLoss $candles $trendCandles $side } catch { LogConsole "Error SL $symbol $_" "ERROR"; return }

    $minDist = [Math]::Max($atr * 0.2, $entryPrice * 0.001)

    if ($side -eq "LONG" -and ($sl -ge $entryPrice -or [Math]::Abs($entryPrice - $sl) -lt $minDist)) { $sl = [Math]::Round($entryPrice - $minDist, 8) }
    if ($side -eq "SHORT" -and ($sl -le $entryPrice -or [Math]::Abs($entryPrice - $sl) -lt $minDist)) { $sl = [Math]::Round($entryPrice + $minDist, 8) }

    $tp = if ($side -eq "LONG") { [Math]::Round($entryPrice + [Math]::Max($atr * $tpMultiplier, $minDist), 8) } else { [Math]::Round($entryPrice - [Math]::Max($atr * $tpMultiplier, $minDist), 8) }

    $positionCost   = $entryPrice * $size
    $commissionOpen = [Math]::Round($positionCost * $commissionRate, 8)
    $totalCost      = $positionCost + $commissionOpen

    if ($global:balance -lt $totalCost) { LogConsole "Недостаточно баланса для открытия позиции $symbol нужно $totalCost, баланс $($global:balance)" "WARN"; return }

    $global:balance -= $totalCost

    $position = [PSCustomObject]@{
        Symbol        = $symbol
        EntryPrice    = [double]$entryPrice
        TP            = $tp
        SL            = $sl
        Size          = [double]$size
        Side          = $side
        Status        = "OPEN"
        OpenedAt      = Get-Timestamp
        CommissionOpen= $commissionOpen
    }

    if (-not $global:positions.ContainsKey($symbol) -or $global:positions[$symbol] -eq $null) { $global:positions[$symbol] = @() }
    $global:positions[$symbol] = @($global:positions[$symbol]) + $position

    LogConsole "🚀 Открыта $side позиция $symbol $entryPrice (TP:$tp SL:$sl Size:$size) списано:$totalCost (комиссия открытия:$commissionOpen)" $side
}

function Close-Position($symbol, $exitPrice, $reason, $side) {
    if (-not $global:positions.ContainsKey($symbol)) { return }
    $posList = $global:positions[$symbol]
    $pos = $posList | Where-Object { $_.Side -eq $side } | Select-Object -First 1
    if (-not $pos) { return }

    # Gross pnl
    $pnl = if ($pos.Side -eq "LONG") { ($exitPrice - $pos.EntryPrice) * $pos.Size } else { ($pos.EntryPrice - $exitPrice) * $pos.Size }
    $commissionClose = [Math]::Round($exitPrice * $pos.Size * $commissionRate, 8)

    # Net realized PnL after both commissions (open + close)
    $netRealized = [Math]::Round($pnl - $pos.CommissionOpen - $commissionClose, 8)

    $global:totalPnL += $netRealized

    # Возвращаем в баланс изначальную стоимость позиции + gross pnl - комиссия закрытия
    $global:balance += [Math]::Round(($pos.EntryPrice * $pos.Size) + ($pnl - $commissionClose), 8)

    if ($reason -eq "TP") { $global:winCount++ }
    $global:totalClosed++

    LogConsole "✅ Закрыта позиция $symbol ($($pos.Side)): по $exitPrice | GrossPnL:$([Math]::Round($pnl,8)) | ком.(open:$($pos.CommissionOpen) close:$commissionClose) | NetRealized:$netRealized | Причина:$reason | Баланс:$($global:balance)" "CLOSE"

    $remaining = $posList | Where-Object { $_.OpenedAt -ne $pos.OpenedAt }
    $global:positions[$symbol] = [System.Collections.ArrayList]@($remaining)
}

# --- Evaluate existing positions (use candles to determine TP/SL hits). Uses a single current price passed by caller. ---
function Evaluate-Position($symbol, $currentPrice) {
    if (-not $global:positions.ContainsKey($symbol)) { return }
    $posList = $global:positions[$symbol]
    foreach ($pos in $posList) {
        if ($pos.Status -ne "OPEN") { continue }

        $candles = Get-Candles $symbol $config.candle_limit $evaluate_candle_period
        if ($candles.Count -eq 0) { continue }

        LogConsole "[MONITOR][$($pos.Side)] $symbol Price:$currentPrice TP:$($pos.TP) SL:$($pos.SL)" "MONITOR"

        # Проверяем последнюю свечу(ы) после открытия
        $candlesAfterOpen = $candles | Where-Object { $_.Timestamp -ge $pos.OpenedAt }
        foreach ($candle in $candlesAfterOpen) {
            if ($pos.Side -eq "LONG") {
                if ($candle.High -ge $pos.TP) { Close-Position $symbol $pos.TP "TP" "LONG"; break }
                elseif ($candle.Low -le $pos.SL) { Close-Position $symbol $pos.SL "SL" "LONG"; break }
            } else {
                if ($candle.Low -le $pos.TP) { Close-Position $symbol $pos.TP "TP" "SHORT"; break }
                elseif ($candle.High -ge $pos.SL) { Close-Position $symbol $pos.SL "SL" "SHORT"; break }
            }
        }

        # As fallback, if candles didn't show TP/SL but market price breached them — close too
        if ($pos.Status -eq "OPEN") {
            if ($pos.Side -eq "LONG") {
                if ($currentPrice -ge $pos.TP) { Close-Position $symbol $pos.TP "TP" "LONG" }
                elseif ($currentPrice -le $pos.SL) { Close-Position $symbol $pos.SL "SL" "LONG" }
            } else {
                if ($currentPrice -le $pos.TP) { Close-Position $symbol $pos.TP "TP" "SHORT" }
                elseif ($currentPrice -ge $pos.SL) { Close-Position $symbol $pos.SL "SL" "SHORT" }
            }
        }
    }
}

# --- Main loop ---
function Run-Bot {
    $winRate = if ($global:totalClosed -gt 0) { [Math]::Round(($global:winCount / $global:totalClosed) * 100, 2) } else { 0 }
    $timestamp = Format-Time
    LogConsole "🔄 Новый цикл. Баланс:$([Math]::Round($global:balance,8)) | PnL:$([Math]::Round($global:totalPnL,8)) | Сделок:$global:totalClosed | WinRate:$winRate%" "INFO"
    Add-Content -Path $logFile -Value "${timestamp} Баланс:$([Math]::Round($global:balance,8)) PnL:$([Math]::Round($global:totalPnL,8)) Сделок:$global:totalClosed WinRate:$winRate%"

    foreach ($symbol in $config.instruments) {
        # Получаем текущую цену один раз
        $price = Get-Last-Tick $symbol
        if ($null -eq $price) { continue }

        # Сначала проверяем и закрываем открытые позиции по инструменту
        Evaluate-Position $symbol $price

        # Получаем свечи для принятия решения об открытии
        $candles = Get-Candles $symbol $config.candle_limit $config.candle_period
        if ($candles.Count -lt 50) { continue }

        $closes = $candles | ForEach-Object { $_.Close }
        $ema21 = Calculate-EMA $closes 21
        $rsi6Arr  = Get-RSI $closes 6
        $rsi14Arr = Get-RSI $closes 14
        $rsi30Arr = Get-RSI $closes 30
        if ($rsi6Arr.Count -lt 1 -or $rsi14Arr.Count -lt 1 -or $rsi30Arr.Count -lt 1) { continue }

        $rsi6Curr  = $rsi6Arr[-1]
        $rsi14Curr = $rsi14Arr[-1]
        $rsi30Curr = $rsi30Arr[-1]
        $atrArr = Calculate-ATR $candles $config.atrPeriod
        if ($atrArr.Count -eq 0) { continue }

        # Higher timeframe trend filter
        $higherCandles = Get-Candles $symbol $config.candle_limit $config.higher_tf
        if ($higherCandles.Count -lt ($config.trend_candles + 10)) { continue }
        $higher_closes   = $higherCandles | ForEach-Object { $_.Close }
        $higher_rsi6Arr  = Get-RSI $higher_closes 6
        $higher_rsi14Arr = Get-RSI $higher_closes 14
        $higher_rsi30Arr = Get-RSI $higher_closes 30
        if ($higher_rsi6Arr.Count -lt 1 -or $higher_rsi14Arr.Count -lt 1 -or $higher_rsi30Arr.Count -lt 1) { continue }

        $higher_rsi6Curr  = $higher_rsi6Arr[-1]
        $higher_rsi14Curr = $higher_rsi14Arr[-1]
        $higher_rsi30Curr = $higher_rsi30Arr[-1]

        $atr = $atrArr[-1]
        $size = [Math]::Round($config.position_size_usd / $price, 4)
        $trend_candles = $config.trend_candles
        $tpMultiplier  = $config.tp_ATR
        $trend         = Get-Trend $candles $config.atrPeriod $trend_candles
        $lastEMA21     = $ema21[-1]

        $longSignal  = ($price -gt $lastEMA21) -and ($rsi6Curr -ge $config.rsi6_max) -and ($rsi14Curr -ge $config.rsi14_max) -and ($rsi30Curr -ge $config.rsi30_max) -and ($higher_rsi6Curr -ge $config.rsi6_max) -and ($higher_rsi14Curr -ge $config.rsi14_max) -and ($higher_rsi30Curr -ge $config.rsi30_max) -and ($trend -eq "UP")
        $shortSignal = ($price -le $lastEMA21) -and ($rsi6Curr -le $config.rsi6_min) -and ($rsi14Curr -le $config.rsi14_min) -and ($rsi30Curr -le $config.rsi30_min) -and ($higher_rsi6Curr -le $config.rsi6_min) -and ($higher_rsi14Curr -le $config.rsi14_min) -and ($higher_rsi30Curr -le $config.rsi30_min) -and ($trend -eq "DOWN")

        # Проверка больших свечей
        $lsRef = [ref]$longSignal; $ssRef = [ref]$shortSignal
        Check-CandleSizeRisk -candles $candles -atr $atr -longSignal $lsRef -shortSignal $ssRef -lookback $config.candleRiskLookback -multiplier $config.candleRiskMultiplier
        $longSignal = $lsRef.Value; $shortSignal = $ssRef.Value

        # Открываем позицию только если для инструмента сейчас нет открытой позиции
        if ($longSignal -and (CanOpenNew $symbol "LONG")) {
            Open-Position $symbol $price $size $atr $tpMultiplier $trend_candles "LONG" $candles
        }
        elseif ($shortSignal -and (CanOpenNew $symbol "SHORT")) {
            Open-Position $symbol $price $size $atr $tpMultiplier $trend_candles "SHORT" $candles
        }

        Start-Sleep -Milliseconds 100
    }
}

# Start main loop
while ($true) {
    Run-Bot
    Start-Sleep -Seconds $config.rerun_interval_s
}
