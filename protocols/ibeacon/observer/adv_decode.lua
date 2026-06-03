-- Input: table with manufacturer_data[company_id] = hex string of payload.
-- Apple (0x004C = 76) iBeacon: payload starts 02 15 (subtype, length), then 16-byte UUID, 2-byte major, 2-byte minor, 1-byte TX power.
-- Returns array of fingerprint entries: { id, display_name, attributes = { uuid, major, minor, tx_power } }.

function parse(input)
  local entries = {}
  local mfg = input.manufacturer_data
  if not mfg then return entries end
  -- Company ID 76 = Apple (0x004C)
  local data = mfg["76"]
  if not data or type(data) ~= "string" then return entries end
  data = data:gsub("%s+", ""):lower()
  -- iBeacon prefix: 02 15 (4 hex chars)
  if data:sub(1, 4) ~= "0215" then return entries end
  if #data < 4 + 32 + 4 + 4 + 2 then return entries end
  local uuidHex = data:sub(5, 36)   -- 32 hex chars
  local majorHex = data:sub(37, 40) -- 2 bytes big-endian
  local minorHex = data:sub(41, 44)
  local uuid = uuidHex:sub(1, 8) .. "-" .. uuidHex:sub(9, 12) .. "-" .. uuidHex:sub(13, 16) .. "-" .. uuidHex:sub(17, 20) .. "-" .. uuidHex:sub(21, 32)
  local major = tonumber(majorHex:sub(1, 2), 16) * 256 + tonumber(majorHex:sub(3, 4), 16)
  local minor = tonumber(minorHex:sub(1, 2), 16) * 256 + tonumber(minorHex:sub(3, 4), 16)
  local txPower = bits.arshift(bits.lshift(bits.byte_at(data, 23), 24), 24)
  entries[1] = {
    id = "ibeacon",
    display_name = "iBeacon",
    attributes = {
      uuid = uuid,
      major = major,
      minor = minor,
      tx_power = txPower
    }
  }
  local ui = {
    device_type = "BEACON",
    display_name = "iBeacon",
    custom_icon = "assets/ibeacon.svg",
    beacon_format = "I_BEACON",
  }
  return entries, ui
end
