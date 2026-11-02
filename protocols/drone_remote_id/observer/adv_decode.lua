-- Drone Remote ID observer (ASTM F3411 / ASD-STAN EN 4709-002).
-- Bluetooth transport: AD type 0x16, UUID 0xFFFA little-endian (FA FF),
-- application code 0x0D, 8-bit counter, then a 25-byte message.
-- The counter is its own byte. It is not the message header.
-- https://github.com/opendroneid/opendroneid-core-c

local ASTM_UUID = "0000fffa00001000800000805f9b34fb"

local STANDARDS = {
  [0] = "ASTM F3411-19",
  [1] = "ASD-STAN prEN 4709-002",
  [2] = "ASTM F3411-22a",
}

local MSG_NAMES = {
  [0] = "basic_id",
  [1] = "location",
  [2] = "authentication",
  [3] = "self_id",
  [4] = "system",
  [5] = "operator_id",
  [0xF] = "message_pack",
}

local ID_TYPES = {
  [0] = "None",
  [1] = "Serial Number (ANSI/CTA-2063-A)",
  [2] = "CAA Registration ID",
  [3] = "UTM UUID",
  [4] = "Specific Session ID",
}

local UA_TYPES = {
  [0] = "None",
  [1] = "Aeroplane",
  [2] = "Helicopter/Multirotor",
  [3] = "Gyroplane",
  [4] = "Hybrid Lift",
  [5] = "Ornithopter",
  [6] = "Glider",
  [7] = "Kite",
  [8] = "Free Balloon",
  [9] = "Captive Balloon",
  [10] = "Airship",
  [11] = "Free Fall/Parachute",
  [12] = "Rocket",
  [13] = "Tethered Powered Aircraft",
  [14] = "Ground Obstacle",
  [15] = "Other",
}

local STATUS = {
  [0] = "Undeclared",
  [1] = "Ground",
  [2] = "Airborne",
  [3] = "Emergency",
  [4] = "Remote ID System Failure",
}

local DESC_TYPES = {
  [0] = "Text",
  [1] = "Emergency",
  [2] = "Extended status",
}

local OP_LOC = {
  [0] = "Takeoff",
  [1] = "Live GNSS",
  [2] = "Fixed",
}

local function named(map, n)
  return map[n] or ("Unknown(" .. tostring(n) .. ")")
end

local function s8(h, i)
  return bits.arshift(bits.lshift(bits.byte_at(h, i), 24), 24)
end

local function s32(h, i)
  local u = bits.le32(h, i)
  if u >= 2147483648 then
    return u - 4294967296
  end
  return u
end

local function alt_m(raw)
  if raw == 65535 then
    return nil
  end
  return raw * 0.5 - 1000
end

local function fmt_num(v, fmt)
  if v == nil then
    return "unknown"
  end
  return string.format(fmt, v)
end

local function horiz_speed(raw, mult)
  if raw == 255 then
    return nil
  end
  if mult == 0 then
    return raw * 0.25
  end
  return raw * 0.75 + 63.75
end

local function decode_one(msg)
  if hex.len(msg) < 25 then
    return nil
  end
  local hdr = bits.byte_at(msg, 1)
  local proto = bits.band(hdr, 0x0F)
  local msg_type = bits.rshift(hdr, 4)
  local name = MSG_NAMES[msg_type]
  if not name then
    return nil
  end

  local attrs = {
    proto_version = tostring(proto),
    standard = STANDARDS[proto] or ("Drone Remote ID protocol " .. tostring(proto)),
    message_type = name,
  }
  local summary = name

  if msg_type == 0 then
    local b1 = bits.byte_at(msg, 2)
    local id_type = bits.rshift(b1, 4)
    local ua_type = bits.band(b1, 0x0F)
    local uas_id = hex.to_ascii(hex.slice(msg, 3, 20))
    attrs.id_type = named(ID_TYPES, id_type)
    attrs.id_type_code = tostring(id_type)
    attrs.ua_type = named(UA_TYPES, ua_type)
    attrs.ua_type_code = tostring(ua_type)
    attrs.uas_id = uas_id
    summary = attrs.id_type .. " " .. uas_id .. " · " .. attrs.ua_type
  elseif msg_type == 1 then
    local flags = bits.byte_at(msg, 2)
    local speed_mult = bits.band(flags, 0x01)
    local ew = bits.band(bits.rshift(flags, 1), 0x01)
    local height_agl = bits.band(bits.rshift(flags, 2), 0x01) == 1
    local status = bits.rshift(flags, 4)
    local dir_raw = bits.byte_at(msg, 3)
    local dir = nil
    if dir_raw ~= 255 then
      dir = dir_raw + 180 * ew
    end
    local spd = horiz_speed(bits.byte_at(msg, 4), speed_mult)
    local vspd_raw = s8(msg, 5)
    local vspd = nil
    if vspd_raw ~= -128 then
      vspd = vspd_raw * 0.5
    end
    local lat = s32(msg, 6) / 10000000
    local lon = s32(msg, 10) / 10000000
    attrs.status = named(STATUS, status)
    attrs.latitude = string.format("%.7f", lat)
    attrs.longitude = string.format("%.7f", lon)
    attrs.direction_deg = fmt_num(dir, "%.0f")
    attrs.speed_h_mps = fmt_num(spd, "%.2f")
    attrs.speed_v_mps = fmt_num(vspd, "%.1f")
    attrs.altitude_baro_m = fmt_num(alt_m(bits.le16(msg, 14)), "%.1f")
    attrs.altitude_geo_m = fmt_num(alt_m(bits.le16(msg, 16)), "%.1f")
    attrs.height_m = fmt_num(alt_m(bits.le16(msg, 18)), "%.1f")
    attrs.height_reference = height_agl and "AGL" or "above_takeoff"
    summary = attrs.latitude .. ", " .. attrs.longitude .. " · " .. attrs.status .. " · " .. attrs.speed_h_mps .. " m/s"
  elseif msg_type == 2 then
    local b1 = bits.byte_at(msg, 2)
    attrs.auth_page = tostring(bits.band(b1, 0x0F))
    attrs.auth_type = tostring(bits.rshift(b1, 4))
    if attrs.auth_page == "0" and hex.len(msg) >= 8 then
      attrs.auth_last_page = tostring(bits.byte_at(msg, 3))
      attrs.auth_length = tostring(bits.byte_at(msg, 4))
    end
    summary = "authentication page " .. attrs.auth_page
  elseif msg_type == 3 then
    local desc_type = bits.byte_at(msg, 2)
    attrs.desc_type = named(DESC_TYPES, desc_type)
    attrs.description = hex.to_ascii(hex.slice(msg, 3, 23))
    summary = attrs.desc_type .. " " .. attrs.description
  elseif msg_type == 4 then
    local b1 = bits.byte_at(msg, 2)
    local lat = s32(msg, 3) / 10000000
    local lon = s32(msg, 7) / 10000000
    attrs.operator_location_type = named(OP_LOC, bits.band(b1, 0x03))
    attrs.classification_type = tostring(bits.band(bits.rshift(b1, 2), 0x07))
    attrs.operator_latitude = string.format("%.7f", lat)
    attrs.operator_longitude = string.format("%.7f", lon)
    attrs.area_count = tostring(bits.le16(msg, 11))
    local radius = bits.byte_at(msg, 13)
    attrs.area_radius_m = radius == 255 and "unknown" or tostring(radius * 10)
    attrs.area_ceiling_m = fmt_num(alt_m(bits.le16(msg, 14)), "%.1f")
    attrs.area_floor_m = fmt_num(alt_m(bits.le16(msg, 16)), "%.1f")
    local eu = bits.byte_at(msg, 18)
    attrs.ua_category_eu = tostring(bits.rshift(eu, 4))
    attrs.ua_class_eu = tostring(bits.band(eu, 0x0F))
    attrs.operator_altitude_m = fmt_num(alt_m(bits.le16(msg, 19)), "%.1f")
    summary = "operator " .. attrs.operator_latitude .. ", " .. attrs.operator_longitude
  elseif msg_type == 5 then
    attrs.operator_id_type = tostring(bits.byte_at(msg, 2))
    attrs.operator_id = hex.to_ascii(hex.slice(msg, 3, 20))
    summary = "operator ID " .. attrs.operator_id
  end

  return attrs, summary
end

local function decode_body(body)
  local counter = bits.byte_at(body, 2)
  local msg = hex.slice(body, 3, hex.len(body) - 2)
  local hdr = bits.byte_at(msg, 1)
  local msg_type = bits.rshift(hdr, 4)

  local attrs
  local summary
  if msg_type == 0xF then
    if hex.len(msg) < 3 then
      return nil
    end
    local msg_size = bits.byte_at(msg, 2)
    local count = bits.byte_at(msg, 3)
    if msg_size ~= 25 or count < 1 or count > 9 then
      return nil
    end
    if hex.len(msg) < 3 + count * 25 then
      return nil
    end
    attrs = {
      proto_version = tostring(bits.band(hdr, 0x0F)),
      message_type = "message_pack",
      pack_count = tostring(count),
    }
    attrs.standard = STANDARDS[tonumber(attrs.proto_version)] or ("Drone Remote ID protocol " .. attrs.proto_version)
    local parts = {}
    local n = 0
    while n < count do
      local one_attrs, one_summary = decode_one(hex.slice(msg, 4 + n * 25, 25))
      if one_attrs then
        parts[#parts + 1] = one_summary
        if one_attrs.uas_id and not attrs.uas_id then
          attrs.uas_id = one_attrs.uas_id
          attrs.id_type = one_attrs.id_type
          attrs.ua_type = one_attrs.ua_type
        end
        if one_attrs.latitude and not attrs.latitude then
          attrs.latitude = one_attrs.latitude
          attrs.longitude = one_attrs.longitude
          attrs.status = one_attrs.status
          attrs.speed_h_mps = one_attrs.speed_h_mps
        end
        if one_attrs.operator_id and not attrs.operator_id then
          attrs.operator_id = one_attrs.operator_id
        end
      end
      n = n + 1
    end
    if #parts == 0 then
      return nil
    end
    summary = table.concat(parts, " | ")
  else
    attrs, summary = decode_one(msg)
    if not attrs then
      return nil
    end
  end

  attrs.protocol = "drone_remote_id"
  attrs.app_code = "0d"
  attrs.msg_counter = tostring(counter)
  return attrs, summary
end

local function key_is_astm(k)
  local c = uuid.compact(tostring(k))
  return c == "fffa" or c == ASTM_UUID
end

-- Service-data value is either FAFF + app + counter + message, or app + counter + message.
local function body_from_value(v)
  local h = hex.norm(v)
  if h:sub(1, 4) == "faff" or h:sub(1, 4) == "fffa" then
    h = h:sub(5)
  end
  if hex.len(h) < 27 then
    return nil
  end
  if bits.byte_at(h, 1) ~= 0x0D then
    return nil
  end
  return h
end

local function find_body(input)
  local sd = input.service_data
  if type(sd) == "table" then
    for k, v in pairs(sd) do
      if type(v) == "string" and key_is_astm(k) then
        local body = body_from_value(v)
        if body then
          return body
        end
      end
    end
  end
  local raws = { input.raw_adv_hex, input.adv_data_hex_combined }
  local r = 1
  while raws[r] do
    if type(raws[r]) == "string" and raws[r] ~= "" then
      local found = adv.find(raws[r], 0x16)
      local i = 1
      while found[i] do
        local body = body_from_value(found[i])
        if body then
          return body
        end
        i = i + 1
      end
    end
    r = r + 1
  end
  return nil
end

function parse(input)
  local body = find_body(input)
  if not body then
    return {}, {}
  end
  local attrs, summary = decode_body(body)
  if not attrs then
    return {}, {}
  end
  local title = "Drone Remote ID"
  if attrs.uas_id and attrs.uas_id ~= "" then
    title = attrs.uas_id
  end
  return {
    {
      id = "drone_remote_id",
      display_name = title,
      attributes = attrs,
    },
  }, {
    device_type = "DRONE",
    beacon_format = "DRONE_REMOTE_ID",
    custom_icon = "assets/drone.svg",
    display_name = title,
    display_info = summary,
  }
end
