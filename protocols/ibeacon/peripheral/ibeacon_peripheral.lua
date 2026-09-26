-- iBeacon peripheral: build legacy ADV payload from `vars` (uuid, major, minor, power).
-- Packs stay in hex for adv_set_data.

local FLAGS_AD = "020106"
local APPLE_COMPANY_LE = "4c00"
local IBEACON_INNER_HDR = "0215"

local adv_profile_id = "main"

--- 32 hex chars (with optional dashes) -> 16-octet lowercase hex
local function uuid_string_to_hex(u)
  if type(u) ~= "string" then
    return nil, "vars.uuid must be a string"
  end
  local h = hex.norm(u:gsub("-", ""))
  if hex.len(h) ~= 16 then
    return nil, "vars.uuid must be 16 bytes (32 hex chars)"
  end
  return h, nil
end

--- Measured TX power as one signed byte (iBeacon convention)
local function measured_power_u8(p)
  local v = math.floor(tonumber(p) or 0)
  if v < -128 then v = -128 elseif v > 127 then v = 127 end
  return hex.u8(v)
end

--- Full legacy AD data: flags + manufacturer specific (Apple iBeacon)
local function build_ibeacon_adv_data(v)
  local uuid_hex, err = uuid_string_to_hex(v.uuid)
  if not uuid_hex then
    return nil, err
  end
  local mfg_value = APPLE_COMPANY_LE .. IBEACON_INNER_HDR .. uuid_hex
    .. hex.be16(v.major) .. hex.be16(v.minor) .. measured_power_u8(v.power)
  local ad_mfg = hex.u8(1 + hex.len(mfg_value)) .. "ff" .. mfg_value
  return FLAGS_AD .. ad_mfg
end

function on_startup()
  gfx_show("ibeacon_logo")
  -- if vars is missing then just use the static profile
  if type(vars) ~= "table" then
    print("ibeacon_peripheral: vars table missing, falling back to advertising from adv.json")
    return
  end
  local adv_hex, err = build_ibeacon_adv_data(vars)
  if not adv_hex then
    print("ibeacon_peripheral: " .. tostring(err))
    return
  end

  local ok, adv_err = adv_set_data(adv_profile_id, adv_hex)
  if not ok then
    print("ibeacon_peripheral: adv_set_data failed: " .. tostring(adv_err))
    return
  end

  print("ibeacon_peripheral: adv updated on profile " .. adv_profile_id .. " with " .. adv_hex)
end
