//+------------------------------------------------------------------+
//|                                                 A_SMC_EA.mq5     |
//|    Smart Money Concepts (SMC) Expert Advisor - simplified, clear |
//+------------------------------------------------------------------+
#property copyright "SMC EA"
#property link      ""
#property version   "1.00"
#property strict

#include <Trade\trade.mqh>

//--- Inputs: core
input int      MagicNumber          = 777777;    // Magic number for orders
input double   FixedLot             = 0.01;      // Fixed lot when RiskPercent = 0
input double   RiskPercent          = 1.0;       // Risk per trade (percent of balance), 0 = fixed lot
input double   MaxSpreadPoints      = 100.0;     // Max spread in points allowed for trading
input bool     EnableTrading        = true;      // Master switch

//--- Inputs: SMC detection
input int      LookbackSwing        = 30;        // Lookback bars to find swings
input double   MinImpulsePips       = 5.0;       // Minimum impulse move (pips) to qualify order block
input int      OB_ZoneBufferPips    = 20;        // Buffer for OB zone in pips
input int      FVG_LookbackBars     = 30;        // Lookback window for FVG detection

//--- Inputs: trade management
input double   SLBufferPips         = 2.0;       // SL buffer in pips beyond OB
input int      TakeProfit1_RR       = 1;         // TP1 at 1:1
input int      TakeProfit2_RR       = 2;         // TP2 at 1:2
input int      TakeProfit3_RR       = 3;         // TP3 at 1:3
input bool     UseTrailingStop      = true;
input int      TrailingStartPips    = 20;        // start trailing after this many pips
input int      TrailingStepPips     = 5;         // trailing step
input bool     UseBreakEven         = true;
input int      BreakEvenPips        = 15;        // move SL to break-even after this many pips

//--- Inputs: sessions (simple hh:mm ranges, server time)
input string   Session1_Start       = "00:00";  // Allow all hours
input string   Session1_End         = "23:59";

//--- Debug
input bool     DebugMode            = true;

//--- Global variables
CTrade         trade;
datetime       lastBarTime = 0;

//--- Helper types
struct OBStruct
{
   double low;
   double high;
   int    bar_index; // index on timeframe where OB found
};

struct FVGStruct
{
   double left; // upper for bearish FVG or lower for bullish
   double right;
   int    from_index;
   int    to_index;
};

//+------------------------------------------------------------------+
//| Utility: convert hh:mm string to minutes of day                  |
//+------------------------------------------------------------------+
int TimeToMinutes(string t)
{
   int hh = StringToInteger(StringSubstr(t,0,2));
   int mm = StringToInteger(StringSubstr(t,3,2));
   return hh*60 + mm;
}

//+------------------------------------------------------------------+
//| Utility: check if current server time is inside allowed session  |
//+------------------------------------------------------------------+
bool InSession()
{
   datetime now = TimeCurrent();
   MqlDateTime dt; TimeToStruct(now, dt);
   int minutes = dt.hour*60 + dt.min;
   int s1 = TimeToMinutes(Session1_Start);
   int e1 = TimeToMinutes(Session1_End);
   if(s1 <= e1) return (minutes >= s1 && minutes <= e1);
   return (minutes >= s1 || minutes <= e1);
}

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit()
{
   Print("A_SMC_EA initializing...");
   lastBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| OnTick: lightweight - only act on new bar and delegate           |
//+------------------------------------------------------------------+
void OnTick()
{
   if(!EnableTrading) return;

   // check session
   if(!InSession())
   {
      if(DebugMode) Print("Outside trading session - skipping");
      return;
   }

   datetime tb = iTime(_Symbol, PERIOD_M5, 0);
   if(tb == lastBarTime) return; // wait for new completed M5 bar
   lastBarTime = tb;

   // check spread
   double spread_points = (SymbolInfoDouble(_Symbol,SYMBOL_ASK) - SymbolInfoDouble(_Symbol,SYMBOL_BID)) / SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   if(spread_points > MaxSpreadPoints)
   {
      if(DebugMode) Print("Spread too high: ", spread_points);
      return;
   }

   // Only open one position per symbol/magic
   if(HasOpenPosition())
   {
      if(DebugMode) Print("Open position exists - management only");
      ManageOpenPosition();
      return;
   }

   // analyze structure on M5 and H1
   AnalyzeAndTrade();
}

//+------------------------------------------------------------------+
//| HasOpenPosition - checks positions for this EA and symbol        |
//+------------------------------------------------------------------+
bool HasOpenPosition()
{
   for(int i=0;i<PositionsTotal();i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
      {
         if(PositionGetString(POSITION_SYMBOL)==_Symbol && PositionGetInteger(POSITION_MAGIC)==MagicNumber)
            return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| ManageOpenPosition - trailing, break-even                          |
//+------------------------------------------------------------------+
void ManageOpenPosition()
{
   for(int i=0;i<PositionsTotal();i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=MagicNumber) continue;

      double price = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl    = PositionGetDouble(POSITION_SL);
      double pr    = PositionGetDouble(POSITION_PROFIT);
      long type    = PositionGetInteger(POSITION_TYPE);
      double current = SymbolInfoDouble(_Symbol, type==POSITION_TYPE_BUY?SYMBOL_BID:SYMBOL_ASK);
      double point = SymbolInfoDouble(_Symbol,SYMBOL_POINT);
      double pip = point * ((_Digits==5||_Digits==3)?10:1);

      // break-even
      if(UseBreakEven)
      {
         double movePips = (type==POSITION_TYPE_BUY) ? (current - price)/pip : (price - current)/pip;
         if(movePips >= BreakEvenPips && sl==0)
         {
            double be = (type==POSITION_TYPE_BUY) ? price +  (2*pip) : price - (2*pip);
            trade.PositionModify(ticket, be, PositionGetDouble(POSITION_TP));
            if(DebugMode) Print("Moved SL to break-even for position ", ticket);
         }
      }

      // trailing
      if(UseTrailingStop)
      {
         double movePips = (type==POSITION_TYPE_BUY) ? (current - price)/pip : (price - current)/pip;
         if(movePips >= TrailingStartPips)
         {
            double newSL = (type==POSITION_TYPE_BUY) ? current - (TrailingStepPips*pip) : current + (TrailingStepPips*pip);
            // ensure not to move SL backwards
            if((type==POSITION_TYPE_BUY && newSL>sl) || (type==POSITION_TYPE_SELL && newSL<sl))
            {
               trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
               if(DebugMode) Print("Trailing SL modified for pos ", ticket);
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| AnalyzeAndTrade - core SMC analysis and potential entries        |
//+------------------------------------------------------------------+
void AnalyzeAndTrade()
{
   if(DebugMode) Print("=== AnalyzeAndTrade started ===");
   
   // Step 1: find swings on H1 to determine market structure
   double h1_high=0, h1_low=0;
   int h1_index_high=-1, h1_index_low=-1;
   bool swingsFound = FindRecentSwings(_Symbol, PERIOD_H1, LookbackSwing, h1_high, h1_low, h1_index_high, h1_index_low);

   if(DebugMode) Print("H1 swings found: ", swingsFound, " high=",h1_high," low=",h1_low);
   if(!swingsFound) { if(DebugMode) Print("Failed to find H1 swings"); return; }

   // Step 2: detect BOS/CHoCH on M5 relative to H1 swings (simplified)
   // We will check if latest M5 high breaks H1 swing high => bullish BOS
   double m5_high = iHigh(_Symbol, PERIOD_M5, 1); // previous completed bar
   double m5_low  = iLow(_Symbol, PERIOD_M5, 1);

   if(DebugMode) Print("M5 bar: high=",m5_high," low=",m5_low);

   bool bullishBOS = (m5_high > h1_high);
   bool bearishBOS = (m5_low  < h1_low);

   if(DebugMode) Print("BOS check: bullish=",bullishBOS," bearish=",bearishBOS);

   // Step 3: find order blocks and FVGs on H1 and M5
   OBStruct bullishOB = FindBullishOrderBlock(_Symbol, PERIOD_H1, LookbackSwing, MinImpulsePips);
   OBStruct bearishOB = FindBearishOrderBlock(_Symbol, PERIOD_H1, LookbackSwing, MinImpulsePips);
   
   if(DebugMode) Print("Bullish OB: bar_index=",bullishOB.bar_index," low=",bullishOB.low," high=",bullishOB.high);
   if(DebugMode) Print("Bearish OB: bar_index=",bearishOB.bar_index," low=",bearishOB.low," high=",bearishOB.high);
   
   // find FVG on M5
   FVGStruct fvg = FindFVG(_Symbol, PERIOD_M5, FVG_LookbackBars);
   
   if(DebugMode) Print("FVG: from_index=",fvg.from_index," left=",fvg.left," right=",fvg.right);

   // Step 4: Simplified logic - if OB found and price in zone, take the trade
   double currentBid = SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double point = SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   double pip = point*((_Digits==5||_Digits==3)?10:1);

   // bullish scenario - prioritize bullish if BOS detected, but don't require it
   if(bullishOB.bar_index!=-1)
   {
      double zoneLow = bullishOB.low - OB_ZoneBufferPips * pip;
      double zoneHigh = bullishOB.high + OB_ZoneBufferPips * pip;
      if(DebugMode) Print("Bullish OB zone: ",zoneLow," to ",zoneHigh," currentBid=",currentBid);
      
      if(currentBid >= zoneLow && currentBid <= zoneHigh)
      {
         if(DebugMode) Print("Price in bullish OB zone - PLACING BUY");
         PlaceBuyAtMarket(bullishOB);
         return;
      }
   }
   else
   {
      if(DebugMode) Print("No bullish OB found");
   }

   // bearish scenario
   if(bearishOB.bar_index!=-1)
   {
      double zoneLow = bearishOB.low - OB_ZoneBufferPips * pip;
      double zoneHigh = bearishOB.high + OB_ZoneBufferPips * pip;
      if(DebugMode) Print("Bearish OB zone: ",zoneLow," to ",zoneHigh," currentBid=",currentBid);
      
      if(currentBid >= zoneLow && currentBid <= zoneHigh)
      {
         if(DebugMode) Print("Price in bearish OB zone - PLACING SELL");
         PlaceSellAtMarket(bearishOB);
         return;
      }
   }
   else
   {
      if(DebugMode) Print("No bearish OB found");
   }
   
   if(DebugMode) Print("=== AnalyzeAndTrade completed - no trade conditions met ===");
}

//+------------------------------------------------------------------+
//| PlaceBuyAtMarket - compute SL/TP and send market buy order       |
//+------------------------------------------------------------------+
void PlaceBuyAtMarket(OBStruct &ob)
{
   double ask = SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double point = SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   double pip = point*((_Digits==5||_Digits==3)?10:1);

   double sl_price = ob.low - SLBufferPips * pip;
   double rr = TakeProfit2_RR; // default mid TP
   double distance = ask - sl_price;
   if(distance<=0) { if(DebugMode) Print("Invalid SL distance"); return; }

   double tp1 = ask + distance * TakeProfit1_RR;
   double tp2 = ask + distance * TakeProfit2_RR;
   double tp3 = ask + distance * TakeProfit3_RR;

   double lots = ComputeLotsFromRisk(distance);
   if(lots<=0) { if(DebugMode) Print("Lots calculated 0"); return; }

   // send market buy
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(10);
   bool ok = trade.Buy(lots, NULL, ask, sl_price, tp2, "SMC Buy");
   if(!ok) Print("Buy failed: ", GetLastError());
   else Print("Buy placed: lots=",lots," SL=",sl_price," TP=",tp2);
}

//+------------------------------------------------------------------+
//| PlaceSellAtMarket                                                 |
//+------------------------------------------------------------------+
void PlaceSellAtMarket(OBStruct &ob)
{
   double bid = SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double point = SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   double pip = point*((_Digits==5||_Digits==3)?10:1);

   double sl_price = ob.high + SLBufferPips * pip;
   double distance = sl_price - bid;
   if(distance<=0) { if(DebugMode) Print("Invalid SL distance"); return; }

   double tp1 = bid - distance * TakeProfit1_RR;
   double tp2 = bid - distance * TakeProfit2_RR;
   double tp3 = bid - distance * TakeProfit3_RR;

   double lots = ComputeLotsFromRisk(distance);
   if(lots<=0) { if(DebugMode) Print("Lots calculated 0"); return; }

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(10);
   bool ok = trade.Sell(lots, NULL, bid, sl_price, tp2, "SMC Sell");
   if(!ok) Print("Sell failed: ", GetLastError());
   else Print("Sell placed: lots=",lots," SL=",sl_price," TP=",tp2);
}

//+------------------------------------------------------------------+
//| ComputeLotsFromRisk - return lots based on RiskPercent (balance) |
//+------------------------------------------------------------------+
double ComputeLotsFromRisk(double slDistancePrice)
{
   if(RiskPercent<=0) return FixedLot;
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount = balance * (RiskPercent/100.0);
   double point = SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   double pip = point*((_Digits==5||_Digits==3)?10:1);
   double slPips = slDistancePrice / pip;

   // pip value per lot (approx)
   double tickValue = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   if(tickSize==0) return FixedLot;
   double pipValuePerLot = (tickValue/tickSize)*point;
   if(pipValuePerLot==0) return FixedLot;

   double lots = riskAmount / (slPips * pipValuePerLot);
   double lotStep = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   double minLot = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   if(lotStep<=0) return FixedLot;
   lots = MathFloor(lots/lotStep)*lotStep;
   lots = MathMax(minLot, MathMin(maxLot, lots));
   return lots;
}

//+------------------------------------------------------------------+
//| FindRecentSwings - simple local extrema finder on timeframe      |
//+------------------------------------------------------------------+
bool FindRecentSwings(string symbol, ENUM_TIMEFRAMES tf, int lookback, double &outHigh, double &outLow, int &highIndex, int &lowIndex)
{
   MqlRates rates[]; ArraySetAsSeries(rates,true);
   if(CopyRates(symbol, tf, 0, lookback, rates) < lookback) return false;
   double maxH = rates[0].high; int maxI=0; double minL = rates[0].low; int minI=0;
   for(int i=1;i<lookback;i++)
   {
      if(rates[i].high>maxH) { maxH=rates[i].high; maxI=i; }
      if(rates[i].low<minL)  { minL=rates[i].low;  minI=i; }
   }
   outHigh = maxH; outLow = minL; highIndex=maxI; lowIndex=minI; return true;
}

//+------------------------------------------------------------------+
//| FindBullishOrderBlock - simple heuristic: last bearish candle    |
//| before a big bullish move on timeframe                           |
//+------------------------------------------------------------------+
OBStruct FindBullishOrderBlock(string symbol, ENUM_TIMEFRAMES tf, int lookback, double minImpulsePips)
{
   OBStruct ob; ob.bar_index=-1; ob.low=0; ob.high=0;
   MqlRates r[]; ArraySetAsSeries(r,true);
   if(CopyRates(symbol, tf, 0, lookback, r) < lookback) return ob;
   double point = SymbolInfoDouble(symbol,SYMBOL_POINT);
   double pip = point*((_Digits==5||_Digits==3)?10:1);
   for(int i=1;i<lookback-1;i++)
   {
      // find bullish impulse: current candle bull and large body compared to previous
      double body = MathAbs(r[i].close - r[i].open);
      double prevBody = MathAbs(r[i+1].close - r[i+1].open);
      double impulsePips = (r[i].high - r[i].low)/pip;
      if(r[i].close>r[i].open && impulsePips>=minImpulsePips)
      {
         // order block is the last bearish candle before the impulse
         if(r[i+1].close < r[i+1].open)
         {
            ob.low = r[i+1].low; ob.high = r[i+1].high; ob.bar_index = i+1; return ob;
         }
      }
   }
   return ob;
}

//+------------------------------------------------------------------+
//| FindBearishOrderBlock                                             |
//+------------------------------------------------------------------+
OBStruct FindBearishOrderBlock(string symbol, ENUM_TIMEFRAMES tf, int lookback, double minImpulsePips)
{
   OBStruct ob; ob.bar_index=-1; ob.low=0; ob.high=0;
   MqlRates r[]; ArraySetAsSeries(r,true);
   if(CopyRates(symbol, tf, 0, lookback, r) < lookback) return ob;
   double point = SymbolInfoDouble(symbol,SYMBOL_POINT);
   double pip = point*((_Digits==5||_Digits==3)?10:1);
   for(int i=1;i<lookback-1;i++)
   {
      double impulsePips = (r[i].high - r[i].low)/pip;
      if(r[i].close<r[i].open && impulsePips>=minImpulsePips)
      {
         if(r[i+1].close > r[i+1].open)
         {
            ob.low = r[i+1].low; ob.high = r[i+1].high; ob.bar_index = i+1; return ob;
         }
      }
   }
   return ob;
}

//+------------------------------------------------------------------+
//| FindFVG - simple fair value gap detection on timeframe           |
//+------------------------------------------------------------------+
FVGStruct FindFVG(string symbol, ENUM_TIMEFRAMES tf, int lookback)
{
   FVGStruct f; f.from_index=-1; f.to_index=-1; f.left=0; f.right=0;
   MqlRates r[]; ArraySetAsSeries(r,true);
   if(CopyRates(symbol, tf, 0, lookback, r) < lookback) return f;
   // FVG detection: check for rapid move creating gap-like imbalance
   for(int i=2;i<lookback-2;i++)
   {
      // if the middle candle's body does not overlap neighbors, mark as FVG
      if(r[i].low > r[i+1].high)
      {
         f.from_index = i+1; f.to_index = i; f.left = r[i+1].high; f.right = r[i].low; return f;
      }
      if(r[i].high < r[i+1].low)
      {
         f.from_index = i+1; f.to_index = i; f.left = r[i].low; f.right = r[i+1].high; return f;
      }
   }
   return f;
}

//+------------------------------------------------------------------+
//| Rejection patterns - simple candle validation                    |
//+------------------------------------------------------------------+
bool IsBullishRejection()
{
   MqlRates r[]; ArraySetAsSeries(r,true);
   if(CopyRates(_Symbol,PERIOD_M5,0,2,r) < 2) return false;
   double body = r[1].close - r[1].open;
   double lowerWick = r[1].open - r[1].low;
   // More permissive: any bullish candle with lower wick
   if(body>0 && lowerWick > MathAbs(body)*0.3) return true;
   // Also accept hammer-like patterns even if body is small
   if(r[1].close >= r[1].open && lowerWick > (r[1].high-r[1].low)*0.4) return true;
   return false;
}

bool IsBearishRejection()
{
   MqlRates r[]; ArraySetAsSeries(r,true);
   if(CopyRates(_Symbol,PERIOD_M5,0,2,r) < 2) return false;
   double body = r[1].open - r[1].close;
   double upperWick = r[1].high - r[1].open;
   // More permissive: any bearish candle with upper wick
   if(body>0 && upperWick > MathAbs(body)*0.3) return true;
   // Also accept shooting star patterns
   if(r[1].close <= r[1].open && upperWick > (r[1].high-r[1].low)*0.4) return true;
   return false;
}

//+------------------------------------------------------------------+
//| OnDeinit and other handlers omitted for brevity                  |
//+------------------------------------------------------------------+
