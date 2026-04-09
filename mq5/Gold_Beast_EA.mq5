//+------------------------------------------------------------------+
//|                                           Gold_Beast_EA.mq5      |
//|                    Maximum Profit Gold Strategy                     |
//|                                                                    |
//|  Concept: Ride EVERY trend move with re-entry.                    |
//|  - Gaussian filter for trend direction                             |
//|  - Enter on ANY pullback in trend direction                        |
//|  - Re-enter immediately after TP hit (don't wait for new signal)  |
//|  - Wide TP (5x ATR) catches big swings                            |
//|  - Tight SL (1.5x ATR) cuts losers fast                           |
//|  - 24/7 trading, no session filter                                 |
//|  - After SL hit, wait for fresh signal (no revenge trading)       |
//|                                                                    |
//|  Symbol: XAUUSD.a  |  Timeframe: H1                               |
//+------------------------------------------------------------------+
#property copyright "Claude EA Generator"
#property version   "1.00"
#property strict

input int    InpGaussPeriod   = 80;
input int    InpGaussPoles    = 4;
input int    InpATRPeriod     = 14;
input int    InpRSIPeriod     = 14;
input int    InpFastEMA       = 21;        // Fast EMA for pullback detection
input int    InpSlowEMA       = 50;        // Slow EMA for trend
input double InpSLMult        = 1.5;       // Tight SL
input double InpTPMult        = 5.0;       // Wide TP
input double InpMaxSLDollars  = 30.0;
input double InpFixedLot      = 0.01;
input double InpMinATR        = 0.50;
input double InpRSIOB         = 80.0;
input double InpRSIOS         = 20.0;
input int    InpMagic         = 889960;

int hATR, hRSI, hEMAFast, hEMASlow;
datetime lastBarTime;
int pendingSignal;
double pendingATR;
bool lastTradeWasTP;       // Track if last trade was TP (for re-entry)
int lastTradeDir;          // Last trade direction for re-entry

int OnInit()
{
   hATR     = iATR(_Symbol, PERIOD_H1, InpATRPeriod);
   hRSI     = iRSI(_Symbol, PERIOD_H1, InpRSIPeriod, PRICE_CLOSE);
   hEMAFast = iMA(_Symbol, PERIOD_H1, InpFastEMA, 0, MODE_EMA, PRICE_CLOSE);
   hEMASlow = iMA(_Symbol, PERIOD_H1, InpSlowEMA, 0, MODE_EMA, PRICE_CLOSE);

   if(hATR == INVALID_HANDLE || hRSI == INVALID_HANDLE ||
      hEMAFast == INVALID_HANDLE || hEMASlow == INVALID_HANDLE)
      return INIT_FAILED;

   lastBarTime = 0;
   pendingSignal = 0;
   lastTradeWasTP = false;
   lastTradeDir = 0;

   Print("Gold_Beast_EA initialized — maximum profit mode");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(hATR     != INVALID_HANDLE) IndicatorRelease(hATR);
   if(hRSI     != INVALID_HANDLE) IndicatorRelease(hRSI);
   if(hEMAFast != INVALID_HANDLE) IndicatorRelease(hEMAFast);
   if(hEMASlow != INVALID_HANDLE) IndicatorRelease(hEMASlow);
}

bool HasOpenPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionGetInteger(POSITION_MAGIC) == InpMagic &&
         PositionGetString(POSITION_SYMBOL) == _Symbol)
         return true;
   }
   return false;
}

// Check last closed trade result
void CheckLastClosedTrade()
{
   // Look at recent deals to see if our last trade hit TP or SL
   HistorySelect(TimeCurrent() - 86400, TimeCurrent());
   int totalDeals = HistoryDealsTotal();
   for(int i = totalDeals - 1; i >= MathMax(0, totalDeals - 5); i--)
   {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket > 0 &&
         HistoryDealGetInteger(dealTicket, DEAL_MAGIC) == InpMagic &&
         HistoryDealGetString(dealTicket, DEAL_SYMBOL) == _Symbol &&
         HistoryDealGetInteger(dealTicket, DEAL_ENTRY) == DEAL_ENTRY_OUT)
      {
         double profit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
         string comment = HistoryDealGetString(dealTicket, DEAL_COMMENT);

         if(profit > 0 || StringFind(comment, "tp") >= 0)
         {
            lastTradeWasTP = true;
            // Get direction of the closed trade
            ENUM_DEAL_TYPE dealType = (ENUM_DEAL_TYPE)HistoryDealGetInteger(dealTicket, DEAL_TYPE);
            // Exit deal type is opposite of position direction
            lastTradeDir = (dealType == DEAL_TYPE_SELL) ? 1 : -1;  // If sold to close, was long
         }
         else
         {
            lastTradeWasTP = false;
            lastTradeDir = 0;
         }
         return;
      }
   }
}

double ComputeGaussianFilter(int shift)
{
   int totalBars = iBars(_Symbol, PERIOD_H1);
   int barsNeeded = MathMin(totalBars - shift, 5000);
   if(barsNeeded < InpGaussPeriod * 3) return 0;

   double closes[];
   ArraySetAsSeries(closes, false);
   if(CopyClose(_Symbol, PERIOD_H1, shift, barsNeeded, closes) < barsNeeded) return 0;

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
         buf[j] = alpha * result[j] + (1.0 - alpha) * buf[j - 1];
      ArrayCopy(result, buf);
   }
   return result[barsNeeded - 1];
}

bool OpenTrade(ENUM_ORDER_TYPE type, double sl, double tp, string comment)
{
   double freeM = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   long lev = AccountInfoInteger(ACCOUNT_LEVERAGE);
   double price = (type == ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                                             : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double marginNeeded = price * InpFixedLot * 100.0 / lev;
   if(marginNeeded > freeM * 0.80) return false;

   MqlTradeRequest req = {};
   MqlTradeResult  res = {};
   req.action = TRADE_ACTION_DEAL;
   req.symbol = _Symbol;
   req.volume = InpFixedLot;
   req.type = type;
   req.price = price;
   req.sl = NormalizeDouble(sl, _Digits);
   req.tp = NormalizeDouble(tp, _Digits);
   req.deviation = 30;
   req.magic = InpMagic;
   req.comment = comment;
   req.type_filling = ORDER_FILLING_IOC;

   if(!OrderSend(req, res)) return false;
   return (res.retcode == TRADE_RETCODE_DONE || res.retcode == TRADE_RETCODE_PLACED);
}

void OnTick()
{
   datetime currentBarTime = iTime(_Symbol, PERIOD_H1, 0);
   bool newBar = (currentBarTime != lastBarTime);

   // Execute pending signal
   if(newBar && pendingSignal != 0 && !HasOpenPosition())
   {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double slDist = pendingATR * InpSLMult;
      double tpDist = pendingATR * InpTPMult;

      if(slDist > InpMaxSLDollars)
      {
         double ratio = InpTPMult / InpSLMult;
         slDist = InpMaxSLDollars;
         tpDist = slDist * ratio;
      }

      if(pendingSignal == 1)
         OpenTrade(ORDER_TYPE_BUY, ask - slDist, ask + tpDist, "Beast_Buy");
      else
         OpenTrade(ORDER_TYPE_SELL, bid + slDist, bid - tpDist, "Beast_Sell");
      pendingSignal = 0;
   }

   if(!newBar) return;
   lastBarTime = currentBarTime;

   // Check if last trade hit TP (for re-entry logic)
   CheckLastClosedTrade();

   if(HasOpenPosition()) { pendingSignal = 0; return; }

   // Get indicators
   double atrArr[1];
   if(CopyBuffer(hATR, 0, 1, 1, atrArr) < 1) return;
   double atrVal = atrArr[0];
   if(atrVal < InpMinATR) return;

   double rsiArr[1];
   if(CopyBuffer(hRSI, 0, 1, 1, rsiArr) < 1) return;
   double rsiVal = rsiArr[0];

   double emaFastArr[2], emaSlowArr[2];
   if(CopyBuffer(hEMAFast, 0, 1, 2, emaFastArr) < 2) return;
   if(CopyBuffer(hEMASlow, 0, 1, 2, emaSlowArr) < 2) return;

   double gfNow  = ComputeGaussianFilter(1);
   double gfPrev = ComputeGaussianFilter(2);
   if(gfNow == 0 || gfPrev == 0) return;

   double close1 = iClose(_Symbol, PERIOD_H1, 1);
   double close2 = iClose(_Symbol, PERIOD_H1, 2);
   double open1  = iOpen(_Symbol, PERIOD_H1, 1);

   bool gfRising  = (gfNow > gfPrev);
   bool gfFalling = (gfNow < gfPrev);
   bool emaUptrend = (emaFastArr[1] > emaSlowArr[1]);
   bool emaDntrend = (emaFastArr[1] < emaSlowArr[1]);

   //=== RE-ENTRY AFTER TP ===
   // If last trade hit TP and trend hasn't changed, re-enter immediately
   if(lastTradeWasTP && lastTradeDir != 0)
   {
      if(lastTradeDir == 1 && gfRising && emaUptrend && rsiVal < InpRSIOB)
      {
         pendingSignal = 1;
         pendingATR = atrVal;
         lastTradeWasTP = false;
         Print("RE-ENTRY BUY after TP. Trend still up.");
         return;
      }
      else if(lastTradeDir == -1 && gfFalling && emaDntrend && rsiVal > InpRSIOS)
      {
         pendingSignal = -1;
         pendingATR = atrVal;
         lastTradeWasTP = false;
         Print("RE-ENTRY SELL after TP. Trend still down.");
         return;
      }
      lastTradeWasTP = false;  // Trend changed, no re-entry
   }

   //=== FRESH SIGNAL ===
   // Pullback entry: price dips to fast EMA in uptrend, or rallies to fast EMA in downtrend

   // BUY: Gaussian rising + EMA uptrend + price pulled back near fast EMA + RSI not OB
   if(gfRising && emaUptrend && close1 > gfNow)
   {
      // Pullback condition: low of bar touched or came near fast EMA
      double low1 = iLow(_Symbol, PERIOD_H1, 1);
      double emaFastVal = emaFastArr[1];
      double pullbackDist = MathAbs(low1 - emaFastVal);

      // Price pulled back to within 1x ATR of fast EMA
      if(pullbackDist < atrVal * 1.5 && close1 > open1)  // Bullish bar after pullback
      {
         if(rsiVal > InpRSIOB) return;  // Skip overbought

         pendingSignal = 1;
         pendingATR = atrVal;
         Print("BEAST BUY: Pullback to EMA", InpFastEMA, " GF rising, RSI=", rsiVal);
      }
   }
   // SELL: Gaussian falling + EMA downtrend + price bounced near fast EMA + RSI not OS
   else if(gfFalling && emaDntrend && close1 < gfNow)
   {
      double high1 = iHigh(_Symbol, PERIOD_H1, 1);
      double emaFastVal = emaFastArr[1];
      double pullbackDist = MathAbs(high1 - emaFastVal);

      if(pullbackDist < atrVal * 1.5 && close1 < open1)  // Bearish bar after bounce
      {
         if(rsiVal < InpRSIOS) return;

         pendingSignal = -1;
         pendingATR = atrVal;
         Print("BEAST SELL: Bounce to EMA", InpFastEMA, " GF falling, RSI=", rsiVal);
      }
   }
}
//+------------------------------------------------------------------+
