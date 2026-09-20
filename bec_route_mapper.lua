local component = require("component")
local computer = require("computer")

local configOk, config = pcall(require, "bec_route_mapper_config")
if not configOk then
  error("cannot load bec_route_mapper_config.lua: " .. tostring(config), 0)
end

local cacheInterface
local referenceInterface
local outputs = {}
local controlsArmed = false

local function now()
  return computer.uptime()
end

local function fail(message)
  error(message, 0)
end

local function trim(value)
  return tostring(value or ""):match("^%s*(.-)%s*$")
end

local function resolveAddress(componentType, prefix, label)
  prefix = trim(prefix)
  local matches = {}
  for address in component.list(componentType, true) do
    if prefix ~= "" and address:sub(1, #prefix) == prefix then
      matches[#matches + 1] = address
    end
  end
  table.sort(matches)
  if #matches == 0 then fail(label .. " not found: " .. prefix) end
  if #matches > 1 then fail(label .. " address is ambiguous: " .. table.concat(matches, ",")) end
  return matches[1]
end

local function bind(componentType, prefix, label, requiredMethods)
  local address = resolveAddress(componentType, prefix, label)
  local methods, reason = component.methods(address)
  if type(methods) ~= "table" then fail(label .. " methods unavailable: " .. tostring(reason)) end
  for _, method in ipairs(requiredMethods) do
    if methods[method] == nil then fail(label .. " does not expose " .. method) end
  end
  return { address = address, label = label }
end

local function invoke(device, method, ...)
  local ok, a, b = pcall(component.invoke, device.address, method, ...)
  if not ok then fail(device.label .. "." .. method .. ": " .. tostring(a)) end
  return a, b
end

local function readFluids(device)
  local raw = invoke(device, "getFluidsInNetwork")
  if type(raw) ~= "table" then fail(device.label .. " returned invalid fluid data") end
  local fluids = {}
  for _, stack in pairs(raw) do
    local name = type(stack) == "table" and stack.name or nil
    local amount = type(stack) == "table" and tonumber(stack.amount) or nil
    if type(name) == "string" and name ~= "" and amount and amount > 0 then
      fluids[name] = (fluids[name] or 0) + amount
    end
  end
  return fluids
end

local function tryReadFluids(device)
  local ok, result = pcall(readFluids, device)
  if ok then return result end
  return nil, result
end

local function fluidSignature(fluids)
  local parts = {}
  for name, amount in pairs(fluids) do
    parts[#parts + 1] = name .. "=" .. string.format("%.0f", amount)
  end
  table.sort(parts)
  return table.concat(parts, "|")
end

local function waitForStableCache(timeout)
  local started = now()
  local stableSince
  local lastSignature
  local lastFluids
  while now() - started <= timeout do
    local fluids = readFluids(cacheInterface)
    local signature = fluidSignature(fluids)
    if signature == lastSignature then
      stableSince = stableSince or now()
      if now() - stableSince >= config.timings.stableFor then return fluids end
    else
      lastSignature = signature
      lastFluids = fluids
      stableSince = now()
    end
    os.sleep(config.timings.poll)
  end
  fail("cache subnet did not remain stable; stop all orders and fluid transfers before mapping (last="
    .. fluidSignature(lastFluids or {}) .. ")")
end

local function positiveDelta(before, after)
  local result = {}
  for name, amount in pairs(after) do
    local delta = amount - (before[name] or 0)
    if delta >= config.minDetectedDelta then result[name] = delta end
  end
  return result
end

local function signedDelta(before, after)
  if not before or not after then return {} end
  local names = {}
  for name in pairs(before) do names[name] = true end
  for name in pairs(after) do names[name] = true end
  local result = {}
  for name in pairs(names) do
    local delta = (after[name] or 0) - (before[name] or 0)
    if math.abs(delta) >= config.minDetectedDelta then result[name] = delta end
  end
  return result
end

local function countEntries(values)
  local count = 0
  for _ in pairs(values) do count = count + 1 end
  return count
end

local function changeText(values)
  local parts = {}
  for name, amount in pairs(values) do
    parts[#parts + 1] = string.format("%s=%+.0f", name, amount)
  end
  table.sort(parts)
  return #parts > 0 and table.concat(parts, ", ") or "none"
end

local function setOutput(route, value)
  local device = route.device
  invoke(device, "setOutput", route.side, value)
  local actual = tonumber(invoke(device, "getOutput", route.side))
  if actual ~= value then
    fail(string.format(
      "%s/%s output verification failed: expected=%d actual=%s",
      device.address,
      route.sideName,
      value,
      tostring(actual)
    ))
  end
end

local function turnAllOffStrict()
  for _, route in ipairs(outputs) do setOutput(route, config.inactiveSignal) end
end

local function turnAllOffBestEffort()
  for _, route in ipairs(outputs) do
    pcall(component.invoke, route.device.address, "setOutput", route.side, config.inactiveSignal)
  end
end

local function validateAndBind()
  if config.schemaVersion ~= 1 then fail("unsupported bec_route_mapper_config schema") end
  if type(config.expectedFluids) ~= "table" or #config.expectedFluids ~= 19 then
    fail("expectedFluids must contain exactly 19 source fluid names")
  end
  if config.activeSignal == config.inactiveSignal then fail("active and inactive signals must differ") end

  cacheInterface = bind("me_interface", config.cacheInterfaceAddress, "cache ME interface", {
    "getFluidsInNetwork",
  })
  referenceInterface = bind("me_interface", config.referenceInterfaceAddress, "reference ME interface", {
    "getFluidsInNetwork",
  })
  if cacheInterface.address == referenceInterface.address then fail("cache and reference interfaces are identical") end

  local seen = {}
  for index, prefix in ipairs(config.redstoneAddresses or {}) do
    local device = bind("redstone", prefix, "probe redstone I/O " .. index, { "getOutput", "setOutput" })
    if seen[device.address] then fail("duplicate probe redstone address " .. device.address) end
    seen[device.address] = true
    for _, side in ipairs(config.testSides or {}) do
      outputs[#outputs + 1] = {
        device = device,
        side = side.value,
        sideName = side.name,
      }
    end
  end
  if #outputs ~= 20 then fail("expected exactly 20 probe outputs, found " .. #outputs) end

  for _, protected in ipairs(config.protectedControls or {}) do
    local device = bind("redstone", protected.address, protected.label, { "getOutput" })
    if seen[device.address] then fail("protected redstone I/O is also present in the probe list: " .. device.address) end
    local value = tonumber(invoke(device, "getOutput", protected.side))
    if value ~= config.inactiveSignal then
      fail(string.format("%s must be disconnected before mapping; current output=%s", protected.label, tostring(value)))
    end
  end
end

local function probeRoute(route, index)
  local baseline = waitForStableCache(config.timings.stableTimeout)
  local referenceBefore = tryReadFluids(referenceInterface)
  print(string.format(
    "[%02d/%02d] probing %s/%s",
    index,
    #outputs,
    route.device.address,
    route.sideName
  ))

  setOutput(route, config.activeSignal)
  local started = now()
  local lastStatus = started
  local readFailed = false
  while now() - started <= config.timings.probeTimeout do
    os.sleep(config.timings.poll)
    local ok, current = pcall(readFluids, cacheInterface)
    if not ok then
      readFailed = true
      break
    end
    if next(positiveDelta(baseline, current)) then break end
    if now() - lastStatus >= config.timings.statusInterval then
      print(string.format("  waiting for fluid... %.1f/%.1f s", now() - started, config.timings.probeTimeout))
      lastStatus = now()
    end
  end

  local offOk, offReason = pcall(setOutput, route, config.inactiveSignal)
  if not offOk then fail("cannot switch probe output off: " .. tostring(offReason)) end

  os.sleep(config.timings.postOffDelay)
  local after = waitForStableCache(readFailed and config.timings.recoveryTimeout or config.timings.stableTimeout)
  local referenceAfter = tryReadFluids(referenceInterface)
  return {
    address = route.device.address,
    side = route.side,
    sideName = route.sideName,
    cacheDelta = positiveDelta(baseline, after),
    referenceDelta = signedDelta(referenceBefore, referenceAfter),
    cacheReadFailedWhileActive = readFailed,
  }
end

local function quote(value)
  return string.format("%q", tostring(value))
end

local function writeResult(path, complete, mapped, unresolved, unusedOutput)
  local handle, reason = io.open(path, "w")
  if not handle then fail("cannot write " .. path .. ": " .. tostring(reason)) end
  handle:write("return {\n")
  handle:write("  schemaVersion = 2,\n")
  handle:write("  complete = ", tostring(complete), ",\n")
  handle:write("  cacheInterfaceAddress = ", quote(cacheInterface.address), ",\n")
  handle:write("  referenceInterfaceAddress = ", quote(referenceInterface.address), ",\n")
  handle:write("  fluids = {\n")
  for _, fluid in ipairs(config.expectedFluids) do
    local route = mapped[fluid]
    if route then
      handle:write(string.format(
        "    [%s] = { address = %s, side = %d, sideName = %s },\n",
        quote(fluid),
        quote(route.address),
        route.side,
        quote(route.sideName)
      ))
    end
  end
  handle:write("  },\n")
  if unusedOutput then
    handle:write(string.format(
      "  unusedOutput = { address = %s, side = %d, sideName = %s },\n",
      quote(unusedOutput.address),
      unusedOutput.side,
      quote(unusedOutput.sideName)
    ))
  end
  handle:write("  unresolved = {\n")
  for _, probe in ipairs(unresolved) do
    handle:write(string.format(
      "    { address = %s, side = %d, sideName = %s, reason = %s, observed = %s },\n",
      quote(probe.address),
      probe.side,
      quote(probe.sideName),
      quote(probe.reason),
      quote(changeText(probe.cacheDelta))
    ))
  end
  handle:write("  },\n")
  handle:write("}\n")
  handle:close()
end

local function run()
  validateAndBind()
  controlsArmed = true
  turnAllOffStrict()

  local expected = {}
  for _, fluid in ipairs(config.expectedFluids) do expected[fluid] = true end
  local initialCache = waitForStableCache(config.timings.stableTimeout)
  local initialReference, referenceReason = tryReadFluids(referenceInterface)
  print("cache interface=" .. cacheInterface.address .. " fluids={" .. fluidSignature(initialCache) .. "}")
  print("reference interface=" .. referenceInterface.address
    .. " fluids={" .. fluidSignature(initialReference or {}) .. "}")
  if not config.allowNonEmptyCache and next(initialCache) then
    fail("cache interface must be empty before mapping; clear its fluids or explicitly allow a non-empty cache")
  end
  if config.requireAllExpectedInReference then
    if not initialReference then fail("cannot read reference interface: " .. tostring(referenceReason)) end
    local unavailable = {}
    for _, fluid in ipairs(config.expectedFluids) do
      if (initialReference[fluid] or 0) < config.minDetectedDelta then
        unavailable[#unavailable + 1] = fluid
      end
    end
    if #unavailable > 0 then
      fail("reference interface is missing expected source fluids: " .. table.concat(unavailable, ","))
    end
  elseif not initialReference or not next(initialReference) then
    print("reference inventory is empty or unavailable; continuing with cache fluid deltas")
  end
  print("probing 20 outputs; only one output is active at a time")

  local mapped = {}
  local unresolved = {}
  for index, route in ipairs(outputs) do
    local probe = probeRoute(route, index)
    local deltaCount = countEntries(probe.cacheDelta)
    if deltaCount == 1 then
      local fluid, amount = next(probe.cacheDelta)
      if not expected[fluid] then
        probe.reason = "unexpected fluid"
        unresolved[#unresolved + 1] = probe
        print("  unresolved: unexpected " .. fluid .. "=" .. string.format("%.0f", amount))
      elseif mapped[fluid] then
        probe.reason = "duplicate route for " .. fluid
        unresolved[#unresolved + 1] = probe
        print("  unresolved: duplicate route for " .. fluid)
      else
        mapped[fluid] = probe
        print(string.format(
          "  mapped: %s +%.0f mB; reference={%s}",
          fluid,
          amount,
          changeText(probe.referenceDelta)
        ))
      end
    else
      if probe.cacheReadFailedWhileActive then
        probe.reason = "cache interface unavailable while active"
      elseif deltaCount == 0 then
        probe.reason = "no fluid detected"
      else
        probe.reason = "multiple fluids detected"
      end
      unresolved[#unresolved + 1] = probe
      print("  unresolved: " .. probe.reason .. "; cache={" .. changeText(probe.cacheDelta) .. "}")
    end
  end

  turnAllOffStrict()
  local missing = {}
  for _, fluid in ipairs(config.expectedFluids) do
    if not mapped[fluid] then missing[#missing + 1] = fluid end
  end
  local mappedCount = countEntries(mapped)
  local complete = mappedCount == #config.expectedFluids
    and #unresolved == 1
    and unresolved[1].reason == "no fluid detected"
  local unusedOutput = complete and unresolved[1] or nil
  local path = complete and config.outputFile or config.partialOutputFile
  writeResult(path, complete, mapped, complete and {} or unresolved, unusedOutput)

  print(string.format(
    "mapped=%d/%d unused=%d unresolved=%d",
    mappedCount,
    #config.expectedFluids,
    unusedOutput and 1 or 0,
    complete and 0 or #unresolved
  ))
  if #missing > 0 then print("missing fluids=" .. table.concat(missing, ",")) end
  if unusedOutput then
    print(string.format(
      "unused output=%s/%s (%s)",
      unusedOutput.address,
      unusedOutput.sideName,
      unusedOutput.reason
    ))
    print("this output remains OFF and is not used by the automation")
  end
  print("wrote " .. path)
  print("all probe outputs are OFF; remove the transferred test fluids from the cache subnet")
end

local function checkOnly()
  validateAndBind()
  local cache = readFluids(cacheInterface)
  local reference, referenceReason = tryReadFluids(referenceInterface)
  print("Read-only mapper check OK")
  print("  cache=" .. cacheInterface.address .. " fluids={" .. fluidSignature(cache) .. "}")
  print("  reference=" .. referenceInterface.address .. " fluids={"
    .. fluidSignature(reference or {}) .. "}")
  if not reference then print("  reference-read-warning=" .. tostring(referenceReason)) end
  for index, route in ipairs(outputs) do
    local value = tonumber(invoke(route.device, "getOutput", route.side))
    print(string.format(
      "  [%02d/%02d] %s/%s output=%s",
      index,
      #outputs,
      route.device.address,
      route.sideName,
      tostring(value)
    ))
  end
end

local args = { ... }
local command = args[1] or "run"
if command ~= "run" and command ~= "check" then
  fail("usage: lua bec_route_mapper.lua [check|run] [probe-seconds]")
end
if args[2] ~= nil then
  local timeout = tonumber(args[2])
  if not timeout or timeout < 1 or timeout > 300 then
    fail("probe-seconds must be a number from 1 to 300")
  end
  config.timings.probeTimeout = timeout
end

local ok, reason = xpcall(command == "check" and checkOnly or run, debug.traceback)
if controlsArmed then turnAllOffBestEffort() end
if not ok then
  io.stderr:write(tostring(reason) .. "\n")
  os.exit(1)
end
