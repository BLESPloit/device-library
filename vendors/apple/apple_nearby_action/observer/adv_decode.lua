-- Nearby Action: outer TLV 0x0F (spec); 0x0A legacy / AirPlay Source-shaped frames.
-- Action type enum: https://github.com/furiousMAC/continuity/blob/master/messages/nearby_action.md

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

--- Per furiousMAC nearby_action.md (action type byte after flags for 0x0F).
local ACTION_TYPES = {
    [0x01] = "Apple TV Setup",
    [0x04] = "Mobile Backup",
    [0x05] = "Watch Setup",
    [0x06] = "Apple TV Pair",
    [0x07] = "Internet Relay",
    [0x08] = "Wi-Fi Password",
    [0x09] = "iOS Setup",
    [0x0A] = "Repair",
    [0x0B] = "Speaker Setup",
    [0x0C] = "Apple Pay",
    [0x0D] = "Whole Home Audio Setup",
    [0x0E] = "Developer Tools Pairing",
    [0x0F] = "Answered Call",
    [0x10] = "Ended Call",
    [0x11] = "DD Ping",
    [0x12] = "DD Pong",
    [0x13] = "Remote Auto Fill",
    [0x14] = "Companion Link Proximity",
    [0x15] = "Remote Management",
    [0x16] = "Remote Auto Fill Pong",
    [0x17] = "Remote Display",
}

--- TLV 0x0F: flags (1) + action type (1) + …
local function decode_nearby_action_0f(data, offset, len)
    if len < 2 then
        return {
            protocol = "NearbyAction",
            action_type = "incomplete",
            action_known = "no",
            flags_raw = "",
        }
    end
    local flags = data[offset + 1] or 0
    local act = data[offset + 2] or 0
    local label = ACTION_TYPES[act]
    return {
        protocol = "NearbyAction",
        action_type = label or string.format("0x%02x", act),
        action_known = label and "yes" or "no",
        action_code_hex = string.format("0x%02x", act),
        flags_raw = string.format("%02x", flags),
    }
end

--- TLV 0x0A: legacy layout (first byte treated as action id in older captures)
local function decode_nearby_action_0a(data, offset, len)
    local action = data[offset + 1] or 0
    local intent = data[offset + 5] or 0
    local legacy = {
        [0x01] = "Apple TV auto-unlock",
        [0x04] = "Watch auto-unlock",
        [0x0D] = "Hotspot",
        [0x0E] = "Hotspot joining",
        [0x20] = "Remote auto-fill",
        [0x13] = "Watch setup",
    }
    local label = legacy[action] or ACTION_TYPES[action]
    return {
        protocol = "NearbyAction",
        action_type = label or string.format("0x%02x", action),
        action_known = label and "yes" or "no",
        action_code_hex = string.format("0x%02x", action),
        intent_raw = string.format("%02x", intent),
    }
end

function parse(input)
    local a = meta_attrs(input)
    if not a or a.continuity_has_nearbyaction ~= "true" or not a.continuity_payload_hex then
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
        local info
        local eid
        if t == 0x0F then
            info = decode_nearby_action_0f(data, pos - 1, len)
            eid = "apple_0f"
        elseif t == 0x0A then
            info = decode_nearby_action_0a(data, pos - 1, len)
            eid = "apple_0a"
        else
            info = nil
        end
        if info then
            local attrs = {}
            for k, v in pairs(info) do
                attrs[k] = tostring(v)
            end
            attrs["type_byte"] = string.format("0x%02x", t)
            attrs["beaconformat"] = info.protocol
            entries[#entries + 1] = {
                id = eid,
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
        device_type = "PHONE",
        custom_icon = assets.icon,
        custom_icon_tint = assets.icon_tint,
        display_name = "Nearby Action",
    }
    if first.action_known == "yes" and first.action_type then
        local s = first.action_type
        if #s > 40 then
            s = s:sub(1, 37) .. "..."
        end
        ui.display_info = s
    end
    return entries, ui
end
