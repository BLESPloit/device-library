-- Quick action: subscribe to bitchat mesh characteristic, wait for signed announce (0x01),
-- decode AnnouncementPacket TLVs, derive peer ID from Noise static key.

local CHR = uuids and uuids.BITCHAT_CHAR
local SVC_MAIN = uuids and uuids.BITCHAT_SERVICE_MAINNET
local SVC_TEST = uuids and uuids.BITCHAT_SERVICE_TESTNET

local MSG_ANNOUNCE = 0x01
local FLAG_HAS_RECIPIENT = 0x01
local FLAG_HAS_SIGNATURE = 0x02
local FLAG_IS_COMPRESSED = 0x04
local FLAG_HAS_ROUTE = 0x08

local TLV_NICKNAME = 0x01
local TLV_NOISE_KEY = 0x02
local TLV_SIGNING_KEY = 0x03
local TLV_NEIGHBORS = 0x04
local TLV_CAPABILITIES = 0x05
local TLV_BRIDGE_GEOHASH = 0x06

local CAP_BITS = {
  { bit = 0, name = "prekeys" },
  { bit = 1, name = "wifiBulk" },
  { bit = 2, name = "gateway" },
  { bit = 3, name = "groups" },
  { bit = 4, name = "board" },
  { bit = 5, name = "vouch" },
  { bit = 6, name = "meshDiagnostics" },
  { bit = 7, name = "bridge" },
  { bit = 8, name = "privateMedia" },
  { bit = 9, name = "privateMediaReceipts" },
}

local function norm_hex(h)
  return hex.norm(h)
end

local function hex_byte(h, byte_index)
  return hex.byte(h, byte_index)
end

local function hex_slice(h, from_byte, n_bytes)
  return hex.slice(h, from_byte, n_bytes)
end

local function hex_len(h)
  return hex.len(h)
end

local function band(a, b)
  return bits.band(a, b)
end

local function resolve_service()
  if type(CHR) ~= "string" or CHR == "" then
    return nil, nil, "uuids.json missing BITCHAT_CHAR"
  end

  local preferred = fp_get and fp_get("network") or nil
  local order = {}
  if preferred == "testnet" then
    order = { { SVC_TEST, "testnet" }, { SVC_MAIN, "mainnet" } }
  else
    order = { { SVC_MAIN, "mainnet" }, { SVC_TEST, "testnet" } }
  end

  for _, item in ipairs(order) do
    local svc, net = item[1], item[2]
    if type(svc) == "string" and svc ~= "" then
      local has = gatt_has_characteristic(svc, CHR)
      if has ~= false then
        return svc, net, nil
      end
    end
  end
  return nil, nil, "bitchat service/characteristic not found on this connection"
end

-- Extract one BinaryProtocol frame starting at byte_offset (1-based). Returns frame_hex, next_offset, err.
local function extract_frame(hex, byte_offset)
  local n = hex_len(hex)
  if byte_offset > n then
    return nil, byte_offset, "eof"
  end

  local version = hex_byte(hex, byte_offset)
  if version ~= 1 and version ~= 2 then
    return nil, byte_offset + 1, "bad version"
  end

  local header_size = (version == 2) and 16 or 14
  local frame_prefix = header_size + 8
  if byte_offset + frame_prefix - 1 > n then
    return nil, byte_offset, "truncated header"
  end

  local flags = hex_byte(hex, byte_offset + 11)
  local has_recipient = band(flags, FLAG_HAS_RECIPIENT) ~= 0
  local has_signature = band(flags, FLAG_HAS_SIGNATURE) ~= 0
  local is_compressed = band(flags, FLAG_IS_COMPRESSED) ~= 0
  local has_route = (version >= 2) and (band(flags, FLAG_HAS_ROUTE) ~= 0)

  local payload_length
  if version == 2 then
    payload_length =
      hex_byte(hex, byte_offset + 12) * 16777216
      + hex_byte(hex, byte_offset + 13) * 65536
      + hex_byte(hex, byte_offset + 14) * 256
      + hex_byte(hex, byte_offset + 15)
  else
    payload_length = hex_byte(hex, byte_offset + 12) * 256 + hex_byte(hex, byte_offset + 13)
  end

  local frame_length = frame_prefix + payload_length
  if has_recipient then
    frame_length = frame_length + 8
  end
  if has_signature then
    frame_length = frame_length + 64
  end

  if has_route then
    local route_count_off = byte_offset + frame_prefix - 1 + (has_recipient and 8 or 0) + 1
    if route_count_off > n then
      return nil, byte_offset, "truncated route"
    end
    local route_count = hex_byte(hex, route_count_off)
    frame_length = frame_length + 1 + route_count * 8
  end

  if is_compressed then
    -- Announce payloads are small and uncompressed; skip compressed frames.
    if byte_offset + frame_length - 1 > n then
      return nil, byte_offset, "truncated compressed"
    end
    return hex_slice(hex, byte_offset, frame_length), byte_offset + frame_length, "compressed"
  end

  if frame_length <= 0 or frame_length > 65536 then
    return nil, byte_offset + 1, "bad frame length"
  end
  if byte_offset + frame_length - 1 > n then
    return nil, byte_offset, "truncated frame"
  end

  return hex_slice(hex, byte_offset, frame_length), byte_offset + frame_length, nil
end

local function parse_packet_header(frame_hex)
  local version = hex_byte(frame_hex, 1)
  if version ~= 1 and version ~= 2 then
    return nil
  end
  local msg_type = hex_byte(frame_hex, 2)
  local ttl = hex_byte(frame_hex, 3)
  local ts = 0
  for i = 4, 11 do
    ts = ts * 256 + hex_byte(frame_hex, i)
  end
  local flags = hex_byte(frame_hex, 12)
  local has_recipient = band(flags, FLAG_HAS_RECIPIENT) ~= 0
  local has_signature = band(flags, FLAG_HAS_SIGNATURE) ~= 0
  local has_route = (version >= 2) and (band(flags, FLAG_HAS_ROUTE) ~= 0)

  local header_size = (version == 2) and 16 or 14
  local payload_length
  if version == 2 then
    payload_length =
      hex_byte(frame_hex, 13) * 16777216
      + hex_byte(frame_hex, 14) * 65536
      + hex_byte(frame_hex, 15) * 256
      + hex_byte(frame_hex, 16)
  else
    payload_length = hex_byte(frame_hex, 13) * 256 + hex_byte(frame_hex, 14)
  end

  local off = header_size + 1
  local sender_id = hex_slice(frame_hex, off, 8)
  off = off + 8

  if has_recipient then
    off = off + 8
  end
  if has_route then
    local route_count = hex_byte(frame_hex, off)
    off = off + 1 + route_count * 8
  end

  local payload = hex_slice(frame_hex, off, payload_length)
  off = off + payload_length

  local signature = nil
  if has_signature then
    signature = hex_slice(frame_hex, off, 64)
  end

  return {
    version = version,
    type = msg_type,
    ttl = ttl,
    timestamp = ts,
    flags = flags,
    has_signature = has_signature,
    sender_id = sender_id,
    payload = payload,
    signature = signature,
  }
end

local function decode_announce_tlvs(payload_hex)
  local n = hex_len(payload_hex)
  local off = 1
  local nick_hex, noise_hex, signing_hex, neighbors_hex, caps_hex, geohash_hex

  while off + 1 <= n do
    local t = hex_byte(payload_hex, off)
    local len = hex_byte(payload_hex, off + 1)
    off = off + 2
    if off + len - 1 > n then
      break
    end
    local value = hex_slice(payload_hex, off, len)
    off = off + len

    if t == TLV_NICKNAME then
      nick_hex = value
    elseif t == TLV_NOISE_KEY then
      noise_hex = value
    elseif t == TLV_SIGNING_KEY then
      signing_hex = value
    elseif t == TLV_NEIGHBORS then
      neighbors_hex = value
    elseif t == TLV_CAPABILITIES then
      caps_hex = value
    elseif t == TLV_BRIDGE_GEOHASH then
      geohash_hex = value
    end
  end

  if not nick_hex or not noise_hex or not signing_hex then
    return nil, "announce missing required TLVs (nickname / noise / signing)"
  end

  return {
    nickname_hex = nick_hex,
    noise_public_key = noise_hex,
    signing_public_key = signing_hex,
    neighbors_hex = neighbors_hex,
    capabilities_hex = caps_hex,
    bridge_geohash_hex = geohash_hex,
  }
end

local function hex_to_text(h)
  return hex.to_ascii(h)
end

local function peer_id_from_noise_key(noise_hex)
  local bin = hex_to_bin(noise_hex)
  if type(bin) ~= "string" or bin == "" then
    return nil
  end
  local digest = sha256(bin)
  if type(digest) ~= "string" or digest == "" then
    return nil
  end
  local hash_hex = norm_hex(bin_to_hex(digest))
  if #hash_hex < 16 then
    return nil
  end
  return hash_hex:sub(1, 16)
end

local function decode_capabilities(caps_hex)
  if not caps_hex or caps_hex == "" then
    return 0, {}
  end
  local raw = 0
  local place = 1
  local n = math.min(hex_len(caps_hex), 8)
  for i = 1, n do
    -- little-endian bitfield
    raw = raw + hex_byte(caps_hex, i) * place
    place = place * 256
  end
  local names = {}
  for _, cap in ipairs(CAP_BITS) do
    local mask = 1
    for _ = 1, cap.bit do
      mask = mask * 2
    end
    if band(raw, mask) ~= 0 then
      names[#names + 1] = cap.name
    end
  end
  return raw, names
end

local function neighbor_ids(neighbors_hex)
  local ids = {}
  if not neighbors_hex or neighbors_hex == "" then
    return ids
  end
  local n = hex_len(neighbors_hex)
  if n % 8 ~= 0 then
    return ids
  end
  for i = 1, n, 8 do
    ids[#ids + 1] = hex_slice(neighbors_hex, i, 8)
  end
  return ids
end

local function find_announce(stream_hex)
  stream_hex = norm_hex(stream_hex)
  if stream_hex == "" then
    return nil, "empty notify stream"
  end

  local off = 1
  local n = hex_len(stream_hex)
  local scanned = 0
  while off <= n and scanned < 64 do
    scanned = scanned + 1
    local frame, next_off, err = extract_frame(stream_hex, off)
    if not frame then
      if err == "truncated header" or err == "truncated frame" or err == "truncated compressed" or err == "truncated route" then
        break
      end
      off = next_off or (off + 1)
    else
      if err == "compressed" then
        off = next_off
      else
        local pkt = parse_packet_header(frame)
        if pkt and pkt.type == MSG_ANNOUNCE then
          return pkt, nil
        end
        off = next_off
      end
    end
  end
  return nil, "no announce (0x01) frame in notify stream"
end

function run()
  if not ble_connected() then
    log("bitchat: not connected")
    gfx_print_text("Not connected")
    return
  end

  local svc, network, err = resolve_service()
  if not svc then
    log("bitchat: " .. tostring(err))
    gfx_print_text("No bitchat GATT")
    return
  end

  start_notify_wait(svc, CHR, 350)
  if not ble_subscribe(svc, CHR) then
    log("bitchat: subscribe failed")
    gfx_print_text("Subscribe failed")
    return
  end

  -- Peer sends announce ~0.4s after subscribe (rate-limited under reconnect churn).
  local stream = finish_notify_wait(svc, CHR, 10000)
  stream = norm_hex(stream)
  if stream == "" then
    log("bitchat: no notify (timeout). Peer may be rate-limiting announces.")
    gfx_print_text("No announce")
    return
  end

  local pkt, perr = find_announce(stream)
  if not pkt then
    log("bitchat: " .. tostring(perr))
    log("bitchat: notify hex (" .. tostring(hex_len(stream)) .. " B): " .. stream:sub(1, 128))
    gfx_print_text("No announce frame")
    return
  end

  local tlvs, terr = decode_announce_tlvs(pkt.payload)
  if not tlvs then
    log("bitchat: " .. tostring(terr))
    gfx_print_text("Announce TLV error")
    return
  end

  local nickname = hex_to_text(tlvs.nickname_hex)
  local derived_peer_id = peer_id_from_noise_key(tlvs.noise_public_key)
  local sender_id = pkt.sender_id
  local caps_raw, cap_names = decode_capabilities(tlvs.capabilities_hex)
  local neighbors = neighbor_ids(tlvs.neighbors_hex)
  local bridge_geohash = hex_to_text(tlvs.bridge_geohash_hex or "")

  local peer_match = (derived_peer_id and derived_peer_id == sender_id) and "true" or "false"

  local caps_str = (#cap_names > 0) and table.concat(cap_names, ",") or "none"
  local summary
  if nickname ~= "" then
    summary = nickname
  else
    summary = "peer " .. (derived_peer_id or sender_id or "?")
  end
  if derived_peer_id then
    summary = summary .. " · " .. derived_peer_id
  end

  log("=== bitchat peer identity ===")
  log("network          : " .. tostring(network))
  log("nickname         : " .. (nickname ~= "" and nickname or "(empty)"))
  log("sender_id        : " .. tostring(sender_id))
  log("peer_id (noise)  : " .. tostring(derived_peer_id))
  log("peer_id match    : " .. peer_match)
  log("noise pubkey     : " .. tostring(tlvs.noise_public_key))
  log("signing pubkey   : " .. tostring(tlvs.signing_public_key))
  log("capabilities     : " .. string.format("0x%X (%s)", caps_raw, caps_str))
  log("neighbors        : " .. tostring(#neighbors))
  for i, nid in ipairs(neighbors) do
    log(string.format("  neighbor[%d]   : %s", i, nid))
  end
  if bridge_geohash ~= "" then
    log("bridge geohash   : " .. bridge_geohash)
  end
  log("announce ts(ms)  : " .. tostring(pkt.timestamp))
  log("signed           : " .. (pkt.has_signature and "true" or "false"))
  log("Summary: " .. summary)

  local attrs = {
    protocol = "bitchat",
    network = network or "",
    nickname = nickname,
    peer_id = derived_peer_id or "",
    sender_id = sender_id or "",
    peer_id_matches_sender = peer_match,
    noise_public_key = tlvs.noise_public_key,
    signing_public_key = tlvs.signing_public_key,
    capabilities = caps_str,
    capabilities_raw = string.format("%X", caps_raw),
    neighbor_count = tostring(#neighbors),
    announce_timestamp_ms = tostring(pkt.timestamp),
    announce_signed = pkt.has_signature and "true" or "false",
  }
  if bridge_geohash ~= "" then
    attrs.bridge_geohash = bridge_geohash
  end
  if #neighbors > 0 then
    attrs.neighbors = table.concat(neighbors, ",")
  end

  fp_set("display_info", summary)
  if nickname ~= "" then
    fp_set("display_name", "bitchat · " .. nickname)
  end
  for key, value in pairs(attrs) do
    if value ~= "" then
      fp_set(key, value)
    end
  end
  fp_append("bitchat_peer_identity", attrs, "bitchat peer identity")

  gfx_print_text(summary)
end
