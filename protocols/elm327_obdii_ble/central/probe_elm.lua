-- Confirm the FFF0 UART. ATI is the adapter banner. ATE0 turns echo off.
-- ATRV is the adapter's own reading of OBD pin 16. It does not talk to an ECU.
-- 0100 is mode 01 PID 00 (supported PIDs). NO DATA / UNABLE TO CONNECT
-- still means the adapter spoke; only silence means the channel failed.
-- SEARCHING with no later reply is the same outcome as UNABLE TO CONNECT.
-- ATZ is the fallback when ATI returns nothing, because it resets the chip.

local SVC = uuids.SVC_UART
local CHR_NOTIFY = uuids.CHR_NOTIFY
local CHR_WRITE = uuids.CHR_WRITE

local function squash(text)
  return ((text or ""):upper():gsub("%s+", ""))
end

local function shorten(text, limit)
  text = ((text or ""):gsub("%s+", " "))
  if #text <= limit then
    return text
  end
  return text:sub(1, limit - 3) .. "..."
end

local function identity_from(text)
  local lower = (text or ""):lower()
  local at = lower:find("elm", 1, true)
  if not at then
    return "adapter"
  end
  local slice = text:sub(at, at + 16)
  slice = (slice:gsub("[^%w%._ ]", ""))
  slice = (slice:gsub("%s+", " "))
  slice = (slice:gsub("^%s+", ""))
  slice = (slice:gsub("%s+$", ""))
  if slice == "" then
    return "adapter"
  end
  return slice
end

local UNABLE_HINT = "UNABLE TO CONNECT means the dongle answered, but no control unit did. Turn the ignition on. Some cars stay silent until the engine is running."
local APP_HINT = "For live data and more tests, use a dedicated app such as Car Scanner (connection type Bluetooth LE)."

local function show_line(line)
  log("elm327: " .. line)
  gfx_print_text(line)
end

local function tidy(text)
  text = shorten(text or "", 72)
  if text == "" then
    return "(no reply)"
  end
  return text
end

local function write_command(ascii)
  local payload = hex.from_ascii(ascii .. "\r")
  local ok, err = ble_write(SVC, CHR_WRITE, payload, true)
  if ok then
    return true
  end
  local ok2, err2 = ble_write(SVC, CHR_WRITE, payload)
  if ok2 then
    return true
  end
  return false, err2 or err or "write failed"
end

local function exchange(ascii, timeout_ms)
  show_line(">> " .. ascii)
  start_notify_wait(SVC, CHR_NOTIFY, 200)
  local ok, err = write_command(ascii)
  if not ok then
    show_line("<< " .. ascii .. " failed: " .. tostring(err or "write failed"))
    return nil, err
  end
  local got = finish_notify_wait(SVC, CHR_NOTIFY, timeout_ms or 5000) or ""
  local text = hex.to_ascii(got)
  local flat = squash(text)
  if flat:find("SEARCHING", 1, true) and not text:find(">", 1, true) then
    show_line("<< " .. ascii .. " " .. tidy(text))
    start_notify_wait(SVC, CHR_NOTIFY, 250)
    local more = finish_notify_wait(SVC, CHR_NOTIFY, 8000) or ""
    local rest = hex.to_ascii(more)
    if rest ~= "" then
      show_line("<< " .. ascii .. " " .. tidy(rest))
    end
    got = got .. more
    text = hex.to_ascii(got)
  else
    show_line("<< " .. ascii .. " " .. tidy(text))
  end
  return text, nil
end

local function channel_up(text)
  if not text or text == "" then
    return false
  end
  local flat = squash(text)
  if flat:find("ELM", 1, true) or flat:find("OK", 1, true) then
    return true
  end
  return text:find(">", 1, true) ~= nil
end

local function voltage_from(text)
  local flat = ((text or ""):upper():gsub("%s+", ""))
  local reading = flat:match("(%d+%.%d+)V") or flat:match("(%d+)V")
  if not reading then
    return nil
  end
  return reading .. "V"
end

local function classify_obd(text)
  local flat = squash(text)
  if flat:find("4100", 1, true) then
    return "ecu"
  end
  if flat:find("NODATA", 1, true)
    or flat:find("UNABLE", 1, true)
    or flat:find("STOPPED", 1, true)
    or flat:find("BUSINIT", 1, true)
    or flat:find("ERROR", 1, true)
    or flat:find("CANERROR", 1, true) then
    return "no_ecu"
  end
  if flat:find("SEARCHING", 1, true) and not (text or ""):find(">", 1, true) then
    return "no_ecu"
  end
  if text and text ~= "" then
    return "unparsed"
  end
  return "silent"
end

function run()
  if not ble_connected() then
    log("elm327: not connected")
    gfx_print_text("Not connected")
    return
  end
  if fp_get("protocol") ~= "elm327_obdii_ble" then
    log("elm327: protocol fingerprint missing")
    gfx_print_text("Not an OBDII BLE UART")
    return
  end
  if gatt_has_characteristic(SVC, CHR_NOTIFY) == false
    or gatt_has_characteristic(SVC, CHR_WRITE) == false then
    log("elm327: FFF1/FFF2 missing")
    gfx_print_text("FFF0 UART missing")
    return
  end

  if type(set_preferred_mtu) == "function" then
    set_preferred_mtu(136)
  end
  if not ble_subscribe(SVC, CHR_NOTIFY) then
    log("elm327: subscribe FFF1 failed")
    gfx_print_text("Subscribe failed")
    return
  end

  local banner, banner_err = exchange("ATI", 4000)
  local used_reset = "false"
  if not channel_up(banner) then
    show_line("ATI empty (" .. tostring(banner_err) .. "), trying ATZ")
    banner, banner_err = exchange("ATZ", 5000)
    used_reset = "true"
  end
  if not channel_up(banner) then
    show_line("No adapter reply (" .. tostring(banner_err) .. ")")
    fp_append("elm327_probe", {
      protocol = "elm327_obdii_ble",
      channel = "silent",
      adapter = "not_connected",
      bus = "not_connected",
      obd_query = "0100",
      obd_result = "not_sent",
    }, "ELM327 probe", "Adapter not connected, bus not connected. UART did not answer ATI or ATZ")
    return
  end

  exchange("ATE0", 2500)

  local atrv = exchange("ATRV", 2500)
  local volts = voltage_from(atrv)

  local obd, obd_err = exchange("0100", 8000)
  local kind = classify_obd(obd)
  local identity = identity_from(banner)

  local head = identity
  if volts then
    head = head .. " · " .. volts
  end

  local summary
  if kind == "ecu" then
    summary = head .. " · ECU " .. shorten(obd, 40)
  elseif kind == "no_ecu" then
    summary = head .. " · UART ok, no ECU"
  elseif kind == "unparsed" then
    summary = head .. " · " .. shorten(obd, 40)
  else
    summary = head .. " · 0100 silent"
  end

  local hint_parts = {}
  local obd_flat = squash(obd)
  local searching_stuck = obd_flat:find("SEARCHING", 1, true) and not (obd or ""):find(">", 1, true)
  local bus_ok = kind == "ecu"
  if bus_ok then
    hint_parts[#hint_parts + 1] = "Adapter connected, bus connected."
  else
    hint_parts[#hint_parts + 1] = "Adapter connected, bus not connected."
  end
  if obd_flat:find("UNABLE", 1, true) or searching_stuck then
    hint_parts[#hint_parts + 1] = UNABLE_HINT
  end
  hint_parts[#hint_parts + 1] = APP_HINT
  local hint = table.concat(hint_parts, " ")

  show_line(summary)
  if obd_err then
    show_line("0100 " .. tostring(obd_err))
  end
  show_line(hint)

  fp_set("display_info", summary)
  fp_append("elm327_probe", {
    protocol = "elm327_obdii_ble",
    channel = "ok",
    adapter = "connected",
    bus = bus_ok and "connected" or "not_connected",
    identity = identity,
    reset_fallback = used_reset,
    voltage = volts or "",
    atrv_text = shorten(atrv, 80),
    obd_query = "0100",
    obd_result = kind,
    obd_text = shorten(obd, 160),
    ati_text = shorten(banner, 160),
  }, "ELM327 probe", hint)
end
