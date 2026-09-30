import QtQuick
import Quickshell.Io
import Quickshell.Wayland

Item {
  id: root
  visible: false

  // Injected by omarchy-shell's singleton service loader.
  property var shell: null
  property var manifest: null

  readonly property string pluginId: manifest ? String(manifest.id) : "hz.auto-brightness"
  property bool automatic: true
  property int offsetPercent: 0
  property int speed: 2
  property int smoothing: 5
  property bool manualOverride: false
  property int lux: 0
  property int brightness: 0
  property int targetBrightness: 0
  property bool statusReady: false
  property string error: ""
  property bool settingsReady: false

  // Keyboard backlight. Driven from the same light readings; the backend keeps
  // reporting lux while display control is paused so this can run on its own.
  property string kbdDevice: ""
  property int kbdMax: 0
  property int kbdLevel: 0
  property bool kbdAuto: true
  property int kbdOnLevel: 1
  property int kbdOnLux: 8
  readonly property int kbdOffLux: kbdOnLux + 7   // dead band so it doesn't chatter at dusk
  property bool kbdIdle: true
  property int kbdIdleSeconds: 30
  property bool kbdDark: false
  property bool kbdManual: false
  property bool kbdParked: false
  property int kbdParkedLevel: 0
  property int kbdLastWritten: -1
  property bool kbdIdleRearming: false
  readonly property bool backendWanted: automatic || (kbdAuto && kbdDevice !== "")

  function clamp(value, minimum, maximum, fallback) {
    var number = Math.round(Number(value))
    if (!isFinite(number)) number = fallback
    return Math.max(minimum, Math.min(maximum, number))
  }

  function currentSettings() {
    var config = shell ? shell.barConfig : null
    var layout = config && config.layout ? config.layout : null
    if (!layout) return ({})

    var sections = ["left", "center", "right"]
    for (var s = 0; s < sections.length; s++) {
      var entries = layout[sections[s]]
      if (!Array.isArray(entries)) continue
      for (var i = 0; i < entries.length; i++) {
        var entry = entries[i]
        var id = typeof entry === "object" && entry !== null ? entry.id : entry
        if (String(id || "") === pluginId)
          return typeof entry === "object" && entry !== null ? entry : ({})
      }
    }
    return ({})
  }

  function applySettings() {
    if (!shell) return
    var settings = currentSettings()
    var nextAutomatic = settings.automatic === undefined ? true : settings.automatic === true
    var nextOffset = clamp(settings.offset, -20, 20, 0)
    var nextSpeed = clamp(settings.speed, 1, 5, 2)
    var nextSmoothing = clamp(settings.smoothing, 1, 10, 5)
    var tuningChanged = settingsReady &&
      (nextOffset !== offsetPercent || nextSpeed !== speed || nextSmoothing !== smoothing ||
       nextAutomatic !== automatic)

    kbdAuto = settings.kbdAuto === undefined ? true : settings.kbdAuto === true
    kbdOnLevel = clamp(settings.kbdLevel, 1, Math.max(1, kbdMax || 3), 1)
    kbdOnLux = clamp(settings.kbdOnLux, 1, 100, 8)
    kbdIdle = settings.kbdIdle === undefined ? true : settings.kbdIdle === true
    kbdIdleSeconds = clamp(settings.kbdIdleSeconds, 5, 300, 30)

    automatic = nextAutomatic
    offsetPercent = nextOffset
    speed = nextSpeed
    smoothing = nextSmoothing
    settingsReady = true

    if (!backendWanted) {
      restartTimer.stop()
      autoProcess.running = false
    } else if (tuningChanged || !autoProcess.running) {
      restart()
    }
  }

  function restart() {
    if (!backendWanted || !settingsReady) return
    statusReady = false
    manualOverride = false
    error = ""
    if (autoProcess.running) autoProcess.running = false
    restartTimer.restart()
  }

  function applyState(raw) {
    try {
      var state = JSON.parse(String(raw || "{}"))
      lux = Number(state.lux || 0)
      brightness = Number(state.brightness || 0)
      targetBrightness = Number(state.target || 0)
      manualOverride = state.manualOverride === true
      statusReady = true
      error = ""
      if (kbdDevice && !kbdPoll.running) kbdPoll.running = true
    } catch (parseError) {
      error = "Invalid automatic-brightness status"
    }
  }

  function writeKeyboard(level) {
    if (!kbdDevice) return
    kbdLastWritten = level
    kbdLevel = level
    kbdSet.command = ["brightnessctl", "-q", "-d", kbdDevice, "set", String(level)]
    kbdSet.running = true
  }

  // A level picked by hand sticks until the room crosses the on/off threshold.
  function setKeyboardLevel(level) {
    level = clamp(level, 0, kbdMax, 0)
    kbdManual = kbdAuto && level !== (kbdDark ? kbdOnLevel : 0)
    writeKeyboard(level)
  }

  function updateKeyboard() {
    if (!kbdDevice || !statusReady || kbdParked) return

    // Changed outside the plugin (keys, another tool): treat like a manual pick.
    if (kbdLastWritten >= 0 && kbdLevel !== kbdLastWritten) {
      kbdManual = kbdLevel !== (kbdDark ? kbdOnLevel : 0)
      kbdLastWritten = kbdLevel
    }

    var wasDark = kbdDark
    if (lux < kbdOnLux) kbdDark = true
    else if (lux > kbdOffLux) kbdDark = false
    if (kbdDark !== wasDark) kbdManual = false

    if (!kbdAuto || kbdManual) {
      kbdLastWritten = kbdLevel
      return
    }
    var wanted = kbdDark ? kbdOnLevel : 0
    if (wanted !== kbdLevel) writeKeyboard(wanted)
    else kbdLastWritten = kbdLevel
  }

  function handleKeyboardIdle(idle) {
    if (!kbdDevice) return
    if (idle) {
      if (kbdParked) return
      kbdParkedLevel = kbdLevel
      kbdParked = true
      if (kbdLevel > 0) writeKeyboard(0)
    } else {
      if (!kbdParked) return
      kbdParked = false
      if (kbdParkedLevel > 0) writeKeyboard(kbdParkedLevel)
      else kbdLastWritten = kbdLevel
    }
  }

  // IdleMonitor keeps the timeout it was created with, so rebuild it on change.
  onKbdIdleSecondsChanged: {
    kbdIdleRearming = true
    kbdRearmTimer.restart()
  }

  onBackendWantedChanged: if (settingsReady) applySettings()
  onShellChanged: if (shell) Qt.callLater(applySettings)
  Component.onCompleted: kbdFind.running = true

  Connections {
    target: root.shell
    function onBarConfigChanged() { root.applySettings() }
  }

  Timer {
    id: restartTimer
    interval: 100
    repeat: false
    onTriggered: {
      if (!root.automatic || !root.settingsReady) return
      autoProcess.command = [
        Qt.resolvedUrl("bin/auto-brightness").toString().replace(/^file:\/\//, ""),
        String(root.offsetPercent),
        String(root.speed),
        String(root.smoothing),
        root.automatic ? "1" : "0"
      ]
      autoProcess.running = true
    }
  }

  Process {
    id: autoProcess
    stdout: SplitParser { onRead: function(line) { root.applyState(line) } }
    stderr: SplitParser {
      onRead: function(line) {
        var message = String(line || "").trim()
        if (message) root.error = message
      }
    }
    onRunningChanged: {
      if (!running && root.backendWanted && root.settingsReady && !restartTimer.running)
        restartTimer.restart()
    }
  }

  Process {
    id: kbdSet
  }

  // brightnessctl -m: device,class,current,percent,max
  Process {
    id: kbdFind
    command: ["brightnessctl", "-l", "-m", "-c", "leds"]
    stdout: SplitParser {
      onRead: function(line) {
        var fields = String(line || "").split(",")
        if (root.kbdDevice || fields.length < 5 || fields[0].indexOf("kbd_backlight") < 0) return
        root.kbdMax = Number(fields[4]) || 0
        root.kbdLevel = Number(fields[2]) || 0
        root.kbdDevice = fields[0]
        root.kbdLastWritten = root.kbdLevel
      }
    }
  }

  Process {
    id: kbdPoll
    command: ["brightnessctl", "-m", "-d", root.kbdDevice]
    stdout: SplitParser {
      onRead: function(line) {
        var fields = String(line || "").split(",")
        if (fields.length < 5) return
        root.kbdLevel = Number(fields[2]) || 0
        root.updateKeyboard()
      }
    }
  }

  Timer {
    id: kbdRearmTimer
    interval: 250
    onTriggered: root.kbdIdleRearming = false
  }

  Loader {
    active: root.kbdIdle && root.kbdDevice !== "" && !root.kbdIdleRearming
    onActiveChanged: if (!active) root.handleKeyboardIdle(false)
    sourceComponent: IdleMonitor {
      timeout: root.kbdIdleSeconds
      respectInhibitors: true
      onIsIdleChanged: root.handleKeyboardIdle(isIdle)
    }
  }

  IpcHandler {
    target: "hz.auto-brightness-backend"

    function status(): string {
      return JSON.stringify({
        enabled: root.automatic,
        lux: root.lux,
        brightness: root.brightness,
        target: root.targetBrightness,
        manualOverride: root.manualOverride,
        offset: root.offsetPercent,
        speed: root.speed,
        smoothing: root.smoothing,
        keyboard: {
          device: root.kbdDevice,
          level: root.kbdLevel,
          max: root.kbdMax,
          auto: root.kbdAuto,
          onLevel: root.kbdOnLevel,
          onLux: root.kbdOnLux,
          dark: root.kbdDark,
          manual: root.kbdManual,
          idle: root.kbdIdle,
          idleSeconds: root.kbdIdleSeconds,
          parked: root.kbdParked
        },
        ready: root.statusReady,
        error: root.error
      })
    }

    function resume(): void { root.restart() }
  }
}
