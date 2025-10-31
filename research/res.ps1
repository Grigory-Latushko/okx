<#
.SYNOPSIS
  Анализ паттернов RSI (RSI6/RSI14/RSI30) для OKX (1H).
.DESCRIPTION
  - Загружает конфиг из JSON.
  - Получает свечи (OKX public API), считает RSI, рассчитывает future returns,
    ищет лучшие интервалы и комбинации для входа в ЛОНГ.
.NOTES
  - Не публикуйте реальные ключи в открытых чатах. Рекомендуется dryRun=true при тестах.
  - Скрипт совместим с Windows PowerShell 5.1 и PowerShell 7+.
#>

param(
    [string]$ConfigPath = ".\config_60m_res.json",
    [switch]$ForceLive,
    [switch]$DebugMode
)

Remove-Item data\*.csv

# ----------------------------
# Helpers & Logging
# ----------------------------
function Get-Timestamp { return [int][double]::Parse((Get-Date -UFormat %s)) }
function Format-Time { return (Get-Date -Format "yyyy-MM-dd HH:mm:ss") }

function Mask {
    param([string]$s)
    if (-not $s) { return "" }
    if ($s.Length -le 8) { return $s.Substring(0,2) + "..." }
    return $s.Substring(0,4) + "..." + $s.Substring($s.Length-4,4)
}

function Log {
    param([string]$msg, [string]$level = "INFO")
    $ts = Format-Time
    switch ($level.ToUpper()) {
        "INFO"  { Write-Host "[$ts][INFO ] $msg" -ForegroundColor Gray }
        "OK"    { Write-Host "[$ts][ OK  ] $msg" -ForegroundColor Green }
        "WARN"  { Write-Host "[$ts][WARN ] $msg" -ForegroundColor Yellow }
        "ERROR" { Write-Host "[$ts][ERR  ] $msg" -ForegroundColor Red }
        "DEBUG" { if ($DebugMode) { Write-Host "[$ts][DBG  ] $msg" -ForegroundColor Cyan } }
        default { Write-Host "[$ts][INFO ] $msg" -ForegroundColor Gray }
    }
}

# ----------------------------
# Load config
# ----------------------------
if (-not (Test-Path $ConfigPath)) {
    Log "Config not found at $ConfigPath" "ERROR"
    throw "Config file not found: $ConfigPath"
}

try {
    $configJson = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
} catch {
    Log "Failed to parse config.json: $($_.Exception.Message)" "ERROR"
    throw $_
}

# Masked view for debug
$displayConfig = @{
    api_key = Mask($configJson.api_key)
    secret_key = Mask($configJson.secret_key)
    passphrase = Mask($configJson.passphrase)
    baseUrl = $configJson.baseUrl
    simulated = $configJson.simulated
    dryRun = $configJson.dryRun
}
if ($DebugMode) { Log ("Loaded config: " + ($displayConfig | ConvertTo-Json -Compress)) "DEBUG" }

# ----------------------------
# Globals
# ----------------------------
if (-not $global:candleCache) { $global:candleCache = @{} }

# ----------------------------
# OKX signing & requests
# ----------------------------
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
    param([string]$Method, [string]$RequestPath, [string]$BodyJson = "", $config)

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

    $maskedHeaders = @{}
    foreach ($k in $headers.Keys) {
        $v = $headers[$k]
        if ($k -match "KEY|SIGN|PASSPHRASE") { $maskedHeaders[$k] = Mask($v) } else { $maskedHeaders[$k] = $v }
    }

    Log "Request: $Method $url" "DEBUG"
    Log "Headers: $($maskedHeaders | ConvertTo-Json -Compress)" "DEBUG"
    if ($BodyJson) { Log "Body: $BodyJson" "DEBUG" }

    if ($config.dryRun -and -not $ForceLive) {
        Log "DryRun enabled — запрос не отправлен" "WARN"
        return @{ dryRun = $true; method = $Method; url = $url; headers = $maskedHeaders; body = $BodyJson }
    }

    try {
        if ($Method.ToUpper() -eq "GET") {
            $resp = Invoke-RestMethod -Method Get -Uri $url -Headers $headers -ErrorAction Stop
        } else {
            $resp = Invoke-RestMethod -Method Post -Uri $url -Headers $headers -Body $BodyJson -ErrorAction Stop
        }
        Log "HTTP OK for $RequestPath" "OK"
        if ($DebugMode) { Log ("Response: " + ($resp | ConvertTo-Json -Depth 5)) "DEBUG" }
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

# ----------------------------
# Market helpers
# ----------------------------
function Get-Price {
    param($instId, $config)
    Log "Получаем цену для $instId" "DEBUG"
    $resp = Send-OkxRequest -Method "GET" -RequestPath "/api/v5/market/ticker?instId=$($instId)" -BodyJson "" -config $config
    if (-not $resp) { Log "Нет ответа от API для $instId" "WARN"; return $null }
    if ($resp.code -and $resp.code -ne "0") { Log "Ошибка OKX code=$($resp.code) msg=$($resp.msg)" "WARN"; return $null }
    if ($resp.data -and $resp.data.Count -ge 1) {
        $p = [decimal]$resp.data[0].last
        Log "Цена $instId = $p" "OK"
        return $p
    }
    Log "Пустой массив data для $instId" "WARN"
    return $null
}

function Get-InstrumentInfo {
    param($instId, $config)
    Log "Получаем информацию об инструменте $instId" "DEBUG"
    $resp = Send-OkxRequest -Method "GET" -RequestPath "/api/v5/public/instruments?instType=SWAP&instId=$($instId)" -BodyJson "" -config $config
    if ($resp -and $resp.data -and $resp.data.Count -ge 1) { return $resp.data[0] }
    return $null
}

# ----------------------------
# Candles retrieval (with cache)
# ----------------------------
function Get-Candles {
    param(
        [string]$symbol,
        [int]$limit = 120,
        [string]$period = "1H"
    )

    # Validate incoming types
    if (-not $symbol) { Log "Get-Candles: symbol is empty" "ERROR"; return @() }
    if (-not $period) { $period = "1H" }

    $cacheKey = "$symbol-$period-$limit"
    if ($global:candleCache.ContainsKey($cacheKey)) {
        $cached = $global:candleCache[$cacheKey]
        $age = (Get-Timestamp) - $cached.Timestamp
        if ($age -lt 60) {
            Log "Using cached candles for $symbol (age ${age}s)" "DEBUG"
            return $cached.Candles
        }
    }

    try {
        $url = "https://www.okx.com/api/v5/market/candles?instId=$symbol&bar=$period&limit=$limit"
        Log "Fetching candles URL: $url" "DEBUG"
        $res = Invoke-RestMethod -Uri $url -Method Get -ErrorAction Stop
        if (-not $res.data) {
            Log ("Empty candles response. Full resp: " + ($res | ConvertTo-Json -Depth 3)) "DEBUG"
            return @()
        }

        $candles = $res.data | ForEach-Object {
            [PSCustomObject]@{
                Timestamp = [long]($_[0])  # ms
                Open      = [double]$_[1]
                High      = [double]$_[2]
                Low       = [double]$_[3]
                Close     = [double]$_[4]
                Volume    = [double]$_[5]
            }
        } | Sort-Object Timestamp

        $global:candleCache[$cacheKey] = @{ Candles = $candles; Timestamp = Get-Timestamp }
        Log "Fetched $($candles.Count) candles for $symbol" "OK"
        return $candles
    } catch {
        Log "Ошибка получения свечей для ${symbol}: $($_.Exception.Message)" "ERROR"
        return @()
    }
}

# ----------------------------
# RSI calculation
# ----------------------------
function Get-RSI {
    param(
        [double[]]$prices,
        [int]$period = 14
    )
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
    $rsi.Add([Math]::Round(100 - (100 / (1 + $rs)), 4))

    for ($i = $period; $i -lt $gains.Count; $i++) {
        $avgGain = (($avgGain * ($period - 1)) + $gains[$i]) / $period
        $avgLoss = (($avgLoss * ($period - 1)) + $losses[$i]) / $period
        $rs = if ($avgLoss -ne 0) { $avgGain / $avgLoss } else { [double]::PositiveInfinity }
        $rsi.Add([Math]::Round(100 - (100 / (1 + $rs)), 4))
    }

    return $rsi
}

# ----------------------------
# Robust stats (for PS 5.1 compatibility)
# ----------------------------
function Get-Stats {
    param([double[]]$values)
    if (-not $values) {
        return [PSCustomObject]@{ Count=0; Mean=$null; Median=$null; StdDev=$null; Sum=$null }
    }

    $arr = $values | Where-Object { $_ -ne $null } | ForEach-Object { [double]$_ }
    $count = $arr.Count
    if ($count -eq 0) { return [PSCustomObject]@{ Count=0; Mean=$null; Median=$null; StdDev=$null; Sum=$null } }

    $sum = 0.0
    foreach ($v in $arr) { $sum += $v }
    $mean = $sum / $count

    $sorted = $arr | Sort-Object
    if ($count % 2 -eq 1) {
        $median = $sorted[([int](([double]$count / 2)))]
    } else {
        $i = $count / 2
        $median = (($sorted[$i - 1] + $sorted[$i]) / 2.0)
    }

    $ss = 0.0
    foreach ($v in $arr) { $ss += ([double]($v - $mean) * [double]($v - $mean)) }
    $std = [math]::Sqrt($ss / $count)

    return [PSCustomObject]@{
        Count  = $count
        Mean   = [math]::Round($mean, 8)
        Median = [math]::Round($median, 8)
        StdDev = [math]::Round($std, 8)
        Sum    = [math]::Round($sum, 8)
    }
}

# ----------------------------
# Analysis building blocks
# ----------------------------
function Compute-RSIsForCandles {
    param(
        [string]$symbol,
        [int]$limit = 500,
        [string]$period = "1H"
    )
    Log ("Compute-RSIsForCandles: symbol=$symbol limit=$limit period=$period") "INFO"

    $candles = Get-Candles -symbol $symbol -limit $limit -period $period
    if (-not $candles -or $candles.Count -lt 60) { Log ("Недостаточно свечей (" + ($candles.Count) + ")") "ERROR"; return $null }

    $closes = $candles | ForEach-Object { [double]$_.Close }

    $rsi6  = Get-RSI -prices $closes -period 6
    $rsi14 = Get-RSI -prices $closes -period 14
    $rsi30 = Get-RSI -prices $closes -period 30

    $out = @()
    for ($i = 0; $i -lt $candles.Count; $i++) {
        $tsMs = [long]$candles[$i].Timestamp
        $dt = [datetime]::UnixEpoch.AddMilliseconds($tsMs).ToLocalTime()
        $obj = [PSCustomObject]@{
            Index     = $i
            Timestamp = $dt
            Open      = [double]$candles[$i].Open
            High      = [double]$candles[$i].High
            Low       = [double]$candles[$i].Low
            Close     = [double]$candles[$i].Close
            Volume    = [double]$candles[$i].Volume
            RSI6      = $null
            RSI14     = $null
            RSI30     = $null
        }

        if ($i -ge 6)  { $obj.RSI6  = $rsi6[($i - 6)] }
        if ($i -ge 14) { $obj.RSI14 = $rsi14[($i - 14)] }
        if ($i -ge 30) { $obj.RSI30 = $rsi30[($i - 30)] }

        $out += $obj
    }

    return $out
}

function Compute-FutureReturns {
    param(
        [array]$rows,
        [int]$futureN = 1,
        [string]$entryType = "nextOpen"
    )

    $len = $rows.Count
    for ($i=0; $i -lt $len; $i++) {
        $entryIndex = $i + 1
        $exitIndex  = $i + $futureN
        $rows[$i] | Add-Member -MemberType NoteProperty -Name FutureN -Value $futureN -Force

        if ($entryIndex -ge $len -or $exitIndex -ge $len) {
            $rows[$i] | Add-Member -MemberType NoteProperty -Name FutureReturn -Value $null -Force
            continue
        }

        if ($entryType -eq "nextOpen") { $entryPrice = [double]$rows[$entryIndex].Open } else { $entryPrice = [double]$rows[$entryIndex].Close }
        $exitPrice = [double]$rows[$exitIndex].Close

        if ($entryPrice -eq 0) { $rows[$i] | Add-Member -MemberType NoteProperty -Name FutureReturn -Value $null -Force; continue }
        $ret = ($exitPrice / $entryPrice) - 1
        $rows[$i] | Add-Member -MemberType NoteProperty -Name FutureReturn -Value ($ret) -Force
    }
    return $rows
}

function Evaluate-IntervalStats {
    param(
        [array]$rows,
        [string]$rsiField,
        [int]$minVal,
        [int]$maxVal,
        [int]$minSamples = 20
    )

    $sel = $rows | Where-Object { $_.$rsiField -ne $null -and $_.$rsiField -ge $minVal -and $_.$rsiField -le $maxVal -and $_.FutureReturn -ne $null }
    $count = $sel.Count
    if ($count -lt $minSamples) { return $null }

    $futureReturns = $sel | ForEach-Object { [double]$_.FutureReturn }

    $stats = Get-Stats -values $futureReturns
    $wins = ($futureReturns | Where-Object { $_ -gt 0 }).Count
    $winRate = [math]::Round(($wins / $count) * 100, 2)

    return [PSCustomObject]@{
        RSIField   = $rsiField
        Min        = $minVal
        Max        = $maxVal
        Count      = $count
        WinRatePct = $winRate
        MeanRet    = $stats.Mean
        MedianRet  = $stats.Median
        StdRet     = $stats.StdDev
    }
}

function Find-TopIntervals {
    param(
        [array]$rows,
        [string]$rsiField,
        [int]$step = 4,
        [int]$minSamples = 20,
        [int]$topK = 10
    )

    $results = @()
    for ($minVal = 0; $minVal -le 96; $minVal += $step) {
        for ($maxVal = ($minVal + $step); $maxVal -le 100; $maxVal += $step) {
            $stat = Evaluate-IntervalStats -rows $rows -rsiField $rsiField -minVal $minVal -maxVal $maxVal -minSamples $minSamples
            if ($stat) { $results += $stat }
        }
    }

    $sorted = $results | Sort-Object -Property @{Expression = { [double]$_.WinRatePct }; Descending = $true }, @{Expression = { [double]$_.MeanRet }; Descending = $true }
    return ,($sorted | Select-Object -First $topK)
}

function Combine-And-Evaluate {
    param(
        [array]$rows,
        [array]$candidates6,
        [array]$candidates14,
        [array]$candidates30,
        [int]$minSamples = 20
    )

    $out = @()
    foreach ($c6 in $candidates6) {
        foreach ($c14 in $candidates14) {
            foreach ($c30 in $candidates30) {
                $sel = $rows | Where-Object {
                    $_.RSI6  -ne $null -and $_.RSI14 -ne $null -and $_.RSI30 -ne $null -and
                    $_.RSI6 -ge $c6.Min -and $_.RSI6 -le $c6.Max -and
                    $_.RSI14 -ge $c14.Min -and $_.RSI14 -le $c14.Max -and
                    $_.RSI30 -ge $c30.Min -and $_.RSI30 -le $c30.Max -and
                    $_.FutureReturn -ne $null
                }
                if ($sel.Count -lt $minSamples) { continue }

                $futureReturns = $sel | ForEach-Object { [double]$_.FutureReturn }
                $stats = Get-Stats -values $futureReturns
                $wins = ($futureReturns | Where-Object { $_ -gt 0 }).Count
                $winRate = [math]::Round(($wins / $sel.Count) * 100, 2)
                $meanReturn = $stats.Mean

                $out += [PSCustomObject]@{
                    RSI6_Min   = $c6.Min
                    RSI6_Max   = $c6.Max
                    RSI14_Min  = $c14.Min
                    RSI14_Max  = $c14.Max
                    RSI30_Min  = $c30.Min
                    RSI30_Max  = $c30.Max
                    Samples    = $sel.Count
                    WinRatePct = $winRate
                    MeanRet    = $meanReturn
                    MedianRet  = $stats.Median
                    StdRet     = $stats.StdDev
                }
            }
        }
    }
    return $out | Sort-Object -Property @{Expression = { [double]$_.WinRatePct }; Descending = $true }, @{Expression = { [double]$_.MeanRet }; Descending = $true }
}

# ----------------------------
# High-level analysis
# ----------------------------
function Analyze-RsiPatterns {
    param(
        [string]$symbol = "BTC-USDT-SWAP",
        [int]$candleLimit = 500,
        [int]$futureN = 1,
        [int]$step = 4,
        [int]$minSamples = 30,
        [int]$topK = 6,
        [string]$period = "1H",
        [string]$entryType = "nextOpen"
    )

    $rows = Compute-RSIsForCandles -symbol $symbol -limit $candleLimit -period $period
    if (-not $rows) { Log "Ошибка: нет данных для анализа" "ERROR"; return $null }

    $rows = Compute-FutureReturns -rows $rows -futureN $futureN -entryType $entryType
    
    
###### ТУТ КОНФИГ ПРОЦЕНТОВ ДЛЯ FIRST MOVE ########
#******************************************************************
    $rows = Get-FirstMove -rows $rows -percentUp 1 -percentDown 5 -maxLookahead 50
#******************************************************************


    Log "Поиск лучших интервалов для RSI6/14/30..." "INFO"
    # $top6  = Find-TopIntervals -rows $rows -rsiField "RSI6"  -step $step -minSamples $minSamples -topK $topK
    # $top14 = Find-TopIntervals -rows $rows -rsiField "RSI14" -step $step -minSamples $minSamples -topK $topK
    # $top30 = Find-TopIntervals -rows $rows -rsiField "RSI30" -step $step -minSamples $minSamples -topK $topK

    # Log "Комбинируем топовые интервалы и оцениваем пересечения..." "INFO"
    # $comb = Combine-And-Evaluate -rows $rows -candidates6 $top6 -candidates14 $top14 -candidates30 $top30 -minSamples $minSamples

    # Save CSVs
    $timestamp = (Get-Date).ToString("yyyyMMdd_HHmmss")
    $outRowsFile = "./data/${symbol}.csv"
    # $outCombFile = "./data/${symbol}_combinations.csv"
    $rows | Export-Csv -Path $outRowsFile -NoTypeInformation -Encoding UTF8
    # $comb | Export-Csv -Path $outCombFile -NoTypeInformation -Encoding UTF8

    Log ("Анализ завершён. Сохранены CSV: $outRowsFile и $outCombFile") "OK"

    return [PSCustomObject]@{
        Symbol = $symbol
        CandlesUsed = $rows.Count
        FutureN = $futureN
        # TopSingleRSI6 = $top6
        # TopSingleRSI14 = $top14
        # TopSingleRSI30 = $top30
        # TopCombinations = $comb
    }
}

# ----------------------------
# Detect first move (+/-1%)
# ----------------------------
function Get-FirstMove {
    param(
        [array]$rows,
        [double]$percentUp   = 1,   # цель вверх в процентах
        [double]$percentDown = 1,   # цель вниз в процентах
        [int]$maxLookahead   = 50   # максимум свечей вперёд
    )

    # Преобразуем проценты в коэффициенты
    $thresholdUp   = $percentUp / 100.0
    $thresholdDown = $percentDown / 100.0

    $len = $rows.Count
    for ($i = 0; $i -lt $len; $i++) {
        $entryPrice = [double]$rows[$i].Close
        if ($entryPrice -eq 0) { continue }

        $upTarget   = $entryPrice * (1 + $thresholdUp)
        $downTarget = $entryPrice * (1 - $thresholdDown)
        $direction  = $null
        $barsToHit  = $null

        for ($j = 1; $j -le $maxLookahead -and ($i + $j) -lt $len; $j++) {
            $future = $rows[$i + $j]
            $high   = [double]$future.High
            $low    = [double]$future.Low

            if ($high -ge $upTarget) {
                $direction = "Up"
                $barsToHit = $j
                break
            }
            elseif ($low -le $downTarget) {
                $direction = "Down"
                $barsToHit = $j
                break
            }
        }

        # Добавляем результаты
        $rows[$i] | Add-Member -MemberType NoteProperty -Name FirstMove -Value $direction -Force
        $rows[$i] | Add-Member -MemberType NoteProperty -Name BarsToHit -Value $barsToHit -Force

        if ($direction -eq "Up") {
            $rows[$i] | Add-Member -MemberType NoteProperty -Name HitReturn -Value $thresholdUp -Force
        } elseif ($direction -eq "Down") {
            $rows[$i] | Add-Member -MemberType NoteProperty -Name HitReturn -Value (-$thresholdDown) -Force
        } else {
            $rows[$i] | Add-Member -MemberType NoteProperty -Name HitReturn -Value $null -Force
        }
    }

    return $rows
}


# ----------------------------
# Main (safe coercion, avoid -or)
# ----------------------------
function Main {
    param($config)

    if (-not $config.instruments) {
        Log "Config has no instruments[]" "ERROR"
        return
    }

    # Safe coercion of config values
    $candleLimit = 500
    if ($null -ne $config.candle_limit) {
        try { $candleLimit = [int]$config.candle_limit } catch { $candleLimit = 500; Log "Невозможно привести candle_limit к int; используем 500" "WARN" }
    }
    if ($candleLimit -lt 10) { Log "candle_limit кажется очень маленьким: $candleLimit" "WARN" }

    $candlePeriod = "1H"
    if ($null -ne $config.candle_period) {
        try { $candlePeriod = [string]$config.candle_period } catch { $candlePeriod = "1H"; Log "Невозможно привести candle_period к string; используем '1H'" "WARN" }
    }
    Log ("Using candleLimit=$candleLimit candlePeriod=$candlePeriod") "DEBUG"

    foreach ($sym in $config.instruments) {
        Log ("=== Analyze $sym ===") "INFO"
        try {
            $report = Analyze-RsiPatterns -symbol $sym -candleLimit $candleLimit -futureN 1 -step 4 -minSamples 30 -topK 8 -period $candlePeriod -entryType "nextOpen"
            if ($report) {
                # Log ("Top combinations for $sym") "INFO"
                $report.TopCombinations | Select-Object -First 6 | Format-Table -AutoSize
            }
        } catch {
            Log ("Ошибка при анализе $sym " + $_.Exception.Message) "ERROR"
            if ($DebugMode) { Log ($_.Exception | ConvertTo-Json -Depth 3) "DEBUG" }
        }
    }
}

# ----------------------------
# Run
# ----------------------------
Log "Запуск анализа RSI. Убедитесь, что ключи валидны и config.json корректен." "INFO"
Main -config $configJson
