import json
import pandas as pd
import matplotlib.pyplot as plt
from data_utils import get_candles
from model import train_or_load_model, predict
from indicators import atr

# ====== Загрузка конфигурации ======
with open("config.json") as f:
    cfg = json.load(f)

position_size = cfg["position_size_usd"]
tp_mult = cfg["tp_percent"]
sl_mult = cfg["sl_percent"]

# ====== Хранилище позиций и лог сделок ======
positions = []
trade_log = []

# ====== Кэш свечей ======
candles_cache = {}

def get_cached_candles(inst, bar="1m", limit=1000):
    key = f"{inst}_{bar}_{limit}"
    if key not in candles_cache:
        candles_cache[key] = get_candles(inst, bar=bar, limit=limit)
    return candles_cache[key]

# ====== Закрытие позиции с расчетом USD ======
def close_position(pos, exit_price):
    pos["exit"] = exit_price
    if pos["side"] == "LONG":
        pos["result"] = (exit_price - pos["entry"]) / pos["entry"] * position_size
    else:  # SHORT
        pos["result"] = (pos["entry"] - exit_price) / pos["entry"] * position_size

# ====== Проверка закрытия позиции ======
def check_position_multi(pos):
    df_1m = get_cached_candles(pos["inst"], bar="1m")
    df_5m = get_cached_candles(pos["inst"], bar="5m")

    # Проверка по 1m
    for _, row in df_1m.iterrows():
        if pos["side"] == "LONG":
            if row["high"] >= pos["tp"]:
                close_position(pos, pos["tp"])
                return True
            elif row["low"] <= pos["sl"]:
                close_position(pos, pos["sl"])
                return True
        elif pos["side"] == "SHORT":
            if row["low"] <= pos["tp"]:
                close_position(pos, pos["tp"])
                return True
            elif row["high"] >= pos["sl"]:
                close_position(pos, pos["sl"])
                return True

    # Проверка по 5m (резерв)
    for _, row in df_5m.iterrows():
        if pos["side"] == "LONG":
            if row["high"] >= pos["tp"]:
                close_position(pos, pos["tp"])
                return True
            elif row["low"] <= pos["sl"]:
                close_position(pos, pos["sl"])
                return True
        elif pos["side"] == "SHORT":
            if row["low"] <= pos["tp"]:
                close_position(pos, pos["tp"])
                return True
            elif row["high"] >= pos["sl"]:
                close_position(pos, pos["sl"])
                return True

    return False

# ====== Основной цикл по инструментам ======
for inst in cfg["instruments"]:
    print(f"Processing {inst}...")

    # Скачиваем все свечи один раз
    df_main = get_cached_candles(inst, bar=cfg["candle_period"], limit=500)

    # Обучаем модель
    model = train_or_load_model(df_main, inst)

    equity_curve = []

    # Эмуляция торговли
    for i in range(20, len(df_main)):
        window = df_main.iloc[:i+1]
        prob_up = predict(model, window)
        last_close = window["close"].iloc[-1]
        last_atr = atr(window).iloc[-1]

        # Проверяем открытые позиции
        for pos in positions[:]:
            if check_position_multi(pos):
                trade_log.append(pos)
                positions.remove(pos)

        # Генерация новых сигналов
        if prob_up > 0.55:
            tp = last_close + last_atr * tp_mult
            sl = last_close - last_atr * sl_mult
            positions.append({"inst": inst, "side": "LONG", "entry": last_close, "tp": tp, "sl": sl})
        elif prob_up < 0.45:
            tp = last_close - last_atr * tp_mult
            sl = last_close + last_atr * sl_mult
            positions.append({"inst": inst, "side": "SHORT", "entry": last_close, "tp": tp, "sl": sl})

        # Обновляем equity
        total_equity = sum(t.get("result", 0) for t in trade_log)
        equity_curve.append(total_equity)

    # ====== График equity ======
    # plt.figure(figsize=(10,4))
    # plt.plot(equity_curve, label=f"{inst} equity")
    # plt.title(f"Equity Curve - {inst}")
    # plt.xlabel("Bars")
    # plt.ylabel("Profit USD")
    # plt.legend()
    # plt.show()

# ====== Общая статистика ======
total_trades = len(trade_log)
wins = sum(1 for t in trade_log if t["result"] > 0)
losses = sum(1 for t in trade_log if t["result"] <= 0)
profit = sum(t["result"] for t in trade_log)

print("=== TRADE SUMMARY ===")
print(f"Total trades: {total_trades}")
print(f"Wins: {wins}, Losses: {losses}, Win rate: {wins/total_trades*100:.2f}%")
print(f"Net profit USD: {profit:.2f}")

# ====== Сохраняем лог сделок в CSV ======
df_log = pd.DataFrame(trade_log)
df_log.to_csv("trade_log.csv", index=False)
print("Trade log saved to trade_log.csv")
