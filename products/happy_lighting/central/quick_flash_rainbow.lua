-- Quick action: turn on (CC2333), then BB 30 0E 44 — rainbow flashing, speed 0x0E.

function run()
  if gatt_has_characteristic(uuids.SVC_HAPPYLIGHT, uuids.CHR_COMMAND) == false then
    log("happy_lighting: " .. uuids.SVC_HAPPYLIGHT .. "->" .. uuids.CHR_COMMAND .. " not present")
    return
  end
  if not ble_write(uuids.SVC_HAPPYLIGHT, uuids.CHR_COMMAND, "cc2333", true) then
    log("happy_lighting: write CC2333 (on) failed")
    return
  end
  delay_ms(300)
  if not ble_write(uuids.SVC_HAPPYLIGHT, uuids.CHR_COMMAND, "bb300444", true) then
    log("happy_lighting: write BB300444 failed")
    return
  end
  log("happy_lighting: on + BB 30 04 44 (rainbow flashing, speed 4)")
end
