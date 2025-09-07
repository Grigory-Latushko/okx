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
$commissionRate = 0.0009              # 0.09%
$evaluate_candle_period = $config.evaluate_candle_period

# === UTILS ===
function Get-Timestamp { return [int][double]::Parse((Get-Date -UFormat %s)) }
function Format-Time { return (Get-Date -Format "yyyy-MM-dd HH:mm:ss") }
function Format-Time-FromTS($ts) { return ([DateTimeOffset]::FromUnixTimeSeconds($ts)).LocalDateTime.ToString("yyyy-MM-dd HH:mm:ss") }

function LogConsole($msg, $type = "INFO") {
    $ts = Format-Time
    Write-Host "[$ts][$type] $msg"
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

function Calculate-ATR($candles, $period = 14) {
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

function Get-StopLoss($candles,$sl_candles,$direction) {
    $recentCandles = $candles | Sort-Object Timestamp | Select-Object -Last $sl_candles
    switch ($direction.ToUpper()) {
        "LONG" { return [Math]::Round(($recentCandles | Measure-Object -Property Close -Minimum).Minimum,8) }
        "SHORT"{ return [Math]::Round(($recentCandles | Measure-Object -Property Close -Maximum).Maximum,8) }
        default{ throw "Unknown direction: $direction" }
    }
}

# === POSITION LOGIC ===
function CanOpenNew($symbol, $side, [ref]$isCounter) {
    $isCounter.Value = $false
    if (-not $global:positions.ContainsKey($symbol) -or $global:positions[$symbol].Count -eq 0) { return $true }
    $sameSide = $global:positions[$symbol] | Where-Object { $_.Side -eq $side }
    if ($sameSide.Count -gt 0) { return $false }

    # Проверка на встречную позицию
    $oppositeSide = if ($side -eq "LONG") { "SHORT" } else { "LONG" }
    $oppositePos = $global:positions[$symbol] | Where-Object { $_.Side -eq $oppositeSide }
    if ($oppositePos.Count -gt 0) { $isCounter.Value = $true }

    return $true
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

function Open-Position($symbol, $entryPrice, $size, $atr, $tpMultiplier, $trendCandles, $side, $candles, [bool]$isCounter = $false) {
    if ($atr -le 0 -or [double]::IsNaN($atr)) { $atr = [Math]::Max(0.01*$entryPrice, 0.0001) }
    try { 
        $sl = Get-StopLoss $candles $trendCandles $side 
    } catch { 
        LogConsole "Error SL $symbol $_"; 
        return 
    }

    $minDist = [Math]::Max($atr*0.2, $entryPrice*0.001)
    if ($side -eq "LONG" -and ($sl -ge $entryPrice -or [Math]::Abs($entryPrice-$sl) -lt $minDist)) { 
        $sl = [Math]::Round($entryPrice-$minDist,8) 
    }
    if ($side -eq "SHORT" -and ($sl -le $entryPrice -or [Math]::Abs($entryPrice-$sl) -lt $minDist)) { 
        $sl = [Math]::Round($entryPrice+$minDist,8) 
    }

    # TP для встречной позиции умножаем на 3
    $effectiveTpMultiplier = if ($isCounter) { $tpMultiplier * $config.hedge_multiplier } else { $tpMultiplier }
    $tp = if ($side -eq "LONG") { 
        [Math]::Round($entryPrice + [Math]::Max($atr*$effectiveTpMultiplier, $minDist), 8) 
    } else { 
        [Math]::Round($entryPrice - [Math]::Max($atr*$effectiveTpMultiplier, $minDist), 8) 
    }

    $symbolDisplay = if ($isCounter) { "⚡ $symbol" } else { $symbol }

    # Считаем комиссию при открытии
    $positionCost = $entryPrice * $size
    $commissionOpen = $positionCost * $commissionRate
    $totalCost = $positionCost + $commissionOpen

    if ($global:balance -lt $totalCost) { 
        LogConsole "Недостаточно баланса $symbol"; 
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
    $global:positions[$symbol] = [System.Collections.ArrayList]@()
    }
    $global:positions[$symbol].Add($position) | Out-Null

    LogConsole "🚀 Открыта $side позиция $symbolDisplay $entryPrice (TP:$tp SL:$sl Size:$size) списано:$totalCost$" $side
}

function Close-Position($symbol, $exitPrice, $reason, $side) {
    if (-not $global:positions.ContainsKey($symbol)) { return }

    $posList = $global:positions[$symbol]
    $pos = $posList | Where-Object { $_.Side -eq $side } | Select-Object -First 1
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

    $remaining = $posList | Where-Object { $_.OpenedAt -ne $pos.OpenedAt }
    $global:positions[$symbol] = [System.Collections.ArrayList]@($remaining)

}

function Evaluate-Position($symbol) {
    if (-not $global:positions.ContainsKey($symbol)) { return }
    $posList = $global:positions[$symbol]

    foreach ($pos in $posList) {
        if ($pos.Status -ne "OPEN") { continue }

        # Получаем свечи с кэшированием
        $candles = Get-Candles $symbol $config.candle_limit $evaluate_candle_period
        if ($candles.Count -eq 0) { continue }

        # Получаем последнюю цену для мониторинга
        $currentPrice = Get-Last-Tick $symbol
        if ($null -eq $currentPrice) { continue }

        # Выводим мониторинг позиции
        LogConsole "[$($pos.Side)] ${symbol}: [Price: $currentPrice] → TP: $($pos.TP), SL: $($pos.SL)" "MONITOR"

        # Отбираем свечи после открытия позиции
        $candlesAfterOpen = $candles | Where-Object { $_.Timestamp -ge $pos.OpenedAt }
        foreach ($candle in $candlesAfterOpen) {
            if ($pos.Side -eq "LONG") {
                if ($candle.High -ge $pos.TP) { Close-Position $symbol $pos.TP "TP" "LONG"; break }
                elseif ($candle.Low -le $pos.SL) { Close-Position $symbol $pos.SL "SL" "LONG"; break }
            } elseif ($pos.Side -eq "SHORT") {
                if ($candle.Low -le $pos.TP) { Close-Position $symbol $pos.TP "TP" "SHORT"; break }
                elseif ($candle.High -ge $pos.SL) { Close-Position $symbol $pos.SL "SL" "SHORT"; break }
            }
        }
    }
}

# === MAIN BOT LOOP ===
function Run-Bot {
    $winRate   = if ($global:totalClosed -gt 0) { [Math]::Round(($global:winCount/$global:totalClosed)*100,2) } else { 0 }
    $timestamp = Format-Time
    
    LogConsole "🔄 Новый цикл. Баланс:$($global:balance)$ | PnL:$($global:totalPnL) 💵 | Сделок:$global:totalClosed | WinRate:$winRate%" "INFO"
    $logEntry = "🔄 ${timestamp} Баланс: $($global:balance)$ | PnL: $($global:totalPnL) 💵 | Сделок: $global:totalClosed | WinRate: $winRate%"

    Add-Content -Path $logFile -Value $logEntry

    foreach ($symbol in $config.instruments) {
        Evaluate-Position $symbol

        # --- Получаем свечи с кэшированием ---
        $candles = Get-Candles $symbol $config.candle_limit $config.candle_period
        if ($candles.Count -lt 50) { continue }

        # Write-Output "Debug 1"

        $closes   = $candles | ForEach-Object { $_.Close }
        $ema21    = Calculate-EMA $closes 21
        $rsi6Arr  = Get-RSI $closes 6
        $rsi14Arr = Get-RSI $closes 14
        $rsi30Arr = Get-RSI $closes 30
        if ($rsi6Arr.Count -lt 2 -or $rsi14Arr.Count -lt 2 -or $rsi30Arr.Count -lt 2) { continue }

        # Write-Output "Debug 2"

        $rsi6Curr  = $rsi6Arr[-1]
        $rsi14Curr = $rsi14Arr[-1]
        $rsi30Curr = $rsi30Arr[-1]
        $atrArr    = Calculate-ATR $candles 14
        if ($atrArr.Count -eq 0) { continue }

        $atr = $atrArr[-1]
        $price = Get-Last-Tick $symbol
        if ($null -eq $price) { continue }

        $size = [Math]::Round($config.position_size_usd/$price,4)
        $trend_candles = $config.trend_candles
        $tpMultiplier  = $config.tp_ATR
        $trend         = Get-Trend $candles $config.atrPeriod $trend_candles
        $lastEMA21     = $ema21[-1]

        $longSignal  = ($price -gt $lastEMA21) -and ($rsi6Curr -ge $config.max_RSI) -and ($rsi14Curr -ge $config.max_RSI) -and ($rsi30Curr -ge $config.max_RSI) -and ($trend -eq "UP")
        $shortSignal = ($price -lt $lastEMA21) -and ($rsi6Curr -le $config.min_RSI) -and ($rsi14Curr -le $config.min_RSI) -and ($rsi30Curr -le $config.min_RSI) -and ($trend -eq "DOWN")

        # Write-Output "symbol = $symbol price = $price lastEMA21 = $lastEMA21 rsi6Curr = $rsi6Curr rsi14Curr = $rsi14Curr rsi30Curr = $rsi30Curr trend = $trend"

        # Проверка больших свечей
        Check-CandleSizeRisk `
            -candles $candles `
            -atr $atr `
            -longSignal ([ref]$longSignal) `
            -shortSignal ([ref]$shortSignal) `
            -lookback $config.candleRiskLookback `
            -multiplier $config.candleRiskMultiplier

        # --- Открытие LONG ---
        $isCounter = $false
        if ($longSignal -and (CanOpenNew $symbol "LONG" ([ref]$isCounter))) {
            Open-Position $symbol $price $size $atr $tpMultiplier $trend_candles "LONG" $candles $isCounter
        }

        # --- Открытие SHORT ---
        $isCounter = $false
        if ($shortSignal -and (CanOpenNew $symbol "SHORT" ([ref]$isCounter))) {
            Open-Position $symbol $price $size $atr $tpMultiplier $trend_candles "SHORT" $candles $isCounter
        }

        Start-Sleep -Milliseconds 100
    }
}

# === MAIN LOOP ===
if (Test-Path $logFile) { Remove-Item $logFile -Force }
while ($true) { Run-Bot; Start-Sleep -Seconds $config.rerun_interval_s }
