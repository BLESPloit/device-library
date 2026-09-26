local is_on = false
local secret

--- GAP Device Name (2A00) and Complete Local Name. Matches peripheral/adv.json scan response.
local DEFAULT_DEVICE_NAME = "BLESPlo.it light"
local MAX_DEVICE_NAME_BYTES = 29
local current_device_name = DEFAULT_DEVICE_NAME

--- When vars.disconnect_without_switch is enabled: require an on/off write within
--- vars.disconnect_without_switch_seconds (default 3) of connect.
--- delay() has no cancel; use a generation guard so stale timeouts are ignored after reconnect.
local got_switch = false
local conn_gen = 0
local pending_gen = 0
local DEFAULT_SWITCH_TIMEOUT_S = 3
local pending_timeout_s = DEFAULT_SWITCH_TIMEOUT_S

local COLOR_OFF = 0xAAAAAA
local COLOR_ON = 0xDBDB48

--- Must match `peripheral/adv.json` profile id.
local ADV_PROFILE_ID = "main"
--- BR/EDR not supported + LE General Discoverable (same as static adv header).
local ADV_FLAGS = string.char(0x02, 0x01, 0x06)
--- 128-bit service UUID (little-endian air order) for SVC_LIGHTBULB — last 16 bytes of AD type 0x21.
local SVC_UUID_LE_HEX = "d78fc31d6099245dba4086e465cc00a7"

--- RGB bytes mirrored in Service Data: <1B on/off><R><G><B> (see observer adv_decode.lua).
--- cur_* is what is advertised / shown; last_* is the color restored by turn_on.
local cur_r, cur_g, cur_b = 0xAA, 0xAA, 0xAA
local last_r, last_g, last_b = 0xDB, 0xDB, 0x48

local function disconnect_without_switch_enabled()
  if type(vars) ~= "table" or vars.disconnect_without_switch == nil then
    return false
  end
  local v = vars.disconnect_without_switch
  if type(v) == "boolean" then
    return v
  end
  if type(v) == "number" then
    return v ~= 0
  end
  if type(v) == "string" then
    local s = string.lower(v)
    return s == "true" or s == "1" or s == "yes"
  end
  return false
end

local function switch_timeout_seconds()
  local fallback = DEFAULT_SWITCH_TIMEOUT_S
  if type(vars) ~= "table" or vars.disconnect_without_switch_seconds == nil then
    return fallback
  end
  local n = tonumber(vars.disconnect_without_switch_seconds)
  if n == nil or n < 0 then
    return fallback
  end
  return n
end

local function mark_switch_received()
  got_switch = true
end

--- Printable bytes only. Length is octets so a UTF-8 nick cannot exceed the legacy scan response.
local function valid_device_name(name)
  if type(name) ~= "string" then
    return false
  end
  local n = #name
  if n < 1 or n > MAX_DEVICE_NAME_BYTES then
    return false
  end
  for i = 1, n do
    if string.byte(name, i) < 0x20 then
      return false
    end
  end
  return true
end

local function resolve_device_name()
  if type(vars) == "table" and valid_device_name(vars.device_name) then
    return vars.device_name
  end
  return DEFAULT_DEVICE_NAME
end

local function show_device_name()
  if type(gfx_render_text) ~= "function" or type(gfx_update_text) ~= "function" then
    return
  end
  gfx_render_text("device_name", "bottom_center", 0, -16, 0x333333)
  gfx_update_text("device_name", resolve_device_name(), 0x333333)
end

local function device_name_scan_rsp_hex(name)
  if type(bin_to_hex) ~= "function" then
    return nil
  end
  local tlv = string.char(1 + #name, 0x09) .. name
  local ok, hex = pcall(bin_to_hex, tlv)
  if not ok or type(hex) ~= "string" or hex == "" then
    return nil
  end
  return hex
end

local function schedule_adv_reapply()
  if type(delay) == "function" then
    delay(0.3, "light_reapply_adv")
  end
end

local function rgb24_to_triplet(rgb24)
  local r = math.floor(rgb24 / 65536) % 256
  local g = math.floor(rgb24 / 256) % 256
  local b = rgb24 % 256
  return r, g, b
end

local function set_cur_rgb_from24(rgb24)
  cur_r, cur_g, cur_b = rgb24_to_triplet(rgb24)
end

local function set_last_rgb(r, g, b)
  last_r, last_g, last_b = r, g, b
end

local function last_rgb24()
  return last_r * 2^16 + last_g * 2^8 + last_b
end

--- Show and advertise the remembered color (does not change last_*).
local function apply_on_display()
  cur_r, cur_g, cur_b = last_r, last_g, last_b
  gfx_set_color("lightbulb", last_rgb24())
end

--- Grey the bulb without forgetting last_*.
local function apply_off_display()
  set_cur_rgb_from24(COLOR_OFF)
  gfx_set_color("lightbulb", COLOR_OFF)
end

local function apply_service_data_adv()
  current_device_name = resolve_device_name()
  show_device_name()
  if type(adv_set_data) ~= "function" or type(hex_to_bin) ~= "function" or type(bin_to_hex) ~= "function" then
    return
  end
  local ok_u, uuid_le = pcall(hex_to_bin, SVC_UUID_LE_HEX)
  if not ok_u or type(uuid_le) ~= "string" or #uuid_le ~= 16 then
    print("lightbulb: hex_to_bin(SVC_UUID_LE) failed")
    return
  end
  local on_byte = is_on and 0x01 or 0x00
  local payload = string.char(on_byte, cur_r, cur_g, cur_b)
  --- AD: Len=21 Type=0x21 Data=<UUID 16B><service data 4B>
  local tlv = string.char(0x15, 0x21) .. uuid_le .. payload
  local blob = ADV_FLAGS .. tlv
  local ok_h, hex = pcall(bin_to_hex, blob)
  if not ok_h or type(hex) ~= "string" then
    print("lightbulb: bin_to_hex(adv blob) failed")
    return
  end
  local scan = device_name_scan_rsp_hex(current_device_name)
  if scan == nil then
    print("lightbulb: device name scan response failed")
    return
  end
  local ok_set, err = adv_set_data(ADV_PROFILE_ID, hex, scan)
  if ok_set ~= true then
    print("lightbulb: adv_set_data: " .. tostring(err))
  end
end

--- NimBLE restarts advertising from static adv.json after a link change.
function light_reapply_adv()
  apply_service_data_adv()
end

local function notify_power_switch(on)
  local svc = uuids and uuids.SVC_LIGHTBULB
  local chr = uuids and uuids.CHR_ONOFF
  if type(svc) ~= "string" or type(chr) ~= "string" or svc == "" or chr == "" then
    return
  end
  local hex = on and "01" or "00"
  ble_notify(svc, chr, hex)
end

function on_read_name(_input)
  current_device_name = resolve_device_name()
  return current_device_name
end

function on_write_name(input)
  if not valid_device_name(input) then
    return resolve_device_name()
  end
  if type(vars) ~= "table" then
    vars = {}
  end
  vars.device_name = input
  current_device_name = input
  if type(vars_save) == "function" then
    vars_save()
  end
  apply_service_data_adv()
  return current_device_name
end

function turn_on()
    apply_on_display()
    if not is_on then
        notify_power_switch(true)
    end
    is_on = true
    apply_service_data_adv()
end

function turn_off()
    apply_off_display()
    if is_on then
        notify_power_switch(false)
    end
    is_on = false
    apply_service_data_adv()
end

function toggle()
    if is_on == true then
        turn_off()
    else
        turn_on()
    end
end

--- Invoked from peripheral interface (double-press on button 0).
function set_random_color()
    local r = math.random(0, 255)
    local g = math.random(0, 255)
    local b = math.random(0, 255)
    set_last_rgb(r, g, b)
    if is_on then
        apply_on_display()
    end
    local rgb = last_rgb24()
    local svc = uuids and uuids.SVC_LIGHTBULB
    local chr = uuids and uuids.CHR_RGB
    if type(svc) == "string" and type(chr) == "string" and svc ~= "" and chr ~= "" then
        ble_notify(svc, chr, hex.u8(r) .. hex.u8(g) .. hex.u8(b))
    end
    print(string.format("Random color R=%d G=%d B=%d (0x%06X)", r, g, b, rgb))
    apply_service_data_adv()
end

function on_write_onoff(input)
    local hex_str = ""
    for i = 1, #input do
        hex_str = hex_str .. string.format("%02X ", string.byte(input, i))
    end
    print("Received: " .. hex_str)
    local byte1 = hex.byte(bin_to_hex(input), 1)
    --- Proper light switch: first byte is 0x00 (off) or 0x01 (on).
    if byte1 == 0x00 or byte1 == 0x01 then
        mark_switch_received()
    end
    if byte1 == 0x01 then
        turn_on()
    else
        turn_off()
    end
    -- pass the value unchanged
    return input
end

function on_write_onoff_invert(input)
    local hex_str = ""
    for i = 1, #input do
        hex_str = hex_str .. string.format("%02X ", string.byte(input, i))
    end
    print("Received: " .. hex_str)
    local byte1 = hex.byte(bin_to_hex(input), 1)

    -- Invert: 0x01 -> 0x00, 0x00 -> 0x01
    local inverted = (byte1 == 0x01) and 0x00 or 0x01

    if byte1 == 0x00 or byte1 == 0x01 then
        mark_switch_received()
    end

    if inverted == 0x01 then
        turn_on()
    else
        turn_off()
    end

    -- Return the inverted byte as the new value
    return string.char(inverted) .. string.sub(input, 2)
end

function on_connected()
  got_switch = false
  conn_gen = conn_gen + 1
  apply_service_data_adv()
  schedule_adv_reapply()
  if not disconnect_without_switch_enabled() then
    return
  end
  pending_gen = conn_gen
  pending_timeout_s = switch_timeout_seconds()
  print(string.format(
    "lightbulb: switch required within %ss (conn_gen=%s)",
    tostring(pending_timeout_s),
    tostring(conn_gen)
  ))
  delay(pending_timeout_s, "switch_timeout")
end

function on_disconnected()
  --- Invalidate any pending switch_timeout for this link.
  conn_gen = conn_gen + 1
  got_switch = false
  apply_service_data_adv()
  schedule_adv_reapply()
end

function switch_timeout()
  if pending_gen ~= conn_gen then
    return
  end
  if got_switch then
    return
  end
  if type(ble_connected) == "function" and ble_connected() then
    print(string.format(
      "lightbulb: no on/off switch within %ss — disconnecting central",
      tostring(pending_timeout_s)
    ))
    ble_disconnect()
  end
end



function on_write_color(input)
    local hex_str = ""
    for i = 1, #input do
        hex_str = hex_str .. string.format("%02X ", string.byte(input, i))
    end
    print("Received: " .. hex_str)

    -- Extract the three RGB bytes
    local h = bin_to_hex(input)
    local red = hex.byte(h, 1)
    local green = hex.byte(h, 2)
    local blue = hex.byte(h, 3)

    set_last_rgb(red, green, blue)
    if is_on then
        apply_on_display()
    end

    apply_service_data_adv()
    -- pass the value unchanged
    return input
end

function on_read_color(_input)
    return string.char(last_r, last_g, last_b)
end

-- Function to check if single byte input matches the random number
function on_write_secret(input)
    -- Convert input string to hex for display
    local hex_str = ""
    for i = 1, #input do
        hex_str = hex_str .. string.format("%02X ", string.byte(input, i))
    end
    print("Secret received: " .. hex_str)

    -- Extract the first byte
    local byte1 = hex.byte(bin_to_hex(input), 1)

    -- Compare with secret number
    if byte1 == secret then
        print(string.format("Match! Input byte 0x%02X (%d) matches secret number", byte1, byte1))
    else
        print(string.format("No match. Input: 0x%02X (%d), Secret: 0x%02X (%d)",
              byte1, byte1, secret, secret))
    end
-- no need to return anything, GATT handler will take care of it
end


function generate_random_byte()
    -- Generate a random number between 0 and 255 (0x0 to 0xFF)
    secret = math.random(0, 255)
    print(string.format("Random number generated: %d (0x%02X)", secret, secret))

    return secret
end

function on_startup()
    print("Lua script starting...")
    gfx_show("lightbulb")
    is_on = false
    last_r, last_g, last_b = rgb24_to_triplet(COLOR_ON)
    apply_off_display()
    generate_random_byte()
    notify_power_switch(false)
    apply_service_data_adv()
end
