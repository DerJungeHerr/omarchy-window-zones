import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// The bar icon: left click opens the settings, right click turns Window Zones
// on or off. Settings live on this widget's entry in shell.json, where
// Service.qml reads them and hands them to the Lua side.
Panel {
  id: root
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property var defaults: ({
    enabled: true, edges: true, panel: true, fan: true, peek: true, hoverFocus: false,
    fanMax: 5, fanOffset: 24, peekDelay: 250, peekOpacity: 85, newWindowSize: 100
  })

  readonly property var switches: [
    { key: "edges", label: "Screen edges", description: "Drag to the left or right edge for a half, into a corner for a quarter" },
    { key: "panel", label: "Layout panel", description: "Drag under the clock for zones and the scratchpad" },
    { key: "fan", label: "Fan out shared zones", description: "Windows dropped on a taken zone fan out like cards" },
    { key: "peek", label: "Peek in fans", description: "Rest on a covered window to see it" },
    { key: "hoverFocus", label: "Focus follows mouse", description: "Hovering a window focuses it, like on tiled workspaces" }
  ]

  readonly property var sliders: [
    { key: "fanMax", label: "Windows per fan", min: 2, max: 8, step: 1, unit: "" },
    { key: "fanOffset", label: "Fan offset", min: 8, max: 60, step: 4, unit: " px" },
    { key: "peekDelay", label: "Peek delay", min: 100, max: 1000, step: 50, unit: " ms" },
    { key: "peekOpacity", label: "Peek opacity", min: 40, max: 100, step: 5, unit: " %" },
    { key: "newWindowSize", label: "New window size", min: 50, max: 150, step: 5, unit: " %" }
  ]

  function value(key) { return setting(key, defaults[key]) }

  function save(key, v) {
    var next = Object.assign({}, root.settings)
    next[key] = v
    root.settings = next
    if (root.bar && root.bar.shell) root.bar.shell.updateEntryInline(root.moduleName, next)
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // nf-md-view-grid / view-grid-outline
    text: root.value("enabled") ? "\u{F0570}" : "\u{F0571}"
    tooltipText: root.value("enabled") ? "Window Zones" : "Window Zones (off)"
    onPressed: function(b) {
      if (b === Qt.RightButton) root.save("enabled", !root.value("enabled"))
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight)

    content: PanelKeyCatcher {
      anchors.fill: parent
      implicitHeight: column.implicitHeight
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        width: parent.width
        spacing: Style.space(4)

        Toggle {
          width: parent.width
          label: "Window Zones"
          description: "Snap windows by dragging them"
          checked: root.value("enabled")
          onClicked: root.save("enabled", !checked)
        }

        Repeater {
          model: root.switches

          delegate: Toggle {
            required property var modelData
            width: column.width
            enabled: root.value("enabled")
            opacity: enabled ? 1 : 0.5
            label: modelData.label
            description: modelData.description
            checked: root.value(modelData.key)
            onClicked: root.save(modelData.key, !checked)
          }
        }

        Repeater {
          model: root.sliders

          delegate: Column {
            id: row
            required property var modelData
            width: column.width
            spacing: Style.space(6)
            topPadding: Style.space(8)
            enabled: root.value("enabled")
            opacity: enabled ? 1 : 0.5

            Item {
              width: parent.width
              height: label.implicitHeight
              Text {
                id: label
                text: row.modelData.label
                color: Commons.Color.popups.text
                font.family: Style.font.family
                font.pixelSize: Style.font.body
              }
              Text {
                anchors.right: parent.right
                text: Math.round(slider.liveValue) + row.modelData.unit
                color: Commons.Color.popups.text
                opacity: 0.7
                font.family: Style.font.family
                font.pixelSize: Style.font.body
              }
            }

            PanelSlider {
              id: slider
              bar: root.bar
              width: parent.width
              integer: true
              minimum: row.modelData.min
              maximum: row.modelData.max
              step: row.modelData.step
              value: root.value(row.modelData.key)
              onReleased: function(v) { root.save(row.modelData.key, Math.round(v)) }
            }
          }
        }
      }
    }
  }
}
