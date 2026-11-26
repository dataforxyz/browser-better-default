import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Layouts
import Quickshell.Io
import qs.Commons

Item {
  id: root

  property var shell: null
  property bool opened: false
  property string statusKey: ""
  property string errorText: ""
  readonly property string installer: decodeURIComponent(String(Qt.resolvedUrl("../install.sh")).replace(/^file:\/\//, ""))

  function open() {
    opened = true
    window.requestActivate()
  }

  function close() {
    opened = false
  }

  function install(refreshOnly) {
    statusKey = "working"
    errorText = ""
    setup.command = refreshOnly ? [installer, "--no-bridge", "--refresh"] : [installer, "--no-bridge"]
    setup.running = true
  }

  Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  Process {
    id: setup
    stderr: StdioCollector { id: errors }
    onExited: function(exitCode, exitStatus) {
      root.statusKey = exitCode === 0 && exitStatus === 0 ? "success" : "failure"
      root.errorText = errors.text.trim()
    }
  }

  Window {
    id: window
    title: strings.t("title")
    visible: root.opened
    width: 480
    height: content.implicitHeight + 48
    color: Color.background
    onClosing: function(event) {
      event.accepted = false
      if (root.shell) root.shell.hide("browser-better-default")
      else root.close()
    }

    ColumnLayout {
      id: content
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.margins: 24
      spacing: 12

      Text {
        Layout.fillWidth: true
        color: Color.foreground
        text: strings.t("description")
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
      }

      RowLayout {
        Controls.Button {
          text: strings.t("setDefault")
          enabled: !setup.running
          onClicked: root.install(false)
        }
        Controls.Button {
          text: strings.t("refresh")
          enabled: !setup.running
          onClicked: root.install(true)
        }
      }

      Text {
        Layout.fillWidth: true
        visible: root.statusKey !== ""
        color: Color.foreground
        text: root.statusKey ? strings.t(root.statusKey) : ""
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
      }

      Text {
        Layout.fillWidth: true
        visible: root.statusKey === "failure" && root.errorText !== ""
        color: Color.foreground
        text: root.errorText
        textFormat: Text.PlainText
        wrapMode: Text.Wrap
      }
    }
  }
}
