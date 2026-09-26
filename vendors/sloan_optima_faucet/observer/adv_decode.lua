-- Sloan Optima Gen1 faucet (Sloan Connect).
-- Sample: FAUCET ADSKU02 A0149 — adv service d0aba888-…c900 + Battery 0x180F;
-- scan response Complete Local Name "FAUCET ADSKU02 A0149".

local ENTRY_ID = "sloan_optima_faucet"
local PROTOCOL = "sloan_optima"
local FAUCET_SVC = "d0aba888fb104dc99b17bdd8f490c900"

-- "FAUCET ADSKU02 A0149" → sku=ADSKU02, unit=A0149
local function parse_faucet_name(name)
  if not name or name == "" then
    return nil, nil, nil
  end
  local upper = name:upper()
  if not upper:match("^FAUCET%s") and upper ~= "FAUCET" then
    return nil, nil, nil
  end
  local sku, unit = upper:match("^FAUCET%s+(%S+)%s+(%S+)$")
  if sku then
    return "FAUCET", sku, unit
  end
  local only_sku = upper:match("^FAUCET%s+(%S+)$")
  if only_sku then
    return "FAUCET", only_sku, nil
  end
  return "FAUCET", nil, nil
end

function parse(input)
  local name = input.device_name or ""
  local family, sku, unit = parse_faucet_name(name)
  local gen1 = adv.has_uuid(input, FAUCET_SVC)

  -- Manifest already ORs name / service UUID; still reject unrelated hits.
  if not family and not gen1 then
    return {}, {}
  end

  local display_info = "Sloan Optima"
  if sku and unit then
    display_info = string.format("Sloan Optima · %s · %s", sku, unit)
  elseif sku then
    display_info = "Sloan Optima · " .. sku
  elseif name ~= "" then
    display_info = "Sloan Optima · " .. name
  end

  local attrs = {
    protocol = PROTOCOL,
    generation = gen1 and "gen1" or "unknown",
    device_name = name,
    gen1_faucet_service = gen1 and "true" or "false",
  }
  if sku then
    attrs.sku = sku
  end
  if unit then
    attrs.unit_id = unit
  end

  return {
    {
      id = ENTRY_ID,
      display_name = "Sloan Optima",
      attributes = attrs,
    },
  }, {
    device_type = "SMART_HOME",
    custom_icon = "assets/faucet.svg",
    custom_icon_tint = "#0B6E99",
    display_info = display_info,
  }
end
