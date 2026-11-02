-- HomeKit identity from the GATT service list.
-- Pairing state lives in the advertisement, which iOS strips, so this script never sets paired.

local APPLE = "0000100080000026bb765291"
local ACCESSORY_INFO = "0000003e" .. APPLE
local PAIRING = "00000055" .. APPLE

-- First match wins. Security and locks come before sensors so a lock that also
-- exposes a sensor stays a lock. Infrastructure services (protocol, battery,
-- firmware) are omitted so a bare accessory stays "HomeKit".
local DEVICE_TYPES = {
  { "00000045", "Lock Mechanism", "SECURITY" },
  { "00000044", "Lock Management", "SECURITY" },
  { "00000041", "Garage Door Opener", "SECURITY" },
  { "00000081", "Door", "SECURITY" },
  { "0000008b", "Window", "SECURITY" },
  { "0000007e", "Security System", "SECURITY" },
  { "00000085", "Motion Sensor", "SENSOR_ENVIRONMENTAL" },
  { "00000080", "Contact Sensor", "SENSOR_ENVIRONMENTAL" },
  { "0000008a", "Temperature Sensor", "SENSOR_ENVIRONMENTAL" },
  { "00000082", "Humidity Sensor", "SENSOR_ENVIRONMENTAL" },
  { "00000084", "Light Sensor", "SENSOR_ENVIRONMENTAL" },
  { "00000083", "Leak Sensor", "SENSOR_ENVIRONMENTAL" },
  { "00000086", "Occupancy Sensor", "SENSOR_ENVIRONMENTAL" },
  { "00000087", "Smoke Sensor", "SENSOR_ENVIRONMENTAL" },
  { "0000008d", "Air Quality Sensor", "SENSOR_ENVIRONMENTAL" },
  { "00000097", "Carbon Dioxide Sensor", "SENSOR_ENVIRONMENTAL" },
  { "0000007f", "Carbon Monoxide Sensor", "SENSOR_ENVIRONMENTAL" },
  { "0000004a", "Thermostat", "SENSOR_ENVIRONMENTAL" },
  { "00000043", "Lightbulb", "SMART_HOME" },
  { "00000047", "Outlet", "SMART_HOME" },
  { "00000049", "Switch", "SMART_HOME" },
  { "00000040", "Fan", "SMART_HOME" },
  { "000000b7", "Fan v2", "SMART_HOME" },
  { "00000088", "Stateful Programmable Switch", "SMART_HOME" },
  { "00000089", "Stateless Programmable Switch", "SMART_HOME" },
  { "00000113", "Speaker", "AUDIO" },
  { "00000228", "Smart Speaker", "AUDIO" },
  { "00000112", "Microphone", "AUDIO" },
  { "000000d8", "Television", "TV_DISPLAY" },
  { "000000d9", "Input Source", "TV_DISPLAY" },
  { "00000125", "Target Control", "TV_DISPLAY" },
  { "00000122", "Target Control Management", "TV_DISPLAY" },
  { "0000020a", "Wi-Fi Router", "NETWORK" },
  { "0000020f", "Wi-Fi Satellite", "NETWORK" },
  { "000000bb", "Air Purifier", "GENERIC" },
  { "00000121", "Doorbell", "GENERIC" },
  { "000000d7", "Faucet", "GENERIC" },
  { "000000bc", "Heater-Cooler", "GENERIC" },
  { "000000bd", "Humidifier-Dehumidifier", "GENERIC" },
  { "000000cf", "Irrigation System", "GENERIC" },
  { "000000d0", "Valve", "GENERIC" },
  { "0000008c", "Window Covering", "GENERIC" },
  { "000000b9", "Slat", "GENERIC" },
  { "00000260", "Access Code", "GENERIC" },
  { "000000da", "Access Control", "GENERIC" },
  { "00000110", "Camera RTP Stream Management", "GENERIC" },
  { "0000021a", "Camera Operating Mode", "GENERIC" },
  { "00000204", "Camera Recording Management", "GENERIC" },
  { "00000127", "Audio Stream Management", "GENERIC" },
  { "0000026a", "Assistant", "GENERIC" },
  { "00000133", "Siri", "GENERIC" },
  { "00000253", "Siri Endpoint", "GENERIC" },
  { "00000266", "NFC Access", "GENERIC" },
  { "00000056", "Tunnel", "GENERIC" },
  { "0000005a", "Cloud Relay", "GENERIC" },
}

local function norm(uuid)
  return (tostring(uuid or "")):lower():gsub("-", "")
end

function parse(input)
  local present = {}
  local services = (input and input.service_uuids) or {}
  for i = 1, #services do
    present[norm(services[i])] = true
  end
  if not present[ACCESSORY_INFO] or not present[PAIRING] then
    return {}
  end

  local label = "HomeKit"
  local device_type = "GENERIC"
  for _, row in ipairs(DEVICE_TYPES) do
    if present[row[1] .. APPLE] then
      label = "HomeKit " .. row[2]
      device_type = row[3]
      break
    end
  end

  return {
    {
      id = "homekit",
      display_name = label,
      hint = "Pairing state unknown. Raw advertisement data is missing.",
      attributes = { protocol = "homekit" },
    },
  }, {
    device_type = device_type,
    custom_icon = "assets/homekit.svg",
    display_info = label,
  }
end
