-- Quick action: speed 30 -> C555 1E AA (see uuids.json).

function run()
    if gatt_has_characteristic(uuids.SVC_REALOV, uuids.CHR_SPEED) == false then
        log("realov_vibe: FFE1 not present")
        return
    end
    if not ble_write(uuids.SVC_REALOV, uuids.CHR_SPEED, "c5551eaa", false) then
        log("realov_vibe: write C5551EAA failed")
        return
    end
    log("realov_vibe: speed 30 (C5551EAA)")
end
