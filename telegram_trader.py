"""
telegram_trader.py — Auto-trade XAUUSD from Telegram signals
==============================================================
Connects to the GOLD PRO TRADER Telegram channel, parses trade signals,
and executes them on MT5 automatically.

Signal format (GOLD PRO TRADER channel):
    BUY GOLD@ 4800
    TP1: 4803
    TP2: 4806
    SL : PREMIUM

    SELL GOLD@ 4654
    TP1: 4650
    TP2: 4646
    SL : PREMIUM

Note: SL is hidden (premium only), so we auto-calculate using ATR.

Setup:
    1. Get API credentials from https://my.telegram.org
    2. Set them in telegram_config.json
    3. Run: python telegram_trader.py
    4. First run: enter phone number + code to authenticate
    5. MT5 must be running with Expert Advisors enabled

Usage:
    python telegram_trader.py                    # Run live listener
    python telegram_trader.py --dry-run          # Parse signals but don't trade
    python telegram_trader.py --test             # Test with sample signal
"""
import re
import os
import sys
import json
import asyncio
import logging
from datetime import datetime
from pathlib import Path
from dataclasses import dataclass

# ═══════════════════════════════════════════════════════════════════
#  CONFIG — UPDATE THESE
# ═══════════════════════════════════════════════════════════════════
TELEGRAM_API_ID = 0          # Get from https://my.telegram.org
TELEGRAM_API_HASH = ""       # Get from https://my.telegram.org
CHANNEL_NAME = "" or channel username

# Trading config
SYMBOL = "XAUUSD.a"
LOT_SIZE = 0.01
MAX_SL_DOLLARS = 30.0        # Max loss per trade in $ (0 = disabled)
MAGIC_NUMBER = 889999
TP_INDEX = 1                  # Which TP to use: 0=TP1, 1=TP2

# Price slippage tolerance: max distance from signal price to current price
# If price moved more than this many $ from signal entry, skip the trade
MAX_SLIPPAGE = 5.0            # $5 tolerance (gold moves fast)

# ATR-based SL settings (used when channel hides SL)
ATR_PERIOD = 14
ATR_SL_MULTIPLIER = 2.0      # SL = ATR * multiplier

# Session file for Telegram auth
SESSION_FILE = "telegram_session"

# Config file path (overrides above if exists)
CONFIG_FILE = Path(__file__).parent / "telegram_config.json"

# Log file
LOG_FILE = Path(__file__).parent / "telegram_trades.log"


# ═══════════════════════════════════════════════════════════════════
#  SIGNAL PARSER
# ═══════════════════════════════════════════════════════════════════
@dataclass
class Signal:
    direction: str       # "BUY" or "SELL"
    entry: float         # Entry price
    tp: list             # List of TP prices [TP1, TP2]
    sl: float            # Stop loss price (0 = auto-calculate)
    raw_text: str        # Original message
    timestamp: datetime

    def __str__(self):
        sl_str = f"{self.sl:.2f}" if self.sl > 0 else "AUTO"
        return (f"{self.direction} GOLD @ {self.entry} | "
                f"TP: {self.tp} | SL: {sl_str}")


def parse_signal(text):
    """
    Parse a Telegram message into a Signal object.
    Returns None if the message is not a valid signal.

    Matches formats:
      BUY GOLD@ 4800        (GOLD PRO TRADER format)
      SELL GOLD@ 4654       (GOLD PRO TRADER format)
      #XAUUSD BUY 4800/4805 (legacy format)
    """
    # Clean unicode characters
    clean = text.replace('\u200b', '').replace('\u200e', '').strip()

    # ── Format 1: GOLD PRO TRADER ──
    # "BUY GOLD@ 4800" or "SELL GOLD@ 4654"
    gpt_match = re.search(
        r'(BUY|SELL)\s+GOLD\s*@\s*(\d{3,5}(?:\.\d{1,2})?)',
        clean, re.IGNORECASE
    )
    if gpt_match:
        direction = gpt_match.group(1).upper()
        entry = float(gpt_match.group(2))

        # Extract TP levels: "TP1: 4803" or "TP2: 4806"
        tp_matches = re.findall(r'TP\d?\s*:\s*(\d{3,5}(?:\.\d{1,2})?)', clean, re.IGNORECASE)
        if len(tp_matches) < 1:
            return None
        tp_list = [float(t) for t in tp_matches]

        # Check this isn't a "TP hit" confirmation message
        # e.g. "SELL GOLD@ 4654 TP1: 4650 1ST Target done"
        if re.search(r'target\s*done|all.?target|hit', clean, re.IGNORECASE):
            return None

        # Extract SL if provided (usually says "PREMIUM")
        sl = 0.0
        sl_match = re.search(r'SL\s*:\s*(\d{3,5}(?:\.\d{1,2})?)', clean, re.IGNORECASE)
        if sl_match:
            sl = float(sl_match.group(1))
        # If SL says "PREMIUM" or is missing, sl stays 0 → auto-calculate

        return Signal(
            direction=direction,
            entry=entry,
            tp=tp_list,
            sl=sl,
            raw_text=text,
            timestamp=datetime.now()
        )

    # ── Format 2: Legacy #XAUUSD format ──
    # "#XAUUSD BUY 4800/4805"
    legacy_match = re.search(
        r'#?XAUUSD\s+(BUY|SELL)\s+(\d{3,5}(?:\.\d{1,2})?)\s*/\s*(\d{3,5}(?:\.\d{1,2})?)',
        clean, re.IGNORECASE
    )
    if legacy_match:
        direction = legacy_match.group(1).upper()
        price1 = float(legacy_match.group(2))
        price2 = float(legacy_match.group(3))
        entry = (price1 + price2) / 2  # Use midpoint

        tp_matches = re.findall(r'TP\s+(\d{3,5}(?:\.\d{1,2})?)', clean, re.IGNORECASE)
        if len(tp_matches) < 1:
            return None
        tp_list = [float(t) for t in tp_matches]

        sl = 0.0
        sl_match = re.search(r'SL\s+(\d{3,5}(?:\.\d{1,2})?)', clean, re.IGNORECASE)
        if sl_match:
            sl = float(sl_match.group(1))

        return Signal(
            direction=direction,
            entry=entry,
            tp=tp_list,
            sl=sl,
            raw_text=text,
            timestamp=datetime.now()
        )

    return None


# ═══════════════════════════════════════════════════════════════════
#  ATR CALCULATION (for auto SL)
# ═══════════════════════════════════════════════════════════════════
def get_atr(mt5_module, symbol=SYMBOL, period=ATR_PERIOD, timeframe=None):
    """Calculate ATR from MT5 candle data."""
    if timeframe is None:
        timeframe = mt5_module.TIMEFRAME_H1

    rates = mt5_module.copy_rates_from_pos(symbol, timeframe, 0, period + 1)
    if rates is None or len(rates) < period + 1:
        log(f"  [WARN] Could not get rates for ATR, using fallback SL")
        return None

    tr_list = []
    for i in range(1, len(rates)):
        high = rates[i]['high']
        low = rates[i]['low']
        prev_close = rates[i-1]['close']
        tr = max(high - low, abs(high - prev_close), abs(low - prev_close))
        tr_list.append(tr)

    atr = sum(tr_list[-period:]) / period
    return atr


# ═══════════════════════════════════════════════════════════════════
#  MT5 TRADE EXECUTION
# ═══════════════════════════════════════════════════════════════════
def execute_signal(signal, dry_run=False):
    """Execute a parsed signal on MT5."""
    import MetaTrader5 as mt5

    log(f"{'[DRY RUN] ' if dry_run else ''}Signal: {signal}")

    if not mt5.initialize():
        log(f"  [ERROR] MT5 not running!")
        return False

    # Get current price
    tick = mt5.symbol_info_tick(SYMBOL)
    if tick is None:
        log(f"  [ERROR] Cannot get tick for {SYMBOL}")
        mt5.shutdown()
        return False

    ask = tick.ask
    bid = tick.bid
    log(f"  Current: Ask={ask} Bid={bid}")
    log(f"  Signal entry: {signal.entry}")

    # ── Price slippage check ──
    if signal.direction == "BUY":
        current = ask
        slippage = current - signal.entry  # Positive = price moved up (bad for buy)
    else:
        current = bid
        slippage = signal.entry - current  # Positive = price moved down (bad for sell)

    log(f"  Slippage: ${slippage:.2f} (max allowed: ${MAX_SLIPPAGE})")

    if slippage > MAX_SLIPPAGE:
        log(f"  [SKIP] Price moved ${slippage:.2f} against us (> ${MAX_SLIPPAGE} max)")
        log(f"  Signal entry {signal.entry} vs current {'ask' if signal.direction == 'BUY' else 'bid'} {current}")
        mt5.shutdown()
        return False

    if slippage < -MAX_SLIPPAGE * 2:
        # Price moved way in our favor — might be stale signal, skip
        log(f"  [SKIP] Price moved ${abs(slippage):.2f} in our favor — signal may be stale")
        mt5.shutdown()
        return False

    # ── Auto-calculate SL if not provided ──
    sl = signal.sl
    if sl == 0:
        atr = get_atr(mt5)
        if atr:
            sl_distance = atr * ATR_SL_MULTIPLIER
            log(f"  ATR({ATR_PERIOD})={atr:.2f}, SL distance={sl_distance:.2f}")
        else:
            # Fallback: use distance to TP1 as SL (mirror TP1 on the other side)
            tp1 = signal.tp[0]
            sl_distance = abs(tp1 - signal.entry)
            log(f"  [FALLBACK] Using TP1 mirror for SL, distance={sl_distance:.2f}")

        if signal.direction == "BUY":
            sl = current - sl_distance
        else:
            sl = current + sl_distance
        log(f"  Auto SL: {sl:.2f}")

    # ── Choose TP ──
    tp_idx = min(TP_INDEX, len(signal.tp) - 1)
    tp_price = signal.tp[tp_idx]

    # ── Max SL cap ──
    if signal.direction == "BUY":
        sl_distance = current - sl
    else:
        sl_distance = sl - current

    if sl_distance <= 0:
        log(f"  [ERROR] Invalid SL: distance={sl_distance:.2f}")
        mt5.shutdown()
        return False

    if MAX_SL_DOLLARS > 0 and sl_distance > MAX_SL_DOLLARS:
        log(f"  [RISK CAP] SL distance ${sl_distance:.2f} > max ${MAX_SL_DOLLARS}")
        if signal.direction == "BUY":
            sl = current - MAX_SL_DOLLARS
        else:
            sl = current + MAX_SL_DOLLARS
        sl_distance = MAX_SL_DOLLARS
        log(f"  Adjusted SL to {sl:.2f}")

    # ── Check existing positions ──
    pos = mt5.positions_get(symbol=SYMBOL)
    if pos:
        bot_pos = [p for p in pos if p.magic == MAGIC_NUMBER]
        if bot_pos:
            log(f"  [INFO] {len(bot_pos)} existing position(s) from this bot")

    # ── Margin check ──
    account = mt5.account_info()
    margin_needed = current * LOT_SIZE * 100 / account.leverage
    if margin_needed > account.margin_free * 0.90:
        log(f"  [ERROR] Not enough margin: need ${margin_needed:.2f}, free ${account.margin_free:.2f}")
        mt5.shutdown()
        return False

    if dry_run:
        log(f"  [DRY RUN] Would execute: {signal.direction} {LOT_SIZE} lot @ {current:.2f}")
        log(f"  [DRY RUN] SL={sl:.2f} TP={tp_price:.2f}")
        mt5.shutdown()
        return True

    # ── Place market order (always market since signal = current price) ──
    if signal.direction == "BUY":
        order_type = mt5.ORDER_TYPE_BUY
        price = ask
    else:
        order_type = mt5.ORDER_TYPE_SELL
        price = bid

    request = {
        "action": mt5.TRADE_ACTION_DEAL,
        "symbol": SYMBOL,
        "volume": LOT_SIZE,
        "type": order_type,
        "price": round(price, 2),
        "sl": round(sl, 2),
        "tp": round(tp_price, 2),
        "deviation": 30,
        "magic": MAGIC_NUMBER,
        "comment": f"TG_{signal.direction}",
        "type_filling": mt5.ORDER_FILLING_IOC,
    }

    log(f"  Sending: {signal.direction} {LOT_SIZE} @ {price:.2f} SL={sl:.2f} TP={tp_price:.2f}")

    result = mt5.order_send(request)
    mt5.shutdown()

    if result is None:
        log(f"  [ERROR] order_send returned None")
        return False

    if result.retcode == mt5.TRADE_RETCODE_DONE:
        log(f"  [SUCCESS] Order filled! Ticket={result.order} Price={result.price}")
        return True
    else:
        log(f"  [FAILED] RetCode={result.retcode} Comment={result.comment}")
        return False


# ═══════════════════════════════════════════════════════════════════
#  LOGGING
# ═══════════════════════════════════════════════════════════════════
def log(msg):
    """Log to console and file."""
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{timestamp}] {msg}"
    print(line)
    try:
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except:
        pass


# ═══════════════════════════════════════════════════════════════════
#  CONFIG MANAGEMENT
# ═══════════════════════════════════════════════════════════════════
def load_config():
    """Load config from JSON file."""
    global TELEGRAM_API_ID, TELEGRAM_API_HASH, CHANNEL_NAME
    global LOT_SIZE, MAX_SL_DOLLARS, TP_INDEX, MAX_SLIPPAGE
    global ATR_SL_MULTIPLIER

    if CONFIG_FILE.exists():
        with open(CONFIG_FILE) as f:
            cfg = json.load(f)
        TELEGRAM_API_ID = 0cfg.get("api_id", TELEGRAM_API_ID)
        TELEGRAM_API_HASH = cfg.get("api_hash", TELEGRAM_API_HASH)
        CHANNEL_NAME = cfg.get("channel", CHANNEL_NAME)
        LOT_SIZE = cfg.get("lot_size", LOT_SIZE)
        MAX_SL_DOLLARS = cfg.get("max_sl", MAX_SL_DOLLARS)
        TP_INDEX = cfg.get("tp_index", TP_INDEX)
        MAX_SLIPPAGE = cfg.get("max_slippage", MAX_SLIPPAGE)
        ATR_SL_MULTIPLIER = cfg.get("atr_sl_mult", ATR_SL_MULTIPLIER)
        log(f"Config loaded from {CONFIG_FILE}")
    else:
        log(f"No config file found. Creating template at {CONFIG_FILE}")
        save_config_template()


def save_config_template():
    """Save a template config file."""
    cfg = {
        "api_id": 0,
        "api_hash": "YOUR_API_HASH_HERE",
        "channel": "GOLD PRO TRADER",
        "lot_size": 0.01,
        "max_sl": 30.0,
        "tp_index": 1,
        "max_slippage": 5.0,
        "atr_sl_mult": 2.0,
        "_instructions": [
            "1. Go to https://my.telegram.org and log in",
            "2. Click 'API development tools'",
            "3. Create an app and copy api_id and api_hash",
            "4. Set 'channel' to the Telegram channel name",
            "5. Run: python telegram_trader.py",
        ]
    }
    with open(CONFIG_FILE, "w") as f:
        json.dump(cfg, f, indent=2)


# ═══════════════════════════════════════════════════════════════════
#  TELEGRAM LISTENER
# ═══════════════════════════════════════════════════════════════════
async def run_listener(dry_run=False):
    """Connect to Telegram and listen for signals."""
    from telethon import TelegramClient, events

    if TELEGRAM_API_ID == 0 or not TELEGRAM_API_HASH:
        log("[ERROR] Telegram API credentials not set!")
        log(f"  Edit {CONFIG_FILE} with your API ID and hash")
        log("  Get them from https://my.telegram.org")
        return

    # Check MT5 connection first
    import MetaTrader5 as mt5
    if not dry_run:
        if mt5.initialize():
            acc = mt5.account_info()
            term = mt5.terminal_info()
            log(f"MT5 CONNECTED:")
            log(f"  Account: {acc.login} ({acc.server})")
            log(f"  Balance: ${acc.balance:.2f}")
            log(f"  Leverage: 1:{acc.leverage}")
            log(f"  Trade allowed: {term.trade_allowed}")
            if not term.trade_allowed:
                log(f"  [WARNING] AutoTrading is DISABLED in MT5!")
                log(f"  Enable it: click the green Play button in MT5 toolbar")
            mt5.shutdown()
        else:
            log(f"[WARNING] MT5 NOT RUNNING! Trades will fail until MT5 is started.")
            log(f"  Start Pepperstone MetaTrader 5 and enable AutoTrading.")

    log(f"\nConnecting to Telegram...")
    log(f"  Channel: {CHANNEL_NAME}")
    log(f"  Lot size: {LOT_SIZE}")
    log(f"  Max SL: ${MAX_SL_DOLLARS} (0=disabled)")
    log(f"  Max slippage: ${MAX_SLIPPAGE}")
    log(f"  ATR SL multiplier: {ATR_SL_MULTIPLIER}x")
    log(f"  Using TP{TP_INDEX + 1}")
    log(f"  Dry run: {dry_run}")

    client = TelegramClient(SESSION_FILE, TELEGRAM_API_ID, TELEGRAM_API_HASH)
    await client.start()

    me = await client.get_me()
    log(f"  Logged in as: {me.first_name} ({me.phone})")

    # Find the channel — use ID if available, fallback to name match
    channel = None
    channel_id = 0
    if CONFIG_FILE.exists():
        with open(CONFIG_FILE) as f:
            cfg = json.load(f)
        channel_id = cfg.get("channel_id", 0)

    if channel_id != 0:
        try:
            channel = await client.get_entity(channel_id)
            log(f"  Found channel by ID: {channel_id}")
        except Exception as e:
            log(f"  [WARN] Could not find channel by ID {channel_id}: {e}")

    if channel is None:
        async for dialog in client.iter_dialogs():
            name_ascii = dialog.name.encode('ascii', 'ignore').decode('ascii').lower()
            if CHANNEL_NAME.lower() in name_ascii or CHANNEL_NAME.lower() in dialog.name.lower():
                channel = dialog.entity
                log(f"  Found channel by name: {dialog.name} (ID: {dialog.id})")
                break

    if channel is None:
        log(f"  [ERROR] Channel not found!")
        log("  Make sure you've joined the channel.")
        log("  Try adding 'channel_id' to telegram_config.json")
        await client.disconnect()
        return

    @client.on(events.NewMessage(chats=channel))
    async def handler(event):
        text = event.raw_text
        signal = parse_signal(text)

        if signal:
            log(f"\n{'='*50}")
            log(f"  NEW SIGNAL DETECTED!")
            log(f"  {signal}")
            log(f"{'='*50}")
            execute_signal(signal, dry_run=dry_run)
        # Else: noise message, ignore silently

    log(f"\n  Listening for signals... (Ctrl+C to stop)")
    log(f"  Detects: 'BUY/SELL GOLD@ xxxx' with TP levels")
    log(f"  Ignores: TP hit confirmations, promos, price tracking\n")
    await client.run_until_disconnected()


# ═══════════════════════════════════════════════════════════════════
#  TEST MODE
# ═══════════════════════════════════════════════════════════════════
def test_parser():
    """Test the signal parser with real GOLD PRO TRADER messages."""
    samples = [
        # ── Valid signals (should parse) ──
        ("BUY signal",
         "BUY GOLD@ 4800❤️❤️\n\n👑 TP1: 4803\n\n👑 TP2: 4806\n\n🔴 SL : PREMIUM ✅✅\nManage your risk at all times! Till"),
        ("SELL signal",
         "SELL GOLD@ 4654❤️❤️\n\n👑 TP1: 4650\n\n👑 TP2: 4646\n\n🔴 SL : PREMIUM ✅✅\nManage your risk at all times! Till"),
        ("BUY with numeric SL",
         "BUY GOLD@ 4781❤️❤️\n\n👑 TP1: 4784\n\n👑 TP2: 4788\n\n🔴 SL : 4770\nManage your risk at all times! Till"),
        ("Legacy #XAUUSD format",
         "#XAUUSD SELL 4860/4864\n\nTP 4856\nTP 4853\nTP 4850\nTP 4846\nSL 4876"),

        # ── Noise (should return None) ──
        ("TP1 hit confirmation",
         "SELL GOLD@ 4654❤️❤️\n\n👑 TP1: 4650\n\n👑 1ST Target done 👍✅✅"),
        ("All target done",
         "SELL GOLD@ 4654\n\nTP2: 4646\nAll' target done ✅✅"),
        ("Price tracking",
         "4653.50✅✅"),
        ("Active status",
         "Active ✅✅✅"),
        ("Ready message",
         "READY FOR NEW SIGNALS 🍬🍬💯💯"),
        ("Account promo",
         "ACCOUNT HANDLING WORK DONE ✅✅ 💯💯"),
        ("BUY GOLD@ without TP",
         "BUY GOLD@ 4723❤️❤️"),
    ]

    print("=" * 60)
    print("  SIGNAL PARSER TEST — GOLD PRO TRADER FORMAT")
    print("=" * 60)

    parsed = 0
    for label, msg in samples:
        signal = parse_signal(msg)
        if signal:
            parsed += 1
            print(f"\n  [OK] [{label}] SIGNAL: {signal}")
        else:
            print(f"  [--] [{label}] NOISE (ignored)")

    print(f"\n{'=' * 60}")
    print(f"  Parsed {parsed} signals out of {len(samples)} messages")
    print(f"  Expected: 4 signals, {len(samples) - 4} noise")
    print(f"{'=' * 60}")


# ═══════════════════════════════════════════════════════════════════
#  MAIN
# ═══════════════════════════════════════════════════════════════════
def main():
    import argparse
    parser = argparse.ArgumentParser(description="Telegram Signal Auto-Trader for XAUUSD")
    parser.add_argument("--dry-run", action="store_true", help="Parse signals but don't execute trades")
    parser.add_argument("--test", action="store_true", help="Test signal parser with samples")
    args = parser.parse_args()

    if args.test:
        test_parser()
        return

    load_config()

    if TELEGRAM_API_ID == 0:
        log("[SETUP REQUIRED]")
        log(f"  1. Go to https://my.telegram.org")
        log(f"  2. Get your API ID and Hash")
        log(f"  3. Edit: {CONFIG_FILE}")
        log(f"  4. Run again: python telegram_trader.py")
        return

    asyncio.run(run_listener(dry_run=args.dry_run))


if __name__ == "__main__":
    main()
