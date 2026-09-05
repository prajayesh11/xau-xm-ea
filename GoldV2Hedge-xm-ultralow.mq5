//+------------------------------------------------------------------+
//|                                          AIGold_XM_UltraLow.mq5 |
//|                       MLP (ONNX) – Pure AI Signal                |
//|                     ADAPTED FOR XM ULTRA LOW STANDARD            |
//|                        + Session Filter & Logging                |
//+------------------------------------------------------------------+
#property copyright "Your Name"
#property link      "https://www.yourwebsite.com"
#property version   "1.01"

//+------------------------------------------------------------------+
//| Include the ONNX model as a resource                             |
//+------------------------------------------------------------------+
#resource "\\Files\\gold_price_model.onnx" as uchar ExtModel[];

//+------------------------------------------------------------------+
//| INPUT PARAMETERS – Only essential ones                           |
//+------------------------------------------------------------------+
input double   InpLotSize           = 0.01;          // Base lot size (if risk % = 0)
input double   InpRiskPercent       = 0.5;           // Risk per trade (% of equity)
input bool     InpUseNewBarOnly     = true;          // Act only on new bar
input int      InpMagicNumber       = 20240828;      // EA identifier

// --- Dynamic Stop-Loss & Take-Profit (ATR based) ---
input int      InpATRPeriod         = 100;           // ATR calculation period
input double   InpATRMultiplierSL   = 1.0;           // SL = ATR * this
input double   InpATRMultiplierTP   = 3.0;           // TP = ATR * this

// --- Trailing Stop ---
input double   InpTrailingStartATR  = 1.0;           // Start trail when profit > 1*ATR
input double   InpTrailingStepATR   = 0.5;           // Trail step distance

// --- AI Signal Parameters ---
input double   InpSignalThreshold   = 0.001;         // 0.1% minimum predicted change

// --- Filters ---
input int      InpMaxSpreadPoints   = 50;            // Max allowed spread (adjust as needed)

// --- Session Filter --- (NEW)
input bool     InpUseSessionFilter   = true;         // Enable session filter
input int      InpAsianStartHour     = 0;            // Asian session start hour (server time, 0-23)
input int      InpLondonStartHour    = 8;            // London session start hour
input int      InpNYStartHour        = 13;           // New York session start hour
input int      InpBlackoutMinutes    = 30;           // No trading minutes before/after session start

//+------------------------------------------------------------------+
//| Commission – XM Ultra Low Standard has ZERO commission          |
//+------------------------------------------------------------------+
#define COMMISSION_PER_SIDE 0.0

//+------------------------------------------------------------------+
//| Global variables (modifiable at runtime)                         |
//+------------------------------------------------------------------+
double g_RiskPercent     = InpRiskPercent;
double g_SLMultiplier    = InpATRMultiplierSL;
double g_TPMultiplier    = InpATRMultiplierTP;
bool   g_AutoTrade       = true;

//+------------------------------------------------------------------+
//| Global EA variables                                              |
//+------------------------------------------------------------------+
long         m_onnx_handle = INVALID_HANDLE;
string       m_symbol      = "GOLD.i#";
ENUM_TIMEFRAMES m_timeframe = PERIOD_H1;
datetime     m_lastBarTime = 0;

int          m_atr_handle  = INVALID_HANDLE;
double       m_currentATR  = 0.0;

#define N_FEATURES 24   // 6 assets * 4 lags

// Asset symbols – verify they exist on your XM demo
string AssetSymbols[] = {
    "BTCUSD#",   // Bitcoin
    "EURUSD#",   // Euro/USD
    "GBPUSD#",   // GBP/USD
    "USDJPY#",   // USD/JPY
    "OILCash#",  // WTI Crude Oil (if not available, try "USOIL")
    "GOLD.i#"    // Gold (also a feature)
};

//+------------------------------------------------------------------+
//| SCALER PARAMETERS – REPLACE WITH YOUR ACTUAL VALUES             |
//+------------------------------------------------------------------+
double feature_means[N_FEATURES] = {
    4254.410065, 4255.455885, 4253.354615, 259.581389, 0.000000, 21.561848, 4254.409153, 4255.454969, 4253.353704, 259.579929, 0.000000, 21.561948, 4254.408245, 4255.454063, 4253.352790, 259.579779, 0.000000, 21.561908, 4254.407342, 4255.453157, 4253.351896, 259.578449, 0.000000, 21.562038
};

double feature_scales[N_FEATURES] = {
    195.766147, 195.777897, 195.751238, 118.789473, 1.000000, 4.858860, 195.765118, 195.776864, 195.750205, 118.790881, 1.000000, 4.859055, 195.764091, 195.775840, 195.749167, 118.791077, 1.000000, 4.859026, 195.763067, 195.774817, 195.748154, 118.792679, 1.000000, 4.859319
};

//+------------------------------------------------------------------+
//| Session data structures (NEW)                                    |
//+------------------------------------------------------------------+
struct SessionInfo {
   int   startHour;
   string name;
};
SessionInfo g_sessions[];
string     g_lastSession = "";

//+------------------------------------------------------------------+
//| Helper: Error description                                        |
//+------------------------------------------------------------------+
string ErrorDescription(int err) {
   switch(err) {
      case 4801: return "Indicator cannot be loaded - check symbol availability and data";
      default: return IntegerToString(err);
   }
}

//+------------------------------------------------------------------+
//| Sort sessions by start hour (ascending)                          |
//+------------------------------------------------------------------+
void SortSessions() {
   int n = ArraySize(g_sessions);
   for(int i=0; i<n-1; i++) {
      for(int j=0; j<n-i-1; j++) {
         if(g_sessions[j].startHour > g_sessions[j+1].startHour) {
            SessionInfo temp = g_sessions[j];
            g_sessions[j] = g_sessions[j+1];
            g_sessions[j+1] = temp;
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Get current session name                                         |
//+------------------------------------------------------------------+
string GetCurrentSessionName() {
   datetime now = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(now, dt);
   int hour = dt.hour;
   int total = ArraySize(g_sessions);
   if(total == 0) return "Unknown";
   // Find the session whose interval contains the current hour
   for(int i=0; i<total; i++) {
      int nextStart = (i+1 < total) ? g_sessions[i+1].startHour : 24;
      if(hour >= g_sessions[i].startHour && hour < nextStart) {
         return g_sessions[i].name;
      }
   }
   // If hour is before the first session start, it's off-hours
   return "Off-hours";
}

//+------------------------------------------------------------------+
//| Check if trading is allowed (not in blackout)                    |
//+------------------------------------------------------------------+
bool IsTradingTimeAllowed() {
   if(!InpUseSessionFilter) return true;
   datetime now = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(now, dt);
   // Base date at 00:00 today
   MqlDateTime today;
   TimeToStruct(now, today);
   today.hour = 0; today.min = 0; today.sec = 0;
   datetime todayStart = StructToTime(today);
   
   int blackoutSec = InpBlackoutMinutes * 60;
   int total = ArraySize(g_sessions);
   for(int i=0; i<total; i++) {
      // Compute session start time today
      datetime sessionStart = todayStart + g_sessions[i].startHour * 3600;
      datetime startBlackout = sessionStart - blackoutSec;
      datetime endBlackout   = sessionStart + blackoutSec;
      
      // Check if 'now' falls within the blackout interval
      if(now >= startBlackout && now <= endBlackout) {
         return false;
      }
   }
   return true;
}

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit() {
   Print("Account: ", AccountInfoString(ACCOUNT_NAME));
   Print("Broker: ", AccountInfoString(ACCOUNT_COMPANY));

   // --- Initialize session array from inputs (NEW) ---
   ArrayResize(g_sessions, 3);
   g_sessions[0].startHour = InpAsianStartHour;  g_sessions[0].name = "Asian";
   g_sessions[1].startHour = InpLondonStartHour; g_sessions[1].name = "London";
   g_sessions[2].startHour = InpNYStartHour;     g_sessions[2].name = "New York";
   SortSessions();
   g_lastSession = ""; // force print on first tick

   // --- Verify that XAUUSD is available ---
   if(!SymbolSelect(m_symbol, true)) {
      Print("Symbol ", m_symbol, " is not available. Please add it to Market Watch.");
      return INIT_FAILED;
   }
   if(iBars(m_symbol, m_timeframe) < 10) {
      Print("Not enough data for ", m_symbol, ". Please download historical data.");
      return INIT_FAILED;
   }

   // Load ONNX
   m_onnx_handle = OnnxCreateFromBuffer(ExtModel, ONNX_DEFAULT);
   if(m_onnx_handle == INVALID_HANDLE) {
      Print("Failed to load ONNX. Error: ", GetLastError());
      return INIT_FAILED;
   }
   ulong input_shape[] = {1, N_FEATURES};
   if(!OnnxSetInputShape(m_onnx_handle, 0, input_shape)) {
      Print("Failed set input shape. Error: ", GetLastError());
      return INIT_FAILED;
   }
   ulong output_shape[] = {1, 1};
   if(!OnnxSetOutputShape(m_onnx_handle, 0, output_shape)) {
      Print("Failed set output shape. Error: ", GetLastError());
      return INIT_FAILED;
   }

   // ATR indicator
   m_atr_handle = iATR(m_symbol, m_timeframe, InpATRPeriod);
   if(m_atr_handle == INVALID_HANDLE) {
      int err = GetLastError();
      Print("Failed to create ATR handle. Error: ", err, " (", ErrorDescription(err), ")");
      return INIT_FAILED;
   }

   Print("EA loaded successfully for XM Ultra Low Standard.");
   Print("Session filter ", InpUseSessionFilter ? "ENABLED" : "DISABLED");
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Deinit                                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
   if(m_onnx_handle != INVALID_HANDLE) OnnxRelease(m_onnx_handle);
   if(m_atr_handle != INVALID_HANDLE) IndicatorRelease(m_atr_handle);
}

//+------------------------------------------------------------------+
//| Tick                                                             |
//+------------------------------------------------------------------+
void OnTick() {
   if(!UpdateIndicators()) return;

   datetime curBarTime = iTime(m_symbol, m_timeframe, 0);
   bool isNewBar = (InpUseNewBarOnly && curBarTime != m_lastBarTime);
   if(isNewBar) {
      m_lastBarTime = curBarTime;
      // On a new bar, check and log session change (NEW)
      string currentSession = GetCurrentSessionName();
      if(currentSession != g_lastSession) {
         Print("=== Session changed to ", currentSession, " ===");
         g_lastSession = currentSession;
      }
   }

   double spread = (SymbolInfoDouble(m_symbol, SYMBOL_ASK) - SymbolInfoDouble(m_symbol, SYMBOL_BID)) / 
                   SymbolInfoDouble(m_symbol, SYMBOL_POINT);
   if(spread > InpMaxSpreadPoints) return;

   double currentPrice = SymbolInfoDouble(m_symbol, SYMBOL_BID);
   if(currentPrice <= 0) return;
   float features[N_FEATURES];
   if(!BuildFeatures(features)) return;
   float output[1];
   if(!OnnxRun(m_onnx_handle, ONNX_NO_CONVERSION, features, output)) return;
   double predictedPrice = (double)output[0];
   ENUM_ORDER_TYPE mlpSignal = GetMLPSignal(currentPrice, predictedPrice);

   if(mlpSignal != -1) {
      // --- Check session filter before opening new trades (NEW) ---
      if(!IsTradingTimeAllowed()) {
         // Optionally print a reminder once per bar
         if(isNewBar) Print("Trading blocked due to session blackout.");
         return;
      }

      bool hasBuy = PositionExists(ORDER_TYPE_BUY);
      bool hasSell = PositionExists(ORDER_TYPE_SELL);
      
      if(mlpSignal == ORDER_TYPE_BUY && hasSell) {
         CloseAllPositions();
         hasSell = false;
      }
      else if(mlpSignal == ORDER_TYPE_SELL && hasBuy) {
         CloseAllPositions();
         hasBuy = false;
      }
      
      if(mlpSignal == ORDER_TYPE_BUY && !hasBuy) {
         ExecuteOrder(ORDER_TYPE_BUY);
      }
      else if(mlpSignal == ORDER_TYPE_SELL && !hasSell) {
         ExecuteOrder(ORDER_TYPE_SELL);
      }
   }

   ManageTrailingStop();
}

//+------------------------------------------------------------------+
//| Update ATR value                                                 |
//+------------------------------------------------------------------+
bool UpdateIndicators() {
   double atrBuffer[1];
   if(CopyBuffer(m_atr_handle, 0, 0, 1, atrBuffer) != 1) return false;
   m_currentATR = atrBuffer[0];
   return true;
}

//+------------------------------------------------------------------+
//| Build features for ONNX model                                    |
//+------------------------------------------------------------------+
bool BuildFeatures(float &features[]) {
   int n_assets = ArraySize(AssetSymbols);
   if(n_assets != 6) return false;
   int idx = 0;
   for(int lag=4; lag>=1; lag--) {
      for(int a=0; a<n_assets; a++) {
         string sym = AssetSymbols[a];
         double high = GetHighPrice(sym, m_timeframe, lag);
         if(high <= 0) return false;
         features[idx++] = (float)high;
      }
   }
   for(int i=0; i<N_FEATURES; i++)
      features[i] = (features[i] - (float)feature_means[i]) / (float)feature_scales[i];
   return true;
}

double GetHighPrice(string symbol, ENUM_TIMEFRAMES tf, int shift) {
   double high[];
   ArraySetAsSeries(high, true);
   if(CopyHigh(symbol, tf, shift, 1, high) != 1) return -1;
   return high[0];
}

//+------------------------------------------------------------------+
//| MLP signal                                                       |
//+------------------------------------------------------------------+
ENUM_ORDER_TYPE GetMLPSignal(double currentPrice, double predictedPrice) {
   double change = (predictedPrice - currentPrice) / currentPrice;
   if(change > InpSignalThreshold) return ORDER_TYPE_BUY;
   if(change < -InpSignalThreshold) return ORDER_TYPE_SELL;
   return -1;
}

//+------------------------------------------------------------------+
//| Position exists (by direction)                                   |
//+------------------------------------------------------------------+
bool PositionExists(ENUM_ORDER_TYPE signal) {
   for(int i=PositionsTotal()-1; i>=0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0) continue;
      if(PositionGetString(POSITION_SYMBOL)!=m_symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=InpMagicNumber) continue;
      ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if(signal==ORDER_TYPE_BUY && posType==POSITION_TYPE_BUY) return true;
      if(signal==ORDER_TYPE_SELL && posType==POSITION_TYPE_SELL) return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Count positions (total open by this EA)                          |
//+------------------------------------------------------------------+
int CountPositions() {
   int cnt=0;
   for(int i=PositionsTotal()-1; i>=0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(ticket>0 && PositionGetString(POSITION_SYMBOL)==m_symbol &&
         PositionGetInteger(POSITION_MAGIC)==InpMagicNumber)
         cnt++;
   }
   return cnt;
}

//+------------------------------------------------------------------+
//| Calculate lot size based on risk                                 |
//+------------------------------------------------------------------+
double CalculateLotSize(double slPoints) {
   if(g_RiskPercent <= 0) return InpLotSize;
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskAmount = equity * g_RiskPercent / 100.0;
   double tickValue = SymbolInfoDouble(m_symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(m_symbol, SYMBOL_TRADE_TICK_SIZE);
   double point = SymbolInfoDouble(m_symbol, SYMBOL_POINT);
   double slTicks = slPoints * point / tickSize;
   double riskPerLot = slTicks * tickValue;
   if(riskPerLot <= 0) return InpLotSize;
   double lot = riskAmount / riskPerLot;
   double minLot = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_STEP);
   lot = MathRound(lot / stepLot) * stepLot;
   lot = fmax(minLot, fmin(maxLot, lot));
   return lot;
}

//+------------------------------------------------------------------+
//| Execute order                                                    |
//+------------------------------------------------------------------+
void ExecuteOrder(ENUM_ORDER_TYPE signal) {
   if(m_currentATR <= 0) { Print("Invalid ATR."); return; }
   MqlTick tick;
   if(!SymbolInfoTick(m_symbol, tick)) return;
   double point = SymbolInfoDouble(m_symbol, SYMBOL_POINT);
   double entry = (signal == ORDER_TYPE_BUY) ? tick.ask : tick.bid;
   double slDist = g_SLMultiplier * m_currentATR;
   double tpDist = g_TPMultiplier * m_currentATR;
   double slPoints = slDist / point;

   double sl, tp;
   if(signal == ORDER_TYPE_BUY) { sl = entry - slDist; tp = entry + tpDist; }
   else { sl = entry + slDist; tp = entry - tpDist; }

   double tickSize = SymbolInfoDouble(m_symbol, SYMBOL_TRADE_TICK_SIZE);
   int digits = (int)SymbolInfoInteger(m_symbol, SYMBOL_DIGITS);
   sl = NormalizeDouble(MathRound(sl / tickSize) * tickSize, digits);
   tp = NormalizeDouble(MathRound(tp / tickSize) * tickSize, digits);
   entry = NormalizeDouble(MathRound(entry / tickSize) * tickSize, digits);

   double lot = CalculateLotSize(slPoints);
   if(lot <= 0) lot = InpLotSize;

   double spread = (tick.ask - tick.bid) / point;
   double commissionUSD = COMMISSION_PER_SIDE * lot;

   // Get current session name for logging and comment (NEW)
   string sessionName = GetCurrentSessionName();

   Print("=== TRADE ===");
   Print("Entry: ", entry, " | SL: ", sl, " | TP: ", tp);
   Print("ATR: ", m_currentATR, " | Spread: ", spread, " pts");
   Print("Lot: ", lot, " | Risk: $", AccountInfoDouble(ACCOUNT_EQUITY)*g_RiskPercent/100);
   Print("Session: ", sessionName);

   MqlTradeRequest request = {};
   MqlTradeResult result = {};
   request.action   = TRADE_ACTION_DEAL;
   request.symbol   = m_symbol;
   request.volume   = lot;
   request.type     = signal;
   request.price    = entry;
   request.sl       = sl;
   request.tp       = tp;
   request.deviation= 20;
   request.magic    = InpMagicNumber;
   request.comment  = "XM_MLP_AI_" + sessionName; // include session in comment
   request.type_filling = ORDER_FILLING_IOC;

   if(!OrderSend(request, result)) {
      Print("OrderSend failed. Error: ", GetLastError(), " retcode: ", result.retcode);
   } else {
      Print("Order placed.");
   }
}

//+------------------------------------------------------------------+
//| Manage trailing stop                                             |
//+------------------------------------------------------------------+
void ManageTrailingStop() {
   if(m_currentATR <= 0) return;
   for(int i=PositionsTotal()-1; i>=0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0) continue;
      if(PositionGetString(POSITION_SYMBOL)!=m_symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=InpMagicNumber) continue;
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);
      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double bid = SymbolInfoDouble(m_symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(m_symbol, SYMBOL_ASK);
      double point = SymbolInfoDouble(m_symbol, SYMBOL_POINT);
      double trailDistance = InpTrailingStartATR * m_currentATR;

      if(type == POSITION_TYPE_BUY) {
         double profitPoints = (bid - openPrice) / point;
         if(profitPoints > trailDistance / point) {
            double newSL = bid - (InpTrailingStepATR * m_currentATR);
            newSL = NormalizeDouble(MathRound(newSL / point) * point, (int)SymbolInfoInteger(m_symbol, SYMBOL_DIGITS));
            if(newSL > currentSL) ModifyPosition(ticket, newSL, currentTP);
         }
      } else if(type == POSITION_TYPE_SELL) {
         double profitPoints = (openPrice - ask) / point;
         if(profitPoints > trailDistance / point) {
            double newSL = ask + (InpTrailingStepATR * m_currentATR);
            newSL = NormalizeDouble(MathRound(newSL / point) * point, (int)SymbolInfoInteger(m_symbol, SYMBOL_DIGITS));
            if(newSL < currentSL || currentSL == 0) ModifyPosition(ticket, newSL, currentTP);
         }
      }
   }
}

void ModifyPosition(ulong ticket, double newSL, double newTP) {
   MqlTradeRequest request = {};
   MqlTradeResult result = {};
   request.action = TRADE_ACTION_SLTP;
   request.position = ticket;
   request.symbol = m_symbol;
   request.sl = newSL;
   request.tp = newTP;
   request.deviation = 10;
   request.magic = InpMagicNumber;
   if(OrderSend(request, result)) {
      Print("Trailing stop updated.");
   }
}

//+------------------------------------------------------------------+
//| Close all positions                                              |
//+------------------------------------------------------------------+
void CloseAllPositions() {
   for(int i=PositionsTotal()-1; i>=0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(ticket>0 && PositionGetString(POSITION_SYMBOL)==m_symbol &&
         PositionGetInteger(POSITION_MAGIC)==InpMagicNumber) {
         MqlTradeRequest req = {};
         MqlTradeResult res = {};
         req.action = TRADE_ACTION_DEAL;
         req.symbol = m_symbol;
         req.volume = PositionGetDouble(POSITION_VOLUME);
         req.type = (PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
         req.price = (req.type==ORDER_TYPE_BUY) ? SymbolInfoDouble(m_symbol,SYMBOL_ASK) : SymbolInfoDouble(m_symbol,SYMBOL_BID);
         req.deviation = 20;
         req.magic = InpMagicNumber;
         req.comment = "Close all";
         req.type_filling = ORDER_FILLING_IOC;
         if(!OrderSend(req, res)) {
            Print("Close order failed. Error: ", GetLastError(), " retcode: ", res.retcode);
         }
      }
   }
}
//+------------------------------------------------------------------+