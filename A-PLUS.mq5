//+------------------------------------------------------------------+
//|                                        A_Plus_Confluence_EA.mq5  |
//|                                           Advanced Trading System |
//|                                                                  |
//+------------------------------------------------------------------+
#property copyright "A+ Confluence EA"
#property link      ""
#property version   "1.00"

// --- EA Core Settings ---
input int      MagicNumber = 1337;         // EA Magic Number
input double   LotSize = 0.01;             // Fixed Lot Size (if RiskPercent is 0)
input double   RiskPercent = 1.0;          // Risk as a percentage of account balance (0 to disable)
input double   MaxSpreadInPoints = 20.0;   // Maximum allowed spread in points

// --- Strategy Timeframes & Indicators ---
input ENUM_TIMEFRAMES HTF = PERIOD_H1;         // Higher Timeframe for Trend Analysis
input ENUM_TIMEFRAMES LTF = PERIOD_M5;         // Lower Timeframe for Entry (Chart EA runs on)
input int      EMAPeriod = 50;               // EMA Period for HTF Trend
input ENUM_MA_METHOD EMAMethod = MODE_EMA;   // EMA Method

// --- Fibonacci Settings ---
input double   FibRetracementLevel = 0.618;  // Key Fibonacci Retracement Level
input double   TakeProfitFibLevel = 1.618;   // Fibonacci Extension for Take Profit

// --- Stop Loss & Zone Settings ---
input double   SLBufferPips = 5.0;           // Buffer for Stop Loss in Pips
input double   KeyZoneBufferPips = 10.0;     // Buffer to create a 'zone' around key levels

// --- Debug Settings ---
input bool     Debug_Mode = true;            // Show Debug Messages

//--- Global Variables
int emaHandle;
int vwapHandle;
datetime lastBarTime = 0;
double emaBuffer[];

// Structure to hold swing point data
struct SwingPoints
{
   double swingHigh;
   double swingLow;
   int highIndex;
   int lowIndex;
};

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   //--- Initialize EMA indicator on HTF
   emaHandle = iMA(_Symbol, HTF, EMAPeriod, 0, EMAMethod, PRICE_CLOSE);
   
   if(emaHandle == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create EMA indicator handle");
      return(INIT_FAILED);
   }
   
   //--- Set arrays as series
   ArraySetAsSeries(emaBuffer, true);
   
   //--- Initialize lastBarTime
   lastBarTime = iTime(_Symbol, LTF, 0);
   
   Print("=== A+ Confluence EA Initialized Successfully ===");
   Print("HTF: ", EnumToString(HTF), " | LTF: ", EnumToString(LTF));
   Print("EMA Period: ", EMAPeriod, " | Fib Retracement: ", FibRetracementLevel);
   Print("Risk Management: ", (RiskPercent > 0 ? DoubleToString(RiskPercent, 2) + "%" : "Fixed " + DoubleToString(LotSize, 2) + " lots"));
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   //--- Release indicator handles
   if(emaHandle != INVALID_HANDLE)
      IndicatorRelease(emaHandle);
      
   Print("A+ Confluence EA stopped. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- Check for new bar on LTF
   datetime currentBarTime = iTime(_Symbol, LTF, 0);
   if(currentBarTime == lastBarTime)
      return;
   lastBarTime = currentBarTime;
   
   if(Debug_Mode) Print("=== NEW ", EnumToString(LTF), " BAR ===");
   
   //--- Check if already have open position
   if(HasOpenPosition())
   {
      if(Debug_Mode) Print("Position already open - waiting");
      return;
   }
   
   //--- Check spread
   if(!IsSpreadAcceptable())
   {
      if(Debug_Mode) Print("Spread too high - skipping");
      return;
   }
   
   //--- Main trading logic
   CheckForTradeSetup();
}

//+------------------------------------------------------------------+
//| Check for trade setup on new bar                                 |
//+------------------------------------------------------------------+
void CheckForTradeSetup()
{
   //--- Copy EMA data
   if(CopyBuffer(emaHandle, 0, 0, 3, emaBuffer) < 3)
   {
      Print("ERROR: Failed to copy EMA buffer");
      return;
   }
   
   //--- Check for BUY setup
   if(CheckBuySetup())
   {
      ExecuteBuyTrade();
   }
   //--- Check for SELL setup
   else if(CheckSellSetup())
   {
      ExecuteSellTrade();
   }
}

//+------------------------------------------------------------------+
//| Check for BUY setup conditions                                   |
//+------------------------------------------------------------------+
bool CheckBuySetup()
{
   if(Debug_Mode) Print("Checking BUY setup...");
   
   //--- 1. HTF Trend Check: Price above EMA on HTF
   MqlRates htfRates[];
   ArraySetAsSeries(htfRates, true);
   if(CopyRates(_Symbol, HTF, 0, 3, htfRates) < 3)
   {
      Print("ERROR: Failed to copy HTF rates");
      return false;
   }
   
   double htfClose = htfRates[1].close;  // Previous completed HTF candle
   double htfEMA = emaBuffer[1];
   
   if(htfClose <= htfEMA)
   {
      if(Debug_Mode) Print("✗ BUY: HTF price below EMA (", htfClose, " <= ", htfEMA, ")");
      return false;
   }
   if(Debug_Mode) Print("✓ BUY: HTF bullish trend confirmed (", htfClose, " > ", htfEMA, ")");
   
   //--- 2. Identify swing points on HTF
   SwingPoints swings = IdentifySwingPoints(true);
   if(swings.swingLow == 0 || swings.swingHigh == 0)
   {
      if(Debug_Mode) Print("✗ BUY: Could not identify valid swing points");
      return false;
   }
   if(Debug_Mode) Print("✓ BUY: Swing Low=", swings.swingLow, " | Swing High=", swings.swingHigh);
   
   //--- 3. Calculate Fibonacci retracement
   double fibRetracement = CalculateFibRetracement(swings.swingLow, swings.swingHigh, FibRetracementLevel);
   if(Debug_Mode) Print("Fib 61.8% level: ", fibRetracement);
   
   //--- 4. Check if price is in support zone (previous resistance now support)
   double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double keyZone = FindKeyZoneBuy(swings.swingLow, swings.swingHigh);
   
   if(!IsPriceInZone(currentPrice, keyZone, KeyZoneBufferPips))
   {
      if(Debug_Mode) Print("✗ BUY: Price not in key support zone (", currentPrice, " vs ", keyZone, ")");
      return false;
   }
   if(Debug_Mode) Print("✓ BUY: Price in support zone");
   
   //--- 5. Check Fibonacci confluence
   if(!IsPriceInZone(currentPrice, fibRetracement, KeyZoneBufferPips))
   {
      if(Debug_Mode) Print("✗ BUY: No Fibonacci confluence (", currentPrice, " vs ", fibRetracement, ")");
      return false;
   }
   if(Debug_Mode) Print("✓ BUY: Fibonacci confluence confirmed");
   
   //--- 6. Check VWAP pullback
   double vwap = CalculateVWAP();
   if(!IsPriceNearVWAP(currentPrice, vwap))
   {
      if(Debug_Mode) Print("✗ BUY: Price not near VWAP (", currentPrice, " vs ", vwap, ")");
      return false;
   }
   if(Debug_Mode) Print("✓ BUY: Price near VWAP");
   
   //--- 7. Check for Bullish Outside Candle
   if(!IsBullishOutsideCandle())
   {
      if(Debug_Mode) Print("✗ BUY: No Bullish Outside Candle");
      return false;
   }
   if(Debug_Mode) Print("✓✓✓ BUY: Bullish Outside Candle confirmed - ALL CONDITIONS MET!");
   
   return true;
}

//+------------------------------------------------------------------+
//| Check for SELL setup conditions                                  |
//+------------------------------------------------------------------+
bool CheckSellSetup()
{
   if(Debug_Mode) Print("Checking SELL setup...");
   
   //--- 1. HTF Trend Check: Price below EMA on HTF
   MqlRates htfRates[];
   ArraySetAsSeries(htfRates, true);
   if(CopyRates(_Symbol, HTF, 0, 3, htfRates) < 3)
   {
      Print("ERROR: Failed to copy HTF rates");
      return false;
   }
   
   double htfClose = htfRates[1].close;  // Previous completed HTF candle
   double htfEMA = emaBuffer[1];
   
   if(htfClose >= htfEMA)
   {
      if(Debug_Mode) Print("✗ SELL: HTF price above EMA (", htfClose, " >= ", htfEMA, ")");
      return false;
   }
   if(Debug_Mode) Print("✓ SELL: HTF bearish trend confirmed (", htfClose, " < ", htfEMA, ")");
   
   //--- 2. Identify swing points on HTF
   SwingPoints swings = IdentifySwingPoints(false);
   if(swings.swingLow == 0 || swings.swingHigh == 0)
   {
      if(Debug_Mode) Print("✗ SELL: Could not identify valid swing points");
      return false;
   }
   if(Debug_Mode) Print("✓ SELL: Swing High=", swings.swingHigh, " | Swing Low=", swings.swingLow);
   
   //--- 3. Calculate Fibonacci retracement (from high to low for bearish)
   double fibRetracement = CalculateFibRetracement(swings.swingHigh, swings.swingLow, FibRetracementLevel);
   if(Debug_Mode) Print("Fib 61.8% level: ", fibRetracement);
   
   //--- 4. Check if price is in resistance zone (previous support now resistance)
   double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double keyZone = FindKeyZoneSell(swings.swingLow, swings.swingHigh);
   
   if(!IsPriceInZone(currentPrice, keyZone, KeyZoneBufferPips))
   {
      if(Debug_Mode) Print("✗ SELL: Price not in key resistance zone (", currentPrice, " vs ", keyZone, ")");
      return false;
   }
   if(Debug_Mode) Print("✓ SELL: Price in resistance zone");
   
   //--- 5. Check Fibonacci confluence
   if(!IsPriceInZone(currentPrice, fibRetracement, KeyZoneBufferPips))
   {
      if(Debug_Mode) Print("✗ SELL: No Fibonacci confluence (", currentPrice, " vs ", fibRetracement, ")");
      return false;
   }
   if(Debug_Mode) Print("✓ SELL: Fibonacci confluence confirmed");
   
   //--- 6. Check VWAP pullback
   double vwap = CalculateVWAP();
   if(!IsPriceNearVWAP(currentPrice, vwap))
   {
      if(Debug_Mode) Print("✗ SELL: Price not near VWAP (", currentPrice, " vs ", vwap, ")");
      return false;
   }
   if(Debug_Mode) Print("✓ SELL: Price near VWAP");
   
   //--- 7. Check for Bearish Outside Candle
   if(!IsBearishOutsideCandle())
   {
      if(Debug_Mode) Print("✗ SELL: No Bearish Outside Candle");
      return false;
   }
   if(Debug_Mode) Print("✓✓✓ SELL: Bearish Outside Candle confirmed - ALL CONDITIONS MET!");
   
   return true;
}

//+------------------------------------------------------------------+
//| Identify swing points on HTF                                     |
//+------------------------------------------------------------------+
SwingPoints IdentifySwingPoints(bool forBuy)
{
   SwingPoints swings;
   swings.swingHigh = 0;
   swings.swingLow = 0;
   swings.highIndex = -1;
   swings.lowIndex = -1;
   
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   
   int lookback = 100;  // Look back 100 bars on HTF
   if(CopyRates(_Symbol, HTF, 0, lookback, rates) < lookback)
      return swings;
   
   //--- Find swing high and swing low
   if(forBuy)
   {
      //--- For buy: find recent swing low and swing high
      //--- Look for lowest low (support) and highest high after it (resistance)
      double lowestLow = rates[0].low;
      int lowestIndex = 0;
      
      for(int i = 1; i < lookback / 2; i++)
      {
         if(rates[i].low < lowestLow)
         {
            lowestLow = rates[i].low;
            lowestIndex = i;
         }
      }
      
      //--- Find highest high after the lowest low
      double highestHigh = rates[0].high;
      int highestIndex = 0;
      
      for(int i = 0; i < lowestIndex; i++)
      {
         if(rates[i].high > highestHigh)
         {
            highestHigh = rates[i].high;
            highestIndex = i;
         }
      }
      
      swings.swingLow = lowestLow;
      swings.swingHigh = highestHigh;
      swings.lowIndex = lowestIndex;
      swings.highIndex = highestIndex;
   }
   else
   {
      //--- For sell: find recent swing high and swing low
      //--- Look for highest high (resistance) and lowest low after it (support)
      double highestHigh = rates[0].high;
      int highestIndex = 0;
      
      for(int i = 1; i < lookback / 2; i++)
      {
         if(rates[i].high > highestHigh)
         {
            highestHigh = rates[i].high;
            highestIndex = i;
         }
      }
      
      //--- Find lowest low after the highest high
      double lowestLow = rates[0].low;
      int lowestIndex = 0;
      
      for(int i = 0; i < highestIndex; i++)
      {
         if(rates[i].low < lowestLow)
         {
            lowestLow = rates[i].low;
            lowestIndex = i;
         }
      }
      
      swings.swingHigh = highestHigh;
      swings.swingLow = lowestLow;
      swings.highIndex = highestIndex;
      swings.lowIndex = lowestIndex;
   }
   
   return swings;
}

//+------------------------------------------------------------------+
//| Calculate Fibonacci retracement level                            |
//+------------------------------------------------------------------+
double CalculateFibRetracement(double startPrice, double endPrice, double fibLevel)
{
   double difference = endPrice - startPrice;
   return endPrice - (difference * fibLevel);
}

//+------------------------------------------------------------------+
//| Find key support zone for BUY (previous resistance)              |
//+------------------------------------------------------------------+
double FindKeyZoneBuy(double swingLow, double swingHigh)
{
   //--- Simplified: Use midpoint between swing low and high
   //--- In production, you'd identify actual resistance levels that broke
   return swingLow + ((swingHigh - swingLow) * 0.382);  // 38.2% level as support
}

//+------------------------------------------------------------------+
//| Find key resistance zone for SELL (previous support)             |
//+------------------------------------------------------------------+
double FindKeyZoneSell(double swingLow, double swingHigh)
{
   //--- Simplified: Use midpoint between swing high and low
   //--- In production, you'd identify actual support levels that broke
   return swingHigh - ((swingHigh - swingLow) * 0.382);  // 38.2% level as resistance
}

//+------------------------------------------------------------------+
//| Check if price is within a zone (with buffer)                    |
//+------------------------------------------------------------------+
bool IsPriceInZone(double price, double zoneLevel, double bufferPips)
{
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double buffer = bufferPips * point * ((_Digits == 5 || _Digits == 3) ? 10.0 : 1.0);
   
   return (price >= zoneLevel - buffer && price <= zoneLevel + buffer);
}

//+------------------------------------------------------------------+
//| Calculate VWAP (Volume Weighted Average Price) for the day       |
//+------------------------------------------------------------------+
double CalculateVWAP()
{
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   
   //--- Get today's data on LTF
   datetime todayStart = iTime(_Symbol, PERIOD_D1, 0);
   int bars = Bars(_Symbol, LTF, todayStart, TimeCurrent());
   
   if(bars < 1 || CopyRates(_Symbol, LTF, 0, bars, rates) < bars)
      return SymbolInfoDouble(_Symbol, SYMBOL_BID);  // Fallback to current price
   
   double totalVolPrice = 0;
   long totalVolume = 0;
   
   for(int i = 0; i < bars; i++)
   {
      double typical = (rates[i].high + rates[i].low + rates[i].close) / 3.0;
      totalVolPrice += typical * (double)rates[i].tick_volume;
      totalVolume += rates[i].tick_volume;
   }
   
   if(totalVolume == 0)
      return SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   return totalVolPrice / (double)totalVolume;
}

//+------------------------------------------------------------------+
//| Check if price is near VWAP                                      |
//+------------------------------------------------------------------+
bool IsPriceNearVWAP(double price, double vwap)
{
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double buffer = 20.0 * point * ((_Digits == 5 || _Digits == 3) ? 10.0 : 1.0);  // 20 pips buffer
   
   return MathAbs(price - vwap) <= buffer;
}

//+------------------------------------------------------------------+
//| Check for Bullish Outside Candle pattern                         |
//+------------------------------------------------------------------+
bool IsBullishOutsideCandle()
{
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   
   if(CopyRates(_Symbol, LTF, 0, 3, rates) < 3)
      return false;
   
   //--- Previous candle (index 2) should be bearish (red)
   bool previousIsBearish = rates[2].close < rates[2].open;
   
   //--- Current completed candle (index 1) should be bullish (green)
   bool currentIsBullish = rates[1].close > rates[1].open;
   
   //--- Current candle should engulf previous candle
   bool engulfsHigh = rates[1].high > rates[2].high;
   bool engulfsLow = rates[1].low < rates[2].low;
   bool engulfsBody = (rates[1].open < rates[2].close) && (rates[1].close > rates[2].open);
   
   return (previousIsBearish && currentIsBullish && engulfsHigh && engulfsLow && engulfsBody);
}

//+------------------------------------------------------------------+
//| Check for Bearish Outside Candle pattern                         |
//+------------------------------------------------------------------+
bool IsBearishOutsideCandle()
{
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   
   if(CopyRates(_Symbol, LTF, 0, 3, rates) < 3)
      return false;
   
   //--- Previous candle (index 2) should be bullish (green)
   bool previousIsBullish = rates[2].close > rates[2].open;
   
   //--- Current completed candle (index 1) should be bearish (red)
   bool currentIsBearish = rates[1].close < rates[1].open;
   
   //--- Current candle should engulf previous candle
   bool engulfsHigh = rates[1].high > rates[2].high;
   bool engulfsLow = rates[1].low < rates[2].low;
   bool engulfsBody = (rates[1].open > rates[2].close) && (rates[1].close < rates[2].open);
   
   return (previousIsBullish && currentIsBearish && engulfsHigh && engulfsLow && engulfsBody);
}

//+------------------------------------------------------------------+
//| Execute BUY trade                                                |
//+------------------------------------------------------------------+
void ExecuteBuyTrade()
{
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, LTF, 0, 2, rates) < 2)
      return;
   
   double entry = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double pipMultiplier = ((_Digits == 5 || _Digits == 3) ? 10.0 : 1.0);
   
   //--- Calculate Stop Loss: Low of signal candle minus buffer
   double sl = rates[1].low - (SLBufferPips * point * pipMultiplier);
   
   //--- Calculate Take Profit using Fibonacci extension
   SwingPoints swings = IdentifySwingPoints(true);
   double swingRange = swings.swingHigh - swings.swingLow;
   double tp = swings.swingHigh + (swingRange * (TakeProfitFibLevel - 1.0));
   
   //--- Calculate lot size based on risk
   double lots = CalculateLotSize(entry - sl);
   
   if(lots == 0)
   {
      Print("ERROR: Calculated lot size is 0");
      return;
   }
   
   //--- Execute trade
   MqlTradeRequest request = {};
   MqlTradeResult result = {};
   
   request.action = TRADE_ACTION_DEAL;
   request.symbol = _Symbol;
   request.volume = lots;
   request.type = ORDER_TYPE_BUY;
   request.price = NormalizeDouble(entry, _Digits);
   request.sl = NormalizeDouble(sl, _Digits);
   request.tp = NormalizeDouble(tp, _Digits);
   request.deviation = 10;
   request.magic = MagicNumber;
   request.comment = "A+ BUY";
   request.type_filling = ORDER_FILLING_FOK;
   
   if(!OrderSend(request, result))
   {
      Print("❌ BUY Order FAILED - Error: ", result.retcode, " - ", result.comment);
   }
   else
   {
      Print("✓✓✓ BUY Order #", result.order, " EXECUTED ✓✓✓");
      Print("    Entry: ", entry, " | SL: ", sl, " | TP: ", tp, " | Lots: ", lots);
      Print("    Risk: ", (RiskPercent > 0 ? DoubleToString(RiskPercent, 2) + "%" : "Fixed"));
   }
}

//+------------------------------------------------------------------+
//| Execute SELL trade                                               |
//+------------------------------------------------------------------+
void ExecuteSellTrade()
{
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, LTF, 0, 2, rates) < 2)
      return;
   
   double entry = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double pipMultiplier = ((_Digits == 5 || _Digits == 3) ? 10.0 : 1.0);
   
   //--- Calculate Stop Loss: High of signal candle plus buffer
   double sl = rates[1].high + (SLBufferPips * point * pipMultiplier);
   
   //--- Calculate Take Profit using Fibonacci extension
   SwingPoints swings = IdentifySwingPoints(false);
   double swingRange = swings.swingHigh - swings.swingLow;
   double tp = swings.swingLow - (swingRange * (TakeProfitFibLevel - 1.0));
   
   //--- Calculate lot size based on risk
   double lots = CalculateLotSize(sl - entry);
   
   if(lots == 0)
   {
      Print("ERROR: Calculated lot size is 0");
      return;
   }
   
   //--- Execute trade
   MqlTradeRequest request = {};
   MqlTradeResult result = {};
   
   request.action = TRADE_ACTION_DEAL;
   request.symbol = _Symbol;
   request.volume = lots;
   request.type = ORDER_TYPE_SELL;
   request.price = NormalizeDouble(entry, _Digits);
   request.sl = NormalizeDouble(sl, _Digits);
   request.tp = NormalizeDouble(tp, _Digits);
   request.deviation = 10;
   request.magic = MagicNumber;
   request.comment = "A+ SELL";
   request.type_filling = ORDER_FILLING_FOK;
   
   if(!OrderSend(request, result))
   {
      Print("❌ SELL Order FAILED - Error: ", result.retcode, " - ", result.comment);
   }
   else
   {
      Print("✓✓✓ SELL Order #", result.order, " EXECUTED ✓✓✓");
      Print("    Entry: ", entry, " | SL: ", sl, " | TP: ", tp, " | Lots: ", lots);
      Print("    Risk: ", (RiskPercent > 0 ? DoubleToString(RiskPercent, 2) + "%" : "Fixed"));
   }
}

//+------------------------------------------------------------------+
//| Calculate lot size based on risk percentage                      |
//+------------------------------------------------------------------+
double CalculateLotSize(double slDistance)
{
   //--- If risk percent is 0, use fixed lot size
   if(RiskPercent <= 0)
      return LotSize;
   
   //--- Get account info
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount = balance * (RiskPercent / 100.0);
   
   //--- Calculate pip value
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   
   if(tickSize == 0)
      return LotSize;
   
   double slInPips = slDistance / point;
   double pipValue = (tickValue / tickSize) * point;
   
   if(pipValue == 0)
      return LotSize;
   
   //--- Calculate lot size
   double lots = riskAmount / (slInPips * pipValue);
   
   //--- Normalize to broker's lot step
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   
   lots = MathFloor(lots / lotStep) * lotStep;
   lots = MathMax(minLot, MathMin(maxLot, lots));
   
   return lots;
}

//+------------------------------------------------------------------+
//| Check if spread is acceptable                                    |
//+------------------------------------------------------------------+
bool IsSpreadAcceptable()
{
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   return (spread <= MaxSpreadInPoints);
}

//+------------------------------------------------------------------+
//| Check if there's an open position for this symbol                |
//+------------------------------------------------------------------+
bool HasOpenPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionSelectByTicket(PositionGetTicket(i)))
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
            PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         {
            return true;
         }
      }
   }
   return false;
}
//+------------------------------------------------------------------+
