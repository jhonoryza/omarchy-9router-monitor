import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Bar pill for the 9Router dashboard.
//
// Text-only pill, no icon: the status line is the whole content. Idle shows
// the last model in the normal bar color. While traffic flows the label
// cycles through the rainbow plus a spinner and a gentle pulse. Expired
// session shows "login needed" in urgent — click to open login.
//
// NOTE: content goes through WidgetButton.text (the button's own label).
// Earlier revisions painted a custom Row inside the button while leaving
// text="" — WidgetButton treats empty text as "no visual content" and sets
// opacity 0, which blanked the whole pill. Status text is composed into one
// label string instead, the same way the keyboard-layout widget does.
BarWidget {
  id: root
  moduleName: "jhonoryza.9router"

  readonly property string pluginId: "jhonoryza.9router"
  readonly property bool showLabel: setting("showModelLabel", true) === true
    || String(setting("showModelLabel", "true")) === "true"
  property var svc: null

  function bindService() {
    if (root.svc) {
      pushSettings()
      return
    }
    var host = root.bar && root.bar.shell ? root.bar.shell : null
    if (!host || typeof host.serviceFor !== "function") return
    var s = host.serviceFor(root.pluginId)
    if (!s) return
    root.svc = s
    pushSettings()
    injectPanel()
  }

  function pushSettings() {
    if (!root.svc) return
    root.svc.baseUrl = String(setting("baseUrl", "http://localhost:20128") || "http://localhost:20128")
    var secs = parseInt(setting("refreshSeconds", 5), 10)
    root.svc.refreshSeconds = isFinite(secs) ? Math.max(2, Math.min(120, secs)) : 5
    var remember = setting("rememberPassword", true)
    root.svc.rememberPassword = remember === true || String(remember) === "true"
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
    if ("service" in target) target.service = root.svc
  }

  function refresh() {
    if (root.svc && typeof root.svc.refresh === "function") root.svc.refresh()
    else bindService()
  }

  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }

  function openDashboard() {
    if (root.svc && typeof root.svc.openDashboard === "function") root.svc.openDashboard()
    else Qt.openUrlExternally(String(setting("baseUrl", "http://localhost:20128")) + "/dashboard/usage")
  }

  // Shape contract for shell.summon/hide/toggle routing.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item && panelLoader.item.openFromHotkey) panelLoader.item.openFromHotkey()
  }

  function close() {
    if (panelLoader.item && panelLoader.item.close) panelLoader.item.close()
  }

  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  // ---- read-outs (null-safe until the service binds) -------------------------
  readonly property bool busy: root.svc ? root.svc.hasActivity : false
  readonly property bool expired: root.svc ? root.svc.auth === "expired" : false
  readonly property bool booting: root.svc ? root.svc.auth === "unknown" : true
  readonly property string modelName: root.svc ? String(root.svc.displayModel || "") : ""
  readonly property string providerName: {
    if (!root.svc) return ""
    if (root.svc.hasActivity) return String(root.svc.currentProvider || "")
    return String(root.svc.lastProvider || "")
  }

  readonly property string shortModel: {
    var name = root.modelName
    if (!name) return ""
    // "kr/claude-sonnet-4.5" -> "claude-sonnet-4.5"; keep it bar-sized.
    var slash = name.lastIndexOf("/")
    if (slash >= 0) name = name.slice(slash + 1)
    if (name.length > 22) name = name.slice(0, 21) + "…"
    return name
  }

  // One glance, no click needed: the state line is the whole pill.
  // busy -> "model" / idle -> "last: model" /
  // expired -> "login needed" / never-seen -> "no requests yet".
  readonly property string stateText: {
    if (root.expired) return "login needed"
    if (root.busy) return root.shortModel !== "" ? root.shortModel : "working…"
    if (root.shortModel !== "") return "last: " + root.shortModel
    if (root.booting) return "…"
    if (root.svc && root.svc.errorText !== "") return "offline"
    return "no requests yet"
  }

  // Rainbow flow while busy: hue loops 0->1 (red->red, so the wrap is
  // seamless) and the label color follows it. Saturation/lightness picked
  // to stay readable on a dark bar.
  property real flowHue: 0
  readonly property color flowColor: Qt.hsla(root.flowHue, 0.75, 0.62, 1.0)

  NumberAnimation on flowHue {
    running: root.busy
    loops: Animation.Infinite
    from: 0
    to: 1
    duration: 3500
    easing.type: Easing.Linear
  }

  readonly property string buttonText: {
    if (!root.showLabel) return "\u25cf"
    return root.stateText
  }

  onBusyChanged: {
    if (root.busy) root.eqReset()
  }

  readonly property string tooltipText: {
    if (root.expired) return "9Router session expired — click to log in"
    if (root.busy) {
      var s = "Request in flight"
      if (root.modelName !== "") s += ": " + root.modelName
      if (root.providerName !== "") s += " (" + root.providerName + ")"
      return s
    }
    if (root.modelName !== "") {
      var t = "Last model: " + root.modelName
      if (root.providerName !== "") t += " (" + root.providerName + ")"
      if (root.svc && root.svc.lastFetchText !== "") t += " · updated " + root.svc.lastFetchText
      return t
    }
    if (root.svc && root.svc.errorText !== "") return "9Router: " + root.svc.errorText
    return "9Router: no requests seen yet"
  }

  onBarChanged: { bindService(); injectPanel() }
  onSettingsChanged: pushSettings()

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Component.onCompleted: bindService()

  // ---- equalizer backdrop --------------------------------------------------
  // Bar count follows the pill width so bars never crowd or stretch: ~one
  // bar per 7px of slot. Levels random-walk toward a new target every tick
  // (140ms, in sync with the spinner), eased by Behavior for liquid motion
  // instead of jittery jumps. Bars paint behind the label at low alpha, so
  // the text stays readable while the backdrop dances.
  // Fixed bar count: referencing button.implicitWidth here created a
  // dependency loop (button width derives from label width), which
  // silently killed the whole widget on load.
  readonly property int eqCount: 16
  property var eqLevels: []
  property var eqTargets: []
  property int eqSeed: 12345

  function eqRandom() {
    // Deterministic PRNG (mulberry32): no Math.random needed, and the dance
    // stays identical across monitors showing the same widget.
    eqSeed = (eqSeed + 0x6D2B79F5) & 0xFFFFFFFF
    var t = eqSeed
    t = (t ^ (t >>> 15)) & 0xFFFFFFFF
    t = (t * (t | 1)) & 0xFFFFFFFF
    t = (t ^ (t + ((t ^ (t >>> 7)) & 0xFFFFFFFF))) & 0xFFFFFFFF
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }

  function eqReset() {
    var n = root.eqCount
    var levels = []
    var targets = []
    for (var i = 0; i < n; i++) { levels.push(0.15); targets.push(0.15) }
    root.eqLevels = levels
    root.eqTargets = targets
  }

  function eqStep() {
    var n = root.eqCount
    var levels = root.eqLevels.slice()
    var targets = root.eqTargets.slice()
    while (levels.length < n) { levels.push(0.15); targets.push(0.15) }
    levels.length = n
    targets.length = n
    for (var i = 0; i < n; i++) {
      // Neighbor coupling: each bar drifts toward its target, and targets
      // re-roll near the local average — adjacent bars move like a wave
      // instead of flickering independently.
      var left = i > 0 ? levels[i - 1] : levels[i]
      var right = i < n - 1 ? levels[i + 1] : levels[i]
      var wave = (left + levels[i] + right) / 3
      if (root.eqRandom() < 0.45) targets[i] = Math.max(0.08, Math.min(1.0, wave + (root.eqRandom() - 0.45) * 1.1))
      var t = targets[i]
      levels[i] = levels[i] + (t - levels[i]) * 0.45
    }
    root.eqLevels = levels
    root.eqTargets = targets
  }

  Timer {
    interval: 140
    running: root.busy
    repeat: true
    onTriggered: root.eqStep()
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // Equalizer backdrop: one dancing bar per slot, painted behind the
    // label. Visible only while busy; idle keeps the clean flat pill.
    Row {
      anchors.fill: parent
      anchors.leftMargin: 4
      anchors.rightMargin: 4
      anchors.topMargin: 5
      anchors.bottomMargin: 5
      spacing: 2
      visible: root.busy
      opacity: 0.5

      Repeater {
        model: root.eqCount

        Rectangle {
          required property int index
          width: Math.max(1, (parent.width - (root.eqCount - 1) * 2) / root.eqCount)
          // Anchor grows from the bottom: tall bars rise, short bars sink.
          anchors.bottom: parent.bottom
          height: parent.height * (index < root.eqLevels.length ? root.eqLevels[index] : 0.15)
          radius: width / 2
          color: root.flowColor

          Behavior on height {
            NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
          }
        }
      }
    }

    text: root.buttonText
    // The built-in label cannot do bold or outline, and it sizes the slot —
    // keep it for sizing (implicitWidth still counts while invisible) while
    // boldLabel below does the actual painting.
    labelVisible: false
    fixedWidth: root.vertical ? -1 : (boldLabel.implicitWidth + scaledHorizontalMargin * 2)
    fontSize: Style.font.caption
    tooltipText: root.tooltipText
    horizontalMargin: 6
    // Busy keeps the text solid white on top of the rainbow equalizer;
    // expired paints urgent. Same active mechanism as the microphone's
    // in-use state.
    active: root.busy || root.expired
    activeColor: root.expired ? Color.urgent : "#FFFFFF"
    onPressed: function(code) {
      if (code === Qt.RightButton) { root.openDashboard(); return }
      if (code === Qt.MiddleButton) { root.refresh(); return }
      root.togglePanel()
    }

    // Bold copy of the label with a bar-background outline, so the text
    // stays on top of the dancing equalizer behind it. Anchored exactly
    // like the built-in label it replaces (centerIn + same size).
    Text {
      id: boldLabel
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: root.buttonText
      color: button.active && button.useActiveColor ? button.activeColor : button.foreground
      font.family: button.fontFamily
      font.pixelSize: button.fontSize
      font.bold: false
      style: Text.Outline
      styleColor: root.bar ? root.bar.background : Color.background
      renderType: Text.NativeRendering
      horizontalAlignment: Text.AlignHCenter
      verticalAlignment: Text.AlignVCenter
    }

    // Gentle breathing under the color flow while traffic runs.
    SequentialAnimation on opacity {
      running: root.busy
      loops: Animation.Infinite
      NumberAnimation { to: 0.7; duration: 600; easing.type: Easing.InOutQuad }
      NumberAnimation { to: 1.0; duration: 600; easing.type: Easing.InOutQuad }
    }
  }

  IpcHandler {
    target: "jhonoryza.9router"

    function refresh(): void { root.refresh() }
    function openDashboard(): void { root.openDashboard() }
  }
}
