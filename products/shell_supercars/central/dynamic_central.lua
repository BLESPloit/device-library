-- Central menu: SuperCars AES drive writes (Gadgetbridge SuperCarsSupport / craft_packet).
-- Uses bin_to_hex so ble_write gets an even-length hex string (binary AES blocks break ble_write's ISO-8859-1 path).

local AES_KEY = string.char(
  0x34, 0x52, 0x2a, 0x5b, 0x7a, 0x6e, 0x49, 0x2c,
  0x08, 0x09, 0x0a, 0x9d, 0x8d, 0x2a, 0x23, 0xf8
)

local SPEED_NORMAL = 0x50
local car_lights_on = true

local function light_payload_byte()
  return car_lights_on and 0x00 or 0x01
end

--- Plaintext 16 bytes: \0 CTL + movement/direction flags + light + speed + zeros (Gadgetbridge layout).
local function craft_plain(up, down, left, right)
  return string.char(
    0x00, 0x43, 0x54, 0x4c,
    up, down, left, right,
    light_payload_byte(),
    SPEED_NORMAL,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00
  )
end

local function send_flags(up, down, left, right, label)
  local pt = craft_plain(up, down, left, right)
  local ok, ct = pcall(function()
    return aes_ecb_encrypt(AES_KEY, pt)
  end)
  if not ok then
    gfx_print_text("AES encrypt failed: " .. tostring(ct))
    return
  end
  local hex = bin_to_hex(ct)
  if not ble_write(uuids.SVC_SUPER_CARS, uuids.CHR_DRIVE_CONTROL, hex) then
    gfx_print_text("Write failed (check connection)")
    return
  end
  set_title("SuperCars")
  set_state("last", label)
  gfx_print_text(label)
end

function on_main_enter()
  set_state("lights", car_lights_on and "ON" or "OFF")
end

function drive_forward()
  -- UP + CENTER
  send_flags(1, 0, 0, 0, "Forward")
end

function drive_reverse()
  -- DOWN + CENTER
  send_flags(0, 1, 0, 0, "Reverse")
end

function drive_left()
  -- IDLE + LEFT
  send_flags(0, 0, 1, 0, "Left")
end

function drive_right()
  -- IDLE + RIGHT
  send_flags(0, 0, 0, 1, "Right")
end

function drive_stop()
  send_flags(0, 0, 0, 0, "Stop")
end

function cmd_lights_on()
  car_lights_on = true
  set_state("lights", "ON")
  drive_stop()
  gfx_print_text("Lights ON")
end

function cmd_lights_off()
  car_lights_on = false
  set_state("lights", "OFF")
  drive_stop()
  gfx_print_text("Lights OFF")
end
