-- 70mai tire-pressure receiver, manufacturer company id 0x0059.
-- t01 is the monitor. t02 is the Lite receiver. Readings are in the advertisement.

local ENTRY_ID = "70mai_tire_pressure"
local PROTOCOL = "70mai_tire_pressure"
local TINT_ADVERTISING = "#ea4f16"
local TINT_CONNECTED = "#808080"

local WHEELS = {
  { key = "lf", label = "LF", offset = 7 },
  { key = "rf", label = "RF", offset = 11 },
  { key = "rr", label = "RR", offset = 15 },
  { key = "lr", label = "LR", offset = 19 },
}

local function flag(on)
  if on then
    return "true"
  end
  return "false"
end

local function s8(n)
  if n >= 128 then
    return n - 256
  end
  return n
end

local function bar(n)
  return string.format("%.1f", n / 10)
end

local function payload(input)
  local md = input.manufacturer_data
  if type(md) == "table" and type(md["0059"]) == "string" then
    local h = hex.norm(md["0059"])
    if h:sub(1, 4) == "5900" or h:sub(1, 4) == "0059" then
      h = h:sub(5)
    end
    if h ~= "" then
      return h
    end
  end
  local raw = input.raw_adv_hex or input.adv_data_hex_combined or ""
  local found = adv.find(raw, 0xFF)
  for i = 1, #found do
    local h = hex.norm(found[i])
    if h:sub(1, 4) == "5900" then
      return h:sub(5)
    end
  end
  return nil
end

local function wheel_at(data, offset)
  if hex.len(data) < offset + 3 then
    return nil
  end
  local status = hex.byte(data, offset + 2)
  local alarm = hex.byte(data, offset + 3)
  return {
    pressure = hex.byte(data, offset),
    temperature = s8(hex.byte(data, offset + 1)),
    status = bits.band(status, 0x01) ~= 0,
    fault = bits.band(status, 0x02) ~= 0,
    sensor_battery = bits.band(status, 0x04) ~= 0,
    invalid = bits.band(status, 0x08) ~= 0,
    mode = math.floor(bits.band(status, 0xF0) / 16),
    position = bits.band(alarm, 0x07),
    hp = bits.band(alarm, 0x08) ~= 0,
    lp = bits.band(alarm, 0x10) ~= 0,
    ht = bits.band(alarm, 0x20) ~= 0,
    lt = bits.band(alarm, 0x40) ~= 0,
    leak = bits.band(alarm, 0x80) ~= 0,
  }
end

local function put_wheel(attributes, key, wheel)
  attributes[key .. "_pressure"] = bar(wheel.pressure)
  attributes[key .. "_temperature"] = tostring(wheel.temperature)
  attributes[key .. "_mode"] = tostring(wheel.mode)
  attributes[key .. "_position"] = tostring(wheel.position)
  attributes[key .. "_status"] = flag(wheel.status)
  attributes[key .. "_fault"] = flag(wheel.fault)
  attributes[key .. "_sensor_battery"] = flag(wheel.sensor_battery)
  attributes[key .. "_invalid"] = flag(wheel.invalid)
  attributes[key .. "_high_pressure"] = flag(wheel.hp)
  attributes[key .. "_low_pressure"] = flag(wheel.lp)
  attributes[key .. "_high_temperature"] = flag(wheel.ht)
  attributes[key .. "_low_temperature"] = flag(wheel.lt)
  attributes[key .. "_leak"] = flag(wheel.leak)
end

local function alarm_text(label, wheel)
  local parts = {}
  if wheel.hp then
    parts[#parts + 1] = "high pressure"
  end
  if wheel.lp then
    parts[#parts + 1] = "low pressure"
  end
  if wheel.ht then
    parts[#parts + 1] = "high temperature"
  end
  if wheel.lt then
    parts[#parts + 1] = "low temperature"
  end
  if wheel.leak then
    parts[#parts + 1] = "leak"
  end
  if wheel.fault then
    parts[#parts + 1] = "fault"
  end
  if wheel.sensor_battery then
    parts[#parts + 1] = "sensor battery"
  end
  if #parts == 0 then
    return nil
  end
  return label .. " " .. table.concat(parts, ", ")
end

function parse(input)
  local data = payload(input)
  if not data or hex.len(data) < 22 then
    return {}, {}
  end

  local name = input.device_name or ""
  local model = name:match("^70mai_(t0[12])") or "tire pressure"
  local mac_hex = hex.slice(data, 1, 6)
  local adv_bdaddr = ""
  if hex.len(mac_hex) == 6 then
    adv_bdaddr = mac.from_reversed(mac_hex)
  end

  local pressures = {}
  local alarms = {}
  local attributes = {
    protocol = PROTOCOL,
    vendor = "70mai",
    model = model,
    device_name = name,
    adv_bdaddr = adv_bdaddr,
  }

  for i = 1, #WHEELS do
    local spec = WHEELS[i]
    local wheel = wheel_at(data, spec.offset)
    if wheel then
      put_wheel(attributes, spec.key, wheel)
      pressures[#pressures + 1] = bar(wheel.pressure)
      local text = alarm_text(spec.label, wheel)
      if text then
        alarms[#alarms + 1] = text
      end
    end
  end

  local connected = false
  if hex.len(data) >= 23 then
    attributes.battery = tostring(hex.byte(data, 23))
  end
  if hex.len(data) >= 24 then
    local flags = math.floor(bits.band(hex.byte(data, 24), 0xF0) / 16)
    attributes.cf = flag(bits.band(flags, 0x01) ~= 0)
    attributes.cr = flag(bits.band(flags, 0x02) ~= 0)
    attributes.charger = tostring(math.floor(bits.band(flags, 0x0C) / 4))
  end
  if hex.len(data) >= 25 then
    connected = bits.band(hex.byte(data, 25), 0x01) ~= 0
    attributes.connected = flag(connected)
  end

  local info = model
  if #pressures > 0 then
    info = info .. " · " .. table.concat(pressures, " ") .. " bar"
  end
  if attributes.battery then
    info = info .. " · " .. attributes.battery .. "%"
  end

  local hint = nil
  if #alarms > 0 then
    hint = table.concat(alarms, ". ") .. "."
  end

  return {
    {
      id = ENTRY_ID,
      display_name = "70mai tire pressure",
      hint = hint,
      attributes = attributes,
    },
  }, {
    device_type = "SENSOR",
    custom_icon = "assets/icon.svg",
    custom_icon_tint = connected and TINT_CONNECTED or TINT_ADVERTISING,
    display_name = "70mai tire pressure",
    display_info = info,
  }
end
