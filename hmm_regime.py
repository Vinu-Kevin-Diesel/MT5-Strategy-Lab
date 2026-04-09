"""
hmm_regime.py — Hidden Markov Model Regime Detector for XAUUSD
================================================================
Runs continuously, detects market regime using Gaussian HMM,
writes regime + confidence to a file that the MQ5 EA reads.

Architecture:
  1. Fetch latest XAUUSD H1 data from MT5
  2. Compute features: returns, range, volume change
  3. Train HMM with 5 states on rolling window
  4. Classify current regime
  5. Write regime to CSV file in MT5 data folder
  6. Repeat every N minutes

Regimes:
  1 = STRONG_BULL (highest return state)
  2 = MILD_BULL
  3 = NEUTRAL
  4 = MILD_BEAR
  5 = STRONG_BEAR (lowest return state)

Usage:
  python hmm_regime.py              # Run once
  python hmm_regime.py --loop 5     # Run every 5 minutes
  python hmm_regime.py --train      # Train and show regime history
"""
import argparse
import time
import sys
import warnings
import numpy as np
import pandas as pd
from datetime import datetime, timedelta
from pathlib import Path

warnings.filterwarnings("ignore")

try:
    import MetaTrader5 as mt5
except ImportError:
    print("pip install MetaTrader5")
    sys.exit(1)

try:
    from hmmlearn.hmm import GaussianHMM
except ImportError:
    print("pip install hmmlearn")
    sys.exit(1)


# === CONFIG ===
MT5_DATA = Path(r"<MT5_DATA_PATH>")
REGIME_FILE = MT5_DATA / "MQL5" / "Files" / "hmm_regime.csv"
N_STATES = 5
TRAIN_BARS = 2000      # How many H1 bars to train on
SYMBOL = "XAUUSD.a"
TIMEFRAME = mt5.TIMEFRAME_H1

REGIME_NAMES = {1: "STRONG_BULL", 2: "MILD_BULL", 3: "NEUTRAL", 4: "MILD_BEAR", 5: "STRONG_BEAR"}


def fetch_data(n_bars=TRAIN_BARS):
    """Fetch H1 OHLCV data from MT5."""
    if not mt5.initialize():
        print("  [ERROR] MT5 not running. Start MetaTrader 5 first.")
        return None

    rates = mt5.copy_rates_from_pos(SYMBOL, TIMEFRAME, 0, n_bars)
    mt5.shutdown()

    if rates is None or len(rates) == 0:
        print("  [ERROR] No data received from MT5")
        return None

    df = pd.DataFrame(rates)
    df['time'] = pd.to_datetime(df['time'], unit='s')
    df = df.set_index('time')
    return df


def compute_features(df):
    """Compute HMM features: returns, range, volume change."""
    # Log returns
    df['returns'] = np.log(df['close'] / df['close'].shift(1))

    # Normalized range (high-low / close)
    df['range'] = (df['high'] - df['low']) / df['close']

    # Volume change (log ratio)
    df['vol_change'] = np.log((df['tick_volume'] + 1) / (df['tick_volume'].shift(1) + 1))

    # Drop NaN rows
    df = df.dropna()
    return df


def train_hmm(df):
    """Train Gaussian HMM on features and return model + states."""
    features = df[['returns', 'range', 'vol_change']].values

    # Train HMM with multiple attempts (EM can get stuck)
    best_model = None
    best_score = -np.inf

    for attempt in range(10):
        try:
            model = GaussianHMM(
                n_components=N_STATES,
                covariance_type="full",
                n_iter=200,
                random_state=attempt * 42,
                tol=0.01,
            )
            model.fit(features)
            score = model.score(features)
            if score > best_score:
                best_score = score
                best_model = model
        except:
            continue

    if best_model is None:
        print("  [ERROR] HMM training failed")
        return None, None, None

    # Predict states
    states = best_model.predict(features)

    # Auto-label states by mean return
    state_returns = {}
    for s in range(N_STATES):
        mask = states == s
        if mask.sum() > 0:
            state_returns[s] = features[mask, 0].mean()  # mean return
        else:
            state_returns[s] = 0

    # Sort states by return: highest = bull, lowest = bear
    sorted_states = sorted(state_returns.items(), key=lambda x: x[1], reverse=True)

    # Map: original_state → regime (1=strong bull, 5=strong bear)
    state_to_regime = {}
    for i, (orig_state, _) in enumerate(sorted_states):
        state_to_regime[orig_state] = i + 1  # 1 to 5

    # Apply mapping
    regimes = np.array([state_to_regime[s] for s in states])

    # Get state probabilities for current bar
    probs = best_model.predict_proba(features)

    return best_model, regimes, probs


def get_current_regime(df, regimes, probs):
    """Get current regime and confidence."""
    current_regime = int(regimes[-1])
    current_prob = float(probs[-1].max()) * 100  # Highest probability

    # Also get regime distribution of last 10 bars for stability
    last_10 = regimes[-10:] if len(regimes) >= 10 else regimes
    regime_counts = {}
    for r in last_10:
        regime_counts[r] = regime_counts.get(r, 0) + 1
    dominant = max(regime_counts, key=regime_counts.get)
    stability = regime_counts[dominant] / len(last_10) * 100

    return current_regime, current_prob, stability, dominant


def write_regime(regime, confidence, stability, price, atr):
    """Write regime to CSV file that MQ5 EA reads."""
    # Ensure directory exists
    REGIME_FILE.parent.mkdir(parents=True, exist_ok=True)

    timestamp = datetime.now().strftime("%Y.%m.%d %H:%M:%S")
    regime_name = REGIME_NAMES.get(regime, "UNKNOWN")

    # Write as simple CSV: timestamp, regime_id, regime_name, confidence, stability, price, atr
    with open(REGIME_FILE, 'w') as f:
        f.write("timestamp,regime,name,confidence,stability,price,atr\n")
        f.write(f"{timestamp},{regime},{regime_name},{confidence:.1f},{stability:.1f},{price:.2f},{atr:.2f}\n")

    return regime_name


def run_once(verbose=True):
    """Run one detection cycle."""
    if verbose:
        print(f"\n  [{datetime.now().strftime('%H:%M:%S')}] Fetching {TRAIN_BARS} H1 bars...")

    df = fetch_data()
    if df is None:
        return None

    if verbose:
        print(f"  Data: {df.index[0]} to {df.index[-1]} ({len(df)} bars)")

    df = compute_features(df)

    if verbose:
        print(f"  Training HMM with {N_STATES} states on {len(df)} samples...")

    model, regimes, probs = train_hmm(df)
    if model is None:
        return None

    regime, confidence, stability, dominant = get_current_regime(df, regimes, probs)
    price = float(df['close'].iloc[-1])

    # Compute ATR manually
    tr = np.maximum(
        df['high'].values - df['low'].values,
        np.maximum(
            np.abs(df['high'].values - np.roll(df['close'].values, 1)),
            np.abs(df['low'].values - np.roll(df['close'].values, 1))
        )
    )
    atr = float(np.mean(tr[-14:]))

    regime_name = write_regime(regime, confidence, stability, price, atr)

    if verbose:
        print(f"\n  {'='*50}")
        print(f"  REGIME: {regime_name} (#{regime})")
        print(f"  Confidence: {confidence:.1f}%")
        print(f"  Stability (10-bar): {stability:.0f}%")
        print(f"  Price: ${price:.2f}")
        print(f"  ATR: ${atr:.2f}")
        print(f"  Written to: {REGIME_FILE}")
        print(f"  {'='*50}")

        # Show regime distribution
        unique, counts = np.unique(regimes, return_counts=True)
        print(f"\n  Regime distribution (last {len(regimes)} bars):")
        for u, c in zip(unique, counts):
            pct = c / len(regimes) * 100
            name = REGIME_NAMES.get(u, "?")
            bar = "#" * int(pct / 2)
            print(f"    {name:>15}: {c:>4} ({pct:>5.1f}%) {bar}")

    return regime


def run_training_analysis():
    """Full training analysis with visualization."""
    print("=" * 60)
    print("  HMM REGIME TRAINING ANALYSIS")
    print("=" * 60)

    df = fetch_data(n_bars=5000)
    if df is None:
        return

    df = compute_features(df)
    print(f"  Training on {len(df)} bars...")

    model, regimes, probs = train_hmm(df)
    if model is None:
        return

    df = df.iloc[:len(regimes)].copy()
    df['regime'] = regimes

    # Monthly P&L simulation
    print(f"\n  REGIME SUMMARY:")
    print(f"  {'Regime':<15} {'Bars':>6} {'%':>6} {'Avg Return':>12} {'Volatility':>12}")
    print(f"  {'-'*55}")
    for r in sorted(df['regime'].unique()):
        mask = df['regime'] == r
        bars = mask.sum()
        pct = bars / len(df) * 100
        avg_ret = df.loc[mask, 'returns'].mean() * 100
        vol = df.loc[mask, 'returns'].std() * 100
        name = REGIME_NAMES.get(r, f"State {r}")
        print(f"  {name:<15} {bars:>6} {pct:>5.1f}% {avg_ret:>+11.4f}% {vol:>11.4f}%")

    # Transition matrix
    print(f"\n  TRANSITION PROBABILITIES:")
    trans = model.transmat_
    print(f"  {'From/To':<15}", end="")
    for j in range(N_STATES):
        print(f"  {REGIME_NAMES.get(j+1,'?')[:8]:>8}", end="")
    print()
    for i in range(N_STATES):
        print(f"  {REGIME_NAMES.get(i+1,'?'):<15}", end="")
        for j in range(N_STATES):
            print(f"  {trans[i,j]:>7.1%}", end="")
        print()

    # Current
    regime, conf, stab, dom = get_current_regime(df, regimes, probs)
    print(f"\n  CURRENT: {REGIME_NAMES.get(regime)} | Confidence: {conf:.0f}% | Stability: {stab:.0f}%")


def main():
    parser = argparse.ArgumentParser(description="HMM Regime Detector for XAUUSD")
    parser.add_argument("--loop", type=int, default=0, help="Loop interval in minutes (0=run once)")
    parser.add_argument("--train", action="store_true", help="Full training analysis")
    parser.add_argument("--bars", type=int, default=TRAIN_BARS, help=f"Training bars (default: {TRAIN_BARS})")
    args = parser.parse_args()

    if args.bars != TRAIN_BARS:
        # Override via module-level reassignment
        pass

    if args.train:
        run_training_analysis()
        return

    if args.loop > 0:
        print(f"  HMM Regime Detector — looping every {args.loop} minutes")
        print(f"  Press Ctrl+C to stop\n")
        while True:
            try:
                run_once()
                print(f"\n  Sleeping {args.loop} minutes...")
                time.sleep(args.loop * 60)
            except KeyboardInterrupt:
                print("\n  Stopped.")
                break
    else:
        run_once()


if __name__ == "__main__":
    main()
