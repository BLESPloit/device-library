-- Google Nearby style service-data advertisements (FCF1, FE9F, FEF3, FCC0).

local NEARBY_UUID16 = {
  fcf1 = true,
  fe9f = true,
  fef3 = true,
  fcc0 = true,
}

local function norm_hex(h)
  if not h or type(h) ~= "string" then
    return ""
  end
  return h:gsub("%s+", ""):lower()
end

local function uuid16_from_service_data_key(key)
  if not key or type(key) ~= "string" then
    return nil
  end
  local n = key:gsub("-", ""):lower()
  if #n >= 8 and n:sub(1, 4) == "0000" then
    return n:sub(5, 8)
  end
  if #n == 4 then
    return n
  end
  return nil
end

local function find_nearby_service_data(service_data)
  if not service_data or type(service_data) ~= "table" then
    return nil, nil
  end
  for key, value in pairs(service_data) do
    if type(value) == "string" then
      local u16 = uuid16_from_service_data_key(tostring(key))
      if u16 and NEARBY_UUID16[u16] then
        return u16, norm_hex(value)
      end
    end
  end
  return nil, nil
end

function parse(input)
  local entries = {}
  local ui = {
    device_type = "NEARBY",
    custom_icon = "assets/google.svg",
  }

  local u16, hex = find_nearby_service_data(input.service_data)
  if not u16 then
    return entries, ui
  end

  entries[1] = {
    id = "google_nearby",
    display_name = "Google Nearby",
    attributes = {
      service_uuid_16 = "0x" .. string.upper(u16),
      service_data_hex = hex,
    },
  }
  ui.display_info = "Nearby · service 0x" .. string.upper(u16)
  return entries, ui
end
