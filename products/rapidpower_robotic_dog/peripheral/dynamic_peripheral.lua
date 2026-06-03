-- Maps 7-byte command frames on CHR_COMMAND to a short status line (see uuids.json).

local CMD_LABELS = {
  ["F02A0001D5FFFE"] = "Move forward",
  ["F02A0004D5FFFB"] = "Turn left",
  ["F02A0007D5FFF8"] = "Turn right",
  ["F02A000AD5FFF5"] = "Stop",
  ["F02A000DD5FFF2"] = "Swimming",
  ["F02A0010D5FFEF"] = "Sit down",
  ["F02A0013D5FFEC"] = "Greetings",
  ["F02A0016D5FFE9"] = "Get down",
  ["F02A0019D5FFE6"] = "Act cute",
  ["F02A001CD5FFE3"] = "Handshake",
  ["F02A001FD5FFE0"] = "Attack",
  ["F02A0022D5FFDD"] = "Surrender",
  ["F02A0025D5FFDA"] = "Urinate",
  ["F02A0028D5FFD7"] = "Stand",
  ["F02A002BD5FFD4"] = "Patrol",
  ["F02A002ED5FFD1"] = "Kung fu",
  ["F02A0031D5FFCE"] = "Push-up",
  ["F0120001EDFFFE"] = "Dance 1",
  ["F0120002EDFFFD"] = "Dance 2",
  ["F0120003EDFFFC"] = "Dance 3",
  ["F0120004EDFFFB"] = "Dance 4",
  ["F0180001E7FFFE"] = "Story 1",
  ["F0180002E7FFFD"] = "Story 2",
  ["F0180003E7FFFC"] = "Story 3",
  ["F0180004E7FFFB"] = "Story 4",
  ["F01E0001E1FFFE"] = "Music 1",
  ["F01E0002E1FFFD"] = "Music 2",
  ["F01E0003E1FFFC"] = "Music 3",
  ["F01E0004E1FFFB"] = "Music 4",
  ["F0240001DBFFFE"] = "Sleep 1",
  ["F0240002DBFFFD"] = "Sleep 2",
  ["F0240003DBFFFC"] = "Sleep 3",
  ["F0240004DBFFFB"] = "Sleep 4",
}

local function payload_to_hex_upper(input)
  local hex = ""
  for i = 1, #input do
    hex = hex .. string.format("%02X", string.byte(input, i))
  end
  return hex
end

--- First payload byte: 0xF0 = vendor app path, 0xE1 = remote control.
local function source_channel(b1)
  if not b1 then
    return "?"
  end
  if b1 == 0xF0 then
    return "app"
  end
  if b1 == 0xE1 then
    return "remote"
  end
  return string.format("0x%02X", b1)
end

local function command_label_for_hex(hex)
  local label = CMD_LABELS[hex]
  if label then
    return label
  end
  if #hex == 14 and hex:sub(1, 2) == "E1" then
    return CMD_LABELS["F0" .. hex:sub(3)]
  end
  return nil
end

function on_write_command(input)
  local hex = payload_to_hex_upper(input)
  local b1 = #input >= 1 and string.byte(input, 1) or nil
  local src = source_channel(b1)
  local label = command_label_for_hex(hex)
  local body = label and (label .. " (" .. hex .. ")") or hex
  local line = src .. ": " .. body
  print("rapidpower cmd: " .. line)
  gfx_update_text("status", line)
  return input
end

function on_startup()
  gfx_show("dog")
  gfx_show("status")
end
