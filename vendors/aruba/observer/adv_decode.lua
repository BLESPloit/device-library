-- HPE Aruba access point observer.
-- BluConsole manufacturer data: company 0x011B, payload subtype 0x08.
-- Also enriches Apple iBeacon frames carrying the Aruba UUID, and GAP names AP-{mac12}.

local ENTRY_ID = "aruba_ap"
local PROTOCOL = "aruba_ap"
local ARUBA_IBEACON_UUID = "4152554e-f99b-4a3b-86d0-947070693a78"
local COMPANY_ID = "011B"
local SUBTYPE_BLUCONSOLE = "08"
local TRAILER_MODERN = "020100ff"

local function empty()
  return {}, {}
end

--- modern = byte16 0x01 with fixed trailer; legacy = original + transitional layouts.
local function classify_bluconsole_profile(data, byte16_hex)
  if byte16_hex == "01" and data:sub(-(#TRAILER_MODERN)) == TRAILER_MODERN then
    return "modern"
  end
  return "legacy"
end

local function parse_bluconsole_mfg(data)
  data = hex.norm(data)
  if hex.slice(data, 1, 1) ~= SUBTYPE_BLUCONSOLE then
    return nil
  end
  if hex.len(data) < 19 then
    return nil
  end

  local mac = mac.from_reversed(hex.slice(data, 2, 6))
  local identity_hash = hex.slice(data, 8, 4)
  local adv_version = bits.le16(data, 12)
  local channel_pad = hex.slice(data, 14, 1)
  local wifi_channel_hint = hex.byte(data, 16)
  local byte5_hex = hex.slice(data, 6, 1)
  local byte16_hex = hex.slice(data, 17, 1)
  local trailer = hex.slice(data, 16, hex.len(data) - 15)

  if channel_pad ~= "00" then
    return nil
  end

  local profile = classify_bluconsole_profile(data, byte16_hex)

  return {
    adv_format = "bluconsole_mfg",
    bluconsole = "true",
    bluconsole_profile = profile,
    record_subtype = SUBTYPE_BLUCONSOLE,
    company_id = COMPANY_ID,
    bd_addr = mac,
    identity_hash = identity_hash,
    adv_version = tostring(adv_version),
    wifi_channel_hint = tostring(wifi_channel_hint),
    byte5 = byte5_hex,
    byte16 = byte16_hex,
    trailer = trailer,
  }
end

local function find_aruba_ibeacon(input)
  local prior = input.fingerprint_entries
  if not prior then
    return nil
  end
  for i = 1, #prior do
    local e = prior[i]
    if e.id == "ibeacon" and e.attributes and e.attributes.uuid then
      if e.attributes.uuid:lower() == ARUBA_IBEACON_UUID then
        return e.attributes
      end
    end
  end
  return nil
end

local function parse_gap_name(name)
  name = (name or ""):match("^%s*(.-)%s*$") or ""
  local mac12 = name:match("^AP%-([0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F])$")
  if not mac12 then
    return nil
  end
  return {
    adv_format = "gap_name",
    bluconsole = "unknown",
    device_name = name,
    bd_addr = mac.format(mac12),
  }
end

local function bluconsole_display_info(attrs)
  if attrs.wifi_channel_hint ~= "" then
    return "BluConsole · ch " .. attrs.wifi_channel_hint
  end
  return "BluConsole"
end

local ICON_AP = "assets/aruba_ap.svg"
local ICON_IBEACON = "assets/aruba_ibeacon.svg"

local function build_entry(attrs, display_name, display_info, opts)
  opts = opts or {}
  attrs.protocol = PROTOCOL
  local entries = {
    {
      id = ENTRY_ID,
      display_name = display_name,
      attributes = attrs,
    },
  }
  local ui = {
    device_type = opts.device_type or "ACCESS_POINT",
    display_name = display_name,
    display_info = display_info or "",
    custom_icon = opts.custom_icon or ICON_AP,
  }
  if opts.beacon_format then
    ui.beacon_format = opts.beacon_format
  end
  return entries, ui
end

function parse(input)
  local mfg = input.manufacturer_data
  if mfg then
    local data = mfg[COMPANY_ID]
    local attrs = parse_bluconsole_mfg(data)
    if attrs then
      return build_entry(attrs, "HPE Aruba AP", bluconsole_display_info(attrs))
    end
  end

  local ibeacon = find_aruba_ibeacon(input)
  if ibeacon then
    local attrs = {
      adv_format = "aruba_ibeacon",
      bluconsole = "false",
      ibeacon_uuid = ibeacon.uuid,
      ibeacon_major = tostring(ibeacon.major or ""),
      ibeacon_minor = tostring(ibeacon.minor or ""),
      ibeacon_tx_power = tostring(ibeacon.tx_power or ""),
    }
    local info = string.format(
      "maj %s min %s",
      attrs.ibeacon_major,
      attrs.ibeacon_minor
    )
    return build_entry(attrs, "HPE Aruba iBeacon", info, {
      device_type = "BEACON",
      custom_icon = ICON_IBEACON,
      beacon_format = "I_BEACON",
    })
  end

  local name_attrs = parse_gap_name(input.device_name)
  if name_attrs then
    return build_entry(name_attrs, "HPE Aruba AP", name_attrs.device_name)
  end

  return empty()
end
