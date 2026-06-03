-- Google Fast Pair (BLE provider advertising Service Data UUID 16-bit FE2C).
-- Provider: https://developers.google.com/nearby/fast-pair/specifications/service/provider
-- Optional battery TLV (account ads): https://developers.google.com/nearby/fast-pair/specifications/extensions/batterynotification

local function norm_hex(h)
  if not h or type(h) ~= "string" then
    return ""
  end
  return h:gsub("%s+", ""):lower()
end

local function is_fe2c_service_data_key(uuid_key)
  if not uuid_key or type(uuid_key) ~= "string" then
    return false
  end
  local n = uuid_key:gsub("-", ""):lower()
  if n:sub(1, 8) == "0000fe2c" then
    return true
  end
  if n:match("^00000000%-fe2c%-") then
    return true
  end
  return false
end

local function find_fe2c_payload_hex(service_data)
  if not service_data or type(service_data) ~= "table" then
    return nil
  end
  local best_len = -1
  local best_hex = nil
  for k, v in pairs(service_data) do
    if is_fe2c_service_data_key(tostring(k)) and type(v) == "string" then
      local h = norm_hex(v)
      if #h >= 6 and #h % 2 == 0 and #h > best_len then
        best_len = #h
        best_hex = h
      end
    end
  end
  return best_hex
end

local function be_uint24_at(h)
  return bits.byte_at(h, 1) * 65536 + bits.byte_at(h, 2) * 256 + bits.byte_at(h, 3)
end

--- Big-endian uint24 starting at 1-based byte index [i] within hex payload h.
local function be_uint24_at_byte_index(h, i)
  return bits.byte_at(h, i) * 65536 + bits.byte_at(h, i + 1) * 256 + bits.byte_at(h, i + 2)
end

--- Decode one Fast Pair battery octet: 0bSVVVVVVV (S=charging, V=0–100; V=127 → unknown).
local function decode_fp_battery_octet(oct)
  local charging = math.floor(oct / 128) % 2 == 1
  local v7 = oct % 128
  if v7 == 127 then
    return charging, nil, true
  end
  return charging, v7, false
end

--- Best-effort parse of Account Advertising payload after octet 0 (version_flags).
-- Account Key Data, Salt TLV, then optional Battery Notification extension.
-- Battery: https://developers.google.com/nearby/fast-pair/specifications/extensions/batterynotification
local function enrich_account_adv(attrs, h, nbytes)
  if nbytes < 2 then
    return
  end
  local hdr = bits.byte_at(h, 2)
  local filter_len = math.floor(hdr / 16) % 16
  local filter_type = hdr % 16
  attrs.account_first_header = hdr
  attrs.account_filter_len_octets = filter_len
  attrs.account_filter_type_low_nibble = filter_type

  local end_after_filter = 2 + filter_len
  if end_after_filter > nbytes then
    attrs.account_key_parse_truncated = true
    return
  end

  attrs.account_key_filter_hex = h:sub(5, 4 + filter_len * 2)

  -- Filter occupies bytes 3 .. (L+2); salt TLV header follows at byte L+3.
  local salt_hdr_pos = 3 + filter_len
  local salt_hdr = bits.byte_at(h, salt_hdr_pos)
  attrs.salt_field_header_octet = salt_hdr
  local salt_ty = salt_hdr % 16
  local salt_len = math.floor(salt_hdr / 16) % 16
  attrs.salt_value_type_nibble = salt_ty
  attrs.salt_value_len_nibble = salt_len

  if salt_ty == 1 and salt_len == 2 then
    local salt_end = salt_hdr_pos + salt_len
    if salt_end <= nbytes then
      local b0 = bits.byte_at(h, salt_hdr_pos + 1)
      local b1 = bits.byte_at(h, salt_hdr_pos + 2)
      attrs.salt_hex = string.format("%02x%02x", b0, b1)
    end
  end

  if salt_hdr_pos + salt_len > nbytes then
    attrs.account_key_parse_truncated = true
    return
  end

  -- First byte after salt TLV = optional battery header (Battery Notification extension).
  local after_salt = salt_hdr_pos + 1 + salt_len
  if after_salt > nbytes then
    return
  end

  local bat_hdr = bits.byte_at(h, after_salt)
  local num_bat = math.floor(bat_hdr / 16) % 16
  local bat_ty = bat_hdr % 16
  attrs.fp_battery_header_octet = bat_hdr
  attrs.fp_battery_value_count_nibble = num_bat
  attrs.fp_battery_type_low_nibble = bat_ty
  -- Type 0b0011 = show UI; 0b0100 = hide indication (Battery Notification spec).
  attrs.fp_battery_show_ui_indication = (bat_ty == 3)
  attrs.fp_battery_hide_ui_indication = (bat_ty == 4)

  local need = after_salt + num_bat
  if need > nbytes then
    attrs.fp_battery_parse_truncated = true
    return
  end

  local bat_hex_start = (after_salt - 1) * 2 + 1
  attrs.fp_battery_section_hex = h:sub(bat_hex_start, bat_hex_start + (1 + num_bat) * 2 - 1)

  local labels = { "left", "right", "case" }
  for i = 1, num_bat do
    local b = bits.byte_at(h, after_salt + i)
    local chg, pct, unk = decode_fp_battery_octet(b)
    local label = labels[i] or ("idx_" .. tostring(i))
    attrs["fp_battery_" .. label .. "_charging"] = chg
    if unk then
      attrs["fp_battery_" .. label .. "_percent"] = nil
      attrs["fp_battery_" .. label .. "_unknown"] = true
    else
      attrs["fp_battery_" .. label .. "_percent"] = pct
    end
  end
end

--- Short human line from attrs written by enrich_account_adv (left / right / case).
local function fp_battery_display_suffix(attrs)
  local segments = {}
  local order = {
    { "left", "L" },
    { "right", "R" },
    { "case", "Case" },
  }
  for _, row in ipairs(order) do
    local suf, label = row[1], row[2]
    local pct = attrs["fp_battery_" .. suf .. "_percent"]
    local unk = attrs["fp_battery_" .. suf .. "_unknown"]
    local chg = attrs["fp_battery_" .. suf .. "_charging"]
    if unk then
      table.insert(segments, label .. " ?")
    elseif type(pct) == "number" then
      local s = label .. " " .. tostring(pct) .. "%"
      if chg then
        s = s .. "+"
      end
      table.insert(segments, s)
    end
  end
  if #segments == 0 then
    return nil
  end
  return table.concat(segments, " · ")
end

function parse(input)
  local entries = {}
  local ui = {
    device_type = "FAST_PAIR",
    custom_icon = "assets/fast_pair_logo.svg"
  }

  local h = find_fe2c_payload_hex(input.service_data)
  if not h or #h % 2 ~= 0 then
    return entries, ui
  end

  local nbytes = #h / 2
  local attrs = {
    fp_service_data_hex = h,
    fp_payload_octets = nbytes,
  }

  if nbytes == 3 then
    local mid = be_uint24_at(h)
    attrs.fp_advert_kind = "model_id_discoverable"
    attrs.fast_pair_model_id_uint24 = mid
    attrs.fast_pair_model_id_hex = string.format("%06x", mid)
    entries[1] = {
      id = "google_fast_pair_model",
      display_name = "Google Fast Pair pairing (model ID)",
      attributes = attrs
    }
    ui.display_info = "Fast Pair, device: " .. attrs.fast_pair_model_id_hex
    return entries, ui
  end

  -- Some providers (e.g. Pixel Buds) use a 7-octet FE2C value: prefix + 24-bit model + suffix.
  -- Example: 00 37 DC DA 99 18 00 -> model octets 3–5 = 0xDCDA99 (big-endian).
  if nbytes == 7 then
    local mid = be_uint24_at_byte_index(h, 3)
    attrs.fp_advert_kind = "model_id_discoverable"
    attrs.fp_model_payload_variant = "7_octet"
    attrs.fast_pair_model_id_uint24 = mid
    attrs.fast_pair_model_id_hex = string.format("%06x", mid)
    entries[1] = {
      id = "google_fast_pair_model",
      display_name = "Google Fast Pair pairing (model ID)",
      attributes = attrs
    }
    ui.display_info = "Fast Pair, device: " .. attrs.fast_pair_model_id_hex
    return entries, ui
  end

  attrs.fp_advert_kind = "fast_pair_account"
  attrs.fp_account_version_octet = bits.byte_at(h, 1)
  enrich_account_adv(attrs, h, nbytes)

  entries[1] = {
    id = "google_fast_pair_account",
    display_name = "Google Fast Pair (account advertisement)",
    attributes = attrs
  }
  local bat = fp_battery_display_suffix(attrs)
  if bat then
    ui.display_info = "Fast Pair · " .. bat
  else
    ui.display_info = "Fast Pair"
  end

  return entries, ui
end
