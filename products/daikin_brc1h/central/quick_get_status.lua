-- Quick action: GET power, mode, setpoint, and indoor/outdoor temperatures.

local SVC = uuids.SVC_UART
local CHR_TX = uuids.CHR_UART_TX
local CHR_RX = uuids.CHR_UART_RX

local FN_POWER = 0x0020
local FN_MODE = 0x0030
local FN_SETPOINT = 0x0040
local FN_SENSOR = 0x0110

local MODE_NAMES = {
  [0] = "fan",
  [1] = "dry",
  [2] = "auto",
  [3] = "cool",
  [4] = "heat",
}

local function norm_hex(h)
  if type(h) ~= "string" then
    return ""
  end
  return h:gsub("%s+", ""):lower()
end

local function be16(n)
  n = math.floor(tonumber(n) or 0) % 65536
  return string.format("%02x%02x", math.floor(n / 256), n % 256)
end

local function le16(n)
  n = math.floor(tonumber(n) or 0) % 65536
  return string.format("%02x%02x", n % 256, math.floor(n / 256))
end

local function parse_be16(hex, i1)
  local p = (i1 - 1) * 2 + 1
  local hi = tonumber(hex:sub(p, p + 1), 16) or 0
  local lo = tonumber(hex:sub(p + 2, p + 3), 16) or 0
  return hi * 256 + lo
end

local function parse_le16_hex4(hex4)
  local lo = tonumber(hex4:sub(1, 2), 16) or 0
  local hi = tonumber(hex4:sub(3, 4), 16) or 0
  return lo + hi * 256
end

local function hex_byte(hex, i1)
  local p = (i1 - 1) * 2 + 1
  return tonumber(hex:sub(p, p + 1), 16) or 0
end

local function q7_to_c(u16)
  u16 = math.floor(tonumber(u16) or 0) % 65536
  local e = math.floor(u16 / 128)
  local frac = (u16 % 128) / 128
  return e + math.floor(frac * 100 + 0.5) / 100
end

local function chunk(payload_hex)
  payload_hex = norm_hex(payload_hex)
  local s = #payload_hex
  local u = (s + 4) / 2
  local first = math.min(34, s)
  local out = { "00" .. le16(u) .. payload_hex:sub(1, first) }
  local pos = first + 1
  local idx = 1
  while pos <= s do
    local take = math.min(38, s - pos + 1)
    out[#out + 1] = string.format("%02x", idx) .. payload_hex:sub(pos, pos + take - 1)
    pos = pos + take
    idx = idx + 1
  end
  return out
end

local function dechunk(hex)
  hex = norm_hex(hex)
  if #hex < 6 or hex:sub(1, 2) ~= "00" then
    return nil
  end
  local n = parse_le16_hex4(hex:sub(3, 6))
  local payload_bytes = n - 2
  if payload_bytes < 0 then
    return nil
  end
  local pos = 7
  local first_pay = math.min(17, payload_bytes)
  local out = hex:sub(pos, pos + first_pay * 2 - 1)
  pos = pos + first_pay * 2
  local remaining = payload_bytes - first_pay
  while remaining > 0 do
    if pos + 1 > #hex then
      break
    end
    pos = pos + 2
    local take = math.min(19, remaining)
    out = out .. hex:sub(pos, pos + take * 2 - 1)
    pos = pos + take * 2
    remaining = remaining - take
  end
  return out
end

local function parse_tlvs(hex)
  hex = norm_hex(hex)
  local map = {}
  local pos = 1
  while pos + 3 <= #hex do
    local id = tonumber(hex:sub(pos, pos + 1), 16)
    local len = tonumber(hex:sub(pos + 2, pos + 3), 16)
    if not id or not len then
      break
    end
    pos = pos + 4
    local value = ""
    if len > 0 then
      value = hex:sub(pos, pos + len * 2 - 1)
      pos = pos + len * 2
    end
    map[id] = value
  end
  return map
end

local function get_fn(fn)
  local payload = be16(fn) .. "0000"
  local chunks = chunk(payload)
  start_notify_wait(SVC, CHR_RX, 80)
  for i = 1, #chunks do
    if not ble_write(SVC, CHR_TX, chunks[i], true) then
      return nil
    end
  end
  local raw = finish_notify_wait(SVC, CHR_RX, 5000)
  if not raw then
    return nil
  end
  return dechunk(raw)
end

function run()
  if not ble_connected() then
    log("madoka: not connected")
    gfx_print_text("Not connected")
    return
  end
  if type(SVC) ~= "string" or type(CHR_TX) ~= "string" or type(CHR_RX) ~= "string" then
    gfx_print_text("Missing uuids")
    return
  end

  if not ble_subscribe(SVC, CHR_RX) then
    gfx_print_text("Subscribe failed")
    return
  end
  delay_ms(150)

  local power_hex = get_fn(FN_POWER)
  local mode_hex = get_fn(FN_MODE)
  local set_hex = get_fn(FN_SETPOINT)
  local sens_hex = get_fn(FN_SENSOR)

  local power, mode, cool, heat, indoor, outdoor
  if power_hex then
    local t = parse_tlvs(power_hex:sub(5))
    if t[0x20] then
      power = hex_byte(t[0x20], 1) ~= 0
    end
  end
  if mode_hex then
    local t = parse_tlvs(mode_hex:sub(5))
    if t[0x20] then
      mode = hex_byte(t[0x20], 1)
    end
  end
  if set_hex then
    local t = parse_tlvs(set_hex:sub(5))
    if t[0x20] then
      cool = q7_to_c(parse_be16(t[0x20], 1))
    end
    if t[0x21] then
      heat = q7_to_c(parse_be16(t[0x21], 1))
    end
  end
  if sens_hex then
    local t = parse_tlvs(sens_hex:sub(5))
    if t[0x40] then
      indoor = hex_byte(t[0x40], 1)
    end
    if t[0x41] then
      outdoor = hex_byte(t[0x41], 1)
    end
  end

  local parts = {}
  if power ~= nil then
    parts[#parts + 1] = power and "ON" or "OFF"
  end
  if mode ~= nil then
    parts[#parts + 1] = MODE_NAMES[mode] or tostring(mode)
  end
  if cool ~= nil then
    parts[#parts + 1] = "cool " .. tostring(cool) .. "°"
  end
  if heat ~= nil then
    parts[#parts + 1] = "heat " .. tostring(heat) .. "°"
  end
  if indoor ~= nil then
    parts[#parts + 1] = "in " .. tostring(indoor) .. "°"
  end
  if outdoor ~= nil then
    parts[#parts + 1] = "out " .. tostring(outdoor) .. "°"
  end
  local line = #parts > 0 and table.concat(parts, " · ") or "no reply"

  log("=== Madoka BRC1H ===")
  log("power  : " .. tostring(power_hex))
  log("mode   : " .. tostring(mode_hex))
  log("setpt  : " .. tostring(set_hex))
  log("sensor : " .. tostring(sens_hex))
  log("Summary: " .. line)

  fp_set("display_info", "Madoka · " .. line)
  if power ~= nil then
    fp_set("power", power and "on" or "off")
  end
  if mode ~= nil then
    fp_set("mode", MODE_NAMES[mode] or tostring(mode))
  end
  if cool ~= nil then
    fp_set("cool_setpoint", tostring(cool))
  end
  if heat ~= nil then
    fp_set("heat_setpoint", tostring(heat))
  end
  if indoor ~= nil then
    fp_set("indoor_temp", tostring(indoor))
  end
  if outdoor ~= nil then
    fp_set("outdoor_temp", tostring(outdoor))
  end
  fp_append("daikin_brc1h_status", {
    protocol = "daikin_madoka",
    status_summary = line,
  }, "Madoka status")

  gfx_print_text(line)
end
