-- Nearby Info (outer TLV 0x10). See https://github.com/furiousMAC/continuity/blob/master/messages/nearby_info.md

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

--- Only codes with a known human-readable label (omit 0x00 "unknown" and raw hex from folded line).
local ACTION_LABELS = {
    [0x01] = "Activity reporting disabled",
    [0x03] = "Idle (screen off/locked)",
    [0x05] = "Audio playing, screen locked",
    [0x07] = "Active user (screen on)",
    [0x09] = "Screen on, video playing",
    [0x0A] = "Watch on wrist, unlocked",
    [0x0B] = "Recent interaction",
    [0x0D] = "Driving",
    [0x0E] = "Phone/FaceTime call",
}

local function decode_nearby_info(data, offset, len)
    local byte0 = data[offset + 1] or 0
    local byte1 = data[offset + 2] or 0

    local status_flags = bits.band(bits.rshift(byte0, 4), 0x0F)
    local action_code = bits.band(byte0, 0x0F)

    local wifi_on = bits.band(byte1, 0x04) ~= 0
    local authtag_4b = bits.band(byte1, 0x02) ~= 0
    local authtag_pres = bits.band(byte1, 0x10) ~= 0
    local airpods_on = bits.band(byte1, 0x01) ~= 0
    local airdrop_recv = bits.band(status_flags, 0x04) ~= 0
    local primary_dev = bits.band(status_flags, 0x01) ~= 0

    local auth = {}
    for j = 3, math.min(len, 5) do
        auth[#auth + 1] = string.format("%02x", data[offset + j] or 0)
    end

    local known_activity = ACTION_LABELS[action_code]

    return {
        protocol = "NearbyInfo",
        action_code_hex = string.format("0x%02x", action_code),
        action = known_activity or string.format("0x%02x", action_code),
        activity_known = known_activity and "yes" or "no",
        wifi = wifi_on and "on" or "off",
        airdrop_recv = airdrop_recv and "yes" or "no",
        primary_device = primary_dev and "yes" or "no",
        airpods_conn = airpods_on and "yes" or "no",
        authtag_4b = authtag_4b and "yes" or "no",
        authtag_pres = authtag_pres and "yes" or "no",
        status_flags_raw = string.format("%02x", status_flags),
        data_flags_raw = string.format("%02x", byte1),
        auth_tag = table.concat(auth, ""),
    }
end

function parse(input)
    local a = meta_attrs(input)
    if not a or a.continuity_has_nearbyinfo ~= "true" or not a.continuity_payload_hex then
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
        if t == 0x10 then
            local info = decode_nearby_info(data, pos - 1, len)
            local attrs = {}
            for k, v in pairs(info) do
                attrs[k] = tostring(v)
            end
            attrs["type_byte"] = string.format("0x%02x", t)
            attrs["beaconformat"] = info.protocol
            entries[#entries + 1] = {
                id = "apple_10",
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
    local ui = {
        device_type = "NEARBY",
        custom_icon = assets.icon,
        custom_icon_tint = assets.icon_tint,
        display_name = "Nearby Info",
    }
    if first.activity_known == "yes" and first.action then
        local info_line = first.action
        if #info_line > 40 then
            info_line = info_line:sub(1, 37) .. "..."
        end
        ui.display_info = info_line
    end
    return entries, ui
end
