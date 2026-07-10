# OKX AI Trader (Starter Kit)

**⚠️ Disclaimer**: This project is for educational purposes only. Crypto trading is highly risky. 
You are solely responsible for any losses. Use paper trading first.

## What you get
- Data fetch from OKX via `ccxt` (spot)
- Simple feature set (SMA/RSI) + baseline ML (RandomForest)
- Backtest (walk-forward split)
- Paper-trading loop (no orders) and optional live trading skeleton (market orders)
- Risk controls: max position size, stop-loss, take-profit, cooldown, daily loss cap

## Quick start
1. Install deps (Python 3.10+ recommended):
   ```bash
   pip install -r requirements.txt
   ```
2. Set environment variables (Linux/macOS PowerShell analogous):
   ```bash
   export OKX_API_KEY="..."
   export OKX_API_SECRET="..."
   export OKX_API_PASSPHRASE="..."
   export OKX_TESTNET="false"   # or "true" for demo
   ```

3. Edit `config.yaml` as needed.

4. Download candles & train:
   ```bash
   python run_backtest.py --symbol BTC/USDT --timeframe 1h --since "2024-01-01T00:00:00Z"
   ```

5. Paper-trading loop (no orders, just logs & signals):
   ```bash
   python run_paper.py --symbol BTC/USDT --timeframe 15m
   ```

6. (Optional) Live trading (⚠️ real orders if enabled in config):
   ```bash
   python run_live.py --symbol BTC/USDT --timeframe 15m
   ```

## Structure
```
okx_ai_trader/
  config.yaml
  requirements.txt
  data_okx.py
  features.py
  model.py
  risk.py
  backtest.py
  trade_okx.py
  run_backtest.py
  run_paper.py
  run_live.py
  utils.py
```

## Notes
- Uses **spot** trading to keep things simple. Extending to swaps/perps requires margin & leverage handling.
- Walk-forward validation trains on a rolling window and tests on the next chunk to reduce look-ahead bias.
- Feature engineering is intentionally basic — extend with more market microstructure features, depth data, etc.
- Always start with `OKX_TESTNET=true` (OKX demo trading) or comment out order placement.
