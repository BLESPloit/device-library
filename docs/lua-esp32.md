# Lua API ESP32

This page documents **ESP32 peripheral simulation** and the overlapping APIs used by **Local Sim** on the phone. Mobile Central and Observer Lua are documented separately in [Mobile Lua API]({{< relref "lua-mobile" >}}).

Peripheral Lua in device packs may run on the ESP32 simulator / firmware **or** on the phone via Local → Sim. Functions such as `ble_notify`, `gfx_*`, and `adv_*` described here apply to both, with these Local Sim gaps:

- The phone cannot emit exact `adv_data_hex` PDUs; only OS-supported AD types are advertised. iOS is limited to local name + service UUIDs.
- `ble_disconnect` works on Android (`cancelConnection`); iOS cannot kick a central.
- `get_adv_bd_addr` is often nil when the OS hides the address.
- `gpio_set` / `gpio_get` are firmware/board pins only — Local Sim returns `ok [, err]` / `nil [, err]`, not a Lua error.
- Local Sim runs only in the foreground (no iOS `bluetooth-peripheral` background mode, no Android foreground service in this version).
- Firmware and Local Sim both install the shared `bits` / `hex` / `mac` tables and lowercase `bin_to_hex` (same API as [Mobile Lua]({{< relref "lua-mobile" >}})). They do **not** install `adv` / `uuid`.

---

## Runtime and standard library

ESP32 peripheral scripts run with a restricted standard library, in order to save the memory footprint:

- `_G`
- `string`
- `math`
- `table`

Do not assume Luaj JSE libraries such as `io` or `os` are available here.

Scripts are loaded by `lua_init_persistent_minimal()` in the firmware Lua VM. 

---

## Globals

| Global | Source |
|--------|--------|
| `vars` | Table loaded from device `vars.json` (strings, numbers, bools). |
| `uuids` | String map of symbolic names to UUID strings from the device UUID map JSON via `lua_uuids_inject`. |

---

## Common helpers

These helpers are available in the ESP32 peripheral Lua VM.

| Function | Description |
|----------|-------------|
| `delay(seconds, func_name)` | Schedule global function `func_name` with zero arguments. |
| `bin_to_hex(binary)` → string | Convert binary data to lowercase hex. Non-string → `""`. |
| `hex_to_bin(hex)` → binary | Strip whitespace; mixed case OK; odd / invalid / non-string → `""` (no Lua error). |
| `get_time()` → integer | Returns `time(NULL)`. This is only useful if the device has valid wall-clock time set. |
| `vars_save()` → integer | Serializes the `vars` back to json |

`bin_to_hex`, `bits.tohex`, and `hex.*` packers emit **lowercase** hex. Decoders still accept mixed case. BLE write/notify hex is case-insensitive.

### `hex` table

Pack integer arguments **wrap** to the field width, then emit lowercase hex. Non-numbers raise.

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

Bitwise ops error on non-number. Unpackers take `(hex, offset)` where **offset is a 1-based byte index** into the hex string as given (not `hex.norm`'d). Mixed case is OK; short, odd, or invalid slices return `0`.

- `band`, `bor`, `bxor`, `bnot`, `rshift`, `lshift`, `arshift`
- `byte_at(hex, index)`
- `tohex(n [, width])` — lowercase
- `fromhex(hex)`
- `le16` / `be16` / `le32` / `be32`

### `mac` table

Invalid / not exactly 6 octets → `""`. Colons, dashes, and spaces are ignored when collecting octets.

| Function | Behavior |
|----------|----------|
| `mac.format(hex12)` | `AA:BB:CC:DD:EE:FF` uppercase. |
| `mac.reverse_octets(hex12)` | 12 lowercase hex, octet-reversed. |
| `mac.from_reversed(hex12)` | `mac.format(mac.reverse_octets(hex12))`. |

Firmware and Local Sim have **no** `adv` / `uuid` tables.

### When to use `bin_to_hex` / `hex_to_bin` vs `hex.*` / `bits.*`

Central ATT values (`ble_write`, `ble_read`, `on_notify`) are **hex text**. Peripheral `on_write(input)` and crypto helpers are **binary**. Stay in hex unless you need a binary Lua string.

| Use | For |
|-----|-----|
| `hex.u8` / `hex.le16` / `hex.be16` / `hex.le32` / `hex.be32` | Pack a **field** (integer → 2/4/8 hex chars). Concatenate into a wire hex string for `ble_write` / `ble_notify`. |
| `bits.byte_at` / `bits.le16` / `bits.be16` / `bits.le32` / `bits.be32` | Unpack a **field** from hex (`ble_read`, `on_notify`, or `bin_to_hex(on_write input)`) at a 1-based byte offset. |
| `hex.norm` / `hex.slice` / `hex.len` | Navigate hex text without converting to binary. |
| `hex.from_ascii` | Plain ASCII → hex (`hex.from_ascii("1")` → `"31"`). |
| `bin_to_hex` / `hex_to_bin` | Whole **blob**: binary Lua string ↔ hex text. Use at crypto edges and `on_write(input)`. Invalid hex → `""` (soft-fail). |

Do **not** use `bits.tohex` to encode a blob (one integer, not a byte string). Do not pass `hex_to_bin(...)` to `ble_write` / `ble_notify`. Do not wrap `ble_read` / `on_notify` with `bin_to_hex`.

```lua
-- fields: stay in hex
local n = bits.le16(hex, 1)
ble_write(SVC, CHR, hex.le16(n) .. hex.u8(0x03))

-- blob: binary only at the crypto / on_write edge
function on_write(input)
  local hex = bin_to_hex(input)
  local digest_hex = bin_to_hex(sha256(input))
  ble_notify(SVC, CHR, digest_hex)
  return input
end
```

### Crypto

| Function | Description |
|----------|-------------|
| `aes_ecb_encrypt(key16, block16)` → binary | AES-128-ECB encrypt with exactly 16-byte key and block. |
| `aes_ecb_decrypt(key16, block16)` → binary | AES-128-ECB decrypt. |
| `sha256(data)` → binary | Full 32-byte SHA-256 digest. |
| `sha256_first_16(data)` → binary | First 16 bytes of SHA-256.  |
| `ecdh_generate_keypair()` → `priv32, pub64` | Generates a secp256r1 keypair; `pub64` is `X || Y` without the `0x04` prefix.  |
| `ecdh_compute_shared(priv32, peer_pub64)` → `shared32` | Computes a 32-byte ECDH shared secret.  |
| `x25519_generate_keypair()` → `priv32, pub32` | X25519 keypair. Both values are 32-byte little-endian strings. The private scalar is clamped. |
| `x25519_compute_shared(private_key, peer_public_key)` → `shared32` | X25519 shared secret, 32 bytes. Both inputs are 32 bytes. A wrong length raises. |
| `random_bytes(n)` → binary | Returns hardware RNG output for `n` in the range 1..1024. |
| `aes_cbc_encrypt(key, iv, data)` → binary | AES-CBC encrypt. Key is 16 or 32 bytes, IV is 16 bytes, data is a non-zero multiple of 16 and at most 4096. No padding. |
| `aes_cbc_decrypt(key, iv, data)` → binary | AES-CBC decrypt with the same length rules. No padding. |
| `rsa_pkcs1_encrypt(modulus, public_exponent, plaintext)` → binary | PKCS#1 v1.5 type 2 encrypt. Modulus is 64, 128, or 256 raw bytes. Public exponent is big-endian (often 3 bytes `010001`). Plaintext length is 1..modulus−11. Output is one modulus-sized block. |
| `rsa_pkcs1_decrypt(modulus, public_exponent, private_exponent, ciphertext)` → binary | PKCS#1 v1.5 decrypt. Private exponent and ciphertext lengths equal the modulus. Returns the unpadded plaintext. A bad length or bad padding raises. |
| `rsa_sha256_sign(modulus, public_exponent, private_exponent, message)` → binary | SHA-256 over the raw message, then RSASSA-PKCS1-v1_5. Message length is 1..4096. Output length equals the modulus. |
| `rsa_sha256_verify(modulus, public_exponent, message, signature)` → bool | Same encoding. A wrong signature is `false`. A wrong length raises. |
| `hmac_sha256(key, data)` → binary | HMAC-SHA256. Key is 1..1024 bytes. Output is 32 bytes. |
| `aes_cmac(key, data)` → binary | AES-128-CMAC. Key is exactly 16 bytes. Output is 16 bytes. An empty message is valid. |
| `xor_bytes(a, b)` → binary | Byte-wise XOR of two equal-length strings, 1..4096 bytes. |

AES-CBC does not add or remove padding. PKCS#5/PKCS#7 stays in the script, as does a leading `0x00` on a longer GATT write. RSA helpers take a raw modulus and exponent, not an X.509 key. Store those raw values (for example in `vars.json`). `ecdh_*` is secp256r1 and returns a 64-byte point. X25519 is a separate helper; those keys do not interoperate.

---

## Graphics

These functions bind to the LVGL / WebSocket simulation UI.

| Function | Description |
|----------|-------------|
| `gfx_set_background(color_uint)` | Set background color, typically `0xRRGGBB`.  |
| `gfx_show(id)` | Render an existing element by id.  |
| `gfx_set_position(id [, align_str] [, x, y [, w [, h]]])` | Set anchor and offsets; `align_str` defaults to `center`.  |
| `gfx_set_color(id, color_uint)` | Recolor an existing element.  |
| `gfx_remove(id)` | Remove an element.  |
| `gfx_render_text(id [, align_str] [, x, y] [, color])` | Create or update layout for a text id.  |
| `gfx_update_text(id, text [, color])` | Change the text payload.  |
| `gfx_print_notification(text [, align] [, x, y] [, color] [, size] [, duration_ms])` | Show a toast-style notification.  |

Supported align strings: `top_left`, `top_center`, `top_right`, `middle_left`, `middle_right`, `bottom_left`, `bottom_center`, `bottom_right`; any other value falls back to `center`. 

---

## BLE peripheral

These functions are available in the ESP32 peripheral simulation runtime and in Local Sim on the phone (see OS gaps above).

| Function | Description |
|----------|-------------|
| `ble_notify(svc_uuid, chr_uuid, hex_str)` → `ok [, err]` | Decode `hex_str`, update the characteristic backing value, and notify subscribers.  |
| `ble_notify_raw(svc_uuid, chr_uuid, hex_str)` → `ok [, err]` | Send a notify PDU without updating the backing store; requires connectivity and does not honor CCCD.  |
| `adv_set_data(profile_id, adv_hex [, scan_rsp_hex])` → bool | Replace raw advertising data, with optional scan response, for the advertising profile id.  |
| `get_adv_bd_addr(profile_id)` → `addr | nil [, err]` | Return the resolved TX address string when available.  |
| `adv_enable(profile_id)` → `ok [, err]` | Start an advertising instance.  |
| `adv_disable(profile_id)` → `ok [, err]` | Stop an advertising instance.  |
| `get_mtu()` → int | Return the negotiated ATT MTU, defaulting to 23 if unknown.  |
| `set_preferred_mtu(mtu)` → `ok [, err]` | Request MTU in the allowed range 23..517.  |

---

## Dynamic GATT hooks

Peripheral GATT `dynamic` hooks in JSON, such as `on_read` and `on_write`, can call into Lua. See `ble_sim_gatt.c` for relay-prefixed forms. 

---

## Notes

- All Lua runs on a dedicated task. BLE notify posts `on_notify` asynchronously via a queue. 
- Many functions use multiple return values such as `ok, err` or `nil, err`, and some failures may use `luaL_error`. 
- Prefer entries in `uuids` for readability; UUID strings are normalized internally for lookup. 