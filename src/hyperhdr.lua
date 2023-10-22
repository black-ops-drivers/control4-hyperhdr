local log = require("lib.logging")

local C = require("constants")

local HyperHDR = {
  VIDEO_SOURCE = C.HyperHDR.Components.VIDEOGRABBER,
  COLOR_SOURCE = "COLOR",
  EFFECT_SOURCE = "EFFECT",
  NO_SOURCE = "NONE",
}

local DEFAULT_SOURCE = HyperHDR.COLOR_SOURCE
local EFFECT_PRIORITY = 1
local COLOR_PRIORITY = 1

local emptyCallback = function() end

function HyperHDR:new()
  log:trace("HyperHDR:new()")
  local properties = {
    _statusCallback = emptyCallback,
    _onConnectCallback = emptyCallback,
    _onDisconnectCallback = emptyCallback,
    _onSyncCallback = emptyCallback,
    _stateChangedCallback = emptyCallback,
    _sourceChangedCallback = emptyCallback,
    _brightnessChangedCallback = emptyCallback,
    _colorRGBChangedCallback = emptyCallback,
    _colorXYChangedCallback = emptyCallback,
    _componentChangedCallback = emptyCallback,
    _effectChangedCallback = emptyCallback,
    _webSocket = nil,
    --
    _ip = nil,
    _port = nil,
    _token = nil,
    --
    _lastSyncTime = nil,
    --
    _color = nil,
    _source = HyperHDR.NO_SOURCE,
    _defaultSource = DEFAULT_SOURCE,
    _sources = {},
    _effect = nil,
    _effects = nil,
    --
    _brightness = nil,
    _components = TableMap({
      {
        order = 1,
        id = C.HyperHDR.Components.HDR,
        displayName = "HDR (global)",
        state = nil,
      },
      {
        order = 2,
        id = C.HyperHDR.Components.SMOOTHING,
        displayName = "Smoothing",
        state = nil,
      },
      {
        order = 3,
        id = C.HyperHDR.Components.BLACKBORDER,
        displayName = "Blackbar Detection",
        state = nil,
      },
      {
        order = 4,
        id = C.HyperHDR.Components.FORWARDER,
        displayName = "Forwarder",
        state = nil,
      },
      {
        order = 5,
        id = C.HyperHDR.Components.VIDEOGRABBER,
        displayName = "USB Capture",
        state = nil,
        hidden = true,
      },
      {
        order = 6,
        id = C.HyperHDR.Components.SYSTEMGRABBER,
        displayName = "System Screen Capture",
        state = nil,
      },
      {
        order = 7,
        id = C.HyperHDR.Components.LEDDEVICE,
        displayName = "LED device",
        state = nil,
        hidden = true,
      },
    }, function(component)
      return component, component.id
    end),
  }
  setmetatable(properties, self)
  self.__index = self
  return properties
end

function HyperHDR:getComponents()
  log:trace("HyperHDR:getComponents()")
  local components = TableDeepCopy(TableValues(self._components))
  table.sort(components, function(a, b)
    return a.order < b.order and true or false
  end)
  return components
end

function HyperHDR:on()
  log:trace("HyperHDR:on()")
  self:setSource(self._defaultSource)
end

function HyperHDR:off()
  log:trace("HyperHDR:off()")
  self:setSource(self.NO_SOURCE)
end

function HyperHDR:isOn()
  log:trace("HyperHDR:isOn()")
  return (self._brightness or 0) > 0
    and (
      toboolean(
        Select(self._components, C.HyperHDR.Components.LEDDEVICE, "state")
          or toboolean(Select(self._components, C.HyperHDR.Components.LEDDEVICE, "pendingState"))
      )
    )
end

function HyperHDR:setStatusCallback(callback)
  log:trace("HyperHDR:setStatusCallback(%s)", callback)
  self._statusCallback = type(callback) == "function" and callback or emptyCallback
  self:_updateStatus()
end

function HyperHDR:_updateStatus(status)
  log:trace("HyperHDR:_updateStatus(%s)", status)
  if IsEmpty(status) then
    status = self:_getStatus()
  end
  self._statusCallback(status)
end

function HyperHDR:_getStatus()
  log:trace("HyperHDR:_getStatus()")
  if not self:hasServerConfiguration() then
    return "Not configured"
  elseif self:isConnected() then
    return "Connected"
  elseif self._webSocket ~= nil then
    return "Connecting"
  else
    return "Disconnected"
  end
end

function HyperHDR:setOnConnectCallback(callback)
  log:trace("HyperHDR:setOnConnectCallback(%s)", callback)
  self._onConnectCallback = type(callback) == "function" and callback or emptyCallback
end

function HyperHDR:setOnDisconnectCallback(callback)
  log:trace("HyperHDR:setOnDisconnectCallback(%s)", callback)
  self._onDisconnectCallback = type(callback) == "function" and callback or emptyCallback
end

function HyperHDR:setOnSyncCallback(callback)
  log:trace("HyperHDR:setOnSyncCallback(%s)", callback)
  self._onSyncCallback = type(callback) == "function" and callback or emptyCallback
end

function HyperHDR:setStateChangedCallback(callback)
  log:trace("HyperHDR:setStateChangedCallback(%s)", callback)
  self._stateChangedCallback = type(callback) == "function" and callback or emptyCallback
end

function HyperHDR:setSourceChangedCallback(callback)
  log:trace("HyperHDR:setSourceChangedCallback(%s)", callback)
  self._sourceChangedCallback = type(callback) == "function" and callback or emptyCallback
end

function HyperHDR:setBrightnessChangedCallback(callback)
  log:trace("HyperHDR:setBrightnessChangedCallback(%s)", callback)
  self._brightnessChangedCallback = type(callback) == "function" and callback or emptyCallback
end

function HyperHDR:setComponentChangedCallback(callback)
  log:trace("HyperHDR:setComponentChangedCallback(%s)", callback)
  self._componentChangedCallback = type(callback) == "function" and callback or emptyCallback
end

function HyperHDR:setColorRGBChangedCallback(callback)
  log:trace("HyperHDR:setColorRGBChangedCallback(%s)", callback)
  self._colorRGBChangedCallback = type(callback) == "function" and callback or emptyCallback
end

function HyperHDR:setColorXYChangedCallback(callback)
  log:trace("HyperHDR:setColorXYChangedCallback(%s)", callback)
  self._colorXYChangedCallback = type(callback) == "function" and callback or emptyCallback
end

function HyperHDR:setEffectChangedCallback(callback)
  log:trace("HyperHDR:setEffectChangedCallback(%s)", callback)
  self._effectChangedCallback = type(callback) == "function" and callback or emptyCallback
end

function HyperHDR:setIp(ip)
  log:trace("HyperHDR:setIp(%s)", ip)
  self._ip = not IsEmpty(ip) and ip or nil
end

function HyperHDR:setPort(port)
  log:trace("HyperHDR:setPort(%s)", port)
  self._port = toport(port)
end

function HyperHDR:setToken(token)
  log:trace("HyperHDR:setToken(%s)", not IsEmpty(token) and "****" or "")
  self._token = not IsEmpty(token) and token or nil
end

function HyperHDR:getIp()
  log:trace("HyperHDR:getIp()")
  return self._ip
end

function HyperHDR:getPort()
  log:trace("HyperHDR:getPort()")
  return self._port
end

function HyperHDR:getToken()
  log:trace("HyperHDR:getToken()")
  return self._token
end

function HyperHDR:getLastSyncTime()
  log:trace("HyperHDR:getLastSyncTime()")
  return self._lastSyncTime
end

function HyperHDR:hasServerConfiguration()
  log:trace("HyperHDR:hasServerConfiguration()")
  return not IsEmpty(self:getIp()) and not IsEmpty(self:getPort()) and not IsEmpty(self:getToken())
end

function HyperHDR:connect()
  log:trace("HyperHDR:connect()")
  if not self:hasServerConfiguration() then
    self:_updateStatus()
    return
  end
  local wsUrl = string.format("ws://%s:%d", self:getIp(), self:getPort())
  if self:isConnected() and self._webSocket.url == wsUrl then
    log:debug("HyperHDR connected")
  else
    self:disconnect()
    log:info("Connecting to %s...", wsUrl)
    local timeoutTimer = SetTimer(tostring(os.time()), 10 * ONE_SECOND, function()
      log:warn("WebSocket connection timed out")
      self:disconnect()
    end)
    self._webSocket = WebSocket:new(wsUrl)
      :SetEstablishedFunction(function()
        timeoutTimer:Cancel()
        log:info("Connection established with HyperHDR")
        -- Once a connection is established we have to authenticate.
        self:_requestRequiresAdminAuth()
        self:_updateStatus()
      end)
      :SetProcessMessageFunction(function(_, strData)
        if not IsEmpty(strData) then
          local success, data = pcall(JSON.decode, JSON, strData)
          if not success then
            local errorSuffix = ""
            if type(data) == "string" and not IsEmpty(data) then
              errorSuffix = " -> " .. data
            end
            log:warn("Received message that failed to decode: %s%s", strData, errorSuffix)
          else
            log:trace("Received message: %s", data)
            self:_processMessage(data)
          end
        end
      end)
      :SetClosedByRemoteFunction(function()
        log:warn("HyperHDR server disconnected")
        self:disconnect()
      end)
      :SetOfflineFunction(function()
        log:info("Connection offline")
        self:disconnect()
      end)
      :Start()
  end
  self:_updateStatus()
end

function HyperHDR:disconnect()
  log:trace("HyperHDR:disconnect()")
  if self._webSocket ~= nil then
    self._webSocket:delete()
  end
  self._webSocket = nil
  self:_onDisconnectCallback()
  self:_updateStatus()
end

function HyperHDR:isConnected()
  log:trace("HyperHDR:isConnected()")
  return self._webSocket ~= nil and self._webSocket.connected
end

function HyperHDR:sync()
  log:trace("HyperHDR:sync()")
  if not self:hasServerConfiguration() then
    log:debug("HyperHDR is not configured; skipping sync")
    return
  end
  if not self:isConnected() then
    log:debug("HyperHDR not connected; skipping sync")
    return
  end

  self:_requestInfo()
  self:_updateStatus()
end

function HyperHDR:getBrightness()
  log:trace("HyperHDR:getBrightness()")
  return self:isOn() and InRange(self._brightness or 0, 0, 100) or 0
end

function HyperHDR:setBrightness(brightness)
  log:trace("HyperHDR:setBrightness(%s)", brightness)
  brightness = InRange(tointeger(brightness or 0), 0, 100)
  if brightness == self:getBrightness() then
    return
  end
  self:_sendMessage({
    command = "adjustment",
    tan = 1,
    adjustment = {
      brightness = brightness,
    },
  })
  if brightness > 0 and not self:isOn() then
    self:on()
  elseif brightness == 0 then
    -- Debounce brightness as it changes to 0 when switching sources
    SetTimer(C.TimerIds.BRIGHTNESS_OFF, 2 * ONE_SECOND, function()
      if self:getBrightness() == 0 then
        self:off()
      end
    end)
  end
end

function HyperHDR:getColorRGB()
  log:trace("HyperHDR:getColorRGB()")
  return InRange(tointeger(Select(self._color, "red")), 0, 255),
    InRange(tointeger(Select(self._color, "green")), 0, 255),
    InRange(tointeger(Select(self._color, "blue")), 0, 255)
end

function HyperHDR:setColorRGB(red, green, blue, forceUpdate)
  log:trace("HyperHDR:setColorRGB(%s, %s, %s, %s)", red, green, blue, forceUpdate)
  red = InRange(tointeger(red or 0), 0, 255)
  green = InRange(tointeger(green or 0), 0, 255)
  blue = InRange(tointeger(blue or 0), 0, 255)
  if red == nil or green == nil or blue == nil then
    log:warn("Invalid color rgb(%s, %s, %s)", red, green, blue)
    return
  end
  local currentRed, currentGreen, currentBlue = self:getColorRGB()
  if not forceUpdate and red == currentRed and green == currentGreen and blue == currentBlue then
    return
  end
  if forceUpdate or self._source == self.COLOR_SOURCE then
    self:_sendMessage({
      command = "color",
      tan = 1,
      color = { red, green, blue },
      priority = COLOR_PRIORITY,
      duration = 0,
      origin = "Control4",
    })
  end
end

function HyperHDR:getColorXY()
  log:trace("HyperHDR:getColorXY()")
  local red, green, blue = self:getColorRGB()
  return C4:ColorRGBtoXY(red or 0, green or 0, blue or 0)
end

function HyperHDR:setColorXY(x, y)
  log:trace("HyperHDR:setColorXY(%s, %s)", x, y)
  local red, green, blue = C4:ColorXYtoRGB(x, y)
  self:setColorRGB(red, green, blue)
end

function HyperHDR:setComponentState(id, state)
  log:trace("HyperHDR:setComponentState(%s, %s)", id, state)
  local component = Select(self._components, id)
  if component == nil then
    return
  end
  state = toboolean(state)
  if state ~= Select(component, "state") then
    component.pendingState = state
    self:_sendMessage({
      command = "componentstate",
      tan = 1,
      componentstate = {
        component = id,
        state = state,
      },
    })
  end
end

function HyperHDR:getSource()
  log:trace("HyperHDR:getSource()")
  return not IsEmpty(self._source) and self._source or self.NO_SOURCE
end

function HyperHDR:setSource(source)
  log:trace("HyperHDR:setSource(%s)", source)
  if self._source == source then
    return
  end
  CancelTimer(C.TimerIds.CLEAR_SOURCES)
  if source == self.NO_SOURCE then
    self:setComponentState(C.HyperHDR.Components.VIDEOGRABBER, false)
    self:setComponentState(C.HyperHDR.Components.LEDDEVICE, false)
    self:_sendMessage({
      command = "clear",
      tan = 1,
      priority = -1,
    })
    return
  elseif source == self.VIDEO_SOURCE then
    self:setComponentState(C.HyperHDR.Components.VIDEOGRABBER, true)
    self:setComponentState(C.HyperHDR.Components.LEDDEVICE, true)
  elseif source == self.COLOR_SOURCE then
    local red, green, blue = self:getColorRGB()
    self:setColorRGB(red or 0, green or 0, blue or 0, true)
    self:setComponentState(C.HyperHDR.Components.LEDDEVICE, true)
    self:setComponentState(C.HyperHDR.Components.VIDEOGRABBER, false)
  elseif source == self.EFFECT_SOURCE then
    local effect = self:getEffect()
    self:setEffect(effect, true)
    self:setComponentState(C.HyperHDR.Components.LEDDEVICE, true)
    self:setComponentState(C.HyperHDR.Components.VIDEOGRABBER, false)
  end

  -- Clear all other sources other than the requested one after a delay.
  SetTimer(C.TimerIds.CLEAR_SOURCES, 3 * ONE_SECOND, function()
    for _, activeSource in pairs(self._sources or {}) do
      if Select(activeSource, "componentId") ~= source then
        self:_sendMessage({
          command = "clear",
          tan = 1,
          priority = activeSource.priority,
        })
      end
    end
  end)
end

function HyperHDR:getDefaultSource()
  log:trace("HyperHDR:getDefaultSource()")
  return self._defaultSource
end

function HyperHDR:setDefaultSource(source)
  log:trace("HyperHDR:setDefaultSource(%s)", source)
  if source == self.VIDEO_SOURCE or source == self.COLOR_SOURCE or source == self.EFFECT_SOURCE then
    self._defaultSource = source
  end
end

function HyperHDR:getEffects()
  log:trace("HyperHDR:getEffects()")
  local effects = TableDeepCopy(TableValues(self._effects))
  table.sort(effects, function(a, b)
    return a.order < b.order and true or false
  end)
  return effects
end

function HyperHDR:getEffect()
  log:trace("HyperHDR:getEffect()")
  local effect = Select(self._effect, "name")
  if not IsEmpty(effect) then
    return effect
  end
  return Select(self:getEffects(), 1, "name")
end

function HyperHDR:setEffect(effectName, forceUpdate)
  log:trace("HyperHDR:setEffect(%s, %s)", effectName, forceUpdate)
  local effect = Select(self._effects, effectName)
  if IsEmpty(effect) then
    log:warn("Unknown effect '%s'", effectName)
    return
  end
  if not forceUpdate and effectName == Select(self._effect, "name") then
    return
  end
  if forceUpdate or self._source == self.EFFECT_SOURCE then
    self:_sendMessage({
      command = "effect",
      tan = 1,
      effect = {
        name = effectName,
      },
      priority = EFFECT_PRIORITY,
      duration = 0,
      origin = "Control4",
    })
  end
end

local ON_COMMAND = {}

function HyperHDR:_requestRequiresAdminAuth()
  log:trace("HyperHDR:_requestRequiresAdminAuth()")
  self:_sendMessage({
    command = "authorize",
    tan = 1,
    subcommand = "adminRequired",
  })
end

function ON_COMMAND.authorize_adminRequired(hyperhdr, info)
  log:trace("ON_COMMAND.authorize_adminRequired(<hyperhdr>, %s)", info)
  if Select(info, "adminRequired") == true then
    hyperhdr:_requestAuthorization()
  else
    -- At this point we have a valid connection to HyperHDR
    hyperhdr:_onConnectCallback()
    hyperhdr:_requestInfo()
  end
end

function HyperHDR:_requestAuthorization()
  log:trace("HyperHDR:_requestAuthorization)")
  self:_sendMessage({
    command = "authorize",
    tan = 1,
    subcommand = "login",
    token = self:getToken(),
  })
end

function ON_COMMAND.authorize_login(hyperhdr, info)
  log:trace("ON_COMMAND.authorize_login(<hyperhdr>, %s)", info)
  -- At this point we have a valid connection to HyperHDR
  hyperhdr:_onConnectCallback()
  hyperhdr:_requestInfo()
end

function HyperHDR:_requestInfo()
  log:trace("HyperHDR:_requestInfo()")
  self:_sendMessage({
    command = "serverinfo",
    tan = 1,
    subscribe = {
      "adjustment-update",
      --"benchmark-update",
      "components-update",
      --"effects-update",
      --"grabberstate-update",
      --"imageToLedMapping-update",
      --"instance-update",
      "priorities-update",
      --"sessions-update",
      --"settings-update",
      --"videomode-update",
      --"videomodehdr-update",
    },
  })
end

function ON_COMMAND.serverinfo(hyperhdr, info)
  log:trace("ON_COMMAND.serverinfo(<hyperhdr>, %s)", info)
  for _, component in pairs(Select(info, "components") or {}) do
    ON_COMMAND.components_update(hyperhdr, component)
  end
  ON_COMMAND.adjustment_update(hyperhdr, info)
  ON_COMMAND.priorities_update(hyperhdr, info)

  hyperhdr._effects = {}
  for order, effect in pairs(Select(info, "effects") or {}) do
    if not string.match(effect.name, "^Music: ") then
      hyperhdr._effects[effect.name] = effect
      hyperhdr._effects[effect.name].order = order
    end
  end

  -- Signal the on sync callback
  hyperhdr._onSyncCallback()
end

function ON_COMMAND.adjustment_update(hyperhdr, info)
  log:trace("ON_COMMAND.adjustment_update(<hyperhdr>, %s)", info)

  local brightness = Select(info, "adjustment", 1, "brightness") or Select(info, 1, "brightness")
  if brightness ~= nil then
    brightness = InRange(tointeger(brightness), 0, 100)
    local isOnBefore = hyperhdr:isOn()
    local brightnessBefore = hyperhdr:getBrightness()

    hyperhdr._brightness = brightness

    local isOnAfter = hyperhdr:isOn()
    local brightnessAfter = hyperhdr:getBrightness()

    if isOnBefore ~= isOnAfter then
      hyperhdr._stateChangedCallback(isOnAfter)
    end
    if brightnessBefore ~= brightnessAfter then
      hyperhdr._brightnessChangedCallback(brightnessAfter)
      if brightnessBefore ~= nil then
        log:info("Brightness changed from %s%% to %s%%", brightnessBefore, brightnessAfter)
      end
    end
  end
end

function ON_COMMAND.adjustment(_, info)
  log:trace("ON_COMMAND.adjustment(<hyperhdr>, %s)", info)
  -- Nothing to do
end

function ON_COMMAND.components_update(hyperhdr, info)
  log:trace("ON_COMMAND.components_update(<hyperhdr>, %s)", info)
  local id = Select(info, "name")
  local component = Select(hyperhdr._components, id)
  if component == nil then
    return
  end

  -- Erase any pending state to not alter the actual current state
  component.pendingState = nil

  local enabled = toboolean(Select(info, "enabled"))

  local stateBefore = hyperhdr:isOn()
  local brightnessBefore = hyperhdr:getBrightness()
  local enabledBefore = component.state

  component.state = enabled

  local stateAfter = hyperhdr:isOn()
  local brightnessAfter = hyperhdr:getBrightness()
  local enabledAfter = component.state

  if stateBefore ~= stateAfter then
    hyperhdr._stateChangedCallback(stateAfter)
  end
  if brightnessBefore ~= brightnessAfter then
    hyperhdr._brightnessChangedCallback(brightnessAfter)
    if brightnessBefore ~= nil then
      log:info("Brightness changed from %s%% to %s%%", brightnessBefore, brightnessAfter)
    end
  end
  if enabledBefore ~= enabledAfter then
    hyperhdr._componentChangedCallback(id, enabledAfter, component.hidden or false)
    if enabledBefore ~= nil then
      log:info("Component %s turned %s", id, enabledAfter and "ON" or "OFF")
    end
  end
end

function ON_COMMAND.componentstate(_, info)
  log:trace("ON_COMMAND.componentstate(<hyperhdr>, %s)", info)
  -- Nothing to do
end

function ON_COMMAND.priorities_update(hyperhdr, info)
  log:trace("ON_COMMAND.priorities_update(<hyperhdr>, %s)", info)
  local visibleSource = hyperhdr.NO_SOURCE

  hyperhdr._sources = {}
  for _, priority in pairs(Select(info, "priorities") or {}) do
    local source = Select(priority, "componentId")

    if Select(priority, "componentId") == hyperhdr.COLOR_SOURCE then
      hyperhdr._sources[source] = priority
      if Select(priority, "visible") then
        visibleSource = source
      end

      local red = InRange(tointeger(Select(priority, "value", "RGB", 1)), 0, 255)
      local green = InRange(tointeger(Select(priority, "value", "RGB", 2)), 0, 255)
      local blue = InRange(tointeger(Select(priority, "value", "RGB", 3)), 0, 255)
      if red ~= nil and green ~= nil and blue ~= nil then
        local redBefore, greenBefore, blueBefore = hyperhdr:getColorRGB()

        hyperhdr._color = {
          red = red,
          green = green,
          blue = blue,
        }

        local redAfter, greenAfter, blueAfter = hyperhdr:getColorRGB()

        if redBefore ~= redAfter or greenBefore ~= greenAfter or blueBefore ~= blueAfter then
          local xAfter, yAfter = hyperhdr:getColorXY()
          hyperhdr._colorRGBChangedCallback(redAfter, greenAfter, blueAfter)
          hyperhdr._colorXYChangedCallback(xAfter, yAfter)
          if redBefore ~= nil and greenBefore ~= nil and blueBefore ~= nil then
            log:info(
              "Color changed from rgb(%s, %s, %s) to rgb(%s, %s, %s)",
              redBefore,
              greenBefore,
              blueBefore,
              redAfter,
              greenAfter,
              blueAfter
            )
          end
        end
      elseif type(Select(priority, "priority")) == "number" then
        -- Clear this invalid color
        hyperhdr:_sendMessage({
          command = "clear",
          tan = 1,
          priority = priority.priority,
        })
      end
    elseif Select(priority, "componentId") == hyperhdr.EFFECT_SOURCE then
      hyperhdr._sources[source] = priority
      if Select(priority, "visible") then
        visibleSource = source
      end
      local effect = Select(hyperhdr._effects, Select(priority, "owner"))
      if effect ~= nil then
        local effectNameBefore = Select(hyperhdr._effect, "name")

        hyperhdr._effect = effect

        local effectNameAfter = Select(hyperhdr._effect, "name")

        if effectNameBefore ~= effectNameAfter then
          hyperhdr._effectChangedCallback(effectNameAfter)
          if not IsEmpty(effectNameBefore) then
            log:info("Effect changed from %s to %s", effectNameBefore, effectNameAfter)
          end
        end
      elseif type(Select(priority, "priority")) == "number" then
        -- Clear this invalid effect
        hyperhdr:_sendMessage({
          command = "clear",
          tan = 1,
          priority = priority.priority,
        })
      end
    elseif Select(priority, "componentId") == hyperhdr.VIDEO_SOURCE then
      hyperhdr._sources[source] = priority
      if Select(priority, "visible") then
        visibleSource = source
      end
    else
      hyperhdr._sources[source] = priority
    end
  end

  local beforeSource = hyperhdr._source
  hyperhdr._source = visibleSource
  local afterSource = hyperhdr._source
  if beforeSource ~= afterSource then
    hyperhdr._sourceChangedCallback(afterSource)
    log:info("Source changed from %s to %s", beforeSource or hyperhdr.NO_SOURCE, afterSource or hyperhdr.NO_SOURCE)
  end
end

function ON_COMMAND.clear(_, info)
  log:trace("ON_COMMAND.clear(<hyperhdr>, %s)", info)
  -- Nothing to do
end

function ON_COMMAND.color(_, info)
  log:trace("ON_COMMAND.color(<hyperhdr>, %s)", info)
  -- Nothing to do
end

function ON_COMMAND.effect(_, info)
  log:trace("ON_COMMAND.effect(<hyperhdr>, %s)", info)
  -- Nothing to do
end

function HyperHDR:_processMessage(message)
  log:trace("HyperHDR:_processMessage(%s)", message)
  if Select(message, "success") == false then
    log:error("Previous message was unsuccessful: %s", message)
    return
  end
  local command = Select(message, "command") or ""
  command = string.gsub(command, "%W", "_")
  command = string.gsub(command, "[_]+", "_")
  command = string.gsub(command, "^[_| ]+", "")
  command = string.gsub(command, "[_| ]+$", "")

  local info = Select(message, "info") or Select(message, "data") or {}
  if not IsEmpty(command) and type(Select(ON_COMMAND, command)) == "function" then
    local success, value = pcall(ON_COMMAND[command], self, info)
    if not success then
      local errorSuffix = ""
      if type(value) == "string" and not IsEmpty(value) then
        errorSuffix = " -> " .. value
      end
      log:error("Error calling ON_COMMAND.%s(<hyperhdr>, %s)%s", command, info, errorSuffix)
    end
  else
    log:warn("No handler for message: %s", message)
  end
end

function HyperHDR:_sendMessage(message)
  log:trace("HyperHDR:_sendMessage(%s)", message)
  if message == nil then
    log:debug("Ignoring empty message")
    return
  end
  local data = JSON:encode(message)
  if IsEmpty(data) then
    log:debug("Ignoring empty message")
    return
  end
  if self:isConnected() then
    log:trace("Sending message: %s", data)
    self._webSocket:Send(data)
  else
    log:debug("Disconnected; dropping message: %s", data)
  end
end

return HyperHDR:new()
