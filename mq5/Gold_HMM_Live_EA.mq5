//+------------------------------------------------------------------+
//|                                        Gold_HMM_Live_EA.mq5      |
//|          Reads regime from Python HMM → trades accordingly         |
//|                                                                    |
//|  Bridge: Python hmm_regime.py writes regime to hmm_regime.csv      |
//|  This EA reads that file and only trades in favorable regimes.     |
//|                                                                    |
//|  Run: python hmm_regime.py --loop 5   (in separate terminal)       |
//|  Then attach this EA to XAUUSD.a H1 chart                         |
//+------------------------------------------------------------------+
#property copyright "Claude EA Generator"
#property version   "1.00"
#property strict

//=== INPUTS ===
input double InpFixedLot       = 0.01;
input double InpMaxSLDollars   = 30.0;
input double InpMinATR         = 0.50;
input int    InpCooldownBars   = 12;        // Bars to wait after regime change
input bool   InpCloseOnFlip    = true;      // Close all on bull->bear flip
input string InpRegimeFile     = "hmm_regime.csv";  // File written by Python

//=== STRATEGY INPUTS (GaussMACD — proven best) ===
input int    InpGaussPeriod    = 80;
input int    InpGaussPoles     = 4;
input double InpSLMult         = 2.5;
input double InpTPMult         = 5.0;
input double InpRSIOB          = 80.0;
input double InpRSIOS          = 28.0;
input int    InpMagic          = 889980;

//=== GLOBALS ===
int hATR, hRSI, hMACD;
datetime lastBarTime;
int pendingSignal;
double pendingATR;

// Regime from Python
int    pyRegime;          // 1-5
string pyRegimeName;
double pyConfidence;
double pyStability;
datetime lastFileRead;
int    barsSinceChange;
int    prevRegime;

int OnInit()
{
   hATR  = iATR(_Symbol, PERIOD_H1, 14);
   hRSI  = iRSI(_Symbol, PERIOD_H1, 14, PRICE_CLOSE);
   hMACD = iMACD(_Symbol, PERIOD_H1, 12, 26, 9, PRICE_CLOSE);

   if(hATR == INVALID_HANDLE || hRSI == INVALID_HANDLE || hMACD == INVALID_HANDLE)
      return INIT_FAILED;

   lastBarTime = 0;
   pendingSignal = 0;
   pyRegime = 3;  // NEUTRAL
   pyRegimeName = "UNKNOWN";
   pyConfidence = 0;
   pyStability = 0;
   lastFileRead = 0;
   barsSinceChange = 999;
   prevRegime = 3;

   CreateDashboard();
   Print("Gold_HMM_Live_EA initialized — reading regime from ", InpRegimeFile);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(hATR  != INVALID_HANDLE) IndicatorRelease(hATR);
   if(hRSI  != INVALID_HANDLE) IndicatorRelease(hRSI);
   if(hMACD != INVALID_HANDLE) IndicatorRelease(hMACD);
   ObjectsDeleteAll(0, "HMML_");
}

//+------------------------------------------------------------------+
//|  READ REGIME FROM PYTHON FILE                                      |
//+------------------------------------------------------------------+
void ReadRegimeFile()
{
   // Only read every 30 seconds
   if(TimeCurrent() - lastFileRead < 30) return;
   lastFileRead = TimeCurrent();

   int handle = FileOpen(InpRegimeFile, FILE_READ | FILE_CSV | FILE_ANSI, ',');
   if(handle == INVALID_HANDLE)
   {
      Print("  [WARN] Cannot read ", InpRegimeFile, " — run: python hmm_regime.py --loop 5");
      return;
   }

   // Skip header
   string header = FileReadString(handle);
   FileReadString(handle); // skip rest of header line

   // Read data line
   if(!FileIsEnding(handle))
   {
      string timestamp = FileReadString(handle);
      int regime = (int)FileReadNumber(handle);
      string name = FileReadString(handle);
      double conf = FileReadNumber(handle);
      double stab = FileReadNumber(handle);

      if(regime >= 1 && regime <= 5)
      {
         if(regime != pyRegime)
         {
            prevRegime = pyRegime;
            barsSinceChange = 0;
            Print("REGIME CHANGE: ", pyRegimeName, " -> ", name, " Conf=", conf, "%");
         }
         pyRegime = regime;
         pyRegimeName = name;
         pyConfidence = conf;
         pyStability = stab;
      }
   }
   FileClose(handle);
}

//+------------------------------------------------------------------+
bool HasPosition()
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

void CloseAllPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionGetInteger(POSITION_MAGIC) == InpMagic &&
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
         req.magic = InpMagic;
         req.comment = "HMM_RegimeFlip";
         req.type_filling = ORDER_FILLING_IOC;
         OrderSend(req, res);
      }
   }
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

double ComputeGaussian(int shift)
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

//+------------------------------------------------------------------+
//|  DASHBOARD                                                         |
//+------------------------------------------------------------------+
void CreateLabel(string name, int x, int y, string text, color clr, int fs=9)
{
   string obj = "HMML_" + name;
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
   string obj = "HMML_" + name;
   ObjectSetString(0, obj, OBJPROP_TEXT, text);
   if(clr != clrNONE) ObjectSetInteger(0, obj, OBJPROP_COLOR, clr);
}

void CreateDashboard()
{
   int x = 15, y = 20, g = 18;
   CreateLabel("title", x, y, "HMM LIVE REGIME EA", clrGold, 11); y += g+5;
   CreateLabel("sep1", x, y, "------------------------------------", clrDimGray, 8); y += g;
   CreateLabel("regime_l", x, y, "REGIME:", clrDimGray); CreateLabel("regime_v", x+90, y, "---", clrWhite, 10); y += g;
   CreateLabel("conf_l", x, y, "Confidence:", clrDimGray); CreateLabel("conf_v", x+90, y, "---", clrWhite); y += g;
   CreateLabel("stab_l", x, y, "Stability:", clrDimGray); CreateLabel("stab_v", x+90, y, "---", clrWhite); y += g;
   CreateLabel("cool_l", x, y, "Cooldown:", clrDimGray); CreateLabel("cool_v", x+90, y, "---", clrWhite); y += g;
   CreateLabel("signal_l", x, y, "Signal:", clrDimGray); CreateLabel("signal_v", x+90, y, "---", clrWhite, 10); y += g;
   y += 5;
   CreateLabel("sep2", x, y, "------------------------------------", clrDimGray, 8); y += g;
   CreateLabel("pos_l", x, y, "Position:", clrDimGray); CreateLabel("pos_v", x+90, y, "---", clrWhite); y += g;
   CreateLabel("bal_l", x, y, "Balance:", clrDimGray); CreateLabel("bal_v", x+90, y, "---", clrWhite); y += g;
   CreateLabel("pl_l", x, y, "P/L:", clrDimGray); CreateLabel("pl_v", x+90, y, "---", clrWhite); y += g;
   y += 5;
   CreateLabel("sep3", x, y, "------------------------------------", clrDimGray, 8); y += g;
   CreateLabel("python_l", x, y, "Python:", clrDimGray); CreateLabel("python_v", x+90, y, "NOT RUNNING", clrOrangeRed); y += g;
}

color RegimeColor(int r)
{
   if(r == 1) return clrLime;
   if(r == 2) return clrSpringGreen;
   if(r == 3) return clrYellow;
   if(r == 4) return clrOrange;
   if(r == 5) return clrRed;
   return clrGray;
}

void UpdateDashboard()
{
   UpdateLabel("regime_v", pyRegimeName, RegimeColor(pyRegime));
   UpdateLabel("conf_v", StringFormat("%.0f%%", pyConfidence), pyConfidence > 70 ? clrLime : clrYellow);
   UpdateLabel("stab_v", StringFormat("%.0f%%", pyStability), pyStability > 70 ? clrLime : clrYellow);

   string coolText = (barsSinceChange < InpCooldownBars) ?
      StringFormat("WAIT %d/%d", barsSinceChange, InpCooldownBars) : "READY";
   UpdateLabel("cool_v", coolText, barsSinceChange < InpCooldownBars ? clrOrangeRed : clrLime);

   string sig = "NO TRADE";
   color sigClr = clrOrangeRed;
   if(barsSinceChange >= InpCooldownBars)
   {
      if(pyRegime <= 2) { sig = "LONG"; sigClr = clrLime; }
      else if(pyRegime >= 4) { sig = "SHORT"; sigClr = clrRed; }
      else { sig = "NO TRADE"; sigClr = clrYellow; }
   }
   UpdateLabel("signal_v", sig, sigClr);

   // Position
   string posText = "None";
   color posClr = clrGray;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionGetInteger(POSITION_MAGIC) == InpMagic)
      {
         ENUM_POSITION_TYPE pt = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         double profit = PositionGetDouble(POSITION_PROFIT);
         posText = StringFormat("%s $%+.2f", pt == POSITION_TYPE_BUY ? "BUY" : "SELL", profit);
         posClr = profit >= 0 ? clrLime : clrOrangeRed;
         break;
      }
   }
   UpdateLabel("pos_v", posText, posClr);

   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   UpdateLabel("bal_v", StringFormat("$%.2f", bal), clrWhite);
   double pl = bal - 1000;  // Approximate
   UpdateLabel("pl_v", StringFormat("$%+.2f", pl), pl >= 0 ? clrLime : clrOrangeRed);

   // Python status
   bool fileRecent = (TimeCurrent() - lastFileRead < 600);  // File read within 10 min
   UpdateLabel("python_v", fileRecent && pyRegime > 0 ? "CONNECTED" : "NOT RUNNING",
               fileRecent && pyRegime > 0 ? clrLime : clrOrangeRed);
}

//+------------------------------------------------------------------+
void OnTick()
{
   // Read regime file every tick (throttled inside)
   ReadRegimeFile();

   datetime currentBarTime = iTime(_Symbol, PERIOD_H1, 0);
   bool newBar = (currentBarTime != lastBarTime);

   // Execute pending
   if(newBar && pendingSignal != 0 && !HasPosition())
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
         OpenTrade(ORDER_TYPE_BUY, ask - slDist, ask + tpDist, "HMM_Buy");
      else
         OpenTrade(ORDER_TYPE_SELL, bid + slDist, bid - tpDist, "HMM_Sell");
      pendingSignal = 0;
   }

   if(!newBar) return;
   lastBarTime = currentBarTime;
   barsSinceChange++;

   // Close on regime flip
   if(InpCloseOnFlip && HasPosition())
   {
      bool wasBull = (prevRegime <= 2);
      bool wasBear = (prevRegime >= 4);
      bool nowBull = (pyRegime <= 2);
      bool nowBear = (pyRegime >= 4);
      if((wasBull && nowBear) || (wasBear && nowBull))
      {
         Print("REGIME FLIP! Closing positions.");
         CloseAllPositions();
      }
   }

   if(HasPosition()) { pendingSignal = 0; UpdateDashboard(); return; }

   // Cooldown
   if(barsSinceChange < InpCooldownBars) { UpdateDashboard(); return; }

   // Regime filter
   bool allowBuy  = (pyRegime <= 2);  // Bull regimes
   bool allowSell = (pyRegime >= 4);  // Bear regimes
   if(!allowBuy && !allowSell) { UpdateDashboard(); return; }

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

   double gfNow  = ComputeGaussian(1);
   double gfPrev = ComputeGaussian(2);
   if(gfNow == 0) return;

   double close1 = iClose(_Symbol, PERIOD_H1, 1);

   // GaussMACD signal (same as our proven strategy)
   bool gfRising = (gfNow > gfPrev);
   bool gfFalling = (gfNow < gfPrev);
   bool macdUp = (macdHist > macdHistPrev) && (macdHist > -0.5);
   bool macdDn = (macdHist < macdHistPrev) && (macdHist < 0.5);

   if(gfRising && macdUp && close1 > gfNow && allowBuy && rsiVal < InpRSIOB)
   {
      pendingSignal = 1;
      pendingATR = atrVal;
      Print("HMM BUY signal — Regime: ", pyRegimeName, " Conf: ", pyConfidence, "%");
   }
   else if(gfFalling && macdDn && close1 < gfNow && allowSell && rsiVal > InpRSIOS)
   {
      pendingSignal = -1;
      pendingATR = atrVal;
      Print("HMM SELL signal — Regime: ", pyRegimeName, " Conf: ", pyConfidence, "%");
   }

   UpdateDashboard();
}
//+------------------------------------------------------------------+
