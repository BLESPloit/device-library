-- Sample quick action for BLESPlo.it Light.
-- Option 1: write a fixed on/off byte. Comment Option 2 and uncomment "01" or "00".
-- Option 2: toggle from the advertisement state 
-- Option 3: when turning on, also write a color. Uncomment the static block or the random block.

local SVC = uuids.SVC_LIGHTBULB
local CHR_ON = uuids.CHR_ONOFF
local CHR_RGB = uuids.CHR_RGB

function run()
  if not ble_connected() then return end

  -- Option 1
  -- local payload = "01"
  -- local payload = "00"

  -- Option 2. Read current state and toggle it
  local cur = ble_read(SVC, CHR_ON) or ""
  local payload = (hex.byte(cur, 1) == 1) and "00" or "01"

  local ok, err = ble_write(SVC, CHR_ON, payload)
  if not ok then
    log("Write failed: " .. tostring(err))
    return
  end

  -- Option 3a, static color. The bulb stores it while off and shows it once on.
  -- if payload == "01" then
  --   local color = "FF8800"
  --   local color_ok, color_err = ble_write(SVC, CHR_RGB, color)
  --   if not color_ok then
  --     log("Color failed: " .. tostring(color_err))
  --     return
  --   end
  --   log("Light ON  #" .. color)
  --   return
  -- end

  -- Option 3b, random color. Uncomment this instead of the static block.
  -- if payload == "01" then
  --   local color = string.upper(
  --     hex.u8(math.random(0, 255))
  --       .. hex.u8(math.random(0, 255))
  --       .. hex.u8(math.random(0, 255))
  --   )
  --   local color_ok, color_err = ble_write(SVC, CHR_RGB, color)
  --   if not color_ok then
  --     log("Color failed: " .. tostring(color_err))
  --     return
  --   end
  --   log("Light ON  #" .. color)
  --   return
  -- end

  log(payload == "01" and "Light ON" or "Light OFF")
end
