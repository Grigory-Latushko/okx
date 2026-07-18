# BUY-THE-DIP
param(
  [string]$ConfigPath = ".\config.json",
  [switch]$ForceLive,
  [switch]$DebugMode
)

if (-not $global:candleCache) { $global:candleCache = @{} }

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

# FIX: otmena zavisshikh algo-orderov -- ispravlen format massiva
function Cancel-OrphanAlgos {
    param([string]$instId, $config)
    foreach ($ordType in @("conditional", "move_order_stop")) {
        $resp = Send-OkxRequest -Method "GET" -RequestPath "/api/v5/trade/orders-algo-pending?instId=$instId&ordType=$ordType&instType=SWAP" -BodyJson "" -config $config
        if ($resp -and $resp.data -and $resp.data.Count -gt 0) {
            Log "Otmenyaem $($resp.data.Count) $ordType dlya $instId" "WARN"
            $payload = @($resp.data | ForEach-Object { @{ instId = $instId; algoId = $_.algoId } })
            $body = ConvertTo-Json $payload -Compress
            if ($body -notmatch '^\[') { $body = "[$body]" }
            Send-OkxRequest -Method "POST" -RequestPath "/api/v5/trade/cancel-algos" -BodyJson $body -config $config | Out-Null
        }
    }
}

function Write-TradeLog {
    param([string]$event, [string]$instId, [string]$side, [decimal]$price, [decimal]$sz, [decimal]$dipPct = 0, [decimal]$tp = 0, [decimal]$sl = 0, [decimal]$pnl = 0, [decimal]$pnlPct = 0, [string]$reason = "", $config)
    $logFile = if ($config.log_file) { $config.log_file } else { ".\trades.csv" }
    if (-not (Test-Path $logFile)) { "timestamp,event,instId,side,price,sz,dip_pct,tp,sl,pnl,pnl_pct,reason`n" | Out-File -FilePath $logFile -Encoding utf8 -NoNewline }
    $ts = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ss")
    "$ts,$event,$instId,$side,$price,$sz,$dipPct,$tp,$sl,$pnl,$pnlPct,$reason`n" | Out-File -FilePath $logFile -Encoding utf8 -Append -NoNewline
    Log "LOG: $event $instId @ $price dip=$dipPct% pnl=$pnl ($pnlPct%)" "OK"
}

function Place-TPSL {
    param([string]$instId, [decimal]$entryPx, [decimal]$sz, $info, $config)
    $tick    = if ($info -and $info.tickSz) { [decimal]$info.tickSz } else { $null }
    $tpPct   = [decimal]$config.tp_pct / 100
    $slPct   = [decimal]$config.sl_pct / 100
    $tpPrice = RoundPriceToTick -price ([decimal]($entryPx * (1 + $tpPct))) -tick $tick
    $slPrice = RoundPriceToTick -price ([decimal]($entryPx * (1 - $slPct))) -tick $tick
    $szStr   = [string]$sz
    $tpType  = if ($config.tp_trigger_type) { $config.tp_trigger_type } else { "last" }
    $tpOrdPx = if ($config.tp_exec_market -ne $false) { "-1" } else { [string]$tpPrice }
    $slOrdPx = if ($config.tp_exec_market -ne $false) { "-1" } else { [string]$slPrice }

    Write-Host "  >> TP=$tpPrice (+$([math]::Round($tpPct*100,2))%) SL=$slPrice (-$([math]::Round($slPct*100,2))%)" -ForegroundColor Yellow

    $rTp = Send-OkxRequest -Method "POST" -RequestPath "/api/v5/trade/order-algo" -BodyJson (@{ instId=$instId; tdMode=$config.mgnMode; side="sell"; ordType="conditional"; sz=$szStr; tpTriggerPx=[string]$tpPrice; tpTriggerPxType=$tpType; tpOrdPx=$tpOrdPx } | ConvertTo-Json -Compress) -config $config
    if ($rTp -and $rTp.code -eq "0") { Log "OK: TP @ $tpPrice" "OK" } elseif ($rTp -and $rTp.dryRun) { Log "DryRun: TP" "WARN" } else { Log "ERR TP: $($rTp.msg)" "ERROR" }

    $rSl = Send-OkxRequest -Method "POST" -RequestPath "/api/v5/trade/order-algo" -BodyJson (@{ instId=$instId; tdMode=$config.mgnMode; side="sell"; ordType="conditional"; sz=$szStr; slTriggerPx=[string]$slPrice; slTriggerPxType=$tpType; slOrdPx=$slOrdPx } | ConvertTo-Json -Compress) -config $config
    if ($rSl -and $rSl.code -eq "0") { Log "OK: SL @ $slPrice" "OK" } elseif ($rSl -and $rSl.dryRun) { Log "DryRun: SL" "WARN" } else { Log "ERR SL: $($rSl.msg)" "ERROR" }
}

function Open-DipOrder {
    param([string]$instId, [decimal]$price, [decimal]$dipPct, $config)
    $info  = Get-InstrumentInfo -instId $instId -config $config
    if (-not $info) { Log "Net info dlya $instId" "ERROR"; return $false }
    $ctVal = if ($info.ctVal) { [decimal]$info.ctVal } else { 1 }
    $minSz = if ($info.minSz) { [decimal]$info.minSz } elseif ($info.lotSz) { [decimal]$info.lotSz } else { 0.01 }
    $step  = $minSz
    $tick  = if ($info.tickSz) { [decimal]$info.tickSz } else { $null }
    $notional = [decimal]($config.position_size_usd * $config.leverage)
    $sz = Set-ToStep -value ([decimal]($notional / ($ctVal * $price))) -step $step
    if ($sz -le 0 -or $sz -lt $minSz) { $sz = $minSz }
    $tpPct   = [decimal]$config.tp_pct / 100
    $slPct   = [decimal]$config.sl_pct / 100
    $tpPrice = RoundPriceToTick -price ([decimal]($price * (1 + $tpPct))) -tick $tick
    $slPrice = RoundPriceToTick -price ([decimal]($price * (1 - $slPct))) -tick $tick
    Write-Host ("  {0,-24} | DROP={1}% | BUY {2} @ {3} | TP={4} SL={5}" -f $instId, $dipPct, $sz, $price, $tpPrice, $slPrice) -ForegroundColor Yellow
    $pm = $script:posMode
    $levBody = @{ instId=$instId; lever=([string]$config.leverage); mgnMode="isolated" }
    if ($pm -and ($pm.ToString().ToLower() -match "long_short|hedge")) { $levBody.posSide = "long" }
    Send-OkxRequest -Method "POST" -RequestPath "/api/v5/account/set-leverage" -BodyJson ($levBody | ConvertTo-Json -Compress) -config $config | Out-Null
    $order = @{ instId=$instId; tdMode=$config.mgnMode; side="buy"; ordType="market"; sz=([string]$sz) }
    if ($pm -and ($pm.ToString().ToLower() -match "long_short|hedge")) { $order.posSide = "long" }
    $resp = Send-OkxRequest -Method "POST" -RequestPath "/api/v5/trade/order" -BodyJson ($order | ConvertTo-Json -Compress) -config $config
    if ($resp -and $resp.dryRun) {
        Log "DryRun: $instId LONG $sz @ $price" "WARN"
        Write-TradeLog -event "OPEN" -instId $instId -side "LONG" -price $price -sz $sz -dipPct $dipPct -tp $tpPrice -sl $slPrice -config $config
        Place-TPSL -instId $instId -entryPx $price -sz $sz -info $info -config $config
        return $true
    } elseif (-not $resp -or ($resp.code -and $resp.code -ne "0")) {
        Log "ERR open $instId : $($resp.msg)" "ERROR"; return $false
    } else {
        Log "OK: $instId LONG opened" "OK"
        Write-TradeLog -event "OPEN" -instId $instId -side "LONG" -price $price -sz $sz -dipPct $dipPct -tp $tpPrice -sl $slPrice -config $config
        Place-TPSL -instId $instId -entryPx $price -sz $sz -info $info -config $config
        return $true
    }
}

# ======================== MAIN ========================
$config = Get-Content $configPath -Raw | ConvertFrom-Json
foreach ($field in @("api_key","secret_key","passphrase","instruments")) {
    if (-not $config.$field) { Log "Config: otsutstvuet '$field'" "ERROR"; exit 1 }
}
try {
    $tr = Send-OkxRequest -Method "GET" -RequestPath "/api/v5/public/time" -BodyJson "" -config $config
    if ($tr -and $tr.data) { $d = [math]::Abs(([datetime]::Parse($tr.data[0].iso).ToUniversalTime() - (Get-Date).ToUniversalTime()).TotalSeconds); if ($d -gt 30) { Log "Clock drift >30s" "WARN" } }
} catch {}

$authOk = $true
$balResp = Send-OkxRequest -Method "GET" -RequestPath "/api/v5/account/balance" -BodyJson "" -config $config
if ($null -eq $balResp) { $authOk = $false; Log "Auth failed" "WARN" } else { Log "Auth OK" "DEBUG" }
$posMode = $null
if ($authOk) { $posMode = Get-AccountConfig -config $config }

$script:prevPositions = @{}
# FIX: kesh info chtoby ne delatj API vyzov kazhdyj cikl
$script:infoCache = @{}

function Run-Bot {
    Write-Host "`n========== BUY-THE-DIP ==========" -ForegroundColor Magenta
    if (-not $authOk) { Log "Auth ne proshel" "WARN"; return }

    foreach ($instId in $config.instruments) {

        $openPos = Get-OpenPosition -instId $instId -config $config
        $hasPos  = $null -ne $openPos

        # FIX: detekciya zakrytiya + ochistka zavisshikh orderov
        if ($script:prevPositions.ContainsKey($instId) -and $script:prevPositions[$instId] -and -not $hasPos) {
            $prev    = $script:prevPositions[$instId]
            $entryPx = [decimal]$prev.avgPx
            $ticker  = Get-Ticker -instId $instId -config $config
            $closePx = if ($ticker) { [decimal]$ticker.last } else { $entryPx }
            $posAmt  = [decimal]$prev.pos
            $pnl     = [math]::Round(($closePx - $entryPx) * $posAmt, 4)
            $pnlPct  = [math]::Round((($closePx - $entryPx) / $entryPx) * 100, 2)
            $reason  = if ($pnlPct -gt 0) { "TP" } else { "SL" }
            Write-Host ("  {0,-24} | CLOSED entry={1} close={2} P&L={3}% -> {4}" -f $instId, $entryPx, $closePx, $pnlPct, $reason) -ForegroundColor $(if ($pnlPct -gt 0) { 'Green' } else { 'Red' })
            Write-TradeLog -event "CLOSE" -instId $instId -side "LONG" -price $closePx -sz ([math]::Abs($posAmt)) -pnl $pnl -pnlPct $pnlPct -reason $reason -config $config
            # FIX: otmenyaem zavisshie TP/SL ordera
            Cancel-OrphanAlgos -instId $instId -config $config
        }
        $script:prevPositions[$instId] = $openPos

        if ($hasPos) {
            $entryPx   = [decimal]$openPos.avgPx
            $ticker    = Get-Ticker -instId $instId -config $config
            $currentPx = if ($ticker) { [decimal]$ticker.last } else { $entryPx }
            $pnlPct    = [math]::Round((($currentPx - $entryPx) / $entryPx) * 100, 2)
            Write-Host ("  {0,-24} | LONG entry={1} now={2} P&L={3}%" -f $instId, $entryPx, $currentPx, $pnlPct) -ForegroundColor $(if ($pnlPct -ge 0) { 'Green' } else { 'Yellow' })
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
            Write-Host "  >> $instId : $dropPct% -- BUY!" -ForegroundColor Red
            Open-DipOrder -instId $instId -price $price -dipPct $dropPct -config $config
        }
    }

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
