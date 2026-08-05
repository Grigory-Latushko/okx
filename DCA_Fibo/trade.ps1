# DCA_Fibo — усреднение с размером докупки по ряду Фибоначчи
#
# Базируется на DCA-trail. Отличие: каждая последующая докупка
# умножается на число Фибоначчи согласно порядковому номеру покупки:
#
#   Покупка 1: buy_size_usd × Fib(1) = × 1
#   Покупка 2: buy_size_usd × Fib(2) = × 1
#   Покупка 3: buy_size_usd × Fib(3) = × 2
#   Покупка 4: buy_size_usd × Fib(4) = × 3
#   Покупка 5: buy_size_usd × Fib(5) = × 5
#   Покупка 6: buy_size_usd × Fib(6) = × 8
#   ...
#
# Параметр max_fibo_buys ограничивает максимальное число покупок.
# Позиция закрывается единым trailing TP на весь объём.

param(
  [string]$ConfigPath = ".\config.json",
  [switch]$ForceLive,
  [switch]$DebugMode
)

# ---------------- helpers ----------------
function Get-Timestamp { return [int][double]::Parse((Get-Date -UFormat %s)) }
function Log  { param([string]$msg, [string]$level = "INFO") switch ($level.ToUpper()) { "INFO"  { Write-Host "[INFO ] $msg" -ForegroundColor Gray } "OK"    { Write-Host "[ OK  ] $msg" -ForegroundColor Green } "WARN"  { Write-Host "[WARN ] $msg" -ForegroundColor Yellow } "ERROR" { Write-Host "[ERR  ] $msg" -ForegroundColor Red } "DEBUG" { if ($DebugMode) { Write-Host "[DBG  ] $msg" -ForegroundColor Cyan } } } }
function Get-NowTimestamp { (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ") }

# ---------------- ряд Фибоначчи ----------------
# Fib(1)=1, Fib(2)=1, Fib(3)=2, Fib(4)=3, Fib(5)=5, Fib(6)=8, ...
function Get-FibNumber {
    param([int]$n)
    if ($n -le 0) { return 1 }
    if ($n -le 2) { return 1 }
    $a = 1; $b = 1
    for ($i = 3; $i -le $n; $i++) { $c = $a + $b; $a = $b; $b = $c }
    return $b
}

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
        Log "DryRun -- POST: $RequestPath" "WARN"
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
    if ($null -eq $resp) { return $null }
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
    if ($resp -and ($resp.dryRun -or $resp.code -eq "0")) { Log "Algo otmeneny dlya $instId" "OK" }
    else { Log "Oshibka otmeny: $($resp.msg)" "ERROR" }
}

function Write-TradeLog {
    param([string]$event, [string]$instId, [string]$side, [decimal]$price, [decimal]$sz, [decimal]$dipPct = 0, [decimal]$pnl = 0, [decimal]$pnlPct = 0, [string]$detail = "", $config)
    $logFile = if ($config.log_file) { $config.log_file } else { ".\trades.csv" }
    if (-not (Test-Path $logFile)) { "timestamp,event,instId,side,price,sz,dip_pct,pnl,pnl_pct,detail`n" | Out-File -FilePath $logFile -Encoding utf8 -NoNewline }
    $ts = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ss")
    "$ts,$event,$instId,$side,$price,$sz,$dipPct,$pnl,$pnlPct,$detail`n" | Out-File -FilePath $logFile -Encoding utf8 -Append -NoNewline
    Log "LOG: $event $instId @ $price | $detail" "OK"
}

# ---------------- размер покупки с множителем Фибоначчи ----------------
function Get-FiboBuySz {
    param([string]$instId, [decimal]$price, $info, $config)
    $ctVal    = if ($info.ctVal) { [decimal]$info.ctVal } else { 1 }
    $minSz    = if ($info.minSz) { [decimal]$info.minSz } elseif ($info.lotSz) { [decimal]$info.lotSz } else { 0.01 }
    $step     = $minSz

    # Номер текущей покупки (1-based) и множитель Фибоначчи
    $buyNum   = ($script:buyCount[$instId] + 1)
    $fibMult  = Get-FibNumber -n $buyNum
    $notional = [decimal]($config.buy_size_usd * $config.leverage * $fibMult)

    $sz = Set-ToStep -value ([decimal]($notional / ($ctVal * $price))) -step $step
    if ($sz -le 0 -or $sz -lt $minSz) { $sz = $minSz }

    # Плечо
    $levBody = @{ instId=$instId; lever=([string]$config.leverage); mgnMode=$config.mgnMode }
    if ($script:posMode -and ($script:posMode.ToString().ToLower() -match "long_short|hedge")) { $levBody.posSide = "long" }
    Send-OkxRequest -Method "POST" -RequestPath "/api/v5/account/set-leverage" -BodyJson ($levBody | ConvertTo-Json -Compress) -config $config | Out-Null

    return @{ sz = $sz; fibMult = $fibMult; buyNum = $buyNum }
}

# ---------------- open текущей часовой свечи ----------------
# Кэш на весь час -- цена открытия часа не меняется
$script:hourOpenCache = @{}
function Get-HourOpenPrice {
    param([string]$instId, $config)
    $bucket = [math]::Floor((Get-Timestamp) / 3600)
    if ($script:hourOpenCache.ContainsKey($instId) -and $script:hourOpenCache[$instId].Bucket -eq $bucket) {
        return $script:hourOpenCache[$instId].Value
    }
    try {
        # limit=2: data[0] = текущая (незакрытая) свеча, data[1] = предыдущая закрытая
        $url  = "$($config.baseUrl.TrimEnd('/'))/api/v5/market/candles?instId=$instId&bar=1H&limit=2"
        $resp = Invoke-RestMethod -Uri $url -Method Get -ErrorAction Stop
        if (-not $resp.data -or $resp.data.Count -lt 1) { return $null }
        $candleTsSec  = [long]($resp.data[0][0]) / 1000
        $candleBucket = [math]::Floor($candleTsSec / 3600)
        if ($candleBucket -ne $bucket) {
            # Граница часа -- OKX ещё не создал новую свечу.
            # Берём close предыдущей свечи как временный open нового часа
            $openPx = [decimal]$resp.data[0][4]  # close предыдущей = open нового
        } else {
            $openPx = [decimal]$resp.data[0][1]  # open текущей свечи
        }
        $script:hourOpenCache[$instId] = @{ Value = $openPx; Bucket = $bucket }
        Log "$instId : hour open = $openPx (bucket=$bucket)" "DEBUG"
        return $openPx
    } catch { Log "Hour-open failed dlya $instId : $_" "DEBUG"; return $null }
}

# ---------------- trailing BUY с Фибоначчи-размером ----------------
function Place-FiboTrailingBuy {
    param([string]$instId, [decimal]$price, [decimal]$dropPct, $info, $config)

    $maxBuys = if ($config.max_fibo_buys) { [int]$config.max_fibo_buys } else { 6 }
    $curCount = $script:buyCount[$instId]

    if ($curCount -ge $maxBuys) {
        Write-Host ("  {0,-24} | LIMIT: {1}/{2} pokupok -- bolshe ne dokupaemsya" -f "  $instId", $curCount, $maxBuys) -ForegroundColor DarkGray
        return
    }

    $fbData = Get-FiboBuySz -instId $instId -price $price -info $info -config $config
    $sz       = $fbData.sz
    $fibMult  = $fbData.fibMult
    $buyNum   = $fbData.buyNum
    $callback = [string][math]::Round([decimal]$config.entry_trail_callback_pct / 100, 6)

    Write-Host ("  >> Fibo trailing BUY #{0} | Fib({0})={1}x | usd={2} | sz={3} | 1h drop={4}%" -f $buyNum, $fibMult, ([decimal]$config.buy_size_usd * $fibMult), $sz, $dropPct) -ForegroundColor Cyan

    $body = @{ instId=$instId; tdMode=$config.mgnMode; side="buy"; ordType="move_order_stop"; sz=([string]$sz); callbackRatio=$callback } | ConvertTo-Json -Compress
    $resp = Send-OkxRequest -Method "POST" -RequestPath "/api/v5/trade/order-algo" -BodyJson $body -config $config

    if ($resp -and $resp.dryRun) {
        Log "DryRun: Fibo trailing BUY #$buyNum $instId" "WARN"
        $script:buyCount[$instId]++
        Write-TradeLog -event "FIBO_BUY_PLACED" -instId $instId -side "BUY" -price $price -sz $sz -dipPct $dropPct -detail "buy=$buyNum fib=$fibMult x$([decimal]$config.buy_size_usd*$fibMult)usd" -config $config
    } elseif ($resp -and $resp.code -eq "0") {
        Log "OK: Fibo trailing BUY #$buyNum $instId Fib=$fibMult sz=$sz" "OK"
        $script:buyCount[$instId]++
        Write-TradeLog -event "FIBO_BUY_PLACED" -instId $instId -side "BUY" -price $price -sz $sz -dipPct $dropPct -detail "buy=$buyNum fib=$fibMult x$([decimal]$config.buy_size_usd*$fibMult)usd" -config $config
    } else {
        Log "ERR Fibo trailing BUY #$buyNum $instId : $($resp.msg)" "ERROR"
    }
}

# ---------------- trailing TP на весь объём ----------------
function Place-TrailingTP {
    param([string]$instId, [decimal]$currentPx, [decimal]$sz, [decimal]$entryPx, $info, $config)
    $callback  = [string][math]::Round([decimal]$config.trailing_tp_callback_pct / 100, 6)
    $body      = @{ instId=$instId; tdMode=$config.mgnMode; side="sell"; ordType="move_order_stop"; sz=([string]$sz); callbackRatio=$callback; reduceOnly=$true }
    $activeInfo = ""
    if ($config.tp_activate_pct -and [decimal]$config.tp_activate_pct -gt 0 -and $entryPx -gt 0) {
        $tick      = if ($info.tickSz) { [decimal]$info.tickSz } else { $null }
        $activePx  = RoundPriceToTick -price ([decimal]($entryPx * (1 + [decimal]$config.tp_activate_pct / 100))) -tick $tick
        if ($activePx -gt $currentPx) {
            $body.activePx = [string]$activePx
            $activeInfo = " | activate>=$activePx (zhdjom rosta)"
        } else {
            $activeInfo = " | bez activePx (cena uzhe vyshe -- startuet srazu)"
        }
    }
    Write-Host ("  >> Trailing TP {0} | sz={1} | gap={2}%{3}" -f $instId, $sz, $config.trailing_tp_callback_pct, $activeInfo) -ForegroundColor Yellow
    $resp = Send-OkxRequest -Method "POST" -RequestPath "/api/v5/trade/order-algo" -BodyJson ($body | ConvertTo-Json -Compress) -config $config
    if ($resp -and $resp.dryRun)           { Log "DryRun: trailing TP $instId" "WARN"; $script:lastTpAt[$instId] = Get-Timestamp }
    elseif ($resp -and $resp.code -eq "0") { Log "OK: trailing TP $instId sz=$sz$activeInfo" "OK"; $script:lastTpAt[$instId] = Get-Timestamp; Write-TradeLog -event "TRAIL_TP_PLACED" -instId $instId -side "SELL" -price $currentPx -sz $sz -detail "gap=$($config.trailing_tp_callback_pct)%$activeInfo" -config $config }
    else { Log "ERR trailing TP $instId : $($resp.msg)" "ERROR" }
}

# ======================== MAIN ========================
$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json

foreach ($field in @("api_key","secret_key","passphrase","instruments")) {
    if (-not $config.$field) { Log "Config: otsutstvuet '$field'" "ERROR"; exit 1 }
}

try {
    $tr = Send-OkxRequest -Method "GET" -RequestPath "/api/v5/public/time" -BodyJson "" -config $config
    if ($tr -and $tr.data) {
        $delta = [math]::Abs(([datetime]::Parse($tr.data[0].iso).ToUniversalTime() - (Get-Date).ToUniversalTime()).TotalSeconds)
        if ($delta -gt 30) { Log "Clock drift >30s" "WARN" }
    }
} catch {}

$authOk = $true
$balResp = Send-OkxRequest -Method "GET" -RequestPath "/api/v5/account/balance" -BodyJson "" -config $config
if ($null -eq $balResp) { $authOk = $false; Log "Auth failed" "WARN" } else { Log "Auth OK" "DEBUG" }

$script:posMode    = $null
if ($authOk) { $script:posMode = Get-AccountConfig -config $config }

$script:infoCache      = @{}
$script:prevPositions  = @{}
$script:buyCount       = @{}   # instId → сколько Фибо-покупок сделано (сбрасывается при закрытии позиции)
$script:lastTpAt       = @{}   # instId → unix ts последней постановки TP
$script:tpCooldown     = 6     # сек, ждём синхронизации API после изменения TP

# Инициализируем счётчик покупок для всех инструментов
foreach ($inst in $config.instruments) { $script:buyCount[$inst] = 0 }

function Get-InstrumentInfoCached {
    param([string]$instId, $config)
    if ($script:infoCache.ContainsKey($instId)) { return $script:infoCache[$instId] }
    $info = Get-InstrumentInfo -instId $instId -config $config
    if ($info) { $script:infoCache[$instId] = $info }
    return $info
}

function Run-Bot {
    Write-Host "`n========== DCA FIBO ==========" -ForegroundColor Magenta

    # Показываем план Фибоначчи один раз для наглядности
    $maxBuys = if ($config.max_fibo_buys) { [int]$config.max_fibo_buys } else { 6 }
    $plan = (1..$maxBuys | ForEach-Object { "#{0}:x$(Get-FibNumber -n $_)" }) -join " | "
    Write-Host "  Fibo plan ($maxBuys buys): $plan  [base $($config.buy_size_usd) USD]" -ForegroundColor DarkCyan

    if (-not $authOk) { Log "Auth ne proshel" "WARN"; return }

    foreach ($instId in $config.instruments) {

        $openPos = Get-OpenPosition -instId $instId -config $config
        $info    = Get-InstrumentInfoCached -instId $instId -config $config
        if (-not $info) { Log "Net info dlya $instId" "WARN"; continue }
        $ctVal = if ($info.ctVal) { [decimal]$info.ctVal } else { 1 }

        $moveOrders = Get-ActiveAlgoOrders -instId $instId -config $config -ordType "move_order_stop"
        if ($null -eq $moveOrders) {
            Log "$instId : ne udalos poluchit algo-ordera -- propuskaem" "WARN"
            continue
        }
        $trailBuys  = $moveOrders | Where-Object { $_.side -eq "buy" }
        $trailSells = $moveOrders | Where-Object { $_.side -eq "sell" }
        $hasTrailBuy = $trailBuys.Count -gt 0
        $hasTrailTP  = $trailSells.Count -gt 0

        $ticker = Get-Ticker -instId $instId -config $config
        if (-not $ticker) { continue }
        $price = [decimal]$ticker.last

        # --- Детекция закрытия позиции → сброс счётчика ---
        if ($script:prevPositions.ContainsKey($instId) -and $script:prevPositions[$instId] -and -not $openPos) {
            $prev    = $script:prevPositions[$instId]
            $entryPx = [decimal]$prev.avgPx
            $posAmt  = [math]::Abs([decimal]$prev.pos)
            $pnlPct  = [math]::Round((($price - $entryPx) / $entryPx) * 100, 2)
            $pnl     = [math]::Round(($price - $entryPx) * $posAmt * $ctVal, 4)

            Write-Host ("  {0,-24} | CLOSED entry={1} close={2} P&L={3} ({4}%) | buys={5}" -f $instId, $entryPx, $price, $pnl, $pnlPct, $script:buyCount[$instId]) -ForegroundColor $(if ($pnlPct -gt 0) { 'Green' } else { 'Red' })
            Write-TradeLog -event "CLOSED" -instId $instId -side "LONG" -price $price -sz $posAmt -pnl $pnl -pnlPct $pnlPct -detail "total_buys=$($script:buyCount[$instId])" -config $config

            # Сбрасываем счётчик Фибоначчи при закрытии позиции
            $script:buyCount[$instId] = 0
            Log "$instId : buyCount сброшен до 0" "DEBUG"

            # Отменяем зависшие ордера
            foreach ($ordType in @("conditional","move_order_stop")) {
                $orphans = Get-ActiveAlgoOrders -instId $instId -config $config -ordType $ordType
                if ($orphans -and $orphans.Count -gt 0) {
                    Log "Otmenyaem $($orphans.Count) $ordType dlya $instId" "WARN"
                    Cancel-AlgoOrders -algos $orphans -instId $instId -config $config
                }
            }
        }
        $script:prevPositions[$instId] = $openPos

        $posAmt  = if ($openPos) { [math]::Abs([decimal]$openPos.pos) } else { 0 }
        $entryPx = if ($openPos) { [decimal]$openPos.avgPx } else { 0 }
        $curBuyCount = $script:buyCount[$instId]
        $maxBuys     = if ($config.max_fibo_buys) { [int]$config.max_fibo_buys } else { 6 }

        # ===== 1) Управление trailing TP на весь объём =====
        if ($posAmt -gt 0) {
            $tpCool = $script:lastTpAt.ContainsKey($instId) -and ((Get-Timestamp) - $script:lastTpAt[$instId] -lt $script:tpCooldown)
            if ($tpCool) {
                Log "$instId : TP nedavno izmenyon -- zhdjom" "DEBUG"
            } elseif ($trailSells.Count -gt 1) {
                Log "$instId : dublikaty TP ($($trailSells.Count)) -- chistim" "WARN"
                Cancel-AlgoOrders -algos $trailSells -instId $instId -config $config
                Place-TrailingTP -instId $instId -currentPx $price -sz $posAmt -entryPx $entryPx -info $info -config $config
            } elseif (-not $hasTrailTP) {
                Log "$instId : net trailing TP -- stavim" "WARN"
                Place-TrailingTP -instId $instId -currentPx $price -sz $posAmt -entryPx $entryPx -info $info -config $config
            } else {
                $existSz = [decimal]$trailSells[0].sz
                if ($existSz -ne $posAmt) {
                    Log "$instId : objem izmenilsya ($existSz -> $posAmt) -- perestavlyaem TP" "WARN"
                    Cancel-AlgoOrders -algos $trailSells -instId $instId -config $config
                    Place-TrailingTP -instId $instId -currentPx $price -sz $posAmt -entryPx $entryPx -info $info -config $config
                }
            }
        }

        # ===== 2) Мониторинг часового дипа → Фибо-докупка =====
        $hourOpen = Get-HourOpenPrice -instId $instId -config $config
        if ($hourOpen -and $hourOpen -gt 0) {
            $dropPct   = [math]::Round((($price - $hourOpen) / $hourOpen) * 100, 4)
            $threshold = [decimal]$config.hourly_dip_threshold_pct
            $color     = if ($dropPct -le $threshold) { 'Red' } elseif ($dropPct -le 0) { 'Yellow' } else { 'Green' }

            $nextBuy    = $curBuyCount + 1
            $nextFib    = if ($nextBuy -le $maxBuys) { Get-FibNumber -n $nextBuy } else { 0 }
            $nextUsd    = if ($nextFib -gt 0) { [decimal]$config.buy_size_usd * $nextFib } else { 0 }
            $buyTag     = if ($curBuyCount -ge $maxBuys) { " [MAX $maxBuys dostignut]" }
                          elseif ($hasTrailBuy)           { " [trail BUY aktiven]" }
                          else                            { " [next: #$nextBuy Fib=$nextFib x${nextUsd}usd]" }

            Write-Host ("{0,-24} | 1h: {1,7:F2}% | Cena: {2} | pos={3} | buys={4}/{5}{6}" -f "  $instId", $dropPct, $price, $posAmt, $curBuyCount, $maxBuys, $buyTag) -ForegroundColor $color

            $aboveAvg = ($posAmt -gt 0) -and ($price -ge $entryPx)

            if ($dropPct -le $threshold) {
                if ($hasTrailBuy) {
                    Write-Host "  .. $instId : prosadka est, trailing BUY uzhe aktiven (limit 1)" -ForegroundColor DarkGray
                } elseif ($curBuyCount -ge $maxBuys) {
                    Write-Host "  .. $instId : dostignut predel $maxBuys pokupok -- ne dokupaemsya" -ForegroundColor DarkGray
                } elseif ($aboveAvg) {
                    Write-Host "  .. $instId : cena $price >= srednej $entryPx -- ne usrednyaemsya vverkh" -ForegroundColor DarkGray
                } else {
                    Write-Host "  >> $instId : chasovoy dip $dropPct% -- Fibo dokupka #$nextBuy!" -ForegroundColor Red
                    Place-FiboTrailingBuy -instId $instId -price $price -dropPct $dropPct -info $info -config $config
                }
            }
        } else {
            Log "Net chasovoy svechi dlya $instId" "DEBUG"
        }
    }

    # Balance
    $b = Send-OkxRequest -Method "GET" -RequestPath "/api/v5/account/balance" -BodyJson "" -config $config
    if ($b -and $b.code -eq "0") {
        $acc=$b.data[0]; $usdt=$acc.details|Where-Object{$_.ccy -eq "USDT"}
        Write-Host "`n===== BALANCE =====" -ForegroundColor Cyan
        Write-Host "Total Equity : $($acc.totalEq) USDT" -ForegroundColor White
        if ($usdt) { Write-Host "USDT Available: $($usdt.availBal)" -ForegroundColor Green; Write-Host "USDT UPL: $($usdt.upl)" -ForegroundColor Yellow }
        Write-Host "==================`n" -ForegroundColor Cyan
    }
    Log "Cycle done." "OK"
}

while ($true) { Run-Bot; Start-Sleep -Seconds $config.rerun_interval_s }
