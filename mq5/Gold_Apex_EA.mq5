//+------------------------------------------------------------------+
//|                                          Gold_Apex_EA.mq5        |
//|          The Best of Everything — One Refined Strategy              |
//|                                                                    |
//|  Instead of 3-4 mediocre strategies, ONE strategy combining        |
//|  every lesson from 50+ backtests and live trading:                 |
//|                                                                    |
//|  ENTRY (all must be true):                                         |
//|  - Gaussian(80) rising with meaningful slope                       |
//|  - MACD histogram turning in trend direction                       |
//|  - Price above EMA200 (big trend)                                  |
//|  - ADX > 20 (confirmed trend)                                     |
//|  - Candle body > 0.4x ATR (conviction)                            |
//|  - RSI not at extreme                                              |
//|                                                                    |
//|  PROTECTION (from live trading lessons):                           |
//|  - Skip Monday (live data: -$288 all losses)                       |
//|  - Session 10-22 UTC only (Asian = all losses live)                |
//|  - Dead market ADX < 12 = no trade                                 |
//|  - 2 consecutive losses = 24 bar pause                             |
//|  - Strict $30 MaxSL enforcement                                    |
//|                                                                    |
//|  RE-ENTRY (Beast mechanic, guarded):                               |
//|  - After TP hit, re-enter if trend still strong (ADX > 25)        |
//|  - Kill switch: 2 Beast losses = Beast off for 48 bars             |
//|                                                                    |
//|  SL: 2.0x ATR | TP: 5.0x ATR | MaxSL: $30 | R:R = 1:2.5          |
//|                                                                    |
//|  Symbol: XAUUSD.a  |  Timeframe: H1                               |
//+------------------------------------------------------------------+
#property copyright "Claude EA Generator"
#property version   "1.00"
#property strict

//=== CORE PARAMS ===
input int    InpGaussPeriod   = 80;
input int    InpGaussPoles    = 4;
input int    InpEMAPeriod     = 200;
input double InpSLMult        = 2.0;
input double InpTPMult        = 5.0;
input double InpMaxSLDollars  = 30.0;
input double InpFixedLot      = 0.01;
input double InpMinATR        = 0.50;

//=== FILTERS ===
input double InpADXTrend      = 20.0;      // Min ADX for entry
input double InpADXDead       = 12.0;      // Below this = dead market
input double InpMinBodyATR    = 0.4;       // Min candle body
input double InpMinGaussSlope = 0.2;       // Min Gaussian movement per bar ($)
input double InpRSIOB         = 80.0;
input double InpRSIOS         = 28.0;

//=== TIME FILTERS ===
input bool   InpSkipMonday    = true;
input int    InpSessionStart  = 10;
input int    InpSessionEnd    = 22;

//=== LOSS PROTECTION ===
input int    InpPauseLosses   = 2;         // Pause after N consecutive losses
input int    InpPauseBars     = 24;

//=== RE-ENTRY (guarded Beast) ===
input bool   InpEnableReentry = true;
input double InpReentryADX    = 25.0;      // Only re-enter if ADX above this
input int    InpBeastKillLoss = 2;         // Kill re-entry after N losses
input int    InpBeastKillBars = 48;        // Re-entry off for N bars after kill

input int    InpMagic         = 890000;

//=== GLOBALS ===
int hATR, hRSI, hMACD, hEMA, hADX;
datetime lastBarTime;
int pending; double pendATR;

// Re-entry state
bool reentryLastTP;
int  reentryLastDir;
bool reentryKilled;
int  reentryKillBarsLeft;

// Loss tracking
int  consecLosses;
int  pauseLeft;
int  reentryConsecLoss;

int OnInit()
{
   hATR  = iATR(_Symbol, PERIOD_H1, 14);
   hRSI  = iRSI(_Symbol, PERIOD_H1, 14, PRICE_CLOSE);
   hMACD = iMACD(_Symbol, PERIOD_H1, 12, 26, 9, PRICE_CLOSE);
   hEMA  = iMA(_Symbol, PERIOD_H1, InpEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   hADX  = iADX(_Symbol, PERIOD_H1, 14);

   if(hATR == INVALID_HANDLE || hRSI == INVALID_HANDLE || hMACD == INVALID_HANDLE ||
      hEMA == INVALID_HANDLE || hADX == INVALID_HANDLE)
      return INIT_FAILED;

   lastBarTime = 0; pending = 0;
   reentryLastTP = false; reentryLastDir = 0;
   reentryKilled = false; reentryKillBarsLeft = 0;
   consecLosses = 0; pauseLeft = 0; reentryConsecLoss = 0;

   Print("Gold_Apex_EA | The best of everything");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int r)
{
   if(hATR  != INVALID_HANDLE) IndicatorRelease(hATR);
   if(hRSI  != INVALID_HANDLE) IndicatorRelease(hRSI);
   if(hMACD != INVALID_HANDLE) IndicatorRelease(hMACD);
   if(hEMA  != INVALID_HANDLE) IndicatorRelease(hEMA);
   if(hADX  != INVALID_HANDLE) IndicatorRelease(hADX);
}

bool HasPos()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t > 0 && PositionGetInteger(POSITION_MAGIC) == InpMagic &&
         PositionGetString(POSITION_SYMBOL) == _Symbol) return true;
   }
   return false;
}

bool Trade(ENUM_ORDER_TYPE ty, double sl, double tp, string c)
{
   double f = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   long l = AccountInfoInteger(ACCOUNT_LEVERAGE);
   double p = (ty == ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                                       : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(p * InpFixedLot * 100.0 / l > f * 0.80) return false;
   double sd = MathAbs(p - sl);
   if(InpMaxSLDollars > 0 && sd > InpMaxSLDollars * 1.05) return false;

   MqlTradeRequest rq = {}; MqlTradeResult rs = {};
   rq.action = TRADE_ACTION_DEAL; rq.symbol = _Symbol; rq.volume = InpFixedLot;
   rq.type = ty; rq.price = p;
   rq.sl = NormalizeDouble(sl, _Digits); rq.tp = NormalizeDouble(tp, _Digits);
   rq.deviation = 30; rq.magic = InpMagic; rq.comment = c;
   rq.type_filling = ORDER_FILLING_IOC;
   if(!OrderSend(rq, rs)) return false;
   if(rs.retcode == TRADE_RETCODE_DONE || rs.retcode == TRADE_RETCODE_PLACED)
   { Print(c, " P=", rs.price, " SL=", sl, " TP=", tp); return true; }
   return false;
}

double GF(int shift)
{
   int n = MathMin(iBars(_Symbol, PERIOD_H1) - shift, 5000);
   if(n < InpGaussPeriod * 3) return 0;
   double c[]; ArraySetAsSeries(c, false);
   if(CopyClose(_Symbol, PERIOD_H1, shift, n, c) < n) return 0;
   double bt = (1.0 - MathCos(2.0 * M_PI / InpGaussPeriod)) / (MathPow(2.0, 1.0 / InpGaussPoles) - 1.0);
   double al = -bt + MathSqrt(bt * bt + 2.0 * bt);
   double r[]; ArrayResize(r, n); ArrayCopy(r, c);
   for(int p = 0; p < InpGaussPoles; p++)
   { double b[]; ArrayResize(b, n); b[0] = r[0];
     for(int j = 1; j < n; j++) b[j] = al * r[j] + (1.0 - al) * b[j - 1];
     ArrayCopy(r, b); }
   return r[n - 1];
}

void CheckLastDeal()
{
   HistorySelect(TimeCurrent() - 86400 * 7, TimeCurrent());
   int total = HistoryDealsTotal();
   for(int i = total - 1; i >= MathMax(0, total - 10); i--)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket <= 0) continue;
      if(HistoryDealGetString(ticket, DEAL_SYMBOL) != _Symbol) continue;
      if(HistoryDealGetInteger(ticket, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) != InpMagic) continue;

      double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
      string comment = HistoryDealGetString(ticket, DEAL_COMMENT);

      if(profit > 0 || StringFind(comment, "tp") >= 0)
      {
         reentryLastTP = true;
         ENUM_DEAL_TYPE dt = (ENUM_DEAL_TYPE)HistoryDealGetInteger(ticket, DEAL_TYPE);
         reentryLastDir = (dt == DEAL_TYPE_SELL) ? 1 : -1;
         reentryConsecLoss = 0;
      }
      else
      {
         reentryLastTP = false;
         reentryLastDir = 0;
         reentryConsecLoss++;
      }
      return;
   }
}

int CountConsecLosses()
{
   HistorySelect(TimeCurrent() - 86400 * 7, TimeCurrent());
   int total = HistoryDealsTotal();
   int streak = 0;
   for(int i = total - 1; i >= MathMax(0, total - 20); i--)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket <= 0) continue;
      if(HistoryDealGetString(ticket, DEAL_SYMBOL) != _Symbol) continue;
      if(HistoryDealGetInteger(ticket, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) != InpMagic) continue;
      if(HistoryDealGetDouble(ticket, DEAL_PROFIT) <= 0) streak++;
      else break;
   }
   return streak;
}

void OnTick()
{
   datetime ct = iTime(_Symbol, PERIOD_H1, 0);
   bool nb = (ct != lastBarTime);

   // Execute pending
   if(nb && pending != 0 && !HasPos())
   {
      double a = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double b = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double sd = pendATR * InpSLMult, td = pendATR * InpTPMult;
      if(InpMaxSLDollars > 0 && sd > InpMaxSLDollars)
      { double ratio = InpTPMult / InpSLMult; sd = InpMaxSLDollars; td = sd * ratio; }
      if(pending == 1) Trade(ORDER_TYPE_BUY, a - sd, a + td, "Apex_Buy");
      else Trade(ORDER_TYPE_SELL, b + sd, b - td, "Apex_Sell");
      pending = 0;
   }

   if(!nb) return;
   lastBarTime = ct;

   // Check last deal for re-entry and loss streak
   CheckLastDeal();

   // Loss streak pause
   int losses = CountConsecLosses();
   if(losses >= InpPauseLosses && consecLosses < InpPauseLosses)
      pauseLeft = InpPauseBars;
   consecLosses = losses;
   if(pauseLeft > 0) { pauseLeft--; return; }

   // Re-entry kill switch
   if(reentryConsecLoss >= InpBeastKillLoss && !reentryKilled)
   { reentryKilled = true; reentryKillBarsLeft = InpBeastKillBars; }
   if(reentryKillBarsLeft > 0) reentryKillBarsLeft--;
   if(reentryKillBarsLeft == 0 && reentryKilled) reentryKilled = false;

   if(HasPos()) { pending = 0; return; }

   // TIME FILTERS
   MqlDateTime dt; TimeToStruct(iTime(_Symbol, PERIOD_H1, 1), dt);
   if(InpSkipMonday && dt.day_of_week == 1) return;
   if(dt.hour < InpSessionStart || dt.hour >= InpSessionEnd) return;

   // INDICATORS
   double atr[1]; if(CopyBuffer(hATR, 0, 1, 1, atr) < 1) return;
   if(atr[0] < InpMinATR) return;

   double adx[1]; if(CopyBuffer(hADX, 0, 1, 1, adx) < 1) return;
   if(adx[0] < InpADXDead) return;  // Dead market

   double rsi[1]; if(CopyBuffer(hRSI, 0, 1, 1, rsi) < 1) return;
   double ema[1]; if(CopyBuffer(hEMA, 0, 1, 1, ema) < 1) return;

   double mm[2], ms[2];
   if(CopyBuffer(hMACD, 0, 1, 2, mm) < 2) return;
   if(CopyBuffer(hMACD, 1, 1, 2, ms) < 2) return;
   double mh = mm[1] - ms[1], mhp = mm[0] - ms[0];

   double g1 = GF(1), g2 = GF(2);
   if(g1 == 0) return;

   double c1 = iClose(_Symbol, PERIOD_H1, 1);
   double o1 = iOpen(_Symbol, PERIOD_H1, 1);
   double gSlope = MathAbs(g1 - g2);

   // RE-ENTRY after TP (guarded)
   if(InpEnableReentry && reentryLastTP && !reentryKilled && reentryLastDir != 0)
   {
      if(adx[0] >= InpReentryADX)  // Only re-enter in strong trends
      {
         if(reentryLastDir == 1 && g1 > g2 && c1 > g1 && rsi[0] < InpRSIOB)
         { pending = 1; pendATR = atr[0]; reentryLastTP = false;
           Print("APEX RE-ENTRY BUY | ADX=", adx[0]); return; }
         else if(reentryLastDir == -1 && g1 < g2 && c1 < g1 && rsi[0] > InpRSIOS)
         { pending = -1; pendATR = atr[0]; reentryLastTP = false;
           Print("APEX RE-ENTRY SELL | ADX=", adx[0]); return; }
      }
      reentryLastTP = false;
   }

   // FRESH ENTRY — ALL filters must pass
   if(adx[0] < InpADXTrend) return;
   if(gSlope < InpMinGaussSlope) return;

   double body = MathAbs(c1 - o1);
   if(body < atr[0] * InpMinBodyATR) return;

   bool mu = (mh > mhp) && (mh > -0.5);
   bool md = (mh < mhp) && (mh < 0.5);

   // BUY: Gauss rising + MACD up + price > Gauss + price > EMA200 + RSI ok
   if(g1 > g2 && mu && c1 > g1 && c1 > ema[0] && rsi[0] < InpRSIOB)
   {
      pending = 1; pendATR = atr[0];
      Print("APEX BUY | GF=", g1, " ADX=", adx[0], " RSI=", rsi[0], " MACD=", mh);
   }
   // SELL: Gauss falling + MACD down + price < Gauss + price < EMA200 + RSI ok
   else if(g1 < g2 && md && c1 < g1 && c1 < ema[0] && rsi[0] > InpRSIOS)
   {
      pending = -1; pendATR = atr[0];
      Print("APEX SELL | GF=", g1, " ADX=", adx[0], " RSI=", rsi[0], " MACD=", mh);
   }
}
//+------------------------------------------------------------------+
