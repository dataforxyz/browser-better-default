import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons as Commons
import qs.Ui as Ui

Item {
  id: root

  property var shell: null
  property bool opened: false
  property string statusKey: ""
  property string errorText: ""
  readonly property bool setupVisible: editor.activeTab === "settings"
  property string pendingSort: ""
  property var document: null
  property var pendingRule: null
  property string pendingUrl: ""
  property string operation: ""
  readonly property string installer: decodeURIComponent(String(Qt.resolvedUrl("../install.sh")).replace(/^file:\/\//, ""))
  readonly property string backend: decodeURIComponent(String(Qt.resolvedUrl("../bin/browser-picker-editor-data")).replace(/^file:\/\//, ""))
  readonly property string picker: decodeURIComponent(String(Qt.resolvedUrl("../bin/browser-picker")).replace(/^file:\/\//, ""))

  function open(payloadJson) {
    let duplicateRequest = false
    try {
      const request = JSON.parse(payloadJson || "{}")
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
    window.visible = false
  }

  function syncWindowVisibility() {
    window.visible = opened
  }

  function install(refreshOnly) {
    statusKey = "working"
    errorText = ""
    setup.command = refreshOnly ? [installer, "--no-bridge", "--refresh"] : [installer, "--no-bridge"]
    setup.running = true
  }

  function applyPendingRule() {
    if (!pendingRule)
      return
    editor.beginRule(pendingRule.pattern, pendingRule.label || "")
    pendingUrl = pendingRule.url
    pendingRule = null
  }

  function readOrSave(action, payload) {
    if (dataWorker.running)
      return
    operation = action
    statusKey = "working"
    errorText = ""
    dataWorker.command = payload ? [backend, action, JSON.stringify(payload)] : [backend, action]
    dataWorker.running = true
  }

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  Process {
    id: setup
    stderr: StdioCollector { id: errors }
    onExited: function(exitCode, exitStatus) {
      root.statusKey = exitCode === 0 && exitStatus === 0 ? "success" : "failure"
      root.errorText = errors.text.trim()
    }
  }

  function writeSort() {
    if (sortWorker.running || pendingSort === "")
      return
    sortWorker.command = [backend, "sort", pendingSort]
    pendingSort = ""
    sortWorker.running = true
  }

  Process {
    id: sortWorker
    onExited: function(code, status) {
      if (code !== 0 || status !== 0)
        root.statusKey = "sortSaveFailed"
      Qt.callLater(root.writeSort)
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
      root.statusKey = root.operation === "save" ? "saved" : ""
      if (root.operation === "save" && root.pendingUrl) {
        const url = root.pendingUrl
        root.pendingUrl = ""
        Quickshell.execDetached([root.picker, url])
        if (root.shell) root.shell.hide("browser-better-default")
        else root.close()
      }
      root.applyPendingRule()
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

      RowLayout {
        Layout.fillWidth: true
        Text {
          Layout.fillWidth: true
          text: strings.t(root.setupVisible ? "setup" : "rules")
          textFormat: Text.PlainText
          font.family: Commons.Style.font.family
          font.pixelSize: Commons.Style.font.body + 3
          font.bold: true
          color: Commons.Color.foreground
        }
        Ui.Button {
          text: strings.t(root.setupVisible ? "rules" : "setup")
          focusable: true
          onClicked: {
            root.statusKey = ""
            editor.activeTab = root.setupVisible ? "rules" : "settings"
          }
        }
      }

      RulesEditor {
        id: editor
        Layout.fillWidth: true
        Layout.fillHeight: true
        document: root.document
        busy: dataWorker.running || setup.running
        onSetupRequested: refreshOnly => root.install(refreshOnly)
        onSortChosen: order => {
          root.pendingSort = order
          root.writeSort()
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
