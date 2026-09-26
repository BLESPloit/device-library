-- Quantam / Gridtraq advertising decoder (DeviceModel Old/ExtendedAdvertisingDecoder).
-- MSD (AD 0xFF) includes LE company id as first two bytes in the on-air record.
-- BLESPloit manufacturer_data keys are 4-digit uppercase company ids; values omit those two bytes.

local ENTRY_ID = "karr"
local PROTOCOL = "karr"
local VBAT_K = 0.06
local MIN_MSD = 5
local EXT_LEN = 26

local UNIT_TYPES = {
  [0] = "QT6_CAN",
  [1] = "QT6_BLUE",
  [2] = "QT6_GREEN",
  [3] = "QT6_RED",
  [4] = "DR1_CAN",
  [5] = "VW_Programmer",
  [6] = "CIU",
  [7] = "DR2_ESP",
  [8] = "QT7_GREEN",
  [9] = "QT7_CAN",
  [255] = "Unknown",
}

local MODES = {
  [0] = "Installer",
  [1] = "Dealer",
  [2] = "User",
  [3] = "No_Sale",
  [4] = "BCA",
  [5] = "Valet",
  [6] = "Bootload",
  [7] = "Unconfigured",
  [255] = "Unknown",
}

local function empty()
  return {}, {}
end

local function is_old_serial(name)
  -- Lua patterns have no `|` alternation (unlike Kotlin regex in scan_conditions).
  if type(name) ~= "string" then
    return false
  end
  local hex = name:match("^DR ([A-F0-9]+)$") or name:match("^QT ([A-F0-9]+)$")
  return hex ~= nil and (#hex == 7 or #hex == 8)
end

local function is_new_serial(name)
  return type(name) == "string" and name:match("^[0-9A-HJKMNP-TV-Z][0-9A-HJKMNP-TV-Z][0-9A-HJKMNP-TV-Z][0-9A-HJKMNP-TV-Z][0-9A-HJKMNP-TV-Z][0-9A-HJKMNP-TV-Z][0-9A-HJKMNP-TV-Z][0-9A-HJKMNP-TV-Z][0-9A-HJKMNP-TV-Z][0-9A-HJKMNP-TV-Z][0-9A-HJKMNP-TV-Z][0-9A-HJKMNP-TV-Z][0-9A-HJKMNP-TV-Z]$") ~= nil
end

local function valid_device_name(name)
  return is_old_serial(name) or is_new_serial(name)
end

--- Normalize GAP name (trim NULs; QT/DR hex → uppercase) so sim/phone variants still match.
local function normalize_device_name(name)
  if type(name) ~= "string" then
    return ""
  end
  name = name:gsub("%z", ""):gsub("^%s+", ""):gsub("%s+$", "")
  local prefix = nil
  local hex = name:match("^DR%s+([A-Fa-f0-9]+)$")
  if hex then
    prefix = "DR"
  else
    hex = name:match("^QT%s+([A-Fa-f0-9]+)$")
    if hex then
      prefix = "QT"
    end
  end
  if prefix and hex and (#hex == 7 or #hex == 8) then
    return prefix .. " " .. hex:upper()
  end
  return name
end

--- Complete/Short Local Name from raw ADV when input.device_name is empty or mismatched.
local function name_from_raw_adv(raw)
  local h = hex.norm(raw)
  if h == "" then
    return ""
  end
  return normalize_device_name(hex.to_ascii(adv.find(h, 0x09)[1] or adv.find(h, 0x08)[1] or ""))
end

local function unit_name(n)
  return UNIT_TYPES[n] or string.format("UnitType_%d", n)
end

local function mode_name(n)
  return MODES[n] or string.format("Mode_%d", n)
end

local function fmt_bool(v)
  return v and "true" or "false"
end

local function fmt_num(n, digits)
  if n == nil then
    return ""
  end
  if digits then
    return string.format("%." .. digits .. "f", n)
  end
  return tostring(n)
end

--- Reconstruct full MSD hex (company id LE + payload) candidates from manufacturer_data.
local function msd_candidates_from_mfg(mfg)
  local out = {}
  local seen = {}
  local function add(cid, msd_hex)
    if not msd_hex or #msd_hex < MIN_MSD * 2 or seen[msd_hex] then
      return
    end
    seen[msd_hex] = true
    out[#out + 1] = {
      company_id = cid or "",
      msd_hex = msd_hex,
    }
  end
  if type(mfg) ~= "table" then
    return out
  end
  for cid, payload in pairs(mfg) do
    local cid_s = cid
    if type(cid) == "number" then
      cid_s = string.format("%04X", math.floor(cid) % 65536)
    elseif type(cid) ~= "string" then
      cid_s = nil
    end
    if type(cid_s) == "string" and #cid_s == 4 and type(payload) == "string" then
      local p = hex.norm(payload)
      -- Prefer hex payloads; skip obvious binary blobs.
      if p:match("^[0-9a-f]+$") and (#p % 2 == 0) then
        local lo = cid_s:sub(3, 4):lower()
        local hi = cid_s:sub(1, 2):lower()
        add(cid_s:upper(), lo .. hi .. p)
        -- Some hosts leave company bytes inside the payload.
        if #p >= MIN_MSD * 2 then
          add(cid_s:upper(), p)
        end
      end
    end
  end
  return out
end

--- Extract all AD type 0xFF payloads from raw advertising hex (includes company id bytes).
local function msd_from_raw(raw)
  local out = {}
  local h = hex.norm(raw)
  if h == "" then
    return out
  end
  local found = adv.find(h, 0xFF)
  for i = 1, #found do
    local data = found[i]
    if type(data) == "string" and #data >= MIN_MSD * 2 then
      local cid = ""
      if #data >= 4 then
        cid = (data:sub(3, 4) .. data:sub(1, 2)):upper()
      end
      out[#out + 1] = { company_id = cid, msd_hex = data }
    end
  end
  return out
end

local function utf8_from_masked(hex, start1, count, mask)
  local chars = {}
  for i = 0, count - 1 do
    local b = bits.byte_at(hex, start1 + i)
    if mask then
      b = bits.band(b, mask)
    end
    if b < 32 or b > 126 then
      chars[#chars + 1] = "?"
    else
      chars[#chars + 1] = string.char(b)
    end
  end
  return table.concat(chars)
end

local function utf8_raw(hex, start1, count)
  return utf8_from_masked(hex, start1, count, nil)
end

--- DecodeVinTypeAndModes at 0-based byte offset into full MSD hex.
local function decode_vin_type_modes(msd_hex, offset0, name)
  local start1 = offset0 + 1
  if #msd_hex < (offset0 + 5) * 2 then
    return nil, "msd_too_short_for_vin_block"
  end

  local b0 = bits.byte_at(msd_hex, start1)
  local b1 = bits.byte_at(msd_hex, start1 + 1)
  local b2 = bits.byte_at(msd_hex, start1 + 2)
  local b3 = bits.byte_at(msd_hex, start1 + 3)
  local b4 = bits.byte_at(msd_hex, start1 + 4)

  local ut_raw = bits.bor(
    bits.rshift(bits.band(b0, 0xC0), 6),
    bits.lshift(bits.rshift(bits.band(b1, 0xC0), 6), 2)
  )
  if ut_raw == 0 then
    if is_old_serial(name) then
      ut_raw = 256
    else
      return nil, "invalid_unit_type"
    end
  end
  local unit_type = ut_raw - 1

  local mode_raw = bits.rshift(bits.band(b2, 0xC0), 6)
      + bits.rshift(bits.band(b3, 0x40), 4)
  local mode
  if mode_raw == 0 then
    mode = 255
  else
    mode = mode_raw - 1
  end

  local armed = bits.band(b3, 0x80) ~= 0
  local snow = bits.band(b4, 0x40) ~= 0
  local elite = bits.band(b4, 0x80) ~= 0
  local vin = utf8_from_masked(msd_hex, start1, 5, 0x3F)

  return {
    vin = vin,
    unit_type = unit_type,
    unit_type_name = unit_name(unit_type),
    mode = mode,
    mode_name = mode_name(mode),
    armed = armed,
    snow_mode = snow,
    elite_mode = elite,
  }
end

local function decode_old_position(msd_hex, start0)
  if #msd_hex < (start0 + 6) * 2 then
    return nil
  end
  local s = start0 + 1
  local lat_u24 = bits.byte_at(msd_hex, s)
      + bits.byte_at(msd_hex, s + 1) * 256
      + bits.byte_at(msd_hex, s + 2) * 65536
  local lon_u24 = bits.byte_at(msd_hex, s + 3)
      + bits.byte_at(msd_hex, s + 4) * 256
      + bits.byte_at(msd_hex, s + 5) * 65536
  local lat = lat_u24 / 10000.0 - 90.0
  local lon = lon_u24 / 10000.0 - 180.0
  if lat == 0 and lon == 0 then
    return nil
  end
  return { lat = lat, lon = lon }
end

--- Extended-new 20-bit lat/lon packing (NA window).
local function decode_new_location(msd_hex, start0)
  if #msd_hex < (start0 + 5) * 2 then
    return nil
  end
  local s = start0 + 1
  local b0 = bits.byte_at(msd_hex, s)
  local b1 = bits.byte_at(msd_hex, s + 1)
  local b2 = bits.byte_at(msd_hex, s + 2)
  local b3 = bits.byte_at(msd_hex, s + 3)
  local b4 = bits.byte_at(msd_hex, s + 4)
  local lat20 = bits.bor(
    bits.lshift(b0, 12),
    bits.bor(bits.lshift(b1, 4), bits.rshift(b2, 4))
  )
  local lon20 = bits.bor(
    bits.lshift(bits.band(b2, 0x0F), 16),
    bits.bor(bits.lshift(b3, 8), b4)
  )
  local lat = lat20 / 1048575.0 * 25.0 + 24.5
  local lon = lon20 / 1048575.0 * 58.1 - 125.0
  return { lat = lat, lon = lon }
end

local function name_from_extended_msd(msd_hex)
  local prefix = utf8_raw(msd_hex, 1, 3)
  local name_len = 13
  if prefix == "QT " or prefix == "DR " then
    name_len = 11
  end
  if #msd_hex < name_len * 2 then
    return nil
  end
  return utf8_raw(msd_hex, 1, name_len):gsub("%z", ""):gsub("%s+$", "")
end

local function decode_old(msd_hex, name)
  local n = #msd_hex / 2
  if n < MIN_MSD or n == EXT_LEN then
    return nil
  end
  local core, err = decode_vin_type_modes(msd_hex, 0, name)
  if not core then
    return nil, err
  end
  local out = {
    adv_format = "old",
    vin = core.vin,
    unit_type = tostring(core.unit_type),
    unit_type_name = core.unit_type_name,
    mode = tostring(core.mode),
    mode_name = core.mode_name,
    armed = fmt_bool(core.armed),
    snow_mode = fmt_bool(core.snow_mode),
    elite_mode = fmt_bool(core.elite_mode),
    debug_mode = "false",
    encrypted = "false",
  }
  if n > 5 then
    local vbat = bits.byte_at(msd_hex, 6) * VBAT_K
    out.vbat = fmt_num(vbat, 2)
    out.vbat_raw = tostring(bits.byte_at(msd_hex, 6))
  end
  if n >= 12 then
    local pos = decode_old_position(msd_hex, 6)
    if pos then
      out.latitude = fmt_num(pos.lat, 5)
      out.longitude = fmt_num(pos.lon, 5)
    end
  end
  return out
end

local function decode_extended_old(msd_hex, name)
  local core, err = decode_vin_type_modes(msd_hex, 13, name)
  if not core then
    return nil, err
  end
  local n = #msd_hex / 2
  local out = {
    adv_format = "extended_old",
    vin = core.vin,
    unit_type = tostring(core.unit_type),
    unit_type_name = core.unit_type_name,
    mode = tostring(core.mode),
    mode_name = core.mode_name,
    armed = fmt_bool(core.armed),
    snow_mode = fmt_bool(core.snow_mode),
    elite_mode = fmt_bool(core.elite_mode),
  }
  if n > 18 then
    out.vbat = fmt_num(bits.byte_at(msd_hex, 19) * VBAT_K, 2)
    out.vbat_raw = tostring(bits.byte_at(msd_hex, 19))
  end
  if n >= 25 then
    local pos = decode_old_position(msd_hex, 19)
    if pos then
      out.latitude = fmt_num(pos.lat, 5)
      out.longitude = fmt_num(pos.lon, 5)
    end
  end
  if n == EXT_LEN then
    local flags = bits.byte_at(msd_hex, 26)
    out.debug_mode = fmt_bool(bits.band(flags, 0x01) ~= 0)
    out.encrypted = fmt_bool(bits.band(flags, 0x02) ~= 0)
    out.flags_byte = string.format("%02X", flags)
  else
    out.debug_mode = "false"
    out.encrypted = "false"
  end
  return out
end

local function decode_extended_new(msd_hex)
  local n = #msd_hex / 2
  if n < 26 then
    return nil, "extended_new_too_short"
  end
  local unit_type = bits.byte_at(msd_hex, 14) - 1
  local vin = utf8_raw(msd_hex, 15, 4)
  local vbat_raw = bits.byte_at(msd_hex, 19)
  local mode_byte = bits.byte_at(msd_hex, 25)
  local flags = bits.byte_at(msd_hex, 26)
  local mode = bits.band(mode_byte, 0x07)
  local armed = bits.band(mode_byte, 0x08) ~= 0
  -- Intended bit layout from firmware/app fields (Snow/Elite/Debug/Encrypted).
  local snow = bits.band(flags, 0x01) ~= 0
  local elite = bits.band(flags, 0x02) ~= 0
  local debug = bits.band(flags, 0x04) ~= 0
  local encrypted = bits.band(flags, 0x08) ~= 0
  local pos = decode_new_location(msd_hex, 19)
  local out = {
    adv_format = "extended_new",
    vin = vin,
    unit_type = tostring(unit_type),
    unit_type_name = unit_name(unit_type),
    mode = tostring(mode),
    mode_name = mode_name(mode),
    armed = fmt_bool(armed),
    snow_mode = fmt_bool(snow),
    elite_mode = fmt_bool(elite),
    debug_mode = fmt_bool(debug),
    encrypted = fmt_bool(encrypted),
    vbat = fmt_num(vbat_raw * VBAT_K, 2),
    vbat_raw = tostring(vbat_raw),
    mode_byte = string.format("%02X", mode_byte),
    flags_byte = string.format("%02X", flags),
  }
  if pos then
    out.latitude = fmt_num(pos.lat, 5)
    out.longitude = fmt_num(pos.lon, 5)
  end
  return out
end

local function decode_extended(msd_hex, gap_name)
  local n = #msd_hex / 2
  if n ~= EXT_LEN then
    return nil
  end
  local msd_name = name_from_extended_msd(msd_hex) or ""
  local name = gap_name
  if not valid_device_name(name) and valid_device_name(msd_name) then
    name = msd_name
  end
  if name == "" then
    name = msd_name
  end

  local selector = bits.byte_at(msd_hex, 14)
  local decoded, err
  if selector >= 0x30 then
    decoded, err = decode_extended_old(msd_hex, name)
  else
    decoded, err = decode_extended_new(msd_hex)
  end
  if not decoded then
    return nil, err
  end
  decoded.msd_name = msd_name
  decoded.name = name
  return decoded
end

local function try_decode(msd_hex, name)
  msd_hex = hex.norm(msd_hex)
  local n = #msd_hex / 2
  if n < MIN_MSD then
    return nil, "msd_too_short"
  end
  if n == EXT_LEN then
    return decode_extended(msd_hex, name)
  end
  return decode_old(msd_hex, name)
end

local function collect_msd(input)
  local list = {}
  local seen = {}
  local function add_all(items)
    for _, item in ipairs(items) do
      local key = item.msd_hex
      if key and not seen[key] then
        seen[key] = true
        list[#list + 1] = item
      end
    end
  end
  add_all(msd_from_raw(input.raw_adv_hex or input.adv_data_hex_combined or input.adv_data_hex or ""))
  add_all(msd_candidates_from_mfg(input.manufacturer_data))
  return list
end

local function build_display_info(attrs)
  local parts = {}
  if attrs.unit_type_name and attrs.unit_type_name ~= "" then
    parts[#parts + 1] = attrs.unit_type_name
  end
  if attrs.mode_name and attrs.mode_name ~= "" then
    parts[#parts + 1] = attrs.mode_name
  end
  if attrs.armed == "true" then
    parts[#parts + 1] = "armed"
  end
  if attrs.snow_mode == "true" then
    parts[#parts + 1] = "snow"
  end
  if attrs.elite_mode == "true" then
    parts[#parts + 1] = "elite"
  end
  if attrs.encrypted == "true" then
    parts[#parts + 1] = "enc"
  end
  if attrs.vbat and attrs.vbat ~= "" then
    parts[#parts + 1] = attrs.vbat .. "V"
  end
  if attrs.vin and attrs.vin ~= "" then
    parts[#parts + 1] = "VIN " .. attrs.vin
  end
  return table.concat(parts, " · ")
end

-- Accept fingerprint only with QT/DR identity (GAP or MSD-embedded), not bare 13-char VIN-like names.
local function has_qt_dr_identity(name, msd_name, company_id, adv_format)
  if is_old_serial(name) or is_old_serial(msd_name) then
    return true
  end
  -- Extended ads use company id bytes ASCII "QT"/"DR".
  if company_id == "5451" or company_id == "5244" then
    return true
  end
  if type(adv_format) == "string" and adv_format:sub(1, 8) == "extended" then
    if is_old_serial(msd_name) or is_new_serial(msd_name) then
      return true
    end
  end
  return false
end

local function name_only_result(name)
  return {
    {
      id = ENTRY_ID,
      display_name = "KARR",
      attributes = {
        protocol = PROTOCOL,
        device_name = name,
        adv_format = "name_only",
        msd_present = "false",
        parsed_protocol = name,
      },
    },
  }, {
    device_type = "VEHICLE",
    custom_icon = "assets/KARR.svg",
    display_name = "KARR",
    display_info = name,
  }
end

local function success_result(attrs, display_info)
  attrs.parsed_protocol = display_info
  return {
    {
      id = ENTRY_ID,
      display_name = "KARR",
      attributes = attrs,
    },
  }, {
    device_type = "VEHICLE",
    custom_icon = "assets/KARR.svg",
    display_name = "KARR",
    display_info = display_info,
  }
end

function parse(input)
  input = input or {}
  local raw = input.raw_adv_hex or input.adv_data_hex_combined or input.adv_data_hex or ""
  local name = normalize_device_name(input.device_name or "")
  if name == "" then
    name = name_from_raw_adv(raw)
  elseif not is_old_serial(name) then
    -- Prefer QT/DR name embedded in ADV when GAP name is non-serial junk.
    local from_raw = name_from_raw_adv(raw)
    if is_old_serial(from_raw) then
      name = from_raw
    end
  end

  local candidates = collect_msd(input)
  if #candidates == 0 then
    -- Name-only: QT/DR serials only (never bare 13-char Crockford — VIN false positives).
    if is_old_serial(name) then
      return name_only_result(name)
    end
    return empty()
  end

  for _, cand in ipairs(candidates) do
    local decoded = try_decode(cand.msd_hex, name)
    if decoded then
      local device_name = decoded.name or name
      if device_name == "" then
        device_name = decoded.msd_name or name
      end
      device_name = normalize_device_name(device_name)
      -- Prefer GAP name when valid QT/DR; else MSD-embedded name.
      if not is_old_serial(device_name) and is_old_serial(name) then
        device_name = name
      end
      if not is_old_serial(device_name) and decoded.msd_name and is_old_serial(decoded.msd_name) then
        device_name = normalize_device_name(decoded.msd_name)
      end
      -- Reject VIN-like names (e.g. WBB5BP1116689) without QT/DR identity.
      if has_qt_dr_identity(name, decoded.msd_name or device_name, cand.company_id, decoded.adv_format) then
        local attrs = {
          protocol = PROTOCOL,
          device_name = device_name,
          company_id = cand.company_id or "",
          msd_hex = cand.msd_hex,
          msd_len = tostring(math.floor(#cand.msd_hex / 2)),
          msd_present = "true",
          adv_format = decoded.adv_format,
          vin = decoded.vin or "",
          unit_type = tostring(decoded.unit_type or ""),
          unit_type_name = decoded.unit_type_name or "",
          mode = tostring(decoded.mode or ""),
          mode_name = decoded.mode_name or "",
          armed = decoded.armed or "false",
          snow_mode = decoded.snow_mode or "false",
          elite_mode = decoded.elite_mode or "false",
          debug_mode = decoded.debug_mode or "false",
          encrypted = decoded.encrypted or "false",
          vbat = decoded.vbat or "",
          vbat_raw = decoded.vbat_raw or "",
          latitude = decoded.latitude or "",
          longitude = decoded.longitude or "",
          flags_byte = decoded.flags_byte or "",
          mode_byte = decoded.mode_byte or "",
          msd_name = decoded.msd_name or "",
        }

        local display_info = build_display_info(attrs)
        if device_name ~= "" then
          display_info = device_name .. " · " .. display_info
        end

        return success_result(attrs, display_info)
      end
    end
  end

  -- MSD present but rejected/failed: still surface QT/DR name instead of icon-only empty decode.
  if is_old_serial(name) then
    return name_only_result(name)
  end
  return empty()
end
