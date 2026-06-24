-- Oclean Y3L peripheral: dynamic manufacturer AD carries 6-byte bdaddr; command replies on bb86.

local SVC = uuids.OCLEAN_SERVICE
local CHR_NOTIFY = uuids.OCLEAN_READ_NOTIFY

local ADV_PROFILE_ID = "leg_adv_ind"
-- Flags + 128-bit UUID list (before manufacturer-specific TLV).
local ADV_PREFIX_HEX = "02010411071bd790ece8b975800a4644d30104eda6"
local SCAN_RSP_HEX = "0b094f636c65616e2059334c"

local function battery_percent()
  local pct = tonumber(vars.battery_percent) or 36
  if pct < 0 then
    return 0
  end
  if pct > 100 then
    return 100
  end
  return pct
end

local function bd_addr_to_mfg_hex(addr)
  if not addr or addr == "" then
    return nil
  end
  local parts = {}
  for byte in addr:lower():gmatch("%x%x") do
    parts[#parts + 1] = byte
  end
  if #parts ~= 6 then
    return nil
  end
  local rev = {}
  for i = #parts, 1, -1 do
    rev[#rev + 1] = parts[i]
  end
  return table.concat(rev)
end

local function apply_adv_bdaddr()
  if type(get_adv_bd_addr) ~= "function" or type(adv_set_data) ~= "function" then
    return
  end
  local addr = get_adv_bd_addr(ADV_PROFILE_ID)
  if not addr or addr == "" then
    print("oclean: get_adv_bd_addr returned empty")
    return
  end
  local mfg = bd_addr_to_mfg_hex(addr)
  if not mfg or #mfg ~= 12 then
    print("oclean: bd_addr_to_mfg_hex failed for " .. tostring(addr))
    return
  end
  local adv_hex = (ADV_PREFIX_HEX .. "07ff" .. mfg):lower()
  local ok, err = adv_set_data(ADV_PROFILE_ID, adv_hex, SCAN_RSP_HEX)
  if ok ~= true then
    print("oclean: adv_set_data: " .. tostring(err))
  end
end

local function hex_prefix(input, n)
  local hex = bin_to_hex(input)
  if not hex or #hex < n * 2 then
    return ""
  end
  return hex:sub(1, n * 2):lower()
end

local function notify_battery()
  local pct = battery_percent()
  ble_notify(SVC, CHR_NOTIFY, string.format("0303000000%02X", pct))
end

local function notify_device_info()
  local chunk1 = vars.device_info_chunk1 or "030223240C010100000100000C01014C00020049"
  ble_notify(SVC, CHR_NOTIFY, chunk1)
  delay(0.05, "notify_device_info_part2")
end

function notify_device_info_part2()
  local chunk2 = vars.device_info_chunk2 or "03021A060C0B010B00010000F000120022030000"
  ble_notify(SVC, CHR_NOTIFY, chunk2)
end

function push_startup_battery_notify()
  notify_battery()
end

function on_read_battery(input)
  return string.char(battery_percent())
end

function on_write_command(input)
  local hex3 = hex_prefix(input, 3)
  local hex2 = hex_prefix(input, 2)
  if hex3 == "030201" then
    notify_device_info()
  elseif hex2 == "0303" then
    notify_battery()
  end
  return input
end

function on_startup()
  apply_adv_bdaddr()
  gfx_show("toothbrush")
  delay(0.5, "push_startup_battery_notify")
  gfx_print_notification(
    string.format("Oclean %s sim · %d%%", vars.model_hint or "Y3L", battery_percent()),
    "top_center",
    0,
    8
  )
end
