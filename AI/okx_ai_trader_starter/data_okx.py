import os, time, math, logging
from datetime import datetime
import pandas as pd
import ccxt
from utils import ensure_dir

def _exchange(demo=False, rate_limit_ms=200):
    exchange = ccxt.okx({
        'enableRateLimit': True,
        'timeout': 20000,
        'options': {'defaultType': 'spot'},
        'rateLimit': rate_limit_ms,
        'apiKey': os.getenv('OKX_API_KEY'),
        'secret': os.getenv('OKX_API_SECRET'),
        'password': os.getenv('OKX_API_PASSPHRASE'),  # OKX calls it passphrase
    })
    if str(demo).lower() == 'true':
        exchange.set_sandbox_mode(True)
    return exchange

def fetch_ohlcv(symbol: str, timeframe: str, since_iso: str=None, limit=1000, demo=False, rate_limit_ms=200):
    ex = _exchange(demo, rate_limit_ms)
    ms = None
    if since_iso:
        ms = int(pd.Timestamp(since_iso).timestamp() * 1000)
    all_rows = []
    while True:
        batch = ex.fetch_ohlcv(symbol, timeframe=timeframe, since=ms, limit=limit)
        if not batch:
            break
        all_rows += batch
        if len(batch) < limit:
            break
        ms = batch[-1][0] + 1
        time.sleep(ex.rateLimit / 1000)
    if not all_rows:
        raise RuntimeError("No OHLCV returned. Check symbol/timeframe or use a later 'since'.")
    df = pd.DataFrame(all_rows, columns=['ts','open','high','low','close','volume'])
    df['time'] = pd.to_datetime(df['ts'], unit='ms', utc=True)
    df.set_index('time', inplace=True)
    return df[['open','high','low','close','volume']].sort_index()
