Forbid open if current or pervious candle > 3 ATR
Higher trend filter added \ Higher trend EMA filter added
Динамический стоплосс по цена закрытия из диапазона $config.trend_candles
Можно встречные сделки TPx3
Асинхронная загрузка свечей
3 of 3 RSI for trade
RSI multi level
SL <= 4*ATR

Отлично работал на восходящем тренде с конфигом
        $longSignal  = ($price -gt $lastEMA21) -and ($rsi6Curr -ge $config.rsi6_max) -and ($rsi14Curr -ge $config.rsi14_max) -and ($trend -eq "UP")

