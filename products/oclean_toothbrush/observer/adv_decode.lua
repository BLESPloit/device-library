-- Oclean observer: name + service UUID hints; manufacturer AD is 6-byte bdaddr (not SIG company data).

local ENTRY_ID = "oclean"
local PROTOCOL = "oclean"
local DG_SVC = "a6ed0401d344460a8075b9e8ec90d71b"

local function has_service_uuid(input, target)
  if not input or not target then
    return false
  end
  target = target:lower():gsub("%-", "")
  local lists = { input.service_uuids, input.service_uuids_16 }
  for _, list in ipairs(lists) do
    if type(list) == "table" then
      for _, u in pairs(list) do
        if type(u) == "string" and u:lower():gsub("%-", "") == target then
          return true
        end
      end
    end
  end
  if type(input.service_data) == "table" then
    for key, _ in pairs(input.service_data) do
      if type(key) == "string" and key:lower():gsub("%-", "") == target then
        return true
      end
    end
  end
  return false
end

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

local function reversed_hex_to_bdaddr(rev_hex)
  if not rev_hex or #rev_hex < 12 then
    return ""
  end
  rev_hex = rev_hex:lower()
  local parts = {}
  for i = 1, 12, 2 do
    parts[#parts + 1] = rev_hex:sub(i, i + 1)
  end
  local out = {}
  for i = #parts, 1, -1 do
    out[#out + 1] = parts[i]
  end
  return table.concat(out, ":"):upper()
end

-- Oclean puts the full 6-byte address in manufacturer-specific AD (type 0xFF), not a SIG company ID + payload.
local function parse_mfg_bdaddr_from_raw(raw)
  if not raw or raw == "" then
    return ""
  end
  raw = raw:lower():gsub("%s+", "")
  local pos = 1
  while pos <= #raw - 3 do
    local len = tonumber(raw:sub(pos, pos + 1), 16)
    if not len or len < 1 then
      break
    end
    local typ = raw:sub(pos + 2, pos + 3)
    local data_end = pos + 2 + len * 2
    local data = raw:sub(pos + 4, data_end)
    if typ == "ff" and #data >= 12 then
      return reversed_hex_to_bdaddr(data:sub(1, 12))
    end
    pos = pos + 2 + len * 2
  end
  return ""
end

-- When the scanner splits the first two MAC bytes into a pseudo company_id key, rejoin to 6 bytes.
local function bdaddr_from_mfg_table(mfg)
  if type(mfg) ~= "table" then
    return ""
  end
  for cid, payload in pairs(mfg) do
    if type(cid) == "string" and type(payload) == "string" and #payload >= 8 then
      local wire = cid:sub(3, 4):lower() .. cid:sub(1, 2):lower() .. payload:lower()
      if #wire >= 12 then
        return reversed_hex_to_bdaddr(wire:sub(1, 12))
      end
    end
  end
  return ""
end

local function extract_adv_bdaddr(input)
  local raw = input.raw_adv_hex or input.adv_data_hex_combined or ""
  local addr = parse_mfg_bdaddr_from_raw(raw)
  if addr ~= "" then
    return addr
  end
  return bdaddr_from_mfg_table(input.manufacturer_data)
end

function parse(input)
  local name = input.device_name or ""
  if name == "" or not name:find("Oclean", 1, true) then
    return {}, {}
  end

  local dg_service = has_service_uuid(input, DG_SVC)
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
