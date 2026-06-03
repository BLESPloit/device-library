--- Log Fast Pair GATT writes; ble.json maps dynamic.on_write here for write-capable characteristics.
---
--- Firmware (ESP32 NimBLE simulator) may expose:
---   get_mtu() -> integer   — negotiated ATT MTU (default 23 if unknown); usable notify payload = get_mtu() - 3
---   set_preferred_mtu(n) -> ok[, err] — call early (e.g. on_startup); n in [23,517]; final MTU is min(central, peripheral prefs)
--- Wire these from native (e.g. ble_att_mtu / ble_att_set_preferred_mtu) when building the LUA BLE VM.

local function mtu_notify_max_octets()
  if type(get_mtu) == "function" then
    local m = tonumber(get_mtu())
    if m and m > 3 then
      return m - 3
    end
  end
  return 20
end

--- Send one logical RACE/indication payload as multiple ATT notifications when MTU is small.
local function ble_notify_fragmented(svc_uuid, chr_uuid, pkt_bytes)
  local maxo = mtu_notify_max_octets()
  local off = 1
  local n = #pkt_bytes
  local part = 0
  while off <= n do
    local last = math.min(off + maxo - 1, n)
    local chunk = string.sub(pkt_bytes, off, last)
    part = part + 1
    -- sends raw notification (bypass NimBLE) to have full control over encapsulation and dispatch time
    ble_notify_raw(svc_uuid, chr_uuid, bin_to_hex(chunk))
    off = last + 1
  end
  if part > 1 then
    print(string.format("ble_notify_fragmented: %d octets in %d parts (max %d octets/notify)", n, part, maxo))
  end
end

--- Synthetic RACE_RESPONSE (0x403) one flash page for lab / Sony WH-CH720N sim (race-toolkit ReadFlashPageResponse).
local function u16le(num)
    return string.char(num % 256, math.floor(num / 256) % 256)
end

function on_race_tx_write(input)
    if type(uuids) ~= "table" then
        print("on_race_tx_write: no uuids table")
        return input
    end
    local svc = uuids.SVC_RACE_SONY
    local rx = uuids.CHR_RACE_RX_SONY
    if not svc or not rx then
        print("on_race_tx_write: add SVC_RACE_SONY / CHR_RACE_RX_SONY to uuids.json")
        return input
    end
    if not input or #input < 6 then
        return input
    end
    if string.byte(input, 2) ~= 0x5A then
        return input
    end
    local cmd = string.byte(input, 5) + 256 * string.byte(input, 6)
    local RACE_CMD_PAGE_READ = 0x0403
    local RACE_CMD_BUILD_VER = 0x1E08
    --- Fixed NOTIFY blob for preset "Get build version" (055a0200081e) — lab replay.
    local BUILD_VERSION_RSP_HEX =
        "055b7300081e006d7432383232785f65766b00000000004d54323832325f53444b5f536f6e792d455236395f6d647231345f63343273705f310000000000000000000000000000323032342f30392f31382031383a35383a353520474d54202b30383a3030000000000000000000000000000000000000"
    if cmd == RACE_CMD_BUILD_VER then
        local pkt = hex_to_bin(BUILD_VERSION_RSP_HEX)
        if not pkt or #pkt == 0 then
            print("race sim: BUILD_VERSION_RSP_HEX decode failed")
            return input
        end
        print(
            string.format(
                "race sim: GET_BUILD_INFO-style cmd 0x%04x, notifying %d octets",
                RACE_CMD_BUILD_VER,
                #pkt
            )
        )
        ble_notify_fragmented(svc, rx, pkt)
        return input
    end
    if cmd ~= RACE_CMD_PAGE_READ then
        return input
    end
    local pre = string.char(0, 0, 0, 0, 0, 0, 0, 0)
    local page = string.rep(string.char(0xAA), 0x100)
    local pl = pre .. page
    local hlen = #pl + 2
    local pkt = string.char(0x05, 0x5B) .. u16le(hlen) .. u16le(0x0403) .. pl
    print(string.format("race sim: RACE_STORAGE_PAGE_READ ack, notify %d octets (fragmented if MTU small)", #pkt))
    ble_notify_fragmented(svc, rx, pkt)
    return input
end

function on_fast_pair_kbp_write(input)
  local hex = ""
  for i = 1, #input do
    hex = hex .. string.format("%02X", string.byte(input, i))
  end
  print(string.format("fast_pair KBP received: %d bytes  hex=%s", #input, hex))
  gfx_print_notification("Fast Pair KBP request")
  local rnd1 = random_bytes(16)
  local rnd2 = random_bytes(16)
  local h1 = bin_to_hex(rnd1)
  local h2 = bin_to_hex(rnd2)
  print(string.format("fast_pair KBP notify 1/2 (16 octets random): hex=%s", h1))
  print(string.format("fast_pair KBP notify 2/2 (16 octets random): hex=%s", h2))
  ble_notify_raw(uuids.SVC_FAST_PAIR, uuids.CHR_FAST_PAIR_KBP, h1)
  ble_notify_raw(uuids.SVC_FAST_PAIR, uuids.CHR_FAST_PAIR_KBP, h2)
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
    if type(set_preferred_mtu) == "function" then
        local ok, err = set_preferred_mtu(247)
        if ok then
            print("set_preferred_mtu(247): ok")
        else
            print("set_preferred_mtu:", err or "failed")
        end
    end
    gfx_show("icon")
end


