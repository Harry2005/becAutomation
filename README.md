# 基于 OpenComputer 的 GTNH BEC 自动化

适用版本:GTNH 2.9.0-beta3

本目录是一套可直接部署到 OpenComputers 电脑的 BEC 集成自动化程序。它负责读取物质约束场中的凝聚态流体、识别订单、配置麦克斯韦磁通门和 16 个观测节点、在处理期间预取下一单、空闲补货，并在运行中流体不足时进入带红石联锁的自动恢复或 `HALT` 状态。

注意：使用前需按照提示修改对应文件中UUID配置。

## 文件说明

| 文件 | 用途 | 通常是否修改 |
| --- | --- | --- |
| `bec_automation.lua` | 主程序和状态机 | 否 |
| `bec_dashboard.lua` | 100x30 GPU 状态面板 | 否 |
| `bec_automation_config.lua` | 机器、AE 接口、固定红石 I/O、流体目标和配方计数配置 | 是 |
| `bec_route_mapper.lua` | 自动识别 19 种补货流体对应的红石 I/O 和方向 | 否 |
| `bec_route_mapper_config.lua` | 路由映射器的 10 个候选红石 I/O | 是 |
| `bec_fluid_routes.lua` | 路由映射器生成的“流体 -> 红石 I/O/方向”结果 | 自动生成 |

## 基本原理

### 四个隔离的 AE 网络

程序使用四个彼此隔离的 AE 网络。物料原料网络看不到两个目标缓存网络，整批转移由 ME 接口和红石控制的输出结构完成。

```text
主网订单
   |
   v
[物料原料网络 / income]
   | 物品整批脉冲                 | 流体整批脉冲
   v                              v
[节点物品缓存]                [纠缠装置流体缓存]
   |                              |
   v                              v
16 个观测节点                 纠缠装置 -> 约束场凝聚态缓存

[自动补货流体缓存] -- 单流体 1 秒脉冲 --> 纠缠装置
```

四个网络的职责如下：

| 网络 | OC 读取位置 | 职责 |
| --- | --- | --- |
| 物料原料网络 | `cacheInterfaceAddress` | 接收主网订单，暂存本单或下一单的物品和流体 |
| 节点物品缓存 | `buffers.itemInterfaceAddress` | 接收整批物品，并用于计算物品处理进度 |
| 纠缠装置流体缓存 | `buffers.fluidInterfaceAddress` | 接收订单流体，并用于计算流体处理进度 |
| 自动补货流体缓存 | `refill.cacheInterfaceAddress` | 空闲时按流体逐路向纠缠装置补货 |

物料网络向两个目标网络是主动整批输出。一次 1 秒脉冲表示“发送当前网络中该类物料”，目标网络不会被物料网络回读。因此程序分别读取三个 ME 接口来判断原料、物品缓存和流体缓存的真实状态。

### 一单订单的处理顺序

1. 程序等待物料原料网络的物品和流体快照稳定，防止主网正在发配时读取到半单。
2. 根据物品指纹查找 `recipeDivisors`，计算实际配方数量。未知指纹使用 `fallbackDivisor` 并输出警告。
3. 根据订单流体换算本单需要的凝聚态流体，并读取约束场当前库存。
4. 将场强提高到安全基线以上，为本单和已缓存凝聚态物质保留容量。
5. 对物料网络的流体输出发送一次 1 秒脉冲，把整批流体送入纠缠装置流体缓存。
6. 如果约束场库存不足，等待纠缠装置完成转换；库存足够时配置麦克斯韦磁通门过滤器。
7. 平均设置 16 个观测节点的并行：`min(ceil(配方数 / 16), 64)`。
8. 允许节点工作，并对物品输出发送一次 1 秒脉冲，将整批物品送入节点物品缓存。
9. 运行中以目标缓存剩余量显示物品和流体处理进度。
10. 节点物品缓存为空、所有节点均空闲且节点总并行为 0 后，本单完成并关闭生产路径。

### 运行时预取下一单

当前订单的物品进入节点缓存后，物料原料网络已经腾空，主网可以发配下一单。程序会继续观察物料网络：

- 下一单流体和物品稳定后，先把下一单流体整批送入纠缠装置缓存。
- 下一单物品仍留在物料原料网络，不会混入正在工作的节点缓存。
- 当前单完成后，已预取订单直接进入下一轮，再把对应物品送入节点缓存。
- 若运行中只出现流体而没有物品，程序将其视为可独立转移的流体批次；相同流体签名只发送一次，避免重复脉冲。
- 同配方追加发配不会用旧快照强行比较绝对数量；程序重新取得稳定快照后再更新预取订单。

### 空闲自动补货

每种源流体在 `fluids` 中独立配置：

```lua
{
  source = "molten.eternity",
  condensate = "entangled_eternity",
  unit = 144,
  target = alignedCache(128, 144),
  outputPerSecond = 2880000,
}
```

- `source`：自动补货网络中的普通流体名。
- `condensate`：约束场中的凝聚态流体名。
- `unit`：纠缠转换的最小处理单位。
- `target`：期望保留的凝聚态缓存量，单位 MmB；`alignedCache` 会向下对齐到完整处理单位。
- `outputPerSecond`：该路流体校准器实际每秒输出量，单位 mB/s。

空闲补货只在没有订单、纠缠装置已经停止、且补货功能启用时执行。程序先逐流体打开相应路由，再打开自动补货缓存到纠缠装置的 AE 路径。19 种流体由 10 块红石 I/O 的上、下两面控制，其中 19 面对应流体，剩余一面留空并始终保持低电平。补货接口由独立红石 I/O 控制；当前现场地址是 `eb75eb2d-10b2-40d6-941c-5e0cc80a6ab3` 的东面。

### 场强管理

程序不会把场强简单固定到配置目标总和：

- 启动和空闲时，场强至少覆盖当前实际凝聚态库存和配置基线。
- 接单时，在安全基线/当前库存的较大值之上追加本单需求量。
- 预取下一单或自动恢复流体时，会在转移前提高场强。
- 若库存已经高于配置基线，会保留更高的安全场强并记录警告。

因此补货过程也会调整场强，避免新生成的凝聚态物质没有容量。

### 运行中流体不足、自动恢复和 HALT

程序按每个工作节点报告的 `required - consumed` 汇总剩余凝聚态需求，并与约束场实时库存比较。

检测到不足时立即进入 `RECOVERING`：

1. `HALT` 红石输出保持为高，`synthesis-active` 也保持为高。
2. 关闭生产路径并禁止继续启动节点。
3. 如果物料原料网络中无物品、仅有流体，对流体输出发送一次 1 秒脉冲。
4. 等待纠缠装置活动信号结束，并等待流体缓存可处理量归零或稳定。
5. 重新读取约束场库存。满足剩余需求时释放 `HALT`，恢复节点并返回 `RUNNING`。
6. 没有可恢复流体、转换结束后仍不足、或等待超时，则锁定为红色 `HALT`，需要人工排查并重启程序。

重要限制：对 BEC I/O Node 调用 `setWorkAllowed(false)` 不能暂停一个已经开始的配方。GT5-Unofficial 中 `MTEBECIONode.notAllowedToWork_stopMachine_EM()` 是空实现。因此 `haltAddress` 的外部红石必须真正停止当前处理。当前现场方案是回收蜂群并关闭观测阵列；只接一个指示灯不具备保护作用。

### 状态面板

建议使用 100x30 屏幕。面板显示：

- 当前状态和运行时间；
- `DONE` 已处理配方总数；
- 本单物品进度和流体进度；
- 约束场缓存、场强、配方指纹、并行数和节点状态；
- 纠缠装置活动反馈、麦克斯韦门过滤器和最近日志。

主要状态：

| 状态 | 含义 |
| --- | --- |
| `STARTING` | 绑定组件并施加安全初态 |
| `WAITING` | 等待稳定订单 |
| `STAGING` / `READY` | 正在接收或已预取下一单 |
| `REFILL` | 空闲自动补货 |
| `PREPARING` | 提高场强、转移流体、配置门和节点 |
| `RUNNING` | 本单处理中 |
| `RECOVERING` | 已保持 HALT 输出，正在尝试补入缺失流体 |
| `HALT` | 自动恢复失败，联锁保持，需要人工处理 |

累计数保存在 `/home/bec_processed_recipes.dat`，并使用 `/home/bec_processed_recipes.dat.bak` 作为第二份有效副本；重启电脑后继续累计。同时删除这两个文件才会清零。

## 硬件与连接

### OC 电脑

电脑需要安装 OpenOS，并具备：

- T3机箱、内存、硬盘与APU, 建议使用 100x30 的屏幕；
- 足量 OC 网络线缆、分线器和适配器；
- 约束场、麦克斯韦磁通门、16 个观测节点和 4 个 ME 接口均接入同一 OC 组件网络；
- 所有固定红石 I/O 和 10 个补货路由红石 I/O 均接入该 OC 网络。

电脑无需 `Network` 扩展包或无线网卡。需要跨距离时可按现有机器布局使用 MFU，但 UUID 仍以 `discover` 的实际结果为准。

### 固定红石 I/O

以下六路不参与流体路由自动探测：

| 配置字段 | 方向 | 输入/输出 | 作用 |
| --- | --- | --- | --- |
| `redstone.nodeAddress` | `nodeToggleSide` | 输出 | 物料原料网络 -> 节点物品缓存，整批物品 1 秒脉冲 |
| `redstone.generatorAddress` | `generatorToggleSide` | 输出 | 物料原料网络 -> 纠缠装置流体缓存，整批流体 1 秒脉冲 |
| `redstone.synthesisAddress` | `synthesisSide` | 输出 | 本单开始到安全结束期间保持高电平 |
| `redstone.haltAddress` | `haltSide` | 输出 | `RECOVERING/HALT` 联锁；必须实际暂停蜂群/观测阵列 |
| `refill.entanglerAddress` | `entanglerToggleSide` | 输出 | 自动补货缓存 -> 纠缠装置的 AE 路径总控 |
| `refill.activityAddress` | `activitySide` | 输入 | 纠缠装置正在工作时为高电平 |

纠缠装置活动输入可使用无线活跃探测盖板汇总：配置为机器工作时发出信号，并接到 `activityAddress` 指定的一面。程序在该信号为高时不会仅靠固定延迟判定转换超时。

### 补货路由红石 I/O

`bec_route_mapper_config.lua` 的 `redstoneAddresses` 填写 10 块专用红石 I/O。程序测试每块的 `down` 和 `up`，共 20 路：

- 19 路分别控制 19 种源流体；
- 剩余 1 路不接设备，路由文件将其记录为 `unusedOutput`，主程序不会驱动该面；
- 补货缓存的 ME 接口输出由 `refill.entanglerAddress` / `entanglerToggleSide` 指定的独立红石 I/O 控制，不属于这 20 路；
- 19 个有效路由的高电平都必须只放行对应源流体；
- 每路的流体校准器必须按 `outputPerSecond` 标定，并且只支持整秒输出粒度。

`protectedControls` 会直接引用 `bec_automation_config.lua` 中的固定控制地址。它不是主程序的第二份控制配置，也不会写这些端口；路由映射器只读取并保护它们，发现固定控制 I/O 混入候选路由设备、端口不为低电平或组件缺失时会拒绝探测。迁移机器时先修改主配置，保护列表会自动跟随，无需再次抄 UUID。

## 安装与配置

### 1. 复制程序

将本目录六个 `.lua` 文件复制到 OC 电脑的 `/home`：

```text
/home/bec_automation.lua
/home/bec_dashboard.lua
/home/bec_automation_config.lua
/home/bec_route_mapper.lua
/home/bec_route_mapper_config.lua
/home/bec_fluid_routes.lua
```

保留原文件名，因为程序使用 `require()` 按这些名称加载模块。

### 2. 发现组件地址

确保所有组件已通过 OC 网络连接，执行：

```sh
bec_automation.lua discover
```

输出会列出 `bec_storage`、`bec_diode`、`bec_io_node`、`me_interface` 和 `redstone` 的地址及方法。


### 3. 编辑主配置

编辑 `/home/bec_automation_config.lua`，至少核对下列字段：

| 配置位置 | 填写内容 |
| --- | --- |
| `storageAddress` | 物质约束场 `bec_storage` 地址 |
| `gateAddress` | 麦克斯韦磁通门 `bec_diode` 地址 |
| `cacheInterfaceAddress` | 物料原料网络 ME 接口地址 |
| `buffers.itemInterfaceAddress` | 节点物品缓存网络 ME 接口地址 |
| `buffers.fluidInterfaceAddress` | 纠缠装置流体缓存网络 ME 接口地址 |
| `redstone.*Address` / `*Side` | 物品脉冲、流体脉冲、运行输出和 HALT 输出 |
| `refill.cacheInterfaceAddress` | 自动补货流体缓存网络 ME 接口地址 |
| `refill.entanglerAddress` / `entanglerToggleSide` | 自动补货到纠缠装置的 AE 路径总控 |
| `refill.activityAddress` / `activitySide` | 纠缠装置活动信号输入 |
| `nodes.addresses` | 可留空自动发现；同一 OC 网络有额外 BEC 节点时应显式填写 16 个地址 |

方向使用 `sides.east`、`sides.west`、`sides.north`、`sides.south`、`sides.up` 或 `sides.down`，并以红石 I/O 自身坐标方向为准。

然后逐项配置 `fluids`：

- `target` 是目标缓存，不是单次补货量；
- `outputPerSecond` 必须填写该路实测的每秒流量；
- `source`、`condensate` 和 `unit` 除非整套配方/流体名变化，否则不要随意修改；
- 若不需要空闲补货，将 `refill.enabled = false`。

`orderCounting.recipeDivisors` 用于把物品原料数量换算为实际配方数。日志出现 `unknown recipe fingerprint` 或识别数量成倍错误时，应先确认订单完整稳定，再把日志中的指纹和正确除数写入该表。例如原料快照是实际 4 倍时，除数设为 `4`。

### 4. 配置并生成补货路由

编辑 `/home/bec_route_mapper_config.lua`：

1. 在 `redstoneAddresses` 填入 10 块补货专用红石 I/O 地址。
2. `referenceInterfaceAddress` 填一个能够读到全部 19 种源流体名称的 ME 接口；该项目不必须，可直接使用物料原料网络接口。
3. 确认自动补货缓存为空、20 个被测输出均为低电平，并确认独立补货接口控制也是低电平。
4. 不要把任何固定控制 I/O 同时填入 `redstoneAddresses`。

先执行只读检查：

```sh
bec_route_mapper.lua check
```

检查通过后执行探测；`300` 是每一路允许观察的最长秒数，可按现场流速调整：

```sh
bec_route_mapper.lua run 1
```

映射器会逐路发出脉冲，比较自动补货缓存中新增的流体，并写入 `/home/bec_fluid_routes.lua`。运行期间不要手动向该缓存输入流体，也不要启动主自动化。

完成后检查生成文件：

- `complete = true`；
- `schemaVersion = 2`；
- `fluids` 中有全部 19 种源流体；
- `unusedOutput` 是唯一没有检测到流体的空闲面；
- `unresolved` 为空；任何条目都表示仍有未解决的映射异常。

### 5. 配置自检

执行：

```sh
bec_automation.lua check
```

该命令绑定组件并打印：机器、三个订单相关 ME 接口、固定红石 I/O、补货接口、活动输入、19 种流体目标/速率、麦克斯韦门和 16 个节点。必须先修复所有地址、组件类型、方法或路由错误，再继续。


### 6. 单轮试运行

先用小订单执行一次：

```sh
bec_automation.lua once
```

观察完整过程：订单稳定、流体进入纠缠缓存、场强上调、磁通门过滤器设置、物品进入节点缓存、进度下降、节点空闲、生产路径断开。测试结束后还应确认物料原料网络、节点物品缓存和纠缠流体缓存没有异常残留。

建议另外制造一次可控的凝聚态不足，确认面板进入黄色 `RECOVERING`、HALT 输出保持高、流体转换完成后能自动恢复；没有恢复材料时应转为红色 `HALT` 并继续保持联锁。

### 7. 正式运行

```sh
bec_automation.lua run
```

日志写入 `/home/bec_automation.log`。主程序退出或报错时会尽力关闭传输路径；但若已经进入 `HALT`，错误清理会故意保留 HALT 与合成活动输出，避免外部设备被错误释放。排障后重新运行程序，安全初始化才会重新施加完整初态。

需要开机启动时，可在确认 `run` 稳定后，把启动命令加入 OpenOS `/etc/rc.local`。


## 常见问题

### 红石地址报错 `must be a component address or unique prefix`

配置中的 UUID 不存在、只复制了错误前缀，或该红石 I/O 没有接入当前 OC 网络。用 `discover` 重新确认完整地址。UUID 不是红石频道名。

### 脉冲后没有物料进入目标网络

程序的整批传输脉冲默认是精确 1 秒。检查 `nodeTransferPulse`、`orderFluidTransferPulse`、红石方向、ME 输出结构、触发总线逻辑和目标网络供电。

### 配方完成后没有断开

完成条件不是只看物料原料网络。程序要求节点物品缓存为空、全部节点空闲、总并行为 0；纠缠装置仍工作时还会等待其活动输入结束，之后才允许空闲补货。检查目标缓存 ME 接口是否可读，以及节点状态方法是否正常返回。

### 配方数量识别成倍错误

查看日志中的 `fingerprint`、识别数量和实际产量。确认主网没有在快照稳定期间继续追加原料，然后为该指纹设置正确的 `recipeDivisors`。例如 `4f5dd565` 的当前现场除数为 `4`。

### `RECOVERING` 后仍进入 `HALT`

依次检查：物料网络是否真的只有流体、流体整批脉冲是否送达纠缠缓存、纠缠活动输入是否变化、场强是否足够、麦克斯韦门过滤器是否对应本单，以及 HALT 外部电路是否真正暂停处理。修复后重启主程序重新进行安全初始化。

### 麦克斯韦磁通门过滤器异常

磁通门由 OC 的 `getCondensateFilterAt` / `setCondensateFilterAt` 配置。不要在磁通门结构中放普通流体输入仓作为固定过滤来源；GT 的机器逻辑会按输入覆盖过滤器，导致 OC 设置被改写。
