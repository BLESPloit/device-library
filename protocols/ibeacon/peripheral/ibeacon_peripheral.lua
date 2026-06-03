-- iBeacon peripheral: build legacy ADV payload from `vars` (uuid, major, minor, power).
-- Lua runtime: string + math only (no table library). Uses hex_to_bin / bin_to_hex globals.

local FLAGS_AD         = string.char(0x02, 0x01, 0x06)
local APPLE_COMPANY_LE = string.char(0x4c, 0x00)
local IBEACON_INNER_HDR = string.char(0x02, 0x15)

local adv_profile_id = "main"

--- 32 hex chars (with optional dashes) -> 16-byte binary string
local function uuid_string_to_16_bytes(u)
  if type(u) ~= "string" then
    return nil, "vars.uuid must be a string"
  end
  local h = u:gsub("-", ""):lower()
  if #h ~= 32 then
    return nil, "vars.uuid must be 16 bytes (32 hex chars)"
  end
  if not h:match("^%x+$") then
    return nil, "vars.uuid contains non-hex characters"
  end
  -- hex_to_bin strips whitespace; accepts lower or upper hex
  return hex_to_bin(h), nil
end

local function u16_be(n)
  local v = math.floor(tonumber(n) or 0) % 65536
  return string.char(math.floor(v / 256), v % 256)
end

--- Measured TX power as one signed byte (iBeacon convention)
local function measured_power_byte(p)
  local v = math.floor(tonumber(p) or 0)
  if v < -128 then v = -128 elseif v > 127 then v = 127 end
  if v < 0 then v = v + 256 end
  return string.char(v)
end

--- Full legacy AD data: flags + manufacturer specific (Apple iBeacon)
local function build_ibeacon_adv_data(v)
  local uuid_bytes, err = uuid_string_to_16_bytes(v.uuid)
  if not uuid_bytes then
    return nil, err
  end
  local major = u16_be(v.major)
  local minor = u16_be(v.minor)
  local tx    = measured_power_byte(v.power)

  local mfg_value = APPLE_COMPANY_LE .. IBEACON_INNER_HDR .. uuid_bytes .. major .. minor .. tx
  local ad_mfg    = string.char(1 + #mfg_value, 0xff) .. mfg_value
  return FLAGS_AD .. ad_mfg
end

function on_startup()
  gfx_show("ibeacon_logo")
  -- if vars is missing then just use the static profile
  if type(vars) ~= "table" then
    print("ibeacon_peripheral: vars table missing, falling back to advertising from adv.json")
    return
  end
  local blob, err = build_ibeacon_adv_data(vars)
  if not blob then
    print("ibeacon_peripheral: " .. tostring(err))
    return
  end

  -- adv_set_data expects a hex string; bin_to_hex returns uppercase which is fine
  local ok, adv_err = adv_set_data(adv_profile_id, bin_to_hex(blob))
  if not ok then
    print("ibeacon_peripheral: adv_set_data failed: " .. tostring(adv_err))
    return
  end

  print("ibeacon_peripheral: adv updated on profile " .. adv_profile_id .. " with " .. bin_to_hex(blob))
end