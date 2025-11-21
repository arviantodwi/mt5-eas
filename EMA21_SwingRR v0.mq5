//+------------------------------------------------------------------+
//|                                                EMA21_SwingRR.mq5 |
//|                                 Simple EMA-21 Swing-based R:R EA |
//+------------------------------------------------------------------+
#property strict
#property copyright "Copyright 2025, Arvianto D. Wicaksono"
#property version   "1.01"
#property description "EMA 21 close-based entries with swing high/low SL and RR-based TP."

#include <Trade/Trade.mqh>

input int      InpEMAPeriod        = 21;     // EMA period
input double   InpRiskPercent      = 1.0;    // Risk per trade (% of balance)
input double   InpRiskReward       = 1.5;    // Risk:Reward ratio
input int      InpMaxLookbackBars  = 30;     // Max bars to search for swing high/low
input int      InpSlippagePoints   = 5;      // Max slippage (points)
input ulong    InpMagicNumber      = 21021;  // Magic number

CTrade trade;

//+------------------------------------------------------------------+
//| Check if we already have a position for this EA & symbol         |
//+------------------------------------------------------------------+
bool HaveOpenPosition()
  {
// Try to select current symbol's position (if any)
   if(!PositionSelect(Symbol()))
      return(false);   // no position for this symbol

// Check magic number
   ulong magic = (ulong)PositionGetInteger(POSITION_MAGIC);
   if(magic == InpMagicNumber)
      return(true);

   return(false);
  }

//+------------------------------------------------------------------+
//| Find recent swing low using past bars (skip current forming bar) |
//| Swing low: low[i] < low[i-1] && low[i] < low[i+1]                |
//+------------------------------------------------------------------+
bool FindRecentSwingLow(double &price)
  {
   int barsToCopy = InpMaxLookbackBars + 5;
   MqlRates rates[];

   int copied = CopyRates(Symbol(), (ENUM_TIMEFRAMES)Period(), 1, barsToCopy, rates);
   if(copied < 3)
     {
      Print("Not enough bars to find swing low.");
      return(false);
     }

   ArraySetAsSeries(rates, true); // rates[0] is last closed bar (shift=1)

   int maxLookback = MathMin(InpMaxLookbackBars, copied - 2);

// 1) Try to find a proper swing low
   for(int i = 1; i <= maxLookback; i++)
     {
      if(i + 1 >= copied)
         break;

      if(rates[i].low < rates[i - 1].low && rates[i].low < rates[i + 1].low)
        {
         price = rates[i].low;
         return(true);
        }
     }

// 2) Fallback: just lowest low in the lookback window
   double minLow = rates[0].low;
   for(int i = 1; i <= maxLookback; i++)
     {
      if(rates[i].low < minLow)
         minLow = rates[i].low;
     }

   price = minLow;
   return(true);
  }

//+------------------------------------------------------------------+
//| Find recent swing high using past bars (skip current forming bar)|
//| Swing high: high[i] > high[i-1] && high[i] > high[i+1]           |
//+------------------------------------------------------------------+
bool FindRecentSwingHigh(double &price)
  {
   int barsToCopy = InpMaxLookbackBars + 5;
   MqlRates rates[];

   int copied = CopyRates(Symbol(), (ENUM_TIMEFRAMES)Period(), 1, barsToCopy, rates);
   if(copied < 3)
     {
      Print("Not enough bars to find swing high.");
      return(false);
     }

   ArraySetAsSeries(rates, true);

   int maxLookback = MathMin(InpMaxLookbackBars, copied - 2);

// 1) Try to find a proper swing high
   for(int i = 1; i <= maxLookback; i++)
     {
      if(i + 1 >= copied)
         break;

      if(rates[i].high > rates[i - 1].high && rates[i].high > rates[i + 1].high)
        {
         price = rates[i].high;
         return(true);
        }
     }

// 2) Fallback: just highest high in the lookback window
   double maxHigh = rates[0].high;
   for(int i = 1; i <= maxLookback; i++)
     {
      if(rates[i].high > maxHigh)
         maxHigh = rates[i].high;
     }

   price = maxHigh;
   return(true);
  }

//+------------------------------------------------------------------+
//| Calculate EMA(period) of last closed bar from close prices       |
//+------------------------------------------------------------------+
double CalcEMA(int period)
  {
   if(period <= 1)
      return(0.0);

// Need at least 'period + 5' bars for a stable EMA seed
   int toCopy = period + 5;
   double close[];
   int copied = CopyClose(Symbol(), (ENUM_TIMEFRAMES)Period(), 1, toCopy, close);
   if(copied < period)
     {
      Print("Not enough data to calculate EMA.");
      return(0.0);
     }

   ArraySetAsSeries(close, true); // close[0] = last closed bar

// 1) seed EMA with simple average of first 'period' values at the far end
   double sum = 0.0;
   int startIndex = period - 1;
   for(int i = startIndex; i >= 0; i--)
      sum += close[i];

   double ema = sum / period;
   double alpha = 2.0 / (period + 1.0);

// 2) roll EMA forward until we reach close[0]
   for(int i = startIndex - 1; i >= 0; i--)
      ema = alpha * close[i] + (1.0 - alpha) * ema;

   return(ema);
  }

//+------------------------------------------------------------------+
//| Calculate lot size from risk % and SL distance                   |
//+------------------------------------------------------------------+
double CalculateLotSize(double stopLossPrice, bool isBuy)
  {
   double balance    = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskMoney  = balance * InpRiskPercent / 100.0;

   double tickValue  = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_VALUE);
   double tickSize   = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_SIZE);
   double volumeMin  = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MIN);
   double volumeMax  = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MAX);
   double volumeStep = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_STEP);

   if(tickValue <= 0.0 || tickSize <= 0.0 || volumeStep <= 0.0)
     {
      Print("Market parameters not available. Cannot calculate lot size.");
      return(0.0);
     }

   MqlTick tick;
   if(!SymbolInfoTick(Symbol(), tick))
     {
      Print("Failed to get tick for lot size.");
      return(0.0);
     }

   double price = isBuy ? tick.ask : tick.bid;
   double slDistance = MathAbs(price - stopLossPrice);

   if(slDistance <= 0.0)
     {
      Print("SL distance is zero or negative. Cannot calculate lot size.");
      return(0.0);
     }

// Loss for 1 lot if SL is hit
   double lossPerLot = (slDistance / tickSize) * tickValue;
   if(lossPerLot <= 0.0)
      return(0.0);

   double lots = riskMoney / lossPerLot;

// infer volume digits from step (e.g. 0.01 -> 2)
   int volDigits = (int)MathRound(-MathLog10(volumeStep));

   lots = MathFloor(lots / volumeStep) * volumeStep;
   lots = MathMax(lots, volumeMin);
   lots = MathMin(lots, volumeMax);
   lots = NormalizeDouble(lots, volDigits);

   return(lots);
  }

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
  {
   Print("EMA21_SwingRR EA initialized on symbol: ", Symbol());
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippagePoints);

// --- ADD EMA21 to chart visually ---
   int handleEMA = iMA(Symbol(), (ENUM_TIMEFRAMES)Period(), InpEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   if(handleEMA != INVALID_HANDLE)
     {
      if(!ChartIndicatorAdd(0, 0, handleEMA))
         Print("Failed to attach EMA indicator to chart");
     }

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   Print("EMA21_SwingRR EA deinitialized. Reason: ", reason);
  }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   static datetime lastBarTime = 0;

// Only act on a new bar
   datetime currentBarTime = iTime(Symbol(), (ENUM_TIMEFRAMES)Period(), 0);
   if(currentBarTime == 0)
      return;

   if(currentBarTime == lastBarTime)
      return;

   lastBarTime = currentBarTime;

// Need enough history
   if(Bars(Symbol(), (ENUM_TIMEFRAMES)Period()) < InpEMAPeriod + InpMaxLookbackBars + 5)
      return;

// Skip if a position is already open
   if(HaveOpenPosition())
      return;

// --- EMA + last close ---

   double ema = CalcEMA(InpEMAPeriod);
   double lastClose = iClose(Symbol(), (ENUM_TIMEFRAMES)Period(), 1);

   if(ema == 0.0 || lastClose == 0.0)
      return;

   bool buySignal  = (lastClose > ema);
   bool sellSignal = (lastClose < ema);

   if(!buySignal && !sellSignal)
      return;

   MqlTick tick;
   if(!SymbolInfoTick(Symbol(), tick))
     {
      Print("Failed to get tick in OnTick.");
      return;
     }

   int digits = (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS);

// --- BUY LOGIC --------------------------------------------------
   if(buySignal)
     {
      double slPrice;
      if(!FindRecentSwingLow(slPrice))
        {
         Print("Could not find a swing low for BUY SL.");
        }
      else
         if(slPrice >= tick.ask)
           {
            PrintFormat("Invalid BUY SL (%.5f) >= Ask (%.5f)", slPrice, tick.ask);
           }
         else
           {
            double lots = CalculateLotSize(slPrice, true);
            if(lots > 0.0)
              {
               double riskDistance = tick.ask - slPrice;
               double tpDistance   = riskDistance * InpRiskReward;
               double tpPrice      = tick.ask + tpDistance;

               slPrice = NormalizeDouble(slPrice, digits);
               tpPrice = NormalizeDouble(tpPrice, digits);

               if(!trade.Buy(lots, Symbol(), tick.ask, slPrice, tpPrice))
                 {
                  PrintFormat("BUY failed. Error: %d", GetLastError());
                 }
               else
                 {
                  PrintFormat("BUY opened. Lots: %.2f, Entry: %.5f, SL: %.5f, TP: %.5f",
                              lots, tick.ask, slPrice, tpPrice);
                 }
              }
           }
     }

// --- SELL LOGIC -------------------------------------------------
   if(sellSignal)
     {
      double slPrice;
      if(!FindRecentSwingHigh(slPrice))
        {
         Print("Could not find a swing high for SELL SL.");
        }
      else
         if(slPrice <= tick.bid)
           {
            PrintFormat("Invalid SELL SL (%.5f) <= Bid (%.5f)", slPrice, tick.bid);
           }
         else
           {
            double lots = CalculateLotSize(slPrice, false);
            if(lots > 0.0)
              {
               double riskDistance = slPrice - tick.bid;
               double tpDistance   = riskDistance * InpRiskReward;
               double tpPrice      = tick.bid - tpDistance;

               slPrice = NormalizeDouble(slPrice, digits);
               tpPrice = NormalizeDouble(tpPrice, digits);

               if(!trade.Sell(lots, Symbol(), tick.bid, slPrice, tpPrice))
                 {
                  PrintFormat("SELL failed. Error: %d", GetLastError());
                 }
               else
                 {
                  PrintFormat("SELL opened. Lots: %.2f, Entry: %.5f, SL: %.5f, TP: %.5f",
                              lots, tick.bid, slPrice, tpPrice);
                 }
              }
           }
     }
  }
//+------------------------------------------------------------------+
//| Timer function                                                   |
//+------------------------------------------------------------------+
void OnTimer()
  {
//---

  }
//+------------------------------------------------------------------+
//| Trade function                                                   |
//+------------------------------------------------------------------+
void OnTrade()
  {
//---

  }
//+------------------------------------------------------------------+
//| TradeTransaction function                                        |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& request,
                        const MqlTradeResult& result)
  {
//---

  }
//+------------------------------------------------------------------+
//| Tester function                                                  |
//+------------------------------------------------------------------+
double OnTester()
  {
//---
   double ret=0.0;
//---

//---
   return(ret);
  }
//+------------------------------------------------------------------+
//| TesterInit function                                              |
//+------------------------------------------------------------------+
void OnTesterInit()
  {
//---

  }
//+------------------------------------------------------------------+
//| TesterPass function                                              |
//+------------------------------------------------------------------+
void OnTesterPass()
  {
//---

  }
//+------------------------------------------------------------------+
//| TesterDeinit function                                            |
//+------------------------------------------------------------------+
void OnTesterDeinit()
  {
//---

  }
//+------------------------------------------------------------------+
//| ChartEvent function                                              |
//+------------------------------------------------------------------+
void OnChartEvent(const int32_t id,
                  const long &lparam,
                  const double &dparam,
                  const string &sparam)
  {
//---

  }
//+------------------------------------------------------------------+
//| BookEvent function                                               |
//+------------------------------------------------------------------+
void OnBookEvent(const string &symbol)
  {
//---

  }
//+------------------------------------------------------------------+
