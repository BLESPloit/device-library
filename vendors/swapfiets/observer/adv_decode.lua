-- Swapfiets bike lock: company 0x020F, service UUID 0x1580, local name "Swapfiets".
-- Manufacturer payload (after company id) is 8 bytes; content varies per device.

local COMPANY_ID = "020F"
local ENTRY_ID = "swapfiets"
local PROTOCOL = "swapfiets"

function parse(input)
  local name = (input.device_name or ""):match("^%s*(.-)%s*$")
  if name ~= "Swapfiets" then
    return {}, nil
  end

  local attrs = {
    device_name = name,
    protocol = PROTOCOL,
    company_id = "020F",
    service_uuid_16 = "1580",
  }

  local module_serial = nil
  local mfg = input.manufacturer_data
  if mfg then
    local data = mfg[COMPANY_ID]
    if type(data) == "string" then
      data = data:gsub("%s+", ""):upper()
      if #data >= 2 then
        module_serial = data
        attrs.module_serial = module_serial
      end
    end
  end

  local entries = {
    {
      id = ENTRY_ID,
      display_name = "Swapfiets bike",
      attributes = attrs,
    },
  }

  local ui = {
    device_type = "VEHICLE",
    custom_icon = "assets/swapfiets.svg",
    display_name = "Swapfiets bike",
    display_info = module_serial or "Swapfiets bike",
  }

  return entries, ui
end
