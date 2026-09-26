-- Quick action: authenticate with configurable key from vars.json.
-- vars.auth_key: Base64 (default) or hex cloud/unit key (≥16 bytes decoded).
-- vars.auth_key_encoding: "base64" | "hex"
-- vars.auth_mode: OldHash unit mode (2/5 = customer+serial splice; else dealer). Default 0.
-- vars.serial: optional override; else fingerprint device_name / GAP name.

local SVC = uuids.SVC_TDS
local CHR = uuids.CHR_TDC

local CMD_LOCK = 0x0B
local CMD_REQUEST_AUTH = 0x0E
local CMD_PROVIDE_AUTH = 0x0F
local CMD_AUTH_SUCCESS = 0x10
local CMD_AUTH_FAILED = 0x11

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function to_u8(n)
  n = math.floor(n) % 256
  if n < 0 then
    n = n + 256
  end
  return n
end

local function wrap_i32(n)
  n = n % 4294967296
  if n >= 2147483648 then
    n = n - 4294967296
  end
  return n
end

local function bytes_to_hex(bytes)
  local parts = {}
  for i = 1, #bytes do
    parts[i] = string.format("%02x", to_u8(bytes[i]))
  end
  return table.concat(parts)
end

local function hex_to_bytes(hex)
  if type(hex) ~= "string" then
    return nil
  end
  hex = hex:lower():gsub("%s+", ""):gsub("^0x", "")
  if #hex % 2 ~= 0 or #hex == 0 then
    return nil
  end
  local out = {}
  for i = 1, #hex, 2 do
    local b = tonumber(hex:sub(i, i + 1), 16)
    if not b then
      return nil
    end
    out[#out + 1] = b
  end
  return out
end

local function bin_to_bytes(bin)
  if type(bin) ~= "string" or bin == "" then
    return nil
  end
  local out = {}
  for i = 1, #bin do
    out[i] = string.byte(bin, i)
  end
  return out
end

local function bytes_to_bin(bytes)
  local chars = {}
  for i = 1, #bytes do
    chars[i] = string.char(to_u8(bytes[i]))
  end
  return table.concat(chars)
end

local function bxor_byte(a, b)
  local r, v = 0, 1
  a = to_u8(a)
  b = to_u8(b)
  for _ = 1, 8 do
    if (a % 2) ~= (b % 2) then
      r = r + v
    end
    a = math.floor(a / 2)
    b = math.floor(b / 2)
    v = v * 2
  end
  return r
end

local function base64_decode(s)
  if type(s) ~= "string" then
    return nil
  end
  s = s:gsub("%s+", "")
  local out = {}
  local buf, nbits = 0, 0
  for i = 1, #s do
    local ch = s:sub(i, i)
    if ch ~= "=" then
      local v = B64:find(ch, 1, true)
      if not v then
        return nil
      end
      v = v - 1
      buf = buf * 64 + v
      nbits = nbits + 6
      if nbits >= 8 then
        nbits = nbits - 8
        out[#out + 1] = math.floor(buf / (2 ^ nbits)) % 256
        buf = buf % (2 ^ nbits)
      end
    end
  end
  return out
end

local function decode_key(raw, encoding)
  if type(raw) ~= "string" or raw == "" then
    return nil, "vars.auth_key is empty"
  end
  encoding = (encoding or "base64"):lower()
  local key
  if encoding == "hex" then
    key = hex_to_bytes(raw)
  else
    key = base64_decode(raw)
  end
  if not key or #key < 16 then
    return nil, "auth_key must decode to ≥16 bytes (" .. encoding .. ")"
  end
  return key, nil
end

--- Original 0xAA frame (checksum with sync slot = 0, then write 0xAA).
local function generate_aa(cmd, payload_bytes)
  payload_bytes = payload_bytes or {}
  local L = 1 + #payload_bytes
  local sum = math.floor(L / 256) + (L % 256) + to_u8(cmd)
  local body = hex.be16(L) .. hex.u8(cmd)
  for i = 1, #payload_bytes do
    local b = to_u8(payload_bytes[i])
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
  local payload = {}
  for i = 1, len - 1 do
    payload[i] = hex.byte(data, 4 + i)
  end
  return { cmd = cmd, payload = payload, raw = data }
end

--- OldHash: 8-byte challenge → 32-byte ProvideAuth (DJB-style ×33, Int32 wrap).
local function old_hash(mode, challenge, serial, key)
  local customer = (mode == 2 or mode == 5)
  local hash = {}
  for i = 0, 15 do
    local seed
    if customer then
      if i == 3 then
        seed = serial:byte(8) or 0
      elseif i == 6 then
        seed = serial:byte(9) or 0
      elseif i == 9 then
        seed = serial:byte(10) or 0
      else
        seed = key[i + 1] or 0
      end
    else
      seed = key[i + 1] or 0
    end
    local acc = seed
    for j = 1, 8 do
      acc = wrap_i32(acc * 33 + (challenge[j] or 0))
    end
    local u = acc % 4294967296
    if u < 0 then
      u = u + 4294967296
    end
    hash[2 * i + 1] = u % 256
    hash[2 * i + 2] = math.floor(u / 256) % 256
  end
  return hash
end

--- NewHash: 32-byte challenge → 16-byte AES-128-CBC (Zeros), via mobile aes_ecb_encrypt.
local function new_hash(challenge, key)
  if type(aes_ecb_encrypt) ~= "function" then
    return nil, "aes_ecb_encrypt not available"
  end
  local key16 = bytes_to_bin({
    key[1], key[2], key[3], key[4], key[5], key[6], key[7], key[8],
    key[9], key[10], key[11], key[12], key[13], key[14], key[15], key[16],
  })
  local iv = {}
  local pt = {}
  for i = 1, 16 do
    iv[i] = challenge[i] or 0
    pt[i] = challenge[16 + i] or 0
  end
  local xored = {}
  for i = 1, 16 do
    xored[i] = bxor_byte(pt[i], iv[i])
  end
  local ct = aes_ecb_encrypt(key16, bytes_to_bin(xored))
  local out = bin_to_bytes(ct)
  if not out or #out < 16 then
    return nil, "AES-CBC encrypt failed"
  end
  local trim = {}
  for i = 1, 16 do
    trim[i] = out[i]
  end
  return trim, nil
end

local function resolve_serial()
  local s = vars.serial
  if type(s) == "string" and s ~= "" then
    return s
  end
  s = fp_get("device_name") or fp_get("msd_name") or ""
  if s == "" then
    s = "QT 00000000"
  end
  return s
end

local function ensure_ready()
  if not ble_connected() then
    gfx_print_text("Not connected")
    return false
  end
  if gatt_has_characteristic(SVC, CHR) == false then
    gfx_print_text("TDC missing")
    return false
  end
  if not ble_subscribe(SVC, CHR) then
    gfx_print_text("Subscribe failed")
    return false
  end
  return true
end

local function wait_request_auth()
  -- Real units often push RequestAuth after CCCD enable.
  start_notify_wait(SVC, CHR, 80)
  local hex = finish_notify_wait(SVC, CHR, 2500)
  local f = parse_aa(hex)
  if f and f.cmd == CMD_REQUEST_AUTH then
    return f
  end
  -- Pack sim / some units: provoke challenge with Lock while unauthenticated.
  start_notify_wait(SVC, CHR, 80)
  ble_write(SVC, CHR, generate_aa(CMD_LOCK, {}))
  hex = finish_notify_wait(SVC, CHR, 5000)
  f = parse_aa(hex)
  if f and f.cmd == CMD_REQUEST_AUTH then
    return f
  end
  return nil, hex
end

function run()
  if not ensure_ready() then
    return
  end

  local key, kerr = decode_key(vars.auth_key, vars.auth_key_encoding)
  if not key then
    gfx_print_text(kerr or "Set vars.auth_key")
    log("karr auth: " .. tostring(kerr))
    return
  end

  local mode = tonumber(vars.auth_mode) or 0
  local serial = resolve_serial()
  log(string.format("karr auth: mode=%d serial=%s key_len=%d encoding=%s",
    mode, serial, #key, tostring(vars.auth_key_encoding or "base64")))

  local req, raw = wait_request_auth()
  if not req then
    gfx_print_text("No RequestAuth")
    log("karr auth: no RequestAuth, last=" .. tostring(raw))
    return
  end

  local challenge = req.payload or {}
  local n = #challenge
  log(string.format("karr auth: challenge %d B %s", n, bytes_to_hex(challenge)))

  local hash, herr
  if n == 8 then
    hash = old_hash(mode, challenge, serial, key)
  elseif n == 32 then
    hash, herr = new_hash(challenge, key)
  else
    gfx_print_text("Bad challenge len " .. tostring(n))
    return
  end
  if not hash then
    gfx_print_text(herr or "Hash failed")
    return
  end

  start_notify_wait(SVC, CHR, 80)
  if not ble_write(SVC, CHR, generate_aa(CMD_PROVIDE_AUTH, hash)) then
    gfx_print_text("ProvideAuth write failed")
    return
  end
  local resp = parse_aa(finish_notify_wait(SVC, CHR, 5000))
  if resp and resp.cmd == CMD_AUTH_SUCCESS then
    set_state("auth", "yes")
    fp_set("authenticated", "true")
    push_fingerprint({ protocol = "karr", authenticated = "true", auth_mode = tostring(mode) }, nil)
    gfx_print_text("AuthSuccess")
    log("karr auth: AuthSuccess")
  elseif resp and resp.cmd == CMD_AUTH_FAILED then
    set_state("auth", "fail")
    gfx_print_text("AuthFailed")
    log("karr auth: AuthFailed")
  else
    set_state("auth", "fail")
    gfx_print_text("Auth timeout/unexpected")
    log("karr auth: unexpected " .. tostring(resp and resp.raw))
  end
end
