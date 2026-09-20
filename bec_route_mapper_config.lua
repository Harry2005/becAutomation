local sides = require("sides")
local automation = require("bec_automation_config")

local expectedFluids = {}
for _, entry in ipairs(automation.fluids or {}) do
  expectedFluids[#expectedFluids + 1] = entry.source
end

return {
  schemaVersion = 1,

  cacheInterfaceAddress = automation.refill.cacheInterfaceAddress,

  -- 流体参考网络，需要网络中包含所有BEC要求流体。该项不必须，可直接填入物料缓存网络地址
  referenceInterfaceAddress = "cc50170d-ff67-438c-97c0-87ddedd06c8e",

  -- 自动补货流体路由红石IO。共19种流体，使用10个红石IO的上下两面；
  -- 其中19面控制流体，剩余1面留空。补货接口总控在主配置refill中单独设置。
  redstoneAddresses = {
    "5f8a7897-d7b8-4c4c-99da-a92c4c2dafe6",
    "cd96de69-f9ec-4dc0-a8a8-4fe2839c6cb6",
    "1414463a-c2b2-4d7b-9106-37f73b8a488e",
    "db21edf5-1106-43ce-b4ef-db89b01abfad",
    "62bdc14c-4332-446f-b943-c353ce63f67b",
    "4cd3a3cd-1b01-486b-9a22-45f7a8e986de",
    "aa5db45a-71f8-4f31-8147-568562a37da4",
    "e8da49ff-ba87-4e91-bebd-bc331f16359e",
    "5e5d00c9-36eb-49bb-bd65-86fe463702e0",
    "39ad7e90-1be7-4e86-acaa-f8f66425708c",
  },

  testSides = {
    { value = sides.down, name = "down" },
    { value = sides.up, name = "up" },
  },

  protectedControls = {
    {
      label = "material/item-cache whole-batch output",
      address = automation.redstone.nodeAddress,
      side = automation.redstone.nodeToggleSide,
    },
    {
      label = "material/fluid-cache whole-batch output",
      address = automation.redstone.generatorAddress,
      side = automation.redstone.generatorToggleSide,
    },
    {
      label = "automatic-refill/entangler AE toggle bus",
      address = automation.refill.entanglerAddress,
      side = automation.refill.entanglerToggleSide,
    },
    {
      label = "synthesis-active output",
      address = automation.redstone.synthesisAddress,
      side = automation.redstone.synthesisSide,
    },
    {
      label = "BEC automation HALT output",
      address = automation.redstone.haltAddress,
      side = automation.redstone.haltSide,
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
