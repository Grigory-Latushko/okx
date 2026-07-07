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

# ---------------- UT BOT (TradingView UT Bot Alerts) ----------------
function Compute-HeikinAshi($candles) {
    $n = $candles.Count
    $haOpen = New-Object System.Collections.Generic.List[double]
    $haClose = New-Object System.Collections.Generic.List[double]
    $haHigh = New-Object System.Collections.Generic.List[double]
    $haLow = New-Object System.Collections.Generic.List[double]

    for ($i = 0; $i -lt $n; $i++) {
        $c = $candles[$i]
        $hc = ([double]($c.Open + $c.High + $c.Low + $c.Close) / 4.0)
        if ($i -eq 0) {
            $ho = ([double]($c.Open + $c.Close) / 2.0)
        } else {
            $ho = ([double](($haOpen[$i-1] + $haClose[$i-1]) / 2.0))
        }
        $hh = [Math]::Max($c.High, $ho, $hc)
        $hl = [Math]::Min($c.Low,  $ho, $hc)

        $haOpen.Add([double]$ho)
        $haClose.Add([double]$hc)
        $haHigh.Add([double]$hh)
        $haLow.Add([double]$hl)
    }

    # return array of PSCustomObject candles with fields Open/High/Low/Close
    $out = for ($i=0; $i -lt $n; $i++) {
        [PSCustomObject]@{
            Open = $haOpen[$i]
            High = $haHigh[$i]
            Low  = $haLow[$i]
            Close= $haClose[$i]
        }
    }
    return $out
}

function Compute-ATR-Full($candles, [int]$period) {
    if ($candles.Count -le $period) { return @() }
    $n = $candles.Count
    $trs = New-Object System.Collections.Generic.List[double]
    for ($i = 1; $i -lt $n; $i++) {
        $high = [double]$candles[$i].High
        $low  = [double]$candles[$i].Low
        $prevClose = [double]$candles[$i-1].Close
        $tr = [Math]::Max(($high - $low), [Math]::Max([Math]::Abs($high - $prevClose), [Math]::Abs($low - $prevClose)))
        $trs.Add($tr)
    }
    if ($trs.Count -lt $period) { return @() }

    $atrList = New-Object System.Collections.Generic.List[Nullable[double]]
    # For alignment we will produce an array length = candles.Count with $null for first entries
    for ($i = 0; $i -lt $period; $i++) { $atrList.Add($null) }

    $initialSMA = ($trs[0..($period-1)] | Measure-Object -Sum).Sum / $period
    $atrList.Add([double]$initialSMA)   # this corresponds to index = $period

    $k = 2.0 / ($period + 1)
    for ($i = $period; $i -lt $trs.Count; $i++) {
        $prev = $atrList[$atrList.Count - 1].Value
        $next = ($trs[$i] * $k + $prev * (1 - $k))
        $atrList.Add([double]$next)
    }

    # Now atrList length = trs.Count + 1 = candles.Count
    return ,($atrList)
}

function Get-UTSignals($candles, [double]$a = 1.0, [int]$atrPeriod = 10, [bool]$useHeikin = $false) {
    # Returns PSCustomObject { Buy=bool; Sell=bool; BarBuy=bool; BarSell=bool; TrailingStops=[array]; PosSeries=[array] }

    if ($candles.Count -lt ($atrPeriod + 3)) { return [PSCustomObject]@{ Buy=$false; Sell=$false; BarBuy=$false; BarSell=$false; TrailingStops=@(); Pos=@() } }

    if ($useHeikin) { $hcandles = Compute-HeikinAshi $candles } else { $hcandles = $candles }

    # src = close series
    $src = $hcandles | ForEach-Object { [double]$_.Close }

    # compute ATR aligned
    $atrArr = Compute-ATR-Full $hcandles $atrPeriod
    if (-not $atrArr -or $atrArr.Count -eq 0) { return [PSCustomObject]@{ Buy=$false; Sell=$false; BarBuy=$false; BarSell=$false; TrailingStops=@(); Pos=@() } }

    $n = $src.Count
    $trail = New-Object System.Collections.Generic.List[double]
    $posSeries = New-Object System.Collections.Generic.List[int]

    for ($i = 0; $i -lt $n; $i++) {
        $prevTrail = if ($i -gt 0) { $trail[$i-1] } else { 0.0 }
        $prevSrc   = if ($i -gt 0) { $src[$i-1] } else { $src[$i] }

        # ATR for current bar — if null, fallback to last non-null or 0
        $atrVal = $atrArr[$i]
        if ($atrVal -eq $null) {
            # find last non-null
            for ($j = $i; $j -ge 0; $j--) {
                if ($j -lt $atrArr.Count -and $atrArr[$j] -ne $null) { $atrVal = $atrArr[$j]; break }
            }
            if ($atrVal -eq $null) { $atrVal = 0.0 }
        }
        $nLoss = $a * [double]$atrVal

        if ($i -eq 0) {
            # initialize
            $newTrail = if ($src[$i] -gt $prevTrail) { $src[$i] - $nLoss } else { $src[$i] + $nLoss }
            $trail.Add([double]$newTrail)
            $posSeries.Add(0)
            continue
        }

        if (($src[$i] -gt $prevTrail) -and ($prevSrc -gt $prevTrail)) {
            $newTrail = [Math]::Max($prevTrail, ($src[$i] - $nLoss))
        } elseif (($src[$i] -lt $prevTrail) -and ($prevSrc -lt $prevTrail)) {
            $newTrail = [Math]::Min($prevTrail, ($src[$i] + $nLoss))
        } elseif ($src[$i] -gt $prevTrail) {
            $newTrail = ($src[$i] - $nLoss)
        } else {
            $newTrail = ($src[$i] + $nLoss)
        }
        $trail.Add([double]$newTrail)

        # pos logic
        $prevPos = $posSeries[$i-1]
        if (($prevSrc -lt $prevTrail) -and ($src[$i] -gt $prevTrail)) {
            $posSeries.Add(1)
        } elseif (($prevSrc -gt $prevTrail) -and ($src[$i] -lt $prevTrail)) {
            $posSeries.Add(-1)
        } else {
            $posSeries.Add($prevPos)
        }
    }

    # compute ema(src,1) — equals src but keep using Get-EMA for consistency
    $emaArr = Get-EMA $src 1

    # get last index
    $idx = $n - 1
    $idxPrev = $n - 2

    $emaCurr = [double]$emaArr[$idx]
    $emaPrev = [double]$emaArr[$idxPrev]
    $trailCurr = [double]$trail[$idx]
    $trailPrev = [double]$trail[$idxPrev]
    $srcCurr = [double]$src[$idx]
    $srcPrev = [double]$src[$idxPrev]

    $above = ($emaPrev -lt $trailPrev) -and ($emaCurr -gt $trailCurr)
    $below = ($emaPrev -gt $trailPrev) -and ($emaCurr -lt $trailCurr)

    $buy = ($srcCurr -gt $trailCurr) -and $above
    $sell = ($srcCurr -lt $trailCurr) -and $below
    $barbuy = ($srcCurr -gt $trailCurr)
    $barsell = ($srcCurr -lt $trailCurr)

    return [PSCustomObject]@{
        Buy = [bool]$buy
        Sell = [bool]$sell
        BarBuy = [bool]$barbuy
        BarSell = [bool]$barsell
        TrailingStops = ,($trail)
        Pos = ,($posSeries)
    }
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

############## Trailing stops ######################

function Find-AttachOrdersForInst {
    param([string]$instId, $config)

    try {
        Log "Finding attach/algo orders for $instId (orders-algo-pending)" "DEBUG"
        $reqPath = "/api/v5/trade/orders-algo-pending?instId=$instId"
        $resp = Send-OkxRequest -Method "GET" -RequestPath $reqPath -BodyJson "" -config $config
        if (-not $resp) { Log "No response for attach-orders query $instId" "WARN"; return @() }

        # OKX returns algo orders in resp.data; filter for TP/SL / conditional types
        if ($resp.data -and $resp.data.Count -gt 0) {
            # typical fields: algoId, algoClOrdId, algoType/ordType, tpTriggerPx, tpOrdPx, triggerPx, activePx
            $matches = $resp.data | Where-Object {
                ($_.tpTriggerPx -or $_.tpOrdPx -or $_.triggerPx -or $_.ordType -eq "conditional" -or $_.ordType -eq "oco") 
            }
            if ($matches.Count -gt 0) {
                Log "Found $($matches.Count) algo attach(s) for $instId" "DEBUG"
                if ($DebugMode) { ($matches | ConvertTo-Json -Depth 6) | Write-Host }
                return $matches
            } else {
                Log "No TP/SL-like algo attaches in orders-algo-pending for $instId" "DEBUG"
                if ($DebugMode) { ($resp.data | ConvertTo-Json -Depth 5) | Write-Host }
            }
        } else {
            Log "orders-algo-pending returned empty data for $instId" "DEBUG"
        }
    } catch {
        Log "Find-AttachOrdersForInst error: $($_.Exception.Message)" "ERROR"
    }
    return @()
}

function Cancel-AttachOrders {
    param([array]$algoItems, [string]$instId, $config)
    # algoItems - array of objects: prefer algoId, fallback to algoClOrdId/attachAlgoClOrdId
    if (-not $algoItems -or $algoItems.Count -eq 0) { return $false }

    # Build payload for cancel-algos (expects array of { "algoId": "...", "instId":"..." } or similar)
    $payload = @()
    foreach ($it in $algoItems) {
        $obj = @{}
        if ($it.algoId) { $obj.algoId = $it.algoId }
        elseif ($it.algoClOrdId) { $obj.algoClOrdId = $it.algoClOrdId }
        elseif ($it.attachAlgoClOrdId) { $obj.algoClOrdId = $it.attachAlgoClOrdId }
        else { continue }
        $obj.instId = $instId
        $payload += $obj
    }
    if ($payload.Count -eq 0) { Log "No usable algo identifiers to cancel for $instId" "DEBUG"; return $false }

    $body = ($payload | ConvertTo-Json -Compress)
    Log "Attempting cancel-algos for $instId payload: $body" "DEBUG"

    # Try cancel-algos first (covers conditional TP/SL). If fails or API returns error for trailing, try cancel-advance-algos.
    try {
        $resp = Send-OkxRequest -Method "POST" -RequestPath "/api/v5/trade/cancel-algos" -BodyJson $body -config $config
        if ($resp -and ($resp.code -eq "0" -or -not $resp.code)) {
            Log "Cancel-algos response OK for $instId" "OK"
            if ($DebugMode) { ($resp | ConvertTo-Json -Depth 6) | Write-Host }
            return $true
        } else {
            Log "Cancel-algos returned non-ok (will try cancel-advance-algos): $($resp | ConvertTo-Json -Depth 4)" "WARN"
        }
    } catch {
        Log "cancel-algos call failed: $($_.Exception.Message)" "WARN"
    }

    # fallback: cancel-advance-algos (covers Trailing Stop and other advanced algos)
    try {
        $resp2 = Send-OkxRequest -Method "POST" -RequestPath "/api/v5/trade/cancel-advance-algos" -BodyJson $body -config $config
        if ($resp2 -and ($resp2.code -eq "0" -or -not $resp2.code)) {
            Log "Cancel-advance-algos OK for $instId" "OK"
            if ($DebugMode) { ($resp2 | ConvertTo-Json -Depth 6) | Write-Host }
            return $true
        } else {
            Log "Cancel-advance-algos returned non-ok: $($resp2 | ConvertTo-Json -Depth 4)" "WARN"
            return $false
        }
    } catch {
        Log "cancel-advance-algos call failed: $($_.Exception.Message)" "ERROR"
        return $false
    }
}

function Create-TrailingAttachForPosition {
    param(
        [string]$instId,
        [string]$side,            # "buy" or "sell" (closing side)
        [decimal]$tpPrice,       # activation price (use existing TP)
        [string]$sz,             # size string
        $config,
        [decimal]$deviationPct = 0.5
    )

    # OKX expects callbackRatio as fraction: 0.01 = 1%. So convert percent -> fraction.
    $callbackRatio = [decimal]($deviationPct / 100.0)
    $callbackRatio = [math]::Round($callbackRatio, 6)

    # ordType for trailing: move_order_stop
    $attachId = "trail" + [guid]::NewGuid().ToString("N").Substring(0,12)

    # Prepare body for POST /api/v5/trade/order-algo
    $algoBody = @{
        instId = $instId
        tdMode = if ($config.mgnMode) { $config.mgnMode } else { "isolated" }
        side   = $side
        ordType = "move_order_stop"
        sz = ([string]$sz)
        callbackRatio = ([string]$callbackRatio)
        activePx = ([string]$tpPrice)   # price to activate trailing (use TP)
        algoClOrdId = $attachId
    }

    # add posSide if contract + posMode hedged
    if ($config.posMode) {
        $pm = $config.posMode.ToString().ToLower()
        if ($pm -like "*long*" -or $pm -like "*long_short*") {
            $algoBody.posSide = if ($side -eq "sell") { "short" } else { "long" }
        }
    }

    $body = $algoBody | ConvertTo-Json -Compress
    Log "Creating trailing-attach (order-algo) for $instId body: $body" "DEBUG"

    try {
        $resp = Send-OkxRequest -Method "POST" -RequestPath "/api/v5/trade/order-algo" -BodyJson $body -config $config
        if (-not $resp) {
            Log "Create trailing attach: no response" "ERROR"
            return $false
        }
        # success code is "0" or resp.data may contain algoId
        if ($resp.code -and $resp.code -ne "0") {
            Log "Place algo (trailing) returned code=$($resp.code) msg=$($resp.msg)" "ERROR"
            if ($DebugMode) { ($resp | ConvertTo-Json -Depth 6) | Write-Host }
            return $false
        } else {
            Log "Placed trailing algo (order-algo) OK for $instId" "OK"
            if ($DebugMode) { ($resp | ConvertTo-Json -Depth 6) | Write-Host }
            return $true
        }
    } catch {
        Log "Create-TrailingAttachForPosition exception: $($_.Exception.Message)" "ERROR"
        return $false
    }
}

function Convert-TpToTrailingForPosition {
    param([psobject]$position, $config)

    # позиция приходит из /account/positions: содержит instId, pos, side/hold, avgPx и т.п.
    $instId = $position.instId
    $posAmt = [decimal]$position.pos
    if ($posAmt -eq 0) { return }

    Log "Converting TP->Trailing for position $instId pos=$posAmt" "INFO"

    # 1) Найти attach/algo ордера, относящиеся к этому инструменту (best-effort)
    $attachOrders = Find-AttachOrdersForInst -instId $instId -config $config
    if (-not $attachOrders -or $attachOrders.Count -eq 0) {
        Log "No attach/algo orders found for $instId (nothing to convert)" "DEBUG"
        return
    }

    # 2) Отфильтруем те, которые выглядят как TP (имеют tpTriggerPx / tpOrdPx / attachAlgoClOrdId начин. с tpsl)
    $tpAlgos = $attachOrders | Where-Object {
        ($_.tpTriggerPx -or $_.tpOrdPx) -or ($_.attachAlgoClOrdId -and $_.attachAlgoClOrdId -match "^tpsl")
    }
    if (-not $tpAlgos -or $tpAlgos.Count -eq 0) {
        Log "No obvious TP attach orders found for $instId" "DEBUG"
        return
    }

    # подготовка списка algoClOrdIds для отмены и извлечение TP цен
    $algoIds = @()
    $tpPrices = @()
    foreach ($a in $tpAlgos) {
        if ($a.attachAlgoClOrdId) { $algoIds += $a.attachAlgoClOrdId }
        if ($a.tpTriggerPx) { $tpPrices += [decimal]$a.tpTriggerPx }
        elseif ($a.tpOrdPx) { $tpPrices += [decimal]$a.tpOrdPx }
        elseif ($a.triggerPx) { $tpPrices += [decimal]$a.triggerPx }
    }

    if ($algoIds.Count -eq 0) {
        Log "No algoClOrdIds to cancel for $instId" "DEBUG"
        return
    }

    # 3) Отменяем найденные attach algos
    $cancelOk = Cancel-AttachOrders -algoClOrdIds $algoIds -instId $instId -config $config
    if (-not $cancelOk) {
        Log "Failed to cancel existing attach orders for $instId; aborting conversion" "WARN"
        return
    }

    # 4) Создаём trailing-attach. Возьмём активацию из первого найденного TP
    $tpPrice = if ($tpPrices.Count -gt 0) { $tpPrices[0] } else { 
        Log "No TP price found in attach; using current market price as trigger" "WARN"
        $p = Get-Price -instId $instId -config $config
        if ($p) { $p } else { Log "Cannot get price for $instId, aborting trailing attach creation" "ERROR"; return }
    }

    # определим направление — если позиция положительная -> long (для закрытия трейлинг должен быть sell)
    $sideForTrailing = if ($posAmt -gt 0) { "sell" } else { "buy" }

    # размер — используем absolute value из позиции (или можно использовать saved sz), переводим в строку
    $sz = [string][math]::Abs([decimal]$position.pos)

    $deviation = if ($null -ne $config.tp_to_trailing_deviation_pct) { [decimal]$config.tp_to_trailing_deviation_pct } else { 0.5 }

    $createOk = Create-TrailingAttachForPosition -instId $instId -side $sideForTrailing -tpPrice $tpPrice -sz $sz -config $config -deviationPct $deviation
    if ($createOk) {
        Log "Converted TP -> Trailing for $instId (trigger=$tpPrice, deviation=${deviation}%)" "OK"
    } else {
        Log "Failed to create trailing attach for $instId after cancelling TP attach" "ERROR"
    }
}

function Convert-OpenPositionsToTrailing {
    param($config)

    if (-not $config.convert_existing_tps) {
        Log "convert_existing_tps disabled in config; skipping conversion pass" "DEBUG"
        return
    }
    if (-not $authOk) {
        Log "Auth not OK; skipping open positions convert pass" "WARN"
        return
    }

    Log "Running convert-existing-TPs pass..." "INFO"
    try {
        $positionsResp = Send-OkxRequest -Method "GET" -RequestPath "/api/v5/account/positions" -BodyJson "" -config $config
        if (-not $positionsResp -or -not $positionsResp.data) {
            Log "No positions response or empty data" "DEBUG"
            return
        }

        foreach ($p in $positionsResp.data) {
            if ($p.pos -ne 0) {
                Convert-TpToTrailingForPosition -position $p -config $config
            }
        }
    } catch {
        Log "Convert-OpenPositionsToTrailing exception: $($_.Exception.Message)" "ERROR"
    }
}


# ---------------- main ----------------

$config = Get-Content $configPath -Raw | ConvertFrom-Json

# normalize/ensure some config defaults (including shorts support)
$tp_atr_multiplier = if ($null -ne $config.tp_atr_multiplier) { [decimal]$config.tp_atr_multiplier } else { 1.0 }
$sl_atr_multiplier = if ($null -ne $config.sl_atr_multiplier) { [decimal]$config.sl_atr_multiplier } else { 1.0 }

# RSI thresholds (for long use *_max, for short use *_min). Provide sensible defaults.
$rsi6_max       = if ($null -ne $config.rsi6_max)  { [decimal]$config.rsi6_max }  else { 75 }
$rsi14_max      = if ($null -ne $config.rsi14_max) { [decimal]$config.rsi14_max } else { 70 }
$rsi30_max      = if ($null -ne $config.rsi30_max) { [decimal]$config.rsi30_max } else { 60 }

$rsi6_min       = if ($null -ne $config.rsi6_min)  { [decimal]$config.rsi6_min }  else { 25 }
$rsi14_min      = if ($null -ne $config.rsi14_min) { [decimal]$config.rsi14_min } else { 30 }
$rsi30_min      = if ($null -ne $config.rsi30_min) { [decimal]$config.rsi30_min } else { 40 }

$allow_shorts = if ($null -ne $config.allow_shorts) { [bool]$config.allow_shorts } else { $false }

$configMasked = @{ api_key = Mask($config.api_key); secret_key = Mask($config.secret_key); passphrase = Mask($config.passphrase); position_size_usd = $config.position_size_usd; leverage = $config.leverage; baseUrl = $config.baseUrl; instruments = $config.instruments; take_profit_pct = $config.take_profit_pct; tp_exec_market = $config.tp_exec_market; dryRun = $config.dryRun; allow_shorts = $allow_shorts }
Log "Loaded config: $($configMasked | ConvertTo-Json -Depth 5)" "DEBUG"

if (-not $config.api_key -or -not $config.secret_key -or -not $config.passphrase) { Log "api_key / secret_key / passphrase must be provided in config file" "ERROR"; exit 1 }
if (-not $config.instruments -or $config.instruments.Count -eq 0) { Log "No instruments provided in config -> 'instruments' array" "ERROR"; exit 1 }

# UT Bot options
$use_ut_bot = if ($null -ne $config.use_ut_bot) { [bool]$config.use_ut_bot } else { $false }
$ut_a = if ($null -ne $config.ut_a) { [decimal]$config.ut_a } else { 1.0 }
$ut_atr_period = if ($null -ne $config.ut_atr_period) { [int]$config.ut_atr_period } else { 10 }
$ut_heikin = if ($null -ne $config.ut_heikin) { [bool]$config.ut_heikin } else { $false }


# ---------------- auth & time ----------------
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


# ---------------- loop instruments ----------------
function Run-Bot {
    foreach ($instId in $config.instruments) {
        Write-Host "`n=== Processing $instId ===" -ForegroundColor White

        Start-Sleep -Seconds $config.rerun_interval_s
        
        # проверка уже открытых позиций
        if ($authOk) {
            $positionsResp = Send-OkxRequest -Method "GET" -RequestPath "/api/v5/account/positions?instId=$instId" -BodyJson "" -config $config
            if ($positionsResp -and $positionsResp.data -and $positionsResp.data.Count -gt 0) {
                $openPos = $positionsResp.data | Where-Object { $_.pos -ne 0 }
                if ($openPos.Count -gt 0) {
                    Log "Открытая позиция уже существует для $instId, пропускаем" "WARN"
                    continue
                }
            }
        }

        $price = Get-Price -instId $instId -config $config
            Write-Output "Текущая цена: $price" 
        
        ############ TRADE CONDITIONS CALCULATION ############
        $candles = Get-Candles $instId $candle_limit $candle_period
        Write-Output "Получено $($candles.Count) свечей для $instId по таймфрейму $candle_period"
        if ($candles.Count -lt 2) { continue }   # минимум 2 свечи

        # закрытия свечей
        $closes = $candles | ForEach-Object { $_.Close }

        # массив закрытий без последней свечи
        $closes_prev = $closes[0..($closes.Count - 2)]

        # расчет RSI
        $rsi6Arr       = Get-RSI $closes 6
        $rsi6Arr_prev  = Get-RSI $closes_prev 6

        # RSI последней и предпоследней свечи
        $rsi6Curr = $rsi6Arr[-1]
        $rsi6Prev = $rsi6Arr_prev[-1]

        Write-Output "RSI6: prev=$rsi6Prev, curr=$rsi6Curr"

        # ===== RSI LIVE (с учётом текущей цены) =====
        $closes_live = $closes + $price    # добавляем текущую цену неформировавшейся свечи
        $rsi6Arr_live = Get-RSI $closes_live 6
        $rsi6Live = $rsi6Arr_live[-1]

        Write-Output "RSI6 Live = $rsi6Live"

        # ===== ATR =====
        $atrArr = Get-ATR $candles $atrPeriod
        if ($atrArr.Count -eq 0) { continue }
        $atr = $atrArr[-1]
        Write-Output "ATR($atrPeriod): $atr"
        $atr_pct = ($atr / $price) * 100
        Write-Output "ATR%: $([math]::Round($atr_pct, 4)) %"

        # ===== TradingView UT Bot signals (optional) =====
        if ($use_ut_bot) {
            $ut = Get-UTSignals -candles $candles -a $ut_a -atrPeriod $ut_atr_period -useHeikin $ut_heikin
            Write-Output "UT signals: Buy=$($ut.Buy) Sell=$($ut.Sell) BarBuy=$($ut.BarBuy) BarSell=$($ut.BarSell)"
            # Use UT signals as trade signals
            $longSignal = $ut.Buy
            $shortSignal = $ut.Sell
        } else {
            # ===== ТРЕЙД-СИГНАЛЫ (исходно по 3x RSI check) =====
            $longSignal =
                ($rsi6Prev -lt $rsi6_min) -and
                ($rsi6Curr -lt $rsi6_min) -and
                ($rsi6Live -lt $rsi6_min)

            $shortSignal =
                ($rsi6Prev -gt $rsi6_max) -and
                ($rsi6Curr -gt $rsi6_max) -and
                ($rsi6Live -gt $rsi6_max)
        }

        # FIXED: удален дублирующий блок который обращался к $ut.Buy без проверки $null
        # Сигналы уже вычислены выше в блоке if ($use_ut_bot) / else

        if (-not $longSignal -and -not ($shortSignal -and $allow_shorts)) {
            Log "No trading signal for $instId — skipping" "WARN"
            continue
        }

        ##########################################################

        # проверка уже открытых позиций
        if ($authOk) {
            $positionsResp = Send-OkxRequest -Method "GET" -RequestPath "/api/v5/account/positions?instId=$instId" -BodyJson "" -config $config
            if ($positionsResp -and $positionsResp.data -and $positionsResp.data.Count -gt 0) {
                $openPos = $positionsResp.data | Where-Object { $_.pos -ne 0 }
                if ($openPos.Count -gt 0) {
                    Log "Открытая позиция уже существует для $instId, пропускаем" "WARN"
                    continue
                }
            }
        }
        
        if ($null -eq $price) { Log "Skipping $instId — price not available" "WARN"; continue }

        $info = Get-InstrumentInfo -instId $instId -config $config
        $contractMode = $false; $ctVal = $null; $step = $null; $tick = $null
        if ($info) {
            if ($info.ctVal) { $ctVal = [decimal]$info.ctVal; $contractMode = $true }
            if ($info.minSz) { $step = [decimal]$info.minSz } elseif ($info.lotSz) { $step = [decimal]$info.lotSz } elseif ($info.sz) { $step = [decimal]$info.sz }
            if ($info.tickSz) { $tick = [decimal]$info.tickSz }
            Log "Instrument meta: ctVal=$ctVal, step/minSz=$step, tickSz=$tick" "DEBUG"
        }

        $notional_desired = [decimal]($config.position_size_usd * $config.leverage)
        Log "Desired notional = $notional_desired USD" "DEBUG"

        if ($contractMode -and $null -ne $ctVal -and $ctVal -gt 0) {
            $rawContracts = [decimal]($notional_desired / ($ctVal * $price))
            if ($null -eq $step -or $step -le 0) { $step = 1 }
            $sz = Set-ToStep -value $rawContracts -step $step
            Log "rawContracts = $rawContracts, rounded contracts sz = $sz (contract step = $step)" "DEBUG"
        } else {
            $rawSize = [decimal]($notional_desired / $price)
            if ($null -eq $step -or $step -le 0) { if ($price -gt 1000) { $step = 0.0001 } elseif ($price -lt 1) { $step = 0.01 } else { $step = 0.0001 } }
            $sz = Set-ToStep -value $rawSize -step $step
            Log "rawSize (coin qty) = $rawSize, rounded sz = $sz (coin step = $step)" "DEBUG"
        }

        if ($sz -le 0) {
            if ($config.force_min_size -and $step -gt 0) {
                if ($contractMode -and $null -ne $ctVal) { $notional_if_forced = [math]::Round(($step * $ctVal * $price), 8) } else { $notional_if_forced = [math]::Round(($step * $price), 8) }
                $threshold = $config.force_threshold_factor
                if ($notional_if_forced -gt ($notional_desired * $threshold)) { Log "Forcing minimal step would create notional $notional_if_forced USD > $threshold × desired. Skipping" "WARN"; continue }
                Log "rawSize < step; forcing sz = step ($step). forced notional = $notional_if_forced USD" "WARN"
                $sz = $step
            } else { Log "After rounding sz = 0 and force_min_size is false -> skipping $instId" "WARN"; continue }
        }

        if ($contractMode -and $null -ne $ctVal) { $notional_actual = [math]::Round(($sz * $ctVal * $price), 8) } else { $notional_actual = [math]::Round(($sz * $price), 8) }
        Log "Final: sz = $sz (step $step). notional_actual = $notional_actual USD" "INFO"

        # ---------------- apply leverage ----------------
        if ($config.set_leverage -and $config.leverage -gt 1) {
            if (-not $authOk) {
                Log "Skipping Set-IsolatedLeverage because earlier auth check failed" "WARN"
            } else {
                Log "Applying leverage $($config.leverage) for $instId" "INFO"
                # pass posSide depending on trade direction (will default to 'long' inside function)
                $posSideForLeverage = if ($longSignal) { "long" } elseif ($shortSignal) { "short" } else { "long" }
                $setResp = Set-IsolatedLeverage -instId $instId -lever $config.leverage -config $config -posSide $posSideForLeverage
                if ($null -eq $setResp) { Log "Failed to set leverage; skipping" "ERROR" } else { Log "Set-IsolatedLeverage response: $(ConvertTo-Json $setResp -Depth 5)" "INFO" }
            }
        }

        # ---------------- place market order + attach TP/SL ----------------
        $side = if ($longSignal) { "buy" } else { "sell" }
        $orderObj = @{ instId = $instId; tdMode = $config.mgnMode; side = $side; ordType = "market"; sz = ([string]$sz) }

        if ($contractMode -and $null -ne $posMode) {
            $pm = $posMode.ToString().ToLower()
            if ($pm -like "*long*" -or $pm -like "*long_short*") { $orderObj.posSide = if ($side -eq "buy") { "long" } else { "short" }; Log "posMode=$posMode -> adding posSide='$($orderObj.posSide)' to order" "DEBUG" }
        } elseif ($contractMode) { $orderObj.posSide = if ($side -eq "buy") { "long" } else { "short" }; Log "posMode unknown -> adding posSide for contract (conservative)" "DEBUG" }

        # ---------------- calculate TP & SL ----------------
        $tpPct = $atr_pct * $tp_atr_multiplier / 100
            write-Output "Take Profit % based on ATR: $([math]::Round($tpPct * 100, 4)) %"
        $slPct = $atr_pct * $sl_atr_multiplier / 100
            write-Output "Stop Loss % based on ATR: $([math]::Round($slPct * 100, 4)) %"
        $estimatedEntry = $price

        if ($side -eq "buy") {
            # Long: TP above, SL below
            $tpTriggerRaw = [decimal]($estimatedEntry * (1 + $tpPct))
            $slTriggerRaw = [decimal]($estimatedEntry * (1 - $slPct))
        } else {
            # Short: TP below entry, SL above entry
            $tpTriggerRaw = [decimal]($estimatedEntry * (1 - $tpPct))
            $slTriggerRaw = [decimal]($estimatedEntry * (1 + $slPct))
        }

        if ($null -ne $tick -and $tick -gt 0) { $tpTrigger = RoundPriceToTick -price $tpTriggerRaw -tick $tick } else { $tpTrigger = [math]::Round($tpTriggerRaw, 8) }
        if ($null -ne $tick -and $tick -gt 0) { $slTrigger = RoundPriceToTick -price $slTriggerRaw -tick $tick } else { $slTrigger = [math]::Round($slTriggerRaw, 8) }

        $attachId = "tpsl" + [guid]::NewGuid().ToString("N").Substring(0,12)
        $attachObj = @{
            attachAlgoClOrdId = $attachId
            tpTriggerPx        = ([string]$tpTrigger)
            tpTriggerPxType    = $config.tp_trigger_type
            tpOrdPx            = if ($config.tp_exec_market) { "-1" } else { ([string]$tpTrigger) }
            slTriggerPx        = ([string]$slTrigger)
            slTriggerPxType    = $config.tp_trigger_type
            slOrdPx            = if ($config.tp_exec_market) { "-1" } else { ([string]$slTrigger) }
            sz                 = ([string]$sz)
        }

        $orderObj.attachAlgoOrds = @($attachObj)

        $orderJson = $orderObj | ConvertTo-Json -Depth 10 -Compress
        Log "Open order with attachAlgoOrds (TP+SL): $orderJson" "DEBUG"

        if (-not $authOk) { Log "Auth check earlier failed. Will not place real orders. (Use -ForceLive to override if you know what you're doing)" "WARN"; continue }

        #-------- Сделка --------
        $resp = Send-OkxRequest -Method "POST" -RequestPath "/api/v5/trade/order" -BodyJson $orderJson -config $config
        if ($resp -and $resp.dryRun) {
            Log "DRY RUN — order preview (attached TP+SL shown in preview)" "WARN"
            ($resp | ConvertTo-Json -Depth 6) | Write-Host
        } elseif ($null -eq $resp) {
            Log "Order failed or empty response" "ERROR"
            continue
        } else {
            Log "Order response:" "OK"
            ($resp | ConvertTo-Json -Depth 8) | Write-Host
        }
    }

    Log "Done." "OK"
}

while ($true) {
    Convert-OpenPositionsToTrailing -config $config
    Run-Bot
}
