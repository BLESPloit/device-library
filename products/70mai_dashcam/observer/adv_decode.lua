-- 70mai dash cam advertisement, manufacturer company id 0x0909.
-- Identity and registration state only. Registration itself is done in the official app.

local ENTRY_ID = "70mai_dashcam"
local PROTOCOL = "70mai_dashcam"
local TINT_UNREGISTERED = "#ea4f16"
local TINT_REGISTERED = "#808080"

local FC_CONNECTED = 0x01
local FC_REGISTERED = 0x02
local FC_AUTH_MODE = 0x0C
local FC_ENCRYPTED = 0x10
local FC_MAC = 0x20
local FC_CAPABILITY = 0x40

local CAP_CONNECTABLE = 0x01
local CAP_CENTRAL = 0x02
local CAP_ENCRYPTABLE = 0x04
local CAP_BINDABLE = 0x08

local MODULE_NAMES = {
  [42002] = "M500",
  [47002] = "X200",
  [65001] = "A810",
  [69002] = "A510",
  [87002] = "T800",
  [109002] = "T400",
}

local function flag(n, mask)
  if bits.band(n, mask) ~= 0 then
    return "true"
  end
  return "false"
end

local function payload(input)
  local md = input.manufacturer_data
  if type(md) == "table" and type(md["0909"]) == "string" then
    local h = hex.norm(md["0909"])
    if h:sub(1, 4) == "0909" then
      h = h:sub(5)
    end
    if h ~= "" then
      return h
    end
  end
  local raw = input.raw_adv_hex or input.adv_data_hex_combined or ""
  local found = adv.find(raw, 0xFF)
  for i = 1, #found do
    local h = hex.norm(found[i])
    if h:sub(1, 4) == "0909" then
      return h:sub(5)
    end
  end
  return nil
end

function parse(input)
  local data = payload(input)
  if not data or hex.len(data) < 6 then
    return {}, {}
  end

  local channel = bits.le32(data, 1)
  local fc = hex.byte(data, 5)
  local version = bits.band(hex.byte(data, 6), 0x0F)
  local cursor = 7

  local capability = nil
  if bits.band(fc, FC_CAPABILITY) ~= 0 then
    if hex.len(data) < cursor then
      return {}, {}
    end
    capability = hex.byte(data, cursor)
    cursor = cursor + 1
  end

  local adv_bdaddr = ""
  if bits.band(fc, FC_MAC) ~= 0 then
    if hex.len(data) < cursor + 5 then
      return {}, {}
    end
    adv_bdaddr = mac.from_reversed(hex.slice(data, cursor, 6))
  end

  local name = input.device_name or ""
  local name_model = name:match("^70mai_([^_]+)")
  local product_type = math.floor(channel / 1000000)
  local product_module = math.floor(channel / 1000)
  local module_model = MODULE_NAMES[product_module]
  local model = name_model or module_model or "dash cam"

  local registered = bits.band(fc, FC_REGISTERED) ~= 0
  local auth_mode = math.floor(bits.band(fc, FC_AUTH_MODE) / 4)

  local registration = registered and "registered" or "unregistered"

  local hint
  if registered then
    hint = "Registered. Open the official 70mai app with the account that owns this dash cam."
  else
    hint = "Not registered. Use the official 70mai app to register and control this dash cam. Confirm on the device when it asks."
  end

  local attributes = {
    protocol = PROTOCOL,
    vendor = "70mai",
    model = model,
    device_name = name,
    registered = flag(fc, FC_REGISTERED),
    connected = flag(fc, FC_CONNECTED),
    encrypted = flag(fc, FC_ENCRYPTED),
    auth_mode = tostring(auth_mode),
    frame_version = tostring(version),
    device_channel = tostring(channel),
    product_type = tostring(product_type),
    product_module = tostring(product_module),
    adv_bdaddr = adv_bdaddr,
  }
  if capability ~= nil then
    attributes.connectable = flag(capability, CAP_CONNECTABLE)
    attributes.centralable = flag(capability, CAP_CENTRAL)
    attributes.encryptable = flag(capability, CAP_ENCRYPTABLE)
    attributes.bindable = flag(capability, CAP_BINDABLE)
  end
  if module_model and name_model and module_model ~= name_model then
    attributes.module_model = module_model
  end

  local ui = {
    device_type = "CAMERA",
    custom_icon = "assets/icon.svg",
    display_name = "70mai dash camera",
    display_info = model .. " " .. registration,
    custom_icon_tint = registered and TINT_REGISTERED or TINT_UNREGISTERED,
  }

  return {
    {
      id = ENTRY_ID,
      display_name = "70mai dash camera",
      hint = hint,
      attributes = attributes,
    },
  }, ui
end
