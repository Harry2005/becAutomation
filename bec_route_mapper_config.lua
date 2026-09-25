local sides = require("sides")
local automation = require("bec_automation_config")
local routes = automation.refill and automation.refill.installedRouteAddresses
assert(type(routes) == "table" and #routes == 10,
  "run bec_installer.lua first: expected 10 route addresses in /home/bec_installer_addresses.lua")

local expectedFluids = {}
for _, entry in ipairs(automation.fluids or {}) do
  expectedFluids[#expectedFluids + 1] = entry.source
end

return {
  schemaVersion = 1,

  cacheInterfaceAddress = automation.refill.cacheInterfaceAddress,

  -- 流体参考网络，需要网络中包含所有BEC要求流体。该项不必须，可直接填入物料缓存网络地址
  referenceInterfaceAddress = automation.cacheInterfaceAddress,

  -- 自动补货流体路由红石IO。共19种流体，使用10个红石IO的上下两面；
  -- 其中19面控制流体，剩余1面留空。补货接口总控在主配置refill中单独设置。
  redstoneAddresses = routes,

  testSides = {
    { value = sides.down, name = "down" },
    { value = sides.up, name = "up" },
  },

  protectedControls = {
    {
      label = "material/item-cache whole-batch output",
      address = automation.redstone.nodeAddress,
    },
    {
      label = "material/fluid-cache whole-batch output",
      address = automation.redstone.generatorAddress,
    },
    {
      label = "automatic-refill/entangler AE toggle bus",
      address = automation.refill.entanglerAddress,
    },
    {
      label = "synthesis-active output",
      address = automation.redstone.synthesisAddress,
    },
    {
      label = "BEC automation HALT output",
      address = automation.redstone.haltAddress,
    },
    {
      label = "entangler activity input",
      address = automation.refill.activityAddress,
    },
  },

  expectedFluids = expectedFluids,
  allowNonEmptyCache = false,
  requireAllExpectedInReference = false,
  activeSignal = 15,
  inactiveSignal = 0,
  minDetectedDelta = 1,

  timings = {
    poll = 0.10,
    stableFor = 0.75,
    stableTimeout = 30,
    probeTimeout = 20,
    postOffDelay = 2,
    statusInterval = 2,
    recoveryTimeout = 10,
  },

  outputFile = "/home/bec_fluid_routes.lua",
  partialOutputFile = "/home/bec_fluid_routes.partial.lua",
}
