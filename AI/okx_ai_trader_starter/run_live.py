import time, argparse, pickle, pandas as pd
from utils import load_config, setup_logging
from data_okx import fetch_ohlcv
from features import make_features
from trade_okx import exchange, market_order, fetch_price
from risk import RiskParams, position_size

def loop(symbol, timeframe):
    cfg = load_config()
    setup_logging(cfg['logging']['level'])

    if not cfg['risk']['allow_live_orders']:
        raise RuntimeError("allow_live_orders=false in config.yaml (safety). Set to true only if you accept real trades.")

    with open('artifacts/model.pkl','rb') as f:
        art = pickle.load(f)
    model, feat_cols = art['model'], art['features']

    ex = exchange(cfg['exchange']['demo'], cfg['exchange']['rate_limit_ms'])

    cooldown = 0
    last_day = None
    daily_pnl = 0.0

    while True:
        df = fetch_ohlcv(symbol, timeframe, since_iso=None, limit=300, 
                         demo=cfg['exchange']['demo'], rate_limit_ms=cfg['exchange']['rate_limit_ms'])
        fdf = make_features(df)
        bar = fdf.iloc[-1]
        now_day = bar.name.date()
        if last_day is None or now_day != last_day:
            daily_pnl = 0.0
            last_day = now_day

        proba = float(model.predict_proba(fdf[feat_cols].iloc[[-1]])[:,1][0])
        price = float(bar['close'])

        if cooldown > 0:
            cooldown -= 1
            time.sleep(10); continue

        if daily_pnl <= -abs(cfg['risk']['max_daily_loss_usdt']):
            print("Daily loss cap hit. Pausing until next UTC day.")
            time.sleep(60); continue

        # Simple rule: buy if proba>0.55, sell if <0.45 (close any held position)
        # This starter kit treats positions as flat -> market buy -> immediately place TP/SL idea is simplified.
        if proba > 0.55:
            qty = position_size(price, RiskParams(cfg['risk']['max_notional_usdt'], cfg['risk']['stop_loss_pct'], cfg['risk']['take_profit_pct'], cfg['risk']['cooldown_bars']))
            if qty > 0:
                try:
                    order = market_order(ex, symbol, 'buy', qty)
                    print("BUY", order)
                    cooldown = cfg['risk']['cooldown_bars']
                except Exception as e:
                    print("Order error:", e)
        elif proba < 0.45:
            # For simplicity: sell the capped qty (assumes you hold spot)
            qty = position_size(price, RiskParams(cfg['risk']['max_notional_usdt'], cfg['risk']['stop_loss_pct'], cfg['risk']['take_profit_pct'], cfg['risk']['cooldown_bars']))
            try:
                order = market_order(ex, symbol, 'sell', qty)
                print("SELL", order)
                cooldown = cfg['risk']['cooldown_bars']
            except Exception as e:
                print("Order error:", e)

        time.sleep(30)

if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--symbol", required=True)
    p.add_argument("--timeframe", default="15m")
    a = p.parse_args()
    loop(a.symbol, a.timeframe)
