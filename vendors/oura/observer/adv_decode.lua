-- Oura Ring advertisements (ourakit RingScanRecord).
-- Match: SIG company 0x02B2 and/or service UUID 98ED0001-A541-11E4-B6A0-0002A5D5C51B.
-- Manufacturer payload (company id omitted): [version][hw<<4|mode][color<<4|size][design]

local ENTRY_ID = "oura"
local PROTOCOL = "oura_ring"
local COMPANY_ID = "02B2"
local SERVICE_UUID = "98ed0001a54111e4b6a00002a5d5c51b"
local HARDWARE = {
  [0] = "FRODO",
  [1] = "PROTOTYPE",
  [2] = "GANDALF_WITH_CYPRESS",
  [3] = "GEN2M",
  [4] = "GEN2X",
  [5] = "GEN4K",
  [6] = "GEN4",
  [7] = "COOPER",
  [8] = "BENTLEY",
  [9] = "NOMAD",
  [10] = "NOMAD2",
  [11] = "SUMMIT",
  [12] = "ASTON",
}

local DESIGN_LEGACY = {
  [0] = "FRODO",
  [1] = "HERITAGE",
  [2] = "BALANCE",
  [3] = "BALANCE_DIAMOND",
  [4] = "GEMMA",
  [5] = "GOLLUM_I1",
  [6] = "SIMPLE",
  [7] = "PROTO",
  [8] = "OREO_ORIGINAL",
  [9] = "JADE",
  [10] = "COOPER",
}

local COLOR_LEGACY = {
  [1] = "GLOSSY_WHITE",
  [2] = "GLOSSY_BLACK",
  [3] = "STEALTH_BLACK",
  [4] = "ROSE",
  [5] = "SILVER",
  [6] = "MATT_SILVER",
  [7] = "GLOSSY_GOLD",
  [8] = "MATT_GOLD",
  [9] = "BLACK_AND_GOLD",
  [10] = "TITANIUM_AND_GOLD",
  [11] = "PROTO",
  [12] = "BRUSHED_SILVER",
  [13] = "MIDNIGHT",
  [14] = "PETAL",
  [15] = "TIDE",
}

local COLOR_OLD = {
  [1] = "GLOSSY_BLACK",
  [2] = "STEALTH_BLACK",
  [3] = "SILVER",
  [4] = "ROSE",
  [5] = "SILVER",
  [6] = "GLOSSY_GOLD",
}

local COLOR_GEN4 = {
  [0] = "PROTO",
  [1] = "SILVER",
  [2] = "GLOSSY_GOLD",
  [3] = "ROSE",
  [4] = "GLOSSY_BLACK",
  [5] = "STEALTH_BLACK",
  [6] = "BRUSHED_SILVER",
  [7] = "MIDNIGHT",
  [8] = "PETAL",
  [9] = "TIDE",
  [10] = "CLOUD",
}

local COLOR_COOPER = {
  [0] = "PROTO",
  [1] = "SILVER",
  [2] = "GLOSSY_GOLD",
  [3] = "DEEP_ROSE",
  [4] = "GLOSSY_BLACK",
  [5] = "STEALTH_BLACK",
  [6] = "BRUSHED_SILVER",
}

local DESIGN_GEN4 = {
  [0] = "PROTO",
  [1] = "OREO_ORIGINAL",
  [2] = "JADE",
}

local DESIGN_COOPER = {
  [0] = "PROTO",
  [1] = "COOPER",
}

local function normalize_uuid(u)
  if type(u) ~= "string" then
    return ""
  end
  return u:lower():gsub("%-", ""):gsub("^0x", "")
end

local function has_oura_service(input)
  local lists = { input.service_uuids, input.service_uuids_16 }
  for _, list in ipairs(lists) do
    if type(list) == "table" then
      for _, u in pairs(list) do
        if normalize_uuid(u) == SERVICE_UUID then
          return true
        end
      end
    end
  end
  if type(input.service_data) == "table" then
    for key, _ in pairs(input.service_data) do
      if normalize_uuid(key) == SERVICE_UUID then
        return true
      end
    end
  end
  return false
end

local function mfg_payload(input)
  local mfg = input.manufacturer_data
  if type(mfg) ~= "table" then
    return nil
  end
  local data = mfg[COMPANY_ID] or mfg["02b2"] or mfg[COMPANY_ID:lower()]
  if type(data) ~= "string" or data == "" then
    return nil
  end
  data = data:gsub("%s+", ""):lower()
  if #data < 2 or (#data % 2) ~= 0 then
    return nil
  end
  return data
end

local function byte_at(hex, index0)
  local i = index0 * 2 + 1
  if i + 1 > #hex then
    return nil
  end
  return tonumber(hex:sub(i, i + 1), 16)
end

local function is_gen4(hw)
  return hw == "GEN4" or hw == "GEN4K"
end

local function decode_mode(usage, version)
  if usage == nil then
    return {
      in_factory_reset = "false",
      in_charger = "false",
      in_pairing_mode = "false",
    }
  end
  if version < 4 then
    local factory = (usage == 1)
    local charger_or_pair = (usage == 2 or usage == 1)
    return {
      in_factory_reset = factory and "true" or "false",
      in_charger = charger_or_pair and "true" or "false",
      in_pairing_mode = charger_or_pair and "true" or "false",
      mode_legacy = tostring(usage),
    }
  end
  return {
    in_factory_reset = (bits.band(usage, 1) == 1) and "true" or "false",
    in_charger = (bits.band(usage, 2) == 2) and "true" or "false",
    in_pairing_mode = (bits.band(usage, 4) == 4) and "true" or "false",
  }
end

local function decode_color(hw, nibble)
  if is_gen4(hw) then
    return COLOR_GEN4[nibble] or "UNKNOWN"
  end
  if hw == "COOPER" then
    return COLOR_COOPER[nibble] or "UNKNOWN"
  end
  if hw == "BENTLEY" or hw == "ASTON" or hw == "PROTOTYPE" then
    return "PROTO"
  end
  -- Older families use legacy Color.parse on the nibble; short payloads may use fromOldCode.
  return COLOR_LEGACY[nibble] or COLOR_OLD[nibble] or "UNKNOWN"
end

local function decode_design(hw, nibble)
  if is_gen4(hw) then
    return DESIGN_GEN4[nibble] or "UNKNOWN"
  end
  if hw == "COOPER" then
    return DESIGN_COOPER[nibble] or "UNKNOWN"
  end
  if hw == "BENTLEY" or hw == "PROTOTYPE" then
    return "PROTO"
  end
  if hw == "ASTON" then
    return (nibble == 0) and "PROTO" or "UNKNOWN"
  end
  return DESIGN_LEGACY[nibble] or "UNKNOWN"
end

local function pretty(s)
  if not s or s == "" or s == "UNKNOWN" then
    return nil
  end
  return (s:lower():gsub("_", " "):gsub("(%a)([%w]*)", function(a, b)
    return a:upper() .. b
  end))
end

local function build_display_info(attrs)
  local parts = {}
  local hw = pretty(attrs.hardware_type)
  if hw then
    parts[#parts + 1] = hw
  end
  local color = pretty(attrs.color)
  if color then
    parts[#parts + 1] = color
  end
  if attrs.size and attrs.size ~= "" and attrs.size ~= "-1" then
    parts[#parts + 1] = "size " .. attrs.size
  end
  local flags = {}
  if attrs.in_pairing_mode == "true" then
    flags[#flags + 1] = "pairing"
  end
  if attrs.in_charger == "true" then
    flags[#flags + 1] = "charger"
  end
  if attrs.in_factory_reset == "true" then
    flags[#flags + 1] = "factory reset"
  end
  if #flags > 0 then
    parts[#parts + 1] = table.concat(flags, ", ")
  end
  if #parts == 0 then
    return "Oura Ring"
  end
  return table.concat(parts, " · ")
end

function parse(input)
  local has_svc = has_oura_service(input)
  local payload = mfg_payload(input)
  if not has_svc and not payload then
    return {}, {}
  end

  local name = input.device_name or ""
  local attrs = {
    protocol = PROTOCOL,
    company_id = COMPANY_ID,
    service_uuid = "98ed0001-a541-11e4-b6a0-0002a5d5c51b",
    has_service_uuid = has_svc and "true" or "false",
    device_name = name,
    hardware_type = "UNKNOWN",
    color = "UNKNOWN",
    design = "UNKNOWN",
    size = "-1",
    adv_version = "",
    in_factory_reset = "false",
    in_charger = "false",
    in_pairing_mode = "false",
  }

  if payload then
    attrs.manufacturer_payload_hex = payload
    local version = byte_at(payload, 0)
    if version ~= nil then
      attrs.adv_version = tostring(version)
      local mode_byte = byte_at(payload, 1)
      if mode_byte ~= nil then
        local usage = bits.band(mode_byte, 15)
        local hw_n = bits.rshift(mode_byte, 4)
        local hw = HARDWARE[hw_n] or "UNKNOWN"
        attrs.hardware_type = hw
        attrs.hardware_type_code = tostring(hw_n)

        local mode = decode_mode(usage, version)
        for k, v in pairs(mode) do
          attrs[k] = v
        end
        attrs.mode_nibble = tostring(usage)

        local size_color = byte_at(payload, 2)
        if size_color ~= nil then
          local size = bits.band(size_color, 15)
          local color_n = bits.rshift(size_color, 4)
          attrs.size = tostring(size)
          attrs.color_code = tostring(color_n)
          attrs.color = decode_color(hw, color_n)

          local design_byte = byte_at(payload, 3)
          if design_byte ~= nil then
            local design_n = bits.band(design_byte, 15)
            attrs.design_code = tostring(design_n)
            attrs.design = decode_design(hw, design_n)
          end
        end
      end
    end
  end

  local display_info = build_display_info(attrs)
  local display_name = "Oura Ring"
  if attrs.hardware_type ~= "UNKNOWN" then
    display_name = "Oura " .. pretty(attrs.hardware_type)
  end

  return {
    {
      id = ENTRY_ID,
      display_name = display_name,
      attributes = attrs,
    },
  }, {
    device_type = "HEALTH",
    custom_icon = "assets/oura.svg",
    display_name = display_name,
    display_info = display_info,
  }
end
