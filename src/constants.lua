return {
  SELECT_OPTION = "(Select)",
  REFRESH_LIST_OPTION = " --  Refresh List",
  NONE_OPTION = "None",
  SHOW_PROPERTY = 0,
  HIDE_PROPERTY = 1,

  -- Bindings
  LIGHT_PROXY_BINDING_ID = 5001,
  BUTTON_BINDING_ID_TOP = 200,
  BUTTON_BINDING_ID_BOTTOM = 201,
  BUTTON_BINDING_ID_TOGGLE = 202,

  -- Button Actions
  BUTTON_ID_TOP = 0,
  BUTTON_ID_BOTTOM = 1,
  BUTTON_ID_TOGGLE = 2,
  BUTTON_ACTION_RELEASE = 0,
  BUTTON_ACTION_PRESS = 1,
  BUTTON_ACTION_CLICK = 2,
  BUTTON_ACTION_DOUBLE_CLICK = 3,
  BUTTON_ACTION_TRIPLE_CLICK = 4,

  -- Preset IDs
  DEFAULT_ON_COLOR_PRESET_ID = 1,
  DEFAULT_DIM_COLOR_PRESET_ID = 2,

  -- Preset Origins
  COLOR_PRESET_ORIGIN_INVALID = 0,
  COLOR_PRESET_ORIGIN_DEVICE = 1,
  COLOR_PRESET_ORIGIN_GLOBAL = 2,

  COLOR_MODE_FULL_COLOR = 0,
  COLOR_MODE_CCT = 1,

  TimerIds = {
    BRIGHTNESS_RAMP = "BrightnessRamp",
    BRIGHTNESS_RAMP_FINISHED = "BrightnessRampFinished",
    COLOR_RAMP = "ColorRamp",
    COLOR_RAMP_FINISHED = "ColorRampFinished",
    HYPERHDR_CONNECT = "HyperHDRConnect",
    LOG_MODE = "LogMode",
    CLEAR_SOURCES = "ClearSources",
    BRIGHTNESS_OFF = "BrightnessOff",
  },
  PersistKeys = {
    BRIGHTNESS_PRESET = "BrightnessPreset",
    BRIGHTNESS_RATE_DEFAULT = "BrightnessRateDefault",
    BUTTON_COLORS = "ButtonColors",
    CLICK_RATE_DOWN = "ClickRateDown",
    CLICK_RATE_UP = "ClickRateUp",
    COLOR_PRESETS = "ColorPresets",
    COLOR_RATE_DEFAULT = "ColorRateDefault",
    DEFAULT_SOURCE = "DefaultSource",
    DISCONNECT = "Disconnect",
    EFFECT = "Effect",
    HOLD_RATE_DOWN = "HoldRateDown",
    HOLD_RATE_UP = "HoldRateUp",
    OFF_COLOR = "OffColor",
    ON_COLOR = "OnColor",
    PRESET_LEVEL = "PresetLevel",
    TARGET_BRIGHTNESS = "TargetBrightness",
    TARGET_LIGHT_COLOR = "TargetLightColor",
  },

  HyperHDR = {
    Components = {
      HDR = "HDR",
      SMOOTHING = "SMOOTHING",
      BLACKBORDER = "BLACKBORDER",
      FORWARDER = "FORWARDER",
      VIDEOGRABBER = "VIDEOGRABBER",
      SYSTEMGRABBER = "SYSTEMGRABBER",
      LEDDEVICE = "LEDDEVICE",
    },
  },
}
