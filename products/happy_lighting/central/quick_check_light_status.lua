-- Quick action: subscribe FFD0/FFD4, write EF0177 to FFD9, parse 12-byte state notify (type 0x66).

local SVC_NOTIFY = "ffd0"
local CHR_NOTIFY = "ffd4"
local SVC_CMD = "ffd5"
local CHR_CMD = "ffd9"

local TINT_OFF = "#9E9E9E"

local ICON_STATIC = "assets/lightbulb.svg"
local ICON_EFFECT = "assets/lightbulb_color.svg"

local MOD_NAMES = {
  [0x25] = "Rainbow pulsating",
  [0x26] = "Red pulsating",
  [0x27] = "Green pulsating",
  [0x28] = "Blue pulsating",
  [0x29] = "Yellow pulsating",
  [0x2A] = "Cyan pulsating",
  [0x2B] = "Purple pulsating",
  [0x2C] = "White pulsating",
  [0x2D] = "Red/Green pulsating",
  [0x2E] = "Red/Blue pulsating",
  [0x2F] = "Green/Blue pulsating",
  [0x30] = "Rainbow flashing",
  [0x31] = "Red flashing",
  [0x32] = "Green flashing",
  [0x33] = "Blue flashing",
  [0x34] = "Yellow flashing",
  [0x35] = "Cyan flashing",
  [0x36] = "Purple flashing",
  [0x37] = "White flashing",
  [0x38] = "Rainbow jumping",
}

local function nint(hex, from, to)
  return tonumber(hex:sub(from, to), 16)
end

local function is_effect_mode(mode)
  return MOD_NAMES[mode] ~= nil
end

--- Parse notify hex (24+ chars): b2 on/off, b3 mode, b5 speed, b6–b8 RGB.
local function parse_light_state(hex)
  if not hex or #hex < 24 then
    return nil
  end
  hex = hex:lower():gsub("%s+", "")
  if #hex < 24 then
    return nil
  end
  if nint(hex, 1, 2) ~= 0x66 then
    return nil, "unexpected notify type"
  end
  local b2 = nint(hex, 5, 6)
  local on = (b2 == 0x23)
  local mode = nint(hex, 7, 8)
  local speed = nint(hex, 11, 12)
  local r = nint(hex, 13, 14)
  local g = nint(hex, 15, 16)
  local b = nint(hex, 17, 18)
  return {
    on = on,
    mode = mode,
    speed = speed,
    r = r,
    g = g,
    b = b,
    effect = is_effect_mode(mode),
  }
end

function run()
  if gatt_has_characteristic(SVC_NOTIFY, CHR_NOTIFY) == false then
    log("happy_lighting: FFD4 not present — cannot read status")
    return
  end
  if gatt_has_characteristic(SVC_CMD, CHR_CMD) == false then
    log("happy_lighting: FFD9 not present — cannot read status")
    return
  end
  if not ble_subscribe(SVC_NOTIFY, CHR_NOTIFY) then
    log("happy_lighting: ble_subscribe failed")
    return
  end
  delay_ms(400)
  start_notify_wait(SVC_NOTIFY, CHR_NOTIFY)
  if not ble_write(SVC_CMD, CHR_CMD, "ef0177", true) then
    log("happy_lighting: write EF0177 failed")
    return
  end
  local hex = finish_notify_wait(SVC_NOTIFY, CHR_NOTIFY, 8000)
  if hex == nil then
    log("happy_lighting: no notify (timeout)")
    return
  end
  local st, err = parse_light_state(hex)
  if st == nil then
    log("happy_lighting: parse failed  raw=" .. hex .. (err and ("  " .. err) or ""))
    return
  end
  local state_txt = st.on and "ON" or "OFF"
  local display_line

  if st.effect then
    local mname = MOD_NAMES[st.mode] or string.format("mode 0x%02X", st.mode)
    log(string.format(
      "happy_lighting: %s  %s  speed=%d  raw=%s",
      state_txt,
      mname,
      st.speed,
      hex
    ))
    display_line = string.format("%s · %s (sp. %d)", state_txt, mname, st.speed)
    fp_set("custom_icon", ICON_EFFECT)
    fp_clear("custom_icon_tint")
  else
    local rgb_txt = string.format("#%02X%02X%02X", st.r, st.g, st.b)
    log(string.format(
      "happy_lighting: %s  RGB=%s  mode=0x%02X  speed=%d  raw=%s",
      state_txt,
      rgb_txt,
      st.mode,
      st.speed,
      hex
    ))
    display_line = string.format("%s · %s", state_txt, rgb_txt)
    fp_set("custom_icon", ICON_STATIC)
    if st.on then
      fp_set("custom_icon_tint", rgb_txt)
    else
      fp_set("custom_icon_tint", TINT_OFF)
    end
  end

  fp_set("display_info", display_line)

  local attrs = {
    light_on = st.on and "1" or "0",
    light_mode_hex = string.format("%02X", st.mode),
    light_speed = tostring(st.speed),
    light_state_summary = display_line,
    light_notify_hex = hex,
  }
  if not st.effect then
    attrs.light_rgb = string.format("%02X%02X%02X", st.r, st.g, st.b)
  end
  if st.effect and MOD_NAMES[st.mode] then
    attrs.light_effect = MOD_NAMES[st.mode]
  end
  fp_append("happy_lighting_gatt_status", attrs, "Happy Lighting (GATT)")
end
