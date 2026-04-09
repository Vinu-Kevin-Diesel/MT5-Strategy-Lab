//+------------------------------------------------------------------+
//|                                   Gold_HMM_Portfolio_EA.mq5      |
//|          HMM-Inspired Regime Detection + Portfolio Strategies       |
//|                                                                    |
//|  v1: Regime-first trading — detect market state before trading     |
//|                                                                    |
//|  REGIME DETECTOR (mimics Hidden Markov Model):                     |
//|  Classifies market into 5 states using 6 features:                 |
//|  1. Trend direction (EMA50 vs EMA200)                              |
//|  2. Trend strength (ADX)                                           |
//|  3. Momentum (20-bar rate of change)                               |
//|  4. Volatility regime (ATR vs ATR average)                         |
//|  5. Price position (above/below Gaussian filter)                   |
//|  6. MACD momentum (histogram direction)                            |
//|                                                                    |
//|  States: STRONG_BULL, MILD_BULL, NEUTRAL, MILD_BEAR, STRONG_BEAR  |
//|                                                                    |
//|  STRATEGIES (only active in favorable regimes):                    |
//|  1. Beast — Pullback re-entry (bull/bear regimes)                  |
//|  2. MultiFilter — 5-filter selective (bull/bear regimes)           |
//|  3. GaussMACD — Gaussian + MACD (bull/bear regimes)                |
//|                                                                    |
//|  RISK MANAGEMENT:                                                  |
//|  - 48-bar cooldown after regime change (no revenge trading)        |
//|  - No trading in NEUTRAL regime                                    |
//|  - Close all positions on regime flip (bull→bear or bear→bull)     |
//|                                                                    |
//|  Symbol: XAUUSD.a  |  Timeframe: H1                               |
//+------------------------------------------------------------------+
#property copyright "Claude EA Generator"
#property version   "1.00"
#property strict

//=== SHARED INPUTS ===
input double InpFixedLot       = 0.01;
input double InpMaxSLDollars   = 30.0;
input double InpMinATR         = 0.50;

//=== REGIME DETECTION INPUTS ===
input int    InpRegimeCooldown = 48;        // Bars to wait after regime change
input bool   InpCloseOnFlip    = true;      // Close positions on bull↔bear flip
input int    InpROCPeriod      = 20;        // Rate of change period
input int    InpATRAvgPeriod   = 50;        // ATR average period for vol regime
input double InpVolExpandMult  = 1.3;       // Volatility expanding if ATR > avg * this

//=== BEAST INPUTS ===
input int    InpB_GaussPeriod  = 80;
input int    InpB_GaussPoles   = 4;
input int    InpB_FastEMA      = 21;
input int    InpB_SlowEMA      = 50;
input double InpB_SLMult       = 1.5;
input double InpB_TPMult       = 5.0;
input double InpB_RSIOB        = 80.0;
input double InpB_RSIOS        = 20.0;
input int    InpB_Magic        = 889970;

//=== MULTIFILTER INPUTS ===
input int    InpMF_GaussPeriod = 80;
input int    InpMF_GaussPoles  = 4;
input double InpMF_SLMult      = 2.0;
input double InpMF_TPMult      = 4.0;
input double InpMF_RSIOB       = 80.0;
input double InpMF_RSIOS       = 28.0;
input double InpMF_ADXMin      = 20.0;
input double InpMF_MinBodyATR  = 0.4;
input int    InpMF_EMATrend    = 200;
input int    InpMF_Magic       = 889971;

//=== GAUSSMACD INPUTS ===
input int    InpGM_GaussPeriod = 80;
input int    InpGM_GaussPoles  = 4;
input double InpGM_SLMult      = 2.5;
input double InpGM_TPMult      = 5.0;
input double InpGM_RSIOB       = 80.0;
input double InpGM_RSIOS       = 28.0;
input int    InpGM_Magic       = 889972;

//=== REGIME ENUMS ===
enum REGIME
{
   REGIME_STRONG_BULL = 1,
   REGIME_MILD_BULL   = 2,
   REGIME_NEUTRAL     = 3,
   REGIME_MILD_BEAR   = 4,
   REGIME_STRONG_BEAR = 5
};

//=== GLOBALS ===
int hATR, hRSI, hMACD, hADX;
int hEMAFast, hEMASlow, hEMA200;
datetime lastBarTime;

// Regime state
REGIME currentRegime;
REGIME prevRegime;
int    barsSinceRegimeChange;
double regimeConfidence;

// Strategy pending signals
int    beastPendingSignal;   double beastPendingATR;
int    mfPendingSignal;      double mfPendingATR;
int    gmPendingSignal;      double gmPendingATR;
bool   beastLastTP;          int beastLastDir;

// Dashboard stats
int    statWins, statLosses;
double statProfit;
double startBalance;
datetime lastDealCheck;

//+------------------------------------------------------------------+
int OnInit()
{
   hATR     = iATR(_Symbol, PERIOD_H1, 14);
   hRSI     = iRSI(_Symbol, PERIOD_H1, 14, PRICE_CLOSE);
   hMACD    = iMACD(_Symbol, PERIOD_H1, 12, 26, 9, PRICE_CLOSE);
   hEMAFast = iMA(_Symbol, PERIOD_H1, InpB_FastEMA, 0, MODE_EMA, PRICE_CLOSE);
   hEMASlow = iMA(_Symbol, PERIOD_H1, InpB_SlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   hEMA200  = iMA(_Symbol, PERIOD_H1, InpMF_EMATrend, 0, MODE_EMA, PRICE_CLOSE);
   hADX     = iADX(_Symbol, PERIOD_H1, 14);

   if(hATR == INVALID_HANDLE || hRSI == INVALID_HANDLE || hMACD == INVALID_HANDLE ||
      hEMAFast == INVALID_HANDLE || hEMASlow == INVALID_HANDLE ||
      hEMA200 == INVALID_HANDLE || hADX == INVALID_HANDLE)
      return INIT_FAILED;

   lastBarTime = 0;
   currentRegime = REGIME_NEUTRAL;
   prevRegime = REGIME_NEUTRAL;
   barsSinceRegimeChange = 999;
   regimeConfidence = 0;

   beastPendingSignal = 0; beastLastTP = false; beastLastDir = 0;
   mfPendingSignal = 0;
   gmPendingSignal = 0;

   statWins = 0; statLosses = 0; statProfit = 0;
   startBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   lastDealCheck = 0;

   CreateDashboard();

   Print("Gold_HMM_Portfolio_EA v1 initialized");
   Print("Regime cooldown=", InpRegimeCooldown, " bars, CloseOnFlip=", InpCloseOnFlip);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(hATR     != INVALID_HANDLE) IndicatorRelease(hATR);
   if(hRSI     != INVALID_HANDLE) IndicatorRelease(hRSI);
   if(hMACD    != INVALID_HANDLE) IndicatorRelease(hMACD);
   if(hEMAFast != INVALID_HANDLE) IndicatorRelease(hEMAFast);
   if(hEMASlow != INVALID_HANDLE) IndicatorRelease(hEMASlow);
   if(hEMA200  != INVALID_HANDLE) IndicatorRelease(hEMA200);
   if(hADX     != INVALID_HANDLE) IndicatorRelease(hADX);
   ObjectsDeleteAll(0, "HMM_");
}

//+------------------------------------------------------------------+
//|  REGIME DETECTION                                                  |
//+------------------------------------------------------------------+
REGIME DetectRegime(double atrVal, double rsiVal, double adxVal,
                    double gfNow, double gfPrev,
                    double emaFast, double emaSlow, double ema200,
                    double macdHist, double macdHistPrev, double close1)
{
   // Feature 1: Trend direction (EMA50 vs EMA200)
   int trendScore = 0;
   if(emaFast > emaSlow && close1 > ema200) trendScore = 2;       // Strong uptrend
   else if(emaFast > emaSlow || close1 > ema200) trendScore = 1;  // Mild uptrend
   else if(emaFast < emaSlow && close1 < ema200) trendScore = -2; // Strong downtrend
   else if(emaFast < emaSlow || close1 < ema200) trendScore = -1; // Mild downtrend

   // Feature 2: Trend strength (ADX)
   int adxScore = 0;
   if(adxVal > 30) adxScore = 2;       // Very strong trend
   else if(adxVal > 20) adxScore = 1;  // Moderate trend
   else adxScore = 0;                  // No trend (ranging)

   // Feature 3: Momentum (Rate of Change)
   double closeROC = iClose(_Symbol, PERIOD_H1, 1);
   double closePast = iClose(_Symbol, PERIOD_H1, InpROCPeriod + 1);
   double roc = (closePast > 0) ? (closeROC - closePast) / closePast * 100.0 : 0;
   int momScore = 0;
   if(roc > 2.0) momScore = 2;
   else if(roc > 0.5) momScore = 1;
   else if(roc < -2.0) momScore = -2;
   else if(roc < -0.5) momScore = -1;

   // Feature 4: Volatility regime (ATR expanding or contracting)
   double atrAvg = 0;
   double atrBuf[];
   ArraySetAsSeries(atrBuf, true);
   if(CopyBuffer(hATR, 0, 1, InpATRAvgPeriod, atrBuf) >= InpATRAvgPeriod)
   {
      double sum = 0;
      for(int i = 0; i < InpATRAvgPeriod; i++) sum += atrBuf[i];
      atrAvg = sum / InpATRAvgPeriod;
   }
   int volScore = 0;
   if(atrAvg > 0)
   {
      if(atrVal > atrAvg * InpVolExpandMult) volScore = 1;  // Expanding — good for trends
      else if(atrVal < atrAvg * 0.7) volScore = -1;          // Contracting — choppy
   }

   // Feature 5: Gaussian filter direction
   int gaussScore = 0;
   if(gfNow > gfPrev && close1 > gfNow) gaussScore = 2;
   else if(gfNow > gfPrev) gaussScore = 1;
   else if(gfNow < gfPrev && close1 < gfNow) gaussScore = -2;
   else if(gfNow < gfPrev) gaussScore = -1;

   // Feature 6: MACD momentum
   int macdScore = 0;
   if(macdHist > 0 && macdHist > macdHistPrev) macdScore = 2;
   else if(macdHist > 0) macdScore = 1;
   else if(macdHist < 0 && macdHist < macdHistPrev) macdScore = -2;
   else if(macdHist < 0) macdScore = -1;

   // Total score: range [-12, +12]
   int totalScore = trendScore + adxScore * (trendScore >= 0 ? 1 : -1) + momScore + volScore * (trendScore >= 0 ? 1 : -1) + gaussScore + macdScore;

   // Confidence: how many features agree
   int bullCount = (trendScore > 0 ? 1 : 0) + (momScore > 0 ? 1 : 0) + (gaussScore > 0 ? 1 : 0) + (macdScore > 0 ? 1 : 0);
   int bearCount = (trendScore < 0 ? 1 : 0) + (momScore < 0 ? 1 : 0) + (gaussScore < 0 ? 1 : 0) + (macdScore < 0 ? 1 : 0);
   regimeConfidence = MathMax(bullCount, bearCount) / 4.0 * 100.0;

   // Classify regime
   if(totalScore >= 7) return REGIME_STRONG_BULL;
   if(totalScore >= 3) return REGIME_MILD_BULL;
   if(totalScore <= -7) return REGIME_STRONG_BEAR;
   if(totalScore <= -3) return REGIME_MILD_BEAR;
   return REGIME_NEUTRAL;
}

string RegimeName(REGIME r)
{
   switch(r)
   {
      case REGIME_STRONG_BULL: return "STRONG BULL";
      case REGIME_MILD_BULL:   return "MILD BULL";
      case REGIME_NEUTRAL:     return "NEUTRAL";
      case REGIME_MILD_BEAR:   return "MILD BEAR";
      case REGIME_STRONG_BEAR: return "STRONG BEAR";
   }
   return "UNKNOWN";
}

color RegimeColor(REGIME r)
{
   switch(r)
   {
      case REGIME_STRONG_BULL: return clrLime;
      case REGIME_MILD_BULL:   return clrSpringGreen;
      case REGIME_NEUTRAL:     return clrYellow;
      case REGIME_MILD_BEAR:   return clrOrange;
      case REGIME_STRONG_BEAR: return clrRed;
   }
   return clrGray;
}

bool IsBullRegime(REGIME r) { return (r == REGIME_STRONG_BULL || r == REGIME_MILD_BULL); }
bool IsBearRegime(REGIME r) { return (r == REGIME_STRONG_BEAR || r == REGIME_MILD_BEAR); }

//+------------------------------------------------------------------+
//|  CLOSE ALL POSITIONS FOR A MAGIC                                   |
//+------------------------------------------------------------------+
void ClosePosition(int magic)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionGetInteger(POSITION_MAGIC) == magic &&
         PositionGetString(POSITION_SYMBOL) == _Symbol)
      {
         MqlTradeRequest req = {};
         MqlTradeResult  res = {};
         req.action = TRADE_ACTION_DEAL;
         req.symbol = _Symbol;
         req.volume = PositionGetDouble(POSITION_VOLUME);
         ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         req.type = (posType == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
         req.price = (req.type == ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
         req.position = ticket;
         req.deviation = 30;
         req.magic = magic;
         req.comment = "RegimeFlip_Close";
         req.type_filling = ORDER_FILLING_IOC;
         OrderSend(req, res);
      }
   }
}

void CloseAllPositions()
{
   ClosePosition(InpB_Magic);
   ClosePosition(InpMF_Magic);
   ClosePosition(InpGM_Magic);
}

//+------------------------------------------------------------------+
//|  CORE FUNCTIONS                                                    |
//+------------------------------------------------------------------+
bool HasPosition(int magic)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionGetInteger(POSITION_MAGIC) == magic &&
         PositionGetString(POSITION_SYMBOL) == _Symbol)
         return true;
   }
   return false;
}

bool OpenTrade(ENUM_ORDER_TYPE type, double sl, double tp, int magic, string comment)
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
   req.magic = magic;
   req.comment = comment;
   req.type_filling = ORDER_FILLING_IOC;
   if(!OrderSend(req, res)) return false;
   return (res.retcode == TRADE_RETCODE_DONE || res.retcode == TRADE_RETCODE_PLACED);
}

void ApplyRiskCap(double &slDist, double &tpDist, double slMult, double tpMult)
{
   if(slDist > InpMaxSLDollars)
   {
      double ratio = tpMult / slMult;
      slDist = InpMaxSLDollars;
      tpDist = slDist * ratio;
   }
}

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
   ArrayResize(result, barsNeeded);
   ArrayCopy(result, closes);
   for(int p = 0; p < poles; p++)
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
//|  BEAST TP CHECK                                                    |
//+------------------------------------------------------------------+
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

//+------------------------------------------------------------------+
//|  STRATEGIES (same as Portfolio EA)                                  |
//+------------------------------------------------------------------+
void RunBeast(double atrVal, double rsiVal, double gfNow, double gfPrev,
              double emaFast1, double emaSlow1, double close1, double open1, double low1, double high1,
              bool allowBuy, bool allowSell)
{
   bool gfRising = (gfNow > gfPrev);
   bool gfFalling = (gfNow < gfPrev);
   bool emaUp = (emaFast1 > emaSlow1);
   bool emaDn = (emaFast1 < emaSlow1);

   if(beastLastTP && beastLastDir != 0)
   {
      if(beastLastDir == 1 && gfRising && emaUp && rsiVal < InpB_RSIOB && allowBuy)
      { beastPendingSignal = 1; beastPendingATR = atrVal; beastLastTP = false; return; }
      else if(beastLastDir == -1 && gfFalling && emaDn && rsiVal > InpB_RSIOS && allowSell)
      { beastPendingSignal = -1; beastPendingATR = atrVal; beastLastTP = false; return; }
      beastLastTP = false;
   }

   if(gfRising && emaUp && close1 > gfNow && allowBuy)
   {
      double pullback = MathAbs(low1 - emaFast1);
      if(pullback < atrVal * 1.5 && close1 > open1 && rsiVal < InpB_RSIOB)
      { beastPendingSignal = 1; beastPendingATR = atrVal; }
   }
   else if(gfFalling && emaDn && close1 < gfNow && allowSell)
   {
      double pullback = MathAbs(high1 - emaFast1);
      if(pullback < atrVal * 1.5 && close1 < open1 && rsiVal > InpB_RSIOS)
      { beastPendingSignal = -1; beastPendingATR = atrVal; }
   }
}

void RunMultiFilter(double atrVal, double rsiVal, double gfNow, double gfPrev,
                    double ema200, double adxVal, double close1, double open1,
                    double macdHist, double macdHistPrev,
                    bool allowBuy, bool allowSell)
{
   double body = MathAbs(close1 - open1);
   bool gfRising = (gfNow > gfPrev);
   bool gfFalling = (gfNow < gfPrev);
   bool macdUp = (macdHist > macdHistPrev) && (macdHist > -0.5);
   bool macdDn = (macdHist < macdHistPrev) && (macdHist < 0.5);
   if(adxVal < InpMF_ADXMin) return;
   if(body < atrVal * InpMF_MinBodyATR) return;

   if(gfRising && macdUp && close1 > gfNow && close1 > ema200 && rsiVal < InpMF_RSIOB && allowBuy)
   { mfPendingSignal = 1; mfPendingATR = atrVal; }
   else if(gfFalling && macdDn && close1 < gfNow && close1 < ema200 && rsiVal > InpMF_RSIOS && allowSell)
   { mfPendingSignal = -1; mfPendingATR = atrVal; }
}

void RunGaussMACD(double atrVal, double rsiVal, double gfNow, double gfPrev,
                  double macdHist, double macdHistPrev, double close1,
                  bool allowBuy, bool allowSell)
{
   bool gfRising = (gfNow > gfPrev);
   bool gfFalling = (gfNow < gfPrev);
   bool macdUp = (macdHist > macdHistPrev) && (macdHist > -0.5);
   bool macdDn = (macdHist < macdHistPrev) && (macdHist < 0.5);

   if(gfRising && macdUp && close1 > gfNow && rsiVal < InpGM_RSIOB && allowBuy)
   { gmPendingSignal = 1; gmPendingATR = atrVal; }
   else if(gfFalling && macdDn && close1 < gfNow && rsiVal > InpGM_RSIOS && allowSell)
   { gmPendingSignal = -1; gmPendingATR = atrVal; }
}

//+------------------------------------------------------------------+
//|  DASHBOARD                                                         |
//+------------------------------------------------------------------+
void CreateLabel(string name, int x, int y, string text, color clr, int fontSize=9)
{
   string objName = "HMM_" + name;
   ObjectCreate(0, objName, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, objName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, objName, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, objName, OBJPROP_YDISTANCE, y);
   ObjectSetString(0, objName, OBJPROP_TEXT, text);
   ObjectSetString(0, objName, OBJPROP_FONT, "Consolas");
   ObjectSetInteger(0, objName, OBJPROP_FONTSIZE, fontSize);
   ObjectSetInteger(0, objName, OBJPROP_COLOR, clr);
}

void UpdateLabel(string name, string text, color clr=clrNONE)
{
   string objName = "HMM_" + name;
   ObjectSetString(0, objName, OBJPROP_TEXT, text);
   if(clr != clrNONE) ObjectSetInteger(0, objName, OBJPROP_COLOR, clr);
}

void CreateDashboard()
{
   int x = 15, y = 20, gap = 18;
   CreateLabel("title", x, y, "HMM REGIME PORTFOLIO EA", clrGold, 11); y += gap + 5;
   CreateLabel("sep1", x, y, "--------------------------------------", clrDimGray, 8); y += gap;

   // Regime
   CreateLabel("regime_label", x, y, "REGIME:", clrDimGray); CreateLabel("regime_val", x+100, y, "---", clrWhite, 10); y += gap;
   CreateLabel("conf_label", x, y, "Confidence:", clrDimGray); CreateLabel("conf_val", x+100, y, "---", clrWhite); y += gap;
   CreateLabel("cool_label", x, y, "Cooldown:", clrDimGray); CreateLabel("cool_val", x+100, y, "---", clrWhite); y += gap;
   CreateLabel("signal_label", x, y, "Signal:", clrDimGray); CreateLabel("signal_val", x+100, y, "---", clrWhite, 10); y += gap;
   y += 5;
   CreateLabel("sep2", x, y, "--------------------------------------", clrDimGray, 8); y += gap;

   // Account
   CreateLabel("bal_label", x, y, "Balance:", clrDimGray); CreateLabel("bal_val", x+100, y, "---", clrWhite); y += gap;
   CreateLabel("eq_label", x, y, "Equity:", clrDimGray); CreateLabel("eq_val", x+100, y, "---", clrWhite); y += gap;
   CreateLabel("pl_label", x, y, "P/L:", clrDimGray); CreateLabel("pl_val", x+100, y, "---", clrWhite); y += gap;
   y += 5;
   CreateLabel("sep3", x, y, "--------------------------------------", clrDimGray, 8); y += gap;

   // Positions
   CreateLabel("pos_header", x, y, "POSITIONS", clrDodgerBlue, 9); y += gap;
   CreateLabel("beast_pos", x, y, "Beast:  ---", clrGray); y += gap;
   CreateLabel("mf_pos", x, y, "MFilter: ---", clrGray); y += gap;
   CreateLabel("gm_pos", x, y, "GaussM:  ---", clrGray); y += gap;
   y += 5;
   CreateLabel("sep4", x, y, "--------------------------------------", clrDimGray, 8); y += gap;

   // Stats
   CreateLabel("stat_header", x, y, "STATS", clrDodgerBlue, 9); y += gap;
   CreateLabel("trades_stat", x, y, "Trades: 0W/0L", clrGray); y += gap;
   CreateLabel("profit_stat", x, y, "Profit: $0.00", clrGray); y += gap;
}

string GetPosInfo(int magic)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionGetInteger(POSITION_MAGIC) == magic &&
         PositionGetString(POSITION_SYMBOL) == _Symbol)
      {
         ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         double profit = PositionGetDouble(POSITION_PROFIT);
         string dir = (type == POSITION_TYPE_BUY) ? "BUY" : "SELL";
         return StringFormat("%s $%+.2f", dir, profit);
      }
   }
   return "---";
}

void UpdateStats()
{
   datetime now = TimeCurrent();
   if(now - lastDealCheck < 5) return;
   lastDealCheck = now;
   HistorySelect(0, now);
   statWins = 0; statLosses = 0; statProfit = 0;
   for(int i = 0; i < HistoryDealsTotal(); i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket <= 0) continue;
      if(HistoryDealGetString(ticket, DEAL_SYMBOL) != _Symbol) continue;
      if(HistoryDealGetInteger(ticket, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;
      long magic = HistoryDealGetInteger(ticket, DEAL_MAGIC);
      if(magic != InpB_Magic && magic != InpMF_Magic && magic != InpGM_Magic) continue;
      double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT) + HistoryDealGetDouble(ticket, DEAL_SWAP);
      statProfit += profit;
      if(profit > 0) statWins++; else statLosses++;
   }
}

void UpdateDashboard()
{
   // Regime
   UpdateLabel("regime_val", RegimeName(currentRegime), RegimeColor(currentRegime));
   UpdateLabel("conf_val", StringFormat("%.0f%%", regimeConfidence), regimeConfidence > 75 ? clrLime : (regimeConfidence > 50 ? clrYellow : clrOrangeRed));

   string coolText = (barsSinceRegimeChange < InpRegimeCooldown) ?
      StringFormat("COOLING %d/%d bars", barsSinceRegimeChange, InpRegimeCooldown) : "READY";
   color coolClr = (barsSinceRegimeChange < InpRegimeCooldown) ? clrOrangeRed : clrLime;
   UpdateLabel("cool_val", coolText, coolClr);

   // Signal
   string sigText = "HOLD";
   color sigClr = clrYellow;
   if(currentRegime == REGIME_NEUTRAL || barsSinceRegimeChange < InpRegimeCooldown)
   { sigText = "NO TRADE"; sigClr = clrOrangeRed; }
   else if(IsBullRegime(currentRegime))
   { sigText = "LONG"; sigClr = clrLime; }
   else if(IsBearRegime(currentRegime))
   { sigText = "SHORT"; sigClr = clrRed; }
   UpdateLabel("signal_val", sigText, sigClr);

   // Account
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   UpdateLabel("bal_val", StringFormat("$%.2f", bal), clrWhite);
   UpdateLabel("eq_val", StringFormat("$%.2f", eq), eq >= bal ? clrLime : clrOrangeRed);
   UpdateLabel("pl_val", StringFormat("$%+.2f", bal - startBalance), (bal - startBalance) >= 0 ? clrLime : clrOrangeRed);

   // Positions
   UpdateLabel("beast_pos", "Beast:  " + GetPosInfo(InpB_Magic), HasPosition(InpB_Magic) ? clrLime : clrGray);
   UpdateLabel("mf_pos", "MFilter: " + GetPosInfo(InpMF_Magic), HasPosition(InpMF_Magic) ? clrLime : clrGray);
   UpdateLabel("gm_pos", "GaussM:  " + GetPosInfo(InpGM_Magic), HasPosition(InpGM_Magic) ? clrLime : clrGray);

   // Stats
   UpdateStats();
   int totalT = statWins + statLosses;
   double wr = totalT > 0 ? statWins * 100.0 / totalT : 0;
   UpdateLabel("trades_stat", StringFormat("Trades: %dW/%dL (%.0f%%)", statWins, statLosses, wr), clrWhite);
   UpdateLabel("profit_stat", StringFormat("Profit: $%+.2f", statProfit), statProfit >= 0 ? clrLime : clrOrangeRed);
}

//+------------------------------------------------------------------+
//|  MAIN TICK                                                         |
//+------------------------------------------------------------------+
void OnTick()
{
   datetime currentBarTime = iTime(_Symbol, PERIOD_H1, 0);
   bool newBar = (currentBarTime != lastBarTime);

   // Execute pending signals
   if(newBar)
   {
      ExecutePending(beastPendingSignal, beastPendingATR, InpB_SLMult, InpB_TPMult, InpB_Magic, "Beast");
      ExecutePending(mfPendingSignal, mfPendingATR, InpMF_SLMult, InpMF_TPMult, InpMF_Magic, "MFilter");
      ExecutePending(gmPendingSignal, gmPendingATR, InpGM_SLMult, InpGM_TPMult, InpGM_Magic, "GaussM");
   }

   if(!newBar) return;
   lastBarTime = currentBarTime;
   barsSinceRegimeChange++;

   CheckBeastTP();

   // Get indicators
   double atrArr[1]; if(CopyBuffer(hATR, 0, 1, 1, atrArr) < 1) return;
   double atrVal = atrArr[0];
   if(atrVal < InpMinATR) return;

   double rsiArr[1]; if(CopyBuffer(hRSI, 0, 1, 1, rsiArr) < 1) return;
   double rsiVal = rsiArr[0];

   double macdMain[2], macdSig[2];
   if(CopyBuffer(hMACD, 0, 1, 2, macdMain) < 2) return;
   if(CopyBuffer(hMACD, 1, 1, 2, macdSig) < 2) return;
   double macdHist = macdMain[1] - macdSig[1];
   double macdHistPrev = macdMain[0] - macdSig[0];

   double emaFastArr[2], emaSlowArr[2], ema200Arr[1];
   if(CopyBuffer(hEMAFast, 0, 1, 2, emaFastArr) < 2) return;
   if(CopyBuffer(hEMASlow, 0, 1, 2, emaSlowArr) < 2) return;
   if(CopyBuffer(hEMA200, 0, 1, 1, ema200Arr) < 1) return;

   double adxArr[1];
   if(CopyBuffer(hADX, 0, 1, 1, adxArr) < 1) return;

   double gfNow  = ComputeGaussian(InpB_GaussPeriod, InpB_GaussPoles, 1);
   double gfPrev = ComputeGaussian(InpB_GaussPeriod, InpB_GaussPoles, 2);
   if(gfNow == 0) return;

   double close1 = iClose(_Symbol, PERIOD_H1, 1);
   double open1  = iOpen(_Symbol, PERIOD_H1, 1);
   double high1  = iHigh(_Symbol, PERIOD_H1, 1);
   double low1   = iLow(_Symbol, PERIOD_H1, 1);

   // ═══ STEP 1: DETECT REGIME ═══
   REGIME newRegime = DetectRegime(atrVal, rsiVal, adxArr[0], gfNow, gfPrev,
                                    emaFastArr[1], emaSlowArr[1], ema200Arr[0],
                                    macdHist, macdHistPrev, close1);

   // Check for regime change
   if(newRegime != currentRegime)
   {
      prevRegime = currentRegime;
      currentRegime = newRegime;
      barsSinceRegimeChange = 0;

      Print("REGIME CHANGE: ", RegimeName(prevRegime), " -> ", RegimeName(currentRegime),
            " Confidence=", regimeConfidence, "%");

      // Close on flip: bull→bear or bear→bull
      if(InpCloseOnFlip)
      {
         bool wasBull = IsBullRegime(prevRegime);
         bool wasBear = IsBearRegime(prevRegime);
         bool nowBull = IsBullRegime(currentRegime);
         bool nowBear = IsBearRegime(currentRegime);

         if((wasBull && nowBear) || (wasBear && nowBull))
         {
            Print("REGIME FLIP! Closing all positions.");
            CloseAllPositions();
         }
      }
   }

   // ═══ STEP 2: APPLY COOLDOWN ═══
   if(barsSinceRegimeChange < InpRegimeCooldown)
   {
      UpdateDashboard();
      return;  // Wait for regime to stabilize
   }

   // ═══ STEP 3: DETERMINE ALLOWED DIRECTIONS ═══
   bool allowBuy = false;
   bool allowSell = false;

   if(currentRegime == REGIME_STRONG_BULL)      { allowBuy = true; allowSell = false; }
   else if(currentRegime == REGIME_MILD_BULL)   { allowBuy = true; allowSell = false; }
   else if(currentRegime == REGIME_NEUTRAL)      { allowBuy = false; allowSell = false; }
   else if(currentRegime == REGIME_MILD_BEAR)   { allowBuy = false; allowSell = true; }
   else if(currentRegime == REGIME_STRONG_BEAR)  { allowBuy = false; allowSell = true; }

   // ═══ STEP 4: RUN STRATEGIES (only in allowed direction) ═══
   double gfMF_now  = ComputeGaussian(InpMF_GaussPeriod, InpMF_GaussPoles, 1);
   double gfMF_prev = ComputeGaussian(InpMF_GaussPeriod, InpMF_GaussPoles, 2);
   double gfGM_now  = ComputeGaussian(InpGM_GaussPeriod, InpGM_GaussPoles, 1);
   double gfGM_prev = ComputeGaussian(InpGM_GaussPeriod, InpGM_GaussPoles, 2);

   if(!HasPosition(InpB_Magic))
      RunBeast(atrVal, rsiVal, gfNow, gfPrev, emaFastArr[1], emaSlowArr[1], close1, open1, low1, high1, allowBuy, allowSell);
   if(!HasPosition(InpMF_Magic))
      RunMultiFilter(atrVal, rsiVal, gfMF_now, gfMF_prev, ema200Arr[0], adxArr[0], close1, open1, macdHist, macdHistPrev, allowBuy, allowSell);
   if(!HasPosition(InpGM_Magic))
      RunGaussMACD(atrVal, rsiVal, gfGM_now, gfGM_prev, macdHist, macdHistPrev, close1, allowBuy, allowSell);

   // ═══ STEP 5: UPDATE DASHBOARD ═══
   UpdateDashboard();
}
//+------------------------------------------------------------------+
