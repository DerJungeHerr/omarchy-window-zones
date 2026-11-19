import QtQuick
import QtQuick.Controls
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

  // Custom layouts: { cols: [percent, ...], split: [bool, ...] }, up to three,
  // shown in the panel between the built-in layouts and the scratchpad.
  // A JSON round trip turns the shell's Qt lists into plain arrays, so
  // Array.isArray and slice work on them.
  readonly property var customLayouts: {
    var v = JSON.parse(JSON.stringify(setting("layouts", []) || []))
    return Array.isArray(v) ? v : []
  }

  function setLayout(i, layout) {
    var next = customLayouts.slice()
    if (layout) next[i] = layout
    else next.splice(i, 1)
    save("layouts", next)
  }

  // n equal columns, keeping the splits of the columns that stay.
  function withColumns(layout, n) {
    var w = Math.floor(100 / n), cols = [], split = []
    for (var j = 0; j < n; j++) {
      cols.push(j === n - 1 ? 100 - w * (n - 1) : w)
      split.push(!!(layout && layout.split && layout.split[j]))
    }
    return { cols: cols, split: split }
  }

  // Where the columns meet, in percent from the left.
  function dividers(layout) {
    var sum = layout.cols.reduce(function(a, b) { return a + b }, 0) || 1, at = 0, out = []
    for (var j = 0; j < layout.cols.length - 1; j++) {
      at += layout.cols[j]
      out.push(Math.round(at / sum * 100))
    }
    return out
  }

  // Divider k moved to v: it stays 5 % clear of its neighbours, like the Lua side.
  function moveDivider(layout, k, v) {
    var d = dividers(layout)
    d[k] = Math.max(k > 0 ? d[k - 1] + 5 : 5, Math.min(k < d.length - 1 ? d[k + 1] - 5 : 95, Math.round(v)))
    var cols = [], prev = 0
    for (var j = 0; j < d.length; j++) { cols.push(d[j] - prev); prev = d[j] }
    cols.push(100 - prev)
    return { cols: cols, split: layout.split }
  }

  function toggleSplit(layout, j) {
    var split = layout.cols.map(function(_, i) { return !!(layout.split && layout.split[i]) })
    split[j] = !split[j]
    return { cols: layout.cols, split: split }
  }

  // The preview's cells as fractions, as window-zones.lua builds them.
  function previewCells(layout) {
    var d = dividers(layout), cells = [], x0 = 0
    for (var j = 0; j < layout.cols.length; j++) {
      var x1 = j < d.length ? d[j] / 100 : 1
      if (layout.split && layout.split[j]) {
        cells.push([x0, 0, x1, 0.5])
        cells.push([x0, 0.5, x1, 1])
      } else cells.push([x0, 0, x1, 1])
      x0 = x1
    }
    return cells
  }

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

      // Custom layouts can make the settings taller than a laptop screen; the
      // card stops at the screen, so the content scrolls instead of being cut.
      Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar {
          id: scroll
          policy: ScrollBar.AsNeeded
        }

        Column {
          id: column
          width: flick.width - (flick.interactive ? scroll.width + Style.space(6) : 0)
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

          PanelSeparator {
            width: column.width
            foreground: Commons.Color.popups.text
          }

          PanelSectionHeader {
            text: "Custom layouts"
            foreground: Commons.Color.popups.text
            opacity: root.value("enabled") ? 1 : 0.5
          }

          Repeater {
            // A count, not the array: a model array reaches delegates as Qt lists.
            model: root.customLayouts.length

            delegate: Column {
              id: editor
              required property int index
              readonly property var layout: {
                var l = root.customLayouts[index]
                return l && Array.isArray(l.cols) && l.cols.length > 0 ? l : root.withColumns(null, 2)
              }
              width: column.width
              spacing: Style.space(6)
              topPadding: Style.space(6)
              enabled: root.value("enabled")
              opacity: enabled ? 1 : 0.5

              Item {
                width: parent.width
                height: Math.max(name.implicitHeight, remove.height)
                Text {
                  id: name
                  anchors.verticalCenter: parent.verticalCenter
                  text: "Custom " + (editor.index + 1)
                  color: Commons.Color.popups.text
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                }
                PanelActionButton {
                  id: remove
                  anchors.right: parent.right
                  // nf-md-delete
                  iconText: "\u{F01B4}"
                  tooltipText: "Remove this layout"
                  foreground: Commons.Color.popups.text
                  onClicked: root.setLayout(editor.index, null)
                }
              }

              // A small screen with the layout's cells, like its tile in the panel.
              Rectangle {
                id: preview
                width: Math.round(parent.width * 0.5)
                height: Math.round(width * 9 / 16)
                radius: Math.min(Style.cornerRadius, 4)
                color: "transparent"
                border.color: Qt.alpha(Commons.Color.popups.text, 0.25)
                border.width: 1

                Repeater {
                  model: root.previewCells(editor.layout)
                  delegate: Rectangle {
                    required property var modelData
                    x: 3 + modelData[0] * (preview.width - 6) + (modelData[0] > 0 ? 1.5 : 0)
                    y: 3 + modelData[1] * (preview.height - 6) + (modelData[1] > 0 ? 1.5 : 0)
                    width: (modelData[2] - modelData[0]) * (preview.width - 6) - (modelData[0] > 0 ? 1.5 : 0) - (modelData[2] < 1 ? 1.5 : 0)
                    height: (modelData[3] - modelData[1]) * (preview.height - 6) - (modelData[1] > 0 ? 1.5 : 0) - (modelData[3] < 1 ? 1.5 : 0)
                    radius: 2
                    color: Qt.alpha(Commons.Color.popups.text, 0.12)
                    border.color: Qt.alpha(Commons.Color.popups.text, 0.25)
                    border.width: 1
                  }
                }
              }

              Row {
                spacing: Style.space(8)
                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: "Columns"
                  color: Commons.Color.popups.text
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                }
                ButtonGroup {
                  options: ["1", "2", "3", "4"]
                  value: String(editor.layout.cols.length)
                  foreground: Commons.Color.popups.text
                  onChanged: function(v) { root.setLayout(editor.index, root.withColumns(editor.layout, Number(v))) }
                }
              }

              // One slider per place where two columns meet.
              Repeater {
                model: root.dividers(editor.layout)
                delegate: Column {
                  id: divider
                  required property var modelData
                  required property int index
                  width: editor.width
                  spacing: Style.space(6)

                  Item {
                    width: parent.width
                    height: between.implicitHeight
                    Text {
                      id: between
                      text: "Columns " + (divider.index + 1) + " | " + (divider.index + 2)
                      color: Commons.Color.popups.text
                      opacity: 0.7
                      font.family: Style.font.family
                      font.pixelSize: Style.font.body
                    }
                    Text {
                      anchors.right: parent.right
                      text: Math.round(dividerSlider.liveValue) + " %"
                      color: Commons.Color.popups.text
                      opacity: 0.7
                      font.family: Style.font.family
                      font.pixelSize: Style.font.body
                    }
                  }

                  PanelSlider {
                    id: dividerSlider
                    bar: root.bar
                    width: parent.width
                    integer: true
                    minimum: 5
                    maximum: 95
                    step: 5
                    value: divider.modelData
                    onReleased: function(v) { root.setLayout(editor.index, root.moveDivider(editor.layout, divider.index, v)) }
                  }
                }
              }

              Row {
                spacing: Style.space(6)
                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: "Split"
                  color: Commons.Color.popups.text
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                }
                Repeater {
                  model: editor.layout.cols.length
                  delegate: Button {
                    required property int index
                    text: String(index + 1)
                    tooltipText: "Split column " + (index + 1) + " into a top and a bottom half"
                    bordered: true
                    foreground: Commons.Color.popups.text
                    selected: !!(editor.layout.split && editor.layout.split[index])
                    onClicked: root.setLayout(editor.index, root.toggleSplit(editor.layout, index))
                  }
                }
              }
            }
          }

          Button {
            visible: root.customLayouts.length < 3
            enabled: root.value("enabled")
            opacity: enabled ? 1 : 0.5
            text: "Add layout"
            // nf-md-plus
            iconText: "\u{F0415}"
            bordered: true
            foreground: Commons.Color.popups.text
            onClicked: root.setLayout(root.customLayouts.length, { cols: [60, 40], split: [false, true] })
          }
        }
      }
    }
  }
}
