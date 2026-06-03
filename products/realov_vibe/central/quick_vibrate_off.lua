-- Quick action: speed 0 -> C555 00 AA (off; see uuids.json).

function run()
    if gatt_has_characteristic(uuids.SVC_REALOV, uuids.CHR_SPEED) == false then
        log("realov_vibe: FFE1 not present")
        return
    end
    if not ble_write(uuids.SVC_REALOV, uuids.CHR_SPEED, "c55500aa", false) then
        log("realov_vibe: write C55500AA failed")
        return
    end
    log("realov_vibe: off (C55500AA)")
end
