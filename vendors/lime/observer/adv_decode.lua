-- Lime scooter: GAP local name "lime-{bike_imei}", 16-bit service UUID 0xFFF0.

local ENTRY_ID = "lime"
local PROTOCOL = "lime"

function parse(input)
  local name = (input.device_name or ""):match("^%s*(.-)%s*$")
  local bike_imei = name:match("^lime%-(%d+)$")
  if not bike_imei then
    return {}, nil
  end

  local attrs = {
    device_name = name,
    protocol = PROTOCOL,
    bike_imei = bike_imei
  }

  local entries = {
    {
      id = ENTRY_ID,
      display_name = "Lime scooter",
      attributes = attrs,
    },
  }

  local ui = {
    device_type = "VEHICLE",
    display_name = "Lime scooter",
    display_info = bike_imei,
  }

  return entries, ui
end
