import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Wayland
import qs.Commons

// Loads hypr/perch.lua into Hyprland and draws what it reports while a window
// is dragged: the zone a drop would fill, and the layout panel under the bar.
// It decides nothing itself; perch.lua sends monitor-local geometry.
Item {
  id: root

  property var shell: null
  property var manifest: null

  property var state: ({})
  property real seq: 0
  // Marks this instance's Lua load; calls from any other load are ignored.
  property string gen: ""
  // Where the dock shows, or "" when it does not.
  property string dockEdge: ""

  readonly property string luaPath: Qt.resolvedUrl("hypr/perch.lua").toString().replace(/^file:\/\//, "")
  readonly property string shellJson: (Quickshell.env("XDG_CONFIG_HOME") || Quickshell.env("HOME") + "/.config") + "/omarchy/shell.json"
  // The dock reserves no space of its own, so Perch keeps windows clear of it.
  readonly property int dockSize: Math.round(36 * Style.fontScale) + Style.spacing.md * 2 + Style.spacing.xs

  function load() {
    // The path goes into Lua source, so it must be exactly this safe form.
    if (!/^[A-Za-z0-9_\/.\-]+$/.test(luaPath)) {
      console.warn("perch: refusing to load", luaPath)
      return
    }
    // A load asked for while one runs follows it, so the newest settings win.
    if (loader.running) {
      loader.again = true
      return
    }
    root.gen = String(Date.now())
    root.seq = 0
    root.state = {}
    var dock = root.dockEdge ? "{ edge = \"" + root.dockEdge + "\", size = " + root.dockSize + " }" : "nil"
    loader.command = ["hyprctl", "eval", "perch_gen = " + root.gen + " perch_dock = " + dock + " dofile(\"" + luaPath + "\")"]
    loader.running = true
  }

  function readDockEdge(text) {
    var config = {}
    try { config = JSON.parse(text) } catch (e) {}
    var d = config.dock || {}
    var off = Array.isArray(config.disabledPlugins) && config.disabledPlugins.indexOf("omarchy.dock") !== -1
    if (off || d.autohide === true) return ""
    return ["top", "bottom", "left", "right"].indexOf(d.position) !== -1 ? d.position : "bottom"
  }

  onDockSizeChanged: if (loader.loaded) load()

  FileView {
    path: root.shellJson
    watchChanges: true
    onFileChanged: reload()
    onLoaded: {
      var edge = root.readDockEdge(text())
      if (edge === root.dockEdge && loader.loaded) return
      root.dockEdge = edge
      root.load()
    }
    onLoadFailed: root.load()
  }

  Process {
    id: loader
    property bool loaded: false
    property bool again: false
    stdout: StdioCollector {
      onStreamFinished: if (text.trim() !== "ok") console.warn("perch: hyprctl eval said:", text.trim())
    }
    onExited: {
      loaded = true
      if (again) {
        again = false
        root.load()
      }
    }
  }

  // A config reload starts a fresh Lua state in Hyprland.
  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (event && String(event.name) === "configreloaded") root.load()
    }
  }

  // Stops only the Lua this instance loaded, never a newer one.
  Component.onDestruction: if (gen) Quickshell.execDetached(["hyprctl", "eval", "if perch and perch.gen == " + gen + " then perch.stop() end"])

  IpcHandler {
    target: "perch"

    // Calls are spawned one by one and may arrive out of order: keep the newest.
    function show(gen: string, seq: string, json: string): void {
      if (gen !== root.gen || Number(seq) <= root.seq) return
      root.seq = Number(seq)
      try { root.state = JSON.parse(json) } catch (e) { root.state = {} }
    }
  }

  Variants {
    model: Quickshell.screens

    delegate: Component {
      PanelWindow {
        id: overlay
        required property var modelData
        readonly property bool active: root.state.monitor === modelData.name
        readonly property var panel: active ? root.state.panel : null
        readonly property var hot: root.state.hot

        screen: modelData
        visible: active
        color: "transparent"
        anchors { top: true; bottom: true; left: true; right: true }
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "perch"
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        mask: Region {}

        Rectangle {
          readonly property var r: overlay.active ? root.state.preview : null
          visible: !!r
          x: r ? r.x : 0
          y: r ? r.y : 0
          width: r ? r.w : 0
          height: r ? r.h : 0
          radius: Style.cornerRadius
          color: Qt.alpha(Color.accent, 0.18)
          border.color: Color.accent
          border.width: 2
          Behavior on x { NumberAnimation { duration: 90; easing.type: Easing.OutCubic } }
          Behavior on width { NumberAnimation { duration: 90; easing.type: Easing.OutCubic } }
        }

        Rectangle {
          id: panelBox
          visible: !!overlay.panel
          x: overlay.panel ? overlay.panel.rect.x : 0
          width: overlay.panel ? overlay.panel.rect.w : 0
          height: overlay.panel ? overlay.panel.rect.h : 0
          // Slides down from under the bar.
          y: overlay.panel ? overlay.panel.rect.y : -height
          Behavior on y { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
          radius: Style.cornerRadius
          color: Color.popups.background
          border.color: Color.popups.border
          border.width: 1

          Repeater {
            model: overlay.panel ? overlay.panel.tiles : []

            delegate: Item {
              id: tile
              required property var modelData
              required property int index
              readonly property bool scratchpad: modelData.scratchpad === true

              Repeater {
                model: tile.modelData.cells

                delegate: Rectangle {
                  required property var modelData
                  required property int index
                  readonly property bool lit: !!overlay.hot && overlay.hot.layout === tile.index + 1 && overlay.hot.cell === index + 1
                  x: modelData.x - overlay.panel.rect.x
                  y: modelData.y - overlay.panel.rect.y
                  width: modelData.w
                  height: modelData.h
                  radius: Math.min(Style.cornerRadius, 4)
                  color: lit ? Color.accent : Qt.alpha(Color.popups.text, 0.12)
                  border.color: Qt.alpha(Color.popups.text, tile.scratchpad ? 0.5 : 0.25)
                  border.width: 1

                  Text {
                    visible: tile.scratchpad
                    anchors.centerIn: parent
                    text: "Scratchpad"
                    color: parent.lit ? Color.background : Color.popups.text
                    font.pixelSize: Style.font.body
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
