//+------------------------------------------------------------------+
//|                                          Gold_Combo_EA.mq5       |
//|                 Smart GaussMACD + SessionMomentum Combined         |
//|                                                                    |
//|  v2: Adaptive regime switching                                     |
//|  - ADX measures trend strength                                     |
//|  - Strong trend (ADX > threshold): GaussMACD only                  |
//|  - Weak/ranging (ADX <= threshold): Both strategies active         |
//|  - Best of both worlds: big trends + session scalps                |
//|                                                                    |
//|  Symbol: XAUUSD.a  |  Timeframe: H1                               |
//+------------------------------------------------------------------+
#property copyright "Claude EA Generator"
#property version   "2.00"
#property strict

//=== SHARED INPUTS ===
input double InpFixedLot      = 0.01;
input double InpMaxSLDollars  = 30;
input double InpMinATR        = 0.50;

//=== REGIME DETECTION ===
input int    InpADXPeriod     = 14;        // ADX Period for regime detection
input double InpADXThreshold  = 20;      // ADX above this = strong trend (SM off)

//=== GAUSSMACD INPUTS ===
input int    InpGM_GaussPeriod = 100;       // [GM] Gaussian Period
input int    InpGM_GaussPoles  = 4;        // [GM] Gaussian Poles
input int    InpGM_MACDFast    = 12;       // [GM] MACD Fast
input int    InpGM_MACDSlow    = 26;       // [GM] MACD Slow
input int    InpGM_MACDSignal  = 9;        // [GM] MACD Signal
input int    InpGM_ATRPeriod   = 14;       // [GM] ATR Period
input int    InpGM_RSIPeriod   = 14;       // [GM] RSI Period
input double InpGM_SLMult      = 2.5;      // [GM] SL x ATR
input double InpGM_TPMult      = 4.0;      // [GM] TP x ATR
input double InpGM_RSIOB       = 80.0;     // [GM] RSI Overbought
input double InpGM_RSIOS       = 28.0;     // [GM] RSI Oversold
input int    InpGM_Magic       = 889900;   // [GM] Magic Number

//=== SESSION MOMENTUM INPUTS ===
input int    InpSM_EMAPeriod   = 50;       // [SM] EMA Period
input int    InpSM_ATRPeriod   = 14;       // [SM] ATR Period
input int    InpSM_BodyLookback = 20;      // [SM] Body avg lookback
input double InpSM_BodyMult    = 1.5;      // [SM] Min body multiplier
input double InpSM_SLMult      = 1.0;      // [SM] SL x ATR
input double InpSM_TPMult      = 1.5;      // [SM] TP x ATR
input int    InpSM_LondonHour  = 7;        // [SM] London open hour
input int    InpSM_NYHour      = 13;       // [SM] NY open hour
input double InpSM_RSIOB       = 75.0;     // [SM] RSI Overbought
input double InpSM_RSIOS       = 25.0;     // [SM] RSI Oversold
input int    InpSM_Magic       = 889906;   // [SM] Magic Number

//=== GLOBAL HANDLES ===
int hGM_MACD, hGM_ATR, hGM_RSI;
int hSM_EMA, hSM_ATR, hSM_RSI;
int hADX;  // Regime detector

datetime gmLastBar;
int gmPendingSignal;
double gmPendingATR;

datetime smLastBar;
int smPendingSignal;
double smPendingATR;

//+------------------------------------------------------------------+
int OnInit()
{
   hGM_MACD = iMACD(_Symbol, PERIOD_H1, InpGM_MACDFast, InpGM_MACDSlow, InpGM_MACDSignal, PRICE_CLOSE);
   hGM_ATR  = iATR(_Symbol, PERIOD_H1, InpGM_ATRPeriod);
   hGM_RSI  = iRSI(_Symbol, PERIOD_H1, InpGM_RSIPeriod, PRICE_CLOSE);
   hSM_EMA  = iMA(_Symbol, PERIOD_H1, InpSM_EMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   hSM_ATR  = iATR(_Symbol, PERIOD_H1, InpSM_ATRPeriod);
   hSM_RSI  = iRSI(_Symbol, PERIOD_H1, 14, PRICE_CLOSE);
   hADX     = iADX(_Symbol, PERIOD_H1, InpADXPeriod);

   if(hGM_MACD == INVALID_HANDLE || hGM_ATR == INVALID_HANDLE || hGM_RSI == INVALID_HANDLE ||
      hSM_EMA == INVALID_HANDLE || hSM_ATR == INVALID_HANDLE || hSM_RSI == INVALID_HANDLE ||
      hADX == INVALID_HANDLE)
   {
      Print("Failed to create indicator handles");
      return(INIT_FAILED);
   }

   gmLastBar = 0; gmPendingSignal = 0;
   smLastBar = 0; smPendingSignal = 0;

   Print("Gold_Combo_EA v2 (Adaptive) initialized");
   Print("ADX threshold=", InpADXThreshold, " (above=trend only, below=both strats)");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(hGM_MACD != INVALID_HANDLE) IndicatorRelease(hGM_MACD);
   if(hGM_ATR  != INVALID_HANDLE) IndicatorRelease(hGM_ATR);
   if(hGM_RSI  != INVALID_HANDLE) IndicatorRelease(hGM_RSI);
   if(hSM_EMA  != INVALID_HANDLE) IndicatorRelease(hSM_EMA);
   if(hSM_ATR  != INVALID_HANDLE) IndicatorRelease(hSM_ATR);
   if(hSM_RSI  != INVALID_HANDLE) IndicatorRelease(hSM_RSI);
   if(hADX     != INVALID_HANDLE) IndicatorRelease(hADX);
}

//+------------------------------------------------------------------+
bool HasPosition(int magic)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
         if(PositionGetInteger(POSITION_MAGIC) == magic &&
            PositionGetString(POSITION_SYMBOL) == _Symbol)
            return true;
   }
   return false;
}

//+------------------------------------------------------------------+
bool OpenTrade(ENUM_ORDER_TYPE orderType, double sl, double tp, double lot, int magic, string comment)
{
   double freeM = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   long lev = AccountInfoInteger(ACCOUNT_LEVERAGE);
   double price = (orderType == ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                                                  : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double marginNeeded = price * lot * 100.0 / lev;
   if(marginNeeded > freeM * 0.80) return false;

   MqlTradeRequest request = {};
   MqlTradeResult  result  = {};
   request.action = TRADE_ACTION_DEAL;
   request.symbol = _Symbol;
   request.volume = lot;
   request.type = orderType;
   request.price = price;
   request.sl = NormalizeDouble(sl, _Digits);
   request.tp = NormalizeDouble(tp, _Digits);
   request.deviation = 30;
   request.magic = magic;
   request.comment = comment;
   request.type_filling = ORDER_FILLING_IOC;
   if(!OrderSend(request, result)) return false;
   if(result.retcode == TRADE_RETCODE_DONE || result.retcode == TRADE_RETCODE_PLACED)
   {
      Print("[", comment, "] Price=", result.price, " SL=", sl, " TP=", tp);
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
double ComputeGaussianFilter(int shift)
{
   int totalBars = iBars(_Symbol, PERIOD_H1);
   int barsNeeded = MathMin(totalBars - shift, 5000);
   if(barsNeeded < InpGM_GaussPeriod * 3) return 0;

   double closes[];
   ArraySetAsSeries(closes, false);
   if(CopyClose(_Symbol, PERIOD_H1, shift, barsNeeded, closes) < barsNeeded) return 0;

   double beta = (1.0 - MathCos(2.0 * M_PI / InpGM_GaussPeriod)) / (MathPow(2.0, 1.0 / InpGM_GaussPoles) - 1.0);
   double alpha = -beta + MathSqrt(beta * beta + 2.0 * beta);

   double result[];
   ArrayResize(result, barsNeeded);
   ArrayCopy(result, closes);

   for(int p = 0; p < InpGM_GaussPoles; p++)
   {
      double buf[];
      ArrayResize(buf, barsNeeded);
      buf[0] = result[0];
      for(int j = 1; j < barsNeeded; j++)
         buf[j] = alpha * result[j] + (1.0 - alpha) * buf[j - 1];
      ArrayCopy(result, buf);
   }
   return result[barsNeeded - 1];
}

//+------------------------------------------------------------------+
// Get current ADX value
//+------------------------------------------------------------------+
double GetADX()
{
   double adxArr[1];
   if(CopyBuffer(hADX, 0, 1, 1, adxArr) < 1) return 0;
   return adxArr[0];
}

//+------------------------------------------------------------------+
// STRATEGY 1: GaussMACD (always active)
//+------------------------------------------------------------------+
void RunGaussMACD(bool newBar)
{
   if(newBar && gmPendingSignal != 0 && !HasPosition(InpGM_Magic))
   {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double slDist = gmPendingATR * InpGM_SLMult;
      double tpDist = gmPendingATR * InpGM_TPMult;
      if(slDist > InpMaxSLDollars)
      {
         double ratio = InpGM_TPMult / InpGM_SLMult;
         slDist = InpMaxSLDollars;
         tpDist = slDist * ratio;
      }
      if(gmPendingSignal == 1)
         OpenTrade(ORDER_TYPE_BUY, ask - slDist, ask + tpDist, InpFixedLot, InpGM_Magic, "GM_Buy");
      else
         OpenTrade(ORDER_TYPE_SELL, bid + slDist, bid - tpDist, InpFixedLot, InpGM_Magic, "GM_Sell");
      gmPendingSignal = 0;
   }

   if(!newBar) return;
   if(HasPosition(InpGM_Magic)) { gmPendingSignal = 0; return; }

   double macdMain[2], macdSig[2];
   if(CopyBuffer(hGM_MACD, 0, 1, 2, macdMain) < 2) return;
   if(CopyBuffer(hGM_MACD, 1, 1, 2, macdSig) < 2) return;
   double hist1 = macdMain[1] - macdSig[1];
   double hist2 = macdMain[0] - macdSig[0];

   double atrArr[1];
   if(CopyBuffer(hGM_ATR, 0, 1, 1, atrArr) < 1) return;
   if(atrArr[0] < InpMinATR) return;

   double rsiArr[1];
   if(CopyBuffer(hGM_RSI, 0, 1, 1, rsiArr) < 1) return;

   double gf1 = ComputeGaussianFilter(1);
   double gf2 = ComputeGaussianFilter(2);
   if(gf1 == 0 || gf2 == 0) return;

   double close1 = iClose(_Symbol, PERIOD_H1, 1);
   bool gfRising = (gf1 > gf2);
   bool gfFalling = (gf1 < gf2);
   bool macdUp = (hist1 > hist2) && (hist1 > -0.5);
   bool macdDn = (hist1 < hist2) && (hist1 < 0.5);

   if(gfRising && macdUp && close1 > gf1)
   {
      if(rsiArr[0] > InpGM_RSIOB) return;
      gmPendingSignal = 1;
      gmPendingATR = atrArr[0];
   }
   else if(gfFalling && macdDn && close1 < gf1)
   {
      if(rsiArr[0] < InpGM_RSIOS) return;
      gmPendingSignal = -1;
      gmPendingATR = atrArr[0];
   }
}

//+------------------------------------------------------------------+
// STRATEGY 2: Session Momentum (only in weak/ranging markets)
//+------------------------------------------------------------------+
void RunSessionMomentum(bool newBar, bool smEnabled)
{
   if(newBar && smPendingSignal != 0 && !HasPosition(InpSM_Magic))
   {
      // Still execute pending signals even if SM just got disabled
      // (signal was generated when SM was active)
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double slDist = smPendingATR * InpSM_SLMult;
      double tpDist = smPendingATR * InpSM_TPMult;
      if(slDist > InpMaxSLDollars)
      {
         double ratio = InpSM_TPMult / InpSM_SLMult;
         slDist = InpMaxSLDollars;
         tpDist = slDist * ratio;
      }
      if(smPendingSignal == 1)
         OpenTrade(ORDER_TYPE_BUY, ask - slDist, ask + tpDist, InpFixedLot, InpSM_Magic, "SM_Buy");
      else
         OpenTrade(ORDER_TYPE_SELL, bid + slDist, bid - tpDist, InpFixedLot, InpSM_Magic, "SM_Sell");
      smPendingSignal = 0;
   }

   if(!newBar) return;
   if(HasPosition(InpSM_Magic)) { smPendingSignal = 0; return; }

   // If SM is disabled (strong trend), don't generate new signals
   if(!smEnabled)
   {
      smPendingSignal = 0;
      return;
   }

   MqlDateTime dt;
   TimeToStruct(iTime(_Symbol, PERIOD_H1, 1), dt);
   int hour = dt.hour;
   bool isSessionOpen = (hour >= InpSM_LondonHour && hour <= InpSM_LondonHour + 2) ||
                        (hour >= InpSM_NYHour && hour <= InpSM_NYHour + 2);
   if(!isSessionOpen) return;

   double emaArr[1], atrArr[1], rsiArr[1];
   if(CopyBuffer(hSM_EMA, 0, 1, 1, emaArr) < 1) return;
   if(CopyBuffer(hSM_ATR, 0, 1, 1, atrArr) < 1) return;
   if(CopyBuffer(hSM_RSI, 0, 1, 1, rsiArr) < 1) return;
   if(atrArr[0] < InpMinATR) return;

   double close1 = iClose(_Symbol, PERIOD_H1, 1);
   double open1  = iOpen(_Symbol, PERIOD_H1, 1);
   double body1  = MathAbs(close1 - open1);
   bool bullish  = close1 > open1;

   double totalBody = 0;
   for(int i = 2; i <= InpSM_BodyLookback + 1; i++)
      totalBody += MathAbs(iClose(_Symbol, PERIOD_H1, i) - iOpen(_Symbol, PERIOD_H1, i));
   double avgBody = totalBody / InpSM_BodyLookback;
   if(avgBody <= 0 || body1 < avgBody * InpSM_BodyMult) return;

   if(bullish && close1 > emaArr[0] && rsiArr[0] < InpSM_RSIOB)
   {
      smPendingSignal = 1;
      smPendingATR = atrArr[0];
   }
   else if(!bullish && close1 < emaArr[0] && rsiArr[0] > InpSM_RSIOS)
   {
      smPendingSignal = -1;
      smPendingATR = atrArr[0];
   }
}

//+------------------------------------------------------------------+
void OnTick()
{
   datetime currentBarTime = iTime(_Symbol, PERIOD_H1, 0);
   bool newBar = (currentBarTime != gmLastBar);

   // Regime detection: check ADX for trend strength
   double adxVal = GetADX();
   bool strongTrend = (adxVal > InpADXThreshold);
   bool smEnabled = !strongTrend;  // Disable SM in strong trends

   if(newBar && adxVal > 0)
   {
      string regime = strongTrend ? "TREND (GM only)" : "RANGE (GM + SM)";
      Print("Regime: ", regime, " ADX=", adxVal);
   }

   // GaussMACD always runs
   RunGaussMACD(newBar);

   // SessionMomentum only in ranging/weak markets
   RunSessionMomentum(newBar, smEnabled);

   if(newBar)
   {
      gmLastBar = currentBarTime;
      smLastBar = currentBarTime;
   }
}
//+------------------------------------------------------------------+
