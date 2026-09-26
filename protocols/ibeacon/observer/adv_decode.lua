-- Input: manufacturer_data["004C"] = hex payload (4-digit SIG company id keys).
-- Apple iBeacon: payload starts 02 15 (subtype, length), then 16-byte UUID, 2-byte major, 2-byte minor, 1-byte TX power.
-- Returns array of fingerprint entries: { id, display_name, attributes = { uuid, major, minor, tx_power } }.

function parse(input)
  local entries = {}
  local mfg = input.manufacturer_data
  if not mfg then return entries end
  local data = mfg["004C"]
  if not data or type(data) ~= "string" then return entries end
  data = hex.norm(data)
  if hex.slice(data, 1, 2) ~= "0215" then return entries end
  if hex.len(data) < 23 then return entries end
  local uuidHex = hex.slice(data, 3, 16)
  local uuid = uuidHex:sub(1, 8) .. "-" .. uuidHex:sub(9, 12) .. "-" .. uuidHex:sub(13, 16) .. "-" .. uuidHex:sub(17, 20) .. "-" .. uuidHex:sub(21, 32)
  local major = bits.be16(data, 19)
  local minor = bits.be16(data, 21)
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
