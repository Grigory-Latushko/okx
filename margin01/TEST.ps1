# ================================
#  OKX DEMO — список инструментов
# ================================

param(
    [string]$instType = "SWAP"  # можно: SPOT / FUTURES / SWAP
)

# === Конфигурация ===
$baseUrl = "https://www.okx.com"
$endpoint = "/api/v5/public/instruments?instType=$instType"

# === Запрос ===
try {
    Write-Host "Запрашиваем список инструментов ($instType) из DEMO OKX..." -ForegroundColor Cyan

    $response = Invoke-RestMethod -Uri "$baseUrl$endpoint" -Headers @{
        "x-simulated-trading" = "1"     # 👈 ключевая строчка — демо-режим
    } -Method GET

    if ($response.code -eq "0" -and $response.data.Count -gt 0) {
        Write-Host "Получено $($response.data.Count) инструментов" -ForegroundColor Green

        # Выведем первые 10
        $response.data | Select-Object -First 10 instId, instType, state | Format-Table
    }
    else {
        Write-Host "Ошибка: $($response.msg)" -ForegroundColor Red
    }
}
catch {
    Write-Host "Ошибка запроса: $($_.Exception.Message)" -ForegroundColor Red
}
