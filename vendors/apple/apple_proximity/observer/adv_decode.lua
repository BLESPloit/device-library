-- Proximity pairing (TLV 0x07). See https://github.com/furiousMAC/continuity/blob/master/messages/proximity_pairing.md
-- and https://github.com/kavishdevar/librepods/blob/main/Proximity%20Pairing%20Message.md

local function hex_to_bytes(hex)
    if not hex or hex == "" then return {} end
    local bin = hex_to_bin(hex)
    if #bin == 0 then return {} end
    local bytes = {}
    for i = 1, #bin do
        bytes[i] = string.byte(bin, i)
    end
    return bytes
end

local function meta_attrs(input)
    local fe = input.fingerprint_entries
    if not fe then return nil end
    local i = 1
    while true do
        local e = fe[i]
        if not e then break end
        if e.id == "apple_meta" and e.attributes then return e.attributes end
        i = i + 1
    end
    return nil
end

local function format_battery_nibble(n)
    n = bits.band(n, 0x0F)
    if n == 0x0F then return "n/a" end
    if n >= 0x0A then return "100%" end
    return (n * 10) .. "%"
end

local PROXIMITY_MODELS = {
    [0x0220] = "AirPods 1st Gen",
    [0x0F20] = "AirPods 2nd Gen",
    [0x1320] = "AirPods 3rd Gen",
    [0x1920] = "AirPods 4th Gen",
    [0x1B20] = "AirPods 4th Gen (ANC)",
    [0x0A20] = "AirPods Max",
    [0x1F20] = "AirPods Max (USB-C)",
    [0x0E20] = "AirPods Pro",
    [0x1420] = "AirPods Pro 2nd Gen",
    [0x2420] = "AirPods Pro 2nd Gen (USB-C)",
}

local PROXIMITY_COLORS = {
    [0x00] = "White",
    [0x01] = "Black",
    [0x02] = "Red",
    [0x03] = "Blue",
    [0x04] = "Pink",
    [0x05] = "Gray",
    [0x06] = "Silver",
    [0x07] = "Gold",
    [0x08] = "Rose Gold",
    [0x09] = "Space Gray",
    [0x0A] = "Dark Blue",
    [0x0B] = "Light Blue",
    [0x0C] = "Yellow",
}

local PROXIMITY_CONN = {
    [0x00] = "Disconnected",
    [0x04] = "Idle",
    [0x05] = "Music",
    [0x06] = "Call",
    [0x07] = "Ringing",
    [0x09] = "Hanging Up",
    [0xFF] = "Unknown",
}

local function decode_proximity_pairing(data, offset, len)
    if len < 9 then
        return {
            protocol = "ProximityPairing",
            model = "incomplete",
            color = "?",
            airpods_recognized = "no",
            color_display = "color: unknown (0x00)",
        }
    end
    local pairing_mode = data[offset + 1] or 0
    local model_hi = data[offset + 2] or 0
    local model_lo = data[offset + 3] or 0
    local model_id = bits.lshift(model_hi, 8) + model_lo
    local status = data[offset + 4] or 0
    local pods_batt = data[offset + 5] or 0
    local flags_case = data[offset + 6] or 0
    local lid_ind = data[offset + 7] or 0
    local color_code = data[offset + 8] or 0
    local conn_state = data[offset + 9] or 0

    local primary_left = bits.band(status, 0x20) ~= 0
    local pod_u = bits.band(bits.rshift(pods_batt, 4), 0x0F)
    local pod_l = bits.band(pods_batt, 0x0F)
    local left_batt_n = primary_left and pod_u or pod_l
    local right_batt_n = primary_left and pod_l or pod_u
    local case_batt_n = bits.band(bits.rshift(flags_case, 4), 0x0F)

    local model_name = PROXIMITY_MODELS[model_id]
    local airpods_recognized = "no"
    if not model_name then
        model_name = string.format("unknown 0x%04x", model_id)
    else
        airpods_recognized = "yes"
    end
    local color_name = PROXIMITY_COLORS[color_code]
    local color_decoded = color_name ~= nil
    if not color_name then
        color_name = string.format("unknown 0x%02x", color_code)
    end
    local color_display = color_decoded and color_name
        or string.format("color: unknown (%s)", string.format("0x%02x", color_code))

    local pairing_label = (pairing_mode == 0x01) and "paired"
        or ((pairing_mode == 0x00) and "pairing" or string.format("0x%02x", pairing_mode))

    return {
        protocol = "ProximityPairing",
        model = model_name,
        model_id_hex = string.format("0x%04x", model_id),
        color = color_name,
        color_code_hex = string.format("0x%02x", color_code),
        color_display = color_display,
        airpods_recognized = airpods_recognized,
        pairing_mode = pairing_label,
        connection_state = PROXIMITY_CONN[conn_state] or string.format("0x%02x", conn_state),
        battery_left = format_battery_nibble(left_batt_n),
        battery_right = format_battery_nibble(right_batt_n),
        battery_case = format_battery_nibble(case_batt_n),
        status_raw = string.format("%02x", status),
        lid_raw = string.format("%02x", lid_ind),
        flags_case_raw = string.format("%02x", flags_case),
        primary_pod = primary_left and "left" or "right",
    }
end

function parse(input)
    local a = meta_attrs(input)
    if not a or a.continuity_has_proximity ~= "true" or not a.continuity_payload_hex then
        return {}, {}
    end
    local data = hex_to_bytes(a.continuity_payload_hex)
    local entries = {}
    local pos = 1
    while pos <= #data - 1 do
        local t = data[pos]
        local len = data[pos + 1] or 0
        pos = pos + 2
        if len == 0 or pos + len - 1 > #data then break end
        if t == 0x07 then
            local info = decode_proximity_pairing(data, pos - 1, len)
            local attrs = {}
            for k, v in pairs(info) do
                attrs[k] = tostring(v)
            end
            attrs["type_byte"] = string.format("0x%02x", t)
            attrs["beaconformat"] = info.protocol
            entries[#entries + 1] = {
                id = "apple_07",
                displayName = info.protocol,
                attributes = attrs,
            }
        end
        pos = pos + len
    end
    if #entries == 0 then
        return {}, {}
    end
    local first = entries[1].attributes
    local device_type = "PHONE"
    if first.airpods_recognized == "yes" then
        device_type = "AUDIO"
    end
    local display_name = "Proximity Pairing"
    if first.airpods_recognized == "yes" then
        display_name = first.model
    end
    local info_line = (first.model or "?") .. " · " .. (first.color or "?")
    if #info_line > 48 then
        info_line = info_line:sub(1, 45) .. "..."
    end
    local ui = {
        device_type = device_type,
        custom_icon = assets.icon,
        custom_icon_tint = assets.icon_tint,
        display_name = display_name,
        display_info = info_line,
    }
    return entries, ui
end
