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

        if (-not $res.data) {
            LogConsole "Пустые данные по свечам $symbol" "ERROR"
            return @()
        }

        $candles = $res.data | ForEach-Object {
            [PSCustomObject]@{
                Timestamp = [long]($_[0]) / 1000   # UNIX timestamp в секундах
                Open      = [double]$_[1]
                High      = [double]$_[2]
                Low       = [double]$_[3]
                Close     = [double]$_[4]
                Volume    = [double]$_[5]
            }
        }

        # Разворачиваем в правильный порядок (от старых к новым)
        return $candles | Sort-Object Timestamp
    } catch {
        LogConsole "Ошибка получения свечей для ${symbol}: $($_)" "ERROR"
        return @()
    }
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

function Check-2ATR-Reversal {
    param (
        [array]$candles,
        [double]$atr
    )

    if ($candles.Count -lt 3) { return $null }

    $last2 = $candles | Sort-Object Timestamp | Select-Object -Last 2

    $candle1 = $last2[0]  # предпоследняя
    $candle2 = $last2[1]  # последняя

    $body1 = [Math]::Abs($candle1.Close - $candle1.Open)
    $body2 = [Math]::Abs($candle2.Close - $candle2.Open)

    $isBullBig = ($candle1.Close -gt $candle1.Open) -and ($body1 -ge 1.5 * $atr)
    $isBearBig = ($candle1.Close -lt $candle1.Open) -and ($body1 -ge 1.5 * $atr)

    $isBullBig2 = ($candle2.Close -gt $candle2.Open) -and ($body2 -ge 0.8 * $body1)
    $isBearBig2 = ($candle2.Close -lt $candle2.Open) -and ($body2 -ge 0.8 * $body1)

    # Сценарий SHORT
    if ($isBullBig -and $isBearBig2) {
        return "SHORT"
    }

    # Сценарий LONG
    if ($isBearBig -and $isBullBig2) {
        return "LONG"
    }

    return $null
}


# === TRADE LOGIC ===
$commissionRate = 0.0009  # 0.09%

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

    $positionCost = $entryPrice * $size
    $commissionOpen = $positionCost * $commissionRate
    $totalCost = $positionCost + $commissionOpen

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

    $candle_limit = $config.candle_limit
    $candle_period = $config.candle_period

    # LogConsole "Debug 0"

    $winRate = if ($global:totalClosed -gt 0) {
        [Math]::Round(($global:winCount / $global:totalClosed) * 100, 2)
    } else {
        0
    }
    LogConsole "🔄 Новый цикл бота. Баланс: $($global:balance)$ | PnL: $($global:totalPnL) 💵 | Сделок: $global:totalClosed | WinRate: $winRate%" "INFO"

    foreach ($symbol in $config.instruments) {

        if (CanOpenNew $symbol) {

            # LogConsole "symbol $symbol; candle_limit $candle_limit candle_period $candle_period"

            $candles = Get-Candles $symbol $candle_limit $candle_period

            # LogConsole "candles count = $($candles.Count)" "DEBUG"
            # LogConsole "first candle = $(($candles[0] | ConvertTo-Json -Compress))" "DEBUG"
            # LogConsole "last candle  = $(($candles[-1] | ConvertTo-Json -Compress))" "DEBUG"

            if ($candles.Count -lt 50) { continue }

            # LogConsole "DEBUG 1"

            # $closes = $candles | ForEach-Object { $_.Close }

            $atrArr = Calculate-ATR $candles 14
            if ($atrArr.Count -eq 0) { continue }
            $atr = $atrArr[-1]

            # LogConsole  "DEBUG 2"

            $price = Get-Last-Tick $symbol
            if ($null -eq $price) { continue }

            # LogConsole "DEBUG 3"

            $size = [Math]::Round($config.position_size_usd / $price, 4)
            $tpMultiplier = $config.tp_percent
            $slMultiplier = $config.sl_percent

            $patternSignal = Check-2ATR-Reversal -candles $candles -atr $atr

            # LogConsole  "DEBUG 4"

            if ($null -ne $patternSignal -and (CanOpenNew $symbol)) {
                $size = [Math]::Round($config.position_size_usd / $price, 4)

                # Write-Output "DEBUG 5"

                if ($patternSignal -eq "SHORT") {
                    LogConsole "$symbol → 📉 Паттерн 2ATR reversal: открытие SHORT" "SIGNAL"
                    Open-Position $symbol $price $size $atr $tpMultiplier  $slMultiplier "SHORT"
                    
                    # LogConsole  "DEBUG 6"
                }
                elseif ($patternSignal -eq "LONG") {
                    LogConsole "$symbol → 📈 Паттерн 2ATR reversal: открытие LONG" "SIGNAL"
                    Open-Position $symbol $price $size $atr $tpMultiplier $slMultiplier "LONG"

                    # LogConsole  "DEBUG 7"
                }
                else {

                    LogConsole  "DEBUG 8"
                    LogConsole "symbol= $symbol; patternSignal= $patternSignal; isBullBig= $isBullBig; isBearBig= $isBearBig; isBullBig2= $isBullBig2; isBearBig2= $isBearBig2"
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
