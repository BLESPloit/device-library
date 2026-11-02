-- Tuya BLE peripheral sim: TY-module advertising + unencrypted 0x0000 device-info.
-- Framed like ThingClips X2Request (version nibble 2). Encrypted pairing is not simulated.

local SVC = uuids.SVC_TUYA
local CHR_NOTIFY = uuids.CHR_TUYA_NOTIFY
local ADV_PROFILE_ID = "tuya_ty_unbound"

local CMD_DEVICE_INFO = 0
local CMD_PAIR = 1

local rx = { expect = 0, total = nil, acc = "" }
local pending_frames = {}
local pending_i = 1

local function bxor(a, b)
  local r, v = 0, 1
  a = math.floor(a)
  b = math.floor(b)
  for _ = 1, 16 do
    if (a % 2) ~= (b % 2) then
      r = r + v
    end
    a = math.floor(a / 2)
    b = math.floor(b / 2)
    v = v * 2
  end
  return r
end

local function crc16_modbus(s)
  local crc = 0xFFFF
  for i = 1, #s do
    crc = bxor(crc, string.byte(s, i))
    for _ = 1, 8 do
      if crc % 2 == 1 then
        crc = math.floor(crc / 2)
        crc = bxor(crc, 0xA001)
      else
        crc = math.floor(crc / 2)
      end
    end
  end
  return crc
end

local function be32(n)
  n = math.floor(n) % 4294967296
  return string.char(
    math.floor(n / 16777216) % 256,
    math.floor(n / 65536) % 256,
    math.floor(n / 256) % 256,
    n % 256
  )
end

local function be16(n)
  n = math.floor(n) % 65536
  return string.char(math.floor(n / 256), n % 256)
end

local function u8(s, i)
  return string.byte(s, i) or 0
end

local function u16be(s, i)
  return u8(s, i) * 256 + u8(s, i + 1)
end

local function u32be(s, i)
  return ((u8(s, i) * 256 + u8(s, i + 1)) * 256 + u8(s, i + 2)) * 256 + u8(s, i + 3)
end

local function encode_varint(n)
  local parts = {}
  n = math.floor(n)
  if n < 0 then
    n = 0
  end
  repeat
    local b = n % 128
    n = math.floor(n / 128)
    if n > 0 then
      b = b + 128
    end
    parts[#parts + 1] = string.char(b)
  until n == 0
  return table.concat(parts)
end

local function read_varint(s, pos)
  local n, shift = 0, 1
  while pos <= #s do
    local b = u8(s, pos)
    pos = pos + 1
    n = n + (b % 128) * shift
    if b < 128 then
      return n, pos
    end
    shift = shift * 128
  end
  return nil, pos
end

local function pack_inner(sn, ack, cmd, data)
  data = data or ""
  local body = be32(sn) .. be32(ack) .. be16(cmd) .. be16(#data) .. data
  local crc = crc16_modbus(body)
  return body .. string.char(crc % 256, math.floor(crc / 256) % 256)
end

local function chunk_size()
  local mtu = 23
  if type(get_mtu) == "function" then
    mtu = get_mtu() or 23
  end
  if mtu < 23 then
    mtu = 23
  end
  return math.max(20, mtu - 3)
end

local function fragment_pdu(outer)
  local chunk = chunk_size()
  local frames = {}
  local idx = 0
  local off = 1
  local total = #outer
  while off <= total do
    local hdr = encode_varint(idx)
    if idx == 0 then
      hdr = hdr .. encode_varint(total) .. string.char(32)
    end
    local room = chunk - #hdr
    if room < 1 then
      room = 1
    end
    local take = math.min(room, total - off + 1)
    frames[#frames + 1] = hdr .. outer:sub(off, off + take - 1)
    off = off + take
    idx = idx + 1
  end
  return frames
end

local function pad(s, n)
  s = tostring(s or "")
  if #s >= n then
    return s:sub(1, n)
  end
  return s .. string.rep("\0", n - #s)
end

local function var_bool(v)
  return v == true or v == "true" or v == 1 or v == "1"
end

local function next_sn()
  local n = tonumber(vars.sn) or 1
  n = n + 1
  if n > 2000000000 then
    n = 1
  end
  vars.sn = n
  if type(vars_save) == "function" then
    vars_save()
  end
  return n
end

local function build_device_info_payload()
  local uuid = tostring(vars.uuid or "1mz876o5mr3kllda")
  local bound = var_bool(vars.bound) and 1 or 0
  local srand = string.char(0xA1, 0xB2, 0xC3, 0xD4, 0xE5, 0xF6)
  return table.concat({
    string.char(1, 0),
    string.char(3, 3),
    string.char(0),
    string.char(bound),
    srand,
    string.char(1, 0),
    pad("sim-auth-key-not-used........", 32),
    string.char(1, 0, 0),
    string.char(1, 0, 0),
    string.char(0, 0),
    string.char(0),
    pad(uuid, 22),
    string.char(0, 0, 0),
    string.char(0, 0, 0),
    string.char(0),
  })
end

function tuya_notify_next()
  pending_i = pending_i + 1
  if pending_i <= #pending_frames then
    ble_notify(SVC, CHR_NOTIFY, bin_to_hex(pending_frames[pending_i]))
    if pending_i < #pending_frames then
      delay(0.04, "tuya_notify_next")
    end
  end
end

local function send_ret(ack_sn, cmd, data)
  local sn = next_sn()
  local inner = pack_inner(sn, ack_sn or 0, cmd, data)
  local outer = string.char(0) .. inner
  pending_frames = fragment_pdu(outer)
  pending_i = 1
  if #pending_frames == 0 then
    return
  end
  ble_notify(SVC, CHR_NOTIFY, bin_to_hex(pending_frames[1]))
  if #pending_frames > 1 then
    delay(0.04, "tuya_notify_next")
  end
end

local function handle_pdu(bin)
  if not bin or #bin < 13 then
    return
  end
  local flag = u8(bin, 1)
  if flag ~= 0 then
    print("tuya: encrypted PDU flag=" .. tostring(flag) .. " ignored")
    return
  end
  local body = bin:sub(2)
  if #body < 14 then
    return
  end
  local sn = u32be(body, 1)
  local cmd = u16be(body, 9)
  local len = u16be(body, 11)
  print(string.format("tuya: cmd=0x%04X sn=%d len=%d", cmd, sn, len))
  if cmd == CMD_DEVICE_INFO then
    send_ret(sn, CMD_DEVICE_INFO, build_device_info_payload())
    gfx_print_notification("device info", "top_center", 0, 8)
  elseif cmd == CMD_PAIR then
    send_ret(sn, CMD_PAIR, string.char(1))
  end
end

local function ingest(input)
  if type(input) ~= "string" or #input == 0 then
    return
  end
  -- Unframed unencrypted Ret (flag 0 + SN).
  if u8(input, 1) == 0 and u8(input, 2) == 0 and u8(input, 3) == 0 then
    handle_pdu(input)
    return
  end
  local idx, pos = read_varint(input, 1)
  if not idx then
    handle_pdu(input)
    return
  end
  if idx == 0 then
    local total
    total, pos = read_varint(input, pos)
    pos = pos + 1
    rx.total = total
    rx.acc = input:sub(pos)
    rx.expect = 1
  elseif idx == rx.expect then
    rx.acc = rx.acc .. input:sub(pos)
    rx.expect = rx.expect + 1
  else
    handle_pdu(input)
    return
  end
  if rx.total and #rx.acc >= rx.total then
    handle_pdu(rx.acc:sub(1, rx.total))
    rx = { expect = 0, total = nil, acc = "" }
  end
end

function on_write_tuya(input)
  ingest(input)
  return input
end

function on_startup()
  gfx_show("tuya_logo")
  local name = tostring(vars.device_name or "TY")
  local uuid = tostring(vars.uuid or "")
  gfx_print_notification(
    "Tuya " .. name .. (uuid ~= "" and (" : " .. uuid) or ""),
    "top_center",
    0,
    8
  )
  if type(set_preferred_mtu) == "function" then
    set_preferred_mtu(247)
  end
  if type(adv_enable) == "function" then
    adv_enable(ADV_PROFILE_ID)
  end
end
