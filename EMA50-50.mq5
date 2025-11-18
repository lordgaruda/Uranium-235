//+------------------------------------------------------------------+
//|                                              EMA_Bias_Trader.mq5 |
//|                                                                  |
//|                                                                  |
//+------------------------------------------------------------------+
#property copyright "EMA Bias Trading Strategy"
#property link      ""
#property version   "1.00"

//--- Input Parameters
input int      EMA_Period = 50;                    // EMA Period
input double   RiskReward_Min = 2.0;               // Minimum Risk:Reward Ratio
input double   RiskReward_Max = 4.0;               // Maximum Risk:Reward Ratio (Strong Trends)
input double   LotSize = 0.01;                     // Lot Size
input int      Min_Trend_Strength = 5;             // Minimum Trend Strength (pips)
input bool     Detect_Traps = false;               // Detect and Skip Trap Patterns
input bool     Require_Price_Pullback = false;     // Require Pullback to EMA
input int      Pullback_Distance_Pips = 100;       // Max Pullback Distance from EMA
input bool     Use_Trend_Confirmation = false;     // Use 3-Bar Trend Confirmation
input bool     Filter_Weak_Trends = false;         // Filter Out Weak/Choppy Markets
input int      MagicNumber = 123456;               // Magic Number
input string   TradeComment = "EMA_Bias";          // Trade Comment
input bool     Debug_Mode = true;                  // Show Debug Messages

//--- Global Variables
int emaHighHandle;
int emaLowHandle;
double emaHighBuffer[];
double emaLowBuffer[];
datetime lastBarTime = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   //--- Create EMA indicators
   emaHighHandle = iMA(_Symbol, PERIOD_CURRENT, EMA_Period, 0, MODE_EMA, PRICE_HIGH);
   emaLowHandle = iMA(_Symbol, PERIOD_CURRENT, EMA_Period, 0, MODE_EMA, PRICE_LOW);
   
   if(emaHighHandle == INVALID_HANDLE || emaLowHandle == INVALID_HANDLE)
   {
      Print("Error creating EMA indicators");
      return(INIT_FAILED);
   }
   
   //--- Set array as series
   ArraySetAsSeries(emaHighBuffer, true);
   ArraySetAsSeries(emaLowBuffer, true);
   
   Print("EMA Bias Trader initialized successfully");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   //--- Release indicator handles
   if(emaHighHandle != INVALID_HANDLE) IndicatorRelease(emaHighHandle);
   if(emaLowHandle != INVALID_HANDLE) IndicatorRelease(emaLowHandle);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- Check for new bar
   datetime currentBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(currentBarTime == lastBarTime)
      return;
   lastBarTime = currentBarTime;
   
   if(Debug_Mode) Print("=== NEW BAR ===");
   
   //--- Check if we already have an open position
   if(PositionSelect(_Symbol))
   {
      if(Debug_Mode) Print("Position already open - waiting");
      return;
   }
   
   //--- Copy EMA values
   if(CopyBuffer(emaHighHandle, 0, 0, 5, emaHighBuffer) < 5 ||
      CopyBuffer(emaLowHandle, 0, 0, 5, emaLowBuffer) < 5)
   {
      Print("ERROR: Cannot copy EMA buffers");
      return;
   }
   
   //--- Determine market bias
   int bias = GetMarketBias();
   
   if(bias == 0)
   {
      return; // Skip this bar
   }
   
   //--- BULLISH BIAS - Place BUY
   if(bias == 1)
   {
      if(CheckBullishEntry())
      {
         double sl = emaLowBuffer[1];
         double entry = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double distance = entry - sl;
         
         if(distance > 0)
         {
            //--- Calculate dynamic R:R based on trend strength
            double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
            double multiplier = ((_Digits == 5 || _Digits == 3) ? 10.0 : 1.0);
            double trendStrength = (emaHighBuffer[1] - emaHighBuffer[3]) / (point * multiplier);
            double rrRatio = RiskReward_Min;
            
            //--- Use higher R:R for stronger trends
            if(trendStrength > Min_Trend_Strength * 2)
               rrRatio = RiskReward_Max;
            else if(trendStrength > Min_Trend_Strength * 1.5)
               rrRatio = (RiskReward_Min + RiskReward_Max) / 2;
            
            double tp = entry + (distance * rrRatio);
            Print(">>> EXECUTING BUY <<<");
            Print("Trend: ", (int)trendStrength, " pips | R:R 1:", rrRatio);
            Print("Entry=", entry, " | SL=", sl, " | TP=", tp);
            OpenBuyTrade(entry, sl, tp);
         }
         else
         {
            Print("Invalid BUY distance: ", distance);
         }
      }
   }
   //--- BEARISH BIAS - Place SELL
   else if(bias == -1)
   {
      if(CheckBearishEntry())
      {
         double sl = emaHighBuffer[1];
         double entry = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double distance = sl - entry;
         
         if(distance > 0)
         {
            //--- Calculate dynamic R:R based on trend strength
            double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
            double multiplier = ((_Digits == 5 || _Digits == 3) ? 10.0 : 1.0);
            double trendStrength = (emaLowBuffer[3] - emaLowBuffer[1]) / (point * multiplier);
            double rrRatio = RiskReward_Min;
            
            //--- Use higher R:R for stronger trends
            if(trendStrength > Min_Trend_Strength * 2)
               rrRatio = RiskReward_Max;
            else if(trendStrength > Min_Trend_Strength * 1.5)
               rrRatio = (RiskReward_Min + RiskReward_Max) / 2;
            
            double tp = entry - (distance * rrRatio);
            Print(">>> EXECUTING SELL <<<");
            Print("Trend: ", (int)trendStrength, " pips | R:R 1:", rrRatio);
            Print("Entry=", entry, " | SL=", sl, " | TP=", tp);
            OpenSellTrade(entry, sl, tp);
         }
         else
         {
            Print("Invalid SELL distance: ", distance);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Determine Market Bias                                            |
//| Returns: 1 = Bullish, -1 = Bearish, 0 = Choppy                  |
//+------------------------------------------------------------------+
int GetMarketBias()
{
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double multiplier = ((_Digits == 5 || _Digits == 3) ? 10.0 : 1.0);
   
   //--- Calculate trend strength for EMA High (Bullish)
   double emaHighMove = (emaHighBuffer[1] - emaHighBuffer[3]) / (point * multiplier);
   bool emaHighRising = (emaHighBuffer[1] > emaHighBuffer[2]);
   
   //--- Calculate trend strength for EMA Low (Bearish)
   double emaLowMove = (emaLowBuffer[3] - emaLowBuffer[1]) / (point * multiplier);
   bool emaLowFalling = (emaLowBuffer[1] < emaLowBuffer[2]);
   
   //--- Strong bullish trend (EMA High consistently rising)
   if(Use_Trend_Confirmation)
   {
      emaHighRising = emaHighRising && (emaHighBuffer[2] > emaHighBuffer[3]);
      emaLowFalling = emaLowFalling && (emaLowBuffer[2] < emaLowBuffer[3]);
   }
   
   //--- Check for strong bullish bias
   if(emaHighRising && emaHighMove >= Min_Trend_Strength)
   {
      if(Debug_Mode) Print("✓✓✓ STRONG BULLISH BIAS | Strength: ", (int)emaHighMove, " pips");
      return 1;
   }
   
   //--- Check for strong bearish bias
   if(emaLowFalling && emaLowMove >= Min_Trend_Strength)
   {
      if(Debug_Mode) Print("✓✓✓ STRONG BEARISH BIAS | Strength: ", (int)emaLowMove, " pips");
      return -1;
   }
   
   //--- Weak trend - filter out if enabled
   if(Filter_Weak_Trends)
   {
      if(Debug_Mode && (emaHighRising || emaLowFalling))
         Print("Weak trend filtered: High=", (int)emaHighMove, " Low=", (int)emaLowMove, " pips (min: ", Min_Trend_Strength, ")");
      return 0;
   }
   
   //--- Allow weaker trends if filter disabled
   if(emaHighRising) return 1;
   if(emaLowFalling) return -1;
   
   if(Debug_Mode) Print("No clear bias");
   return 0;
}

//+------------------------------------------------------------------+
//| Detect Trap Patterns                                             |
//+------------------------------------------------------------------+
bool DetectTrap(int bias)
{
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   
   if(CopyRates(_Symbol, PERIOD_CURRENT, 0, 3, rates) < 3)
      return false;
   
   //--- Current candle
   bool isRedCandle = rates[0].close < rates[0].open;
   bool isGreenCandle = rates[0].close > rates[0].open;
   
   //--- If Bullish bias and red candle = potential trap
   if(bias == 1 && isRedCandle)
   {
      return true;
   }
   
   //--- If Bearish bias and green candle = potential trap
   if(bias == -1 && isGreenCandle)
   {
      return true;
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Check Bullish Entry with OB and FVG                              |
//+------------------------------------------------------------------+
bool CheckBullishEntry()
{
   double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double multiplier = ((_Digits == 5 || _Digits == 3) ? 10.0 : 1.0);
   
   //--- If pullback required, check price is near EMA Low
   if(Require_Price_Pullback)
   {
      double distance = (currentPrice - emaLowBuffer[1]) / (point * multiplier);
      
      if(distance < 0)
      {
         if(Debug_Mode) Print("Price below EMA Low - no bullish setup");
         return false;
      }
      
      if(distance > Pullback_Distance_Pips)
      {
         if(Debug_Mode) Print("Price too far from EMA Low: ", (int)distance, " pips (max: ", Pullback_Distance_Pips, ")");
         return false;
      }
      
      if(Debug_Mode) Print("Valid pullback: ", (int)distance, " pips from EMA Low");
   }
   
   //--- Check for trap pattern (bearish candle in bullish bias)
   if(Detect_Traps)
   {
      MqlRates rates[];
      ArraySetAsSeries(rates, true);
      if(CopyRates(_Symbol, PERIOD_CURRENT, 0, 2, rates) >= 2)
      {
         bool previousCandleRed = rates[1].close < rates[1].open;
         if(previousCandleRed)
         {
            if(Debug_Mode) Print("Trap detected: Red candle in bullish bias - SKIPPING");
            return false;
         }
      }
   }
   
   if(Debug_Mode) Print("✓ Bullish entry validated");
   return true;
}

//+------------------------------------------------------------------+
//| Check Bearish Entry with OB and FVG                              |
//+------------------------------------------------------------------+
bool CheckBearishEntry()
{
   double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double multiplier = ((_Digits == 5 || _Digits == 3) ? 10.0 : 1.0);
   
   //--- If pullback required, check price is near EMA High
   if(Require_Price_Pullback)
   {
      double distance = (emaHighBuffer[1] - currentPrice) / (point * multiplier);
      
      if(distance < 0)
      {
         if(Debug_Mode) Print("Price above EMA High - no bearish setup");
         return false;
      }
      
      if(distance > Pullback_Distance_Pips)
      {
         if(Debug_Mode) Print("Price too far from EMA High: ", (int)distance, " pips (max: ", Pullback_Distance_Pips, ")");
         return false;
      }
      
      if(Debug_Mode) Print("Valid pullback: ", (int)distance, " pips from EMA High");
   }
   
   //--- Check for trap pattern (bullish candle in bearish bias)
   if(Detect_Traps)
   {
      MqlRates rates[];
      ArraySetAsSeries(rates, true);
      if(CopyRates(_Symbol, PERIOD_CURRENT, 0, 2, rates) >= 2)
      {
         bool previousCandleGreen = rates[1].close > rates[1].open;
         if(previousCandleGreen)
         {
            if(Debug_Mode) Print("Trap detected: Green candle in bearish bias - SKIPPING");
            return false;
         }
      }
   }
   
   if(Debug_Mode) Print("✓ Bearish entry validated");
   return true;
}









//+------------------------------------------------------------------+
//| Open Buy Trade                                                   |
//+------------------------------------------------------------------+
void OpenBuyTrade(double entry, double sl, double tp)
{
   //--- Validate SL and TP
   if(sl >= entry)
   {
      Print("Invalid BUY SL: SL must be below entry price");
      return;
   }
   
   MqlTradeRequest request = {};
   MqlTradeResult result = {};
   
   request.action = TRADE_ACTION_DEAL;
   request.symbol = _Symbol;
   request.volume = LotSize;
   request.type = ORDER_TYPE_BUY;
   request.price = NormalizeDouble(entry, _Digits);
   request.sl = NormalizeDouble(sl, _Digits);
   request.tp = NormalizeDouble(tp, _Digits);
   request.deviation = 50;
   request.magic = MagicNumber;
   request.comment = TradeComment;
   request.type_filling = ORDER_FILLING_FOK;
   
   if(!OrderSend(request, result))
   {
      Print("BUY Order Failed - Error: ", result.retcode, " - ", result.comment);
      if(Debug_Mode) Print("Entry=", entry, " SL=", sl, " TP=", tp);
   }
   else
   {
      Print("✓ BUY Order #", result.order, " opened at ", entry, " | SL:", sl, " | TP:", tp);
   }
}

//+------------------------------------------------------------------+
//| Open Sell Trade                                                  |
//+------------------------------------------------------------------+
void OpenSellTrade(double entry, double sl, double tp)
{
   //--- Validate SL and TP
   if(sl <= entry)
   {
      Print("Invalid SELL SL: SL must be above entry price");
      return;
   }
   
   MqlTradeRequest request = {};
   MqlTradeResult result = {};
   
   request.action = TRADE_ACTION_DEAL;
   request.symbol = _Symbol;
   request.volume = LotSize;
   request.type = ORDER_TYPE_SELL;
   request.price = NormalizeDouble(entry, _Digits);
   request.sl = NormalizeDouble(sl, _Digits);
   request.tp = NormalizeDouble(tp, _Digits);
   request.deviation = 50;
   request.magic = MagicNumber;
   request.comment = TradeComment;
   request.type_filling = ORDER_FILLING_FOK;
   
   if(!OrderSend(request, result))
   {
      Print("SELL Order Failed - Error: ", result.retcode, " - ", result.comment);
      if(Debug_Mode) Print("Entry=", entry, " SL=", sl, " TP=", tp);
   }
   else
   {
      Print("✓ SELL Order #", result.order, " opened at ", entry, " | SL:", sl, " | TP:", tp);
   }
}
//+------------------------------------------------------------------+
