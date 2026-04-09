"""
hmm_backtest.py — HMM Regime Backtester
=========================================
Backtests the HMM regime + GaussMACD strategy entirely in Python.
Produces MT5-style metrics (Net Profit, PF, DD%, Sharpe, WR).

Uses real MT5 data via the MetaTrader5 Python API.

Usage:
    python hmm_backtest.py                              # Default 2024-2026
    python hmm_backtest.py --from 2022-01-01            # Custom start
    python hmm_backtest.py --states 7                   # 7 HMM states
    python hmm_backtest.py --cooldown 24                # 24-bar cooldown
    python hmm_backtest.py --no-regime                  # Baseline without HMM
"""
import argparse
import warnings
import math
import sys
import numpy as np
import pandas as pd
from datetime import datetime, timedelta
from dataclasses import dataclass, field

warnings.filterwarnings("ignore")

try:
    import MetaTrader5 as mt5
except ImportError:
    print("pip install MetaTrader5"); sys.exit(1)

try:
    from hmmlearn.hmm import GaussianHMM
except ImportError:
    print("pip install hmmlearn"); sys.exit(1)


# ═══════════════════════════════════════════════════════════════════
#  DATA
# ═══════════════════════════════════════════════════════════════════
def fetch_mt5_data(symbol="XAUUSD.a", timeframe_str="H1", n_bars=10000):
    """Fetch OHLCV data from MT5."""
    tf_map = {
        "M1": mt5.TIMEFRAME_M1, "M5": mt5.TIMEFRAME_M5, "M15": mt5.TIMEFRAME_M15,
        "M30": mt5.TIMEFRAME_M30, "H1": mt5.TIMEFRAME_H1, "H4": mt5.TIMEFRAME_H4,
        "D1": mt5.TIMEFRAME_D1,
    }
    tf = tf_map.get(timeframe_str, mt5.TIMEFRAME_H1)

    if not mt5.initialize():
        print("  [ERROR] MT5 not running")
        return None

    rates = mt5.copy_rates_from_pos(symbol, tf, 0, n_bars)
    ping = mt5.terminal_info().ping_last
    mt5.shutdown()

    if rates is None or len(rates) == 0:
        print("  [ERROR] No data from MT5")
        return None

    df = pd.DataFrame(rates)
    df['time'] = pd.to_datetime(df['time'], unit='s')
    df = df.set_index('time')
    print(f"  Fetched {len(df)} {timeframe_str} bars | {df.index[0]} to {df.index[-1]}")
    print(f"  MT5 ping: {ping // 1000}ms")
    return df


# ═══════════════════════════════════════════════════════════════════
#  HMM REGIME DETECTION
# ═══════════════════════════════════════════════════════════════════
def compute_features(df):
    """Compute HMM features."""
    df = df.copy()
    df['returns'] = np.log(df['close'] / df['close'].shift(1))
    df['range'] = (df['high'] - df['low']) / df['close']
    df['vol_change'] = np.log((df['tick_volume'] + 1) / (df['tick_volume'].shift(1) + 1))
    df = df.dropna()
    return df


def train_hmm(features, n_states=5):
    """Train Gaussian HMM and return states + probabilities."""
    X = features[['returns', 'range', 'vol_change']].values

    best_model = None
    best_score = -np.inf

    for seed in range(10):
        try:
            model = GaussianHMM(n_components=n_states, covariance_type="full",
                                n_iter=200, random_state=seed * 42, tol=0.01)
            model.fit(X)
            score = model.score(X)
            if score > best_score:
                best_score = score
                best_model = model
        except:
            continue

    if best_model is None:
        return None, None, None

    states = best_model.predict(X)
    probs = best_model.predict_proba(X)

    # Auto-label: sort by mean return
    state_returns = {}
    for s in range(n_states):
        mask = states == s
        state_returns[s] = X[mask, 0].mean() if mask.sum() > 0 else 0

    sorted_states = sorted(state_returns.items(), key=lambda x: x[1], reverse=True)
    state_map = {orig: i + 1 for i, (orig, _) in enumerate(sorted_states)}
    regimes = np.array([state_map[s] for s in states])

    return best_model, regimes, probs


# ═══════════════════════════════════════════════════════════════════
#  INDICATORS (pure numpy, matching MT5)
# ═══════════════════════════════════════════════════════════════════
def calc_ema(close, period):
    """EMA matching MT5's calculation."""
    ema = pd.Series(close).ewm(span=period, adjust=False).mean().values
    return ema


def calc_rsi(close, period=14):
    """RSI matching MT5."""
    d = np.diff(close)
    gains = np.where(d > 0, d, 0.0)
    losses = np.where(d < 0, -d, 0.0)
    rsi = np.full(len(close), np.nan)
    ag = gains[:period].mean()
    al = losses[:period].mean()
    rsi[period] = 100.0 if al == 0 else 100 - 100 / (1 + ag / al)
    for j in range(period, len(d)):
        ag = (ag * (period - 1) + gains[j]) / period
        al = (al * (period - 1) + losses[j]) / period
        rsi[j + 1] = 100.0 if al == 0 else 100 - 100 / (1 + ag / al)
    return rsi


def calc_atr(high, low, close, period=14):
    """ATR matching MT5."""
    tr = np.empty(len(close))
    tr[0] = high[0] - low[0]
    for j in range(1, len(close)):
        tr[j] = max(high[j] - low[j], abs(high[j] - close[j-1]), abs(low[j] - close[j-1]))
    atr = np.full(len(close), np.nan)
    atr[period] = tr[1:period+1].mean()
    for j in range(period + 1, len(close)):
        atr[j] = (atr[j-1] * (period - 1) + tr[j]) / period
    return atr


def calc_macd(close, fast=12, slow=26, signal=9):
    """MACD histogram matching MT5."""
    s = pd.Series(close)
    m = s.ewm(span=fast, adjust=False).mean() - s.ewm(span=slow, adjust=False).mean()
    sig = m.ewm(span=signal, adjust=False).mean()
    hist = m - sig
    return m.values, sig.values, hist.values


def calc_gaussian(close, period=80, poles=4):
    """Gaussian filter matching MQ5 implementation."""
    beta = (1 - math.cos(2 * math.pi / period)) / (pow(2, 1.0 / poles) - 1)
    alpha = -beta + math.sqrt(beta * beta + 2 * beta)
    result = close.astype(float).copy()
    for _ in range(poles):
        buf = result.copy()
        for j in range(1, len(result)):
            buf[j] = alpha * result[j] + (1.0 - alpha) * buf[j - 1]
        result = buf
    return result


# ═══════════════════════════════════════════════════════════════════
#  BACKTESTER
# ═══════════════════════════════════════════════════════════════════
@dataclass
class Trade:
    bar_idx: int
    direction: int        # 1=buy, -1=sell
    entry_price: float
    sl: float
    tp: float
    exit_price: float = 0
    exit_bar: int = 0
    profit: float = 0
    comment: str = ""


class HMMBacktester:
    """MT5-style backtester with HMM regime filter."""

    def __init__(self, df, regimes, params):
        self.df = df
        self.regimes = regimes
        self.p = params

        # Precompute indicators
        c = df['close'].values
        h = df['high'].values
        l = df['low'].values

        self.close = c
        self.high = h
        self.low = l
        self.open = df['open'].values
        self.atr = calc_atr(h, l, c, 14)
        self.rsi = calc_rsi(c, 14)
        _, _, self.macd_hist = calc_macd(c, 12, 26, 9)
        self.gaussian = calc_gaussian(c, params.get('gauss_period', 80), params.get('gauss_poles', 4))

        # State
        self.balance = params.get('deposit', 1000.0)
        self.equity = self.balance
        self.position = None  # Active Trade
        self.trades = []
        self.balance_curve = []
        self.equity_curve = []
        self.max_balance = self.balance
        self.max_dd_pct = 0

        # Regime
        self.cooldown_left = 0
        self.prev_regime = 3  # NEUTRAL
        self.lot = params.get('lot', 0.01)
        self.spread = params.get('spread_pts', 16) * 0.01  # points to dollars
        self.leverage = params.get('leverage', 20)

    def _is_bull(self, regime):
        return regime <= 2

    def _is_bear(self, regime):
        return regime >= 4

    def run(self):
        """Run the backtest bar by bar."""
        warmup = max(250, self.p.get('gauss_period', 80) * 3)
        sl_mult = self.p.get('sl_mult', 2.5)
        tp_mult = self.p.get('tp_mult', 5.0)
        max_sl = self.p.get('max_sl', 30.0)
        rsi_ob = self.p.get('rsi_ob', 80.0)
        rsi_os = self.p.get('rsi_os', 28.0)
        cooldown_bars = self.p.get('cooldown', 48)
        use_regime = self.p.get('use_regime', True)
        close_on_flip = self.p.get('close_on_flip', True)

        pending_signal = 0
        pending_atr = 0

        for i in range(1, len(self.close)):
            price = self.close[i]
            bar_high = self.high[i]
            bar_low = self.low[i]

            # Update equity for open position
            if self.position:
                if self.position.direction == 1:
                    unrealized = (price - self.position.entry_price) * self.lot * 100
                else:
                    unrealized = (self.position.entry_price - price) * self.lot * 100
                self.equity = self.balance + unrealized

                # Check SL/TP hit within bar
                if self.position.direction == 1:  # Long
                    if bar_low <= self.position.sl:
                        self._close_trade(i, self.position.sl, "SL")
                    elif bar_high >= self.position.tp:
                        self._close_trade(i, self.position.tp, "TP")
                else:  # Short
                    if bar_high >= self.position.sl:
                        self._close_trade(i, self.position.sl, "SL")
                    elif bar_low <= self.position.tp:
                        self._close_trade(i, self.position.tp, "TP")

            self.equity = self.balance + (0 if not self.position else
                ((price - self.position.entry_price) * self.lot * 100 if self.position.direction == 1
                 else (self.position.entry_price - price) * self.lot * 100))

            # Track balance/equity
            self.balance_curve.append((i, self.balance))
            self.equity_curve.append((i, self.equity))
            if self.balance > self.max_balance:
                self.max_balance = self.balance
            dd = (self.max_balance - self.equity) / self.max_balance * 100 if self.max_balance > 0 else 0
            if dd > self.max_dd_pct:
                self.max_dd_pct = dd

            if i < warmup:
                continue

            # === EXECUTE PENDING SIGNAL ===
            if pending_signal != 0 and not self.position:
                ask = price + self.spread / 2
                bid = price - self.spread / 2
                sl_dist = pending_atr * sl_mult
                tp_dist = pending_atr * tp_mult

                if sl_dist > max_sl:
                    ratio = tp_mult / sl_mult
                    sl_dist = max_sl
                    tp_dist = sl_dist * ratio

                # Margin check
                margin_needed = price * self.lot * 100 / self.leverage
                if margin_needed < self.balance * 0.80:
                    if pending_signal == 1:
                        entry = ask
                        sl = entry - sl_dist
                        tp = entry + tp_dist
                        self.position = Trade(i, 1, entry, sl, tp, comment="Buy")
                    else:
                        entry = bid
                        sl = entry + sl_dist
                        tp = entry - tp_dist
                        self.position = Trade(i, -1, entry, sl, tp, comment="Sell")

                pending_signal = 0

            # === REGIME DETECTION ===
            regime = self.regimes[i] if i < len(self.regimes) else 3

            # Regime change
            if regime != self.prev_regime:
                self.cooldown_left = cooldown_bars

                # Close on flip
                if close_on_flip and self.position and use_regime:
                    was_bull = self._is_bull(self.prev_regime)
                    was_bear = self._is_bear(self.prev_regime)
                    now_bull = self._is_bull(regime)
                    now_bear = self._is_bear(regime)
                    if (was_bull and now_bear) or (was_bear and now_bull):
                        self._close_trade(i, price, "RegimeFlip")

                self.prev_regime = regime

            if self.cooldown_left > 0:
                self.cooldown_left -= 1

            # === SIGNAL GENERATION ===
            if self.position:
                continue

            # Cooldown
            if use_regime and self.cooldown_left > 0:
                continue

            # Regime filter
            allow_buy = (not use_regime) or self._is_bull(regime)
            allow_sell = (not use_regime) or self._is_bear(regime)
            if not allow_buy and not allow_sell:
                continue

            # Indicators at bar i-1 (completed bar)
            if i < 2:
                continue
            atr_val = self.atr[i - 1]
            rsi_val = self.rsi[i - 1]
            macd_hist_now = self.macd_hist[i - 1]
            macd_hist_prev = self.macd_hist[i - 2]
            gf_now = self.gaussian[i - 1]
            gf_prev = self.gaussian[i - 2]
            close_1 = self.close[i - 1]

            if np.isnan(atr_val) or np.isnan(rsi_val) or atr_val < 0.50:
                continue

            gf_rising = gf_now > gf_prev
            gf_falling = gf_now < gf_prev
            macd_up = macd_hist_now > macd_hist_prev and macd_hist_now > -0.5
            macd_dn = macd_hist_now < macd_hist_prev and macd_hist_now < 0.5

            # GaussMACD Buy
            if gf_rising and macd_up and close_1 > gf_now and allow_buy:
                if rsi_val < rsi_ob:
                    pending_signal = 1
                    pending_atr = atr_val

            # GaussMACD Sell
            elif gf_falling and macd_dn and close_1 < gf_now and allow_sell:
                if rsi_val > rsi_os:
                    pending_signal = -1
                    pending_atr = atr_val

        # Close any remaining position
        if self.position:
            self._close_trade(len(self.close) - 1, self.close[-1], "END")

    def _close_trade(self, bar_idx, exit_price, reason):
        """Close the current position."""
        if not self.position:
            return

        t = self.position
        t.exit_bar = bar_idx
        t.exit_price = exit_price

        if t.direction == 1:
            t.profit = (exit_price - t.entry_price) * self.lot * 100
        else:
            t.profit = (t.entry_price - exit_price) * self.lot * 100

        # Subtract spread cost
        t.profit -= self.spread * self.lot * 100

        t.comment = reason
        self.balance += t.profit
        self.trades.append(t)
        self.position = None

    def results(self):
        """Calculate MT5-style results."""
        if not self.trades:
            return {"error": "No trades"}

        wins = [t for t in self.trades if t.profit > 0]
        losses = [t for t in self.trades if t.profit <= 0]
        gross_profit = sum(t.profit for t in wins)
        gross_loss = abs(sum(t.profit for t in losses))

        net = sum(t.profit for t in self.trades)
        pf = gross_profit / gross_loss if gross_loss > 0 else 999
        wr = len(wins) / len(self.trades) * 100

        # Sharpe
        returns = [t.profit for t in self.trades]
        avg_ret = np.mean(returns)
        std_ret = np.std(returns)
        sharpe = (avg_ret / std_ret * np.sqrt(252)) if std_ret > 0 else 0

        # Recovery
        recovery = net / (self.max_dd_pct / 100 * self.p.get('deposit', 1000)) if self.max_dd_pct > 0 else 999

        # Duration
        first_bar = self.df.index[0]
        last_bar = self.df.index[-1]
        days = (last_bar - first_bar).days
        monthly = net / max(days / 30.44, 1)

        return {
            "Net Profit": net,
            "Gross Profit": gross_profit,
            "Gross Loss": -gross_loss,
            "Profit Factor": pf,
            "Total Trades": len(self.trades),
            "Win Rate %": wr,
            "Wins": len(wins),
            "Losses": len(losses),
            "Avg Win": gross_profit / len(wins) if wins else 0,
            "Avg Loss": -gross_loss / len(losses) if losses else 0,
            "Max Drawdown %": self.max_dd_pct,
            "Sharpe Ratio": sharpe,
            "Recovery Factor": recovery,
            "Final Balance": self.balance,
            "Monthly Avg": monthly,
            "Days": days,
            "Start": str(first_bar.date()),
            "End": str(last_bar.date()),
        }


# ═══════════════════════════════════════════════════════════════════
#  MAIN
# ═══════════════════════════════════════════════════════════════════
def print_results(label, r):
    """Print results in MT5 report style."""
    print(f"\n  {'=' * 55}")
    print(f"  {label}")
    print(f"  {'=' * 55}")
    print(f"  Net Profit:      ${r['Net Profit']:>10.2f}   Monthly: ${r['Monthly Avg']:>8.2f}")
    print(f"  Gross Profit:    ${r['Gross Profit']:>10.2f}")
    print(f"  Gross Loss:      ${r['Gross Loss']:>10.2f}")
    print(f"  Profit Factor:   {r['Profit Factor']:>10.2f}")
    print(f"  Recovery Factor: {r['Recovery Factor']:>10.2f}")
    print(f"  Sharpe Ratio:    {r['Sharpe Ratio']:>10.2f}")
    print(f"  {'-' * 55}")
    print(f"  Total Trades:    {r['Total Trades']:>10}   ({r['Wins']}W / {r['Losses']}L)")
    print(f"  Win Rate:        {r['Win Rate %']:>9.1f}%")
    print(f"  Avg Win:         ${r['Avg Win']:>10.2f}")
    print(f"  Avg Loss:        ${r['Avg Loss']:>10.2f}")
    print(f"  Max Drawdown:    {r['Max Drawdown %']:>9.1f}%")
    print(f"  {'-' * 55}")
    print(f"  Final Balance:   ${r['Final Balance']:>10.2f}")
    print(f"  Period:          {r['Start']} to {r['End']} ({r['Days']} days)")
    print(f"  {'=' * 55}")


def main():
    parser = argparse.ArgumentParser(description="HMM Regime Backtester")
    parser.add_argument("--from", dest="date_from", default="2024-01-01")
    parser.add_argument("--to", dest="date_to", default="2026-03-01")
    parser.add_argument("--symbol", default="XAUUSD.a")
    parser.add_argument("--states", type=int, default=5, help="HMM states (default: 5)")
    parser.add_argument("--cooldown", type=int, default=48, help="Cooldown bars after regime change")
    parser.add_argument("--deposit", type=float, default=1000)
    parser.add_argument("--spread", type=int, default=16, help="Spread in points")
    parser.add_argument("--no-regime", action="store_true", help="Disable HMM (baseline)")
    parser.add_argument("--gauss", type=int, default=80, help="Gaussian period")
    parser.add_argument("--sl", type=float, default=2.5, help="SL multiplier")
    parser.add_argument("--tp", type=float, default=5.0, help="TP multiplier")
    parser.add_argument("--max-sl", type=float, default=30.0, help="Max SL dollars")
    args = parser.parse_args()

    print("=" * 60)
    print("  HMM REGIME BACKTESTER")
    print(f"  {args.symbol} H1 | ${args.deposit} | 1:20 | {args.spread}pt spread")
    print(f"  {args.date_from} to {args.date_to}")
    print(f"  HMM: {'OFF (baseline)' if args.no_regime else f'{args.states} states, {args.cooldown}-bar cooldown'}")
    print("=" * 60)

    # Fetch data
    df = fetch_mt5_data(args.symbol, "H1", 10000)
    if df is None:
        return

    # Filter date range
    df = df[(df.index >= args.date_from) & (df.index < args.date_to)]
    print(f"  Filtered to {len(df)} bars")

    # Compute features and train HMM
    df_feat = compute_features(df)

    if not args.no_regime:
        print(f"\n  Training HMM ({args.states} states)...")
        model, regimes, probs = train_hmm(df_feat, n_states=args.states)
        if model is None:
            print("  HMM training failed!")
            return

        # Pad regimes to match df length (features drop first row)
        full_regimes = np.full(len(df), 3)  # Default NEUTRAL
        offset = len(df) - len(regimes)
        full_regimes[offset:] = regimes

        # Show regime distribution
        unique, counts = np.unique(regimes, return_counts=True)
        regime_names = {1: "STRONG_BULL", 2: "MILD_BULL", 3: "NEUTRAL", 4: "MILD_BEAR", 5: "STRONG_BEAR"}
        print(f"\n  Regime distribution:")
        for u, c in zip(unique, counts):
            pct = c / len(regimes) * 100
            print(f"    {regime_names.get(u, '?'):>15}: {c:>5} bars ({pct:>5.1f}%)")
    else:
        full_regimes = np.ones(len(df), dtype=int)  # All STRONG_BULL = always trade

    # Run backtest with HMM
    params = {
        'deposit': args.deposit, 'lot': 0.01, 'leverage': 20,
        'spread_pts': args.spread, 'gauss_period': args.gauss, 'gauss_poles': 4,
        'sl_mult': args.sl, 'tp_mult': args.tp, 'max_sl': args.max_sl,
        'rsi_ob': 80, 'rsi_os': 28,
        'cooldown': args.cooldown, 'use_regime': not args.no_regime,
        'close_on_flip': True,
    }

    bt = HMMBacktester(df, full_regimes, params)
    bt.run()
    r = bt.results()

    if "error" in r:
        print(f"\n  {r['error']}")
        return

    print_results("HMM REGIME + GaussMACD" if not args.no_regime else "BASELINE (no HMM)", r)

    # Also run baseline for comparison
    if not args.no_regime:
        print("\n  Running baseline (no regime filter) for comparison...")
        params_base = params.copy()
        params_base['use_regime'] = False
        bt_base = HMMBacktester(df, full_regimes, params_base)
        bt_base.run()
        r_base = bt_base.results()

        if "error" not in r_base:
            print_results("BASELINE (no HMM filter)", r_base)

            # Comparison
            print(f"\n  {'-' * 55}")
            print(f"  COMPARISON: HMM vs Baseline")
            print(f"  {'-' * 55}")
            profit_diff = r['Net Profit'] - r_base['Net Profit']
            dd_diff = r['Max Drawdown %'] - r_base['Max Drawdown %']
            pf_diff = r['Profit Factor'] - r_base['Profit Factor']
            print(f"  Profit:    ${profit_diff:>+8.2f} ({'better' if profit_diff > 0 else 'worse'})")
            print(f"  PF:        {pf_diff:>+8.2f} ({'better' if pf_diff > 0 else 'worse'})")
            print(f"  DD%:       {dd_diff:>+7.1f}% ({'better' if dd_diff < 0 else 'worse'})")
            print(f"  Trades:    {r['Total Trades']} vs {r_base['Total Trades']} ({r['Total Trades'] - r_base['Total Trades']:+d})")
            print(f"  {'-' * 55}")

    # Monthly breakdown
    print(f"\n  MONTHLY P&L:")
    monthly_pnl = {}
    for t in bt.trades:
        month = df.index[t.bar_idx].strftime("%Y-%m")
        monthly_pnl[month] = monthly_pnl.get(month, 0) + t.profit

    for month in sorted(monthly_pnl.keys()):
        pnl = monthly_pnl[month]
        bar = "+" * int(max(0, pnl) / 3) + "-" * int(max(0, -pnl) / 3)
        color_mark = ">>>" if pnl > 50 else ("<<<" if pnl < -50 else "   ")
        print(f"    {month}: ${pnl:>+8.2f} {color_mark} {bar}")


if __name__ == "__main__":
    main()
