-- Drone Remote ID peripheral (ASTM F3411 / EN 4709-002).
-- vars.adv_mode:
--   legacy (default) — Bluetooth 4 legacy advertisements, one 25-byte message
--     each, rotating Basic ID, Location, and System. A pack does not fit in 31 bytes.
--   ble5 — one Bluetooth 5 extended advertisement with a message pack (type 0xF) on LE Coded.
-- Service data is 16 FA FF 0D <counter> <message or pack>.
-- odid_rotate must stay global: delay() looks the callback up by name.
-- The first physical button calls toggle_broadcast to switch mode while running.
-- Restart the sim after editing vars.

local LEGACY_PROFILE = "legacy"
local BLE5_PROFILE = "ble5"

local rotating = false
local ble5_active = false
local rotate_epoch = 0
local slot = 0
local counter = 0

local function round(x)
  if x >= 0 then
    return math.floor(x + 0.5)
  end
  return math.ceil(x - 0.5)
end

local function clamp(n, lo, hi)
  if n < lo then
    return lo
  end
  if n > hi then
    return hi
  end
  return n
end

local function num(v, fallback)
  local n = tonumber(v)
  if n == nil then
    return fallback
  end
  return n
end

local function header(msg_type)
  local ver = clamp(math.floor(num(vars.proto_version, 2)), 0, 15)
  return hex.u8(msg_type * 16 + ver)
end

local function le32s(n)
  n = round(n)
  if n < 0 then
    n = n + 4294967296
  end
  return hex.le32(n)
end

local function latlon(deg)
  return le32s(num(deg, 0) * 10000000)
end

local function enc_alt(m)
  if m == nil then
    return 65535
  end
  return clamp(round((num(m, 0) + 1000) * 2), 0, 65534)
end

local function pad_id(s)
  if type(s) ~= "string" then
    s = ""
  end
  if #s > 20 then
    s = s:sub(1, 20)
  end
  local h = hex.from_ascii(s)
  local missing = 20 - (hex.len(h))
  if missing > 0 then
    h = h .. string.rep("00", missing)
  end
  return h:sub(1, 40)
end

local function enc_basic()
  local id_type = clamp(math.floor(num(vars.id_type, 1)), 0, 15)
  local ua_type = clamp(math.floor(num(vars.ua_type, 2)), 0, 15)
  return header(0) .. hex.u8(id_type * 16 + ua_type) .. pad_id(vars.uas_id) .. "000000"
end

local function enc_speed_h(mps)
  mps = num(mps, -1)
  if mps < 0 then
    return 255, 0
  end
  if mps <= 63.75 then
    return clamp(round(mps / 0.25), 0, 254), 0
  end
  return clamp(round((mps - 63.75) / 0.75), 0, 254), 1
end

local function enc_dir(deg)
  if deg == nil then
    return 255, 0
  end
  local d = math.floor(num(deg, 0) + 0.5) % 360
  if d < 0 then
    d = d + 360
  end
  if d >= 180 then
    return d - 180, 1
  end
  return d, 0
end

local function enc_location()
  local sh, speed_mult = enc_speed_h(vars.speed_h_mps)
  local direction, ew = enc_dir(vars.direction_deg)
  local height_bit = 0
  if vars.height_agl == true then
    height_bit = 1
  end
  local status = clamp(math.floor(num(vars.status, 2)), 0, 15)
  local flags = speed_mult + ew * 2 + height_bit * 4 + status * 16
  local v = -128
  if vars.speed_v_mps ~= nil then
    v = clamp(round(num(vars.speed_v_mps, 0) / 0.5), -127, 127)
  end
  local msg = header(1)
    .. hex.u8(flags)
    .. hex.u8(direction)
    .. hex.u8(sh)
    .. hex.u8(v)
    .. latlon(vars.latitude)
    .. latlon(vars.longitude)
    .. hex.le16(enc_alt(vars.altitude_baro_m))
    .. hex.le16(enc_alt(vars.altitude_geo_m))
    .. hex.le16(enc_alt(vars.height_m))
    .. "0000"
    .. "ffff"
    .. "0000"
  return msg
end

local function enc_system()
  local op_loc = clamp(math.floor(num(vars.operator_location_type, 1)), 0, 3)
  local msg = header(4)
    .. hex.u8(op_loc)
    .. latlon(vars.operator_latitude)
    .. latlon(vars.operator_longitude)
    .. hex.le16(1)
    .. "00"
    .. "ffff"
    .. "ffff"
    .. "00"
    .. hex.le16(enc_alt(vars.operator_altitude_m))
    .. "ffffffff"
    .. "00"
  return msg
end

local function std_messages()
  return { enc_basic(), enc_location(), enc_system() }
end

local function wrap_service(counter_byte, payload)
  if hex.len(payload) < 25 then
    return nil, "short payload"
  end
  local value = "faff0d" .. hex.u8(counter_byte) .. payload
  return hex.u8(1 + hex.len(value)) .. "16" .. value, nil
end

local function enc_pack(parts)
  local n = #parts
  if n < 1 or n > 9 then
    return nil, "pack count"
  end
  local body = header(0xF) .. hex.u8(25) .. hex.u8(n)
  local i = 1
  while i <= n do
    if hex.len(parts[i]) ~= 25 then
      return nil, "message length " .. tostring(hex.len(parts[i]))
    end
    body = body .. parts[i]
    i = i + 1
  end
  return body, nil
end

local function apply(profile, adv_hex)
  if type(adv_set_data) ~= "function" then
    print("drone_remote_id: adv_set_data missing")
    return false
  end
  local ok, err = adv_set_data(profile, adv_hex)
  if not ok then
    print("drone_remote_id: adv_set_data " .. profile .. " failed: " .. tostring(err))
    return false
  end
  return true
end

local function profile_off(id)
  if type(adv_disable) == "function" then
    adv_disable(id)
  end
end

local function profile_on(id)
  if type(adv_enable) == "function" then
    adv_enable(id)
  end
end

local function use_ble5()
  local mode = vars.adv_mode
  if type(mode) ~= "string" then
    return false
  end
  mode = mode:lower():gsub("%s+", "")
  return mode == "ble5" or mode == "bt5" or mode == "extended"
end

local function legacy_interval()
  local interval = num(vars.legacy_interval_s, 0.333)
  if interval < 0.1 then
    return 0.1
  end
  if interval > 3 then
    return 3
  end
  return interval
end

local function show_mode()
  local label = ble5_active and "Bluetooth 5" or "Bluetooth 4"
  if type(gfx_render_text) == "function" then
    gfx_render_text("broadcast_mode", "bottom_center", 0, -12, 0x333333)
  end
  if type(gfx_update_text) == "function" then
    gfx_update_text("broadcast_mode", label, 0x333333)
  end
end

local function start_ble5()
  local pack, err = enc_pack(std_messages())
  if not pack then
    print("drone_remote_id: " .. tostring(err))
    return false
  end
  local adv_hex, wrap_err = wrap_service(counter, pack)
  if not adv_hex then
    print("drone_remote_id: " .. tostring(wrap_err))
    return false
  end
  rotating = false
  rotate_epoch = rotate_epoch + 1
  ble5_active = true
  profile_off(LEGACY_PROFILE)
  apply(BLE5_PROFILE, adv_hex)
  profile_on(BLE5_PROFILE)
  show_mode()
  print("drone_remote_id: BLE 5 message pack " .. adv_hex)
  return true
end

local function arm_rotate()
  local stamp = rotate_epoch
  function odid_rotate()
    if stamp ~= rotate_epoch or not rotating then
      return
    end
    local parts = std_messages()
    slot = slot + 1
    if slot > #parts then
      slot = 1
    end
    local adv_hex, err = wrap_service(counter, parts[slot])
    if adv_hex then
      apply(LEGACY_PROFILE, adv_hex)
      counter = (counter + 1) % 256
    else
      print("drone_remote_id: " .. tostring(err))
    end
    if stamp == rotate_epoch and rotating and type(delay) == "function" then
      delay(legacy_interval(), "odid_rotate")
    end
  end
  odid_rotate()
end

local function start_legacy()
  ble5_active = false
  rotating = true
  rotate_epoch = rotate_epoch + 1
  profile_off(BLE5_PROFILE)
  profile_on(LEGACY_PROFILE)
  show_mode()
  if type(delay) ~= "function" then
    local adv_hex = wrap_service(counter, enc_basic())
    if adv_hex then
      apply(LEGACY_PROFILE, adv_hex)
    end
    print("drone_remote_id: delay() missing, advertising Basic ID only")
    return true
  end
  arm_rotate()
  return true
end

function toggle_broadcast()
  if ble5_active then
    start_legacy()
  else
    start_ble5()
  end
end

function on_startup()
  gfx_show("drone_mark")
  if type(vars) ~= "table" then
    print("drone_remote_id: vars missing, using static adv.json")
    return
  end
  counter = math.floor(num(vars.msg_counter, 0)) % 256
  if counter < 0 then
    counter = counter + 256
  end
  slot = 0

  if use_ble5() then
    start_ble5()
  else
    start_legacy()
  end
end
