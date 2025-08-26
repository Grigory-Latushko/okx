import json, argparse, pandas as pd
from utils import load_config, setup_logging, ensure_dir
from data_okx import fetch_ohlcv
from features import make_features
from model import walk_forward

def run(symbol, timeframe, since_iso):
    cfg = load_config()
    setup_logging(cfg['logging']['level'])
    df = fetch_ohlcv(symbol, timeframe, since_iso, limit=cfg['data']['max_fetch_ohlcv'], 
                     demo=cfg['exchange']['demo'],
                     rate_limit_ms=cfg['exchange']['rate_limit_ms'])
    feat = make_features(df)
    feature_cols = cfg['strategy']['features']
    model, wf = walk_forward(feat, feature_cols, cfg['strategy']['label'])
    print("Walk-forward:", json.dumps(wf, indent=2))
    # Save model (pickle)
    import pickle, os
    ensure_dir('artifacts')
    with open('artifacts/model.pkl','wb') as f:
        pickle.dump({'model': model, 'features': feature_cols}, f)
    feat.tail(10).to_csv('artifacts/last_features.csv')
    print("Saved artifacts to ./artifacts")

if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--symbol", required=True)
    p.add_argument("--timeframe", default="1h")
    p.add_argument("--since", dest="since_iso", default=None)
    a = p.parse_args()
    run(a.symbol, a.timeframe, a.since_iso)
