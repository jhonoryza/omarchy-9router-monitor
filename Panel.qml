import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Popup for the 9Router monitor: live activity, last model, and the password
// prompt when the dashboard session expires. The widget owns the anchor; the
// service owns the state — this file only renders and collects the password.
Panel {
  id: root
  moduleName: "jhonoryza.9router"
  ipcTarget: "jhonoryza.9router"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property var service: null
  readonly property var barIdentity: hostWidget || root

  property bool openedFromHotkey: false
  property string draftPassword: ""
  property bool showPassword: false
  property string draftHost: "localhost"
  property string draftPort: "20128"
  property string connectionError: ""
  property string connectionStatus: ""

  function open() {
    openedFromHotkey = false
    setCenterHoverRevealSuppressed(false)
    root.controller.show()
    Qt.callLater(focusPasswordIfNeeded)
  }

  function openFromHotkey() {
    openedFromHotkey = true
    root.controller.show()
    Qt.callLater(function() {
      if (root.opened) setCenterHoverRevealSuppressed(true)
      focusPasswordIfNeeded()
    })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    clearDraft()
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.openFromHotkey()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  // ---- service read-outs (null-safe until the widget injects it) ------------
  readonly property bool expired: root.service ? root.service.auth === "expired" : false
  readonly property bool authed: root.service ? root.service.auth === "ok" : false
  readonly property bool busyLogin: root.service ? root.service.loggingIn : false
  readonly property bool hasActivity: root.service ? root.service.hasActivity : false
  readonly property var activeList: root.service ? root.service.activeRequests : []
  readonly property var recentList: root.service ? root.service.recentRequests : []
  readonly property string loginErrorText: root.service ? String(root.service.loginError || "") : ""
  readonly property string serviceError: root.service ? String(root.service.errorText || "") : ""
  readonly property string baseUrl: root.service ? String(root.service.baseUrl || "") : ""
  readonly property bool rememberPassword: root.service ? root.service.rememberPassword : true
  readonly property string lastFetchText: root.service ? String(root.service.lastFetchText || "") : ""

  function focusPasswordIfNeeded() {
    if (root.opened && root.expired && !root.busyLogin) passwordField.forceActiveFocus()
  }

  function clearDraft() {
    root.draftPassword = ""
    root.showPassword = false
    if (passwordField) passwordField.text = ""
  }

  function syncConnectionDraft() {
    var host = "localhost"
    var port = "20128"
    var parsed = root.parseBaseUrl(root.baseUrl)
    if (parsed) {
      if (parsed.host !== "") host = parsed.host
      if (parsed.port !== "") port = parsed.port
    }
    if (hostWidget && hostWidget.setting) {
      var h = hostWidget.setting("dashboardHost", "")
      var p = hostWidget.setting("dashboardPort", "")
      if (String(h === undefined || h === null ? "" : h).trim() !== "") host = String(h).trim()
      if (String(p === undefined || p === null ? "" : p).trim() !== "") port = String(p).trim()
    }
    root.draftHost = host
    root.draftPort = port
    root.connectionError = ""
    if (hostField) hostField.text = host
    if (portField) portField.text = port
  }

  function parseBaseUrl(url) {
    var s = String(url || "").trim().replace(/\/+$/, "")
    var m = s.match(/^(https?):\/\/([^\/:]+)(?::(\d+))?$/)
    if (!m) return null
    return { scheme: m[1], host: m[2], port: m[3] || "" }
  }

  function serviceOrLookup() {
    if (root.service) return root.service
    // The panel may open before the widget finishes binding — resolve the
    // service directly through the shell instead of waiting.
    var candidates = []
    if (hostWidget && hostWidget.pluginId) candidates.push(hostWidget.pluginId)
    if (hostWidget && hostWidget.moduleName) candidates.push(hostWidget.moduleName)
    candidates.push("vm.9router", "jhonoryza.9router")
    var shell = root.bar && root.bar.shell ? root.bar.shell : null
    if (shell && typeof shell.serviceFor === "function") {
      for (var i = 0; i < candidates.length; i++) {
        if (!candidates[i]) continue
        var s = shell.serviceFor(candidates[i])
        if (s) {
          root.service = s
          return s
        }
      }
    }
    if (hostWidget && hostWidget.svc) {
      root.service = hostWidget.svc
      return hostWidget.svc
    }
    return null
  }

  function applyConnection() {
    var host = String(root.draftHost || "").trim()
    var portText = String(root.draftPort || "").trim()
    if (host === "" || /[\s\/:@]/.test(host)) {
      root.connectionError = "Enter a valid host (IP or hostname, no scheme or path)."
      return
    }
    if (!/^\d+$/.test(portText) || parseInt(portText, 10) < 1 || parseInt(portText, 10) > 65535) {
      root.connectionError = "Port must be a number 1-65535."
      return
    }
    var port = parseInt(portText, 10)
    var scheme = "http"
    var parsed = root.parseBaseUrl(root.baseUrl)
    if (parsed) scheme = parsed.scheme
    var baseUrl = scheme + "://" + host + ":" + port
    if (baseUrl === root.baseUrl) {
      root.connectionError = ""
      return
    }
    root.connectionError = ""
    root.connectionStatus = "Connecting to " + baseUrl + "…"
    // Persist first so the new URL survives restarts, then drive the live
    // service directly — pushSettings only re-fires when settings change.
    if (hostWidget && typeof hostWidget.persistConnection === "function") {
      hostWidget.persistConnection(host, port, baseUrl)
    }
    var svc = root.serviceOrLookup()
    if (svc && typeof svc.setConnection === "function") {
      svc.setConnection(baseUrl)
    } else if (svc) {
      svc.baseUrl = baseUrl
      root.refresh()
    } else {
      root.connectionError = "Service not ready — reopen the panel and try again."
      root.connectionStatus = ""
    }
  }

  onExpiredChanged: {
    if (root.expired && root.opened) Qt.callLater(focusPasswordIfNeeded)
    if (!root.expired) clearDraft()
  }

  onBaseUrlChanged: {
    root.connectionStatus = ""
    if (root.opened) Qt.callLater(syncConnectionDraft)
  }

  onOpenedChanged: {
    if (root.opened) {
      syncConnectionDraft()
      Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
      Qt.callLater(focusPasswordIfNeeded)
    } else {
      clearDraft()
    }
  }

  function submitLogin() {
    if (!root.service || root.busyLogin) return
    var secret = root.draftPassword
    if (secret === "") return
    root.service.login(secret)
    // The service copies what it needs on start; drop the panel copy now so
    // the secret lives in as few places as possible.
    root.draftPassword = ""
    if (passwordField) passwordField.text = ""
  }

  function toggleRemember(value) {
    if (!root.service) return
    root.service.rememberPassword = value
    persistRemember(value)
  }

  function persistRemember(value) {
    if (!root.bar || !root.bar.shell || typeof root.bar.shell.updateEntryInline !== "function") return
    if (!hostWidget) return
    var entry = { id: hostWidget.moduleName }
    var current = hostWidget.settings || {}
    for (var k in current) if (k !== "id") entry[k] = current[k]
    entry["rememberPassword"] = value
    hostWidget.settings = entry
    root.bar.shell.updateEntryInline(hostWidget.moduleName, entry)
  }

  function openDashboard() {
    if (root.service && typeof root.service.openDashboard === "function") root.service.openDashboard()
  }

  function refresh() {
    if (root.service && typeof root.service.refresh === "function") root.service.refresh()
  }

  function logout() {
    if (root.service && typeof root.service.logout === "function") root.service.logout()
  }

  function agoText(iso) {
    if (!iso) return ""
    var then = Date.parse(iso)
    if (isNaN(then)) return ""
    var secs = Math.max(0, Math.floor((Date.now() - then) / 1000))
    if (secs < 10) return "just now"
    if (secs < 60) return secs + "s ago"
    var mins = Math.floor(secs / 60)
    if (mins < 60) return mins + "m ago"
    var hours = Math.floor(mins / 60)
    if (hours < 24) return hours + "h ago"
    return Math.floor(hours / 24) + "d ago"
  }

  IpcHandler {
    target: "jhonoryza.9router.panel"

    function open(): void { root.openFromHotkey() }
    function close(): void { root.close() }
    function show(): void { root.openFromHotkey() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(bodyColumn.implicitHeight + Style.space(8))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: passwordField.activeFocus
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        anchors.fill: parent
        contentWidth: width
        contentHeight: bodyColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: bodyColumn
          width: parent.width
          spacing: Style.space(12)

          PanelHero {
            width: parent.width
            title: "9Router"
            meta: root.hasActivity ? "REQUEST IN FLIGHT" : (root.expired ? "SESSION EXPIRED" : (root.authed ? "IDLE" : "CONNECTING"))
            detail: root.hasActivity
              ? String((root.activeList[0] || {}).model || "")
              : (root.service ? String(root.service.displayModel || "no requests yet") : "")
            foreground: root.bar ? root.bar.foreground : Color.foreground
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          }

          // ---- live requests ------------------------------------------------
          Column {
            visible: root.hasActivity
            width: parent.width
            spacing: Style.space(6)

            PanelSectionHeader {
              width: parent.width
              text: "ACTIVE NOW"
            }

            Repeater {
              model: root.activeList

              Rectangle {
                required property var modelData
                required property int index
                width: parent.width
                height: activeRow.implicitHeight + Style.space(10)
                radius: Style.cornerRadius
                color: Style.hoverFillFor(root.bar ? root.bar.foreground : Color.foreground, Color.accent)

                Row {
                  id: activeRow
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.leftMargin: Style.space(12)
                  anchors.rightMargin: Style.space(12)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(8)

                  Text {
                    textFormat: Text.PlainText
                    text: "●"
                    color: Color.accent
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.body
                    anchors.verticalCenter: parent.verticalCenter

                    SequentialAnimation on opacity {
                      running: true
                      loops: Animation.Infinite
                      NumberAnimation { to: 0.3; duration: 550; easing.type: Easing.InOutQuad }
                      NumberAnimation { to: 1.0; duration: 550; easing.type: Easing.InOutQuad }
                    }
                  }

                  Column {
                    width: parent.width - Style.space(24)
                    spacing: Style.space(1)

                    Text {
                      width: parent.width
                      textFormat: Text.PlainText
                      text: String(modelData.model || "unknown model")
                      color: root.bar ? root.bar.foreground : Color.foreground
                      font.family: root.bar ? root.bar.fontFamily : Style.font.family
                      font.pixelSize: Style.font.body
                      font.bold: true
                      elide: Text.ElideRight
                    }

                    Text {
                      width: parent.width
                      textFormat: Text.PlainText
                      visible: text !== ""
                      text: {
                        var bits = []
                        if (modelData.provider) bits.push(String(modelData.provider))
                        if (modelData.account) bits.push(String(modelData.account))
                        if (modelData.count > 1) bits.push("×" + modelData.count)
                        return bits.join(" · ")
                      }
                      color: root.bar ? Qt.darker(root.bar.foreground, 1.5) : Color.muted
                      font.family: root.bar ? root.bar.fontFamily : Style.font.family
                      font.pixelSize: Style.font.caption
                      elide: Text.ElideRight
                    }
                  }
                }
              }
            }
          }

          // ---- password prompt ----------------------------------------------
          Column {
            visible: root.expired
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              width: parent.width
              text: "DASHBOARD LOGIN"
            }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              text: "Session expired (restart logs the dashboard out). Type the dashboard password to sign back in."
              color: root.bar ? Qt.darker(root.bar.foreground, 1.4) : Color.muted
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.bodySmall
            }

            TextField {
              id: passwordField
              width: parent.width
              password: !root.showPassword
              enabled: !root.busyLogin
              placeholderText: "Dashboard password"
              foreground: root.bar ? root.bar.foreground : Color.foreground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              text: root.draftPassword
              onTextChanged: if (text !== root.draftPassword) root.draftPassword = text
              onAccepted: root.submitLogin()
              Keys.onEscapePressed: root.close()
            }

            Text {
              visible: root.loginErrorText !== ""
              width: parent.width
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              text: root.loginErrorText
              color: Color.urgent
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.bodySmall
            }

            Row {
              width: parent.width
              spacing: Style.space(8)

              Button {
                text: root.busyLogin ? "Signing in…" : "Sign in"
                selected: true
                enabled: !root.busyLogin && root.draftPassword !== ""
                foreground: root.bar ? root.bar.foreground : Color.foreground
                onClicked: root.submitLogin()
              }

              Button {
                text: root.showPassword ? "Hide" : "Show"
                enabled: !root.busyLogin
                foreground: root.bar ? root.bar.foreground : Color.foreground
                onClicked: root.showPassword = !root.showPassword
              }
            }

            Row {
              width: parent.width
              spacing: Style.space(8)

              ToggleSwitch {
                id: rememberSwitch
                anchors.verticalCenter: parent.verticalCenter
                checked: root.rememberPassword
                enabled: !root.busyLogin
                foreground: root.bar ? root.bar.foreground : Color.foreground
                onToggled: root.toggleRemember(!root.rememberPassword)
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: "Remember password & re-login automatically"
                color: root.bar ? root.bar.foreground : Color.foreground
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.bodySmall

                TapHandler {
                  onTapped: if (!root.busyLogin) root.toggleRemember(!root.rememberPassword)
                }
              }
            }
          }

          // ---- recent models --------------------------------------------------
          Column {
            visible: root.recentList.length > 0
            width: parent.width
            spacing: Style.space(4)

            PanelSectionHeader {
              width: parent.width
              text: "RECENT MODELS"
            }

            Repeater {
              model: root.recentList.slice(0, 8)

              Row {
                required property var modelData
                width: parent.width
                spacing: Style.space(8)

                Text {
                  width: parent.width - timeText.implicitWidth - Style.space(8)
                  textFormat: Text.PlainText
                  text: {
                    var s = String(modelData.model || "")
                    if (modelData.provider) s += "  ·  " + String(modelData.provider)
                    return s
                  }
                  color: root.bar ? root.bar.foreground : Color.foreground
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideRight
                }

                Text {
                  id: timeText
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  text: root.agoText(modelData.timestamp)
                  color: root.bar ? Qt.darker(root.bar.foreground, 1.5) : Color.muted
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }

          Text {
            visible: !root.hasActivity && !root.expired && root.recentList.length === 0
            width: parent.width
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            text: root.serviceError !== "" ? ("Dashboard: " + root.serviceError) : "No requests seen yet. Send a prompt through the gateway and it shows up here."
            color: root.bar ? Qt.darker(root.bar.foreground, 1.4) : Color.muted
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.bodySmall
            font.italic: true
          }

          // ---- connection -------------------------------------------------------
          Column {
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              width: parent.width
              text: "CONNECTION"
            }

            Row {
              width: parent.width
              spacing: Style.space(8)

              Column {
                width: (parent.width - Style.space(8)) * 0.62
                spacing: Style.space(4)

                Text {
                  textFormat: Text.PlainText
                  text: "Host"
                  color: root.bar ? Qt.darker(root.bar.foreground, 1.4) : Color.muted
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.caption
                }

                TextField {
                  id: hostField
                  width: parent.width
                  placeholderText: "localhost"
                  foreground: root.bar ? root.bar.foreground : Color.foreground
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  text: root.draftHost
                  onTextChanged: if (text !== root.draftHost) root.draftHost = text
                  onAccepted: root.applyConnection()
                  Keys.onEscapePressed: root.close()
                }
              }

              Column {
                width: (parent.width - Style.space(8)) * 0.38
                spacing: Style.space(4)

                Text {
                  textFormat: Text.PlainText
                  text: "Port"
                  color: root.bar ? Qt.darker(root.bar.foreground, 1.4) : Color.muted
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.caption
                }

                TextField {
                  id: portField
                  width: parent.width
                  placeholderText: "20128"
                  inputMethodHints: Qt.ImhDigitsOnly
                  foreground: root.bar ? root.bar.foreground : Color.foreground
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  text: root.draftPort
                  onTextChanged: if (text !== root.draftPort) root.draftPort = text
                  onAccepted: root.applyConnection()
                  Keys.onEscapePressed: root.close()
                }
              }
            }

            Text {
              visible: root.connectionError !== ""
              width: parent.width
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              text: root.connectionError
              color: Color.urgent
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.bodySmall
            }

            Text {
              visible: root.connectionStatus !== "" && root.connectionError === ""
              width: parent.width
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              text: root.connectionStatus
              color: root.bar ? Qt.darker(root.bar.foreground, 1.4) : Color.muted
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.bodySmall
              font.italic: true
            }

            Button {
              text: "Apply & reconnect"
              foreground: root.bar ? root.bar.foreground : Color.foreground
              enabled: root.draftHost.trim() !== "" && root.draftPort.trim() !== ""
              onClicked: root.applyConnection()
            }
          }

          // ---- footer actions ---------------------------------------------------
          Row {
            width: parent.width
            spacing: Style.space(8)

            Button {
              text: "Open dashboard"
              foreground: root.bar ? root.bar.foreground : Color.foreground
              onClicked: root.openDashboard()
            }

            Button {
              text: "Refresh"
              foreground: root.bar ? root.bar.foreground : Color.foreground
              onClicked: root.refresh()
            }

            Button {
              visible: root.authed || root.expired
              text: "Log out"
              foreground: root.bar ? root.bar.foreground : Color.foreground
              onClicked: root.logout()
            }
          }

          Text {
            visible: root.lastFetchText !== ""
            width: parent.width
            textFormat: Text.PlainText
            text: "Updated " + root.lastFetchText + (root.baseUrl !== "" ? " · " + root.baseUrl : "")
            color: root.bar ? Qt.darker(root.bar.foreground, 1.6) : Color.muted
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }
}
