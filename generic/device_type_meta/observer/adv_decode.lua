-- device_type_meta observer: infer scan-list device_type from GAP data only (Appearance, Class of Device, 16-bit service UUIDs).

local function appearance_to_device_type(category)
  local map = {
    [0x01] = "PHONE", [0x02] = "COMPUTER", [0x03] = "WATCH_WEARABLE", [0x04] = "TV_DISPLAY",
    [0x05] = "TV_DISPLAY", [0x06] = "LIGHT_SMART_HOME", [0x07] = "TV_DISPLAY", [0x08] = "BEACON",
    [0x09] = "BEACON", [0x0A] = "AUDIO", [0x0B] = "SENSOR_ENVIRONMENTAL", [0x0C] = "HEALTH",
    [0x0D] = "HEART_RATE_FITNESS", [0x0E] = "HEALTH", [0x0F] = "HID", [0x10] = "HEALTH",
    [0x11] = "HEART_RATE_FITNESS", [0x12] = "HEART_RATE_FITNESS", [0x13] = "LIGHT_SMART_HOME",
    [0x14] = "NETWORK", [0x15] = "SENSOR_ENVIRONMENTAL", [0x16] = "LIGHT_SMART_HOME",
    [0x17] = "LIGHT_SMART_HOME", [0x18] = "LIGHT_SMART_HOME", [0x19] = "LIGHT_SMART_HOME",
    [0x1A] = "LIGHT_SMART_HOME", [0x1B] = "LIGHT_SMART_HOME", [0x1C] = "SECURITY"
  }
  return map[category]
end

local function cod_major_to_device_type(major)
  local map = {
    [1] = "COMPUTER", [2] = "PHONE", [3] = "NETWORK", [4] = "AUDIO", [5] = "HID",
    [6] = "TV_DISPLAY", [7] = "WATCH_WEARABLE", [8] = "TOYS", [9] = "HEALTH"
  }
  return map[major]
end

local function service_uuid_to_device_type(uuid16)
  local map = {
    [0x180D] = "HEART_RATE_FITNESS", [0x1816] = "HEART_RATE_FITNESS", [0x1818] = "HEART_RATE_FITNESS",
    [0x1814] = "HEART_RATE_FITNESS", [0x1826] = "HEART_RATE_FITNESS", [0x1810] = "HEALTH",
    [0x1808] = "HEALTH", [0x1809] = "HEALTH", [0x1822] = "HEALTH", [0x181F] = "MEDICAL",
    [0x183A] = "MEDICAL", [0x1812] = "HID", [0x181A] = "SENSOR_ENVIRONMENTAL", [0x1815] = "LIGHT_SMART_HOME",
    [0x180F] = "GENERIC"
  }
  return map[uuid16]
end

-- GAP Appearance: category is bits 15-10 (Bluetooth Assigned Numbers), not the full high byte.
local function appearance_category_bits(appearance)
  return math.floor(appearance / 1024) % 64
end

local function parse_uuid16_cell(cell)
  if cell == nil then return nil end
  if type(cell) == "number" then
    local n = math.floor(cell)
    if n >= 1 and n <= 0xFEFF then return n end
    return nil
  end
  if type(cell) == "string" then
    local n = tonumber(cell, 16)
    if n and n >= 1 and n <= 0xFEFF then return n end
    return nil
  end
  if type(cell) == "userdata" and cell.tonumber then
    local n = cell:tonumber()
    if n then
      n = math.floor(n)
      if n >= 1 and n <= 0xFEFF then return n end
    end
  end
  return nil
end

-- Scan full 16-bit UUID list: any 0x1812 => HID; else first non-GENERIC mapping in AD order.
local function infer_device_type_from_service_uuids(input, to_num)
  local hid = false
  local first_mapped = nil
  local t = input.service_uuids_16
  if t then
    local i = 1
    while true do
      local cell = t[i]
      if cell == nil then break end
      local u16 = parse_uuid16_cell(cell)
      if u16 then
        if u16 == 0x1812 then hid = true end
        local dt = service_uuid_to_device_type(u16)
        if dt and dt ~= "GENERIC" and first_mapped == nil then
          first_mapped = dt
        end
      end
      i = i + 1
    end
  end
  local first_only = to_num(input.first_service_uuid_16)
  if first_only and first_only >= 1 and first_only <= 0xFEFF then
    if first_only == 0x1812 then hid = true end
    if first_mapped == nil then
      local dt = service_uuid_to_device_type(first_only)
      if dt and dt ~= "GENERIC" then first_mapped = dt end
    end
  end
  if hid then return "HID" end
  return first_mapped
end

function parse(input)
  local entries = {}
  local function to_num(v)
    if v == nil then return nil end
    if type(v) == "number" then return v end
    if type(v) == "userdata" and v.tonumber then return v:tonumber() end
    return nil
  end
  local appearance = to_num(input.appearance) or -1
  local cod_major = to_num(input.cod_major) or -1

  local device_type = "GENERIC"
  if appearance >= 0 then
    local category = appearance_category_bits(appearance)
    device_type = appearance_to_device_type(category) or device_type
  end
  if device_type == "GENERIC" and cod_major >= 0 then
    device_type = cod_major_to_device_type(cod_major) or device_type
  end

  local from_services = infer_device_type_from_service_uuids(input, to_num)
  if from_services == "HID" then
    device_type = "HID"
  elseif device_type == "GENERIC" and from_services then
    device_type = from_services
  end

  local ui = {
    device_type = device_type,
  }
  return entries, ui
end
