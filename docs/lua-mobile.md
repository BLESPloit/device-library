# Lua API mobile

On mobile, Lua does **not** run in the same environment as the ESP32 firmware Lua VM. There are **two mobile Lua contexts** documented here: **Central** and **Observer**. Peripheral scripts are edited and synced on mobile, but they are executed on the ESP32 firmware and are documented separately in [ESP32 Lua API]({{< relref "lua-esp32" >}}).

Do not assume one script sees every function listed in the ESP32 documentation. Mobile Central and mobile Observer have different globals, different entry points, and different available helpers.

---

## Contexts

| Context | When it runs | Engine | Notes |
|--------|---------------|--------|-------|
| Observer | During scan / fingerprint decode | Luaj (`FingerprintScriptRunner`) | Partial helper set; no BLE client calls, no crypto, no menu. |
| Central | After GATT connect, including Scripts / Inspect flows | Luaj (`LuaEngine` + central runtime) | Most mobile BLE, crypto, menu, and helper APIs live here. |

---

## Standard library

Mobile Lua uses Luaj JSE globals, which are broader than the ESP32 firmware runtime. In practice, portable pack scripts should avoid relying on `io`, `os`, or other host-specific libraries even if Luaj exposes them.

---

## Shared mobile globals

The following concepts appear on mobile, though not always in every context.

| Global | Mobile behavior |
|--------|------------------|
| `vars` | Loaded from `vars.json` plus manifest path handling; in Central there may also be a per-script overlay from `roles.central.scripts[].vars`, and overlay values win on key collisions. |
| `uuids` | Loaded from the mobile UUID index for the pack folder id. |
| `assets` | Mobile-only table with fields such as `icon`, `graphics`, and `icon_tint`. Not available in ESP32 peripheral scripts. |

---

## Common mobile helpers

### Hex

| Function | Behavior |
|----------|----------|
| `bin_to_hex(binary)` | Returns uppercase hex. |
| `hex_to_bin(hex)` | Strips whitespace; invalid input returns an empty string instead of raising a Lua error. Input must be handled as raw `byte[]` in Luaj so bytes `>= 0x80` remain one octet. |

This differs from the ESP32 firmware behavior, where invalid hex may hard-fail instead of returning an empty string. [file:1]

---

## Observer

Observer Lua runs during scan / fingerprint decode when `roles.observer.entry` matches scan conditions. This context is mobile-only.

Entry point:

```lua
parse(input) --> entries
parse(input) --> entries, ui
```

Observer has no crypto helpers, no `ble_*` client functions, and no menu functions. It is intended for scan data parsing and fingerprint enrichment only.

### Observer globals

| Global | Description |
|--------|-------------|
| `bits` | Full Observer bits library. |
| `hex_to_bin` | Same mobile hex decoder behavior as above. |
| `bin_to_hex` | Same mobile hex encoder behavior as above. |
| `vars` | Vars table. |
| `uuids` | UUID map. |
| `assets` | Mobile assets table. |

### bits library in Observer

Observer exposes a richer bits library than Central:

- `band`
- `bor`
- `bxor`
- `bnot`
- `rshift`
- `lshift`
- `arshift`
- `byte_at(hex, index)`
- `tohex(n [, width])`
- `fromhex(hex)`
- `be16(hex, offset)`
- `be32(hex, offset)`

### `parse(input)` fields

The `input` table built for Observer parsing may include:

| Field | Description |
|------|-------------|
| `device_name` | Scanned device name. |
| `company_name` | Company name if known. |
| `manufacturer_data` | Map of 4-digit uppercase hex SIG company id → lowercase hex payload (same format as manifest `company_id`, e.g. `"0075"`, `"004C"`). |
| `service_uuids_16` | List or collection of 16-bit service UUIDs. |
| `service_uuids` | Service UUID collection. |
| `service_data` | Service data collection. |
| `raw_adv_hex` | Raw advertising hex. |
| `adv_data_hex_combined` | Combined advertising payload hex. |
| `appearance` | Appearance code. |
| `appearance_name` | Appearance name, if resolved. |
| `cod_major` | Class-of-device major value. |
| `cod_name` | Class-of-device name. |
| `first_company_id` | First manufacturer company id as 4-digit uppercase hex string (e.g. `"0075"`), or absent. |
| `first_service_uuid_16` | First 16-bit service UUID. |
| `fingerprint_entries` | Prior entries from higher-priority observers. |

### Observer return value

Return an array of entries with shape:

```lua
{
  {
    id = "...",
    display_name = "...", -- optional
    attributes = {
      -- key/value attributes
    }
  }
}
```

You may also return a second `ui` table with optional keys such as:

- `device_type`
- `beacon_format`
- `custom_icon`
- `custom_icon_tint`
- `display_name`
- `display_info`

---


## Central

Central Lua runs after GATT connection and is the main mobile GATT-client scripting environment. It includes BLE access, crypto, menu helpers, display helpers, fingerprint helpers, and data helpers.

### Central globals and helpers

| Function / global | Description |
|-------------------|-------------|
| `delay_ms(ms)` | Blocking sleep for 0..10,000 ms. |
| `gfx_print_text(text)` | Display a script status line on mobile; it is cleared after roughly 4 seconds. |
| `push_menu(id)` | Push a menu node by id. |
| `pop_menu()` | Pop the menu stack; returns `bool` indicating whether a menu was popped. |
| `set_title(text)` | Set the UI title. |
| `set_state(key, value)` | Store string UI state by key. |
| `log(...)`, `print(...)` | Routed to the script log observer when the central context is set. |

### Crypto

These are installed in mobile Central only, not in Observer.

| Function | Description |
|----------|-------------|
| `aes_ecb_encrypt` | Same intended semantics as the ESP32 version. |
| `aes_ecb_decrypt` | Same intended semantics as the ESP32 version. |
| `sha256` | Same intended semantics as the ESP32 version. |
| `sha256_first_16` | Same intended semantics as the ESP32 version. |
| `ecdh_generate_keypair` | Same intended semantics as the ESP32 version. |
| `ecdh_compute_shared` | Same intended semantics as the ESP32 version. |
| `random_bytes` | Same intended semantics as the ESP32 version. |

### BLE client API

Mobile Central BLE API details.

| Function | Description |
|----------|-------------|
| `ble_connected()` → bool | Returns whether GATT is ready. |
| `ble_read(svc, chr)` | Returns lowercase hex string or `nil`; also triggers `on_ble_read_result(svc, chr, hex, err)`. |
| `ble_write(svc, chr, data, write_without_resp?)` | Accepts hex string or "binary-ish" string; optional 4th arg sends write without response; returns `bool` only. |
| `ble_subscribe(svc, chr)` | Subscribe for notifications; returns `bool` only. |
| `ble_unsubscribe(svc, chr)` | Unsubscribe; returns `bool` only. |
| `get_mtu()` | Returns ATT MTU, default 23 when unknown. |
| `set_preferred_mtu(mtu)` | Request MTU in range 23..517; return value indicates whether the request was queued on Android. |

### BLE helpers

| Function | Description |
|----------|-------------|
| `start_notify_wait(svc, chr, idle_gap_ms?)` | Arm a notify waiter, including idle-gap reassembly if `idle_gap_ms > 0`. |
| `finish_notify_wait(svc, chr, timeout_ms?)` | Wait for concatenated notify hex or return `nil`; default timeout is 8000 ms. |
| `gatt_address()` | Return normalized peripheral MAC address. |
| `gatt_address_fast_pair_uint48()` | Return Fast Pair uint48; raises LuaError on invalid address. |
| `gatt_has_characteristic(svc, chr)` | Returns `true`, `false`, or `nil` if transport is unavailable. |

### Callbacks and entry points

| Name | Description |
|------|-------------|
| `on_connected` | Optional callback after GATT is ready. |
| `on_notify(svc, chr, hex_payload)` | Notification callback; mobile uses lowercase hex. |
| `on_ble_read_result(svc, chr, hex, err)` | Mobile-only callback after each `ble_read`. |
| `run()` | Invoked once at load for quick-action scripts if defined. |

### Fingerprint and enrichment helpers

| Function | Description |
|----------|-------------|
| `fp_set(key, value)` | Set overlay fingerprint key. |
| `fp_clear(key)` | Remove overlay key. |
| `fp_get(key)` | Read overlay value or `nil`. |
| `fp_append(id, attrs_table, display_name?)` | Append a GATT-origin fingerprint entry. |
| `push_fingerprint(attrs_table, ui_table?)` | Append enrichment entry and optional UI overlay keys. |
| `ui_overlay(key, value)` | Alias for `fp_set`. |
| `fp_apply_fast_pair_post_enrich()` | Run Fast Pair post-processing on the fingerprint. |

### Data helpers

| Function | Description |
|----------|-------------|
| `data.load_json(path)` | Load JSON from pack assets or an on-disk library and return a Lua value. |
| `data.fast_pair_catalog_lookup(id)` | Look up a row in the bundled Fast Pair catalog. |

### bits library in Central

Central exposes a limited subset:

- `bits.band`
- `bits.bor`

Do not assume the full Observer `bits.*` API is present in Central.

---

## Peripheral note

Peripheral runtime APIs such as `gfx_set_background`, `gfx_render_text`, `ble_notify`, `ble_notify_raw`, `adv_set_data`, `adv_enable`, `adv_disable`, and dynamic GATT hooks are **currently not available in mobile Lua**. Those belong to ESP32 peripheral scripts and remain documented in [ESP32 Lua API]({{< relref "lua-esp32" >}}).