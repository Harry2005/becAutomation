local MiB = 1024 * 1024
local function alignedCache(mebibytes, unit)
  return math.floor(mebibytes * MiB / unit) * unit
end

local config = {
  schemaVersion = 11,
  -- BEC机器地址。使用适配器连接（可用MFU避免机器正面被遮挡）
  -- storageAddress  约束场
  -- gateAddress     麦克斯韦磁通门
  storageAddress = "d8ca9388-f160-4049-ac32-dbe1a755ae3a",
  gateAddress = "da4ec6ec-b423-4da1-81e7-392fcb58ea04",

  -- 原料发配网络缓存接口。使用适配器连接ME接口
  cacheInterfaceAddress = "cc50170d-ff67-438c-97c0-87ddedd06c8e",
  cacheInterfaceType = "me_interface",

  -- 纠缠装置流体缓存与节点装配原料缓存。使用适配器连接ME接口
  buffers = {
    itemInterfaceAddress = "3261a6f1-6d7b-49ea-ae9e-edde7d457d50",
    fluidInterfaceAddress = "97d546bd-922b-4225-9b63-85b82541d958",
    interfaceType = "me_interface",
  },

  redstone = {
    -- 独立红石IO端口
    -- nodeAddress        输出。对应原料发配网络到节点装配原料缓存网络
    -- generatorAddress   输出。对应原料发配网络到纠缠装置流体缓存网络
    -- synthesisAddress   输出。当BEC正在处理配方时输出红石信号
    nodeAddress = "325408ed-a882-45b9-85c7-0a44d3833fe8",
    generatorAddress = "de4df182-4f5a-46a6-be77-626b26fd8bbc",
    synthesisAddress = "096e685f-f580-4fbf-8a88-702b1a96cbe2",
    -- 保护（HALT）状态红石输出，该输出连接到蜂群回收与观测阵列开关。当该信号为高时回收所有蜂群并停止观测阵列，保护当前配方不被销毁
    haltAddress = "ae241cc3-ba80-4f6a-8ec3-afac1943157f",
    -- 固定控制 I/O 六面同时输出，单块 I/O 不能复用给另一作用。
    connectSignal = 15,
    disconnectSignal = 0,
  },

  -- 流体自动补充相关配置
  refill = {
    -- 功能启用，设置为false禁用流体自动补充功能
    enabled = true,
    routeModule = "bec_fluid_routes",
    -- 流体自动补充缓存网络地址。使用适配器连接ME接口
    cacheInterfaceAddress = "90f03a21-99ee-4611-9dee-b6d6848e2431",
    cacheInterfaceType = "me_interface",
    -- 流体自动补货缓存输出红石IO。有红石信号时通过触发总线将补货缓存网络连接至纠缠装置
    entanglerAddress = "eb75eb2d-10b2-40d6-941c-5e0cc80a6ab3",
    -- 纠缠装置活动指示输入红石IO。使用活跃探测盖板检测纠缠装置是否工作，工作中输出红石信号
    activityAddress = "bd0a910a-69cb-4d69-a6c8-445135e89e97",
    activityThreshold = 1,
    connectSignal = 15,
    disconnectSignal = 0,
    poll = 0.05,
    routeTimeout = 30, -- 单路开启后缓存连续无增长的最长等待时间，单位秒
    -- 纠缠装置流体超时。若纠缠装置正在工作该超时计时器不生效
    conversionTimeout = 1800,
    checkInterval = 5,
    drainedWaitTimeout = 240,
  },

  ui = {
    enabled = true,
    width = 100,
    height = 30,
    refreshInterval = 1.0,
    processedRecipeFile = "/home/bec_processed_recipes.dat",
    fluidSettingsFile = "/home/bec_fluid_settings.dat",
  },

  -- 观测节点配置
  nodes = {
    -- 观测节点总数
    expectedCount = 16,
    -- 每个观测节点最大并行数
    maxParallelPerNode = 64,
    -- 观测节点OC地址。使用适配器连接，留空为自动发现
    addresses = {},
  },

  -- 流体缓存数量配置。语义如下：
  -- rateLitersPerSecond 直接填写 L/s；校准器 yy L / xx tick 对应 yy * 20 / xx L/s。
  -- 补货时保持该路红石输出，直到缓存网络中对应流体达到目标；此流速用于预计耗时，不远程修改校准器。
  -- { source = <"输入流体名称">, condensate = <"凝聚态流体名称">, unit = <单次处理最小数量>, target = alignedCache(<缓存目标数量，单位MiB>, <单次最小处理数量>), rateLitersPerSecond = <流速，单位L/s> }
  fluids = {
    { source = "molten.neutronium", condensate = "entangled_neutronium", unit = 144, target = alignedCache(128, 144), rateLitersPerSecond = 2880 },
    { source = "molten.cosmicneutronium", condensate = "entangled_cosmicneutronium", unit = 144, target = alignedCache(128, 144), rateLitersPerSecond = 2880 },
    { source = "molten.bedrockium", condensate = "entangled_bedrockium", unit = 144, target = alignedCache(6300, 144), rateLitersPerSecond = 576000 },
    { source = "molten.chromaticglass", condensate = "entangled_chromaticglass", unit = 144, target = alignedCache(128, 144), rateLitersPerSecond = 2880 },
    { source = "molten.celestialtungsten", condensate = "entangled_celestialtungsten", unit = 144, target = alignedCache(128, 144), rateLitersPerSecond = 2880 },
    { source = "molten.infinity", condensate = "entangled_infinity", unit = 144, target = alignedCache(128, 144), rateLitersPerSecond = 2880 },
    { source = "molten.hypogen", condensate = "entangled_hypogen", unit = 144, target = alignedCache(128, 144), rateLitersPerSecond = 2880 },
    { source = "molten.transcendentmetal", condensate = "entangled_transcendentmetal", unit = 144, target = alignedCache(128, 144), rateLitersPerSecond = 2880 },
    { source = "dimensionallyshiftedsuperfluid", condensate = "entangled_dimshiftedsuperfluid", unit = 1000, target = alignedCache(128, 1000), rateLitersPerSecond = 2880 },
    { source = "phononmedium", condensate = "entangled_phononmedium", unit = 1000, target = alignedCache(128, 1000), rateLitersPerSecond = 2880 },
    { source = "quarkgluonplasma", condensate = "entangled_quarkgluonplasma", unit = 1000, target = alignedCache(128, 1000), rateLitersPerSecond = 2880 },
    { source = "molten.spacetime", condensate = "entangled_spacetime", unit = 144, target = alignedCache(128, 144), rateLitersPerSecond = 2880 },
    { source = "temporalfluid", condensate = "entangled_time", unit = 144, target = alignedCache(128, 144), rateLitersPerSecond = 2880 },
    { source = "spatialfluid", condensate = "entangled_space", unit = 144, target = alignedCache(128, 144), rateLitersPerSecond = 2880 },
    { source = "boundlesscosmicsolder", condensate = "entangled_cosmicsolder", unit = 1000, target = alignedCache(128, 1000), rateLitersPerSecond = 2880 },
    { source = "molten.magnetohydrodynamicallyconstrainedstarmatter", condensate = "entangled_mhdcsm", unit = 144, target = alignedCache(16, 144), rateLitersPerSecond = 2880 },
    { source = "molten.magmatter", condensate = "entangled_magmatter", unit = 144, target = alignedCache(128, 144), rateLitersPerSecond = 2880 },
    { source = "molten.universium", condensate = "entangled_universium", unit = 144, target = alignedCache(128, 144), rateLitersPerSecond = 2880 },
    { source = "molten.eternity", condensate = "entangled_eternity", unit = 144, target = alignedCache(128, 144), rateLitersPerSecond = 2880 },
  },

  orderCounting = {
    -- 配方指纹与对应除数。用于处理自动并行配置
    fallbackDivisor = 1,
    recipeDivisors = {
      ["01f4a7e0"] = 2,
      ["074e8946"] = 64,
      ["136c78dc"] = 4,
      ["3b3d449b"] = 2,
      ["751d1813"] = 2,
      ["807691b7"] = 6,
      ["c3307e91"] = 4,
      ["fa6f4c32"] = 4,
      ["4f5dd565"] = 4,
      ["5823282a"] = 4,
      ["b02e3d7c"] = 4,
      ["5823282e"] = 4,
    },
    itemAliases = {
      ["dreamcraft:CircuitUEV0"] = "#circuitBio",
      ["gregtech:gt.metaitem.0332120"] = "#circuitBio",
      ["gregtech:gt.metaitem.0332156"] = "#circuitBio",
      ["gregtech:gt.metaitem.0332167"] = "#circuitBio",
      ["gregtech:gt.metaitem.0332170"] = "#circuitBio",
      ["dreamcraft:CircuitUIV0"] = "#circuitOptical",
      ["gregtech:gt.metaitem.0332157"] = "#circuitOptical",
      ["gregtech:gt.metaitem.0332168"] = "#circuitOptical",
      ["gregtech:gt.metaitem.0332171"] = "#circuitOptical",
      ["gregtech:gt.metaitem.0332174"] = "#circuitOptical",
      ["dreamcraft:PikoCircuit0"] = "#circuitExotic",
      ["dreamcraft:CircuitUMV0"] = "#circuitExotic",
      ["gregtech:gt.metaitem.0332169"] = "#circuitExotic",
      ["gregtech:gt.metaitem.0332172"] = "#circuitExotic",
      ["gregtech:gt.metaitem.0332175"] = "#circuitExotic",
      ["dreamcraft:QuantumCircuit0"] = "#circuitCosmic",
      ["dreamcraft:CircuitUXV0"] = "#circuitCosmic",
      ["gregtech:gt.metaitem.0332173"] = "#circuitCosmic",
      ["gregtech:gt.metaitem.0332176"] = "#circuitCosmic",
      ["dreamcraft:CircuitMAX0"] = "#circuitTranscendent",
      ["dreamcraft:PlanckCircuit0"] = "#circuitTranscendent",
      ["gregtech:gt.metaitem.0332177"] = "#circuitTranscendent",
    },
  },

  timings = {
    poll = 0.25,
    orderSettle = 1.0,
    emptySettle = 1.0,
    filterVerifyDelay = 0.15,
    nodeTransferPulse = 1.0,
    orderFluidTransferPulse = 1.0,
    nodeStartGrace = 3.0,
    condensateWaitTimeout = 4800,
    orderRunTimeout = 7200,
    statusInterval = 10,
    cooldown = 1.0,
  },

  safety = {
    allowZeroTargetStock = false,
    requireConfiguredStockAtStartup = false,
    allowFieldStrengthBelowCurrentStock = false,
  },

  logFile = "/home/bec_automation.log",
}

local addressFile = "/home/bec_installer_addresses.lua"
if require("filesystem").exists(addressFile) then
  local addresses = assert(loadfile(addressFile))()
  assert(type(addresses) == "table" and addresses.schemaVersion == 1,
    "invalid bec_installer_addresses.lua")
  config.storageAddress = addresses.storageAddress
  config.gateAddress = addresses.gateAddress
  config.cacheInterfaceAddress = addresses.cacheInterfaceAddress
  config.buffers.itemInterfaceAddress = addresses.itemInterfaceAddress
  config.buffers.fluidInterfaceAddress = addresses.fluidInterfaceAddress
  config.refill.cacheInterfaceAddress = addresses.refillCacheInterfaceAddress
  config.redstone.nodeAddress = addresses.nodeAddress
  config.redstone.generatorAddress = addresses.generatorAddress
  config.redstone.synthesisAddress = addresses.synthesisAddress
  config.redstone.haltAddress = addresses.haltAddress
  config.refill.entanglerAddress = addresses.entanglerAddress
  config.refill.activityAddress = addresses.activityAddress
  config.refill.installedRouteAddresses = addresses.routeAddresses
  config.nodes.addresses = addresses.nodeAddresses
end

local settingsFile = config.ui.fluidSettingsFile
assert(type(settingsFile) == "string" and settingsFile ~= "", "invalid fluidSettingsFile")
if require("filesystem").exists(settingsFile) then
  local file = assert(io.open(settingsFile, "r"))
  local contents = file:read("*a")
  file:close()
  local settings = assert(require("serialization").unserialize(contents),
    "invalid bec_fluid_settings.dat")
  assert(type(settings) == "table" and settings.schemaVersion == 3
      and type(settings.fluids) == "table",
    "obsolete fluid settings format; move /home/bec_fluid_settings.dat aside and configure L/s again")
  local recognized = {}
  for _, entry in ipairs(config.fluids) do
    recognized[entry.source] = true
    local values = settings.fluids[entry.source]
    assert(type(values) == "table" and type(values.target) == "number"
        and values.target >= 0 and values.target % 1 == 0
        and values.target <= 1000000 * MiB
        and values.target % entry.unit == 0
        and type(values.rateLitersPerSecond) == "number"
        and values.rateLitersPerSecond >= 0.001
        and values.rateLitersPerSecond <= 2147483,
      "invalid fluid settings for " .. entry.source)
    entry.target = values.target
    entry.rateLitersPerSecond = values.rateLitersPerSecond
  end
  for source in pairs(settings.fluids) do
    assert(recognized[source], "unknown fluid settings source " .. tostring(source))
  end
end

return config
