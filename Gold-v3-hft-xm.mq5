//+------------------------------------------------------------------+
//|                                     Gold-v3-vwap-greed.mq5        |
//|         VWAP direction + Greed Martingale for GOLD.i#             |
//|         Target broker: XM Ultra Low Standard                      |
//+------------------------------------------------------------------+
#property copyright   "Gold-v3-vwap-greed"
#property version     "1.00"
#property description "VWAP-driven greed martingale EA for GOLD.i# on XM Ultra Low."
#property strict

#include <Trade\Trade.mqh>
#include <Trade\SymbolInfo.mqh>

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
input group "=== VWAP ==="
input int      VWAP_LookbackBars     = 0;       // 0 = anchored to today's session; >0 = rolling N bars
input bool     VWAP_UseTypicalPrice  = true;    // true = (H+L+C)/3; false = close only
input int      VWAP_MinCrossBars     = 1;       // bars price must stay on one side before flipping

input group "=== Base Lot & Martingale ==="
input double   BaseLot               = 0.01;
input double   MartingaleMultiplier  = 2.0;
input int      MaxMartingaleSteps    = 5;
input double   MaxLot                = 1.00;

input group "=== Greed Pyramiding ==="
input bool     UseGreedPyramid       = true;
input double   PyramidStepPoints     = 200;
input int      MaxPyramidLegs        = 3;
input double   PyramidLotFactor      = 0.5;

input group "=== Stop Loss / Take Profit (points) ==="
input double   SL_Points             = 200;
input double   TP_Points             = 300;

input group "=== Trailing / Break-even (points) ==="
input bool     UseTrailing           = true;
input double   Trailing_Start        = 100;
input double   Trailing_Distance     = 80;
input bool     UseBreakEven          = true;
input double   BreakEven_Trigger     = 80;
input double   BreakEven_Lock        = 5;

input group "=== Safety Brakes ==="
input double   MaxDailyLossPercent   = 10.0;
input int      MaxConsecutiveLosses  = 6;
input int      PauseBarsAfterStop    = 12;

input group "=== Broker / Symbol Filters ==="
input double   MaxSpreadPoints       = 80;
input int      SlippagePoints        = 20;
input int      MagicNumber           = 20250922;

input group "=== Diagnostics ==="
input bool     DebugMode             = true;

//+------------------------------------------------------------------+
//| Globals                                                          |
//+------------------------------------------------------------------+
CTrade        trade;
CSymbolInfo   symbolInfo;

//--- Martingale state
double        g_currentLot          = 0.0;
int           g_consecutiveLosses   = 0;
datetime      g_pauseUntil          = 0;

//--- Last deal tracking
ulong         g_lastDealTicket      = 0;

//--- Pyramiding state
int           g_pyramidLegs         = 0;
double        g_lastLegOpenPrice    = 0.0;
double        g_lastLegLot          = 0.0;

//--- Daily loss tracking
datetime      g_dayStart            = 0;
double        g_dayStartBalance     = 0.0;

//--- VWAP direction state
int           g_lastVWAPDir         = 0;    // +1 above, -1 below, 0 unknown
int           g_barsOnCurrentSide   = 0;

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   if(!symbolInfo.Name(_Symbol)) return INIT_FAILED;
   symbolInfo.RefreshRates();

   Print("=== ", _Symbol, " Symbol Specs ===");
   Print("Digits: ",        symbolInfo.Digits());
   Print("Point: ",         _Point);
   Print("Tick Size: ",     SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE));
   Print("Tick Value: ",    SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE));
   Print("Min Lot: ",       SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN));
   Print("Max Lot: ",       SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX));
   Print("Lot Step: ",      SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP));
   Print("Stops Level: ",   SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL));
   Print("VWAP mode: ",     (VWAP_LookbackBars <= 0 ? "session-anchored" :
                             "rolling " + IntegerToString(VWAP_LookbackBars) + " bars"));

   g_currentLot      = BaseLot;
   g_dayStart        = (datetime)iTime(_Symbol, PERIOD_D1, 0);
   g_dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);

   Print("Gold-v3-vwap-greed initialised. Base lot=", DoubleToString(BaseLot, 2),
         " multiplier=", DoubleToString(MartingaleMultiplier, 2));
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| OnDeinit                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {}

//+------------------------------------------------------------------+
//| OnTick                                                           |
//+------------------------------------------------------------------+
void OnTick()
{
   if(!symbolInfo.RefreshRates()) return;

   CheckDailyReset();
   ManageOpenPositions();

   static datetime lastBar = 0;
   datetime barTime = (datetime)iTime(_Symbol, _Period, 0);
   if(barTime == lastBar) return;
   lastBar = barTime;

   if(TimeCurrent() < g_pauseUntil)
   {
      if(DebugMode) Print("[PAUSE] Cooling off until ", TimeToString(g_pauseUntil));
      return;
   }

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double dailyLossPct = (g_dayStartBalance > 0.0)
                         ? (g_dayStartBalance - equity) / g_dayStartBalance * 100.0
                         : 0.0;
   if(dailyLossPct >= MaxDailyLossPercent)
   {
      if(DebugMode) Print("[BRAKE] Daily loss ", DoubleToString(dailyLossPct, 2), "% hit.");
      return;
   }

   double spreadPts = (symbolInfo.Ask() - symbolInfo.Bid()) / _Point;
   if(spreadPts > MaxSpreadPoints) return;

   UpdateLastDealState();

   //--- Compute VWAP for the last closed bar
   double vwap = ComputeVWAP(1);
   if(vwap <= 0.0) return;

   double close1 = iClose(_Symbol, _Period, 1);
   if(close1 <= 0.0) return;

   //--- Direction from VWAP
   int dir = 0;
   if(close1 > vwap) dir = +1;
   else if(close1 < vwap) dir = -1;

   if(dir == 0) return;

   //--- Track how many bars have stayed on this side
   if(dir == g_lastVWAPDir)
      g_barsOnCurrentSide++;
   else
   {
      g_barsOnCurrentSide = 1;
   }

   if(DebugMode)
      Print("[VWAP] vwap=", DoubleToString(vwap, _Digits),
            " close=", DoubleToString(close1, _Digits),
            " dir=", (dir > 0 ? "ABOVE" : "BELOW"),
            " bars=", g_barsOnCurrentSide,
            " | lot=", DoubleToString(g_currentLot, 2),
            " losses=", g_consecutiveLosses,
            " pyr=", g_pyramidLegs);

   //--- Confirm flip only after N bars on the new side
   if(g_barsOnCurrentSide < VWAP_MinCrossBars) return;

   //--- VWAP side changed → close opposite, open new
   if(dir != g_lastVWAPDir)
   {
      if(g_lastVWAPDir != 0)
      {
         if(dir > 0) CloseAllPositions(POSITION_TYPE_SELL);
         else        CloseAllPositions(POSITION_TYPE_BUY);
      }

      double lot = ComputeNextLot();
      OpenPosition(dir > 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, lot);

      g_lastVWAPDir       = dir;
      g_pyramidLegs       = 0;
      g_lastLegOpenPrice  = (dir > 0) ? symbolInfo.Ask() : symbolInfo.Bid();
      g_lastLegLot        = lot;
      return;
   }

   //--- Greed pyramid while price stays on the correct side of VWAP
   if(UseGreedPyramid && g_pyramidLegs < MaxPyramidLegs)
   {
      double px = symbolInfo.Bid();
      double stepPrice = PyramidStepPoints * _Point;

      bool addLeg = false;
      if(dir > 0 && (px - g_lastLegOpenPrice) >= stepPrice) addLeg = true;
      if(dir < 0 && (g_lastLegOpenPrice - px) >= stepPrice) addLeg = true;

      if(addLeg)
      {
         double newLot = NormalizeLot(g_lastLegLot * PyramidLotFactor);
         if(newLot > 0.0)
         {
            OpenPosition(dir > 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, newLot);
            g_lastLegLot       = newLot;
            g_lastLegOpenPrice = px;
            g_pyramidLegs++;
            if(DebugMode)
               Print("[PYRAMID] added leg #", g_pyramidLegs,
                     " lot=", DoubleToString(newLot, 2));
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Compute VWAP                                                     |
//|   If VWAP_LookbackBars <= 0 → anchored to today's session        |
//|   Else → rolling over the last N bars (starting at `startShift`) |
//+------------------------------------------------------------------+
double ComputeVWAP(int startShift)
{
   datetime fromTime = 0;

   if(VWAP_LookbackBars <= 0)
   {
      //--- Session-anchored: from today's first bar
      fromTime = (datetime)iTime(_Symbol, PERIOD_D1, 0);
   }
   else
   {
      //--- Rolling: from `VWAP_LookbackBars + startShift` bars back
      fromTime = iTime(_Symbol, _Period, VWAP_LookbackBars + startShift);
   }

   datetime toTime = iTime(_Symbol, _Period, startShift);
   if(fromTime == 0 || toTime == 0 || fromTime >= toTime) return 0.0;

   //--- Compute number of bars in window
   int barsBack = iBarShift(_Symbol, _Period, fromTime, false);
   int barsEnd  = iBarShift(_Symbol, _Period, toTime,   false);
   int count    = barsBack - barsEnd + 1;
   if(count < 1) return 0.0;

   //--- Read the price and volume series over the window
   double high[], low[], close[];
   long   vol[];
   ArraySetAsSeries(high,  true);
   ArraySetAsSeries(low,   true);
   ArraySetAsSeries(close, true);
   ArraySetAsSeries(vol,   true);

   if(CopyHigh (_Symbol, _Period, barsEnd, count, high)  < count) return 0.0;
   if(CopyLow  (_Symbol, _Period, barsEnd, count, low)   < count) return 0.0;
   if(CopyClose(_Symbol, _Period, barsEnd, count, close) < count) return 0.0;
   if(CopyTickVolume(_Symbol, _Period, barsEnd, count, vol) < count) return 0.0;

   double numerator   = 0.0;
   double denominator = 0.0;

   for(int i = 0; i < count; i++)
   {
      double px = VWAP_UseTypicalPrice
                  ? (high[i] + low[i] + close[i]) / 3.0
                  : close[i];

      double v = (double)vol[i];
      if(v <= 0.0) v = 1.0;      // fallback if broker returns 0 volume

      numerator   += px * v;
      denominator += v;
   }

   if(denominator <= 0.0) return 0.0;
   return numerator / denominator;
}

//+------------------------------------------------------------------+
//| Compute martingale lot                                           |
//+------------------------------------------------------------------+
double ComputeNextLot()
{
   if(g_consecutiveLosses <= 0)
      return NormalizeLot(BaseLot);

   double lot = BaseLot * MathPow(MartingaleMultiplier, g_consecutiveLosses);
   if(lot > MaxLot) lot = MaxLot;

   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   if(lotStep > 0.0) lot = MathFloor(lot / lotStep) * lotStep;
   if(lot < minLot)  lot = minLot;

   return NormalizeDouble(lot, 2);
}

//+------------------------------------------------------------------+
//| Normalize lot to broker constraints                              |
//+------------------------------------------------------------------+
double NormalizeLot(double lot)
{
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(lotStep > 0.0) lot = MathFloor(lot / lotStep) * lotStep;
   if(lot < minLot)  lot = minLot;
   if(lot > maxLot)  lot = maxLot;
   if(lot > MaxLot)  lot = MaxLot;

   return NormalizeDouble(lot, 2);
}

//+------------------------------------------------------------------+
//| Update state from newest closed deal                             |
//+------------------------------------------------------------------+
void UpdateLastDealState()
{
   if(!HistorySelect(0, TimeCurrent())) return;

   int total = HistoryDealsTotal();
   if(total <= 0) return;

   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0) continue;
      if(ticket == g_lastDealTicket) return;

      long magic = HistoryDealGetInteger(ticket, DEAL_MAGIC);
      if(magic != MagicNumber) continue;

      long entry = HistoryDealGetInteger(ticket, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT) continue;

      double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT)
                    + HistoryDealGetDouble(ticket, DEAL_SWAP)
                    + HistoryDealGetDouble(ticket, DEAL_COMMISSION);

      g_lastDealTicket = ticket;

      if(profit < 0.0)
      {
         g_consecutiveLosses++;
         if(g_consecutiveLosses > MaxMartingaleSteps)
            g_consecutiveLosses = MaxMartingaleSteps;

         if(DebugMode)
            Print("[LOSS] profit=", DoubleToString(profit, 2),
                  " consecutive=", g_consecutiveLosses);

         if(g_consecutiveLosses >= MaxConsecutiveLosses)
         {
            g_pauseUntil = TimeCurrent() + PauseBarsAfterStop * PeriodSeconds(_Period);
            g_consecutiveLosses = 0;
            Print("[BRAKE] ", MaxConsecutiveLosses,
                  " consecutive losses. Pausing until ",
                  TimeToString(g_pauseUntil));
         }
      }
      else if(profit > 0.0)
      {
         if(DebugMode)
            Print("[WIN] profit=", DoubleToString(profit, 2),
                  " — martingale reset");
         g_consecutiveLosses = 0;
      }
      return;
   }
}

//+------------------------------------------------------------------+
//| Daily reset                                                      |
//+------------------------------------------------------------------+
void CheckDailyReset()
{
   datetime today = (datetime)iTime(_Symbol, PERIOD_D1, 0);
   if(today != g_dayStart)
   {
      g_dayStart          = today;
      g_dayStartBalance   = AccountInfoDouble(ACCOUNT_BALANCE);
      g_consecutiveLosses = 0;
      if(DebugMode) Print("[DAY] Reset. Balance=",
                          DoubleToString(g_dayStartBalance, 2));
   }
}

//+------------------------------------------------------------------+
//| Position helpers                                                 |
//+------------------------------------------------------------------+
int CountPositions(ENUM_POSITION_TYPE type)
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) != _Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != (long)MagicNumber) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != type) continue;
      count++;
   }
   return count;
}

void CloseAllPositions(ENUM_POSITION_TYPE type)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) != _Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != (long)MagicNumber) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != type) continue;

      ulong ticket = (ulong)PositionGetInteger(POSITION_TICKET);
      if(!trade.PositionClose(ticket))
         Print("[FAIL] Close #", ticket, ": ", trade.ResultRetcodeDescription());
      else if(DebugMode)
         Print("[CLOSE] #", ticket, " (", EnumToString(type), ")");
   }
}

//+------------------------------------------------------------------+
//| Open position                                                    |
//+------------------------------------------------------------------+
void OpenPosition(ENUM_ORDER_TYPE type, double lot)
{
   if(lot <= 0.0) return;

   double price = (type == ORDER_TYPE_BUY) ? symbolInfo.Ask() : symbolInfo.Bid();

   double slDist = SL_Points * _Point;
   double tpDist = TP_Points * _Point;

   double sl = (type == ORDER_TYPE_BUY) ? price - slDist : price + slDist;
   double tp = (type == ORDER_TYPE_BUY) ? price + tpDist : price - tpDist;

   sl = NormalizeDouble(sl, (int)symbolInfo.Digits());
   tp = NormalizeDouble(tp, (int)symbolInfo.Digits());

   double minStop = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   if(minStop > 0.0 && slDist < minStop)
   {
      Print("[SKIP] SL dist ", DoubleToString(slDist, _Digits),
            " < broker stops level ", DoubleToString(minStop, _Digits));
      return;
   }

   bool ok = (type == ORDER_TYPE_BUY)
             ? trade.Buy (lot, _Symbol, price, sl, tp, "VWAP_GREED")
             : trade.Sell(lot, _Symbol, price, sl, tp, "VWAP_GREED");

   if(!ok)
      Print("[FAIL] Open ", EnumToString(type), ": ", trade.ResultRetcode(), " - ",
            trade.ResultRetcodeDescription());
   else
      Print("[OPEN] ", EnumToString(type), " lot=", DoubleToString(lot, 2),
            " price=", DoubleToString(price, _Digits),
            " sl=", DoubleToString(sl, _Digits),
            " tp=", DoubleToString(tp, _Digits));
}

//+------------------------------------------------------------------+
//| Trailing stop + break-even                                       |
//+------------------------------------------------------------------+
void ManageOpenPositions()
{
   double trailDist  = Trailing_Distance * _Point;
   double trailStart = Trailing_Start    * _Point;
   double beTrigger  = BreakEven_Trigger * _Point;
   double beLock     = BreakEven_Lock    * _Point;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) != _Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != (long)MagicNumber) continue;

      ulong  ticket    = (ulong)PositionGetInteger(POSITION_TICKET);
      long   posType   = PositionGetInteger(POSITION_TYPE);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double curSL     = PositionGetDouble(POSITION_SL);
      double curTP     = PositionGetDouble(POSITION_TP);
      double curPrice  = PositionGetDouble(POSITION_PRICE_CURRENT);

      double newSL = curSL;

      if(posType == POSITION_TYPE_BUY)
      {
         double profit = curPrice - openPrice;

         if(UseBreakEven && profit >= beTrigger)
         {
            double be = NormalizeDouble(openPrice + beLock, _Digits);
            if(be > newSL) newSL = be;
         }
         if(UseTrailing && profit >= trailStart)
         {
            double trail = NormalizeDouble(curPrice - trailDist, _Digits);
            if(trail > newSL) newSL = trail;
         }
         if(newSL > curSL + _Point)
            trade.PositionModify(ticket, newSL, curTP);
      }
      else if(posType == POSITION_TYPE_SELL)
      {
         double profit = openPrice - curPrice;

         if(UseBreakEven && profit >= beTrigger)
         {
            double be = NormalizeDouble(openPrice - beLock, _Digits);
            if(curSL == 0.0 || be < newSL) newSL = be;
         }
         if(UseTrailing && profit >= trailStart)
         {
            double trail = NormalizeDouble(curPrice + trailDist, _Digits);
            if(curSL == 0.0 || trail < newSL) newSL = trail;
         }
         if(curSL == 0.0 || newSL < curSL - _Point)
            trade.PositionModify(ticket, newSL, curTP);
      }
   }
}
//+------------------------------------------------------------------+