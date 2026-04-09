"""
backtest_engine.py
==================
Self-contained MT5-style backtesting engine.

Usage (write an EA and run it):

    from backtest_engine import Backtest, BaseEA, DataLoader

    class MyEA(BaseEA):
        def on_tick(self):
            if not self.position:
                self.buy(0.1)

    df  = DataLoader.yahoo("EURUSD=X", "2020-01-01", "2024-01-01")
    bt  = Backtest(df, MyEA, balance=10_000)
    res = bt.run()
    res.print_report()
    res.save_html("report.html")
    res.save_pdf("report.pdf")
"""

from __future__ import annotations
import math, warnings
from dataclasses import dataclass, field
from datetime import datetime
from enum import Enum
from typing import Optional

import numpy as np
import pandas as pd

warnings.filterwarnings("ignore")


# ══════════════════════════════════════════════════════════════════════════════
#  ENUMS
# ══════════════════════════════════════════════════════════════════════════════

class OrderType(Enum):
    BUY       = "BUY"
    SELL      = "SELL"
    BUY_LIMIT  = "BUY_LIMIT"
    SELL_LIMIT = "SELL_LIMIT"
    BUY_STOP   = "BUY_STOP"
    SELL_STOP  = "SELL_STOP"


# ══════════════════════════════════════════════════════════════════════════════
#  TRADE / POSITION
# ══════════════════════════════════════════════════════════════════════════════

@dataclass
class Trade:
    ticket:      int
    order_type:  OrderType
    volume:      float
    open_price:  float
    open_time:   datetime
    sl:          float = 0.0
    tp:          float = 0.0
    comment:     str   = ""
    close_price: float = 0.0
    close_time:  Optional[datetime] = None
    profit:      float = 0.0
    commission:  float = 0.0
    swap:        float = 0.0

    @property
    def is_long(self):  return self.order_type == OrderType.BUY
    @property
    def is_open(self):  return self.close_time is None
    @property
    def net_profit(self): return self.profit + self.commission + self.swap


# ══════════════════════════════════════════════════════════════════════════════
#  PAIR SPECIFICATIONS
# ══════════════════════════════════════════════════════════════════════════════

PAIR_SPECS = {
    "EURUSD":  {"lot_size": 100_000, "pip": 0.0001, "pip_value_per_lot": 10.0,   "point": 0.00001, "digits": 5, "quote_is_usd": True},
    "GBPUSD":  {"lot_size": 100_000, "pip": 0.0001, "pip_value_per_lot": 10.0,   "point": 0.00001, "digits": 5, "quote_is_usd": True},
    "USDCAD":  {"lot_size": 100_000, "pip": 0.0001, "pip_value_per_lot": 7.35,   "point": 0.00001, "digits": 5, "quote_is_usd": False},
    "USDJPY":  {"lot_size": 100_000, "pip": 0.01,   "pip_value_per_lot": 6.50,   "point": 0.001,   "digits": 3, "quote_is_usd": False},
    "XAUUSD":  {"lot_size": 100,     "pip": 0.01,   "pip_value_per_lot": 1.0,    "point": 0.01,    "digits": 2, "quote_is_usd": True},
}

def get_pair_spec(symbol: str) -> dict:
    """Look up pair spec by symbol (strips .a suffix etc.)."""
    clean = symbol.upper().replace(".A", "").replace(".B", "").replace("_", "")
    for key in PAIR_SPECS:
        if key in clean:
            return PAIR_SPECS[key]
    # Default forex
    return PAIR_SPECS["EURUSD"]


# ══════════════════════════════════════════════════════════════════════════════
#  BROKER  (order execution + account state)
# ══════════════════════════════════════════════════════════════════════════════

class Broker:
    def __init__(self, balance: float, commission_per_lot: float,
                 spread_pts: int, lot_size: int, leverage: int,
                 swap_long: float, swap_short: float,
                 stopout_pct: float = 50.0, symbol: str = "EURUSD"):
        self.initial_balance   = balance
        self.balance           = balance
        self.commission_per_lot = commission_per_lot
        self.spread_pts        = spread_pts
        self._base_spread_pts  = spread_pts   # original configured spread (never changes)
        self.lot_size          = lot_size
        self.leverage          = leverage
        self.swap_long         = swap_long
        self.swap_short        = swap_short
        self.stopout_pct       = stopout_pct
        self.symbol            = symbol

        self._pair_spec = get_pair_spec(symbol)

        self._tick   = 0
        self._pos: Optional[Trade] = None          # single open position
        self._pending: list[Trade] = []
        self.history: list[Trade]  = []

        self.balance_curve: list[tuple] = []
        self.equity_curve:  list[tuple] = []

        self.bid = self.ask = 0.0
        self.now: Optional[datetime] = None
        self._margin_calls = 0
        self._rejected_margin = 0

    # ── quotes ────────────────────────────────────────────────────────────
    def _half_spread(self):
        return self.spread_pts * self._pair_spec["point"] / 2

    def update(self, close: float, time: datetime,
               high: float = None, low: float = None,
               bar_spread: int = None):
        """Simple update for backward compatibility (non-MT5-accurate mode).
        The MT5-accurate run loop in Backtest.run() handles the full
        Open→H/L→Close sequence directly.
        """
        if bar_spread is not None:
            self.spread_pts = bar_spread
        hs = self._half_spread()
        if high is not None and low is not None:
            self._check_sl_tp_hilo(high, low, hs)
        self.bid = close - hs
        self.ask = close + hs
        self.now = time
        self._check_pending()
        self._check_sl_tp()
        self._check_stopout()
        eq = self._equity()
        self.balance_curve.append((time, self.balance))
        self.equity_curve.append((time, eq))

    def daily_swap(self, weekday: int = 0):
        if self._pos:
            s = self.swap_long if self._pos.is_long else self.swap_short
            mult = 3 if weekday == 2 else 1  # triple swap on Wednesday
            self._pos.swap += s * self._pos.volume * mult

    # ── margin helpers ──────────────────────────────────────────────────
    def required_margin(self, price: float, volume: float) -> float:
        """Margin required to open position at given price and volume."""
        return price * volume * self.lot_size / self.leverage

    def _margin_used(self) -> float:
        if not self._pos:
            return 0.0
        return self._pos.open_price * self._pos.volume * self.lot_size / self.leverage

    def margin_level(self) -> float:
        """Margin level as percentage. 0 if no position."""
        mu = self._margin_used()
        if mu <= 0:
            return float("inf")
        return (self._equity() / mu) * 100.0

    def calc_lot(self, risk_pct: float, sl_distance: float,
                 price: float = None, min_lot: float = 0.01,
                 max_lot: float = 10.0) -> float:
        """Calculate lot size based on risk % and SL distance.
        sl_distance is in price units (e.g., 0.0050 for 50 pips on EURUSD).
        """
        if sl_distance <= 0:
            return min_lot
        risk_dollars = self.balance * risk_pct / 100.0
        spec = self._pair_spec
        pips = sl_distance / spec["pip"]
        dollar_per_pip_per_lot = spec["pip_value_per_lot"]
        lot = risk_dollars / (pips * dollar_per_pip_per_lot)
        lot = max(min_lot, min(max_lot, round(lot, 2)))
        # Verify margin availability
        if price is None:
            price = self.ask
        req = self.required_margin(price, lot)
        if req > self.free_margin:
            # First check if min_lot is affordable
            if self.required_margin(price, min_lot) <= self.free_margin:
                # Find max affordable lot by stepping down
                lot = math.floor(self.free_margin / self.required_margin(price, min_lot)) * min_lot
                lot = max(min_lot, min(max_lot, round(lot, 2)))
                if self.required_margin(price, lot) > self.free_margin:
                    lot = min_lot
            else:
                return 0.0  # cannot afford even min lot
        return lot

    def _check_stopout(self):
        """Force close position if margin level drops below stop-out %."""
        if not self._pos:
            return
        ml = self.margin_level()
        if ml < self.stopout_pct:
            price = self.bid if self._pos.is_long else self.ask
            self._finalise(self._pos, price, "STOPOUT")
            self._pos = None
            self._margin_calls += 1

    # ── order placement ───────────────────────────────────────────────────
    def open_market(self, order_type: OrderType, volume: float,
                    sl: float = 0.0, tp: float = 0.0,
                    comment: str = "") -> Optional[Trade]:
        if self._pos:
            return None                             # already in a trade

        price = self.ask if order_type == OrderType.BUY else self.bid
        # Margin check
        req = self.required_margin(price, volume)
        if req > self.free_margin:
            self._rejected_margin += 1
            return None

        comm  = -self.commission_per_lot * volume
        self.balance += comm
        self._tick += 1
        t = Trade(ticket=self._tick, order_type=order_type, volume=volume,
                  open_price=price, open_time=self.now,
                  sl=sl, tp=tp, comment=comment, commission=comm)
        self._pos = t
        return t

    def place_pending(self, order_type: OrderType, volume: float,
                      price: float, sl: float = 0.0, tp: float = 0.0,
                      comment: str = "") -> Trade:
        self._tick += 1
        t = Trade(ticket=self._tick, order_type=order_type, volume=volume,
                  open_price=price, open_time=self.now,
                  sl=sl, tp=tp, comment=comment)
        self._pending.append(t)
        return t

    def close_position(self, comment: str = "") -> Optional[Trade]:
        if not self._pos:
            return None
        price = self.bid if self._pos.is_long else self.ask
        self._finalise(self._pos, price, comment)
        closed = self._pos
        self._pos = None
        return closed

    def cancel_pending(self, ticket: int):
        self._pending = [p for p in self._pending if p.ticket != ticket]

    def modify_sl_tp(self, sl: float = 0.0, tp: float = 0.0):
        if self._pos:
            self._pos.sl = sl
            self._pos.tp = tp

    # ── properties ────────────────────────────────────────────────────────
    @property
    def position(self) -> Optional[Trade]:
        return self._pos

    @property
    def equity(self) -> float:
        return self._equity()

    @property
    def free_margin(self) -> float:
        return self.equity - self._margin_used()

    # ── internal ──────────────────────────────────────────────────────────
    def _convert_pnl(self, raw_pnl: float, price: float) -> float:
        """Convert raw P&L from quote currency to USD.
        For xxxUSD pairs (quote=USD), no conversion needed.
        For USDxxx pairs (quote=CAD/JPY/etc), divide by current price.
        """
        if self._pair_spec.get("quote_is_usd", True):
            return raw_pnl
        if price <= 0:
            return raw_pnl
        return raw_pnl / price

    def _equity(self) -> float:
        if not self._pos:
            return self.balance
        cp = self.bid if self._pos.is_long else self.ask
        d  = 1 if self._pos.is_long else -1
        raw_pnl = d * (cp - self._pos.open_price) * self._pos.volume * self.lot_size
        unreal = self._convert_pnl(raw_pnl, cp)
        return self.balance + unreal + self._pos.swap

    def _finalise(self, t: Trade, price: float, comment: str):
        d = 1 if t.is_long else -1
        raw_pnl = d * (price - t.open_price) * t.volume * self.lot_size
        t.profit      = self._convert_pnl(raw_pnl, price)
        t.close_price = price
        t.close_time  = self.now
        if comment: t.comment = comment
        self.balance += t.profit + t.swap
        self.history.append(t)

    def _check_sl_tp(self):
        p = self._pos
        if not p:
            return
        price = self.bid if p.is_long else self.ask
        hit_sl = p.sl and (price <= p.sl if p.is_long else price >= p.sl)
        hit_tp = p.tp and (price >= p.tp if p.is_long else price <= p.tp)
        if hit_sl or hit_tp:
            reason = "SL" if hit_sl else "TP"
            trigger = p.sl if hit_sl else p.tp
            self._finalise(p, trigger, reason)
            self._pos = None

    def _check_sl_tp_hilo(self, high: float, low: float, hs: float):
        """Check SL/TP against bar's High and Low (intra-bar simulation).
        For longs: low can hit SL, high can hit TP.
        For shorts: high can hit SL, low can hit TP.
        When both SL and TP are hit in the same bar, SL takes priority
        (conservative assumption — matches MT5 behavior for tight stops).
        """
        p = self._pos
        if not p:
            return
        if p.is_long:
            bid_low  = low - hs
            bid_high = high - hs
            hit_sl = p.sl and bid_low <= p.sl
            hit_tp = p.tp and bid_high >= p.tp
        else:
            ask_low  = low + hs
            ask_high = high + hs
            hit_sl = p.sl and ask_high >= p.sl
            hit_tp = p.tp and ask_low <= p.tp
        if hit_sl and hit_tp:
            # Both hit in same bar — SL takes priority (conservative)
            self._finalise(p, p.sl, "SL")
            self._pos = None
        elif hit_sl:
            self._finalise(p, p.sl, "SL")
            self._pos = None
        elif hit_tp:
            self._finalise(p, p.tp, "TP")
            self._pos = None

    def _check_pending(self):
        filled = []
        for t in self._pending:
            ot = t.order_type
            if ot == OrderType.BUY_LIMIT  and self.ask <= t.open_price: filled.append((t, self.ask))
            if ot == OrderType.SELL_LIMIT and self.bid >= t.open_price: filled.append((t, self.bid))
            if ot == OrderType.BUY_STOP   and self.ask >= t.open_price: filled.append((t, self.ask))
            if ot == OrderType.SELL_STOP  and self.bid <= t.open_price: filled.append((t, self.bid))
        for t, price in filled:
            self._pending.remove(t)
            if not self._pos:
                comm = -self.commission_per_lot * t.volume
                self.balance += comm
                t.commission = comm
                t.open_price = price
                t.open_time  = self.now
                self._pos = t


# ══════════════════════════════════════════════════════════════════════════════
#  DATA FEED  (indicators + price history)
# ══════════════════════════════════════════════════════════════════════════════

class Feed:
    def __init__(self, df: pd.DataFrame):
        df = df.copy()
        if not isinstance(df.index, pd.DatetimeIndex):
            df = df.set_index(df.columns[0])
        df.index = pd.to_datetime(df.index, utc=True)
        df.columns = [c.lower() for c in df.columns]
        df = df.sort_index()
        self._o = df["open"].values
        self._h = df["high"].values
        self._l = df["low"].values
        self._c = df["close"].values
        self._v = df.get("volume", pd.Series(np.zeros(len(df)))).values
        # Per-bar spread (in broker points) if available
        self._spread = df["spread"].values if "spread" in df.columns else None
        self._t = df.index.to_pydatetime()
        self._i = 0
        self._cache: dict = {}              # cache for precomputed indicator series
        self._gf_cache: dict = {}          # cache for gaussian filter series

    # ── engine interface ──────────────────────────────────────────────────
    @property
    def total(self): return len(self._c)

    def advance(self): self._i += 1

    @property
    def time(self):  return self._t[self._i]
    @property
    def open(self):  return self._o[self._i]
    @property
    def high(self):  return self._h[self._i]
    @property
    def low(self):   return self._l[self._i]
    @property
    def close(self): return self._c[self._i]

    # ── MT5-style price accessors (shift=0 → current bar) ─────────────────
    def iOpen(self,  shift=0): return self._o[self._i - shift]
    def iHigh(self,  shift=0): return self._h[self._i - shift]
    def iLow(self,   shift=0): return self._l[self._i - shift]
    def iClose(self, shift=0): return self._c[self._i - shift]
    def iTime(self,  shift=0): return self._t[self._i - shift]

    def closes(self, n: int) -> np.ndarray:
        return self._c[max(0, self._i - n + 1): self._i + 1]

    def highs(self, n: int) -> np.ndarray:
        return self._h[max(0, self._i - n + 1): self._i + 1]

    def lows(self, n: int) -> np.ndarray:
        return self._l[max(0, self._i - n + 1): self._i + 1]

    # ── Indicators ────────────────────────────────────────────────────────
    def sma(self, period: int, shift=0) -> float:
        arr = self._c[max(0, self._i - shift - period + 1): self._i - shift + 1]
        return float(arr.mean()) if len(arr) == period else float("nan")

    def ema(self, period: int, shift=0) -> float:
        idx = self._i - shift
        if idx < period - 1:
            return float("nan")
        key = ("ema", period)
        if key not in self._cache:
            self._cache[key] = pd.Series(self._c).ewm(span=period, adjust=False).mean().values
        return float(self._cache[key][idx])

    def rsi(self, period=14, shift=0) -> float:
        idx = self._i - shift
        if idx < period:
            return float("nan")
        key = ("rsi", period)
        if key not in self._cache:
            d = np.diff(self._c)
            gains = np.where(d > 0, d, 0.0)
            losses = np.where(d < 0, -d, 0.0)
            rsi_arr = np.full(len(self._c), np.nan)
            ag = gains[:period].mean()
            al = losses[:period].mean()
            rsi_arr[period] = 100.0 if al == 0 else 100 - 100 / (1 + ag / al)
            for j in range(period, len(d)):
                ag = (ag * (period - 1) + gains[j]) / period
                al = (al * (period - 1) + losses[j]) / period
                rsi_arr[j + 1] = 100.0 if al == 0 else 100 - 100 / (1 + ag / al)
            self._cache[key] = rsi_arr
        return float(self._cache[key][idx])

    def atr(self, period=14, shift=0) -> float:
        idx = self._i - shift
        if idx < period:
            return float("nan")
        key = ("atr", period)
        if key not in self._cache:
            tr = np.empty(len(self._c))
            tr[0] = self._h[0] - self._l[0]
            for j in range(1, len(self._c)):
                tr[j] = max(self._h[j] - self._l[j],
                            abs(self._h[j] - self._c[j - 1]),
                            abs(self._l[j] - self._c[j - 1]))
            atr_arr = np.full(len(self._c), np.nan)
            atr_arr[period] = tr[1:period + 1].mean()
            for j in range(period + 1, len(self._c)):
                atr_arr[j] = (atr_arr[j - 1] * (period - 1) + tr[j]) / period
            self._cache[key] = atr_arr
        return float(self._cache[key][idx])

    def bollinger(self, period=20, dev=2.0, shift=0):
        arr = self._c[max(0, self._i - shift - period + 1): self._i - shift + 1]
        if len(arr) < period: return float("nan"), float("nan"), float("nan")
        mid = arr.mean(); std = arr.std(ddof=0)
        return mid + dev * std, mid, mid - dev * std

    def macd(self, fast=12, slow=26, signal=9, shift=0):
        idx = self._i - shift
        if idx < slow + signal - 1:
            return float("nan"), float("nan"), float("nan")
        key = ("macd", fast, slow, signal)
        if key not in self._cache:
            s = pd.Series(self._c)
            m = s.ewm(span=fast, adjust=False).mean() - s.ewm(span=slow, adjust=False).mean()
            sig = m.ewm(span=signal, adjust=False).mean()
            self._cache[key] = (m.values, sig.values, (m - sig).values)
        m, sig, hist = self._cache[key]
        return float(m[idx]), float(sig[idx]), float(hist[idx])

    def stochastic(self, k=5, d=3, slow=3, shift=0):
        n = self._i - shift
        if n < k: return float("nan"), float("nan")
        raw = []
        for j in range(max(0, n - k * 4), n + 1):
            if j < k - 1: continue
            hh = self._h[j - k + 1: j + 1].max()
            ll = self._l[j - k + 1: j + 1].min()
            raw.append(50.0 if hh == ll else 100 * (self._c[j] - ll) / (hh - ll))
        if len(raw) < slow + d: return float("nan"), float("nan")
        sk = pd.Series(raw).rolling(slow).mean().dropna().values
        sd = pd.Series(sk).rolling(d).mean().dropna().values
        if not len(sk) or not len(sd): return float("nan"), float("nan")
        return float(sk[-1]), float(sd[-1])

    def cci(self, period=14, shift=0) -> float:
        sl = self._i - shift
        arr_h = self._h[max(0, sl - period + 1): sl + 1]
        arr_l = self._l[max(0, sl - period + 1): sl + 1]
        arr_c = self._c[max(0, sl - period + 1): sl + 1]
        if len(arr_c) < period: return float("nan")
        tp = (arr_h + arr_l + arr_c) / 3
        mad = np.mean(np.abs(tp - tp.mean()))
        return float((tp[-1] - tp.mean()) / (0.015 * mad)) if mad else 0.0

    def highest(self, period: int, shift=0) -> float:
        return float(self._h[max(0, self._i - shift - period + 1): self._i - shift + 1].max())

    def lowest(self, period: int, shift=0) -> float:
        return float(self._l[max(0, self._i - shift - period + 1): self._i - shift + 1].min())

    # ── Gaussian Indicators ───────────────────────────────────────────────
    def _gaussian_series(self, period: int, poles: int) -> np.ndarray:
        """
        Compute full Gaussian filter (multi-pole recursive IIR) over all closes.
        Cached per (period, poles) key — computed once, reused on every bar.
        Formula (DonovanWall / John Ehlers):
            beta  = (1 - cos(2π/period)) / (2^(1/poles) - 1)
            alpha = -beta + sqrt(beta² + 2·beta)
        Applied `poles` times as first-order recursive filter.
        """
        key = (period, poles)
        if key in self._gf_cache:
            return self._gf_cache[key]
        beta  = (1 - math.cos(2 * math.pi / period)) / (pow(2, 1.0 / poles) - 1)
        alpha = -beta + math.sqrt(beta * beta + 2 * beta)
        result = self._c.astype(float).copy()
        for _ in range(poles):
            buf = result.copy()
            for j in range(1, len(result)):
                buf[j] = alpha * result[j] + (1.0 - alpha) * buf[j - 1]
            result = buf
        self._gf_cache[key] = result
        return result

    def gaussian_filter(self, period: int = 20, poles: int = 4, shift: int = 0) -> float:
        """
        Gaussian-weighted moving average at current bar (or `shift` bars back).
        Uses a sliding window of 5000 bars to match MT5 MQ5 implementation.
        """
        idx = self._i - shift
        if idx < 0:
            return float("nan")
        # Use sliding window to match MT5 (5000 bars max, not full history)
        return float(self._gaussian_filter_windowed(period, poles, idx))

    def _gaussian_filter_windowed(self, period: int, poles: int, idx: int,
                                   window: int = 5000) -> float:
        """
        Compute Gaussian filter at a specific index using a sliding window
        of `window` bars — matches the MT5 MQ5 implementation exactly.
        MT5 EA uses CopyClose(shift, barsNeeded) where barsNeeded = min(totalBars-shift, 5000).
        """
        key = ("gf_win", period, poles, idx)
        if key in self._gf_cache:
            return self._gf_cache[key]

        # Determine window: from idx going back `window` bars
        start = max(0, idx - window + 1)
        end = idx + 1
        closes = self._c[start:end].astype(float).copy()

        if len(closes) < period * 3:
            return float("nan")

        beta  = (1 - math.cos(2 * math.pi / period)) / (pow(2, 1.0 / poles) - 1)
        alpha = -beta + math.sqrt(beta * beta + 2 * beta)

        result = closes.copy()
        for _ in range(poles):
            buf = result.copy()
            for j in range(1, len(result)):
                buf[j] = alpha * result[j] + (1.0 - alpha) * buf[j - 1]
            result = buf

        val = float(result[-1])
        self._gf_cache[key] = val
        return val

    def gaussian_channel(self, period: int = 144, poles: int = 4,
                         mult: float = 2.0, atr_period: int = 14,
                         shift: int = 0):
        """
        Gaussian Channel: Gaussian MA ± mult × ATR bands.
        Returns (upper, mid, lower).
        """
        mid     = self.gaussian_filter(period, poles, shift)
        atr_val = self.atr(atr_period, shift)
        if math.isnan(mid) or math.isnan(atr_val):
            return float("nan"), float("nan"), float("nan")
        return mid + mult * atr_val, mid, mid - mult * atr_val


# ══════════════════════════════════════════════════════════════════════════════
#  BASE EA
# ══════════════════════════════════════════════════════════════════════════════

class BaseEA:
    """
    Subclass this and override on_tick().
    All price, indicator, and order methods are available as self.* methods.
    """

    # ── injected by Backtest ──────────────────────────────────────────────
    _feed:   Feed
    _broker: Broker
    _symbol: str

    # ── lifecycle (override if needed) ────────────────────────────────────
    def on_init(self):  pass
    def on_tick(self):  raise NotImplementedError
    def on_deinit(self): pass

    # ── current bar prices ────────────────────────────────────────────────
    @property
    def ask(self):   return self._broker.ask
    @property
    def bid(self):   return self._broker.bid
    @property
    def now(self):   return self._broker.now

    # ── bar accessors (shift=0 → current) ─────────────────────────────────
    def iOpen(self,  shift=0): return self._feed.iOpen(shift)
    def iHigh(self,  shift=0): return self._feed.iHigh(shift)
    def iLow(self,   shift=0): return self._feed.iLow(shift)
    def iClose(self, shift=0): return self._feed.iClose(shift)
    def iTime(self,  shift=0): return self._feed.iTime(shift)

    # ── indicators ────────────────────────────────────────────────────────
    def sma(self, period, shift=0):            return self._feed.sma(period, shift)
    def ema(self, period, shift=0):            return self._feed.ema(period, shift)
    def rsi(self, period=14, shift=0):         return self._feed.rsi(period, shift)
    def atr(self, period=14, shift=0):         return self._feed.atr(period, shift)
    def bollinger(self, period=20, dev=2.0, shift=0): return self._feed.bollinger(period, dev, shift)
    def macd(self, fast=12, slow=26, signal=9, shift=0): return self._feed.macd(fast, slow, signal, shift)
    def stochastic(self, k=5, d=3, slow=3, shift=0): return self._feed.stochastic(k, d, slow, shift)
    def cci(self, period=14, shift=0):         return self._feed.cci(period, shift)
    def highest(self, period, shift=0):        return self._feed.highest(period, shift)
    def lowest(self, period, shift=0):         return self._feed.lowest(period, shift)
    def gaussian_filter(self, period=20, poles=4, shift=0):
        return self._feed.gaussian_filter(period, poles, shift)
    def gaussian_channel(self, period=144, poles=4, mult=2.0, atr_period=14, shift=0):
        return self._feed.gaussian_channel(period, poles, mult, atr_period, shift)

    # ── orders ────────────────────────────────────────────────────────────
    def buy(self, volume=0.1, sl=0.0, tp=0.0, comment=""):
        return self._broker.open_market(OrderType.BUY, volume, sl, tp, comment)

    def sell(self, volume=0.1, sl=0.0, tp=0.0, comment=""):
        return self._broker.open_market(OrderType.SELL, volume, sl, tp, comment)

    def buy_limit(self, volume, price, sl=0.0, tp=0.0, comment=""):
        return self._broker.place_pending(OrderType.BUY_LIMIT, volume, price, sl, tp, comment)

    def sell_limit(self, volume, price, sl=0.0, tp=0.0, comment=""):
        return self._broker.place_pending(OrderType.SELL_LIMIT, volume, price, sl, tp, comment)

    def buy_stop(self, volume, price, sl=0.0, tp=0.0, comment=""):
        return self._broker.place_pending(OrderType.BUY_STOP, volume, price, sl, tp, comment)

    def sell_stop(self, volume, price, sl=0.0, tp=0.0, comment=""):
        return self._broker.place_pending(OrderType.SELL_STOP, volume, price, sl, tp, comment)

    def close(self, comment=""):
        return self._broker.close_position(comment)

    def modify(self, sl=0.0, tp=0.0):
        self._broker.modify_sl_tp(sl, tp)

    def cancel(self, ticket: int):
        self._broker.cancel_pending(ticket)

    # ── position ──────────────────────────────────────────────────────────
    @property
    def position(self) -> Optional[Trade]:
        return self._broker.position

    @property
    def is_long(self) -> bool:
        return bool(self._broker.position and self._broker.position.is_long)

    @property
    def is_short(self) -> bool:
        return bool(self._broker.position and not self._broker.position.is_long)

    # ── account ───────────────────────────────────────────────────────────
    @property
    def balance(self):     return self._broker.balance
    @property
    def equity(self):      return self._broker.equity
    @property
    def free_margin(self): return self._broker.free_margin

    def calc_lot(self, risk_pct: float, sl_distance: float) -> float:
        """Calculate lot size for given risk% and SL distance in price units."""
        return self._broker.calc_lot(risk_pct, sl_distance, price=self.ask)

    @property
    def pair_spec(self) -> dict:
        return self._broker._pair_spec

    def Print(self, *args):
        print(f"[{type(self).__name__}]", *args)


# ══════════════════════════════════════════════════════════════════════════════
#  BACKTEST ENGINE
# ══════════════════════════════════════════════════════════════════════════════

class Backtest:
    """
    Parameters
    ----------
    df              : pd.DataFrame with OHLCV data
    ea_class        : BaseEA subclass (not an instance)
    ea_kwargs       : dict of kwargs passed to the EA constructor
    balance         : starting account balance
    commission      : round-trip commission per 1 lot
    spread_pts      : fixed spread in points
    lot_size        : units per lot (100,000 for forex)
    leverage        : account leverage
    swap_long/short : daily swap per lot
    warmup          : bars skipped before EA starts trading
    """

    def __init__(
        self,
        df:           pd.DataFrame,
        ea_class,
        ea_kwargs:    dict        = None,
        balance:      float       = 10_000,
        commission:   float       = 7.0,
        spread_pts:   int         = 2,
        lot_size:     int         = None,
        leverage:     int         = 100,
        swap_long:    float       = -0.5,
        swap_short:   float       = -0.5,
        warmup:       int         = 100,
        symbol:       str         = "SYMBOL",
        timeframe:    str         = "D1",
    ):
        # Auto-detect lot_size from symbol if not explicitly provided
        if lot_size is None:
            lot_size = get_pair_spec(symbol)["lot_size"]
        self.feed   = Feed(df)
        self.broker = Broker(balance, commission, spread_pts,
                             lot_size, leverage, swap_long, swap_short,
                             symbol=symbol)
        self.ea     = ea_class(**(ea_kwargs or {}))
        self.ea._feed   = self.feed
        self.ea._broker = self.broker
        self.ea._symbol = symbol
        self.warmup   = warmup
        self.symbol   = symbol
        self.timeframe = timeframe

    def run(self) -> "Result":
        self.ea.on_init()
        last_day = None

        for i in range(self.feed.total):
            self.feed._i = i
            bar_time = self.feed.time

            if last_day is None or bar_time.date() != last_day:
                if last_day is not None:
                    self.broker.daily_swap(bar_time.weekday())
                last_day = bar_time.date()

            # Per-bar spread: use max of data spread and configured base spread
            self.broker.spread_pts = self.broker._base_spread_pts
            bar_spread = None
            if self.feed._spread is not None:
                raw = int(self.feed._spread[i])
                if raw > self.broker._base_spread_pts:
                    bar_spread = raw

            # ── MT5-accurate bar processing order ──
            # Step 1: Set prices to bar OPEN first (for pending signal execution)
            #         MT5 executes pending signals at the new bar's open price.
            hs = (bar_spread if bar_spread else self.broker.spread_pts) * self.broker._pair_spec["point"] / 2
            self.broker.bid = self.feed.open - hs
            self.broker.ask = self.feed.open + hs
            self.broker.now = bar_time
            if bar_spread is not None:
                self.broker.spread_pts = bar_spread

            # Step 2: Let EA see the new bar open (executes pending signals here)
            if i >= self.warmup:
                try:
                    self.ea.on_tick()
                except Exception as e:
                    if not getattr(self, '_err_logged', False):
                        import traceback
                        print(f"[ENGINE] EA error at bar {i}: {e}")
                        traceback.print_exc()
                        self._err_logged = True

            # Step 3: Check SL/TP against bar's High and Low (intra-bar)
            if self.broker._pos:
                self.broker._check_sl_tp_hilo(self.feed.high, self.feed.low, hs)

            # Step 4: Set prices to bar CLOSE (for signal detection on this bar)
            self.broker.bid = self.feed.close - hs
            self.broker.ask = self.feed.close + hs
            self.broker._check_sl_tp()
            self.broker._check_stopout()
            self.broker._check_pending()

            eq = self.broker._equity()
            self.broker.balance_curve.append((bar_time, self.broker.balance))
            self.broker.equity_curve.append((bar_time, eq))

            # Step 5: Second EA tick at bar close (for signal detection)
            #         MT5 EAs see the bar close and generate pendingSignal
            if i >= self.warmup:
                try:
                    self.ea.on_tick()
                except Exception as e:
                    pass  # already logged

        # close any open position at the end
        if self.broker.position:
            self.broker.close_position("END")

        self.ea.on_deinit()

        return Result(
            symbol          = self.symbol,
            timeframe       = self.timeframe,
            ea_name         = type(self.ea).__name__,
            initial_balance = self.broker.initial_balance,
            final_balance   = self.broker.balance,
            trades          = self.broker.history,
            equity_curve    = self.broker.equity_curve,
            balance_curve   = self.broker.balance_curve,
            start           = self.feed._t[0],
            end             = self.feed._t[-1],
            margin_calls    = self.broker._margin_calls,
            margin_rejects  = self.broker._rejected_margin,
        )


# ══════════════════════════════════════════════════════════════════════════════
#  RESULT  (metrics + reports)
# ══════════════════════════════════════════════════════════════════════════════

class Result:
    def __init__(self, symbol, timeframe, ea_name, initial_balance,
                 final_balance, trades, equity_curve, balance_curve,
                 start, end, margin_calls=0, margin_rejects=0):
        self.symbol          = symbol
        self.timeframe       = timeframe
        self.ea_name         = ea_name
        self.initial_balance = initial_balance
        self.final_balance   = final_balance
        self.trades          = trades
        self.equity_curve    = equity_curve
        self.balance_curve   = balance_curve
        self.start           = start
        self.end             = end
        self.margin_calls    = margin_calls
        self.margin_rejects  = margin_rejects
        self._stats: Optional[dict] = None

    # ── computed on first access ──────────────────────────────────────────
    @property
    def stats(self) -> dict:
        if self._stats is None:
            self._stats = self._compute()
        return self._stats

    def _compute(self) -> dict:
        trades = self.trades
        if not trades:
            return {"error": "No trades"}

        profits = np.array([t.net_profit for t in trades])
        wins    = profits[profits > 0]
        losses  = profits[profits < 0]

        gross_profit = wins.sum()   if len(wins)   else 0.0
        gross_loss   = losses.sum() if len(losses) else 0.0
        net          = profits.sum()
        pf           = abs(gross_profit / gross_loss) if gross_loss else float("inf")
        win_rate     = len(wins) / len(profits) * 100
        avg_win      = wins.mean()   if len(wins)   else 0.0
        avg_loss     = losses.mean() if len(losses) else 0.0
        expectancy   = profits.mean()
        payoff       = abs(avg_win / avg_loss) if avg_loss else float("inf")
        best         = profits.max()
        worst        = profits.min()

        # drawdown
        eq = np.array([v for _, v in self.equity_curve])
        peak = np.maximum.accumulate(eq)
        dd   = peak - eq
        max_dd     = dd.max()
        max_dd_pct = (max_dd / peak[np.argmax(dd)] * 100) if max_dd else 0.0
        abs_dd     = self.initial_balance - eq.min()
        rel_dd_pct = (dd / np.maximum(peak, 1e-10) * 100).max()

        # streaks
        w_arr = (profits > 0).astype(int)
        def max_streak(arr, val):
            best = cur = 0
            for x in arr:
                cur = cur + 1 if x == val else 0
                best = max(best, cur)
            return best

        # risk ratios — annualize based on timeframe
        ret = np.diff(eq) / np.maximum(eq[:-1], 1e-10)
        tf_map = {"M1": 252*24*60, "M5": 252*24*12, "M15": 252*24*4,
                  "M30": 252*24*2, "H1": 252*24, "H4": 252*6,
                  "D1": 252, "W1": 52, "MN1": 12}
        bars_per_year = tf_map.get(self.timeframe, 252)
        ann = math.sqrt(bars_per_year)
        sharpe  = ret.mean() / ret.std(ddof=1) * ann  if ret.std(ddof=1) else 0.0
        down    = ret[ret < 0]
        sortino = ret.mean() / down.std(ddof=1) * ann  if len(down) > 1 else 0.0
        calmar  = net / max_dd if max_dd else float("inf")
        recover = net / max_dd if max_dd else float("inf")

        long_t  = [t for t in trades if t.is_long]
        short_t = [t for t in trades if not t.is_long]

        dur = self.end - self.start

        return {
            "EA":               self.ea_name,
            "Symbol":           self.symbol,
            "Timeframe":        self.timeframe,
            "Start":            str(self.start)[:10],
            "End":              str(self.end)[:10],
            "Duration (days)":  dur.days,
            # account
            "Initial Balance":  round(self.initial_balance, 2),
            "Final Balance":    round(self.final_balance, 2),
            "Net Profit":       round(net, 2),
            "Net Profit %":     round(net / self.initial_balance * 100, 2),
            "Gross Profit":     round(gross_profit, 2),
            "Gross Loss":       round(gross_loss, 2),
            "Profit Factor":    round(pf, 4),
            # drawdown
            "Abs Drawdown":     round(abs_dd, 2),
            "Max Drawdown":     round(max_dd, 2),
            "Max Drawdown %":   round(max_dd_pct, 2),
            "Rel Drawdown %":   round(rel_dd_pct, 2),
            # trades
            "Total Trades":     len(trades),
            "Long Trades":      len(long_t),
            "Short Trades":     len(short_t),
            "Win Rate %":       round(win_rate, 2),
            "Winning Trades":   len(wins),
            "Losing Trades":    len(losses),
            "Avg Win":          round(avg_win, 2),
            "Avg Loss":         round(avg_loss, 2),
            "Best Trade":       round(best, 2),
            "Worst Trade":      round(worst, 2),
            "Expectancy":       round(expectancy, 2),
            "Payoff Ratio":     round(payoff, 4),
            "Max Consec Wins":  max_streak(w_arr, 1),
            "Max Consec Loss":  max_streak(w_arr, 0),
            # risk
            "Sharpe Ratio":     round(sharpe, 4),
            "Sortino Ratio":    round(sortino, 4),
            "Calmar Ratio":     round(calmar, 4),
            "Recovery Factor":  round(recover, 4),
        }

    # ── dataframe ─────────────────────────────────────────────────────────
    def trades_df(self) -> pd.DataFrame:
        if not self.trades:
            return pd.DataFrame()
        return pd.DataFrame([{
            "#":           t.ticket,
            "type":        t.order_type.value,
            "vol":         t.volume,
            "open_time":   t.open_time,
            "open":        round(t.open_price, 5),
            "close_time":  t.close_time,
            "close":       round(t.close_price, 5),
            "sl":          t.sl,
            "tp":          t.tp,
            "profit":      round(t.profit, 2),
            "comm":        round(t.commission, 2),
            "swap":        round(t.swap, 2),
            "net":         round(t.net_profit, 2),
            "comment":     t.comment,
        } for t in self.trades])

    def monthly_pnl(self) -> pd.DataFrame:
        df = self.trades_df()
        if df.empty: return pd.DataFrame()
        df["close_time"] = pd.to_datetime(df["close_time"])
        df["yr"]  = df["close_time"].dt.year
        df["mon"] = df["close_time"].dt.strftime("%b")
        pivot = df.pivot_table(values="net", index="yr", columns="mon", aggfunc="sum")
        order = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"]
        pivot = pivot.reindex(columns=[m for m in order if m in pivot.columns])
        pivot["Total"] = pivot.sum(axis=1)
        return pivot.round(2)

    # ── console report ────────────────────────────────────────────────────
    def print_report(self):
        s = self.stats
        W = 64
        print("=" * W)
        print(f"  {s.get('EA','')}  |  {s.get('Symbol','')} {s.get('Timeframe','')}")
        print(f"  {s.get('Start','')} → {s.get('End','')}  ({s.get('Duration (days)',0)} days)")
        print("=" * W)
        groups = [
            ("ACCOUNT", ["Initial Balance","Final Balance","Net Profit",
                         "Net Profit %","Gross Profit","Gross Loss","Profit Factor"]),
            ("DRAWDOWN", ["Abs Drawdown","Max Drawdown","Max Drawdown %","Rel Drawdown %"]),
            ("TRADES",   ["Total Trades","Long Trades","Short Trades",
                          "Win Rate %","Winning Trades","Losing Trades",
                          "Avg Win","Avg Loss","Best Trade","Worst Trade",
                          "Expectancy","Payoff Ratio",
                          "Max Consec Wins","Max Consec Loss"]),
            ("RISK",     ["Sharpe Ratio","Sortino Ratio","Calmar Ratio","Recovery Factor"]),
        ]
        for title, keys in groups:
            print(f"\n  {title}")
            print("  " + "-" * (W - 2))
            for k in keys:
                v = s.get(k, "N/A")
                label = f"  {k}".ljust(30)
                val   = f"{v:>10,.4f}" if isinstance(v, float) else f"{v:>10}"
                print(f"{label}{val}")
        print("=" * W)

    # ── charts ────────────────────────────────────────────────────────────
    def plot(self, show: bool = True):
        import matplotlib
        matplotlib.use("Agg" if not show else matplotlib.get_backend())
        import matplotlib.pyplot as plt

        fig, axes = plt.subplots(3, 1, figsize=(14, 12),
                                 gridspec_kw={"height_ratios": [3, 1.2, 1.2]})
        s = self.stats
        fig.suptitle(f"{s.get('EA','')} | {s.get('Symbol','')} {s.get('Timeframe','')} | "
                     f"Net: ${s.get('Net Profit',0):,.0f}  WR: {s.get('Win Rate %',0):.1f}%  "
                     f"PF: {s.get('Profit Factor',0):.2f}",
                     fontsize=12, fontweight="bold")

        # equity / balance
        if self.equity_curve:
            et, ev = zip(*self.equity_curve)
            bt, bv = zip(*self.balance_curve)
            axes[0].plot(et, ev, "#1f77b4", lw=1.2, label="Equity")
            axes[0].plot(bt, bv, "#ff7f0e", lw=1.0, ls="--", label="Balance")
            axes[0].axhline(self.initial_balance, color="grey", ls=":", lw=0.8)
            axes[0].set_ylabel("Account ($)")
            axes[0].legend(fontsize=9); axes[0].grid(alpha=0.3)

            # drawdown
            ev_arr = np.array(ev)
            peak = np.maximum.accumulate(ev_arr)
            dd_pct = (peak - ev_arr) / np.maximum(peak, 1e-10) * 100
            axes[1].fill_between(et, -dd_pct, 0, color="red", alpha=0.4)
            axes[1].set_ylabel("Drawdown %"); axes[1].grid(alpha=0.3)

        # per-trade P&L bars
        df = self.trades_df()
        if not df.empty:
            colors = ["green" if v > 0 else "red" for v in df["net"]]
            axes[2].bar(range(len(df)), df["net"], color=colors, width=0.8, alpha=0.7)
            axes[2].axhline(0, color="grey", lw=0.8)
            axes[2].set_ylabel("Trade P&L ($)"); axes[2].grid(alpha=0.3)

        plt.tight_layout(rect=[0, 0, 1, 0.95])
        if show:
            plt.show()
        return fig

    # ── PDF ───────────────────────────────────────────────────────────────
    def save_pdf(self, path: str = "report.pdf"):
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        from matplotlib.backends.backend_pdf import PdfPages

        with PdfPages(path) as pdf:
            fig = self.plot(show=False)
            pdf.savefig(fig, bbox_inches="tight"); plt.close(fig)

            # trade distribution page
            df = self.trades_df()
            if not df.empty:
                fig2, axes = plt.subplots(2, 2, figsize=(14, 10))
                fig2.suptitle("Trade Analysis", fontsize=13, fontweight="bold")
                # cumulative profit
                axes[0,0].plot(df["net"].cumsum().values, "#2ca02c")
                axes[0,0].axhline(0, color="grey", lw=0.8, ls=":")
                axes[0,0].set_title("Cumulative P&L"); axes[0,0].grid(alpha=0.3)
                # histogram
                axes[0,1].hist(df["net"], bins=40, color="#9467bd", edgecolor="white", alpha=0.8)
                axes[0,1].axvline(0, color="red", lw=1.2, ls="--")
                axes[0,1].set_title("P&L Distribution"); axes[0,1].grid(alpha=0.3)
                # pie
                wc = (df["net"] > 0).sum(); lc = (df["net"] <= 0).sum()
                axes[1,0].pie([wc, lc], labels=["Wins","Losses"],
                              colors=["#2ca02c","#d62728"], autopct="%1.1f%%")
                axes[1,0].set_title("Win/Loss Split")
                # monthly
                monthly = self.monthly_pnl()
                if not monthly.empty:
                    axes[1,1].bar(range(len(monthly)), monthly["Total"],
                                  color=["green" if v >= 0 else "red"
                                         for v in monthly["Total"]])
                    axes[1,1].set_xticks(range(len(monthly)))
                    axes[1,1].set_xticklabels(monthly.index.astype(str), rotation=45)
                    axes[1,1].set_title("Yearly P&L"); axes[1,1].grid(alpha=0.3)
                plt.tight_layout(rect=[0,0,1,0.95])
                pdf.savefig(fig2, bbox_inches="tight"); plt.close(fig2)

        print(f"PDF saved → {path}")

    # ── HTML ──────────────────────────────────────────────────────────────
    def save_html(self, path: str = "report.html"):
        s  = self.stats
        df = self.trades_df()
        net = s.get("Net Profit", 0)

        def row(k, v, col=""):
            style = f' style="color:{col}"' if col else ""
            val = f"{v:,.2f}" if isinstance(v, float) else str(v)
            return f"<tr><td>{k}</td><td{style}><b>{val}</b></td></tr>"

        trade_rows = ""
        if not df.empty:
            for _, r in df.head(500).iterrows():
                c = "green" if r["net"] > 0 else "red"
                trade_rows += (f"<tr style='color:{c}'>"
                    f"<td>{r['#']}</td><td>{r['type']}</td><td>{r['vol']}</td>"
                    f"<td>{r['open_time']}</td><td>{r['open']}</td>"
                    f"<td>{r['close_time']}</td><td>{r['close']}</td>"
                    f"<td>{r['net']}</td><td>{r['comment']}</td></tr>")

        html = f"""<!DOCTYPE html><html><head><meta charset='UTF-8'>
<title>{s.get('EA','')} — {s.get('Symbol','')}</title>
<style>
body{{font-family:Segoe UI,Arial;background:#f5f5f5;padding:20px;color:#333}}
h1{{background:#2c3e50;color:white;padding:14px 20px;border-radius:6px}}
h2{{color:#2c3e50;border-left:4px solid #3498db;padding-left:10px;margin-top:28px}}
.grid{{display:grid;grid-template-columns:repeat(2,1fr);gap:18px}}
.card{{background:white;border-radius:8px;padding:18px;box-shadow:0 2px 6px rgba(0,0,0,.1)}}
table{{width:100%;border-collapse:collapse;font-size:.9em}}
th,td{{padding:7px 12px;text-align:left;border-bottom:1px solid #e5e5e5}}
th{{background:#3498db;color:white}}tr:hover{{background:#f0f7ff}}
.badge{{display:inline-block;padding:4px 12px;border-radius:12px;font-weight:bold;font-size:1.1em}}
.pos{{background:#e8f5e9;color:green}}.neg{{background:#ffebee;color:red}}
</style></head><body>
<h1>{s.get('EA','')} &nbsp;|&nbsp; {s.get('Symbol','')} {s.get('Timeframe','')}</h1>
<p><b>Period:</b> {s.get('Start','')} → {s.get('End','')} ({s.get('Duration (days)',0)} days)</p>
<p>Net Profit: <span class="badge {'pos' if net>=0 else 'neg'}">${net:,.2f} ({s.get('Net Profit %',0):.2f}%)</span></p>
<div class='grid'>
<div class='card'><h2>Account</h2><table>
{row("Initial Balance", s.get("Initial Balance",0))}
{row("Final Balance",   s.get("Final Balance",0))}
{row("Net Profit",      s.get("Net Profit",0), "green" if net>=0 else "red")}
{row("Gross Profit",    s.get("Gross Profit",0), "green")}
{row("Gross Loss",      s.get("Gross Loss",0), "red")}
{row("Profit Factor",   s.get("Profit Factor",0))}
</table></div>
<div class='card'><h2>Drawdown</h2><table>
{row("Abs Drawdown",   s.get("Abs Drawdown",0))}
{row("Max Drawdown",   s.get("Max Drawdown",0), "red")}
{row("Max Drawdown %", s.get("Max Drawdown %",0), "red")}
{row("Rel Drawdown %", s.get("Rel Drawdown %",0))}
</table></div>
<div class='card'><h2>Trades</h2><table>
{row("Total Trades",  s.get("Total Trades",0))}
{row("Win Rate %",    s.get("Win Rate %",0))}
{row("Avg Win",       s.get("Avg Win",0), "green")}
{row("Avg Loss",      s.get("Avg Loss",0), "red")}
{row("Best Trade",    s.get("Best Trade",0), "green")}
{row("Worst Trade",   s.get("Worst Trade",0), "red")}
{row("Expectancy",    s.get("Expectancy",0))}
{row("Payoff Ratio",  s.get("Payoff Ratio",0))}
</table></div>
<div class='card'><h2>Risk</h2><table>
{row("Sharpe Ratio",   s.get("Sharpe Ratio",0))}
{row("Sortino Ratio",  s.get("Sortino Ratio",0))}
{row("Calmar Ratio",   s.get("Calmar Ratio",0))}
{row("Recovery Factor",s.get("Recovery Factor",0))}
</table></div>
</div>
<h2>Trade History</h2>
<div style='overflow-x:auto'><table>
<tr><th>#</th><th>Type</th><th>Vol</th><th>Open Time</th><th>Open</th>
<th>Close Time</th><th>Close</th><th>Net P&L</th><th>Comment</th></tr>
{trade_rows}
</table></div>
<p style='color:#aaa;font-size:.8em;margin-top:30px'>Python MT5 Backtest Engine</p>
</body></html>"""

        with open(path, "w", encoding="utf-8") as f:
            f.write(html)
        print(f"HTML saved → {path}")


# ══════════════════════════════════════════════════════════════════════════════
#  DATA LOADER
# ══════════════════════════════════════════════════════════════════════════════

class DataLoader:
    @staticmethod
    def yahoo(symbol: str, start: str, end: str = None, interval: str = "1d") -> pd.DataFrame:
        try:
            import yfinance as yf
        except ImportError:
            raise ImportError("pip install yfinance")
        df = yf.Ticker(symbol).history(start=start, end=end, interval=interval, auto_adjust=True)
        df = df[["Open","High","Low","Close","Volume"]].copy()
        df.columns = ["open","high","low","close","volume"]
        df.index.name = "time"
        return df.dropna()

    @staticmethod
    def csv(path: str, time_col="time", sep=",") -> pd.DataFrame:
        df = pd.read_csv(path, sep=sep)
        df.columns = [c.lower() for c in df.columns]
        df = df.rename(columns={time_col.lower(): "time"})
        df["time"] = pd.to_datetime(df["time"])
        return df.set_index("time").sort_index()

    @staticmethod
    def mt5_csv(path: str) -> pd.DataFrame:
        """
        Load an MT5-exported CSV / TSV file.
        Expected columns: <DATE>  <TIME>  <OPEN>  <HIGH>  <LOW>  <CLOSE>
                          <TICKVOL>  <VOL>  <SPREAD>
        Tab-separated, dates in YYYY.MM.DD format.
        """
        # Try tab first; fall back to comma
        for sep in ("\t", ",", ";"):
            try:
                df = pd.read_csv(path, sep=sep)
                if df.shape[1] >= 6:
                    break
            except Exception:
                continue
        # Strip angle-bracket wrappers: <DATE> → date
        df.columns = [c.strip().strip("<>").lower() for c in df.columns]
        # Build datetime index from separate date + time columns
        if "date" in df.columns and "time" in df.columns:
            df["datetime"] = pd.to_datetime(
                df["date"].astype(str) + " " + df["time"].astype(str),
                format="%Y.%m.%d %H:%M:%S",
            )
            df = df.set_index("datetime")
            df.index.name = "time"
        elif "datetime" in df.columns:
            df["datetime"] = pd.to_datetime(df["datetime"])
            df = df.set_index("datetime")
            df.index.name = "time"
        # Normalise column names
        rename_map = {
            "tickvol": "volume",
            "vol":     "vol_raw",
        }
        df = df.rename(columns=rename_map)
        needed = ["open", "high", "low", "close"]
        for col in needed:
            if col not in df.columns:
                raise ValueError(f"mt5_csv: missing required column '{col}'")
        if "volume" not in df.columns:
            df["volume"] = 0
        cols = ["open", "high", "low", "close", "volume"]
        if "spread" in df.columns:
            cols.append("spread")
        return df[cols].copy().sort_index()

    @staticmethod
    def resample(df: pd.DataFrame, target_tf: str = "1h") -> pd.DataFrame:
        """Resample OHLCV data to a higher timeframe (e.g., M15 → H1)."""
        agg = {
            "open": "first",
            "high": "max",
            "low": "min",
            "close": "last",
            "volume": "sum",
        }
        if "spread" in df.columns:
            agg["spread"] = "max"  # worst-case spread
        resampled = df.resample(target_tf).agg(agg).dropna()
        return resampled

    @staticmethod
    def synthetic(n=3000, price=1.1, vol=0.001, seed=42) -> pd.DataFrame:
        rng = np.random.default_rng(seed)
        idx = pd.date_range("2020-01-01", periods=n, freq="D", tz="UTC")
        c = price * np.exp(np.cumsum(rng.normal(0, vol, n)))
        h = c * (1 + abs(rng.normal(0, vol/2, n)))
        l = c * (1 - abs(rng.normal(0, vol/2, n)))
        o = np.roll(c, 1); o[0] = price
        return pd.DataFrame({"open":o,"high":h,"low":l,"close":c,
                             "volume":rng.integers(100,9999,n)}, index=idx)
