-- Daikin Madoka BRC1H advertisement fingerprint.
-- Real units: Flags + 128-bit UCG UART UUID + manufacturer 0x0093/E000 + names "Daikin" / "BRC1H xx:xx:xx".

local ENTRY_ID = "daikin_brc1h"
local PROTOCOL = "daikin_madoka"
local UART_UUID = "2141e110213a11e6b67b9e71128cae77"
local COMPANY = "0093"
local MSD_PREFIX = "e000"

local function empty()
  return {}, {}
end

local function norm_hex(h)
  if type(h) ~= "string" then
    return ""
  end
  return h:gsub("%s+", ""):lower()
end

local function norm_uuid(u)
  if type(u) ~= "string" then
    return ""
  end
  return u:lower():gsub("%-", "")
end

local function ascii_from_hex(hex)
  hex = norm_hex(hex)
  local chars = {}
  for i = 1, #hex, 2 do
    local b = tonumber(hex:sub(i, i + 1), 16)
    if b and b >= 32 and b <= 126 then
      chars[#chars + 1] = string.char(b)
    end
  end
  return table.concat(chars)
end

local function name_from_raw_adv(raw)
  raw = norm_hex(raw)
  if raw == "" then
    return "", ""
  end
  local complete, short = "", ""
  local pos = 1
  while pos <= #raw - 3 do
    local len = tonumber(raw:sub(pos, pos + 1), 16)
    if not len or len < 1 then
      break
    end
    local typ = raw:sub(pos + 2, pos + 3)
    local data_end = pos + 2 + len * 2
    local data = raw:sub(pos + 4, data_end)
    if typ == "09" and #data >= 2 then
      complete = ascii_from_hex(data)
    elseif typ == "08" and #data >= 2 then
      short = ascii_from_hex(data)
    end
    pos = pos + 2 + len * 2
  end
  return complete, short
end

local function has_uart_uuid(input)
  local lists = { input.service_uuids, input.service_uuids_16 }
  for _, list in ipairs(lists) do
    if type(list) == "table" then
      for _, u in pairs(list) do
        if norm_uuid(tostring(u)) == UART_UUID then
          return true
        end
      end
    elseif type(list) == "string" and norm_uuid(list) == UART_UUID then
      return true
    end
  end
  local raw = norm_hex(input.raw_adv_hex or input.adv_data_hex_combined or input.adv_data_hex or "")
  -- Little-endian 128-bit UUID in AD type 0x06/0x07: 77ae8c12…10e14121
  if raw:find("77ae8c12719e7bb6e6113a2110e14121", 1, true) then
    return true
  end
  return false
end

local function msd_payload(input)
  local mfg = input.manufacturer_data
  if type(mfg) == "table" then
    local p = mfg[COMPANY] or mfg["0093"] or mfg[0x0093]
    if type(p) == "string" then
      return norm_hex(p)
    end
  end
  local raw = norm_hex(input.raw_adv_hex or input.adv_data_hex_combined or input.adv_data_hex or "")
  local pos = 1
  while pos <= #raw - 3 do
    local len = tonumber(raw:sub(pos, pos + 1), 16)
    if not len or len < 1 then
      break
    end
    local typ = raw:sub(pos + 2, pos + 3)
    local data = raw:sub(pos + 4, pos + 2 + len * 2)
    if typ == "ff" and #data >= 4 then
      local cid = (data:sub(3, 4) .. data:sub(1, 2)):upper()
      if cid == COMPANY then
        return data:sub(5)
      end
    end
    pos = pos + 2 + len * 2
  end
  return ""
end

local function is_brc1h_name(name)
  return type(name) == "string" and name:match("^BRC1H") ~= nil
end

local function suffix_from_name(name)
  if type(name) ~= "string" then
    return ""
  end
  local a, b, c = name:match("BRC1H%s+(%x%x):(%x%x):(%x%x)")
  if a then
    return (a .. ":" .. b .. ":" .. c):upper()
  end
  return ""
end

function parse(input)
  input = input or {}
  local raw = input.raw_adv_hex or input.adv_data_hex_combined or input.adv_data_hex or ""
  local complete, short = name_from_raw_adv(raw)
  local name = input.device_name or ""
  if name == "" then
    name = complete
  end
  if name == "" then
    name = short
  end

  local uart = has_uart_uuid(input)
  local payload = msd_payload(input)
  local daikin_msd = payload:sub(1, 4) == MSD_PREFIX
  local named = is_brc1h_name(name) or is_brc1h_name(complete)

  if not uart and not daikin_msd and not named then
    return empty()
  end

  local suffix = suffix_from_name(name)
  if suffix == "" then
    suffix = suffix_from_name(complete)
  end

  -- Title is the vendor class. "Madoka" stays on the subtitle only.
  local display_info = "Madoka"
  if suffix ~= "" then
    display_info = display_info .. " · " .. suffix
  elseif name ~= "" and name ~= "Daikin" then
    display_info = display_info .. " · " .. name
  end

  return {
    {
      id = ENTRY_ID,
      display_name = "Daikin A/C",
      hint = "Pairing (including confirmation on the device) is required to use the communication protocol.",
      attributes = {
        protocol = PROTOCOL,
        product = "BRC1H",
        device_name = name,
        short_name = short,
        company_id = COMPANY,
        msd_hex = payload,
        uart_service = uart and "true" or "false",
        mac_suffix = suffix,
      },
    },
  }, {
    device_type = "APPLIANCE",
    custom_icon = "assets/madoka.svg",
    display_name = "Daikin A/C",
    display_info = display_info,
  }
end
