---
name: blesploit-device-library-entry
description: >-
  Creates BLESPloit device library entry (manifest.json, observer/central/peripheral Lua, uuids, assets). 
  Use when adding a device, creating a library entry, writing a Lua adv decoder, or generating
  a manifest for a BLE device.
---

# BLESPloit device library entry

> **Best results with the `device-library` (https://github.com/blesploit/device-library) repo open in the workspace.**  
> Reference entry: `products/blesploit_lightbulb/` (all three roles, full asset layout).  
> Attach for full detail: `docs/device-manifest.schema.json`, `docs/lua-mobile.md`,  
> `docs/lua-esp32.md` (peripheral runs on ESP32).  
> Full schema: https://blesplo.it/docs/device-library


## Workflow

1. Classify entry: `products/<id>/` (specific product), `vendors/<id>/` (vendor-wide), `protocols/<id>/` (cross-vendor), `generic/<id>/` (fallback).
2. Derive `scan_conditions` from advertisement captures; tighten with AND keys before adding Lua.
3. Write `manifest.json` (`manifest_version: 1`, `version: 1` on new entries).
4. Add role scripts only for requested capabilities. Omit unused roles entirely.
5. Store reference captures in `sample_scans/` (not loaded at runtime).
6. Validate JSON against schema; match naming/style of nearest existing entry.

Entry folder id (e.g. `products/blesploit_lightbulb`) is the runtime device id. All manifest paths are relative to that folder.

---

## Inputs

| Input | Required for | Use |
|-------|-------------|-----|
| Device name, vendor, product model | all roles | `name`, entry folder id, observer `display_name` |
| Roles needed | all roles | determines which files to generate; only include declared roles |
| Advertisement scan(s) — `adv.json`, raw hex, or app capture | observer | derive `scan_conditions`, decode logic |
| Known advertisement filters (company id, name, service data) | observer | prefer manifest filters over Lua-only matching |
| Observer match pattern | observer | `scan_conditions`; mirror in Lua guard if non-trivial |
| GATT service/characteristic UUID map | central, peripheral | `uuids.json`, `ble.json`, `match.services` |
| Protocol syntax (opcode layout, notify framing) | central, peripheral | central Lua, peripheral `dynamic` hooks |
| Sample GATT log / `ble.json` capture | peripheral (required), central (recommended) | peripheral GATT profile, central scripts |
| Icon / graphics | observer without `entry` (required), any (recommended) | `assets.icon`; `assets.graphics` for sim UI |
| Chained-decode dependency | observer (if chaining) | `fingerprint_has_entry_id` when decoding after another observer |
| Companion app links | optional | `apps.google`, `apps.apple`, `apps.direct[]` |
| Provenance / testing notes | optional | `notes`, `author`, `source_url` |

Ask for missing required inputs **for the declared roles** before generating files.

---

## Output file set

| File | When | Purpose |
|------|------|---------|
| `manifest.json` | always | Entry registry: roles, scan conditions, script paths |
| `observer/adv_decode.lua` | observer with decode logic | `parse(input)` → fingerprint entries + UI overlay |
| `central/*.lua` | central role | GATT client scripts (`run()` for quick_action) |
| `central/menu.json` | `kind: full_menu` | Scripts tab menu tree |
| `peripheral/dynamic.lua` or `peripheral.lua` | peripheral role | ESP32 GATT/adv simulation hooks |
| `peripheral/adv.json` | peripheral role | Advertising profile(s) for simulator |
| `peripheral/interface.json` | peripheral with UI | LVGL layout ids for simulator screen |
| `uuids.json` | GATT scripts | Symbolic name → service/characteristic UUID map |
| `vars.json` | peripheral or configurable central | Default state merged into Lua `vars` |
| `ble.json` | peripheral / GATT-heavy central | Full GATT profile (`profile` in manifest) |
| `assets/icon.svg` | scan UI branding | Scan-row icon; required if observer has no `entry` |
| `assets/graphics.json` | peripheral UI | Icon/element definitions for simulator |
| `assets/*.svg` | optional | Extra icons referenced by Lua or graphics |
| `sample_scans/**` | optional | Reference `adv.json`, `ble.json`, `meta.json` captures |

Do not add files for roles not declared in the manifest.

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
  "assets": { "icon": "assets/icon.svg", "graphics": "assets/graphics.json", "icon_tint": "#RRGGBB" },
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

**`assets.icon_tint`** — omit unless the icon is a monochrome/silhouette SVG. Applying a tint to a logo or multi-color SVG repaints it as a flat color square.

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
{ "company_id": "0075", "device_name_contains": "Samsung" }

// Specific product (AND all three)
{ "device_name_contains": "Samsung Soundbar Q990B", "company_id": "0075", "manufacturer_data_prefix_hex": "420483" }

// Alternatives (OR)
{ "one_of": [{ "company_id": "0075" }, { "service_data_uuid_16": "fd69" }] }

// Chained after apple_meta @ priority 20
{ "fingerprint_has_entry_id": "apple_meta", "fingerprint_entry_attributes": { "continuity_has_nearbyinfo": "true" } }
```

Tighten `scan_conditions` in the manifest; use Lua for payload parsing, not for broad filtering.

---

## Priority guidelines

Lower observer `priority` runs **first**. Higher-priority observers see `input.fingerprint_entries` from earlier ones.

| Range | Meaning | Examples |
|-------|---------|----------|
| **10** | Generic meta / GAP inference | `generic/device_type_meta` |
| **20** | Broad vendor or protocol dispatcher | `vendors/apple/apple_dispatcher`, `vendors/samsung`, `protocols/fast_pair` (25) |
| **30** | Protocol sub-decode chained on prior entry | Apple continuity TLV decoders |
| **40** | Protocol instance after dispatcher | `protocols/ibeacon` (after Apple @ 20/30) |
| **45** | Vendor family with decode logic | `vendors/lime`, `vendors/tesla` |
| **50** | Default; name- or UUID-specific product | `products/pixel_buds_2a`, `products/happy_lighting` |
| **100** | Late / catch-all | `vendors/microsoft_nearby` |

Central script `priority`: higher first; put `quick_action` at 55–60, `full_menu` at 50 or lower.

When adding a chained observer, set priority **after** the dependency (e.g. iBeacon 40 after `apple_meta` @ 20).

---

## Lua conventions

### Observer (mobile only)

- Entry: `function parse(input)` → `entries` or `entries, ui`.
- Return `{}` or `{}, {}` when no match (even if `scan_conditions` passed — Lua can still reject).
- Entry shape: `{ id, display_name?, attributes = { key = "string_value", … } }`.
- UI overlay keys: `device_type`, `beacon_format`, `custom_icon`, `custom_icon_tint`, `display_name`, `display_info`.
- Globals: `vars`, `uuids`, `assets`, `bits.*`, `hex_to_bin`, `bin_to_hex`.
- No `ble_*`, crypto, or menu APIs.
- Put stable match keys in `attributes` (`protocol`, product-specific fields) for central `match.fingerprint`.
- `manufacturer_data` keys are **4-digit uppercase hex** SIG company ids (`"0075"`, `"004C"`) — same as manifest `scan_conditions.company_id`. Values are lowercase hex payloads (company id bytes omitted).
- `first_company_id` uses the same hex string format when present.

### Central (mobile only)

- Quick action: define `function run()`; optional `on_connected`, `on_notify`, `on_ble_read_result`.
- Full menu: menu JSON drives flow; use `push_menu`, `set_title`, `set_state`.
- Prefer `uuids.SYMBOL` over raw UUID strings.
- Use `ble_read` / `ble_write` / `ble_subscribe`, `start_notify_wait` + `finish_notify_wait` for request/notify protocols.
- Use `fp_get`, `fp_set`, `push_fingerprint` to enrich after GATT reads.
- `delay_ms(ms)` max 10000. `hex_to_bin` returns `""` on invalid input (no error).

### Peripheral (ESP32 only)

- Edited on mobile, **executed on ESP32** — use `ble_notify`, `adv_enable`/`adv_disable`, `gfx_*`, `vars_save`.
- Restricted stdlib: `_G`, `string`, `math`, `table` only.
- GATT `on_read` / `on_write` hooks referenced from `ble.json`.
- Persist sim state in `vars`; defaults from `vars.json`.

Do not mix mobile and ESP32 APIs in one script file.

---

## Reference examples

### Minimal observer-only manifest (manifest-only icon)

Based on `vendors/jabra` — no Lua, icon overlay only:

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

Based on `products/blesploit_lightbulb`:

```json
{
  "name": "BLESPlo.it Light",
  "description": "Example lightbulb: on/off, RGB color, peripheral secret-challenge.",
  "author": "Slawomir Jasek",
  "manifest_version": 1,
  "version": 1,
  "profile": "ble.json",
  "uuids": "uuids.json",
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

Improve central scripts by adding `"fingerprint": { "protocol": ["blesploit_lightbulb"] }` once observer sets that attribute.

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

- [ ] Entry path matches category (`products/`, `vendors/`, `protocols/`, `generic/`)
- [ ] `manifest_version: 1`, sensible `priority`, tight `scan_conditions`
- [ ] Observer `attributes.protocol` (or equivalent) set for central fingerprint matching
- [ ] Central quick actions prefer `match.fingerprint` over services-only when observer provides attrs
- [ ] `uuids.json` symbols used consistently in Lua; `ble.json` matches GATT capture
- [ ] Manifest-only observer has `assets.icon` and no `entry`
- [ ] No mobile APIs in peripheral scripts; no ESP32 APIs in observer/central scripts
