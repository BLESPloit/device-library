local counter = 0
local is_on = false
local secret

local COLOR_OFF = 0xAAAAAA
local COLOR_ON = 0xDBDB48

--- Must match `peripheral/adv.json` profile id.
local ADV_PROFILE_ID = "main"
--- BR/EDR not supported + LE General Discoverable (same as static adv header).
local ADV_FLAGS = string.char(0x02, 0x01, 0x06)
--- 128-bit service UUID (little-endian air order) for SVC_LIGHTBULB — last 16 bytes of AD type 0x21.
local SVC_UUID_LE_HEX = "d78fc31d6099245dba4086e465cc00a7"

--- RGB bytes mirrored in Service Data: <1B on/off><R><G><B> (see observer adv_decode.lua).
local cur_r, cur_g, cur_b = 0xAA, 0xAA, 0xAA

local function rgb24_to_triplet(rgb24)
  local r = math.floor(rgb24 / 65536) % 256
  local g = math.floor(rgb24 / 256) % 256
  local b = rgb24 % 256
  return r, g, b
end

local function set_cur_rgb_from24(rgb24)
  cur_r, cur_g, cur_b = rgb24_to_triplet(rgb24)
end

local function apply_service_data_adv()
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
  local ok_set, err = adv_set_data(ADV_PROFILE_ID, hex)
  if ok_set ~= true then
    print("lightbulb: adv_set_data: " .. tostring(err))
  end
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

function on_read_name(input)
    counter = counter + 1
    return "DYN" .. counter
end

function on_write_name(input)
    counter = counter + 10
    return string.upper(input)
end

function reset_state()
    counter = 0
end

function turn_on()
    set_cur_rgb_from24(COLOR_ON)
    gfx_set_color("lightbulb", COLOR_ON)
    if not is_on then
        notify_power_switch(true)
    end
    is_on = true
    apply_service_data_adv()
end

function turn_off()
    set_cur_rgb_from24(COLOR_OFF)
    gfx_set_color("lightbulb", COLOR_OFF)
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
    cur_r, cur_g, cur_b = r, g, b
    local rgb = r * 2^16 + g * 2^8 + b
    gfx_set_color("lightbulb", rgb)
    local svc = uuids and uuids.SVC_LIGHTBULB
    local chr = uuids and uuids.CHR_RGB
    if type(svc) == "string" and type(chr) == "string" and svc ~= "" and chr ~= "" then
        ble_notify(svc, chr, string.format("%02x%02x%02x", r, g, b))
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
    local byte1 = string.byte(input, 1)
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
    local byte1 = string.byte(input, 1)

    -- Invert: 0x01 -> 0x00, 0x00 -> 0x01
    local inverted = (byte1 == 0x01) and 0x00 or 0x01

    if inverted == 0x01 then
        turn_on()
    else
        turn_off()
    end

    -- Return the inverted byte as the new value
    return string.char(inverted) .. string.sub(input, 2)
end



function on_write_color(input)
    local hex_str = ""
    for i = 1, #input do
        hex_str = hex_str .. string.format("%02X ", string.byte(input, i))
    end
    print("Received: " .. hex_str)

    -- Extract the three RGB bytes
    local red = string.byte(input, 1)
    local green = string.byte(input, 2)
    local blue = string.byte(input, 3)

    cur_r, cur_g, cur_b = red, green, blue

    -- Combine into a 32-bit RGB value
    local rgb = red * 2^16 + green * 2^8 + blue

    gfx_set_color("lightbulb", rgb)

    apply_service_data_adv()
    -- pass the value unchanged
    return input
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
    local byte1 = string.byte(input, 1)

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
    set_cur_rgb_from24(COLOR_OFF)
    gfx_set_color("lightbulb", COLOR_OFF)
    generate_random_byte()
    notify_power_switch(false)
    apply_service_data_adv()
end
