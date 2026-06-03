-- Happy Lighting family: BLE local name prefixes aligned with vendor app (see COMPANY_NAME regex).
-- Scan conditions (manifest) use device_name_contains; here we classify prefix for display_info.

local DEVICE_KEY = "happy_lighting"

--- Prefix rules: order matters — more specific families before broad ^Triones.
local FAMILY_RULES = {
  { "^BRGlight", "BRGlight" },
  { "^Color%+", "Color+" },
  { "^Color%-", "Color-" },
  { "^Dream%-", "Dream" },
  { "^Dream%*", "Dream" },
  { "^Dream%#", "Dream" },
  { "^Dream~", "Dream" },
  { "^Dream&", "Dream" },
  { "^Dream=", "Dream" },
  { "^Light%-", "Light-" },
  { "^LD%-", "LD-" },
  { "^Dimmer", "Dimmer" },
  { "^QHM", "QHM" },
  { "^Flash", "Flash" },
  { "^QLAMP", "QLAMP" },
  { "^Morimoto", "Morimoto" },
  { "^Thaillamp", "Thaillamp" },
  { "^LXDZ", "LXDZ" },
  { "^Archaic", "Archaic" },
  { "^GLOWDRIV", "GLOWDRIV" },
  { "^RAMAND", "RAMAND" },
  { "^Triones", "Triones" },
}

local function recognize_family(name)
  if not name or name == "" then
    return nil
  end
  for _, row in ipairs(FAMILY_RULES) do
    local patt, label = row[1], row[2]
    if name:match(patt) then
      return label
    end
  end
  return nil
end

function parse(input)
  local entries = {}
  local name = input.device_name or ""

  local family = recognize_family(name)
  local display_line = family and ("Happy Light: " .. family) or "Happy Light"

  entries[1] = {
    id = DEVICE_KEY,
    display_name = "Happy Light",
    attributes = {
      family = family or "",
      device_name = name,
      protocol = "happy_lighting",
    },
  }

  local ui = {
    device_type = "SMART_HOME",
    custom_icon = "assets/happy_lighting.svg",
    display_info = display_line,
  }
  return entries, ui
end
