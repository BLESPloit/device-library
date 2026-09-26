-- OrangeCon 2026 Badge: manufacturer data (company 0xBAD0) is <1B type><4B id> (id little-endian).
-- Example payload 0144332211: type 01 ("regular"), id 0x11223344.

local COMPANY_ID = "BAD0"

local TYPE_NAMES = {
  [0x01] = "regular",
  [0x02] = "staff",
  [0x03] = "speaker"
}

local function type_label(byte)
  return TYPE_NAMES[byte] or ("0x" .. bits.tohex(byte, 2))
end

function parse(input)
  local entries = {}
  local mfg = input.manufacturer_data
  if not mfg then return entries end

  local data = mfg[COMPANY_ID]
  if not data or type(data) ~= "string" then return entries end
  data = hex.norm(data)
  if hex.len(data) < 5 then return entries end

  local type_byte = hex.byte(data, 1)
  local id = bits.le32(data, 2)

  local type_str = type_label(type_byte)
  local id_str = bits.tohex(id, 8)
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
