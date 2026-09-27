---
name: blesploit-device-library-entry
description: >-
  Creates a BLESPloit device library entry (manifest.json, observer/central/peripheral
  Lua, uuids, assets) and a .zip for in-app import. Use when adding a device,
  creating a library entry, writing a Lua adv decoder, or generating a manifest
  for a BLE device.
---

# BLESPloit device library entry

Default: a **user** entry the owner imports in the app as a zip. Do not assume KMP sources or `bundled/devices/` exist.

This skill may run standalone. A clone of [blesploit/device-library](https://github.com/blesploit/device-library) (or similar) is optional reference only.

## Discover docs and samples

If present in the workspace, read before writing (any matching path):

- `**/docs/device-manifest.schema.json`
- `**/docs/lua-mobile.md` (observer, central — phone)
- `**/docs/lua-esp32.md` (peripheral — ESP32 simulator)

If those files are missing, use the snippets in this skill. If sample entries exist, match the nearest one with the same roles — do not invent a `bundled/` tree.

---

## Workflow

1. Pick a **flat slug** for the entry folder: lowercase `[a-z0-9_-]`, max 64 (`my_lock`, `acme_sensor`). This is the runtime id after import.
2. Derive `scan_conditions` from advertisement captures; tighten with AND keys before adding Lua.
3. Write files under `<slug>/` (`manifest.json` with `manifest_version: 1`, `version: 1` on new entries).
4. Add role scripts only for requested capabilities. Omit unused roles entirely.
5. Validate JSON against the schema when available; match naming/style of a nearby sample if one exists.
6. Zip the folder and tell the user to **Import** that zip in the device library.

Do **not** put the entry under `products/`, `vendors/`, `protocols/`, or `generic/` unless the user asked to contribute to the official catalog. User entries live as a single folder; import uses the last path segment as the folder id, so a `products/` prefix is discarded.

Do **not** create `sample_scans/` (or any capture dump) inside the entry. Use scan input to derive filters/scripts only.

All manifest paths are relative to the entry folder.

### Official catalog (optional)

Only when contributing to the shipped library: `products/<id>/` (specific product), `vendors/<id>/` (vendor-wide), `protocols/<id>/` (cross-vendor), `generic/<id>/` (fallback). Folder id then includes the category (e.g. `products/oclean_toothbrush`).

---

## Inputs

| Input | Required | Use |
|-------|----------|-----|
| Device name, vendor, product model | **yes** | `name`, entry slug, observer `display_name` |
| Advertisement scan(s) — `adv.json`, raw hex, or app capture | **yes** (observer) | Derive `scan_conditions`, decode logic — do not copy into the entry |
| GATT service/characteristic UUID map | if central/peripheral | Vendor UUIDs only in `uuids.json`; `ble.json`, `match.services` |
| Protocol syntax (opcode layout, notify framing) | if central/peripheral | Central Lua, peripheral `dynamic` hooks |
| Observer match pattern | **yes** (observer) | `scan_conditions`; mirror in Lua guard if non-trivial |
| Known advertisement filters (company id, name, service data) | **yes** (observer) | Prefer manifest filters over Lua-only matching |
| Companion app links | optional | `apps.google`, `apps.apple`, `apps.direct[]` |
| Icon / graphics | optional (required for manifest-only observer) | `assets.icon`; `assets.graphics` for sim UI. No `icon_tint` by default |
| Provenance / testing notes | optional | `notes`, `author`, `source_url` |
| Roles needed | **yes** | `observer`, `central`, `peripheral` — only include those requested |
| Sample GATT log / `ble.json` capture | optional | Central scripts, peripheral GATT profile — do not store as `sample_scans/` |
| Chained-decode dependency | optional | `fingerprint_has_entry_id` when decoding after another observer |

Ask for missing **required** inputs before generating files.

---

## Output file set

Write everything under `<slug>/`:

| File | When | Purpose |
|------|------|---------|
| `manifest.json` | always | Entry registry: roles, scan conditions, script paths |
| `observer/adv_decode.lua` | observer with decode logic | `parse(input)` → fingerprint entries + UI overlay |
| `central/*.lua` | central role | GATT client scripts (`run()` for quick_action) |
| `central/menu.json` | `kind: full_menu` | Scripts tab menu tree |
| `peripheral/dynamic.lua` or `peripheral.lua` | peripheral role | ESP32 GATT/adv simulation hooks |
| `peripheral/adv.json` | peripheral role | Advertising profile(s) for simulator |
| `peripheral/interface.json` | peripheral with UI | LVGL layout ids for simulator screen |
| `uuids.json` | GATT scripts | Vendor/proprietary symbolic UUID map only |
| `vars.json` | peripheral or configurable central | Default state merged into Lua `vars` |
| `ble.json` | peripheral / GATT-heavy central | Full GATT profile (`profile` in manifest) |
| `assets/icon.svg` or `assets/icon.png` | scan UI branding | Scan-row icon; required if observer has no `entry`. PNG is not tinted; prefer square 128–256 px with alpha. |
| `assets/graphics.json` | peripheral UI | Icon/element definitions for simulator |
| `assets/*.svg`, `assets/*.png` | optional | Extra icons referenced by Lua or graphics |
| `<slug>.zip` | **always** (user entry) | Importable archive — see below |

Do not add files for roles not declared in the manifest. Do not add `sample_scans/`.

### Deliverable zip

Create `<slug>.zip` with a **single top-level folder** named `<slug>` (same as the entry directory). Official import looks for a directory that contains `manifest.json`. Loose files at the zip root make the proposed folder id the unpack directory name (`unpacked`) — always wrap.

```
my_lock/manifest.json
my_lock/observer/adv_decode.lua
my_lock/uuids.json
my_lock/assets/icon.svg
```

Zip the folder, not its contents. Example:

```bash
# Unix
zip -r my_lock.zip my_lock

# PowerShell (folder as root entry)
Compress-Archive -Path my_lock -DestinationPath my_lock.zip
```

Tell the user: Device library → **Import** → pick `<slug>.zip`. The app slug-normalizes the inner folder name (`[a-z0-9_-]`, max 64) and can rename on conflict.

### `uuids.json` — vendor UUIDs only

The app already names Bluetooth SIG 16-bit services/characteristics from the bundled SIG catalog (GAP, GATT, Battery `180f`/`2a19`, Device Information `180a`, CCCD `2902`, etc.).

- Put **only proprietary / vendor** UUIDs in the entry `uuids.json`.
- Do **not** re-declare standard SIG UUIDs already in that catalog.
- SIG-base keys (`0000XXXX-0000-1000-8000-00805f9b34fb` / short `2a19`) are excluded from the global UUID index anyway.
- Convention: `SVC_*` services, `CHR_*` characteristics. Entry shape: `type`, `uuid`, `name`, optional `structure` / `write_presets`.

### Icons — no default tint

Omit `assets.icon_tint` and observer `custom_icon_tint` unless the SVG is a **monochrome glyph** that must follow a brand color.

`icon_tint` is SVG-only (`#RRGGBB` / `#AARRGGBB`). The UI applies `SrcIn`, which replaces every non-transparent pixel with one color and **often breaks multi-color logos**. PNG is never tinted. Prefer an SVG (or PNG) that already looks correct with no tint. Do not copy `icon_tint` from `blesploit_lightbulb` into new entries.

---

## manifest.json schema (essentials)

```json
{
  "name": "Display name",
  "description": "Short summary",
  "author": "Author label",
  "manifest_version": 1,
  "version": 1,
  "notes": "Pairing, testing, provenance",
  "author_url": "https://…",
  "model_url": "https://…",
  "source_url": "https://…",
  "profile": "ble.json",
  "uuids": "uuids.json",
  "vars": "vars.json",
  "assets": { "icon": "assets/icon.svg", "graphics": "assets/graphics.json" },
  "apps": {
    "google": { "url": "https://…", "version_note": "…" },
    "apple": { "url": "https://…", "version_note": "…" },
    "direct": [{ "label": "…", "url": "https://…", "version_note": "…" }]
  },
  "roles": {
    "observer": { "entry": "observer/adv_decode.lua", "priority": 50, "scan_conditions": {} },
    "central": { "scripts": [] },
    "peripheral": { "advertisement": "peripheral/adv.json", "entry": "peripheral/dynamic.lua", "interface": "peripheral/interface.json" }
  }
}
```

`assets.icon` may be `.svg` or `.png`. For PNG, use a square 128–256 px image with alpha (preferably as small as possible); entries are synced wholesale to ESP32.

### Observer (`roles.observer`)

- `entry` — omit for **manifest-only** entries: `scan_conditions` + `assets.icon` apply icon without Lua (see `vendors/jabra`).
- `priority` — lower runs first (default 50).
- `scan_conditions` — pre-filter before Lua; see below.

### Central (`roles.central.scripts[]`)

| Field | Notes |
|-------|-------|
| `id`, `title`, `entry` | Required |
| `kind` | `full_menu` (needs `menu`) or `quick_action` |
| `priority` | Higher sorts first among matches; quick actions typically 55–60 |
| `match.fingerprint` | **Preferred** — key → allowed value(s); keys come from observer `attributes` |
| `match.services` | GATT UUIDs; all must be present |
| `match.fingerprint_or_services` | Default false (AND); true = match either branch |
| `match.require_discovered_services` | Default **true** when `services` non-empty |
| `auto_run_on_connect` | Default false |
| `vars` | Per-script string overlay into Lua `vars` |

**Central matching rule:** prefer `match.fingerprint` keyed on observer output (`protocol`, `device_type`, entry-specific attrs). Use `match.services` to confirm GATT identity. Combine both when product-specific confirmation is needed. Quick actions should read state via `fp_get()` / fingerprint attrs, not re-parse raw advertisements.

Example fingerprint-first quick action match:

```json
"match": {
  "fingerprint": { "protocol": ["happy_lighting"] },
  "services": ["ffd5"]
}
```

Example fingerprint-or-services (protocol entry):

```json
"match": {
  "fingerprint_or_services": true,
  "fingerprint": { "device_type": ["FAST_PAIR"] },
  "services": ["fe2c"],
  "require_discovered_services": true
}
```

### Peripheral (`roles.peripheral`)

- `advertisement`, `entry` — required for simulation.
- `interface` — optional LVGL layout JSON.
- Scripts run on **ESP32**, not mobile.

### Version fields

- `manifest_version` — format version (currently `1`).
- `version` — entry content revision; bump on edits; compared for ESP32 sync.

---

## Observer scan conditions

All keys live under `roles.observer.scan_conditions`. JSON keys use **snake_case** (not camelCase).

### Combining rules

- Top-level keys on one object → **AND**.
- `one_of: [...]` → at least one branch matches (**OR**); each branch is ANDed internally; may nest.
- Most fields accept a string or string array → **OR** across array values.

### Filter keys

| Key | Matches |
|-----|---------|
| `company_id` | 16-bit manufacturer company ID (`"0075"`, `"004C"`) |
| `manufacturer_data_prefix_hex` | Hex prefix of manufacturer specific data |
| `service_uuid_128` | 128-bit UUID in AD service list |
| `service_uuid_16` | 16-bit UUID in AD service list (`"fe2c"`, `["3081","3082"]`) |
| `service_data_uuid_128` | 128-bit UUID key in service data AD |
| `service_data_uuid_16` | 16-bit UUID key in service data AD |
| `device_name_contains` | Case-sensitive substring of advertised name |
| `device_name_regex` | Kotlin regex on name; use `^`/`$` for full match; `(?i)` for ignore-case |
| `fingerprint_has_entry_id` | Prior observer entry id (chained decode) |
| `fingerprint_entry_attributes` | Attribute map on that entry; requires `fingerprint_has_entry_id` |
| `ad_type` | AD type byte(s); pair with `ad_type_data_hex` |
| `ad_type_data_hex` | Hex prefix or regex on payload for `ad_type` |
| `has_gap_device_type_hints` | `true` if Appearance, CoD, or service UUID list present |

If both `device_name_contains` and `device_name_regex` are set, **both** must pass.

### Condition patterns from sample entries

```json
// Vendor icon only (AND)
{ "company_id": "0075", "device_name_contains": "HUAWEI" }

// Vendor family + decode (vendors/samsung @ 25): icon for all matches;
// Lua decodes VD 0x42/0x04 power state (on/standby/off) for TVs, soundbars, monitors
{ "one_of": [{ "company_id": "0075" }, { "service_data_uuid_16": "fd69" }] }

// Product name or service (oclean_toothbrush)
{ "one_of": [{ "device_name_contains": "Oclean" }, { "service_uuid_128": "a6ed0401d344460a8075b9e8ec90d71b" }] }

// Chained after apple_meta @ priority 20
{ "fingerprint_has_entry_id": "apple_meta", "fingerprint_entry_attributes": { "continuity_has_nearbyinfo": "true" } }
```

Tighten `scan_conditions` in the manifest; use Lua for payload parsing, not for broad filtering. Do not add a separate product entry for Samsung soundbar on/off — that lives in `vendors/samsung`.

---

## Priority guidelines

Lower observer `priority` runs **first**. Higher-priority observers see `input.fingerprint_entries` from earlier ones.

| Range | Meaning | Examples |
|-------|---------|----------|
| **10** | Generic meta / GAP inference | `generic/device_type_meta` |
| **20** | Broad vendor or protocol dispatcher | `vendors/apple/apple_dispatcher`, `vendors/jabra` |
| **25** | Vendor/protocol with decode (not just icon) | `vendors/samsung` (VD power state), `protocols/fast_pair` |
| **30** | Protocol sub-decode chained on prior entry | Apple continuity TLV decoders |
| **40** | Protocol instance after dispatcher | `protocols/ibeacon` (after Apple @ 20/30) |
| **45** | Vendor family with decode logic | `vendors/lime`, `vendors/tesla` |
| **50** | Default; name- or UUID-specific product | `pixel_buds_2a`, `happy_lighting`, `oclean_toothbrush` (catalog: under `products/`) |
| **100** | Late / catch-all | `vendors/microsoft_nearby` |

Central script `priority`: higher first; put `quick_action` at 55–60, `full_menu` at 50 or lower.

When adding a chained observer, set priority **after** the dependency (e.g. iBeacon 40 after `apple_meta` @ 20). User product entries usually use **50**.

---

## Lua conventions

### Observer (mobile only)

- Entry: `function parse(input)` → `entries` or `entries, ui`.
- Return `{}` or `{}, {}` when no match (even if `scan_conditions` passed — Lua can still reject).
- Entry shape: `{ id, display_name?, attributes = { key = "string_value", … } }`.
- UI overlay keys: `device_type`, `beacon_format`, `custom_icon` (`.svg` or `.png`), `custom_icon_tint` (SVG only — omit unless monochrome glyph), `display_name`, `display_info`.
- Globals: `vars`, `uuids`, `assets`, full `bits.*` / `hex.*`, `adv.*` / `uuid.compact` / `mac.*`, `hex_to_bin`, lowercase `bin_to_hex`.
- No `ble_*`, crypto, or menu APIs.
- Put stable match keys in `attributes` (`protocol`, product-specific fields) for central `match.fingerprint`.
- `manufacturer_data` keys are **4-digit uppercase hex** SIG company ids (`"0075"`, `"004C"`) — same as manifest `scan_conditions.company_id`. Values are lowercase hex payloads (company id bytes omitted).
- `first_company_id` uses the same hex string format when present.
- `first_service_uuid_16` is a 4-digit uppercase hex string (e.g. `"FE2C"`), or absent.

### Central (mobile only)

- Quick action: define `function run()`; optional `on_connected`, `on_notify`, `on_ble_read_result`.
- Full menu: menu JSON drives flow; use `push_menu`, `set_title`, `set_state`.
- Prefer `uuids.SYMBOL` over raw UUID strings.
- Use `ble_read` / `ble_write` / `ble_subscribe`, `start_notify_wait` + `finish_notify_wait` for request/notify protocols.
- Use `fp_get`, `fp_set`, `push_fingerprint` to enrich after GATT reads.
- `delay_ms(ms)` max 10000. `hex_to_bin` returns `""` on invalid input (no error).
- Same full `bits.*` / `hex.*` / `adv.*` / `uuid.*` / `mac.*` as Observer; `bin_to_hex` emits lowercase.
- Hex vs binary: `hex.*` / `bits.*` pack and unpack **fields** (stay in hex for `ble_write` / `ble_read` / `on_notify`). `bin_to_hex` / `hex_to_bin` convert a whole **blob** at crypto edges (and firmware `on_write` binary). Do not use `bits.tohex` as blob encode; do not `bin_to_hex(ble_read())`.
- Crypto arguments are binary strings. Helpers: `aes_cbc_encrypt` / `aes_cbc_decrypt` (16- or 32-byte key, unpadded — PKCS#5/PKCS#7 stays in Lua), `rsa_pkcs1_encrypt` / `rsa_pkcs1_decrypt` / `rsa_sha256_sign` / `rsa_sha256_verify` (raw modulus and exponent, not an X.509 key), `hmac_sha256`, `aes_cmac`, `xor_bytes`, `x25519_generate_keypair` / `x25519_compute_shared` (32-byte little-endian keys; clamping is inside the helper). `ecdh_*` stays secp256r1 and returns a 64-byte point; it does not interoperate with X25519. `rsa_pkcs1_decrypt` raises on bad PKCS#1 padding. `rsa_sha256_verify` returns a boolean and raises on a bad length. Full signatures are in `bundled/devices/docs/lua-mobile.md` and `lua-esp32.md`.

### Peripheral (ESP32 firmware; also Local Sim preview)

- Edited on mobile, **executed on ESP32** (and on-phone Local Sim) — use `ble_notify`, `adv_enable`/`adv_disable`, `gfx_*`, `vars_save`.
- Restricted stdlib on firmware: `_G`, `string`, `math`, `table` only.
- GATT `on_read` / `on_write` hooks referenced from `ble.json`.
- Persist sim state in `vars`; defaults from `vars.json`.
- Same `bits.*` / `hex.*` / `mac.*` as Observer/Central on firmware and Local Sim; **no** `adv` / `uuid`. `bin_to_hex` emits lowercase. `hex_to_bin` returns `""` on invalid input (no error). Peripheral `on_write(input)` is binary — `bin_to_hex(input)` before field unpack.
- Same crypto helpers as Central (`aes_cbc_*`, `rsa_pkcs1_encrypt` / `rsa_pkcs1_decrypt`, `rsa_sha256_sign` / `rsa_sha256_verify`, `hmac_sha256`, `aes_cmac`, `xor_bytes`, `x25519_generate_keypair` / `x25519_compute_shared`), on firmware and Local Sim. Arguments are binary strings. AES-CBC is unpadded (PKCS#5/PKCS#7 stays in Lua). RSA takes a raw modulus and exponent, not an X.509 key. X25519 keys are 32-byte little-endian strings and the helper clamps the scalar; `ecdh_*` stays secp256r1 with a 64-byte point. `rsa_pkcs1_decrypt` raises on bad padding so the script can `pcall` it. `rsa_sha256_verify` returns a boolean and raises on a bad length. A wrong X25519 length raises. Full signatures are in `bundled/devices/docs/lua-esp32.md` and `lua-mobile.md`.

Do not mix mobile and ESP32 APIs in one script file.

---

## Reference examples

### Minimal observer-only manifest (manifest-only icon)

Based on `vendors/jabra` — no Lua, icon overlay only, **no tint**:

```json
{
  "name": "Jabra",
  "description": "Just icon",
  "version": 1,
  "manifest_version": 1,
  "assets": { "icon": "assets/jabra.svg" },
  "roles": {
    "observer": {
      "priority": 20,
      "scan_conditions": { "device_name_contains": "Jabra" }
    }
  }
}
```

### Full three-role manifest (annotated)

Based on `blesploit_lightbulb`. Omit `icon_tint` on new entries (this example does not include it):

```json
{
  "name": "BLESPlo.it Light",
  "description": "Example lightbulb: on/off, RGB color, peripheral secret-challenge.",
  "author": "Slawomir Jasek",
  "manifest_version": 1,
  "version": 1,
  "profile": "ble.json",
  "uuids": "uuids.json",
  "vars": "vars.json",
  "assets": {
    "icon": "assets/blesploit_logo.svg",
    "graphics": "assets/graphics.json"
  },
  "roles": {
    "observer": {
      "entry": "observer/adv_decode.lua",
      "priority": 50,
      "scan_conditions": {
        "service_data_uuid_128": "a700cc65-e486-40ba-5d24-99601dc38fd7"
      }
    },
    "peripheral": {
      "advertisement": "peripheral/adv.json",
      "entry": "peripheral/dynamic_peripheral.lua",
      "interface": "peripheral/interface.json"
    },
    "central": {
      "scripts": [
        {
          "id": "main",
          "title": "BLESPlo.it Light",
          "kind": "full_menu",
          "entry": "central/dynamic_central.lua",
          "menu": "central/menu.json",
          "match": {
            "services": [
              "a701cc65-e486-40ba-5d24-99601dc38fd7",
              "a702cc65-e486-40ba-5d24-99601dc38fd7"
            ]
          }
        }
      ]
    }
  }
}
```

Observer decodes 4-byte service data (on/off + RGB); central matches on discovered GATT service UUIDs. `uuids.json` lists only the custom `a70x…` UUIDs — not SIG Battery/GAP. Add `"fingerprint": { "state": ["on"] }` (or a `protocol` attr) to central `match` when observer sets stable attrs worth reusing.

### Minimal observer Lua

```lua
local ENTRY_ID = "my_device"
local PROTOCOL = "my_protocol"

function parse(input)
  local name = input.device_name or ""
  -- manifest scan_conditions already filter; validate payload here
  local data = (input.manufacturer_data or {})["0075"]
  if not data then return {}, {} end

  return {
    { id = ENTRY_ID, display_name = "My Device",
      attributes = { protocol = PROTOCOL, device_name = name } }
  }, {
    device_type = "AUDIO",
    custom_icon = "assets/icon.svg",
    display_info = name,
  }
end
```

Do not set `custom_icon_tint` in the UI overlay unless the SVG is a monochrome glyph.

### Minimal central quick_action Lua

```lua
local SVC = uuids.MY_SERVICE
local CHR = uuids.MY_CHAR

function run()
  if not ble_connected() then return end
  if fp_get("protocol") ~= "my_protocol" then return end
  ble_subscribe(SVC, CHR)
  start_notify_wait(SVC, CHR, 100)
  ble_write(SVC, uuids.MY_WRITE, "0100")
  local hex = finish_notify_wait(SVC, CHR, 8000)
  if hex then push_fingerprint({ last_status = hex }) end
  gfx_print_text(hex and "OK" or "Timeout")
end
```

### Minimal peripheral Lua (ESP32)

```lua
local SVC = uuids.MY_SERVICE
local CHR_NOTIFY = uuids.MY_NOTIFY

function on_write(input)
  local hex = bin_to_hex(input)
  if hex:sub(1, 4) == "0303" then
    ble_notify(SVC, CHR_NOTIFY, string.format("0303000000%02X", vars.battery_percent or 50))
  end
  return input
end

function on_startup()
  gfx_show("icon")
end
```

---

## Checklist before finishing

- [ ] Flat slug folder (`[a-z0-9_-]`, max 64) — catalog `products/` / `vendors/` / … only if contributing to the official library
- [ ] `manifest_version: 1`, sensible `priority`, tight `scan_conditions`
- [ ] `<slug>.zip` wraps a single top-level `<slug>/` (not loose files at zip root)
- [ ] No `sample_scans/` (or other capture dumps) in the entry
- [ ] `uuids.json` has vendor/proprietary UUIDs only — no standard SIG UUIDs already in the catalog
- [ ] No `icon_tint` / `custom_icon_tint` unless the SVG is a monochrome glyph
- [ ] Observer `attributes.protocol` (or equivalent) set for central fingerprint matching
- [ ] Central quick actions prefer `match.fingerprint` over services-only when observer provides attrs
- [ ] `uuids.json` symbols used consistently in Lua; `ble.json` matches GATT capture
- [ ] Manifest-only observer has `assets.icon` and no `entry`
- [ ] No mobile APIs in peripheral scripts; no ESP32 APIs in observer/central scripts
