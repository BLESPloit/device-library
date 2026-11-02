-- Shell Racing Legends identity from the GATT characteristic list.
-- 0xFFF0 and 0xFFF1 are shared. Require the vendor FE01 characteristic as well.

local ENTRY_ID = "shell_racing_legends"
local PROTOCOL = "shell_racing_legends"
local VENDOR_CHR = "fe01"
local DRIVE = "fff1"
local BASE = "00001000800000805f9b34fb"

local function canonical(uuid)
  local hex = (tostring(uuid or "")):lower():gsub("-", ""):gsub("^0x", "")
  if #hex == 4 then
    return "0000" .. hex .. BASE
  end
  if #hex == 8 and hex:sub(1, 4) == "0000" then
    return hex .. BASE
  end
  return hex
end

local function has_uuid(list, want)
  local target = canonical(want)
  if target == "" then
    return false
  end
  for i = 1, #(list or {}) do
    if canonical(list[i]) == target then
      return true
    end
  end
  return false
end

function parse(input)
  local chars = (input and input.characteristic_uuids) or {}
  if not has_uuid(chars, VENDOR_CHR) or not has_uuid(chars, DRIVE) then
    return {}
  end

  return {
    {
      id = ENTRY_ID,
      display_name = "Shell Racing Legends",
      attributes = { protocol = PROTOCOL },
    },
  }, {
    device_type = "TOY",
    custom_icon = "assets/shell_racing_legends.svg",
    display_name = "Shell Racing Legends",
    display_info = "RC car",
  }
end
