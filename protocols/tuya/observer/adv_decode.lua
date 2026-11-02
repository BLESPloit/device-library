-- Tuya BLE observer: company 0x07D0 manufacturer data + 0xA201/0xFD50 service data.
-- Layout matches ThingClips qbpbpqp / DeviceBeaconParser. Bound → grey icon; unbound → Tuya red + app hint.

local ENTRY_ID = "tuya"
local PROTOCOL = "tuya"
local COMPANY_ID = "07D0"
local SVC_A201 = "a201"
local SVC_FD50 = "fd50"

local function norm_hex(h)
  if type(h) ~= "string" then
    return ""
  end
  return h:gsub("%s+", ""):gsub(":", ""):lower()
end

local function norm_uuid16(u)
  if type(u) ~= "string" then
    return ""
  end
  local n = u:gsub("-", ""):gsub("^0x", ""):lower()
  if #n >= 8 and n:sub(1, 4) == "0000" then
    n = n:sub(5, 8)
  end
  if #n > 4 then
    n = n:sub(-4)
  end
  return n
end

local function hex_byte(hex, i1)
  local p = (i1 - 1) * 2 + 1
  return tonumber(hex:sub(p, p + 1), 16)
end

local function hex_slice(hex, from_byte, to_byte)
  return hex:sub((from_byte - 1) * 2 + 1, to_byte * 2)
end

local function hex_to_ascii(hex)
  if not hex or #hex < 2 or (#hex % 2) ~= 0 then
    return ""
  end
  local chars = {}
  for i = 1, #hex, 2 do
    local b = tonumber(hex:sub(i, i + 1), 16)
    if not b then
      return ""
    end
    if b < 32 or b > 126 then
      return ""
    end
    chars[#chars + 1] = string.char(b)
  end
  return table.concat(chars)
end

local function bit_set(byte, bit)
  if not byte then
    return false
  end
  local v = 2 ^ bit
  return (byte % (v * 2)) >= v
end

local function has_uuid16(list, want)
  if type(list) ~= "table" then
    return false
  end
  want = norm_uuid16(want)
  for _, u in pairs(list) do
    if type(u) == "string" and norm_uuid16(u) == want then
      return true
    end
  end
  return false
end

local function mfg_payload(input)
  local mfg = input and input.manufacturer_data
  if type(mfg) ~= "table" then
    return ""
  end
  for key, value in pairs(mfg) do
    if type(key) == "string" and key:upper() == COMPANY_ID and type(value) == "string" then
      return norm_hex(value)
    end
  end
  return ""
end

local function find_service_data(service_data, uuid16)
  if type(service_data) ~= "table" then
    return nil
  end
  local want = norm_uuid16(uuid16)
  for key, value in pairs(service_data) do
    if type(key) == "string" and type(value) == "string" and norm_uuid16(key) == want then
      return norm_hex(value)
    end
  end
  return nil
end

-- Walk raw AD structure; return payload hex for type (without length/type bytes).
local function ad_payloads(raw, ad_type)
  local out = {}
  raw = norm_hex(raw)
  local pos = 1
  while pos <= #raw - 3 do
    local len = tonumber(raw:sub(pos, pos + 1), 16)
    if not len or len < 1 then
      break
    end
    local typ = tonumber(raw:sub(pos + 2, pos + 3), 16)
    local data_end = pos + 2 + len * 2
    local data = raw:sub(pos + 4, data_end)
    if typ == ad_type and data and #data >= 2 then
      out[#out + 1] = data
    end
    pos = pos + 2 + len * 2
  end
  return out
end

local function service_data_from_raw(raw, uuid16)
  local want = norm_uuid16(uuid16)
  for _, data in ipairs(ad_payloads(raw, 0x16)) do
    if #data >= 6 then
      -- 16-bit UUID is little-endian on air.
      local u = data:sub(3, 4) .. data:sub(1, 2)
      if u == want then
        return data:sub(5)
      end
    end
  end
  return nil
end

local function parse_id_blob(hex)
  if not hex or #hex < 2 then
    return nil
  end
  -- Android service_data is usually type+id (17 bytes). Some stacks prefix the UUID.
  if #hex >= 38 then
    local u = hex:sub(3, 4) .. hex:sub(1, 2)
    if u == SVC_A201 or u == SVC_FD50 then
      hex = hex:sub(5)
    end
  end
  local id_type = hex_byte(hex, 1)
  if not id_type then
    return nil
  end
  local rest = hex:sub(3)
  if #rest < 16 then
    return nil
  end
  -- 8-byte or 16-byte product id / uuid
  local id_hex
  if #rest >= 32 then
    id_hex = rest:sub(1, 32)
  else
    id_hex = rest:sub(1, 16)
  end
  local ascii = hex_to_ascii(id_hex)
  local is_product_key = (id_type == 1)
  return {
    id_type = id_type,
    is_product_key = is_product_key,
    id_hex = id_hex,
    id_ascii = ascii,
  }
end

local function radio_label(extra0, extra1, plug_play)
  extra0 = extra0 or 0
  extra1 = extra1 or 0
  local zigbee = bit_set(extra1, 0)
  local wifi = bit_set(extra1, 2)
  local wifi_5g = bit_set(extra1, 3)
  local cat1 = bit_set(extra1, 6)
  local ethernet = bit_set(extra0, 1)
  local parts = {}
  if zigbee then
    parts[#parts + 1] = "Zigbee"
  end
  if wifi then
    parts[#parts + 1] = wifi_5g and "Wi-Fi 5G" or "Wi-Fi"
  end
  if ethernet then
    parts[#parts + 1] = "Ethernet"
  end
  if cat1 then
    parts[#parts + 1] = "Cat.1"
  end
  if #parts == 0 then
    parts[1] = "BLE"
  else
    table.insert(parts, 1, "BLE")
  end
  if plug_play then
    parts[#parts + 1] = "plug&play"
  end
  return table.concat(parts, "+")
end

local function parse_mfg(hex)
  if not hex or #hex < 12 then
    return nil
  end
  local flags = hex_byte(hex, 1)
  local pv = hex_byte(hex, 2)
  local kind = hex_byte(hex, 3)
  local extra0 = hex_byte(hex, 4) or 0
  local extra1 = hex_byte(hex, 5) or 0
  if not flags or not pv then
    return nil
  end
  local enc_uuid = ""
  if #hex >= 44 then
    enc_uuid = hex_slice(hex, 7, 22)
  end
  return {
    flags = flags,
    protocol_version = pv,
    enc_type = kind or 0,
    extra0 = extra0,
    extra1 = extra1,
    bound = bit_set(flags, 7),
    share = bit_set(flags, 1),
    plug_play = bit_set(flags, 3),
    qr = bit_set(flags, 4),
    security_support = bit_set(flags, 5),
    security_enable = bit_set(flags, 6),
    encrypted_uuid_hex = enc_uuid,
  }
end

function parse(input)
  input = input or {}
  local raw = input.raw_adv_hex or input.adv_data_hex_combined or ""
  local mfg = mfg_payload(input)
  if mfg == "" then
    local ff = ad_payloads(raw, 0xFF)
    for _, data in ipairs(ff) do
      if #data >= 6 then
        local cid = data:sub(3, 4) .. data:sub(1, 2)
        if cid == "07d0" then
          mfg = data:sub(5)
          break
        end
      end
    end
  end

  local svc_hex = find_service_data(input.service_data, SVC_A201)
    or find_service_data(input.service_data, SVC_FD50)
    or service_data_from_raw(raw, SVC_A201)
    or service_data_from_raw(raw, SVC_FD50)

  local has_a201 = has_uuid16(input.service_uuids_16, SVC_A201)
    or has_uuid16(input.service_uuids, SVC_A201)
  local has_fd50 = has_uuid16(input.service_uuids_16, SVC_FD50)
    or has_uuid16(input.service_uuids, SVC_FD50)

  if mfg == "" and not svc_hex and not has_a201 and not has_fd50 then
    return {}, {}
  end

  -- Company 0x07D0 is also used on Tuya SIG Mesh; require BLE adv shape or A201/FD50.
  local m = parse_mfg(mfg)
  local ble_mfg = mfg ~= "" and #mfg >= 44 and m and m.protocol_version >= 2 and m.protocol_version <= 5
  if not ble_mfg and not svc_hex and not has_a201 and not has_fd50 then
    return {}, {}
  end

  local id = parse_id_blob(svc_hex)

  local bound = m and m.bound or false
  local pv = m and m.protocol_version or 0
  local radio = m and radio_label(m.extra0, m.extra1, m.plug_play) or "BLE"
  local name = input.device_name or ""

  local id_label = ""
  if id then
    if id.is_product_key then
      id_label = "key " .. id.id_hex:sub(1, 8)
    elseif id.id_ascii ~= "" then
      id_label = id.id_ascii
    else
      id_label = id.id_hex:sub(1, 8)
    end
  end

  local display_name = "Tuya"
  if id_label ~= "" then
    display_name = "Tuya · " .. id_label
  end

  local display_info_parts = {}
  display_info_parts[#display_info_parts + 1] = bound and "Bound" or "Unbound"
  if pv > 0 then
    display_info_parts[#display_info_parts + 1] = "v" .. tostring(pv)
  end
  display_info_parts[#display_info_parts + 1] = radio
  local display_info = table.concat(display_info_parts, " · ")

  local attrs = {
    protocol = PROTOCOL,
    device_name = name,
    bound = bound and "true" or "false",
    radio = radio,
  }
  if pv > 0 then
    attrs.adv_protocol_version = tostring(pv)
  end
  if m then
    attrs.flag_hex = string.format("%02X", m.flags)
    attrs.share = m.share and "true" or "false"
    attrs.plug_play = m.plug_play and "true" or "false"
    attrs.security_support = m.security_support and "true" or "false"
    attrs.security_enable = m.security_enable and "true" or "false"
    if m.encrypted_uuid_hex ~= "" then
      attrs.encrypted_uuid_hex = m.encrypted_uuid_hex
    end
    attrs.mfg_hex = mfg
  end
  if id then
    attrs.id_kind = id.is_product_key and "product_key" or "uuid"
    attrs.product_id_hex = id.id_hex
    if id.id_ascii ~= "" then
      attrs.uuid = id.id_ascii
    end
    if id.is_product_key then
      attrs.product_key_hex = id.id_hex
    end
  end
  if has_a201 then
    attrs.service_uuid_16 = "A201"
  elseif has_fd50 then
    attrs.service_uuid_16 = "FD50"
  end

  local entry = {
    id = ENTRY_ID,
    display_name = display_name,
    attributes = attrs,
  }
  if not bound then
    entry.hint = "Continue with the official Tuya app to check device details (product name, model, ...) and optionally bind it to your account to control it."
  end

  local ui = {
    device_type = "SMART_HOME",
    custom_icon = "assets/tuya.svg",
    display_name = display_name,
    display_info = display_info,
  }
  -- Monochrome T glyph: unpaired keeps SVG red (#ff4802); bound is grey.
  if bound then
    ui.custom_icon_tint = "#9E9E9E"
  end

  return { entry }, ui
end
