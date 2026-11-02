-- Two ELM327 BLE advertisement shapes share one UART:
--   name OBDII, incomplete 16-bit UUID 4353 (CEVA). FFF0 is not in the ad.
--   name OBDII or "OBD BLE", complete 16-bit UUID FFF0 (66:1E modules).

local ENTRY_ID = "elm327_obdii_ble"
local PROTOCOL = "elm327_obdii_ble"

local function compact_uuid(value)
  if type(value) ~= "string" then
    return ""
  end
  return (value:gsub("-", ""):gsub("%s+", ""):lower())
end

local function is_short(compact, short)
  return compact == short or compact == "0000" .. short .. "00001000800000805f9b34fb"
end

local function list_has(list, short)
  if type(list) ~= "table" then
    return false
  end
  for _, value in pairs(list) do
    if is_short(compact_uuid(value), short) then
      return true
    end
  end
  return false
end

local function payload_has(raw, short)
  raw = hex.norm(raw or "")
  if raw == "" then
    return false
  end
  for _, typ in ipairs({ 0x02, 0x03 }) do
    local rows = adv.find(raw, typ)
    for i = 1, #rows do
      local h = hex.norm(rows[i])
      local p = 1
      while p + 3 <= #h do
        local uuid = h:sub(p + 2, p + 3) .. h:sub(p, p + 1)
        if uuid == short then
          return true
        end
        p = p + 4
      end
    end
  end
  return false
end

local function has_service(input, short)
  if adv.has_uuid(input, short) then
    return true
  end
  local first = input.first_service_uuid_16
  if type(first) == "string" and first:lower() == short then
    return true
  end
  if list_has(input.service_uuids_16, short) or list_has(input.service_uuids, short) then
    return true
  end
  return payload_has(input.raw_adv_hex, short) or payload_has(input.adv_data_hex_combined, short)
end

local function gap_name(name)
  name = ((name or ""):gsub("^%s+", ""))
  name = (name:gsub("%s+$", ""))
  name = (name:gsub("%s+", " "))
  local key = name:lower()
  if key == "obdii" then
    return "OBDII"
  end
  if key == "obd ble" then
    return "OBD BLE"
  end
  return nil
end

function parse(input)
  local name = gap_name(input.device_name or "")
  if not name then
    return {}, {}
  end

  local service = nil
  if has_service(input, "4353") then
    service = "4353"
  elseif has_service(input, "fff0") then
    service = "fff0"
  end
  if not service then
    return {}, {}
  end

  local hint = "Vehicle diagnostic BLE serial to OBDII port, no pairing. Connect and run Probe ELM327 to confirm."

  return {
    {
      id = ENTRY_ID,
      display_name = "ELM327 " .. name,
      hint = hint,
      attributes = {
        protocol = PROTOCOL,
        device_name = name,
        advertised_service = service,
        uart_service = "fff0",
        uart_notify = "fff1",
        uart_write = "fff2",
        pairing_required = "false",
      },
    },
  }, {
    device_type = "VEHICLE",
    custom_icon = "assets/obdii.svg",
    display_name = "ELM327 " .. name,
    display_info = "BLE UART · " .. service:upper(),
  }
end
