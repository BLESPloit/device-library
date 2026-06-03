-- Quick action: read 24-bit Fast Pair Model ID from GATT (uuids.CHR_MODEL_ID under uuids.SVC_FAST_PAIR).

local function fp_uuids()
  if type(uuids) ~= "table" then
    return nil, nil, "uuids table missing — open script from Fast Pair device pack"
  end
  local svc = uuids.SVC_FAST_PAIR
  local model_chr = uuids.CHR_MODEL_ID
  if not svc or svc == "" or not model_chr or model_chr == "" then
    return nil, nil, "uuids.json missing SVC_FAST_PAIR / CHR_MODEL_ID"
  end
  return svc, model_chr, nil
end

local function norm_hex(h)
  if not h then return "" end
  return (h:gsub("%s+", "")):lower()
end

--- Catalog row from Kotlin [FastPairModelsCatalog] via `data.fast_pair_catalog_lookup`, or JSON fallback.
local function catalog_lookup_row(id6)
  local u = string.upper(id6)
  if data and data.fast_pair_catalog_lookup then
    local ok, row = pcall(function()
      return data.fast_pair_catalog_lookup(u)
    end)
    if ok and type(row) == "table" then
      return row
    end
  end
  if not data or not data.load_json then
    return nil
  end
  local ok, cat = pcall(function()
    return data.load_json("fast_pair/fast_pair_models.json")
  end)
  if not ok or cat == nil or type(cat) ~= "table" then
    return nil
  end
  local models = cat.models
  if type(models) ~= "table" then
    return nil
  end
  return models[u]
end

local function catalog_display_name(row)
  if type(row) ~= "table" then
    return nil
  end
  local n = row.device_name or row.name
  if type(n) == "string" and n ~= "" then
    return n
  end
  return nil
end

function run()
  local SVC_FP, CHR_MODEL_ID, uerr = fp_uuids()
  if not SVC_FP then
    log(uerr)
    return
  end

  if gatt_has_characteristic(SVC_FP, CHR_MODEL_ID) == false then
    log("Fast Pair: Model ID characteristic not found on this connection (missing 0xFE2C service?)")
    return
  end

  local hex = ble_read(SVC_FP, CHR_MODEL_ID)
  hex = norm_hex(hex)
  if hex == "" then
    log("Fast Pair: read Model ID returned empty")
    return
  end

  if #hex < 6 then
    log("Fast Pair: Model ID value too short (expected ≥3 octets): " .. hex)
    return
  end

  local mid_hex = hex:sub(1, 6)
  local mid_uint24 = tonumber(mid_hex, 16)
  local row = catalog_lookup_row(mid_hex)
  local name = catalog_display_name(row)

  local line = string.format("0x%s", mid_hex)
  if name and name ~= "" then
    line = line .. " · " .. name
  end
  log("Fast Pair GATT: " .. line)

  fp_set("fast_pair_gatt_model_id_hex", mid_hex)
  fp_set("display_name", line)

  local attrs = {
    fast_pair_model_id_hex = mid_hex,
    fast_pair_model_id_uint24 = mid_uint24,
    read_hex = hex,
  }
  if name then
    attrs.catalog_display_name = name
  end
  if type(row) == "table" and type(row.manufacturer) == "string" and row.manufacturer ~= "" then
    attrs.catalog_manufacturer = row.manufacturer
  end
  if type(row) == "table" and row.supports_tracking ~= nil then
    attrs.catalog_supports_tracking = row.supports_tracking
  end

  fp_append("google_fast_pair_gatt_model", attrs, "Fast Pair model ID (GATT)")
end
