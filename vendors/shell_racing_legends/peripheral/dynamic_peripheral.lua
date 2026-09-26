--[[
  Shell Racing Legends peripheral

  - Central writes plaintext 8-byte drive packets to CHR_DRIVE (FFF1), usually Write Command.
  - Layout: [1]=0x01 [2]=fwd [3]=rev [4]=left [5]=right [6]=light [7]=turbo [8]=special
  - Status line on the sim UI mirrors SuperCars-style movement / lights / turbo feedback.
  - Advertising matches SL-SF-24 sample (flags + incomplete 0x6936 + Complete Local Name).
]]

local function flag_on(b)
  return b == 1
end

local function describe_movement(h)
  if flag_on(hex.byte(h, 2)) then return "forward" end
  if flag_on(hex.byte(h, 3)) then return "reverse" end
  return "idle"
end

local function describe_direction(h)
  if flag_on(hex.byte(h, 4)) then return "left" end
  if flag_on(hex.byte(h, 5)) then return "right" end
  return "center"
end

local function describe_light(h)
  if flag_on(hex.byte(h, 6)) then return "lights on" end
  return "lights off"
end

local function describe_turbo(h)
  if flag_on(hex.byte(h, 7)) then return "turbo" end
  return "normal"
end

local function describe_special(h)
  if flag_on(hex.byte(h, 8)) then return "spin" end
  return nil
end

local function format_drive_line(h)
  local parts = {
    describe_movement(h),
    describe_direction(h),
    describe_light(h),
    describe_turbo(h),
  }
  local special = describe_special(h)
  if special then
    parts[#parts + 1] = special
  end
  return table.concat(parts, " | ")
end

--- Called from ble.json dynamic.on_write on FFF1.
function on_write_drive(input)
  local h = hex.norm(bin_to_hex(input))
  local n = hex.len(h)
  if n < 8 then
    print(string.format("racing_legends: drive write length %d (expected >= 8), ignored", n))
    return input
  end

  if hex.byte(h, 1) ~= 0x01 then
    print("racing_legends: unexpected header, hex=" .. tostring(h))
    return input
  end

  local line = format_drive_line(h)
  print("racing_legends: " .. line)
  gfx_update_text("status", line)
  return input
end

function on_startup()
  gfx_show("car")
  gfx_show("status")
  gfx_update_text("status", "Ready | idle | lights off | normal")
end
