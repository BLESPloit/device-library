--[[
  Shell SuperCars peripheral
  References:
    https://codeberg.org/Freeyourgadget/Gadgetbridge/src/branch/master/app/src/main/java/nodomain/freeyourgadget/gadgetbridge/service/devices/supercars/SuperCarsSupport.java
    https://codeberg.org/Freeyourgadget/Gadgetbridge/src/branch/master/app/src/main/java/nodomain/freeyourgadget/gadgetbridge/devices/supercars/SuperCarsConstants.java

  - Central writes AES-ECB (no padding) 16-byte ciphertext to CHR_DRIVE_CONTROL.
  - Plaintext layout (16 bytes, indices 1-based Lua):
      [1]=0x00 [2]='C' [3]='T' [4]='L'
      [5] UP movement flag   [6] DOWN movement flag
      [7] LEFT dir flag      [8] RIGHT dir flag
      [9] headlights: 0=ON, 1=OFF
      [10] speed: 0x50=NORMAL, 0x64=TURBO
  - Battery notify on CHR_BATTERY_NOTIFY: same AES key; Gadgetbridge decrypts and uses plaintext byte [5] (Java index 4) as level.

  - Advertising: Short Local Name `QCAR-` + 6 uppercase hex nibbles from the **last three** BD octets (`get_adv_bd_addr("leg_adv_ind")`; `adv_set_data` overrides static adv.json when host binds both).
]]

local AES_KEY = string.char(
  0x34, 0x52, 0x2a, 0x5b, 0x7a, 0x6e, 0x49, 0x2c,
  0x08, 0x09, 0x0a, 0x9d, 0x8d, 0x2a, 0x23, 0xf8
)

local battery_percent = 100

--- `peripheral/adv.json` profile id
local ADV_PROFILE_ID = "leg_adv_ind"
--- AD: Flags only; Short Local Name follows; manufacturer blob matches sample `adv_data_hex`.
local ADV_FLAGS_HEX = "020106"
local ADV_TAIL_HEX = "05ff5452003c"
--- Shortened Local Name: "QCAR-" + 6 hex chars (three address octets), e.g. QCAR-1E6651
local ADV_SHORT_NAME_PREFIX = "QCAR-"
local SHORT_NAME_AD_TYPE = 0x08

--- Last three BD octets as 6 uppercase hex digits ("1e","66","51" → "1E6651").
local function bd_addr_last_three_octets_hex(bd_mac)
  if type(bd_mac) ~= "string" or bd_mac == "" then
    return nil
  end
  local octets = {}
  for oct in bd_mac:gmatch("%x%x") do
    octets[#octets + 1] = oct
  end
  if #octets < 3 then
    return nil
  end
  return (
    octets[#octets - 2] .. octets[#octets - 1] .. octets[#octets]
  ):upper()
end

local function build_shell_supercars_adv(short_name_str)
  local ok_f, flags = pcall(hex_to_bin, ADV_FLAGS_HEX)
  local ok_t, tail = pcall(hex_to_bin, ADV_TAIL_HEX)
  if not ok_f or type(flags) ~= "string" or not ok_t or type(tail) ~= "string" then
    return nil, "hex_to_bin(flags/tail) failed"
  end
  if type(short_name_str) ~= "string" or #short_name_str < 1 or #short_name_str > 29 then
    return nil, "invalid Shortened Local Name length"
  end
  local inner = 1 + #short_name_str
  if inner > 255 then
    return nil, "AD inner length overflow"
  end
  local name_tlv =
    string.char(inner, SHORT_NAME_AD_TYPE) .. short_name_str
  return flags .. name_tlv .. tail, nil
end

local function apply_adv_name_from_bd_addr()
  if type(adv_set_data) ~= "function" or type(get_adv_bd_addr) ~= "function" then
    return
  end
  local bd, errmsg = get_adv_bd_addr(ADV_PROFILE_ID)
  if type(bd) ~= "string" or bd == "" then
    print("shell_car: get_adv_bd_addr: " .. tostring(errmsg))
    return
  end
  local suf = bd_addr_last_three_octets_hex(bd)
  if not suf then
    print(
      string.format(
        "shell_car: could not derive last-three-octets from BD (%s)",
        bd
      )
    )
    return
  end
  local name = ADV_SHORT_NAME_PREFIX .. suf
  local blob, berr = build_shell_supercars_adv(name)
  if not blob then
    print("shell_car: adv build: " .. tostring(berr))
    return
  end
  local ok_h, h = pcall(bin_to_hex, blob)
  if not ok_h or type(h) ~= "string" then
    print("shell_car: bin_to_hex(adv) failed")
    return
  end
  local ok_set, setterr = adv_set_data(ADV_PROFILE_ID, h)
  if ok_set ~= true then
    print("shell_car: adv_set_data: " .. tostring(setterr))
    return
  end
  print(string.format("shell_car: advertising Shortened Local Name %q (%s)", name, bd))
end

local function clamp_pct(x)
  if x < 0 then return 0 end
  if x > 100 then return 100 end
  return math.floor(x + 0.5)
end

--- Plaintext block for battery notify (Gadgetbridge reads Java index 4 = Lua byte index 5).
local function build_battery_plaintext(level)
  level = clamp_pct(level)
  return string.char(0, 0, 0, 0, level, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
end

local function push_battery_notify()
  local ok, enc = pcall(function()
    return aes_ecb_encrypt(AES_KEY, build_battery_plaintext(battery_percent))
  end)
  if not ok then
    print("shell_car: battery encrypt failed: " .. tostring(enc))
    return
  end
  ble_notify(uuids.SVC_SUPER_CARS, uuids.CHR_BATTERY_NOTIFY, enc)
end

local function describe_movement(pt)
  local up = string.byte(pt, 5)
  local dn = string.byte(pt, 6)
  if up == 1 then return "up" end
  if dn == 1 then return "down" end
  return "idle"
end

local function describe_direction(pt)
  local l = string.byte(pt, 7)
  local r = string.byte(pt, 8)
  if l == 1 then return "left" end
  if r == 1 then return "right" end
  return "center"
end

local function describe_light(pt)
  local b = string.byte(pt, 9)
  if b == 0 then return "lights on" end
  if b == 1 then return "lights off" end
  return string.format("light 0x%02x", b)
end

local function describe_speed(pt)
  local b = string.byte(pt, 10)
  if b == 0x50 then return "normal" end
  if b == 0x64 then return "turbo" end
  return string.format("speed 0x%02x", b)
end

local function is_supercars_magic(pt)
  return #pt == 16
    and string.byte(pt, 1) == 0x00
    and string.byte(pt, 2) == 0x43
    and string.byte(pt, 3) == 0x54
    and string.byte(pt, 4) == 0x4c
end

local function format_drive_line(pt)
  return string.format(
    "%s | %s | %s | %s | bat %d%%",
    describe_movement(pt),
    describe_direction(pt),
    describe_light(pt),
    describe_speed(pt),
    battery_percent
  )
end

--- Called from ble.json dynamic.on_write on encrypted drive characteristic.
function on_write_supercars_drive(input)
  local n = #input
  if n ~= 16 then
    print(string.format("shell_car: drive write length %d (expected 16), ignored", n))
    return input
  end

  local ok, pt = pcall(function()
    return aes_ecb_decrypt(AES_KEY, input)
  end)
  if not ok then
    print("shell_car: AES decrypt failed: " .. tostring(pt))
    return input
  end

  if not is_supercars_magic(pt) then
    print("shell_car: decrypted payload missing \\0CTL magic")
    local hex = ""
    for i = 1, #pt do
      hex = hex .. string.format("%02x", string.byte(pt, i))
    end
    print("shell_car: pt hex=" .. hex)
    return input
  end

  local spd = string.byte(pt, 10)

  local line = format_drive_line(pt)
  print("shell_car: " .. line)
  gfx_update_text("status", line)

--  push_battery_notify()
  return input
end

function on_startup()
  apply_adv_name_from_bd_addr()
  gfx_show("car")
  gfx_show("status")
  gfx_update_text("status", string.format("Ready | bat %d%%", battery_percent))
  push_battery_notify()
end
