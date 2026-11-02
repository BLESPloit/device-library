-- Daikin Madoka BRC1H peripheral: UCG UART chunked function-ID + TLV.

local SVC = uuids.SVC_UART
local CHR_RX = uuids.CHR_UART_RX
local ADV_PROFILE_ID = "brc1h_madoka"
local ADV_PREFIX = "020106110677ae8c12719e7bb6e6113a2110e1412105ff9300e000"

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

local function ascii_to_hex(s)
  local parts = {}
  for i = 1, #s do
    parts[i] = string.format("%02x", string.byte(s, i))
  end
  return table.concat(parts)
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
  -- Keep integer °C for sim display; Q7 fraction in low 7 bits.
  local frac = (u16 % 128) / 128
  return e + math.floor(frac * 100 + 0.5) / 100
end

local function bool_on()
  return vars.power_on == true or vars.power_on == "true" or vars.power_on == 1 or vars.power_on == "1"
end

local function mode_id()
  return math.floor(tonumber(vars.mode) or 3)
end

local function persist()
  if type(vars_save) == "function" then
    vars_save()
  end
end

local function status_label()
  local p = bool_on() and "ON" or "OFF"
  local m = MODE_NAMES[mode_id()] or tostring(mode_id())
  local t = tonumber(vars.indoor_temp) or 0
  local sp = (mode_id() == 4) and (tonumber(vars.heat_setpoint) or 21) or (tonumber(vars.cool_setpoint) or 24)
  return string.format("%s · %s · %s° / %s°", p, m, tostring(sp), tostring(t))
end

local function refresh_ui()
  if type(gfx_update_text) == "function" then
    gfx_update_text("status", status_label())
  end
end

local function unit_name_from_addr(addr)
  if not addr or addr == "" then
    return vars.unit_name or "BRC1H 46:DC:ED"
  end
  local parts = {}
  for byte in addr:upper():gmatch("%x%x") do
    parts[#parts + 1] = byte
  end
  if #parts ~= 6 then
    return vars.unit_name or "BRC1H 46:DC:ED"
  end
  return "BRC1H " .. parts[4] .. ":" .. parts[5] .. ":" .. parts[6]
end

local function apply_adv()
  if type(adv_set_data) ~= "function" then
    return
  end
  local name = vars.unit_name or "BRC1H 46:DC:ED"
  if type(get_adv_bd_addr) == "function" then
    local addr = get_adv_bd_addr(ADV_PROFILE_ID)
    if addr and addr ~= "" then
      name = unit_name_from_addr(addr)
      vars.unit_name = name
    end
  end
  local name_hex = ascii_to_hex(name)
  local scan = string.format("%02x08%s%02x09%s", 1 + 6, ascii_to_hex("Daikin"), 1 + #name, name_hex):lower()
  local ok, err = adv_set_data(ADV_PROFILE_ID, ADV_PREFIX, scan)
  if ok ~= true then
    print("madoka: adv_set_data: " .. tostring(err))
  end
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
  local pos = 1
  local out = {}
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
    out[#out + 1] = { id = id, len = len, value = value }
  end
  return out
end

local function notify_payload(payload_hex)
  if type(SVC) ~= "string" or type(CHR_RX) ~= "string" then
    print("madoka: missing UART uuids")
    return
  end
  local chunks = chunk(payload_hex)
  for i = 1, #chunks do
    local ok, err = ble_notify(SVC, CHR_RX, chunks[i])
    if ok ~= true then
      print("madoka: ble_notify failed: " .. tostring(err))
      return
    end
  end
end

local function handle_get(fn)
  if fn == FN_INFO then
    return be16(FN_INFO) .. tlv(0x10, "7f") .. tlv(0x11, "1f") .. tlv(0x12, "0f") .. tlv(0x13, "0f")
  end
  if fn == FN_POWER then
    return be16(FN_POWER) .. tlv(0x10, "01") .. tlv(0x15, "00") .. tlv(0x20, bool_on() and "01" or "00")
  end
  if fn == FN_MODE then
    return be16(FN_MODE)
      .. tlv(0x12, "1f")
      .. tlv(0x20, string.format("%02x", to_u8(mode_id())))
  end
  if fn == FN_SETPOINT then
    return be16(FN_SETPOINT)
      .. tlv(0x20, be16(c_to_q7(tonumber(vars.cool_setpoint) or 24)))
      .. tlv(0x21, be16(c_to_q7(tonumber(vars.heat_setpoint) or 21)))
  end
  if fn == FN_SENSOR then
    return be16(FN_SENSOR)
      .. tlv(0x40, string.format("%02x", to_u8(tonumber(vars.indoor_temp) or 23)))
      .. tlv(0x41, string.format("%02x", to_u8(tonumber(vars.outdoor_temp) or 12)))
  end
  return be16(fn) .. "0000"
end

local function handle_set(fn, tlvs)
  local ok_body = ""
  for i = 1, #tlvs do
    local p = tlvs[i]
    if fn == FN_POWER and p.id == 0x20 then
      vars.power_on = hex_byte(p.value, 1) ~= 0
      ok_body = ok_body .. tlv(0x20, "00")
    elseif fn == FN_MODE and p.id == 0x20 then
      vars.mode = hex_byte(p.value, 1)
      ok_body = ok_body .. tlv(0x20, "00")
    elseif fn == FN_SETPOINT and p.id == 0x20 then
      vars.cool_setpoint = q7_to_c(parse_be16(p.value, 1))
      ok_body = ok_body .. tlv(0x20, "00")
    elseif fn == FN_SETPOINT and p.id == 0x21 then
      vars.heat_setpoint = q7_to_c(parse_be16(p.value, 1))
      ok_body = ok_body .. tlv(0x21, "00")
    elseif p.len > 0 then
      ok_body = ok_body .. tlv(p.id, "00")
    end
  end
  persist()
  refresh_ui()
  if type(gfx_print_notification) == "function" then
    gfx_print_notification(status_label(), "top_center", 0, 8)
  end
  if ok_body == "" then
    ok_body = "0000"
  end
  return be16(fn + SET_BIT) .. ok_body
end

local function handle_message(payload_hex)
  payload_hex = norm_hex(payload_hex)
  if #payload_hex < 4 then
    return
  end
  local hdr = parse_be16(payload_hex, 1)
  local is_set = hdr >= SET_BIT
  local fn = hdr % SET_BIT
  local body = payload_hex:sub(5)
  local reply
  if is_set then
    reply = handle_set(fn, parse_tlvs(body))
  else
    reply = handle_get(fn)
  end
  notify_payload(reply)
end

local function feed_chunk(hex)
  hex = norm_hex(hex)
  if hex == "" then
    return
  end
  local idx = hex:sub(1, 2)
  if idx == "00" then
    vars.rx_buf = hex
    if #hex >= 6 then
      vars.rx_need = parse_le16_hex4(hex:sub(3, 6))
    else
      vars.rx_need = 0
    end
  else
    vars.rx_buf = (vars.rx_buf or "") .. hex
  end
  local buf = vars.rx_buf or ""
  local need = tonumber(vars.rx_need) or 0
  -- Accumulated bytes after the 1-byte index of chunk 0 must reach `need`.
  -- Wire length ≈ (#buf/2). Complete when dechunk yields a payload of need-2 bytes.
  local payload = dechunk(buf)
  if payload and need > 0 and math.floor(#payload / 2) >= (need - 2) then
    vars.rx_buf = ""
    vars.rx_need = 0
    handle_message(payload)
  elseif idx == "00" and need > 0 and need <= 17 then
    -- Single-chunk messages: payload fits in first frame.
    if payload then
      vars.rx_buf = ""
      vars.rx_need = 0
      handle_message(payload)
    end
  end
end

function on_write_uart_tx(input)
  local hex = bin_to_hex(input)
  feed_chunk(hex)
  return input
end

function toggle_power()
  vars.power_on = not bool_on()
  persist()
  refresh_ui()
  if type(gfx_print_notification) == "function" then
    gfx_print_notification(status_label(), "top_center", 0, 8)
  end
end

function on_startup()
  if vars.power_on == nil then
    vars.power_on = true
  end
  if vars.mode == nil then
    vars.mode = 3
  end
  vars.rx_buf = ""
  vars.rx_need = 0
  apply_adv()
  gfx_show("thermostat")
  if type(gfx_render_text) == "function" then
    gfx_render_text("status", "top_center", 0, 88, 0xFFFFFF)
  end
  refresh_ui()
  gfx_print_notification(vars.display_label or "Madoka BRC1H sim", "top_center", 0, 8)
end
