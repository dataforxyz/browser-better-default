import QtQuick
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "browser-better-default"
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "↗"
    tooltipText: strings.t("title")
    onPressed: function(mouseButton) {
      if (mouseButton === Qt.LeftButton && root.bar)
        root.bar.run("omarchy-shell shell toggle browser-better-default '{}'")
    }
  }
}
