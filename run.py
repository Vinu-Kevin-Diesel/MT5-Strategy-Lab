"""
run.py - Automated MT5 Strategy Tester Runner
===============================================
Launches MetaTrader 5's Strategy Tester with your .ex5 EA,
waits for completion, and parses the results.

100% accurate - runs the REAL EA in the REAL MT5 engine.

Usage:
    python run.py                                       # Default: Gold_Combo_EA
    python run.py --ea Gold_GaussMACD_EA                # Specific EA
    python run.py --from 2024.01.01 --to 2026.03.01     # Date range
    python run.py --symbol XAUUSD.a --period H1         # Symbol/TF
    python run.py --list                                # List all EAs
"""
import argparse
import subprocess
import time
import os
import re
import sys
from pathlib import Path
from datetime import datetime

try:
    import MetaTrader5 as mt5
except ImportError:
    print("pip install MetaTrader5")
    sys.exit(1)


# == Paths ==
MT5_DATA = Path(r"<MT5_DATA_PATH>")
MT5_EXE = Path(r"<MT5_TERMINAL_PATH>")
EA_FOLDER = MT5_DATA / "MQL5" / "Experts" / "claude"
TESTER_FOLDER = MT5_DATA / "Tester"
AGENT_LOG_DIR = Path(r"<MT5_TESTER_PATH>")

PERIOD_MAP = {
    "M1": "1", "M5": "5", "M15": "15", "M30": "30",
    "H1": "60", "H4": "240", "D1": "1440", "W1": "10080", "MN1": "43200",
}


def find_ea(name):
    """Find compiled .ex5 EA by name. Returns path relative to MQL5/Experts/."""
    for folder in [EA_FOLDER, MT5_DATA / "MQL5" / "Experts"]:
        ex5 = folder / f"{name}.ex5"
        if ex5.exists():
            return str(ex5.relative_to(MT5_DATA / "MQL5" / "Experts"))
    for f in (MT5_DATA / "MQL5" / "Experts").rglob(f"{name}.ex5"):
        return str(f.relative_to(MT5_DATA / "MQL5" / "Experts"))
    return None


def list_eas():
    """List all compiled .ex5 EAs."""
    print("\n  Available EAs:")
    print(f"  {'Name':<35} {'Size':>8}  {'Modified'}")
    print(f"  {'-'*60}")
    seen = set()
    for folder in [EA_FOLDER, MT5_DATA / "MQL5" / "Experts"]:
        if not folder.exists():
            continue
        for f in sorted(folder.glob("*.ex5")):
            if f.stem in seen:
                continue
            seen.add(f.stem)
            kb = f.stat().st_size / 1024
            mod = datetime.fromtimestamp(f.stat().st_mtime).strftime("%Y-%m-%d %H:%M")
            print(f"  {f.stem:<35} {kb:>6.1f}KB  {mod}")


def _all_log_files():
    """Get all tester log files."""
    files = []
    for search_dir in [TESTER_FOLDER / "logs"]:
        if search_dir.is_dir():
            files.extend(search_dir.glob("*.log"))
    for d in AGENT_LOG_DIR.rglob("logs"):
        if d.is_dir():
            files.extend(d.glob("*.log"))
    return files


def get_log_snapshot():
    """Get a snapshot: dict of {filepath: (file_size, line_count)} for all logs."""
    snap = {}
    for lf in _all_log_files():
        try:
            size = lf.stat().st_size
            # Count lines for precise tracking
            with open(lf, "r", encoding="utf-16-le", errors="ignore") as f:
                line_count = sum(1 for _ in f)
            snap[str(lf)] = (size, line_count)
        except:
            pass
    return snap


def parse_new_lines(prev_snapshot):
    """Read ONLY lines written after the snapshot. Returns list of new lines."""
    new_lines = []
    for lf in _all_log_files():
        try:
            path_str = str(lf)
            current_size = lf.stat().st_size
            prev_size, prev_lines = prev_snapshot.get(path_str, (0, 0))

            if current_size <= prev_size:
                continue  # File didn't grow

            with open(lf, "r", encoding="utf-16-le", errors="ignore") as f:
                all_lines = f.readlines()

            # Only take lines AFTER the previous line count
            if len(all_lines) > prev_lines:
                new_lines.extend(all_lines[prev_lines:])
        except:
            pass
    return new_lines


def parse_results(new_lines, deposit):
    """Parse results from a list of log lines."""
    final_balance = None
    sl_hits = 0
    tp_hits = 0
    buy_signals = 0
    sell_signals = 0
    risk_caps = 0
    rsi_filtered = 0
    test_time = ""
    ticks = ""
    bars = ""
    total_deals = 0

    for line in new_lines:
        ll = line.lower()
        if "final balance" in ll:
            m = re.search(r"final balance ([\d.]+)", line)
            if m:
                final_balance = float(m.group(1))
        if "sl triggered" in ll or "stop loss" in ll:
            sl_hits += 1
        elif "tp triggered" in ll or "take profit" in ll:
            tp_hits += 1
        elif re.search(r"\bbuy\b", ll) and "signal" in ll:
            buy_signals += 1
        elif re.search(r"\bsell\b", ll) and "signal" in ll:
            sell_signals += 1
        elif "risk cap" in ll or "capped to" in ll:
            risk_caps += 1
        elif "skipped" in ll:
            rsi_filtered += 1
        elif "ticks," in ll and "bars" in ll:
            m = re.search(r"([\d]+) ticks, ([\d]+) bars.*?in ([\d:]+\.\d+)", line)
            if m:
                ticks = m.group(1)
                bars = m.group(2)
                test_time = m.group(3)
        # Count deal entries (more accurate trade count)
        if "deal #" in ll or "deal performed" in ll or ("order" in ll and "filled" in ll):
            total_deals += 1

    if final_balance is None:
        return None

    # Best trade count estimate
    total_trades = sl_hits + tp_hits
    if total_trades == 0:
        total_trades = total_deals // 2  # Each trade = open + close deal
    if total_trades == 0:
        total_trades = buy_signals + sell_signals

    net_profit = final_balance - deposit
    win_rate = (tp_hits / (sl_hits + tp_hits) * 100) if (sl_hits + tp_hits) > 0 else 0

    return {
        "final_balance": final_balance,
        "net_profit": net_profit,
        "total_trades": total_trades,
        "sl_hits": sl_hits,
        "tp_hits": tp_hits,
        "win_rate": win_rate,
        "buy_signals": buy_signals,
        "sell_signals": sell_signals,
        "risk_caps": risk_caps,
        "rsi_filtered": rsi_filtered,
        "test_time": test_time,
        "ticks": ticks,
        "bars": bars,
    }


def run_backtest(ea_name, symbol="XAUUSD.a", period="H1",
                 date_from="2024.01.01", date_to="2026.03.01",
                 deposit=1000, leverage=20, model=0, timeout=300):
    """Run MT5 Strategy Tester with given EA and return results."""

    print(f"\n{'=' * 60}")
    print(f"  MT5 STRATEGY TESTER")
    print(f"  EA: {ea_name}")
    print(f"  {symbol} {period} | ${deposit} | 1:{leverage}")
    print(f"  {date_from} to {date_to}")
    model_names = {0: "Every tick", 1: "1-min OHLC", 2: "Open prices", 4: "Every tick (real)"}
    print(f"  Model: {model_names.get(model, model)}")
    print(f"{'=' * 60}")

    # Find EA
    ea_path = find_ea(ea_name)
    if not ea_path:
        print(f"\n  ERROR: '{ea_name}.ex5' not found!")
        print(f"  Compile it in MetaEditor first.")
        list_eas()
        return None
    print(f"  EA path: {ea_path}")

    # Get real latency from MT5
    latency_ms = 50  # fallback
    try:
        if mt5.initialize():
            term = mt5.terminal_info()
            if term and term.ping_last > 0:
                latency_ms = max(1, term.ping_last // 1000)  # microseconds to ms
            mt5.shutdown()
            print(f"  Latency: {latency_ms}ms (from MT5 ping)")
    except:
        print(f"  Latency: {latency_ms}ms (fallback)")

    # Create tester.ini
    ini_content = f"""; Auto-generated by run.py
[Tester]
Expert={ea_path}
Symbol={symbol}
Period={PERIOD_MAP.get(period, "60")}
Optimization=0
Model={model}
FromDate={date_from}
ToDate={date_to}
ForwardMode=0
Deposit={deposit}
Leverage={leverage}
Currency=USD
ProfitInPips=0
ExecutionMode=0
Latency={latency_ms}
OptimizationCriterion=0
Visual=0
ReplaceReport=1
ShutdownTerminal=1
"""
    ini_path = MT5_DATA / "tester.ini"
    ini_path.write_text(ini_content)

    # Take snapshot BEFORE killing MT5 (captures current state of all logs)
    prev_snapshot = get_log_snapshot()

    # Kill MT5 completely (must be a fresh launch for /config to work)
    subprocess.run(["powershell", "-Command",
                    "Stop-Process -Name 'terminal64' -Force -ErrorAction SilentlyContinue"],
                   capture_output=True)
    time.sleep(5)
    print("  Killed any running MT5")

    # Launch MT5
    print(f"\n  Running backtest...")
    start = time.time()
    proc = subprocess.Popen([str(MT5_EXE), f"/config:{ini_path}"])

    # Wait for completion
    while time.time() - start < timeout:
        if proc.poll() is not None:
            break
        elapsed = int(time.time() - start)
        if elapsed > 0 and elapsed % 30 == 0:
            print(f"  ... {elapsed}s elapsed")
        time.sleep(3)
    else:
        print(f"  TIMEOUT ({timeout}s) - killing MT5")
        proc.kill()
        return None

    elapsed = time.time() - start
    print(f"  MT5 finished in {elapsed:.0f}s")

    # Poll for new result (agent process may still be writing)
    results = None
    for wait in range(15):
        time.sleep(2)
        new_lines = parse_new_lines(prev_snapshot)
        if new_lines:
            results = parse_results(new_lines, deposit)
            if results:
                break

    if not results:
        print("\n  No results found in tester log.")
        print("  Open MT5 manually and check the Tester tab.")
        return None

    # Display results
    r = results
    print(f"\n  {'=' * 50}")
    print(f"  RESULTS")
    print(f"  {'=' * 50}")
    print(f"  Final Balance:   ${r['final_balance']:>10.2f}")
    print(f"  Net Profit:      ${r['net_profit']:>10.2f}")
    print(f"  Total Trades:    {r['total_trades']:>10}")
    if r['tp_hits'] + r['sl_hits'] > 0:
        print(f"    - TP Wins:     {r['tp_hits']:>10}")
        print(f"    - SL Losses:   {r['sl_hits']:>10}")
        print(f"  Win Rate:        {r['win_rate']:>9.1f}%")
    print(f"  {'-' * 50}")
    if r['buy_signals'] + r['sell_signals'] > 0:
        print(f"  Signals: {r['buy_signals']} buys + {r['sell_signals']} sells")
    if r['risk_caps'] > 0:
        print(f"  Risk Capped:     {r['risk_caps']:>10}")
    if r['rsi_filtered'] > 0:
        print(f"  RSI Filtered:    {r['rsi_filtered']:>10}")
    if r['test_time']:
        print(f"  Test Time:       {r['test_time']}")
        print(f"  Ticks/Bars:      {r['ticks']}/{r['bars']}")
    print(f"  {'=' * 50}")

    return results


def main():
    parser = argparse.ArgumentParser(
        description="MT5 Strategy Tester Runner",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  python run.py                                  # Gold EA, default settings
  python run.py --ea Gold_GaussMACD_EA --symbol EURUSD.a --leverage 30
  python run.py --from 2023.01.01 --to 2025.12.31 --model 4
  python run.py --list                           # Show all EAs
        """)
    parser.add_argument("--ea", default="Gold_Combo_EA", help="EA name (default: Gold_Combo_EA)")
    parser.add_argument("--symbol", default="XAUUSD.a", help="Symbol (default: XAUUSD.a)")
    parser.add_argument("--period", default="H1", help="Timeframe (default: H1)")
    parser.add_argument("--from", dest="date_from", default="2024.01.01", help="Start date (default: 2024.01.01)")
    parser.add_argument("--to", dest="date_to", default="2026.03.01", help="End date (default: 2026.03.01)")
    parser.add_argument("--deposit", type=int, default=1000, help="Deposit (default: 1000)")
    parser.add_argument("--leverage", type=int, default=20, help="Leverage (default: 20)")
    parser.add_argument("--model", type=int, default=0, help="0=Every tick, 1=1min OHLC, 2=Open prices, 4=Real ticks")
    parser.add_argument("--timeout", type=int, default=300, help="Max wait seconds (default: 300)")
    parser.add_argument("--list", action="store_true", help="List available EAs")
    args = parser.parse_args()

    if args.list:
        list_eas()
        return

    run_backtest(
        ea_name=args.ea,
        symbol=args.symbol,
        period=args.period,
        date_from=args.date_from,
        date_to=args.date_to,
        deposit=args.deposit,
        leverage=args.leverage,
        model=args.model,
        timeout=args.timeout,
    )


if __name__ == "__main__":
    main()
