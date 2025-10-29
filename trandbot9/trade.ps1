<#
trade.ps1 — версия с поддержкой posSide в long_short_mode.
#>

param(
  [string]$ConfigPath = ".\config.json",
  [switch]$ForceLive,
  [switch]$DebugMode
)

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
  param([string]$Method, [string]$RequestPath, [string]$BodyJson, $Cfg)

  $ts = Get-NowTimestamp
  $sig = Sign-OkxRequest -Secret $Cfg.secret_key -Timestamp $ts -Method $Method.ToUpper() -RequestPath $RequestPath -Body $BodyJson

  $headers = @{
    "OK-ACCESS-KEY"        = $Cfg.api_key
    "OK-ACCESS-SIGN"       = $sig
    "OK-ACCESS-TIMESTAMP"  = $ts
    "OK-ACCESS-PASSPHRASE" = $Cfg.passphrase
    "Content-Type"         = "application/json"
  }
  if ($Cfg.simulated -ne $null) {
    if ($Cfg.simulated -eq $true) { $headers["x-simulated-trading"] = "1" } else { $headers["x-simulated-trading"] = "0" }
  }

  $url = $Cfg.baseUrl.TrimEnd('/') + $RequestPath
  $maskedHeaders = @{}
  foreach ($k in $headers.Keys) {
    $v = $headers[$k]
    if ($k -match "KEY|SIGN|PASSPHRASE") { $maskedHeaders[$k] = Mask($v) } else { $maskedHeaders[$k] = $v }
  }

  Log "Request: $Method $url" "DEBUG"
  Log "Body: $BodyJson" "DEBUG"
  Log "Headers: $($maskedHeaders | ConvertTo-Json -Compress)" "DEBUG"

  if ($Cfg.dryRun -and -not $ForceLive) {
    Log "DryRun enabled — запрос не отправлен" "WARN"
    return @{ dryRun = $true; method = $Method; url = $url; headers = $maskedHeaders; body = $BodyJson }
  }

  try {
    if ($Method.ToUpper() -eq "GET") { $resp = Invoke-RestMethod -Method Get -Uri $url -Headers $headers -ErrorAction Stop }
    else { $resp = Invoke-RestMethod -Method Post -Uri $url -Headers $headers -Body $BodyJson -ErrorAction Stop }
    Log "HTTP OK for $RequestPath" "OK"
    if ($DebugMode) { Log "Response:`n$($resp | ConvertTo-Json -Depth 8)" "DEBUG" }
    return $resp
  } catch {
    Log "Request failed: $Method $url" "ERROR"
    Log $_.Exception.Message "ERROR"
    if ($_.Exception.Response) {
      try { $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream()); $body = $reader.ReadToEnd(); Log "Response body: $body" "DEBUG" } catch {}
    }
    return $null
  }
}

function Get-Price { param($instId, $Cfg) Log "Получаем цену для $instId" "DEBUG"; $resp = Send-OkxRequest -Method "GET" -RequestPath "/api/v5/market/ticker?instId=$($instId)" -BodyJson "" -Cfg $Cfg; if ($resp -and $resp.data -and $resp.data.Count -ge 1) { $p = [decimal]$resp.data[0].last; Log "Цена $instId = $p" "OK"; return $p } Log "Не удалось получить цену $instId" "WARN"; return $null }

function Get-InstrumentInfo { param($instId, $Cfg) Log "Получаем информацию об инструменте $instId" "DEBUG"; $resp = Send-OkxRequest -Method "GET" -RequestPath "/api/v5/public/instruments?instType=SWAP&instId=$($instId)" -BodyJson "" -Cfg $Cfg; if ($resp -and $resp.data -and $resp.data.Count -ge 1) { return $resp.data[0] } return $null }

function Round-ToStep { param($value, $step) if ($step -eq 0 -or $null -eq $step) { return [math]::Round($value, 8) } $quotient = [math]::Floor(($value / $step) + 0.0000000001); $rounded = $quotient * $step; return [decimal]$([math]::Round([double]$rounded, 8)) }
function Round-ToStepCeil { param($value, $step) if ($step -eq 0 -or $null -eq $step) { return [math]::Round($value, 8) } $quotient = [math]::Ceiling(($value / $step) - 0.000000000001); $rounded = $quotient * $step; return [decimal]$([math]::Round([double]$rounded, 8)) }

function Get-AccountConfig {
  param($Cfg)
  Log "Получаем конфиг аккаунта (/api/v5/account/config)" "DEBUG"
  $resp = Send-OkxRequest -Method "GET" -RequestPath "/api/v5/account/config" -BodyJson "" -Cfg $Cfg
  if ($resp -and $resp.data -and $resp.data.Count -ge 1) {
    # try to find posMode in response
    $d = $resp.data[0]
    if ($d.psMode) { return $d.psMode }     # some variants
    if ($d.posMode) { return $d.posMode }
    if ($d.positionMode) { return $d.positionMode }
    return $resp.data
  }
  return $null
}

function Set-Leverage { param($instId, $lever, $mgnMode, $Cfg) $bodyObj = @{ instId = $instId; lever = ([string]$lever); mgnMode = $mgnMode }; $body = $bodyObj | ConvertTo-Json -Compress; Log "Setting leverage for $instId lever=$lever mgnMode=$mgnMode" "DEBUG"; return Send-OkxRequest -Method "POST" -RequestPath "/api/v5/account/set-leverage" -BodyJson $body -Cfg $Cfg }

# ---------------- MAIN ----------------
if (-not (Test-Path $ConfigPath)) { Log "Config file not found: $ConfigPath" "ERROR"; exit 1 }
$cfgRaw = Get-Content $ConfigPath -Raw
try { $cfg = $cfgRaw | ConvertFrom-Json } catch { Log "Invalid JSON in config file: $_" "ERROR"; exit 1 }

function GetCfgVal($obj, $names, $default) { foreach ($n in $names) { if ($obj.PSObject.Properties.Name -contains $n) { return $obj.$n } } return $default }

$simFlag = GetCfgVal $cfg @("simulated","sim","demo","simulated_trading") $null
$simBool = $null
if ($simFlag -ne $null) { $simBool = [bool]$simFlag } else { $simBool = $null }

$Cfg = [PSCustomObject]@{
  api_key           = GetCfgVal $cfg @("api_key","apiKey","apikey") $null
  secret_key        = GetCfgVal $cfg @("secret_key","secretKey","secret") $null
  passphrase        = GetCfgVal $cfg @("passphrase","passPhrase") $null
  position_size_usd = [decimal](GetCfgVal $cfg @("position_size_usd","positionSizeUsd","position_size") 1)
  leverage          = [decimal](GetCfgVal $cfg @("leverage","lev") 1)
  set_leverage      = [bool](GetCfgVal $cfg @("set_leverage","setLeverage") $false)
  mgnMode           = GetCfgVal $cfg @("mgnMode","mgn_mode","margin_mode") "cross"
  dryRun            = [bool](GetCfgVal $cfg @("dryRun","dry_run","dry_run") $true)
  baseUrl           = GetCfgVal $cfg @("baseUrl","base_url","base") "https://www.okx.com"
  instruments       = GetCfgVal $cfg @("instruments","instrument_list","insts") @()
  force_min_size    = [bool](GetCfgVal $cfg @("force_min_size","forceMinSize") $false)
  force_threshold_factor = [decimal](GetCfgVal $cfg @("force_threshold_factor","forceThresholdFactor") 3)
  simulated         = $simBool
}

$cfgMasked = @{ api_key = Mask($Cfg.api_key); secret_key = Mask($Cfg.secret_key); passphrase = Mask($Cfg.passphrase); position_size_usd = $Cfg.position_size_usd; leverage = $Cfg.leverage; set_leverage = $Cfg.set_leverage; dryRun = $Cfg.dryRun; baseUrl = $Cfg.baseUrl; instruments = $Cfg.instruments; force_min_size = $Cfg.force_min_size; force_threshold_factor = $Cfg.force_threshold_factor; simulated = $Cfg.simulated }
Log "Loaded config: $($cfgMasked | ConvertTo-Json -Depth 5)" "DEBUG"

if (-not $Cfg.api_key -or -not $Cfg.secret_key -or -not $Cfg.passphrase) { Log "api_key / secret_key / passphrase must be provided in config file" "ERROR"; exit 1 }
if (-not $Cfg.instruments -or $Cfg.instruments.Count -eq 0) { Log "No instruments provided in config -> 'instruments' array" "ERROR"; exit 1 }

# Check server time
try {
  $timeResp = Send-OkxRequest -Method "GET" -RequestPath "/api/v5/public/time" -BodyJson "" -Cfg $Cfg
  if ($timeResp -and $timeResp.data -and $timeResp.data.Count -ge 1) {
    $serverIso = $timeResp.data[0].iso
    try { $serverTs = [datetime]::ParseExact($serverIso, "yyyy-MM-ddTHH:mm:ss.fffZ", $null).ToUniversalTime() } catch { $serverTs = [datetime]::Parse($serverIso).ToUniversalTime() }
    $localUtc = (Get-Date).ToUniversalTime(); $delta = [math]::Abs(($serverTs - $localUtc).TotalSeconds)
    Log "Server time: $serverTs, Local UTC: $localUtc, delta(s) = $delta" "DEBUG"
    if ($delta -gt 30) { Log "Local time differs by >30s. Sync clock (NTP) to avoid timestamp errors." "WARN" }
  }
} catch {}

# Auth check + account config (posMode)
$authOk = $true
$balResp = Send-OkxRequest -Method "GET" -RequestPath "/api/v5/account/balance" -BodyJson "" -Cfg $Cfg
if ($null -eq $balResp) { Log "Warning: failed to call private endpoint /account/balance. Check API key permissions, IP whitelist, or environment (demo vs live)." "WARN"; $authOk = $false } else { Log "/account/balance OK (auth check passed)" "DEBUG" }

$posMode = $null
if ($authOk) {
  $cfgResp = Get-AccountConfig -Cfg $Cfg
  if ($cfgResp) {
    Log "Account config posMode: $cfgResp" "DEBUG"
    $posMode = $cfgResp
  } else {
    Log "Could not fetch account config (posMode). Will default to including posSide only when necessary." "DEBUG"
  }
}

# main loop
foreach ($instId in $Cfg.instruments) {
  Write-Host "`n=== Processing $instId ===" -ForegroundColor White

  $price = Get-Price -instId $instId -Cfg $Cfg
  if ($null -eq $price) { Log "Skipping $instId — price not available" "WARN"; continue }

  $info = Get-InstrumentInfo -instId $instId -Cfg $Cfg
  $contractMode = $false; $ctVal = $null; $step = $null
  if ($info) {
    if ($info.ctVal) { $ctVal = [decimal]$info.ctVal; $contractMode = $true }
    if ($info.minSz) { $step = [decimal]$info.minSz } elseif ($info.lotSz) { $step = [decimal]$info.lotSz } elseif ($info.sz) { $step = [decimal]$info.sz }
    Log "Instrument meta: ctVal=$ctVal, step/minSz=$step" "DEBUG"
  }

  $notional_desired = [decimal]($Cfg.position_size_usd * $Cfg.leverage)
  Log "Desired notional = $notional_desired USD" "DEBUG"

  if ($contractMode -and $ctVal -ne $null -and $ctVal -gt 0) {
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
    if ($Cfg.force_min_size -and $step -gt 0) {
      if ($contractMode -and $ctVal -ne $null) { $notional_if_forced = [math]::Round(($step * $ctVal * $price), 8) } else { $notional_if_forced = [math]::Round(($step * $price), 8) }
      $threshold = $Cfg.force_threshold_factor
      if ($notional_if_forced -gt ($notional_desired * $threshold)) { Log "Forcing minimal step would create notional $notional_if_forced USD > $threshold × desired. Skipping" "WARN"; continue }
      Log "rawSize < step; forcing sz = step ($step). forced notional = $notional_if_forced USD" "WARN"
      $sz = $step
    } else { Log "After rounding sz = 0 and force_min_size is false -> skipping $instId" "WARN"; continue }
  }

  if ($contractMode -and $ctVal -ne $null) { $notional_actual = [math]::Round(($sz * $ctVal * $price), 8) } else { $notional_actual = [math]::Round(($sz * $price), 8) }
  Log "Final: sz = $sz (step $step). notional_actual = $notional_actual USD" "INFO"

  # optional set leverage
  if ($Cfg.set_leverage -and $Cfg.leverage -gt 1) {
    if (-not $authOk) { Log "Skipping set-leverage because earlier auth check failed" "WARN" } else { $setResp = Set-Leverage -instId $instId -lever $Cfg.leverage -mgnMode $Cfg.mgnMode -Cfg $Cfg; if ($null -eq $setResp) { Log "Failed to set leverage; skipping" "ERROR"; continue } }
  }

  # prepare order; add posSide if account posMode requires it
  $side = "buy"
  $orderObj = @{ instId = $instId; tdMode = $Cfg.mgnMode; side = $side; ordType = "market"; sz = ([string]$sz) }

  # include posSide when account in long_short_mode and instrument is contract
  if ($contractMode -and $posMode -ne $null) {
    $pm = $posMode.ToString().ToLower()
    if ($pm -like "*long*" -or $pm -like "*long_short*") {
      # when account is long/short (hedged), posSide is required for open/close orders: long or short
      $orderObj.posSide = if ($side -eq "buy") { "long" } else { "short" }
      Log "posMode=$posMode -> adding posSide='$($orderObj.posSide)' to order" "DEBUG"
    } else {
      Log "posMode=$posMode -> not adding posSide (net mode detected)" "DEBUG"
    }
  } else {
    # if posMode unknown, conservative: add posSide for contract buys
    if ($contractMode) {
      $orderObj.posSide = if ($side -eq "buy") { "long" } else { "short" }
      Log "posMode unknown -> adding posSide='$($orderObj.posSide)' (conservative)" "DEBUG"
    }
  }

  $orderJson = $orderObj | ConvertTo-Json -Compress
  Log "Order body: $orderJson" "DEBUG"

  if (-not $authOk) { Log "Auth check failed earlier — not placing real orders" "WARN"; continue }

  $resp = Send-OkxRequest -Method "POST" -RequestPath "/api/v5/trade/order" -BodyJson $orderJson -Cfg $Cfg
  if ($resp -and $resp.dryRun) { Log "DRY RUN — order not sent (preview)" "WARN"; ($resp | ConvertTo-Json -Depth 5) | Write-Host }
  elseif ($null -eq $resp) { Log "Order failed or empty response" "ERROR" }
  else { Log "Order response:" "OK"; ($resp | ConvertTo-Json -Depth 6) | Write-Host }

  Start-Sleep -Milliseconds 500
}

Log "Done." "OK"
