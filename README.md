Device library is a collection of definitions (JSON format) and optional dynamic scripts (LUA) that can act in various BLE roles.

## Overview


A **library entry** is a folder on the filesystem that describes BLE device roles (each optional):
 - **Observer** - for recognizing the device based on advertised data: matching conditions, decoding logic
 - **Central** - for connecting and controlling the peripheral device: quick action or full menu scripts
 - **Peripheral** - for device simulation: its BLE GATT profile (services + characteristics), advertising data, UI, interface, and scripting logic.


## Device folder layout

```text
my-device/
  manifest.json         ← identity, role declarations, asset paths
  ble.json              ← GATT services, characteristics, descriptors, pairing
  vars.json             ← runtime variables (strings, numbers, bools)
  uuids.json            ← symbolic name → UUID map
  assets/
    icon.svg
    other_graphic.png
    graphics.json
  observer/
    adv_decode.lua      ← Lua script executed during BLE scan
  central/
    dynamic.lua         ← Lua script executed on the GATT client
    menu.json           ← GATT-client menu tree with Lua snippet hooks
  peripheral/
    adv.json            ← advertising profiles (raw hex, scan response)
    interface.json      ← peripheral "physical" interface
    dynamic.lua         ← peripheral Lua script
```

## More information

[Device Library documentation](https://blesplo.it/docs/device-library)

[Device Profile Sharing Policy](https://blesplo.it/policies/sharing-policy/)


