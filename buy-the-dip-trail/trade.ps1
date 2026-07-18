# BUY-THE-DIP-TRAIL — покупаем просадку с трейлингом
#
# Машина состояний для каждого инструмента:
# [1] Нет позиции, нет ордеров      → мониторим просадку → trailing BUY
# [2] Есть pending trailing BUY     → ждём исполнения
# [3] Позиция открыта, нет TP/SL   → ставим TP и SL
# [4] Позиция открыта, убыток > SL → аварийный trailing SELL
# [5] Позиция открыта, прибыль > порога → trailing SELL для фиксации

param(
  [string]$ConfigPath = ".\config.json",
  [switch]$ForceLive,
  [switch]$DebugMode
)

# ---------------- helpers ----------------
function Get-Timestamp { return [int][double]::Parse((Get-Date -UFormat %s)) }
function Format-Time   { return (Get-Date -Format "yyyy-MM-dd HH:mm:ss") }
function Mask { param([string]$s) if (-not $s) { return "" } if ($s.Length -le 8) { return $s.Substring(0,2) + "..." } return $s.Substring(0,4) + "..." + $s.Substring($s.Length-4,4) }
function Log  { param([string]$msg, [string]$level = "INFO") switch ($level.ToUpper()) { "INFO"  { Write-Host "[INFO ] $msg" -ForegroundColor Gray } "OK"    { Write-Host "[ OK  ] $msg" -ForegroundColor Green } "WARN"  { Write-Host "[WARN ] $msg" -ForegroundColor Yellow } "ERROR" { Write-Host "[ERR  ] $msg" -ForegroundColor Red } "DEBUG" { if ($DebugMode) { Write-Host "[DBG  ] $msg" -ForegroundColor Cyan } } } }
function Get-NowTimestamp { (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ") }

function Set-OkxRequest {
    param($Secret, $Timestamp, $Method, $RequestPath, $Body)
    if ($null -eq $Body) { $Body = "" }
    $prehash = "$Timestamp$Method$RequestPath$Body"
    $hmac    = New-Object System.Security.Cryptography.HMACSHA256
    $hmac.Key = [System.Text.Encoding]::UTF8.GetBytes($Secret)
    $hash    = $hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($prehash))
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
    if ($config.dryRun -and -not $ForceLive -and $Method.ToUpper() -eq "POST") {
        Log "DryRun -- POST ne otpravlen: $RequestPath" "WARN"
        return @{ dryRun = $true; method = $Method; url = $url; body = $BodyJson }
    }
    try {
        if ($Method.ToUpper() -eq "GET") { $resp = Invoke-RestMethod -Method Get  -Uri $url -Headers $headers -ErrorAction Stop }
        else                             { $resp = Invoke-RestMethod -Method Post -Uri $url -Headers $headers -Body $BodyJson -ErrorAction Stop }
        if ($DebugMode) { Log "Response:`n$($resp | ConvertTo-Json -Depth 8)" "DEBUG" }
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
    if (-not $resp -or ($resp.code -and $resp.code -ne "0")) { Log "Net tikkera dlya $instId" "WARN"; return $null }
    if ($resp.data -and $resp.data.Count -ge 1) { return $resp.data[0] }
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
    return [decimal]$([math]::Round([double]([math]::Round([math]::Round($price / $tick, 8)) * $tick), 8))
}

function Get-AccountConfig {
    param($config)
    $resp = Send-OkxRequest -Method "GET" -RequestPath "/api/v5/account/config" -BodyJson "" -config $config
    if ($resp -and $resp.data -and $resp.data.Count -ge 1) {
        $d = $resp.data[0]
        if ($d.psMode)       { return $d.psMode }
        if ($d.posMode)      { return $d.posMode }
        if ($d.positionMode) { return $d.positionMode }
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

# FIX: dobavlen instType=SWAP -- reshaet 400 Bad Request dlya nekotorykh instrumentov
function Get-ActiveAlgoOrders {
    param([string]$instId, $config, [string]$ordType)
    $resp = Send-OkxRequest -Method "GET" -RequestPath "/api/v5/trade/orders-algo-pending?instId=$instId&ordType=$ordType&instType=SWAP" -BodyJson "" -config $config
    if (-not $resp -or -not $resp.data) { return @() }
    return $resp.data
}

function Cancel-AlgoOrders {
    param([array]$algos, [string]$instId, $config)
    if (-not $algos -or $algos.Count -eq 0) { return }
    # FIX: @() garantiruet massiv dazhe pri odnom elemente
    $payload = @($algos | ForEach-Object { @{ instId = $instId; algoId = $_.algoId } })
    $body = ConvertTo-Json $payload -Compress
    if ($body -notmatch '^\[') { $body = "[$body]" }
    $resp = Send-OkxRequest -Method "POST" -RequestPath "/api/v5/trade/cancel-algos" -BodyJson $body -config $config
    if ($resp -and ($resp.dryRun -or $resp.code -eq "0")) { Log "Algo otmeneny" "OK" }
    else { Log "Oshibka otmeny algo: $($resp.msg)" "ERROR" }
}

# ---------------- logirovanie ----------------
function Write-TradeLog {
    param(
        [string]$event,
        [string]$instId,
        [string]$side,
        [decimal]$price,
        [decimal]$sz      = 0,
        [decimal]$dipPct  = 0,
        [decimal]$pnl     = 0,
        [decimal]$pnlPct  = 0,
        [string]$detail   = "",
        $config
    )
    $logFile = if ($config.log_file) { $config.log_file } else { ".\trades.csv" }
    if (-not (Test-Path $logFile)) {
        "timestamp,event,instId,side,price,sz,dip_pct,pnl,pnl_pct,detail`n" | Out-File -FilePath $logFile -Encoding utf8 -NoNewline
    }
    $ts = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ss")
    "$ts,$event,$instId,$side,$price,$sz,$dipPct,$pnl,$pnlPct,$detail`n" | Out-File -FilePath $logFile -Encoding utf8 -Append -NoNewline
    Log "LOG: $event $instId @ $price | $detail" "OK"
}

# ---------------- razmer pozicii ----------------
function Get-PositionSz {
    param([string]$instId, [decimal]$price, $info, $config, [string]$posSide = "long")
    $ctVal = if ($info.ctVal) { [decimal]$info.ctVal } else { 1 }
    $minSz = if ($info.minSz) { [decimal]$info.minSz } elseif ($info.lotSz) { [decimal]$info.lotSz } else { 0.01 }
    $step  = $minSz
    $notional = [decimal]($config.position_size_usd * $config.leverage)
    $sz = Set-ToStep -value ([decimal]($notional / ($ctVal * $price))) -step $step
    if ($sz -le 0 -or $sz -lt $minSz) { $sz = $minSz }
    $pm = $script:posMode
    $levBody = @{ instId=$instId; lever=([string]$config.leverage); mgnMode="isolated" }
    if ($pm -and ($pm.ToString().ToLower() -match "long_short|hedge")) { $levBody.posSide = $posSide }
    Send-OkxRequest -Method "POST" -RequestPath "/api/v5/account/set-leverage" -BodyJson ($levBody | ConvertTo-Json -Compress) -config $config | Out-Null
    return $sz
}

# ======================== SOSTOYANIYA ========================

function Place-TrailingBuy {
    param([string]$instId, [decimal]$price, [decimal]$dropPct, $info, $config)
    $sz = Get-PositionSz -instId $instId -price $price -info $info -config $config -posSide "long"
    $callbackRatio = [string][math]::Round([decimal]$config.entry_trail_callback_pct / 100, 6)
    Write-Host "  >> Trailing BUY $instId | drop=$dropPct% | callback=$($config.entry_trail_callback_pct)% | sz=$sz" -ForegroundColor Cyan
    $body = @{ instId=$instId; tdMode=$config.mgnMode; side="buy"; ordType="move_order_stop"; sz=([string]$sz); callbackRatio=$callbackRatio } | ConvertTo-Json -Compress
    $resp = Send-OkxRequest -Method "POST" -RequestPath "/api/v5/trade/order-algo" -BodyJson $body -config $config
    if ($resp -and $resp.dryRun)         { Log "DryRun: trailing BUY $instId" "WARN" }
    elseif ($resp -and $resp.code -eq "0") { Log "OK: Trailing BUY $instId" "OK"; Write-TradeLog -event "TRAIL_BUY_PLACED" -instId $instId -side "BUY" -price $price -sz $sz -dipPct $dropPct -detail "callback=$($config.entry_trail_callback_pct)%" -config $config }
    else { Log "ERR trailing BUY $instId : $($resp.msg)" "ERROR" }
}

function Place-TPSL {
    param([string]$instId, [decimal]$entryPx, [decimal]$sz, $info, $config)
    $tick    = if ($info.tickSz) { [decimal]$info.tickSz } else { $null }
    $tpPct   = [decimal]$config.tp_pct / 100
    $slPct   = [decimal]$config.sl_pct / 100
    $tpPrice = RoundPriceToTick -price ([decimal]($entryPx * (1 + $tpPct))) -tick $tick
    $slPrice = RoundPriceToTick -price ([decimal]($entryPx * (1 - $slPct))) -tick $tick
    $szStr   = [string]$sz
    $tpType  = if ($config.tp_trigger_type) { $config.tp_trigger_type } else { "last" }
    Write-Host "  >> TP=$tpPrice (+$($config.tp_pct)%) SL=$slPrice (-$($config.sl_pct)%) dlya $instId" -ForegroundColor Yellow
    $tpBody = @{ instId=$instId; tdMode=$config.mgnMode; side="sell"; ordType="conditional"; sz=$szStr; tpTriggerPx=[string]$tpPrice; tpTriggerPxType=$tpType; tpOrdPx="-1" } | ConvertTo-Json -Compress
    $rTp = Send-OkxRequest -Method "POST" -RequestPath "/api/v5/trade/order-algo" -BodyJson $tpBody -config $config
    if ($rTp -and $rTp.code -eq "0") { Log "OK: TP @ $tpPrice" "OK" } elseif ($rTp -and $rTp.dryRun) { Log "DryRun: TP" "WARN" } else { Log "ERR TP: $($rTp.msg)" "ERROR" }
    $slBody = @{ instId=$instId; tdMode=$config.mgnMode; side="sell"; ordType="conditional"; sz=$szStr; slTriggerPx=[string]$slPrice; slTriggerPxType=$tpType; slOrdPx="-1" } | ConvertTo-Json -Compress
    $rSl = Send-OkxRequest -Method "POST" -RequestPath "/api/v5/trade/order-algo" -BodyJson $slBody -config $config
    if ($rSl -and $rSl.code -eq "0") { Log "OK: SL @ $slPrice" "OK" } elseif ($rSl -and $rSl.dryRun) { Log "DryRun: SL" "WARN" } else { Log "ERR SL: $($rSl.msg)" "ERROR" }
    Write-TradeLog -event "TPSL_PLACED" -instId $instId -side "SELL" -price $entryPx -sz $sz -detail "TP=$tpPrice SL=$slPrice" -config $config
}

function Place-TrailingSell {
    param([string]$instId, [decimal]$currentPx, [decimal]$sz, [string]$reason, [decimal]$callbackPct, $config)
    $callbackRatio = [string][math]::Round($callbackPct / 100, 6)
    Write-Host "  >> Trailing SELL $instId | reason=$reason | callback=$callbackPct% | sz=$sz" -ForegroundColor Magenta
    $body = @{ instId=$instId; tdMode=$config.mgnMode; side="sell"; ordType="move_order_stop"; sz=([string]$sz); callbackRatio=$callbackRatio; reduceOnly=$true } | ConvertTo-Json -Compress
    $resp = Send-OkxRequest -Method "POST" -RequestPath "/api/v5/trade/order-algo" -BodyJson $body -config $config
    if ($resp -and $resp.dryRun)         { Log "DryRun: trailing SELL $instId ($reason)" "WARN" }
    elseif ($resp -and $resp.code -eq "0") { Log "OK: Trailing SELL $instId ($reason)" "OK"; Write-TradeLog -event "TRAIL_SELL_PLACED" -instId $instId -side "SELL" -price $currentPx -sz $sz -detail "reason=$reason callback=$callbackPct%" -config $config }
    else { Log "ERR trailing SELL $instId : $($resp.msg)" "ERROR" }
}

# ======================== MAIN ========================
$config = Get-Content $configPath -Raw | ConvertFrom-Json

foreach ($field in @("api_key","secret_key","passphrase","instruments")) {
    if (-not $config.$field) { Log "Config: otsutstvuet pole '$field'" "ERROR"; exit 1 }
}

try {
    $timeResp = Send-OkxRequest -Method "GET" -RequestPath "/api/v5/public/time" -BodyJson "" -config $config
    if ($timeResp -and $timeResp.data) {
        $delta = [math]::Abs(([datetime]::Parse($timeResp.data[0].iso).ToUniversalTime() - (Get-Date).ToUniversalTime()).TotalSeconds)
        if ($delta -gt 30) { Log "Vremya raskhozhdenie >30s" "WARN" }
    }
} catch {}

$authOk = $true
$balResp = Send-OkxRequest -Method "GET" -RequestPath "/api/v5/account/balance" -BodyJson "" -config $config
if ($null -eq $balResp) { Log "Auth check failed" "WARN"; $authOk = $false } else { Log "Auth OK" "DEBUG" }

$posMode = $null
if ($authOk) { $posMode = Get-AccountConfig -config $config }

$script:infoCache     = @{}
$script:prevPositions = @{}
$script:slCooldown    = @{}
$script:slStreak      = @{}

function Get-InstrumentInfoCached {
    param([string]$instId, $config)
    if ($script:infoCache.ContainsKey($instId)) { return $script:infoCache[$instId] }
    $info = Get-InstrumentInfo -instId $instId -config $config
    if ($info) { $script:infoCache[$instId] = $info }
    return $info
}

function Run-Bot {
    Write-Host "`n========== BUY-THE-DIP-TRAIL ==========" -ForegroundColor Magenta
    if (-not $authOk) { Log "Auth ne proshjol" "WARN"; return }

    foreach ($instId in $config.instruments) {

        $openPos = Get-OpenPosition -instId $instId -config $config
        $info    = Get-InstrumentInfoCached -instId $instId -config $config
        if (-not $info) { Log "Net info dlya $instId" "WARN"; continue }
        $ctVal = if ($info.ctVal) { [decimal]$info.ctVal } else { 1 }

        # 2 vyzova vmesto 4 -- bystreye
        $moveOrders = Get-ActiveAlgoOrders -instId $instId -config $config -ordType "move_order_stop"
        $condOrders = Get-ActiveAlgoOrders -instId $instId -config $config -ordType "conditional"
        # FIX: count-based detekciya vmesto khrupkogo parsinga polej
        # TP i SL kladutsya kak otdelnye conditional ordera
        # 0 = net nichego, 1 = est tolko TP, 2+ = est oba
        $trailBuys    = $moveOrders | Where-Object { $_.side -eq "buy" }
        $trailSells   = $moveOrders | Where-Object { $_.side -eq "sell" }
        $hasTrailBuy  = $trailBuys.Count  -gt 0
        $hasTrailSell = $trailSells.Count -gt 0
        $condCount    = $condOrders.Count
        $hasTP        = $condCount -ge 1
        $hasSL        = $condCount -ge 2

        # --- Detekciya zakrytiya pozicii ---
        if ($script:prevPositions.ContainsKey($instId) -and $script:prevPositions[$instId] -and -not $openPos) {
            $prev    = $script:prevPositions[$instId]
            $entryPx = [decimal]$prev.avgPx
            $ticker  = Get-Ticker -instId $instId -config $config
            $closePx = if ($ticker) { [decimal]$ticker.last } else { $entryPx }
            $posAmt  = [math]::Abs([decimal]$prev.pos)  # FIX: v kontraktakh, bez /ctVal
            $pnlPct  = [math]::Round((($closePx - $entryPx) / $entryPx) * 100, 2)
            $pnl     = [math]::Round(($closePx - $entryPx) * $posAmt * $ctVal, 4)
            $reason  = if ($pnlPct -gt 0) { "TP" } else { "SL" }
            Write-Host ("  {0,-24} | CLOSED entry={1} close={2} P&L={3} ({4}%) -> {5}" -f $instId, $entryPx, $closePx, $pnl, $pnlPct, $reason) -ForegroundColor $(if ($pnlPct -gt 0) { 'Green' } else { 'Red' })
            Write-TradeLog -event "CLOSED" -instId $instId -side "LONG" -price $closePx -sz $posAmt -pnl $pnl -pnlPct $pnlPct -detail $reason -config $config

            # FIX: cooldown i streak counter
            $cooldownMin = if ($config.sl_cooldown_minutes) { [int]$config.sl_cooldown_minutes } else { 60 }
            $maxStreak   = if ($config.max_sl_streak)       { [int]$config.max_sl_streak }       else { 3 }
            $streakPause = if ($config.streak_pause_hours)  { [int]$config.streak_pause_hours }  else { 6 }

            if ($reason -eq "SL") {
                if (-not $script:slStreak.ContainsKey($instId)) { $script:slStreak[$instId] = 0 }
                $script:slStreak[$instId]++
                $streak = $script:slStreak[$instId]
                if ($streak -ge $maxStreak) {
                    $script:slCooldown[$instId] = (Get-Date).AddHours($streakPause)
                    $script:slStreak[$instId]   = 0
                    Write-Host ("  {0,-24} | PAUSE: {1} SL podryad -- pauza {2} ch." -f $instId, $streak, $streakPause) -ForegroundColor Red
                } else {
                    $script:slCooldown[$instId] = (Get-Date).AddMinutes($cooldownMin)
                    Write-Host ("  {0,-24} | COOLDOWN: SL #{1}/{2} -- {3} min." -f $instId, $streak, $maxStreak, $cooldownMin) -ForegroundColor Yellow
                }
            } else {
                $script:slStreak[$instId] = 0
            }

            # Otmenyaem zavisshie ordera
            $orphanCond = Get-ActiveAlgoOrders -instId $instId -config $config -ordType "conditional"
            if ($orphanCond.Count -gt 0) {
                Log "Otmenyaem $($orphanCond.Count) zavisshikh TP/SL dlya $instId" "WARN"
                Cancel-AlgoOrders -algos $orphanCond -instId $instId -config $config
            }
            $orphanMove = Get-ActiveAlgoOrders -instId $instId -config $config -ordType "move_order_stop"
            if ($orphanMove.Count -gt 0) {
                Log "Otmenyaem $($orphanMove.Count) zavisshikh trailing dlya $instId" "WARN"
                Cancel-AlgoOrders -algos $orphanMove -instId $instId -config $config
            }
        }
        $script:prevPositions[$instId] = $openPos

        # ===== STATE 1: net pozicii, net trailing BUY =====
        if (-not $openPos -and -not $hasTrailBuy) {

            # FIX: proverka cooldown pered vkhodom
            if ($script:slCooldown.ContainsKey($instId) -and (Get-Date) -lt $script:slCooldown[$instId]) {
                $remaining = [math]::Round(($script:slCooldown[$instId] - (Get-Date)).TotalMinutes, 0)
                Write-Host ("{0,-24} | COOLDOWN: eshe {1} min." -f "  $instId", $remaining) -ForegroundColor DarkGray
                continue
            }

            $ticker = Get-Ticker -instId $instId -config $config
            if (-not $ticker) { continue }
            $price     = [decimal]$ticker.last
            $open24h   = [decimal]$ticker.open24h
            $dropPct   = if ($open24h -gt 0) { [math]::Round((($price - $open24h) / $open24h) * 100, 4) } else { 0 }
            $threshold = [decimal]$config.dip_threshold_pct

            $color = if ($dropPct -le -3) { 'Red' } elseif ($dropPct -le 0) { 'Yellow' } else { 'Green' }
            Write-Host ("{0,-24} | 24h: {1,7:F2}%  | Cena: {2}" -f "  $instId", $dropPct, $price) -ForegroundColor $color

            if ($dropPct -le $threshold) {
                Write-Host "  >> $instId : prosadka $dropPct% -- trailing BUY!" -ForegroundColor Red
                Place-TrailingBuy -instId $instId -price $price -dropPct $dropPct -info $info -config $config
            }
            continue
        }

        # ===== STATE 2: net pozicii, est trailing BUY =====
        if (-not $openPos -and $hasTrailBuy) {
            $tb = $trailBuys[0]
            Write-Host ("{0,-24} | WAIT trailing BUY | callback={1} sz={2}" -f "  $instId", $tb.callbackRatio, $tb.sz) -ForegroundColor Cyan
            # Chistim zavisshie TP/SL ot predydushchej pozicii
            if ($condOrders.Count -gt 0) {
                Log "Zavisshie TP/SL bez pozicii $instId -- otmenyaem" "WARN"
                Cancel-AlgoOrders -algos $condOrders -instId $instId -config $config
            }
            continue
        }

        # ===== Poziciya otkryta: obshchie dannye =====
        $entryPx         = [decimal]$openPos.avgPx
        $ticker          = Get-Ticker -instId $instId -config $config
        $currentPx       = if ($ticker) { [decimal]$ticker.last } else { $entryPx }
        $posAmt          = [math]::Abs([decimal]$openPos.pos)
        $profitPct       = [math]::Round((($currentPx - $entryPx) / $entryPx) * 100, 2)
        $pnl             = [math]::Round(($currentPx - $entryPx) * $posAmt * $ctVal, 4)
        $slPct           = [decimal]$config.sl_pct
        $tpPct           = [decimal]$config.tp_pct
        $profitThreshold = [decimal]$config.profit_trail_threshold_pct
        $szForOrders     = $posAmt

        $ordStatus = if ($hasTrailSell) { "[trail]" } elseif ($hasTP -and $hasSL) { "[TP/SL]" } elseif ($hasTP) { "[TP only]" } elseif ($hasSL) { "[SL only]" } else { "[NO ORDERS]" }
        Write-Host ("{0,-24} | LONG entry={1} now={2} P&L={3}% {4}" -f "  $instId", $entryPx, $currentPx, $profitPct, $ordStatus) -ForegroundColor $(if ($profitPct -ge 0) { 'Green' } else { 'Red' })

        # ===== STATE 4: ubytok prevysil SL =====
        if ($profitPct -le -$slPct) {
            if (-not $hasTrailSell) {
                Write-Host "  >> $instId : ubytok $profitPct% > SL -$slPct% -- EMERGENCY trailing SELL!" -ForegroundColor Red
                # Otmenyaem vse conditional ordera pered postavkoj trailing
                if ($condOrders.Count -gt 0) { Cancel-AlgoOrders -algos $condOrders -instId $instId -config $config }
                Place-TrailingSell -instId $instId -currentPx $currentPx -sz $szForOrders -reason "EMERGENCY_SL" -callbackPct $config.loss_trail_callback_pct -config $config
            }
            continue
        }

        # ===== STATE 3: ne khvataet TP ili SL =====
        if ((-not $hasTP -or -not $hasSL) -and -not $hasTrailSell) {
            if (-not $hasTP -and -not $hasSL) {
                Place-TPSL -instId $instId -entryPx $entryPx -sz $szForOrders -info $info -config $config
            } elseif (-not $hasTP) {
                $tick    = if ($info.tickSz) { [decimal]$info.tickSz } else { $null }
                $tpPrice = RoundPriceToTick -price ([decimal]($entryPx * (1 + [decimal]$config.tp_pct / 100))) -tick $tick
                $tpType  = if ($config.tp_trigger_type) { $config.tp_trigger_type } else { "last" }
                $r = Send-OkxRequest -Method "POST" -RequestPath "/api/v5/trade/order-algo" -BodyJson (@{ instId=$instId; tdMode=$config.mgnMode; side="sell"; ordType="conditional"; sz=([string]$szForOrders); tpTriggerPx=[string]$tpPrice; tpTriggerPxType=$tpType; tpOrdPx="-1" } | ConvertTo-Json -Compress) -config $config
                if ($r -and $r.code -eq "0") { Log "OK: TP @ $tpPrice" "OK" } else { Log "ERR TP: $($r.msg)" "ERROR" }
            } else {
                # Est TP, net SL -- pytaemsya postavit SL, pri oshibke -- trailing
                $tick    = if ($info.tickSz) { [decimal]$info.tickSz } else { $null }
                $slPrice = RoundPriceToTick -price ([decimal]($entryPx * (1 - [decimal]$config.sl_pct / 100))) -tick $tick
                $tpType  = if ($config.tp_trigger_type) { $config.tp_trigger_type } else { "last" }
                $r = Send-OkxRequest -Method "POST" -RequestPath "/api/v5/trade/order-algo" -BodyJson (@{ instId=$instId; tdMode=$config.mgnMode; side="sell"; ordType="conditional"; sz=([string]$szForOrders); slTriggerPx=[string]$slPrice; slTriggerPxType=$tpType; slOrdPx="-1" } | ConvertTo-Json -Compress) -config $config
                if ($r -and $r.code -eq "0") {
                    Log "OK: SL @ $slPrice" "OK"
                } elseif ($r -and -not $r.dryRun) {
                    Log "SL ne udalos ($($r.msg)) -- trailing SELL vmesto SL" "WARN"
                    Place-TrailingSell -instId $instId -currentPx $currentPx -sz $szForOrders -reason "SL_FALLBACK" -callbackPct $config.loss_trail_callback_pct -config $config
                }
            }
            continue
        }

        # ===== STATE 5: pribyl > poroga -- trailing SELL =====
        $tpLevel = $entryPx * (1 + $tpPct / 100)
        if ($profitPct -ge $profitThreshold -and $currentPx -lt $tpLevel -and -not $hasTrailSell) {
            Write-Host "  >> $instId : pribyl $profitPct% > $profitThreshold% -- LOCK PROFIT trailing SELL!" -ForegroundColor Green
            Place-TrailingSell -instId $instId -currentPx $currentPx -sz $szForOrders -reason "LOCK_PROFIT" -callbackPct $config.exit_trail_callback_pct -config $config
        }
    }

    # Balance
    $b = Send-OkxRequest -Method "GET" -RequestPath "/api/v5/account/balance" -BodyJson "" -config $config
    if ($b -and $b.code -eq "0") {
        $acc  = $b.data[0]
        $usdt = $acc.details | Where-Object { $_.ccy -eq "USDT" }
        Write-Host "`n===== BALANCE =====" -ForegroundColor Cyan
        Write-Host "Total Equity : $($acc.totalEq) USDT" -ForegroundColor White
        if ($usdt) { Write-Host "USDT Available: $($usdt.availBal)" -ForegroundColor Green; Write-Host "USDT UPL: $($usdt.upl)" -ForegroundColor Yellow }
        Write-Host "==================`n" -ForegroundColor Cyan
    }

    Log "Cycle done." "OK"
}

while ($true) { Run-Bot; Start-Sleep -Seconds $config.rerun_interval_s }
