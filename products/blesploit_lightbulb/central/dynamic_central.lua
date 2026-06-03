-- UUIDs from uuids.json (Lua global `uuids`); GATT callbacks may use hyphenated or compact 128-bit forms.

local function uuid(sym)
  local u = uuids and uuids[sym]
  if type(u) ~= "string" or u == "" then
    return nil
  end
  return u
end

local function norm_uuid(s)
  if not s or type(s) ~= "string" then
    return ""
  end
  return (s:lower():gsub("%-", ""))
end

local function same_chr(a, b)
  return norm_uuid(a) == norm_uuid(b) and norm_uuid(a) ~= ""
end

local function svc_rgb()
  return uuid("SVC_LIGHTBULB"), uuid("CHR_ONOFF"), uuid("CHR_RGB")
end

local function show_rgb_read(hex, err)
  if err and err ~= "" then
    gfx_print_text("Read error: " .. err)
    return
  end
  if hex and hex ~= "" then
    gfx_print_text("Color data: " .. hex)
    set_state("color", hex)
  end
end

function on_connected()
  print("LUA on_connected called")
  local SVC, CHR_ON, _ = svc_rgb()
  if not SVC or not CHR_ON then
    print("central: need SVC_LIGHTBULB / CHR_ONOFF in uuids.json")
    return
  end
  local ok, err = ble_subscribe(SVC, CHR_ON)
  if not ok then
    print("Subscribe failed")
  end
end

function on_main_enter()
  print("LUA on_main_enter")
end

function on_select_on()
  local SVC, CHR_ON, _ = svc_rgb()
  if not SVC or not CHR_ON then return end
  local ok, err = ble_write(SVC, CHR_ON, "\x01")
  if ok then
    set_title("Light ON")
    set_state("power", "ON")
  end
end

function on_select_off()
  local SVC, CHR_ON, _ = svc_rgb()
  if not SVC or not CHR_ON then return end
  local ok, err = ble_write(SVC, CHR_ON, "\x00")
  if ok then
    set_title("Light OFF")
    set_state("power", "OFF")
  end
end

function on_select_color()
  push_menu("color")
end

function set_color(color)
  local SVC, _, CHR_RGB = svc_rgb()
  if not SVC or not CHR_RGB then return end
  -- color is hex like "FF0000" (red). CHR_RGB expects 3 bytes.
  if #color >= 6 then
    local ok = ble_write(SVC, CHR_RGB, color:sub(1, 6))
    if ok then
      gfx_print_text("Color set: " .. color:sub(1, 6))
    end
  else
    gfx_print_text("Color: " .. color)
  end
end

-- TEST Called from interface_central menu item:
-- "id": "set_mode(on,fast)"
function set_mode(args)
  gfx_print_text("Args: " .. args)

  -- split "on,fast" by comma if needed
  local mode, speed = args:match("([^,]+),([^,]+)")
  if mode and speed then
    gfx_print_text("Mode: " .. mode .. "  Speed: " .. speed)
  end
end

-- Called from on_enter:
-- "on_enter": "on_enter_menu(settings)"
function on_enter_menu(section)
  gfx_print_text("Entered section: " .. section)
end

function on_select_info()
  local SVC, _, CHR_RGB = svc_rgb()
  if not SVC or not CHR_RGB then return end
  ble_read(SVC, CHR_RGB)
end

function on_select_color_get()
  local SVC, _, CHR_RGB = svc_rgb()
  if not SVC or not CHR_RGB then return end
  ble_read(SVC, CHR_RGB)
end

-- Invoked from Kotlin after each ble_read (main thread); handles remote + local GATT.
function on_ble_read_result(svc_uuid, chr_uuid, hex_data, err)
  local _, _, CHR_RGB = svc_rgb()
  if not CHR_RGB or not same_chr(chr_uuid, CHR_RGB) then
    return
  end
  show_rgb_read(hex_data, err)
end

-- Single handler for ALL incoming notifications
function on_notify(svc_uuid, chr_uuid, hex_data)
  print("LUA: notify received")
  local _, CHR_ON, _ = svc_rgb()
  if CHR_ON and same_chr(chr_uuid, CHR_ON) then
    print("Notify ON/OFF")
    gfx_print_text("ON/OFF notify: " .. hex_data)
    if hex_data == '01' then
      set_state("power", "ON")
    else
      set_state("power", "OFF")
    end
  end
end
