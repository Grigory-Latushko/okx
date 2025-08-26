from dataclasses import dataclass
import math

@dataclass
class RiskParams:
    max_notional_usdt: float
    stop_loss_pct: float
    take_profit_pct: float
    cooldown_bars: int

def position_size(price, risk: RiskParams):
    # cap by notional
    qty = risk.max_notional_usdt / price
    return max(qty, 0.0)
