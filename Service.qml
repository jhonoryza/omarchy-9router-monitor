// Shared 9Router state for the shell: one fetcher, one login flow, one truth.
//
// The bar is built per monitor, so a Process living on the bar widget would
// poll once per screen and spam the dashboard. This service owns the polling
// instead; every BarWidget/panel instance binds to it and stays a pure
// read-out.
import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: root
  width: 0
  height: 0
  visible: false

  property var shell: null
  property var manifest: null
  property var pluginRegistry: null
  property var barWidgetRegistry: null
  property string omarchyPath: ""

  // ---- configuration (pushed from the bar widget's shell.json entry) ------
  property string baseUrl: "http://localhost:20128"
  property int refreshSeconds: 5
  property bool rememberPassword: true

  // ---- live state -----------------------------------------------------------
  // auth: "unknown" | "ok" | "expired" — "expired" means the dashboard said
  // 401, i.e. the browser-visible "please log in again" state.
  property string auth: "unknown"
  property string errorText: ""
  property bool fetching: false
  property bool loggingIn: false
  property string loginError: ""
  property var activeRequests: []
  property var recentRequests: []
  property string lastModel: ""
  property string lastProvider: ""
  property string lastTimestamp: ""
  property string lastFetchText: ""

  // "Busy" window after the newest request lands. The server only ever
  // fills activeRequests while a request is mid-flight, and for short
  // requests that window never coincides with a fetch — so a pill driven
  // by activeRequests alone would never light up. Instead, treat the
  // arrival of a fresh request as activity and hold the busy look for a
  // few seconds, refreshed by every new arrival while traffic flows.
  property double lastArrivalMs: 0
  property string lastSeenKey: ""
  property bool seenPrimed: false
  property int busyHoldSeconds: 12
  readonly property bool freshTraffic: (Date.now() - lastArrivalMs) < busyHoldSeconds * 1000
  readonly property bool busy: fetching || loggingIn
  readonly property int activeCount: activeRequests.length
  readonly property bool serverActive: activeCount > 0
  readonly property bool hasActivity: serverActive || freshTraffic
  readonly property string currentModel: {
    if (serverActive && activeRequests.length > 0) return String(activeRequests[0].model || "")
    if (freshTraffic) return lastModel
    return ""
  }
  readonly property string currentProvider: {
    if (serverActive && activeRequests.length > 0) return String(activeRequests[0].provider || "")
    if (freshTraffic) return lastProvider
    return ""
  }
  readonly property string displayModel: hasActivity ? (serverActive && activeRequests.length > 0 ? String(activeRequests[0].model || "") : lastModel) : lastModel

  readonly property string scriptPath: Qt.resolvedUrl("monitor.py").toString().replace(/^file:\/\//, "")
  readonly property string keyringService: "omarchy-9router"
  readonly property string keyringAccount: "dashboard-password"

  signal stateChanged()

  function singleLine(value, limit) {
    return String(value || "").replace(/[\r\n\t]+/g, " ").slice(0, limit)
  }

  function emitChanged() { root.stateChanged() }

  function applySnapshot(raw) {
    var text = String(raw || "").trim()
    if (!text) {
      if (root.auth === "unknown") {
        root.errorText = "Empty answer from dashboard"
        root.emitChanged()
      }
      return
    }
    var data
    try {
      data = JSON.parse(text)
    } catch (e) {
      root.errorText = "Unreadable answer from dashboard"
      root.emitChanged()
      return
    }
    if (!data || data.ok !== true) {
      root.errorText = root.singleLine(data && data.error ? data.error : "Dashboard error", 200)
      // A stored-cookie fetch that stops working mid-session (server
      // restart, expiry) surfaces here as ok:false rather than 401; treat a
      // previously-good session the same as an expired one.
      if (root.auth === "ok") root.auth = "expired"
      root.emitChanged()
      return
    }
    root.errorText = ""
    if (data.authenticated === false) {
      root.auth = "expired"
      root.emitChanged()
      return
    }
    root.auth = "ok"
    root.loginError = ""
    var active = Array.isArray(data.active) ? data.active : []
    var recent = Array.isArray(data.recent) ? data.recent : []
    root.activeRequests = active
    root.recentRequests = recent
    if (recent.length > 0) {
      var top = recent[0] || {}
      var topKey = String(top.timestamp || "") + "|" + String(top.model || "")
      if (top.model) root.lastModel = String(top.model)
      if (top.provider) root.lastProvider = String(top.provider)
      if (top.timestamp) root.lastTimestamp = String(top.timestamp)
      // A request this snapshot did not have before counts as an arrival:
      // light the pill for the busy window, extended by further arrivals.
      if (topKey !== "" && topKey !== root.lastSeenKey) {
        root.lastSeenKey = topKey
        if (root.seenPrimed) root.lastArrivalMs = Date.now()
      }
      // The very first snapshot after startup only establishes the
      // baseline — it must not light the pill for old history.
      if (!root.seenPrimed) {
        root.seenPrimed = true
        root.lastArrivalMs = 0
      }
    }
    root.lastFetchText = Qt.formatDateTime(new Date(), "hh:mm:ss")
    root.emitChanged()
  }

  function refresh() {
    if (fetchProc.running) {
      // A live stream already owns the truth; a plain fetch would only
      // duplicate it. But if the stream silently died, this is the kick
      // that restarts it.
      if (!streamProc.running && root.auth === "ok") startStream()
      return
    }
    root.fetching = true
    fetchProc.command = ["python3", "-u", root.scriptPath, "--base=" + root.baseUrl]
    fetchProc.running = true
  }

  // Live SSE tail: the server pushes on every request start/finish, so the
  // pill flips to busy/idle instantly instead of at poll boundaries. Each
  // line is one full snapshot; SplitParser delivers them as they arrive.
  function startStream() {
    if (streamProc.running) return
    streamProc.command = ["python3", "-u", root.scriptPath,
      "--base=" + root.baseUrl, "--stream", "--max-seconds=300"]
    streamProc.running = true
  }

  function stopStream() {
    streamProc.running = false
  }

  // Login with a password the panel collected. The secret travels over the
  // process's stdin, never argv, so it cannot leak through `ps`.
  function login(password) {
    var secret = String(password || "")
    if (!secret || loginProc.running) return
    root.loggingIn = true
    root.loginError = ""
    // Parked before start: the process's own onStarted clears `secret` right
    // after writing it to stdin, and handler order is not something to rely
    // on, so the keyring copy is staged here instead.
    loginProc.submittedSecret = secret
    loginProc.secret = secret
    loginProc.stdinEnabled = true
    loginProc.command = ["python3", root.scriptPath, "--base=" + root.baseUrl, "--password-stdin"]
    loginProc.running = true
  }

  // Stored-password login after an expiry: tried automatically when the user
  // opted into remembering it; never attempted when they did not.
  function tryStoredLogin() {
    if (!root.rememberPassword || keyringProc.running || root.loggingIn) return
    keyringProc.mode = "read"
    keyringProc.command = ["secret-tool", "lookup", "service", root.keyringService, "account", root.keyringAccount]
    keyringProc.running = true
  }

  function rememberSecret(secret) {
    if (!root.rememberPassword || !secret) return
    keyringProc.mode = "store"
    keyringProc.pendingSecret = String(secret)
    keyringProc.stdinEnabled = true
    keyringProc.command = ["secret-tool", "store", "--label=9Router dashboard password",
      "service", root.keyringService, "account", root.keyringAccount]
    keyringProc.running = true
  }

  function forgetSecret() {
    keyringProc.mode = "clear"
    keyringProc.command = ["secret-tool", "clear", "service", root.keyringService, "account", root.keyringAccount]
    keyringProc.running = true
  }

  function clearCookies() {
    Quickshell.execDetached(["python3", "-c",
      "import os; p=os.path.join(os.environ.get('XDG_STATE_HOME',os.path.join(os.path.expanduser('~'),'.local','state')),'omarchy','9router','cookies.txt');\n"
      + "try:\n os.remove(p)\n"
      + "except OSError:\n pass\n"])
  }

  // Full sign-out: drop the session cookie and the remembered password, so
  // the next refresh lands back on the password prompt for real.
  function logout() {
    root.auth = "expired"
    root.activeRequests = []
    root.loginError = ""
    root.clearCookies()
    root.forgetSecret()
    root.emitChanged()
  }

  function openDashboard() {
    Qt.openUrlExternally(root.baseUrl + "/dashboard/usage")
  }

  onAuthChanged: {
    // A fresh expiry with a stored password retries silently once, before
    // the widget has to admit it needs the user. Manual logouts skip this:
    // logout() already cleared the keyring entry.
    if (root.auth === "expired" && root.rememberPassword) root.tryStoredLogin()
    if (root.auth === "ok") {
      streamRestart.restartSoon()
      Qt.callLater(root.startStream)
    }
  }

  Process {
    id: streamProc
    stdout: SplitParser {
      onRead: function(line) {
        if (streamRestart.backoffMs > 0) {
          streamRestart.backoffMs = 0
          streamRestart.interval = 5000
        }
        root.applySnapshot(line)
      }
    }
    onExited: function(exitCode) {
      // 401 (expired) is handled by applySnapshot-less expiry below; any
      // other exit just reschedules the tail with backoff.
      if (root.auth === "ok" && exitCode !== 0) {
        if (exitCode === 2) {
          root.auth = "expired"
          root.emitChanged()
        } else {
          streamRestart.restartWithBackoff()
        }
      } else if (root.auth === "ok") {
        streamRestart.restartSoon()
      }
    }
    onRunningChanged: {
      if (!running && root.auth === "ok") streamRestart.restartSoon()
    }
  }

  // Restarts the SSE tail after drops: fast retry first, then backing off
  // to a 60s ceiling so a dead dashboard does not spin the CPU.
  Timer {
    id: streamRestart
    property int backoffMs: 0
    interval: 5000
    onTriggered: {
      if (root.auth === "ok" && !streamProc.running) root.startStream()
    }
    function restartSoon() {
      if (running) return
      interval = 5000
      restart()
    }
    function restartWithBackoff() {
      backoffMs = backoffMs <= 0 ? 5000 : Math.min(60000, backoffMs * 2)
      interval = backoffMs
      restart()
    }
  }

  Process {
    id: fetchProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        watchdog.stop()
        root.fetching = false
        root.applySnapshot(text)
      }
    }
    onExited: function(exitCode) {
      watchdog.stop()
      if (root.fetching) {
        root.fetching = false
        root.errorText = "Monitor script failed to run"
        root.emitChanged()
      }
    }
    onRunningChanged: {
      if (running) watchdog.restart()
      else watchdog.stop()
    }
  }

  // A fetch that never returns would wedge the pill: fetchProc.running stays
  // true, so every later refresh() returns early and the widget goes stale
  // forever. Kill the overrun and let the next tick retry.
  Timer {
    id: watchdog
    interval: 25000
    onTriggered: {
      fetchProc.running = false
      loginProc.running = false
    }
  }

  Process {
    id: loginProc
    property string secret: ""
    stdinEnabled: true
    onStarted: {
      write(secret + "\n")
      secret = ""
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        watchdog.stop()
        root.loggingIn = false
        var raw = String(text || "").trim()
        var data = null
        try { data = JSON.parse(raw) } catch (e) { data = null }
        if (!data || data.ok !== true || data.authenticated !== true) {
          var reason = data && data.error ? String(data.error) : ""
          if (reason.indexOf("login failed:") === 0) reason = reason.slice("login failed:".length).trim()
          root.loginError = root.singleLine(reason || "Login failed", 200)
          root.auth = "expired"
          root.emitChanged()
          return
        }
        // Success: keep polling on the fresh session, and remember the
        // password only now that it proved valid.
        root.rememberSecret(loginProc.submittedSecret)
        loginProc.submittedSecret = ""
        root.auth = "ok"
        root.loginError = ""
        root.emitChanged()
        Qt.callLater(root.startStream)
        Qt.callLater(root.refresh)
      }
    }
    onExited: function(exitCode) {
      watchdog.stop()
      if (root.loggingIn) {
        root.loggingIn = false
        if (!root.loginError) root.loginError = "Login process failed"
        root.emitChanged()
      }
    }

    property string submittedSecret: ""
  }

  // login() funnels through here so the secret queued for the keyring is the
  // same one that just authenticated — submittedSecret is parked before the
  // write clears `secret`.

  Process {
    id: keyringProc
    property string mode: ""
    property string pendingSecret: ""
    stdinEnabled: true
    onStarted: {
      if (keyringProc.mode === "store") {
        write(keyringProc.pendingSecret + "\n")
        keyringProc.pendingSecret = ""
      }
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var secret = String(text || "").split("\n")[0] || ""
        var mode = keyringProc.mode
        keyringProc.mode = ""
        if (mode === "read" && secret !== "") {
          root.login(secret)
        } else if (mode === "read") {
          // Nothing remembered: stay expired and let the panel ask.
          root.emitChanged()
        }
      }
    }
    onExited: function(exitCode) {
      // A missing secret-tool or a locked keyring is not fatal: the panel
      // simply asks for the password directly.
      if (keyringProc.mode === "read") {
        keyringProc.mode = ""
        root.emitChanged()
      } else {
        keyringProc.mode = ""
      }
    }
  }

  // Slow heartbeat while the stream owns the live truth: keeps the
  // "last model" fresh, detects expiry the stream might miss, and revives
  // a silently dead tail. Refresh interval stays user-tunable.
  // Ticks the busy window closed when traffic stops. Without a ticking
  // re-evaluation, freshTraffic would stay true until the next snapshot
  // lands instead of expiring busyHoldSeconds after the last arrival.
  Timer {
    interval: 1000
    running: root.auth === "ok"
    repeat: true
    onTriggered: root.emitChanged()
  }

  Timer {
    id: pollTimer
    interval: Math.max(10, root.refreshSeconds * 6) * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      if (root.auth === "ok" && !streamProc.running) root.startStream()
      root.refresh()
    }
  }

  onRefreshSecondsChanged: {
    pollTimer.interval = Math.max(10, root.refreshSeconds * 6) * 1000
    pollTimer.restart()
  }

  // Kick the stream once the service is up and whenever the session heals.
  Component.onCompleted: {
    stateFile.reload()
  }

  // First paint before any fetch lands: keep the last-known model across
  // restarts in a tiny state file, so the pill is useful immediately.
  FileView {
    id: stateFile
    path: (Quickshell.env("HOME") || "") + "/.local/state/omarchy/9router/last.json"
    watchChanges: false
    printErrors: false
    onLoaded: {
      try {
        var data = JSON.parse(text() || "{}")
        if (data && data.model && !root.lastModel) root.lastModel = String(data.model)
        if (data && data.provider && !root.lastProvider) root.lastProvider = String(data.provider)
        if (data && data.timestamp && !root.lastTimestamp) root.lastTimestamp = String(data.timestamp)
      } catch (e) {
      }
    }
  }

  onLastModelChanged: persistLast()
  onLastProviderChanged: persistLast()

  function persistLast() {
    if (!root.lastModel) return
    persistProc.command = ["python3", "-c",
      "import json,os; "
      + "d=os.path.join(os.environ.get('XDG_STATE_HOME',os.path.join(os.path.expanduser('~'),'.local','state')),'omarchy','9router'); "
      + "os.makedirs(d,mode=0o700,exist_ok=True); "
      + "open(os.path.join(d,'last.json'),'w').write(json.dumps("
      + JSON.stringify({model: root.lastModel, provider: root.lastProvider, timestamp: root.lastTimestamp})
      + "))"]
    if (!persistProc.running) persistProc.running = true
  }

  Process {
    id: persistProc
  }
}
