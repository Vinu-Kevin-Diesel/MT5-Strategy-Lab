# AlgoGold: AI-Powered Algorithmic Trading System for XAUUSD

An end-to-end algorithmic trading framework that uses **Gaussian signal processing**, **Hidden Markov Model regime detection**, and **multi-strategy portfolio optimization** to trade Gold (XAUUSD) on MetaTrader 5.

Built from scratch — 50+ strategy variants backtested, 6 core EAs developed, and a live-trading pipeline with Telegram signal integration.

## Architecture

```
                          ┌─────────────────────┐
                          │   Regime Detector    │
                          │  (HMM / ADX-based)   │
                          └─────────┬───────────┘
                                    │
                    ┌───────────────┼───────────────┐
                    │               │               │
              ┌─────▼─────┐  ┌─────▼─────┐  ┌─────▼─────┐
              │ MultiFilter│  │ GaussMACD │  │   Beast   │
              │  (Trend)   │  │(Momentum) │  │(Re-entry) │
              └─────┬─────┘  └─────┬─────┘  └─────┬─────┘
                    │               │               │
                    └───────────────┼───────────────┘
                                    │
                          ┌─────────▼───────────┐
                          │    Risk Management   │
                          │  MaxSL / Kill Switch │
                          │  Loss Streak Pause   │
                          └─────────┬───────────┘
                                    │
                          ┌─────────▼───────────┐
                          │   MetaTrader 5 API   │
                          │   Order Execution    │
                          └─────────────────────┘
```

## Key Technical Components

### 1. Gaussian IIR Filter (John Ehlers)
Multi-pole recursive Gaussian filter for trend detection with minimal lag — significantly outperforms traditional EMA/SMA:
```
beta  = (1 - cos(2*PI/period)) / (2^(1/poles) - 1)
alpha = -beta + sqrt(beta^2 + 2*beta)
output[i] = alpha * input[i] + (1-alpha) * output[i-1]  (applied N poles)
```

### 2. Hidden Markov Model Regime Detection
Gaussian HMM with 5 states trained on returns, range, and volume features to classify market into:
- **Strong Bull / Mild Bull** → Trend strategies active
- **Neutral** → No trading
- **Mild Bear / Strong Bear** → Short strategies active

### 3. Multi-Strategy Portfolio with Kill Switches
Three uncorrelated strategies run simultaneously with independent magic numbers:
- **MultiFilter**: 5-filter selective trend trading (Gaussian + MACD + EMA200 + ADX + Body)
- **GaussMACD**: Gaussian trend + MACD histogram momentum confirmation
- **Beast**: Pullback re-entry with automatic kill switch after consecutive losses

### 4. Automated MT5 Strategy Tester Runner
Python script that programmatically launches MT5's built-in Strategy Tester via command-line config, parses results from tester logs, and returns metrics — enabling automated parameter optimization loops.

### 5. Telegram Signal Auto-Trader
Connects to Telegram channels via Telethon, parses trade signals in real-time, and executes them on MT5 with smart order type selection (Market / Limit / Stop based on current price vs signal zone).

## Results (Backtest — MT5 Strategy Tester, Every Tick, 47ms Latency)

| EA | Period | Net Profit | Profit Factor | Max DD | Win Rate | Trades |
|---|---|---:|---:|---:|---:|---:|
| **Gold_Apex_EA** | 2022-2025 (4yr) | +$673 | — | Low | 34.1% | 622 |
| **Gold_SmartTrio_EA** | 2022-2025 (4yr) | +$3,385 | — | ~25% | 37.7% | 2,624 |
| **Gold_Portfolio_v4_EA** | 2024-2025 (2yr) | +$4,621 | — | ~28% | 36.2% | 2,594 |
| **Gold_MultiFilter_EA** | 2024-2026 (2yr) | +$1,928 | 1.53 | 12.8% | 43% | 302 |
| Gold_GaussMACD_EA (Pass 238) | 2024-2026 (2yr) | +$1,619 | 1.31 | 12.5% | 38.8% | 404 |

> $1,000 starting balance, 0.01 lot, 1:20 leverage, XAUUSD.a H1, Pepperstone UAE Standard (zero commission)

## Project Structure

```
├── run.py                    # MT5 Strategy Tester automation
├── hmm_regime.py             # Hidden Markov Model regime detector
├── hmm_backtest.py           # Python backtester with HMM integration
├── telegram_trader.py        # Telegram signal → MT5 auto-execution
├── mq5/                      # MQL5 Expert Advisors
│   ├── Gold_Apex_EA.mq5          # Best-of-everything single strategy
│   ├── Gold_Portfolio_v7_EA.mq5  # 3-strategy portfolio + kill switches
│   ├── Gold_SmartTrio_EA.mq5     # 3-strategy + dead market filter
│   ├── Gold_SmartDuo_EA.mq5      # 2-strategy (lowest drawdown)
│   ├── Gold_MultiFilter_EA.mq5   # Highest PF single strategy
│   ├── Gold_GaussMACD_EA.mq5     # Core Gaussian + MACD strategy
│   ├── Gold_Combo_EA.mq5         # GaussMACD + SessionMomentum
│   ├── Gold_Beast_EA.mq5         # Pullback re-entry strategy
│   └── Gold_HMM_Portfolio_EA.mq5 # Rule-based regime + portfolio
└── archive/                  # Deprecated Python backtest engine
    └── backtest_engine.py
```

## Technical Stack

- **Python 3.11**: MetaTrader5 API, hmmlearn (Gaussian HMM), telethon, pandas, numpy
- **MQL5**: Expert Advisors with Gaussian IIR filters, ATR-based risk management, multi-magic position tracking
- **MetaTrader 5**: Strategy Tester (Every Tick mode), command-line automation via tester.ini
- **Signal Processing**: John Ehlers' multi-pole recursive IIR Gaussian filter, Hilbert Transform concepts

## Key Engineering Decisions

1. **Real MT5 backtesting over Python simulation**: After finding 35% divergence between Python engine and MT5 results, switched to automating MT5's native Strategy Tester for 100% accurate backtests.

2. **Kill switch over removal**: Instead of permanently disabling the Beast strategy (which cost $1,635 in missed profits), implemented a conditional kill switch that activates after 2 consecutive losses and recovers after 48 bars.

3. **Dead market filter**: Simple ADX < 12 threshold prevents all strategies from trading during low-volatility ranging periods — reduced 4-year drawdown from 84% to ~25%.

4. **Pending signal pattern**: All EAs detect signals on bar close but execute on next bar open, preventing look-ahead bias in backtests.

## Setup

### Prerequisites
- MetaTrader 5 (Pepperstone or any broker)
- Python 3.11+
- `pip install MetaTrader5 hmmlearn telethon pandas numpy`

### Running a Backtest
```bash
python run.py --ea Gold_Apex_EA --from 2024.01.01 --to 2025.12.31 --timeout 300
```

### Running HMM Regime Detection
```bash
python hmm_regime.py --train          # Full analysis
python hmm_regime.py --loop 5         # Live updates every 5 min
```

### Running Telegram Auto-Trader
```bash
python telegram_trader.py --dry-run   # Test mode
python telegram_trader.py             # Live execution
```

## Optimization

All EAs support MT5's built-in optimizer (Slow Complete or Fast Genetic). Typical optimization:
- 729 parameter combinations via grid search
- 4-year backtest window (2022-2025) for robustness
- Sorted by Recovery Factor (profit / max drawdown) to balance returns and risk

## Disclaimer

This is an educational project demonstrating algorithmic trading concepts. Past backtest performance does not guarantee future results. Use at your own risk.

## License

MIT
