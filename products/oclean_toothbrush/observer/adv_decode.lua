-- Oclean observer: name + service UUID hints; manufacturer AD is 6-byte bdaddr (not SIG company data).

local ENTRY_ID = "oclean"
local PROTOCOL = "oclean"
local DG_SVC = "a6ed0401d344460a8075b9e8ec90d71b"

local function infer_model(name)
  if not name or name == "" then
    return "Oclean"
  end
  local model = name:match("^Oclean%s+(.+)$") or name:match("^Oclean_(.+)$")
  if model and model ~= "" then
    return model
  end
  return "Oclean"
end

-- When the scanner splits the first two MAC bytes into a pseudo company_id key, rejoin to 6 bytes.
local function bdaddr_from_mfg_table(mfg)
  if type(mfg) ~= "table" then
    return ""
  end
  for cid, payload in pairs(mfg) do
    if type(cid) == "string" and type(payload) == "string" and #payload >= 8 then
      local wire = cid:sub(3, 4):lower() .. cid:sub(1, 2):lower() .. hex.norm(payload)
      if #wire >= 12 then
        return mac.from_reversed(wire:sub(1, 12))
      end
    end
  end
  return ""
end

local function extract_adv_bdaddr(input)
  local raw = input.raw_adv_hex or input.adv_data_hex_combined or ""
  local ff = adv.find(raw, 0xFF)
  local data = ff[1]
  if type(data) == "string" and #data >= 12 then
    return mac.from_reversed(data:sub(1, 12))
  end
  return bdaddr_from_mfg_table(input.manufacturer_data)
end

function parse(input)
  local name = input.device_name or ""
  if name == "" or not name:find("Oclean", 1, true) then
    return {}, {}
  end

  local dg_service = adv.has_uuid(input, DG_SVC)
  local model_hint = infer_model(name)
  local adv_bdaddr = extract_adv_bdaddr(input)

  local display_info = "Toothbrush · " .. model_hint
  if name ~= "" and name ~= model_hint then
    display_info = display_info .. " · " .. name
  end

  return {
    {
      id = ENTRY_ID,
      display_name = "Oclean",
      attributes = {
        protocol = PROTOCOL,
        device_name = name,
        model_hint = model_hint,
        adv_bdaddr = adv_bdaddr,
        dg_service = dg_service and "true" or "false",
      },
    },
  }, {
    device_type = "HEALTH",
    custom_icon = "assets/oclean_logo.svg",
    display_info = display_info,
  }
end
