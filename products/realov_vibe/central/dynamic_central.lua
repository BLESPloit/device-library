-- CHR_SPEED: frame C555 + speed octet + AA (see uuids.json). Peripheral stub reads byte 3 as speed.

local function speed_arg_to_hex(arg)
    local n = tonumber(arg, 10)
    if not n then
        gfx_print_text("Invalid speed (need 0-255)")
        return nil
    end
    n = math.floor(n + 0.5)
    if n < 0 then n = 0 end
    if n > 255 then n = 255 end
    return string.format("C555%02XAA", n)
end

function on_main_enter()
    print("realov_vibe central: main menu")
end

function set_speed(arg)
    local hex = speed_arg_to_hex(arg)
    if not hex then
        return
    end
    local ok, err = ble_write(uuids.SVC_REALOV, uuids.CHR_SPEED, hex)
    if ok then
        set_title("Speed " .. arg)
        set_state("speed", arg)
    end
end
