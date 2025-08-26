import requests
import pandas as pd

BASE_URL = "https://www.okx.com"

def get_candles(inst, bar="15m", limit=100):
    url = f"{BASE_URL}/api/v5/market/candles?instId={inst}&bar={bar}&limit={limit}"
    r = requests.get(url)
    data = r.json()["data"]
    df = pd.DataFrame(data, columns=["ts","open","high","low","close","vol","volCcy","volCcyQuote","confirm"])
    df = df.astype({"open":float,"high":float,"low":float,"close":float,"vol":float})
    df = df.iloc[::-1].reset_index(drop=True)  # разворачиваем в нормальный порядок
    return df


