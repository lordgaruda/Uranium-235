//+------------------------------------------------------------------+
//|                                      Smart_Money_Scalper_EA.mq5  |
//|           Smart Money Scalping Strategy with Footprint Zones     |
//+------------------------------------------------------------------+
#property copyright "Smart Money Scalper"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

//--- Input Parameters
input group "=== Risk Management ==="
input double   RiskPercent          = 1.0;       // Risk per trade (% of balance)
input double   FixedLot             = 0.01;      // Fixed lot if RiskPercent = 0
input int      MagicNumber          = 888888;    // Magic number

input group "=== Footprint Zone Settings ==="
input int      ZoneFreshnessHours   = 3;         // Max age of zone (hours)
input int      BOS_LookbackBars     = 50;        // Bars to check for Break of Structure
input double   MinBOS_Pips          = 15.0;      // Minimum BOS move in pips
input int      ZoneBufferPips       = 3;         // Buffer around zone edges

input group "=== Pivot Confluence ==="
input double   PivotTolerancePips   = 10.0;      // Max distance zone-to-pivot for confluence

input group "=== Liquidity Sweep ==="
input int      SwingLookback        = 10;        // Bars to identify swing high/low
input double   MinSweepPips         = 3.0;       // Minimum sweep distance in pips

input group "=== Trade Management ==="
input int      SL_BufferPips        = 5;         // Stop loss buffer in pips
input double   MinRiskReward        = 1.5;       // Minimum R:R ratio
input int      MaxSpreadPoints      = 50;        // Max spread allowed

input group "=== General ==="
input bool     EnableTrading        = true;      // Master switch
input bool     DebugMode            = true;      // Debug logging

//--- Global Variables
CTrade         trade;
datetime       lastBarTime = 0;

//--- Zone Structure
struct FootprintZone
{
   datetime    createdTime;
   double      high;
   double      low;
   bool        isDemand;      // true = demand (buy), false = supply (sell)
   bool        fresh;         // true = not yet retested
   bool        hasPivotConfluence;
   int         creationBar;
};

FootprintZone demandZones[];
FootprintZone supplyZones[];

//--- Pivot Levels
struct PivotLevels
{
   double PP;  // Pivot Point
   double R1, R2, R3;
   double S1, S2, S3;
};

PivotLevels dailyPivots;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   Print("Smart Money Scalper EA initialized");
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(10);
   
   ArrayResize(demandZones, 0);
   ArrayResize(supplyZones, 0);
   
   lastBarTime = iTime(_Symbol, PERIOD_M5, 0);
   CalculateDailyPivots();
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   if(!EnableTrading) return;
   
   // Check for new M5 bar
   datetime currentBar = iTime(_Symbol, PERIOD_M5, 0);
   if(currentBar == lastBarTime) return;
   lastBarTime = currentBar;
   
   // Check spread
   double spreadPoints = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - 
                          SymbolInfoDouble(_Symbol, SYMBOL_BID)) / 
                          SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(spreadPoints > MaxSpreadPoints)
   {
      if(DebugMode) Print("Spread too high: ", spreadPoints);
      return;
   }
   
   // Only one position at a time
   if(HasOpenPosition()) return;
   
   // Update pivots daily
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.hour == 0 && dt.min < 5) CalculateDailyPivots();
   
   // Step 1: Identify new footprint zones
   IdentifyFootprintZones();
   
   // Step 2 & 3: Check confluence and liquidity sweeps for existing zones
   CheckZonesForEntry();
   
   // Clean old zones
   CleanOldZones();
}

//+------------------------------------------------------------------+
//| Check if EA has open position                                    |
//+------------------------------------------------------------------+
bool HasOpenPosition()
{
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol && 
            PositionGetInteger(POSITION_MAGIC) == MagicNumber)
            return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Calculate Daily Pivot Points                                     |
//+------------------------------------------------------------------+
void CalculateDailyPivots()
{
   MqlRates dailyBar[];
   ArraySetAsSeries(dailyBar, true);
   
   if(CopyRates(_Symbol, PERIOD_D1, 1, 1, dailyBar) < 1) return;
   
   double high = dailyBar[0].high;
   double low = dailyBar[0].low;
   double close = dailyBar[0].close;
   
   dailyPivots.PP = (high + low + close) / 3.0;
   dailyPivots.R1 = 2 * dailyPivots.PP - low;
   dailyPivots.R2 = dailyPivots.PP + (high - low);
   dailyPivots.R3 = high + 2 * (dailyPivots.PP - low);
   dailyPivots.S1 = 2 * dailyPivots.PP - high;
   dailyPivots.S2 = dailyPivots.PP - (high - low);
   dailyPivots.S3 = low - 2 * (high - dailyPivots.PP);
   
   if(DebugMode) 
      Print("Daily Pivots: PP=", dailyPivots.PP, " R1=", dailyPivots.R1, 
            " S1=", dailyPivots.S1);
}

//+------------------------------------------------------------------+
//| Identify Footprint Zones (Supply/Demand with BOS)               |
//+------------------------------------------------------------------+
void IdentifyFootprintZones()
{
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   
   if(CopyRates(_Symbol, PERIOD_M5, 0, BOS_LookbackBars, rates) < BOS_LookbackBars)
      return;
   
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double pip = point * ((_Digits == 5 || _Digits == 3) ? 10 : 1);
   
   // Look for Break of Structure
   for(int i = 5; i < BOS_LookbackBars - 5; i++)
   {
      // Find swing high/low in the past
      double recentHigh = FindSwingHigh(rates, i + 5, 10);
      double recentLow = FindSwingLow(rates, i + 5, 10);
      
      // Check for bullish BOS (demand zone)
      if(rates[i].close > recentHigh)
      {
         double bosPips = (rates[i].close - recentHigh) / pip;
         if(bosPips >= MinBOS_Pips)
         {
            // Find the last bearish candle before the impulse (footprint)
            int zoneBar = FindLastOpposingCandle(rates, i, true);
            if(zoneBar > 0)
            {
               FootprintZone zone;
               zone.createdTime = rates[zoneBar].time;
               zone.low = rates[zoneBar].low;
               zone.high = rates[zoneBar].high;
               zone.isDemand = true;
               zone.fresh = true;
               zone.creationBar = zoneBar;
               zone.hasPivotConfluence = CheckPivotConfluence(zone);
               
               // Avoid duplicates
               if(!ZoneExists(zone, true))
               {
                  AddDemandZone(zone);
                  if(DebugMode) 
                     Print("New DEMAND zone created at ", zone.low, "-", zone.high, 
                           " Pivot confluence: ", zone.hasPivotConfluence);
               }
            }
         }
      }
      
      // Check for bearish BOS (supply zone)
      if(rates[i].close < recentLow)
      {
         double bosPips = (recentLow - rates[i].close) / pip;
         if(bosPips >= MinBOS_Pips)
         {
            // Find the last bullish candle before the impulse
            int zoneBar = FindLastOpposingCandle(rates, i, false);
            if(zoneBar > 0)
            {
               FootprintZone zone;
               zone.createdTime = rates[zoneBar].time;
               zone.low = rates[zoneBar].low;
               zone.high = rates[zoneBar].high;
               zone.isDemand = false;
               zone.fresh = true;
               zone.creationBar = zoneBar;
               zone.hasPivotConfluence = CheckPivotConfluence(zone);
               
               if(!ZoneExists(zone, false))
               {
                  AddSupplyZone(zone);
                  if(DebugMode) 
                     Print("New SUPPLY zone created at ", zone.low, "-", zone.high,
                           " Pivot confluence: ", zone.hasPivotConfluence);
               }
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Find swing high in range                                         |
//+------------------------------------------------------------------+
double FindSwingHigh(MqlRates &rates[], int start, int range)
{
   double maxHigh = 0;
   for(int i = start; i < start + range && i < ArraySize(rates); i++)
      if(rates[i].high > maxHigh) maxHigh = rates[i].high;
   return maxHigh;
}

//+------------------------------------------------------------------+
//| Find swing low in range                                          |
//+------------------------------------------------------------------+
double FindSwingLow(MqlRates &rates[], int start, int range)
{
   double minLow = 999999;
   for(int i = start; i < start + range && i < ArraySize(rates); i++)
      if(rates[i].low < minLow) minLow = rates[i].low;
   return minLow;
}

//+------------------------------------------------------------------+
//| Find last opposing candle before impulse                         |
//+------------------------------------------------------------------+
int FindLastOpposingCandle(MqlRates &rates[], int impulseBar, bool lookForBearish)
{
   for(int i = impulseBar + 1; i < impulseBar + 5; i++)
   {
      if(lookForBearish)
      {
         if(rates[i].close < rates[i].open) return i;
      }
      else
      {
         if(rates[i].close > rates[i].open) return i;
      }
   }
   return -1;
}

//+------------------------------------------------------------------+
//| Check if zone has pivot confluence                               |
//+------------------------------------------------------------------+
bool CheckPivotConfluence(FootprintZone &zone)
{
   double pip = SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 
                ((_Digits == 5 || _Digits == 3) ? 10 : 1);
   double tolerance = PivotTolerancePips * pip;
   
   double zoneMid = (zone.high + zone.low) / 2.0;
   
   double pivots[] = {dailyPivots.PP, dailyPivots.R1, dailyPivots.R2, dailyPivots.R3,
                      dailyPivots.S1, dailyPivots.S2, dailyPivots.S3};
   
   for(int i = 0; i < ArraySize(pivots); i++)
   {
      if(MathAbs(zoneMid - pivots[i]) <= tolerance)
         return true;
      
      // Also check if pivot is within zone range
      if(pivots[i] >= zone.low && pivots[i] <= zone.high)
         return true;
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Check zones for entry conditions                                 |
//+------------------------------------------------------------------+
void CheckZonesForEntry()
{
   double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double pip = point * ((_Digits == 5 || _Digits == 3) ? 10 : 1);
   
   // Check demand zones for buy setups
   for(int i = 0; i < ArraySize(demandZones); i++)
   {
      if(!demandZones[i].fresh) continue;
      if(!demandZones[i].hasPivotConfluence) continue;
      
      double zoneLow = demandZones[i].low - ZoneBufferPips * pip;
      double zoneHigh = demandZones[i].high + ZoneBufferPips * pip;
      
      // Check if price is in zone
      if(currentPrice >= zoneLow && currentPrice <= zoneHigh)
      {
         if(DebugMode) Print("Price in DEMAND zone, checking liquidity sweep...");
         
         // Check for liquidity sweep (price dipped below recent low)
         if(DetectBullishLiquiditySweep())
         {
            if(DebugMode) Print("Bullish liquidity sweep detected - PLACING BUY");
            ExecuteBuyTrade(demandZones[i]);
            demandZones[i].fresh = false;
            return;
         }
      }
   }
   
   // Check supply zones for sell setups
   for(int i = 0; i < ArraySize(supplyZones); i++)
   {
      if(!supplyZones[i].fresh) continue;
      if(!supplyZones[i].hasPivotConfluence) continue;
      
      double zoneLow = supplyZones[i].low - ZoneBufferPips * pip;
      double zoneHigh = supplyZones[i].high + ZoneBufferPips * pip;
      
      if(currentPrice >= zoneLow && currentPrice <= zoneHigh)
      {
         if(DebugMode) Print("Price in SUPPLY zone, checking liquidity sweep...");
         
         if(DetectBearishLiquiditySweep())
         {
            if(DebugMode) Print("Bearish liquidity sweep detected - PLACING SELL");
            ExecuteSellTrade(supplyZones[i]);
            supplyZones[i].fresh = false;
            return;
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Detect bullish liquidity sweep (dip below recent low)           |
//+------------------------------------------------------------------+
bool DetectBullishLiquiditySweep()
{
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   
   if(CopyRates(_Symbol, PERIOD_M5, 0, SwingLookback + 5, rates) < SwingLookback + 5)
      return false;
   
   double pip = SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 
                ((_Digits == 5 || _Digits == 3) ? 10 : 1);
   
   // Find recent swing low (5-10 bars ago)
   double swingLow = 999999;
   for(int i = 2; i < SwingLookback; i++)
   {
      if(rates[i].low < swingLow) swingLow = rates[i].low;
   }
   
   // Check if price recently went below that low and reversed
   if(rates[1].low < swingLow)
   {
      double sweepPips = (swingLow - rates[1].low) / pip;
      if(sweepPips >= MinSweepPips && rates[1].close > rates[1].open)
      {
         if(DebugMode) Print("Bullish sweep: swingLow=", swingLow, " swept to=", rates[1].low);
         return true;
      }
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Detect bearish liquidity sweep (spike above recent high)        |
//+------------------------------------------------------------------+
bool DetectBearishLiquiditySweep()
{
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   
   if(CopyRates(_Symbol, PERIOD_M5, 0, SwingLookback + 5, rates) < SwingLookback + 5)
      return false;
   
   double pip = SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 
                ((_Digits == 5 || _Digits == 3) ? 10 : 1);
   
   double swingHigh = 0;
   for(int i = 2; i < SwingLookback; i++)
   {
      if(rates[i].high > swingHigh) swingHigh = rates[i].high;
   }
   
   if(rates[1].high > swingHigh)
   {
      double sweepPips = (rates[1].high - swingHigh) / pip;
      if(sweepPips >= MinSweepPips && rates[1].close < rates[1].open)
      {
         if(DebugMode) Print("Bearish sweep: swingHigh=", swingHigh, " swept to=", rates[1].high);
         return true;
      }
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Execute Buy Trade                                                |
//+------------------------------------------------------------------+
void ExecuteBuyTrade(FootprintZone &zone)
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double pip = point * ((_Digits == 5 || _Digits == 3) ? 10 : 1);
   
   double sl = zone.low - SL_BufferPips * pip;
   double slDistance = ask - sl;
   
   if(slDistance <= 0)
   {
      if(DebugMode) Print("Invalid SL distance for BUY");
      return;
   }
   
   // Find next supply zone or resistance pivot for TP
   double tp = FindNextSupplyLevel(ask);
   if(tp == 0) tp = ask + slDistance * 2.0; // Default 1:2 R:R
   
   // Check minimum R:R
   double tpDistance = tp - ask;
   if(tpDistance / slDistance < MinRiskReward)
   {
      tp = ask + slDistance * MinRiskReward;
   }
   
   double lots = CalculateLotSize(slDistance);
   
   if(trade.Buy(lots, _Symbol, ask, sl, tp, "Smart Money BUY"))
   {
      Print("BUY executed: Lot=", lots, " SL=", sl, " TP=", tp, " R:R=", tpDistance/slDistance);
   }
   else
   {
      Print("BUY failed: ", GetLastError());
   }
}

//+------------------------------------------------------------------+
//| Execute Sell Trade                                               |
//+------------------------------------------------------------------+
void ExecuteSellTrade(FootprintZone &zone)
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double pip = point * ((_Digits == 5 || _Digits == 3) ? 10 : 1);
   
   double sl = zone.high + SL_BufferPips * pip;
   double slDistance = sl - bid;
   
   if(slDistance <= 0)
   {
      if(DebugMode) Print("Invalid SL distance for SELL");
      return;
   }
   
   double tp = FindNextDemandLevel(bid);
   if(tp == 0) tp = bid - slDistance * 2.0;
   
   double tpDistance = bid - tp;
   if(tpDistance / slDistance < MinRiskReward)
   {
      tp = bid - slDistance * MinRiskReward;
   }
   
   double lots = CalculateLotSize(slDistance);
   
   if(trade.Sell(lots, _Symbol, bid, sl, tp, "Smart Money SELL"))
   {
      Print("SELL executed: Lot=", lots, " SL=", sl, " TP=", tp, " R:R=", tpDistance/slDistance);
   }
   else
   {
      Print("SELL failed: ", GetLastError());
   }
}

//+------------------------------------------------------------------+
//| Calculate lot size based on risk                                 |
//+------------------------------------------------------------------+
double CalculateLotSize(double slDistance)
{
   if(RiskPercent <= 0) return FixedLot;
   
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount = balance * (RiskPercent / 100.0);
   
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   
   if(tickSize == 0) return FixedLot;
   
   double ticksInSL = slDistance / tickSize;
   double lots = riskAmount / (ticksInSL * tickValue);
   
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   
   lots = MathFloor(lots / lotStep) * lotStep;
   lots = MathMax(minLot, MathMin(maxLot, lots));
   
   return lots;
}

//+------------------------------------------------------------------+
//| Find next supply level for TP (buy trade)                       |
//+------------------------------------------------------------------+
double FindNextSupplyLevel(double currentPrice)
{
   double closest = 0;
   double minDistance = 999999;
   
   // Check supply zones
   for(int i = 0; i < ArraySize(supplyZones); i++)
   {
      if(supplyZones[i].low > currentPrice)
      {
         double distance = supplyZones[i].low - currentPrice;
         if(distance < minDistance)
         {
            minDistance = distance;
            closest = supplyZones[i].low;
         }
      }
   }
   
   // Check resistance pivots
   double pivots[] = {dailyPivots.R1, dailyPivots.R2, dailyPivots.R3};
   for(int i = 0; i < ArraySize(pivots); i++)
   {
      if(pivots[i] > currentPrice)
      {
         double distance = pivots[i] - currentPrice;
         if(distance < minDistance)
         {
            minDistance = distance;
            closest = pivots[i];
         }
      }
   }
   
   return closest;
}

//+------------------------------------------------------------------+
//| Find next demand level for TP (sell trade)                      |
//+------------------------------------------------------------------+
double FindNextDemandLevel(double currentPrice)
{
   double closest = 0;
   double minDistance = 999999;
   
   for(int i = 0; i < ArraySize(demandZones); i++)
   {
      if(demandZones[i].high < currentPrice)
      {
         double distance = currentPrice - demandZones[i].high;
         if(distance < minDistance)
         {
            minDistance = distance;
            closest = demandZones[i].high;
         }
      }
   }
   
   double pivots[] = {dailyPivots.S1, dailyPivots.S2, dailyPivots.S3};
   for(int i = 0; i < ArraySize(pivots); i++)
   {
      if(pivots[i] < currentPrice)
      {
         double distance = currentPrice - pivots[i];
         if(distance < minDistance)
         {
            minDistance = distance;
            closest = pivots[i];
         }
      }
   }
   
   return closest;
}

//+------------------------------------------------------------------+
//| Clean old zones                                                  |
//+------------------------------------------------------------------+
void CleanOldZones()
{
   datetime currentTime = TimeCurrent();
   int maxAgeSeconds = ZoneFreshnessHours * 3600;
   
   // Clean demand zones
   for(int i = ArraySize(demandZones) - 1; i >= 0; i--)
   {
      if(currentTime - demandZones[i].createdTime > maxAgeSeconds)
      {
         ArrayRemove(demandZones, i, 1);
      }
   }
   
   // Clean supply zones
   for(int i = ArraySize(supplyZones) - 1; i >= 0; i--)
   {
      if(currentTime - supplyZones[i].createdTime > maxAgeSeconds)
      {
         ArrayRemove(supplyZones, i, 1);
      }
   }
}

//+------------------------------------------------------------------+
//| Check if zone already exists                                     |
//+------------------------------------------------------------------+
bool ZoneExists(FootprintZone &zone, bool isDemand)
{
   FootprintZone existingZones[];
   
   if(isDemand)
      ArrayCopy(existingZones, demandZones);
   else
      ArrayCopy(existingZones, supplyZones);
   
   for(int i = 0; i < ArraySize(existingZones); i++)
   {
      if(MathAbs(existingZones[i].low - zone.low) < 0.00001 &&
         MathAbs(existingZones[i].high - zone.high) < 0.00001)
         return true;
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Add demand zone                                                  |
//+------------------------------------------------------------------+
void AddDemandZone(FootprintZone &zone)
{
   int size = ArraySize(demandZones);
   ArrayResize(demandZones, size + 1);
   demandZones[size] = zone;
}

//+------------------------------------------------------------------+
//| Add supply zone                                                  |
//+------------------------------------------------------------------+
void AddSupplyZone(FootprintZone &zone)
{
   int size = ArraySize(supplyZones);
   ArrayResize(supplyZones, size + 1);
   supplyZones[size] = zone;
}

//+------------------------------------------------------------------+
