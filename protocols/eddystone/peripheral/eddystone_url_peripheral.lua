-- Eddystone-URL peripheral: legacy ADV with FEAA service data (URL frame).
-- If `vars` has url (+ optional tx_power), build payload; else use static adv.json.
-- Encoding matches google/eddystone URL frame (same table as UrlUtils.kt).

local adv_profile_id = "main"

local FLAGS_AD = "020106"
-- Complete list of 16-bit UUIDs (0x03): Eddystone 0xFEAA LE on air = AA FE
local AD_UUID16_COMPLETE = "0303aafe"

-- Longest scheme prefix first
local SCHEMES = {
  { 1, "https://www." },
  { 0, "http://www." },
  { 3, "https://" },
  { 2, "http://" },
}

-- Eddystone URL expansion codes; greedy longest match first (code, suffix)
local EXPANSIONS = {
  { 0, ".com/" },
  { 1, ".org/" },
  { 2, ".edu/" },
  { 3, ".net/" },
  { 4, ".info/" },
  { 5, ".biz/" },
  { 6, ".gov/" },
  { 7, ".com" },
  { 8, ".org" },
  { 9, ".edu" },
  { 10, ".net" },
  { 11, ".info" },
  { 12, ".biz" },
  { 13, ".gov" },
}

local function measured_power_u8(p)
  local v = math.floor(tonumber(p) or -8)
  if v < -128 then v = -128 elseif v > 127 then v = 127 end
  return hex.u8(v)
end

--- @return hex string or nil, error string or nil
local function encode_url_payload(url)
  if type(url) ~= "string" or url == "" then
    return nil, "vars.url must be a non-empty string"
  end
  local u = url
  local scheme_hex = nil
  for i = 1, #SCHEMES do
    local code = SCHEMES[i][1]
    local prefix = SCHEMES[i][2]
    if u:sub(1, #prefix) == prefix then
      scheme_hex = hex.u8(code)
      u = u:sub(#prefix + 1)
      break
    end
  end
  if not scheme_hex then
    return nil, "vars.url must start with http:// or https:// (optional www.)"
  end

  local parts = { scheme_hex }
  while u ~= "" do
    local matched = false
    for j = 1, #EXPANSIONS do
      local code = EXPANSIONS[j][1]
      local suf = EXPANSIONS[j][2]
      if u:sub(1, #suf) == suf then
        parts[#parts + 1] = hex.u8(code)
        u = u:sub(#suf + 1)
        matched = true
        break
      end
    end
    if not matched then
      parts[#parts + 1] = hex.from_ascii(u:sub(1, 1))
      u = u:sub(2)
    end
  end

  return table.concat(parts), nil
end

local function build_url_frame(url, tx_power)
  local enc, err = encode_url_payload(url)
  if not enc then
    return nil, err
  end
  return hex.u8(0x10) .. measured_power_u8(tx_power) .. enc, nil
end

--- Full legacy AD: flags + 16-bit UUID list + service data (0x16 FEAA + frame)
local function build_eddy_url_adv_data(url, tx_power)
  local service, err = build_url_frame(url, tx_power)
  if not service then
    return nil, err
  end
  local sd_content_len = 1 + 2 + hex.len(service)
  local ad_service = hex.u8(sd_content_len) .. "16aafe" .. service
  return FLAGS_AD .. AD_UUID16_COMPLETE .. ad_service, nil
end

function on_startup()
  gfx_show("eddystone_logo")
  if type(vars) ~= "table" or type(vars.url) ~= "string" then
    print("eddystone_url_peripheral: vars.url missing, using static adv.json")
    return
  end
  local adv_hex, err = build_eddy_url_adv_data(vars.url, vars.tx_power)
  if not adv_hex then
    print("eddystone_url_peripheral: " .. tostring(err))
    return
  end
  local ok, adv_err = adv_set_data(adv_profile_id, adv_hex)
  if not ok then
    print("eddystone_url_peripheral: adv_set_data failed: " .. tostring(adv_err))
    return
  end
  print("eddystone_url_peripheral: adv updated on profile " .. adv_profile_id .. " with " .. adv_hex)
end
