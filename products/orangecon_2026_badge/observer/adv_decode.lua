-- OrangeCon 2026 Badge: manufacturer data (company 0xBAD0) is <1B type><4B id> (id little-endian).
-- Example payload 0144332211: type 01 ("regular"), id 0x11223344.

local COMPANY_ID = "47824" -- 0xBAD0

local TYPE_NAMES = {
  [0x01] = "regular",
  [0x02] = "staff",
  [0x03] = "speaker"
}

local function type_label(byte)
  return TYPE_NAMES[byte] or string.format("0x%02X", byte)
end

function parse(input)
  local entries = {}
  local mfg = input.manufacturer_data
  if not mfg then return entries end

  local data = mfg[COMPANY_ID]
  if not data or type(data) ~= "string" then return entries end
  data = data:gsub("%s+", ""):lower()
  if #data < 10 then return entries end

  local type_byte = tonumber(data:sub(1, 2), 16)
  local b0 = tonumber(data:sub(3, 4), 16)
  local b1 = tonumber(data:sub(5, 6), 16)
  local b2 = tonumber(data:sub(7, 8), 16)
  local b3 = tonumber(data:sub(9, 10), 16)
  if type_byte == nil or b0 == nil or b1 == nil or b2 == nil or b3 == nil then
    return entries
  end
  local id = b0 + b1 * 256 + b2 * 65536 + b3 * 16777216

  local type_str = type_label(type_byte)
  local id_str = string.format("%08X", id)
  local subtitle = type_str .. " · " .. id_str

  entries[1] = {
    id = "orangecon_2026_badge",
    display_name = "OrangeCon 2026 Badge",
    attributes = {
      type = type_byte,
      type_label = type_str,
      id = id,
      id_hex = id_str,
    },
  }

  local ui = {
    display_name = "OrangeCon 2026 Badge",
    display_info = subtitle,
    custom_icon = "assets/orangecon.svg",
  }
  return entries, ui
end
