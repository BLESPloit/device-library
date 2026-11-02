-- Shell SuperCars identity from the GATT characteristic list.
-- Service 0xFFF0 is shared by other proprietary protocols. The drive characteristic is not.

local ENTRY_ID = "shell_supercars"
local PROTOCOL = "shell_supercars"
local DRIVE = "d44bc439-abfd-45a2-b575-925416129600"
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
  if not has_uuid(chars, DRIVE) then
    return {}
  end

  return {
    {
      id = ENTRY_ID,
      display_name = "Shell SuperCars",
      attributes = { protocol = PROTOCOL },
    },
  }, {
    device_type = "TOY",
    custom_icon = "assets/bmw_m1.svg",
    display_name = "Shell SuperCars",
    display_info = "Shell SuperCars",
  }
end
