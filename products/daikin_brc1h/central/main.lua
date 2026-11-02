-- Daikin Madoka BRC1H central: chunked UART function-ID + TLV over 2141e112/2141e111.

local SVC = uuids.SVC_UART
local CHR_TX = uuids.CHR_UART_TX
local CHR_RX = uuids.CHR_UART_RX

local FN_INFO = 0x0000
local FN_POWER = 0x0020
local FN_MODE = 0x0030
local FN_SETPOINT = 0x0040
local FN_SENSOR = 0x0110
local SET_BIT = 0x4000

local MODE_NAMES = {
  [0] = "fan",
  [1] = "dry",
  [2] = "auto",
  [3] = "cool",
  [4] = "heat",
}

local function to_u8(n)
  n = math.floor(tonumber(n) or 0) % 256
  if n < 0 then
    n = n + 256
  end
  return n
end

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

local function tlv(id, value_hex)
  value_hex = norm_hex(value_hex or "")
  local len = math.floor(#value_hex / 2)
  return string.format("%02x%02x%s", to_u8(id), to_u8(len), value_hex)
end

local function c_to_q7(t)
  t = tonumber(t) or 0
  local r = math.floor(t)
  local frac = t - r
  return r * 128 + math.floor(frac * 128 + 0.5)
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

local function ensure_ready()
  if not ble_connected() then
    gfx_print_text("Not connected")
    return false
  end
  if type(SVC) ~= "string" or type(CHR_TX) ~= "string" or type(CHR_RX) ~= "string" then
    gfx_print_text("Missing uuids")
    return false
  end
  if gatt_has_characteristic(SVC, CHR_TX) == false then
    gfx_print_text("UART TX missing")
    return false
  end
  if not ble_subscribe(SVC, CHR_RX) then
    gfx_print_text("Subscribe failed")
    return false
  end
  return true
end

local function request(payload_hex)
  if not ensure_ready() then
    return nil
  end
  local chunks = chunk(payload_hex)
  start_notify_wait(SVC, CHR_RX, 80)
  for i = 1, #chunks do
    if not ble_write(SVC, CHR_TX, chunks[i], true) then
      gfx_print_text("Write failed")
      return nil
    end
  end
  local raw = finish_notify_wait(SVC, CHR_RX, 5000)
  if not raw then
    return nil
  end
  return dechunk(raw)
end

local function get_fn(fn)
  return request(be16(fn) .. "0000")
end

local function set_fn(fn, body_hex)
  return request(be16(fn + SET_BIT) .. body_hex)
end

local function apply_status(power_hex, mode_hex, set_hex, sensor_hex)
  local power, mode, cool, heat, indoor, outdoor
  if power_hex and #power_hex >= 4 then
    local t = parse_tlvs(power_hex:sub(5))
    if t[0x20] then
      power = hex_byte(t[0x20], 1) ~= 0
    end
  end
  if mode_hex and #mode_hex >= 4 then
    local t = parse_tlvs(mode_hex:sub(5))
    if t[0x20] then
      mode = hex_byte(t[0x20], 1)
    end
  end
  if set_hex and #set_hex >= 4 then
    local t = parse_tlvs(set_hex:sub(5))
    if t[0x20] then
      cool = q7_to_c(parse_be16(t[0x20], 1))
    end
    if t[0x21] then
      heat = q7_to_c(parse_be16(t[0x21], 1))
    end
  end
  if sensor_hex and #sensor_hex >= 4 then
    local t = parse_tlvs(sensor_hex:sub(5))
    if t[0x40] then
      indoor = hex_byte(t[0x40], 1)
    end
    if t[0x41] then
      outdoor = hex_byte(t[0x41], 1)
    end
  end
  return {
    power = power,
    mode = mode,
    cool = cool,
    heat = heat,
    indoor = indoor,
    outdoor = outdoor,
  }
end

local function push_status(st)
  if st.power ~= nil then
    set_state("power", st.power and "ON" or "OFF")
    fp_set("power", st.power and "on" or "off")
  end
  if st.mode ~= nil then
    local name = MODE_NAMES[st.mode] or tostring(st.mode)
    set_state("mode", name)
    fp_set("mode", name)
  end
  if st.cool ~= nil then
    set_state("cool", tostring(st.cool) .. "°")
    fp_set("cool_setpoint", tostring(st.cool))
  end
  if st.heat ~= nil then
    set_state("heat", tostring(st.heat) .. "°")
    fp_set("heat_setpoint", tostring(st.heat))
  end
  if st.indoor ~= nil then
    set_state("indoor", tostring(st.indoor) .. "°")
    fp_set("indoor_temp", tostring(st.indoor))
  end
  if st.outdoor ~= nil then
    fp_set("outdoor_temp", tostring(st.outdoor))
  end
end

local function summary(st)
  local parts = {}
  if st.power ~= nil then
    parts[#parts + 1] = st.power and "ON" or "OFF"
  end
  if st.mode ~= nil then
    parts[#parts + 1] = MODE_NAMES[st.mode] or tostring(st.mode)
  end
  if st.cool ~= nil then
    parts[#parts + 1] = "cool " .. tostring(st.cool) .. "°"
  end
  if st.heat ~= nil then
    parts[#parts + 1] = "heat " .. tostring(st.heat) .. "°"
  end
  if st.indoor ~= nil then
    parts[#parts + 1] = "in " .. tostring(st.indoor) .. "°"
  end
  if st.outdoor ~= nil then
    parts[#parts + 1] = "out " .. tostring(st.outdoor) .. "°"
  end
  return #parts > 0 and table.concat(parts, " · ") or "no reply"
end

local function refresh_status()
  local power = get_fn(FN_POWER)
  local mode = get_fn(FN_MODE)
  local setp = get_fn(FN_SETPOINT)
  local sens = get_fn(FN_SENSOR)
  local st = apply_status(power, mode, setp, sens)
  push_status(st)
  local line = summary(st)
  set_title(line)
  gfx_print_text(line)
  fp_set("display_info", "Madoka · " .. line)
  push_fingerprint({
    protocol = "daikin_madoka",
    status_summary = line,
    power = st.power and "on" or (st.power == false and "off" or ""),
    mode = st.mode and (MODE_NAMES[st.mode] or tostring(st.mode)) or "",
  }, nil)
  return st
end

function on_connected()
  if type(SVC) == "string" and type(CHR_RX) == "string" then
    ble_subscribe(SVC, CHR_RX)
    delay_ms(150)
  end
  -- Bonding probe used by the official app (GET 0x0000).
  get_fn(FN_INFO)
end

function on_main_enter()
  set_title("Madoka BRC1H")
end

function on_get_status()
  refresh_status()
end

function on_power_on()
  local hex = set_fn(FN_POWER, tlv(0x20, "01"))
  if hex then
    set_state("power", "ON")
    gfx_print_text("Power ON")
  else
    gfx_print_text("Power ON failed")
  end
end

function on_power_off()
  local hex = set_fn(FN_POWER, tlv(0x20, "00"))
  if hex then
    set_state("power", "OFF")
    gfx_print_text("Power OFF")
  else
    gfx_print_text("Power OFF failed")
  end
end

local function set_mode(id, label)
  local hex = set_fn(FN_MODE, tlv(0x20, string.format("%02x", id)))
  if hex then
    set_state("mode", label)
    gfx_print_text("Mode " .. label)
  else
    gfx_print_text("Mode failed")
  end
end

function on_mode_cool()
  set_mode(3, "cool")
end

function on_mode_heat()
  set_mode(4, "heat")
end

function on_mode_auto()
  set_mode(2, "auto")
end

function on_mode_fan()
  set_mode(0, "fan")
end

function on_mode_dry()
  set_mode(1, "dry")
end

function on_mode_menu()
  push_menu("mode")
end

function on_setpoint_menu()
  push_menu("setpoint")
end

local function set_cool(c)
  local hex = set_fn(FN_SETPOINT, tlv(0x20, be16(c_to_q7(c))))
  if hex then
    set_state("cool", tostring(c) .. "°")
    gfx_print_text("Cool " .. tostring(c) .. "°")
  else
    gfx_print_text("Set cool failed")
  end
end

local function set_heat(c)
  local hex = set_fn(FN_SETPOINT, tlv(0x21, be16(c_to_q7(c))))
  if hex then
    set_state("heat", tostring(c) .. "°")
    gfx_print_text("Heat " .. tostring(c) .. "°")
  else
    gfx_print_text("Set heat failed")
  end
end

function on_cool_22()
  set_cool(22)
end

function on_cool_24()
  set_cool(24)
end

function on_cool_26()
  set_cool(26)
end

function on_heat_18()
  set_heat(18)
end

function on_heat_20()
  set_heat(20)
end

function on_heat_22()
  set_heat(22)
end
