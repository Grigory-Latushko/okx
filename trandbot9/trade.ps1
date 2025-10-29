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

function Sign-OkxRequest {
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
  $sig = Sign-OkxRequest -Secret $config.secret_key -Timestamp $ts -Method $Method.ToUpper() -RequestPath $RequestPath -Body $BodyJson

  $headers = @{
    "OK-ACCESS-KEY"        = $config.api_key
    "OK-ACCESS-SIGN"       = $sig
    "OK-ACCESS-TIMESTAMP"  = $ts
    "OK-ACCESS-PASSPHRASE" = $config.passphrase
    "Content-Type"         = "application/json"
  }
  if ($config.simulated -ne $null) { $headers["x-simulated-trading"] = if ($config.simulated) { "1" } else { "0" } }

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
function Get-Price { param($instId, $config) Log "Получаем цену для $instId" "DEBUG"; $resp = Send-OkxRequest -Method "GET" -RequestPath "/api/v5/market/ticker?instId=$($instId)" -BodyJson "" -config $config; if ($resp -and $resp.data -and $resp.data.Count -ge 1) { $p = [decimal]$resp.data[0].last; Log "Цена $instId = $p" "OK"; return $p } Log "Не удалось получить цену $instId" "WARN"; return $null }
function Get-InstrumentInfo { param($instId, $config) Log "Получаем информацию об инструменте $instId" "DEBUG"; $resp = Send-OkxRequest -Method "GET" -RequestPath "/api/v5/public/instruments?instType=SWAP&instId=$($instId)" -BodyJson "" -config $config; if ($resp -and $resp.data -and $resp.data.Count -ge 1) { return $resp.data[0] } return $null }

function Round-ToStep { param($value, $step) if ($step -eq 0 -or $null -eq $step) { return [math]::Round($value, 8) } $quotient = [math]::Floor(($value / $step) + 0.0000000001); $rounded = $quotient * $step; return [decimal]$([math]::Round([double]$rounded, 8)) }

function RoundPriceToTick { param($price, $tick) if ($tick -eq 0 -or $null -eq $tick) { return [math]::Round($price, 8) } $q = [math]::Round($price / $tick, 8); $r = [math]::Round($q) * $tick; return [decimal]$([math]::Round([double]$r, 8)) }

function Get-AccountConfig { param($config) Log "Получаем конфиг аккаунта (/api/v5/account/config)" "DEBUG"; $resp = Send-OkxRequest -Method "GET" -RequestPath "/api/v5/account/config" -BodyJson "" -config $config; if ($resp -and $resp.data -and $resp.data.Count -ge 1) { $d = $resp.data[0]; if ($d.psMode) { return $d.psMode }; if ($d.posMode) { return $d.posMode }; if ($d.positionMode) { return $d.positionMode }; return $resp.data }; return $null }

# ---------------- apply leverage (isolated) ----------------
function Set-IsolatedLeverage {
    param($instId, $lever, $config, $posSide="long")

    # Устанавливаем isolated
    $mgnMode = "isolated"
    
    # Проверяем минимальный размер позиции для leverage
    $info = Get-InstrumentInfo -instId $instId -config $config
    $price = Get-Price -instId $instId -config $config
    if (-not $info -or -not $price) { 
        Log "Cannot get instrument info or price for $instId" "ERROR"; return $null 
    }

    $ctVal = if ($info.ctVal) { [decimal]$info.ctVal } else { 1 }
    $minSz = if ($info.minSz) { [decimal]$info.minSz } else { 0.01 }
    $notional_desired = [decimal]($config.position_size_usd * $lever)
    $sz = [math]::Round($notional_desired / ($ctVal * $price), 8)
    
    if ($sz -lt $minSz) {
        Log "Position size $sz < minSz $minSz for isolated leverage. Adjusting to minSz." "WARN"
        $sz = $minSz
    }

    # Подготовка тела запроса
    $bodyObj = @{
        instId = $instId
        lever  = ([string]$lever)
        mgnMode = $mgnMode
        posSide = $posSide
    }
    $body = $bodyObj | ConvertTo-Json -Compress

    # Отправка запроса
    $resp = Send-OkxRequest -Method "POST" -RequestPath "/api/v5/account/set-leverage" -BodyJson $body -config $config
    if ($resp -and $resp.code -eq "0") {
        Log "Set-Isolated-Leverage OK: $($resp.data | ConvertTo-Json -Depth 5)" "OK"
        return $sz
    } else {
        Log "Failed to set isolated leverage for $instId" "ERROR"
        return $null
    }
}


#################### INDICATORS ####################

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
function Calculate-EMA($prices, $period) {
    if ($prices.Count -lt $period) { return @() }
    $k = 2 / ($period + 1)
    $ema = @($prices[0])
    for ($i = 1; $i -lt $prices.Count; $i++) {
        $ema += $prices[$i] * $k + $ema[$i-1] * (1 - $k)
    }
    return $ema
}

# ---------------- main ----------------
# if (-not (Test-Path $ConfigPath)) { Log "Config file not found: $ConfigPath" "ERROR"; exit 1 }
# $configRaw = Get-Content $ConfigPath -Raw
# try { $config = $configRaw | ConvertFrom-Json } catch { Log "Invalid JSON in config: $_" "ERROR"; exit 1 }

function GetconfigVal($obj, $names, $default) { foreach ($n in $names) { if ($obj.PSObject.Properties.Name -contains $n) { return $obj.$n } } return $default }

$simFlag = GetconfigVal $config @("simulated","sim","demo","simulated_trading") $null
$simBool = if ($null -ne $simFlag) { [bool]$simFlag } else { $null }

# $config = [PSCustomObject]@{
#   api_key           = GetconfigVal $config @("api_key","apiKey","apikey") $null
#   secret_key        = GetconfigVal $config @("secret_key","secretKey","secret") $null
#   passphrase        = GetconfigVal $config @("passphrase","passPhrase") $null
#   position_size_usd = [decimal](GetconfigVal $config @("position_size_usd","positionSizeUsd","position_size") 1)
#   leverage          = [decimal](GetconfigVal $config @("leverage","lev") 1)
#   set_leverage      = [bool](GetconfigVal $config @("set_leverage","setLeverage") $false)
#   mgnMode           = GetconfigVal $config @("mgnMode","mgn_mode","margin_mode") "cross"
#   dryRun            = [bool](GetconfigVal $config @("dryRun","dry_run","dry_run") $true)
#   baseUrl           = GetconfigVal $config @("baseUrl","base_url","base") "https://www.okx.com"
#   instruments       = GetconfigVal $config @("instruments","instrument_list","insts") @()
#   force_min_size    = [bool](GetconfigVal $config @("force_min_size","forceMinSize") $false)
#   force_threshold_factor = [decimal](GetconfigVal $config @("force_threshold_factor","forceThresholdFactor") 3)
#   simulated         = $simBool
#   take_profit_pct   = [decimal](GetconfigVal $config @("take_profit_pct","tp_pct") 0.01)
#   tp_trigger_type   = GetconfigVal $config @("tp_trigger_type","tpTriggerType") "last"
#   tp_exec_market    = [bool](GetconfigVal $config @("tp_exec_market","tpMarket") $true)
# }

$config = Get-Content $configPath -Raw | ConvertFrom-Json

$configMasked = @{ api_key = Mask($config.api_key); secret_key = Mask($config.secret_key); passphrase = Mask($config.passphrase); position_size_usd = $config.position_size_usd; leverage = $config.leverage; baseUrl = $config.baseUrl; instruments = $config.instruments; take_profit_pct = $config.take_profit_pct; tp_exec_market = $config.tp_exec_market; dryRun = $config.dryRun }
Log "Loaded config: $($configMasked | ConvertTo-Json -Depth 5)" "DEBUG"

if (-not $config.api_key -or -not $config.secret_key -or -not $config.passphrase) { Log "api_key / secret_key / passphrase must be provided in config file" "ERROR"; exit 1 }
if (-not $config.instruments -or $config.instruments.Count -eq 0) { Log "No instruments provided in config -> 'instruments' array" "ERROR"; exit 1 }

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

$candle_period  = $config.candle_period
$candle_limit   = $config.candle_limit

# ---------------- loop instruments ----------------
foreach ($instId in $config.instruments) {
    Write-Host "`n=== Processing $instId ===" -ForegroundColor White

    ############ TRADE CONDITIONS CALCULATION ############
    $candles = Get-Candles $instId $candle_limit $candle_period
    Write-Output "Получено $($candles.Count) свечей для $instId по таймфрейму $candle_period" "DEBUG"

    $closes = $candles | ForEach-Object { $_.Close }
#    Write-Output "Закрытия: $($closes -join ', ')" "DEBUG"
    $ema21 = Calculate-EMA $closes 21
#    Write-Output "EMA21: $($ema21 -join ', ')" "DEBUG"
    $lastEMA21     = $ema21[-1]
    Write-Output "Последняя EMA21: $lastEMA21" 
    $price = Get-Price -instId $instId -config $config
    Write-Output "Текущая цена: $price" 
    $longSignal  = ($price -gt $lastEMA21)
    Write-Output "Long signal: $longSignal" 

    if (-not $longSignal) {
        Log "No long signal for $instId — skipping" "WARN"
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
        $sz = Round-ToStep -value $rawContracts -step $step
        Log "rawContracts = $rawContracts, rounded contracts sz = $sz (contract step = $step)" "DEBUG"
    } else {
        $rawSize = [decimal]($notional_desired / $price)
        if ($null -eq $step -or $step -le 0) { if ($price -gt 1000) { $step = 0.0001 } elseif ($price -lt 1) { $step = 0.01 } else { $step = 0.0001 } }
        $sz = Round-ToStep -value $rawSize -step $step
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
            $setResp = Set-IsolatedLeverage -instId $instId -lever $config.leverage -mgnMode $config.mgnMode -config $config
            if ($null -eq $setResp) { Log "Failed to set leverage; skipping" "ERROR" } else { Log "Set-IsolatedLeverage response: $(ConvertTo-Json $setResp -Depth 5)" "INFO" }
        }
    }

# ---------------- place market order + attach TP/SL ----------------
$side = "buy"
$orderObj = @{ instId = $instId; tdMode = $config.mgnMode; side = $side; ordType = "market"; sz = ([string]$sz) }

if ($contractMode -and $null -ne $posMode) {
    $pm = $posMode.ToString().ToLower()
    if ($pm -like "*long*" -or $pm -like "*long_short*") { $orderObj.posSide = if ($side -eq "buy") { "long" } else { "short" }; Log "posMode=$posMode -> adding posSide='$($orderObj.posSide)' to order" "DEBUG" }
} elseif ($contractMode) { $orderObj.posSide = if ($side -eq "buy") { "long" } else { "short" }; Log "posMode unknown -> adding posSide for contract (conservative)" "DEBUG" }

# ---------------- calculate TP & SL ----------------
$tpPct = $config.take_profit_pct
$slPct = if ($config.PSObject.Properties.Name -contains "stop_loss_pct") { [decimal]$config.stop_loss_pct } else { 0.01 } # default 1% if not in config

$estimatedEntry = $price

# TP
$tpTriggerRaw = [decimal]($estimatedEntry * (1 + $tpPct))
if ($null -ne $tick -and $tick -gt 0) { $tpTrigger = RoundPriceToTick -price $tpTriggerRaw -tick $tick } else { $tpTrigger = [math]::Round($tpTriggerRaw, 8) }

# SL
$slTriggerRaw = [decimal]($estimatedEntry * (1 - $slPct))
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

Start-Sleep -Milliseconds 500
}

Log "Done." "OK"
