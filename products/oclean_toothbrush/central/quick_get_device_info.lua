-- Quick action: subscribe bb86, query battery (0303) and device info (030201),
-- decode notify payloads and report battery + language.

local SVC = uuids.OCLEAN_SERVICE
local CHR_WRITE = uuids.OCLEAN_WRITE
local CHR_NOTIFY = uuids.OCLEAN_READ_NOTIFY

local LANGUAGE_NAMES = {
  [1] = "Chinese (Simplified)",
  [2] = "Chinese (Traditional)",
  [3] = "English",
  [4] = "French",
  [5] = "Japanese",
  [6] = "German",
  [7] = "Russian",
  [8] = "Spanish",
  [9] = "Italian",
  [10] = "Hebrew",
  [11] = "Turkish",
  [12] = "Polish",
  [13] = "Arabic",
  [14] = "Korean",
}

local function norm_hex(hex)
  if not hex then
    return nil
  end
  return hex:upper():gsub("%s+", "")
end

local function hex_len(hex)
  return hex and (#hex / 2) or 0
end

local function hex_byte(hex, byte_index)
  local pos = (byte_index - 1) * 2 + 1
  return tonumber(hex:sub(pos, pos + 1), 16)
end

local function hex_bytes_be(hex, from_byte, to_byte)
  local value = 0
  for i = from_byte, to_byte do
    value = (value * 256) + hex_byte(hex, i)
  end
  return value
end

local function split_opcode(full_hex)
  full_hex = norm_hex(full_hex)
  if not full_hex or #full_hex < 4 then
    return nil, nil
  end
  return full_hex:sub(1, 4), full_hex:sub(5)
end

local function ensure_subscribed()
  if gatt_has_characteristic(SVC, CHR_NOTIFY) == false then
    log("oclean: bb86 not present")
    return false
  end
  if not ble_subscribe(SVC, CHR_NOTIFY) then
    log("oclean: subscribe failed")
    return false
  end
  delay_ms(350)
  return true
end

local function cmd_wait(hex, idle_gap_ms)
  start_notify_wait(SVC, CHR_NOTIFY, idle_gap_ms or 0)
  if not ble_write(SVC, CHR_WRITE, hex) then
    return nil
  end
  return finish_notify_wait(SVC, CHR_NOTIFY, 8000)
end

local function strip_info_chunks(raw_hex)
  raw_hex = norm_hex(raw_hex)
  if not raw_hex or raw_hex == "" then
    return nil
  end

  local body = ""
  local pos = 1
  while pos <= #raw_hex do
    if raw_hex:sub(pos, pos + 3) == "0302" then
      pos = pos + 4
    end
    local next_opcode = raw_hex:find("0302", pos, true)
    if next_opcode and next_opcode > pos then
      body = body .. raw_hex:sub(pos, next_opcode - 1)
      pos = next_opcode
    else
      body = body .. raw_hex:sub(pos)
      break
    end
  end
  return body
end

-- Reassemble chunked 0302 body (matches ParseUtils.parseDeviceInfoByte).
-- First fragment: [0]='#' [1]=len_byte [2..]=data; continuations append raw bytes.
local function extract_info_payload(chunk_hex)
  chunk_hex = norm_hex(chunk_hex)
  if not chunk_hex or chunk_hex == "" then
    return nil, nil
  end

  if hex_byte(chunk_hex, 1) ~= 0x23 then
    return chunk_hex, nil
  end

  local len_byte = hex_byte(chunk_hex, 2)
  local total_len = len_byte - 2
  local header = string.format("# %02X → %d data bytes", len_byte, total_len)
  if total_len <= 0 then
    return "", header
  end

  local data_hex = chunk_hex:sub(5)
  if hex_len(data_hex) >= total_len then
    return data_hex:sub(1, total_len * 2), header
  end

  return data_hex, header .. string.format(" (partial %d/%d)", hex_len(data_hex), total_len)
end

local function language_name(num)
  return LANGUAGE_NAMES[num] or string.format("Unknown (%d)", num)
end

local function decode_battery(full_hex)
  local opcode, payload = split_opcode(full_hex)
  if opcode ~= "0303" or not payload then
    return nil, "not a 0303 battery reply"
  end
  if hex_len(payload) < 4 then
    return nil, "0303 payload too short"
  end

  local pct = hex_byte(payload, 4)
  local b0 = hex_byte(payload, 1)
  local b1 = hex_byte(payload, 2)
  local b2 = hex_byte(payload, 3)

  local lines = {
    string.format("0303 battery reply (%d bytes)", hex_len(payload)),
    string.format("  raw payload : %s", payload),
    string.format("  status[0..2]: %02X %02X %02X", b0, b1, b2),
    string.format("  level[3]    : 0x%02X = %d%%", pct, pct),
  }

  if hex_len(payload) >= 6 then
    lines[#lines + 1] = string.format(
      "  extra[4..5] : %02X %02X",
      hex_byte(payload, 5),
      hex_byte(payload, 6)
    )
  end

  return {
    percent = pct,
    status_b0 = b0,
    status_b1 = b1,
    status_b2 = b2,
    payload = payload,
    summary = string.format("Battery %d%%", pct),
    lines = lines,
  }, nil
end

-- Y3 device-info layout (ParseUtils.parseDeviceInfoForDateY3), byte indices 1-based.
local function decode_y3_body(body)
  local n = hex_len(body)
  if n < 32 then
    return nil, string.format("need ≥32 bytes, got %d", n)
  end

  local voice_type = hex_bytes_be(body, 5, 8)
  local voice_open = hex_byte(body, 9) == 0
  local volume = hex_byte(body, 10)
  local calendar_on = hex_byte(body, 11) == 0
  local project_num = hex_byte(body, 12)
  local brush_mode = hex_byte(body, 13)
  local brush_strength = hex_byte(body, 14)
  local brush_session_s = hex_bytes_be(body, 15, 16)
  local clock = {
    year = hex_byte(body, 17) + 2000,
    month = hex_byte(body, 18),
    day = hex_byte(body, 19),
    hour = hex_byte(body, 20),
    min = hex_byte(body, 21),
    sec = hex_byte(body, 22),
  }
  local pressure_mode = hex_byte(body, 23)
  local reminder_mode = hex_byte(body, 24)
  local tz_index = hex_byte(body, 25)
  local brush_max_s = hex_bytes_be(body, 26, 27)
  local head_days = hex_bytes_be(body, 28, 29)
  local head_uses = hex_bytes_be(body, 30, 31)
  local language_num = hex_byte(body, 32)
  local head_wear_pct = 0
  if brush_max_s > 0 and brush_session_s <= brush_max_s then
    head_wear_pct = math.floor(((brush_max_s - brush_session_s) * 100.0) / brush_max_s + 0.5)
  end

  return {
    voice_type = voice_type,
    voice_open = voice_open,
    volume = volume,
    calendar_on = calendar_on,
    project_num = project_num,
    brush_mode = brush_mode,
    brush_strength = brush_strength,
    brush_session_s = brush_session_s,
    brush_max_s = brush_max_s,
    head_days = head_days,
    head_uses = head_uses,
    head_wear_pct = head_wear_pct,
    pressure_mode = pressure_mode,
    reminder_mode = reminder_mode,
    tz_index = tz_index,
    clock = clock,
    language_num = language_num,
    language_name = language_name(language_num),
  }, nil
end

local function decode_device_info(full_hex)
  full_hex = norm_hex(full_hex)
  if not full_hex or full_hex == "" then
    return nil, "empty device info reply"
  end

  local notify_count = 0
  for _ in full_hex:gmatch("0302") do
    notify_count = notify_count + 1
  end

  local chunks = strip_info_chunks(full_hex)
  if not chunks or chunks == "" then
    return nil, "empty device info reply"
  end

  local body, chunk_header = extract_info_payload(chunks)
  if not body or body == "" then
    return nil, "could not extract device info body"
  end

  local byte_count = hex_len(body)
  local lines = {
    string.format(
      "0302 device info (%d B%s)",
      byte_count,
      notify_count > 1 and (", " .. notify_count .. " notifies") or ""
    ),
  }
  if chunk_header then
    lines[#lines + 1] = "  chunk hdr : " .. chunk_header
  end
  lines[#lines + 1] = "  raw body  : " .. body

  if byte_count < 32 then
    return {
      summary = string.format("Device info (%d B, incomplete)", byte_count),
      lines = lines,
      body = body,
      byte_count = byte_count,
      notify_count = notify_count,
      chunk_header = chunk_header,
      language_num = nil,
      language_name = nil,
    }, nil
  end

  local fields, err = decode_y3_body(body)
  if not fields then
    return { summary = "Device info parse error", lines = lines }, err
  end

  local clk = fields.clock
  lines[#lines + 1] = string.format(
    "  voice       : %s, type %d, volume %d",
    fields.voice_open and "on" or "off",
    fields.voice_type,
    fields.volume
  )
  lines[#lines + 1] = string.format(
    "  calendar    : %s, plan #%d",
    fields.calendar_on and "on" or "off",
    fields.project_num
  )
  lines[#lines + 1] = string.format(
    "  brush       : mode %d, strength %d, session %ds / max %ds",
    fields.brush_mode,
    fields.brush_strength,
    fields.brush_session_s,
    fields.brush_max_s
  )
  lines[#lines + 1] = string.format(
    "  brush head  : %d days, %d uses (~%d%% life left)",
    fields.head_days,
    fields.head_uses,
    fields.head_wear_pct
  )
  lines[#lines + 1] = string.format(
    "  device clock: %04d-%02d-%02d %02d:%02d:%02d, tz idx %d",
    clk.year, clk.month, clk.day, clk.hour, clk.min, clk.sec,
    fields.tz_index
  )
  lines[#lines + 1] = string.format(
    "  language[32]: id=%d → %s",
    fields.language_num,
    fields.language_name
  )

  return {
    summary = string.format("Lang %s, mode %d", fields.language_name, fields.brush_mode),
    lines = lines,
    body = body,
    byte_count = byte_count,
    notify_count = notify_count,
    chunk_header = chunk_header,
    fields = fields,
  }, nil
end

local function bool_str(v)
  if v then
    return "1"
  end
  return "0"
end

local function build_fingerprint_attrs(summary, gatt_hex, gatt_pct, bat_hex, info_hex, bat, info)
  local attrs = {
    status_summary = summary,
    battery_notify_hex = bat_hex or "",
    device_info_hex = info_hex or "",
    gatt_battery_hex = gatt_hex or "",
  }

  local pct = (bat and bat.percent) or gatt_pct
  if pct then
    attrs.battery_percent = tostring(pct)
  end
  if gatt_pct then
    attrs.gatt_battery_percent = tostring(gatt_pct)
  end
  if bat and bat.percent then
    attrs.battery_notify_percent = tostring(bat.percent)
  end
  if bat and bat.payload then
    attrs.battery_notify_payload = bat.payload
    if bat.status_b0 then
      attrs.battery_status_b0 = string.format("%02X", bat.status_b0)
      attrs.battery_status_b1 = string.format("%02X", bat.status_b1)
      attrs.battery_status_b2 = string.format("%02X", bat.status_b2)
    end
  end

  if info then
    if info.body then
      attrs.device_info_body_hex = info.body
    end
    if info.byte_count then
      attrs.device_info_byte_count = tostring(info.byte_count)
    end
    if info.notify_count then
      attrs.device_info_notify_count = tostring(info.notify_count)
    end
    if info.chunk_header then
      attrs.device_info_chunk_header = info.chunk_header
    end
    if info.language_num then
      attrs.language_id = tostring(info.language_num)
    end
    if info.language_name then
      attrs.language = info.language_name
    end

    local f = info.fields
    if f then
      attrs.language_id = tostring(f.language_num)
      attrs.language = f.language_name
      attrs.voice_type = tostring(f.voice_type)
      attrs.voice_on = bool_str(f.voice_open)
      attrs.volume = tostring(f.volume)
      attrs.calendar_on = bool_str(f.calendar_on)
      attrs.project_num = tostring(f.project_num)
      attrs.brush_mode = tostring(f.brush_mode)
      attrs.brush_strength = tostring(f.brush_strength)
      attrs.brush_session_s = tostring(f.brush_session_s)
      attrs.brush_max_s = tostring(f.brush_max_s)
      attrs.head_days = tostring(f.head_days)
      attrs.head_uses = tostring(f.head_uses)
      attrs.head_wear_pct = tostring(f.head_wear_pct)
      attrs.pressure_mode = tostring(f.pressure_mode)
      attrs.reminder_mode = tostring(f.reminder_mode)
      attrs.tz_index = tostring(f.tz_index)
      if f.clock then
        local clk = f.clock
        attrs.device_clock = string.format(
          "%04d-%02d-%02d %02d:%02d:%02d",
          clk.year, clk.month, clk.day, clk.hour, clk.min, clk.sec
        )
        attrs.device_clock_year = tostring(clk.year)
        attrs.device_clock_month = tostring(clk.month)
        attrs.device_clock_day = tostring(clk.day)
        attrs.device_clock_hour = tostring(clk.hour)
        attrs.device_clock_min = tostring(clk.min)
        attrs.device_clock_sec = tostring(clk.sec)
      end
    elseif info.brush_mode then
      attrs.brush_mode = tostring(info.brush_mode)
    end
    if info.voice_open ~= nil then
      attrs.voice_on = bool_str(info.voice_open)
    end
    if info.volume then
      attrs.volume = tostring(info.volume)
    end
  end

  return attrs
end

local function explain_notify(label, full_hex)
  if not full_hex or full_hex == "" then
    return { summary = label .. ": no reply", lines = { label .. ": timeout / no notify" } }
  end

  full_hex = norm_hex(full_hex)
  local opcode = full_hex:sub(1, 4)

  if opcode == "0303" then
    local decoded, err = decode_battery(full_hex)
    if decoded then
      decoded.lines[1] = label .. " → " .. decoded.lines[1]
      return decoded
    end
    return { summary = label .. ": parse error", lines = { label .. ": " .. tostring(err), "raw=" .. full_hex } }
  end

  if opcode == "0302" or full_hex:find("0302", 1, true) then
    local decoded, err = decode_device_info(full_hex)
    if decoded then
      decoded.lines[1] = label .. " → " .. decoded.lines[1]
      return decoded
    end
    return { summary = label .. ": parse error", lines = { label .. ": " .. tostring(err), "raw=" .. full_hex } }
  end

  return {
    summary = string.format("%s opcode %s", label, opcode),
    lines = {
      label .. " → opcode " .. opcode,
      "  raw : " .. full_hex,
      "  (unknown opcode — not decoded)",
    },
  }
end

function run()
  if not ble_connected() then
    log("oclean: not connected")
    return
  end
  if not ensure_subscribed() then
    return
  end

  local gatt_hex = norm_hex(ble_read(uuids.BATTERY_SERVICE, uuids.BATTERY_LEVEL))
  local gatt_pct = gatt_hex and tonumber(gatt_hex:sub(1, 2), 16) or nil

  local bat_hex = cmd_wait("0303")
  local info_hex = cmd_wait("030201", 150)

  local bat = explain_notify("0303 battery", bat_hex)
  local info = explain_notify("030201 device info", info_hex)

  local pct = bat.percent or gatt_pct
  local lang = (info.fields and info.fields.language_name) or info.language_name

  local summary_parts = {}
  if pct then
    summary_parts[#summary_parts + 1] = string.format("Battery %d%%", pct)
  end
  if lang then
    summary_parts[#summary_parts + 1] = "Lang " .. lang
  elseif info.summary then
    summary_parts[#summary_parts + 1] = info.summary
  end
  if gatt_pct and not pct then
    summary_parts[#summary_parts + 1] = string.format("GATT batt %d%%", gatt_pct)
  end

  local summary = #summary_parts > 0 and table.concat(summary_parts, " · ") or "Oclean connected"

  log("=== Oclean status ===")
  if gatt_hex then
    log(string.format("GATT 180f/2a19 read: %s (%s)", gatt_hex, gatt_pct and (gatt_pct .. "%") or "?"))
  end
  for _, line in ipairs(bat.lines) do
    log(line)
  end
  for _, line in ipairs(info.lines) do
    log(line)
  end
  log("Summary: " .. summary)

  fp_set("display_info", "Toothbrush · " .. summary)

  local fp_attrs = build_fingerprint_attrs(summary, gatt_hex, gatt_pct, bat_hex, info_hex, bat, info)
  fp_append("oclean_gatt_status", fp_attrs, "Oclean status")

  for key, value in pairs(fp_attrs) do
    if value ~= "" then
      fp_set(key, value)
    end
  end

  gfx_print_text(summary)
end
