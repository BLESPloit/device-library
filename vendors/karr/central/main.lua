-- KARR central: QtProtocol over Microchip Transparent UART (write + notify).

local SVC = uuids.SVC_TDS
local CHR = uuids.CHR_TDC

local CMD_ACK_OK = 0x00
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

local function to_u8(n)
  return math.floor(tonumber(n) or 0) % 256
end

--- Original 0xAA frame (checksum with sync slot = 0, then write 0xAA).
local function generate_aa(cmd, payload)
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

local function parse_aa(data)
  if type(data) ~= "string" then
    return nil
  end
  data = hex.norm(data)
  if hex.len(data) < 5 or hex.slice(data, 1, 1) ~= "aa" then
    return nil
  end
  local len = bits.be16(data, 2)
  if hex.len(data) < (len + 4) then
    return nil
  end
  local cmd = hex.byte(data, 4)
  local payload_len = len - 1
  local payload_hex = ""
  if payload_len > 0 then
    payload_hex = hex.slice(data, 5, payload_len)
  end
  return { cmd = cmd, payload_hex = payload_hex, raw = data }
end

local function ensure_ready()
  if not ble_connected() then
    gfx_print_text("Not connected")
    return false
  end
  if type(SVC) ~= "string" or type(CHR) ~= "string" then
    gfx_print_text("Missing uuids")
    return false
  end
  if gatt_has_characteristic(SVC, CHR) == false then
    gfx_print_text("TDC characteristic missing")
    return false
  end
  if not ble_subscribe(SVC, CHR) then
    gfx_print_text("Subscribe failed")
    return false
  end
  return true
end

local function cmd_wait(cmd, payload, timeout_ms)
  if not ensure_ready() then
    return nil
  end
  local frame = generate_aa(cmd, payload)
  start_notify_wait(SVC, CHR, 0)
  if not ble_write(SVC, CHR, frame) then
    gfx_print_text("Write failed")
    return nil
  end
  return finish_notify_wait(SVC, CHR, timeout_ms or 5000)
end

local function describe_notify(hex)
  local f = parse_aa(hex)
  if not f then
    return "notify " .. tostring(hex)
  end
  if f.cmd == CMD_ACK_OK then
    return "AckOk"
  end
  if f.cmd == CMD_AUTH_SUCCESS then
    return "AuthSuccess"
  end
  if f.cmd == CMD_AUTH_FAILED then
    return "AuthFailed"
  end
  if f.cmd == CMD_REQUEST_AUTH then
    return "RequestAuth challenge=" .. (f.payload_hex or "")
  end
  if f.cmd == 0xFF then
    return "AckError"
  end
  return string.format("cmd=0x%02X %s", f.cmd, f.raw)
end

local function zeros(n)
  local t = {}
  for i = 1, n do
    t[i] = 0
  end
  return t
end

function on_connected()
  if type(SVC) == "string" and type(CHR) == "string" then
    ble_subscribe(SVC, CHR)
  end
  set_state("auth", "no")
  set_state("doors", fp_get("armed") == "true" and "locked" or "?")
end

function on_main_enter()
  set_title("KARR")
end

function on_silent_menu()
  push_menu("silent")
end

function on_secure_menu()
  push_menu("secure")
end

--- Sim auth: ProvideAuth with 32 zero bytes (peripheral accept_any_auth).
--- If device challenges first, still accepted by the pack peripheral.
function on_authenticate()
  if not ensure_ready() then
    return
  end
  start_notify_wait(SVC, CHR, 80)
  local frame = generate_aa(CMD_PROVIDE_AUTH, zeros(32))
  if not ble_write(SVC, CHR, frame) then
    gfx_print_text("Auth write failed")
    return
  end
  local hex = finish_notify_wait(SVC, CHR, 5000)
  local f = parse_aa(hex)
  if f and f.cmd == CMD_AUTH_SUCCESS then
    set_state("auth", "yes")
    set_title("Authenticated")
    gfx_print_text("AuthSuccess")
    fp_set("authenticated", "true")
    push_fingerprint({ protocol = "karr", authenticated = "true" }, nil)
  elseif f and f.cmd == CMD_REQUEST_AUTH then
    -- Challenge received — reply again (sim still uses zeros).
    local hex2 = cmd_wait(CMD_PROVIDE_AUTH, zeros(32), 5000)
    local f2 = parse_aa(hex2)
    if f2 and f2.cmd == CMD_AUTH_SUCCESS then
      set_state("auth", "yes")
      set_title("Authenticated")
      gfx_print_text("AuthSuccess (after challenge)")
      fp_set("authenticated", "true")
    else
      set_state("auth", "fail")
      gfx_print_text(describe_notify(hex2))
    end
  else
    set_state("auth", "fail")
    gfx_print_text(hex and describe_notify(hex) or "Auth timeout")
  end
end

local function door_cmd(cmd, locked_label)
  local hex = cmd_wait(cmd, {}, 5000)
  local f = parse_aa(hex)
  if f and f.cmd == CMD_ACK_OK then
    set_state("doors", locked_label)
    set_title(locked_label == "locked" and "Locked" or "Unlocked")
    gfx_print_text("AckOk · " .. locked_label)
    fp_set("armed", locked_label == "locked" and "true" or "false")
  elseif f and f.cmd == CMD_REQUEST_AUTH then
    set_state("auth", "needed")
    gfx_print_text("Auth required — run Authenticate")
  elseif f and f.cmd == CMD_AUTH_FAILED then
    set_state("auth", "fail")
    gfx_print_text("AuthFailed")
  else
    gfx_print_text(hex and describe_notify(hex) or "Timeout")
  end
end

function on_lock()
  door_cmd(CMD_LOCK, "locked")
end

function on_unlock()
  door_cmd(CMD_UNLOCK, "unlocked")
end

function on_silent_lock()
  door_cmd(CMD_SILENT_LOCK, "locked")
end

function on_silent_unlock()
  door_cmd(CMD_SILENT_UNLOCK, "unlocked")
end

function on_secure_arm()
  door_cmd(CMD_SECURE_ARM, "locked")
end

function on_secure_disarm()
  door_cmd(CMD_SECURE_DISARM, "unlocked")
end

function on_notify(svc_uuid, chr_uuid, hex_data)
  local f = parse_aa(hex_data)
  if not f then
    return
  end
  if f.cmd == CMD_REQUEST_AUTH then
    set_state("auth", "challenge")
  elseif f.cmd == CMD_AUTH_SUCCESS then
    set_state("auth", "yes")
  elseif f.cmd == CMD_AUTH_FAILED then
    set_state("auth", "fail")
  end
end
