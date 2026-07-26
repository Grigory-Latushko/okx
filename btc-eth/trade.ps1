# BTC-ETH CORRELATION LAG STRATEGY
#
# Идея: BTC и ETH коррелируют, но ETH реагирует с задержкой.
# Когда BTC сделал значительный ход, а ETH ещё не догнал —
# открываем позицию по ETH в направлении BTC.
# ETH обычно догоняет и немного обгоняет BTC.
#
# Состояния:
# [1] Нет позиции → измеряем gap → если gap > порога → открываем ETH
# [2] Позиция открыта → мониторим TP/SL → управляем

param(
  [string]$ConfigPath = ".\config.json",
  [switch]$ForceLive,
  [switch]$DebugMode
)

if (-not $global:candleCache) { $global:candleCache = @{} }

# ---------------- helpers ----------------
function Get-Timestamp { return [int][double]::Parse((Get-Date -UFormat %s)) }
function Log { param([string]$msg, [string]$level = "INFO") switch ($level.ToUpper()) { "INFO"  { Write-Host "[INFO ] $msg" -ForegroundColor Gray } "OK"    { Write-Host "[ OK  ] $msg" -ForegroundColor Green } "WARN"  { Write-Host "[WARN ] $msg" -ForegroundColor Yellow } "ERROR" { Write-Host "[ERR  ] $msg" -ForegroundColor Red } "DEBUG" { if ($DebugMode) { Write-Host "[DBG  ] $msg" -ForegroundColor Cyan } } } }
function Get-NowTimestamp { (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ") }

function Set-OkxRequest {
    param($Secret, $Timestamp, $Method, $RequestPath, $Body)
    if ($null -eq $Body) { $Body = "" }
    $prehash = "$Timestamp$Method$RequestPath$Body"
    $hmac    = New-Object System.Security.Cryptography.HMACSHA256
    $hmac.Key = [System.Text.Encoding]::UTF8.GetBytes($Secret)
    return [Convert]::ToBase64String($hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($prehash)))
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
    if ($config.dryRun -and -not $ForceLive -and $Method.ToUpper() -eq "POST") {
        Log "DryRun -- POST: $RequestPath" "WARN"
        return @{ dryRun = $true; body = $BodyJson }
    }
    try {
        if ($Method.ToUpper() -eq "GET") { $resp = Invoke-RestMethod -Method Get  -Uri $url -Headers $headers -ErrorAction Stop }
        else                             { $resp = Invoke-RestMethod -Method Post -Uri $url -Headers $headers -Body $BodyJson -ErrorAction Stop }
        if ($DebugMode) { Log "Response:`n$($resp | ConvertTo-Json -Depth 6)" "DEBUG" }
        return $resp
    } catch {
        Log "Request failed: $Method $url -- $($_.Exception.Message)" "ERROR"
        if ($_.Exception.Response) { try { $r = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream()); Log "Body: $($r.ReadToEnd())" "DEBUG" } catch {} }
        return $null
    }
}

function Get-Ticker {
    param($instId, $config)
    $resp = Send-OkxRequest -Method "GET" -RequestPath "/api/v5/market/ticker?instId=$instId" -BodyJson "" -config $config
    if ($resp -and $resp.data -and $resp.data.Count -ge 1) { return $resp.data[0] }
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
    return [decimal]$([math]::Round([double]([math]::Floor(($value / $step) + 0.0000000001) * $step), 8))
}

function RoundPriceToTick {
    param($price, $tick)
    if ($tick -eq 0 -or $null -eq $tick) { return [math]::Round($price, 8) }
    return [decimal]$([math]::Round([double]([math]::Round([math]::Round($price / $tick, 8)) * $tick), 8))
}

function Get-AccountConfig {
    param($config)
    $resp = Send-OkxRequest -Method "GET" -RequestPath "/api/v5/account/config" -BodyJson "" -config $config
    if ($resp -and $resp.data -and $resp.data.Count -ge 1) {
        $d = $resp.data[0]
        if ($d.psMode) { return $d.psMode } if ($d.posMode) { return $d.posMode } if ($d.positionMode) { return $d.positionMode }
    }
    return $null
}

function Get-OpenPosition {
    param([string]$instId, $config)
    $resp = Send-OkxRequest -Method "GET" -RequestPath "/api/v5/account/positions?instId=$instId" -BodyJson "" -config $config
    if (-not $resp -or -not $resp.data) { return $null }
    foreach ($p in $resp.data) { if ([decimal]$p.pos -ne 0) { return $p } }
    return $null
}

function Get-ActiveAlgoOrders {
    param([string]$instId, $config, [string]$ordType)
    $resp = Send-OkxRequest -Method "GET" -RequestPath "/api/v5/trade/orders-algo-pending?instId=$instId&ordType=$ordType&instType=SWAP" -BodyJson "" -config $config
    if (-not $resp -or -not $resp.data) { return @() }
    return $resp.data
}

function Cancel-AlgoOrders {
    param([array]$algos, [string]$instId, $config)
    if (-not $algos -or $algos.Count -eq 0) { return }
    $payload = @($algos | ForEach-Object { @{ instId = $instId; algoId = $_.algoId } })
    $body = ConvertTo-Json $payload -Compress
    if ($body -notmatch '^\[') { $body = "[$body]" }
    $resp = Send-OkxRequest -Method "POST" -RequestPath "/api/v5/trade/cancel-algos" -BodyJson $body -config $config
    if ($resp -and ($resp.dryRun -or $resp.code -eq "0")) { Log "Algo otmeneny dlya $instId" "OK" }
    else { Log "Oshibka otmeny: $($resp.msg)" "ERROR" }
}

# ---------------- свечи ----------------
function Get-Candles {
    param($symbol, $limit, $period)
    $key = "$symbol-$period-$limit"
    if ($global:candleCache.ContainsKey($key)) {
        $c = $global:candleCache[$key]
        if ((Get-Timestamp) - $c.Timestamp -lt 30) { return $c.Candles }
    }
    try {
        $url = "https://www.okx.com/api/v5/market/candles?instId=$symbol&bar=$period&limit=$limit"
        $res = Invoke-RestMethod -Uri $url -Method Get
        if (-not $res.data) { return @() }
        $candles = $res.data | ForEach-Object {
            [PSCustomObject]@{ Timestamp=[long]($_[0])/1000; Open=[double]$_[1]; High=[double]$_[2]; Low=[double]$_[3]; Close=[double]$_[4] }
        } | Sort-Object Timestamp
        $global:candleCache[$key] = @{ Candles=$candles; Timestamp=Get-Timestamp }
        return $candles
    } catch { Log "Oshibka svechej $symbol : $_" "ERROR"; return @() }
}

# ---------------- ключевая функция: расчёт корреляционного gap ----------------
function Get-CorrelationSignal {
    param($config)

    $btcId = $config.btc_instrument
    $ethId = $config.eth_instrument
    $period = $config.candle_period
    $lookback = [int]$config.lookback_candles
    $limit = $lookback + 5

    $btcCandles = Get-Candles $btcId $limit $period
    $ethCandles = Get-Candles $ethId $limit $period

    if ($btcCandles.Count -lt ($lookback + 1) -or $ethCandles.Count -lt ($lookback + 1)) {
        Log "Nedostatochno svechej" "WARN"; return $null
    }

    # Цена N свечей назад и сейчас
    $btcPriceNow  = [decimal]$btcCandles[-1].Close
    $btcPriceBack = [decimal]$btcCandles[-($lookback+1)].Close
    $ethPriceNow  = [decimal]$ethCandles[-1].Close
    $ethPriceBack = [decimal]$ethCandles[-($lookback+1)].Close

    if ($btcPriceBack -eq 0 -or $ethPriceBack -eq 0) { return $null }

    $btcReturn = [math]::Round((($btcPriceNow - $btcPriceBack) / $btcPriceBack) * 100, 4)
    $ethReturn = [math]::Round((($ethPriceNow - $ethPriceBack) / $ethPriceBack) * 100, 4)
    $gap       = [math]::Round($btcReturn - $ethReturn, 4)

    # Доп. проверка: насколько свежий ход BTC (не старый тренд)
    # Смотрим что произошло в последней трети периода
    $recentLookback  = [math]::Max(1, [int]($lookback / 3))
    $btcPriceRecent  = [decimal]$btcCandles[-($recentLookback+1)].Close
    $ethPriceRecent  = [decimal]$ethCandles[-($recentLookback+1)].Close
    $btcReturnRecent = [math]::Round((($btcPriceNow - $btcPriceRecent) / $btcPriceRecent) * 100, 4)
    $ethReturnRecent = [math]::Round((($ethPriceNow - $ethPriceRecent) / $ethPriceRecent) * 100, 4)
    $gapRecent       = [math]::Round($btcReturnRecent - $ethReturnRecent, 4)

    return @{
        btcPriceNow    = $btcPriceNow
        ethPriceNow    = $ethPriceNow
        btcReturn      = $btcReturn
        ethReturn      = $ethReturn
        gap            = $gap           # полный период
        gapRecent      = $gapRecent     # последняя треть (свежесть хода)
        btcReturnRecent = $btcReturnRecent
        ethReturnRecent = $ethReturnRecent
    }
}

# ---------------- логирование ----------------
function Write-TradeLog {
    param([string]$event, [string]$side, [decimal]$ethPrice, [decimal]$btcReturn, [decimal]$ethReturn, [decimal]$gap, [decimal]$sz, [decimal]$tp, [decimal]$sl, [decimal]$pnl = 0, [decimal]$pnlPct = 0, [string]$detail = "", $config)
    $logFile = if ($config.log_file) { $config.log_file } else { ".\trades.csv" }
    if (-not (Test-Path $logFile)) {
        "timestamp,event,side,eth_price,btc_return,eth_return,gap,sz,tp,sl,pnl,pnl_pct,detail`n" | Out-File -FilePath $logFile -Encoding utf8 -NoNewline
    }
    $ts = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ss")
    "$ts,$event,$side,$ethPrice,$btcReturn,$ethReturn,$gap,$sz,$tp,$sl,$pnl,$pnlPct,$detail`n" | Out-File -FilePath $logFile -Encoding utf8 -Append -NoNewline
}

# ---------------- постановка TP/SL ----------------
function Place-TPSL {
    param([string]$instId, [string]$side, [decimal]$entryPx, [decimal]$sz, [decimal]$tpPct, [decimal]$slPct, $info, $config)
    $tick   = if ($info -and $info.tickSz) { [decimal]$info.tickSz } else { $null }
    $tpType = if ($config.tp_trigger_type) { $config.tp_trigger_type } else { "last" }
    $szStr  = [string]$sz

    if ($side -eq "LONG") {
        $tpPrice = RoundPriceToTick -price ([decimal]($entryPx * (1 + $tpPct / 100))) -tick $tick
        $slPrice = RoundPriceToTick -price ([decimal]($entryPx * (1 - $slPct / 100))) -tick $tick
    } else {
        $tpPrice = RoundPriceToTick -price ([decimal]($entryPx * (1 - $tpPct / 100))) -tick $tick
        $slPrice = RoundPriceToTick -price ([decimal]($entryPx * (1 + $slPct / 100))) -tick $tick
    }
    $closeSide = if ($side -eq "LONG") { "sell" } else { "buy" }

    Write-Host "  >> TP=$tpPrice (+$([math]::Round($tpPct,2))%) SL=$slPrice (-$([math]::Round($slPct,2))%)" -ForegroundColor Yellow

    $rTp = Send-OkxRequest -Method "POST" -RequestPath "/api/v5/trade/order-algo" -BodyJson (@{ instId=$instId; tdMode=$config.mgnMode; side=$closeSide; ordType="conditional"; sz=$szStr; tpTriggerPx=[string]$tpPrice; tpTriggerPxType=$tpType; tpOrdPx="-1" } | ConvertTo-Json -Compress) -config $config
    if ($rTp -and $rTp.code -eq "0") { Log "OK: TP @ $tpPrice" "OK" } elseif ($rTp -and $rTp.dryRun) { Log "DryRun: TP @ $tpPrice" "WARN" } else { Log "ERR TP: $($rTp.msg)" "ERROR" }

    $rSl = Send-OkxRequest -Method "POST" -RequestPath "/api/v5/trade/order-algo" -BodyJson (@{ instId=$instId; tdMode=$config.mgnMode; side=$closeSide; ordType="conditional"; sz=$szStr; slTriggerPx=[string]$slPrice; slTriggerPxType=$tpType; slOrdPx="-1" } | ConvertTo-Json -Compress) -config $config
    if ($rSl -and $rSl.code -eq "0") { Log "OK: SL @ $slPrice" "OK" } elseif ($rSl -and $rSl.dryRun) { Log "DryRun: SL @ $slPrice" "WARN" } else { Log "ERR SL: $($rSl.msg)" "ERROR" }

    return @{ tp = $tpPrice; sl = $slPrice }
}

# ======================== MAIN ========================
$config = Get-Content $configPath -Raw | ConvertFrom-Json

foreach ($field in @("api_key","secret_key","passphrase","btc_instrument","eth_instrument")) {
    if (-not $config.$field) { Log "Config: otsutstvuet '$field'" "ERROR"; exit 1 }
}

try {
    $tr = Send-OkxRequest -Method "GET" -RequestPath "/api/v5/public/time" -BodyJson "" -config $config
    if ($tr -and $tr.data) {
        $delta = [math]::Abs(([datetime]::Parse($tr.data[0].iso).ToUniversalTime() - (Get-Date).ToUniversalTime()).TotalSeconds)
        if ($delta -gt 30) { Log "Clock drift >30s -- sync NTP!" "WARN" }
    }
} catch {}

$authOk = $true
$balResp = Send-OkxRequest -Method "GET" -RequestPath "/api/v5/account/balance" -BodyJson "" -config $config
if ($null -eq $balResp) { $authOk = $false; Log "Auth failed" "WARN" } else { Log "Auth OK" "DEBUG" }

$posMode = $null
if ($authOk) { $posMode = Get-AccountConfig -config $config }

$script:ethInfo   = $null
$script:prevEthPos = $null

function Run-Bot {
    Write-Host "`n========== BTC-ETH CORRELATION ==========" -ForegroundColor Magenta
    if (-not $authOk) { Log "Auth ne proshel" "WARN"; return }

    $ethId = $config.eth_instrument
    $btcId = $config.btc_instrument

    # Кэшируем инфо об инструменте
    if (-not $script:ethInfo) { $script:ethInfo = Get-InstrumentInfo -instId $ethId -config $config }
    $info = $script:ethInfo

    # Текущая позиция по ETH
    $openPos = Get-OpenPosition -instId $ethId -config $config
    $hasPos  = $null -ne $openPos

    # Считаем correlation signal всегда — нужен для отображения
    $signal = Get-CorrelationSignal -config $config

    if (-not $signal) { Log "Signal calculation failed" "WARN"; return }

    $btcReturn      = $signal.btcReturn
    $ethReturn      = $signal.ethReturn
    $gap            = $signal.gap
    $gapRecent      = $signal.gapRecent
    $btcPriceNow    = $signal.btcPriceNow
    $ethPriceNow    = $signal.ethPriceNow

    # Отображаем текущий gap
    $gapColor = if ([math]::Abs($gap) -ge [decimal]$config.min_gap_pct) { 'Cyan' } else { 'Gray' }
    Write-Host ("`n  BTC {0,7:F2}%  ETH {1,7:F2}%  GAP {2,7:F2}%  (recent BTC {3,6:F2}% ETH {4,6:F2}%)" -f $btcReturn, $ethReturn, $gap, $signal.btcReturnRecent, $signal.ethReturnRecent) -ForegroundColor $gapColor

    # === Дetekciya zakrytiya pozicii ===
    if ($script:prevEthPos -and -not $hasPos) {
        $entryPx = [decimal]$script:prevEthPos.avgPx
        $ticker  = Get-Ticker -instId $ethId -config $config
        $closePx = if ($ticker) { [decimal]$ticker.last } else { $entryPx }
        $posAmt  = [math]::Abs([decimal]$script:prevEthPos.pos)
        $ctVal   = if ($info -and $info.ctVal) { [decimal]$info.ctVal } else { 1 }
        $isLong  = [decimal]$script:prevEthPos.pos -gt 0
        $pnlPct  = [math]::Round((($closePx - $entryPx) / $entryPx) * 100 * $(if ($isLong) { 1 } else { -1 }), 2)
        $pnl     = [math]::Round(($closePx - $entryPx) * $posAmt * $ctVal * $(if ($isLong) { 1 } else { -1 }), 4)
        $reason  = if ($pnlPct -gt 0) { "TP" } else { "SL" }
        Write-Host ("  CLOSED ETH {0} | entry={1} close={2} P&L={3}% ({4}) -> {5}" -f (if($isLong){"LONG"}else{"SHORT"}), $entryPx, $closePx, $pnlPct, $pnl, $reason) -ForegroundColor $(if ($pnlPct -gt 0) { 'Green' } else { 'Red' })
        Write-TradeLog -event "CLOSED" -side (if($isLong){"LONG"}else{"SHORT"}) -ethPrice $closePx -btcReturn $btcReturn -ethReturn $ethReturn -gap $gap -sz $posAmt -tp 0 -sl 0 -pnl $pnl -pnlPct $pnlPct -detail $reason -config $config
        # Отменяем зависшие ордера
        foreach ($ordType in @("conditional", "move_order_stop")) {
            $orphans = Get-ActiveAlgoOrders -instId $ethId -config $config -ordType $ordType
            if ($orphans.Count -gt 0) {
                Log "Otmenyaem $($orphans.Count) $ordType" "WARN"
                Cancel-AlgoOrders -algos $orphans -instId $ethId -config $config
            }
        }
    }
    $script:prevEthPos = $openPos

    # === Есть открытая позиция ===
    if ($hasPos) {
        $entryPx   = [decimal]$openPos.avgPx
        $posAmt    = [math]::Abs([decimal]$openPos.pos)
        $isLong    = [decimal]$openPos.pos -gt 0
        $pnlPct    = [math]::Round((($ethPriceNow - $entryPx) / $entryPx) * 100 * $(if ($isLong) { 1 } else { -1 }), 2)

        # Count-based дetekciya TP/SL как в buy-the-dip-trail
        $condOrders = Get-ActiveAlgoOrders -instId $ethId -config $config -ordType "conditional"
        $condCount  = $condOrders.Count
        $hasTP      = $condCount -ge 1
        $hasSL      = $condCount -ge 2

        $ordStatus = if ($hasTP -and $hasSL) { "[TP/SL]" } elseif ($hasTP) { "[TP only]" } else { "[NO ORDERS]" }
        $posLabel  = if ($isLong) { "LONG" } else { "SHORT" }
        Write-Host ("  ETH {0} open | entry={1} now={2} P&L={3}% {4}" -f $posLabel, $entryPx, $ethPriceNow, $pnlPct, $ordStatus) -ForegroundColor $(if ($pnlPct -ge 0) { 'Green' } else { 'Red' })
        Write-Host ("  Gap now: BTC {0:F2}% ETH {1:F2}% gap={2:F2}% (entry gap stored in log)" -f $btcReturn, $ethReturn, $gap) -ForegroundColor Gray

        # Восстанавливаем TP/SL если пропали
        if (-not $hasTP -and -not $hasSL) {
            Log "Net TP i SL -- vosstanavlivaem" "WARN"
            if ($config.tp_pct -ne $null) {
                $tpPct = [decimal]$config.tp_pct
            } else {
                $tpMultiplier = [decimal]$config.tp_gap_multiplier
                $remainingGap = [math]::Abs($gap)
                $tpPct = [math]::Round($remainingGap * $tpMultiplier, 4)
                $tpPct = [math]::Max($tpPct, [decimal]$config.min_tp_pct)
                $tpPct = [math]::Min($tpPct, [decimal]$config.max_tp_pct)
            }
            $slPct = [decimal]$config.sl_pct
            Place-TPSL -instId $ethId -side $posLabel -entryPx $entryPx -sz $posAmt -tpPct $tpPct -slPct $slPct -info $info -config $config | Out-Null
        } elseif (-not $hasSL) {
            Log "Net SL -- vosstanavlivaem" "WARN"
            $tick    = if ($info -and $info.tickSz) { [decimal]$info.tickSz } else { $null }
            $slPct   = [decimal]$config.sl_pct / 100
            $slPrice = if ($isLong) { RoundPriceToTick -price ([decimal]($entryPx * (1 - $slPct))) -tick $tick }
                       else         { RoundPriceToTick -price ([decimal]($entryPx * (1 + $slPct))) -tick $tick }
            $closeSide = if ($isLong) { "sell" } else { "buy" }
            $tpType    = if ($config.tp_trigger_type) { $config.tp_trigger_type } else { "last" }
            $r = Send-OkxRequest -Method "POST" -RequestPath "/api/v5/trade/order-algo" -BodyJson (@{ instId=$ethId; tdMode=$config.mgnMode; side=$closeSide; ordType="conditional"; sz=([string]$posAmt); slTriggerPx=[string]$slPrice; slTriggerPxType=$tpType; slOrdPx="-1" } | ConvertTo-Json -Compress) -config $config
            if ($r -and $r.code -eq "0") { Log "OK: SL @ $slPrice" "OK" } else { Log "ERR SL: $($r.msg)" "ERROR" }
        }
        return
    }

    # === Нет позиции: проверяем сигнал ===
    $minGap    = [decimal]$config.min_gap_pct
    $maxGap    = [decimal]$config.max_gap_pct
    $minBtcMove = [decimal]$config.min_btc_move_pct  # BTC должен сам по себе сделать минимальный ход
    $absGap    = [math]::Abs($gap)
    $absGapRec = [math]::Abs($gapRecent)

    # Проверка условий входа
    $longSignal  = $gap -ge $minGap -and $absGap -le $maxGap `
                   -and [math]::Abs($btcReturn) -ge $minBtcMove `
                   -and $gapRecent -ge ($minGap * 0.5)  # ход должен быть свежим

    $shortSignal = $gap -le -$minGap -and $absGap -le $maxGap `
                   -and [math]::Abs($btcReturn) -ge $minBtcMove `
                   -and $gapRecent -le -($minGap * 0.5) `
                   -and [bool]$config.allow_shorts

    if (-not $longSignal -and -not $shortSignal) {
        $status = if ($absGap -lt $minGap) { "gap slishkom malen ($absGap% < $minGap%)" }
                  elseif ($absGap -gt $maxGap) { "gap slishkom velik ($absGap% > $maxGap%)" }
                  elseif ([math]::Abs($btcReturn) -lt $minBtcMove) { "BTC dvizheniye slaboe ($([math]::Abs($btcReturn))% < $minBtcMove%)" }
                  else { "gap ne podtverzhdyon poslednim periodom (recent=$gapRecent%)" }
        Log "Net signala: $status" "DEBUG"
        return
    }

    $side    = if ($longSignal) { "LONG" } else { "SHORT" }
    $openSide = if ($longSignal) { "buy" } else { "sell" }

    Write-Host "  >> SIGNAL: ETH $side | BTC=$btcReturn% ETH=$ethReturn% GAP=$gap%" -ForegroundColor $(if ($longSignal) { 'Green' } else { 'Red' })

    # Динамический TP: ETH догоняет BTC и немного обгоняет
    # tp_gap_multiplier > 1.0 означает ожидаемый перелёт
    $tpMultiplier = [decimal]$config.tp_gap_multiplier
    $remainingGap = [math]::Abs($gap)  # сколько ETH нужно ещё пройти
    $tpPct = [math]::Round($remainingGap * $tpMultiplier, 4)
    $tpPct = [math]::Max($tpPct, [decimal]$config.min_tp_pct)  # минимальный TP
    $tpPct = [math]::Min($tpPct, [decimal]$config.max_tp_pct)  # максимальный TP
    $slPct = [decimal]$config.sl_pct

    Write-Host ("  >> Dynamic TP={0}% (gap={1}% x {2}) SL={3}%" -f $tpPct, $remainingGap, $tpMultiplier, $slPct) -ForegroundColor Yellow

    # Размер позиции
    $ctVal  = if ($info -and $info.ctVal) { [decimal]$info.ctVal } else { 1 }
    $minSz  = if ($info -and $info.minSz) { [decimal]$info.minSz } elseif ($info -and $info.lotSz) { [decimal]$info.lotSz } else { 0.01 }
    $step   = $minSz
    $notional = [decimal]($config.position_size_usd * $config.leverage)
    $sz = Set-ToStep -value ([decimal]($notional / ($ctVal * $ethPriceNow))) -step $step
    if ($sz -le 0 -or $sz -lt $minSz) { $sz = $minSz }

    # Плечо
    $pm = $posMode
    $levBody = @{ instId=$ethId; lever=([string]$config.leverage); mgnMode="isolated" }
    if ($pm -and ($pm.ToString().ToLower() -match "long_short|hedge")) { $levBody.posSide = if ($longSignal) { "long" } else { "short" } }
    Send-OkxRequest -Method "POST" -RequestPath "/api/v5/account/set-leverage" -BodyJson ($levBody | ConvertTo-Json -Compress) -config $config | Out-Null

    # Открываем ордер
    $order = @{ instId=$ethId; tdMode=$config.mgnMode; side=$openSide; ordType="market"; sz=([string]$sz) }
    if ($pm -and ($pm.ToString().ToLower() -match "long_short|hedge")) { $order.posSide = if ($longSignal) { "long" } else { "short" } }
    $resp = Send-OkxRequest -Method "POST" -RequestPath "/api/v5/trade/order" -BodyJson ($order | ConvertTo-Json -Compress) -config $config

    if ($resp -and $resp.dryRun) {
        Log "DryRun: ETH $side $sz @ $ethPriceNow" "WARN"
    } elseif (-not $resp -or ($resp.code -and $resp.code -ne "0")) {
        Log "ERR open ETH: $($resp.msg)" "ERROR"; return
    } else {
        Log "OK: ETH $side opened $sz @ $ethPriceNow" "OK"
    }

    # Ставим TP/SL
    $tpsl = Place-TPSL -instId $ethId -side $side -entryPx $ethPriceNow -sz $sz -tpPct $tpPct -slPct $slPct -info $info -config $config
    Write-TradeLog -event "OPEN" -side $side -ethPrice $ethPriceNow -btcReturn $btcReturn -ethReturn $ethReturn -gap $gap -sz $sz -tp $tpsl.tp -sl $tpsl.sl -config $config
}

# ======================== LOOP ========================
while ($true) {

    Run-Bot

    # Баланс
    $b = Send-OkxRequest -Method "GET" -RequestPath "/api/v5/account/balance" -BodyJson "" -config $config
    if ($b -and $b.code -eq "0") {
        $acc=$b.data[0]; $usdt=$acc.details|Where-Object{$_.ccy -eq "USDT"}
        Write-Host "`n  BALANCE: $($acc.totalEq) USDT $(if ($usdt) { '| Available: ' + $usdt.availBal })" -ForegroundColor Cyan
    }

    Start-Sleep -Seconds $config.rerun_interval_s
}
