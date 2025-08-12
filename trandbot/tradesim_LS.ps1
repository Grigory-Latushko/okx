# trading_bot_fixed.ps1
# Исправленная версия бота: exposure по reserved margin, sanity caps, min stop, diagnostics.
param(
    [string]$configPath = ".\config.json"
)

# --- LOG / CONFIG LOAD ---
$logFileName = [IO.Path]::GetFileNameWithoutExtension($configPath)
$logFile = ".\${logFileName}_trades.log"

if (-not (Test-Path $configPath)) {
    Write-Host "Config not found: $configPath" -ForegroundColor Red
    exit 1
}

$config = Get-Content $configPath | ConvertFrom-Json

# Set defaults for new config parameters if absent
if (-not $config.PSObject.Properties.Name.Contains("risk_per_trade")) { $config | Add-Member -MemberType NoteProperty -Name risk_per_trade -Value 0.01 }
if (-not $config.PSObject.Properties.Name.Contains("leverage")) { $config | Add-Member -MemberType NoteProperty -Name leverage -Value 5 }
if (-not $config.PSObject.Properties.Name.Contains("max_concurrent_positions")) { $config | Add-Member -MemberType NoteProperty -Name max_concurrent_positions -Value 5 }
if (-not $config.PSObject.Properties.Name.Contains("max_exposure_usd")) { $config | Add-Member -MemberType NoteProperty -Name max_exposure_usd -Value 200 }
if (-not $config.PSObject.Properties.Name.Contains("min_avg_volume")) { $config | Add-Member -MemberType NoteProperty -Name min_avg_volume -Value 0 }
if (-not $config.PSObject.Properties.Name.Contains("allowed_instruments")) { $config | Add-Member -MemberType NoteProperty -Name allowed_instruments -Value $null }
if (-not $config.PSObject.Properties.Name.Contains("max_notional_per_trade")) { $config | Add-Member -MemberType NoteProperty -Name max_notional_per_trade -Value ($config.position_size_usd * 20) }
if (-not $config.PSObject.Properties.Name.Contains("min_stop_pct")) { $config | Add-Member -MemberType NoteProperty -Name min_stop_pct -Value 0.002 } # 0.2% минимальный стоп

# === STATE ===
$global:positions = @{}                 # keyed by symbol
$global:balance = [double]$config.max_balance
$global:totalPnL = 0.0
$global:winCount = 0
$global:totalClosed = 0
$commissionRate = 0.0009  # 0.09%

# stats per instrument
$global:instrumentTotal = @{}
$global:instrumentWins = @{}

# remove old log
if (Test-Path $logFile) { Remove-Item $logFile -Force }

# === UTILS ===
function Get-Timestamp { return [int][double]::Parse((Get-Date -UFormat %s)) }
function Format-Time { return (Get-Date -Format "yyyy-MM-dd HH:mm:ss") }
function Format-Time-FromTS($ts) { return ([DateTimeOffset]::FromUnixTimeSeconds([long]$ts)).LocalDateTime.ToString("yyyy-MM-dd HH:mm:ss") }

function LogConsole($msg, $type = "INFO") {
    $ts = Format-Time
    $full = "[$ts][$type] $msg"
    Write-Host $full
    Add-Content -Path $logFile -Value $full
}

function LogTradeWithWinRate($pos, $reason, $winRate) {
    $openedAtStr = Format-Time-FromTS $pos.OpenedAt
    $closedAtStr = Format-Time-FromTS $pos.ClosedAt
    $timestamp = Format-Time

    $logEntry = "[${timestamp}][TRADE] Закрыта позиция $($pos.Symbol) $($pos.Side) PnL: $([Math]::Round($pos.PnL,8)) Причина: $reason Баланс: $([Math]::Round($global:balance,8)) WinRate инструмента: $winRate%`n" +
                "  Открытие:     $openedAtStr`n" +
                "  Закрытие:     $closedAtStr`n" +
                "  Цена входа:   $($pos.EntryPrice)`n" +
                "  Цена выхода:  $($pos.ExitPrice)`n" +
                "  Размер:       $($pos.Size)`n" +
                "  Нотионал:     $([Math]::Round($pos.Notional,8))`n" +
                "  Зарезерв-маржа:$([Math]::Round($pos.ReservedMargin,8))`n" +
                "  Комиссии O/C: $([Math]::Round($pos.CommissionOpen,8))/ $([Math]::Round($pos.CommissionClose,8))`n"

    Add-Content -Path $logFile -Value $logEntry
}

# === DATA FETCH ===
function Get-Last-Tick($symbol) {
    try {
        $url = "https://www.okx.com/api/v5/market/ticker?instId=$symbol"
        $res = Invoke-RestMethod -Uri $url -Method Get -ErrorAction Stop
        return [double]$res.data[0].last
    } catch {
        LogConsole "Ошибка получения тика для ${symbol}: $($_.Exception.Message)" "ERROR"
        return $null
    }
}

function Get-Candles($symbol, $limit, $period) {
    try {
        $url = "https://www.okx.com/api/v5/market/candles?instId=$symbol&bar=$period&limit=$limit"
        $res = Invoke-RestMethod -Uri $url -Method Get -ErrorAction Stop
        $arr = $res.data | ForEach-Object {
            [PSCustomObject]@{
                Timestamp = [long]($_[0] / 1000)
                Open = [double]$_[1]
                High = [double]$_[2]
                Low  = [double]$_[3]
                Close = [double]$_[4]
                Volume = [double]$_[5]
            }
        }
        # chronological order: old -> new
        return $arr | Sort-Object Timestamp
    } catch {
        LogConsole "Ошибка получения свечей для ${symbol}: $($_.Exception.Message)" "ERROR"
        return @()
    }
}

# === INDICATORS ===
function Calculate-EMA($prices, $period) {
    if ($prices.Count -lt $period) { return @() }
    $k = 2 / ($period + 1)
    $ema = New-Object System.Collections.Generic.List[double]

    $seed = ($prices[0..($period-1)] | Measure-Object -Sum).Sum / $period

    for ($i=0; $i -lt $prices.Count; $i++) {
        if ($i -lt $period) {
            $ema.Add([double]$seed)
        } else {
            $prev = $ema[$i-1]
            $value = $prices[$i] * $k + $prev * (1 - $k)
            $ema.Add([double]$value)
        }
    }
    return $ema.ToArray()
}

function Calculate-ATR($candles, $period = 14) {
    $n = $candles.Count
    if ($n -le $period) { return @() }

    $trs = New-Object System.Collections.Generic.List[double]
    for ($i = 1; $i -lt $n; $i++) {
        $high = $candles[$i].High
        $low = $candles[$i].Low
        $prevClose = $candles[$i - 1].Close
        $tr = [Math]::Max($high - $low, [Math]::Max([Math]::Abs($high - $prevClose), [Math]::Abs($low - $prevClose)))
        $trs.Add([double]$tr)
    }

    $atr = New-Object System.Collections.Generic.List[double]
    for ($i=0; $i -lt $n; $i++) { $atr.Add(0.0) }

    $initialSMA = ($trs[0..($period-1)] | Measure-Object -Sum).Sum / $period
    $atr[$period] = [double]$initialSMA

    $k = 2 / ($period + 1)
    for ($i = $period + 1; $i -lt $n; $i++) {
        $value = $trs[$i - 1] * $k + $atr[$i - 1] * (1 - $k)
        $atr[$i] = [double]$value
    }

    return $atr.ToArray()
}

# === TRADE LOGIC / POSITION MANAGEMENT ===
function Open-Position($symbol, $entryPrice, $size, $tp, $sl, $reservedMargin, $commissionOpen, $side = "LONG") {
    $position = [PSCustomObject]@{
        Symbol = $symbol
        EntryPrice = [double]$entryPrice
        TP = [double]$tp
        SL = [double]$sl
        Size = [double]$size
        Side = $side
        Status = "OPEN"
        OpenedAt = Get-Timestamp

        ExitPrice = $null
        PnL = $null
        ClosedAt = $null

        Notional = [double]($entryPrice * $size)
        ReservedMargin = [double]$reservedMargin
        CommissionOpen = [double]$commissionOpen
        CommissionClose = 0.0
    }

    $global:balance = [double]([Math]::Round($global:balance - $reservedMargin, 8))
    $global:positions[$symbol] = $position

    LogConsole "Открыта $side позиция ${symbol}: Entry $entryPrice | Size $size | TP $tp | SL $sl | ReservedMargin $([Math]::Round($reservedMargin,8))" "OPEN"
}

function Close-Position($symbol, $exitPrice, $reason) {
    if (-not $global:positions.ContainsKey($symbol)) { return }
    $pos = $global:positions[$symbol]

    if ($pos.Side -eq "LONG") {
        $rawPnl = ($exitPrice - $pos.EntryPrice) * $pos.Size
    } else {
        $rawPnl = ($pos.EntryPrice - $exitPrice) * $pos.Size
    }

    $commissionClose = $exitPrice * $pos.Size * $commissionRate
    $totalCommission = $pos.CommissionOpen + $commissionClose

    $pnlNet = $rawPnl - $totalCommission

    $global:totalPnL += $pnlNet
    $global:balance = [double]([Math]::Round($global:balance + $pos.ReservedMargin + $pnlNet, 8))
    $pos.CommissionClose = [double]$commissionClose

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

    $pos.ExitPrice = [double]$exitPrice
    $pos.PnL = [double]([Math]::Round($pnlNet,8))
    $pos.ClosedAt = Get-Timestamp
    $pos.Status = $reason

    $instrumentWinRate = 0
    if ($global:instrumentTotal[$symbol] -gt 0) {
        $instrumentWinRate = [Math]::Round(($global:instrumentWins[$symbol] / $global:instrumentTotal[$symbol]) * 100, 2)
    }

    LogConsole "Закрыта позиция ${symbol} ($($pos.Side)): Exit $exitPrice | PnL: $([Math]::Round($pnlNet,8)) | Причина: $reason | Баланс: $([Math]::Round($global:balance,8)) | Сделок: $global:totalClosed | WinRate инструмента: $instrumentWinRate%" "CLOSE"
    LogTradeWithWinRate $pos $reason $instrumentWinRate

    $global:positions.Remove($symbol)
}

function Get-CurrentExposure([string]$mode = "margin") {
    $sum = 0.0
    foreach ($p in $global:positions.Values) {
        if ($mode -eq "notional") { $sum += [double]$p.Notional }
        else { $sum += [double]$p.ReservedMargin }
    }
    return $sum
}

function Evaluate-Position($symbol) {
    if (-not $global:positions.ContainsKey($symbol)) { return }

    $pos = $global:positions[$symbol]
    if ($pos.Status -ne "OPEN") { return }

    $candles = Get-Candles $symbol 200 $config.candle_period
    if ($candles.Count -eq 0) { return }

    $openedAtTimestamp = $pos.OpenedAt
    $candlesAfterOpen = $candles | Where-Object { $_.Timestamp -ge $openedAtTimestamp }

    foreach ($candle in $candlesAfterOpen) {
        if ($pos.Side -eq "LONG") {
            if ($candle.High -ge $pos.TP) {
                Close-Position $symbol $pos.TP "TP"; break
            } elseif ($candle.Low -le $pos.SL) {
                Close-Position $symbol $pos.SL "SL"; break
            }
        } else {
            if ($candle.Low -le $pos.TP) {
                Close-Position $symbol $pos.TP "TP"; break
            } elseif ($candle.High -ge $pos.SL) {
                Close-Position $symbol $pos.SL "SL"; break
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
    if ($global:positions.ContainsKey($symbol)) { return $false }
    if ($global:positions.Keys.Count -ge $config.max_concurrent_positions) { return $false }
    if ($global:balance -lt 1) { return $false }
    return $true
}

function Run-Bot {
    $winRate = if ($global:totalClosed -gt 0) { [Math]::Round(($global:winCount / $global:totalClosed) * 100, 2) } else { 0 }

    LogConsole "🔄 Новый цикл. Баланс: $([Math]::Round($global:balance,8)) | TotalPnL: $([Math]::Round($global:totalPnL,8)) | WinRate: $winRate%" "INFO"

    $symbols = @()
    if ($config.allowed_instruments -ne $null -and $config.allowed_instruments.Count -gt 0) {
        $symbols = $config.allowed_instruments
    } else {
        $symbols = $config.instruments
    }

    foreach ($symbol in $symbols) {
        try {
            if (-not (CanOpenNew $symbol)) {
                Evaluate-Position $symbol
                Start-Sleep -Milliseconds 150
                continue
            }

            $candles = Get-Candles $symbol $config.candle_limit $config.candle_period
            if ($candles.Count -lt 60) { Start-Sleep -Milliseconds 100; continue }

            if ($config.min_avg_volume -gt 0) {
                $avgVol = ($candles | Select-Object -First 50 | Measure-Object -Property Volume -Average).Average
                if ($avgVol -lt $config.min_avg_volume) {
                    LogConsole "Пропускаем $symbol — низкий avg volume: $([Math]::Round($avgVol,4))" "DEBUG"
                    Start-Sleep -Milliseconds 100
                    continue
                }
            }

            $closes = $candles | ForEach-Object { $_.Close }
            $closesArr = @($closes)

            $ema9 = Calculate-EMA $closesArr 9
            $ema21 = Calculate-EMA $closesArr 21
            $atrArr = Calculate-ATR $candles 14
            if ($ema9.Count -eq 0 -or $ema21.Count -eq 0 -or $atrArr.Count -eq 0) { Start-Sleep -Milliseconds 50; continue }

            $last = $closesArr.Count - 1
            if ($last -lt 2) { continue }

            $ema9_last = $ema9[$last]
            $ema9_prev = $ema9[$last - 1]
            $ema21_last = $ema21[$last]
            $ema21_prev = $ema21[$last - 1]

            $emaCrossUp = ($ema9_last -gt $ema21_last) -and ($ema9_prev -le $ema21_prev)
            $emaCrossDown = ($ema9_last -lt $ema21_last) -and ($ema9_prev -ge $ema21_prev)

            $lookback = [Math]::Min(6, $last)
            $ema21_trend = $ema21_last - $ema21[$last - $lookback]

            $ema21TrendUp = $ema21_trend -gt 0
            $ema21TrendDown = $ema21_trend -lt 0

            $atr = $atrArr[$last]
            if ($atr -le 0) { Start-Sleep -Milliseconds 20; continue }

            $price = Get-Last-Tick $symbol
            if ($null -eq $price) { Start-Sleep -Milliseconds 20; continue }

            $riskPercent = $config.risk_per_trade
            $leverage = $config.leverage
            $riskAmount = [double]($global:balance * $riskPercent)

            $minStop = $price * $config.min_stop_pct
            $stopDistance = if ($atr -gt $minStop) { $atr } else { $minStop }
            if ($stopDistance -le 0) { Start-Sleep -Milliseconds 10; continue }

            $size = [double]([Math]::Round(($riskAmount / $stopDistance), 6))
            if ($size -le 0) { Start-Sleep -Milliseconds 10; continue }

            $notional = [double]($price * $size)
            $maxNotional = [double]$config.max_notional_per_trade
            if ($notional -gt $maxNotional) {
                $size = [double]([Math]::Round($maxNotional / $price, 6))
                $notional = [double]($price * $size)
                if ($size -le 0) { Start-Sleep -Milliseconds 10; continue }
            }

            $requiredMargin = [double]([Math]::Round($notional / $leverage, 8))
            $commissionOpen = $notional * $commissionRate

            # Расчёт TP и SL
            $tpMul = 2
            $slMul = 1

            if ($emaCrossUp -and $ema21TrendUp) {
                $tp = [Math]::Round($price + $atr * $tpMul, 8)
                $sl = [Math]::Round($price - $atr * $slMul, 8)
            } elseif ($emaCrossDown -and $ema21TrendDown) {
                $tp = [Math]::Round($price - $atr * $tpMul, 8)
                $sl = [Math]::Round($price + $atr * $slMul, 8)
            } else {
                Evaluate-Position $symbol
                Start-Sleep -Milliseconds 150
                continue
            }

            $stopPct = [Math]::Round(([Math]::Abs($price - $sl) / $price) * 100, 4)
            $tpPct = [Math]::Round(([Math]::Abs($tp - $price) / $price) * 100, 4)

            LogConsole "$symbol Price=$price, Size=$size, StopDist=$stopDistance (мин $minStop), StopPct=$stopPct%, TP_Pct=$tpPct%" "DEBUG"

            if ($global:balance -lt $requiredMargin + $commissionOpen) {
                LogConsole "Недостаточно баланса для открытия позиции $symbol нужно $([Math]::Round($requiredMargin + $commissionOpen,8)), есть $([Math]::Round($global:balance,8))" "WARN"
                Start-Sleep -Milliseconds 100
                continue
            }

            if ($emaCrossUp -and $ema21TrendUp) {
                Open-Position $symbol $price $size $tp $sl $requiredMargin $commissionOpen "LONG"
            } elseif ($emaCrossDown -and $ema21TrendDown) {
                Open-Position $symbol $price $size $tp $sl $requiredMargin $commissionOpen "SHORT"
            }

            Start-Sleep -Milliseconds 300
        } catch {
            LogConsole "Ошибка в цикле по $symbol $($_.Exception.Message)" "ERROR"
        }
    }
}

# === MAIN LOOP ===
while ($true) {
    Run-Bot
    Start-Sleep -Seconds $config.loop_delay_seconds
}
