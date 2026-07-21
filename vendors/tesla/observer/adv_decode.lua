-- Tesla vehicle proximity token:
-- (1) iBeacon manufacturer block (0xFF) plus 18-char local name starting with "S".
-- (2) iOS / stripped path: same name pattern + incomplete 16-bit service UUID 0x1122 (AD 0x02 2211).

local TESLA_SVC_UUID16 = "1122"

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

local function is_tesla_adv_name(name)
  return #name == 18 and name:sub(1, 1) == "S"
end

local function has_service_uuid_16(input, want)
  local t = input.service_uuids_16
  if not t then
    return false
  end
  local want_norm = want:upper()
  local i = 1
  while true do
    local u = t[i]
    if not u then
      break
    end
    if type(u) == "string" then
      local norm = u:gsub("^0x", ""):upper()
      if norm == want_norm then
        return true
      end
    end
    i = i + 1
  end
  return false
end

local function build_ui(name, beacon_format)
  local ui = {
    device_type = "VEHICLE",
    display_name = "Tesla",
    display_info = name,
    custom_icon = "assets/tesla.svg",
  }
  if beacon_format then
    ui.beacon_format = beacon_format
  end
  return ui
end

function parse(input)
  local name = input.device_name or ""
  if not is_tesla_adv_name(name) then
    return {}, {}
  end

  local ibeacon = find_entry_by_id(input.fingerprint_entries, "ibeacon")
  if ibeacon and ibeacon.attributes then
    local a = ibeacon.attributes
    return {
      {
        id = "tesla_ibeacon_adv",
        display_name = "Tesla (iBeacon)",
        attributes = {
          protocol = "tesla_ibeacon_adv",
          adv_name = name,
          uuid = a.uuid,
          major = a.major,
          minor = a.minor,
          tx_power = a.tx_power,
          match = "ibeacon",
        },
      },
    }, build_ui(name, "I_BEACON")
  end

  if has_service_uuid_16(input, TESLA_SVC_UUID16) then
    return {
      {
        id = "tesla_ibeacon_adv",
        display_name = "Tesla",
        attributes = {
          protocol = "tesla_ibeacon_adv",
          adv_name = name,
          service_uuid_16 = TESLA_SVC_UUID16,
          match = "name_and_service_uuid",
        },
      },
    }, build_ui(name, nil)
  end

  return {}, {}
end
