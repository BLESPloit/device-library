-- HomeKit accessory advertisement (Apple company 004C, HAP subtype 0x06).
-- Not a Continuity TLV: the second byte is an interval/length field, not a TLV length.
-- Type 0x11 is an encrypted notification when that second byte does not fit a Continuity TLV.

local ICON = "assets/homekit.svg"
local TINT_PAIRED = "#8E8E93"
local TINT_UNPAIRED = "#FF9F0A"

--- Length-13 advertising interval/length bytes (low 5 bits = 13).
local AIL_LEN13 = {
    [0x2D] = true,
    [0x4D] = true,
    [0x6D] = true,
    [0x8D] = true,
    [0xAD] = true,
    [0xCD] = true,
    [0xED] = true,
}

local CATEGORY_NAME = {
    [1] = "Other",
    [2] = "Bridge",
    [3] = "Fan",
    [4] = "Garage door",
    [5] = "Lightbulb",
    [6] = "Door lock",
    [7] = "Outlet",
    [8] = "Switch",
    [9] = "Thermostat",
    [10] = "Sensor",
    [11] = "Security system",
    [12] = "Door",
    [13] = "Window",
    [14] = "Window covering",
    [15] = "Programmable switch",
    [16] = "Range extender",
    [17] = "IP camera",
    [18] = "Video doorbell",
    [19] = "Air purifier",
    [20] = "Heater",
    [21] = "Air conditioner",
    [22] = "Humidifier",
    [23] = "Dehumidifier",
    [24] = "Apple TV",
    [25] = "HomePod",
    [26] = "Speaker",
    [27] = "AirPort",
    [28] = "Sprinkler",
    [29] = "Faucet",
    [30] = "Shower head",
    [31] = "Television",
    [32] = "Remote",
    [33] = "Router",
    [34] = "Audio receiver",
    [35] = "Set-top box",
    [36] = "Streaming stick",
}

local CATEGORY_DEVICE_TYPE = {
    [3] = "SMART_HOME",
    [4] = "SECURITY",
    [5] = "SMART_HOME",
    [6] = "SECURITY",
    [7] = "SMART_HOME",
    [8] = "SMART_HOME",
    [9] = "SENSOR_ENVIRONMENTAL",
    [10] = "SENSOR_ENVIRONMENTAL",
    [11] = "SECURITY",
    [12] = "SECURITY",
    [13] = "SECURITY",
    [15] = "SMART_HOME",
    [16] = "NETWORK",
    [24] = "TV_DISPLAY",
    [25] = "AUDIO",
    [26] = "AUDIO",
    [27] = "NETWORK",
    [31] = "TV_DISPLAY",
    [33] = "NETWORK",
    [35] = "TV_DISPLAY",
    [36] = "TV_DISPLAY",
}

local function empty()
    return {}, {}
end

local function apple_payload(input)
    local raw = input.raw_adv_hex or input.adv_data_hex_combined or ""
    local segments = adv.manufacturer(raw, "004C")
    if #segments > 0 then
        return hex.norm(segments[1])
    end
    local mfg = input.manufacturer_data
    local raw_hex = mfg and mfg["004C"]
    if type(raw_hex) == "string" and raw_hex ~= "" then
        return hex.norm(raw_hex)
    end
    return ""
end

--- True when byte 2 is a Continuity TLV length that fits in the payload.
local function continuity_length_fits(h)
    local n = hex.len(h)
    if n < 2 then
        return false
    end
    local len = hex.byte(h, 2)
    if len == 0 then
        return false
    end
    return (2 + len) <= n
end

local function hap_ail_ok(ail, remaining)
    if bits.band(ail, 0x1F) ~= remaining then
        return false
    end
    if remaining == 13 then
        return AIL_LEN13[ail] == true
    end
    if remaining == 17 then
        return ail == 0x31
    end
    return false
end

local function emit(attrs, display_name, device_type, tint, display_info, hint)
    local entry = {
        id = "homekit",
        displayName = display_name,
        attributes = attrs,
    }
    if hint and hint ~= "" then
        entry.hint = hint
    end
    local ui = {
        device_type = device_type,
        custom_icon = ICON,
        custom_icon_tint = tint,
        display_info = display_info,
    }
    return { entry }, ui
end

local function decode_encrypted(h)
    if hex.len(h) < 8 or continuity_length_fits(h) then
        return nil
    end
    local attrs = {
        protocol = "homekit",
        record_type = "0x11",
        advertising_id = hex.slice(h, 3, 6),
    }
    return emit(attrs, "Encrypted notification", "GENERIC", TINT_UNPAIRED, "Encrypted notification")
end

local function decode_discoverable(h)
    local n = hex.len(h)
    if n < 2 then
        return nil
    end
    local ail = hex.byte(h, 2)
    local remaining = n - 2
    if not hap_ail_ok(ail, remaining) then
        return nil
    end

    local status = hex.byte(h, 3)
    local paired = bits.band(status, 0x01) == 0
    local category = bits.le16(h, 10)
    local category_name = CATEGORY_NAME[category] or "HomeKit"
    local device_type = CATEGORY_DEVICE_TYPE[category] or "GENERIC"
    local attrs = {
        protocol = "homekit",
        record_type = "0x06",
        paired = paired and "true" or "false",
        device_id = hex.slice(h, 4, 6),
        category = tostring(category),
        category_name = category_name,
        global_state_number = tostring(bits.le16(h, 12)),
        config_number = tostring(hex.byte(h, 14)),
        compatible_version = tostring(hex.byte(h, 15)),
    }
    if remaining == 17 then
        attrs.setup_hash = hex.slice(h, 16, 4)
    end
    local tint = paired and TINT_PAIRED or TINT_UNPAIRED
    local pair_label = paired and "Paired" or "Unpaired"
    local display_info
    if CATEGORY_NAME[category] then
        display_info = "HomeKit " .. category_name .. " · " .. pair_label
    else
        display_info = "HomeKit · " .. pair_label
    end
    local hint = nil
    if not paired then
        hint = "Unpaired. Pair it from the Apple Home app using the setup code on the accessory."
    end
    return emit(attrs, category_name, device_type, tint, display_info, hint)
end

function parse(input)
    local h = apple_payload(input)
    if h == "" then
        return empty()
    end
    local subtype = hex.byte(h, 1)
    local entries, ui
    if subtype == 0x06 then
        entries, ui = decode_discoverable(h)
    elseif subtype == 0x11 then
        entries, ui = decode_encrypted(h)
    end
    if not entries then
        return empty()
    end
    return entries, ui
end
