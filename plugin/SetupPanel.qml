import QtQuick
import QtQuick.Layouts
import QtCore as Core
import Quickshell
import Quickshell.Io
import qs.Commons as Commons

Item {
  id: root

  property var shell: null
  property bool opened: false
  property bool startSetupOnLoad: false
  property string statusKey: ""
  property string errorText: ""
  property string pendingSort: ""
  property string pendingAutosave: ""
  property bool pendingOnboarding: false
  property string pendingTrace: ""
  property string activeTrace: ""
  property var document: null
  property bool profileSyncEnabled: false
  property bool profileSyncLoaded: false
  property string profileSyncStatus: ""
  property string profileSyncAction: ""
  property bool settingDefaultHandler: false
  property var pendingRule: null
  property string pendingUrl: ""
  property string operation: ""
  readonly property string installer: decodeURIComponent(String(Qt.resolvedUrl("../install.sh")).replace(/^file:\/\//, ""))
  readonly property string bridgeInstaller: decodeURIComponent(String(Qt.resolvedUrl("../extension/install-bridge.sh")).replace(/^file:\/\//, ""))
  readonly property string backend: decodeURIComponent(String(Qt.resolvedUrl("../bin/browser-picker-editor-data")).replace(/^file:\/\//, ""))
  readonly property string picker: decodeURIComponent(String(Qt.resolvedUrl("../bin/browser-picker")).replace(/^file:\/\//, ""))

  function open(payloadJson) {
    let duplicateRequest = false
    startSetupOnLoad = false
    try {
      const request = JSON.parse(payloadJson || "{}")
      startSetupOnLoad = request?.setup === true
      if (request && typeof request.pattern === "string" && typeof request.url === "string"
          && /^(https?:\/\/|mailto:)/.test(request.url)) {
        if (pendingRule || pendingUrl)
          duplicateRequest = true
        else
          pendingRule = request
      }
    } catch (_) {}
    opened = true
    editor.activeTab = "rules"
    updateProfileShortcuts("status")
    if (!editor.dirty && !dataWorker.running)
      readOrSave("load")
    else if (document && !dataWorker.running)
      applyPendingRule()
    if (duplicateRequest)
      statusKey = "pendingLink"
    Qt.callLater(syncWindowVisibility)
  }

  function close() {
    opened = false
    startSetupOnLoad = false
    window.visible = false
  }

  function syncWindowVisibility() {
    window.visible = opened
  }

  function install(refreshOnly) {
    if (setup.running)
      return
    settingDefaultHandler = !refreshOnly
    statusKey = "working"
    errorText = ""
    setup.command = refreshOnly ? [installer, "--no-bridge", "--refresh"] : [installer, "--no-bridge"]
    setup.running = true
  }

  function applyPendingRule() {
    if (!pendingRule)
      return
    pendingUrl = pendingRule.url
    editor.beginRule(pendingRule.pattern, pendingRule.label || "")
    pendingRule = null
  }

  function readOrSave(action, payload) {
    if (dataWorker.running)
      return
    operation = action
    statusKey = action === "save" ? "" : "working"
    errorText = ""
    dataWorker.command = payload ? [backend, action, JSON.stringify(payload)] : [backend, action]
    dataWorker.running = true
  }

  function updateProfileShortcuts(action) {
    if (profileSyncWorker.running)
      return
    profileSyncAction = action
    if (action === "sync")
      profileSyncStatus = ""
    profileSyncWorker.command = [backend, "profile-shortcuts", action]
    profileSyncWorker.running = true
  }

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  Core.Settings {
    id: setupHistory
    location: Core.StandardPaths.writableLocation(Core.StandardPaths.ConfigLocation)
      + "/browser-picker/recommended-setup.ini"
    category: "BrowserPickerRecommendedSetup"
    property string profileShortcuts: ""
    property string defaultHandler: ""
    property string bridge: ""
    property bool profileShortcutsFailed: false
    property bool defaultHandlerFailed: false
    property bool bridgeFailed: false
  }

  function reportProfileShortcuts(message, failed = false) {
    profileSyncStatus = message
    if (profileSyncAction === "sync") {
      setupHistory.profileShortcuts = message
      setupHistory.profileShortcutsFailed = failed
    }
  }

  Process {
    id: profileSyncWorker
    stdout: StdioCollector { id: profileSyncOutput }
    stderr: StdioCollector { id: profileSyncErrors }
    onExited: function(code, status) {
      if (code !== 0 || status !== 0) {
        root.reportProfileShortcuts(profileSyncErrors.text.trim()
          ? strings.t("profileSyncFailed") + "\n" + profileSyncErrors.text.trim()
          : strings.t("profileSyncFailed"), true)
        return
      }
      try {
        const result = JSON.parse(profileSyncOutput.text)
        root.profileSyncEnabled = result.enabled
        root.profileSyncLoaded = true
        if (root.profileSyncAction === "sync") {
          if (result.added === 0)
            root.reportProfileShortcuts(strings.t("profileSyncNone"))
          else if (result.added === 1)
            root.reportProfileShortcuts(strings.t("profileSyncOne"))
          else
            root.reportProfileShortcuts(strings.t("profileSyncAdded").arg(result.added))
        }
      } catch (_) {
        root.reportProfileShortcuts(strings.t("profileSyncFailed"), true)
      }
    }
  }

  Process {
    id: setup
    stderr: StdioCollector { id: errors }
    onExited: function(exitCode, exitStatus) {
      root.statusKey = exitCode === 0 && exitStatus === 0 ? "success" : "failure"
      root.errorText = errors.text.trim()
      if (root.settingDefaultHandler)
        setupHistory.defaultHandler = root.statusKey === "success"
          ? strings.t("defaultHandlerSet")
          : strings.t("defaultHandlerFailed") + (root.errorText ? "\n" + root.errorText : "")
      if (root.settingDefaultHandler)
        setupHistory.defaultHandlerFailed = root.statusKey !== "success"
      root.settingDefaultHandler = false
    }
  }

  Process {
    id: bridgeWorker
    command: [root.bridgeInstaller]
    stderr: StdioCollector { id: bridgeErrors }
    onExited: function(code, status) {
      setupHistory.bridge = code === 0 && status === 0
        ? "Installer finished. Restart open browser and web app windows."
        : "Bridge installation failed." + (bridgeErrors.text.trim() ? "\n" + bridgeErrors.text.trim() : "")
      setupHistory.bridgeFailed = code !== 0 || status !== 0
    }
  }

  function writePreference() {
    if (preferenceWorker.running || (pendingSort === "" && pendingAutosave === "" && !pendingOnboarding))
      return
    if (pendingAutosave !== "") {
      preferenceWorker.command = [backend, "autosave", pendingAutosave]
      pendingAutosave = ""
    } else if (pendingSort !== "") {
      preferenceWorker.command = [backend, "sort", pendingSort]
      pendingSort = ""
    } else {
      preferenceWorker.command = [backend, "onboarding"]
      pendingOnboarding = false
    }
    preferenceWorker.running = true
  }

  Process {
    id: preferenceWorker
    onExited: function(code, status) {
      if (code !== 0 || status !== 0)
        root.statusKey = "preferenceSaveFailed"
      Qt.callLater(root.writePreference)
    }
  }

  function writeTrace() {
    if (traceWorker.running || pendingTrace === "")
      return
    activeTrace = pendingTrace
    pendingTrace = ""
    traceWorker.command = [backend, "trace"]
    traceWorker.running = true
  }

  Process {
    id: traceWorker
    stdinEnabled: true
    onStarted: write(root.activeTrace + "\n")
    stdout: StdioCollector { id: traceOutput }
    stderr: StdioCollector { id: traceErrors }
    onExited: function(code, status) {
      let result = null
      let error = ""
      if (code === 0 && status === 0) {
        try { result = JSON.parse(traceOutput.text) }
        catch (_) { error = strings.t("invalidData") }
      } else {
        error = traceErrors.text.trim() || strings.t("failure")
      }
      editor.acceptTrace(root.activeTrace, result, error)
      Qt.callLater(root.writeTrace)
    }
  }

  Process {
    id: dataWorker
    stdout: StdioCollector { id: dataOutput }
    stderr: StdioCollector { id: dataErrors }
    onExited: function(code, status) {
      if (code !== 0 || status !== 0) {
        root.statusKey = "failure"
        root.errorText = dataErrors.text.trim()
        return
      }
      try {
        root.document = JSON.parse(dataOutput.text)
      } catch (_) {
        root.statusKey = "invalidData"
        return
      }
      root.statusKey = ""
      if (root.operation === "save" && root.pendingUrl) {
        const url = root.pendingUrl
        root.pendingUrl = ""
        Quickshell.execDetached([root.picker, url])
        if (root.shell) root.shell.hide("browser-better-default")
        else root.close()
      }
      root.applyPendingRule()
      if (root.startSetupOnLoad) {
        root.startSetupOnLoad = false
        if (root.opened && !editor.onboardingSeen)
          Qt.callLater(() => { if (root.opened) editor.startRecommendedSetup() })
      }
    }
  }

  FloatingWindow {
    id: window
    title: strings.t("title")
    visible: false
    implicitWidth: 720
    implicitHeight: 560
    color: Commons.Color.background
    onVisibleChanged: {
      if (!visible && root.opened) {
        if (root.shell) root.shell.hide("browser-better-default")
        else root.close()
      }
    }

    ColumnLayout {
      id: content
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      anchors.margins: Commons.Style.space(14)
      spacing: Commons.Style.space(8)

      RulesEditor {
        id: editor
        Layout.fillWidth: true
        Layout.fillHeight: true
        document: root.document
        editorBackend: root.backend
        allowAutosave: root.pendingUrl === "" && !root.pendingRule
        busy: dataWorker.running || setup.running
        profileSyncEnabled: root.profileSyncEnabled
        profileSyncLoaded: root.profileSyncLoaded
        profileSyncBusy: profileSyncWorker.running
        profileSyncStatus: root.profileSyncStatus
        setupProfileSyncStatus: setupHistory.profileShortcuts
        setupProfileSyncFailed: setupHistory.profileShortcutsFailed
        defaultHandlerFailed: !setup.running && setupHistory.defaultHandlerFailed
        bridgeFailed: setupHistory.bridgeFailed
        defaultHandlerStatus: setup.running && root.settingDefaultHandler
          ? strings.t("settingDefaultHandler") : (setupHistory.defaultHandler ? "Last run · " + setupHistory.defaultHandler : "")
        bridgeStatus: bridgeWorker.running ? "Installing bridge…" : (setupHistory.bridge ? "Last run · " + setupHistory.bridge : "")
        bridgeBusy: bridgeWorker.running
        onBridgeInstallRequested: {
          if (!bridgeWorker.running)
            bridgeWorker.running = true
        }
        onProfileSyncToggled: enabled => root.updateProfileShortcuts(enabled ? "on" : "off")
        onProfileSyncRequested: root.updateProfileShortcuts("sync")
        onAutosaveChosen: enabled => {
          root.pendingAutosave = enabled ? "on" : "off"
          root.writePreference()
        }
        onOnboardingDismissed: {
          root.pendingOnboarding = true
          root.writePreference()
        }
        onDraftDiscarded: root.pendingUrl = ""
        onSetupRequested: refreshOnly => root.install(refreshOnly)
        onSortChosen: order => {
          root.pendingSort = order
          root.writePreference()
        }
        onTraceRequested: request => {
          root.pendingTrace = request
          root.writeTrace()
        }
        onRescanRequested: {
          if (editor.dirty) {
            root.statusKey = "saveFirst"
            root.errorText = ""
          } else {
            root.readOrSave("rescan")
          }
        }
        onSaveRequested: function(rules, fallback) {
          if (root.document)
            root.readOrSave("save", {rules, fallback: fallback || null, revision: root.document.revision})
        }
      }

      Text {
        Layout.fillWidth: true
        visible: root.statusKey !== ""
        color: Commons.Color.foreground
        text: root.statusKey ? strings.t(root.statusKey) : ""
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
      }

      Text {
        Layout.fillWidth: true
        visible: root.statusKey === "failure" && root.errorText !== ""
        color: Commons.Color.foreground
        text: root.errorText
        textFormat: Text.PlainText
        wrapMode: Text.Wrap
        maximumLineCount: 3
        elide: Text.ElideRight
      }
    }
  }
}
