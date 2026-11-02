-- Mijia thermometer peripheral. vars.model selects the protocol:
--   MJ_HT_V1    V1 advertisement object 0x100D (0.1°C / 0.1% RH), name in scan response
--   LYWSD03MMC  V2 identity beacon (default) plus ebe0ccc1 notify
--   LYWSD02     V3 identity beacon, notify, battery percent on ebe0ccc4, clock on ebe0ccb7
--   MHO-C401    V4 identity beacon plus the same notify layout as V2

local SVC = uuids.SVC_MIJIA
local CHR = uuids.CHR_SENSOR
local ADV_PROFILE_ID = "adv1"
local DEFAULT_ADDR = "A4:C1:38:00:5B:03"

local function clamp(n, lo, hi)
  n = math.floor(n)
  if n < lo then
    return lo
  end
  if n > hi then
    return hi
  end
  return n
end

local function temp_c()
  local c = 23.56
  if type(vars) == "table" and vars.temperature_c ~= nil then
    c = tonumber(vars.temperature_c) or c
  end
  return c
end

local function temp_centi()
  local c = temp_c()
  local centi = math.floor(c * 100 + (c >= 0 and 0.5 or -0.5))
  return clamp(centi, -32768, 32767)
end

local function humidity_percent()
  local h = 45
  if type(vars) == "table" and vars.humidity_percent ~= nil then
    h = tonumber(vars.humidity_percent) or h
  end
  return clamp(h, 0, 100)
end

local function battery_mv()
  local mv = 3000
  if type(vars) == "table" and vars.battery_mv ~= nil then
    mv = tonumber(vars.battery_mv) or mv
  end
  return clamp(mv, 0, 65535)
end

local function battery_percent()
  return clamp(math.floor((battery_mv() * 100) / 3100), 0, 100)
end

local function frame_counter()
  local n = 1
  if type(vars) == "table" and vars.frame_counter ~= nil then
    n = tonumber(vars.frame_counter) or n
  end
  return clamp(n, 0, 255)
end

local function model_name()
  local name = "LYWSD03MMC"
  if type(vars) == "table" and type(vars.model) == "string" and vars.model ~= "" then
    name = vars.model
  end
  if name == "MJ_HT_V1" or name == "LYWSD02" or name == "LYWSD03MMC" or name == "MHO-C401" then
    return name
  end
  return "LYWSD03MMC"
end

local function model_kind()
  local name = model_name()
  if name == "MJ_HT_V1" then
    return "v1"
  end
  if name == "LYWSD02" then
    return "v3"
  end
  if name == "MHO-C401" then
    return "v4"
  end
  return "v2"
end

-- int16 LE temperature (0.01°C), uint8 humidity, uint16 LE millivolts.
local function sensor_hex()
  return hex.le16(temp_centi()) .. hex.u8(humidity_percent()) .. hex.le16(battery_mv())
end

local function reading_line()
  local name = model_name()
  if model_kind() == "v1" then
    local c = temp_c()
    local deci_t = math.floor(c * 10 + (c >= 0 and 0.5 or -0.5))
    local deci_h = humidity_percent() * 10
    return string.format("%s  %.1f°C  %.1f%% RH", name, deci_t / 10, deci_h / 10)
  end
  local pct = battery_percent()
  local line = string.format("%s  %.2f°C  %d%%  %d mV (%d%%)", name, temp_centi() / 100, humidity_percent(), battery_mv(), pct)
  if model_kind() == "v3" then
    line = line .. "  clock"
  end
  return line
end

local function show_reading()
  if type(gfx_show) == "function" then
    gfx_show("thermometer")
  end
  if type(gfx_render_text) ~= "function" or type(gfx_update_text) ~= "function" then
    return
  end
  gfx_render_text("reading", "bottom_center", 0, -12, 0x333333)
  gfx_update_text("reading", reading_line(), 0x333333)
end

local function mac_reversed()
  local addr = nil
  if type(get_adv_bd_addr) == "function" then
    addr = get_adv_bd_addr(ADV_PROFILE_ID)
  end
  if type(addr) ~= "string" or addr == "" then
    addr = DEFAULT_ADDR
  end
  local rev = mac.reverse_octets(addr)
  if type(rev) ~= "string" or #rev ~= 12 then
    return mac.reverse_octets(DEFAULT_ADDR)
  end
  return rev
end

local function name_tlv(name)
  return hex.u8(1 + #name) .. "09" .. hex.from_ascii(name)
end

local function fe95_ad(payload)
  local payload_len = math.floor(#payload / 2)
  return hex.u8(1 + 2 + payload_len) .. "1695fe" .. payload
end

local function identity_payload(product_le)
  return "3058" .. product_le .. hex.u8(frame_counter()) .. mac_reversed() .. "08"
end

local function v1_payload()
  local c = temp_c()
  local deci_t = clamp(math.floor(c * 10 + (c >= 0 and 0.5 or -0.5)), -32768, 32767)
  local deci_h = clamp(humidity_percent() * 10, 0, 65535)
  return "5020aa01" .. hex.u8(frame_counter()) .. mac_reversed() .. "0d1004" .. hex.le16(deci_t) .. hex.le16(deci_h)
end

-- Flags + FE95 service data. Complete Local Name is appended when the legacy PDU still has room.
local function apply_adv()
  if type(adv_set_data) ~= "function" then
    return
  end
  local kind = model_kind()
  local payload
  if kind == "v1" then
    payload = v1_payload()
  elseif kind == "v3" then
    payload = identity_payload("5b04")
  elseif kind == "v4" then
    payload = identity_payload("8703")
  else
    payload = identity_payload("5b05")
  end
  local ntlv = name_tlv(model_name())
  local body = "020106" .. fe95_ad(payload)
  local adv = body
  if (#body + #ntlv) <= 62 then
    adv = body .. ntlv
  end
  local ok, err = adv_set_data(ADV_PROFILE_ID, adv, ntlv)
  if ok ~= true then
    print("mijia: adv_set_data: " .. tostring(err))
  end
end

function on_read_name(_input)
  return model_name()
end

function on_read_sensor(_input)
  return hex_to_bin(sensor_hex())
end

function on_read_battery(_input)
  return string.char(battery_percent())
end

function on_read_time(_input)
  local t = 0
  if type(get_time) == "function" then
    t = get_time() or 0
  end
  if type(vars) == "table" and vars.unix_time ~= nil then
    t = tonumber(vars.unix_time) or t
  end
  if t < 0 then
    t = 0
  end
  return hex_to_bin(hex.le32(math.floor(t)))
end

function push_sensor_notify()
  if type(ble_connected) ~= "function" or not ble_connected() then
    return
  end
  local notified, ok_or_err, err = pcall(ble_notify, SVC, CHR, sensor_hex())
  if not notified then
    print("mijia: notify error: " .. tostring(ok_or_err))
  elseif ok_or_err ~= true and err and err ~= "" then
    print("mijia: notify: " .. tostring(err))
  end
  show_reading()
  delay(2, "push_sensor_notify")
end

function on_connected()
  show_reading()
  delay(0.3, "push_sensor_notify")
end

function on_startup()
  apply_adv()
  show_reading()
  if type(gfx_print_notification) == "function" then
    gfx_print_notification(reading_line(), "top_center", 0, 8)
  end
end
