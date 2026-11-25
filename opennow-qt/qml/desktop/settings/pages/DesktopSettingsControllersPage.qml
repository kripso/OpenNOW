import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs
import OpenNOW

DesktopSettingsPanel {
    id: controlsRoot
    objectName: "desktopControllerBehaviorSettings"
    required property real availableWidth
    required property var settingsScreen

    function controllerGlyph(controller) {
        return controller && (controller.family === "playstation" || controller.family === "xbox")
            ? controller.family : "controller"
    }

    function batteryLabel(controller) {
        const percent = Number(controller.batteryPercent)
        const hasPercent = Number.isFinite(percent) && percent >= 0 && percent <= 100
        switch (controller.powerState) {
        case "charging": return hasPercent ? qsTr("Charging · %1%").arg(percent) : qsTr("Charging")
        case "charged": return qsTr("Fully charged")
        case "noBattery": return qsTr("Wired power")
        case "onBattery": return hasPercent ? qsTr("Battery %1%").arg(percent) : qsTr("On battery")
        default: return qsTr("Battery unavailable")
        }
    }

    width: controlsRoot.availableWidth; paperStyle: true
    DesktopSettingsSection { text: qsTr("CONTROLLERS") }
    DesktopSettingsRow {
        width: parent.width; paperStyle: true; glyph: "controller"; title: qsTr("Controller input")
        description: qsTr("%1 CONNECTED").arg(AppController.controllerCount)
        DesktopSettingsToggle { checked: controlsRoot.settingsScreen.boolSetting("controllerMode",true); onValueChangedByUser: value => controlsRoot.settingsScreen.setSetting("controllerMode",value) }
    }
    DesktopSettingsChoice {
        objectName: "controllerSourceChoice"
        width: parent.width
        title: qsTr("Controller input source")
        description: qsTr("Choose one device as Player 1 if a controller appears twice. Selection lasts until app restart; select again after reconnecting.")
        glyph: current ? current.glyph || "controller" : "controller"
        items: [{value: 0, label: qsTr("All controllers (multiplayer)")}].concat(
            ControllerInput.availableControllers.map(controller => ({
                value: controller.instanceId,
                label: qsTr("Device %1 · %2").arg(controller.slot).arg(controller.name),
                glyph: controlsRoot.controllerGlyph(controller),
                detail: controlsRoot.batteryLabel(controller)
            })))
        value: ControllerInput.inputControllerId
        valueLabel: current ? current.label : qsTr("Selected controller disconnected")
        onSelected: value => ControllerInput.inputControllerId = Number(value)
    }
    Repeater {
        model: ControllerInput.controllers
        delegate: DesktopSettingsRow {
            required property var modelData
            objectName: "controllerRow-" + modelData.instanceId
            width: parent.width; paperStyle: true
            glyph: controlsRoot.controllerGlyph(modelData); title: modelData.name
            description: qsTr("Player %1").arg(modelData.slot) + " · " + controlsRoot.batteryLabel(modelData)
            DesktopSettingsButton { text: "P" + modelData.slot; onClicked: AppController.navigate("joining") }
        }
    }
    DesktopSettingsRow {
        visible: ControllerInput.controllers.length === 0; width: parent.width; paperStyle: true; glyph: "controller"
        title: qsTr("No controllers connected"); description: qsTr("Connect a controller to assign a player")
        DesktopSettingsButton { text: qsTr("Controller order"); onClicked: AppController.navigate("joining") }
    }
    DesktopSettingsRow {
        width: parent.width; paperStyle: true; glyph: "controller"; title: qsTr("Left stick dead zone")
        description: qsTr("Ignore stick drift during gameplay. Default: 5%. The remaining travel is rescaled to full range.")
        DesktopSettingsSlider {
            objectName: "controllerLeftStickDeadzoneSlider"
            from: 0; to: 50; stepSize: 1
            value: Number(controlsRoot.settingsScreen.valueSetting("controllerLeftStickDeadzone", 5))
            onCommitted: value => controlsRoot.settingsScreen.setSetting("controllerLeftStickDeadzone", value)
        }
    }
    DesktopSettingsRow {
        width: parent.width; paperStyle: true; glyph: "controller"; title: qsTr("Right stick dead zone")
        description: qsTr("Ignore stick drift during gameplay. Default: 5%. Set to 0% to leave dead zones to the game.")
        DesktopSettingsSlider {
            objectName: "controllerRightStickDeadzoneSlider"
            from: 0; to: 50; stepSize: 1
            value: Number(controlsRoot.settingsScreen.valueSetting("controllerRightStickDeadzone", 5))
            onCommitted: value => controlsRoot.settingsScreen.setSetting("controllerRightStickDeadzone", value)
        }
    }
    DesktopSettingsRow {
        width: parent.width; paperStyle: true; glyph: "controller"; title: qsTr("Controller vibration")
        description: qsTr("Scale game vibration on supported controllers. Set to 0% to disable.")
        DesktopSettingsSlider {
            objectName: "controllerVibrationIntensitySlider"
            from: 0; to: 100; stepSize: 1
            value: Number(controlsRoot.settingsScreen.valueSetting("controllerVibrationIntensity", 100))
            onCommitted: value => controlsRoot.settingsScreen.setSetting("controllerVibrationIntensity", value)
        }
    }
    DesktopSettingsRow { width: parent.width; paperStyle: true; glyph: "globe"; title: qsTr("Gyroscope"); description: qsTr("Motion aiming on supported pads")
        DesktopSettingsToggle { checked: controlsRoot.settingsScreen.boolSetting("enableGyroscopeControls",false); onValueChangedByUser: value => controlsRoot.settingsScreen.setSetting("enableGyroscopeControls",value) }
    }
    FileDialog {
        id: layoutFileDialog
        title: qsTr("Choose a Steam Input layout file")
        fileMode: FileDialog.OpenFile
        onAccepted: SteamLayouts.importFile(selectedFile)
    }
    Connections {
        target: SteamLayouts
        function onLayoutImported() { steamLayoutReference.text = "" }
    }
    DesktopSettingsRow {
        objectName: "steamLayoutsRow"
        width: parent.width; paperStyle: true; glyph: "controller"; title: qsTr("Steam layouts")
        description: qsTr("Import community layouts made for Steam Input and pick one per controller in the stream menu")
        Row {
            spacing: DesktopTokens.px(10)
            DesktopSettingsField {
                id: steamLayoutReference
                objectName: "steamLayoutReference"
                width: DesktopTokens.px(220)
                placeholderText: qsTr("Steam layout link or ID")
                Accessible.name: placeholderText
            }
            DesktopSettingsButton {
                objectName: "steamLayoutImport"
                text: qsTr("Import")
                enabled: SteamLayouts.workshopId(steamLayoutReference.text) !== "" && !SteamLayouts.importing
                onClicked: SteamLayouts.importFromSteam(steamLayoutReference.text)
            }
            DesktopSettingsButton {
                objectName: "steamLayoutImportFile"
                text: qsTr("Import a file…")
                enabled: !SteamLayouts.importing
                onClicked: layoutFileDialog.open()
            }
        }
    }
    Item {
        width: parent.width
        visible: SteamLayouts.message !== ""
        height: visible ? steamLayoutMessage.implicitHeight + DesktopTokens.px(12) : 0
        Text {
            id: steamLayoutMessage
            objectName: "steamLayoutMessage"
            x: DesktopTokens.settingsLabelInset
            width: parent.width - 2 * x
            text: SteamLayouts.message
            color: DesktopTokens.textMuted
            font.family: DesktopTokens.bodyFont; font.pixelSize: 11; font.weight: Font.DemiBold
            wrapMode: Text.WordWrap
        }
    }
    Repeater {
        model: SteamLayouts.layouts
        delegate: DesktopSettingsRow {
            id: layoutRow
            required property var modelData
            required property int index
            objectName: "steamLayoutRow-" + index
            width: parent.width; paperStyle: true; glyph: "controller"
            title: String(modelData.title || "")
            description: String(modelData.controllerType || "").replace("controller_", "")
            DesktopSettingsButton {
                objectName: "steamLayoutRemove-" + layoutRow.index
                text: qsTr("Remove")
                onClicked: SteamLayouts.remove(layoutRow.modelData.id)
            }
        }
    }
}
