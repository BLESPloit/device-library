-- Basic ELM327 clone. FFF2 takes ASCII commands ending in CR.
-- FFF1 notifies the reply. Defaults match a v1.5 chip: echo on, spaces on.
-- 0100 returns vars.pid0100. Any other OBD request returns NO DATA.
-- ATZ restores echo, spaces, and linefeeds and prints the identity banner.

local SVC = uuids.SVC_UART
local CHR_NOTIFY = uuids.CHR_NOTIFY
local ADV_CEVA = "adv1"
local ADV_FFF0 = "adv_fff0"
local FFF0_PREFIX = "03194002020102020a000303f0ff"

local pending = ""

local function flag(name, default)
  if type(vars) ~= "table" or vars[name] == nil then
    return default
  end
  local value = vars[name]
  if value == true or value == 1 or value == "true" then
    return true
  end
  if value == false or value == 0 or value == "false" then
    return false
  end
  return default
end

local function identity()
  if type(vars) == "table" and type(vars.identity) == "string" and vars.identity ~= "" then
    return vars.identity
  end
  return "ELM327 v1.5"
end

local function voltage()
  if type(vars) == "table" and type(vars.voltage) == "string" and vars.voltage ~= "" then
    return vars.voltage
  end
  return "12.6V"
end

local function pid_bytes()
  local raw = "BE3FA813"
  if type(vars) == "table" and type(vars.pid0100) == "string" then
    local norm = (vars.pid0100:gsub("%s+", "")):upper()
    if #norm == 8 and norm:match("^[0-9A-F]+$") then
      raw = norm
    end
  end
  return raw
end

local function nl()
  if flag("linefeeds", false) then
    return "\r\n"
  end
  return "\r"
end

local function show_status(line)
  if type(gfx_show) == "function" then
    gfx_show("dongle")
  end
  if type(gfx_render_text) ~= "function" or type(gfx_update_text) ~= "function" then
    return
  end
  gfx_render_text("status", "bottom_center", 0, -12, 0xd6e4ff)
  gfx_update_text("status", line, 0xd6e4ff)
end

local function notify_text(text)
  local payload = hex.from_ascii(text)
  local size = 20
  if type(get_mtu) == "function" then
    local mtu = tonumber(get_mtu()) or 23
    if mtu - 3 > size then
      size = mtu - 3
    end
  end
  local step = size * 2
  local i = 1
  while i <= #payload do
    local chunk = payload:sub(i, i + step - 1)
    local ok, err = ble_notify(SVC, CHR_NOTIFY, chunk)
    if ok ~= true then
      print("elm327: notify: " .. tostring(err))
      return
    end
    i = i + step
  end
end

local function respond(body, echoed)
  local endline = nl()
  local out = ""
  if echoed and echoed ~= "" then
    out = echoed .. endline
  end
  if body and body ~= "" then
    out = out .. body .. endline
  end
  out = out .. endline .. ">"
  notify_text(out)
end

local function format_0100()
  local body = "4100" .. pid_bytes()
  if not flag("spaces", true) then
    return body
  end
  local parts = {}
  local i = 1
  while i <= #body do
    parts[#parts + 1] = body:sub(i, i + 1)
    i = i + 2
  end
  return table.concat(parts, " ")
end

local function canon(ascii)
  return ((ascii or ""):upper():gsub("%s+", ""))
end

local function handle_command(line_hex)
  local raw = hex.to_ascii(line_hex)
  local cmd = canon(raw)
  if cmd == "" then
    respond("", nil)
    return
  end

  if cmd == "ATZ" then
    pending = ""
    if type(vars) == "table" then
      vars.echo = true
      vars.spaces = true
      vars.linefeeds = false
    end
    local endline = nl()
    notify_text(endline .. endline .. identity() .. endline .. endline .. ">")
    show_status(identity() .. "  reset")
    return
  end

  local echoed = nil
  if flag("echo", true) then
    echoed = raw
  end

  local body
  if cmd == "ATI" or cmd == "AT@1" then
    body = identity()
  elseif cmd == "ATE0" then
    if type(vars) == "table" then
      vars.echo = false
    end
    body = "OK"
  elseif cmd == "ATE1" then
    if type(vars) == "table" then
      vars.echo = true
    end
    body = "OK"
  elseif cmd == "ATL0" then
    if type(vars) == "table" then
      vars.linefeeds = false
    end
    body = "OK"
  elseif cmd == "ATL1" then
    if type(vars) == "table" then
      vars.linefeeds = true
    end
    body = "OK"
  elseif cmd == "ATS0" then
    if type(vars) == "table" then
      vars.spaces = false
    end
    body = "OK"
  elseif cmd == "ATS1" then
    if type(vars) == "table" then
      vars.spaces = true
    end
    body = "OK"
  elseif cmd == "ATRV" then
    body = voltage()
  elseif cmd == "ATD" then
    if type(vars) == "table" then
      vars.echo = true
      vars.spaces = true
      vars.linefeeds = false
    end
    body = "OK"
  elseif cmd == "0100" then
    body = format_0100()
  elseif cmd:sub(1, 2) == "AT" then
    body = "?"
  elseif cmd:match("^[0-9A-F]+$") then
    body = "NO DATA"
  else
    body = "?"
  end

  respond(body, echoed)
  show_status(cmd .. "  " .. body)
end

local function take_lines(chunk_hex)
  pending = pending .. hex.norm(chunk_hex)
  if #pending > 256 then
    pending = ""
    return {}
  end
  local lines = {}
  while true do
    local cut = nil
    local i = 1
    while i + 1 <= #pending do
      if pending:sub(i, i + 1) == "0d" then
        cut = i
        break
      end
      i = i + 2
    end
    if not cut then
      break
    end
    lines[#lines + 1] = pending:sub(1, cut - 1)
    pending = pending:sub(cut + 2)
  end
  return lines
end

function on_write_elm(input)
  local lines = take_lines(bin_to_hex(input))
  for n = 1, #lines do
    handle_command(lines[n])
  end
  return input
end

local function gap_name()
  local name = "OBDII"
  if type(vars) == "table" and type(vars.gap_name) == "string" and vars.gap_name ~= "" then
    name = vars.gap_name
  end
  if name:lower() == "obd ble" then
    return "OBD BLE"
  end
  return "OBDII"
end

local function advertised_service()
  if type(vars) == "table" and type(vars.advertised_service) == "string" and vars.advertised_service:lower() == "fff0" then
    return "fff0"
  end
  return "4353"
end

local function name_tlv(name)
  return hex.u8(1 + #name) .. "09" .. hex.from_ascii(name)
end

local function apply_adv()
  if advertised_service() == "4353" then
    if type(adv_disable) == "function" then
      adv_disable(ADV_FFF0)
    end
    if type(adv_enable) == "function" then
      adv_enable(ADV_CEVA)
    end
    return
  end
  if type(adv_disable) == "function" then
    adv_disable(ADV_CEVA)
  end
  local name = gap_name()
  if type(adv_set_data) == "function" then
    local ok, err = adv_set_data(ADV_FFF0, FFF0_PREFIX .. name_tlv(name), "")
    if ok ~= true then
      print("elm327: adv_set_data: " .. tostring(err))
    end
  end
  if type(adv_enable) == "function" then
    adv_enable(ADV_FFF0)
  end
end

function on_startup()
  apply_adv()
  local line = identity()
  if advertised_service() == "fff0" then
    line = line .. "  " .. gap_name()
  end
  show_status(line)
  if type(gfx_print_notification) == "function" then
    gfx_print_notification(line .. "  FFF1/FFF2", "top_center", 0, 8)
  end
end

function on_connected()
  pending = ""
  show_status(identity() .. "  connected")
end
