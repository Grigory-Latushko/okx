import os, logging, time
import ccxt

def exchange(demo=False, rate_limit_ms=200):
    ex = ccxt.okx({
        'enableRateLimit': True,
        'timeout': 20000,
        'options': {'defaultType': 'spot'},
        'rateLimit': rate_limit_ms,
        'apiKey': os.getenv('OKX_API_KEY'),
        'secret': os.getenv('OKX_API_SECRET'),
        'password': os.getenv('OKX_API_PASSPHRASE'),
    })
    if str(demo).lower() == 'true':
        ex.set_sandbox_mode(True)
    return ex

def market_order(ex, symbol, side, amount):
    # OKX uses quote precision; ccxt handles amounts
    return ex.create_order(symbol, type='market', side=side, amount=amount)

def fetch_price(ex, symbol):
    ticker = ex.fetch_ticker(symbol)
    return float(ticker['last'])
