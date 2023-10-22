DRIVER_GITHUB_REPO = "black-ops-drivers/control4-hyperhdr"
DRIVER_FILENAMES = {
  "hyperhdr.c4z",
}
---
require("vendor.drivers-common-public.global.handlers")
require("vendor.drivers-common-public.global.lib")
require("vendor.drivers-common-public.global.timer")
require("vendor.drivers-common-public.global.url")

JSON = require("vendor.JSON")
WebSocket = require("vendor.drivers-common-public.module.websocket")

require("lib.utils")
local conditionals = require("lib.conditionals")
local log = require("lib.logging")
local persist = require("lib.persist")
local events = require("lib.events")
local githubUpdater = require("lib.github-updater")
local C = require("constants")

local hyperhdr = require("hyperhdr")

local SOURCE_OPTIONS = {
  Off = hyperhdr.NO_SOURCE,
  Color = hyperhdr.COLOR_SOURCE,
  Video = hyperhdr.VIDEO_SOURCE,
  Effect = hyperhdr.EFFECT_SOURCE,
}
local DEFAULT_SOURCE_OPTIONS = TableDeepCopy(SOURCE_OPTIONS)
DEFAULT_SOURCE_OPTIONS.Off = nil

-- HELPER FUNCTIONS --------------------------------------------------------------------------------
local function updateStatus(status)
  UpdateProperty("Driver Status", not IsEmpty(status) and status or "Unknown")
end

local function disconnect()
  log:trace("disconnect()")
  CancelTimer(C.TimerIds.HYPERHDR_CONNECT)
  hyperhdr:disconnect()
end

local function connect()
  log:trace("connect()")
  if not gInitialized or persist:get(C.PersistKeys.DISCONNECT, false) then
    return
  end

  local lastUpdateTime = os.time() -- Don't check for updates on the first cycle

  local heartbeat = function()
    local now = os.time()
    local secondsSinceLastUpdate = now - lastUpdateTime
    local secondsSinceLastSync = now - (hyperhdr:getLastSyncTime() or 0)

    if toboolean(Properties["Automatic Updates"]) and secondsSinceLastUpdate > (30 * 60) then
      log:info("Checking for driver update (timer expired)")
      lastUpdateTime = now
      UpdateDrivers()
    elseif not hyperhdr:isConnected() then
      log:info("Connecting to HyperHDR (timer expired)")
      hyperhdr:connect()
    elseif secondsSinceLastSync > (15 * 60) then
      log:info("Synchronizing with HyperHDR (timer expired)")
      hyperhdr:sync()
    end
  end

  -- Perform the initial refresh then schedule it on a repeating timer
  heartbeat()
  SetTimer(C.TimerIds.HYPERHDR_CONNECT, 15 * ONE_SECOND, heartbeat, true)
end

local function getAllButtonColors()
  log:trace("getAllButtonColors()")
  return persist:get(C.PersistKeys.BUTTON_COLORS, {
    [C.BUTTON_BINDING_ID_TOP] = { ON_COLOR = "0000ff", OFF_COLOR = "000000" },
    [C.BUTTON_BINDING_ID_BOTTOM] = { ON_COLOR = "0000ff", OFF_COLOR = "000000" },
    [C.BUTTON_BINDING_ID_TOGGLE] = { ON_COLOR = "0000ff", OFF_COLOR = "000000" },
  })
end

local function getButtonColors(bindingId)
  log:trace("getButtonColors(%s)", bindingId)
  return Select(getAllButtonColors(), bindingId)
end

local function setButtonColors(bindingId, onColor, offColor)
  log:trace("setButtonColors(%s, %s, %s)", bindingId, onColor, offColor)
  local buttonColors = getAllButtonColors()
  if buttonColors[bindingId] == nil then
    log:warn("Cannot set button colors for unknown button id %s", bindingId)
    return
  end
  buttonColors[bindingId] = {
    ON_COLOR = not IsEmpty(onColor) and onColor or buttonColors[bindingId].ON_COLOR,
    OFF_COLOR = not IsEmpty(offColor) and offColor or buttonColors[bindingId].OFF_COLOR,
  }
  persist:set(C.PersistKeys.BUTTON_COLORS, buttonColors)
end

local function lightColorChanging(x, y, mode, rate)
  log:trace("lightColorChanging(%s, %s, %s, %s)", x, y, mode, rate)
  persist:set(C.PersistKeys.TARGET_LIGHT_COLOR, { X = x, Y = y, mode = mode })
  local currentX, currentY = hyperhdr:getColorXY()
  SendToProxy(C.LIGHT_PROXY_BINDING_ID, "LIGHT_COLOR_CHANGING", {
    LIGHT_COLOR_TARGET_X = x,
    LIGHT_COLOR_TARGET_Y = y,
    LIGHT_COLOR_TARGET_COLOR_MODE = mode,
    LIGHT_COLOR_CURRENT_X = currentX,
    LIGHT_COLOR_CURRENT_Y = currentY,
    LIGHT_COLOR_CURRENT_COLOR_MODE = C.COLOR_MODE_FULL_COLOR,
    RATE = InRange(tointeger(rate), 0),
  }, "NOTIFY")
end

local function lightColorChanged(x, y, mode)
  log:trace("lightColorChanged(%s, %s, %s)", x, y, mode)
  persist:set(C.PersistKeys.TARGET_LIGHT_COLOR, { X = x, Y = y, mode = mode })
  hyperhdr:setColorXY(x, y)
  SendToProxy(C.LIGHT_PROXY_BINDING_ID, "LIGHT_COLOR_CHANGED", {
    LIGHT_COLOR_CURRENT_X = x,
    LIGHT_COLOR_CURRENT_Y = y,
    LIGHT_COLOR_CURRENT_COLOR_MODE = mode,
  }, "NOTIFY")
end

local function getColorPresets()
  log:trace("getColorPresets()")
  -- In "Previous" color on mode, dim color can be nil.
  local colorPresets = persist:get(C.PersistKeys.COLOR_PRESETS)
  if not IsEmpty(colorPresets) and not IsEmpty(colorPresets.onPreset) then
    return colorPresets.dimPreset, colorPresets.onPreset
  end
  return persist:get(C.PersistKeys.OFF_COLOR), persist:get(C.PersistKeys.ON_COLOR)
end

local function updateLightColorUsingPresets(brightness, brightnessTarget)
  log:trace("updateLightColorUsingPresets(%s, %s)", brightness, brightnessTarget)
  local offColor, onColor = getColorPresets()
  if not IsEmpty(onColor) and brightness == 0 and brightnessTarget > 0 then
    lightColorChanged(onColor.X, onColor.Y, onColor.mode)
  elseif not IsEmpty(offColor) and brightness > 0 and brightnessTarget == 0 then
    lightColorChanged(offColor.X, offColor.Y, offColor.mode)
  end
end

local function lightBrightnessChanging(targetBrightness, rate)
  log:trace("lightBrightnessChanging(%s, %s)", targetBrightness, rate)
  targetBrightness = InRange(tointeger(targetBrightness), 0, 100)
  rate = InRange(tointeger(rate) or 0, 0)
  persist:set(C.PersistKeys.TARGET_BRIGHTNESS, targetBrightness)
  SendToProxy(
    C.LIGHT_PROXY_BINDING_ID,
    "LIGHT_BRIGHTNESS_CHANGING",
    { LIGHT_BRIGHTNESS_TARGET = targetBrightness, RATE = rate },
    "NOTIFY"
  )
end

local function lightBrightnessChanged(brightness)
  log:trace("lightBrightnessChanged(%s)", brightness)
  brightness = InRange(tointeger(brightness), 0, 100)
  persist:set(C.PersistKeys.TARGET_BRIGHTNESS, brightness)
  hyperhdr:setBrightness(brightness)
  SendToProxy(C.LIGHT_PROXY_BINDING_ID, "LIGHT_BRIGHTNESS_CHANGED", { LIGHT_BRIGHTNESS_CURRENT = brightness }, "NOTIFY")
  -- TODO: Do we need this?
  --SendToProxy(
  --  C.LIGHT_PROXY_BINDING_ID,
  --  "LIGHT_LEVEL",
  --  tostring(brightness),
  --  "NOTIFY"
  --)
end

local function cancelBrightnessRampTimers()
  log:trace("cancelBrightnessRampTimers()")
  CancelTimer(C.TimerIds.BRIGHTNESS_RAMP)
  CancelTimer(C.TimerIds.BRIGHTNESS_RAMP_FINISHED)
  Timer[C.TimerIds.BRIGHTNESS_RAMP] = nil
  Timer[C.TimerIds.BRIGHTNESS_RAMP_FINISHED] = nil
end

local function brightnessRampFinished()
  log:trace("brightnessRampFinished()")
  cancelBrightnessRampTimers()
  local brightness = persist:get(C.PersistKeys.TARGET_BRIGHTNESS, hyperhdr:getBrightness())
  log:debug("Brightness ramp finished at %s%%", brightness)
  lightBrightnessChanged(brightness)
end

local function brightnessRampStopped()
  log:trace("brightnessRampStopped()")
  cancelBrightnessRampTimers()
  local brightness = hyperhdr:getBrightness()
  log:debug("Brightness ramp stopped at %s%%", brightness)
  lightBrightnessChanged(brightness)
end

local function rampToBrightness(level, rate)
  log:trace("rampToBrightness(%s, %s)", level, rate)
  level = InRange(tointeger(level) or 0, 0, 100)
  rate = InRange(tointeger(rate) or 0, 0)

  local startingLevel = hyperhdr:getBrightness()
  cancelBrightnessRampTimers()
  updateLightColorUsingPresets(startingLevel, level)

  if rate == 0 then
    lightBrightnessChanged(level)
    return
  end

  lightBrightnessChanging(level, rate)

  local cycleFrequency = 100
  local isIncreasing = startingLevel < level
  local changePerCycle = round((level - startingLevel) / (rate / cycleFrequency))
  if isIncreasing then
    changePerCycle = InRange(changePerCycle, 1, 100)
  else
    changePerCycle = InRange(changePerCycle, -100, -1)
  end
  local cycle
  cycle = function()
    local currentLevel = hyperhdr:getBrightness()
    if currentLevel == level then
      return
    end
    local nextLevel = tointeger(currentLevel + changePerCycle)
    if isIncreasing then
      -- Increasing
      hyperhdr:setBrightness(InRange(nextLevel, 0, level))
    else
      -- Decreasing
      hyperhdr:setBrightness(InRange(nextLevel, level, 100))
    end
    SetTimer(C.TimerIds.BRIGHTNESS_RAMP, cycleFrequency, cycle, false)
  end
  SetTimer(C.TimerIds.BRIGHTNESS_RAMP, cycleFrequency, cycle, false)
  SetTimer(C.TimerIds.BRIGHTNESS_RAMP_FINISHED, rate, brightnessRampFinished, false)
end

local function cancelColorRampTimers()
  log:trace("cancelColorRampTimers()")
  CancelTimer(C.TimerIds.COLOR_RAMP)
  CancelTimer(C.TimerIds.COLOR_RAMP_FINISHED)
  Timer[C.TimerIds.COLOR_RAMP] = nil
  Timer[C.TimerIds.COLOR_RAMP_FINISHED] = nil
end

local function colorRampFinished()
  log:trace("colorRampFinished()")
  cancelColorRampTimers()
  local x, y = hyperhdr:getColorXY()
  local color = persist:get(C.PersistKeys.TARGET_LIGHT_COLOR, {
    X = x,
    Y = y,
    mode = C.COLOR_MODE_FULL_COLOR,
  })
  log:debug("Color ramp finished at X=%s Y=%s mode=%s", color.X, color.Y, color.mode)
  lightColorChanged(color.X, color.Y, color.mode)
end

local function rampToColor(x, y, mode, rate)
  log:trace("rampToColor(%s, %s, %s, %s)", x, y, mode, rate)
  x = InRange(tonumber(x) or 0, 0, 1)
  y = InRange(tonumber(y) or 0, 0, 1)
  mode = tointeger(mode) or C.COLOR_MODE_FULL_COLOR
  rate = InRange(tointeger(rate) or 0, 0)

  cancelColorRampTimers()

  if rate == 0 then
    lightColorChanged(x, y, mode)
    return
  end

  lightColorChanging(x, y, mode, rate)

  local startingX, startingY = hyperhdr:getColorXY()
  local cycleFrequency = 75
  local changeXPerCycle = (x - startingX) / (rate / cycleFrequency)
  local changeYPerCycle = (y - startingY) / (rate / cycleFrequency)
  local cycle
  cycle = function()
    local currentX, currentY = hyperhdr:getColorXY()
    if currentX == x and currentY == y then
      return
    end
    local nextX = currentX + changeXPerCycle
    local nextY = currentY + changeYPerCycle
    if nextX > currentX then
      -- Increasing
      nextX = InRange(nextX, 0, x)
    else
      -- Decreasing
      nextX = InRange(nextX, x, 1)
    end
    if nextY > currentY then
      -- Increasing
      nextY = InRange(nextY, 0, y)
    else
      -- Decreasing
      nextY = InRange(nextY, y, 1)
    end
    hyperhdr:setColorXY(nextX, nextY)
    SetTimer(C.TimerIds.COLOR_RAMP, cycleFrequency, cycle, false)
  end
  SetTimer(C.TimerIds.COLOR_RAMP, cycleFrequency, cycle, false)
  SetTimer(C.TimerIds.COLOR_RAMP_FINISHED, rate, colorRampFinished, false)
end

local function getDefaultBrightnessRate()
  log:trace("getDefaultBrightnessRate()")
  return InRange(tointeger(persist:get(C.PersistKeys.BRIGHTNESS_RATE_DEFAULT, 0)) or 0, 0)
end

local function getDefaultColorRate()
  log:trace("getDefaultColorRate()")
  return InRange(tointeger(persist:get(C.PersistKeys.COLOR_RATE_DEFAULT, 0)) or 0, 0)
end

local function getPresetOnBrightness()
  log:trace("getPresetOnBrightness()")
  local brightnessPresetLevel =
    InRange(tointeger(Select(persist:get(C.PersistKeys.BRIGHTNESS_PRESET), "presetLevel")), 0, 100)
  if brightnessPresetLevel ~= nil then
    return brightnessPresetLevel
  end
  local presetLevel = InRange(tointeger(persist:get(C.PersistKeys.PRESET_LEVEL)), 0, 100)
  if presetLevel ~= nil then
    return presetLevel
  end
  return 100
end

local function getClickRateUp()
  log:trace("getClickRateUp()")
  return InRange(tointeger(persist:get(C.PersistKeys.CLICK_RATE_UP, 0)) or 0, 0)
end

local function getClickRateDown()
  log:trace("getClickRateDown()")
  return InRange(tointeger(persist:get(C.PersistKeys.CLICK_RATE_DOWN, 0)) or 0, 0)
end

local function getHoldRateUp()
  log:trace("getHoldRateUp()")
  return InRange(tointeger(persist:get(C.PersistKeys.HOLD_RATE_UP, 0)) or 0, 0)
end

local function getHoldRateDown()
  log:trace("getHoldRateDown()")
  return InRange(tointeger(persist:get(C.PersistKeys.HOLD_RATE_DOWN, 0)) or 0, 0)
end

local function setupExtras()
  log:trace("setupExtras()")
  local extrasXml = [[<extras_setup>
  <extra>
]]
  -- Source Select
  local sourceOptions = {
    {
      id = hyperhdr.COLOR_SOURCE,
      displayName = "Color",
    },
    {
      id = hyperhdr.VIDEO_SOURCE,
      displayName = "Video",
    },
    {
      id = hyperhdr.EFFECT_SOURCE,
      displayName = "Effect",
    },
  }
  extrasXml = extrasXml
    .. '    <section label="Source Select">\n'
    .. '      <object type="list" id="defaultSource" label="Default On Source" command="SET_DEFAULT_SOURCE" value="'
    .. hyperhdr:getDefaultSource()
    .. '">\n'
    .. '        <list maxselections="1" minselections="1">\n'
  for _, sourceOption in pairs(sourceOptions) do
    extrasXml = extrasXml
      .. '          <item text="'
      .. sourceOption.displayName
      .. '" value="'
      .. sourceOption.id
      .. '"/>\n'
  end
  extrasXml = extrasXml .. [[        </list>
      </object>
]]
  extrasXml = extrasXml
    .. '      <object type="list" id="currentSource" label="Current Source" command="SET_CURRENT_SOURCE" value="'
    .. hyperhdr:getSource()
    .. '" hidden="'
    .. (hyperhdr:getSource() == hyperhdr.NO_SOURCE and "true" or "false")
    .. '">\n'
    .. '        <list maxselections="1" minselections="1">\n'
  for _, sourceOption in pairs(sourceOptions) do
    extrasXml = extrasXml
      .. '          <item text="'
      .. sourceOption.displayName
      .. '" value="'
      .. sourceOption.id
      .. '"/>\n'
  end
  extrasXml = extrasXml .. [[        </list>
      </object>
]]
  extrasXml = extrasXml
    .. '      <object type="list" id="effect" label="Effect" command="SET_EFFECT" value="'
    .. (hyperhdr:getEffect() or "")
    .. '" hidden="'
    .. (hyperhdr:getSource() ~= hyperhdr.EFFECT_SOURCE and hyperhdr:getDefaultSource() ~= hyperhdr.EFFECT_SOURCE and "true" or "false")
    .. '">\n'
    .. '        <list maxselections="1" minselections="1">\n'
  for _, effect in pairs(hyperhdr:getEffects()) do
    extrasXml = extrasXml .. '          <item text="' .. effect.name .. '" value="' .. effect.name .. '"/>\n'
  end
  extrasXml = extrasXml .. [[        </list>
      </object>
    </section>
]]

  -- Components
  local components = hyperhdr:getComponents()
  extrasXml = extrasXml .. '    <section label="Components">\n'
  for _, component in pairs(components) do
    extrasXml = extrasXml
      .. '      <object type="switch" id="'
      .. component.id
      .. '" label="'
      .. component.displayName
      .. '" command="SET_COMPONENT_STATE" value="'
      .. (component.state and "true" or "false")
      .. '" hidden="'
      .. ((component.hidden or (component.state == nil)) and "true" or "false")
      .. '"/>\n'
  end
  extrasXml = extrasXml .. "    </section>\n"

  extrasXml = extrasXml .. [[  </extra>
</extras_setup>]]
  SendToProxy(C.LIGHT_PROXY_BINDING_ID, "EXTRAS_SETUP_CHANGED", { XML = MinifyXml(extrasXml) })
end

local function extrasStateChanged(objectId, tParams)
  log:trace("extrasStateChanged(%s, %s)", objectId, tParams)
  local extrasXml = [[<extras_state>
  <extra>
    <object id="]] .. objectId .. '" '
  for param, value in pairs(tParams or {}) do
    extrasXml = extrasXml .. tostring(param) .. '="' .. tostring(value) .. '" '
  end
  extrasXml = extrasXml .. [[/>
  </extra>
</extras_state>]]
  SendToProxy(C.LIGHT_PROXY_BINDING_ID, "EXTRAS_STATE_CHANGED", { XML = MinifyXml(extrasXml) })
end

local function updateExtrasDefaultSource(source)
  log:trace("updateExtrasDefaultSource(%s)", source)
  extrasStateChanged("defaultSource", {
    value = (not IsEmpty(source) and source or ""),
  })
end

local function updateExtrasCurrentSource(source)
  log:trace("updateExtrasCurrentSource(%s)", source)
  extrasStateChanged("currentSource", {
    value = (not IsEmpty(source) and source or ""),
    hidden = (source == hyperhdr.NO_SOURCE and true or false),
  })
end

local function updateExtrasComponent(id, state, hidden)
  log:trace("updateExtrasComponent(%s, %s, %s)", id, state, hidden)
  extrasStateChanged(id, {
    value = (state and true or false),
    hidden = ((hidden or state == nil) and true or false),
  })
end

local function updateExtrasEffect(effectName)
  log:trace("updateExtrasEffect(%s)", effectName)
  extrasStateChanged("effect", {
    value = not IsEmpty(effectName) and effectName or hyperhdr:getEffect(),
    hidden = hyperhdr:getSource() ~= hyperhdr.EFFECT_SOURCE
        and hyperhdr:getDefaultSource() ~= hyperhdr.EFFECT_SOURCE
        and true
      or false,
  })
end

local function getEffectNamesList()
  log:trace("getEffectNamesList()")
  local effectNames = {}
  for _, effect in pairs(hyperhdr:getEffects()) do
    table.insert(effectNames, effect.name)
  end
  return effectNames
end

-- INIT --------------------------------------------------------------------------------------------
function OnDriverLateInit()
  if not CheckMinimumVersion() then
    return
  end
  gInitialized = false
  log:setLogName(C4:GetDeviceData(C4:GetDeviceID(), "name"))
  log:setLogLevel(Properties["Log Level"])
  log:setLogMode(Properties["Log Mode"])
  log:trace("OnDriverLateInit()")

  C4:AllowExecute(true)
  C4:FileSetDir("c29tZXNwZWNpYWxrZXk=++11")
  events:restoreEvents()

  hyperhdr:setDefaultSource(persist:get(C.PersistKeys.DEFAULT_SOURCE))
  hyperhdr:setStatusCallback(updateStatus)
  hyperhdr:setOnConnectCallback(function()
    SendToProxy(C.LIGHT_PROXY_BINDING_ID, "ONLINE_CHANGED", { STATE = true }, "NOTIFY")
  end)
  hyperhdr:setOnDisconnectCallback(function()
    SendToProxy(C.LIGHT_PROXY_BINDING_ID, "ONLINE_CHANGED", { STATE = false }, "NOTIFY")
  end)
  hyperhdr:setOnSyncCallback(function()
    hyperhdr:setDefaultSource(persist:get(C.PersistKeys.DEFAULT_SOURCE, hyperhdr:getDefaultSource()))
    hyperhdr:setEffect(persist:get(C.PersistKeys.EFFECT, hyperhdr:getEffect()))
    setupExtras()

    for _, component in pairs(hyperhdr:getComponents()) do
      conditionals:upsertConditional("hyperhdr", tostring(component.id) .. "_state", {
        type = "BOOL",
        condition_statement = component.displayName .. " Component State",
        description = "NAME " .. component.displayName .. " component is STRING",
        true_text = "On",
        false_text = "Off",
      }, function(strConditionName, tParams)
        local isOn = toboolean(Select(hyperhdr.getComponents(), component.id, "state"))
        local test = Select(tParams, "VALUE") == "On"
        local result
        if Select(tParams, "LOGIC") == "NOT_EQUAL" then
          result = test ~= isOn
        else
          result = test == isOn
        end
        log:trace("TC condition=%s, tParams=%s, result -> %s", strConditionName, tParams, result)
        return result
      end)
      events:upsertEvent(
        "hyperhdr",
        tostring(component.id) .. "_state_changed",
        component.displayName .. " State Changed",
        "When NAME " .. component.displayName .. " state changes"
      )
    end
    conditionals:upsertConditional("hyperhdr", "current_source", {
      type = "LIST",
      condition_statement = "Current Source",
      description = "NAME current source is LOGIC STRING",
      list_items = table.concat(TableKeys(SOURCE_OPTIONS), ","),
    }, function(strConditionName, tParams)
      local testSource = Select(SOURCE_OPTIONS, Select(tParams, "VALUE"))
      local result
      if Select(tParams, "LOGIC") == "NOT_EQUAL" then
        result = testSource ~= hyperhdr:getSource()
      else
        result = testSource == hyperhdr:getSource()
      end
      log:trace("TC condition=%s, tParams=%s, result -> %s", strConditionName, tParams, result)
      return result
    end)
    events:upsertEvent(
      "hyperhdr",
      "current_source_changed",
      "Current Source Changed",
      "When NAME current source changes"
    )

    conditionals:upsertConditional("hyperhdr", "default_source", {
      type = "LIST",
      condition_statement = "Default Source",
      description = "NAME default source is LOGIC STRING",
      list_items = table.concat(TableKeys(DEFAULT_SOURCE_OPTIONS), ","),
    }, function(strConditionName, tParams)
      local testSource = Select(DEFAULT_SOURCE_OPTIONS, Select(tParams, "VALUE"))
      local result
      if Select(tParams, "LOGIC") == "NOT_EQUAL" then
        result = testSource ~= hyperhdr:getDefaultSource()
      else
        result = testSource == hyperhdr:getDefaultSource()
      end
      log:trace("TC condition=%s, tParams=%s, result -> %s", strConditionName, tParams, result)
      return result
    end)
    events:upsertEvent(
      "hyperhdr",
      "default_source_changed",
      "Default Source Changed",
      "When NAME default source changes"
    )

    conditionals:upsertConditional("hyperhdr", "effect", {
      type = "LIST",
      condition_statement = "Effect",
      description = "NAME effect is LOGIC STRING",
      list_items = table.concat(getEffectNamesList(), ","),
    }, function(strConditionName, tParams)
      local testEffect = Select(tParams, "VALUE")
      local result
      if Select(tParams, "LOGIC") == "NOT_EQUAL" then
        result = testEffect ~= hyperhdr:getEffect()
      else
        result = testEffect == hyperhdr:getEffect()
      end
      log:trace("TC condition=%s, tParams=%s, result -> %s", strConditionName, tParams, result)
      return result
    end)
    events:upsertEvent("hyperhdr", "effect_changed", "Effect Changed", "When NAME effect changes")
  end)
  hyperhdr:setBrightnessChangedCallback(function(brightness)
    if Timer[C.TimerIds.BRIGHTNESS_RAMP] == nil and Timer[C.TimerIds.BRIGHTNESS_RAMP_FINISHED] == nil then
      -- No brightness ramp in progress
      lightBrightnessChanged(brightness)
    end
  end)
  hyperhdr:setStateChangedCallback(function(isOn)
    if Timer[C.TimerIds.BRIGHTNESS_RAMP] == nil and Timer[C.TimerIds.BRIGHTNESS_RAMP_FINISHED] == nil then
      -- No brightness ramp in progress
      lightBrightnessChanged(hyperhdr:getBrightness())
    end
    SendToProxy(C.BUTTON_BINDING_ID_TOP, "MATCH_LED_STATE", { STATE = isOn })
    SendToProxy(C.BUTTON_BINDING_ID_BOTTOM, "MATCH_LED_STATE", { STATE = not isOn })
    SendToProxy(C.BUTTON_BINDING_ID_TOGGLE, "MATCH_LED_STATE", { STATE = isOn })
  end)
  hyperhdr:setSourceChangedCallback(function(source)
    updateExtrasCurrentSource(source)
    updateExtrasEffect()
    events:fire("hyperhdr", "current_source_changed")
  end)
  hyperhdr:setComponentChangedCallback(function(id, state, hidden)
    updateExtrasComponent(id, state, hidden)
    events:fire("hyperhdr", id .. "_state_changed")
  end)
  hyperhdr:setEffectChangedCallback(function(effectName)
    updateExtrasEffect(effectName)
    events:fire("hyperhdr", "effect_changed")
  end)
  hyperhdr:setColorXYChangedCallback(function(x, y)
    if Timer[C.TimerIds.COLOR_RAMP] == nil and Timer[C.TimerIds.COLOR_RAMP_FINISHED] == nil then
      -- No color ramp in progress
      lightColorChanged(x, y, C.COLOR_MODE_FULL_COLOR)
    end
  end)

  -- Fire OnPropertyChanged to set the initial Headers and other Property
  -- global sets, they'll change if Property is changed.
  for p, _ in pairs(Properties) do
    local status, err = pcall(OnPropertyChanged, p)
    if not status then
      log:error(err)
    end
  end
  gInitialized = true

  connect()
end

function OnDriverDestroyed()
  log:trace("OnDriverDestroyed()")
  disconnect()
end

function OPC.Server_IP(propertyValue)
  log:trace("OPC.Server_IP('%s')", propertyValue)
  hyperhdr:setIp(propertyValue)
  connect()
end

function OPC.Server_Port(propertyValue)
  log:trace("OPC.Server_Port('%s')", propertyValue)
  hyperhdr:setPort(propertyValue)
  connect()
end

function OPC.Token(propertyValue)
  log:trace("OPC.Token('%s')", not IsEmpty(propertyValue) and "****" or "")
  hyperhdr:setToken(propertyValue)
  connect()
end

function OPC.Driver_Version(propertyValue)
  log:trace("OPC.Driver_Version('%s')", propertyValue)
  UpdateProperty("Driver Version", C4:GetDriverConfigInfo("version"))
end

function OPC.Driver_Status(propertyValue)
  log:trace("OPC.Driver_Status('%s')", propertyValue)
  if not gInitialized then
    propertyValue = "Initializing"
    UpdateProperty("Driver Status", "Initializing")
  end
end

function OPC.Log_Mode(propertyValue)
  log:trace("OPC.Log_Mode('%s')", propertyValue)
  log:setLogMode(propertyValue)
  CancelTimer(C.TimerIds.LOG_MODE)
  if not log:isEnabled() then
    return
  end
  log:warn("Log mode '%s' will expire in 3 hours", propertyValue)
  SetTimer(C.TimerIds.LOG_MODE, 3 * ONE_HOUR, function()
    log:warn("Setting log mode to 'Off' (timer expired)")
    UpdateProperty("Log Mode", "Off", true)
  end)
end

function OPC.Log_Level(propertyValue)
  log:trace("OPC.Log_Level('%s')", propertyValue)
  log:setLogLevel(propertyValue)
  if log:getLogLevel() >= 6 and log:isPrintEnabled() then
    DEBUGPRINT = true
    DEBUG_TIMER = true
    DEBUG_RFN = true
    DEBUG_URL = true
    DEBUG_WEBSOCKET = true
  else
    DEBUGPRINT = false
    DEBUG_TIMER = false
    DEBUG_RFN = false
    DEBUG_URL = false
    DEBUG_WEBSOCKET = false
  end
end

-- COMMANDS ---------------------------------------------------------------------------------------

function EC.Synchronize()
  log:trace("EC.Synchronize()")
  if hyperhdr:isConnected() then
    log:print("Synchronizing with HyperHDR server")
    hyperhdr:sync()
  else
    log:print("Cannot synchronize when disconnected from the HyperHDR server")
  end
end

function EC.Connect()
  log:trace("EC.Connect()")
  log:print("Connecting to HyperHDR...")
  persist:delete(C.PersistKeys.DISCONNECT)
  connect()
end

function EC.Disconnect()
  log:trace("EC.Disconnect()")
  log:print("Disconnecting from HyperHDR")
  disconnect()
  persist:set(C.PersistKeys.DISCONNECT, true)
end

function RFP.GET_CONNECTED_STATE(idBinding, strCommand, tParams, args)
  log:trace("RFP.GET_CONNECTED_STATE(%s, %s, %s, %s)", idBinding, strCommand, tParams, args)
  SendToProxy(idBinding, "ONLINE_CHANGED", { STATE = hyperhdr:isConnected() }, "NOTIFY")
end

function RFP.SET_BRIGHTNESS_TARGET(idBinding, strCommand, tParams, args)
  log:trace("RFP.SET_BRIGHTNESS_TARGET(%s, %s, %s, %s)", idBinding, strCommand, tParams, args)
  local level = InRange(tointeger(Select(tParams, "LIGHT_BRIGHTNESS_TARGET")), 0, 100)
  local rate = InRange(tointeger(Select(tParams, "RATE")), 0)
  if level == nil then
    return
  end
  if rate == nil then
    rate = getDefaultBrightnessRate()
  end
  rampToBrightness(level, rate)
end

function RFP.SET_COLOR_TARGET(idBinding, strCommand, tParams, args)
  log:trace("RFP.SET_COLOR_TARGET(%s, %s, %s, %s)", idBinding, strCommand, tParams, args)
  local x = InRange(tonumber(Select(tParams, "LIGHT_COLOR_TARGET_X")), 0, 1)
  local y = InRange(tonumber(Select(tParams, "LIGHT_COLOR_TARGET_Y")), 0, 1)
  local mode = tointeger(Select(tParams, "LIGHT_COLOR_TARGET_MODE"))
  local rate = InRange(tointeger(Select(tParams, "LIGHT_COLOR_TARGET_RATE")), 0)
  if x == nil or y == nil or mode == nil then
    return
  end
  if rate == nil then
    rate = InRange(tointeger(Select(tParams, "RATE")), 0)
  end
  if rate == nil then
    rate = getDefaultColorRate()
  end
  rampToColor(x, y, mode, rate)
end

function RFP.SET_PRESET_LEVEL(idBinding, strCommand, tParams, args)
  log:trace("RFP.SET_PRESET_LEVEL(%s, %s, %s, %s)", idBinding, strCommand, tParams, args)
  local level = InRange(tointeger(Select(tParams, "LEVEL")), 0, 100)
  if level == nil then
    return
  end
  log:debug("Setting preset level to %s%%", level)
  persist:set(C.PersistKeys.PRESET_LEVEL, level)
  SendToProxy(C.LIGHT_PROXY_BINDING_ID, "PRESET_LEVEL", tostring(level), "NOTIFY")
end

function RFP.UPDATE_BRIGHTNESS_ON_MODE(idBinding, strCommand, tParams, args)
  log:trace("RFP.UPDATE_BRIGHTNESS_ON_MODE(%s, %s, %s, %s)", idBinding, strCommand, tParams, args)
  local presetId = InRange(tointeger(Select(tParams, "BRIGHTNESS_PRESET_ID")), 0)
  local presetLevel = InRange(tointeger(Select(tParams, "BRIGHTNESS_PRESET_LEVEL")), 0, 100)
  if presetId == nil or presetLevel == nil then
    return
  end
  log:debug("Setting preset brightness id=%s to %s%%", presetId, presetLevel)
  persist:set(C.PersistKeys.BRIGHTNESS_PRESET, { presetId = presetId, presetLevel = presetLevel })
end

function RFP.UPDATE_BRIGHTNESS_PRESET(idBinding, strCommand, tParams, args)
  log:trace("RFP.UPDATE_BRIGHTNESS_PRESET(%s, %s, %s, %s)", idBinding, strCommand, tParams, args)
  local command = Select(tParams, "COMMAND")
  local presetId = InRange(tointeger(Select(tParams, "ID")), 0)
  local presetLevel = InRange(tointeger(Select(tParams, "LEVEL")), 0, 100)
  if IsEmpty(command) or presetId == nil or presetLevel == nil then
    return
  end

  local currentPreset = persist:get(C.PersistKeys.BRIGHTNESS_PRESET)
  if Select(currentPreset, "presetId") ~= presetId then
    return
  end
  if command == "DELETED" then
    persist:delete(C.PersistKeys.BRIGHTNESS_PRESET)
  else
    currentPreset.presetLevel = presetLevel
    persist:set(C.PersistKeys.BRIGHTNESS_PRESET, currentPreset)
  end
end

function RFP.UPDATE_BRIGHTNESS_RATE_DEFAULT(idBinding, strCommand, tParams, args)
  log:trace("RFP.UPDATE_BRIGHTNESS_RATE_DEFAULT(%s, %s, %s, %s)", idBinding, strCommand, tParams, args)
  local rate = InRange(tointeger(Select(tParams, "RATE")), 0)
  if rate == nil then
    return
  end
  log:debug("Setting brightness rate default to %s", rate)
  persist:set(C.PersistKeys.BRIGHTNESS_RATE_DEFAULT, rate)
end

function RFP.UPDATE_COLOR_RATE_DEFAULT(idBinding, strCommand, tParams, args)
  log:trace("RFP.UPDATE_COLOR_RATE_DEFAULT(%s, %s, %s, %s)", idBinding, strCommand, tParams, args)
  local rate = InRange(tointeger(Select(tParams, "RATE")), 0)
  if rate == nil then
    return
  end
  log:debug("Setting color rate default to %s", rate)
  persist:set(C.PersistKeys.COLOR_RATE_DEFAULT, rate)
end

function RFP.SET_CLICK_RATE_UP(idBinding, strCommand, tParams, args)
  log:trace("RFP.SET_CLICK_RATE_UP(%s, %s, %s, %s)", idBinding, strCommand, tParams, args)
  local rate = InRange(tointeger(Select(tParams, "RATE")), 0)
  if rate == nil then
    return
  end
  log:debug("Setting click rate up to %s", rate)
  persist:set(C.PersistKeys.CLICK_RATE_UP, rate)
  SendToProxy(C.LIGHT_PROXY_BINDING_ID, "CLICK_RATE_UP", tostring(rate), "NOTIFY")
end

function RFP.SET_CLICK_RATE_DOWN(idBinding, strCommand, tParams, args)
  log:trace("RFP.SET_CLICK_RATE_DOWN(%s, %s, %s, %s)", idBinding, strCommand, tParams, args)
  local rate = InRange(tointeger(Select(tParams, "RATE")), 0)
  if rate == nil then
    return
  end
  log:debug("Setting click rate down to %s", rate)
  persist:set(C.PersistKeys.CLICK_RATE_DOWN, rate)
  SendToProxy(C.LIGHT_PROXY_BINDING_ID, "CLICK_RATE_DOWN", tostring(rate), "NOTIFY")
end

function RFP.SET_HOLD_RATE_UP(idBinding, strCommand, tParams, args)
  log:trace("RFP.SET_HOLD_RATE_UP(%s, %s, %s, %s)", idBinding, strCommand, tParams, args)
  local rate = InRange(tointeger(Select(tParams, "RATE")), 0)
  if rate == nil then
    return
  end
  log:debug("Setting hold rate up to %s", rate)
  persist:set(C.PersistKeys.HOLD_RATE_UP, rate)
  SendToProxy(C.LIGHT_PROXY_BINDING_ID, "HOLD_RATE_UP", tostring(rate), "NOTIFY")
end

function RFP.SET_HOLD_RATE_DOWN(idBinding, strCommand, tParams, args)
  log:trace("RFP.SET_HOLD_RATE_DOWN(%s, %s, %s, %s)", idBinding, strCommand, tParams, args)
  local rate = InRange(tointeger(Select(tParams, "RATE")), 0)
  if rate == nil then
    return
  end
  log:debug("Setting hold rate down to %s", rate)
  persist:set(C.PersistKeys.HOLD_RATE_DOWN, rate)
  SendToProxy(C.LIGHT_PROXY_BINDING_ID, "HOLD_RATE_DOWN", tostring(rate), "NOTIFY")
end

function RFP.BUTTON_ACTION(idBinding, strCommand, tParams, args)
  log:trace("RFP.BUTTON_ACTION(%s, %s, %s, %s)", idBinding, strCommand, tParams, args)
  if idBinding ~= C.LIGHT_PROXY_BINDING_ID then
    return
  end

  local buttonId = tointeger(Select(tParams, "BUTTON_ID") or -1)
  local action = tointeger(Select(tParams, "ACTION") or -1)

  if action == C.BUTTON_ACTION_CLICK then
    if buttonId == C.BUTTON_ID_TOP then
      rampToBrightness(getPresetOnBrightness(), getClickRateUp())
    elseif buttonId == C.BUTTON_ID_BOTTOM then
      rampToBrightness(0, getClickRateDown())
    elseif buttonId == C.BUTTON_ID_TOGGLE then
      if hyperhdr:isOn() then
        rampToBrightness(0, getClickRateDown())
      else
        rampToBrightness(getPresetOnBrightness(), getClickRateUp())
      end
    else
      return
    end
  elseif action == C.BUTTON_ACTION_PRESS then
    if buttonId == C.BUTTON_ID_TOP then
      rampToBrightness(getPresetOnBrightness(), getHoldRateUp())
    elseif buttonId == C.BUTTON_ID_BOTTOM then
      rampToBrightness(0, getHoldRateDown())
    elseif buttonId == C.BUTTON_ID_TOGGLE then
      if hyperhdr:isOn() then
        rampToBrightness(0, getHoldRateDown())
      else
        rampToBrightness(getPresetOnBrightness(), getHoldRateUp())
      end
    else
      return
    end
  elseif action == C.BUTTON_ACTION_RELEASE then
    if buttonId == C.BUTTON_ID_TOP then
      brightnessRampStopped()
    elseif buttonId == C.BUTTON_ID_BOTTOM then
      brightnessRampStopped()
    elseif buttonId == C.BUTTON_ID_TOGGLE then
      brightnessRampStopped()
    else
      return
    end
  else
    return
  end
  SendToProxy(C.LIGHT_PROXY_BINDING_ID, "BUTTON_ACTION", { BUTTON_ID = buttonId, ACTION = action }, "NOTIFY")
end

function RFP.REQUEST_BUTTON_COLORS(idBinding, strCommand, tParams, args)
  log:trace("RFP.REQUEST_BUTTON_COLORS(%s, %s, %s, %s)", idBinding, strCommand, tParams, args)
  local isOn = hyperhdr:isOn()
  if idBinding == C.BUTTON_BINDING_ID_TOP then
    SendToProxy(idBinding, "BUTTON_COLORS", getButtonColors(idBinding), "NOTIFY")
    SendToProxy(idBinding, "MATCH_LED_STATE", { STATE = isOn })
  elseif idBinding == C.BUTTON_BINDING_ID_BOTTOM then
    SendToProxy(idBinding, "BUTTON_COLORS", getButtonColors(idBinding), "NOTIFY")
    SendToProxy(idBinding, "MATCH_LED_STATE", { STATE = not isOn })
  elseif idBinding == C.BUTTON_BINDING_ID_TOGGLE then
    SendToProxy(idBinding, "BUTTON_COLORS", getButtonColors(idBinding), "NOTIFY")
    SendToProxy(idBinding, "MATCH_LED_STATE", { STATE = isOn })
  end
end

function RFP.SET_BUTTON_COLOR(idBinding, strCommand, tParams, args)
  log:trace("RFP.SET_BUTTON_COLOR(%s, %s, %s, %s)", idBinding, strCommand, tParams, args)
  local buttonId = tointeger(Select(tParams, "BUTTON_ID"))
  local onColor = Select(tParams, "ON_COLOR")
  local offColor = Select(tParams, "OFF_COLOR")
  if buttonId == C.BUTTON_ID_TOP then
    setButtonColors(C.BUTTON_BINDING_ID_TOP, onColor, offColor)
  elseif buttonId == C.BUTTON_ID_BOTTOM then
    setButtonColors(C.BUTTON_BINDING_ID_BOTTOM, onColor, offColor)
  elseif buttonId == C.BUTTON_ID_TOGGLE then
    setButtonColors(C.BUTTON_BINDING_ID_TOGGLE, onColor, offColor)
  else
    return
  end
  if not IsEmpty(onColor) then
    SendToProxy(idBinding, "BUTTON_INFO", { BUTTON_ID = buttonId, ON_COLOR = onColor }, "NOTIFY")
  end
  if not IsEmpty(offColor) then
    SendToProxy(idBinding, "BUTTON_INFO", { BUTTON_ID = buttonId, OFF_COLOR = offColor }, "NOTIFY")
  end
end

function RFP.UPDATE_COLOR_PRESET(idBinding, strCommand, tParams, args)
  log:trace("RFP.UPDATE_COLOR_PRESET(%s, %s, %s, %s)", idBinding, strCommand, tParams, args)
  local command = Select(tParams, "COMMAND")
  local presetId = tointeger(Select(tParams, "ID"))
  local x = InRange(tonumber(Select(tParams, "COLOR_X")), 0, 1)
  local y = InRange(tonumber(Select(tParams, "COLOR_Y")), 0, 1)
  local mode = tointeger(Select(tParams, "COLOR_MODE"))
  if IsEmpty(command) or presetId == nil or x == nil or y == nil or mode == nil then
    return
  end
  if command == "MODIFIED" or command == "ADDED" then
    local color = {
      X = x,
      Y = y,
      mode = mode,
    }
    if presetId == C.DEFAULT_ON_COLOR_PRESET_ID then
      persist:set(C.PersistKeys.ON_COLOR, color)
    elseif presetId == C.DEFAULT_DIM_COLOR_PRESET_ID then
      persist:set(C.PersistKeys.OFF_COLOR, color)
    end

    local colorPresets = persist:get(C.PersistKeys.COLOR_PRESETS)
    if IsEmpty(colorPresets) then
      return
    end
    local colorPreset
    if
      Select(colorPresets, "onPreset", "id") == presetId
      and Select(colorPresets, "onPreset", "origin") == C.COLOR_PRESET_ORIGIN_DEVICE
    then
      colorPreset = colorPresets.onPreset
    elseif
      Select(colorPresets, "dimPreset", "id") == presetId
      and Select(colorPresets, "dimPreset", "origin") == C.COLOR_PRESET_ORIGIN_DEVICE
    then
      colorPreset = colorPresets.dimPreset
    else
      return
    end

    if not IsEmpty(colorPreset) then
      colorPreset.X = x
      colorPreset.Y = y
      colorPreset.mode = mode
    end
    persist:set(C.PersistKeys.COLOR_PRESETS, colorPresets)
  end
end

local function createPreset(origin, id, x, y, mode)
  if origin == nil or origin == C.COLOR_PRESET_ORIGIN_INVALID or x == nil or y == nil or mode == nil then
    return nil
  end
  return {
    origin = origin,
    id = id,
    X = x,
    Y = y,
    mode = mode,
  }
end

function RFP.UPDATE_COLOR_ON_MODE(idBinding, strCommand, tParams, args)
  log:trace("RFP.UPDATE_COLOR_ON_MODE(%s, %s, %s, %s)", idBinding, strCommand, tParams, args)
  local colorPresets = {
    onPreset = createPreset(
      tointeger(Select(tParams, "COLOR_PRESET_ORIGIN")),
      tointeger(Select(tParams, "COLOR_PRESET_ID")),
      InRange(tonumber(Select(tParams, "COLOR_PRESET_COLOR_X")), 0, 1),
      InRange(tonumber(Select(tParams, "COLOR_PRESET_COLOR_Y")), 0, 1),
      tointeger(Select(tParams, "COLOR_PRESET_COLOR_MODE"))
    ),
    dimPreset = createPreset(
      tointeger(Select(tParams, "COLOR_FADE_PRESET_ORIGIN")),
      tointeger(Select(tParams, "COLOR_FADE_PRESET_ID")),
      InRange(tonumber(Select(tParams, "COLOR_FADE_PRESET_COLOR_X")), 0, 1),
      InRange(tonumber(Select(tParams, "COLOR_FADE_PRESET_COLOR_Y")), 0, 1),
      tointeger(Select(tParams, "COLOR_FADE_PRESET_COLOR_MODE"))
    ),
  }
  persist:set(C.PersistKeys.COLOR_PRESETS, not IsEmpty(colorPresets) and colorPresets or nil)
end

function RFP.DO_CLICK(idBinding, strCommand, tParams, args)
  log:trace("RFP.DO_CLICK(%s, %s, %s, %s)", idBinding, strCommand, tParams, args)
  if idBinding == C.BUTTON_BINDING_ID_TOP then
    rampToBrightness(getPresetOnBrightness(), getClickRateUp())
  elseif idBinding == C.BUTTON_BINDING_ID_BOTTOM then
    rampToBrightness(0, getClickRateDown())
  elseif idBinding == C.BUTTON_BINDING_ID_TOGGLE then
    if hyperhdr:isOn() then
      rampToBrightness(0, getClickRateDown())
    else
      rampToBrightness(getPresetOnBrightness(), getClickRateUp())
    end
  end
end

function RFP.DO_PUSH(idBinding, strCommand, tParams, args)
  log:trace("RFP.DO_PUSH(%s, %s, %s, %s)", idBinding, strCommand, tParams, args)
  if idBinding == C.BUTTON_BINDING_ID_TOP then
    rampToBrightness(getPresetOnBrightness(), getHoldRateUp())
  elseif idBinding == C.BUTTON_BINDING_ID_BOTTOM then
    rampToBrightness(0, getHoldRateDown())
  elseif idBinding == C.BUTTON_BINDING_ID_TOGGLE then
    if hyperhdr:isOn() then
      rampToBrightness(0, getHoldRateDown())
    else
      rampToBrightness(getPresetOnBrightness(), getHoldRateUp())
    end
  end
end

function RFP.DO_RELEASE(idBinding, strCommand, tParams, args)
  log:trace("RFP.DO_RELEASE(%s, %s, %s, %s)", idBinding, strCommand, tParams, args)
  if idBinding == C.BUTTON_BINDING_ID_TOP then
    brightnessRampStopped()
  elseif idBinding == C.BUTTON_BINDING_ID_BOTTOM then
    brightnessRampStopped()
  elseif idBinding == C.BUTTON_BINDING_ID_TOGGLE then
    brightnessRampStopped()
  end
end

function RFP.ON(idBinding, strCommand, tParams, args)
  log:trace("RFP.ON(%s, %s, %s, %s)", idBinding, strCommand, tParams, args)
  rampToBrightness(getPresetOnBrightness(), 0)
end

function RFP.OFF(idBinding, strCommand, tParams, args)
  log:trace("RFP.OFF(%s, %s, %s, %s)", idBinding, strCommand, tParams, args)
  rampToBrightness(0, 0)
end

function RFP.TOGGLE(idBinding, strCommand, tParams, args)
  log:trace("RFP.TOGGLE(%s, %s, %s, %s)", idBinding, strCommand, tParams, args)
  if hyperhdr:isOn() then
    rampToBrightness(0, 0)
  else
    rampToBrightness(getPresetOnBrightness(), 0)
  end
end

-- TODO: Do we need this?
--function RFP.SET_LEVEL(idBinding, strCommand, tParams, args)
--  log:trace("RFP.SET_LEVEL(%s, %s, %s, %s)", idBinding, strCommand, tParams, args)
--  local level = InRange(tointeger(Select(tParams, "LEVEL") or 0), 0, 100)
--  if level > 0 then
--    hyperhdr:setBrightness(level)
--  else
--    hyperhdr:off()
--  end
--end

-- TODO: Do we need this?
--function RFP.GET_LIGHT_LEVEL(idBinding, strCommand, tParams, args)
--  log:trace("RFP.GET_LIGHT_LEVEL(%s, %s, %s, %s)", idBinding, strCommand, tParams, args)
--  local isOn = hyperhdr:isOn()
--
--  SendToProxy(
--    C.LIGHT_PROXY_BINDING_ID,
--    "LIGHT_LEVEL",
--    isOn and tostring(hyperhdr:getBrightness()) or "0",
--    "NOTIFY"
--  )
--end

-- TODO: Do we need this?
--function RFP.RAMP_TO_LEVEL(idBinding, strCommand, tParams, args)
--  log:trace("RFP.RAMP_TO_LEVEL(%s, %s, %s, %s)", idBinding, strCommand, tParams, args)
--  RFP.SET_LEVEL(idBinding, strCommand, tParams, args)
--end

function RFP.SET_DEFAULT_SOURCE(idBinding, strCommand, tParams, args)
  log:trace("RFP.SET_DEFAULT_SOURCE(%s, %s, %s, %s)", idBinding, strCommand, tParams, args)
  hyperhdr:setDefaultSource(Select(tParams, "value"))
  local defaultSource = hyperhdr:getDefaultSource()
  persist:set(C.PersistKeys.DEFAULT_SOURCE, defaultSource)
  updateExtrasDefaultSource(defaultSource)
  updateExtrasEffect()
  events:fire("hyperhdr", "default_source_changed")
end

function RFP.SET_CURRENT_SOURCE(idBinding, strCommand, tParams, args)
  log:trace("RFP.SET_CURRENT_SOURCE(%s, %s, %s, %s)", idBinding, strCommand, tParams, args)
  hyperhdr:setSource(Select(tParams, "value"))
end

function RFP.SET_COMPONENT_STATE(idBinding, strCommand, tParams, args)
  log:trace("RFP.SET_COMPONENT_STATE(%s, %s, %s, %s)", idBinding, strCommand, tParams, args)
  hyperhdr:setComponentState(Select(tParams, "id"), toboolean(Select(tParams, "value")))
end

function RFP.SET_EFFECT(idBinding, strCommand, tParams, args)
  log:trace("RFP.SET_EFFECT(%s, %s, %s, %s)", idBinding, strCommand, tParams, args)
  hyperhdr:setEffect(Select(tParams, "value"))
  persist:set(C.PersistKeys.EFFECT, hyperhdr:getEffect())
end

function EC.Set_Current_Source(params)
  log:trace("EC.Set_Current_Source(%s)", params)
  local source = Select(SOURCE_OPTIONS, Select(params, "Source"))
  if IsEmpty(source) then
    return
  end
  hyperhdr:setSource(source)
end

function GCPL.Set_Current_Source(paramName)
  log:trace("GCPL.Set_Current_Source(%s)", paramName)
  if paramName ~= "Source" then
    return {}
  end
  local options = TableKeys(SOURCE_OPTIONS)
  table.sort(options)
  return options
end

function EC.Set_Default_On_Source(params)
  log:trace("EC.Set_Default_On_Source(%s)", params)
  local source = Select(DEFAULT_SOURCE_OPTIONS, Select(params, "Source"))
  if IsEmpty(source) then
    return
  end
  hyperhdr:setDefaultSource(source)
  local defaultSource = hyperhdr:getDefaultSource()
  persist:set(C.PersistKeys.DEFAULT_SOURCE, defaultSource)
  updateExtrasDefaultSource(defaultSource)
  updateExtrasEffect()
  events:fire("hyperhdr", "default_source_changed")
end

function GCPL.Set_Default_On_Source(paramName)
  log:trace("GCPL.Set_Default_On_Source(%s)", paramName)
  if paramName ~= "Source" then
    return {}
  end
  local options = TableKeys(DEFAULT_SOURCE_OPTIONS)
  table.sort(options)
  return options
end

function EC.Set_Effect(params)
  log:trace("EC.Set_Effect(%s)", params)
  hyperhdr:setEffect(Select(params, "Effect"))
  persist:set(C.PersistKeys.EFFECT, hyperhdr:getEffect())
end

function GCPL.Set_Effect(paramName)
  log:trace("GCPL.Set_Effect(%s)", paramName)
  if paramName ~= "Effect" then
    return {}
  end
  return getEffectNamesList()
end

function EC.Set_Component_State(params)
  log:trace("EC.Set_Component_State(%s)", params)
  local componentName = Select(params, "Component")
  local componentId
  for _, component in pairs(hyperhdr:getComponents()) do
    if component.displayName == componentName then
      componentId = component.id
    end
  end
  if IsEmpty(componentId) then
    return
  end
  hyperhdr:setComponentState(componentId, Select(params, "State") == "On")
end

function GCPL.Set_Component_State(paramName)
  log:trace("GCPL.Set_Component_State(%s)", paramName)
  if paramName ~= "Component" then
    return {}
  end
  local components = {}
  for _, component in pairs(hyperhdr:getComponents()) do
    table.insert(components, component.displayName)
  end
  return components
end

function EC.UpdateDrivers()
  log:trace("EC.UpdateDrivers()")
  log:print("Updating drivers")
  UpdateDrivers(true)
end

function UpdateDrivers(forceUpdate)
  log:trace("UpdateDrivers(%s)", forceUpdate)
  githubUpdater
    :updateAll(DRIVER_GITHUB_REPO, DRIVER_FILENAMES, Properties["Update Channel"] == "Prerelease", forceUpdate)
    :next(function(updatedDrivers)
      if not IsEmpty(updatedDrivers) then
        log:info("Updated driver(s): %s", table.concat(updatedDrivers, ","))
      else
        log:debug("No driver updates available")
      end
    end, function(error)
      log:error("An error occurred updating drivers; %s", error)
    end)
end
