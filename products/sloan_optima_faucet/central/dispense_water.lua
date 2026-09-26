-- Quick action: Gen1 remote water dispense.
-- ATT Write Request (0x12) to Water Dispense …c965 with value 0x31 ('1').
-- Confirmed against FAUCET ADSKU02 A0149 GATT (handle 0x00b3 in that capture).

local SVC = uuids.DIAGNOSTIC_SERVICE
local CHR = uuids.WATER_DISPENSE
local DISPENSE_HEX = "31"

function run()
  if not ble_connected() then
    log("sloan_optima: not connected")
    gfx_print_text("Not connected")
    return
  end

  if gatt_has_characteristic(SVC, CHR) == false then
    log("sloan_optima: water dispense characteristic not present")
    gfx_print_text("No dispense char")
    return
  end

  -- Write with response (default); matches ATT opcode 0x12 on the wire.
  if not ble_write(SVC, CHR, DISPENSE_HEX) then
    log("sloan_optima: dispense write failed")
    gfx_print_text("Dispense failed")
    return
  end

  log("sloan_optima: wrote 0x31 to Water Dispense (remote dispense)")
  fp_set("last_dispense", "31")
  fp_set("display_info", "Dispense commanded")
  gfx_print_text("Water dispense")
end
