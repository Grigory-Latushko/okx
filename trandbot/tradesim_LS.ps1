# === CONFIG ===
param(
    [string]$configPath = ".\config.json"
)

# Лог-файл
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

$global:instrumentTotal = @{}
$global:instrumentWins = @{}

# === UTILS ===
function Get-Timestamp { return [int][double]::Parse((Get-Date -UFormat %s)) }
function Format-Time { return (Get-Date -Format "yyyy-MM-dd HH:mm:ss") }
function Format-Time-FromTS($ts) { return ([DateTimeOffset]::FromUnixTimeSeconds($ts)).LocalDateTime.ToString("yyyy-MM-dd HH:mm:ss") }

function LogConsole($msg, $type="INFO") {
    $ts = Format-Time
    Write-Host "[$ts][$type] $msg"
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
    $ema = @($prices[0])
    for ($i = 1; $i -lt $prices.Count; $i++) {
        $ema += $prices[$i] * $k + $ema[$i-1] * (1 - $k)
    }
    return $ema
}

function Calculate-ATR($candles, $period=14) {
    $trs = @()
    for ($i = 1; $i -lt $candles.Count; $i++) {
        $high = $candles[$i].High
        $low = $candles[$i].Low
        $prevClose = $candles[$i-1].Close
        $tr = [Math]::Max($high - $low, [Math]::Max([Math]::Abs($high - $prevClose), [Math]::Abs($low - $prevClose)))
        $trs += $tr
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

function Calculate-RSI($prices, $period=14) {
    $gains = @()
    $losses = @()
    for ($i = 1; $i -lt $prices.Count; $i++) {
        $change = $prices[$i] - $prices[$i-1]
        if ($change -gt 0) { $gains += $change; $losses += 0 } else { $gains += 0; $losses += -$change }
    }
    $avgGain = ($gains[0..($period-1)] | Measure-Object -Sum).Sum / $period
    $avgLoss = ($losses[0..($period-1)] | Measure-Object -Sum).Sum / $period
    $rsi = @()
    $rs = if ($avgLoss -eq 0) { 0 } else { $avgGain / $avgLoss }
    $rsi += if ($avgLoss -eq 0) { 100 } else { 100 - (100 / (1 + $rs)) }
    for ($i = $period; $i -lt $gains.Count; $i++) {
        $avgGain = (($avgGain * ($period-1)) + $gains[$i]) / $period
        $avgLoss = (($avgLoss * ($period-1)) + $losses[$i]) / $period
        $rs = if ($avgLoss -eq 0) { 0 } else { $avgGain / $avgLoss }
        $rsi += if ($avgLoss -eq 0) { 100 } else { 100 - (100 / (1 + $rs)) }
    }
    return $rsi
}

# === TRADE LOGIC ===
function Open-Position($symbol, $entryPrice, $size, $atr, $tpMultiplier, $slMultiplier, $side="LONG") {
    if ($side -eq "LONG") {
        $tp = [Math]::Round($entryPrice + $atr * $tpMultiplier, 8)
        $sl = [Math]::Round($entryPrice - $atr * $slMultiplier, 8)
    } elseif ($side -eq "SHORT") {
        $tp = [Math]::Round($entryPrice - $atr * $tpMultiplier, 8)
        $sl = [Math]::Round($entryPrice + $atr * $slMultiplier, 8)
    } else { LogConsole "Unknown position side: $side" "ERROR"; return }

    $positionCost = $entryPrice * $size
    $commissionOpen = $positionCost * $commissionRate
    $totalCost = $positionCost + $commissionOpen
    if ($global:balance -lt $totalCost) { LogConsole "Недостаточно баланса для $symbol" "WARN"; return }

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
    LogConsole "Открыта $side позиция $symbol $entryPrice (TP: $tp, SL: $sl, Size: $size), списано $totalCost" $side
}

function Close-Position($symbol, $exitPrice, $reason) {
    $pos = $global:positions[$symbol]
    if ($pos.Side -eq "LONG") { $pnl = ($exitPrice - $pos.EntryPrice) * $pos.Size } 
    elseif ($pos.Side -eq "SHORT") { $pnl = ($pos.EntryPrice - $exitPrice) * $pos.Size } 
    else { LogConsole "Unknown side" "ERROR"; return }

    $commissionClose = $exitPrice * $pos.Size * $commissionRate
    $pnlRounded = [Math]::Round($pnl - $commissionClose, 8)
    $global:totalPnL += $pnlRounded
    $global:balance += ($pos.EntryPrice * $pos.Size) + $pnlRounded

    if (-not $global:instrumentTotal.ContainsKey($symbol)) { $global:instrumentTotal[$symbol]=0; $global:instrumentWins[$symbol]=0 }
    $global:instrumentTotal[$symbol]++
    if ($reason -eq "TP") { $global:winCount++; $global:instrumentWins[$symbol]++ }
    $global:totalClosed++

    $pos.ExitPrice=$exitPrice; $pos.PnL=$pnlRounded; $pos.ClosedAt=Get-Timestamp; $pos.Status=$reason
    $instrumentWinRate = [Math]::Round(($global:instrumentWins[$symbol]/$global:instrumentTotal[$symbol])*100,2)

    LogConsole "Закрыта позиция $symbol ($($pos.Side)): $exitPrice | PnL: $pnlRounded | Причина: $reason | Баланс: $($global:balance) | Сделок: $global:totalClosed | WinRate: $instrumentWinRate%" "CLOSE"
    $global:positions.Remove($symbol)
}

function Evaluate-Position($symbol) {
    if (-not $global:positions.ContainsKey($symbol)) { return }
    $pos = $global:positions[$symbol]
    if ($pos.Status -ne "OPEN") { return }

    $candles = Get-Candles $symbol 100 $config.candle_period
    if ($candles.Count -eq 0) { return }

    $candlesAfterOpen = $candles | Where-Object { $_.Timestamp -ge $pos.OpenedAt }
    foreach ($candle in $candlesAfterOpen) {
        if ($pos.Side -eq "LONG") {
            if ($candle.High -ge $pos.TP) { Close-Position $symbol $pos.TP "TP"; break }
            elseif ($candle.Low -le $pos.SL) { Close-Position $symbol $pos.SL "SL"; break }
        } elseif ($pos.Side -eq "SHORT") {
            if ($candle.Low -le $pos.TP) { Close-Position $symbol $pos.TP "TP"; break }
            elseif ($candle.High -ge $pos.SL) { Close-Position $symbol $pos.SL "SL"; break }
        }
    }

    if ($global:positions.ContainsKey($symbol)) {
        $price = Get-Last-Tick $symbol
        if ($null -ne $price) { LogConsole "$symbol [Price: $price] → TP: $($pos.TP), SL: $($pos.SL)" "MONITOR" }
    }
}

function CanOpenNew($symbol) {
    return (-not $global:positions.ContainsKey($symbol)) -and ($global:balance -ge $config.position_size_usd)
}

# === MAIN BOT LOOP ===
function Run-Bot {
    $winRate = if ($global:totalClosed -gt 0) { [Math]::Round(($global:winCount / $global:totalClosed)*100,2) } else {0}
    LogConsole "🔄 Новый цикл. Баланс: $($global:balance)$ | PnL: $($global:totalPnL) | Сделок: $global:totalClosed | WinRate: $winRate%" "INFO"

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
            $rsiArr = Calculate-RSI $closes 14
            if ($rsiArr.Count -eq 0) { continue }
            $rsi = $rsiArr[-1]

            $emaCrossUp = ($ema9[-1] -gt $ema21[-1]) -and ($ema9[-2] -le $ema21[-2])
            $ema21TrendUp = $ema21[-1] -gt $ema21[-6]
            $emaCrossDown = ($ema9[-1] -lt $ema21[-1]) -and ($ema9[-2] -ge $ema21[-2])
            $ema21TrendDown = $ema21[-1] -lt $ema21[-6]

            $price = Get-Last-Tick $symbol
            if ($null -eq $price) { continue }
            $size = [Math]::Round($config.position_size_usd / $price, 4)

            # LONG если EMA+RSI подтверждают
            if ($emaCrossUp -and $ema21TrendUp -and $rsi -lt 40) {
                Open-Position $symbol $price $size $atr $config.tp_percent $config.sl_percent "LONG"
            } elseif ($emaCrossDown -and $ema21TrendDown -and $rsi -gt 60) {
                Open-Position $symbol $price $size $atr $config.tp_percent $config.sl_percent "SHORT"
            }
        } else {
            Evaluate-Position $symbol
        }
        Start-Sleep -Milliseconds 200
    }
}

if (Test-Path $logFile) { Remove-Item $logFile -Force }
while ($true) { Run-Bot; Start-Sleep -Seconds $config.rerun_interval_s }
