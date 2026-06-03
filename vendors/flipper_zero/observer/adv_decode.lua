-- source: https://github.com/k3yomi/Wall-of-Flippers/
local SHELL_BY_UUID = {
  ["3081"] = "Black",
  ["3082"] = "White",
  ["3083"] = "Transparent",
}

local function norm_uuid16(cell)
  if type(cell) == "string" then
    return cell:gsub("^0x", ""):upper()
  end
  return nil
end

local function detect_shell(input)
  local t = input.service_uuids_16
  if not t then return nil end
  local i = 1
  while true do
    local u = norm_uuid16(t[i])
    if not u then break end
    local shell = SHELL_BY_UUID[u]
    if shell then return shell end
    i = i + 1
  end
  return nil
end

function parse(input)
  local shell = detect_shell(input)
  if not shell then
    return {}, { custom_icon = "assets/flipper.svg" }
  end

  local adv = (input.device_name or ""):match("^%s*(.-)%s*$")
  local display_name = (adv ~= "") and ("Flipper " .. adv) or "Flipper"

  local entries = {
    {
      id = "flipper_zero",
      display_name = "Flipper Zero",
      attributes = {
        shell_color = shell,
      },
    },
  }

  local ui = {
    custom_icon = "assets/flipper.svg",
    display_name = display_name,
    display_info = shell,
  }

  return entries, ui
end