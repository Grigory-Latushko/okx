# btc-eth — Correlation Lag Strategy

## Идея

BTC и ETH сильно коррелируют, но ETH реагирует с задержкой и часто немного перелетает.

**Пример:**
- BTC вырос на +2% за последние 60 минут
- ETH вырос только на +0.4%
- Gap = 2% - 0.4% = **+1.6%**
- ETH должен догнать BTC и немного обогнать его (~+3%)
- Открываем **LONG ETH**

## Логика сигнала

```
Измеряем доходность BTC и ETH за lookback_candles × candle_period

btc_return = (BTC_now - BTC_N_candles_ago) / BTC_N_candles_ago × 100
eth_return = (ETH_now - ETH_N_candles_ago) / ETH_N_candles_ago × 100
gap = btc_return - eth_return

LONG ETH если:
  gap >= min_gap_pct          ← BTC опередил ETH
  gap <= max_gap_pct          ← не слишком большой (аномалия)
  |btc_return| >= min_btc_move_pct  ← BTC сам по себе сделал ход
  gap свежий (recent gap >= min_gap_pct × 0.5)  ← ход произошёл недавно

SHORT ETH если (зеркально, allow_shorts=true):
  gap <= -min_gap_pct         ← BTC упал быстрее ETH, ETH не догнал падение
```

## Динамический TP


```
tp_pct = gap × tp_gap_multiplier
```

| Параметр | Описание |
|---|---|
| `tp_gap_multiplier = 1.0` | ETH только догоняет BTC |
| `tp_gap_multiplier = 1.2` | ETH догоняет и немного обгоняет (рекомендуется) |
| `min_tp_pct` | Минимальный TP даже при маленьком gap |
| `max_tp_pct` | Максимальный TP — защита от аномальных ситуаций |

## Параметры конфига

| Поле | Описание | Рекомендация |
|---|---|---|
| `candle_period` | Таймфрейм свечей | `5m` или `15m` |
| `lookback_candles` | Сколько свечей назад смотрим | 12 (= 1 час на 5m) |
| `min_gap_pct` | Минимальный gap для входа | `1.5%` |
| `max_gap_pct` | Максимальный gap (защита от аномалий) | `8.0%` |
| `min_btc_move_pct` | Минимальный ход BTC | `0.2%` |
| `tp_gap_multiplier` | Множитель для расчёта TP | `1.2` |
| `sl_pct` | Фиксированный SL | `1.0%` |
| `allow_shorts` | Разрешить SHORT ETH когда BTC падает | `true` |

## Проверка свежести хода

Чтобы не входить в старый тренд, дополнительно проверяется:
- Ход за последнюю треть периода (`lookback_candles / 3`)
- Если recent gap < `min_gap_pct × 0.5` — сигнал игнорируется

## Пример вывода

```
  BTC  +2.14%  ETH  +0.38%  GAP  +1.76%  (recent BTC +1.21% ETH +0.18%)

  >> SIGNAL: ETH LONG | BTC=2.14% ETH=0.38% GAP=1.76%
  >> Dynamic TP=2.11% (gap=1.76% x 1.2) SL=1.0%
```

## Запуск

```powershell
TP рассчитывается как доля от gap — ETH должен пройти оставшееся расстояние до BTC:

.\trade.ps1              # dryRun режим
.\trade.ps1 -ForceLive   # боевой режим
.\trade.ps1 -DebugMode   # debug вывод
```

## Риски

- **Decoupling**: иногда BTC и ETH расходятся на длительное время (бычий рост BTC без ETH или наоборот)
- **Ложный сигнал**: если BTC начал коррекцию прямо после нашего входа — ETH упадёт вместе с ним
- **Рекомендация**: тестировать с маленькими `position_size_usd` и `dryRun=true` перед боевым режимом
