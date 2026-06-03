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

local function decode_handoff(data, offset, len)
    local hash_bytes = {}
    for j = 1, math.min(len, 4) do
        hash_bytes[#hash_bytes + 1] = string.format("%02x", data[offset + j] or 0)
    end
    return {
        protocol = "Handoff",
        activity_hash = table.concat(hash_bytes, ""),
    }
end

function parse(input)
    local a = meta_attrs(input)
    if not a or a.continuity_has_handoff ~= "true" or not a.continuity_payload_hex then
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
        if t == 0x0C then
            local info = decode_handoff(data, pos - 1, len)
            local attrs = {}
            for k, v in pairs(info) do
                attrs[k] = tostring(v)
            end
            attrs["type_byte"] = string.format("0x%02x", t)
            attrs["beaconformat"] = info.protocol
            entries[#entries + 1] = {
                id = "apple_0c",
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
        device_type = "PHONE",
        custom_icon = assets.icon,
        custom_icon_tint = assets.icon_tint,
        display_name = "Handoff",
        display_info = "Activity hash: " .. (entries[1].attributes.activity_hash or "?"),
    }
    return entries, ui
end
