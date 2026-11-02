-- Quick action for the connectable Mijia sensors.
-- V2 LYWSD03MMC and V4 MHO-C401: notify ebe0ccc1 (temp 0.01°C, humidity, battery mV).
-- V3 LYWSD02: same notify for temp/humidity, battery percent from ebe0ccc4, clock from ebe0ccb7.
-- V1 is advertisement-only and does not match this action.

local SVC = uuids.SVC_MIJIA
local CHR = uuids.CHR_SENSOR

local function s16(n)
  if n >= 32768 then
    return n - 65536
  end
  return n
end

local function decode_sensor(payload)
  payload = hex.norm(payload or "")
  local n = hex.len(payload)
  if n < 3 then
    return nil, "payload shorter than 3 bytes"
  end

  local centi = s16(bits.le16(payload, 1))
  local reading = {
    temperature_c = centi / 100,
    humidity = hex.byte(payload, 3),
    raw = payload,
  }
  if n >= 5 then
    local mv = bits.le16(payload, n - 1)
    reading.battery_mv = mv
    reading.battery_percent = math.floor((mv * 100) / 3100)
  end
  return reading, nil
end

local function format_clock(payload)
  payload = hex.norm(payload or "")
  if hex.len(payload) < 4 then
    return nil
  end
  local unix = bits.le32(payload, 1)
  if unix == 0 then
    return nil
  end
  if os and os.date then
    return os.date("%H:%M", unix)
  end
  local secs = unix % 86400
  return string.format("%02d:%02d", math.floor(secs / 3600), math.floor((secs % 3600) / 60))
end

local function format_reading(reading)
  local parts = {
    string.format("%.2f°C", reading.temperature_c),
    string.format("%d%% RH", reading.humidity),
  }
  if reading.battery_mv ~= nil then
    parts[#parts + 1] = string.format("%d mV (%d%%)", reading.battery_mv, reading.battery_percent)
  elseif reading.battery_percent ~= nil then
    parts[#parts + 1] = string.format("battery %d%%", reading.battery_percent)
  end
  if reading.clock then
    parts[#parts + 1] = reading.clock
  end
  return table.concat(parts, " · ")
end

function run()
  if not ble_connected() then
    log("mijia: not connected")
    return
  end
  if fp_get("protocol") ~= "mijia_thermometer" then
    log("mijia: protocol fingerprint missing")
    return
  end
  if fp_get("connectable") == "false" then
    log("mijia: V1 readings are in the advertisement")
    return
  end
  if gatt_has_characteristic(SVC, CHR) == false then
    log("mijia: sensor characteristic not present")
    return
  end

  local model = fp_get("model") or ""
  local version = fp_get("version") or ""
  local is_v3 = model == "LYWSD02" or version == "v3"

  start_notify_wait(SVC, CHR)
  if not ble_subscribe(SVC, CHR) then
    log("mijia: subscribe failed")
    return
  end

  local payload = finish_notify_wait(SVC, CHR, 8000)
  if not payload or payload == "" then
    log("mijia: no notification, reading characteristic")
    payload = ble_read(SVC, CHR)
  end
  if not payload or payload == "" then
    log("mijia: no sensor data")
    gfx_print_text("No sensor data")
    return
  end

  local reading, err = decode_sensor(payload)
  if not reading then
    log("mijia: " .. tostring(err) .. " raw=" .. payload)
    gfx_print_text("Parse failed")
    return
  end

  if is_v3 then
    reading.battery_mv = nil
    reading.battery_percent = nil
    if uuids.CHR_BATTERY and gatt_has_characteristic(SVC, uuids.CHR_BATTERY) ~= false then
      local bat = hex.norm(ble_read(SVC, uuids.CHR_BATTERY) or "")
      if hex.len(bat) >= 1 then
        reading.battery_percent = hex.byte(bat, 1)
      end
    end
    if uuids.CHR_TIME and gatt_has_characteristic(SVC, uuids.CHR_TIME) ~= false then
      reading.clock = format_clock(ble_read(SVC, uuids.CHR_TIME))
    end
  end

  local summary = format_reading(reading)
  log("mijia: " .. model .. " " .. summary .. " raw=" .. reading.raw)

  local attrs = {
    protocol = "mijia_thermometer",
    version = version,
    model = model,
    temperature_c = string.format("%.2f", reading.temperature_c),
    humidity_percent = tostring(reading.humidity),
    sensor_hex = reading.raw,
    sensor_summary = summary,
  }
  if reading.battery_mv ~= nil then
    attrs.battery_mv = tostring(reading.battery_mv)
    attrs.battery_percent = tostring(reading.battery_percent)
    attrs.battery_source = "millivolts"
  elseif reading.battery_percent ~= nil then
    attrs.battery_percent = tostring(reading.battery_percent)
    attrs.battery_source = "percent"
  end
  if reading.clock then
    attrs.clock = reading.clock
  end

  fp_set("display_info", summary)
  fp_append("mijia_reading", attrs, model .. " sensors", summary)
  gfx_print_text(summary)
end
