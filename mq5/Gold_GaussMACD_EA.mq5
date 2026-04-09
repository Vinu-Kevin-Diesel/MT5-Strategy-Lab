//+------------------------------------------------------------------+
//|                                          Gold_GaussMACD_EA.mq5   |
//|                                    Gaussian Trend + MACD Momentum |
//|                                                                    |
//|  v4.2: Optimized params (243 combos tested, best Sharpe)           |
//|                                                                    |
//|  Strategy: Gaussian filter (100-period, 4-pole) for smooth trend  |
//|  direction + MACD histogram turn for momentum confirmation +       |
//|  RSI filter to avoid overbought buys / oversold sells.            |
//|  ATR-based SL/TP with MAX RISK CAP to prevent oversized losses.   |
//|  Fixed lot sizing for $1000 account.                               |
//|                                                                    |
//|  Designed for: Pepperstone UAE Standard, $1000, 1:20 leverage     |
//|  Symbol: XAUUSD.a  |  Timeframe: H1                               |
//+------------------------------------------------------------------+
#property copyright "Claude EA Generator"
#property version   "4.20"
#property strict

//--- Input parameters
input int    InpGaussPeriod   = 100;       // Gaussian Filter Period (optimized)
input int    InpGaussPoles    = 4;         // Gaussian Filter Poles (1-4)
input int    InpMACDFast      = 12;        // MACD Fast EMA
input int    InpMACDSlow      = 26;        // MACD Slow EMA
input int    InpMACDSignal    = 9;         // MACD Signal Period
input int    InpATRPeriod     = 14;        // ATR Period
input int    InpRSIPeriod     = 14;        // RSI Period
input double InpSLMult        = 2.5;       // SL Multiplier (x ATR)
input double InpTPMult        = 5.0;       // TP Multiplier (x ATR) (optimized)
input double InpFixedLot      = 0.01;      // Fixed lot size
input double InpMaxRiskPct   = 5.0;       // Max risk % per trade (fallback if MaxSL=0)
input double InpMaxSLDollars = 60;        // Max SL in $ (0=use MaxRiskPct instead) (optimized)
input int    InpSessionStart  = 7;         // Session Start Hour (UTC)
input int    InpSessionEnd    = 20;        // Session End Hour (UTC)
input double InpMinATR        = 0.50;      // Minimum ATR filter ($)
input double InpRSIOB         = 80.0;      // RSI Overbought (skip buy above) (optimized)
input double InpRSIOS         = 20.0;      // RSI Oversold (skip sell below) (optimized)
input bool   InpUseRSIFilter  = true;      // Enable RSI filter
input int    InpMagic         = 889900;    // Magic Number

//--- Global variables
int    hMACD;
int    hATR;
int    hRSI;
datetime lastBarTime;

// Signal state: detect on bar close, execute on next bar open
int    pendingSignal;    // 0=none, 1=buy, -1=sell
double pendingATR;

//+------------------------------------------------------------------+
//| Expert initialization                                              |
//+------------------------------------------------------------------+
int OnInit()
{
   hMACD = iMACD(_Symbol, PERIOD_H1, InpMACDFast, InpMACDSlow, InpMACDSignal, PRICE_CLOSE);
   if(hMACD == INVALID_HANDLE)
   {
      Print("Failed to create MACD handle");
      return(INIT_FAILED);
   }

   hATR = iATR(_Symbol, PERIOD_H1, InpATRPeriod);
   if(hATR == INVALID_HANDLE)
   {
      Print("Failed to create ATR handle");
      return(INIT_FAILED);
   }

   hRSI = iRSI(_Symbol, PERIOD_H1, InpRSIPeriod, PRICE_CLOSE);
   if(hRSI == INVALID_HANDLE)
   {
      Print("Failed to create RSI handle");
      return(INIT_FAILED);
   }

   lastBarTime = 0;
   pendingSignal = 0;

   Print("Gold_GaussMACD_EA v4.1 initialized");
   Print("Lot=", InpFixedLot, " SL=", InpSLMult, "xATR  TP=", InpTPMult, "xATR");
   Print("MaxRisk=", InpMaxRiskPct, "% per trade (caps SL distance)");
   Print("RSI Filter=", InpUseRSIFilter, " OB=", InpRSIOB, " OS=", InpRSIOS);

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                            |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(hMACD != INVALID_HANDLE) IndicatorRelease(hMACD);
   if(hATR  != INVALID_HANDLE) IndicatorRelease(hATR);
   if(hRSI  != INVALID_HANDLE) IndicatorRelease(hRSI);
}

//+------------------------------------------------------------------+
//| Compute Gaussian Filter value                                      |
//+------------------------------------------------------------------+
double ComputeGaussianFilter(int shift)
{
   int totalBars = iBars(_Symbol, PERIOD_H1);
   int barsNeeded = MathMin(totalBars - shift, 5000);
   if(barsNeeded < InpGaussPeriod * 3)
      return 0;

   double closes[];
   ArraySetAsSeries(closes, false);
   if(CopyClose(_Symbol, PERIOD_H1, shift, barsNeeded, closes) < barsNeeded)
      return 0;

   double beta = (1.0 - MathCos(2.0 * M_PI / InpGaussPeriod)) / (MathPow(2.0, 1.0 / InpGaussPoles) - 1.0);
   double alpha = -beta + MathSqrt(beta * beta + 2.0 * beta);

   double result[];
   ArrayResize(result, barsNeeded);
   ArrayCopy(result, closes);

   for(int p = 0; p < InpGaussPoles; p++)
   {
      double buf[];
      ArrayResize(buf, barsNeeded);
      buf[0] = result[0];
      for(int j = 1; j < barsNeeded; j++)
      {
         buf[j] = alpha * result[j] + (1.0 - alpha) * buf[j - 1];
      }
      ArrayCopy(result, buf);
   }

   return result[barsNeeded - 1];
}

//+------------------------------------------------------------------+
//| Check if we have an open position with our magic number           |
//+------------------------------------------------------------------+
bool HasOpenPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
      {
         if(PositionGetInteger(POSITION_MAGIC) == InpMagic &&
            PositionGetString(POSITION_SYMBOL) == _Symbol)
            return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Check margin and open trade                                        |
//+------------------------------------------------------------------+
bool OpenTrade(ENUM_ORDER_TYPE orderType, double sl, double tp, double lotSize, string comment)
{
   if(lotSize <= 0)
      return false;

   // Margin safety check
   double freeM = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   long lev = AccountInfoInteger(ACCOUNT_LEVERAGE);
   double price = (orderType == ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                                                  : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double marginNeeded = price * lotSize * 100.0 / lev;
   if(marginNeeded > freeM * 0.80)
   {
      Print("SKIP: Not enough margin. Need $", marginNeeded, " Free=$", freeM);
      return false;
   }

   MqlTradeRequest request = {};
   MqlTradeResult  result  = {};

   request.action    = TRADE_ACTION_DEAL;
   request.symbol    = _Symbol;
   request.volume    = lotSize;
   request.type      = orderType;
   request.price     = price;
   request.sl        = NormalizeDouble(sl, _Digits);
   request.tp        = NormalizeDouble(tp, _Digits);
   request.deviation = 30;
   request.magic     = InpMagic;
   request.comment   = comment;
   request.type_filling = ORDER_FILLING_IOC;

   if(!OrderSend(request, result))
   {
      Print("OrderSend failed: ", GetLastError(), " RetCode=", result.retcode);
      return false;
   }

   if(result.retcode == TRADE_RETCODE_DONE || result.retcode == TRADE_RETCODE_PLACED)
   {
      Print("Trade opened: ", comment, " Lot=", lotSize, " Price=", result.price,
            " SL=", sl, " TP=", tp);
      return true;
   }

   Print("Trade failed: RetCode=", result.retcode);
   return false;
}

//+------------------------------------------------------------------+
//| Expert tick function                                               |
//+------------------------------------------------------------------+
void OnTick()
{
   // Detect new H1 bar
   datetime currentBarTime = iTime(_Symbol, PERIOD_H1, 0);
   bool newBar = (currentBarTime != lastBarTime);

   //--- STEP 1: Execute pending signal at bar open
   if(newBar && pendingSignal != 0 && !HasOpenPosition())
   {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double slDist = pendingATR * InpSLMult;
      double tpDist = pendingATR * InpTPMult;

      //--- MAX RISK CAP: limit SL distance so loss doesn't exceed X% of equity
      //    At 0.01 lot XAUUSD (1 oz): $1 move = $1 loss
      //    So slDist in $ = max loss per trade at 0.01 lot
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      double maxSL = 0;
      if(InpMaxSLDollars > 0)
         maxSL = InpMaxSLDollars;
      else
         maxSL = equity * InpMaxRiskPct / 100.0 / (InpFixedLot * 100.0);
      // maxSL is now the max price distance allowed for SL

      if(slDist > maxSL)
      {
         Print("Risk cap: SL $", slDist, " capped to $", maxSL,
               " (", InpMaxRiskPct, "% of $", equity, ")");
         // Adjust TP proportionally to maintain R:R ratio
         double ratio = InpTPMult / InpSLMult;
         slDist = maxSL;
         tpDist = slDist * ratio;
      }

      if(pendingSignal == 1)
      {
         double sl = ask - slDist;
         double tp = ask + tpDist;
         OpenTrade(ORDER_TYPE_BUY, sl, tp, InpFixedLot, "GaussMACD_Buy");
      }
      else if(pendingSignal == -1)
      {
         double sl = bid + slDist;
         double tp = bid - tpDist;
         OpenTrade(ORDER_TYPE_SELL, sl, tp, InpFixedLot, "GaussMACD_Sell");
      }
      pendingSignal = 0;
   }

   if(!newBar)
      return;
   lastBarTime = currentBarTime;

   //--- STEP 2: Check for new signals
   if(HasOpenPosition())
   {
      pendingSignal = 0;
      return;
   }

   // Session filter
   MqlDateTime dt;
   datetime prevBarTime = iTime(_Symbol, PERIOD_H1, 1);
   TimeToStruct(prevBarTime, dt);
   if(dt.hour < InpSessionStart || dt.hour >= InpSessionEnd)
      return;

   // MACD histogram (buffer 0 = MACD line, buffer 1 = signal line)
   double macdMainArr[2], macdSigArr[2];
   if(CopyBuffer(hMACD, 0, 1, 2, macdMainArr) < 2) return;
   if(CopyBuffer(hMACD, 1, 1, 2, macdSigArr) < 2) return;

   double macdHist_now  = macdMainArr[1] - macdSigArr[1];
   double macdHist_prev = macdMainArr[0] - macdSigArr[0];

   // ATR
   double atrArr[1];
   if(CopyBuffer(hATR, 0, 1, 1, atrArr) < 1) return;
   double atrVal = atrArr[0];

   if(atrVal < InpMinATR)
      return;

   // RSI
   double rsiArr[1];
   double rsiVal = 50.0;  // default neutral
   if(InpUseRSIFilter)
   {
      if(CopyBuffer(hRSI, 0, 1, 1, rsiArr) < 1) return;
      rsiVal = rsiArr[0];
   }

   // Gaussian filter
   double gf_now  = ComputeGaussianFilter(1);
   double gf_prev = ComputeGaussianFilter(2);

   if(gf_now == 0 || gf_prev == 0)
      return;

   double close1 = iClose(_Symbol, PERIOD_H1, 1);

   bool gfRising  = (gf_now > gf_prev);
   bool gfFalling = (gf_now < gf_prev);
   bool macdTurningUp   = (macdHist_now > macdHist_prev) && (macdHist_now > -0.5);
   bool macdTurningDown = (macdHist_now < macdHist_prev) && (macdHist_now < 0.5);

   //--- Generate BUY signal
   if(gfRising && macdTurningUp && close1 > gf_now)
   {
      // RSI filter: skip if already overbought
      if(InpUseRSIFilter && rsiVal > InpRSIOB)
      {
         Print("BUY skipped: RSI=", rsiVal, " > ", InpRSIOB, " (overbought)");
         return;
      }

      pendingSignal = 1;
      pendingATR = atrVal;
      Print("BUY signal. GF=", gf_now, " Close=", close1, " ATR=", atrVal, " RSI=", rsiVal);
   }
   //--- Generate SELL signal
   else if(gfFalling && macdTurningDown && close1 < gf_now)
   {
      // RSI filter: skip if already oversold
      if(InpUseRSIFilter && rsiVal < InpRSIOS)
      {
         Print("SELL skipped: RSI=", rsiVal, " < ", InpRSIOS, " (oversold)");
         return;
      }

      pendingSignal = -1;
      pendingATR = atrVal;
      Print("SELL signal. GF=", gf_now, " Close=", close1, " ATR=", atrVal, " RSI=", rsiVal);
   }
}
//+------------------------------------------------------------------+
