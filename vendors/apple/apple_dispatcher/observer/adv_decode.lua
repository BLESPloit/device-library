-- Apple Continuity TLV scan only — decoders run in apple_* observer scripts.
-- Protocol reference: https://github.com/furiousMAC/continuity (Wireshark FIELDS.md, messages/)
-- iBeacon payload (TLV 0x02) is only flagged here; devices/ibeacon decodes it.

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

--- Walk BLE AD structures and collect Apple 0x004C manufacturer inner payloads.
local function extract_apple_manufacturer_inners_from_raw(raw_hex)
    local out = {}
    if not raw_hex or #raw_hex < 6 then return out end
    local raw = hex_to_bytes(raw_hex)
    local i = 1
    while i <= #raw do
        local elen = raw[i] or 0
        if elen == 0 then break end
        if i + elen > #raw then break end
        local ad_type = raw[i + 1] or 0
        if ad_type == 0xFF and elen >= 4 then
            local cid = (raw[i + 2] or 0) + bits.lshift(raw[i + 3] or 0, 8)
            if cid == 0x004C then
                local inner_start = i + 4
                local inner_end = i + elen
                if inner_start <= inner_end then
                    local chunk = {}
                    for j = inner_start, inner_end do
                        chunk[#chunk + 1] = raw[j]
                    end
                    out[#out + 1] = chunk
                end
            end
        end
        i = i + elen + 1
    end
    return out
end

--- Collect unique continuity TLV type bytes in first-seen order; fill type set for flags.
local function scan_continuity_tlv_types(data, ordered, has)
    local pos = 1
    while pos <= #data - 1 do
        local t = data[pos]
        local len = data[pos + 1] or 0
        pos = pos + 2
        if len == 0 or pos + len - 1 > #data then break end
        if not has[t] then
            has[t] = true
            ordered[#ordered + 1] = t
        end
        pos = pos + len
    end
end

local function format_type_list(types)
    local parts = {}
    for _, t in ipairs(types) do
        parts[#parts + 1] = string.format("0x%02x", t)
    end
    return table.concat(parts, ",")
end

--- Types with a dedicated apple_* observer (excluded from generic "unknown" fallback).
local SUBSCRIPT_TYPES = {
    [0x07] = true,
    [0x0A] = true,
    [0x0C] = true,
    [0x0F] = true,
    [0x10] = true,
    [0x12] = true,
}

--- 0x02 is the iBeacon-in-Apple signature; devices/ibeacon decodes it (priority 40).
local function tlv_recognized_elsewhere(t)
    return t == 0x02
end

local function collect_unknown_tlv_types(ordered)
    local unk = {}
    for _, t in ipairs(ordered) do
        if not SUBSCRIPT_TYPES[t] and not tlv_recognized_elsewhere(t) then
            unk[#unk + 1] = t
        end
    end
    return unk
end

function parse(input)
    local segments = extract_apple_manufacturer_inners_from_raw(input.raw_adv_hex)
    local ordered_types = {}
    local has_type = {}

    if #segments > 0 then
        for s = 1, #segments do
            scan_continuity_tlv_types(segments[s], ordered_types, has_type)
        end
    end

    local payload_hex = ""
    if #segments > 0 then
        local parts = {}
        for _, seg in ipairs(segments) do
            for _, b in ipairs(seg) do
                parts[#parts + 1] = string.format("%02x", b)
            end
        end
        payload_hex = table.concat(parts, "")
    else
        local mfg = input.manufacturer_data
        local raw_hex = mfg and mfg["76"]
        if raw_hex and #raw_hex > 0 then
            local data = hex_to_bytes(raw_hex)
            scan_continuity_tlv_types(data, ordered_types, has_type)
            payload_hex = raw_hex
        end
    end

    if payload_hex == "" and #ordered_types == 0 then
        return {}, {}
    end

    local function flag(t)
        return (has_type[t] and "true") or "false"
    end

    local unknown_types = collect_unknown_tlv_types(ordered_types)
    local has_unknown = #unknown_types > 0

    --- Nearby Info = 0x10, Nearby Action = 0x0F (and legacy 0x0A AirPlay Source slot); see furiousMAC FIELDS.md
    local attrs = {
        beaconformat = "AppleContinuity",
        continuity_payload_hex = payload_hex,
        continuity_tlv_types = format_type_list(ordered_types),
        continuity_has_proximity = flag(0x07),
        continuity_has_nearbyinfo = flag(0x10),
        continuity_has_findmy = flag(0x12),
        continuity_has_handoff = flag(0x0C),
        continuity_has_nearbyaction = ((has_type[0x0F] or has_type[0x0A]) and "true") or "false",
        continuity_has_ibeacon = flag(0x02),
        continuity_has_unknown_tlv = has_unknown and "true" or "false",
    }
    if has_unknown then
        attrs.continuity_unknown_tlv_types = format_type_list(unknown_types)
    end

    local meta_entry = {
        id = "apple_meta",
        displayName = "Apple Continuity",
        attributes = attrs,
    }

    if not has_unknown then
        return { meta_entry }, {}
    end
    local ui = {
        device_type = "NEARBY",
        custom_icon = "assets/apple.svg",
        custom_icon_tint = assets.icon_tint,
        display_name = "Apple unknown",
        display_info = "TLV " .. format_type_list(unknown_types),
    }
    return { meta_entry }, ui
end
