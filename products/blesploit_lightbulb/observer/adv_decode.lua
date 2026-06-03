-- Parses 4-byte service data for SVC_LIGHTBULB (uuid from uuids.json): 1 byte on/off (00/01), 3 bytes RGB.
-- Sets device_type to SMART_HOME and returns parsed protocol for display.

-- Find service data value for a UUID key (key may vary in casing in service_data table).
local function find_service_data(service_data, uuid)
  if not service_data or type(service_data) ~= "table" or not uuid or type(uuid) ~= "string" then
    return nil
  end
  local target = uuid:lower()
  for key, value in pairs(service_data) do
    if type(key) == "string" and key:lower() == target then
      return value
    end
  end
  return nil
end

function parse(input)
  local entries = {}
  local svc = uuids and uuids.SVC_LIGHTBULB
  if type(svc) ~= "string" or svc == "" then
    return entries
  end

  local service_data = input.service_data
  local dataHex = find_service_data(service_data, svc)
  if not dataHex or type(dataHex) ~= "string" then return entries end
  dataHex = dataHex:gsub("%s+", ""):lower()
  if #dataHex < 8 then return entries end

  -- 4 bytes: [0] = on/off (00 or 01), [1..3] = R, G, B
  local byte0 = tonumber(dataHex:sub(1, 2), 16)
  local r = tonumber(dataHex:sub(3, 4), 16)
  local g = tonumber(dataHex:sub(5, 6), 16)
  local b = tonumber(dataHex:sub(7, 8), 16)
  local state_str = (byte0 == 1) and "on" or "off"
  local parsed_protocol = string.format("state=%s R=%d G=%d B=%d", state_str, r, g, b)

  -- Scan-row SVG tint: live RGB when on, neutral grey when off (SrcIn over monochrome asset).
  local TINT_OFF = "#9E9E9E"
  local icon_tint = (byte0 == 1)
      and string.format("#%02X%02X%02X", r or 0, g or 0, b or 0)
      or TINT_OFF

  entries[1] = {
    id = "blesploit_light",
    display_name = "Blesploit Light",
    attributes = {
      state = state_str,
--      r = r,
--      g = g,
--      b = b,
      parsed_protocol = parsed_protocol
    }
  }
  local ui = {
    device_type = "SMART_HOME",
    custom_icon = "assets/lightbulb.svg",
    custom_icon_tint = icon_tint,
    display_info = parsed_protocol,
  }
  return entries, ui
end
