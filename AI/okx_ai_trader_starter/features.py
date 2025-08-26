import pandas as pd
import numpy as np

def rsi(series: pd.Series, length: int = 14):
    delta = series.diff()
    gain = (delta.clip(lower=0)).rolling(length).mean()
    loss = (-delta.clip(upper=0)).rolling(length).mean()
    rs = gain / (loss.replace(0, np.nan))
    rsi = 100 - (100 / (1 + rs))
    return rsi

def make_features(df: pd.DataFrame):
    out = df.copy()
    out['ret_1'] = out['close'].pct_change(1)
    out['sma_14'] = out['close'].rolling(14).mean()
    out['sma_50'] = out['close'].rolling(50).mean()
    out['rsi_14'] = rsi(out['close'], 14)
    out['fwd_ret_1'] = out['close'].pct_change(-1) * -1  # forward return next bar
    out['up'] = (out['fwd_ret_1'] > 0).astype(int)
    out = out.dropna()
    return out
