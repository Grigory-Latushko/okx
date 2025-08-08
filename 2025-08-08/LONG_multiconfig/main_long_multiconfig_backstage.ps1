param(
    [string]$configPath = ".\config.json"
)

# === Чтение конфигурации ===
$config = Get-Content $configPath | ConvertFrom-Json

# Путь к CSV для записи результатов
$outputFile = ".\backtest_results_short.csv"
if (Test-Path $outputFile) { Remove-Item $outputFile -Force }
Add-Content -Path $outputFile -Value "Instrument,EMAfast,EMAslow,RSIperiod,RSImax,MACDfast,MACDslow,ATRperiod,TPmult,SLmult,PnL,WinRate,Trades"

# === Функции ===
function Get-Candles-From-OKX($symbol, $limit, $period) {
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
        } | Sort-Object Timestamp
    } catch {
        Write-Host "Ошибка загрузки свечей для $symbol $_"
        return @()
    }
}

function Calculate-EMA($prices, $period) {
    if ($prices.Count -lt $period) { return @() }
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
    if ($prices.Count -lt $period) { return @() }
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
    $rsi = @(100 - (100 / (1 + $rs)))
    for ($i = $period; $i -lt $gains.Count; $i++) {
        $avgGain = (($avgGain * ($period - 1)) + $gains[$i]) / $period
        $avgLoss = (($avgLoss * ($period - 1)) + $losses[$i]) / $period
        $rs = if ($avgLoss -eq 0) { 100 } else { $avgGain / $avgLoss }
        $rsi += 100 - (100 / (1 + $rs))
    }
    return $rsi
}

function Calculate-MACD($prices, $fastPeriod, $slowPeriod, $signalPeriod) {
    $emaFast = Calculate-EMA $prices $fastPeriod
    $emaSlow = Calculate-EMA $prices $slowPeriod
    if ($emaFast.Count -eq 0 -or $emaSlow.Count -eq 0) { return @(@(), @()) }
    $macdLine = @()
    for ($i = 0; $i -lt $prices.Count; $i++) {
        $f = if ($i -lt $emaFast.Count) { $emaFast[$i] } else { 0 }
        $s = if ($i -lt $emaSlow.Count) { $emaSlow[$i] } else { 0 }
        $macdLine += $f - $s
    }
    $signalLine = Calculate-EMA $macdLine $signalPeriod
    return ,@($macdLine, $signalLine)
}

function Calculate-ATR($candles, $period) {
    if ($candles.Count -lt $period + 1) { return @() }
    $trs = @()
    for ($i = 1; $i -lt $candles.Count; $i++) {
        $high = $candles[$i].High
        $low = $candles[$i].Low
        $prevClose = $candles[$i - 1].Close
        $tr = [Math]::Max(
            $high - $low,
            [Math]::Max([Math]::Abs($high - $prevClose), [Math]::Abs($low - $prevClose))
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

# === Запуск бэктеста ===
foreach ($symbol in $config.instruments) {
    Write-Host "Загружаю свечи для $symbol..."
    $candles = Get-Candles-From-OKX $symbol 1000 $config.candle_period
    if ($candles.Count -eq 0) { continue }
    $closes = $candles | ForEach-Object { $_.Close }
    $volumes = $candles | ForEach-Object { $_.Volume }

    Write-Host "Начинаю перебор параметров для $symbol..."

    $emaFastValues = @(8, 10, 12)
    $emaSlowValues = @(21, 30, 40)
    $rsiPeriodValues = @(12, 14, 16)
    $rsiMaxValues = @(68, 70, 75)
    $macdFastValues = @(8, 12)
    $macdSlowValues = @(26, 30)
    $macdSignal = 9
    $atrPeriod = 14
    $tpMultValues = @(0.5, 0.8, 1, 1.5, 1.8, 2, 2.2)
    $slMultValues = @(0.2, 0.5, 0.8, 1.0)

    foreach ($emaFast in $emaFastValues) {
        foreach ($emaSlow in $emaSlowValues) {
            if ($emaSlow -le $emaFast) { continue }
            foreach ($rsiPeriod in $rsiPeriodValues) {
                $rsiArr = Calculate-RSI $closes $rsiPeriod
                foreach ($rsiMax in $rsiMaxValues) {
                    foreach ($macdFast in $macdFastValues) {
                        foreach ($macdSlow in $macdSlowValues) {
                            if ($macdSlow -le $macdFast) { continue }

                            $macdRes = Calculate-MACD $closes $macdFast $macdSlow $macdSignal
                            $macdLine = $macdRes[0]
                            $macdSignalLine = $macdRes[1]

                            $atrArr = Calculate-ATR $candles $atrPeriod
                            if ($atrArr.Count -eq 0) { continue }

                            $startIndex = @(
                                $emaSlow,
                                $macdSlow,
                                $rsiPeriod,
                                $atrPeriod
                            ) | Measure-Object -Maximum | Select-Object -ExpandProperty Maximum

                            foreach ($tpMult in $tpMultValues) {
                                foreach ($slMult in $slMultValues) {

                                    $balance = $config.max_balance
                                    $positions = @{}
                                    $totalPnL = 0
                                    $wins = 0
                                    $trades = 0

                                    $peakBalance = $balance
                                    $maxDrawdown = 0

                                    for ($i = $startIndex; $i -lt $candles.Count; $i++) {
                                        # Проверяем открытые позиции
                                        if ($positions.ContainsKey("LONG")) {
                                            $pos = $positions["LONG"]
                                            # Закрытие по TP
                                            if ($candles[$i].High -ge $pos.TP) {
                                                $pnl = ($pos.TP - $pos.Entry) * $pos.Size
                                                $balance += $pos.Entry * $pos.Size + $pnl
                                                $totalPnL += $pnl
                                                $wins++
                                                $trades++
                                                $positions.Remove("LONG")
                                            }
                                            # Закрытие по SL
                                            elseif ($candles[$i].Low -le $pos.SL) {
                                                $pnl = ($pos.SL - $pos.Entry) * $pos.Size
                                                $balance += $pos.Entry * $pos.Size + $pnl
                                                $totalPnL += $pnl
                                                $trades++
                                                $positions.Remove("LONG")
                                            }
                                        }

                                        # Условия открытия LONG
                                        if (-not $positions.ContainsKey("LONG")) {
                                            $emaFastArr = Calculate-EMA $closes[0..$i] $emaFast
                                            $emaSlowArr = Calculate-EMA $closes[0..$i] $emaSlow

                                            if ($emaFastArr.Count -lt 2 -or $emaSlowArr.Count -lt 2) { continue }

                                            $emaCrossUp = ($emaFastArr[-1] -gt $emaSlowArr[-1]) -and ($emaFastArr[-2] -le $emaSlowArr[-2])

                                            # Проверяем, что MACD данные существуют и индекс в диапазоне
                                            if ($macdLine.Count -le $i -or $macdSignalLine.Count -le $i) { continue }
                                            $macdBullish = $macdLine[$i] -gt $macdSignalLine[$i]

                                            $rsiIndex = $i - $rsiPeriod
                                            if ($rsiIndex -lt 0 -or $rsiIndex -ge $rsiArr.Count) { continue }
                                            $rsiOk = $rsiArr[$rsiIndex] -lt $rsiMax

                                            $avgVolume = ($volumes[0..$i] | Measure-Object -Average).Average
                                            $volumeOk = $volumes[$i] -gt $avgVolume

                                            if ($emaCrossUp -and $macdBullish -and $rsiOk -and $volumeOk) {
                                                $price = $closes[$i]
                                                $size = [Math]::Round($config.position_size_usd / $price, 4)
                                                $atrIndex = $i - $atrPeriod
                                                if ($atrIndex -lt 0 -or $atrIndex -ge $atrArr.Count) { continue }
                                                $atrValue = $atrArr[$atrIndex]
                                                $tp = [Math]::Round($price + $atrValue * $tpMult, 8)
                                                $sl = [Math]::Round($price - $atrValue * $slMult, 8)
                                                $positions["LONG"] = [PSCustomObject]@{
                                                    Entry = $price
                                                    TP = $tp
                                                    SL = $sl
                                                    Size = $size
                                                }
                                                $balance -= $price * $size
                                            }
                                        }

                                        # Подсчёт просадки
                                        if ($balance -gt $peakBalance) { $peakBalance = $balance }
                                        $drawdown = ($peakBalance - $balance) / $peakBalance * 100
                                        if ($drawdown -gt $maxDrawdown) { $maxDrawdown = $drawdown }
                                    }

                                    if ($trades -gt 0) {
                                        $winRate = [Math]::Round(($wins / $trades) * 100, 2)
                                        $line = "$symbol,$emaFast,$emaSlow,$rsiPeriod,$rsiMax,$macdFast,$macdSlow,$atrPeriod,$tpMult,$slMult,$totalPnL,$winRate,$trades"
                                        Add-Content -Path $outputFile -Value $line
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

Write-Host "Бэктест завершён. Результаты в $outputFile"
