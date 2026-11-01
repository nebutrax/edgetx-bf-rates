-- toolName = TNS|BF Rates|TNE
-- BF Rates: store Betaflight rate sets on the radio and load them to the FC
-- over CRSF MSP (ExpressLRS / TBS Crossfire). EdgeTX, B&W 128x64 radios (Boxer etc.).
-- Install: /SCRIPTS/TOOLS/BFRates.lua  -> SYS > Tools > "BF Rates"
-- Quad must be powered, linked, telemetry on, and DISARMED. Requires Betaflight 4.2+.
-- Slots live on the radio in /SCRIPTS/BFRates.cfg and are written to the FC's ACTIVE
-- rate profile: rates type, R/P/Y rates, throttle mid/expo and throttle limit.
-- Rate limits and any other rate-profile fields on the FC are kept.
-- Main: wheel = select slot, ENTER = menu (Apply to FC / Edit / Save FC here).
-- "*" = slot matches the FC, "~" = rates match but throttle differs.
-- Values are Betaflight raw CLI units (rc_rate / srate / expo), shown as in Configurator.

local CFG = "/SCRIPTS/BFRates.cfg"
local NAMELEN = 7
local CHARS = " ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_."

local TYPES = { [0] = "BF", "RACEFL", "KISS", "ACTUAL", "QUICK" }   -- rates_type 0..4
local TABR  = { [0] = "BF", "RF", "KS", "AC", "QK" }
local LBL = {                                   -- field names per type: rc, rate, expo
  [0] = { "RC rate", "S rate", "Expo" },
  { "Rate", "Acro+", "Expo" },
  { "RC rate", "Rate", "Curve" },
  { "Center", "Max", "Expo" },
  { "RC rate", "Max", "Expo" },
}
local TDEF = { [0] = { 100, 70, 0 }, { 37, 80, 50 }, { 100, 70, 0 }, { 7, 67, 0 }, { 100, 67, 0 } }

local AXES = { "r", "p", "y" }
local AXN  = { r = "Roll", p = "Pitch", y = "Yaw" }
-- MSP_RC_TUNING byte index (1-based) of { rc_rate, srate, expo } per axis
local MAP  = { r = { 1, 3, 2 }, p = { 13, 4, 14 }, y = { 12, 5, 11 } }
local TYPE_BYTE = 23

-- throttle: { thr_mid, thr_expo, throttle_limit_type, throttle_limit_percent }
local TH_BYTE = { 7, 8, 15, 16 }                -- MSP_RC_TUNING byte index of each
local TH_LO   = { 0, 0, 0, 25 }
local TH_HI   = { 100, 100, 2, 100 }
local TH_DEF  = { 50, 0, 0, 100 }
local TH_LBL  = { "Thr mid", "Thr expo", "Thr limit", "Thr lim %" }
local LTYPES  = { [0] = "OFF", "SCALE", "CLIP" }

local function mk(name, t, r, y, th)
  y, th = y or r, th or TH_DEF
  return { name = name, t = t, r = { r[1], r[2], r[3] }, p = { r[1], r[2], r[3] },
           y = { y[1], y[2], y[3] }, th = { th[1], th[2], th[3], th[4] } }
end

-- defaults (ACTUAL: center/10, max/10, expo/100); overwrite on the radio or with "Save FC here"
local SLOTS = {
  mk("Default", 3, { 7, 67, 0 }),
  mk("Fstyle",  3, { 15, 80, 50 }, { 15, 65, 40 }),
  mk("Cine",    3, { 10, 40, 30 }, { 10, 30, 30 }, { 50, 30, 0, 100 }),
  mk("Race",    3, { 25, 75, 20 }),
  mk("Slot5",   3, { 7, 67, 0 }),
  mk("Slot6",   3, { 7, 67, 0 }),
}

local MSP_RC_TUNING     = 111
local MSP_STATUS_EX     = 150
local MSP_SET_RC_TUNING = 204
local MSP_EEPROM_WRITE  = 250

local ADDR_FC, ADDR_RADIO = 0xC8, 0xEA
local FT_REQ, FT_RESP, FT_WRITE = 0x7A, 0x7B, 0x7C
local TX_CHUNK = 8     -- MSP bytes per CRSF frame (incl. status byte)
local TIMEOUT  = 250   -- 2.5 s per try (getTime() = 10 ms ticks)
local RETRIES  = 5     -- the first read retries until you press EXIT
local ROWS = 7
local READY = "ENTER = menu"
local MENU = { "Apply to FC", "Edit", "Save FC here" }

local page, sel, msel, state, msg = "main", 1, 1, "read", "Reading FC..."
local cfg, cur, target, rp, statAsked, gslot = nil, nil, nil, nil, false, 1
-- edit page
local eslot, items, si, top, edit, snap, dirty = 1, {}, 1, 1, false, nil, false
local nbuf, npos = {}, 1

-- TX state
local txBuf, txIdx, txCrc, txType, txPending, seq = {}, 1, 0, FT_REQ, false, 0
local lastCmd, lastSend, tries = nil, 0, 0
-- RX state
local rxBuf, rxSize, rxCmd, rxErr, rxSeq, rxOn = {}, 0, nil, false, 0, false

---------------------------------------------------------------- helpers
local function lim(t, f)
  if f == 1 then return 1, 255 end
  if f == 2 then return 0, (t == 0 or t == 2) and 100 or 255 end
  return 0, 100
end

local function clamp(x, lo, hi)
  if x < lo then return lo elseif x > hi then return hi end
  return x
end

local function copySlot(s)
  local c = { name = s.name, t = s.t, th = { s.th[1], s.th[2], s.th[3], s.th[4] } }
  for _, ax in ipairs(AXES) do c[ax] = { s[ax][1], s[ax][2], s[ax][3] } end
  return c
end

local function setVals(dst, src)
  dst.t = src.t
  for _, ax in ipairs(AXES) do
    for f = 1, 3 do dst[ax][f] = src[ax][f] end
  end
  for i = 1, 4 do dst.th[i] = src.th[i] end
end

local function sameRates(s)
  if not cur or cur.t ~= s.t then return false end
  for _, ax in ipairs(AXES) do
    for f = 1, 3 do if cur[ax][f] ~= s[ax][f] then return false end end
  end
  return true
end

local function sameThr(s)
  if not cur then return false end
  for i = 1, 4 do if cur.th[i] ~= s.th[i] then return false end end
  return true
end

local function same(s) return sameRates(s) and sameThr(s) end

local function dec(x)                          -- 0..100 -> ".50" / "1.0" (fits a narrow column)
  if x >= 100 then return "1.0" end
  return string.format(".%02d", x)
end

local function thrText(th)                    -- "Thr .50/.00 OFF", "Thr .50/.30 S80"
  local lt = (th[3] == 0) and "OFF" or (((th[3] == 1) and "S" or "C") .. th[4])
  return "Thr " .. dec(th[1]) .. "/" .. dec(th[2]) .. " " .. lt
end

local function maxDps(t, a)                   -- full-stick rate in deg/s, as Betaflight computes it
  local rc, sr, m = a[1], a[2], 0
  if t == 0 then
    local r = rc / 100
    if r > 2 then r = r + 14.54 * (r - 2) end
    m = 200 * r / math.max(1 - sr / 100, 0.01)
  elseif t == 1 then m = 10 * rc * (1 + sr / 100)
  elseif t == 2 then m = 2 * rc / math.max(1 - sr / 100, 0.01)
  elseif t == 3 then m = math.max(sr, rc) * 10
  elseif t == 4 then m = math.max(sr * 10, rc * 2) end
  return math.min(math.floor(m + 0.5), 1998)
end

local function dps3(s)
  return maxDps(s.t, s.r) .. "/" .. maxDps(s.t, s.p) .. "/" .. maxDps(s.t, s.y)
end

local function f2(x) return string.format("%.2f", x / 100) end

local function fmt(t, f, x)                    -- raw value -> Configurator display
  if f == 1 then
    if t == 1 or t == 3 then return tostring(x * 10) end
    return f2(x)
  elseif f == 2 then
    if t == 0 or t == 2 then return f2(x) end
    if t == 1 then return tostring(x) end
    return tostring(x * 10)
  end
  if t == 1 then return tostring(x) end
  return f2(x)
end

---------------------------------------------------------------- settings file
local function loadCfg()                      -- returns true if the file is missing or incomplete
  local f = io.open(CFG, "r")
  if not f then return true end
  local data = io.read(f, 2048) or ""
  io.close(f)
  local seen = 0
  for _ in string.gmatch(data, "s%d_th=") do seen = seen + 1 end
  for k, val in string.gmatch(data, "([%w_]+)=([^\r\n]*)") do
    local n, fld = string.match(k, "^s(%d)_(%a+)$")
    local s = n and SLOTS[tonumber(n)]
    if s then
      if fld == "name" then
        local nm = string.sub(string.match(val, "^%s*(.-)%s*$") or "", 1, NAMELEN)
        if nm ~= "" then s.name = nm end
      elseif fld == "t" then
        local t = tonumber(val)
        if t and t >= 0 and t <= 4 then s.t = t end
      elseif fld == "r" or fld == "p" or fld == "y" then
        local a, b, c = string.match(val, "^%s*(%d+)%s*,%s*(%d+)%s*,%s*(%d+)")
        if a then s[fld][1], s[fld][2], s[fld][3] = tonumber(a), tonumber(b), tonumber(c) end
      elseif fld == "th" then                  -- mid,expo,limit type,limit %
        local a, b, c, e = string.match(val, "^%s*(%d+)%s*,%s*(%d+)%s*,%s*(%d+)%s*,%s*(%d+)")
        if a then s.th[1], s.th[2], s.th[3], s.th[4] = tonumber(a), tonumber(b), tonumber(c), tonumber(e) end
      end
    end
  end
  for _, s in ipairs(SLOTS) do                 -- keep hand-edited values in range
    for _, ax in ipairs(AXES) do
      for fi = 1, 3 do s[ax][fi] = clamp(s[ax][fi], lim(s.t, fi)) end
    end
    for i = 1, 4 do s.th[i] = clamp(s.th[i], TH_LO[i], TH_HI[i]) end
  end
  return seen < #SLOTS                         -- older file without throttle lines
end

local function saveCfg()
  local out = ""
  for i, s in ipairs(SLOTS) do
    out = out .. "s" .. i .. "_name=" .. s.name .. "\n" .. "s" .. i .. "_t=" .. s.t .. "\n"
    for _, ax in ipairs(AXES) do
      out = out .. "s" .. i .. "_" .. ax .. "=" .. s[ax][1] .. "," .. s[ax][2] .. "," .. s[ax][3] .. "\n"
    end
    out = out .. "s" .. i .. "_th=" .. s.th[1] .. "," .. s.th[2] .. "," .. s.th[3] .. "," .. s.th[4] .. "\n"
  end
  local f = io.open(CFG, "w")
  if not f then return false end
  io.write(f, out)
  io.close(f)
  return true
end

---------------------------------------------------------------- MSP over CRSF
local function send(cmd, data, write)
  while crossfireTelemetryPop() do end           -- drop stale replies from earlier requests
  rxOn = false
  txType = write and FT_WRITE or FT_REQ
  txBuf = { #data, cmd }
  for i = 1, #data do txBuf[i + 2] = bit32.band(data[i], 0xFF) end
  txIdx, txCrc, txPending = 1, 0, true
  lastCmd, lastSend, tries = cmd, getTime(), 0
end

local function resend()
  txIdx, txCrc, txPending = 1, 0, true
  lastSend, tries = getTime(), tries + 1
end

local function pumpTx()
  if not txPending or not crossfireTelemetryPush() then return end
  local f = { ADDR_FC, ADDR_RADIO }
  local status = seq + 0x20                      -- MSP v1
  if txIdx == 1 then status = status + 0x10 end  -- start of packet
  seq = bit32.band(seq + 1, 0x0F)
  f[3] = status
  local i = 2
  while i <= TX_CHUNK and txIdx <= #txBuf do
    f[i + 2] = txBuf[txIdx]
    txCrc = bit32.bxor(txCrc, txBuf[txIdx])
    txIdx, i = txIdx + 1, i + 1
  end
  if i <= TX_CHUNK then                          -- last chunk: CRC + zero fill
    f[i + 2] = txCrc
    i = i + 1
    while i <= TX_CHUNK do f[i + 2] = 0; i = i + 1 end
    txPending = false
  end
  crossfireTelemetryPush(txType, f)
end

local function sizeOk(cmd, n)                   -- BF <= 4.2 replies carry no cmd byte:
  if cmd == MSP_RC_TUNING then return n >= 16 end   -- reject late duplicates by size
  if cmd == MSP_STATUS_EX then return n >= 15 end
  return n == 0
end

local function handleChunk(d)
  local idx = 3
  local status = d[idx]; idx = idx + 1
  local s = bit32.band(status, 0x0F)
  if bit32.btest(status, 0x10) then              -- start frame
    rxBuf, rxErr = {}, bit32.btest(status, 0x80)
    rxSize = d[idx]; idx = idx + 1
    rxCmd = lastCmd
    if bit32.rshift(bit32.band(status, 0x60), 5) == 1 then
      rxCmd = d[idx]; idx = idx + 1
    end
    rxOn = (rxCmd == lastCmd) and (rxErr or sizeOk(rxCmd, rxSize))
    if not rxOn then return nil end
  elseif not rxOn or bit32.band(rxSeq + 1, 0x0F) ~= s then
    rxOn = false
    return nil
  end
  rxSeq = s
  while idx <= #d and #rxBuf < rxSize do
    rxBuf[#rxBuf + 1] = d[idx]
    idx = idx + 1
  end
  if #rxBuf < rxSize then return nil end
  rxOn = false
  return rxCmd, rxBuf, rxErr
end

local function pollRx()
  local t, d = crossfireTelemetryPop()
  while t do
    if t == FT_RESP and d[1] == ADDR_RADIO and d[2] == ADDR_FC then
      local c, b, e = handleChunk(d)
      if c then return c, b, e end
    end
    t, d = crossfireTelemetryPop()
  end
end

---------------------------------------------------------------- FC rates <-> slot
local function fromFC(d)
  local s = { t = d[TYPE_BYTE], th = {} }
  for ax, m in pairs(MAP) do s[ax] = { d[m[1]], d[m[2]], d[m[3]] } end
  for i = 1, 4 do s.th[i] = d[TH_BYTE[i]] end
  return s
end

local function payload(s)                       -- read-modify-write of the FC's own reply
  local d = {}
  for i = 1, #cfg do d[i] = cfg[i] end
  for ax, m in pairs(MAP) do
    for f = 1, 3 do d[m[f]] = s[ax][f] end
  end
  for i = 1, 4 do d[TH_BYTE[i]] = s.th[i] end
  d[TYPE_BYTE] = s.t
  return d
end

local function onReply(cmd, d, err)
  if lastCmd == MSP_STATUS_EX then
    local ok = not err and cmd == MSP_STATUS_EX and #d >= 15
    if ok then rp = d[15] + 1 end
    if state == "chk" then
      if not ok then state, msg = "idle", "Status read failed"; return end
      if bit32.btest(d[7], 1) then state, msg = "idle", "Disarm first!"; return end
      state, msg = "write", "Writing..."
      send(MSP_SET_RC_TUNING, payload(target), true)
    else
      state, msg = "idle", READY
    end
    return
  end
  if err then state, msg = "idle", "FC error (armed?)"; return end
  if cmd == MSP_RC_TUNING then
    if #d < 23 then state, msg = "idle", "BF too old (<4.2)"; return end
    cfg = d
    cur = fromFC(d)
    if state == "verify" then
      msg = same(target) and ("Loaded: " .. target.name) or "Verify mismatch!"
      state = "idle"
    elseif state == "grab" then
      state = "idle"
      if not TYPES[cur.t] then msg = "Unknown rates type"; return end
      setVals(SLOTS[gslot], cur)
      local th = SLOTS[gslot].th
      for i = 1, 4 do th[i] = clamp(th[i] or TH_DEF[i], TH_LO[i], TH_HI[i]) end
      msg = saveCfg() and ("FC -> " .. SLOTS[gslot].name) or "Save failed!"
    else                                         -- first read after opening
      for i, s in ipairs(SLOTS) do if same(s) then sel = i end end
      if not statAsked then                      -- active rate profile, once per open
        statAsked = true
        state, msg = "stat", "Reading status..."
        send(MSP_STATUS_EX, {}, false)
        return
      end
      state, msg = "idle", READY
    end
  elseif cmd == MSP_SET_RC_TUNING then
    state, msg = "save", "Saving EEPROM..."
    send(MSP_EEPROM_WRITE, {}, false)
  elseif cmd == MSP_EEPROM_WRITE then
    state, msg = "verify", "Verifying..."
    send(MSP_RC_TUNING, {}, false)
  end
end

local function apply()
  if not cfg then
    state, msg = "read", "Reading FC..."
    send(MSP_RC_TUNING, {}, false)
    return
  end
  target = copySlot(SLOTS[sel])                  -- snapshot
  state, msg = "chk", "Checking FC..."
  send(MSP_STATUS_EX, {}, false)                 -- armed check first
end

local function grab()
  gslot = sel
  state, msg = "grab", "Reading FC..."
  send(MSP_RC_TUNING, {}, false)
end

---------------------------------------------------------------- edit page
local function openEdit()
  eslot = sel
  items = { { k = "name" }, { k = "type" } }
  for _, ax in ipairs(AXES) do
    for f = 1, 3 do items[#items + 1] = { ax = ax, f = f } end
  end
  for i = 1, 4 do items[#items + 1] = { k = "th", i = i } end
  page, si, top, edit, dirty = "edit", 1, 1, false, false
end

local function label(s, it)
  if it.k == "name" then return "Name" end
  if it.k == "type" then return "Type" end
  if it.k == "th" then return TH_LBL[it.i] end
  return AXN[it.ax] .. " " .. LBL[s.t][it.f]
end

local function valText(s, it)
  if it.k == "name" then return s.name end
  if it.k == "type" then return TYPES[s.t] end
  if it.k == "th" then
    local x = s.th[it.i]
    if it.i == 3 then return LTYPES[x] end
    if it.i == 4 then return (s.th[3] == 0) and ("(" .. x .. "%)") or (x .. "%") end
    return f2(x)
  end
  return fmt(s.t, it.f, s[it.ax][it.f])
end

local function drawEdit()
  local s = SLOTS[eslot]
  local cit = items[si]
  lcd.clear()
  lcd.drawText(1, 0, "Edit " .. s.name, SMLSIZE + INVERS)
  if cit.ax then
    lcd.drawText(84, 0, "max " .. maxDps(s.t, s[cit.ax]), SMLSIZE)
  else
    lcd.drawText(100, 0, si .. "/" .. #items, SMLSIZE)
  end
  if si < top then top = si elseif si > top + ROWS - 1 then top = si - ROWS + 1 end
  for r = 0, ROWS - 1 do
    local i = top + r
    local it = items[i]
    if not it then break end
    local y = 8 + r * 8
    lcd.drawText(2, y, label(s, it), SMLSIZE)
    if i == si and edit and it.k == "name" then  -- name editor: one char at a time
      for c = 1, NAMELEN do
        lcd.drawText(84 + (c - 1) * 6, y, nbuf[c], SMLSIZE + ((c == npos) and (INVERS + BLINK) or 0))
      end
    else
      local fl = SMLSIZE
      if i == si then fl = fl + INVERS + (edit and BLINK or 0) end
      lcd.drawText(84, y, valText(s, it), fl)
    end
  end
end

local function nameDone(s)
  local raw = ""                                 -- no table library in EdgeTX Lua
  for c = 1, NAMELEN do raw = raw .. nbuf[c] end
  local nm = string.match(raw, "^%s*(.-)%s*$")
  s.name = (nm ~= "") and nm or ("Slot" .. eslot)
  edit, dirty = false, true
end

local function adjust(s, it, d)
  if it.k == "name" then
    local idx = string.find(CHARS, nbuf[npos], 1, true) or 1
    idx = (idx - 1 + d) % #CHARS + 1
    nbuf[npos] = string.sub(CHARS, idx, idx)
  elseif it.k == "type" then                     -- new type: start from its defaults (throttle kept)
    s.t = (s.t + d) % 5
    for _, ax in ipairs(AXES) do
      for f = 1, 3 do s[ax][f] = TDEF[s.t][f] end
    end
  elseif it.k == "th" then
    local i = it.i
    if i == 3 then s.th[3] = (s.th[3] + d) % 3
    else s.th[i] = clamp(s.th[i] + d, TH_LO[i], TH_HI[i]) end
  else
    s[it.ax][it.f] = clamp(s[it.ax][it.f] + d, lim(s.t, it.f))
  end
end

local function runEdit(event)
  local s = SLOTS[eslot]
  local it = items[si]
  if edit then                                   -- wheel: INC == NEXT; keys: INC == UP
    if event == EVT_VIRTUAL_INC or event == EVT_VIRTUAL_INC_REPT then adjust(s, it, 1)
    elseif event == EVT_VIRTUAL_DEC or event == EVT_VIRTUAL_DEC_REPT then adjust(s, it, -1)
    elseif event == EVT_VIRTUAL_ENTER then
      if it.k == "name" then
        npos = npos + 1
        if npos > NAMELEN then nameDone(s) end
      else
        edit, dirty = false, true
      end
    elseif event == EVT_VIRTUAL_EXIT then
      if it.k == "name" then nameDone(s)
      else setVals(s, snap); edit = false end   -- cancel edit
    end
  else
    if event == EVT_VIRTUAL_NEXT or event == EVT_VIRTUAL_NEXT_REPT then si = math.min(si + 1, #items)
    elseif event == EVT_VIRTUAL_PREV or event == EVT_VIRTUAL_PREV_REPT then si = math.max(si - 1, 1)
    elseif event == EVT_VIRTUAL_ENTER then
      snap, edit = copySlot(s), true
      if it.k == "name" then
        for c = 1, NAMELEN do
          local ch = string.sub(s.name, c, c)
          nbuf[c] = (ch == "") and " " or ch
        end
        npos = 1
      end
    elseif event == EVT_VIRTUAL_EXIT then
      if dirty then msg = saveCfg() and "Saved - apply to FC" or "Save failed!" end
      page = "main"
    end
  end
end

---------------------------------------------------------------- main page
local function drawMain()
  lcd.clear()
  lcd.drawText(1, 0, "BF Rates   R/P/Y deg/s", SMLSIZE + INVERS)
  for i, s in ipairs(SLOTS) do
    local y = 8 + (i - 1) * 7
    lcd.drawText(2, y, s.name, SMLSIZE + ((i == sel) and INVERS or 0))
    if same(s) then lcd.drawText(38, y, "*", SMLSIZE)
    elseif sameRates(s) then lcd.drawText(38, y, "~", SMLSIZE) end   -- rates match, throttle differs
    lcd.drawText(43, y, TABR[s.t], SMLSIZE)
    lcd.drawText(56, y, dps3(s), SMLSIZE)
  end
  if cur then
    lcd.drawText(2, 50, "FC" .. (rp and (" rp" .. rp) or "") .. " " .. (TABR[cur.t] or "?") .. " " .. dps3(cur), SMLSIZE)
  end
  lcd.drawText(2, 57, msg, (state ~= "idle") and (SMLSIZE + BLINK) or SMLSIZE)
  if state ~= "idle" then
    local d = crossfireTelemetryPush()
    local st = (d == nil) and "noCRSF" or (getRSSI() == 0 and "noTLM") or ("t" .. (tries + 1) .. (d and "" or "b"))
    lcd.drawText(98, 57, st, SMLSIZE)
  end
end

local function drawMenu()
  drawMain()
  lcd.drawFilledRectangle(4, 9, 120, 46, ERASE)
  lcd.drawRectangle(4, 9, 120, 46)
  lcd.drawText(8, 11, SLOTS[sel].name, SMLSIZE)
  lcd.drawText(48, 11, thrText(SLOTS[sel].th), SMLSIZE)
  if cur then
    lcd.drawText(8, 18, "FC", SMLSIZE)
    lcd.drawText(48, 18, thrText(cur.th), SMLSIZE)
  end
  for i, m in ipairs(MENU) do
    lcd.drawText(8, 18 + i * 8, m, SMLSIZE + ((i == msel) and INVERS or 0))
  end
end

local function init()
  if loadCfg() then saveCfg() end              -- create / upgrade BFRates.cfg on open
  send(MSP_RC_TUNING, {}, false)
end

local function run(event)
  if state ~= "idle" then                        -- MSP engine runs on every page
    pumpTx()
    local c, d, e = pollRx()
    if c then
      onReply(c, d, e)
    elseif getTime() - lastSend > TIMEOUT then
      if tries < RETRIES or state == "read" then resend()
      elseif state == "stat" then state, msg = "idle", READY   -- status is optional on open
      else state, msg = "idle", "No reply - telem?" end
    end
  end

  if page == "edit" then
    runEdit(event)
  elseif page == "menu" then
    if event == EVT_VIRTUAL_NEXT then msel = msel % #MENU + 1
    elseif event == EVT_VIRTUAL_PREV then msel = (msel - 2) % #MENU + 1
    elseif event == EVT_VIRTUAL_EXIT then page = "main"
    elseif event == EVT_VIRTUAL_ENTER then
      if msel == 2 then openEdit()
      elseif state == "idle" then
        page = "main"
        if msel == 1 then apply() else grab() end
      end
    end
  else
    if event == EVT_VIRTUAL_EXIT then
      if state == "idle" then return 1 end
      state, msg, txPending = "idle", "Cancelled", false
    elseif event == EVT_VIRTUAL_NEXT then sel = sel % #SLOTS + 1
    elseif event == EVT_VIRTUAL_PREV then sel = (sel - 2) % #SLOTS + 1
    elseif event == EVT_VIRTUAL_ENTER then page, msel = "menu", 1
    end
  end

  if page == "edit" then drawEdit() elseif page == "menu" then drawMenu() else drawMain() end
  return 0
end

return { init = init, run = run }
