# === CONFIG ===
param(
    [string]$configPath = ".\config.json"
)

# Имя лог-файла формируется на основе имени файла конфига
$logFileName = [IO.Path]::GetFileNameWithoutExtension($configPath)
$logFile = ".\${logFileName}_trades.log"

$config = Get-Content $configPath | ConvertFrom-Json

# === DEFAULTS FOR NEW STRATEGY PARAMETERS (если не заданы в config.json) ===
if (-not $config.PSObject.Properties.Name -contains 'impulse_lookback') { $config | Add-Member -NotePropertyName impulse_lookback -NotePropertyValue 10 }
if (-not $config.PSObject.Properties.Name -contains 'impulse_pct') { $config | Add-Member -NotePropertyName impulse_pct -NotePropertyValue 2.0 }         # %
if (-not $config.PSObject.Properties.Name -contains 'vol_multiplier') { $config | Add-Member -NotePropertyName vol_multiplier -NotePropertyValue 1.5 }
if (-not $config.PSObject.Properties.Name -contains 'pullback_min_pct') { $config | Add-Member -NotePropertyName pullback_min_pct -NotePropertyValue 30 }  # %
if (-not $config.PSObject.Properties.Name -contains 'pullback_max_pct') { $config | Add-Member -NotePropertyName pullback_max_pct -NotePropertyValue 70 }  # %
if (-not $config.PSObject.Properties.Name -contains 'breakout_vol_multiplier') { $config | Add-Member -NotePropertyName breakout_vol_multiplier -NotePropertyValue 1.5 }
if (-not $config.PSObject.Properties.Name -contains 'breakout_buf') { $config | Add-Member -NotePropertyName breakout_buf -NotePropertyValue 0.001 }        # 0.1%

# === STATE ===
$global:positions = @{}
$global:balance = $config.max_balance
$global:totalPnL = 0
$global:winCount = 0
$global:totalClosed = 0

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
    if ($prices.Count -lt 1) { return @() }
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
    if ($prices.Count -le $period) { return @() }

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

function Calculate-ATR($candles, $period = 14) {
    if ($candles.Count -le $period) { return @() }

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

    # Рассчитаем ATR как SMA первых period TR и затем EMA по стандартной формуле
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

# === TRADE LOGIC (unchanged interfaces) ===
function Open-Position($symbol, $entryPrice, $size, $tp, $sl) {
    $positionCost = $entryPrice * $size
    if ($global:balance -lt $positionCost) {
        LogConsole "Недостаточно баланса для открытия позиции $symbol требуется $positionCost$, доступно $($global:balance)$" "WARN"
        return $false
    }
    $global:balance -= $positionCost

    $position = [PSCustomObject]@{
        Symbol = $symbol
        EntryPrice = $entryPrice
        TP = [Math]::Round($tp, 8)
        SL = [Math]::Round($sl, 8)
        Size = $size
        Status = "OPEN"
        OpenedAt = Get-Timestamp

        ExitPrice = $null
        PnL = $null
        ClosedAt = $null
        Side = $null
    }

    $global:positions[$symbol] = $position
    LogConsole "Открыта позиция ${symbol}: по $entryPrice (TP: $($position.TP), SL: $($position.SL), Size: $size), списано с баланса: $positionCost$" "LONG/SHORT"
    return $true
}

function Close-Position($symbol, $exitPrice, $reason) {
    if (-not $global:positions.ContainsKey($symbol)) { return }
    $pos = $global:positions[$symbol]

    # Для шорта PnL считается иначе — здесь мы предполагаем только обычные "лонг"-логика по фиату.
    # Если торгуешь perpetuals с займами, надо учитывать направление. Для простоты:
    $pnl = 0
    if ($pos.Side -eq "SHORT") {
        # При шорте прибыль когда цена упала
        $pnl = ($pos.EntryPrice - $exitPrice) * $pos.Size
    } else {
        $pnl = ($exitPrice - $pos.EntryPrice) * $pos.Size
    }
    $pnlRounded = [Math]::Round($pnl, 8)

    $global:totalPnL += $pnlRounded
    $global:balance += ($pos.EntryPrice * $pos.Size) + $pnlRounded

    $pos.ExitPrice = $exitPrice
    $pos.PnL = $pnlRounded
    $pos.ClosedAt = Get-Timestamp
    $pos.Status = $reason

    if ($pnlRounded -gt 0) {
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

    $candles = Get-Candles $symbol $config.candle_limit $config.candle_period
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
        } else {
            # SHORT
            if ($candle.Low -le $pos.TP) {            # TP for short is lower price
                Close-Position $symbol $pos.TP "TP"
                break
            } elseif ($candle.High -ge $pos.SL) {     # SL for short is higher price
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

# === Helper: detect impulse / pullback / breakout ===
function Detect-Impulse-Pullback-Breakout($closes, $volumes) {
    # Возвращает объект с полями:
    #  Found: $true/$false, Side: "LONG"/"SHORT", Peak: value, StartPrice: value, RetracePct: value
    $len = $closes.Count
    $lookback = [int]$config.impulse_lookback
    if ($len -le $lookback) { return $null }

    $startIdx = $len - 1 - $lookback
    $startPrice = $closes[$startIdx]
    $endPrice = $closes[-1]
    $deltaPct = (($endPrice - $startPrice) / $startPrice) * 100.0

    $avgVolume = ($volumes | Measure-Object -Average).Average
    $lastVol = $volumes[-1]

    # check impulse
    if (([math]::Abs($deltaPct) -ge [double]$config.impulse_pct) -and ($lastVol -ge ($avgVolume * [double]$config.vol_multiplier))) {
        if ($deltaPct -gt 0) {
            $side = "LONG"
            $peak = ($closes[$startIdx..($len-1)] | Measure-Object -Maximum).Maximum
            # retrace percent = (peak - current) / (peak - startPrice) * 100
            $den = ($peak - $startPrice)
            if ($den -eq 0) { $retrace = 0 } else { $retrace = (($peak - $endPrice) / $den) * 100.0 }
        } else {
            $side = "SHORT"
            $peak = ($closes[$startIdx..($len-1)] | Measure-Object -Minimum).Minimum
            $den = ($startPrice - $peak)
            if ($den -eq 0) { $retrace = 0 } else { $retrace = (($endPrice - $peak) / $den) * 100.0 }
        }

        # check pullback between min and max
        $minPull = [double]$config.pullback_min_pct
        $maxPull = [double]$config.pullback_max_pct
        if (($retrace -ge $minPull) -and ($retrace -le $maxPull)) {
            # check breakout: last close beyond peak (with small buffer)
            $buf = [double]$config.breakout_buf
            if ($side -eq "LONG") {
                $broke = $endPrice -gt ($peak * (1 + $buf))
            } else {
                $broke = $endPrice -lt ($peak * (1 - $buf))
            }

            # breakout volume check (last volume vs avg)
            $breakoutVolOk = $lastVol -ge ($avgVolume * [double]$config.breakout_vol_multiplier)

            return [PSCustomObject]@{
                Found = $true
                Side = $side
                Peak = $peak
                StartPrice = $startPrice
                RetracePct = $retrace
                Breakout = $broke
                AvgVolume = $avgVolume
                LastVolume = $lastVol
                BreakoutVolOk = $breakoutVolOk
            }
        }
    }

    return [PSCustomObject]@{ Found = $false }
}

# === RUN BOT ===
function Run-Bot {
    $winRate = if ($global:totalClosed -gt 0) {
        [Math]::Round(($global:winCount / $global:totalClosed) * 100, 2)
    } else {
        0
    }

    LogConsole "🔄 Новый цикл бота. Баланс: $($global:balance)$ | PnL: $($global:totalPnL) 💵 | WinRate: $winRate%" "INFO"

    foreach ($symbol in $config.instruments) {
        if (CanOpenNew $symbol) {
            $candles = Get-Candles $symbol $config.candle_limit $config.candle_period
            if ($candles.Count -lt 50) { continue }

            $closes = $candles | ForEach-Object { $_.Close }
            $volumes = $candles | ForEach-Object { $_.Volume }

            # ATR for TP/SL
            $atrArr = Calculate-ATR $candles 14
            if ($atrArr.Count -eq 0) { continue }
            $atr = $atrArr[-1]

            # EMA trend filter: EMA50 and EMA200
            $ema50 = Calculate-EMA $closes 50
            $ema200 = Calculate-EMA $closes 200
            if ($ema50.Count -lt 1 -or $ema200.Count -lt 1) {
                # not enough data for trend filter: skip symbol
                continue
            }
            $ema50_last = $ema50[-1]
            $ema200_last = $ema200[-1]

            # RSI filter (optional): use last RSI if available
            $rsiArr = Calculate-RSI $closes 14
            $rsi_last = if ($rsiArr.Count -gt 0) { $rsiArr[-1] } else { $null }

            # Detect pattern
            $det = Detect-Impulse-Pullback-Breakout $closes $volumes
            if (-not $det.Found) { continue }

            # Side filters: allow LONG only if EMA50 > EMA200, SHORT only if EMA50 < EMA200
            if ($det.Side -eq "LONG") {
                if ($ema50_last -le $ema200_last) { continue }
                if ($rsi_last -ne $null -and $rsi_last -ge 75) { continue } # avoid extreme overbought
            } else {
                if ($ema50_last -ge $ema200_last) { continue }
                if ($rsi_last -ne $null -and $rsi_last -le 25) { continue } # avoid extreme oversold
            }

            # We require breakout condition AND breakout volume ok OR if breakout not yet, wait for breakout (here we only act if breakout already happened)
            if (-not $det.Breakout) { continue }
            if (-not $det.BreakoutVolOk) { continue }

            # Prepare order parameters
            $price = Get-Last-Tick $symbol
            if ($null -eq $price) { continue }

            $size = [Math]::Round($config.position_size_usd / $price, 4)
            if ($size -le 0) { continue }

            # TP/SL based on ATR, for LONG: TP = entry + ATR*tpMult, SL = entry - ATR*slMult
            $tpMult = if ($config.PSObject.Properties.Name -contains 'tp_multiplier') { [double]$config.tp_multiplier } else { 2.0 }
            $slMult = if ($config.PSObject.Properties.Name -contains 'sl_multiplier') { [double]$config.sl_multiplier } else { 1.0 }

            if ($det.Side -eq "LONG") {
                $tp = $price + $atr * $tpMult
                $sl = $price - $atr * $slMult
            } else {
                # SHORT — tp lower than entry, sl higher
                $tp = $price - $atr * $tpMult
                $sl = $price + $atr * $slMult
            }

            # Open and mark side
            $opened = Open-Position $symbol $price $size $tp $sl
            if ($opened) {
                $global:positions[$symbol].Side = $det.Side
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
