-- Writes vendor 7-byte frames to CHR_COMMAND (hex, no spaces).

function on_main_enter()
  print("rapidpower robotic dog central")
end

function send_cmd(hex)
  if not hex or hex == "" then
    return
  end
  hex = hex:upper()
  local ok = ble_write(uuids.SVC_RAPIDPOWER, uuids.CHR_COMMAND, hex)
  if ok then
    set_title("CMD")
    set_state("cmd", hex)
  end
end

function menu_move()
  push_menu("movement")
end

function menu_actions()
  push_menu("actions")
end

function menu_dance()
  push_menu("dance")
end

function menu_story()
  push_menu("story")
end

function menu_music()
  push_menu("music")
end

function menu_sleep()
  push_menu("sleep")
end
