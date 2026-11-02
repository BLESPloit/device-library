-- Mijia Reader sensor family on service data UUID 0xFE95.
-- V1 MJ_HT_V1: one measurement object per advertisement (fixed offsets the app uses).
-- V2 LYWSD03MMC, V3 LYWSD02, V4 MHO-C401: identity only; readings are on GATT.

local ENTRY_ID = "mijia_thermometer"
local PROTOCOL = "mijia_thermometer"

local FC_ENCRYPTED = 0x08
local FC_MAC = 0x10
local FC_CAPABILITY = 0x20
local FC_OBJECT = 0x40
local CAP_EXTRA = 0x20

local OBJ_TEMP = 0x1004
local OBJ_HUMIDITY = 0x1006
local OBJ_BATTERY = 0x100A
local OBJ_TEMP_HUMIDITY = 0x100D

local MODELS = {
  MJ_HT_V1 = { version = "v1", connectable = "false", product = 0x01AA },
  LYWSD03MMC = { version = "v2", connectable = "true", product = 0x055B },
  LYWSD02 = { version = "v3", connectable = "true", product = 0x045B },
  ["MHO-C401"] = { version = "v4", connectable = "true", product = 0x0387 },
}

local function norm_hex(h)
  if type(h) ~= "string" then
    return ""
  end
  return hex.norm(h)
end

local function s16(n)
  if n >= 32768 then
    return n - 65536
  end
  return n
end

local function uuid16_from_key(key)
  if type(key) ~= "string" then
    return nil
  end
  local n = key:gsub("-", ""):lower()
  if #n >= 8 and n:sub(1, 4) == "0000" then
    return n:sub(5, 8)
  end
  if #n == 4 then
    return n
  end
  return nil
end

local function payload_from_service_data(service_data)
  if type(service_data) ~= "table" then
    return nil
  end
  for key, value in pairs(service_data) do
    if uuid16_from_key(tostring(key)) == "fe95" and type(value) == "string" then
      local h = norm_hex(value)
      if h:sub(1, 4) == "95fe" then
        h = h:sub(5)
      end
      if h ~= "" then
        return h
      end
    end
  end
  return nil
end

local function payload_from_adv(input)
  local raw = input.raw_adv_hex or input.adv_data_hex_combined or ""
  local found = adv.find(raw, 0x16)
  for i = 1, #found do
    local h = norm_hex(found[i])
    if h:sub(1, 4) == "95fe" then
      return h:sub(5)
    end
  end
  return nil
end

local function flag(n, mask)
  if bits.band(n, mask) ~= 0 then
    return "true"
  end
  return "false"
end

-- Mijia Reader reads the object id at byte offset 11 and does not walk frame-control bits.
local function parse_v1_object(data)
  if hex.len(data) < 13 then
    return nil
  end
  local obj = bits.le16(data, 12)
  local out = { object_type = string.format("%04x", obj) }
  if obj == OBJ_TEMP_HUMIDITY and hex.len(data) >= 18 then
    out.temperature_c = s16(bits.le16(data, 15)) / 10
    out.humidity_percent = s16(bits.le16(data, 17)) / 10
  elseif obj == OBJ_TEMP then
    out.temperature_c = s16(bits.le16(data, hex.len(data) - 1)) / 10
  elseif obj == OBJ_HUMIDITY then
    out.humidity_percent = s16(bits.le16(data, hex.len(data) - 1)) / 10
  elseif obj == OBJ_BATTERY and hex.len(data) >= 15 then
    out.battery_percent = hex.byte(data, 15)
  end
  return out
end

local function format_tenths(n)
  return string.format("%.1f", n)
end

function parse(input)
  local name = input.device_name or ""
  local info = MODELS[name]
  if not info then
    return {}, {}
  end

  local data = payload_from_service_data(input.service_data) or payload_from_adv(input)
  if not data or hex.len(data) < 5 then
    return {}, {}
  end

  local frame = bits.le16(data, 1)
  local product = bits.le16(data, 3)
  local counter = hex.byte(data, 5)
  local encrypted = bits.band(frame, FC_ENCRYPTED) ~= 0
  local has_mac = bits.band(frame, FC_MAC) ~= 0
  local has_capability = bits.band(frame, FC_CAPABILITY) ~= 0

  local adv_bdaddr = ""
  if hex.len(data) >= 11 and (info.version == "v1" or has_mac) then
    adv_bdaddr = mac.from_reversed(hex.slice(data, 6, 6))
  end

  local capability = ""
  local capability_data = ""
  if info.version ~= "v1" and has_mac and hex.len(data) >= 11 then
    local cursor = 12
    if has_capability and hex.len(data) >= cursor then
      local cap = hex.byte(data, cursor)
      capability = string.format("%02x", cap)
      cursor = cursor + 1
      if bits.band(cap, CAP_EXTRA) ~= 0 and hex.len(data) >= cursor + 1 then
        capability_data = hex.slice(data, cursor, 2)
      end
    end
  end

  local measurement = nil
  if info.version == "v1" then
    measurement = parse_v1_object(data)
  end
  local has_measurement = measurement and (
    measurement.temperature_c ~= nil
    or measurement.humidity_percent ~= nil
    or measurement.battery_percent ~= nil
  )

  local parts = {}
  local hint = "Advertisement has identity only. Connect and run Read sensors."
  if info.version == "v1" then
    hint = "V1 puts one measurement object in the advertisement. It does not connect."
    if has_measurement then
      if measurement.temperature_c ~= nil then
        parts[#parts + 1] = format_tenths(measurement.temperature_c) .. "°C"
      end
      if measurement.humidity_percent ~= nil then
        parts[#parts + 1] = format_tenths(measurement.humidity_percent) .. "% RH"
      end
      if measurement.battery_percent ~= nil then
        parts[#parts + 1] = string.format("battery %d%%", measurement.battery_percent)
      end
    else
      hint = "V1 packet has no temperature, humidity, or battery object."
    end
  elseif encrypted then
    hint = "Bound to Mi Home, advertisement data encrypted with the bind key. Connect and run Read sensors (not encrypted)."
  end

  if product ~= info.product then
    hint = hint .. " Product id " .. string.format("%04x", product)
      .. " is not the usual " .. string.format("%04x", info.product) .. " for this model."
  end

  local display_info = "Mi Sensor"
  if #parts > 0 then
    display_info = table.concat(parts, " · ")
  end

  local attributes = {
    protocol = PROTOCOL,
    version = info.version,
    model = name,
    device_name = name,
    connectable = info.connectable,
    product_id = string.format("%04x", product),
    product_id_expected = string.format("%04x", info.product),
    product_id_match = (product == info.product) and "true" or "false",
    frame_control = string.format("%04x", frame),
    frame_counter = string.format("%02x", counter),
    encrypted = encrypted and "true" or "false",
    mi_home_bound = encrypted and "true" or "false",
    has_mac = flag(frame, FC_MAC),
    has_capability = flag(frame, FC_CAPABILITY),
    has_object = flag(frame, FC_OBJECT),
    capability = capability,
    capability_data = capability_data,
    adv_bdaddr = adv_bdaddr,
    measurements_in_adv = has_measurement and "true" or "false",
  }
  if measurement then
    attributes.object_type = measurement.object_type or ""
    if measurement.temperature_c ~= nil then
      attributes.temperature_c = format_tenths(measurement.temperature_c)
    end
    if measurement.humidity_percent ~= nil then
      attributes.humidity_percent = format_tenths(measurement.humidity_percent)
    end
    if measurement.battery_percent ~= nil then
      attributes.battery_percent = tostring(measurement.battery_percent)
    end
  end

  return {
    {
      id = ENTRY_ID,
      display_name = "Xiaomi " .. name,
      hint = hint,
      attributes = attributes,
    },
  }, {
    device_type = "SMART_HOME",
    custom_icon = "assets/thermometer.svg",
    display_info = display_info,
  }
end
