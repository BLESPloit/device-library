local speed = 0
local is_on = false

function turn_on()
    is_on = true
end

function turn_off()
    is_on = false
end

function on_write_speed(input)
    local hex_str = ""
    for i = 1, #input do
        hex_str = hex_str .. string.format("%02X ", string.byte(input, i))
    end
    -- print("Received: " .. hex_str)
    speed = string.byte(input, 3)
    print("Speed: " .. speed)
    gfx_update_text("status", "Speed: " .. speed)
    -- pass the value unchanged
    return input
end


function on_startup()
    print("Lua script starting...")    
    gfx_show("realov")
    gfx_show("status")
end