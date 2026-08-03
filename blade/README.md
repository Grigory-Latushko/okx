# Margin2

# buy-the-dip-trail — покупаем просадку с трейлингом

## Машина состояний

```
[1] Нет позиции, нет ордеров
    └── мониторим 24h drop
    └── drop <= dip_threshold_pct → trailing BUY (вход на отскоке)

[2] Pending trailing BUY
    └── ждём исполнения, показываем статус

[3] Позиция открыта, нет TP/SL
    └── выставляем TP (+tp_pct%) и SL (-sl_pct%)

[4] Позиция открыта, убыток > sl_pct%
    └── аварийный trailing SELL (callback = loss_trail_callback_pct%)
    └── отменяем существующий SL если есть

[5] Позиция открыта, TP/SL есть, прибыль > profit_trail_threshold% но < TP
    └── trailing SELL для фиксации прибыли (callback = exit_trail_callback_pct%)
```

## Параметры конфига

| Поле | Описание | Пример |
|---|---|---|
| `instruments` | Список инструментов | `["BTC-USDT-SWAP"]` |
| `dip_threshold_pct` | Порог суточного падения | `-5.0` |
| `entry_trail_callback_pct` | Callback входного trailing BUY | `2.0` |
| `position_size_usd` | Размер позиции в USD | `1` |
| `leverage` | Плечо | `10` |
| `tp_pct` | Take Profit в % от входа | `3.0` |
| `sl_pct` | Stop Loss в % от входа | `1.5` |
| `profit_trail_threshold_pct` | Порог прибыли для trailing SELL | `1.5` |
| `exit_trail_callback_pct` | Callback trailing SELL (фиксация прибыли) | `1.0` |
| `loss_trail_callback_pct` | Callback аварийного trailing SELL | `0.5` |

## Запуск

```powershell
.\trade.ps1              # dryRun режим
.\trade.ps1 -ForceLive   # боевой режим
.\trade.ps1 -DebugMode   # debug вывод
```
