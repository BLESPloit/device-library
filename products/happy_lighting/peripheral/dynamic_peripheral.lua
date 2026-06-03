-- local SVC_NOTIFY = "ffd0"
-- local CHR_NOTIFY = "ffd4"

local COLOR_OFF = 0xAAAAAA
local COLOR_ON  = 0xDBDB48

local is_on = false
local current_color = COLOR_ON
-- Light-state notify payload (see EF 01 77 reply); speed_param updated by BB special cmd
local mode_id = 0x41
local speed_param = 0x10

--- XX in BB XX YY 44 — matches vendor app mod list (values 0x25–0x38).
local SPECIAL_MOD_NAMES = {
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

local function rgb_components(rgb)
    local r = math.floor(rgb / 65536) % 256
    local g = math.floor(rgb / 256) % 256
    local b = rgb % 256
    return r, g, b
end

--- 12-byte light-state frame (type 0x66), same layout as real notify samples.
local function build_light_state_packet()
    local rgb = is_on and current_color or COLOR_OFF
    local r, g, b = rgb_components(rgb)
    local onoff = is_on and 0x23 or 0x24
    return string.char(
        0x66, 0x04, onoff, mode_id, 0x20, speed_param,
        r, g, b, 0x00, 0x03, 0x99
    )
end

local function hex_dump_bytes(bin)
    local s = ""
    for i = 1, #bin do
        s = s .. string.format("%02X ", string.byte(bin, i))
    end
    return s:sub(1, -2)
end

function turn_on()
    gfx_set_color("lightbulb", COLOR_ON)
    is_on = true
end

function turn_off()
    gfx_set_color("lightbulb", COLOR_OFF)
    is_on = false
end

function toggle()
    if is_on == true then
        turn_off()
    else
        turn_on()
    end
end

function on_write_command(input)
    local len = #input

    -- Build hex dump for debug
    local hex_str = ""
    for i = 1, len do
        hex_str = hex_str .. string.format("%02X ", string.byte(input, i))
    end
    print("Received: " .. hex_str)

    local b1 = len >= 1 and string.byte(input, 1) or 0

    -- Check PIN: CF d1 d2 d3 d4 FC  (6 bytes); show PIN as decimal digits per byte
    if len == 6 and b1 == 0xCF and string.byte(input, 6) == 0xFC then
        local d1 = string.byte(input, 2)
        local d2 = string.byte(input, 3)
        local d3 = string.byte(input, 4)
        local d4 = string.byte(input, 5)
        print(string.format("Command: CHECK PIN  %02X %02X %02X %02X", d1, d2, d3, d4))
        -- Each byte in decimal, concatenated (e.g. bytes 01 02 03 04 -> "1234")
        local pin_dec = string.format("%d%d%d%d", d1, d2, d3, d4)
        gfx_print_notification("PIN: " .. pin_dec)
        return input
    end

    -- Read current light state (write): EF 01 77  — reply payload prepared (raw log for now)
    if len == 3 and b1 == 0xEF and string.byte(input, 2) == 0x01 and string.byte(input, 3) == 0x77 then
        print("Command: READ LIGHT STATE (EF0177)")
        local pkt = build_light_state_packet()
        print("Light state reply (12 B): " .. hex_dump_bytes(pkt))
        ble_notify(uuids.SVC_NOTIFY, uuids.CHR_NOTIFY, bin_to_hex(pkt))
        return input
    end

    -- Need at least 3 bytes for other commands
    if len < 3 then
        print("Command too short, ignoring.")
        return input
    end

    local b2 = string.byte(input, 2)
    local b3 = string.byte(input, 3)

    -- Turn ON:  CC 23 33
    if b1 == 0xCC and b2 == 0x23 and b3 == 0x33 then
        print("Command: TURN ON")
        turn_on()

    -- Turn OFF: CC 24 33
    elseif b1 == 0xCC and b2 == 0x24 and b3 == 0x33 then
        print("Command: TURN OFF")
        turn_off()

    -- Set color: 56 RR GG BB 00 F0 AA  (7 bytes)
    elseif b1 == 0x56 and len >= 7 then
        local red   = string.byte(input, 2)
        local green = string.byte(input, 3)
        local blue  = string.byte(input, 4)
        -- bytes 5-7 are 00 F0 AA (footer, ignored)
        local rgb = red * 2^16 + green * 2^8 + blue
        print(string.format("Command: SET COLOR  R=%d G=%d B=%d (0x%06X)", red, green, blue, rgb))
        gfx_set_color("lightbulb", rgb)
        current_color = rgb
        mode_id = 0x41

    -- Special function: BB XX YY 44  (4 bytes)
    elseif b1 == 0xBB and len >= 4 then
        local cmd_code = string.byte(input, 2)   -- XX (mod / effect id)
        local speed    = string.byte(input, 3)   -- YY
        speed_param = speed
        mode_id = cmd_code
        local effect_name = SPECIAL_MOD_NAMES[cmd_code]
            or string.format("Unknown mod 0x%02X", cmd_code)
        -- byte 4 is 0x44 (footer)
        print(string.format(
            "Command: SPECIAL  %s  (XX=0x%02X  speed=%d)",
            effect_name,
            cmd_code,
            speed
        ))
        gfx_print_notification(effect_name .. ", speed " .. speed)

    else
        print("Unknown command, ignoring.")
    end

    return input
end

function on_startup()
    print("Lua script starting...")
    gfx_show("lightbulb")
    gfx_set_color("lightbulb", current_color)
end