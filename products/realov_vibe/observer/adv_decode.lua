-- REALOV_VIBE local name (manifest scan_conditions). Sets protocol for central quick_action / menu match.

local ENTRY_ID = "realov_vibe"
local PROTOCOL = "realov_vibe"

function parse(input)
  local name = input.device_name or ""
  if name == "" then
    return {}, nil
  end
  -- Manifest already filters REALOV_VIBE; keep a sanity check for substring.
  if not name:find("REALOV_VIBE", 1, true) then
    return {}, nil
  end

  local entries = {
    {
      id = ENTRY_ID,
      display_name = "Realov Vibe",
      attributes = {
        device_name = name,
        protocol = PROTOCOL,
      },
    },
  }

  local ui = {
    device_type = "SMART_HOME",
    custom_icon = "assets/realov.svg",
    display_info = "Realov Vibe",
  }
  return entries, ui
end
