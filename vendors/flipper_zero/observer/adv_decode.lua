-- source: https://github.com/k3yomi/Wall-of-Flippers/
local SHELL_BY_UUID = {
  ["3081"] = "Black",
  ["3082"] = "White",
  ["3083"] = "Transparent",
}

local function detect_shell(input)
  for uuid16, shell in pairs(SHELL_BY_UUID) do
    if adv.has_uuid(input, uuid16) then
      return shell
    end
  end
  return nil
end

function parse(input)
  local shell = detect_shell(input)
  if not shell then
    return {}, { custom_icon = "assets/flipper.svg" }
  end

  local adv_name = (input.device_name or ""):match("^%s*(.-)%s*$")
  local display_name = (adv_name ~= "") and ("Flipper " .. adv_name) or "Flipper"

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