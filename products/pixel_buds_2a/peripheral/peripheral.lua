--- Log Fast Pair GATT writes; ble.json maps dynamic.on_write here for write-capable characteristics.
function on_fast_pair_write(input)
  local hex = ""
  for i = 1, #input do
    hex = hex .. string.format("%02X", string.byte(input, i))
  end
  print(string.format("fast_pair write: %d bytes  hex=%s", #input, hex))
  return input
end


function pairing_on()
    local ok, err
    print("Pairing ON!")
    ok, err = adv_disable("legacy")
    if not ok then print("Error:", err) end
    ok, err = adv_enable("legacy_pairing_mode")
    if not ok then print("Error:", err) end
end

function pairing_off()
    local ok, err
    print("Pairing OFF!")
    ok, err = adv_disable("legacy_pairing_mode")
    if not ok then print("Error:", err) end
    ok, err = adv_enable("legacy")
    if not ok then print("Error:", err) end
end

function on_startup()
    gfx_show("icon")
end
