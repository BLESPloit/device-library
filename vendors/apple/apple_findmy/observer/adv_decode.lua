-- Find My (TLV 0x12). See https://github.com/furiousMAC/continuity/blob/master/dissector/FIELDS.md

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

local function decode_findmy(data, offset, len)
    local status = data[offset + 1] or 0
    local battery_state = bits.band(bits.rshift(status, 6), 0x03)
    local battery_labels = { [0] = "full", [1] = "medium", [2] = "low", [3] = "critically low" }
    local key_fragment = {}
    for j = 1, math.min(len - 1, 6) do
        key_fragment[#key_fragment + 1] = string.format("%02x", data[offset + 1 + j] or 0)
    end
    return {
        protocol = "FindMy",
        battery_state = battery_labels[battery_state] or "unknown",
        key_fragment = table.concat(key_fragment, ""),
        status_raw = string.format("%02x", status),
    }
end

function parse(input)
    local a = meta_attrs(input)
    if not a or a.continuity_has_findmy ~= "true" or not a.continuity_payload_hex then
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
        if t == 0x12 then
            local info = decode_findmy(data, pos - 1, len)
            local attrs = {}
            for k, v in pairs(info) do
                attrs[k] = tostring(v)
            end
            attrs["type_byte"] = string.format("0x%02x", t)
            attrs["beaconformat"] = info.protocol
            entries[#entries + 1] = {
                id = "apple_12",
                displayName = info.protocol,
                attributes = attrs,
            }
        end
        pos = pos + len
    end
    if #entries == 0 then
        return {}, {}
    end
    local ui = {
        device_type = "TRACKER",
        custom_icon = assets.icon,
        custom_icon_tint = assets.icon_tint,
        display_name = "FindMy",
    }
    return entries, ui
end
