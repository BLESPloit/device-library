-- Advertise one 70mai tire-pressure receiver from vars.
-- Flags and the name are the legacy advertising PDU.
-- Manufacturer data (company 0x0059) is the scan response.
-- on_startup replaces the static profile in peripheral/adv.json.

local ADV_PROFILE_ID = "main"
local GFX_ICON = "icon"
local COLOR_ADVERTISING = 0xea4f16
local COLOR_CONNECTED = 0x808080

local WHEEL_ORDER = { "lf", "rf", "rr", "lr" }
local WHEEL_POSITION = { lf = 1, rf = 2, rr = 3, lr = 4 }

local function on(v)
  return v == true or v == 1 or v == "true"
end

local function show_icon(connected)
  if type(gfx_show) ~= "function" then
    return
  end
  gfx_show(GFX_ICON)
  if type(gfx_set_color) == "function" then
    gfx_set_color(GFX_ICON, connected and COLOR_CONNECTED or COLOR_ADVERTISING)
  end
end

local function ad(type_byte, value_hex)
  return hex.u8(1 + hex.len(value_hex)) .. hex.u8(type_byte) .. value_hex
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

local function wheel_bytes(v, key)
  local pressure = clamp(math.floor(tonumber(v[key .. "_pressure"]) or 0), 0, 255)
  local temperature = clamp(math.floor(tonumber(v[key .. "_temperature"]) or 0), -128, 127)
  local mode = clamp(math.floor(tonumber(v[key .. "_mode"]) or 0), 0, 15)
  local position = math.floor(tonumber(v[key .. "_position"]) or WHEEL_POSITION[key] or 0)
  position = clamp(position, 0, 7)
  local status = mode * 16
  if on(v[key .. "_status"]) then
    status = status + 1
  end
  if on(v[key .. "_fault"]) then
    status = status + 2
  end
  if on(v[key .. "_sensor_battery"]) then
    status = status + 4
  end
  if on(v[key .. "_invalid"]) then
    status = status + 8
  end
  local alarm = position
  if on(v[key .. "_hp"]) then
    alarm = alarm + 8
  end
  if on(v[key .. "_lp"]) then
    alarm = alarm + 16
  end
  if on(v[key .. "_ht"]) then
    alarm = alarm + 32
  end
  if on(v[key .. "_lt"]) then
    alarm = alarm + 64
  end
  if on(v[key .. "_leak"]) then
    alarm = alarm + 128
  end
  return hex.u8(pressure) .. hex.u8(temperature) .. hex.u8(status) .. hex.u8(alarm)
end

local function name_suffix(addr)
  local h = hex.norm((addr:gsub("[:%s%-]", "")))
  if hex.len(h) ~= 6 then
    return nil
  end
  return h:sub(9, 12)
end

local function build_adv(v, addr)
  local model = v.model
  if type(model) ~= "string" or not model:match("^t0[12]$") then
    return nil, "vars.model must be t01 or t02"
  end
  local suffix = name_suffix(addr)
  local mac_hex = mac.reverse_octets(addr)
  if not suffix or mac_hex == "" then
    return nil, "profile address must be 6 octets"
  end
  local name = "70mai_" .. model .. "_" .. suffix
  if #name > 26 then
    return nil, "advertised name is longer than a legacy PDU allows"
  end

  local body = mac_hex
  for i = 1, #WHEEL_ORDER do
    body = body .. wheel_bytes(v, WHEEL_ORDER[i])
  end

  local battery = clamp(math.floor(tonumber(v.battery) or 0), 0, 255)
  local charger = clamp(math.floor(tonumber(v.charger) or 0), 0, 3)
  local nibble = charger * 4
  if on(v.cf) then
    nibble = nibble + 1
  end
  if on(v.cr) then
    nibble = nibble + 2
  end
  local connected = on(v.connected) and 1 or 0
  body = body .. hex.u8(battery) .. hex.u8(nibble * 16) .. hex.u8(connected)

  local adv = ad(0x01, "05") .. ad(0x09, hex.from_ascii(name))
  local scan_rsp = ad(0xFF, "5900" .. body)
  return adv, scan_rsp
end

function on_startup()
  local connected = type(vars) == "table" and on(vars.connected)
  show_icon(connected)
  if type(vars) ~= "table" then
    print("70mai tire: vars missing, using peripheral/adv.json")
    return
  end
  if type(get_adv_bd_addr) ~= "function" or type(adv_set_data) ~= "function" then
    print("70mai tire: get_adv_bd_addr unavailable, using peripheral/adv.json")
    return
  end
  local addr, addr_err = get_adv_bd_addr(ADV_PROFILE_ID)
  if type(addr) ~= "string" or addr == "" then
    print("70mai tire: get_adv_bd_addr: " .. tostring(addr_err))
    return
  end
  local adv, scan_rsp_or_err = build_adv(vars, addr)
  if not adv then
    print("70mai tire: " .. tostring(scan_rsp_or_err))
    return
  end
  local ok, err = adv_set_data(ADV_PROFILE_ID, adv, scan_rsp_or_err)
  if not ok then
    print("70mai tire: adv_set_data: " .. tostring(err))
    return
  end
  print("70mai tire: advertising " .. adv .. scan_rsp_or_err)
end
