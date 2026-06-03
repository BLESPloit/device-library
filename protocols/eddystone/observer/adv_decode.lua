-- Eddystone observer: decodes FEAA service data frames (UID, URL, TLM, EID).
-- Spec: https://github.com/google/eddystone/blob/master/protocol-specification.md
-- URL expansion follows google/eddystone URL frame (same mapping as beacon_utils UrlUtils.kt).
-- Decode from payload hex + bits.byte_at (clear and robust). hex_to_bin now returns raw octets
-- via LuaValue.valueOf(byte[]), so string.byte on binary would also be safe if needed.

local EDDYSTONE_FULL_PREFIX = "0000feaa"

local URI_SCHEMES = {
  [0] = "http://www.",
  [1] = "https://www.",
  [2] = "http://",
  [3] = "https://",
  [4] = "urn:uuid:",
}

local URL_CODES = {
  [0] = ".com/", [1] = ".org/", [2] = ".edu/", [3] = ".net/", [4] = ".info/",
  [5] = ".biz/", [6] = ".gov/", [7] = ".com", [8] = ".org", [9] = ".edu",
  [10] = ".net", [11] = ".info", [12] = ".biz", [13] = ".gov",
}

local function norm_hex(h)
  if not h or type(h) ~= "string" then
    return ""
  end
  return h:gsub("%s+", ""):lower()
end

local function byte_at_raw(raw, j)
  local s = j * 2 + 1
  return tonumber(raw:sub(s, s + 1), 16)
end

local function extract_feaa_service_data_hex(raw_hex)
  local raw = norm_hex(raw_hex)
  if #raw < 6 or #raw % 2 ~= 0 then
    return nil
  end
  local nbytes = #raw / 2
  local k = 0
  while k < nbytes do
    local blen = byte_at_raw(raw, k)
    if not blen or blen < 1 then
      break
    end
    k = k + 1
    if k >= nbytes then
      break
    end
    local typ = byte_at_raw(raw, k)
    k = k + 1
    local data_len = blen - 1
    if data_len < 0 or k + data_len > nbytes then
      break
    end
    if typ == 0x16 and data_len >= 2 then
      local u0 = byte_at_raw(raw, k)
      local u1 = byte_at_raw(raw, k + 1)
      if u0 == 0xAA and u1 == 0xFE and data_len > 2 then
        local inner_b0 = k + 2
        local inner_len = data_len - 2
        local hstart = inner_b0 * 2 + 1
        return raw:sub(hstart, hstart + inner_len * 2 - 1)
      end
    end
    k = k + data_len
  end
  return nil
end

local function strip_feaa_prefix_hex(h)
  if not h or #h < 4 then
    return h
  end
  if h:sub(1, 4) == "aafe" or h:sub(1, 4) == "feaa" then
    return h:sub(5)
  end
  return h
end

--- Signed int8 from AD payload hex, 1-based byte index (same as bits.byte_at).
local function s8_hex(h, i)
  local b = bits.byte_at(h, i)
  return bits.arshift(bits.lshift(b, 24), 24)
end

local function be16_hex(h, i)
  local hi = bits.byte_at(h, i)
  local lo = bits.byte_at(h, i + 1)
  return hi * 256 + lo
end

local function be32_hex(h, i)
  local a = bits.byte_at(h, i)
  local b = bits.byte_at(h, i + 1)
  local c = bits.byte_at(h, i + 2)
  local d = bits.byte_at(h, i + 3)
  return ((a * 256 + b) * 256 + c) * 256 + d
end

--- 16 raw bytes starting at 1-based byte index [start_byte] -> UUID string.
local function decode_urn_uuid_hex(payload_hex, start_byte, nbytes)
  if nbytes < start_byte + 15 then
    return nil
  end
  local s = (start_byte - 1) * 2 + 1
  local hl = payload_hex:sub(s, s + 31):lower()
  if #hl < 32 then
    return nil
  end
  return string.format("%s-%s-%s-%s-%s", hl:sub(1, 8), hl:sub(9, 12), hl:sub(13, 16), hl:sub(17, 20), hl:sub(21, 32))
end

local function decode_eddystone_url_hex(payload_hex, nbytes)
  if nbytes < 3 then
    return nil
  end
  local off = 3
  local scheme_code = bits.byte_at(payload_hex, off)
  off = off + 1
  local scheme = URI_SCHEMES[scheme_code]
  if not scheme then
    return nil
  end
  local url = scheme
  if scheme == "urn:uuid:" then
    local uuid = decode_urn_uuid_hex(payload_hex, off, nbytes)
    if not uuid then
      return nil
    end
    return url .. uuid
  end
  while off <= nbytes do
    local b = bits.byte_at(payload_hex, off)
    off = off + 1
    local code = URL_CODES[b]
    if code then
      url = url .. code
    else
      url = url .. string.char(b)
    end
  end
  return url
end

local function find_feaa_hex(service_data)
  if not service_data or type(service_data) ~= "table" then
    return nil
  end
  for k, v in pairs(service_data) do
    local ks = type(k) == "string" and k or tostring(k)
    if type(v) == "string" then
      local compact = ks:lower():gsub("%-", "")
      if compact:sub(1, #EDDYSTONE_FULL_PREFIX) == EDDYSTONE_FULL_PREFIX then
        return v:gsub("%s+", ""):lower()
      end
    end
  end
  return nil
end

local function resolve_feaa_payload_hex(input)
  local h = find_feaa_hex(input.service_data)
  if h and #h >= 2 then
    return strip_feaa_prefix_hex(norm_hex(h)), "service_data"
  end
  h = extract_feaa_service_data_hex(input.raw_adv_hex)
  if h and #h >= 2 then
    return norm_hex(h), "raw_adv_hex"
  end
  h = extract_feaa_service_data_hex(input.adv_data_hex_combined)
  if h and #h >= 2 then
    return norm_hex(h), "adv_data_hex_combined"
  end
  return nil, "none"
end

function parse(input)
  local entries = {}
  local payload_hex, resolve_src = resolve_feaa_payload_hex(input)
  if not payload_hex or #payload_hex < 2 or #payload_hex % 2 ~= 0 then
    return entries
  end

  local nbytes = #payload_hex / 2

  local b0 = bits.byte_at(payload_hex, 1)
  local frame_hi = bits.rshift(b0, 4)
  local frame_lo = bits.band(b0, 0x0F)
  if frame_lo ~= 0 then
    return entries
  end

  local attrs = { frame_byte = bits.tohex(b0, 2) }
  local display_suffix = "Eddystone"
  local id_suffix = "eddystone"

  if frame_hi == 0 then
    if nbytes < 20 then
      return entries
    end
    id_suffix = "eddystone_uid"
    display_suffix = "Eddystone-UID"
    attrs.frame_type = "UID"
    attrs.tx_power = s8_hex(payload_hex, 2)
    attrs.namespace_hex = payload_hex:sub(5, 24):lower()
    attrs.instance_hex = payload_hex:sub(25, 36):lower()
    attrs.uid_hex = attrs.namespace_hex .. attrs.instance_hex
    attrs.rfu_hex = payload_hex:sub(37, 40):lower()
  elseif frame_hi == 1 then
    if nbytes < 3 then
      return entries
    end
    id_suffix = "eddystone_url"
    display_suffix = "Eddystone-URL"
    attrs.frame_type = "URL"
    attrs.tx_power = s8_hex(payload_hex, 2)
    attrs.url = decode_eddystone_url_hex(payload_hex, nbytes) or ""
  elseif frame_hi == 2 then
    if nbytes < 14 then
      return entries
    end
    id_suffix = "eddystone_tlm"
    display_suffix = "Eddystone-TLM"
    attrs.frame_type = "TLM"
    attrs.tlm_version = bits.byte_at(payload_hex, 2)
    attrs.battery_mv = be16_hex(payload_hex, 3)
    local ti = s8_hex(payload_hex, 5)
    local tf = bits.byte_at(payload_hex, 6)
    if ti == -128 and tf == 0 then
      attrs.temperature_c = "unsupported"
    else
      attrs.temperature_c = ti + tf / 256.0
    end
    attrs.adv_count = be32_hex(payload_hex, 7)
    local uptime_ds = be32_hex(payload_hex, 11)
    attrs.time_since_boot_ds = uptime_ds
    attrs.time_since_boot_s = uptime_ds / 10.0
    if nbytes >= 20 then
      attrs.rfu_hex = payload_hex:sub(29, 40):lower()
    end
  elseif frame_hi == 3 then
    id_suffix = "eddystone_eid"
    display_suffix = "Eddystone-EID"
    attrs.frame_type = "EID"
    if nbytes >= 17 then
      attrs.eid_hex = payload_hex:sub(3, 34):lower()
    end
  elseif frame_hi == 4 then
    attrs.frame_type = "RESERVED"
    attrs.raw_service_data_hex = payload_hex
  else
    attrs.frame_type = "UNKNOWN"
    attrs.frame_nibble = frame_hi
    attrs.raw_service_data_hex = payload_hex
  end

  entries[1] = {
    id = id_suffix,
    display_name = display_suffix,
    attributes = attrs,
  }

  local ui = {
    device_type = "BEACON",
    beacon_format = "EDDYSTONE",
    custom_icon = "assets/eddystone.svg",
    display_name = display_suffix,
  }
  return entries, ui
end
