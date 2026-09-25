local component = require("component")
local computer = require("computer")
local filesystem = require("filesystem")
local serialization = require("serialization")

local configOk, config = pcall(require, "bec_automation_config")
if not configOk then
  error("cannot load bec_automation_config.lua: " .. tostring(config), 0)
end

local logHandle
local storage
local gate
local cache
local itemCache
local fluidCache
local nodeRedstone
local generatorRedstone
local synthesisRedstone
local haltRedstone
local refillCache
local refillLinkRedstone
local refillActivityRedstone
local refillRoutes = {}
local routeConfig
local nodes = {}
local baselineFieldStrength = 1
local fluidBySource = {}
local targetByCondensate = {}
local controlsArmed = false
local refillFieldStrengthFloor = 1
local dashboard
local dashboardPaused = false
local processedRecipeTotal = 0
local processedRecipeFile
local haltLatched = false
local haltInterlockActive = false

local function now()
  return computer.uptime()
end

local function fail(message)
  error(message, 0)
end

local function log(level, message)
  local timestamp = now()
  local line = string.format("[%9.1f] %-5s %s", timestamp, level, message)
  if dashboard then
    local ok = pcall(dashboard.log, dashboard, level, message, timestamp)
    if not ok then
      pcall(dashboard.close, dashboard)
      dashboard = nil
      print(line)
      print("[dashboard disabled after a rendering error]")
    end
  else
    print(line)
  end
  if logHandle then
    logHandle:write(line, "\n")
    logHandle:flush()
  end
end

local function uiUpdate(values, force)
  if not dashboard then return end
  local ok = pcall(dashboard.update, dashboard, values, force, dashboardPaused)
  if not ok then
    pcall(dashboard.close, dashboard)
    dashboard = nil
    print("[dashboard disabled after a rendering error]")
  end
end

local function uiPhase(phase, detail)
  uiUpdate({ phase = phase, detail = detail })
end

local function initializeDashboard()
  local options = config.ui or {}
  if options.enabled == false then return end
  local loaded, module = pcall(require, "bec_dashboard")
  if not loaded then
    print("[dashboard unavailable: cannot load bec_dashboard.lua: " .. tostring(module) .. "]")
    return
  end
  local created, reason = module.new(options, config.fluids)
  if not created then
    print("[dashboard unavailable: " .. tostring(reason) .. "]")
    return
  end
  dashboard = created
end

local function checked(label, fn, ...)
  local ok, a, b, c, d = pcall(fn, ...)
  if not ok then fail(label .. ": " .. tostring(a)) end
  return a, b, c, d
end

local function trim(value)
  return tostring(value or ""):match("^%s*(.-)%s*$")
end

local function isInteger(value)
  return type(value) == "number" and value >= 0 and value % 1 == 0
end

local function formatInteger(value)
  local number = tonumber(value) or 0
  local text
  if math.type and math.type(number) == "integer" then
    text = string.format("%d", number)
  else
    text = string.format("%.0f", number)
  end
  local replacements
  repeat
    text, replacements = text:gsub("^(%-?%d+)(%d%d%d)", "%1,%2")
  until replacements == 0
  return text
end

local function readProcessedRecipeFile(path)
  local handle, reason = io.open(path, "r")
  if not handle then return nil, "missing", reason end
  local contents = handle:read("*a")
  handle:close()
  local text = contents and contents:match("^BEC_PROCESSED_V1 (%d+)\n$")
  local value = tonumber(text)
  if not isInteger(value) then return nil, "invalid", "invalid counter contents" end
  return value
end

local function writeProcessedRecipeFile(path, contents)
  local handle, reason = io.open(path, "w")
  if not handle then return nil, reason end
  local wrote, writeReason = handle:write(contents)
  if not wrote then
    pcall(handle.close, handle)
    return nil, writeReason
  end
  local flushed, flushReason = handle:flush()
  if not flushed then
    pcall(handle.close, handle)
    return nil, flushReason
  end
  -- OpenOS filesystem close succeeds without a return value.
  local closed, closeReason = pcall(handle.close, handle)
  if not closed then return nil, closeReason end
  return true
end

local function loadProcessedRecipeTotal()
  local primary, primaryState, primaryReason = readProcessedRecipeFile(processedRecipeFile)
  local backup, backupState, backupReason = readProcessedRecipeFile(processedRecipeFile .. ".bak")
  if primary or backup then
    processedRecipeTotal = math.max(primary or 0, backup or 0)
    if primaryState == "invalid" or backupState == "invalid" then
      log("WARN", "recovered processed recipe total from the valid counter copy")
    end
  elseif primaryState == "missing" and backupState == "missing" then
    processedRecipeTotal = 0
  else
    fail(string.format(
      "processed recipe counter is unreadable: primary=%s backup=%s",
      tostring(primaryReason),
      tostring(backupReason)
    ))
  end
  uiUpdate({ processedRecipeTotal = processedRecipeTotal }, true)
  log("INFO", "processed recipe total=" .. formatInteger(processedRecipeTotal))
end

local function saveProcessedRecipeTotal()
  local contents = string.format("BEC_PROCESSED_V1 %.0f\n", processedRecipeTotal)
  local primary = readProcessedRecipeFile(processedRecipeFile)
  local backup = readProcessedRecipeFile(processedRecipeFile .. ".bak")
  local firstPath = processedRecipeFile
  local secondPath = processedRecipeFile .. ".bak"
  if (backup or -1) < (primary or -1) then
    firstPath, secondPath = secondPath, firstPath
  end

  local firstOk, firstReason = writeProcessedRecipeFile(firstPath, contents)
  if not firstOk then return nil, firstPath .. ": " .. tostring(firstReason) end
  local secondOk, secondReason = writeProcessedRecipeFile(secondPath, contents)
  if not secondOk then
    return true, secondPath .. " write failed; the other counter copy is current: "
      .. tostring(secondReason)
  end
  return true
end

local function resolveAddress(componentType, prefix, label)
  prefix = trim(prefix)
  local available = {}
  local matches = {}

  for address in component.list(componentType, true) do
    available[#available + 1] = address
    if prefix == "" or address:sub(1, #prefix) == prefix then
      matches[#matches + 1] = address
    end
  end
  table.sort(available)
  table.sort(matches)

  if #matches == 0 then
    fail(string.format(
      "%s (%s) not found; prefix=%s; available=%s",
      label,
      componentType,
      prefix ~= "" and prefix or "<auto>",
      #available > 0 and table.concat(available, ",") or "none"
    ))
  end
  if #matches > 1 then
    fail(label .. " address is ambiguous: " .. table.concat(matches, ","))
  end
  return matches[1]
end

local function bindAddress(address, componentType, label, requiredMethods)
  if component.type(address) ~= componentType then
    fail(string.format("%s %s is not a %s", label, address, componentType))
  end

  local exposed, reason = component.methods(address)
  if type(exposed) ~= "table" then fail(label .. " methods unavailable: " .. tostring(reason)) end
  for _, method in ipairs(requiredMethods) do
    if exposed[method] == nil then fail(label .. " does not expose " .. method) end
  end

  local bound = { address = address, type = componentType }
  for method in pairs(exposed) do
    local methodName = method
    bound[methodName] = function(...)
      return component.invoke(address, methodName, ...)
    end
  end
  return bound
end

local function bindOne(componentType, prefix, label, requiredMethods)
  return bindAddress(resolveAddress(componentType, prefix, label), componentType, label, requiredMethods)
end

local function validateConfig()
  if config.schemaVersion ~= 11 then
    fail(
      "bec_automation_config.lua is outdated or does not match this program; "
        .. "copy the current config file together with bec_automation.lua"
    )
  end
  local uiConfig = config.ui or {}
  if uiConfig.processedRecipeFile ~= nil
      and (type(uiConfig.processedRecipeFile) ~= "string"
        or trim(uiConfig.processedRecipeFile) == "") then
    fail("ui.processedRecipeFile must be a non-empty path")
  end
  processedRecipeFile = trim(uiConfig.processedRecipeFile or "/home/bec_processed_recipes.dat")
  local buffers = config.buffers or {}
  for _, entry in ipairs({
    { name = "buffers.itemInterfaceAddress", value = buffers.itemInterfaceAddress },
    { name = "buffers.fluidInterfaceAddress", value = buffers.fluidInterfaceAddress },
    { name = "buffers.interfaceType", value = buffers.interfaceType },
  }) do
    if type(entry.value) ~= "string" or trim(entry.value) == "" then
      fail(entry.name .. " must be a non-empty string")
    end
  end
  local redstoneConfig = config.redstone or {}
  for _, entry in ipairs({
    { name = "redstone.nodeAddress", value = redstoneConfig.nodeAddress },
    { name = "redstone.generatorAddress", value = redstoneConfig.generatorAddress },
    { name = "redstone.synthesisAddress", value = redstoneConfig.synthesisAddress },
    { name = "redstone.haltAddress", value = redstoneConfig.haltAddress },
  }) do
    if type(entry.value) ~= "string" or trim(entry.value) == "" then
      fail(entry.name .. " must be a component address or unique prefix")
    end
  end

  local refill = config.refill or {}
  if refill.enabled then
    for _, entry in ipairs({
      { name = "refill.routeModule", value = refill.routeModule },
      { name = "refill.cacheInterfaceAddress", value = refill.cacheInterfaceAddress },
      { name = "refill.cacheInterfaceType", value = refill.cacheInterfaceType },
      { name = "refill.entanglerAddress", value = refill.entanglerAddress },
      { name = "refill.activityAddress", value = refill.activityAddress },
    }) do
      if type(entry.value) ~= "string" or trim(entry.value) == "" then
        fail(entry.name .. " must be a non-empty string")
      end
    end
    if not isInteger(refill.activityThreshold) or refill.activityThreshold < 1 then
      fail("refill.activityThreshold must be a positive integer")
    end
    for _, entry in ipairs({
      { name = "refill.connectSignal", value = refill.connectSignal },
      { name = "refill.disconnectSignal", value = refill.disconnectSignal },
    }) do
      if not isInteger(entry.value) or entry.value > 15 then
        fail(entry.name .. " must be an integer from 0 to 15")
      end
    end
    if refill.connectSignal == refill.disconnectSignal then
      fail("refill connectSignal and disconnectSignal must be different")
    end
    for _, name in ipairs({
      "poll", "routeTimeout",
      "conversionTimeout", "checkInterval", "drainedWaitTimeout",
    }) do
      if type(refill[name]) ~= "number" or refill[name] <= 0 then
        fail("refill." .. name .. " must be a positive number")
      end
    end
  end
  if redstoneConfig.connectSignal == redstoneConfig.disconnectSignal then
    fail("redstone connectSignal and disconnectSignal must be different")
  end
  for _, entry in ipairs({
    { name = "redstone.connectSignal", value = redstoneConfig.connectSignal },
    { name = "redstone.disconnectSignal", value = redstoneConfig.disconnectSignal },
  }) do
    if not isInteger(entry.value) or entry.value > 15 then
      fail(entry.name .. " must be an integer from 0 to 15")
    end
  end

  local nodeConfig = config.nodes or {}
  if not isInteger(nodeConfig.expectedCount) or nodeConfig.expectedCount < 1 then
    fail("nodes.expectedCount must be a positive integer")
  end
  if not isInteger(nodeConfig.maxParallelPerNode) or nodeConfig.maxParallelPerNode < 1 then
    fail("nodes.maxParallelPerNode must be a positive integer")
  end

  if type(config.fluids) ~= "table" or #config.fluids ~= 19 then
    fail("config.fluids must contain exactly 19 entries")
  end
  baselineFieldStrength = 0
  for index, entry in ipairs(config.fluids) do
    if type(entry.source) ~= "string" or entry.source == "" then
      fail("fluids[" .. index .. "].source is missing")
    end
    if type(entry.condensate) ~= "string" or entry.condensate:sub(1, 10) ~= "entangled_" then
      fail("fluids[" .. index .. "].condensate must be an entangled_* fluid name")
    end
    if not isInteger(entry.target) or entry.target < 0 then
      fail("fluids[" .. index .. "].target must be a non-negative integer")
    end
    if not isInteger(entry.unit) or entry.unit < 1 then
      fail("fluids[" .. index .. "].unit must be a positive integer")
    end
    if entry.target % entry.unit ~= 0 then
      fail("fluids[" .. index .. "].target must be divisible by its generator recipe unit")
    end
    if refill.enabled and (type(entry.rateLitersPerSecond) ~= "number"
        or entry.rateLitersPerSecond < 0.001
        or entry.rateLitersPerSecond > 2147483) then
      fail("fluids[" .. index .. "].rateLitersPerSecond must be between 0.001 and 2147483 L/s")
    end
    if fluidBySource[entry.source] then fail("duplicate source fluid " .. entry.source) end
    if targetByCondensate[entry.condensate] then fail("duplicate condensate " .. entry.condensate) end
    fluidBySource[entry.source] = entry.condensate
    targetByCondensate[entry.condensate] = entry.target
    baselineFieldStrength = baselineFieldStrength + entry.target
  end
  if baselineFieldStrength == 0 and not ((config.safety or {}).allowZeroTargetStock) then
    fail("all 19 fluid targets are zero; configure the production baseline before check/run")
  end
  baselineFieldStrength = math.max(1, baselineFieldStrength)
  refillFieldStrengthFloor = baselineFieldStrength

  if refill.enabled then
    local loaded, routes = pcall(require, refill.routeModule)
    if not loaded then fail("cannot load " .. refill.routeModule .. ".lua: " .. tostring(routes)) end
    if type(routes) ~= "table" or routes.schemaVersion ~= 2 or routes.complete ~= true then
      fail(refill.routeModule .. ".lua must be a complete schemaVersion 2 route map")
    end
    if routes.cacheInterfaceAddress ~= refill.cacheInterfaceAddress then
      fail("refill route map cacheInterfaceAddress does not match refill configuration")
    end
    if routes.referenceInterfaceAddress ~= config.cacheInterfaceAddress then
      fail("refill route map referenceInterfaceAddress does not match the material-cache interface")
    end
    if type(routes.unusedOutput) ~= "table" then
      fail("refill route map is missing unusedOutput")
    end
    if refill.installedRouteAddresses then
      local installed = {}
      for _, address in ipairs(refill.installedRouteAddresses) do installed[address] = true end
      if not installed[routes.unusedOutput.address] then
        fail("refill route map uses an old/unknown I/O; rerun bec_route_mapper.lua")
      end
      for _, entry in ipairs(config.fluids) do
        local route = (routes.fluids or {})[entry.source]
        if type(route) == "table" and not installed[route.address] then
          fail("refill route map for " .. entry.source
            .. " uses an old/unknown I/O; rerun bec_route_mapper.lua")
        end
      end
    end
    for _, entry in ipairs(config.fluids) do
      if type((routes.fluids or {})[entry.source]) ~= "table" then
        fail("refill route map is missing " .. entry.source)
      end
    end
    routeConfig = routes
  end

  local timings = config.timings or {}
  for _, name in ipairs({
    "poll", "orderSettle", "emptySettle", "filterVerifyDelay", "nodeTransferPulse",
    "orderFluidTransferPulse", "nodeStartGrace", "condensateWaitTimeout", "orderRunTimeout",
    "statusInterval", "cooldown",
  }) do
    if type(timings[name]) ~= "number" or timings[name] < 0 then
      fail("timings." .. name .. " must be a non-negative number")
    end
  end
  if timings.nodeTransferPulse <= 0 then
    fail("timings.nodeTransferPulse must be greater than zero")
  end
end

local function bindComponents()
  storage = bindOne("bec_storage", config.storageAddress, "BEC containment field", {
    "getFieldStrength", "setFieldStrength", "getStoredCondensate",
  })
  gate = bindOne("bec_diode", config.gateAddress, "BEC Maxwell gate", {
    "getCondensateFilterCount", "getCondensateFilterAt", "setCondensateFilters",
    "setWorkAllowed", "isWorkAllowed",
  })
  cache = bindOne(config.cacheInterfaceType, config.cacheInterfaceAddress, "material-cache interface", {
    "getItemsInNetwork", "getFluidsInNetwork",
  })
  itemCache = bindOne(config.buffers.interfaceType, config.buffers.itemInterfaceAddress, "item-cache interface", {
    "getItemsInNetwork",
  })
  fluidCache = bindOne(config.buffers.interfaceType, config.buffers.fluidInterfaceAddress, "fluid-cache interface", {
    "getFluidsInNetwork",
  })
  local cacheAddresses = {}
  for _, entry in ipairs({
    { address = cache.address, label = "material-cache interface" },
    { address = itemCache.address, label = "item-cache interface" },
    { address = fluidCache.address, label = "fluid-cache interface" },
  }) do
    if cacheAddresses[entry.address] then
      fail(entry.label .. " cannot be identical to " .. cacheAddresses[entry.address])
    end
    cacheAddresses[entry.address] = entry.label
  end
  nodeRedstone = bindOne("redstone", config.redstone.nodeAddress, "node-bus redstone I/O", {
    "getOutput", "setOutput",
  })
  generatorRedstone = bindOne("redstone", config.redstone.generatorAddress, "order-fluid transfer redstone I/O", {
    "getOutput", "setOutput",
  })
  synthesisRedstone = bindOne("redstone", config.redstone.synthesisAddress, "synthesis-active redstone I/O", {
    "getOutput", "setOutput",
  })
  haltRedstone = bindOne("redstone", config.redstone.haltAddress, "HALT redstone I/O", {
    "getOutput", "setOutput",
  })
  local fixedOutputs = {}
  for _, output in ipairs({
    { address = nodeRedstone.address, label = "material/item-cache output" },
    { address = generatorRedstone.address, label = "material/fluid-cache output" },
    { address = synthesisRedstone.address, label = "synthesis-active output" },
    { address = haltRedstone.address, label = "HALT output" },
  }) do
    if fixedOutputs[output.address] then fail(output.label .. " overlaps " .. fixedOutputs[output.address]) end
    fixedOutputs[output.address] = output.label
  end

  if (config.refill or {}).enabled then
    local refill = config.refill
    refillCache = bindOne(refill.cacheInterfaceType, refill.cacheInterfaceAddress, "automatic-refill interface", {
      "getFluidsInNetwork",
    })
    if cacheAddresses[refillCache.address] then
      fail("automatic-refill interface cannot be identical to " .. cacheAddresses[refillCache.address])
    end
    refillLinkRedstone = bindOne("redstone", refill.entanglerAddress, "automatic-refill/entangler redstone I/O", {
      "getOutput", "setOutput",
    })
    refillActivityRedstone = bindOne("redstone", refill.activityAddress, "entangler activity redstone I/O", {
      "getInput",
    })

    local usedOutputs = {}
    local usedDevices = {}
    local routeDevices = {}
    local function claimDevice(address, label)
      if usedDevices[address] then fail(label .. " overlaps " .. usedDevices[address]) end
      usedDevices[address] = label
    end
    local function claimOutput(address, side, label)
      if usedDevices[address] then fail(label .. " overlaps " .. usedDevices[address]) end
      local key = address .. ":" .. side
      if usedOutputs[key] then fail(label .. " overlaps " .. usedOutputs[key]) end
      usedOutputs[key] = label
    end
    claimDevice(nodeRedstone.address, "material/item-cache output")
    claimDevice(generatorRedstone.address, "material/fluid-cache output")
    claimDevice(synthesisRedstone.address, "synthesis-active output")
    claimDevice(haltRedstone.address, "HALT output")
    claimDevice(refillLinkRedstone.address, "automatic-refill/entangler toggle bus")
    local function bindRouteOutput(definition, label)
      if type(definition.address) ~= "string"
          or not isInteger(definition.side)
          or definition.side > 5 then
        fail(label .. " has an invalid redstone address or side")
      end
      local device = bindOne("redstone", definition.address, label, { "getOutput", "setOutput" })
      claimOutput(device.address, definition.side, label)
      routeDevices[device.address] = true
      return {
        address = device.address,
        device = device,
        side = definition.side,
        sideName = definition.sideName or tostring(definition.side),
      }
    end

    for _, entry in ipairs(config.fluids) do
      refillRoutes[entry.source] = bindRouteOutput(
        routeConfig.fluids[entry.source],
        "refill route for " .. entry.source
      )
    end
    if usedDevices[refillActivityRedstone.address] or routeDevices[refillActivityRedstone.address] then
      fail("entangler activity input overlaps an output on " .. refillActivityRedstone.address)
    end
  end

  local nodeConfig = config.nodes or {}
  local configured = nodeConfig.addresses or {}
  local addresses = {}
  if #configured > 0 then
    for index, prefix in ipairs(configured) do
      addresses[index] = resolveAddress("bec_io_node", prefix, "BEC I/O node " .. index)
    end
  else
    for address in component.list("bec_io_node", true) do addresses[#addresses + 1] = address end
    table.sort(addresses)
  end
  if #addresses ~= nodeConfig.expectedCount then
    fail(string.format("expected %d bec_io_node components, found %d", nodeConfig.expectedCount, #addresses))
  end

  local seen = {}
  for index, address in ipairs(addresses) do
    if seen[address] then fail("duplicate BEC I/O node address " .. address) end
    seen[address] = true
    nodes[index] = bindAddress(address, "bec_io_node", "BEC I/O node " .. index, {
      "getState", "getParallelRecipesInProgress", "getMaxParallel",
      "getRequiredCondensate", "getConsumedCondensate",
      "setMaxParallel", "setWorkAllowed", "isWorkAllowed",
    })
  end

  local filterCount = tonumber(checked("get filter count", gate.getCondensateFilterCount)) or 0
  if filterCount < #config.fluids then
    fail(string.format("Maxwell gate has %d filter slots, but %d fluids are configured", filterCount, #config.fluids))
  end
end

local function setSignalOutput(device, side, label, connected, signalConfig)
  local value = connected and signalConfig.connectSignal or signalConfig.disconnectSignal
  if side ~= nil then
    checked("set " .. label .. " redstone output", device.setOutput, side, value)
    local actual = tonumber(checked("read " .. label .. " redstone output", device.getOutput, side))
    if actual ~= value then
      fail(string.format("%s redstone output verification failed on side %d: expected=%d actual=%s", label, side, value, tostring(actual)))
    end
  else
    local values = {}
    for face = 0, 5 do values[face] = value end
    checked("set " .. label .. " all-face redstone output", device.setOutput, values)
    local actual = checked("read " .. label .. " all-face redstone output", device.getOutput)
    if type(actual) ~= "table" then fail(label .. " getOutput did not return a side table") end
    for face = 0, 5 do
      if tonumber(actual[face]) ~= value then
        fail(string.format("%s redstone output verification failed on side %d: expected=%d actual=%s", label, face, value, tostring(actual[face])))
      end
    end
  end
end

local function setToggle(device, side, label, connected)
  setSignalOutput(device, side, label, connected, config.redstone)
end

local function setNodeNetwork(connected)
  setToggle(nodeRedstone, nil, "material/item-cache output", connected)
  uiUpdate({ nodeConnected = connected })
  log("INFO", "material/item-cache output " .. (connected and "enabled" or "disabled"))
end

local function setOrderFluidTransfer(connected)
  setToggle(generatorRedstone, nil, "material/fluid-cache output", connected)
  uiUpdate({ fluidConnected = connected })
  log("INFO", "material/fluid-cache output " .. (connected and "enabled" or "disabled"))
end

local function setSynthesisActive(active)
  setToggle(synthesisRedstone, nil, "synthesis-active", active)
  uiUpdate({ synthesisActive = active })
  log("INFO", "synthesis-active redstone output " .. (active and "enabled" or "disabled"))
end

local function setHaltOutput(active)
  if active then haltInterlockActive = true end
  setToggle(haltRedstone, nil, "HALT", active)
  if not active then haltInterlockActive = false end
  uiUpdate({ haltActive = active })
  log("INFO", "HALT redstone output " .. (active and "enabled" or "disabled"))
end

local function setRefillSource(route, source, connected)
  setSignalOutput(route.device, route.side, "refill source " .. source, connected, config.refill)
end

local function setRefillLink(connected)
  if not refillLinkRedstone then return end
  setSignalOutput(
    refillLinkRedstone,
    nil,
    "automatic-refill/entangler",
    connected,
    config.refill
  )
  uiUpdate({ refillConnected = connected })
end

local function readEntanglerActivity()
  if not refillActivityRedstone then return false, 0 end
  local inputs = checked("read entangler activity input", refillActivityRedstone.getInput)
  if type(inputs) ~= "table" then fail("entangler activity input did not return a side table") end
  local signal = 0
  for face = 0, 5 do signal = math.max(signal, tonumber(inputs[face]) or 0) end
  local active = signal >= config.refill.activityThreshold
  uiUpdate({ entanglerActive = active, entanglerSignal = signal })
  return active, signal
end

local function setAllRefillSourcesOff()
  for _, entry in ipairs(config.fluids) do
    setRefillSource(refillRoutes[entry.source], entry.source, false)
  end
end

local function setMachinesAllowed(allowed)
  checked("set Maxwell gate work state", gate.setWorkAllowed, allowed)
  local gateActual = checked("read Maxwell gate work state", gate.isWorkAllowed)
  if gateActual ~= allowed then fail("Maxwell gate work-state verification failed") end
  for index, node in ipairs(nodes) do
    checked("set node " .. index .. " work state", node.setWorkAllowed, allowed)
    local actual = checked("read node " .. index .. " work state", node.isWorkAllowed)
    if actual ~= allowed then fail("node " .. index .. " work-state verification failed") end
  end
end

local function getStoredCondensate()
  local raw = checked("getStoredCondensate", storage.getStoredCondensate)
  if type(raw) ~= "table" then fail("getStoredCondensate returned " .. type(raw)) end
  local result = {}
  local total = 0
  for fluid, amount in pairs(raw) do
    local number = tonumber(amount)
    if type(fluid) == "string" and number and number > 0 then
      result[fluid] = number
      total = total + number
    end
  end
  uiUpdate({ condensates = result, storedTotal = total })
  return result
end

local function sumValues(values)
  local total = 0
  for _, amount in pairs(values) do total = total + amount end
  return total
end

local function setSafeIdleFieldStrength(stored, label)
  stored = stored or getStoredCondensate()
  refillFieldStrengthFloor = math.max(refillFieldStrengthFloor, sumValues(stored))
  local strength = math.max(baselineFieldStrength, refillFieldStrengthFloor)
  checked(label or "set safe idle field strength", storage.setFieldStrength, strength)
  uiUpdate({ fieldStrength = strength })
  return strength
end

local function assertBaselineIsSafe(stored)
  local currentTotal = sumValues(stored)
  if baselineFieldStrength < currentTotal
      and not ((config.safety or {}).allowFieldStrengthBelowCurrentStock) then
    if (config.refill or {}).enabled then
      log("WARN", string.format(
        "condensate stock %s exceeds configured baseline %s; preserving the higher safe field strength",
        formatInteger(currentTotal),
        formatInteger(baselineFieldStrength)
      ))
    else
      fail(string.format(
        "configured baseline field strength %s is below current condensate stock %s; "
          .. "set all 19 targets correctly before running",
        formatInteger(baselineFieldStrength),
        formatInteger(currentTotal)
      ))
    end
  end
  return currentTotal
end

local function readNetwork()
  local rawItems = checked("getItemsInNetwork", cache.getItemsInNetwork)
  local rawFluids = checked("getFluidsInNetwork", cache.getFluidsInNetwork)
  if type(rawItems) ~= "table" or type(rawFluids) ~= "table" then
    fail("material-cache interface returned invalid item or fluid data")
  end

  local items = {}
  local fluids = {}
  local itemTotal = 0
  local fluidTotal = 0
  local signatureParts = {}
  local fluidSignatureParts = {}

  for _, stack in pairs(rawItems) do
    local amount = type(stack) == "table" and tonumber(stack.size) or 0
    if amount and amount > 0 then
      local item = {
        name = tostring(stack.name or ""),
        damage = tonumber(stack.damage) or 0,
        size = amount,
      }
      if item.name == "" then fail("order cache contains an item without a registry name") end
      items[#items + 1] = item
      itemTotal = itemTotal + amount
      signatureParts[#signatureParts + 1] = string.format("I:%s:%s:%s", item.name, item.damage, formatInteger(amount))
    end
  end
  for _, stack in pairs(rawFluids) do
    local amount = type(stack) == "table" and tonumber(stack.amount) or 0
    if amount and amount > 0 then
      local fluid = { name = tostring(stack.name or ""), amount = amount }
      if fluid.name == "" then fail("order cache contains a fluid without a registry name") end
      fluids[#fluids + 1] = fluid
      fluidTotal = fluidTotal + amount
      local signaturePart = "F:" .. fluid.name .. ":" .. formatInteger(amount)
      signatureParts[#signatureParts + 1] = signaturePart
      fluidSignatureParts[#fluidSignatureParts + 1] = signaturePart
    end
  end
  table.sort(signatureParts)
  table.sort(fluidSignatureParts)
  local snapshot = {
    items = items,
    fluids = fluids,
    itemTotal = itemTotal,
    fluidTotal = fluidTotal,
    signature = table.concat(signatureParts, "|"),
    fluidSignature = table.concat(fluidSignatureParts, "|"),
  }
  uiUpdate({
    cacheItemTotal = snapshot.itemTotal,
    cacheFluidTotal = snapshot.fluidTotal,
  })
  return snapshot
end

local function readItemCacheTotal()
  local raw = checked("get item-cache items", itemCache.getItemsInNetwork)
  if type(raw) ~= "table" then fail("item-cache interface returned invalid item data") end
  local total = 0
  for _, stack in pairs(raw) do
    local amount = type(stack) == "table" and tonumber(stack.size) or 0
    if amount and amount > 0 then total = total + amount end
  end
  uiUpdate({ itemCacheTotal = total, orderRemainingItemTotal = total })
  return total
end

local function readFluidCacheFluids()
  local raw = checked("get fluid-cache fluids", fluidCache.getFluidsInNetwork)
  if type(raw) ~= "table" then fail("fluid-cache interface returned invalid fluid data") end
  local fluids = {}
  local total = 0
  for _, stack in pairs(raw) do
    local name = type(stack) == "table" and tostring(stack.name or "") or ""
    local amount = type(stack) == "table" and tonumber(stack.amount) or 0
    if name ~= "" and amount and amount > 0 then
      fluids[name] = (fluids[name] or 0) + amount
      total = total + amount
    end
  end
  uiUpdate({ fluidCacheTotal = total })
  return fluids, total
end

local function readFluidCacheTotal()
  local _, total = readFluidCacheFluids()
  return total
end

local function hasCompleteOrder(snapshot)
  return #snapshot.items > 0 and #snapshot.fluids > 0
end

local function hasAnyOrderInput(snapshot)
  return snapshot.itemTotal > 0 or snapshot.fluidTotal > 0
end

local function pulseNodeOrderTransfer(fingerprint, expectedItemTotal)
  log("INFO", string.format(
    "pulsing material/item-cache output for %.2fs: fingerprint=%s items=%s",
    config.timings.nodeTransferPulse,
    fingerprint,
    formatInteger(expectedItemTotal)
  ))
  local ok, reason = xpcall(function()
    setNodeNetwork(true)
    os.sleep(config.timings.nodeTransferPulse)
  end, debug.traceback)
  local offOk, offReason = pcall(setNodeNetwork, false)
  if not offOk then
    fail("cannot disable material/item-cache output: " .. tostring(offReason)
      .. (ok and "" or "; original error: " .. tostring(reason)))
  end
  if not ok then error(reason, 0) end
  log("INFO", "material/item-cache pulse complete; whole-batch output command sent")
end

local function transferOrderFluidsToBuffer(reason, amount)
  if amount <= 0 then return end
  log("INFO", string.format(
    "pulsing material/fluid-cache output for %.2fs: reason=%s amount=%s",
    config.timings.orderFluidTransferPulse,
    reason,
    formatInteger(amount)
  ))
  local ok, result = xpcall(function()
    setOrderFluidTransfer(true)
    os.sleep(config.timings.orderFluidTransferPulse)
  end, debug.traceback)
  local offOk, offReason = pcall(setOrderFluidTransfer, false)
  if not offOk then
    fail("cannot disable material/fluid-cache output: " .. tostring(offReason)
      .. (ok and "" or "; original error: " .. tostring(result)))
  end
  if not ok then error(result, 0) end
  log("INFO", "material/fluid-cache pulse complete; whole-batch output command sent")
end

local function readRefillFluids()
  local raw = checked("get automatic-refill fluids", refillCache.getFluidsInNetwork)
  if type(raw) ~= "table" then fail("automatic-refill interface returned invalid fluid data") end
  local fluids = {}
  local total = 0
  for _, stack in pairs(raw) do
    local name = type(stack) == "table" and tostring(stack.name or "") or ""
    local amount = type(stack) == "table" and tonumber(stack.amount) or 0
    if name ~= "" and amount and amount > 0 then
      fluids[name] = (fluids[name] or 0) + amount
      total = total + amount
    end
  end
  uiUpdate({ refillStagedTotal = total })
  return fluids
end

local crc32Table = {}
for value = 0, 255 do
  local crc = value
  for _ = 1, 8 do
    if (crc & 1) == 1 then crc = (crc >> 1) ~ 0xEDB88320 else crc = crc >> 1 end
  end
  crc32Table[value] = crc
end

local function crc32(values)
  local crc = 0xFFFFFFFF
  for _, value in ipairs(values) do
    for index = 1, #value do
      local byte = string.byte(value, index)
      crc = (crc >> 8) ~ crc32Table[(crc & 0xFF) ~ byte]
    end
  end
  return string.format("%08x", ~crc & 0xFFFFFFFF)
end

local function identifyOrder(items)
  if #items == 0 then fail("cannot calculate order count without item inputs") end
  local identities = {}
  local inputDetails = {}
  local minimum = math.huge
  for _, stack in ipairs(items) do
    local identity = stack.name .. tostring(stack.damage)
    identities[#identities + 1] = identity
    inputDetails[#inputDetails + 1] = {
      identity = identity,
      size = stack.size,
    }
    minimum = math.min(minimum, stack.size)
  end
  table.sort(identities)

  local aliases = (config.orderCounting or {}).itemAliases or {}
  for index, identity in ipairs(identities) do
    identities[index] = aliases[identity] or identity
  end
  local fingerprint = crc32(identities)
  return fingerprint, minimum, inputDetails, aliases
end

local function getOrderCount(items)
  local fingerprint, minimum, inputDetails, aliases = identifyOrder(items)
  local counting = config.orderCounting or {}
  local divisor = (counting.recipeDivisors or {})[fingerprint]
  if divisor == nil then
    divisor = counting.fallbackDivisor
    if not isInteger(divisor) or divisor < 1 then
      fail("unknown recipe fingerprint " .. fingerprint .. " and no valid fallbackDivisor is configured")
    end
    log("WARN", "unknown recipe fingerprint " .. fingerprint .. "; using fallback divisor " .. divisor)
    table.sort(inputDetails, function(left, right) return left.identity < right.identity end)
    local parts = {}
    for _, detail in ipairs(inputDetails) do
      local normalized = aliases[detail.identity] or detail.identity
      parts[#parts + 1] = string.format(
        "%s=%s->%s",
        detail.identity,
        formatInteger(detail.size),
        normalized
      )
    end
    log("WARN", string.format(
      "unknown recipe inputs: min-stack=%s; %s",
      formatInteger(minimum),
      table.concat(parts, ",")
    ))
  end
  if not isInteger(divisor) or divisor < 1 then fail("invalid divisor for recipe " .. fingerprint) end

  local count = math.ceil(minimum / divisor)
  if count < 1 then fail("calculated order count is zero") end
  return count, fingerprint, divisor
end

local function getRequiredCondensate(fluids)
  local required = {}
  for _, stack in ipairs(fluids) do
    local condensate = fluidBySource[stack.name]
    if not condensate then fail("unknown order fluid: " .. stack.name) end
    required[condensate] = (required[condensate] or 0) + stack.amount
  end
  return required
end

local function appendOrderFluids(snapshot, additions)
  local amounts = {}
  for _, stack in ipairs(snapshot.fluids or {}) do
    amounts[stack.name] = (amounts[stack.name] or 0) + stack.amount
  end
  for _, stack in ipairs(additions or {}) do
    amounts[stack.name] = (amounts[stack.name] or 0) + stack.amount
  end

  local merged = {}
  local total = 0
  for name, amount in pairs(amounts) do
    merged[#merged + 1] = { name = name, amount = amount }
    total = total + amount
  end
  table.sort(merged, function(left, right) return left.name < right.name end)
  snapshot.fluids = merged
  snapshot.fluidTotal = total
end

local function getDeficits(required, stored)
  local deficits = {}
  for fluid, amount in pairs(required) do
    local missing = amount - (stored[fluid] or 0)
    if missing > 0 then deficits[fluid] = missing end
  end
  return deficits
end

local function deficitText(deficits)
  local parts = {}
  for fluid, amount in pairs(deficits) do parts[#parts + 1] = fluid .. "=" .. formatInteger(amount) end
  table.sort(parts)
  return #parts > 0 and table.concat(parts, ", ") or "none"
end

local function assertBaselineStockPresent(stored)
  if not ((config.safety or {}).requireConfiguredStockAtStartup) then return end
  local deficits = getDeficits(targetByCondensate, stored)
  if next(deficits) then
    fail("configured baseline stock must be prefilled before startup: " .. deficitText(deficits))
  end
end

local function reportBaselineStock()
  local stored = getStoredCondensate()
  local deficits = getDeficits(targetByCondensate, stored)
  if next(deficits) then
    log("WARN", "configured baseline stock is not yet present: " .. deficitText(deficits))
  else
    log("INFO", "configured baseline stock is present")
  end
end

local function saveFluidSettings(entries)
  local path = config.ui.fluidSettingsFile
  local data = { schemaVersion = 3, fluids = {} }
  for _, entry in ipairs(entries) do
    data.fluids[entry.source] = {
      target = entry.target,
      rateLitersPerSecond = entry.rateLitersPerSecond,
    }
  end
  local temp = path .. ".new"
  local file, reason = io.open(temp, "w")
  if not file then fail("cannot write fluid settings: " .. tostring(reason)) end
  local wrote, writeReason = file:write(serialization.serialize(data))
  if not wrote then
    pcall(file.close, file)
    fail("cannot write fluid settings: " .. tostring(writeReason))
  end
  local flushed, flushReason = file:flush()
  if not flushed then
    pcall(file.close, file)
    fail("cannot flush fluid settings: " .. tostring(flushReason))
  end
  local closed, closeReason = pcall(file.close, file)
  if not closed then fail("cannot close fluid settings: " .. tostring(closeReason)) end

  local backup
  if filesystem.exists(path) then
    local index = 1
    repeat
      backup = path .. ".bak" .. index
      index = index + 1
    until not filesystem.exists(backup)
    local moved, moveReason = filesystem.rename(path, backup)
    if not moved then fail("cannot back up fluid settings: " .. tostring(moveReason)) end
  end
  local installed, installReason = filesystem.rename(temp, path)
  if not installed then
    if backup then
      local restored, restoreReason = filesystem.rename(backup, path)
      if not restored then
        fail("cannot install fluid settings: " .. tostring(installReason)
          .. "; previous settings remain at " .. backup
          .. " (restore failed: " .. tostring(restoreReason) .. ")")
      end
    end
    fail("cannot install fluid settings: " .. tostring(installReason))
  end
end

local function applyFluidSettings(entries)
  if type(entries) ~= "table" or #entries ~= #config.fluids then
    fail("fluid settings must contain all configured fluids")
  end
  local nextBaseline = 0
  for index, entry in ipairs(entries) do
    local original = config.fluids[index]
    if entry.source ~= original.source or entry.condensate ~= original.condensate
        or entry.unit ~= original.unit
        or not isInteger(entry.target) or entry.target > 1000000 * 1024 * 1024
        or entry.target % entry.unit ~= 0
        or type(entry.rateLitersPerSecond) ~= "number"
        or entry.rateLitersPerSecond < 0.001
        or entry.rateLitersPerSecond > 2147483 then
      fail("invalid fluid settings for " .. original.source)
    end
    nextBaseline = nextBaseline + entry.target
  end
  if nextBaseline == 0 then fail("at least one fluid target must be positive") end

  local currentStrength = tonumber(checked("read field strength", storage.getFieldStrength))
  if not currentStrength then fail("BEC storage returned invalid field strength") end
  local safeStrength = math.max(currentStrength, refillFieldStrengthFloor,
    nextBaseline, sumValues(getStoredCondensate()))
  if safeStrength > currentStrength then
    checked("raise field strength for fluid settings", storage.setFieldStrength, safeStrength)
    local actual = tonumber(checked("verify field strength", storage.getFieldStrength))
    if not actual or actual < safeStrength then fail("BEC field strength did not increase") end
  end
  saveFluidSettings(entries)
  for index, entry in ipairs(entries) do
    config.fluids[index].target = entry.target
    config.fluids[index].rateLitersPerSecond = entry.rateLitersPerSecond
    targetByCondensate[entry.condensate] = entry.target
  end
  baselineFieldStrength = nextBaseline
  refillFieldStrengthFloor = math.max(refillFieldStrengthFloor, safeStrength)
  uiUpdate({ fieldStrength = safeStrength }, true)
  log("INFO", "fluid cache targets and refill rates saved")
end

local function stageRefillFluid(entry, requiredAmount, options)
  options = options or {}
  local refill = config.refill
  local route = refillRoutes[entry.source]
  local interruptForOrder = options.interruptForOrder ~= false
  uiPhase(
    options.phase or "STAGING",
    (options.detailPrefix or "Loading ") .. entry.source
  )
  local target = math.ceil(requiredAmount / entry.unit) * entry.unit
  local current = readRefillFluids()[entry.source] or 0
  if current >= target then return "ready", current end

  local estimatedSeconds = (target - current) / (entry.rateLitersPerSecond * 1000)
  log("INFO", string.format(
    "staging refill fluid %s: current=%s target=%s rate=%.3f L/s estimated-time=%.1fs",
    entry.source,
    formatInteger(current),
    formatInteger(target),
    entry.rateLitersPerSecond,
    estimatedSeconds
  ))
  local lastIncrease = now()
  local lastAmount = current
  local lastStatus = -math.huge
  dashboardPaused = true
  local ok, state, observed = xpcall(function()
    setRefillSource(route, entry.source, true)
    while true do
      if interruptForOrder and hasAnyOrderInput(readNetwork()) then
        return "order", readRefillFluids()[entry.source] or 0
      end
      current = readRefillFluids()[entry.source] or 0
      if current >= target then return "ready", current end
      local timestamp = now()
      if current > lastAmount then
        lastAmount = current
        lastIncrease = timestamp
      end
      if timestamp - lastIncrease >= refill.routeTimeout then
        log("WARN", string.format(
          "refill source %s produced no cache increase within %.1fs; current=%s target=%s",
          entry.source,
          refill.routeTimeout,
          formatInteger(current),
          formatInteger(target)
        ))
        return "stalled", current
      end
      if timestamp - lastStatus >= config.timings.statusInterval then
        log("INFO", string.format(
          "refill source %s ON: current=%s target=%s rate=%.3f L/s",
          entry.source,
          formatInteger(current),
          formatInteger(target),
          entry.rateLitersPerSecond
        ))
        lastStatus = timestamp
      end
      os.sleep(refill.poll)
    end
  end, debug.traceback)
  local offOk, offReason = pcall(setRefillSource, route, entry.source, false)
  dashboardPaused = false
  uiUpdate({}, true)
  if not offOk then
    fail("cannot switch refill source off: " .. tostring(offReason)
      .. (ok and "" or "; original error: " .. tostring(state)))
  end
  if not ok then fail(state) end
  if state == "order" or state == "stalled" then return state, observed end
  current = observed
  log("INFO", string.format(
    "staged refill fluid %s=%s mB%s",
    entry.source,
    formatInteger(current),
    current > target and " (transfer overshoot retained in staging cache)" or ""
  ))
  return "ready", current
end

local function stopRefillDrainBestEffort()
  local errors = {}
  local ok, reason = pcall(setRefillLink, false)
  if not ok then errors[#errors + 1] = tostring(reason) end
  return #errors == 0, table.concat(errors, "; ")
end

local function drainRefillBatch(requiredCondensate, options)
  options = options or {}
  local refill = config.refill
  local targets = requiredCondensate or targetByCondensate
  local interruptForOrder = options.interruptForOrder ~= false
  local initialStored = getStoredCondensate()
  local initialDeficits = getDeficits(targets, initialStored)
  if not next(initialDeficits) then return "ready", initialStored end

  uiPhase(options.phase or "REFILL", options.detail or "Converting staged fluids")
  local logPrefix = options.logPrefix or "automatic refill"
  log("INFO", logPrefix .. " connecting staged fluids to entangler: "
    .. deficitText(initialDeficits))
  local stagedFluids = readRefillFluids()
  local refillStrength = math.max(
    baselineFieldStrength,
    sumValues(initialStored) + sumValues(stagedFluids)
  )
  refillFieldStrengthFloor = math.max(refillFieldStrengthFloor, refillStrength)
  checked("raise field strength for automatic refill", storage.setFieldStrength, refillStrength)
  uiUpdate({ fieldStrength = refillStrength })
  log("INFO", "automatic-refill field strength=" .. formatInteger(refillStrength))
  local linkOk, linkReason = pcall(setRefillLink, true)
  if not linkOk then fail(linkReason) end

  local lastActivity = now()
  local lastTotal = sumValues(initialStored)
  local lastStatus = -math.huge
  local previousEntanglerActive
  local ok, state, finalStored = xpcall(function()
    while true do
      if interruptForOrder and hasAnyOrderInput(readNetwork()) then
        return "order", getStoredCondensate()
      end
      local stored = getStoredCondensate()
      local deficits = getDeficits(targets, stored)
      if not next(deficits) then return "ready", stored end

      local total = sumValues(stored)
      if total > lastTotal then
        lastTotal = total
        lastActivity = now()
      end

      local entanglerActive, activitySignal = readEntanglerActivity()
      if entanglerActive then lastActivity = now() end
      if entanglerActive ~= previousEntanglerActive then
        log("INFO", string.format(
          "entangler activity=%s signal=%s",
          entanglerActive and "running" or "idle",
          tostring(activitySignal)
        ))
        previousEntanglerActive = entanglerActive
      end

      local staged = readRefillFluids()
      local processable = false
      for _, entry in ipairs(config.fluids) do
        if (staged[entry.source] or 0) >= entry.unit then
          processable = true
          break
        end
      end
      if not entanglerActive
          and not processable
          and now() - lastActivity >= refill.drainedWaitTimeout then
        return "depleted", stored
      end
      if not entanglerActive and now() - lastActivity > refill.conversionTimeout then
        fail("entangler inactive without condensate progress: " .. deficitText(deficits))
      end
      if now() - lastStatus >= config.timings.statusInterval then
        log("INFO", logPrefix .. " converting: " .. deficitText(deficits)
          .. "; staged-total=" .. formatInteger(sumValues(staged))
          .. "; entangler=" .. (entanglerActive and "running" or "idle")
          .. "; signal=" .. tostring(activitySignal))
        lastStatus = now()
      end
      os.sleep(refill.poll)
    end
  end, debug.traceback)

  local offOk, offReason = stopRefillDrainBestEffort()
  if not offOk then
    fail("cannot disconnect automatic-refill path: " .. offReason
      .. (ok and "" or "; original error: " .. tostring(state)))
  end
  if not ok then fail(state) end
  return state, finalStored
end

local function replenishIdleStock(initialStored)
  if not ((config.refill or {}).enabled) then return true end
  local stored = initialStored or getStoredCondensate()
  local deficits = getDeficits(targetByCondensate, stored)
  if not next(deficits) then return true end

  uiPhase("REFILL", "Building configured condensate stock")
  log("INFO", "idle stock refill started: " .. deficitText(deficits))
  while next(deficits) do
    local beforeTotal = sumValues(stored)
    local stagedTargets = {}
    for _, entry in ipairs(config.fluids) do
      local missing = entry.target - (stored[entry.condensate] or 0)
      if missing > 0 then
        if hasAnyOrderInput(readNetwork()) then
          log("INFO", "idle stock refill paused for incoming order")
          return false
        end

        local stageState = stageRefillFluid(entry, missing)
        if stageState == "order" then
          log("INFO", "idle stock refill paused while staging for incoming order")
          return false
        elseif stageState == "ready" then
          stagedTargets[entry.condensate] = entry.target
        end
      end
    end

    if not next(stagedTargets) then
      uiPhase("WAITING", "Refill sources did not deliver fluid; retrying later")
      return false
    end
    local drainState, finalStored = drainRefillBatch(stagedTargets)
    if drainState == "order" then
      log("INFO", "idle stock refill paused while converting for incoming order")
      return false
    end
    stored = finalStored or getStoredCondensate()
    if sumValues(stored) <= beforeTotal then
      fail("automatic refill made no condensate progress; remaining="
        .. deficitText(getDeficits(targetByCondensate, stored)))
    end
    deficits = getDeficits(targetByCondensate, stored)
  end
  log("INFO", "idle stock refill complete")
  reportBaselineStock()
  return true
end

local function waitForStableOrder()
  local stableSignature
  local stableSince
  local lastFieldCheck = -math.huge
  local nextRefillCheck = 0
  local waitingForEntanglerStop = false
  local entanglerIdleSince
  uiUpdate({ phase = "WAITING", detail = "Waiting for a stable order", order = false })
  log("INFO", "waiting for a stable order in the material-cache subnet")

  while true do
    local snapshot = readNetwork()
    if dashboard and dashboard:hasConfigRequest() and not hasAnyOrderInput(snapshot) then
      local buffered = readFluidCacheTotal()
      local entanglerActive = readEntanglerActivity()
      if buffered == 0 and not entanglerActive and dashboard:takeConfigRequest() then
        local shown, values = pcall(dashboard.editFluidSettings, dashboard)
        if not shown then
          log("ERROR", "fluid config screen failed: " .. tostring(values))
        elseif values then
          local saved, reason = pcall(applyFluidSettings, values)
          if not saved then log("ERROR", "fluid config was not saved: " .. tostring(reason)) end
        end
        stableSignature = nil
        stableSince = nil
        nextRefillCheck = 0
        snapshot = readNetwork()
      end
    end
    if hasCompleteOrder(snapshot) then
      if snapshot.signature ~= stableSignature then
        stableSignature = snapshot.signature
        stableSince = now()
      elseif now() - stableSince >= config.timings.orderSettle then
        return snapshot
      end
    else
      stableSignature = nil
      stableSince = nil
    end

    if (config.refill or {}).enabled and not hasAnyOrderInput(snapshot) then
      if now() >= nextRefillCheck then
        local stored = getStoredCondensate()
        local deficits = getDeficits(targetByCondensate, stored)
        if next(deficits) then
          local entanglerActive, activitySignal = readEntanglerActivity()
          local bufferedOrderFluids = readFluidCacheTotal()
          if entanglerActive or bufferedOrderFluids > 0 then
            if not waitingForEntanglerStop then
              log("INFO", "order-fluid processing is not finished; idle stock refill deferred"
                .. "; entangler=" .. (entanglerActive and "running" or "idle")
                .. "; signal=" .. tostring(activitySignal)
                .. "; fluid-cache=" .. formatInteger(bufferedOrderFluids))
            end
            waitingForEntanglerStop = true
            entanglerIdleSince = nil
            uiPhase("WAITING", "Order fluids finishing before idle refill")
            nextRefillCheck = now() + config.timings.poll
          else
            entanglerIdleSince = entanglerIdleSince or now()
            local idleFor = now() - entanglerIdleSince
            if idleFor >= config.timings.emptySettle then
              if waitingForEntanglerStop then
                log("INFO", "order fluid cache empty and entangler stopped; idle stock refill may start")
              end
              waitingForEntanglerStop = false
              entanglerIdleSince = nil
              replenishIdleStock(stored)
              nextRefillCheck = now() + config.refill.checkInterval
            else
              uiPhase("WAITING", "Confirming entangler stopped before idle refill")
              nextRefillCheck = now() + config.timings.poll
            end
          end
        else
          waitingForEntanglerStop = false
          entanglerIdleSince = nil
          nextRefillCheck = now() + config.refill.checkInterval
        end
      end
    else
      waitingForEntanglerStop = false
      entanglerIdleSince = nil
    end

    if now() - lastFieldCheck >= config.timings.statusInterval then
      setSafeIdleFieldStrength(nil, "maintain safe idle field strength")
      lastFieldCheck = now()
    end
    os.sleep(config.timings.poll)
  end
end

local function configureNodes(orderCount)
  local parallel = math.min(
    math.ceil(orderCount / #nodes),
    config.nodes.maxParallelPerNode
  )
  for index, node in ipairs(nodes) do
    checked("set node " .. index .. " max parallel", node.setMaxParallel, parallel)
    local actual = tonumber(checked("read node " .. index .. " max parallel", node.getMaxParallel))
    if actual ~= parallel then
      fail(string.format("node %d parallel verification failed: expected=%d actual=%s", index, parallel, tostring(actual)))
    end
  end
  log("INFO", string.format("order=%d nodes=%d max-parallel-per-node=%d", orderCount, #nodes, parallel))
  uiUpdate({ nodeMaxParallel = parallel })
  return parallel
end

local function configureGate(required)
  local filters = {}
  for fluid in pairs(required) do filters[#filters + 1] = fluid end
  table.sort(filters)

  local count = tonumber(checked("get gate filter count", gate.getCondensateFilterCount)) or 0
  if #filters > count then fail("order requires more Maxwell gate filters than available slots") end
  checked("set Maxwell gate filters", gate.setCondensateFilters, filters)
  os.sleep(config.timings.filterVerifyDelay)
  for slot = 1, count do
    local expected = filters[slot]
    local actual = checked("verify gate filter " .. slot, gate.getCondensateFilterAt, slot)
    if actual ~= expected then
      fail(string.format(
        "Maxwell gate filter %d was overwritten (expected=%s actual=%s); remove conventional fluid input hatches",
        slot,
        tostring(expected),
        tostring(actual)
      ))
    end
  end
  uiUpdate({ filters = filters })
  log("INFO", "Maxwell gate filters=" .. table.concat(filters, ","))
end

local function waitForCondensate(required)
  local lastActivity = now()
  local previousDeficitTotal
  local lastStatus = -math.huge
  uiPhase("PREPARING", "Waiting for required condensate")
  while true do
    readFluidCacheTotal()
    local deficits = getDeficits(required, getStoredCondensate())
    local deficitTotal = sumValues(deficits)
    uiUpdate({ orderRemainingFluidTotal = deficitTotal })
    if not next(deficits) then return end
    if previousDeficitTotal and deficitTotal < previousDeficitTotal then
      lastActivity = now()
    end
    previousDeficitTotal = deficitTotal

    local entanglerActive, activitySignal = readEntanglerActivity()
    if entanglerActive then lastActivity = now() end
    if not entanglerActive and now() - lastActivity > config.timings.condensateWaitTimeout then
      fail("entangler inactive without required-condensate progress: " .. deficitText(deficits))
    end
    if now() - lastStatus >= config.timings.statusInterval then
      log("INFO", "waiting for condensate: " .. deficitText(deficits)
        .. "; entangler=" .. (entanglerActive and "running" or "idle")
        .. "; signal=" .. tostring(activitySignal))
      lastStatus = now()
    end
    os.sleep(config.timings.poll)
  end
end

local function allNodesIdle()
  local states = {}
  local idle = true
  local parallelTotal = 0
  local remainingCondensate = {}
  for index, node in ipairs(nodes) do
    local state = tostring(checked("get node " .. index .. " state", node.getState))
    local parallel = tonumber(checked(
      "get node " .. index .. " recipes in progress",
      node.getParallelRecipesInProgress
    )) or 0
    states[state] = (states[state] or 0) + 1
    parallelTotal = parallelTotal + parallel
    if state ~= "idle" or parallel > 0 then idle = false end
    if parallel > 0 then
      local required = checked(
        "get node " .. index .. " required condensate",
        node.getRequiredCondensate
      )
      local consumed = checked(
        "get node " .. index .. " consumed condensate",
        node.getConsumedCondensate
      )
      if required ~= nil and type(required) ~= "table" then
        fail("node " .. index .. " getRequiredCondensate returned " .. type(required))
      end
      if consumed ~= nil and type(consumed) ~= "table" then
        fail("node " .. index .. " getConsumedCondensate returned " .. type(consumed))
      end
      consumed = consumed or {}
      for fluid, amount in pairs(required or {}) do
        local requiredAmount = tonumber(amount)
        local consumedAmount = tonumber(consumed[fluid]) or 0
        if type(fluid) ~= "string" or not requiredAmount then
          fail("node " .. index .. " returned invalid condensate accounting data")
        end
        local remaining = math.max(0, requiredAmount - consumedAmount)
        if remaining > 0 then
          remainingCondensate[fluid] = (remainingCondensate[fluid] or 0) + remaining
        end
      end
    end
  end
  uiUpdate({
    nodeStates = states,
    nodeParallel = parallelTotal,
    orderRemainingFluidTotal = sumValues(remainingCondensate),
  })
  return idle, states, parallelTotal, remainingCondensate
end

local function stateText(states)
  local parts = {}
  for state, count in pairs(states) do parts[#parts + 1] = state .. "=" .. count end
  table.sort(parts)
  return table.concat(parts, ",")
end

local function tryHaltAutomaticRefill(activeFieldStrength, shortages)
  if not ((config.refill or {}).enabled) or not next(shortages) then
    return activeFieldStrength, false
  end

  local entryByCondensate = {}
  for _, entry in ipairs(config.fluids) do
    entryByCondensate[entry.condensate] = entry
  end
  for condensate in pairs(shortages) do
    if not entryByCondensate[condensate] then
      fail("HALT automatic refill has no source route for " .. tostring(condensate))
    end
  end

  local stored = getStoredCondensate()
  local requiredStock = {}
  log("WARN", "attempting automatic-refill recovery: " .. deficitText(shortages))
  for condensate, missing in pairs(shortages) do
    local entry = entryByCondensate[condensate]
    requiredStock[condensate] = (stored[condensate] or 0) + missing
    local stageState = stageRefillFluid(entry, missing, {
      interruptForOrder = false,
      phase = "RECOVERING",
      detailPrefix = "Recovery refill loading ",
    })
    if stageState == "stalled" then
      return activeFieldStrength, false,
        "HALT refill source " .. entry.source .. " delivered no fluid; manual supply required"
    elseif stageState ~= "ready" then
      fail("HALT automatic refill staging ended in unexpected state " .. tostring(stageState))
    end
  end

  local drainState, finalStored = drainRefillBatch(requiredStock, {
    interruptForOrder = false,
    phase = "RECOVERING",
    detail = "Converting automatic-refill fluids",
    logPrefix = "automatic recovery refill",
  })
  finalStored = finalStored or getStoredCondensate()
  activeFieldStrength = math.max(
    activeFieldStrength,
    refillFieldStrengthFloor,
    sumValues(finalStored)
  )
  local remaining = getDeficits(requiredStock, finalStored)
  if drainState ~= "ready" or next(remaining) then
    log("WARN", "HALT automatic-refill attempt ended without enough condensate: "
      .. deficitText(remaining))
    return activeFieldStrength, false, "HALT automatic refill incomplete; manual supply required"
  end

  log("INFO", "HALT automatic-refill recovery reached the active recipe requirement")
  return activeFieldStrength, true
end

local function applyCondensateFaultStop(phase, detail, states, parallel)
  uiUpdate({
    phase = phase,
    detail = detail,
    haltActive = true,
    nodeStates = states,
    nodeParallel = parallel,
  }, true)

  local stopErrors = {}
  local function attempt(label, fn)
    local ok, reason = pcall(fn)
    if not ok then stopErrors[#stopErrors + 1] = label .. ": " .. tostring(reason) end
  end

  -- Assert the external interlock first, then stop every local path that can
  -- advance or feed a recipe. Keep synthesis-active high so AE cannot send a
  -- replacement order while the recovery/HALT interlock is active.
  attempt("assert HALT output", function() setHaltOutput(true) end)
  attempt("disable Maxwell gate", function()
    checked("disable Maxwell gate", gate.setWorkAllowed, false)
    if checked("verify Maxwell gate disabled", gate.isWorkAllowed) ~= false then
      fail("Maxwell gate did not enter disabled state")
    end
  end)
  for index, node in ipairs(nodes) do
    attempt("disable node " .. index, function()
      checked("disable node " .. index, node.setWorkAllowed, false)
      if checked("verify node " .. index .. " disabled", node.isWorkAllowed) ~= false then
        fail("node " .. index .. " did not enter disabled state")
      end
    end)
  end
  attempt("disable material/item-cache output", function() setNodeNetwork(false) end)
  attempt("disable material/fluid-cache output", function() setOrderFluidTransfer(false) end)
  if (config.refill or {}).enabled then
    for _, entry in ipairs(config.fluids) do
      local route = refillRoutes[entry.source]
      attempt("disable refill source " .. entry.source, function()
        setRefillSource(route, entry.source, false)
      end)
    end
    attempt("disable automatic-refill link", function() setRefillLink(false) end)
  end
  attempt("hold synthesis-active output", function() setSynthesisActive(true) end)

  return stopErrors
end

local function haltForCondensateShortage(
    activeFieldStrength,
    shortages,
    states,
    parallel,
    reason,
    stopErrors
)
  haltLatched = true
  local detail = reason or ("Condensate shortage: " .. deficitText(shortages))
  local recoveryPhase = (config.refill or {}).enabled and "RECOVERING" or "HALT"
  if stopErrors == nil then
    stopErrors = applyCondensateFaultStop(recoveryPhase, detail, states, parallel)
  else
    uiUpdate({
      phase = recoveryPhase,
      detail = detail,
      haltActive = true,
      nodeStates = states,
      nodeParallel = parallel,
    }, true)
  end

  log("WARN", "active-node condensate demand exceeds containment stock: "
    .. deficitText(shortages))
  log("WARN", recoveryPhase .. " reason: " .. detail)
  for _, message in ipairs(stopErrors) do log("ERROR", recoveryPhase .. " shutdown failure: " .. message) end
  uiUpdate({ phase = recoveryPhase, detail = detail, haltActive = true }, true)

  local manualRefillRequired = false
  if (config.refill or {}).enabled then
    local refillStored = getStoredCondensate()
    local refillIdle, _, refillParallel, refillRemaining = allNodesIdle()
    local refillShortages = getDeficits(refillRemaining, refillStored)
    if refillParallel > 0 and not refillIdle and next(refillShortages) then
      uiPhase("RECOVERING", "Trying automatic refill for active nodes")
      local refillOk, updatedFieldStrength, refillSatisfied, refillReason = xpcall(function()
        return tryHaltAutomaticRefill(activeFieldStrength, refillShortages)
      end, debug.traceback)
      if refillOk then
        activeFieldStrength = updatedFieldStrength
        manualRefillRequired = not refillSatisfied
        detail = refillSatisfied
          and "Automatic refill complete; verifying active recipe inventory"
          or (refillReason or "HALT automatic refill incomplete; manual supply required")
      else
        manualRefillRequired = true
        detail = "HALT automatic refill failed; manual supply required"
        log("ERROR", "HALT automatic-refill recovery failed: " .. tostring(updatedFieldStrength))
        dashboardPaused = false
        pcall(setAllRefillSourcesOff)
        pcall(setRefillLink, false)
      end
      uiUpdate({
        phase = manualRefillRequired and "HALT" or "RECOVERING",
        detail = detail,
        haltActive = true,
      }, true)
    end
  end

  local lastStatus = -math.huge
  local nextResumeAttempt = 0
  while true do
    local stored = getStoredCondensate()
    local storedTotal = sumValues(stored)
    local idle, currentStates, currentParallel, remainingCondensate = allNodesIdle()
    local currentShortages = getDeficits(remainingCondensate, stored)
    local activeRecipePresent = currentParallel > 0 and not idle

    if activeRecipePresent
        and not next(currentShortages)
        and now() >= nextResumeAttempt then
      if storedTotal > activeFieldStrength then
        activeFieldStrength = storedTotal
        checked(
          "preserve HALT recovery condensate field strength",
          storage.setFieldStrength,
          activeFieldStrength
        )
        uiUpdate({ fieldStrength = activeFieldStrength })
      end
      refillFieldStrengthFloor = math.max(refillFieldStrengthFloor, activeFieldStrength)

      local resumeOk, resumeReason = xpcall(function()
        -- Enable the local machines while the external interlock is still
        -- asserted, then release HALT as the final resume action.
        setMachinesAllowed(true)
        setHaltOutput(false)
      end, debug.traceback)
      if resumeOk then
        haltLatched = false
        uiPhase("RUNNING", "HALT inventory requirement satisfied; nodes resumed")
        log("INFO", "HALT condensate monitor found sufficient inventory; interlock released and nodes resumed")
        return activeFieldStrength
      end

      detail = "HALT inventory is sufficient but resume failed: " .. tostring(resumeReason)
      log("ERROR", detail)
      nextResumeAttempt = now() + math.max(1, config.timings.statusInterval)
      local retryStopErrors = applyCondensateFaultStop(
        "HALT",
        detail,
        currentStates,
        currentParallel
      )
      for _, message in ipairs(retryStopErrors) do
        log("ERROR", "HALT retry shutdown failure: " .. message)
      end
    elseif activeRecipePresent and next(currentShortages) then
      detail = (manualRefillRequired and "HALT manual fluid supply required: "
        or "HALT waiting for condensate: ") .. deficitText(currentShortages)
    elseif activeRecipePresent then
      detail = "HALT inventory is sufficient; waiting to retry machine resume"
    else
      detail = "HALT cannot auto-resume: active node recipe state is unavailable"
    end

    uiUpdate({
      phase = "HALT",
      detail = detail,
      haltActive = true,
      nodeStates = currentStates,
      nodeParallel = currentParallel,
      fieldStrength = activeFieldStrength,
    }, true)
    if now() - lastStatus >= config.timings.statusInterval then
      log("WARN", "HALT monitoring: "
        .. (next(currentShortages) and deficitText(currentShortages) or "condensate requirement satisfied")
        .. "; stored=" .. formatInteger(storedTotal)
        .. "; nodes={" .. stateText(currentStates) .. "}"
        .. "; parallel=" .. tostring(currentParallel))
      lastStatus = now()
    end
    os.sleep(config.timings.poll)
  end
end

local function recoverCondensateShortage(
    activeFieldStrength,
    shortages,
    states,
    parallel,
    recoveryFluidInFlight,
    alreadyPulsedFluidSignature
)
  local detail = "Pausing nodes; checking incoming recovery fluids"
  local stopErrors = applyCondensateFaultStop("RECOVERING", detail, states, parallel)
  log("WARN", "condensate shortage detected; automatic recovery started: " .. deficitText(shortages))
  if #stopErrors > 0 then
    activeFieldStrength = haltForCondensateShortage(
      activeFieldStrength,
      shortages,
      states,
      parallel,
      "Recovery could not stop all processing paths",
      stopErrors
    )
    return activeFieldStrength, alreadyPulsedFluidSignature
  end

  local snapshot = readNetwork()
  if snapshot.itemTotal ~= 0
      or (snapshot.fluidTotal <= 0 and not recoveryFluidInFlight) then
    activeFieldStrength = haltForCondensateShortage(
      activeFieldStrength,
      shortages,
      states,
      parallel,
      string.format(
        "Recovery unavailable: incoming cache has %s items / %s fluid",
        formatInteger(snapshot.itemTotal),
        formatInteger(snapshot.fluidTotal)
      ),
      stopErrors
    )
    return activeFieldStrength, alreadyPulsedFluidSignature
  end

  local stored = getStoredCondensate()
  local recoveryFluidSignature = alreadyPulsedFluidSignature
  local shouldPulseRecoveryFluid = snapshot.fluidTotal > 0
    and snapshot.fluidSignature ~= alreadyPulsedFluidSignature
  if shouldPulseRecoveryFluid then
    local reservation = snapshot.fluidTotal
    local requiredFieldStrength = math.max(
      activeFieldStrength,
      baselineFieldStrength,
      refillFieldStrengthFloor,
      sumValues(stored) + reservation,
      activeFieldStrength + reservation
    )
    if requiredFieldStrength > activeFieldStrength then
      activeFieldStrength = requiredFieldStrength
      checked("raise field strength for HALT recovery fluids", storage.setFieldStrength, activeFieldStrength)
      uiUpdate({ fieldStrength = activeFieldStrength })
      log("INFO", "field strength raised for HALT recovery fluids="
        .. formatInteger(activeFieldStrength))
    end
    refillFieldStrengthFloor = math.max(refillFieldStrengthFloor, activeFieldStrength)

    local pulseOk, pulseReason = xpcall(function()
      transferOrderFluidsToBuffer("HALT automatic recovery", snapshot.fluidTotal)
    end, debug.traceback)
    if not pulseOk then
      activeFieldStrength = haltForCondensateShortage(
        activeFieldStrength,
        shortages,
        states,
        parallel,
        "Recovery fluid transfer failed: " .. tostring(pulseReason),
        stopErrors
      )
      return activeFieldStrength, recoveryFluidSignature
    end
    recoveryFluidSignature = snapshot.fluidSignature
  else
    log("INFO", "HALT recovery is waiting for the fluid-only batch already sent to the entangler cache")
  end

  uiPhase("RECOVERING", "Waiting for entangler to finish recovery fluids")
  local recoveryStarted = now()
  local lastActivity = recoveryStarted
  local lastStoredTotal = sumValues(stored)
  local lastStatus = -math.huge
  local entanglerIdleSince
  local sawEntanglerActivity = false
  local sawStockProgress = false

  while true do
    stored = getStoredCondensate()
    local storedTotal = sumValues(stored)
    if storedTotal > lastStoredTotal then
      lastStoredTotal = storedTotal
      lastActivity = now()
      sawStockProgress = true
    end

    local entanglerActive, activitySignal = readEntanglerActivity()
    local bufferedFluids, bufferedFluidTotal = readFluidCacheFluids()
    local processableBufferedFluid = false
    for _, entry in ipairs(config.fluids) do
      if (bufferedFluids[entry.source] or 0) >= entry.unit then
        processableBufferedFluid = true
        break
      end
    end
    if entanglerActive then
      sawEntanglerActivity = true
      lastActivity = now()
      entanglerIdleSince = nil
    else
      local startupGraceElapsed = now() - recoveryStarted >= config.timings.nodeStartGrace
      local completionObservable = sawEntanglerActivity
        or sawStockProgress
        or startupGraceElapsed
      if completionObservable and not processableBufferedFluid then
        entanglerIdleSince = entanglerIdleSince or now()
        if now() - entanglerIdleSince >= config.timings.emptySettle then break end
      else
        entanglerIdleSince = nil
      end
    end

    if not entanglerActive
        and now() - lastActivity > config.timings.condensateWaitTimeout then
      activeFieldStrength = haltForCondensateShortage(
        activeFieldStrength,
        shortages,
        states,
        parallel,
        "Recovery entangler made no progress before timeout",
        stopErrors
      )
      return activeFieldStrength, recoveryFluidSignature
    end
    if now() - lastStatus >= config.timings.statusInterval then
      log("INFO", "HALT recovery waiting: buffered-fluid=" .. formatInteger(bufferedFluidTotal)
        .. "; processable=" .. (processableBufferedFluid and "yes" or "no")
        .. "; stored=" .. formatInteger(storedTotal)
        .. "; entangler=" .. (entanglerActive and "running" or "idle")
        .. "; signal=" .. tostring(activitySignal))
      lastStatus = now()
    end
    os.sleep(config.timings.poll)
  end

  stored = getStoredCondensate()
  local recoveredIdle, recoveredStates, recoveredParallel, recoveredRemaining = allNodesIdle()
  if recoveredParallel <= 0 or recoveredIdle then
    activeFieldStrength = haltForCondensateShortage(
      activeFieldStrength,
      shortages,
      recoveredStates,
      recoveredParallel,
      "Recovery failed: active node recipe state disappeared",
      stopErrors
    )
    return activeFieldStrength, recoveryFluidSignature
  end
  local remainingShortages = getDeficits(recoveredRemaining, stored)
  if next(remainingShortages) then
    activeFieldStrength = haltForCondensateShortage(
      activeFieldStrength,
      remainingShortages,
      recoveredStates,
      recoveredParallel,
      "Recovery fluids finished but condensate is still insufficient: "
        .. deficitText(remainingShortages),
      stopErrors
    )
    return activeFieldStrength, recoveryFluidSignature
  end

  local recoveredStoredTotal = sumValues(stored)
  if recoveredStoredTotal > activeFieldStrength then
    activeFieldStrength = recoveredStoredTotal
    checked("preserve recovered condensate field strength", storage.setFieldStrength, activeFieldStrength)
    uiUpdate({ fieldStrength = activeFieldStrength })
  end
  refillFieldStrengthFloor = math.max(refillFieldStrengthFloor, activeFieldStrength)

  local resumeOk, resumeReason = xpcall(function()
    setMachinesAllowed(true)
    setHaltOutput(false)
  end, debug.traceback)
  if not resumeOk then
    activeFieldStrength = haltForCondensateShortage(
      activeFieldStrength,
      shortages,
      recoveredStates,
      recoveredParallel,
      "Recovery inventory is sufficient but processing could not resume: " .. tostring(resumeReason)
    )
    return activeFieldStrength, recoveryFluidSignature
  end

  uiPhase("RUNNING", "Automatic condensate recovery succeeded; nodes resumed")
  log("INFO", "HALT automatic recovery succeeded; interlock released and nodes resumed")
  return activeFieldStrength, recoveryFluidSignature
end

local function waitForNodeCompletion(activeFieldStrength, acceptedOrderCount)
  local started = now()
  local completionStableSince
  local lastStatus = -math.huge
  local nextOrderSignature
  local nextOrderStableSince
  local preparedNextSnapshot
  local preparedNextFingerprint
  local preparedUpdateSignature
  local preparedUpdateStableSince
  local preparedLastPulsedFluidSignature
  local residualFluidSignature
  local residualFluidStableSince
  local lastResidualPulsedFluidSignature
  local fluidOnlyRecoveryInFlight = false
  local sawNodeActivity = false
  uiPhase("RUNNING", "Active nodes running; receiving next order")

  while true do
    -- Read stock before per-node accounting. If consumption happens between
    -- these reads, the older (higher) stock avoids a transient false HALT;
    -- the next poll catches a real shortage.
    local stored = getStoredCondensate()
    local storedTotal = sumValues(stored)
    local idle, states, parallel, remainingCondensate = allNodesIdle()
    if parallel > 0 then
      local shortages = getDeficits(remainingCondensate, stored)
      if next(shortages) then
        local recoveryFluidSignature
        activeFieldStrength, recoveryFluidSignature = recoverCondensateShortage(
          activeFieldStrength,
          shortages,
          states,
          parallel,
          fluidOnlyRecoveryInFlight,
          lastResidualPulsedFluidSignature
        )
        fluidOnlyRecoveryInFlight = false
        lastResidualPulsedFluidSignature = recoveryFluidSignature
        stored = getStoredCondensate()
        storedTotal = sumValues(stored)
        idle, states, parallel, remainingCondensate = allNodesIdle()
      end
    end
    local snapshot = readNetwork()
    local itemCacheTotal = readItemCacheTotal()
    local fluidCacheTotal = readFluidCacheTotal()
    if not idle or parallel > 0 then sawNodeActivity = true end
    local completionEligible = sawNodeActivity
      or now() - started >= config.timings.nodeStartGrace
    local preparedUpdatePending = false

    if preparedNextSnapshot then
      if #snapshot.items == 0 then
        fail("prefetched next-order items disappeared from the material cache")
      end
      local liveFingerprint = identifyOrder(snapshot.items)
      if liveFingerprint ~= preparedNextFingerprint then
        fail(string.format(
          "prefetched next order fingerprint changed: expected=%s actual=%s items=%s",
          preparedNextFingerprint,
          liveFingerprint,
          formatInteger(snapshot.itemTotal)
        ))
      end
      if snapshot.itemTotal < preparedNextSnapshot.itemTotal then
        fail(string.format(
          "prefetched next order items decreased: expected-at-least=%s actual=%s fingerprint=%s",
          formatInteger(preparedNextSnapshot.itemTotal),
          formatInteger(snapshot.itemTotal),
          preparedNextFingerprint
        ))
      end

      local itemGrowth = snapshot.itemTotal - preparedNextSnapshot.itemTotal
      local hasAdditionalFluids = snapshot.fluidTotal > 0
      local fluidsAlreadyPulsed = hasAdditionalFluids
        and snapshot.fluidSignature == preparedLastPulsedFluidSignature
      if itemGrowth > 0 or (hasAdditionalFluids and not fluidsAlreadyPulsed) then
        preparedUpdatePending = true
        if snapshot.signature ~= preparedUpdateSignature then
          preparedUpdateSignature = snapshot.signature
          preparedUpdateStableSince = now()
        elseif now() - preparedUpdateStableSince >= config.timings.orderSettle then
          local previousItemTotal = preparedNextSnapshot.itemTotal
          local appendedFluidTotal = 0
          if hasAdditionalFluids and not fluidsAlreadyPulsed then
            getRequiredCondensate(snapshot.fluids)
            local reservation = snapshot.fluidTotal
            local requiredFieldStrength = math.max(
              activeFieldStrength,
              baselineFieldStrength,
              refillFieldStrengthFloor,
              storedTotal + reservation,
              activeFieldStrength + reservation
            )
            if requiredFieldStrength > activeFieldStrength then
              activeFieldStrength = requiredFieldStrength
              checked(
                "raise field strength for appended next-order fluids",
                storage.setFieldStrength,
                activeFieldStrength
              )
              uiUpdate({ fieldStrength = activeFieldStrength })
              log("INFO", "field strength raised for appended next-order fluids="
                .. formatInteger(activeFieldStrength))
            end
            transferOrderFluidsToBuffer(
              "appended prefetched order " .. preparedNextFingerprint,
              snapshot.fluidTotal
            )
            appendOrderFluids(preparedNextSnapshot, snapshot.fluids)
            preparedLastPulsedFluidSignature = snapshot.fluidSignature
            appendedFluidTotal = snapshot.fluidTotal
          end
          preparedNextSnapshot.items = snapshot.items
          preparedNextSnapshot.itemTotal = snapshot.itemTotal
          preparedNextSnapshot.signature = snapshot.signature
          preparedUpdateSignature = nil
          preparedUpdateStableSince = nil
          preparedUpdatePending = false
          log("INFO", string.format(
            "prefetched next order expanded: fingerprint=%s items=%s->%s additional-fluids=%s",
            preparedNextFingerprint,
            formatInteger(previousItemTotal),
            formatInteger(snapshot.itemTotal),
            formatInteger(appendedFluidTotal)
          ))
        end
      else
        preparedUpdateSignature = nil
        preparedUpdateStableSince = nil
        if not hasAdditionalFluids then preparedLastPulsedFluidSignature = nil end
      end
    elseif hasCompleteOrder(snapshot) then
      local fingerprint = identifyOrder(snapshot.items)
      if snapshot.signature ~= nextOrderSignature then
        nextOrderSignature = snapshot.signature
        nextOrderStableSince = now()
      elseif now() - nextOrderStableSince >= config.timings.orderSettle then
        getRequiredCondensate(snapshot.fluids)
        local reservation = snapshot.fluidTotal
        local requiredFieldStrength = math.max(
          activeFieldStrength,
          baselineFieldStrength,
          refillFieldStrengthFloor,
          storedTotal + reservation,
          activeFieldStrength + reservation
        )
        if requiredFieldStrength > activeFieldStrength then
          activeFieldStrength = requiredFieldStrength
          checked(
            "raise field strength for prefetched next order",
            storage.setFieldStrength,
            activeFieldStrength
          )
          uiUpdate({ fieldStrength = activeFieldStrength })
          log("INFO", "field strength raised for prefetched next order="
            .. formatInteger(activeFieldStrength))
        end
        log("INFO", string.format(
          "prefetching next-order fluids while active nodes run: fingerprint=%s amount=%s",
          fingerprint,
          formatInteger(snapshot.fluidTotal)
        ))
        local frozenSnapshot = snapshot
        transferOrderFluidsToBuffer("prefetched next order " .. fingerprint, snapshot.fluidTotal)
        frozenSnapshot.fluidsTransferred = true
        preparedNextSnapshot = frozenSnapshot
        preparedNextFingerprint = fingerprint
        preparedLastPulsedFluidSignature = snapshot.fluidSignature
        nextOrderSignature = nil
        nextOrderStableSince = nil
        uiPhase("RUNNING", "Next-order fluids prefetched; active nodes running")
        log("INFO", "next-order items retained in material cache; fluids are processing")
      end
    else
      nextOrderSignature = nil
      nextOrderStableSince = nil
    end

    local activeOrderFinished = completionEligible and idle and itemCacheTotal == 0
    if not preparedNextSnapshot
        and snapshot.itemTotal == 0 and snapshot.fluidTotal > 0 then
      if snapshot.fluidSignature == lastResidualPulsedFluidSignature then
        residualFluidSignature = nil
        residualFluidStableSince = nil
      elseif snapshot.fluidSignature ~= residualFluidSignature then
        residualFluidSignature = snapshot.fluidSignature
        residualFluidStableSince = now()
      elseif now() - residualFluidStableSince >= config.timings.orderSettle then
        getRequiredCondensate(snapshot.fluids)
        local reservation = snapshot.fluidTotal
        local requiredFieldStrength = math.max(
          activeFieldStrength,
          baselineFieldStrength,
          refillFieldStrengthFloor,
          storedTotal + reservation,
          activeFieldStrength + reservation
        )
        if requiredFieldStrength > activeFieldStrength then
          activeFieldStrength = requiredFieldStrength
          checked(
            "raise field strength for fluid-only income",
            storage.setFieldStrength,
            activeFieldStrength
          )
          uiUpdate({ fieldStrength = activeFieldStrength })
        end
        refillFieldStrengthFloor = math.max(refillFieldStrengthFloor, activeFieldStrength)
        transferOrderFluidsToBuffer("fluid-only income while order is active", snapshot.fluidTotal)
        lastResidualPulsedFluidSignature = snapshot.fluidSignature
        fluidOnlyRecoveryInFlight = true
        residualFluidSignature = nil
        residualFluidStableSince = nil
        log("INFO", "fluid-only income exported to entangler cache; amount="
          .. formatInteger(snapshot.fluidTotal)
          .. "; reserved-field-strength=" .. formatInteger(activeFieldStrength))
      end
    elseif snapshot.fluidTotal == 0 then
      residualFluidSignature = nil
      residualFluidStableSince = nil
      lastResidualPulsedFluidSignature = nil
    else
      residualFluidSignature = nil
      residualFluidStableSince = nil
    end

    if activeOrderFinished
        and preparedNextSnapshot and not preparedUpdatePending then
      log("INFO", string.format(
        "active order nodes idle; prefetched next order ready fingerprint=%s",
        preparedNextFingerprint
      ))
      return activeFieldStrength, preparedNextSnapshot, acceptedOrderCount
    end

    if activeOrderFinished and not hasAnyOrderInput(snapshot) then
      completionStableSince = completionStableSince or now()
      if now() - completionStableSince >= config.timings.emptySettle then
        return activeFieldStrength, nil, acceptedOrderCount
      end
    else
      completionStableSince = nil
    end

    if now() - started > config.timings.orderRunTimeout then
      fail(string.format(
        "order timed out: item-cache=%s fluid-cache=%s incoming-items=%s incoming-fluids=%s next=%s nodes={%s} parallel=%d",
        formatInteger(itemCacheTotal),
        formatInteger(fluidCacheTotal),
        formatInteger(snapshot.itemTotal),
        formatInteger(snapshot.fluidTotal),
        preparedUpdatePending and "expanding"
          or (preparedNextSnapshot and "prefetched"
            or (hasAnyOrderInput(snapshot) and "loading" or "none")),
        stateText(states),
        parallel
      ))
    end
    if now() - lastStatus >= config.timings.statusInterval then
      log("INFO", string.format(
        "running: item-cache=%s fluid-cache=%s incoming-items=%s incoming-fluids=%s next=%s nodes={%s} parallel=%d",
        formatInteger(itemCacheTotal),
        formatInteger(fluidCacheTotal),
        formatInteger(snapshot.itemTotal),
        formatInteger(snapshot.fluidTotal),
        preparedUpdatePending and "expanding"
          or (preparedNextSnapshot and "prefetched"
            or (hasAnyOrderInput(snapshot) and "loading" or "none")),
        stateText(states),
        parallel
      ))
      lastStatus = now()
    end
    os.sleep(config.timings.poll)
  end
end

local function processOrder(snapshot)
  local orderCount, fingerprint, divisor = getOrderCount(snapshot.items)
  local required = getRequiredCondensate(snapshot.fluids)
  local initialStored = getStoredCondensate()
  local orderFluidTotal = sumValues(required)
  local currentStoredTotal = sumValues(initialStored)
  local deficits = getDeficits(required, initialStored)
  local activeFieldStrength = math.max(
    baselineFieldStrength,
    currentStoredTotal,
    refillFieldStrengthFloor
  ) + orderFluidTotal

  uiUpdate({
    phase = "PREPARING",
    detail = "Configuring order " .. fingerprint,
    order = {
      count = orderCount,
      fingerprint = fingerprint,
      divisor = divisor,
      itemTotal = snapshot.itemTotal,
      fluidTotal = orderFluidTotal,
    },
    orderRemainingItemTotal = snapshot.itemTotal,
    orderRemainingFluidTotal = sumValues(deficits),
  })
  log("INFO", string.format(
    "accepted order: count=%d fingerprint=%s divisor=%d item-total=%s fluid-total=%s",
    orderCount,
    fingerprint,
    divisor,
    formatInteger(snapshot.itemTotal),
    formatInteger(snapshot.fluidTotal)
  ))
  setSynthesisActive(true)
  checked("raise field strength", storage.setFieldStrength, activeFieldStrength)
  uiUpdate({ fieldStrength = activeFieldStrength })
  log("INFO", "field strength=" .. formatInteger(activeFieldStrength))
  if not snapshot.fluidsTransferred then
    transferOrderFluidsToBuffer("accepted order " .. fingerprint, snapshot.fluidTotal)
    snapshot.fluidsTransferred = true
  end

  if next(deficits) then
    log("INFO", "cache insufficient; waiting for intermediate-buffer processing: " .. deficitText(deficits))
    waitForCondensate(required)
    configureGate(required)
    configureNodes(orderCount)
  else
    log("INFO", "cache sufficient; configuring gate and nodes before moving items to node cache")
    configureGate(required)
    configureNodes(orderCount)
  end

  setMachinesAllowed(true)
  pulseNodeOrderTransfer(fingerprint, snapshot.itemTotal)
  local nextSnapshot
  local completedOrderCount
  activeFieldStrength, nextSnapshot, completedOrderCount = waitForNodeCompletion(
    activeFieldStrength,
    orderCount
  )

  setNodeNetwork(false)
  setMachinesAllowed(false)
  setOrderFluidTransfer(false)
  if not nextSnapshot then setSynthesisActive(false) end
  if nextSnapshot then
    log("INFO", "item cache empty and all nodes idle; next-order fluids prefetched")
  else
    log("INFO", "item cache empty and all nodes idle; order complete")
  end
  local idleStrength
  if nextSnapshot then
    idleStrength = activeFieldStrength
    log("INFO", "preserving prefetched-order field strength=" .. formatInteger(idleStrength))
  else
    idleStrength = setSafeIdleFieldStrength(nil, "restore safe idle field strength")
  end
  processedRecipeTotal = processedRecipeTotal + completedOrderCount
  local saved, saveWarning = saveProcessedRecipeTotal()
  if not saved then fail("cannot persist processed recipe total: " .. tostring(saveWarning)) end
  uiUpdate({
    phase = nextSnapshot and "READY" or "WAITING",
    detail = nextSnapshot and "Next-order fluids prefetched" or "Order complete",
    order = false,
    orderRemainingItemTotal = 0,
    orderRemainingFluidTotal = 0,
    processedRecipeTotal = processedRecipeTotal,
  })
  if saveWarning then log("WARN", saveWarning) end
  log("INFO", string.format(
    "completed recipes=%s; processed recipe total=%s",
    formatInteger(completedOrderCount),
    formatInteger(processedRecipeTotal)
  ))
  log("INFO", "order complete; idle field strength=" .. formatInteger(idleStrength))
  reportBaselineStock()
  if not nextSnapshot then os.sleep(config.timings.cooldown) end
  return nextSnapshot
end

local function initializeSafeState()
  uiPhase("STARTING", "Applying safe machine state")
  local stored = getStoredCondensate()
  assertBaselineIsSafe(stored)
  assertBaselineStockPresent(stored)
  haltLatched = false
  setHaltOutput(false)
  setNodeNetwork(false)
  setOrderFluidTransfer(false)
  setSynthesisActive(false)
  if (config.refill or {}).enabled then
    setAllRefillSourcesOff()
    setRefillLink(false)
    readEntanglerActivity()
  end
  setMachinesAllowed(false)
  uiUpdate({ nodeStates = { disabled = #nodes }, nodeParallel = 0 })
  local idleStrength = setSafeIdleFieldStrength(stored, "set safe idle field strength")
  log("INFO", "idle field strength=" .. formatInteger(idleStrength))
  reportBaselineStock()
end

local function discover()
  for _, componentType in ipairs({
    "bec_storage", "bec_diode", "bec_io_node", "me_interface", "redstone",
  }) do
    for address in component.list(componentType, true) do
      local methods = component.methods(address) or {}
      local names = {}
      for method in pairs(methods) do names[#names + 1] = method end
      table.sort(names)
      print(componentType .. "  " .. address)
      print("  methods=" .. table.concat(names, ","))
    end
  end
end

local function checkConfiguration()
  local function outputText(device)
    local values = checked("read all-face output", device.getOutput)
    if type(values) ~= "table" then fail("redstone getOutput did not return a side table") end
    local parts = {}
    for face = 0, 5 do parts[#parts + 1] = tostring(tonumber(values[face]) or "?") end
    return table.concat(parts, ",")
  end
  print("Components found")
  print("  storage=" .. storage.address)
  print("  gate=" .. gate.address)
  print("  material-cache=" .. cache.address .. " (" .. cache.type .. ")")
  print("  item-cache=" .. itemCache.address .. " (" .. itemCache.type .. ")")
  print("  fluid-cache=" .. fluidCache.address .. " (" .. fluidCache.type .. ")")
  print("  node-redstone=" .. nodeRedstone.address .. " side=all")
  print("  node-transfer-pulse=" .. tostring(config.timings.nodeTransferPulse) .. "s")
  print("  order-fluid-transfer-redstone="
    .. generatorRedstone.address .. " side=all")
  print("  synthesis-active-redstone="
    .. synthesisRedstone.address .. " side=all")
  print("  synthesis-active-output=" .. outputText(synthesisRedstone))
  print("  halt-redstone=" .. haltRedstone.address .. " side=all")
  print("  halt-output=" .. outputText(haltRedstone))
  if (config.refill or {}).enabled then
    print("  refill-cache=" .. refillCache.address .. " (" .. refillCache.type .. ")")
    print("  refill-entangler-redstone=" .. refillLinkRedstone.address
      .. " side=all")
    print("  refill-entangler-activity-redstone=" .. refillActivityRedstone.address
      .. " side=all")
    print("  refill-unused-route-output=" .. routeConfig.unusedOutput.address
      .. " side=" .. routeConfig.unusedOutput.side .. " (kept off)")
    print("  refill-fluid-config:")
    for _, entry in ipairs(config.fluids) do
      print(string.format(
        "    %s target=%s rate=%.3f L/s",
        entry.source,
        formatInteger(entry.target),
        entry.rateLitersPerSecond
      ))
    end
    print("  refill-staged-fluids=" .. formatInteger(sumValues(readRefillFluids())))
    print("  refill-entangler-output=" .. outputText(refillLinkRedstone))
    local entanglerActive, activitySignal = readEntanglerActivity()
    print("  refill-entangler-activity=" .. (entanglerActive and "running" or "idle")
      .. " signal=" .. tostring(activitySignal)
      .. " threshold=" .. tostring(config.refill.activityThreshold))
    local activeSources = {}
    for _, entry in ipairs(config.fluids) do
      local route = refillRoutes[entry.source]
      local value = tonumber(checked(
        "read refill source " .. entry.source,
        route.device.getOutput,
        route.side
      )) or 0
      if value ~= config.refill.disconnectSignal then
        activeSources[#activeSources + 1] = entry.source .. "=" .. value
      end
    end
    print("  active-refill-sources="
      .. (#activeSources > 0 and table.concat(activeSources, ",") or "none"))
  end
  print("  nodes=" .. #nodes)
  print("  baseline-field-strength=" .. formatInteger(baselineFieldStrength))
  local currentStored = getStoredCondensate()
  print("  current-condensate-stock=" .. formatInteger(sumValues(currentStored)))
  assertBaselineIsSafe(currentStored)
  assertBaselineStockPresent(currentStored)
  local snapshot = readNetwork()
  print("  material-cache-items=" .. formatInteger(snapshot.itemTotal))
  print("  material-cache-fluids=" .. formatInteger(snapshot.fluidTotal))
  print("  item-cache-items=" .. formatInteger(readItemCacheTotal()))
  print("  fluid-cache-fluids=" .. formatInteger(readFluidCacheTotal()))
  if hasCompleteOrder(snapshot) then
    local count, fingerprint, divisor = getOrderCount(snapshot.items)
    print(string.format("  pending-order=%d fingerprint=%s divisor=%d", count, fingerprint, divisor))
    print("  required-condensate=" .. deficitText(getRequiredCondensate(snapshot.fluids)))
  end
  print("Configuration OK (read-only check)")
end

local function cleanup()
  if controlsArmed and nodeRedstone then
    pcall(setToggle, nodeRedstone, nil, "material/item-cache output", false)
  end
  if controlsArmed and generatorRedstone then
    pcall(setToggle, generatorRedstone, nil, "material/fluid-cache output", false)
  end
  if controlsArmed and synthesisRedstone and not haltInterlockActive then
    pcall(setToggle, synthesisRedstone, nil, "synthesis-active", false)
  end
  if controlsArmed and haltRedstone and not haltInterlockActive then
    pcall(setToggle, haltRedstone, nil, "HALT", false)
  end
  if controlsArmed and (config.refill or {}).enabled then
    for _, entry in ipairs(config.fluids) do
      local route = refillRoutes[entry.source]
      if route then pcall(setRefillSource, route, entry.source, false) end
    end
    if refillLinkRedstone then pcall(setRefillLink, false) end
  end
  if controlsArmed and gate then pcall(gate.setWorkAllowed, false) end
  if controlsArmed then
    for _, node in ipairs(nodes) do pcall(node.setWorkAllowed, false) end
  end
  if logHandle then logHandle:close() end
  if dashboard then
    pcall(dashboard.close, dashboard)
    dashboard = nil
  end
end

local args = { ... }
local command = args[1] or "run"
if command == "discover" then
  discover()
  return
end

local ok, reason = xpcall(function()
  validateConfig()
  bindComponents()
  if command == "check" then
    checkConfiguration()
    return
  end
  if command ~= "run" and command ~= "once" then
    fail("usage: lua bec_automation.lua [discover|check|run|once]")
  end

  initializeDashboard()
  if config.logFile then
    logHandle = io.open(config.logFile, "a")
    if not logHandle then fail("cannot open log file " .. tostring(config.logFile)) end
  end
  loadProcessedRecipeTotal()
  controlsArmed = true
  initializeSafeState()
  log("INFO", "BEC automation online")

  local pendingSnapshot
  repeat
    local snapshot = pendingSnapshot or waitForStableOrder()
    pendingSnapshot = processOrder(snapshot)
  until command == "once"
end, debug.traceback)

cleanup()
if not ok then
  io.stderr:write(tostring(reason) .. "\n")
  os.exit(1)
end
