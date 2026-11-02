-- Advertise one 70mai dash cam from vars. Flags, name, and TX power are the
-- legacy advertising PDU. Manufacturer data (company 0x0909) is the scan response.
-- on_startup replaces the static profile in peripheral/adv.json.

local ADV_PROFILE_ID = "main"
local GFX_ICON = "icon"
local COLOR_UNREGISTERED = 0xea4f16
local COLOR_REGISTERED = 0x808080

local FC_CONNECTED = 0x01
local FC_REGISTERED = 0x02
local FC_ENCRYPTED = 0x10
local FC_MAC = 0x20
local FC_CAPABILITY = 0x40

local CAP_CONNECTABLE = 0x01
local CAP_CENTRAL = 0x02
local CAP_ENCRYPTABLE = 0x04
local CAP_BINDABLE = 0x08

local function on(v)
  return v == true or v == 1 or v == "true"
end

local function show_icon(registered)
  if type(gfx_show) ~= "function" then
    return
  end
  gfx_show(GFX_ICON)
  if type(gfx_set_color) == "function" then
    gfx_set_color(GFX_ICON, registered and COLOR_REGISTERED or COLOR_UNREGISTERED)
  end
end

local function ad(type_byte, value_hex)
  return hex.u8(1 + hex.len(value_hex)) .. hex.u8(type_byte) .. value_hex
end

local function build_adv(v)
  local model = v.model
  if type(model) ~= "string" or model == "" then
    return nil, "vars.model must be a non-empty string"
  end
  local name = "70mai_" .. model
  if type(v.name_suffix) == "string" and v.name_suffix ~= "" then
    name = name .. "_" .. v.name_suffix
  end
  if #name > 23 then
    return nil, "advertised name is longer than a legacy PDU allows"
  end

  local channel = math.floor(tonumber(v.device_channel) or 0)
  if channel < 0 or channel > 4294967295 then
    return nil, "vars.device_channel must fit in uint32"
  end

  local auth_mode = math.floor(tonumber(v.auth_mode) or 0)
  if auth_mode < 0 then
    auth_mode = 0
  elseif auth_mode > 3 then
    auth_mode = 3
  end

  local version = bits.band(math.floor(tonumber(v.frame_version) or 1), 0x0F)
  local fc = auth_mode * 4
  if on(v.connected) then
    fc = fc + FC_CONNECTED
  end
  if on(v.registered) then
    fc = fc + FC_REGISTERED
  end
  if on(v.encrypted) then
    fc = fc + FC_ENCRYPTED
  end

  local cap = nil
  if on(v.with_capability) then
    fc = fc + FC_CAPABILITY
    cap = 0
    if on(v.connectable) then
      cap = cap + CAP_CONNECTABLE
    end
    if on(v.centralable) then
      cap = cap + CAP_CENTRAL
    end
    if on(v.encryptable) then
      cap = cap + CAP_ENCRYPTABLE
    end
    if on(v.bindable) then
      cap = cap + CAP_BINDABLE
    end
  end

  local mac_hex = ""
  if on(v.with_mac) then
    fc = fc + FC_MAC
    mac_hex = mac.reverse_octets(v.bd_addr or "")
    if mac_hex == "" then
      return nil, "vars.bd_addr must be a 6-octet address"
    end
  end

  local body = hex.le32(channel) .. hex.u8(fc) .. hex.u8(version)
  if cap ~= nil then
    body = body .. hex.u8(cap)
  end
  body = body .. mac_hex

  local tx = math.floor(tonumber(v.tx_power) or 0)
  if tx < -128 then
    tx = -128
  elseif tx > 127 then
    tx = 127
  end

  local adv = ad(0x01, "04") .. ad(0x09, hex.from_ascii(name)) .. ad(0x0A, hex.u8(tx))
  local scan_rsp = ad(0xFF, "0909" .. body)
  return adv, scan_rsp
end

function on_startup()
  local registered = type(vars) == "table" and on(vars.registered)
  show_icon(registered)
  if type(vars) ~= "table" then
    print("70mai: vars missing, using peripheral/adv.json")
    return
  end
  local adv, scan_rsp_or_err = build_adv(vars)
  if not adv then
    print("70mai: " .. tostring(scan_rsp_or_err))
    return
  end
  local ok, err = adv_set_data(ADV_PROFILE_ID, adv, scan_rsp_or_err)
  if not ok then
    print("70mai: adv_set_data: " .. tostring(err))
    return
  end
  print("70mai: advertising " .. adv .. scan_rsp_or_err)
end
