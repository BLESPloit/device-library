-- Confirm Tuya GATT after service discovery. Does not read characteristics.
-- Real TY modules expose either SIG 0xFD50 (current) or legacy 0x1910.

local ENTRY_ID = "tuya_gatt"
local PROTOCOL = "tuya"

local function compact_set(list)
  local out = {}
  if type(list) ~= "table" then
    return out
  end
  for _, u in pairs(list) do
    if type(u) == "string" then
      local c = uuid.compact(u)
      if c ~= "" then
        out[c] = true
      end
    end
  end
  return out
end

local function has_any(set, ...)
  for i = 1, select("#", ...) do
    local key = select(i, ...)
    if key and key ~= "" and set[key] then
      return true
    end
  end
  return false
end

local function cu(u, fallback)
  if type(u) == "string" and u ~= "" then
    return uuid.compact(u)
  end
  return uuid.compact(fallback or "")
end

function parse(input)
  input = input or {}
  local services = compact_set(input.service_uuids)
  local chrs = compact_set(input.characteristic_uuids)

  local fd50 = cu(uuids.SVC_TUYA, "0000fd50-0000-1000-8000-00805f9b34fb")
  local legacy = cu(uuids.SVC_TUYA_LEGACY, "00001910-0000-1000-8000-00805f9b34fb")
  local wr = cu(uuids.CHR_TUYA_WRITE, "00000001-0000-1001-8001-00805f9b07d0")
  local ntf = cu(uuids.CHR_TUYA_NOTIFY, "00000002-0000-1001-8001-00805f9b07d0")
  local wr_l = cu(uuids.CHR_TUYA_LEGACY_WRITE, "00002b11-0000-1000-8000-00805f9b34fb")
  local ntf_l = cu(uuids.CHR_TUYA_LEGACY_NOTIFY, "00002b10-0000-1000-8000-00805f9b34fb")

  local layout
  if services[fd50] then
    layout = "fd50"
  elseif services[legacy] then
    layout = "1910"
  else
    return {}, {}
  end

  local attrs = {
    protocol = PROTOCOL,
    gatt_layout = layout,
  }
  if layout == "fd50" then
    attrs.gatt_write = has_any(chrs, wr) and "true" or "false"
    attrs.gatt_notify = has_any(chrs, ntf) and "true" or "false"
  else
    attrs.gatt_write = has_any(chrs, wr_l) and "true" or "false"
    attrs.gatt_notify = has_any(chrs, ntf_l) and "true" or "false"
  end

  local label = layout == "fd50" and "Tuya GATT (0xFD50)" or "Tuya GATT (legacy 0x1910)"
  return {
    {
      id = ENTRY_ID,
      display_name = label,
      attributes = attrs,
    },
  }, {}
end
