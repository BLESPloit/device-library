-- Microsoft Nearby Advertising Beacon fingerprint script.
-- Input: table with manufacturer_data[company_id] = hex string of payload.
-- https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-cdp/77b446d0-8cea-4821-ad21-fabdf4d9a569
-- Microsoft (0x0006 = 6) payload (24 bytes):
--   Byte 0  : Scenario_Type (0x01 = Bluetooth)
--   Byte 1  : Version_and_Device_Type (high 3 bits = version, low 5 bits = device type)
--   Byte 2  : Version_and_Flags (high 3 bits = version, low 5 bits = share flags)
--   Byte 3  : Flags_and_Device_Status (bit 5 = BT addr as ID, bits 3-0 = ExtendedDeviceStatus)
--   Bytes 4-7  : Salt (4 bytes)
--   Bytes 8-26 : Device_Hash (19 bytes)
-- Returns array of fingerprint entries: { id, display_name, attributes = { ... } }.

local DEVICE_TYPES = {
  [1]  = "Xbox One",      [6]  = "Apple iPhone",  [7]  = "Apple iPad",
  [8]  = "Android",       [9]  = "Windows Desktop", [11] = "Windows Phone",
  [12] = "Linux",         [13] = "Windows IoT",   [14] = "Surface Hub",
  [15] = "Windows Laptop",[16] = "Windows Tablet"
}

local EXT_STATUS_FLAGS = {
  [0x01] = "RemoteSessionsHosted",
  [0x02] = "RemoteSessionsNotHosted",
  [0x04] = "NearShareAuthPolicySameUser",
  [0x08] = "NearShareAuthPolicyPermissive"
}

function parse(input)
  local entries = {}
  local mfg = input.manufacturer_data
  if not mfg then return entries end
  -- Company ID 6 = Microsoft (0x0006)
  local data = mfg["6"]
  if not data or type(data) ~= "string" then return entries end
  data = data:gsub("%s+", ""):lower()
  -- 24 bytes = 48 hex chars minimum
  if #data < 48 then return entries end

  local scenario_type       = tonumber(data:sub(1,  2),  16)
  local ver_dev             = tonumber(data:sub(3,  4),  16)
  local ver_flags           = tonumber(data:sub(5,  6),  16)
  local flags_status        = tonumber(data:sub(7,  8),  16)
  local salt                = data:sub(9,  16)   -- 4 bytes
  local device_hash         = data:sub(17, 54)   -- 19 bytes

  local device_type_id      = ver_dev % 32
  local share_flags         = ver_flags % 32
  local bt_addr_as_id       = math.floor(flags_status / 32) % 2 == 1
  local ext_status          = flags_status % 16

  local device_type = DEVICE_TYPES[device_type_id] or ("Unknown(" .. device_type_id .. ")")

  local ext_parts = {}
  for mask, name in pairs(EXT_STATUS_FLAGS) do
    if ext_status % (mask * 2) >= mask then
      ext_parts[#ext_parts + 1] = name
    end
  end
  local ext_status_str = #ext_parts > 0 and table.concat(ext_parts, "|") or "None"

  entries[1] = {
    id = "ms_nearby",
    display_name = "Microsoft Nearby Beacon",
    attributes = {
      scenario_type           = scenario_type,
      ms_device_type          = device_type,
      nearby_share_everyone   = (share_flags == 0x01),
      bt_address_as_device_id = bt_addr_as_id,
      extended_status         = ext_status_str,
      salt                    = salt,
      device_hash             = device_hash
    }
  }
  local ui = {
    device_type = "NEARBY",
    custom_icon = "assets/windows_logo_blue.svg",
    display_name = device_type,
  }
  return entries, ui
end
