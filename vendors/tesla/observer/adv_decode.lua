-- Tesla vehicle proximity / iBeacon token pattern:
-- Apple iBeacon manufacturer block (decoded by devices/ibeacon) plus GAP local name of
-- exactly 18 characters starting with "S".
-- Reads uuid/major/minor/tx_power from the existing ibeacon fingerprint entry.

local function find_entry_by_id(fingerprint_entries, want_id)
  if not fingerprint_entries then
    return nil
  end
  local i = 1
  while true do
    local e = fingerprint_entries[i]
    if not e then
      break
    end
    if e.id == want_id then
      return e
    end
    i = i + 1
  end
  return nil
end

function parse(input)
  local ibeacon = find_entry_by_id(input.fingerprint_entries, "ibeacon")
  if not ibeacon or not ibeacon.attributes then
    return {}, {}
  end

  local name = input.device_name or ""
  if #name ~= 18 or name:sub(1, 1) ~= "S" then
    return {}, {}
  end

  local a = ibeacon.attributes
  local uuid = a.uuid
  local major = a.major
  local minor = a.minor
  local tx = a.tx_power

  local entries = {
    {
      id = "tesla_ibeacon_adv",
      display_name = "Tesla (iBeacon)",
      attributes = {
        protocol = "tesla_ibeacon_adv",
        adv_name = name,
        uuid = uuid,
        major = major,
        minor = minor,
        tx_power = tx,
      },
    },
  }

  local ui = {
    device_type = "VEHICLE",
    display_name = "Tesla",
    display_info = name,
    custom_icon = "assets/tesla.svg",
    beacon_format = "I_BEACON",
  }
  return entries, ui
end
