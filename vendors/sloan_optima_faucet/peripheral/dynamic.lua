-- Sloan Optima Gen1 peripheral sim (from FAUCET ADSKU02 A0149 scan).
-- Adv: Flags + Battery 0x180F + faucet service …c900; name FAUCET ADSKU02 A0149.
-- Water Dispense …c965: Write Request 0x31 triggers a dispense toast.

local ADV_PROFILE_ID = "adv1"

local function battery_percent()
  local pct = tonumber(vars.battery_percent) or 99
  if pct < 0 then
    return 0
  end
  if pct > 100 then
    return 100
  end
  return pct
end

function on_read_battery(_input)
  return string.char(battery_percent())
end

function on_write_water_dispense(input)
  local data = bin_to_hex(input)
  if not data then
    return input
  end
  data = hex.norm(data)
  print("sloan_optima: Water Dispense write " .. data)
  if hex.byte(data, 1) == 0x31 then
    vars.last_dispense = "31"
    if type(vars_save) == "function" then
      vars_save()
    end
    gfx_print_notification("Water dispense", "top_center", 0, 8)
    gfx_update_text("status", "Dispensing…", 0x0B6E99)
    delay(1.5, "clear_dispense_status")
  end
  return input
end

function clear_dispense_status()
  gfx_update_text("status", vars.device_name or "FAUCET ADSKU02 A0149", 0x333333)
end

function on_startup()
  gfx_show("faucet")
  gfx_render_text("status", "bottom_center", 0, -12, 0x333333)
  gfx_update_text("status", vars.device_name or "FAUCET ADSKU02 A0149", 0x333333)
  if type(adv_enable) == "function" then
    adv_enable(ADV_PROFILE_ID)
  end
  gfx_print_notification(
    string.format("Sloan Optima sim · %d%%", battery_percent()),
    "top_center",
    0,
    8
  )
end
