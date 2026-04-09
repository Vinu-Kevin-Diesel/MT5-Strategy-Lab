//+------------------------------------------------------------------+
//|                                       Gold_SmartTrio_EA.mq5      |
//|          3-Strategy with Dead Market Protection                     |
//|                                                                    |
//|  SmartDuo + GaussMACD, all protected by dead market filter.        |
//|  Strategy 1: MultiFilter (trend)     Magic: 889910                 |
//|  Strategy 2: Channel Bounce (revert) Magic: 889955                 |
//|  Strategy 3: GaussMACD (momentum)    Magic: 889900                 |
//|  Master: ADX < threshold = ALL strategies pause                    |
//|                                                                    |
//|  Symbol: XAUUSD.a  |  Timeframe: H1                               |
//+------------------------------------------------------------------+
#property copyright "Claude EA Generator"
#property version   "1.00"
#property strict

input double InpFixedLot=0.01;
input double InpMaxSLDollars=30.0;
input double InpMinATR=0.50;
input double InpDeadMarketADX=12.0;
input int InpMF_GaussPeriod=80;
input int InpMF_GaussPoles=4;
input double InpMF_SLMult=2.0;
input double InpMF_TPMult=4.0;
input double InpMF_RSIOB=80.0;
input double InpMF_RSIOS=28.0;
input double InpMF_ADXMin=20.0;
input double InpMF_MinBodyATR=0.4;
input int InpMF_EMATrend=200;
input int InpMF_Magic=889910;
input double InpCH_BandMult=1.5;
input double InpCH_SLMult=1.5;
input double InpCH_TPMult=2.5;
input double InpCH_RSIOB=75.0;
input double InpCH_RSIOS=25.0;
input int InpCH_Magic=889955;
input int InpGM_GaussPeriod=80;
input int InpGM_GaussPoles=4;
input double InpGM_SLMult=2.5;
input double InpGM_TPMult=5.0;
input double InpGM_RSIOB=80.0;
input double InpGM_RSIOS=28.0;
input int InpGM_Magic=889900;

int hATR,hRSI,hMACD,hEMA200,hADX;
datetime lastBarTime;
int mfP; double mfA;
int chP; double chA;
int gmP; double gmA;
double startBal;

int OnInit(){
   hATR=iATR(_Symbol,PERIOD_H1,14);
   hRSI=iRSI(_Symbol,PERIOD_H1,14,PRICE_CLOSE);
   hMACD=iMACD(_Symbol,PERIOD_H1,12,26,9,PRICE_CLOSE);
   hEMA200=iMA(_Symbol,PERIOD_H1,InpMF_EMATrend,0,MODE_EMA,PRICE_CLOSE);
   hADX=iADX(_Symbol,PERIOD_H1,14);
   if(hATR==INVALID_HANDLE||hRSI==INVALID_HANDLE||hMACD==INVALID_HANDLE||hEMA200==INVALID_HANDLE||hADX==INVALID_HANDLE) return INIT_FAILED;
   lastBarTime=0; mfP=0; chP=0; gmP=0;
   startBal=AccountInfoDouble(ACCOUNT_BALANCE);
   Print("Gold_SmartTrio_EA | DeadADX=",InpDeadMarketADX);
   return INIT_SUCCEEDED;
}
void OnDeinit(const int r){
   if(hATR!=INVALID_HANDLE)IndicatorRelease(hATR);
   if(hRSI!=INVALID_HANDLE)IndicatorRelease(hRSI);
   if(hMACD!=INVALID_HANDLE)IndicatorRelease(hMACD);
   if(hEMA200!=INVALID_HANDLE)IndicatorRelease(hEMA200);
   if(hADX!=INVALID_HANDLE)IndicatorRelease(hADX);
}
bool HasPos(int m){
   for(int i=PositionsTotal()-1;i>=0;i--){
      ulong t=PositionGetTicket(i);
      if(t>0&&PositionGetInteger(POSITION_MAGIC)==m&&PositionGetString(POSITION_SYMBOL)==_Symbol) return true;
   } return false;
}
bool Trade(ENUM_ORDER_TYPE ty,double sl,double tp,int m,string c){
   double f=AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   long l=AccountInfoInteger(ACCOUNT_LEVERAGE);
   double p=(ty==ORDER_TYPE_BUY)?SymbolInfoDouble(_Symbol,SYMBOL_ASK):SymbolInfoDouble(_Symbol,SYMBOL_BID);
   if(p*InpFixedLot*100.0/l>f*0.80) return false;
   MqlTradeRequest rq={}; MqlTradeResult rs={};
   rq.action=TRADE_ACTION_DEAL;rq.symbol=_Symbol;rq.volume=InpFixedLot;
   rq.type=ty;rq.price=p;rq.sl=NormalizeDouble(sl,_Digits);rq.tp=NormalizeDouble(tp,_Digits);
   rq.deviation=30;rq.magic=m;rq.comment=c;rq.type_filling=ORDER_FILLING_IOC;
   if(!OrderSend(rq,rs)) return false;
   if(rs.retcode==TRADE_RETCODE_DONE||rs.retcode==TRADE_RETCODE_PLACED){Print(c," P=",rs.price," SL=",sl," TP=",tp);return true;}
   return false;
}
void Exec(int &sig,double &atr,double slM,double tpM,int mag,string pfx){
   if(sig==0||HasPos(mag)){sig=0;return;}
   double a=SymbolInfoDouble(_Symbol,SYMBOL_ASK),b=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double sd=atr*slM,td=atr*tpM;
   if(InpMaxSLDollars>0&&sd>InpMaxSLDollars){double r=tpM/slM;sd=InpMaxSLDollars;td=sd*r;}
   if(sig==1) Trade(ORDER_TYPE_BUY,a-sd,a+td,mag,pfx+"_Buy");
   else Trade(ORDER_TYPE_SELL,b+sd,b-td,mag,pfx+"_Sell");
   sig=0;
}
double GF(int per,int pol,int sh){
   int n=MathMin(iBars(_Symbol,PERIOD_H1)-sh,5000);
   if(n<per*3) return 0;
   double c[]; ArraySetAsSeries(c,false);
   if(CopyClose(_Symbol,PERIOD_H1,sh,n,c)<n) return 0;
   double bt=(1.0-MathCos(2.0*M_PI/per))/(MathPow(2.0,1.0/pol)-1.0);
   double al=-bt+MathSqrt(bt*bt+2.0*bt);
   double r[]; ArrayResize(r,n); ArrayCopy(r,c);
   for(int p=0;p<pol;p++){
      double b[]; ArrayResize(b,n); b[0]=r[0];
      for(int j=1;j<n;j++) b[j]=al*r[j]+(1.0-al)*b[j-1];
      ArrayCopy(r,b);
   } return r[n-1];
}

void OnTick(){
   datetime ct=iTime(_Symbol,PERIOD_H1,0);
   bool nb=(ct!=lastBarTime);
   if(nb){
      Exec(mfP,mfA,InpMF_SLMult,InpMF_TPMult,InpMF_Magic,"MF");
      Exec(chP,chA,InpCH_SLMult,InpCH_TPMult,InpCH_Magic,"CH");
      Exec(gmP,gmA,InpGM_SLMult,InpGM_TPMult,InpGM_Magic,"GM");
   }
   if(!nb) return;
   lastBarTime=ct;

   double atr[1]; if(CopyBuffer(hATR,0,1,1,atr)<1) return;
   if(atr[0]<InpMinATR) return;
   double rsi[1]; if(CopyBuffer(hRSI,0,1,1,rsi)<1) return;
   double adx[1]; if(CopyBuffer(hADX,0,1,1,adx)<1) return;
   double ema[1]; if(CopyBuffer(hEMA200,0,1,1,ema)<1) return;
   double mm[2],ms[2];
   if(CopyBuffer(hMACD,0,1,2,mm)<2) return;
   if(CopyBuffer(hMACD,1,1,2,ms)<2) return;
   double mh=mm[1]-ms[1], mhp=mm[0]-ms[0];

   double g1=GF(InpMF_GaussPeriod,InpMF_GaussPoles,1);
   double g2=GF(InpMF_GaussPeriod,InpMF_GaussPoles,2);
   if(g1==0) return;

   double c1=iClose(_Symbol,PERIOD_H1,1),o1=iOpen(_Symbol,PERIOD_H1,1);
   double h1=iHigh(_Symbol,PERIOD_H1,1),l1=iLow(_Symbol,PERIOD_H1,1);

   // DEAD MARKET FILTER
   if(adx[0]<InpDeadMarketADX) return;

   // Strategy 1: MultiFilter
   if(!HasPos(InpMF_Magic)){
      double bd=MathAbs(c1-o1);
      if(adx[0]>=InpMF_ADXMin && bd>=atr[0]*InpMF_MinBodyATR){
         bool mu=(mh>mhp)&&(mh>-0.5), md=(mh<mhp)&&(mh<0.5);
         if(g1>g2&&mu&&c1>g1&&c1>ema[0]&&rsi[0]<InpMF_RSIOB){mfP=1;mfA=atr[0];}
         else if(g1<g2&&md&&c1<g1&&c1<ema[0]&&rsi[0]>InpMF_RSIOS){mfP=-1;mfA=atr[0];}
      }
   }

   // Strategy 2: Channel Bounce
   if(!HasPos(InpCH_Magic)){
      double up=g1+atr[0]*InpCH_BandMult, lo=g1-atr[0]*InpCH_BandMult;
      if(g1>g2&&c1>g1&&l1<=lo+atr[0]*0.3&&c1>l1&&rsi[0]<InpCH_RSIOB){chP=1;chA=atr[0];}
      else if(g1<g2&&c1<g1&&h1>=up-atr[0]*0.3&&c1<h1&&rsi[0]>InpCH_RSIOS){chP=-1;chA=atr[0];}
   }

   // Strategy 3: GaussMACD
   if(!HasPos(InpGM_Magic)){
      double gg1=GF(InpGM_GaussPeriod,InpGM_GaussPoles,1);
      double gg2=GF(InpGM_GaussPeriod,InpGM_GaussPoles,2);
      if(gg1!=0){
         bool mu=(mh>mhp)&&(mh>-0.5), md=(mh<mhp)&&(mh<0.5);
         if(gg1>gg2&&mu&&c1>gg1&&rsi[0]<InpGM_RSIOB){gmP=1;gmA=atr[0];}
         else if(gg1<gg2&&md&&c1<gg1&&rsi[0]>InpGM_RSIOS){gmP=-1;gmA=atr[0];}
      }
   }
}
