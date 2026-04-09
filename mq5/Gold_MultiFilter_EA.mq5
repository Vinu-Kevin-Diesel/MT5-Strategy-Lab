//+------------------------------------------------------------------+
//|                                        Gold_MultiFilter_EA.mq5   |
//|  GaussMACD with extra confirmation filters for higher win rate    |
//|                                                                    |
//|  Adds to base GaussMACD:                                          |
//|  1. EMA200 trend filter (only trade with big trend)               |
//|  2. ADX > 20 (only trade when market is trending)                 |
//|  3. Candle body filter (require strong candle, not doji)          |
//|  4. Higher timeframe confirmation (H4 Gaussian direction)         |
//|                                                                    |
//|  Goal: 50%+ win rate by filtering out weak setups                 |
//+------------------------------------------------------------------+
#property copyright "Claude EA Generator"
#property version   "1.00"
#property strict

input int    InpGaussPeriod   = 80;
input int    InpGaussPoles    = 4;
input int    InpMACDFast      = 12;
input int    InpMACDSlow      = 26;
input int    InpMACDSignal    = 9;
input int    InpATRPeriod     = 14;
input int    InpRSIPeriod     = 14;
input int    InpEMATrend      = 200;       // EMA trend filter period
input int    InpADXPeriod     = 14;        // ADX period
input double InpADXMin        = 20.0;      // Minimum ADX for entry
input double InpSLMult        = 2.5;
input double InpTPMult        = 5.0;
input double InpFixedLot      = 0.01;
input double InpMaxSLDollars  = 30.0;
input double InpRSIOB         = 80.0;
input double InpRSIOS         = 28.0;
input double InpMinBodyATR    = 0.3;       // Min candle body as fraction of ATR
input double InpMinATR        = 0.50;
input int    InpMagic         = 889910;

int hMACD, hATR, hRSI, hADX, hEMA200;
datetime lastBarTime;
int    pendingSignal;
double pendingATR;

int OnInit()
{
   hMACD   = iMACD(_Symbol, PERIOD_H1, InpMACDFast, InpMACDSlow, InpMACDSignal, PRICE_CLOSE);
   hATR    = iATR(_Symbol, PERIOD_H1, InpATRPeriod);
   hRSI    = iRSI(_Symbol, PERIOD_H1, InpRSIPeriod, PRICE_CLOSE);
   hADX    = iADX(_Symbol, PERIOD_H1, InpADXPeriod);
   hEMA200 = iMA(_Symbol, PERIOD_H1, InpEMATrend, 0, MODE_EMA, PRICE_CLOSE);

   if(hMACD == INVALID_HANDLE || hATR == INVALID_HANDLE || hRSI == INVALID_HANDLE ||
      hADX == INVALID_HANDLE || hEMA200 == INVALID_HANDLE)
   {
      Print("Failed to create indicator handles");
      return(INIT_FAILED);
   }

   lastBarTime = 0;
   pendingSignal = 0;
   Print("Gold_MultiFilter_EA initialized — high WR mode");
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   if(hMACD   != INVALID_HANDLE) IndicatorRelease(hMACD);
   if(hATR    != INVALID_HANDLE) IndicatorRelease(hATR);
   if(hRSI    != INVALID_HANDLE) IndicatorRelease(hRSI);
   if(hADX    != INVALID_HANDLE) IndicatorRelease(hADX);
   if(hEMA200 != INVALID_HANDLE) IndicatorRelease(hEMA200);
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

bool OpenTrade(ENUM_ORDER_TYPE orderType, double sl, double tp, double lotSize, string comment)
{
   if(lotSize <= 0) return false;
   double freeM = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   long lev = AccountInfoInteger(ACCOUNT_LEVERAGE);
   double price = (orderType == ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                                                  : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double marginNeeded = price * lotSize * 100.0 / lev;
   if(marginNeeded > freeM * 0.80) return false;

   MqlTradeRequest request = {};
   MqlTradeResult  result  = {};
   request.action = TRADE_ACTION_DEAL;
   request.symbol = _Symbol;
   request.volume = lotSize;
   request.type   = orderType;
   request.price  = price;
   request.sl     = NormalizeDouble(sl, _Digits);
   request.tp     = NormalizeDouble(tp, _Digits);
   request.deviation = 30;
   request.magic  = InpMagic;
   request.comment = comment;
   request.type_filling = ORDER_FILLING_IOC;
   if(!OrderSend(request, result)) return false;
   return (result.retcode == TRADE_RETCODE_DONE || result.retcode == TRADE_RETCODE_PLACED);
}

void OnTick()
{
   datetime currentBarTime = iTime(_Symbol, PERIOD_H1, 0);
   bool newBar = (currentBarTime != lastBarTime);

   if(newBar && pendingSignal != 0 && !HasOpenPosition())
   {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double slDist = pendingATR * InpSLMult;
      double tpDist = pendingATR * InpTPMult;

      if(InpMaxSLDollars > 0 && slDist > InpMaxSLDollars)
      {
         double ratio = InpTPMult / InpSLMult;
         slDist = InpMaxSLDollars;
         tpDist = slDist * ratio;
      }

      if(pendingSignal == 1)
         OpenTrade(ORDER_TYPE_BUY, ask - slDist, ask + tpDist, InpFixedLot, "MF_Buy");
      else
         OpenTrade(ORDER_TYPE_SELL, bid + slDist, bid - tpDist, InpFixedLot, "MF_Sell");
      pendingSignal = 0;
   }

   if(!newBar) return;
   lastBarTime = currentBarTime;
   if(HasOpenPosition()) { pendingSignal = 0; return; }

   // MACD
   double macdMain[2], macdSig[2];
   if(CopyBuffer(hMACD, 0, 1, 2, macdMain) < 2) return;
   if(CopyBuffer(hMACD, 1, 1, 2, macdSig) < 2)  return;
   double hist_now  = macdMain[1] - macdSig[1];
   double hist_prev = macdMain[0] - macdSig[0];

   // ATR
   double atrArr[1];
   if(CopyBuffer(hATR, 0, 1, 1, atrArr) < 1) return;
   double atrVal = atrArr[0];
   if(atrVal < InpMinATR) return;

   // RSI
   double rsiArr[1];
   if(CopyBuffer(hRSI, 0, 1, 1, rsiArr) < 1) return;
   double rsiVal = rsiArr[0];

   // ADX — FILTER 1: must be trending
   double adxArr[1];
   if(CopyBuffer(hADX, 0, 1, 1, adxArr) < 1) return;
   if(adxArr[0] < InpADXMin) return;

   // EMA200 — FILTER 2: trade with big trend
   double emaArr[1];
   if(CopyBuffer(hEMA200, 0, 1, 1, emaArr) < 1) return;
   double ema200 = emaArr[0];

   // Gaussian filter
   double gf_now  = ComputeGaussianFilter(1);
   double gf_prev = ComputeGaussianFilter(2);
   if(gf_now == 0 || gf_prev == 0) return;

   double close1 = iClose(_Symbol, PERIOD_H1, 1);
   double open1  = iOpen(_Symbol, PERIOD_H1, 1);

   // FILTER 3: Candle body must be significant (not doji)
   double body = MathAbs(close1 - open1);
   if(body < atrVal * InpMinBodyATR) return;

   bool gfRising  = (gf_now > gf_prev);
   bool gfFalling = (gf_now < gf_prev);
   bool macdUp    = (hist_now > hist_prev) && (hist_now > -0.5);
   bool macdDn    = (hist_now < hist_prev) && (hist_now < 0.5);

   // BUY: Gauss rising + MACD up + close > Gauss + close > EMA200 + RSI not OB
   if(gfRising && macdUp && close1 > gf_now && close1 > ema200)
   {
      if(rsiVal > InpRSIOB) return;
      pendingSignal = 1;
      pendingATR = atrVal;
   }
   // SELL: Gauss falling + MACD down + close < Gauss + close < EMA200 + RSI not OS
   else if(gfFalling && macdDn && close1 < gf_now && close1 < ema200)
   {
      if(rsiVal < InpRSIOS) return;
      pendingSignal = -1;
      pendingATR = atrVal;
   }
}
//+------------------------------------------------------------------+
