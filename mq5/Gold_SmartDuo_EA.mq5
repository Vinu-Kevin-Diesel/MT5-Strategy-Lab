//+------------------------------------------------------------------+
//|                                        Gold_SmartDuo_EA.mq5      |
//|             2-Strategy Portfolio: Trend + Mean Reversion            |
//|                                                                    |
//|  GOAL: Portfolio-level profit with LOWER drawdown.                 |
//|  Only 2 uncorrelated strategies instead of 4 correlated ones.      |
//|                                                                    |
//|  Strategy 1: MULTIFILTER (Trend)                                   |
//|  Gaussian + MACD + EMA200 + ADX + Body filter                     |
//|  Catches big trend moves. Works great in trending markets.         |
//|  Magic: 889910                                                     |
//|                                                                    |
//|  Strategy 2: GAUSS CHANNEL BOUNCE (Mean Reversion)                 |
//|  Gaussian center + ATR bands. Buy dips to lower band in uptrend.  |
//|  Catches pullbacks that MultiFilter misses. Tighter TP.            |
//|  Magic: 889955                                                     |
//|                                                                    |
//|  REGIME FILTER: Simple ADX check                                   |
//|  ADX < 12 = dead market (no volatility) = NO TRADING              |
//|  This avoids the 2022-2023 choppy period.                          |
//|                                                                    |
//|  Symbol: XAUUSD.a  |  Timeframe: H1                               |
//+------------------------------------------------------------------+
#property copyright "Claude EA Generator"
#property version   "1.00"
#property strict

//=== SHARED ===
input double InpFixedLot       = 0.01;
input double InpMaxSLDollars   = 30.0;
input double InpMinATR         = 0.50;
input double InpDeadMarketADX  = 12.0;     // ADX below this = dead market, no trading

//=== MULTIFILTER (Trend) ===
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

//=== GAUSS CHANNEL BOUNCE (Mean Reversion) ===
input int    InpCH_GaussPeriod = 80;
input int    InpCH_GaussPoles  = 4;
input double InpCH_BandMult    = 1.5;      // ATR band width
input double InpCH_SLMult      = 1.5;
input double InpCH_TPMult      = 2.5;
input double InpCH_RSIOB       = 75.0;
input double InpCH_RSIOS       = 25.0;
input int    InpCH_Magic       = 889955;

//=== GLOBALS ===
int hATR, hRSI, hMACD, hEMA200, hADX;
datetime lastBarTime;

int    mfPending;   double mfATR;
int    chPending;   double chATR;

double startBalance;

//+------------------------------------------------------------------+
int OnInit()
{
   hATR    = iATR(_Symbol, PERIOD_H1, 14);
   hRSI    = iRSI(_Symbol, PERIOD_H1, 14, PRICE_CLOSE);
   hMACD   = iMACD(_Symbol, PERIOD_H1, 12, 26, 9, PRICE_CLOSE);
   hEMA200 = iMA(_Symbol, PERIOD_H1, InpMF_EMATrend, 0, MODE_EMA, PRICE_CLOSE);
   hADX    = iADX(_Symbol, PERIOD_H1, 14);

   if(hATR == INVALID_HANDLE || hRSI == INVALID_HANDLE || hMACD == INVALID_HANDLE ||
      hEMA200 == INVALID_HANDLE || hADX == INVALID_HANDLE)
      return INIT_FAILED;

   lastBarTime = 0;
   mfPending = 0; chPending = 0;
   startBalance = AccountInfoDouble(ACCOUNT_BALANCE);

   CreateDashboard();
   Print("Gold_SmartDuo_EA initialized | DeadMarketADX=", InpDeadMarketADX);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(hATR    != INVALID_HANDLE) IndicatorRelease(hATR);
   if(hRSI    != INVALID_HANDLE) IndicatorRelease(hRSI);
   if(hMACD   != INVALID_HANDLE) IndicatorRelease(hMACD);
   if(hEMA200 != INVALID_HANDLE) IndicatorRelease(hEMA200);
   if(hADX    != INVALID_HANDLE) IndicatorRelease(hADX);
   ObjectsDeleteAll(0, "SD_");
}

//+------------------------------------------------------------------+
bool HasPosition(int magic)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionGetInteger(POSITION_MAGIC) == magic &&
         PositionGetString(POSITION_SYMBOL) == _Symbol) return true;
   }
   return false;
}

bool OpenTrade(ENUM_ORDER_TYPE type, double sl, double tp, int magic, string comment)
{
   double freeM = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   long lev = AccountInfoInteger(ACCOUNT_LEVERAGE);
   double price = (type == ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                                             : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(price * InpFixedLot * 100.0 / lev > freeM * 0.80) return false;

   MqlTradeRequest req = {}; MqlTradeResult res = {};
   req.action = TRADE_ACTION_DEAL; req.symbol = _Symbol; req.volume = InpFixedLot;
   req.type = type; req.price = price;
   req.sl = NormalizeDouble(sl, _Digits); req.tp = NormalizeDouble(tp, _Digits);
   req.deviation = 30; req.magic = magic; req.comment = comment;
   req.type_filling = ORDER_FILLING_IOC;
   if(!OrderSend(req, res)) return false;
   if(res.retcode == TRADE_RETCODE_DONE || res.retcode == TRADE_RETCODE_PLACED)
   { Print(comment, " P=", res.price, " SL=", sl, " TP=", tp); return true; }
   return false;
}

void ApplyRiskCap(double &slDist, double &tpDist, double slMult, double tpMult)
{
   if(InpMaxSLDollars > 0 && slDist > InpMaxSLDollars)
   {
      double ratio = tpMult / slMult;
      slDist = InpMaxSLDollars;
      tpDist = slDist * ratio;
   }
}

void ExecutePending(int &signal, double &atr, double slMult, double tpMult, int magic, string prefix)
{
   if(signal == 0 || HasPosition(magic)) { signal = 0; return; }
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double slDist = atr * slMult;
   double tpDist = atr * tpMult;
   ApplyRiskCap(slDist, tpDist, slMult, tpMult);
   if(signal == 1)
      OpenTrade(ORDER_TYPE_BUY, ask - slDist, ask + tpDist, magic, prefix + "_Buy");
   else
      OpenTrade(ORDER_TYPE_SELL, bid + slDist, bid - tpDist, magic, prefix + "_Sell");
   signal = 0;
}

//+------------------------------------------------------------------+
double ComputeGaussian(int period, int poles, int shift)
{
   int totalBars = iBars(_Symbol, PERIOD_H1);
   int barsNeeded = MathMin(totalBars - shift, 5000);
   if(barsNeeded < period * 3) return 0;
   double closes[];
   ArraySetAsSeries(closes, false);
   if(CopyClose(_Symbol, PERIOD_H1, shift, barsNeeded, closes) < barsNeeded) return 0;
   double beta = (1.0 - MathCos(2.0 * M_PI / period)) / (MathPow(2.0, 1.0 / poles) - 1.0);
   double alpha = -beta + MathSqrt(beta * beta + 2.0 * beta);
   double result[];
   ArrayResize(result, barsNeeded); ArrayCopy(result, closes);
   for(int p = 0; p < poles; p++)
   {
      double buf[]; ArrayResize(buf, barsNeeded); buf[0] = result[0];
      for(int j = 1; j < barsNeeded; j++)
         buf[j] = alpha * result[j] + (1.0 - alpha) * buf[j - 1];
      ArrayCopy(result, buf);
   }
   return result[barsNeeded - 1];
}

//+------------------------------------------------------------------+
//|  STRATEGY 1: MULTIFILTER (Trend Following)                         |
//+------------------------------------------------------------------+
void RunMultiFilter(double atrVal, double rsiVal, double adxVal,
                    double ema200, double close1, double open1,
                    double macdHist, double macdHistPrev,
                    double gfNow, double gfPrev)
{
   double body = MathAbs(close1 - open1);
   if(adxVal < InpMF_ADXMin) return;
   if(body < atrVal * InpMF_MinBodyATR) return;

   bool gfRising = (gfNow > gfPrev);
   bool gfFalling = (gfNow < gfPrev);
   bool macdUp = (macdHist > macdHistPrev) && (macdHist > -0.5);
   bool macdDn = (macdHist < macdHistPrev) && (macdHist < 0.5);

   if(gfRising && macdUp && close1 > gfNow && close1 > ema200 && rsiVal < InpMF_RSIOB)
   { mfPending = 1; mfATR = atrVal; }
   else if(gfFalling && macdDn && close1 < gfNow && close1 < ema200 && rsiVal > InpMF_RSIOS)
   { mfPending = -1; mfATR = atrVal; }
}

//+------------------------------------------------------------------+
//|  STRATEGY 2: GAUSS CHANNEL BOUNCE (Mean Reversion)                 |
//|  Buy when price touches lower Gaussian band in uptrend             |
//|  Sell when price touches upper Gaussian band in downtrend          |
//+------------------------------------------------------------------+
void RunChannelBounce(double atrVal, double rsiVal, double close1,
                      double low1, double high1,
                      double gfNow, double gfPrev)
{
   double upperBand = gfNow + atrVal * InpCH_BandMult;
   double lowerBand = gfNow - atrVal * InpCH_BandMult;

   bool trendUp = (gfNow > gfPrev) && (close1 > gfNow);
   bool trendDn = (gfNow < gfPrev) && (close1 < gfNow);

   // BUY: Uptrend + price dipped to lower band + bounced (bullish bar)
   if(trendUp && low1 <= lowerBand + atrVal * 0.3 && close1 > low1 && rsiVal < InpCH_RSIOB)
   {
      chPending = 1; chATR = atrVal;
      Print("Channel BUY: Bounce off lower band=", lowerBand, " Close=", close1);
   }
   // SELL: Downtrend + price rallied to upper band + rejected (bearish bar)
   else if(trendDn && high1 >= upperBand - atrVal * 0.3 && close1 < high1 && rsiVal > InpCH_RSIOS)
   {
      chPending = -1; chATR = atrVal;
      Print("Channel SELL: Bounce off upper band=", upperBand, " Close=", close1);
   }
}

//+------------------------------------------------------------------+
//|  DASHBOARD                                                         |
//+------------------------------------------------------------------+
void CreateLabel(string name, int x, int y, string text, color clr, int fs=9)
{
   string obj = "SD_" + name;
   ObjectCreate(0, obj, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, obj, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, obj, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, obj, OBJPROP_YDISTANCE, y);
   ObjectSetString(0, obj, OBJPROP_TEXT, text);
   ObjectSetString(0, obj, OBJPROP_FONT, "Consolas");
   ObjectSetInteger(0, obj, OBJPROP_FONTSIZE, fs);
   ObjectSetInteger(0, obj, OBJPROP_COLOR, clr);
}
void UpdateLabel(string name, string text, color clr=clrNONE)
{
   string obj = "SD_" + name;
   ObjectSetString(0, obj, OBJPROP_TEXT, text);
   if(clr != clrNONE) ObjectSetInteger(0, obj, OBJPROP_COLOR, clr);
}

void CreateDashboard()
{
   int x = 15, y = 20, g = 18;
   CreateLabel("title", x, y, "SMART DUO EA", clrGold, 11); y += g+5;
   CreateLabel("sep1", x, y, "-----------------------------------", clrDimGray, 8); y += g;
   CreateLabel("regime", x, y, "Market: ---", clrWhite); y += g;
   CreateLabel("gauss", x, y, "Gaussian: ---", clrWhite); y += g;
   CreateLabel("adx", x, y, "ADX: ---", clrWhite); y += g;
   CreateLabel("rsi", x, y, "RSI: ---", clrWhite); y += g;
   CreateLabel("sep2", x, y, "-----------------------------------", clrDimGray, 8); y += g;
   CreateLabel("mf_pos", x, y, "Trend: ---", clrGray); y += g;
   CreateLabel("ch_pos", x, y, "MeanRev: ---", clrGray); y += g;
   CreateLabel("sep3", x, y, "-----------------------------------", clrDimGray, 8); y += g;
   CreateLabel("bal", x, y, "Balance: ---", clrWhite); y += g;
   CreateLabel("pl", x, y, "P/L: ---", clrWhite); y += g;
}

void UpdateDash(double adxVal, double rsiVal, double gfNow, double gfPrev, bool isDead)
{
   UpdateLabel("regime", isDead ? "Market: DEAD (no trade)" : "Market: ACTIVE",
               isDead ? clrOrangeRed : clrLime);
   UpdateLabel("gauss", StringFormat("Gaussian: %s (%.2f)", gfNow > gfPrev ? "UP" : "DOWN", gfNow),
               gfNow > gfPrev ? clrLime : clrOrangeRed);
   UpdateLabel("adx", StringFormat("ADX: %.1f %s", adxVal, adxVal > 20 ? "TREND" : (adxVal > 12 ? "WEAK" : "DEAD")),
               adxVal > 20 ? clrLime : (adxVal > 12 ? clrYellow : clrOrangeRed));
   UpdateLabel("rsi", StringFormat("RSI: %.1f", rsiVal),
               rsiVal > 70 ? clrOrangeRed : (rsiVal < 30 ? clrDodgerBlue : clrWhite));

   // Positions
   string mfText = HasPosition(InpMF_Magic) ? "Trend: OPEN" : "Trend: ---";
   string chText = HasPosition(InpCH_Magic) ? "MeanRev: OPEN" : "MeanRev: ---";
   UpdateLabel("mf_pos", mfText, HasPosition(InpMF_Magic) ? clrLime : clrGray);
   UpdateLabel("ch_pos", chText, HasPosition(InpCH_Magic) ? clrLime : clrGray);

   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   UpdateLabel("bal", StringFormat("Balance: $%.2f", bal), clrWhite);
   double pl = bal - startBalance;
   UpdateLabel("pl", StringFormat("P/L: $%+.2f", pl), pl >= 0 ? clrLime : clrOrangeRed);
}

//+------------------------------------------------------------------+
void OnTick()
{
   datetime currentBarTime = iTime(_Symbol, PERIOD_H1, 0);
   bool newBar = (currentBarTime != lastBarTime);

   if(newBar)
   {
      ExecutePending(mfPending, mfATR, InpMF_SLMult, InpMF_TPMult, InpMF_Magic, "MF");
      ExecutePending(chPending, chATR, InpCH_SLMult, InpCH_TPMult, InpCH_Magic, "CH");
   }

   if(!newBar) return;
   lastBarTime = currentBarTime;

   // Indicators
   double atrArr[1]; if(CopyBuffer(hATR, 0, 1, 1, atrArr) < 1) return;
   double atrVal = atrArr[0]; if(atrVal < InpMinATR) return;

   double rsiArr[1]; if(CopyBuffer(hRSI, 0, 1, 1, rsiArr) < 1) return;

   double adxArr[1]; if(CopyBuffer(hADX, 0, 1, 1, adxArr) < 1) return;
   double adxVal = adxArr[0];

   double ema200Arr[1]; if(CopyBuffer(hEMA200, 0, 1, 1, ema200Arr) < 1) return;

   double macdMain[2], macdSig[2];
   if(CopyBuffer(hMACD, 0, 1, 2, macdMain) < 2) return;
   if(CopyBuffer(hMACD, 1, 1, 2, macdSig) < 2) return;
   double macdHist = macdMain[1] - macdSig[1];
   double macdHistPrev = macdMain[0] - macdSig[0];

   double gfNow  = ComputeGaussian(InpMF_GaussPeriod, InpMF_GaussPoles, 1);
   double gfPrev = ComputeGaussian(InpMF_GaussPeriod, InpMF_GaussPoles, 2);
   if(gfNow == 0) return;

   double close1 = iClose(_Symbol, PERIOD_H1, 1);
   double open1  = iOpen(_Symbol, PERIOD_H1, 1);
   double high1  = iHigh(_Symbol, PERIOD_H1, 1);
   double low1   = iLow(_Symbol, PERIOD_H1, 1);

   // Dead market filter
   bool isDead = (adxVal < InpDeadMarketADX);

   UpdateDash(adxVal, rsiArr[0], gfNow, gfPrev, isDead);

   if(isDead) return;  // No trading in dead markets

   // Run both strategies
   if(!HasPosition(InpMF_Magic))
      RunMultiFilter(atrVal, rsiArr[0], adxVal, ema200Arr[0], close1, open1, macdHist, macdHistPrev, gfNow, gfPrev);

   if(!HasPosition(InpCH_Magic))
      RunChannelBounce(atrVal, rsiArr[0], close1, low1, high1, gfNow, gfPrev);
}
//+------------------------------------------------------------------+
