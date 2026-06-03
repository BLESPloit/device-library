-- read_device_info.lua
-- Generic fallback: GAP device name + Device Information (0x180A) standard characteristics
-- when present. Uses gatt_has_characteristic when discovery is available to skip absent UUIDs.

local GAP_SVC  = "1800"
local GAP_NAME = "2a00"

local DIS_SVC    = "180a"
local DIS_MFR    = "2a29"
local DIS_MODEL  = "2a24"
local DIS_SERIAL = "2a25"
local DIS_FW     = "2a26"
local DIS_HW     = "2a27"
local DIS_SYSID  = "2a23"
local DIS_PNP    = "2a50"

local function chr_available(svc, chr)
  local h = gatt_has_characteristic(svc, chr)
  if h == nil then return true end
  return h
end

local function one_line(s)
  if s == nil then return "(nil)" end
  s = tostring(s)
  s = string.gsub(s, "[\r\n]+", " ")
  return s
end

local function ble_read_utf8_trim(svc, chr)
  local h = ble_read(svc, chr)
  if not h or h == "" then return nil end
  local bin = hex_to_bin(h)
  if not bin then return nil end
  bin = bin:gsub("%z+", "")
  bin = (bin:match("^%s*(.-)%s*$") or "")
  if bin == "" then return nil end
  return bin
end

local function ble_read_utf8_if_present(svc, chr, label)
  if not chr_available(svc, chr) then
--    log("skip " .. label .. " (not in GATT discovery)")
    return nil
  end
  local v = ble_read_utf8_trim(svc, chr)
  if v == nil or v == "" then
    log(label .. ": (no data)")
  else
    log(label .. ": " .. one_line(v))
  end
  return v
end

local function read_hex_if_present(svc, chr, label)
  if not chr_available(svc, chr) then
--    log("skip " .. label .. " (not in GATT discovery)")
    return nil
  end
  local v = ble_read(svc, chr)
  if v == nil or v == "" then
    log(label .. " (hex): (no data)")
  else
    log(label .. " (hex): " .. one_line(v))
  end
  return v
end

function run()
  log("generic_ble: read_device_info start")

  local name = ble_read_utf8_if_present(GAP_SVC, GAP_NAME, "Device Name")
  if name ~= nil and name ~= "" then
    fp_set("device_name", name)
  end

  local mfr = ble_read_utf8_if_present(DIS_SVC, DIS_MFR, "Manufacturer Name")
  if mfr ~= nil and mfr ~= "" then fp_set("manufacturer_name", mfr) end

  local model = ble_read_utf8_if_present(DIS_SVC, DIS_MODEL, "Model Number")
  if model ~= nil and model ~= "" then fp_set("model_number", model) end

  local serial = ble_read_utf8_if_present(DIS_SVC, DIS_SERIAL, "Serial Number")
  if serial ~= nil and serial ~= "" then fp_set("serialNumberString", serial) end

  local fw = ble_read_utf8_if_present(DIS_SVC, DIS_FW, "Firmware Revision")
  if fw ~= nil and fw ~= "" then fp_set("firmwareRevision", fw) end

  local hw = ble_read_utf8_if_present(DIS_SVC, DIS_HW, "Hardware Revision")
  if hw ~= nil and hw ~= "" then fp_set("hardwareRevision", hw) end

  local sysid = read_hex_if_present(DIS_SVC, DIS_SYSID, "System ID")
  if sysid ~= nil and sysid ~= "" then fp_set("system_id_hex", sysid) end

  local pnp = read_hex_if_present(DIS_SVC, DIS_PNP, "PnP ID")
  if pnp ~= nil and pnp ~= "" then fp_set("pnp_id_hex", pnp) end

  local enrich = nil
  if name ~= nil and name ~= "" then
    enrich = name
  elseif model ~= nil and model ~= "" then
    enrich = model
  elseif mfr ~= nil and mfr ~= "" then
    enrich = mfr
  end
  if enrich ~= nil then
    fp_set("enrichment_display_name", enrich)
  end

  local info_bits = {}
  if model ~= nil and model ~= "" and model ~= enrich then table.insert(info_bits, model) end
  if mfr ~= nil and mfr ~= "" and mfr ~= enrich then table.insert(info_bits, mfr) end
  local base_display = ""
  if #info_bits > 0 then
    base_display = table.concat(info_bits, " · ")
  end

  if base_display ~= "" then
    fp_set("display_info", base_display)
  elseif enrich ~= nil then
    fp_set("display_info", "")
  end

  local attrs = {}
  if name ~= nil then attrs.device_name = name end
  if mfr ~= nil then attrs.manufacturer_name = mfr end
  if model ~= nil then attrs.model_number = model end
  if serial ~= nil then attrs.serialNumberString = serial end
  if fw ~= nil then attrs.firmwareRevision = fw end
  if hw ~= nil then attrs.hardwareRevision = hw end
  if sysid ~= nil then attrs.system_id_hex = sysid end
  if pnp ~= nil then attrs.pnp_id_hex = pnp end
  if next(attrs) ~= nil then
    fp_append("stage4_generic", attrs, "Device info")
  end

  log("generic_ble: read_device_info done")
end
