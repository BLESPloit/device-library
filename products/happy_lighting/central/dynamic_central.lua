-- SVC_HAPPYLIGHT, CHR_COMMAND from uuids.json
-- FFD9 is write-without-response only (iOS rejects with-response writes).

function on_main_enter()
    print("LUA on_main_enter")
end

function turn_on()
    local ok, err = ble_write(uuids.SVC_HAPPYLIGHT, uuids.CHR_COMMAND, "CC2333", true)
    if ok then
        set_title("Light ON")
        set_state("power", "ON")
    end
end

function turn_off()
    local ok, err = ble_write(uuids.SVC_HAPPYLIGHT, uuids.CHR_COMMAND, "CC2433", true)
    if ok then 
        set_title("Light OFF")
        set_state("power", "OFF")
    end
end

function on_select_color()
    push_menu("color")
end

function set_color(color)
    -- color is hex like "FF0000" (red). CHR_COMMAND expects "56RRGGBB00F0AA"
    if type(color) == "string" and #color >= 6 then
        local ok = ble_write(uuids.SVC_HAPPYLIGHT, uuids.CHR_COMMAND, "56" .. string.sub(color, 1, 6) .. "00F0AA", true)
        if ok then
            gfx_print_text("Color set: " .. string.sub(color, 1, 6))
        end
    else
        gfx_print_text("Color: " .. tostring(color))
    end
end
