-- KARR peripheral sim from real QT unit scans (6-byte old MSD + Transparent UART).
-- ADV layout matches field captures: Complete Local Name + Flags + MSD (no scan_rsp).

local SVC = uuids.SVC_TDS
local CHR = uuids.CHR_TDC
local ADV_PROFILE_ID = "karr_old_armed"

local CMD_ACK_OK = 0x00
local CMD_ACK_ERR = 0xFF
local CMD_LOCK = 0x0B
local CMD_UNLOCK = 0x0C
local CMD_REQUEST_AUTH = 0x0E
local CMD_PROVIDE_AUTH = 0x0F
local CMD_AUTH_SUCCESS = 0x10
local CMD_AUTH_FAILED = 0x11
local CMD_SILENT_LOCK = 0x25
local CMD_SILENT_UNLOCK = 0x26
local CMD_SECURE_ARM = 0x44
local CMD_SECURE_DISARM = 0x45

-- Default MSD from 44:B7:D0:6B:D6:55 capture (armed User, VIN 10472, ~12.54V).
local MSD_DEFAULT = { 0x71, 0x30, 0xf4, 0xb7, 0x32, 0xd1 }

local function to_u8(n)
  return math.floor(tonumber(n) or 0) % 256
end

local function bytes_to_hex(bytes)
  local parts = {}
  for i = 1, #bytes do
    parts[i] = hex.u8(bytes[i])
  end
  return table.concat(parts)
end

local function authenticated()
  return vars.authenticated == true or vars.authenticated == "true"
end

local function set_authenticated(v)
  vars.authenticated = v and true or false
  if type(vars_save) == "function" then
    vars_save()
  end
end

local function armed()
  return vars.armed == true or vars.armed == "true"
end

local function auth_required()
  return vars.auth_required ~= false and vars.auth_required ~= "false"
end

local function accept_any_auth()
  return vars.accept_any_auth ~= false and vars.accept_any_auth ~= "false"
end

local function msd_bytes()
  local h = vars.msd_hex
  if type(h) == "string" then
    h = hex.norm(h)
    if hex.len(h) >= 6 then
      local out = {}
      for i = 1, 6 do
        out[i] = hex.byte(h, i)
      end
      return out
    end
  end
  local out = {}
  for i = 1, #MSD_DEFAULT do
    out[i] = MSD_DEFAULT[i]
  end
  return out
end

--- Build Original (0xAA) frame hex. Checksum sums sync slot as 0, then writes 0xAA.
local function generate_aa_hex(cmd, payload)
  payload = payload or {}
  local L = 1 + #payload
  local sum = math.floor(L / 256) + (L % 256) + to_u8(cmd)
  local body = hex.be16(L) .. hex.u8(cmd)
  for i = 1, #payload do
    local b = to_u8(payload[i])
    sum = sum + b
    body = body .. hex.u8(b)
  end
  return "aa" .. body .. hex.u8(-sum)
end

local function notify_frame(cmd, payload)
  if type(SVC) ~= "string" or type(CHR) ~= "string" then
    print("karr: missing uuids.SVC_TDS / CHR_TDC")
    return
  end
  local frame = generate_aa_hex(cmd, payload)
  local ok, err = ble_notify(SVC, CHR, frame)
  if ok ~= true then
    print("karr: ble_notify failed: " .. tostring(err))
  end
end

local function parse_aa(data)
  data = hex.norm(data)
  if hex.len(data) < 5 or hex.slice(data, 1, 1) ~= "aa" then
    return nil
  end
  local len = bits.be16(data, 2)
  if hex.len(data) < (len + 4) then
    return nil
  end
  local cmd = hex.byte(data, 4)
  local payload = {}
  for i = 1, len - 1 do
    payload[i] = hex.byte(data, 4 + i)
  end
  local cs = hex.byte(data, len + 4)
  local sum = 0
  for i = 2, len + 3 do
    sum = sum + hex.byte(data, i)
  end
  if to_u8(sum + cs) ~= 0 then
    return nil
  end
  return { cmd = cmd, payload = payload, len = len }
end

local function unit_name_from_addr(addr)
  if not addr or addr == "" then
    return vars.unit_name or "QT D06BD655"
  end
  local parts = {}
  for byte in addr:upper():gmatch("%x%x") do
    parts[#parts + 1] = byte
  end
  if #parts ~= 6 then
    return vars.unit_name or "QT D06BD655"
  end
  -- Real units: "QT " + last 4 MAC octets (8 hex chars).
  return "QT " .. parts[3] .. parts[4] .. parts[5] .. parts[6]
end

local function apply_adv(is_armed)
  if type(adv_set_data) ~= "function" then
    return
  end
  local msd = msd_bytes()
  local b3 = msd[4]
  if is_armed then
    msd[4] = bits.bor(b3, 0x80)
  else
    msd[4] = bits.band(b3, 0x7F)
  end
  -- Optional VBat override from vars.
  local vbat = tonumber(vars.vbat_raw)
  if vbat then
    if vbat < 0 then
      vbat = 0
    end
    if vbat > 255 then
      vbat = 255
    end
    msd[6] = math.floor(vbat)
  end
  vars.msd_hex = bytes_to_hex(msd)

  local name = vars.unit_name or "QT D06BD655"
  if type(get_adv_bd_addr) == "function" then
    local addr = get_adv_bd_addr(ADV_PROFILE_ID)
    if addr and addr ~= "" then
      name = unit_name_from_addr(addr)
      vars.unit_name = name
    end
  end

  local name_hex = hex.from_ascii(name)
  local adv_hex = hex.u8(1 + #name) .. "09" .. name_hex .. "02010607ff" .. bytes_to_hex(msd)
  local ok, err = adv_set_data(ADV_PROFILE_ID, adv_hex, "")
  if ok ~= true then
    print("karr: adv_set_data: " .. tostring(err))
  end
end

local function set_armed(is_armed)
  vars.armed = is_armed and true or false
  if type(vars_save) == "function" then
    vars_save()
  end
  apply_adv(is_armed)
  if is_armed then
    gfx_print_notification("LOCKED / armed", "top_center", 0, 8)
  else
    gfx_print_notification("UNLOCKED", "top_center", 0, 8)
  end
end

local function require_auth_or_challenge()
  if authenticated() or not auth_required() then
    return true
  end
  notify_frame(CMD_REQUEST_AUTH, { 0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF })
  return false
end

local function handle_provide_auth(payload)
  if not accept_any_auth() then
    if #payload ~= 16 and #payload ~= 32 then
      notify_frame(CMD_AUTH_FAILED, {})
      set_authenticated(false)
      return
    end
  end
  set_authenticated(true)
  notify_frame(CMD_AUTH_SUCCESS, {})
  gfx_print_notification("AuthSuccess", "top_center", 0, 8)
end

function on_write_tdc(input)
  local data = bin_to_hex(input)
  if not data or data == "" then
    return input
  end
  data = hex.norm(data)

  local frame = parse_aa(data)
  if not frame then
    if hex.slice(data, 1, 1) == "bb" then
      print("karr: 0xBB counter frames not simulated")
    end
    notify_frame(CMD_ACK_ERR, {})
    return input
  end

  local cmd = frame.cmd
  if cmd == CMD_PROVIDE_AUTH then
    handle_provide_auth(frame.payload)
    return input
  end

  if cmd == CMD_LOCK or cmd == CMD_SILENT_LOCK or cmd == CMD_SECURE_ARM then
    if not require_auth_or_challenge() then
      return input
    end
    set_armed(true)
    notify_frame(CMD_ACK_OK, {})
    return input
  end

  if cmd == CMD_UNLOCK or cmd == CMD_SILENT_UNLOCK or cmd == CMD_SECURE_DISARM then
    if not require_auth_or_challenge() then
      return input
    end
    set_armed(false)
    notify_frame(CMD_ACK_OK, {})
    return input
  end

  if cmd == CMD_ACK_OK then
    return input
  end

  notify_frame(CMD_ACK_ERR, {})
  return input
end

function on_startup()
  set_authenticated(false)
  if vars.armed == nil then
    vars.armed = true
  end
  apply_adv(armed())
  gfx_show("KARR_logo")
  local label = vars.display_label or "KARR QT sim"
  gfx_print_notification(label, "top_center", 0, 8)
end
