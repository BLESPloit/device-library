-- Microsoft Nearby Advertising Beacon fingerprint script.
-- Input: manufacturer_data["0006"] = hex payload (4-digit SIG company id keys).
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
  local data = mfg["0006"]
  if not data or type(data) ~= "string" then return entries end
  data = hex.norm(data)
  if hex.len(data) < 24 then return entries end

  local scenario_type = hex.byte(data, 1)
  local ver_dev = hex.byte(data, 2)
  local ver_flags = hex.byte(data, 3)
  local flags_status = hex.byte(data, 4)
  local salt = hex.slice(data, 5, 4)
  local device_hash = hex.slice(data, 9, 19)

  local device_type_id = bits.band(ver_dev, 0x1F)
  local share_flags = bits.band(ver_flags, 0x1F)
  local bt_addr_as_id = bits.band(flags_status, 0x20) ~= 0
  local ext_status = bits.band(flags_status, 0x0F)

  local device_type = DEVICE_TYPES[device_type_id] or ("Unknown(" .. device_type_id .. ")")

  local ext_parts = {}
  for mask, name in pairs(EXT_STATUS_FLAGS) do
    if bits.band(ext_status, mask) ~= 0 then
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
