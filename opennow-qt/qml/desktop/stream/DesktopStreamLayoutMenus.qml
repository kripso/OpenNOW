pragma ComponentBehavior: Bound

import QtQuick
import OpenNOW

// On-screen menus that an imported Steam Input layout has open. The overlay never takes input.
Item {
    id: root
    objectName: "streamLayoutMenus"
    enabled: false
    property var menus: []
    readonly property var leftMenus: menus.filter(menu => menu.left === true)
    readonly property var rightMenus: menus.filter(menu => menu.left !== true)

    component MenuPanel: Rectangle {
        id: panel
        required property var menu
        readonly property var items: menu.items || []
        readonly property int count: items.length
        readonly property bool radial: menu.radial === true
        readonly property int columns: Math.max(1, Number(menu.columns || 1))
        readonly property int rows: Math.ceil(count / columns)
        readonly property int padding: 14
        // The circle grows with the number of items so their labels do not run into each other.
        readonly property int radialRadius: 72 + Math.max(0, count - 6) * 14
        readonly property int radialSize: radialRadius * 2 + 92
        readonly property int cellWidth: 104
        readonly property int cellHeight: 30
        readonly property int cellSpacing: 8
        readonly property real titleHeight: String(menu.title || "") !== "" ? titleText.implicitHeight + 10 : 0
        readonly property real bodyWidth: radial ? radialSize : columns * cellWidth + (columns - 1) * cellSpacing
        readonly property real bodyHeight: radial ? radialSize
            : rows * cellHeight + Math.max(0, rows - 1) * cellSpacing

        width: bodyWidth + padding * 2
        height: titleHeight + bodyHeight + padding * 2
        radius: 16
        color: "#D90E1018"
        border.width: 1
        border.color: "#24FFFFFF"
        layer.enabled: HdrOutput.chromeRequired
        layer.effect: HdrChromeEffect {}

        Text {
            id: titleText
            x: panel.padding; y: panel.padding
            width: panel.bodyWidth
            visible: String(panel.menu.title || "") !== ""
            text: String(panel.menu.title || "")
            color: DesktopTokens.textHigh
            font.family: DesktopTokens.bodyFont; font.pixelSize: 12; font.weight: Font.Bold
            elide: Text.ElideRight
        }
        Repeater {
            model: panel.items
            delegate: Rectangle {
                id: entry
                required property var modelData
                required property int index
                readonly property bool chosen: entry.index === Number(panel.menu.selected)
                readonly property real slotX: panel.radial
                    ? panel.radialSize / 2 + panel.radialRadius * Math.sin(2 * Math.PI * entry.index / panel.count) - width / 2
                    : (entry.index % panel.columns) * (panel.cellWidth + panel.cellSpacing)
                readonly property real slotY: panel.radial
                    ? panel.radialSize / 2 - panel.radialRadius * Math.cos(2 * Math.PI * entry.index / panel.count) - height / 2
                    : Math.floor(entry.index / panel.columns) * (panel.cellHeight + panel.cellSpacing)
                x: panel.padding + slotX
                y: panel.padding + panel.titleHeight + slotY
                width: panel.radial ? 84 : panel.cellWidth
                height: panel.radial ? 28 : panel.cellHeight
                radius: height / 2
                color: entry.chosen ? "#F2F5FA" : "#14FFFFFF"
                Text {
                    anchors.centerIn: parent
                    width: parent.width - 12
                    horizontalAlignment: Text.AlignHCenter
                    elide: Text.ElideRight
                    text: String(entry.modelData) !== "" ? String(entry.modelData) : String(entry.index + 1)
                    color: entry.chosen ? "#0E1018" : DesktopTokens.textHigh
                    font.family: DesktopTokens.bodyFont; font.pixelSize: 12; font.weight: Font.Bold
                }
            }
        }
    }

    Column {
        anchors.left: parent.left
        anchors.bottom: parent.bottom
        anchors.margins: 24
        spacing: 12
        Repeater {
            model: root.leftMenus
            delegate: MenuPanel {
                required property var modelData
                menu: modelData
            }
        }
    }
    Column {
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: 24
        spacing: 12
        Repeater {
            model: root.rightMenus
            delegate: MenuPanel {
                required property var modelData
                menu: modelData
            }
        }
    }
}
