# MARGIN 06 — Pair Trading: BTC LONG + ETH SHORT
# Одновременно открывает два ордера на одинаковую сумму:
#   - LONG BTC-USDT-SWAP
#   - SHORT ETH-USDT-SWAP
# TP = 2x ATR, SL = 1x ATR для каждого инструмента независимо
# Новая пара открывается только при отсутствии позиций по обоим инструментам

param(
  [string]$ConfigPath = ".\config_60m.json",
  [switch]$ForceLive,
  [switch]$DebugMode
)

if (-not $global:candleCache) { $global:candleCache = @{} }

# ---------------- helpers ----------------
function Get-Timestamp { return [int][double]::Parse((Get-Date -UFormat %s)) }
function Format-Time { return (Get-Date -Format "yyyy-MM-dd HH:mm:ss") }
function LogConsole($msg, $type = "INFO") { $ts = Format-Time; Write-Host "[$ts][$type] $msg" }
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
    return [Convert]::ToBase64String($hash)
}

function Send-OkxRequest {
    param([string]$Method, [string]$RequestPath, [string]$BodyJson, $config)
    $ts  = Get-NowTimestamp
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
    Log "Request: $Method $url" "DEBUG"
    Log "Body: $BodyJson" "DEBUG"
    if ($config.dryRun -and -not $ForceLive) { Log "DryRun — запрос не отправлен" "WARN"; return @{ dryRun = $true; method = $Method; url = $url; body = $BodyJson } }
    try {
        if ($Method.ToUpper() -eq "GET") { $resp = Invoke-RestMethod -Method Get  -Uri $url -Headers $headers -ErrorAction Stop }
        else                             { $resp = Invoke-RestMethod -Method Post -Uri $url -Headers $headers -Body $BodyJson -ErrorAction Stop }
        if ($DebugMode) { Log "Response:`n$($resp | ConvertTo-Json -Depth 8)" "DEBUG" }
        return $resp
    } catch {
        Log "Request failed: $Method $url — $($_.Exception.Message)" "ERROR"
        if ($_.Exception.Response) { try { $r = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream()); Log "Response: $($r.ReadToEnd())" "DEBUG" } catch {} }
        return $null
    }
}

function Get-Price {
    param($instId, $config)
    $resp = Send-OkxRequest -Method "GET" -RequestPath "/api/v5/market/ticker?instId=$instId" -BodyJson "" -config $config
    if (-not $resp -or ($resp.code -and $resp.code -ne "0")) { Log "Нет цены для $instId" "WARN"; return $null }
    if ($resp.data -and $resp.data.Count -ge 1) { return [decimal]$resp.data[0].last }
    return $null
}

function Get-InstrumentInfo {
    param($instId, $config)
    $resp = Send-OkxRequest -Method "GET" -RequestPath "/api/v5/public/instruments?instType=SWAP&instId=$instId" -BodyJson "" -config $config
    if ($resp -and $resp.data -and $resp.data.Count -ge 1) { return $resp.data[0] }
    return $null
}

function Set-ToStep {
    param($value, $step)
    if ($step -eq 0 -or $null -eq $step) { return [math]::Round($value, 8) }
    $q = [math]::Floor(($value / $step) + 0.0000000001)
    return [decimal]$([math]::Round([double]($q * $step), 8))
}

function RoundPriceToTick {
    param($price, $tick)
    if ($tick -eq 0 -or $null -eq $tick) { return [math]::Round($price, 8) }
    $q = [math]::Round($price / $tick, 8)
    return [decimal]$([math]::Round([double]([math]::Round($q) * $tick), 8))
}

function Get-AccountConfig {
    param($config)
    $resp = Send-OkxRequest -Method "GET" -RequestPath "/api/v5/account/config" -BodyJson "" -config $config
    if ($resp -and $resp.data -and $resp.data.Count -ge 1) {
        $d = $resp.data[0]
        if ($d.psMode) { return $d.psMode }
        if ($d.posMode) { return $d.posMode }
        if ($d.positionMode) { return $d.positionMode }
    }
    return $null
}

function Get-ActiveAlgoOrders {
    param([string]$instId, $config, [string]$ordType = "")
    $path = if ($ordType) { "/api/v5/trade/orders-algo-pending?instId=$instId&ordType=$ordType" } else { "/api/v5/trade/orders-algo-pending?instId=$instId" }
    $resp = Send-OkxRequest -Method "GET" -RequestPath $path -BodyJson "" -config $config
    return $resp.data
}

# ---------------- вычисление размера позиции ----------------
function Get-PositionSize {
    param([string]$instId, $config, [string]$posSide = "long")
    $info  = Get-InstrumentInfo -instId $instId -config $config
    $price = Get-Price -instId $instId -config $config
    if (-not $info -or -not $price) { Log "Не удалось получить info/price для $instId" "ERROR"; return $null }

    $ctVal  = if ($info.ctVal) { [decimal]$info.ctVal } else { 1 }
    $minSz  = if ($info.minSz) { [decimal]$info.minSz } elseif ($info.lotSz) { [decimal]$info.lotSz } else { 0.01 }
    $step   = if ($info.minSz) { [decimal]$info.minSz } elseif ($info.lotSz) { [decimal]$info.lotSz } else { 1 }
    if ($step -le 0) { $step = 1 }

    $notional = [decimal]($config.position_size_usd * $config.leverage)
    $sz = Set-ToStep -value ([decimal]($notional / ($ctVal * $price))) -step $step
    if ($sz -le 0) { $sz = $step }
    if ($sz -lt $minSz) { $sz = $minSz }

    # выставляем плечо
    $pm = $script:posMode
    $bodyObj = @{ instId = $instId; lever = ([string]$config.leverage); mgnMode = "isolated" }
    if ($pm -and ($pm.ToString().ToLower() -match "long_short|hedge")) { $bodyObj.posSide = $posSide }
    $resp = Send-OkxRequest -Method "POST" -RequestPath "/api/v5/account/set-leverage" -BodyJson ($bodyObj | ConvertTo-Json -Compress) -config $config
    if ($resp -and -not $resp.dryRun -and $resp.code -ne "0") { Log "set-leverage error for $instId`: $($resp.msg)" "ERROR"; return $null }

    return @{ sz = $sz; info = $info; price = $price }
}

# ---------------- индикаторы ----------------
function Get-Candles($symbol, $limit, $period) {
    $key = "$symbol-$period-$limit"
    if ($global:candleCache.ContainsKey($key)) {
        $c = $global:candleCache[$key]
        if ((Get-Timestamp) - $c.Timestamp -lt 60) { return $c.Candles }
    }
    try {
        $url = "https://www.okx.com/api/v5/market/candles?instId=$symbol&bar=$period&limit=$limit"
        $res = Invoke-RestMethod -Uri $url -Method Get
        if (-not $res.data) { return @() }
        $candles = $res.data | ForEach-Object {
            [PSCustomObject]@{ Timestamp=[long]($_[0])/1000; Open=[double]$_[1]; High=[double]$_[2]; Low=[double]$_[3]; Close=[double]$_[4]; Volume=[double]$_[5] }
        } | Sort-Object Timestamp
        $global:candleCache[$key] = @{ Candles = $candles; Timestamp = Get-Timestamp }
        return $candles
    } catch { LogConsole "Ошибка свечей $symbol`: $_" "ERROR"; return @() }
}

function Get-ATR($candles, $period) {
    if (-not $candles -or $candles.Count -le $period) { return @() }
    $trs = @()
    for ($i = 1; $i -lt $candles.Count; $i++) {
        $trs += [Math]::Max($candles[$i].High - $candles[$i].Low,
                 [Math]::Max([Math]::Abs($candles[$i].High - $candles[$i-1].Close),
                             [Math]::Abs($candles[$i].Low  - $candles[$i-1].Close)))
    }
    if ($trs.Count -lt $period) { return @() }
    $atr = @(($trs[0..($period-1)] | Measure-Object -Sum).Sum / $period)
    $k = 2.0 / ($period + 1)
    for ($i = $period; $i -lt $trs.Count; $i++) { $atr += $trs[$i] * $k + $atr[-1] * (1 - $k) }
    return $atr
}

# ---------------- проверка позиции ----------------
function Get-OpenPosition {
    param([string]$instId, $config)
    $resp = Send-OkxRequest -Method "GET" -RequestPath "/api/v5/account/positions?instId=$instId" -BodyJson "" -config $config
    if (-not $resp -or -not $resp.data) { return $null }
    foreach ($p in $resp.data) {
        $info = Get-InstrumentInfo -instId $instId -config $config
        if (-not $info) { continue }
        $ctVal = if ($info.ctVal) { [decimal]$info.ctVal } else { 1 }
        $pos = [decimal]$p.pos / $ctVal
        if ($pos -ne 0) { return @{ pos = $pos; data = $p } }
    }
    return $null
}

# ---------------- управление трейлинг-стопами ----------------
function Manage-TrailingStops {
    param([string]$instId, $openPos, $atr, $price, $config)

    $posData   = $openPos.data
    $posSize   = $openPos.pos
    $entryPx   = [decimal]$posData.avgPx
    $currentPx = [decimal]$price
    $atrDec    = [decimal]$atr
    $info      = Get-InstrumentInfo -instId $instId -config $config

    $isLong    = $posSize -gt 0
    $profit    = if ($isLong) { $currentPx - $entryPx } else { $entryPx - $currentPx }
    $profitPct = [math]::Round(($profit / $entryPx) * 100, 2)

    $side = if ($isLong) { "🟢 LONG" } else { "🔴 SHORT" }
    Write-Output "$side $instId | Entry=$entryPx | Now=$currentPx | P&L=$profitPct%"

    $trailingOrders = Get-ActiveAlgoOrders -instId $instId -config $config -ordType "move_order_stop"
    if ($trailingOrders.Count -gt 0) {
        Write-Output "  ✔️ Трейлинг активен ($($trailingOrders.Count) ордеров)"
        return
    }

    $ctVal     = if ($info.ctVal) { [decimal]$info.ctVal } else { 1 }
    $szApi     = [string][math]::Abs([math]::Round($posSize * $ctVal, 8))
    $closeSide = if ($isLong) { "sell" } else { "buy" }

    # TP trailing: активируется при достижении 2x ATR прибыли
    $tpActivation = if ($isLong) { $entryPx + ([decimal]$config.tp_atr_multiplier * $atrDec) } else { $entryPx - ([decimal]$config.tp_atr_multiplier * $atrDec) }

    if (($isLong -and $currentPx -ge $tpActivation) -or (-not $isLong -and $currentPx -le $tpActivation)) {
        Write-Output "  🎯 TP достигнут! Ставим трейлинг (profit=$profitPct%)"
        $callbackRatio = [string][math]::Round(([decimal]$config.callback_atr_multiplier * $atrDec) / $currentPx, 6)
        $resp = Send-OkxRequest -Method "POST" -RequestPath "/api/v5/trade/order-algo" -BodyJson (@{
            instId=$instId; tdMode=$config.mgnMode; side=$closeSide
            ordType="move_order_stop"; sz=$szApi; callbackRatio=$callbackRatio
        } | ConvertTo-Json -Compress) -config $config
        if ($resp.code -eq "0") { Log "  TP trailing placed для $instId" "OK" }
        else { Log "  Ошибка TP trailing: $($resp.msg)" "ERROR" }
        return
    }

    # SL: активируется при убытке 1x ATR
    if ($profit -le -([decimal]$config.sl_atr_multiplier * $atrDec)) {
        Write-Output "  ❌ SL сработал! Ставим трейлинг (profit=$profitPct%)"
        $callbackRatio = [string][math]::Round(([decimal]$config.callback_sl_atr_multiplier * $atrDec) / $currentPx, 6)
        $resp = Send-OkxRequest -Method "POST" -RequestPath "/api/v5/trade/order-algo" -BodyJson (@{
            instId=$instId; tdMode=$config.mgnMode; side=$closeSide
            ordType="move_order_stop"; sz=$szApi; callbackRatio=$callbackRatio; reduceOnly=$true
        } | ConvertTo-Json -Compress) -config $config
        if ($resp.code -eq "0") { Log "  SL trailing placed для $instId" "OK" }
        else { Log "  Ошибка SL trailing: $($resp.msg)" "ERROR" }
    }
}

# ---------------- открытие пары ордеров ----------------
function Open-PairOrders {
    param($config)

    $btcId = $config.btc_instrument
    $ethId = $config.eth_instrument

    Write-Host "`n🔄 Открываем пару: LONG $btcId + SHORT $ethId" -ForegroundColor Cyan

    $btcData = Get-PositionSize -instId $btcId -config $config -posSide "long"
    $ethData = Get-PositionSize -instId $ethId -config $config -posSide "short"
    if (-not $btcData -or -not $ethData) { Log "Не удалось вычислить размеры — отмена" "ERROR"; return $false }

    $btcCandles = Get-Candles $btcId $config.candle_limit $config.candle_period
    $ethCandles = Get-Candles $ethId $config.candle_limit $config.candle_period
    if ($btcCandles.Count -lt 2 -or $ethCandles.Count -lt 2) { Log "Недостаточно свечей" "WARN"; return $false }

    $btcAtrArr = Get-ATR $btcCandles $config.atrPeriod
    $ethAtrArr = Get-ATR $ethCandles $config.atrPeriod
    if ($btcAtrArr.Count -eq 0 -or $ethAtrArr.Count -eq 0) { Log "Ошибка ATR" "WARN"; return $false }

    $btcAtr   = [decimal]$btcAtrArr[-1];  $ethAtr   = [decimal]$ethAtrArr[-1]
    $btcPrice = $btcData.price;           $ethPrice = $ethData.price
    $btcInfo  = $btcData.info;            $ethInfo  = $ethData.info
    $tpMult   = [decimal]$config.tp_atr_multiplier
    $slMult   = [decimal]$config.sl_atr_multiplier

    $btcTick = if ($btcInfo.tickSz) { [decimal]$btcInfo.tickSz } else { $null }
    $ethTick = if ($ethInfo.tickSz) { [decimal]$ethInfo.tickSz } else { $null }

    $btcTp = RoundPriceToTick -price ([decimal]($btcPrice + ($tpMult * $btcAtr))) -tick $btcTick
    $btcSl = RoundPriceToTick -price ([decimal]($btcPrice - ($slMult * $btcAtr))) -tick $btcTick
    $ethTp = RoundPriceToTick -price ([decimal]($ethPrice - ($tpMult * $ethAtr))) -tick $ethTick  # SHORT: TP ниже
    $ethSl = RoundPriceToTick -price ([decimal]($ethPrice + ($slMult * $ethAtr))) -tick $ethTick  # SHORT: SL выше

    $btcSz = [string]$btcData.sz;  $ethSz = [string]$ethData.sz

    Write-Output "  BTC: LONG  $btcSz @ $btcPrice | TP=$btcTp SL=$btcSl ATR=$btcAtr"
    Write-Output "  ETH: SHORT $ethSz @ $ethPrice | TP=$ethTp SL=$ethSl ATR=$ethAtr"

    $tpTriggerType = if ($config.tp_trigger_type) { $config.tp_trigger_type } else { "last" }
    $tpExecMarket  = if ($null -ne $config.tp_exec_market) { [bool]$config.tp_exec_market } else { $true }
    $tpOrdPx       = if ($tpExecMarket) { "-1" } else { $null }

    # === LONG BTC ===
    $btcOrder = @{
        instId = $btcId; tdMode = $config.mgnMode; side = "buy"; ordType = "market"; sz = $btcSz
        attachAlgoOrds = @(@{
            attachAlgoClOrdId = "tpsl" + [guid]::NewGuid().ToString("N").Substring(0,12)
            tpTriggerPx = [string]$btcTp; tpTriggerPxType = $tpTriggerType; tpOrdPx = if ($tpOrdPx) { $tpOrdPx } else { [string]$btcTp }
            slTriggerPx = [string]$btcSl; slTriggerPxType = $tpTriggerType; slOrdPx = if ($tpOrdPx) { $tpOrdPx } else { [string]$btcSl }
            sz = $btcSz
        })
    }
    $respBtc = Send-OkxRequest -Method "POST" -RequestPath "/api/v5/trade/order" -BodyJson ($btcOrder | ConvertTo-Json -Depth 10 -Compress) -config $config
    if     ($respBtc -and $respBtc.dryRun)                                      { Log "DryRun: BTC LONG" "WARN" }
    elseif (-not $respBtc -or ($respBtc.code -and $respBtc.code -ne "0"))       { Log "❌ Ошибка BTC LONG: $($respBtc.msg)" "ERROR"; return $false }
    else                                                                          { Log "✅ BTC LONG открыт" "OK" }

    # === SHORT ETH ===
    $ethOrder = @{
        instId = $ethId; tdMode = $config.mgnMode; side = "sell"; ordType = "market"; sz = $ethSz
        attachAlgoOrds = @(@{
            attachAlgoClOrdId = "tpsl" + [guid]::NewGuid().ToString("N").Substring(0,12)
            tpTriggerPx = [string]$ethTp; tpTriggerPxType = $tpTriggerType; tpOrdPx = if ($tpOrdPx) { $tpOrdPx } else { [string]$ethTp }
            slTriggerPx = [string]$ethSl; slTriggerPxType = $tpTriggerType; slOrdPx = if ($tpOrdPx) { $tpOrdPx } else { [string]$ethSl }
            sz = $ethSz
        })
    }
    $respEth = Send-OkxRequest -Method "POST" -RequestPath "/api/v5/trade/order" -BodyJson ($ethOrder | ConvertTo-Json -Depth 10 -Compress) -config $config
    if     ($respEth -and $respEth.dryRun)                                      { Log "DryRun: ETH SHORT" "WARN" }
    elseif (-not $respEth -or ($respEth.code -and $respEth.code -ne "0"))       {
        Log "❌ Ошибка ETH SHORT: $($respEth.msg)" "ERROR"
        Log "⚠️  BTC LONG открыт, ETH SHORT не открылся — закройте BTC вручную!" "WARN"
        return $false
    } else { Log "✅ ETH SHORT открыт" "OK" }

    return $true
}

# ======================== MAIN ========================
$config = Get-Content $configPath -Raw | ConvertFrom-Json

foreach ($field in @("api_key","secret_key","passphrase","btc_instrument","eth_instrument")) {
    if (-not $config.$field) { Log "Конфиг: отсутствует поле '$field'" "ERROR"; exit 1 }
}

try {
    $timeResp = Send-OkxRequest -Method "GET" -RequestPath "/api/v5/public/time" -BodyJson "" -config $config
    if ($timeResp -and $timeResp.data) {
        $delta = [math]::Abs(([datetime]::Parse($timeResp.data[0].iso).ToUniversalTime() - (Get-Date).ToUniversalTime()).TotalSeconds)
        if ($delta -gt 30) { Log "Расхождение времени >30s" "WARN" }
    }
} catch {}

$authOk = $true
$balResp = Send-OkxRequest -Method "GET" -RequestPath "/api/v5/account/balance" -BodyJson "" -config $config
if ($null -eq $balResp) { Log "Auth check failed" "WARN"; $authOk = $false } else { Log "Auth OK" "DEBUG" }

$posMode = $null
if ($authOk) { $posMode = Get-AccountConfig -config $config }

$btcId = $config.btc_instrument
$ethId = $config.eth_instrument

function Run-Bot {
    Write-Host "`n========== PAIR BOT CYCLE ==========" -ForegroundColor Magenta
    if (-not $authOk) { Log "Auth не прошёл — пропускаем цикл" "WARN"; return }

    $btcPos = Get-OpenPosition -instId $btcId -config $config
    $ethPos = Get-OpenPosition -instId $ethId -config $config
    $hasBtc = $null -ne $btcPos
    $hasEth = $null -ne $ethPos

    Write-Output "BTC: $(if ($hasBtc) { '✅ pos=' + $btcPos.pos } else { '— нет позиции' })"
    Write-Output "ETH: $(if ($hasEth) { '✅ pos=' + $ethPos.pos } else { '— нет позиции' })"

    if ($hasBtc) {
        $c = Get-Candles $btcId $config.candle_limit $config.candle_period
        $a = Get-ATR $c $config.atrPeriod
        if ($a.Count -gt 0) { Manage-TrailingStops -instId $btcId -openPos $btcPos -atr $a[-1] -price (Get-Price -instId $btcId -config $config) -config $config }
    }
    if ($hasEth) {
        $c = Get-Candles $ethId $config.candle_limit $config.candle_period
        $a = Get-ATR $c $config.atrPeriod
        if ($a.Count -gt 0) { Manage-TrailingStops -instId $ethId -openPos $ethPos -atr $a[-1] -price (Get-Price -instId $ethId -config $config) -config $config }
    }

    if (-not $hasBtc -and -not $hasEth) {
        Write-Host "`n🟡 Позиций нет — открываем пару" -ForegroundColor Yellow
        $ok = Open-PairOrders -config $config
        if ($ok) { Log "Пара открыта" "OK" } else { Log "Ошибка открытия пары" "WARN" }
    } elseif ($hasBtc -xor $hasEth) {
        Log "⚠️  Одна позиция закрыта, ждём второй..." "WARN"
    } else {
        Log "Обе позиции открыты — управляем трейлингами" "INFO"
    }

    $b = Send-OkxRequest -Method "GET" -RequestPath "/api/v5/account/balance" -BodyJson "" -config $config
    if ($b -and $b.code -eq "0") {
        $acc = $b.data[0]; $usdt = $acc.details | Where-Object { $_.ccy -eq "USDT" }
        Write-Host "`n===== BALANCE =====" -ForegroundColor Cyan
        Write-Host "Total Equity : $($acc.totalEq) USDT" -ForegroundColor White
        if ($usdt) { Write-Host "USDT Available: $($usdt.availBal)" -ForegroundColor Green; Write-Host "USDT UPL: $($usdt.upl)" -ForegroundColor Yellow }
        Write-Host "==================`n" -ForegroundColor Cyan
    }
    Log "Cycle done." "OK"
}

while ($true) { Run-Bot; Start-Sleep -Seconds $config.rerun_interval_s }
