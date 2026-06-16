-- Samsung vendor observer: always show Samsung icon for matched scans.
-- When manufacturer payload starts with 0x42, dispatch by family byte:
--   0x04 VD (TV/AV/monitor) — power state via custom_icon_tint
--   0x0C Connect v3 (appliances) — mnId/setupId/MAC/model metadata
--   0x1F short rotation profile — best-effort metadata

local COMPANY_ID = "0075"
local ENTRY_ID = "samsung"
local ICON = "assets/samsung.svg"

local TINT_ON = "#30D158"
local TINT_STANDBY = "#FF9F0A"
local TINT_OFF = "#9E9E9E"
local DEFAULT_NAME = "Samsung"

local VD_STATE = {
  [0x01] = { state = "on", label = "On", tint = TINT_ON },
  [0x40] = { state = "standby", label = "Standby", tint = TINT_STANDBY },
  [0x80] = { state = "off", label = "Off", tint = TINT_OFF },
}

local VD_CLASS = {
  [0x01] = { device_class = "tv", device_type = "TV" },
  [0x03] = { device_class = "av", device_type = "AUDIO" },
  [0x05] = { device_class = "refrigerator", device_type = "APPLIANCE" },
  [0x06] = { device_class = "monitor", device_type = "MONITOR" },
}

local function hex_to_bytes(hex)
  if not hex or type(hex) ~= "string" then
    return nil
  end
  hex = hex:gsub("%s+", ""):lower()
  if #hex < 2 or (#hex % 2) ~= 0 then
    return nil
  end
  local bytes = {}
  for i = 1, #hex, 2 do
    local b = tonumber(hex:sub(i, i + 1), 16)
    if b == nil then
      return nil
    end
    bytes[#bytes + 1] = b
  end
  return bytes
end

local function bytes_to_hex(bytes, start_idx, count)
  if not bytes then
    return nil
  end
  start_idx = start_idx or 1
  local end_idx = count and (start_idx + count - 1) or #bytes
  local parts = {}
  for i = start_idx, end_idx do
    parts[#parts + 1] = string.format("%02x", bytes[i] or 0)
  end
  return table.concat(parts)
end

local function format_mac(hex6)
  if not hex6 or #hex6 ~= 12 then
    return nil
  end
  return string.upper(string.format(
    "%s:%s:%s:%s:%s:%s",
    hex6:sub(1, 2),
    hex6:sub(3, 4),
    hex6:sub(5, 6),
    hex6:sub(7, 8),
    hex6:sub(9, 10),
    hex6:sub(11, 12)
  ))
end

local function read_ascii(bytes, start_idx, len)
  if not bytes or start_idx + len - 1 > #bytes then
    return nil
  end
  local chars = {}
  for i = start_idx, start_idx + len - 1 do
    local b = bytes[i]
    if b < 0x20 or b > 0x7E then
      return nil
    end
    chars[#chars + 1] = string.char(b)
  end
  return table.concat(chars)
end

local function get_mfg_bytes(input)
  local mfg = input and input.manufacturer_data
  if not mfg then
    return nil
  end
  return hex_to_bytes(mfg[COMPANY_ID])
end

local function find_service_data(service_data, uuid16)
  if not service_data or type(service_data) ~= "table" or not uuid16 then
    return nil
  end
  local target = uuid16:lower()
  for key, value in pairs(service_data) do
    if type(key) == "string" and key:lower() == target and type(value) == "string" then
      return value:gsub("%s+", ""):lower()
    end
  end
  return nil
end

local function parse_service_data_0b04(input)
  local hex = find_service_data(input and input.service_data, "0b04")
  if not hex or #hex < 8 then
    return nil
  end
  if hex:sub(1, 4) == "7500" then
    hex = hex:sub(5)
  end
  if #hex >= 8 then
    return read_ascii(hex_to_bytes(hex), 1, 4) or hex:sub(1, 8)
  end
  return nil
end

local function has_device_name(input)
  local name = input and input.device_name
  return type(name) == "string" and name ~= ""
end

local function entry_display_name(input)
  if has_device_name(input) then
    return input.device_name
  end
  return DEFAULT_NAME
end

-- Only set ui.display_name when the advert has no name: leave scan-row name to the app
-- (named devices are shown in blue from the scanned AD, not from script overlay).
local function set_ui_display_name(ui, input)
  if not has_device_name(input) then
    ui.display_name = DEFAULT_NAME
  end
end

local function append_parsed(parts, key, value)
  if value and value ~= "" then
    parts[#parts + 1] = key .. "=" .. tostring(value)
  end
end

local function extract_connect_mac(bytes, after_idx)
  for i = after_idx, #bytes - 5 do
    if bytes[i] == 0x06 and bytes[i + 1] == 0x01 and bytes[i + 2] == 0x04 then
      return format_mac(bytes_to_hex(bytes, i + 3, 6))
    end
  end
  return nil
end

local function decode_vd(bytes, input)
  if #bytes < 4 or bytes[1] ~= 0x42 or bytes[2] ~= 0x04 then
    return nil
  end

  local type_nibble = bits.band(bytes[3], 0x0F)
  local state_byte = bytes[4]
  local class_info = VD_CLASS[type_nibble] or {
    device_class = "unknown",
    device_type = "TV",
  }

  if state_byte == 0x20 then
    local parsed = {
      "family=vd",
      "adv_format=extension",
      "device_class=" .. class_info.device_class,
      "state_byte=0x20",
    }
    return {
      id = ENTRY_ID,
      display_name = entry_display_name(input),
      attributes = {
        protocol = "samsung",
        family = "vd",
        adv_format = "extension",
        device_class = class_info.device_class,
        state = "extension",
        state_label = "Extension",
        state_byte = "0x20",
        parsed_protocol = table.concat(parsed, " "),
      },
    }, {
      custom_icon = ICON,
    }
  end

  local known = VD_STATE[state_byte]
  local state_str = known and known.state or string.format("0x%02X", state_byte)
  local state_label = known and known.label or state_str
  local tint = known and known.tint or nil

  local ble_mac = nil
  if state_byte == 0x01 or state_byte == 0x40 or state_byte == 0x80 then
    local mac_offset = (type_nibble == 0x03) and 10 or 6
    if #bytes >= mac_offset + 5 then
      ble_mac = format_mac(bytes_to_hex(bytes, mac_offset, 6))
    end
  end

  local parsed = {}
  append_parsed(parsed, "family", "vd")
  append_parsed(parsed, "adv_format", "power")
  append_parsed(parsed, "device_class", class_info.device_class)
  append_parsed(parsed, "state", state_str)
  append_parsed(parsed, "state_byte", string.format("0x%02X", state_byte))
  append_parsed(parsed, "ble_mac", ble_mac)

  local attrs = {
    protocol = "samsung",
    family = "vd",
    adv_format = "power",
    device_class = class_info.device_class,
    state = state_str,
    state_label = state_label,
    state_byte = string.format("0x%02X", state_byte),
    parsed_protocol = table.concat(parsed, " "),
  }
  if ble_mac then
    attrs.ble_mac = ble_mac
  end

  local ui = {
    custom_icon = ICON,
    device_type = class_info.device_type,
    display_info = state_label,
  }
  set_ui_display_name(ui, input)
  if tint then
    ui.custom_icon_tint = tint
  end

  return {
    id = ENTRY_ID,
    display_name = entry_display_name(input),
    attributes = attrs,
  }, ui
end

local function decode_connect(bytes, input)
  if #bytes < 6 or bytes[1] ~= 0x42 or bytes[2] ~= 0x0C then
    return nil
  end

  local version_byte = bytes[3]
  if bits.band(version_byte, 0x0F) ~= 0x03 then
    return nil
  end

  local connectible = bytes[4]
  local presence = -1
  local idx = 5
  if bits.band(version_byte, 0x80) ~= 0 then
    if #bytes < idx then
      return nil
    end
    presence = bytes[idx]
    idx = idx + 1
  end

  local mn_id, setup_id
  if presence ~= -1 and bits.band(presence, 0x01) ~= 0 then
    mn_id = read_ascii(bytes, idx, 4)
    setup_id = read_ascii(bytes, idx + 4, 3)
    idx = idx + 7
  end

  local ble_mac = extract_connect_mac(bytes, idx)
  local model_code = parse_service_data_0b04(input)

  local parsed = {}
  append_parsed(parsed, "family", "connect")
  append_parsed(parsed, "mn_id", mn_id)
  append_parsed(parsed, "setup_id", setup_id)
  append_parsed(parsed, "model_code", model_code)
  append_parsed(parsed, "ble_mac", ble_mac)
  append_parsed(parsed, "connectible", string.format("0x%02X", connectible))

  local display_info = setup_id or model_code or mn_id or "Connect"
  local attrs = {
    protocol = "samsung",
    family = "connect",
    device_class = "appliance",
    parsed_protocol = table.concat(parsed, " "),
  }
  if mn_id then attrs.mn_id = mn_id end
  if setup_id then attrs.setup_id = setup_id end
  if model_code then attrs.model_code = model_code end
  if ble_mac then attrs.ble_mac = ble_mac end
  attrs.connectible = connectible

  local ui = {
    custom_icon = ICON,
    device_type = "APPLIANCE",
    display_info = display_info,
  }
  set_ui_display_name(ui, input)

  return {
    id = ENTRY_ID,
    display_name = entry_display_name(input),
    attributes = attrs,
  }, ui
end

local function decode_short(bytes, input)
  if #bytes < 4 or bytes[1] ~= 0x42 or bytes[2] ~= 0x1F then
    return nil
  end

  local status_hex = bytes_to_hex(bytes, 3, math.min(8, #bytes - 2))
  local parsed = { "family=short", "payload=" .. status_hex }

  local ui = {
    custom_icon = ICON,
    device_type = "APPLIANCE",
    display_info = "Short adv",
  }
  set_ui_display_name(ui, input)

  return {
    id = ENTRY_ID,
    display_name = entry_display_name(input),
    attributes = {
      protocol = "samsung",
      family = "short",
      device_class = "appliance",
      state_label = "short_adv",
      parsed_protocol = table.concat(parsed, " "),
    },
  }, ui
end

local function decode_payload(bytes, input)
  if not bytes or #bytes < 2 or bytes[1] ~= 0x42 then
    return nil
  end

  local family = bytes[2]
  if family == 0x04 then
    return decode_vd(bytes, input)
  end
  if family == 0x0C then
    return decode_connect(bytes, input)
  end
  if family == 0x1F then
    return decode_short(bytes, input)
  end
  return nil
end

function parse(input)
  local entries = {}
  local ui = {
    custom_icon = ICON,
  }
  set_ui_display_name(ui, input)

  local bytes = get_mfg_bytes(input)
  if bytes then
    local entry, decoded_ui = decode_payload(bytes, input)
    if entry then
      entries[1] = entry
      for key, value in pairs(decoded_ui) do
        ui[key] = value
      end
    end
  end

  return entries, ui
end
