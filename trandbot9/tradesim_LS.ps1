# === CONFIG ===
param(
    [string]$configPath = ".\config.json"
)

$config = Get-Content $configPath | ConvertFrom-Json

# === UTILS ===
function Get-Timestamp { return [int][double]::Parse((Get-Date -UFormat %s)) }
function Format-Time { return (Get-Date -Format "yyyy-MM-dd HH:mm:ss") }
function LogConsole($msg, $type = "INFO") {
    $ts = Format-Time
    Write-Host "[$ts][$type] $msg"
}

# === API CLIENT ===
# ⚠️ Здесь нужно добавить твои ключи OKX
$apiKey    = "<API_KEY>"
$secretKey = "<SECRET_KEY>"
$passphrase= "<PASSPHRASE>"
$baseUrl   = "https://www.okx.com"

function Invoke-OKX {
    param(
        [string]$method,
        [string]$endpoint,
        [string]$body = ""
    )
    # TODO: добавить подпись запроса по OKX API (HMAC-SHA256)
    $url = "$baseUrl$endpoint"
    $headers = @{
        "OK-ACCESS-KEY" = $apiKey
        "OK-ACCESS-PASSPHRASE" = $passphrase
        # OK-ACCESS-SIGN и OK-ACCESS-TIMESTAMP нужно генерировать
    }
    return Invoke-RestMethod -Uri $url -Method $method -Headers $headers -Body $body
}

# === DATA FETCH ===
function Get-Last-Tick($symbol) {
    try {
        $url = "$baseUrl/api/v5/market/ticker?instId=$symbol"
        $res = Invoke-RestMethod -Uri $url -Method Get
        return [double]$res.data[0].last
    } catch {
        LogConsole "Ошибка получения тика для ${symbol}: $($_)" "ERROR"
        return $null
    }
}

function Get-Candles($symbol, $limit, $period) {
    try {
        $url = "$baseUrl/api/v5/market/candles?instId=$symbol&bar=$period&limit=$limit"
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

function Get-RSI([double[]]$prices, [int]$period) {
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

function Get-Trend($candles, $atrPeriod, $trend_candles, $trendsize) {
    if (-not $candles -or $candles.Count -lt $trend_candles) { return "NEUTRAL" }
    $atrArr = Calculate-ATR $candles $atrPeriod
    if (-not $atrArr -or $atrArr.Count -eq 0) { return "NEUTRAL" }
    $lastAtr=$atrArr[-1]
    $lastCloses=$candles | Sort-Object Timestamp | Select-Object -Last $trend_candles | ForEach-Object {$_.Close}
    if ($lastCloses.Count -lt 2) { return "NEUTRAL" }
    $delta = $lastCloses[-1] - $lastCloses[0]
    if ($delta -gt $lastAtr*$trendsize) { return "UP" } elseif ($delta -lt -$lastAtr*$trendsize) { return "DOWN" } else { return "NEUTRAL" }
}

function Get-StopLoss($candles,$sl_candles,$direction,$entryPrice,$atr) {
    $recentCandles = $candles | Sort-Object Timestamp | Select-Object -Last $sl_candles
    switch ($direction.ToUpper()) {
        "LONG" { $sl = ($recentCandles | Measure-Object -Property Close -Minimum).Minimum }
        "SHORT"{ $sl = ($recentCandles | Measure-Object -Property Close -Maximum).Maximum }
    }
    $minDist = [Math]::Max($atr * 0.2, $entryPrice * 0.001)
    if ($direction -eq "LONG" -and ($sl -ge $entryPrice -or [Math]::Abs($entryPrice - $sl) -lt $minDist)) {
        $sl = $entryPrice - $minDist
    }
    if ($direction -eq "SHORT" -and ($sl -le $entryPrice -or [Math]::Abs($entryPrice - $sl) -lt $minDist)) {
        $sl = $entryPrice + $minDist
    }
    return [Math]::Round($sl,8)
}

# === TRADING ===
function Get-Position($symbol) {
    try {
        $res = Invoke-OKX -method "GET" -endpoint "/api/v5/account/positions?instId=$symbol"
        if ($res.data.Count -eq 0) { return "FLAT" }

        $pos = $res.data[0]
        $size = [double]$pos.pos

        if ($size -gt 0) { return "LONG" }
        elseif ($size -lt 0) { return "SHORT" }
        else { return "FLAT" }
    } catch {
        LogConsole "Ошибка при получении позиции по $symbol $($_)" "ERROR"
        return "FLAT"
    }
}



function Place-Order($symbol,$side,$size,$tp,$sl) {
    $currentPos = Get-Position $symbol
    LogConsole "📊 Текущая позиция по $symbol = $currentPos" "INFO"

    if ($currentPos -eq "OPEN") {
        LogConsole "⏸ Уже открыта позиция по $symbol, новый ордер не выставляем" "WARN"
        return
    }

    # 1. Открываем позицию
    $orderBody = @{
        instId = $symbol
        tdMode = "cross"
        side   = $side.ToLower()
        ordType= "market"
        sz     = "$size"
    }
    $orderResp = Invoke-OKX -method "POST" -endpoint "/api/v5/trade/order" -body ($orderBody | ConvertTo-Json -Compress)

    # 2. Определяем сторону выхода
    if ($side -eq "BUY") { $closeSide = "sell" } else { $closeSide = "buy" }

    # 3. Ставим TP/SL
    $algoBody = @{
        instId = $symbol
        tdMode = "cross"
        side   = $closeSide
        ordType= "conditional"
        sz     = "$size"

        tpTriggerPx = "$tp"
        tpOrdPx     = "-1"   # по рынку
        slTriggerPx = "$sl"
        slOrdPx     = "-1"
    }
    $algoResp = Invoke-OKX -method "POST" -endpoint "/api/v5/trade/order-algo" -body ($algoBody | ConvertTo-Json -Compress)

    LogConsole "✅ Сделка открыта: entry=$($orderResp.data[0].ordId), TP/SL algo=$($algoResp.data[0].algoId)" "TRADE"
}


# === MAIN LOOP ===
function Run-Bot {
    foreach ($symbol in $config.instruments) {
        $candles = Get-Candles $symbol $config.candle_limit $config.candle_period
        if ($candles.Count -lt 50) { continue }

        $closes   = $candles | ForEach-Object { $_.Close }
        $ema21    = Calculate-EMA $closes 21
        $rsi6Arr  = Get-RSI $closes 6
        $rsi14Arr = Get-RSI $closes 14
        $rsi30Arr = Get-RSI $closes 30
        if ($rsi6Arr.Count -lt 2 -or $rsi14Arr.Count -lt 2 -or $rsi30Arr.Count -lt 2) { continue }

        $rsi6Curr  = $rsi6Arr[-1]
        $rsi14Curr = $rsi14Arr[-1]
        $rsi30Curr = $rsi30Arr[-1]
        $atrArr    = Calculate-ATR $candles $config.atrPeriod
        if ($atrArr.Count -eq 0) { continue }

        $atr = $atrArr[-1]
        $price = Get-Last-Tick $symbol
        if ($null -eq $price) { continue }

        $size = [Math]::Round($config.position_size_usd/$price,4)
        $trend_candles = $config.trend_candles
        $tpMultiplier  = $config.tp_ATR
        $trend         = Get-Trend $candles $config.atrPeriod $trend_candles $config.trend_size
        $lastEMA21     = $ema21[-1]

        $longSignal  = ($price -gt $lastEMA21) -and ($rsi6Curr -ge $config.rsi6_max) -and ($rsi14Curr -ge $config.rsi14_max) -and ($rsi30Curr -ge $config.rsi30_max) -and ($trend -eq "UP")
        $shortSignal = ($price -lt $lastEMA21) -and ($rsi6Curr -le $config.rsi6_min) -and ($rsi14Curr -le $config.rsi14_min) -and ($rsi30Curr -le $config.rsi30_min) -and ($trend -eq "DOWN")

        if ($longSignal) {
            $sl = Get-StopLoss $candles $trend_candles "LONG" $price $atr
            $tp = [Math]::Round($price + [Math]::Max($atr * $tpMultiplier, $price*0.001),8)
            Place-Order $symbol "BUY" $size $tp $sl
        }

        if ($shortSignal) {
            $sl = Get-StopLoss $candles $trend_candles "SHORT" $price $atr
            $tp = [Math]::Round($price - [Math]::Max($atr * $tpMultiplier, $price*0.001),8)
            Place-Order $symbol "SELL" $size $tp $sl
        }

        Start-Sleep -Milliseconds 200
    }
}

while ($true) { Run-Bot; Start-Sleep -Seconds $config.rerun_interval_s }
