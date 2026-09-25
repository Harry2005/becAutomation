local computer = require("computer")
local event = require("event")
local keyboard = require("keyboard")
local term = require("term")

local M = {}
local Dashboard = {}
Dashboard.__index = Dashboard
local MiB = 1024 * 1024
local MAX_CACHE_MIB = 1000000
local MAX_RATE_LITERS = 2147483

local function litersPerSecond(rate)
  return (string.format("%.3f", rate):gsub("0+$", ""):gsub("%.$", ""))
end

local COLORS = {
  background = 0x111417,
  panel = 0x1B2025,
  header = 0x25313A,
  text = 0xD8DEE3,
  muted = 0x82909A,
  blue = 0x59A5D8,
  green = 0x6FCF97,
  yellow = 0xE6C56A,
  red = 0xEB6A6A,
}

local function clip(value, width)
  value = tostring(value or "")
  if width <= 0 then return "" end
  if #value <= width then return value end
  if width <= 3 then return value:sub(1, width) end
  return value:sub(1, width - 3) .. "..."
end

local function compact(value)
  local number = tonumber(value) or 0
  local units = {
    { 1e15, "P" },
    { 1e12, "T" },
    { 1e9, "G" },
    { 1e6, "M" },
    { 1e3, "K" },
  }
  for _, unit in ipairs(units) do
    if math.abs(number) >= unit[1] then
      local scaled = number / unit[1]
      if scaled >= 100 then return string.format("%.0f%s", scaled, unit[2]) end
      if scaled >= 10 then return string.format("%.1f%s", scaled, unit[2]) end
      return string.format("%.2f%s", scaled, unit[2])
    end
  end
  return string.format("%.0f", number)
end

local function integer(value)
  local text = string.format("%.0f", tonumber(value) or 0)
  local replacements
  repeat
    text, replacements = text:gsub("^(%-?%d+)(%d%d%d)", "%1,%2")
  until replacements == 0
  return text
end

local function fluidLabel(source)
  local aliases = {
    dimensionallyshiftedsuperfluid = "dimshifted",
    phononmedium = "phonon",
    quarkgluonplasma = "qgp",
    temporalfluid = "temporal",
    spatialfluid = "spatial",
    boundlesscosmicsolder = "cosmic_solder",
    ["molten.magnetohydrodynamicallyconstrainedstarmatter"] = "mhdcsm",
  }
  return aliases[source] or source:gsub("^molten%.", "")
end

local function stateText(states)
  local parts = {}
  for name, count in pairs(states or {}) do
    parts[#parts + 1] = name .. "=" .. tostring(count)
  end
  table.sort(parts)
  return #parts > 0 and table.concat(parts, " ") or "unavailable"
end

local function busText(value)
  if value == nil then return "?" end
  return value and "ON" or "OFF"
end

local function activityText(value)
  if value == nil then return "?" end
  return value and "RUN" or "IDLE"
end

local function progressLine(label, order, total, remaining, width)
  local prefix
  local suffix
  local ratio = 0
  if order then
    total = math.max(0, tonumber(total) or 0)
    remaining = math.max(0, tonumber(remaining) or 0)
    local completed = math.max(0, total - math.min(remaining, total))
    if total > 0 then ratio = math.min(1, completed / total) end
    prefix = string.format(" %-6s %5.1f%% ", label, ratio * 100)
    suffix = string.format(" %s/%s", compact(completed), compact(total))
  else
    prefix = string.format(" %-6s   --.-%% ", label)
    suffix = " no active order"
  end
  local barWidth = math.max(8, width - #prefix - #suffix - 2)
  local filled = math.floor(ratio * barWidth + 0.5)
  return prefix .. "[" .. string.rep("#", filled)
    .. string.rep("-", barWidth - filled) .. "]" .. suffix, ratio
end

function Dashboard:_colors(foreground, background)
  self.gpu.setForeground(foreground or COLORS.text, false)
  self.gpu.setBackground(background or COLORS.background, false)
end

function Dashboard:_line(y, text, foreground, background)
  if y < 1 or y > self.height then return end
  self:_colors(foreground, background)
  self.gpu.fill(1, y, self.width, 1, " ")
  self.gpu.set(1, y, clip(text, self.width))
end

function Dashboard:_cell(x, y, width, text, foreground, background)
  if y < 1 or y > self.height or x > self.width then return end
  width = math.min(width, self.width - x + 1)
  self:_colors(foreground, background)
  self.gpu.fill(x, y, width, 1, " ")
  self.gpu.set(x, y, clip(text, width))
end

function Dashboard:update(values, force, deferRender)
  for key, value in pairs(values or {}) do self.state[key] = value end
  if not deferRender then self:render(force) end
end

function Dashboard:log(level, message, timestamp)
  local logs = self.state.logs
  logs[#logs + 1] = {
    level = tostring(level or "INFO"),
    message = tostring(message or ""),
    timestamp = tonumber(timestamp) or computer.uptime(),
  }
  while #logs > self.logRows do table.remove(logs, 1) end
  self:render(false)
end

function Dashboard:render(force)
  if self.editorOpen then return end
  local now = computer.uptime()
  if not force and now - self.lastRender < self.refreshInterval then return end
  self.lastRender = now

  local state = self.state
  self:_line(1, " BEC AUTOMATION", COLORS.text, COLORS.header)
  local uptime = string.format("UP %.0fs", now)
  local uptimeX = self.width - #uptime
  local processed = "DONE " .. integer(state.processedRecipeTotal)
  local processedWidth = math.min(#processed, math.max(0, uptimeX - 18))
  self:_cell(uptimeX - processedWidth - 1, 1, processedWidth, processed, COLORS.green, COLORS.header)
  self:_cell(uptimeX, 1, #uptime + 1, uptime, COLORS.muted, COLORS.header)

  local phase = tostring(state.phase or "STARTING")
  local phaseColor = COLORS.blue
  if phase == "RUNNING" or phase == "READY" then phaseColor = COLORS.green end
  if phase == "WAITING" or phase == "REFILL" or phase == "STAGING" or phase == "RECOVERING" then
    phaseColor = COLORS.yellow
  end
  if phase == "ERROR" or phase == "HALT" then phaseColor = COLORS.red end
  self:_line(2, string.format(" %-10s %s", phase, state.detail or ""), phaseColor, COLORS.panel)

  local buses = string.format(
    "Move %s  Fluid %s  Refill %s  Craft %s  Halt %s  Ent %s",
    busText(state.nodeConnected),
    busText(state.fluidConnected),
    busText(state.refillConnected),
    busText(state.synthesisActive),
    busText(state.haltActive),
    activityText(state.entanglerActive)
  )
  self:_line(3, string.format(
    " Field %s  Stored %s  Staged %s  |  %s",
    compact(state.fieldStrength),
    compact(state.storedTotal),
    compact(state.refillStagedTotal),
    buses
  ), COLORS.text, COLORS.background)

  local order = state.order
  if order then
    self:_line(4, string.format(
      " Order x%s fp=%s  buffers=%sI/%sF  incoming=%sI/%sF  node-max=%s",
      tostring(order.count or "?"),
      tostring(order.fingerprint or "?"),
      compact(state.itemCacheTotal),
      compact(state.fluidCacheTotal),
      compact(state.cacheItemTotal),
      compact(state.cacheFluidTotal),
      tostring(state.nodeMaxParallel or "?")
    ), COLORS.text, COLORS.background)
  else
    self:_line(4, string.format(
      " Order none  incoming=%sI/%sF  buffers=%sI/%sF",
      compact(state.cacheItemTotal),
      compact(state.cacheFluidTotal),
      compact(state.itemCacheTotal),
      compact(state.fluidCacheTotal)
    ), COLORS.muted, COLORS.background)
  end

  self:_line(5, " Filters " .. table.concat(state.filters or {}, ", "), COLORS.blue, COLORS.background)
  self:_line(6, string.format(
    " Nodes %s  active-parallel=%s",
    stateText(state.nodeStates),
    compact(state.nodeParallel)
  ), COLORS.text, COLORS.background)
  local itemProgress, itemRatio = progressLine(
    "Items",
    order,
    order and order.itemTotal,
    state.orderRemainingItemTotal,
    self.width
  )
  local itemColor = order and COLORS.blue or COLORS.muted
  if order and itemRatio >= 1 then itemColor = COLORS.green end
  self:_line(7, itemProgress, itemColor, COLORS.background)
  local fluidProgress, fluidRatio = progressLine(
    "Fluids",
    order,
    order and order.fluidTotal,
    state.orderRemainingFluidTotal,
    self.width
  )
  local fluidColor = order and COLORS.yellow or COLORS.muted
  if order and fluidRatio >= 1 then fluidColor = COLORS.green end
  self:_line(8, fluidProgress, fluidColor, COLORS.background)
  self:_line(9, string.rep("-", self.width), COLORS.muted, COLORS.background)
  self:_line(10,
    " CONDENSATE CACHE  current / target  "
      .. (self.configRequested and "[CONFIG QUEUED]" or "[CONFIG]"),
    self.configRequested and COLORS.yellow or COLORS.muted, COLORS.panel)

  local columns = 2
  local rows = 10
  local cellWidth = math.floor(self.width / columns)
  local stored = state.condensates or {}
  self:_colors(COLORS.text, COLORS.background)
  self.gpu.fill(1, 11, self.width, rows, " ")
  for index, entry in ipairs(self.fluids) do
    local column = math.floor((index - 1) / rows)
    local row = (index - 1) % rows
    local x = column * cellWidth + 1
    local amount = stored[entry.condensate] or 0
    local percent = entry.target > 0 and math.floor(amount * 100 / entry.target) or 100
    local color = COLORS.red
    if percent >= 100 then color = COLORS.green elseif percent >= 50 then color = COLORS.yellow end
    local value = string.format(
      " %-15s %7s / %-7s %3d%%",
      clip(fluidLabel(entry.source), 15),
      compact(amount),
      compact(entry.target),
      math.min(percent, 999)
    )
    self:_cell(x, 11 + row, cellWidth, value, color, COLORS.background)
  end

  self:_line(21, string.rep("-", self.width), COLORS.muted, COLORS.background)
  self:_line(22, " RECENT EVENTS", COLORS.muted, COLORS.panel)
  for row = 1, self.logRows do
    local entry = state.logs[#state.logs - self.logRows + row]
    if entry then
      local color = COLORS.text
      if entry.level == "WARN" then color = COLORS.yellow end
      if entry.level == "ERROR" then color = COLORS.red end
      self:_line(22 + row, string.format(
        " %7.1f %-5s %s",
        entry.timestamp,
        entry.level,
        entry.message
      ), color, COLORS.background)
    else
      self:_line(22 + row, "", COLORS.text, COLORS.background)
    end
  end
end

function Dashboard:takeConfigRequest()
  if not self.configRequested then return false end
  self.configRequested = false
  return true
end

function Dashboard:hasConfigRequest()
  return self.configRequested == true
end

function Dashboard:editFluidSettings()
  local values = {}
  for index, entry in ipairs(self.fluids) do
    values[index] = {
      source = entry.source,
      condensate = entry.condensate,
      unit = entry.unit,
      target = entry.target,
      rateLitersPerSecond = entry.rateLitersPerSecond,
    }
  end
  local selected, field, editing, input, status = 1, 1, false, "", nil
  local targetX = self.width - 29
  local pulseX = self.width - 14
  self.editorOpen = true
  local ok, result = xpcall(function()
    while true do
      self:_colors(COLORS.text, COLORS.background)
      self.gpu.fill(1, 1, self.width, self.height, " ")
      self:_line(1, " BEC  /  FLUID CONFIG", COLORS.text, COLORS.header)
      self:_line(2, " Cache targets and calibrated flow rate", COLORS.muted, COLORS.background)
      self:_cell(1, 3, targetX - 1, " FLUID", COLORS.muted, COLORS.panel)
      self:_cell(targetX, 3, pulseX - targetX, " CACHE MiB", COLORS.muted, COLORS.panel)
      self:_cell(pulseX, 3, self.width - pulseX + 1, " L/s", COLORS.muted, COLORS.panel)
      for index, entry in ipairs(values) do
        local row = index + 3
        local selectedRow = index == selected
        local background = selectedRow and COLORS.header or COLORS.background
        self:_cell(1, row, targetX - 1,
          string.format(" %2d  %s", index, fluidLabel(entry.source)),
          selectedRow and COLORS.text or COLORS.muted, background)
        self:_cell(targetX, row, pulseX - targetX,
          string.format(" %.0f", math.floor(entry.target / MiB + 0.5)),
          selectedRow and field == 1 and COLORS.yellow or COLORS.text, background)
        self:_cell(pulseX, row, self.width - pulseX + 1,
          " " .. litersPerSecond(entry.rateLitersPerSecond),
          selectedRow and field == 2 and COLORS.yellow or COLORS.text, background)
      end
      if editing then
        local name = field == 1 and "CACHE MiB" or "L/s"
        self:_line(self.height - 2, " " .. (status or (name .. ": " .. input
          .. "_  Enter apply / Esc cancel")),
          COLORS.yellow, COLORS.panel)
      else
        self:_line(self.height - 2, " " .. (status or "Select a value to edit"),
          status and COLORS.yellow or COLORS.muted, COLORS.panel)
      end
      self:_line(self.height - 1,
        " [ SAVE ] S / click left       [ CANCEL ] Q / click right",
        COLORS.text, COLORS.header)
      local name, _, char, code = event.pull()
      if name == "key_down" then
        if editing then
          if code == keyboard.keys.enter then
            if input ~= "" then
              local amount = tonumber(input)
              local maximum = field == 1 and MAX_CACHE_MIB or MAX_RATE_LITERS
              if not amount or amount > maximum
                  or (field == 1 and amount % 1 ~= 0)
                  or (field == 2 and amount < 0.001) then
                status = "Invalid value (max " .. maximum .. (field == 2 and ", min 0.001" or "") .. ")"
              elseif field == 1 then
                values[selected].target = math.floor(amount * MiB / values[selected].unit)
                  * values[selected].unit
                editing, status = false, nil
              else
                values[selected].rateLitersPerSecond = math.floor(amount * 1000 + 0.5) / 1000
                editing, status = false, nil
              end
            else
              editing = false
            end
          elseif code == keyboard.keys.esc then
            editing, status = false, nil
          elseif code == keyboard.keys.back then
            input = input:sub(1, -2)
          elseif field == 2 and char == 46 and input ~= ""
              and not input:find(".", 1, true) and #input < 12 then
            input = input .. "."
          elseif char and char >= 48 and char <= 57 and #input < 12
              and (field ~= 2 or not input:match("%.%d%d%d$")) then
            input = input .. string.char(char)
          end
        elseif code == keyboard.keys.up then
          selected = math.max(1, selected - 1)
        elseif code == keyboard.keys.down then
          selected = math.min(#values, selected + 1)
        elseif code == keyboard.keys.left then
          field = 1
        elseif code == keyboard.keys.right then
          field = 2
        elseif code == keyboard.keys.enter then
          editing, input, status = true, "", nil
        elseif code == keyboard.keys.s then
          local total = 0
          for _, entry in ipairs(values) do total = total + entry.target end
          if total > 0 then return values end
          status = "At least one cache target must be positive"
        elseif code == keyboard.keys.q or code == keyboard.keys.esc then
          return nil
        end
      elseif name == "touch" then
        local x, y = char, code
        if y >= 4 and y <= 3 + #values then
          selected = y - 3
          if x >= targetX then
            field = x >= pulseX and 2 or 1
            editing, input, status = true, "", nil
          end
        elseif y >= self.height - 1 and not editing then
          if x <= self.width / 2 then
            local total = 0
            for _, entry in ipairs(values) do total = total + entry.target end
            if total > 0 then return values end
            status = "At least one cache target must be positive"
          else
            return nil
          end
        end
      end
    end
  end, debug.traceback)
  self.editorOpen = false
  self.configRequested = false
  self.lastRender = -math.huge
  self:render(true)
  if not ok then error(result, 0) end
  return result
end

function Dashboard:close()
  if self.touchListener then pcall(event.ignore, "touch", self.touchListener) end
  pcall(self.gpu.setForeground, self.oldForeground, false)
  pcall(self.gpu.setBackground, self.oldBackground, false)
  pcall(self.gpu.setResolution, self.oldWidth, self.oldHeight)
  pcall(term.setCursorBlink, self.oldCursorBlink)
  pcall(term.clear)
end

function M.new(options, fluids)
  options = options or {}
  if not term.isAvailable() then return nil, "GPU and screen are required for the dashboard" end
  local gpu = term.gpu()
  local maxWidth, maxHeight = gpu.maxResolution()
  if maxWidth < 80 or maxHeight < 25 then
    return nil, string.format("dashboard requires 80x25; GPU/screen supports %dx%d", maxWidth, maxHeight)
  end

  local oldWidth, oldHeight = gpu.getResolution()
  local width = math.min(maxWidth, math.max(80, tonumber(options.width) or 100))
  local height = math.min(maxHeight, math.max(25, tonumber(options.height) or 30))
  local self = setmetatable({
    gpu = gpu,
    width = width,
    height = height,
    logRows = math.max(3, height - 22),
    oldWidth = oldWidth,
    oldHeight = oldHeight,
    oldForeground = gpu.getForeground(),
    oldBackground = gpu.getBackground(),
    oldCursorBlink = term.getCursorBlink(),
    refreshInterval = math.max(0.1, tonumber(options.refreshInterval) or 0.25),
    lastRender = -math.huge,
    fluids = fluids or {},
    state = {
      phase = "STARTING",
      detail = "Binding components",
      processedRecipeTotal = 0,
      orderRemainingItemTotal = 0,
      orderRemainingFluidTotal = 0,
      cacheItemTotal = 0,
      cacheFluidTotal = 0,
      itemCacheTotal = 0,
      fluidCacheTotal = 0,
      haltActive = false,
      logs = {},
      filters = {},
      nodeStates = {},
      condensates = {},
    },
  }, Dashboard)

  gpu.setResolution(width, height)
  term.setCursorBlink(false)
  self:_colors(COLORS.text, COLORS.background)
  term.clear()
  self:render(true)
  self.screenAddress = gpu.getScreen()
  self.touchListener = function(_, screen, _, y)
    if not self.editorOpen and screen == self.screenAddress and y >= 10 and y <= 20 then
      self.configRequested = true
      self:render(true)
    end
  end
  event.listen("touch", self.touchListener)
  return self
end

return M
