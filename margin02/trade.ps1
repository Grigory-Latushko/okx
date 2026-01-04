# MARGIN 02

param(
  [string]$ConfigPath = ".\config.json",
  [switch]$ForceLive,
  [switch]$DebugMode
)

if (-not $global:candleCache) { $global:candleCache = @{} }

# ---------------- helpers ----------------
function Get-Timestamp { return [int][double]::Parse((Get-Date -UFormat %s)) }

function Format-Time { return (Get-Date -Format "yyyy-MM-dd HH:mm:ss") }

function LogConsole($msg, $type = "INFO") {
    $ts = Format-Time
    Write-Host "[$ts][$type] $msg"
}
function Mask { param([string]$s) if (-not $s) { return "" } if ($s.Length -le 8) { return $s.Substring(0,2) + "..." } return $s.Substring(0,4) + "..." + $s.Substring($s.Length-4,4) } 
function Log { param([string]$msg, [string]$level = "INFO") switch ($level.ToUpper()) { "INFO"  { Write-Host "[INFO ] $msg" -ForegroundColor Gray } "OK"    { Write-Host "[ OK  ] $msg" -ForegroundColor Green } "WARN"  { Write-Host "[WARN ] $msg" -ForegroundColor Yellow } "ERROR" { Write-Host "[ERR  ] $msg" -ForegroundColor Red } "DEBUG" { if ($DebugMode) { Write-Host "[DBG  ] $msg" -ForegroundColor Cyan } } } }
function Get-NowTimestamp { (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ") }

function Set-OkxRequest {
  param($Secret, $Timestamp, $Method, $RequestPath, $Body)
  if ($null -eq $Body) { $Body = "" }
  $prehash = "$Timestamp$Method$RequestPath$Body"
  $hmac = New-Object System.Security.Cryptography.HMACSHA256
  $hmac.Key = [System.Text.Encoding]::UTF8.GetBytes($Secret)
  $hash = $hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($prehash))
  $sig = [Convert]::ToBase64String($hash)
  if ($DebugMode) { Log "prehash: $prehash" "DEBUG"; Log "signature: $sig" "DEBUG" }
  return $sig
}

function Send-OkxRequest {
  param([string]$Method, [string]$RequestPath, [string]$BodyJson, $config)

  $ts = Get-NowTimestamp
  $sig = Set-OkxRequest -Secret $config.secret_key -Timestamp $ts -Method $Method.ToUpper() -RequestPath $RequestPath -Body $BodyJson

  $headers = @{
    "OK-ACCESS-KEY"        = $config.api_key
    "OK-ACCESS-SIGN"       = $sig
    "OK-ACCESS-TIMESTAMP"  = $ts
    "OK-ACCESS-PASSPHRASE" = $config.passphrase
    "Content-Type"         = "application/json"
  }
  if ($null -ne $config.simulated) { $headers["x-simulated-trading"] = if ($config.simulated) { "1" } else { "0" } }

  $url = $config.baseUrl.TrimEnd('/') + $RequestPath
  $maskedHeaders = @{}; foreach ($k in $headers.Keys) { $v = $headers[$k]; if ($k -match "KEY|SIGN|PASSPHRASE") { $maskedHeaders[$k] = Mask($v) } else { $maskedHeaders[$k] = $v } }

  Log "Request: $Method $url" "DEBUG"
  Log "Body: $BodyJson" "DEBUG"
  Log "Headers: $($maskedHeaders | ConvertTo-Json -Compress)" "DEBUG"

  if ($config.dryRun -and -not $ForceLive) { Log "DryRun enabled — запрос не отправлен" "WARN"; return @{ dryRun = $true; method = $Method; url = $url; headers = $maskedHeaders; body = $BodyJson } }

  try {
    if ($Method.ToUpper() -eq "GET") { $resp = Invoke-RestMethod -Method Get -Uri $url -Headers $headers -ErrorAction Stop } else { $resp = Invoke-RestMethod -Method Post -Uri $url -Headers $headers -Body $BodyJson -ErrorAction Stop }
    Log "HTTP OK for $RequestPath" "OK"
    if ($DebugMode) { Log "Response:`n$($resp | ConvertTo-Json -Depth 8)" "DEBUG" }
    return $resp
  } catch {
    Log "Request failed: $Method $url" "ERROR"
    Log $_.Exception.Message "ERROR"
    if ($_.Exception.Response) { try { $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream()); $body = $reader.ReadToEnd(); Log "Response body: $body" "DEBUG" } catch {} }
    return $null
  }
}

function Get-Price { 
    param($instId, $config)
    Log "Получаем цену для $instId" "DEBUG"

    $resp = Send-OkxRequest -Method "GET" -RequestPath "/api/v5/market/ticker?instId=$($instId)" -BodyJson "" -config $config

    if (-not $resp) {
        Log "Нет ответа от API для $instId" "WARN"
        return $null
    }

    # Если сервер вернул ошибку OKX
    if ($resp.code -and $resp.code -ne "0") {
        Log "Ошибка OKX для $instId code=$($resp.code) msg=$($resp.msg)" "WARN"
        return $null
    }

    if ($resp.data -and $resp.data.Count -ge 1) {
        $p = [decimal]$resp.data[0].last
        Log "Цена $instId = $p" "OK"
        return $p
    }

    Log "Пустой массив data для $instId $($resp | ConvertTo-Json -Depth 5)" "WARN"
    return $null
}

function Get-InstrumentInfo { 
    param($instId, $config) Log "Получаем информацию об инструменте $instId" "DEBUG"; $resp = Send-OkxRequest -Method "GET" -RequestPath "/api/v5/public/instruments?instType=SWAP&instId=$($instId)" -BodyJson "" -config $config; if ($resp -and $resp.data -and $resp.data.Count -ge 1) { return $resp.data[0] } return $null 
}

function Set-ToStep {
    param($value, $step) if ($step -eq 0 -or $null -eq $step) { return [math]::Round($value, 8) } $quotient = [math]::Floor(($value / $step) + 0.0000000001); $rounded = $quotient * $step; return [decimal]$([math]::Round([double]$rounded, 8)) 
}

function RoundPriceToTick { 
    param($price, $tick) if ($tick -eq 0 -or $null -eq $tick) { return [math]::Round($price, 8) } $q = [math]::Round($price / $tick, 8); $r = [math]::Round($q) * $tick; return [decimal]$([math]::Round([double]$r, 8)) 
}

function Get-AccountConfig { 
   param($config) Log "Получаем конфиг аккаунта (/api/v5/account/config)" "DEBUG"; $resp = Send-OkxRequest -Method "GET" -RequestPath "/api/v5/account/config" -BodyJson "" -config $config; if ($resp -and $resp.data -and $resp.data.Count -ge 1) { $d = $resp.data[0]; if ($d.psMode) { return $d.psMode }; if ($d.posMode) { return $d.posMode }; if ($d.positionMode) { return $d.positionMode }; return $resp.data }; return $null 
}

function Get-ActiveAlgoOrders {
    param(
        [string]$instId,
        [psobject]$config,
        [string]$ordType = ""  # по умолчанию берем все типы
    )

    # Если указан ordType, добавляем параметр
    if ($ordType) {
        $path = "/api/v5/trade/orders-algo-pending?instId=$instId&ordType=$ordType"
    } else {
        $path = "/api/v5/trade/orders-algo-pending?instId=$instId"
    }

    $resp = Send-OkxRequest -Method "GET" `
        -RequestPath $path `
        -BodyJson "" `
        -config $config

    return $resp.data
}

function Cancel-AlgoOrder {
    param($instId, $algoId, $config)

    $body = @{
        instId = $instId
        algoId = $algoId
    } | ConvertTo-Json -Compress

    Send-OkxRequest `
        -Method "POST" `
        -RequestPath "/api/v5/trade/cancel-algos" `
        -BodyJson $body `
        -config $config
}

function Place-StopLoss {
    param($instId, $slPrice, $sz, $config)

    $body = @{
        instId      = $instId
        tdMode      = $config.mgnMode
        ordType     = "conditional"
        side        = "sell"      # 🔴 КРИТИЧНО
        posSide     = "net"
        sz          = ([string]$sz)
        slTriggerPx = ([string]$slPrice)
        slOrdPx     = "-1"
    } | ConvertTo-Json -Compress

    Send-OkxRequest -Method "POST" `
        -RequestPath "/api/v5/trade/order-algo" `
        -BodyJson $body `
        -config $config
}

# ---------------- apply leverage (isolated) ----------------
function Set-IsolatedLeverage {
    param(
        [string]$instId,
        [int]$lever,
        $config,
        [string]$posSide = "long"
    )

    Log "=== Set-IsolatedLeverage START for $instId lever=$lever posSide=$posSide ===" "DEBUG"

    if (-not $instId) { Log "instId is required" "ERROR"; return $null }
    if (-not $lever -or $lever -le 0) { Log "Invalid lever: $lever" "ERROR"; return $null }

    # Получаем мета-информацию и цену
    Log "Fetching instrument info for $instId" "DEBUG"
    $info = Get-InstrumentInfo -instId $instId -config $config
    Log "Fetching current price for $instId" "DEBUG"
    $price = Get-Price -instId $instId -config $config

    if (-not $info) {
        Log "Instrument info not available for $instId" "ERROR"
        return $null
    }
    if (-not $price) {
        Log "Price not available for $instId" "ERROR"
        return $null
    }

    # Преобразуем и логируем мета-поля если есть
    $ctVal = if ($info.ctVal) { [decimal]$info.ctVal } else { 1 }
    $minSz = if ($info.minSz) { [decimal]$info.minSz } elseif ($info.lotSz) { [decimal]$info.lotSz } elseif ($info.sz) { [decimal]$info.sz } else { 0.01 }
    $tick  = if ($info.tickSz) { [decimal]$info.tickSz } else { $null }

    Log "Instrument meta: ctVal=$ctVal, minSz=$minSz, tick=$tick" "DEBUG"

    # Проверка допустимого плеча (если в meta есть соответствующее поле)
    $maxLeverCandidates = @()
    foreach ($fn in @("maxLeverage","max_leverage","maxLever","maxleverage","lever","maxLeverRatio")) {
        if ($info.PSObject.Properties.Name -contains $fn) {
            $maxLeverCandidates += [string]$info.$fn
        }
    }
    if ($maxLeverCandidates.Count -gt 0) {
        $maxLev = [decimal]$maxLeverCandidates[0]
        Log "Found max leverage candidate in instrument meta: $maxLev" "DEBUG"
        if ($lever -gt $maxLev) {
            Log "Requested lever $lever > instrument max $maxLev. Aborting." "ERROR"
            return $null
        }
    } else {
        Log "No explicit max-leverage found in instrument meta; continuing." "DEBUG"
    }

    # Рассчитаем минимальный размер позиции / контрактов ради проверки
    $notional_desired = [decimal]($config.position_size_usd * $lever)
    if ($ctVal -gt 0) {
        $rawContracts = [decimal]($notional_desired / ($ctVal * $price))
        $step = if ($info.minSz) { [decimal]$info.minSz } elseif ($info.lotSz) { [decimal]$info.lotSz } elseif ($info.sz) { [decimal]$info.sz } else { 1 }
        if ($step -le 0) { $step = 1 }
        $sz = Set-ToStep -value $rawContracts -step $step
        Log "Computed contracts: raw=$rawContracts, step=$step, rounded sz=$sz" "DEBUG"
    } else {
        $rawSize = [decimal]($notional_desired / $price)
        $step = if ($info.minSz) { [decimal]$info.minSz } elseif ($info.lotSz) { [decimal]$info.lotSz } else { 0.0001 }
        if ($step -le 0) { $step = 0.0001 }
        $sz = Set-ToStep -value $rawSize -step $step
        Log "Computed spot qty: raw=$rawSize, step=$step, rounded sz=$sz" "DEBUG"
    }

    if ($sz -le 0) {
        if ($config.force_min_size -and $step -gt 0) {
            if ($ctVal -gt 0) { $notional_if_forced = [math]::Round(($step * $ctVal * $price), 8) } else { $notional_if_forced = [math]::Round(($step * $price), 8) }
            $threshold = if ($config.force_threshold_factor) { $config.force_threshold_factor } else { 3 }
            if ($notional_if_forced -gt ($notional_desired * $threshold)) {
                Log "Forcing minimal step would create notional $notional_if_forced USD > $threshold × desired. Aborting." "WARN"
                return $null
            }
            Log "Forcing minimal step: sz = $step (forced notional = $notional_if_forced USD)" "WARN"
            $sz = $step
        } else {
            Log "Calculated size <= 0 and force_min_size not allowed -> aborting" "WARN"
            return $null
        }
    }

    # Повторная проверка minSz
    if ($sz -lt $minSz) {
        Log "Calculated size $sz < instrument minSz $minSz. Adjusting to minSz." "WARN"
        $sz = $minSz
    }

    $notional_actual = if ($ctVal -and $ctVal -gt 0) { [math]::Round(($sz * $ctVal * $price), 8) } else { [math]::Round(($sz * $price), 8) }
    Log "Final size to be used for leverage decision: sz=$sz notional_actual=$notional_actual USD" "DEBUG"

    # Решаем нужно ли отправлять posSide в теле запроса
    # Пытаемся использовать глобальный/скриптовый posMode, иначе запрашиваем.
    $pm = $null
    if ($script:posMode) { $pm = $script:posMode } elseif ($posMode) { $pm = $posMode }
    if (-not $pm) {
        Log "posMode not found in memory; fetching account config" "DEBUG"
        $g = Get-AccountConfig -config $config
        if ($g) { $pm = $g }
    }
    Log "Resolved posMode = '$pm'" "DEBUG"

    $mgnMode = "isolated"
    $bodyObj = @{
        instId = $instId
        lever  = ([string]$lever)
        mgnMode = $mgnMode
    }

    # Если posMode указывает на hedge/long_short — posSide обязателен
    if ($pm -and ($pm.ToString().ToLower().Contains("long_short") -or $pm.ToString().ToLower().Contains("hedge") -or $pm.ToString().ToLower().Contains("hedged"))) {
        Log "Account in hedged/long_short mode -> adding posSide='$posSide' to request body" "DEBUG"
        $bodyObj.posSide = $posSide
    } else {
        Log "Account in net/one-way/unknown mode -> NOT adding posSide to request body (to avoid bad-request)" "DEBUG"
    }

    $body = $bodyObj | ConvertTo-Json -Compress
    Log "Prepared set-leverage body: $body" "DEBUG"

    # Выводим защищённые заголовки для дебага (маскируем секреты)
    $masked = @{ api_key = Mask($config.api_key); passphrase = Mask($config.passphrase); secret_key = Mask($config.secret_key); baseUrl = $config.baseUrl }
    Log "Config (masked): $($masked | ConvertTo-Json -Compress)" "DEBUG"

    # Отправляем запрос и обрабатываем результат
    try {
        $resp = Send-OkxRequest -Method "POST" -RequestPath "/api/v5/account/set-leverage" -BodyJson $body -config $config
        if (-not $resp) {
            Log "No response or request failed for set-leverage (null)" "ERROR"
            return $null
        }
        # Если в Send-OkxRequest для dryRun вернулся специальный объект
        if ($resp.dryRun) {
            Log "DryRun: set-leverage preview returned" "WARN"
            if ($DebugMode) { ($resp | ConvertTo-Json -Depth 6) | Write-Host }
            return $sz
        }

        # Проверяем код OKX
        if ($resp.code -and $resp.code -eq "0") {
            Log "Set-Isolated-Leverage OK for $instId (resp.code=0)" "OK"
            if ($DebugMode) { Log "Response full: $($resp | ConvertTo-Json -Depth 8)" "DEBUG" }
            return $sz
        } else {
            # Логируем максимально подробный ответ ошибки
            if ($resp | ConvertTo-Json -Depth 6) {
                Log "Set-Leverage returned non-zero code: code=$($resp.code) msg=$($resp.msg)" "ERROR"
                if ($DebugMode) { ($resp | ConvertTo-Json -Depth 8) | Write-Host }
            } else {
                Log "Set-Leverage returned failure; response object present but cannot serialize" "ERROR"
            }
            return $null
        }
    } catch {
        Log "Exception during set-leverage: $($_.Exception.Message)" "ERROR"
        try {
            if ($_.Exception.Response) {
                $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream());
                $bodyErr = $reader.ReadToEnd();
                Log "HTTP error response body: $bodyErr" "ERROR"
            }
        } catch { }
        return $null
    } finally {
        Log "=== Set-IsolatedLeverage END for $instId ===" "DEBUG"
    }
}

#################### INDICATORS ####################

function Get-Candles($symbol, $limit, $period) {
    $cacheKey = "$symbol-$period-$limit"
    
    # Проверяем, есть ли в кэше и свежие ли данные
    if ($global:candleCache.ContainsKey($cacheKey)) {
        $cached = $global:candleCache[$cacheKey]
        # $age = Get-Timestamp - $cached.Timestamp
        $age = (Get-Timestamp) - $cached.Timestamp
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
function Get-EMA($prices, $period) {
    if ($prices.Count -lt $period) { return @() }
    $k = 2 / ($period + 1)
    $ema = @($prices[0])
    for ($i = 1; $i -lt $prices.Count; $i++) {
        $ema += $prices[$i] * $k + $ema[$i-1] * (1 - $k)
    }
    return $ema
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
function Get-ATR($candles, $period) {
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

function Get-UTBotSignals {
    param(
        [array]$candles,
        [int]$atrPeriod = 10,
        [decimal]$atrMultiplier = 1.0
    )

    if ($candles.Count -le ($atrPeriod + 2)) { return $null }

    $closes = $candles | ForEach-Object { $_.Close }

    # ATR
    $atrArr = Get-ATR $candles $atrPeriod
    if ($atrArr.Count -eq 0) { return $null }

    $atr = [decimal]$atrArr[-1]
    $nLoss = $atr * $atrMultiplier

    # Trailing Stop array
    $ts = @()
    $ts += $closes[0]

    for ($i = 1; $i -lt $closes.Count; $i++) {
        $prevTS = $ts[$i - 1]
        $price = $closes[$i]
        $prevPrice = $closes[$i - 1]

        if ($price -gt $prevTS -and $prevPrice -gt $prevTS) {
            $ts += [Math]::Max($prevTS, $price - $nLoss)
        }
        elseif ($price -lt $prevTS -and $prevPrice -lt $prevTS) {
            $ts += [Math]::Min($prevTS, $price + $nLoss)
        }
        elseif ($price -gt $prevTS) {
            $ts += ($price - $nLoss)
        }
        else {
            $ts += ($price + $nLoss)
        }
    }

    # Последние 2 значения
    $tsPrev   = $ts[-2]
    $tsCurr   = $ts[-1]
    $closePrev = $closes[-2]
    $closeCurr = $closes[-1]

    $longSignal  = ($closePrev -le $tsPrev) -and ($closeCurr -gt $tsCurr)
    $shortSignal = ($closePrev -ge $tsPrev) -and ($closeCurr -lt $tsCurr)

    return @{
        atr = $atr
        trailingStop = $tsCurr
        long  = $longSignal
        short = $shortSignal
    }
}

# #################### main ####################

$config = Get-Content $configPath -Raw | ConvertFrom-Json

$allow_shorts = if ($null -ne $config.allow_shorts) { [bool]$config.allow_shorts } else { $false }

$configMasked = @{ api_key = Mask($config.api_key); secret_key = Mask($config.secret_key); passphrase = Mask($config.passphrase); position_size_usd = $config.position_size_usd; leverage = $config.leverage; baseUrl = $config.baseUrl; instruments = $config.instruments; take_profit_pct = $config.take_profit_pct; tp_exec_market = $config.tp_exec_market; dryRun = $config.dryRun; allow_shorts = $allow_shorts }
Log "Loaded config: $($configMasked | ConvertTo-Json -Depth 5)" "DEBUG"

if (-not $config.api_key -or -not $config.secret_key -or -not $config.passphrase) { Log "api_key / secret_key / passphrase must be provided in config file" "ERROR"; exit 1 }
if (-not $config.instruments -or $config.instruments.Count -eq 0) { Log "No instruments provided in config -> 'instruments' array" "ERROR"; exit 1 }

# #################### auth & time ####################

try {
    $timeResp = Send-OkxRequest -Method "GET" -RequestPath "/api/v5/public/time" -BodyJson "" -config $config
    if ($timeResp -and $timeResp.data -and $timeResp.data.Count -ge 1) {
        $serverIso = $timeResp.data[0].iso
        $serverTs = try { [datetime]::ParseExact($serverIso, "yyyy-MM-ddTHH:mm:ss.fffZ", $null).ToUniversalTime() } catch { [datetime]::Parse($serverIso).ToUniversalTime() }
        $localUtc = (Get-Date).ToUniversalTime(); $delta = [math]::Abs(($serverTs - $localUtc).TotalSeconds)
        Log "Server time: $serverTs, Local UTC: $localUtc, delta(s) = $delta" "DEBUG"
        if ($delta -gt 30) { Log "Local time differs by >30s. Sync clock (NTP)." "WARN" }
    }
} catch {}

$authOk = $true
$balResp = Send-OkxRequest -Method "GET" -RequestPath "/api/v5/account/balance" -BodyJson "" -config $config
if ($null -eq $balResp) { Log "Warning: failed to call private endpoint /account/balance. Check API key permissions, IP whitelist, or environment (demo vs live)." "WARN"; $authOk = $false } else { Log "/account/balance OK (auth check passed)" "DEBUG" }

$posMode = $null
if ($authOk) {
    $configResp = Get-AccountConfig -config $config
    if ($configResp) { Log "Account config posMode: $configResp" "DEBUG"; $posMode = $configResp } else { Log "Could not fetch account config (posMode). posMode unknown." "DEBUG" }
}

$candle_period     = $config.candle_period
$candle_limit      = $config.candle_limit
$atrPeriod         = $config.atrPeriod
$tp_atr_multiplier = $tp_atr_multiplier
$higher_tf         = $config.higher_tf


# #################### loop instruments ####################
function Run-Bot {
    foreach ($instId in $config.instruments) {
        Write-Host "`n=== Processing $instId ===" -ForegroundColor White

        Start-Sleep -Seconds $config.rerun_interval_s
        
        $price = Get-Price -instId $instId -config $config
        Write-Output "Текущая цена: $price" 
        
        ############ TRADE CONDITIONS CALCULATION ############
        $candles = Get-Candles $instId $candle_limit $candle_period
        Write-Output "Получено $($candles.Count) свечей для $instId по таймфрейму $candle_period"

        if ($candles.Count -lt 2) { continue }   # минимум 2 свечи

        # закрытия свечей
        # $closes = $candles | ForEach-Object { $_.Close }

        # ===== ATR =====
        $atrArr = Get-ATR $candles $atrPeriod
        if ($atrArr.Count -eq 0) { continue }
        $atr = $atrArr[-1]
        Write-Output "ATR($atrPeriod): $atr"
        $atr_pct = ($atr / $price) * 100
        Write-Output "ATR%: $([math]::Round($atr_pct, 4)) %"

        # === CHECK EXISTING POSITION ===
        $hasLong = $false
        $posSize = 0
        $position = $null
        $info = Get-InstrumentInfo -instId $instId -config $config

        if ($authOk) {
            $positionsResp = Send-OkxRequest -Method "GET" `
                -RequestPath "/api/v5/account/positions?instId=$instId" `
                -BodyJson "" -config $config

            foreach ($p in $positionsResp.data) {
                $side = ($p.posSide ?? "net").ToLower()
                $posRaw = [decimal]$p.pos
                $ctVal = [decimal]$info.ctVal

                $pos = $posRaw / $ctVal

                if ($pos -gt 0 -and ($side -eq "long" -or $side -eq "net")) {
                    $hasLong = $true
                    $posSize = $pos
                    $position = $p
                    Write-Output "Открытая позиция: side=$side size=$posSize"
                    break
                }
            }
        }

        if ($hasLong) {

            $entryPx   = [decimal]$position.avgPx
            $currentPx = [decimal]$price
            $atrDec    = [decimal]$atr

            $profit = $currentPx - $entryPx
            Write-Output "Profit from entry: $profit"

            $profitPct = [math]::Round(($profit / $entryPx) * 100, 2)
            Write-Output "Profit %: $profitPct %"

            $trailingOrders  = Get-ActiveAlgoOrders -instId $instId -config $config -ordType "move_order_stop"
            write-output "Всего активных trailingOrders ордеров: $($trailingOrders.Count)"

            # получить все conditional (старые SL)
            $conditionalOrders = Get-ActiveAlgoOrders -instId $instId -config $config -ordType "conditional"

            # старт трейлинга после минимального профита
            if (($profit -ge $atrDec) -and ($trailingOrders.Count -eq 0)) {
               
                # новый трейлинг-стоп
                $trailStopPrice = $currentPx - (0.5 * $atrDec)
                $trailStopPrice = RoundPriceToTick $trailStopPrice $info.tickSz

                # размер позиции
                $ctVal = [decimal]$info.ctVal
                $szApi = [math]::Round($posSize * $ctVal, 8)

                Write-Output "Placing/Updating trailing stop: $trailStopPrice for size $szApi"

                # создаём обычный стоп-ордeр (market SL)
                # Половина ATR
                $halfAtr = 0.5 * $atrDec

                # callbackRatio = половина ATR относительно текущей цены
                $callbackRatio = [math]::Round($halfAtr / $currentPx, 6)

                $trailingOrder = @{
                    instId = $instId
                    tdMode = $config.mgnMode
                    side = "sell"
                    ordType = "move_order_stop"
                    sz = ([string]$szApi)
                    callbackRatio = ([string]$callbackRatio)
                    activePx = ([string]$currentPx)
                }

                $resp = Send-OkxRequest -Method "POST" `
                        -RequestPath "/api/v5/trade/order-algo" `
                        -BodyJson ($trailingOrder | ConvertTo-Json -Compress) `
                        -config $config

                if ($resp.code -eq "0") {
                    Log "Trailing stop placed: $currentPx for size $szApi" "OK"
                } else {
                    Log "Failed to place trailing stop: $($resp.msg)" "ERROR"
                }
            }
        }

        ############ UT BOT SIGNALS ############

        if ($hasLong) {
            Write-Output "There is an open LONG position  $instId"
        } else {
            Write-Output "No open LONG position for $instId"

            $ut = Get-UTBotSignals `
                    -candles $candles `
                    -atrPeriod $config.atrPeriod `
                    -atrMultiplier $config.ut_multiplier

            if (-not $ut) {
                Log "UT Bot calculation failed — skipping $instId" "WARN"
                continue
            }

            Write-Output "UT Bot: ATR=$($ut.atr), TS=$($ut.trailingStop)"

            # === UT BOT SIGNALS ===
            $buySignal  = $ut.long
            $sellSignal = $ut.short
            if ($buySignal) { Write-Output "UT Bot generated BUY signal 📈" }
            if ($sellSignal) { Write-Output "UT Bot generated SELL signal 📉" }

            if (-not $buySignal -and -not $sellSignal) {
                Log "No UT Bot signal — waiting" "DEBUG"
                continue
            }

            $sz = Set-IsolatedLeverage `
                    -instId $instId `
                    -lever $config.leverage `
                    -config $config `
                    -posSide "long"

            if (-not $sz) {
                Log "Failed to calculate position size" "ERROR"
                continue
            }

            # === OPEN LONG ===
            if ($buySignal -and -not $hasLong) {

                if (-not $sz -or $sz -le 0) {
                    Log "Invalid sz — cannot open LONG" "ERROR"
                    continue
                }

                Log "UT BUY → opening LONG" "OK"
                write-output "sz=$sz" "DEBUG"

                $orderObj = @{
                    instId = $instId
                    tdMode = $config.mgnMode
                    side   = "buy"
                    ordType = "market"
                    sz = ([string]$sz)
                    # posSide = "long"
                }

                $resp = Send-OkxRequest -Method "POST" `
                    -RequestPath "/api/v5/trade/order" `
                    -BodyJson ($orderObj | ConvertTo-Json -Compress) `
                    -config $config

                if ($resp) {
                    Log "LONG opened by UT BUY" "OK"
                    write-output "Order response: $($resp | ConvertTo-Json -Depth 6)" "DEBUG"
                }

                continue
            }
        }
        # === CLOSE LONG ===
        # if ($sellSignal -and $hasLong) {
        #     Log "UT SELL → closing LONG" "WARN"
        #     $info = Get-InstrumentInfo -instId $instId -config $config
        #     $ctVal = if ($info.ctVal) { [decimal]$info.ctVal } else { 1 }
        #     $szApi = [math]::Round($posSize * $ctVal, 8)
        #     $closeObj = @{
        #         instId = $instId
        #         tdMode = $config.mgnMode
        #         side   = "sell"
        #         ordType = "market"
        #         sz     = ([string]$szApi)
        #         reduceOnly = $true
        #     }

        #     $resp = Send-OkxRequest -Method "POST" `
        #         -RequestPath "/api/v5/trade/order" `
        #         -BodyJson ($closeObj | ConvertTo-Json -Compress) `
        #         -config $config

        #     if ($resp) {
        #         Log "LONG closed by UT SELL" "OK"
        #     }
        #     continue
        # }
    }
        Log "Done." "OK"
}

while ($true) {
    Run-Bot
}
