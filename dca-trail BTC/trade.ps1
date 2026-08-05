# DCA-TRAIL — усреднение с трейлинг-стопом на вход и единым трейлинг-ТП на весь объём
#
# Логика для каждого инструмента (каждый цикл):
# [1] Куплено (pos > 0) → проверяем, стоит ли trailing TP на ВЕСЬ текущий объём.
#     Если нет — ставим. Если объём позиции изменился (докупили) — переставляем
#     trailing TP на новый полный объём.
# [2] Цена относительно open текущего часа: если просадка <= hourly_dip_threshold_pct
#     И нет ни одного активного trailing BUY — ставим trailing BUY на сумму
#     buy_size_usd с гэпом entry_trail_callback_pct. Не более одного активного
#     trailing BUY на инструмент одновременно.

param(
  [string]$ConfigPath = ".\config.json",
  [switch]$ForceLive,
  [switch]$DebugMode
)

# ---------------- helpers ----------------
function Get-Timestamp { return [int][double]::Parse((Get-Date -UFormat %s)) }
function Format-Time   { return (Get-Date -Format "yyyy-MM-dd HH:mm:ss") }
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
    return [decimal]$([math]::Round([double]([math]::Round($price / $tick, 8)) * $tick, 8))
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

function Get-ActiveAlgoOrders {
    param([string]$instId, $config, [string]$ordType)
    $resp = Send-OkxRequest -Method "GET" -RequestPath "/api/v5/trade/orders-algo-pending?instId=$instId&ordType=$ordType&instType=SWAP" -BodyJson "" -config $config
    # FIX: $null oznachaet "zapros ne udalsya" (setevaya oshibka, rate-limit i t.p.) --
    # eto NE to zhe samoe, chto "ordera podtverzhdenno otsutstvuyut" ($resp.data пустой).
    # Ranshe oba sluchaya vozvrashchali @(), i sboj zaprosa vosprinimalsya kak "TP net",
    # chto privodilo k postanovke dublyayushchego ordera poverh sushchestvuyushchego.
    if ($null -eq $resp) { return $null }
    # FIX: "return @()" v PowerShell razvorachivaetsya v NOL vyhodnyh obyektov, i pri
    # prisvoenii peremennoj ($x = Get-ActiveAlgoOrders ...) rezultat stanovitsya $null,
    # ne pustym massivom! Operator zapyatoj (,@()) predotvrashchaet razvorachivanie.
    if (-not $resp.data) { return ,@() }
    return ,$resp.data
}

function Cancel-AlgoOrders {
    param([array]$algos, [string]$instId, $config)
    if (-not $algos -or $algos.Count -eq 0) { return }
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

# ---------------- razmer pokupki ----------------
function Get-DcaPositionSz {
    param([string]$instId, [decimal]$price, $info, $config)
    $ctVal = if ($info.ctVal) { [decimal]$info.ctVal } else { 1 }
    $minSz = if ($info.minSz) { [decimal]$info.minSz } elseif ($info.lotSz) { [decimal]$info.lotSz } else { 0.01 }
    $step  = $minSz
    $notional = [decimal]($config.buy_size_usd * $config.leverage)
    $sz = Set-ToStep -value ([decimal]($notional / ($ctVal * $price))) -step $step
    if ($sz -le 0 -or $sz -lt $minSz) { $sz = $minSz }
    $levBody = @{ instId=$instId; lever=([string]$config.leverage); mgnMode=$config.mgnMode }
    if ($script:posMode -and ($script:posMode.ToString().ToLower() -match "long_short|hedge")) { $levBody.posSide = "long" }
    Send-OkxRequest -Method "POST" -RequestPath "/api/v5/account/set-leverage" -BodyJson ($levBody | ConvertTo-Json -Compress) -config $config | Out-Null
    return $sz
}

# ---------------- open chasovoj svechi (kesh na chas) ----------------
$script:hourOpenCache = @{}
function Get-HourOpenPrice {
    param([string]$instId, $config)
    $bucket = [math]::Floor((Get-Timestamp) / 3600)
    if ($script:hourOpenCache.ContainsKey($instId) -and $script:hourOpenCache[$instId].Bucket -eq $bucket) {
        return $script:hourOpenCache[$instId].Value
    }
    try {
        $url  = "$($config.baseUrl.TrimEnd('/'))/api/v5/market/candles?instId=$instId&bar=1H&limit=1"
        $resp = Invoke-RestMethod -Uri $url -Method Get -ErrorAction Stop
        if (-not $resp.data -or $resp.data.Count -lt 1) { return $null }
        $candleTsSec = [long]($resp.data[0][0]) / 1000
        $candleBucket = [math]::Floor($candleTsSec / 3600)
        if ($candleBucket -ne $bucket) {
            # OKX eshhjo ne sozdal svechu novogo chasa (granica chasa) -- ne kešируем stalyj open,
            # probuem zanovo na sleduyushchem cikle
            Log "$instId : svecha API eshhjo staraya (bucket $candleBucket != $bucket) -- propuskaem kesh" "DEBUG"
            return $null
        }
        $openPx = [decimal]$resp.data[0][1]
        $script:hourOpenCache[$instId] = @{ Value = $openPx; Bucket = $bucket }
        return $openPx
    } catch {
        Log "Hour-open fetch failed dlya $instId : $_" "DEBUG"
        return $null
    }
}

# ======================== DEJSTVIYA ========================

function Place-TrailingBuy {
    param([string]$instId, [decimal]$price, [decimal]$dropPct, $info, $config)
    $sz = Get-DcaPositionSz -instId $instId -price $price -info $info -config $config
    $callbackRatio = [string][math]::Round([decimal]$config.entry_trail_callback_pct / 100, 6)
    Write-Host "  >> Trailing BUY (DCA) $instId | 1h drop=$dropPct% | gap=$($config.entry_trail_callback_pct)% | sz=$sz" -ForegroundColor Cyan
    $body = @{ instId=$instId; tdMode=$config.mgnMode; side="buy"; ordType="move_order_stop"; sz=([string]$sz); callbackRatio=$callbackRatio } | ConvertTo-Json -Compress
    $resp = Send-OkxRequest -Method "POST" -RequestPath "/api/v5/trade/order-algo" -BodyJson $body -config $config
    if ($resp -and $resp.dryRun)         { Log "DryRun: trailing BUY $instId" "WARN"; $script:lastBuyBucket[$instId] = [math]::Floor((Get-Timestamp) / 3600) }
    elseif ($resp -and $resp.code -eq "0") { Log "OK: Trailing BUY $instId" "OK"; $script:lastBuyBucket[$instId] = [math]::Floor((Get-Timestamp) / 3600); Write-TradeLog -event "TRAIL_BUY_PLACED" -instId $instId -side "BUY" -price $price -sz $sz -dipPct $dropPct -detail "gap=$($config.entry_trail_callback_pct)%" -config $config }
    else { Log "ERR trailing BUY $instId : $($resp.msg)" "ERROR" }
}

function Place-TrailingTP {
    param([string]$instId, [decimal]$currentPx, [decimal]$sz, [decimal]$entryPx, $info, $config)
    $callbackRatio = [string][math]::Round([decimal]$config.trailing_tp_callback_pct / 100, 6)
    $body = @{ instId=$instId; tdMode=$config.mgnMode; side="sell"; ordType="move_order_stop"; sz=([string]$sz); callbackRatio=$callbackRatio; reduceOnly=$true }
    $activeInfo = ""
    if ($config.tp_activate_pct -and [decimal]$config.tp_activate_pct -gt 0 -and $entryPx -gt 0) {
        $tick     = if ($info.tickSz) { [decimal]$info.tickSz } else { $null }
        $activePx = RoundPriceToTick -price ([decimal]($entryPx * (1 + [decimal]$config.tp_activate_pct / 100))) -tick $tick
        # FIX: stavim activePx tolko esli tekushchaya cena NIZHE aktivacii.
        # Esli cena uzhe VYSHE -- activePx ne nuzhna: trailing startuet srazu.
        # Esli aktivaciyu postavit vyshe tekushchej ceny -- OKX budet zhdat
        # peresecheniya snizu vverkh i TP 'zависнет'.
        if ($activePx -gt $currentPx) {
            $body.activePx = [string]$activePx
            $activeInfo = " | activate>=$activePx (zhdjom rosta)"
        } else {
            $activeInfo = " | bez activePx (cena uzhe vyshe $activePx -- startuet srazu)"
        }
    }
    Write-Host "  >> Trailing TP $instId | gap=$($config.trailing_tp_callback_pct)% | sz=$sz$activeInfo" -ForegroundColor Yellow
    $resp = Send-OkxRequest -Method "POST" -RequestPath "/api/v5/trade/order-algo" -BodyJson ($body | ConvertTo-Json -Compress) -config $config
    if ($resp -and $resp.dryRun)           { Log "DryRun: trailing TP $instId" "WARN"; $script:lastTpChangeAt[$instId] = Get-Timestamp }
    elseif ($resp -and $resp.code -eq "0") { Log "OK: Trailing TP $instId sz=$sz$activeInfo" "OK"; $script:lastTpChangeAt[$instId] = Get-Timestamp; Write-TradeLog -event "TRAIL_TP_PLACED" -instId $instId -side "SELL" -price $currentPx -sz $sz -detail "gap=$($config.trailing_tp_callback_pct)%$activeInfo" -config $config }
    else { Log "ERR trailing TP $instId : $($resp.msg)" "ERROR" }
}

# ======================== MAIN ========================
$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json

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

$script:posMode = $null
if ($authOk) { $script:posMode = Get-AccountConfig -config $config }

$script:infoCache     = @{}
$script:prevPositions = @{}
$script:lastBuyBucket = @{}  # instId -> chasovoj bucket poslednej postavlennoj trailing BUY
$script:lastTpChangeAt = @{}  # instId -> unix ts poslednej postavki/perestanovki trailing TP
$script:tpChangeCooldownSec = 6  # zhdyom, poka birzha otrazit ordera v spiske active, pered sleduyushchim izmeneniem

function Get-InstrumentInfoCached {
    param([string]$instId, $config)
    if ($script:infoCache.ContainsKey($instId)) { return $script:infoCache[$instId] }
    $info = Get-InstrumentInfo -instId $instId -config $config
    if ($info) { $script:infoCache[$instId] = $info }
    return $info
}

function Run-Bot {
    Write-Host "`n========== DCA-TRAIL ==========" -ForegroundColor Magenta
    if (-not $authOk) { Log "Auth ne proshjol" "WARN"; return }

    foreach ($instId in $config.instruments) {

        $openPos = Get-OpenPosition -instId $instId -config $config
        $info    = Get-InstrumentInfoCached -instId $instId -config $config
        if (-not $info) { Log "Net info dlya $instId" "WARN"; continue }
        $ctVal = if ($info.ctVal) { [decimal]$info.ctVal } else { 1 }

        $moveOrders = Get-ActiveAlgoOrders -instId $instId -config $config -ordType "move_order_stop"
        if ($null -eq $moveOrders) {
            Log "$instId : ne udalos poluchit spisok algo-orderov -- propuskaem cikl (chtoby ne postavit dublikat)" "WARN"
            continue
        }
        $trailBuys   = $moveOrders | Where-Object { $_.side -eq "buy" }
        $trailSells  = $moveOrders | Where-Object { $_.side -eq "sell" }
        $hasTrailBuy = $trailBuys.Count  -gt 0
        $hasTrailTP  = $trailSells.Count -gt 0

        $ticker = Get-Ticker -instId $instId -config $config
        if (-not $ticker) { continue }
        $price = [decimal]$ticker.last

        # --- Detekciya zakrytiya pozicii (dlya loga) ---
        if ($script:prevPositions.ContainsKey($instId) -and $script:prevPositions[$instId] -and -not $openPos) {
            $prev       = $script:prevPositions[$instId]
            $entryPx    = [decimal]$prev.avgPx
            $posAmtPrev = [math]::Abs([decimal]$prev.pos)
            $pnlPct     = [math]::Round((($price - $entryPx) / $entryPx) * 100, 2)
            $pnl        = [math]::Round(($price - $entryPx) * $posAmtPrev * $ctVal, 4)
            Write-Host ("  {0,-24} | CLOSED entry={1} close={2} P&L={3} ({4}%)" -f $instId, $entryPx, $price, $pnl, $pnlPct) -ForegroundColor $(if ($pnlPct -gt 0) { 'Green' } else { 'Red' })
            Write-TradeLog -event "CLOSED" -instId $instId -side "LONG" -price $price -sz $posAmtPrev -pnl $pnl -pnlPct $pnlPct -detail "TRAIL_TP" -config $config
        }
        $script:prevPositions[$instId] = $openPos

        $posAmt = if ($openPos) { [math]::Abs([decimal]$openPos.pos) } else { 0 }
        $entryPx = if ($openPos) { [decimal]$openPos.avgPx } else { 0 }

        # ===== 1) Kupleno > 0 -- proveryaem trailing TP na ves objem =====
        if ($posAmt -gt 0) {
            $tpCooldown = $script:lastTpChangeAt.ContainsKey($instId) -and ((Get-Timestamp) - $script:lastTpChangeAt[$instId] -lt $script:tpChangeCooldownSec)
            if ($tpCooldown) {
                # Nedavno stavili/perestavlyali TP -- zhdyom, poka birzha otrazit izmenenie
                # v spiske active algo orders, chtoby ne sozdat dublikat iz-za zaderzhki propagacii
                Log "$instId : TP nedavno izmenjon -- zhdyom sinhronizacii API" "DEBUG"
            } elseif ($trailSells.Count -gt 1) {
                Log "$instId : obnaruzheny dublikaty trailing TP ($($trailSells.Count) sht) -- chistim i perestavlyaem" "WARN"
                Cancel-AlgoOrders -algos $trailSells -instId $instId -config $config
                Place-TrailingTP -instId $instId -currentPx $price -sz $posAmt -entryPx $entryPx -info $info -config $config
            } elseif (-not $hasTrailTP) {
                Log "$instId : poziciya sz=$posAmt bez trailing TP -- stavim" "WARN"
                Place-TrailingTP -instId $instId -currentPx $price -sz $posAmt -entryPx $entryPx -info $info -config $config
            } else {
                $existingSz = [decimal]$trailSells[0].sz
                if ($existingSz -ne $posAmt) {
                    Log "$instId : objem izmenilsya ($existingSz -> $posAmt) -- perestavlyaem trailing TP" "WARN"
                    Cancel-AlgoOrders -algos $trailSells -instId $instId -config $config
                    Place-TrailingTP -instId $instId -currentPx $price -sz $posAmt -entryPx $entryPx -info $info -config $config
                }
            }
        }

        # ===== 2) Prosadka ot nachala chasa -- trailing BUY na usredneniye =====
        $hourOpen = Get-HourOpenPrice -instId $instId -config $config
        if ($hourOpen -and $hourOpen -gt 0) {
            $dropPct    = [math]::Round((($price - $hourOpen) / $hourOpen) * 100, 4)
            $threshold  = [decimal]$config.hourly_dip_threshold_pct
            $curBucket  = [math]::Floor((Get-Timestamp) / 3600)
            $boughtThisHour = $script:lastBuyBucket.ContainsKey($instId) -and $script:lastBuyBucket[$instId] -eq $curBucket
            $color      = if ($dropPct -le $threshold) { 'Red' } elseif ($dropPct -le 0) { 'Yellow' } else { 'Green' }
            $tag        = if ($hasTrailBuy) { " [trail BUY active]" } elseif ($boughtThisHour) { " [uzhe kupleno v etom chasu]" } else { "" }
            Write-Host ("{0,-24} | 1h: {1,7:F2}% | Cena: {2} | pos={3}{4}" -f "  $instId", $dropPct, $price, $posAmt, $tag) -ForegroundColor $color

            $aboveAvg = ($posAmt -gt 0) -and ($price -ge $entryPx)

            if ($dropPct -le $threshold) {
                if ($hasTrailBuy) {
                    Write-Host "  .. $instId : prosadka est, no trailing BUY uzhe aktiven -- propuskaem (limit 1)" -ForegroundColor DarkGray
                } elseif ($boughtThisHour) {
                    Write-Host "  .. $instId : prosadka est, no pokupka v etom chasu uzhe byla -- propuskaem (limit 1/chas)" -ForegroundColor DarkGray
                } elseif ($aboveAvg) {
                    Write-Host "  .. $instId : cena $price >= srednej $entryPx -- ne usrednyaemsya vverkh, propuskaem" -ForegroundColor DarkGray
                } else {
                    Write-Host "  >> $instId : chasovaya prosadka $dropPct% -- trailing BUY (usredneniye)!" -ForegroundColor Red
                    Place-TrailingBuy -instId $instId -price $price -dropPct $dropPct -info $info -config $config
                }
            }
        } else {
            Log "Net dannykh po chasovoj svyeche dlya $instId" "DEBUG"
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
