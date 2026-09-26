-- Central menu: Shell Racing Legends drive writes (FFF1 Write Command).
-- Packet (8 bytes): 01 | fwd | rev | left | right | light | turbo | special
-- Captured against SL-SF-24; see sample_scans/protocol.txt and sample_dump.pcapng.

local lights_on = false
local turbo_on = false

local function flag(on)
  return on and 1 or 0
end

local function craft_hex(fwd, rev, left, right, special)
  return "01"
    .. hex.u8(flag(fwd))
    .. hex.u8(flag(rev))
    .. hex.u8(flag(left))
    .. hex.u8(flag(right))
    .. hex.u8(flag(lights_on))
    .. hex.u8(flag(turbo_on))
    .. hex.u8(flag(special))
end

local function send_drive(fwd, rev, left, right, special, label)
  if not ble_connected() then
    gfx_print_text("Not connected")
    return
  end
  local hex = craft_hex(fwd, rev, left, right, special)
  -- Capture used ATT Write Command (0x52) → write without response.
  if not ble_write(uuids.SVC_CONTROL, uuids.CHR_DRIVE, hex, true) then
    gfx_print_text("Write failed")
    return
  end
  set_title("Racing Legends")
  set_state("last", label .. " (" .. hex .. ")")
  gfx_print_text(label)
end

local function refresh_states()
  set_state("lights", lights_on and "ON" or "OFF")
  set_state("turbo", turbo_on and "ON" or "OFF")
end

function on_main_enter()
  refresh_states()
end

function drive_forward()
  send_drive(true, false, false, false, false, "Forward")
end

function drive_reverse()
  send_drive(false, true, false, false, false, "Reverse")
end

function drive_left()
  send_drive(false, false, true, false, false, "Left")
end

function drive_right()
  send_drive(false, false, false, true, false, "Right")
end

function drive_stop()
  send_drive(false, false, false, false, false, "Stop")
end

function cmd_spin()
  -- Byte 7 set once in capture; app reviews mention a 360° / special move.
  send_drive(false, false, false, false, true, "Spin / special")
end

function cmd_lights_on()
  lights_on = true
  refresh_states()
  drive_stop()
  gfx_print_text("Lights ON")
end

function cmd_lights_off()
  lights_on = false
  refresh_states()
  drive_stop()
  gfx_print_text("Lights OFF")
end

function cmd_turbo_on()
  turbo_on = true
  refresh_states()
  drive_stop()
  gfx_print_text("Turbo ON")
end

function cmd_turbo_off()
  turbo_on = false
  refresh_states()
  drive_stop()
  gfx_print_text("Turbo OFF")
end
