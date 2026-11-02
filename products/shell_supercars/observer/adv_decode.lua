-- Shell SuperCars: advertised name QCAR-XXXX (manifest scan_conditions).
-- Sets protocol so the central menu is not selected by service 0xFFF0 alone.

local ENTRY_ID = "shell_supercars"
local PROTOCOL = "shell_supercars"

function parse(input)
  local name = input.device_name or ""
  if not name:match("^QCAR%-[0-9A-F][0-9A-F][0-9A-F][0-9A-F]$") then
    return {}, {}
  end

  return {
    {
      id = ENTRY_ID,
      display_name = "Shell SuperCars",
      attributes = {
        protocol = PROTOCOL,
        device_name = name,
      },
    },
  }, {
    device_type = "TOY",
    custom_icon = "assets/bmw_m1.svg",
    display_name = "Shell SuperCars",
    display_info = name,
  }
end
