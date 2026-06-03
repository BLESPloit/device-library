--[[
  ElinkSmart-style smart lock peripheral.
  - AES-128-ECB key = ASCII hex for "7b7079bb69001dce"
  - RX (app -> lock): byte1 nibble-swapped packet_count; ciphertext from Lua index 3 (ESP sample).
  - TX (lock -> app): pdu1 = LE16(cipher_len) || cipher (≤18 B); further pdus raw cipher (≤20 B) — eSmartLock.
  - PKCS7 when plaintext length not multiple of 16 (matches sample)
  - Sim PIN: vars.pin in vars.json (manifest `vars`); exactly 6 decimal digits; default 123456
  - GFX: assets/graphics.json — lock_closed blue, lock_open green (unlocked), lock_closed red (auth fails)
  - Challenge: when cached (after cmd 1), verify PKCS7 / zero-pad ECB proof or proof at params[5..8]. Unlock (0x04/0x12) with empty cache skips proof — PIN checked (apps often omit re-auth once paired).
  - After green/red state, `delay(sec, "esm_revert_blue")` restores blue closed. Keep the name short — some hosts truncate callback strings (~30 chars).
  - Advertising: legacy head (flags + svc UUID) + Manufacturer Specific `FF` payload `01 0c` + **6-octet BD address reversed** (`A4:…:B0` → `…B0112438C1A4`) + Complete Local Name `lock-<last 2 octets hex>`. Uses `get_adv_bd_addr` + `adv_set_data("main", …)`.
]]

--- Verbose RX/TX + per-block AES hex (set false to reduce log noise).
local ELINK_DBG = true

local function dbg_print(msg)
  if ELINK_DBG then
    print("elinksmart: DBG " .. msg)
  end
end

local function dbg_hex(tag, bin)
  if not ELINK_DBG then
    return
  end
  if bin == nil or type(bin) ~= "string" then
    dbg_print(tag .. " (nil/invalid)")
    return
  end
  local n = #bin
  local ok, h = pcall(bin_to_hex, bin)
  if not ok or type(h) ~= "string" then
    dbg_print(tag .. " len=" .. n .. " (bin_to_hex failed)")
    return
  end
  dbg_print(string.format("%s len=%d hex=%s", tag, n, h))
end

local AES_KEY = string.char(
  0x37, 0x62, 0x37, 0x30, 0x37, 0x39, 0x62, 0x62,
  0x36, 0x39, 0x30, 0x30, 0x31, 0x64, 0x63, 0x65
)

-- Plaintext suffix for auth notify (fixed template from sample); bytes 5–8 (1-based) = challenge.
local AUTH_TAIL_HEX =
  "0c0000000707ee01002f00000000010001000000503842462d50470000000000010014000000000000000e0e0e0e0e0e0e0e0e0e0e0e0e0e"

local DEFAULT_SIM_PIN = "123456"

--- Six decimal digits expected by eSmartLock payloads (vars.pin overrides).
local function resolve_sim_pin()
  local p = nil
  if type(vars) == "table" and vars.pin ~= nil then
    p = tostring(vars.pin):match("^%s*(.-)%s*$") or ""
    if p == "" then
      p = nil
    end
  end
  if not p then
    return DEFAULT_SIM_PIN
  end
  if #p ~= 6 or not p:match("^%d%d%d%d%d%d$") then
    print(string.format(
      "elinksmart: vars.pin must be exactly 6 decimal digits (got len=%d), using %s",
      #p,
      DEFAULT_SIM_PIN
    ))
    return DEFAULT_SIM_PIN
  end
  return p
end

local GFX_CLOSED = "lock_closed"
local GFX_OPEN = "lock_open"

--- Must match peripheral/adv.json profile `id`; used by `get_adv_bd_addr` / `adv_set_data`.
local ADV_PROFILE_ID = "main"
--- AD octets **before** the Manufacturer Specific TLV: Flags + Incomplete 16-bit UUID list FF30 (`adv.json` baseline).
local ADV_HEAD_HEX = "020106030230ff"
local ADV_COMPLETE_LOCAL_PREFIX = "lock-"

--- Packed RGB 0xRRGGBB (matches manifest scan icon hue for locked).
local COLOR_LOCKED_BLUE = 0x096eab
local COLOR_UNLOCKED_GREEN = 0x2e7d32
local COLOR_AUTH_FAIL_RED = 0xc62828

--- Seconds before reverting from success (green open) or failure (red) back to default blue closed.
local REVERT_TO_BLUE_DELAY_SEC = 5
local REVERT_TO_BLUE_CB = "esm_revert_blue"

local function gfx_remove_id(id)
  if type(gfx_remove) == "function" then
    pcall(gfx_remove, id)
  elseif type(gfx_remove_element) == "function" then
    pcall(gfx_remove_element, id)
  end
end

--- Single closed-lock pass: remove open icon first, then show closed + color.
local function visuals_closed(rgb)
  gfx_remove_id(GFX_OPEN)
  gfx_show(GFX_CLOSED)
  gfx_set_color(GFX_CLOSED, rgb)
end

local function visuals_locked_blue()
  visuals_closed(COLOR_LOCKED_BLUE)
end

local function visuals_locked_red()
  visuals_closed(COLOR_AUTH_FAIL_RED)
end

--- Remove closed lock before showing open (shape switch).
local function visuals_unlocked_green()
  gfx_remove_id(GFX_CLOSED)
  gfx_show(GFX_OPEN)
  gfx_set_color(GFX_OPEN, COLOR_UNLOCKED_GREEN)
end

--- Called by host `delay(sec, name)`. Short global name — firmware may truncate long strings when resolving callbacks.
function esm_revert_blue()
  visuals_locked_blue()
end

local function schedule_revert_blue_locked()
  if type(delay) ~= "function" then
    if ELINK_DBG then
      dbg_print("schedule_revert_blue_locked: delay() not bound — skipping revert")
    end
    return
  end
  local ok, err = pcall(delay, REVERT_TO_BLUE_DELAY_SEC, REVERT_TO_BLUE_CB)
  if not ok and ELINK_DBG then
    dbg_print("schedule_revert_blue_locked: delay() failed: " .. tostring(err))
  end
end

--- Last two BD octets → 4 ASCII hex digits ("79","6a" → "796A").
local function bd_addr_last_two_octets_hex(bd_mac)
  if type(bd_mac) ~= "string" or bd_mac == "" then
    return nil
  end
  local octets = {}
  for oct in bd_mac:gmatch("%x%x") do
    octets[#octets + 1] = oct
  end
  if #octets < 2 then
    return nil
  end
  return (octets[#octets - 1] .. octets[#octets]):upper()
end

--- Exactly 6 BD octets in **reverse transmit order**: last string octet first (e.g. A4:…:B0 → …B0112438C1A4).
local function bd_six_octets_reversed_bin(bd_mac)
  if type(bd_mac) ~= "string" or bd_mac == "" then
    return nil
  end
  local octets = {}
  for oct in bd_mac:gmatch("%x%x") do
    octets[#octets + 1] = oct
  end
  if #octets ~= 6 then
    return nil
  end
  local chunks = {}
  for i = 6, 1, -1 do
    local v = tonumber(octets[i], 16)
    if not v then
      return nil
    end
    chunks[#chunks + 1] = string.char(v)
  end
  return table.concat(chunks)
end

--- Returns blob, optional error reason, Complete Local Name used.
local function build_elink_adv_blob_from_bd(bd_mac)
  local rev6 = bd_six_octets_reversed_bin(bd_mac)
  if not rev6 then
    return nil, "BD parse / reverse (need 6 octets)", nil
  end
  local suf = bd_addr_last_two_octets_hex(bd_mac)
  if not suf then
    return nil, "BD suffix for name", nil
  end
  local ok_h, head = pcall(hex_to_bin, ADV_HEAD_HEX)
  if not ok_h or type(head) ~= "string" or #head == 0 then
    return nil, "hex_to_bin(ADV_HEAD_HEX) failed", nil
  end

  -- Manufacturer Specific: Len=9 Type=FF payload 01 0c || BD reversed (6 B).
  local mfg_payload = string.char(0x01, 0x0c) .. rev6
  local mfg_tlv = string.char(1 + #mfg_payload, 0xff) .. mfg_payload

  local complete_name = ADV_COMPLETE_LOCAL_PREFIX .. suf
  if #complete_name < 1 or #complete_name > 247 then
    return nil, "invalid Complete Local Name length", nil
  end
  local inner_name = 1 + #complete_name
  if inner_name > 255 then
    return nil, "AD length overflow", nil
  end
  local name_tlv = string.char(inner_name, 0x09) .. complete_name

  return head .. mfg_tlv .. name_tlv, nil, complete_name
end

--- Overwrites advertisement for ADV_PROFILE_ID; no-op when host omit adv_set_data / get_adv_bd_addr (static adv.json).
local function apply_adv_name_from_bd_addr()
  if type(adv_set_data) ~= "function" or type(get_adv_bd_addr) ~= "function" then
    if ELINK_DBG then
      dbg_print(
        "adv BD name: skipping (need adv_set_data + get_adv_bd_addr on host)"
      )
    end
    return
  end
  local bd, errmsg = get_adv_bd_addr(ADV_PROFILE_ID)
  if type(bd) ~= "string" or bd == "" then
    print("elinksmart: get_adv_bd_addr: " .. tostring(errmsg))
    return
  end
  local blob, terr, complete_name = build_elink_adv_blob_from_bd(bd)
  if not blob then
    print("elinksmart: adv build: " .. tostring(terr))
    return
  end
  local ok_adv, ah = pcall(bin_to_hex, blob)
  if not ok_adv or type(ah) ~= "string" then
    print("elinksmart: bin_to_hex(adv blob) failed")
    return
  end
  local ok_set, setterr = adv_set_data(ADV_PROFILE_ID, ah)
  if ok_set ~= true then
    print("elinksmart: adv_set_data: " .. tostring(setterr))
    return
  end
  local rev6 = bd_six_octets_reversed_bin(bd)
  if rev6 and ELINK_DBG then
    local mfg_pay = string.char(0x01, 0x0c) .. rev6
    local ok_m, mfg_hex = pcall(bin_to_hex, mfg_pay)
    if ok_m and type(mfg_hex) == "string" then
      dbg_print(string.format(
        "mfg Specific payload (after AD type FF): %s (= 01 0c || BD_rev6)",
        mfg_hex
      ))
    end
  end
  print(string.format(
    "elinksmart: advertising name %q (%s)",
    complete_name,
    bd
  ))
end

local incoming_active = false
local expecting_remaining = 0
--- Expected ciphertext byte count (`packet_count * 20 - 2`, ESP sample).
local cipher_budget = 0
local agg_bytes = {}
local challenge_bin = ""

local function svc_chr()
  return uuids.SVC_ELINK_SMARTLOCK, uuids.CHR_DATAOUT
end

local function swap_nibbles_u8(b)
  b = b % 256
  return (math.floor(b / 16) + (b % 16) * 16) % 256
end

local function elinksmart_add_padding(buf)
  local len = #buf
  if len % 16 == 0 then
    return buf
  end
  local padn = 16 - (len % 16)
  local parts = {}
  for i = 1, padn do
    parts[i] = string.char(padn)
  end
  return buf .. table.concat(parts)
end

local function aes_decrypt_buffer(key, ciphertext)
  if #ciphertext % 16 ~= 0 then
    return nil, "ciphertext not multiple of 16"
  end
  local out = {}
  for i = 1, #ciphertext, 16 do
    local block = string.sub(ciphertext, i, i + 15)
    if ELINK_DBG then
      dbg_hex(string.format("  AES ECB decrypt block@%d ciphertext", i - 1), block)
    end
    local plainb = aes_ecb_decrypt(key, block)
    if ELINK_DBG then
      dbg_hex(string.format("  AES ECB decrypt block@%d plaintext", i - 1), plainb)
    end
    table.insert(out, plainb)
  end
  return table.concat(out), nil
end

local function aes_encrypt_buffer(key, plaintext)
  local padded = elinksmart_add_padding(plaintext)
  if ELINK_DBG then
    dbg_hex("AES encrypt input (after PKCS7 if any)", padded)
  end
  local out = {}
  for i = 1, #padded, 16 do
    local block = string.sub(padded, i, i + 15)
    local cipherb = aes_ecb_encrypt(key, block)
    if ELINK_DBG then
      dbg_hex(string.format("  AES ECB encrypt block@%d plaintext_in", i - 1), block)
      dbg_hex(string.format("  AES ECB encrypt block@%d ciphertext_out", i - 1), cipherb)
    end
    table.insert(out, cipherb)
  end
  return table.concat(out)
end

--- Expected challenge proof = first 4 bytes of AES-ECB(block). Reference firmware uses PKCS7;
--- some Android stacks use AES/ECB/NoPadding with zero fill to 16 bytes — accept either.
local function expected_challenge_proofs(ch_bin)
  local pad = elinksmart_add_padding(ch_bin)
  local enc_pkcs = aes_ecb_encrypt(AES_KEY, string.sub(pad, 1, 16))
  local zero16 = string.sub(ch_bin, 1, 4) .. string.rep(string.char(0), 12)
  local enc_zero = aes_ecb_encrypt(AES_KEY, zero16)
  return string.sub(enc_pkcs, 1, 4), string.sub(enc_zero, 1, 4)
end

local function proof_matches_prefix(prefix4, pkcs4, zero4)
  return prefix4 == pkcs4 or prefix4 == zero4
end


local function proof_ok_for_cached_challenge(params)
  if #challenge_bin ~= 4 or #params < 4 then
    return false
  end
  local pkcs4, zero4 = expected_challenge_proofs(challenge_bin)
  local g1 = string.sub(params, 1, 4)
  if proof_matches_prefix(g1, pkcs4, zero4) then
    return true
  end
  -- Rare layouts: timestamp first ([5..8] = encrypted challenge prefix per reverse-engineered clients)
  if #params >= 8 then
    local g2 = string.sub(params, 5, 8)
    if proof_matches_prefix(g2, pkcs4, zero4) then
      return true
    end
  end
  return false
end

local function unlock_command(cmd)
  return cmd == 0x04 or cmd == 0x12
end

--- Cached challenge ⇒ verify ECB proof; unlock with empty cache ⇒ allow (PIN still checked later).
local function verify_challenge_for_command(command, params)
  if #challenge_bin == 4 then
    return proof_ok_for_cached_challenge(params)
  end
  if unlock_command(command) then
    print("elinksmart: unlock without cached challenge — proof skipped")
    return true
  end
  return false
end

local function dbg_challenge_proof(params)
  dbg_hex("challenge stored (4 B)", challenge_bin)
  if #challenge_bin ~= 4 then
    dbg_print("challenge proof: SKIPPED (#challenge~=4)")
    return
  end
  local pkcs4, zero4 = expected_challenge_proofs(challenge_bin)
  dbg_hex("expected proof PKCS7-prefix (4 B)", pkcs4)
  dbg_hex("expected proof zeroPad16-prefix (4 B)", zero4)
  if params and type(params) == "string" and #params >= 4 then
    dbg_hex("received proof-prefix from params[1..4] (4 B)", string.sub(params, 1, 4))
  end
  if params and type(params) == "string" and #params >= 8 then
    dbg_hex("params bytes [5..8] (alt proof / timestamp slot)", string.sub(params, 5, 8))
  end
  if params and type(params) == "string" and #params >= 14 then
    dbg_hex(
      "params PIN ascii bytes [9..14]",
      string.sub(params, 9, 14)
    )
    dbg_print(
      string.format(
        'packet PIN ("%s")',
        string.sub(params, 9, 14)
      )
    )
  end
end

--- Notify ciphertext to the app using eSmartLock framing (labs.reversec.com / BleProtocolUtils).
--- First pdu: LE u16 (=cipher byte count, must be ≤32767 for signed Java callers) || cipher[..].
--- Later pdus (if needed): raw cipher continuation (≤20 octets each).
local function send_dataout_in_chunks(binary)
  local svc, chr = svc_chr()
  if type(svc) ~= "string" or type(chr) ~= "string" then
    print("elinksmart: missing svc/chr UUIDs")
    return
  end
  local clen = #binary
  if clen >= 32768 then
    print("elinksmart: TX cipher too long for LE16 length header")
    return
  end
  dbg_hex("TX NOTIFY ciphertext (full, before framing)", binary)
  local lo = clen % 256
  local hi = math.floor(clen / 256) % 256
  dbg_print(string.format(
    "TX NOTIFY LE16(cipher_len)=%d bytes 0x%02x 0x%02x (lo hi)",
    clen,
    lo,
    hi
  ))

  local max_first_body = 18
  local first_body = math.min(max_first_body, clen)
  local first_pdu = string.char(lo, hi) .. string.sub(binary, 1, first_body)
  dbg_hex("TX NOTIFY pdu #1 (LE len + cipher start)", first_pdu)
  ble_notify(svc, chr, bin_to_hex(first_pdu))

  local off = first_body + 1
  local part = 2
  while off <= clen do
    local take = math.min(20, clen - off + 1)
    local frag = string.sub(binary, off, off + take - 1)
    dbg_hex(string.format("TX NOTIFY pdu #%d (continuation)", part), frag)
    ble_notify(svc, chr, bin_to_hex(frag))
    off = off + take
    part = part + 1
  end
end

local function parse_decrypted_command(payload)
  print("elinksmart: decrypted payload " .. (#payload) .. " B")
  dbg_hex("DECRYPTED command blob (full)", payload)
  if #payload < 3 then
    visuals_locked_red()
    schedule_revert_blue_locked()
    return
  end
  local command_size = string.byte(payload, 1)
  local command = string.byte(payload, 3)
  local command_payload = string.sub(payload, 3)
  local command_params = string.sub(command_payload, 3)
  dbg_hex("DECRYPTED tail (from byte3 params)", command_params)
  print(string.format("elinksmart: command_size=%d cmd=0x%02x", command_size, command))

  if command == 1 then
    visuals_locked_blue()
    local chal_ok, ch = pcall(function()
      return random_bytes(4)
    end)
    if not chal_ok or type(ch) ~= "string" or #ch ~= 4 then
      ch = string.char(
        math.random(0, 255),
        math.random(0, 255),
        math.random(0, 255),
        math.random(0, 255)
      )
    end
    challenge_bin = ch
    dbg_hex("AUTH challenge (4 B random)", ch)
    local plain = string.char(0x30, 0x00, 0x01, 0x00) .. ch .. hex_to_bin(AUTH_TAIL_HEX)
    if #plain ~= 64 then
      print("elinksmart: internal auth template length " .. (#plain))
      visuals_locked_red()
      schedule_revert_blue_locked()
      return
    end
    dbg_hex("AUTH plaintext (64 B before AES)", plain)
    local enc = aes_encrypt_buffer(AES_KEY, plain)
    dbg_hex("AUTH ciphertext (before chunking)", enc)
    send_dataout_in_chunks(enc)
    gfx_print_notification("Auth: issued challenge")
    return
  end

  local chal_ok = verify_challenge_for_command(command, command_params)
  if chal_ok then
    if command == 0x04 or command == 0x12 then
      local pkt_pin = ""
      if #command_params >= 14 then
        pkt_pin = string.sub(command_params, 9, 14)
      end
      local want = resolve_sim_pin()
      print(
        string.format(
          "elinksmart: UNLOCK cmd=0x%02x PIN=%s",
          command,
          pkt_pin ~= "" and pkt_pin or "(short)"
        )
      )
      if pkt_pin ~= want then
        print("elinksmart: PIN mismatch — no ACK")
        dbg_challenge_proof(command_params)
        visuals_locked_red()
        gfx_print_notification(
          string.format(
            "Wrong PIN: %s",
            pkt_pin ~= "" and pkt_pin or "(short)"
          )
        )
        schedule_revert_blue_locked()
        return
      end
      print("elinksmart: unlock OK")
      visuals_unlocked_green()
      gfx_print_notification(string.format("Unlock OK: PIN %s", pkt_pin ~= "" and pkt_pin or want))
      schedule_revert_blue_locked()
    elseif command == 0x0c then
      print("elinksmart: factory reset requested")
      visuals_locked_blue()
      gfx_print_notification("Factory reset (simulated)")
    else
      print(string.format("elinksmart: cmd 0x%02x ok", command))
    end

    local plain_ack = string.char(0x04, 0x00, command, 0x00, 0x00, 0x00)
    dbg_hex("ACK plaintext (6 B)", plain_ack)
    local enc_ack = aes_encrypt_buffer(AES_KEY, plain_ack)
    dbg_hex("ACK ciphertext", enc_ack)
    send_dataout_in_chunks(enc_ack)
  else
    local had_challenge = (#challenge_bin == 4)
    if had_challenge then
      print("elinksmart: wrong challenge response")
      local ok, h = pcall(bin_to_hex, challenge_bin)
      if ok and type(h) == "string" then
        print("elinksmart: stored_challenge_hex=" .. h .. " (from last auth notify)")
      end
    else
      print(string.format(
        "elinksmart: cmd 0x%02x rejected: login (cmd 1) first — no cached challenge",
        command
      ))
    end
    if unlock_command(command) and #command_params >= 14 then
      print(string.format(
        "elinksmart: proof mismatch path packet PIN=%s",
        string.sub(command_params, 9, 14)
      ))
    end
    if had_challenge then
      dbg_challenge_proof(command_params)
    end
    visuals_locked_red()
    if had_challenge then
      local pkt = (#command_params >= 14) and string.sub(command_params, 9, 14) or ""
      if unlock_command(command) and pkt ~= "" then
        gfx_print_notification(string.format("Rejected: bad proof (PIN %s)", pkt))
      else
        gfx_print_notification("Rejected: bad challenge proof")
      end
    else
      gfx_print_notification(string.format("Rejected: login first (cmd 0x01)"))
    end
    schedule_revert_blue_locked()
    challenge_bin = ""
  end
end

local function append_bytes_from(pkt, start_i, end_j)
  for i = start_i, end_j do
    agg_bytes[#agg_bytes + 1] = string.sub(pkt, i, i)
  end
end

local function process_complete_buffer(last_frag_len)
  local eff_len = cipher_budget - (20 - last_frag_len)
  dbg_print(string.format(
    "reassembly done: cipher_budget=%s last_frag_len=%d agg_count=%d eff_len=%d",
    tostring(cipher_budget),
    last_frag_len,
    #agg_bytes,
    eff_len
  ))
  cipher_budget = 0
  incoming_active = false
  expecting_remaining = 0
  local take = math.min(eff_len, #agg_bytes)
  dbg_hex("reassembled ciphertext (raw agg, all bytes recv)", table.concat(agg_bytes, "", 1, #agg_bytes))
  if take <= 0 then
    print("elinksmart: empty ciphertext after reassembly")
    agg_bytes = {}
    visuals_locked_red()
    schedule_revert_blue_locked()
    return
  end
  local blob = table.concat(agg_bytes, "", 1, take)
  agg_bytes = {}
  dbg_hex("ciphertext fed to AES (first eff_len bytes)", blob)

  local dec, err = aes_decrypt_buffer(AES_KEY, blob)
  if not dec then
    print("elinksmart: decrypt failed: " .. tostring(err))
    visuals_locked_red()
    schedule_revert_blue_locked()
    return
  end
  parse_decrypted_command(dec)
end

--- Reassemble chunked writes → decrypt → dispatch.
local function ingest_write_packet(pkt)
  local n = #pkt
  if n < 2 then
    return
  end
  if not incoming_active and n < 3 then
    dbg_print("RX first fragment too short (need >=3 B for 2 B hdr + cipher); ignoring")
    return
  end
  dbg_hex("RX ATT write (raw)", pkt)
  print("elinksmart: RX " .. n .. " B (active=" .. tostring(incoming_active) .. ")")

  if not incoming_active then
    local b1 = string.byte(pkt, 1)
    local b2 = string.byte(pkt, 2)
    local packet_count = swap_nibbles_u8(b1)
    cipher_budget = packet_count * 20 - 2
    agg_bytes = {}
    dbg_print(string.format(
      "RX 1st frag hdr: byte1=0x%02x byte2=0x%02x nib_swap_count=%d cipher_budget=%d (payload start Lua index 3, C index 2)",
      b1,
      b2,
      packet_count,
      cipher_budget
    ))
    -- Mirror ESP32 nimBLE sample: hdr = data[0] + data[1]; ciphertext begins at data[2] → Lua index 3.
    append_bytes_from(pkt, 3, n)
    incoming_active = packet_count > 1
    expecting_remaining = packet_count > 1 and (packet_count - 1) or 0
  else
    append_bytes_from(pkt, 1, n)
    expecting_remaining = expecting_remaining - 1
  end

  if expecting_remaining ~= 0 then
    return
  end

  process_complete_buffer(n)
end

--- Hook for both DATIN and DATIN2 writes.
function on_write_smartlock_datain(input)
  ingest_write_packet(input)
  return input
end

function on_startup()
  apply_adv_name_from_bd_addr()
  local pin = resolve_sim_pin()
  visuals_locked_blue()
  print(
    string.format(
      "elinksmart lock: AES ECB + LE notify framing; vars.pin/default sim PIN loaded (%s). ELINK_DBG=%s",
      pin,
      tostring(ELINK_DBG)
    )
  )
end
