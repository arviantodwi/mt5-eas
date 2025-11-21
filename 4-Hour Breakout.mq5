//+------------------------------------------------------------------+
//|                                                4-Hour Breakout.mq5 |
//|                             Copyright 2025, Arvianto D. Wicaksono |
//|                                             https://www.arvian.to |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, Arvianto D. Wicaksono"
#property link      "https://www.arvian.to"
#property version   "1.21" // Optimized performance by running checks only once per M5 bar
#property description "This Expert Advisor identifies and marks the high and low of the first 4-hour candle of the day."
#property description "Calculates and draws key Fibonacci retracement levels within the range."
#property description "Detects breakouts of the 4H range on the M5 timeframe and places pending limit orders after ATR confirmation."

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\OrderInfo.mqh>

//--- Input Parameters
input group "Setup Parameters"
input ENUM_TIMEFRAMES InpTimeframe = PERIOD_H4; // The timeframe to analyze (4 hours)
input color HighLineColor = clrRed;            // Color for the High line (Outer boundary)
input color LowLineColor  = clrAqua;           // Color for the Low line (Outer boundary)
input color FiboLineColor = clrYellow;         // Color for the Fibo Retracement lines (Inner levels)
input ENUM_LINE_STYLE FiboLineStyle = STYLE_DOT; // Style for the Fibo Retracement lines
input int FiboLineWidth = 1;                     // Width for the Fibo Retracement lines

input group "Execution Parameters"
input double InpLotSize = 0.01;              // Lot size for orders
input double InpRiskRewardRatio = 5.0;       // Risk/Reward Ratio (TP/Risk)
input int    InpSessionEndHour = 23;         // Hour of the day to remove pending orders (0-23)
input double InpAtrMultiplier = 0.8;         // Multiplier for ATR filter

//--- Global Variables
CTrade   trade;
COrderInfo order;
CPositionInfo position;
datetime g_currentDayStart = 0;   // Stores the day start time we last SUCCESSFULLY calculated the levels for
bool     g_hasLoggedNewDayMessage = false; // Prevents "New Day" log spam
bool     g_hasLoggedFailureForDay = false; // Prevents "Waiting" log spam
bool     g_hasLoggedAtrWait = false;   // Prevents "Waiting for ATR" log spam
string   g_bias = "none";           // Stores the daily market bias: "none", "bullish", or "bearish"
datetime g_lastCheckedM5Time = 0; // Stores the time of the last M5 candle we processed

double   g_first4HHigh = 0.0;     // High of the first 4H candle
double   g_first4HLow  = 0.0;     // Low of the first 4H candle
string   g_prefix = "4HBreakout_"; // Unique prefix for Chart Objects for cleanup

// --- Fibo Levels and Average Zones ---
double   g_fibo382 = 0.0;         // 38.2% Retracement Level
double   g_fibo500 = 0.0;         // 50.0% Retracement Level
double   g_fibo618 = 0.0;         // 61.8% Retracement Level
double   g_avg38_50 = 0.0;        // Average of 38.2% and 50.0%
double   g_avg50_61 = 0.0;        // Average of 50.0% and 61.8%

// --- ATR Indicator Handle ---
int      g_atrHandle = INVALID_HANDLE;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
   {
//--- Initialize the trade object
    trade.SetExpertMagicNumber(12345);
    trade.SetDeviationInPoints(10);
    trade.SetTypeFilling(ORDER_FILLING_IOC);

//--- Initialize the ATR indicator handle
    g_atrHandle = iATR(_Symbol, PERIOD_M5, 14);
    if(g_atrHandle == INVALID_HANDLE)
      {
       Print("Error creating ATR indicator");
       return(INIT_FAILED);
      }

//--- Initialize the day marker to the previous day to force a setup on the first tick.
    g_currentDayStart = (datetime)iTime(_Symbol, PERIOD_D1, 1);
    g_hasLoggedNewDayMessage = false;
    g_hasLoggedFailureForDay = false;
    g_hasLoggedAtrWait = false;
    g_bias = "none";
    g_lastCheckedM5Time = 0;
    Print("4-Hour Breakout v1.21 Initialized.");
    return(INIT_SUCCEEDED);
   }

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
   {
//--- Release the ATR indicator handle
    if(g_atrHandle != INVALID_HANDLE)
      {
         IndicatorRelease(g_atrHandle);
      }
//--- Clean up any remaining objects when the EA is removed or stopped
    ObjectsDeleteAll(0, g_prefix);
    Print("4-Hour Breakout v1.21 Deinitialized.");
   }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
   {
// 1. Get the open time of the current daily candle (index 0)
    datetime newDayStart = (datetime)iTime(_Symbol, PERIOD_D1, 0);

// Check if a new day has started since the last SUCCESSFUL setup
    if(newDayStart > g_currentDayStart)
       {
        // --- It's a new day, so reset our daily state variables ---
        if(g_bias != "none")
           {
            Print("--- New Day Detected: ", TimeToString(newDayStart, TIME_DATE), ". Bias reset to none. ---");
           }
        g_bias = "none";
        g_hasLoggedNewDayMessage = false;
        g_hasLoggedFailureForDay = false;
        g_hasLoggedAtrWait = false;
        g_lastCheckedM5Time = 0; // Reset M5 check time for the new day

        // 2. Find the first closed 4H candle that belongs to the current day
        PerformDailySetup(newDayStart);
       }
    else // The setup for the day is complete, now we manage trades
       {
        // --- Performance Optimization: Check for new M5 bar ---
        MqlRates rates_m5[];
        ArraySetAsSeries(rates_m5, true);
        if(CopyRates(_Symbol, PERIOD_M5, 1, 1, rates_m5) < 1) return;

        // Only run logic if a new M5 bar has closed
        if(rates_m5[0].time != g_lastCheckedM5Time)
           {
            // --- Step 1: Check for Breakout Logic (sets the bias) ---
            CheckForBreakout(rates_m5[0]);

            // --- Step 2: Check for ATR Confirmation and place an order if conditions are met ---
            // This only runs if we have a bias and no active trades/orders
            if(g_bias != "none" && !HasOpenPosition() && !HasPendingOrder())
               {
                    CheckForAtrConfirmation(rates_m5[0]);
               }

            // --- Update the time of the last checked bar ---
            g_lastCheckedM5Time = rates_m5[0].time;
           }

        // --- Check for End of Day Cleanup (this still needs to run on every tick) ---
        CheckForEndOfDayCleanup();
       }
   }

//+------------------------------------------------------------------+
//| Performs the daily setup for the 4H candle                   |
//+------------------------------------------------------------------+
void PerformDailySetup(datetime dayStart)
   {
    MqlRates rates_h4[];
    ArraySetAsSeries(rates_h4, true); // Set array as series to check from most recent

    bool setupFound = false;
    // Search for the first closed 4H candle of the current day
    for(int i = 1; i < 10; i++) // Check the last 10 closed 4H candles
       {
        // Copy one candle at a time, starting from the most recent closed one (index 1)
        if(CopyRates(_Symbol, InpTimeframe, i, 1, rates_h4) > 0)
           {
            // Get the day that the candle belongs to by zeroing out its time
            MqlDateTime candleTimeStruct;
            TimeToStruct(rates_h4[0].time, candleTimeStruct);
            datetime candleDayStart = StructToTime(candleTimeStruct);

            // If this candle belongs to the current day, this is our setup candle
            if(candleDayStart == dayStart)
               {
                    // --- The first 4H candle of the day is found. Process its data. ---
                    setupFound = true;
                    Print("SUCCESS: Found first 4H candle for the day.");

                    // --- 3a. Calculate the Fibonacci Retracement Levels ---
                    double range = rates_h4[0].high - rates_h4[0].low;

                    // Levels are calculated relative to the high
                    g_fibo382 = rates_h4[0].high - range * 0.382;
                    g_fibo500 = rates_h4[0].high - range * 0.500;
                    g_fibo618 = rates_h4[0].high - range * 0.618;

                    // --- 3b. Calculate the Average Prices for future zones ---
                    g_avg38_50 = (g_fibo382 + g_fibo500) / 2.0;
                    g_avg50_61 = (g_fibo500 + g_fibo618) / 2.0;

                    // Store the primary levels and time
                    g_first4HHigh = rates_h4[0].high;
                    g_first4HLow  = rates_h4[0].low;
                    datetime first4HTime = rates_h4[0].time;

                    // 4. Draw new Chart Objects
                    DrawSetupObjects(dayStart, first4HTime);

                    // 5. Update the global variable to mark this day as SUCCESSFULLY processed
                    g_currentDayStart = dayStart;

                    break; // Exit the loop since we found our candle
               }
           }
       }

    // If the loop finished and we didn't find a setup candle, it means it hasn't closed yet.
    if(!setupFound)
       {
        // Only print the message once per day to avoid log spam
        if(!g_hasLoggedFailureForDay)
           {
            Print("INFO: First 4-hour candle for the day has not closed yet. Will retry...");
            g_hasLoggedFailureForDay = true;
           }
       }
   }

//+------------------------------------------------------------------+
//| Checks for a breakout of the 4H range on the M5 timeframe        |
//+------------------------------------------------------------------+
void CheckForBreakout(MqlRates &m5Bar)
   {
    // Check for bullish breakout
    if(m5Bar.close > g_first4HHigh)
       {
        // Only update and print if the bias is not already bullish
        if(g_bias != "bullish")
           {
                g_bias = "bullish";
                g_hasLoggedAtrWait = false; // Reset ATR wait log for new bias
                Print("BIAS CHANGE: Bias changed to BULLISH at ", TimeToString(m5Bar.time), ". Close price: ", m5Bar.close);
           }
        return;
       }

    // Check for bearish breakout
    if(m5Bar.close < g_first4HLow)
       {
        // Only update and print if the bias is not already bearish
        if(g_bias != "bearish")
           {
                g_bias = "bearish";
                g_hasLoggedAtrWait = false; // Reset ATR wait log for new bias
                Print("BIAS CHANGE: Bias changed to BEARISH at ", TimeToString(m5Bar.time), ". Close price: ", m5Bar.close);
           }
        return;
       }
   }

//+------------------------------------------------------------------+
//| Checks for ATR confirmation before placing an order              |
//+------------------------------------------------------------------+
void CheckForAtrConfirmation(MqlRates &m5Bar)
   {
    double atrBuffer[];
    ArraySetAsSeries(atrBuffer, true);
    // Get the ATR value from the last closed M5 candle (index 1)
    if(CopyBuffer(g_atrHandle, 0, 1, 2, atrBuffer) < 2)
       {
        Print("ERROR: Failed to copy ATR values.");
        return;
       }
    double atrValue = atrBuffer[1] * InpAtrMultiplier;

    // Check for bullish ATR confirmation
    if(g_bias == "bullish")
       {
        double atrLow = m5Bar.low - atrValue;
        Print("ATR Check (Bullish): ATR Low (", DoubleToString(atrLow, _Digits), ") vs 4H High (", DoubleToString(g_first4HHigh, _Digits), ")");
        if(atrLow > g_first4HHigh)
           {
            Print("ATR CONFIRMED: Bullish condition met. Placing pending BUY order.");
            PlacePendingBuyOrder();
           }
        else
           {
            if(!g_hasLoggedAtrWait)
               {
                Print("ATR WAITING: Bullish condition not yet met. Waiting for confirmation...");
                g_hasLoggedAtrWait = true;
               }
           }
       }

    // Check for bearish ATR confirmation
    if(g_bias == "bearish")
       {
        double atrHigh = m5Bar.high + atrValue;
        Print("ATR Check (Bearish): ATR High (", DoubleToString(atrHigh, _Digits), ") vs 4H Low (", DoubleToString(g_first4HLow, _Digits), ")");
        if(atrHigh < g_first4HLow)
           {
            Print("ATR CONFIRMED: Bearish condition met. Placing pending SELL order.");
            PlacePendingSellOrder();
           }
        else
           {
            if(!g_hasLoggedAtrWait)
               {
                Print("ATR WAITING: Bearish condition not yet met. Waiting for confirmation...");
                g_hasLoggedAtrWait = true;
               }
           }
       }
   }

//+------------------------------------------------------------------+
//| Places a pending BUY order                                        |
//+------------------------------------------------------------------+
void PlacePendingBuyOrder()
   {
    double entryPrice = g_avg50_61;
    double stopLoss = g_first4HLow;
    double risk = entryPrice - stopLoss;
    double takeProfit = entryPrice + risk * InpRiskRewardRatio;

    if(trade.BuyLimit(InpLotSize, entryPrice, _Symbol, stopLoss, takeProfit, ORDER_TIME_DAY, 0, "Bullish Breakout"))
       {
        Print("EXECUTION: Placed BUY LIMIT at ", DoubleToString(entryPrice, _Digits), ", SL at ", DoubleToString(stopLoss, _Digits), ", TP at ", DoubleToString(takeProfit, _Digits));
       }
    else
       {
        Print("ERROR: Failed to place BUY LIMIT. Error code: ", trade.ResultRetcode(), ". ", trade.ResultComment());
       }
   }

//+------------------------------------------------------------------+
//| Places a pending SELL order                                       |
//+------------------------------------------------------------------+
void PlacePendingSellOrder()
   {
    double entryPrice = g_avg38_50;
    double stopLoss = g_first4HHigh;
    double risk = stopLoss - entryPrice;
    double takeProfit = entryPrice - risk * InpRiskRewardRatio;

    if(trade.SellLimit(InpLotSize, entryPrice, _Symbol, stopLoss, takeProfit, ORDER_TIME_DAY, 0, "Bearish Breakout"))
       {
        Print("EXECUTION: Placed SELL LIMIT at ", DoubleToString(entryPrice, _Digits), ", SL at ", DoubleToString(stopLoss, _Digits), ", TP at ", DoubleToString(takeProfit, _Digits));
       }
    else
       {
        Print("ERROR: Failed to place SELL LIMIT. Error code: ", trade.ResultRetcode(), ". ", trade.ResultComment());
       }
   }

//+------------------------------------------------------------------+
//| Checks if there is a pending order for this EA                  |
//+------------------------------------------------------------------+
bool HasPendingOrder()
   {
    for(int i = 0; i < OrdersTotal(); i++)
       {
        if(order.SelectByIndex(i))
           {
            if(order.Symbol() == _Symbol && order.Magic() == trade.RequestMagic())
               {
                return true;
               }
           }
       }
    return false;
   }

//+------------------------------------------------------------------+
//| Checks if there is an open position for this EA                |
//+------------------------------------------------------------------+
bool HasOpenPosition()
   {
    for(int i = 0; i < PositionsTotal(); i++)
       {
        if(position.SelectByIndex(i))
           {
            if(position.Symbol() == _Symbol && position.Magic() == trade.RequestMagic())
               {
                return true;
               }
           }
       }
    return false;
   }

//+------------------------------------------------------------------+
//| Checks for end of day and removes pending orders                 |
//+------------------------------------------------------------------+
void CheckForEndOfDayCleanup()
   {
    MqlDateTime currentTime;
    TimeToStruct(TimeCurrent(), currentTime);

    if(currentTime.hour >= InpSessionEndHour)
       {
        for(int i = OrdersTotal() - 1; i >= 0; i--) // Loop backwards to avoid index issues when deleting
           {
            if(order.SelectByIndex(i) && order.Symbol() == _Symbol && order.Magic() == trade.RequestMagic())
               {
                if(trade.OrderDelete(order.Ticket()))
                   {
                    Print("CLEANUP: Removed pending order #", order.Ticket(), " at session end.");
                   }
                else
                   {
                    Print("ERROR: Failed to remove pending order #", order.Ticket(), ". Error: ", trade.ResultComment());
                   }
               }
           }
       }
   }

//+------------------------------------------------------------------+
//| Draws the setup objects on the chart                             |
//+------------------------------------------------------------------+
void DrawSetupObjects(datetime dayStart, datetime candleTime)
   {
    // Ensure objects from the previous day's analysis are cleaned up
    ObjectsDeleteAll(0, g_prefix);

    string currentDayStr = TimeToString(dayStart, TIME_DATE);

    // --- Draw Fibo Lines ---

    // 38.2%
    string fibo382Name = g_prefix + "Fibo382_" + currentDayStr;
    ObjectCreate(0, fibo382Name, OBJ_HLINE, 0, candleTime, g_fibo382);
    ObjectSetString(0, fibo382Name, OBJPROP_TEXT, "Fibo 38.2");
    ObjectSetInteger(0, fibo382Name, OBJPROP_COLOR, FiboLineColor);
    ObjectSetInteger(0, fibo382Name, OBJPROP_STYLE, FiboLineStyle);
    ObjectSetInteger(0, fibo382Name, OBJPROP_WIDTH, FiboLineWidth);
    ObjectSetInteger(0, fibo382Name, OBJPROP_TIMEFRAMES, OBJ_ALL_PERIODS);

    // 50.0%
    string fibo500Name = g_prefix + "Fibo500_" + currentDayStr;
    ObjectCreate(0, fibo500Name, OBJ_HLINE, 0, candleTime, g_fibo500);
    ObjectSetString(0, fibo500Name, OBJPROP_TEXT, "Fibo 50.0");
    ObjectSetInteger(0, fibo500Name, OBJPROP_COLOR, FiboLineColor);
    ObjectSetInteger(0, fibo500Name, OBJPROP_STYLE, FiboLineStyle);
    ObjectSetInteger(0, fibo500Name, OBJPROP_WIDTH, FiboLineWidth);
    ObjectSetInteger(0, fibo500Name, OBJPROP_TIMEFRAMES, OBJ_ALL_PERIODS);

    // 61.8%
    string fibo618Name = g_prefix + "Fibo618_" + currentDayStr;
    ObjectCreate(0, fibo618Name, OBJ_HLINE, 0, candleTime, g_fibo618);
    ObjectSetString(0, fibo618Name, OBJPROP_TEXT, "Fibo 61.8");
    ObjectSetInteger(0, fibo618Name, OBJPROP_COLOR, FiboLineColor);
    ObjectSetInteger(0, fibo618Name, OBJPROP_STYLE, FiboLineStyle);
    ObjectSetInteger(0, fibo618Name, OBJPROP_WIDTH, FiboLineWidth);
    ObjectSetInteger(0, fibo618Name, OBJPROP_TIMEFRAMES, OBJ_ALL_PERIODS);

    // --- Draw HIGH and LOW lines ---

    string highObjectName = g_prefix + "High_" + currentDayStr;
    ObjectCreate(0, highObjectName, OBJ_HLINE, 0, candleTime, g_first4HHigh);
    ObjectSetString(0, highObjectName, OBJPROP_TEXT, "4H High");
    ObjectSetInteger(0, highObjectName, OBJPROP_COLOR, HighLineColor);
    ObjectSetInteger(0, highObjectName, OBJPROP_WIDTH, 2);
    ObjectSetInteger(0, highObjectName, OBJPROP_TIMEFRAMES, OBJ_ALL_PERIODS);

    string lowObjectName  = g_prefix + "Low_" + currentDayStr;
    ObjectCreate(0, lowObjectName, OBJ_HLINE, 0, candleTime, g_first4HLow);
    ObjectSetString(0, lowObjectName, OBJPROP_TEXT, "4H Low");
    ObjectSetInteger(0, lowObjectName, OBJPROP_COLOR, LowLineColor);
    ObjectSetInteger(0, lowObjectName, OBJPROP_STYLE, STYLE_SOLID);
    ObjectSetInteger(0, lowObjectName, OBJPROP_WIDTH, 2);
    ObjectSetInteger(0, lowObjectName, OBJPROP_TIMEFRAMES, OBJ_ALL_PERIODS);
   }
//+------------------------------------------------------------------+