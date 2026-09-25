local component = require("component")
local computer = require("computer")
local event = require("event")
local filesystem = require("filesystem")
local keyboard = require("keyboard")
local serialization = require("serialization")

local outputFile = "/home/bec_installer_addresses.lua"
local activeRefillLink
local roles = { "-", "NODE", "FLUID", "CRAFT", "HALT", "REFILL_LINK", "ACTIVE_INPUT", "ROUTE" }
local fixed = {
  NODE = "nodeAddress", FLUID = "generatorAddress", CRAFT = "synthesisAddress",
  HALT = "haltAddress", REFILL_LINK = "entanglerAddress", ACTIVE_INPUT = "activityAddress",
}
local gpu = component.isAvailable("gpu") and component.gpu or nil
local colors = { bg = 0x101C20, panel = 0x20343A, text = 0xE7EDEC,
  muted = 0xA7B8B8, accent = 0x64D6AE, selected = 0x30574D, warning = 0xFFCA74 }

local function fail(message) error(message, 0) end
local function devices(kind)
  local result = {}
  for address in component.list(kind, true) do result[#result + 1] = address end
  table.sort(result)
  return result
end

local function draw(title, lines, footer)
  local width, height = gpu.getResolution()
  gpu.setBackground(colors.bg)
  gpu.fill(1, 1, width, height, " ")
  gpu.setBackground(colors.panel)
  gpu.fill(1, 1, width, 2, " ")
  gpu.setForeground(colors.accent)
  gpu.set(2, 1, "BEC  /  " .. title:sub(1, width - 10))
  gpu.setBackground(colors.bg)
  gpu.setForeground(colors.text)
  for index, value in ipairs(lines or {}) do
    if index + 3 < height - 2 then gpu.set(3, index + 3, tostring(value):sub(1, width - 4)) end
  end
  gpu.setBackground(colors.panel)
  gpu.fill(1, height - 2, width, 3, " ")
  gpu.setForeground(colors.warning)
  gpu.set(2, height - 1, (footer or "Enter / click CONTINUE | Q cancel"):sub(1, width - 2))
  gpu.setBackground(colors.bg)
  gpu.setForeground(colors.text)
end

local function action(title, lines, confirm, cancelLabel)
  local width, height = gpu.getResolution()
  while true do
    draw(title, lines, "[ " .. (confirm or "CONTINUE") .. " ] Enter/click       [ "
      .. (cancelLabel or "CANCEL") .. " ] Q/click")
    local name, _, a, b = event.pull()
    if name == "key_down" then
      if b == keyboard.keys.enter then return true end
      if b == keyboard.keys.q or b == keyboard.keys.esc then return false end
    elseif name == "touch" and b >= height - 2 then
      return a < width / 2
    end
  end
end

local function requireAction(title, lines, confirm)
  if not action(title, lines, confirm) then fail("installer cancelled without saving") end
end

local function choose(label, addresses)
  if #addresses == 0 then fail("missing " .. label .. " on this OC network") end
  if #addresses == 1 then
    requireAction("MACHINE / " .. label, { "Found one matching component", addresses[1] })
    return addresses[1]
  end
  local selected, offset = 1, 0
  while true do
    local _, height = gpu.getResolution()
    local visible = height - 10
    if selected <= offset then offset = selected - 1 end
    if selected > offset + visible then offset = selected - visible end
    local lines = { "Select " .. label .. " (arrows or touch a row):" }
    for index = offset + 1, math.min(#addresses, offset + visible) do
      lines[#lines + 1] = (index == selected and "> " or "  ") .. addresses[index]
    end
    draw("MACHINE / " .. label, lines, "Enter: use selection   UP/DOWN: select   Q: cancel")
    local name, _, a, b = event.pull()
    if name == "key_down" then
      if b == keyboard.keys.up then selected = math.max(1, selected - 1)
      elseif b == keyboard.keys.down then selected = math.min(#addresses, selected + 1)
      elseif b == keyboard.keys.enter then return addresses[selected]
      elseif b == keyboard.keys.q or b == keyboard.keys.esc then fail("installer cancelled") end
    elseif name == "touch" then
      local index = offset + b - 4
      if index >= 1 and index <= #addresses then
        if index == selected then return addresses[index] end
        selected = index
      end
    end
  end
end

local function itemSnapshot(address)
  local ok, stacks = pcall(component.invoke, address, "getItemsInNetwork")
  if not ok or type(stacks) ~= "table" then
    fail("cannot read ME items on " .. address .. ": " .. tostring(stacks))
  end
  local result = {}
  for _, stack in pairs(stacks) do
    if type(stack) == "table" and tonumber(stack.size) and tonumber(stack.size) > 0 then
      local key = tostring(stack.name) .. ":" .. tostring(stack.damage or 0)
      result[key] = (result[key] or 0) + tonumber(stack.size)
    end
  end
  return result
end

local function snapshots(addresses)
  local result = {}
  for _, address in ipairs(addresses) do result[address] = itemSnapshot(address) end
  return result
end

local function changes(before, after, addresses)
  local changed = {}
  for _, address in ipairs(addresses) do
    for key, amount in pairs(after[address]) do
      if amount ~= (before[address][key] or 0) then changed[address] = true end
    end
    for key, amount in pairs(before[address]) do
      if amount ~= (after[address][key] or 0) then changed[address] = true end
    end
  end
  return changed
end

local function discoverME(addresses)
  local result = {}
  local assigned = {}
  local labels = {
    { field = "cacheInterfaceAddress", name = "MATERIAL / incoming orders" },
    { field = "itemInterfaceAddress", name = "ITEM / node cache" },
    { field = "fluidInterfaceAddress", name = "FLUID / entangler cache" },
    { field = "refillCacheInterfaceAddress", name = "REFILL / fluid source cache" },
  }
  for _, entry in ipairs(labels) do
    while true do
      requireAction("AE / " .. entry.name, {
        "Step 1 / 3: remove any previous marker item.",
        "Stop automation, deliveries and unrelated inventory changes.",
        "The network needs temporary item storage.",
      }, "READ BASELINE")
      local before = snapshots(addresses)
      requireAction("AE / " .. entry.name, {
        "Step 2 / 3: insert one unique marker item",
        "into ONLY this AE network.", "Wait for the item to appear in storage.",
      }, "DETECT INTERFACE")
      local after = snapshots(addresses)
      local changed = changes(before, after, addresses)
      local match, count = nil, 0
      for _, address in ipairs(addresses) do
        if changed[address] then match, count = address, count + 1 end
      end
      if count == 1 and not assigned[match] then
        local gained = false
        for key, size in pairs(after[match]) do
          if size > (before[match][key] or 0) then gained = true end
        end
        if gained then
          requireAction("AE / " .. entry.name, {
            "Step 3 / 3: detected interface:", match,
            "Remove the marker item and wait for the network to settle.",
          }, "VERIFY REMOVAL")
          local restored = snapshots(addresses)
          if not next(changes(before, restored, addresses)) then
            result[entry.field] = match
            assigned[match] = true
            draw("AE / CONFIRMED", { entry.name, match }, "Continuing to next network...")
            break
          end
          if not action("AE / NOT VERIFIED", {
            "Inventory did not return to baseline.", "No address was accepted.",
          }, "RETRY") then fail("ME identification cancelled") end
        else
          if not action("AE / NOT VERIFIED", {
            "No positive item change on the matching interface.",
            "No address was accepted.",
          }, "RETRY") then fail("ME identification cancelled") end
        end
      else
        if not action("AE / AMBIGUOUS", {
          "Expected exactly one unused ME interface to change.",
          "Observed changed interfaces: " .. count,
          "Remove the marker and stop other inventory changes.",
        }, "RETRY") then fail("ME identification cancelled") end
      end
    end
  end
  return result
end

local function readTestInput(row)
  local inputs = component.invoke(row.address, "getInput")
  if type(inputs) ~= "table" then fail("activity input did not return a side table") end
  local strongest = 0
  for side = 0, 5 do strongest = math.max(strongest, tonumber(inputs[side]) or 0) end
  return "Input max=" .. strongest .. " (read only)"
end

local function setTestOutput(session, value)
  if session.role == "ROUTE" then
    component.invoke(session.address, "setOutput", session.side, value)
    if tonumber(component.invoke(session.address, "getOutput", session.side)) ~= value then
      fail("route output verification failed on " .. session.address)
    end
  else
    local values = {}
    for side = 0, 5 do values[side] = value end
    component.invoke(session.address, "setOutput", values)
    local actual = component.invoke(session.address, "getOutput")
    if type(actual) ~= "table" then fail("output did not return a side table") end
    for side = 0, 5 do
      if tonumber(actual[side]) ~= value then
        fail("output verification failed on " .. session.address .. " side " .. side)
      end
    end
  end
  session.high = value ~= 0
end

local function validate(rows)
  local selected, routes = {}, {}
  for _, row in ipairs(rows) do
    if row.role == "ROUTE" then
      routes[#routes + 1] = row.address
    elseif row.role ~= "-" then
      if selected[row.role] then fail("role assigned twice: " .. row.role) end
      selected[row.role] = row.address
    end
  end
  for role in pairs(fixed) do if not selected[role] then fail("missing redstone role " .. role) end end
  if #routes ~= 10 then fail("exactly 10 ROUTE devices required, found " .. #routes) end
  return selected, routes
end

local function redstoneTable(addresses, previous)
  if not gpu then fail("a GPU and screen are required for the installer") end
  local width, height = gpu.getResolution()
  if width < 80 or height < 20 then fail("installer needs at least 80x20 screen resolution") end
  local rows = {}
  for _, address in ipairs(addresses) do
    local role = "-"
    for name, field in pairs(fixed) do
      if previous and previous[field] == address then role = name end
    end
    if previous then
      for _, route in ipairs(previous.routeAddresses or {}) do
        if route == address then role = "ROUTE" end
      end
    end
    rows[#rows + 1] = { address = address, role = role, side = 0, testing = false }
  end
  local selected, offset, message = 1, 0, "Automation must remain STOPPED during tests"
  local active
  local function stopTest()
    if not active then return end
    setTestOutput(active, 0)
    active.row.testing = false
    active = nil
  end
  local function toggleTest(row)
    if row.role == "ACTIVE_INPUT" then return readTestInput(row) end
    if active and active.row == row then
      stopTest()
      return "Pulse stopped; output verified OFF"
    end
    stopTest()
    active = { row = row, address = row.address, side = row.side, role = row.role, high = false }
    row.testing = true
    setTestOutput(active, 15)
    active.deadline = computer.uptime() + 1
    return "Pulsing " .. row.address .. ": 1s HIGH / 1s LOW"
  end
  local function draw()
    local width, height = gpu.getResolution()
    local visible = height - 11
    if selected <= offset then offset = selected - 1 end
    if selected > offset + visible then offset = selected - visible end
    gpu.setBackground(colors.bg)
    gpu.fill(1, 1, width, height, " ")
    gpu.setBackground(colors.panel)
    gpu.fill(1, 1, width, 2, " ")
    gpu.setForeground(colors.accent)
    gpu.set(2, 1, "BEC  /  REDSTONE I/O    " .. #rows .. " devices")
    gpu.setBackground(colors.bg)
    gpu.setForeground(colors.muted)
    gpu.set(2, 3, "UP/DOWN row | LEFT/RIGHT role | F/[UP/DOWN] route side | T toggle")
    gpu.setForeground(colors.warning)
    gpu.set(2, 4, "Tests can move materials or release HALT. Isolate hazardous loads.")
    gpu.setForeground(colors.accent)
    gpu.set(2, 6, string.format("%-37s %-24s %s", "ADDRESS", "ROLE", "TOGGLE"))
    for index = offset + 1, math.min(#rows, offset + visible) do
      local row = rows[index]
      local roleLabel = row.role == "ROUTE"
        and string.format("%-12s[%s]", "ROUTE", row.side == 0 and "DOWN" or "UP")
        or row.role
      local toggle = row.role == "ACTIVE_INPUT" and "READ"
        or (row.testing and (active.high and "ON/HIGH" or "ON/LOW") or "OFF")
      local display = string.format("%-37s %-24s %s", row.address, roleLabel, toggle)
      local y = index - offset + 6
      if index == selected then
        gpu.setBackground(colors.selected)
        gpu.fill(1, y, width, 1, " ")
        gpu.setForeground(colors.text)
      else
        gpu.setBackground(colors.bg)
        gpu.setForeground(colors.muted)
      end
      gpu.set(2, y, display:sub(1, width - 2))
    end
    gpu.setBackground(colors.panel)
    gpu.fill(1, height - 3, width, 4, " ")
    gpu.setForeground(colors.warning)
    gpu.set(2, height - 3, message:sub(1, width - 2))
    gpu.setForeground(colors.accent)
    gpu.set(2, height - 1, "[ SAVE ] S / click")
    gpu.set(30, height - 1, "[ CANCEL ] Q / click")
    gpu.setBackground(colors.bg)
    gpu.setForeground(colors.text)
  end
  if #rows < 16 then fail("expected at least 16 redstone I/O devices, found " .. #rows) end
  local ok, selectedRoles, selectedRoutes = xpcall(function()
    while true do
      if active and computer.uptime() >= active.deadline then
        setTestOutput(active, active.high and 0 or 15)
        active.deadline = computer.uptime() + 1
      end
      draw()
      local eventName, _, char, code
      if active then
        eventName, _, char, code = event.pull(math.max(0, active.deadline - computer.uptime()))
      else
        eventName, _, char, code = event.pull()
      end
      if eventName == "key_down" then
        local key = type(char) == "number" and string.char(char % 256):lower() or ""
        local row = rows[selected]
        if code == keyboard.keys.up then selected = math.max(1, selected - 1)
        elseif code == keyboard.keys.down then selected = math.min(#rows, selected + 1)
        elseif code == keyboard.keys.left or code == keyboard.keys.right then
          if active and active.row == row then stopTest() end
          local pos = 1
          for index, role in ipairs(roles) do if role == row.role then pos = index end end
          row.role = roles[(pos - 1 + (code == keyboard.keys.right and 1 or -1)) % #roles + 1]
          message = "Role selected for " .. row.address
        elseif key == "f" then
          if row.role == "ROUTE" then
            if active and active.row == row then stopTest() end
            row.side = 1 - row.side
          end
        elseif key == "t" then
          message = toggleTest(row)
        elseif key == "s" then
          local valid, selectedRoles, selectedRoutes = pcall(validate, rows)
          if valid then return selectedRoles, selectedRoutes end
          message = tostring(selectedRoles)
        elseif key == "q" then fail("installer cancelled without saving") end
      elseif eventName == "touch" then
        local x, y = char, code
        if y >= height - 2 then
          if x < 25 then
            local valid, selectedRoles, selectedRoutes = pcall(validate, rows)
            if valid then return selectedRoles, selectedRoutes end
            message = tostring(selectedRoles)
          elseif x >= 28 and x < 52 then
            fail("installer cancelled without saving")
          end
        elseif y >= 7 and y < height - 3 then
          local index = offset + y - 6
          if rows[index] then
            selected = index
            local touched = rows[index]
            if x >= 40 and x < 52 then
              if active and active.row == touched then stopTest() end
              local pos = 1
              for i, role in ipairs(roles) do if role == touched.role then pos = i end end
              touched.role = roles[pos % #roles + 1]
            elseif x >= 52 and x < 65 then
              if touched.role == "ROUTE" then
                if active and active.row == touched then stopTest() end
                touched.side = 1 - touched.side
              end
            elseif x >= 65 then
              message = toggleTest(touched)
            end
          end
        end
      end
    end
  end, debug.traceback)
  local off, offError = pcall(stopTest)
  if not off then off, offError = pcall(stopTest) end
  if not off then fail("TEST OUTPUT MAY STILL BE HIGH: " .. tostring(offError)) end
  if not ok then error(selectedRoles, 0) end
  return selectedRoles, selectedRoutes
end

local function writeAddresses(addresses)
  local temp = outputFile .. ".new"
  local file, err = io.open(temp, "w")
  if not file then fail("cannot write " .. temp .. ": " .. tostring(err)) end
  file:write("return ", serialization.serialize(addresses), "\n")
  file:close()
  local loaded, data = pcall(dofile, temp)
  if not loaded or type(data) ~= "table" or data.schemaVersion ~= 1 then
    fail("generated address file failed validation: " .. tostring(data))
  end
  local backup
  if filesystem.exists(outputFile) then
    local index = 1
    repeat
      backup = outputFile .. ".bak" .. index
      index = index + 1
    until not filesystem.exists(backup)
    local ok, reason = filesystem.rename(outputFile, backup)
    if not ok then fail("cannot back up existing addresses: " .. tostring(reason)) end
  end
  local ok, reason = filesystem.rename(temp, outputFile)
  if not ok then
    if backup then filesystem.rename(backup, outputFile) end
    fail("cannot install generated addresses: " .. tostring(reason))
  end
  return backup
end

local function backupRoute(path)
  if not filesystem.exists(path) then return nil end
  local index = 1
  local backup
  repeat
    backup = path .. ".bak" .. index
    index = index + 1
  until not filesystem.exists(backup)
  local ok, reason = filesystem.rename(path, backup)
  if not ok then fail("cannot back up old route map: " .. tostring(reason)) end
  return backup
end

local function checkedInvoke(address, method, ...)
  local ok, result = pcall(component.invoke, address, method, ...)
  if not ok then fail(address .. "." .. method .. ": " .. tostring(result)) end
  return result
end

local function readStagedTotal(address)
  local fluids = checkedInvoke(address, "getFluidsInNetwork")
  if type(fluids) ~= "table" then fail("ME interface " .. address .. " returned invalid fluid data") end
  local total = 0
  for _, stack in pairs(fluids) do
    if type(stack) == "table" then
      total = total + math.max(0, tonumber(stack.amount) or 0)
    end
  end
  return total
end

local function readCondensateTotal(address)
  local fluids = checkedInvoke(address, "getStoredCondensate")
  if type(fluids) ~= "table" then fail("BEC storage returned invalid condensate data") end
  local total = 0
  for _, amount in pairs(fluids) do total = total + math.max(0, tonumber(amount) or 0) end
  return total
end

local function setRefillLinkOutput(address, signal)
  local values = {}
  for side = 0, 5 do values[side] = signal end
  checkedInvoke(address, "setOutput", values)
  local actual = checkedInvoke(address, "getOutput")
  if type(actual) ~= "table" then fail("REFILL_LINK did not return all-face outputs") end
  for side = 0, 5 do
    if tonumber(actual[side]) ~= signal then
      fail("REFILL_LINK output verification failed on side " .. side)
    end
  end
end

local function openRouterLink(addresses, config)
  local staged = readStagedTotal(addresses.refillCacheInterfaceAddress)
  if staged > 0 then
    if readStagedTotal(addresses.fluidInterfaceAddress) > 0 then
      fail("entangler input cache is not empty; finish the existing fluids before connecting REFILL_LINK")
    end
    if checkedInvoke(addresses.storageAddress, "isMachineActive") ~= true then
      fail("BEC storage is not active; do not entangle fluids until it is running")
    end
    local currentStrength = tonumber(checkedInvoke(addresses.storageAddress, "getFieldStrength"))
    if not currentStrength then fail("BEC storage returned invalid field strength") end
    local requiredStrength = math.max(currentStrength,
      readCondensateTotal(addresses.storageAddress) + staged)
    if requiredStrength > currentStrength then
      checkedInvoke(addresses.storageAddress, "setFieldStrength", requiredStrength)
      local actual = tonumber(checkedInvoke(addresses.storageAddress, "getFieldStrength"))
      if not actual or actual < requiredStrength then fail("BEC field strength did not increase") end
    end
  end
  local ok, reason = pcall(setRefillLinkOutput, addresses.entanglerAddress,
    config.refill.connectSignal)
  if not ok then
    local offOk, offReason = pcall(setRefillLinkOutput, addresses.entanglerAddress,
      config.refill.disconnectSignal)
    if not offOk then fail("REFILL_LINK MAY STILL BE ON: " .. tostring(offReason)
      .. "; original error: " .. tostring(reason)) end
    fail("cannot open REFILL_LINK: " .. tostring(reason))
  end
  activeRefillLink = {
    address = addresses.entanglerAddress,
    signal = config.refill.disconnectSignal,
  }
end

local function closeRouterLink()
  if not activeRefillLink then return end
  setRefillLinkOutput(activeRefillLink.address, activeRefillLink.signal)
  activeRefillLink = nil
end

local function waitForEmptyRouterCache(addresses, config, initialFluids)
  local names = {}
  for name, amount in pairs(initialFluids) do
    names[#names + 1] = string.format("%s: %.0f mB", name, amount)
  end
  table.sort(names)
  local status
  while true do
    local remaining = readStagedTotal(addresses.refillCacheInterfaceAddress)
    local lines = {
      string.format("Refill cache: %.0f mB", remaining),
      "REFILL_LINK: " .. (activeRefillLink and "ON" or "OFF"),
      "T / left: toggle link to the entangler.",
      "Enter / middle: switch OFF and recheck cache.",
      "Q / right: switch OFF and cancel mapping.",
      "Probe outputs remain OFF while this page is open.",
    }
    for index = 1, math.min(#names, 3) do lines[#lines + 1] = names[index] end
    if status then lines[#lines + 1] = status end
    draw("ROUTER / CACHE NOT EMPTY", lines,
      "T/left: LINK " .. (activeRefillLink and "OFF" or "ON")
      .. " | Enter/middle: RECHECK | Q/right: CANCEL")
    local name, _, x, key = event.pull(1)
    local choice
    if name == "key_down" then
      if key == keyboard.keys.t then choice = "toggle"
      elseif key == keyboard.keys.enter then choice = "recheck"
      elseif key == keyboard.keys.q or key == keyboard.keys.esc then choice = "cancel" end
    elseif name == "touch" then
      local width, height = gpu.getResolution()
      if key >= height - 2 then
        if x <= width / 3 then choice = "toggle"
        elseif x <= width * 2 / 3 then choice = "recheck"
        else choice = "cancel" end
      end
    end
    if choice == "toggle" then
      if activeRefillLink then
        closeRouterLink()
        status = nil
      else
        local ok, reason = pcall(openRouterLink, addresses, config)
        if not ok then
          if tostring(reason):find("REFILL_LINK MAY STILL BE ON", 1, true) then fail(reason) end
          status = tostring(reason):match("^[^\n]+")
        else
          status = nil
        end
      end
    elseif choice == "recheck" or choice == "cancel" then
      closeRouterLink()
      return choice == "recheck"
    end
  end
end

local function main()
  if not gpu then fail("a GPU and screen are required for the installer") end
  local width, height = gpu.getResolution()
  if width < 80 or height < 20 then fail("installer needs at least 80x20 screen resolution") end
  requireAction("SETUP", {
    "This installer identifies components and writes addresses only.",
    "Stop BEC automation, route mapper, and AE deliveries first.",
    "Each AE network needs temporary item storage for a marker.",
    "Redstone tests can energize outputs; isolate unsafe loads.",
  }, "START DISCOVERY")
  local storage = choose("BEC containment field", devices("bec_storage"))
  local gate = choose("Maxwell gate", devices("bec_diode"))
  local nodes = devices("bec_io_node")
  if #nodes ~= 16 then fail("expected exactly 16 BEC nodes, found " .. #nodes) end
  requireAction("MACHINES / NODES", {
    "Found exactly 16 BEC I/O nodes on this OC network.",
    "The detected addresses will be saved in sorted order.",
  })
  local interfaces = devices("me_interface")
  if #interfaces < 4 then fail("expected at least 4 ME interfaces, found " .. #interfaces) end
  local ae = discoverME(interfaces)
  local previous
  local ok, config = pcall(require, "bec_automation_config")
  if ok and type(config) == "table" then
    previous = {
      nodeAddress = config.redstone.nodeAddress,
      generatorAddress = config.redstone.generatorAddress,
      synthesisAddress = config.redstone.synthesisAddress,
      haltAddress = config.redstone.haltAddress,
      entanglerAddress = config.refill.entanglerAddress,
      activityAddress = config.refill.activityAddress,
    }
    previous.routeAddresses = config.refill.installedRouteAddresses
  end
  local rolesByName, routes = redstoneTable(devices("redstone"), previous)
  local addresses = {
    schemaVersion = 1,
    storageAddress = storage,
    gateAddress = gate,
    nodeAddresses = nodes,
    cacheInterfaceAddress = ae.cacheInterfaceAddress,
    itemInterfaceAddress = ae.itemInterfaceAddress,
    fluidInterfaceAddress = ae.fluidInterfaceAddress,
    refillCacheInterfaceAddress = ae.refillCacheInterfaceAddress,
    routeAddresses = routes,
  }
  for role, field in pairs(fixed) do addresses[field] = rolesByName[role] end
  requireAction("SAVE / REVIEW", {
    "BEC field: " .. storage,
    "Maxwell gate: " .. gate,
    "ME interfaces: 4 unique addresses verified",
    "BEC nodes: 16", "Redstone roles: 6 fixed + 10 route devices",
    "Addresses will be saved, then 20 refill outputs auto-mapped.",
    "Refill cache must be empty; probes will transfer real fluids.",
  }, "SAVE ADDRESSES")
  local backup = writeAddresses(addresses)
  package.loaded["bec_automation_config"] = nil
  package.loaded["bec_route_mapper_config"] = nil
  package.loaded["bec_route_mapper"] = nil
  local mapperConfig = require("bec_route_mapper_config")
  local automationConfig = require("bec_automation_config")
  local routeBackup = backupRoute(mapperConfig.outputFile)
  local mapper = require("bec_route_mapper")
  local recent = {}
  local function progress(message)
    recent[#recent + 1] = tostring(message)
    if #recent > 10 then table.remove(recent, 1) end
    draw("ROUTER / AUTO MAPPING", recent,
      "Probing 20 outputs; keep networks stable and do not stop the computer")
  end
  progress("Old route map archived; checking connected I/O devices...")
  local checked, reason = mapper.execute("check", { report = progress })
  if not checked then fail("router preflight failed: " .. tostring(reason)) end
  progress("Starting automatic route mapping")
  local mapped, result = mapper.execute("run", {
    probeTimeout = 30,
    report = progress,
    onNonEmptyCache = function(fluids)
      return waitForEmptyRouterCache(addresses, automationConfig, fluids)
    end,
  })
  if not mapped then fail("router auto-mapping failed: " .. tostring(result)) end
  if not result.complete then
    fail("router mapped " .. result.mapped .. "/19 fluids; inspect " .. result.path)
  end
  local staged = readStagedTotal(addresses.refillCacheInterfaceAddress)
  local linkOpened = false
  if action("ROUTER / ENTANGLE CACHE", {
    "All routes are configured. Refill cache contains:",
    string.format("%.0f mB of mapped test fluids", staged),
    "Enter: raise BEC field strength and connect REFILL_LINK.",
    "The link remains ON until you exit the final page.",
    "Q: skip and leave REFILL_LINK off.",
  }, "ENTANGLE ALL", "SKIP") then
    openRouterLink(addresses, automationConfig)
    linkOpened = true
  end
  action("INSTALLATION COMPLETE", {
    "Saved " .. outputFile,
    backup and ("Previous mapping: " .. backup) or "No previous address overlay",
    "Auto-mapped 19 fluids; one route output unused.",
    "Route map: " .. result.path,
    routeBackup and ("Previous route map: " .. routeBackup) or "No previous route map",
    "Next: bec_automation.lua check",
    linkOpened and "REFILL_LINK ON; wait for all fluids to entangle."
      or "REFILL_LINK OFF; test fluids remain in the cache.",
    linkOpened and "Press Enter/Q after conversion to disconnect and exit."
      or "Clear the test fluids before running automation.",
  }, "DISCONNECT / EXIT", "DISCONNECT / EXIT")
end

local ok, err = xpcall(main, debug.traceback)
if activeRefillLink then
  local link = activeRefillLink
  activeRefillLink = nil
  local offOk, offReason = pcall(setRefillLinkOutput, link.address, link.signal)
  if not offOk then
    err = "REFILL_LINK MAY STILL BE ON: " .. tostring(offReason)
      .. (ok and "" or "; original error: " .. tostring(err))
    ok = false
  end
end
if not ok then
  if gpu then
    pcall(function()
      action("INSTALLATION STOPPED", {
        tostring(err):match("^[^\n]+") or tostring(err),
        "If SAVE completed, the new addresses are already on disk.",
        "Old routes may be in .bakN; inspect .partial.lua.",
        "Check the terminal for the full traceback.",
      }, "CLOSE")
    end)
  end
  io.stderr:write(tostring(err), "\n")
  os.exit(1)
end
