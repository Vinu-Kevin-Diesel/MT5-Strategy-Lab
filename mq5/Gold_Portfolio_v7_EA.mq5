//+------------------------------------------------------------------+
//|                                    Gold_Portfolio_v7_EA.mq5      |
//|          Smart Portfolio — Beast with Kill Switch                    |
//|                                                                    |
//|  3 strategies: MultiFilter + GaussMACD + Beast (conditional)       |
//|                                                                    |
//|  Beast has a KILL SWITCH:                                          |
//|  ON when:  Gaussian strongly rising + ADX > 20 + no recent losses |
//|  OFF when: 2+ consecutive Beast losses OR ADX < 15 OR Gauss flat  |
//|                                                                    |
//|  Also includes:                                                    |
//|  - Monday skip                                                     |
//|  - Session filter 10:00-22:00 UTC                                  |
//|  - Dead market ADX < 12 filter (all strategies)                    |
//|  - Global loss streak pause (3 losses = 24 bar pause)              |
//|  - Strict MaxSL enforcement                                        |
//|                                                                    |
//|  Symbol: XAUUSD.a  |  Timeframe: H1                               |
//+------------------------------------------------------------------+
#property copyright "Claude EA Generator"
#property version   "7.00"
#property strict

//=== SHARED ===
input double InpFixedLot       = 0.01;
input double InpMaxSLDollars   = 30.0;
input double InpMinATR         = 0.50;
input double InpDeadMarketADX  = 12.0;
input bool   InpSkipMonday     = true;
input int    InpSessionStart   = 10;
input int    InpSessionEnd     = 22;
input int    InpGlobalPauseLosses = 3;      // Global pause after N consecutive losses
input int    InpGlobalPauseBars  = 24;      // Global pause duration

//=== BEAST (with kill switch) ===
input int    InpB_GaussPeriod  = 80;
input int    InpB_GaussPoles   = 4;
input int    InpB_FastEMA      = 21;
input int    InpB_SlowEMA      = 50;
input double InpB_SLMult       = 1.5;
input double InpB_TPMult       = 5.0;
input double InpB_RSIOB        = 80.0;
input double InpB_RSIOS        = 20.0;
input double InpB_MinADX       = 20.0;      // Beast only when ADX above this
input int    InpB_MaxConsecLoss = 2;         // Beast kill switch: off after N losses
input int    InpB_RecoveryBars  = 48;        // Beast stays off for this many bars after kill
input double InpB_MinGaussSlope = 0.3;       // Gaussian must move at least this $/bar
input int    InpB_Magic        = 889960;

//=== MULTIFILTER ===
input int    InpMF_GaussPeriod = 80;
input int    InpMF_GaussPoles  = 4;
input double InpMF_SLMult      = 2.0;
input double InpMF_TPMult      = 4.0;
input double InpMF_RSIOB       = 80.0;
input double InpMF_RSIOS       = 28.0;
input double InpMF_ADXMin      = 20.0;
input double InpMF_MinBodyATR  = 0.4;
input int    InpMF_EMATrend    = 200;
input int    InpMF_Magic       = 889910;

//=== GAUSSMACD ===
input int    InpGM_GaussPeriod = 80;
input int    InpGM_GaussPoles  = 4;
input double InpGM_SLMult      = 2.5;
input double InpGM_TPMult      = 5.0;
input double InpGM_RSIOB       = 80.0;
input double InpGM_RSIOS       = 28.0;
input int    InpGM_Magic       = 889900;

//=== GLOBALS ===
int hATR, hRSI, hMACD, hEMA200, hADX, hEMAFast, hEMASlow;
datetime lastBarTime;

int mfPending; double mfATR;
int gmPending; double gmATR;
int bPending;  double bATR;

// Beast state
bool   beastKilled;         // Kill switch active
int    beastKillBarsLeft;   // Bars until Beast can re-activate
int    beastConsecLosses;   // Beast-specific consecutive losses
bool   beastLastTP;
int    beastLastDir;

// Global pause
int    globalConsecLosses;
int    globalPauseBarsLeft;

double startBalance;

int OnInit()
{
   hATR     = iATR(_Symbol, PERIOD_H1, 14);
   hRSI     = iRSI(_Symbol, PERIOD_H1, 14, PRICE_CLOSE);
   hMACD    = iMACD(_Symbol, PERIOD_H1, 12, 26, 9, PRICE_CLOSE);
   hEMA200  = iMA(_Symbol, PERIOD_H1, InpMF_EMATrend, 0, MODE_EMA, PRICE_CLOSE);
   hADX     = iADX(_Symbol, PERIOD_H1, 14);
   hEMAFast = iMA(_Symbol, PERIOD_H1, InpB_FastEMA, 0, MODE_EMA, PRICE_CLOSE);
   hEMASlow = iMA(_Symbol, PERIOD_H1, InpB_SlowEMA, 0, MODE_EMA, PRICE_CLOSE);

   if(hATR == INVALID_HANDLE || hRSI == INVALID_HANDLE || hMACD == INVALID_HANDLE ||
      hEMA200 == INVALID_HANDLE || hADX == INVALID_HANDLE ||
      hEMAFast == INVALID_HANDLE || hEMASlow == INVALID_HANDLE)
      return INIT_FAILED;

   lastBarTime = 0;
   mfPending = 0; gmPending = 0; bPending = 0;
   beastKilled = false; beastKillBarsLeft = 0; beastConsecLosses = 0;
   beastLastTP = false; beastLastDir = 0;
   globalConsecLosses = 0; globalPauseBarsLeft = 0;
   startBalance = AccountInfoDouble(ACCOUNT_BALANCE);

   Print("Gold_Portfolio_v7 | Beast kill switch | Monday=", InpSkipMonday,
         " | Session=", InpSessionStart, "-", InpSessionEnd);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(hATR     != INVALID_HANDLE) IndicatorRelease(hATR);
   if(hRSI     != INVALID_HANDLE) IndicatorRelease(hRSI);
   if(hMACD    != INVALID_HANDLE) IndicatorRelease(hMACD);
   if(hEMA200  != INVALID_HANDLE) IndicatorRelease(hEMA200);
   if(hADX     != INVALID_HANDLE) IndicatorRelease(hADX);
   if(hEMAFast != INVALID_HANDLE) IndicatorRelease(hEMAFast);
   if(hEMASlow != INVALID_HANDLE) IndicatorRelease(hEMASlow);
}

bool HasPos(int magic)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t > 0 && PositionGetInteger(POSITION_MAGIC) == magic &&
         PositionGetString(POSITION_SYMBOL) == _Symbol) return true;
   }
   return false;
}

bool Trade(ENUM_ORDER_TYPE ty, double sl, double tp, int mag, string c)
{
   double f = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   long l = AccountInfoInteger(ACCOUNT_LEVERAGE);
   double p = (ty == ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                                       : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(p * InpFixedLot * 100.0 / l > f * 0.80) return false;
   // Strict SL check
   double sd = MathAbs(p - sl);
   if(InpMaxSLDollars > 0 && sd > InpMaxSLDollars * 1.05)
   { Print("[BLOCKED] SL $", sd, " > max $", InpMaxSLDollars); return false; }

   MqlTradeRequest rq = {}; MqlTradeResult rs = {};
   rq.action = TRADE_ACTION_DEAL; rq.symbol = _Symbol; rq.volume = InpFixedLot;
   rq.type = ty; rq.price = p;
   rq.sl = NormalizeDouble(sl, _Digits); rq.tp = NormalizeDouble(tp, _Digits);
   rq.deviation = 30; rq.magic = mag; rq.comment = c;
   rq.type_filling = ORDER_FILLING_IOC;
   if(!OrderSend(rq, rs)) return false;
   if(rs.retcode == TRADE_RETCODE_DONE || rs.retcode == TRADE_RETCODE_PLACED)
   { Print(c, " P=", rs.price, " SL=", sl, " TP=", tp); return true; }
   return false;
}

void Exec(int &sig, double &atr, double slM, double tpM, int mag, string pfx)
{
   if(sig == 0 || HasPos(mag)) { sig = 0; return; }
   double a = SymbolInfoDouble(_Symbol, SYMBOL_ASK), b = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sd = atr * slM, td = atr * tpM;
   if(InpMaxSLDollars > 0 && sd > InpMaxSLDollars)
   { double r = tpM / slM; sd = InpMaxSLDollars; td = sd * r; }
   if(sig == 1) Trade(ORDER_TYPE_BUY, a - sd, a + td, mag, pfx + "_Buy");
   else Trade(ORDER_TYPE_SELL, b + sd, b - td, mag, pfx + "_Sell");
   sig = 0;
}

double GF(int per, int pol, int sh)
{
   int n = MathMin(iBars(_Symbol, PERIOD_H1) - sh, 5000);
   if(n < per * 3) return 0;
   double c[]; ArraySetAsSeries(c, false);
   if(CopyClose(_Symbol, PERIOD_H1, sh, n, c) < n) return 0;
   double bt = (1.0 - MathCos(2.0 * M_PI / per)) / (MathPow(2.0, 1.0 / pol) - 1.0);
   double al = -bt + MathSqrt(bt * bt + 2.0 * bt);
   double r[]; ArrayResize(r, n); ArrayCopy(r, c);
   for(int p = 0; p < pol; p++)
   { double b[]; ArrayResize(b, n); b[0] = r[0];
     for(int j = 1; j < n; j++) b[j] = al * r[j] + (1.0 - al) * b[j - 1];
     ArrayCopy(r, b); }
   return r[n - 1];
}

// Check recent losses for a specific magic
int CountRecentLosses(int magic)
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
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) != magic) continue;
      double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
      if(profit <= 0) streak++;
      else break;
   }
   return streak;
}

// Check global consecutive losses (any strategy)
int CountGlobalLosses()
{
   HistorySelect(TimeCurrent() - 86400 * 7, TimeCurrent());
   int total = HistoryDealsTotal();
   int streak = 0;
   for(int i = total - 1; i >= MathMax(0, total - 30); i--)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket <= 0) continue;
      if(HistoryDealGetString(ticket, DEAL_SYMBOL) != _Symbol) continue;
      if(HistoryDealGetInteger(ticket, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;
      long mag = HistoryDealGetInteger(ticket, DEAL_MAGIC);
      if(mag != InpB_Magic && mag != InpMF_Magic && mag != InpGM_Magic) continue;
      double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
      if(profit <= 0) streak++;
      else break;
   }
   return streak;
}

void CheckBeastTP()
{
   HistorySelect(TimeCurrent() - 86400, TimeCurrent());
   int total = HistoryDealsTotal();
   for(int i = total - 1; i >= MathMax(0, total - 5); i--)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket > 0 && HistoryDealGetInteger(ticket, DEAL_MAGIC) == InpB_Magic &&
         HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol &&
         HistoryDealGetInteger(ticket, DEAL_ENTRY) == DEAL_ENTRY_OUT)
      {
         double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
         string comment = HistoryDealGetString(ticket, DEAL_COMMENT);
         if(profit > 0 || StringFind(comment, "tp") >= 0)
         {
            beastLastTP = true;
            ENUM_DEAL_TYPE dt = (ENUM_DEAL_TYPE)HistoryDealGetInteger(ticket, DEAL_TYPE);
            beastLastDir = (dt == DEAL_TYPE_SELL) ? 1 : -1;
         }
         else { beastLastTP = false; beastLastDir = 0; }
         return;
      }
   }
}

void OnTick()
{
   datetime ct = iTime(_Symbol, PERIOD_H1, 0);
   bool nb = (ct != lastBarTime);

   if(nb)
   {
      Exec(mfPending, mfATR, InpMF_SLMult, InpMF_TPMult, InpMF_Magic, "MF");
      Exec(gmPending, gmATR, InpGM_SLMult, InpGM_TPMult, InpGM_Magic, "GM");
      Exec(bPending, bATR, InpB_SLMult, InpB_TPMult, InpB_Magic, "Beast");
   }

   if(!nb) return;
   lastBarTime = ct;

   // === GLOBAL PAUSE CHECK ===
   int gLosses = CountGlobalLosses();
   if(gLosses >= InpGlobalPauseLosses && globalConsecLosses < InpGlobalPauseLosses)
   {
      globalPauseBarsLeft = InpGlobalPauseBars;
      Print("[GLOBAL PAUSE] ", gLosses, " consecutive losses. Pausing ", InpGlobalPauseBars, " bars.");
   }
   globalConsecLosses = gLosses;

   if(globalPauseBarsLeft > 0) { globalPauseBarsLeft--; return; }

   // === BEAST KILL SWITCH ===
   CheckBeastTP();
   int bLosses = CountRecentLosses(InpB_Magic);
   if(bLosses >= InpB_MaxConsecLoss && !beastKilled)
   {
      beastKilled = true;
      beastKillBarsLeft = InpB_RecoveryBars;
      Print("[BEAST KILLED] ", bLosses, " consecutive Beast losses. Off for ", InpB_RecoveryBars, " bars.");
   }
   if(beastKillBarsLeft > 0) beastKillBarsLeft--;
   if(beastKillBarsLeft == 0 && beastKilled)
   {
      beastKilled = false;
      Print("[BEAST REVIVED] Kill switch off. Beast can trade again.");
   }

   // === TIME FILTERS ===
   MqlDateTime dt;
   TimeToStruct(iTime(_Symbol, PERIOD_H1, 1), dt);
   if(InpSkipMonday && dt.day_of_week == 1) return;
   if(dt.hour < InpSessionStart || dt.hour >= InpSessionEnd) return;

   // === INDICATORS ===
   double atr[1]; if(CopyBuffer(hATR, 0, 1, 1, atr) < 1) return;
   if(atr[0] < InpMinATR) return;

   double adx[1]; if(CopyBuffer(hADX, 0, 1, 1, adx) < 1) return;
   if(adx[0] < InpDeadMarketADX) return;

   double rsi[1]; if(CopyBuffer(hRSI, 0, 1, 1, rsi) < 1) return;
   double ema200[1]; if(CopyBuffer(hEMA200, 0, 1, 1, ema200) < 1) return;
   double emaF[2], emaS[2];
   if(CopyBuffer(hEMAFast, 0, 1, 2, emaF) < 2) return;
   if(CopyBuffer(hEMASlow, 0, 1, 2, emaS) < 2) return;

   double mm[2], ms[2];
   if(CopyBuffer(hMACD, 0, 1, 2, mm) < 2) return;
   if(CopyBuffer(hMACD, 1, 1, 2, ms) < 2) return;
   double mh = mm[1] - ms[1], mhp = mm[0] - ms[0];

   double c1 = iClose(_Symbol, PERIOD_H1, 1);
   double o1 = iOpen(_Symbol, PERIOD_H1, 1);
   double h1 = iHigh(_Symbol, PERIOD_H1, 1);
   double l1 = iLow(_Symbol, PERIOD_H1, 1);

   // === STRATEGY 1: MULTIFILTER ===
   if(!HasPos(InpMF_Magic))
   {
      double g1 = GF(InpMF_GaussPeriod, InpMF_GaussPoles, 1);
      double g2 = GF(InpMF_GaussPeriod, InpMF_GaussPoles, 2);
      if(g1 != 0 && g2 != 0)
      {
         double body = MathAbs(c1 - o1);
         if(adx[0] >= InpMF_ADXMin && body >= atr[0] * InpMF_MinBodyATR)
         {
            bool mu = (mh > mhp) && (mh > -0.5), md = (mh < mhp) && (mh < 0.5);
            if(g1 > g2 && mu && c1 > g1 && c1 > ema200[0] && rsi[0] < InpMF_RSIOB)
            { mfPending = 1; mfATR = atr[0]; }
            else if(g1 < g2 && md && c1 < g1 && c1 < ema200[0] && rsi[0] > InpMF_RSIOS)
            { mfPending = -1; mfATR = atr[0]; }
         }
      }
   }

   // === STRATEGY 2: GAUSSMACD ===
   if(!HasPos(InpGM_Magic))
   {
      double g1 = GF(InpGM_GaussPeriod, InpGM_GaussPoles, 1);
      double g2 = GF(InpGM_GaussPeriod, InpGM_GaussPoles, 2);
      if(g1 != 0 && g2 != 0)
      {
         bool mu = (mh > mhp) && (mh > -0.5), md = (mh < mhp) && (mh < 0.5);
         if(g1 > g2 && mu && c1 > g1 && rsi[0] < InpGM_RSIOB)
         { gmPending = 1; gmATR = atr[0]; }
         else if(g1 < g2 && md && c1 < g1 && rsi[0] > InpGM_RSIOS)
         { gmPending = -1; gmATR = atr[0]; }
      }
   }

   // === STRATEGY 3: BEAST (with kill switch) ===
   if(!beastKilled && !HasPos(InpB_Magic))
   {
      double g1 = GF(InpB_GaussPeriod, InpB_GaussPoles, 1);
      double g2 = GF(InpB_GaussPeriod, InpB_GaussPoles, 2);
      if(g1 != 0 && g2 != 0)
      {
         // Beast extra conditions: ADX must be strong + Gaussian must be moving decisively
         double gSlope = MathAbs(g1 - g2);
         if(adx[0] < InpB_MinADX || gSlope < InpB_MinGaussSlope)
         {
            // Not trending enough for Beast
         }
         else
         {
            bool gfUp = (g1 > g2), gfDn = (g1 < g2);
            bool emaUp = (emaF[1] > emaS[1]), emaDn = (emaF[1] < emaS[1]);

            // Re-entry after TP
            if(beastLastTP && beastLastDir != 0)
            {
               if(beastLastDir == 1 && gfUp && emaUp && rsi[0] < InpB_RSIOB)
               { bPending = 1; bATR = atr[0]; beastLastTP = false; }
               else if(beastLastDir == -1 && gfDn && emaDn && rsi[0] > InpB_RSIOS)
               { bPending = -1; bATR = atr[0]; beastLastTP = false; }
               else beastLastTP = false;
            }
            else
            {
               // Fresh pullback entry
               if(gfUp && emaUp && c1 > g1)
               {
                  double pb = MathAbs(l1 - emaF[1]);
                  if(pb < atr[0] * 1.5 && c1 > o1 && rsi[0] < InpB_RSIOB)
                  { bPending = 1; bATR = atr[0]; }
               }
               else if(gfDn && emaDn && c1 < g1)
               {
                  double pb = MathAbs(h1 - emaF[1]);
                  if(pb < atr[0] * 1.5 && c1 < o1 && rsi[0] > InpB_RSIOS)
                  { bPending = -1; bATR = atr[0]; }
               }
            }
         }
      }
   }
}
//+------------------------------------------------------------------+
