-- bitchat mesh: advertisements are service-UUID-only (no Local Name / mfg / service data).
-- Mainnet (release): F47B5E2D-4A9E-4C5A-9B3F-8E1D2C3A4B5C
-- Testnet (DEBUG):   F47B5E2D-4A9E-4C5A-9B3F-8E1D2C3A4B5A
-- Identity (nickname, peer ID, keys) is exchanged post-connect via signed announce TLVs.

local ENTRY_ID = "bitchat"
local PROTOCOL = "bitchat"

local MAINNET_SVC = "f47b5e2d4a9e4c5a9b3f8e1d2c3a4b5c"
local TESTNET_SVC = "f47b5e2d4a9e4c5a9b3f8e1d2c3a4b5a"
local CHAR_UUID = "a1b2c3d4-e5f6-4a5b-8c9d-0e1f2a3b4c5d"

local function detect_network(input)
  if adv.has_uuid(input, MAINNET_SVC) then
    return "mainnet", "f47b5e2d-4a9e-4c5a-9b3f-8e1d2c3a4b5c"
  end
  if adv.has_uuid(input, TESTNET_SVC) then
    return "testnet", "f47b5e2d-4a9e-4c5a-9b3f-8e1d2c3a4b5a"
  end
  return nil, nil
end

function parse(input)
  local network, service_uuid = detect_network(input)
  if not network then
    return {}, {}
  end

  local display_info = network
  local name = (input.device_name or ""):match("^%s*(.-)%s*$") or ""
  -- Official builds omit Local Name; keep any unexpected name for diagnostics.
  if name ~= "" then
    display_info = network .. " · " .. name
  end

  return {
    {
      id = ENTRY_ID,
      display_name = "bitchat",
      attributes = {
        protocol = PROTOCOL,
        network = network,
        service_uuid = service_uuid,
        characteristic_uuid = CHAR_UUID,
        device_name = name,
      },
    },
  }, {
    device_type = "NEARBY",
    custom_icon = "assets/bitchat.svg",
    display_name = "bitchat",
    display_info = display_info,
  }
end
