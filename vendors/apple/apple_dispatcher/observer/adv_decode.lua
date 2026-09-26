-- Apple Continuity TLV scan only — decoders run in apple_* observer scripts.
-- Protocol reference: https://github.com/furiousMAC/continuity (Wireshark FIELDS.md, messages/)
-- iBeacon payload (TLV 0x02) is only flagged here; devices/ibeacon decodes it.

--- Collect unique continuity TLV type bytes in first-seen order; fill type set for flags.
local function scan_continuity_tlv_types(payload_hex, ordered, has)
    local h = hex.norm(payload_hex)
    local n = hex.len(h)
    local i = 1
    while i + 1 <= n do
        local t = hex.byte(h, i)
        local len = hex.byte(h, i + 1)
        i = i + 2
        if len == 0 or i + len - 1 > n then break end
        if not has[t] then
            has[t] = true
            ordered[#ordered + 1] = t
        end
        i = i + len
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
    local raw = input.raw_adv_hex or input.adv_data_hex_combined or ""
    local segments = adv.manufacturer(raw, "004C")
    local ordered_types = {}
    local has_type = {}

    if #segments == 0 then
        local mfg = input.manufacturer_data
        local raw_hex = mfg and mfg["004C"]
        if type(raw_hex) == "string" and raw_hex ~= "" then
            segments = { hex.norm(raw_hex) }
        end
    end

    local payload_hex = ""
    if #segments > 0 then
        payload_hex = table.concat(segments, "")
        for s = 1, #segments do
            scan_continuity_tlv_types(segments[s], ordered_types, has_type)
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
