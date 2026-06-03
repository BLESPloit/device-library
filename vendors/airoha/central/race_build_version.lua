-- RACE minimal "get build version" probe (race-toolkit-style cmd 0x1E08, empty payload on wire).
-- Manifest supplies vars.svc / vars.tx / vars.rx like race_flash.lua.
-- Request preset hex: 055a0200081e (LENGTH=2 counts cmd only; NOTIFY reply on RX).

local RACE_CMD_BUILD_INFO = 0x1E08
local RACE_TYPE_RSP = 0x5B
local REQ_HEX = "055a0200081e"

local BUILD_VER_TITLE_SUFFIX = " · Airoha build version read confirmed"

local function parse_build_rsp(hex_data)
  if not hex_data or hex_data == "" then
    return false, nil, "empty notification"
  end
  local b = hex_to_bin(hex_data)
  if not b or #b < 7 then
    return false, nil, "packet too short"
  end
  local typ = string.byte(b, 2)
  if typ ~= RACE_TYPE_RSP then
    return false, nil, string.format("expected RESPONSE 0x5B got 0x%02x", typ)
  end
  local cmd_lo = string.byte(b, 5)
  local cmd_hi = string.byte(b, 6)
  local cmd = cmd_lo + cmd_hi * 256
  if cmd ~= RACE_CMD_BUILD_INFO then
    return false, nil, string.format("expected cmd 0x%04x got 0x%x", RACE_CMD_BUILD_INFO, cmd)
  end
  local ret = string.byte(b, 7)
  if ret ~= 0 then
    return false, nil, string.format("return_code=%d", ret)
  end
  local body = ""
  if #b > 7 then
    body = string.sub(b, 8)
  end
  return true, body, nil
end

--- Extract printable ASCII runs from binary body (NUL-padded build / version fields).
local function decode_build_version_text(bin_body, min_run)
  min_run = min_run or 4
  if not bin_body or #bin_body == 0 then
    return ""
  end
  local parts = {}
  local cur = ""
  for i = 1, #bin_body do
    local ch = string.byte(bin_body, i)
    if ch >= 32 and ch <= 126 then
      cur = cur .. string.char(ch)
    else
      if #cur >= min_run then
        parts[#parts + 1] = cur
      end
      cur = ""
    end
  end
  if #cur >= min_run then
    parts[#parts + 1] = cur
  end
  return table.concat(parts, " | ")
end

local function scan_row_base_title()
  local title = fp_get("enrichment_display_name")
  if title and title ~= "" then
    return title
  end
  title = fp_get("display_name")
  if title and title ~= "" then
    return title
  end
  return gatt_address()
end

local function apply_build_version_confirmed_title()
  local base = scan_row_base_title()
  if base:find("Build version NOTIFY confirmed", 1, true) then
    fp_set("enrichment_display_name", base)
    return
  end
  fp_set("enrichment_display_name", base .. BUILD_VER_TITLE_SUFFIX)
end

local function fp_build_probe(attrs)
  fp_append("airoha_race_build_version_probe", attrs, "Check Airoha vulnerability: build version")
end

function run()
  if type(uuids) ~= "table" then
    log("RESULT: FAIL — uuids global missing (open script from Airoha device pack).")
    fp_build_probe({
      race_build_verdict = "config_error",
      race_build_vulnerability_confirmed = false,
      race_error = "uuids_missing",
      race_variant = "",
      gatt_mac = gatt_address(),
    })
    return
  end
  if type(vars) ~= "table" then
    log("RESULT: FAIL — vars missing (manifest central.scripts[].vars).")
    fp_build_probe({
      race_build_verdict = "config_error",
      race_build_vulnerability_confirmed = false,
      race_error = "vars_missing",
      race_variant = "",
      gatt_mac = gatt_address(),
    })
    return
  end
  local sk = vars.svc
  local tk = vars.tx
  local rk = vars.rx
  if not sk or sk == "" or not tk or tk == "" or not rk or rk == "" then
    log("RESULT: FAIL — vars.svc, vars.tx, vars.rx required.")
    fp_build_probe({
      race_build_verdict = "config_error",
      race_build_vulnerability_confirmed = false,
      race_error = "vars_incomplete",
      race_variant = tostring(vars.variant or ""),
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
    fp_build_probe({
      race_build_verdict = "config_error",
      race_build_vulnerability_confirmed = false,
      race_error = "uuid_keys_missing",
      race_variant = tostring(vars.variant or ""),
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
    fp_build_probe({
      race_build_verdict = "ble_subscribe_failed",
      race_build_vulnerability_confirmed = false,
      race_variant = tostring(label),
      gatt_mac = gatt_address(),
    })
    return
  end
  delay_ms(80)
  start_notify_wait(SVC, RX, 180)
  if not ble_write(SVC, TX, REQ_HEX, true) then
    log("RESULT: FAIL — RACE TX write did not complete (" .. tostring(label) .. ").")
    fp_build_probe({
      race_build_verdict = "write_failed",
      race_build_vulnerability_confirmed = false,
      race_variant = tostring(label),
      gatt_mac = gatt_address(),
    })
    return
  end
  local rsp_hex = finish_notify_wait(SVC, RX, 12000)
  local ok, body, err = parse_build_rsp(rsp_hex)
  if not ok then
    log(
      "RESULT: FAIL — build-info NOTIFY invalid ("
        .. tostring(label)
        .. "): "
        .. (err or "?")
    )
    fp_build_probe({
      race_build_verdict = "response_invalid",
      race_build_vulnerability_confirmed = false,
      race_response_error = err or "",
      race_variant = tostring(label),
      gatt_mac = gatt_address(),
    })
    return
  end
  local decoded = decode_build_version_text(body)
  log(
    "RESULT: PASS — Airoha build-info NOTIFY confirmed (vendor debug responding to cmd 0x1E08, variant "
      .. tostring(label)
      .. ")."
  )
  if decoded ~= "" then
    log("Build version (decoded ASCII): " .. decoded)
  else
    log("Build version: no printable ASCII runs in NOTIFY body (see raw hex on device).")
  end
  local peek = rsp_hex or ""
  if #peek > 64 then
    peek = peek:sub(1, 64) .. "…"
  end
  log("race_build_version (" .. tostring(label) .. "): NOTIFY prefix_hex=" .. peek)
  apply_build_version_confirmed_title()
  fp_build_probe({
    race_build_verdict = "vendor_debug_confirmed",
    race_build_vulnerability_confirmed = true,
    race_build_decoded = decoded,
    race_notify_prefix_hex = (rsp_hex and rsp_hex ~= "" and #rsp_hex > 128) and (rsp_hex:sub(1, 128)) or (rsp_hex or ""),
    race_variant = tostring(label),
    research_ref = "CVE-2025-20700 CVE-2025-20702",
    gatt_mac = gatt_address(),
  })
end
