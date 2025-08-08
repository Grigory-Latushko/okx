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

# === TRADE LOGIC ===
function Open-Position($symbol, $entryPrice, $size, $atr, $tpMultiplier, $slMultiplier) {
    $tp = [Math]::Round($entryPrice + $atr * $tpMultiplier, 8)
    $sl = [Math]::Round($entryPrice - $atr * $slMultiplier, 8)

    $positionCost = $entryPrice * $size
    if ($global:balance -lt $positionCost) {
        LogConsole "Недостаточно баланса для открытия позиции $symbol требуется $positionCost$, доступно $($global:balance)$" "WARN"
        return
    }
    $global:balance -= $positionCost

    $position = [PSCustomObject]@{
        Symbol = $symbol
        EntryPrice = $entryPrice
        TP = $tp
        SL = $sl
        Size = $size
        Status = "OPEN"
        OpenedAt = Get-Timestamp

        ExitPrice = $null
        PnL = $null
        ClosedAt = $null
    }

    $global:positions[$symbol] = $position
    LogConsole "Открыта LONG позиция ${symbol}: по $entryPrice (TP: $tp, SL: $sl, Size: $size), списано с баланса: $positionCost$" "LONG"
}

function Close-Position($symbol, $exitPrice, $reason) {
    $pos = $global:positions[$symbol]
    $pnl = ($exitPrice - $pos.EntryPrice) * $pos.Size
    $pnlRounded = [Math]::Round($pnl, 8)

    $global:totalPnL += $pnlRounded
    $global:balance += ($pos.EntryPrice * $pos.Size) + $pnlRounded

    $pos.ExitPrice = $exitPrice
    $pos.PnL = $pnlRounded
    $pos.ClosedAt = Get-Timestamp
    $pos.Status = $reason

    if ($reason -eq "TP") {
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
        if ($candle.High -ge $pos.TP) {
            Close-Position $symbol $pos.TP "TP"
            break
        } elseif ($candle.Low -le $pos.SL) {
            Close-Position $symbol $pos.SL "SL"
            break
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

    LogConsole "🔄 Новый цикл бота. Баланс: $($global:balance)$ | PnL: $($global:totalPnL) 💵 | WinRate: $winRate%" "INFO" 

    foreach ($symbol in $config.instruments) {
        if (CanOpenNew $symbol) {
            # Получаем свечи основного таймфрейма
            $candles = Get-Candles $symbol $config.candle_limit $config.candle_period
            if ($candles.Count -lt 50) { continue }

            $closes = $candles | ForEach-Object { $_.Close }

            # Индикаторы EMA на основном таймфрейме
            $ema9 = Calculate-EMA $closes 9
            $ema21 = Calculate-EMA $closes 21

            # Расчёт ATR для адаптивного TP/SL
            $atrArr = Calculate-ATR $candles 14
            if ($atrArr.Count -eq 0) { continue }
            $atr = $atrArr[-1]

            # Условия для входа LONG на основе тренда:
            # EMA9 пересекла EMA21 вверх, и EMA21 тренд вверх (сравним с 5 свечами назад)
            $emaCrossUp = ($ema9[-1] -gt $ema21[-1]) -and ($ema9[-2] -le $ema21[-2])
            $ema21TrendUp = $ema21[-1] -gt $ema21[-6]

            if ($emaCrossUp -and $ema21TrendUp) {
                $price = Get-Last-Tick $symbol
                if ($null -eq $price) { continue }

                $size = [Math]::Round($config.position_size_usd / $price, 4)

                # Множители для TP/SL (можно менять в config или прямо здесь)
                $tpMultiplier = 2
                $slMultiplier = 1

                Open-Position $symbol $price $size $atr $tpMultiplier $slMultiplier
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
