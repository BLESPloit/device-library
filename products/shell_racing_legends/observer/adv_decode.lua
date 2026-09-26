-- Shell Racing Legends: SL-<model> name (e.g. SL-SF-24) and/or vendor service 0x6936.

local ENTRY_ID = "shell_racing_legends"
local PROTOCOL = "shell_racing_legends"
local VENDOR_SVC = "6936"

--- SL-SF-24 → model "SF-24"; SL-SF1000 → "SF1000"; bare SL-foo → "foo"
local function infer_model(name)
  if not name or name == "" then
    return ""
  end
  local rest = name:match("^[Ss][Ll]%-(.+)$")
  if rest and rest ~= "" then
    return rest
  end
  return name
end

function parse(input)
  local name = input.device_name or ""
  local name_ok = name:match("^[Ss][Ll]%-") ~= nil
  local svc_ok = adv.has_uuid(input, VENDOR_SVC)
  if not name_ok and not svc_ok then
    return {}, {}
  end

  local model = infer_model(name)
  local display_name = "Shell Racing Legends"
  local display_info = "RC car"
  if model ~= "" then
    display_info = model
  elseif name ~= "" then
    display_info = name
  end
  if svc_ok then
    display_info = display_info .. " · 6936"
  end

  return {
    {
      id = ENTRY_ID,
      display_name = display_name,
      attributes = {
        protocol = PROTOCOL,
        device_name = name,
        model = model,
        vendor_service = svc_ok and "true" or "false",
      },
    },
  }, {
    device_type = "TOY",
    custom_icon = "assets/shell_racing_legends.svg",
    display_name = display_name,
    display_info = display_info,
  }
end
