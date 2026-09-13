# Lua API mobile

On mobile, Lua does **not** run in the same environment as the ESP32 firmware Lua VM. There are **three mobile Lua contexts** documented here: **Central**, **Observer**, and **Local Sim (peripheral)**. Peripheral scripts can also be executed on the ESP32 firmware; see [ESP32 Lua API]({{< relref "lua-esp32" >}}).

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
| `assets` | Mobile-only table with fields such as `icon` (`.svg` or `.png`), `graphics`, and `icon_tint` (SVG only). Not available in ESP32 peripheral scripts. |

---

## Common mobile helpers

These helpers are installed in **Observer**, **Central**, and **Local Sim**. Firmware peripheral/central Lua installs the same `bits` / `hex` tables and lowercase `bin_to_hex` — see [ESP32 Lua API]({{< relref "lua-esp32" >}}).

### Hex payloads (lowercase emit)

`bin_to_hex`, `bits.tohex`, and `hex.*` packers emit **lowercase** hex on mobile, Local Sim, and ESP32. Decoders still accept mixed case. BLE write/notify hex is case-insensitive.

Company-id map keys and `first_company_id` stay **4-digit uppercase** identifiers (e.g. `"004C"`); those are not payload encode.

| Function | Behavior |
|----------|----------|
| `bin_to_hex(binary)` | Returns lowercase hex. |
| `hex_to_bin(hex)` | Strips whitespace; invalid input returns an empty string instead of raising a Lua error. Input must be handled as raw `byte[]` in Luaj so bytes `>= 0x80` remain one octet. |

### `hex` table

Pack integer arguments **wrap** to the field width (same mask policy as `bits.tohex` / `n % 256` for `u8`), then emit lowercase hex. Non-numbers raise via `checkint`.

| Function | Behavior |
|----------|----------|
| `hex.u8(n)` | Pack 8-bit; width 2. `hex.u8(0x123)` → `"23"`; `hex.u8(-1)` → `"ff"`. |
| `hex.le16(n)` / `hex.be16(n)` | Pack 16-bit little/big endian; width 4. `hex.le16(0x10000)` → `"0000"`. |
| `hex.le32(n)` / `hex.be32(n)` | Pack 32-bit little/big endian; width 8. |
| `hex.norm(s)` | Strip whitespace, lowercase; non-string → `""`. |
| `hex.byte(h, i)` | Alias of `bits.byte_at` (1-based byte index into the hex string as given). Packing one octet is `hex.u8`, not `hex.byte`. |
| `hex.len(h)` | Octet count after `norm`. |
| `hex.slice(h, from, n)` | `n` octets from 1-based `from` after `norm`; out of bounds → `""`. |
| `hex.to_ascii(h)` | **Lossy display helper:** keep bytes `0x20`–`0x7E`, drop NULs and other non-printables. Not a safe round-trip with `hex.from_ascii` for arbitrary BLE payloads. |
| `hex.from_ascii(s)` | Each octet → two lowercase hex digits (includes non-printables if present in the Lua string). |

### `bits` table

Bitwise ops use `checkint` (Lua error on non-number). Unpackers take `(hex, offset)` where **offset is a 1-based byte index** into the hex string as given (not `hex.norm`'d). Mixed case is OK; short, odd, or invalid slices return `0`.

- `band`, `bor`, `bxor`, `bnot`, `rshift`, `lshift`, `arshift`
- `byte_at(hex, index)`
- `tohex(n [, width])` — lowercase
- `fromhex(hex)`
- `le16` / `be16` / `le32` / `be32`

### `adv` / `uuid` (Observer + Central only)

These are **not** installed on Local Sim or ESP32 (peripheral Lua must stay firmware-portable). The global table `adv` does **not** replace `adv_set_data` / `adv_enable`.

Walk BLE GAP TLV `[len][type][value…]` after `hex.norm` (whitespace + lowercase only). Odd length or a non-hex nibble stops and keeps records already found (`"0x020106"` is not valid AD hex). `len == 0` stops. `len == 1` is `{ type = n, data = "" }`.

`adv.find` always returns a **table** (empty is truthy — use `#t > 0` or `[1]`).

| Function | Behavior |
|----------|----------|
| `adv.structures(hex)` | 1-based `{ {type=n, data=hex}, … }`. `data` is the AD value after type. |
| `adv.find(hex, type)` | **All** AD values of `type` (`checkint`, e.g. `0xFF`). Raw value — **includes** the 2-byte CID on `0xFF`. Non-number `type` raises. |
| `adv.manufacturer(hex [, cid])` | `0xFF` only; **always strips** the 2-byte LE CID. `cid` is a hex string (`"004C"`, `"4c"`, `"0x004c"`). Omitted or non-string → no filter. Unparsable string → empty list. |
| `adv.has_uuid(input, uuid)` | Not an AD walker. Compact-equals string cells/keys in `service_uuids`, `service_uuids_16`, `service_data` keys, and `first_service_uuid_16`. Non-string `uuid` → `false`. |
| `uuid.compact(s)` | Lowercase; strip whitespace, `-`, leading `0x`. Non-string → `""`. |

There is no `adv.local_name`. Use `hex.to_ascii(adv.find(h, 0x09)[1] or adv.find(h, 0x08)[1] or "")`.

### `mac` (Observer, Central, Local Sim)

Also on ESP32 firmware. Invalid / not exactly 6 octets → `""`. Colons, dashes, and spaces are ignored when collecting octets.

| Function | Behavior |
|----------|----------|
| `mac.format(hex12)` | `AA:BB:CC:DD:EE:FF` uppercase. |
| `mac.reverse_octets(hex12)` | 12 lowercase hex, octet-reversed. |
| `mac.from_reversed(hex12)` | `mac.format(mac.reverse_octets(hex12))`. |

### When to use `bin_to_hex` / `hex_to_bin` vs `hex.*` / `bits.*`

Central ATT values (`ble_write`, `ble_read`, `on_notify`) are **hex text**. Stay in hex unless you need a binary Lua string.

| Use | For |
|-----|-----|
| `hex.u8` / `hex.le16` / `hex.be16` / `hex.le32` / `hex.be32` | Pack a **field** (integer → 2/4/8 hex chars). Concatenate into a wire hex string for `ble_write`. |
| `bits.byte_at` / `bits.le16` / `bits.be16` / `bits.le32` / `bits.be32` | Unpack a **field** from hex (`ble_read`, `on_notify`, adv hex) at a 1-based byte offset. |
| `hex.norm` / `hex.slice` / `hex.len` | Navigate hex text without converting to binary. |
| `hex.from_ascii` | Plain ASCII → hex when `ble_write` needs text (`hex.from_ascii("1")` → `"31"`). |
| `bin_to_hex` / `hex_to_bin` | Whole **blob**: binary Lua string ↔ hex text. Use at crypto edges (`aes_*`, `sha256`, `random_bytes`) and firmware peripheral `on_write(input)` (binary). Invalid hex → `""` (soft-fail). |

Do **not**:

- Use `bits.tohex` to encode a blob — it formats one integer, not a byte string.
- Convert to binary just to read or pack fields — stay in hex.
- Pass `hex_to_bin(...)` to `ble_write` — write wants hex.
- Wrap `ble_read` / `on_notify` with `bin_to_hex` — they are already hex.

```lua
-- fields: stay in hex
local n = bits.le16(hex, 1)
ble_write(SVC, CHR, hex.le16(n) .. hex.u8(0x03))

-- blob: binary only at the crypto edge
local digest_hex = bin_to_hex(sha256(hex_to_bin(payload_hex)))
ble_write(SVC, CHR, digest_hex)
```

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
| `bits` | Shared bits library (same as Central / Local Sim). |
| `hex` | Shared hex packers and string helpers (same as Central / Local Sim). |
| `adv` / `uuid` | AD walk and UUID helpers (Observer + Central only). |
| `mac` | MAC format / reverse (also Local Sim + ESP32). |
| `hex_to_bin` | Same mobile hex decoder behavior as above. |
| `bin_to_hex` | Same mobile hex encoder behavior as above (lowercase). |
| `vars` | Vars table. |
| `uuids` | UUID map. |
| `assets` | Mobile assets table. |

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
| `first_service_uuid_16` | First 16-bit service UUID as 4-digit uppercase hex string (e.g. `"FE2C"`), or absent. |
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
- `custom_icon` — pack-relative `.svg` or `.png` (e.g. `assets/icon.svg`). PNG is shown with intrinsic colors.
- `custom_icon_tint` — hex tint for SVG only (`#RRGGBB` / `#AARRGGBB`); ignored for PNG.
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
| `ble_read(svc, chr)` | Returns lowercase hex string or `nil` (same on firmware); also triggers `on_ble_read_result(svc, chr, hex, err)`. Empty characteristic → `""`. |
| `ble_write(svc, chr, hex [, no_resp])` → ok [, err] | Strict non-empty even hex (`0-9a-fA-F`); no binary / UTF-8 fallback. Optional `no_resp` is Lua-truthy Write Command. `ble_write(svc, chr, ble_read(...))` works for any **non-empty** value; empty `ble_read` → `""` is not writable. |
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

### bits / hex / adv / mac in Central

Central installs the same `bits` / `hex` / `adv` / `uuid` / `mac` tables as Observer (see Common mobile helpers).

---

## Peripheral note (Local Sim)

Peripheral runtime APIs (`gfx_*`, `ble_notify`, `ble_notify_raw`, `adv_set_data`, `adv_enable`, `adv_disable`, `ble_connected`, `ble_disconnect`, `get_mtu`, `set_preferred_mtu`, `delay`, crypto helpers, and `ble.json` dynamic hooks) run on this phone when you start **Local → Sim**.

Local Sim and ESP32 firmware both install the shared `bits` / `hex` / `mac` tables and lowercase `bin_to_hex`. They do **not** install `adv` / `uuid`. Peripheral scripts may use `bits` / `hex` / `mac` on Remote Sim and Local Sim.

On-phone simulation cannot match ESP32 Remote Sim or real hardware in every respect:

- The OS only accepts structured advertising fields (service UUIDs, and on Android also service data / manufacturer data). Raw `adv_data_hex` PDUs are reconstructed, not replayed.
- iOS advertising is limited to local name + service UUIDs. Service data and manufacturer data are dropped; the Sim canvas shows an OS-limit banner.
- `ble_disconnect` can cancel the central on Android only. iOS has no public API to kick a connected central.
- `get_adv_bd_addr` is often unavailable (the OS hides the adapter address).
- `gpio_set` / `gpio_get` are not applicable on a phone, Local Sim returns `ok [, err]` / `nil [, err]`, not a Lua error.
- Simulation runs only while the app is in the foreground. Background advertising is not enabled in this version.

The same peripheral Lua also runs on ESP32 Remote Sim; prefer that path when you need full advertising fidelity. Details remain in [ESP32 Lua API]({{< relref "lua-esp32" >}}).