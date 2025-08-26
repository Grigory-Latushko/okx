import time, argparse, pickle, pandas as pd
from utils import load_config, setup_logging
from data_okx import fetch_ohlcv
from features import make_features
from trade_okx import exchange, fetch_price
from risk import RiskParams, position_size

def loop(symbol, timeframe):
    cfg = load_config()
    setup_logging(cfg['logging']['level'])
    # load model
    with open('artifacts/model.pkl','rb') as f:
        art = pickle.load(f)
    model, feat_cols = art['model'], art['features']

    while True:
        df = fetch_ohlcv(symbol, timeframe, since_iso=None, limit=200, 
                         demo=cfg['exchange']['demo'], rate_limit_ms=cfg['exchange']['rate_limit_ms'])
        fdf = make_features(df).iloc[-1:]  # latest bar
        proba = float(model.predict_proba(fdf[feat_cols])[:,1][0])
        last_close = float(fdf['close'].iloc[0])
        print(f"[{pd.Timestamp.utcnow()}] {symbol} close={last_close:.2f} up_proba={proba:.3f}")
        time.sleep(60)  # sleep 60s between checks

if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--symbol", required=True)
    p.add_argument("--timeframe", default="15m")
    a = p.parse_args()
    loop(a.symbol, a.timeframe)
