-- check_ios_model.lua
-- Devices identified as Apple Nearby Info (i.e. almost
-- always an iOS device), connect and read DIS 0x180A / 0x2A24 (Model Number
-- String), then map the raw Apple identifier (e.g. "iPhone15,3") to the
-- marketing name ("iPhone 14 Pro Max") via the device-local
-- assets/ios-device-identifiers.json file.
--
-- Also reads GAP 0x1800 / 0x2A00 for the user-visible device name — stored as
-- device_name only; the scan-row title uses the marketing name (not the generic
-- "iPhone" GAP label).
--
-- Do not set display_info here: the observer keeps that line for Nearby activity
-- (screen state, etc.). Only enrichment_display_name promotes the list title.
--
-- Safety: only reads 2 characteristics from standard Apple-public services.
-- Neither requires pairing on iOS. Ephemeral Inspect sessions are torn down when appropriate.

local GAP_SVC  = "1800"
local GAP_NAME = "2a00"
local DIS_SVC  = "180a"
local DIS_MODEL = "2a24"

local function marketing_name_for(identifier, db)
  if identifier == nil or identifier == "" or db == nil then return nil end
  local id = identifier:gsub("^%s+", ""):gsub("%s+$", "")
  for _, section in pairs(db) do
    if type(section) == "table" then
      local hit = section[id]
      if hit ~= nil and hit ~= "" then return hit end
    end
  end
  local direct = db[id]
  if direct ~= nil and direct ~= "" then return direct end
  return nil
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

function run()
  log("check_ios_model: start")

  local name = ble_read_utf8_trim(GAP_SVC, GAP_NAME)
  if name ~= nil and name ~= "" then
    fp_set("device_name", name)
  end

  local identifier = ble_read_utf8_trim(DIS_SVC, DIS_MODEL)
  if identifier == nil or identifier == "" then
    log("check_ios_model: model read failed or empty")
    if name ~= nil and name ~= "" then
      fp_set("enrichment_display_name", name)
    end
    return
  end

  fp_set("model_number", identifier)

  local db = data.load_json("ios-device-identifiers.json")
  local mkt = marketing_name_for(identifier, db)
  if mkt ~= nil then
    fp_set("ios_model", mkt)
    log("check_ios_model: " .. identifier .. " → " .. mkt)
  else
    fp_set("ios_model", identifier)
    log("check_ios_model: no marketing name for " .. identifier)
  end

  -- Scan-row title: prefer full marketing name, then Apple identifier, then GAP
  -- name (often just "iPhone"). Never touch display_info — observer uses it for
  -- Nearby activity subtitle.
  local title = mkt or identifier
  if title == nil or title == "" then
    title = name
  end
  if title ~= nil and title ~= "" then
    fp_set("enrichment_display_name", title)
  end

  fp_append("stage4_ios", {
    identifier = identifier,
    marketing_name = mkt or "",
    device_name = name or "",
  }, "iOS model")
end
