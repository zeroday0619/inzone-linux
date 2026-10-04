import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts

ColumnLayout {
    id: row
    objectName: "deviceField_" + field.name
    required property var app
    required property var field
    readonly property var values: field.values || []
    readonly property var labels: field.labels || []
    readonly property var reported: app.deviceFields[field.name]
    readonly property bool available: reported !== undefined && reported !== null
    readonly property int selection: values.indexOf(reported)
    readonly property bool toggle: values.length === 2 && values[0] === 0 && values[1] === 1
    readonly property bool continuous: values.length > 10
    readonly property bool needsAmbient: field.name === "ambient_level" || field.name === "voice_focus"
    Connections {
        target: row.app.backend
        function onBusyChanged() {
            if (!row.app.backend.busy) {
                valueSlider.value = Qt.binding(function() { return row.available ? row.reported : valueSlider.from; });
            }
        }
    }
    spacing: 8
    enabled: app.canChangeDevice && available && (!needsAmbient || app.deviceFields.anc === 2)
    RowLayout {
        Layout.fillWidth: true
        Text { textFormat: Text.PlainText; text: row.field.label; color: row.enabled ? row.app.theme.text : row.app.theme.disabledText; font.pixelSize: 14; Layout.fillWidth: true; wrapMode: Text.WordWrap }
        Text { textFormat: Text.PlainText; visible: row.continuous; text: row.available ? String(Math.round(valueSlider.value)) : "Unavailable"; color: row.app.theme.secondaryText; font.pixelSize: 13 }
        VerifiedSwitch {
            backend: row.app.backend
            objectName: "deviceToggle"
            visible: row.toggle
            reportedChecked: row.reported === 1
            Accessible.name: row.field.label
            onToggled: row.app.invoke("SetDeviceField", row.field.name, "", checked ? 1 : 0)
        }
        VerifiedChoiceBox {
            objectName: "deviceChoice"
            backend: row.app.backend
            theme: row.app.theme
            visible: !row.toggle && !row.continuous
            Layout.preferredWidth: 180
            model: row.labels.length === row.values.length ? row.labels : row.values.map(function(value) { return value === 0 && row.field.name === "auto_power" ? "Disabled" : String(value) + (row.field.name === "auto_power" ? " minutes" : ""); })
            reportedIndex: row.selection
            Accessible.name: row.field.label
            onActivated: row.app.invoke("SetDeviceField", row.field.name, "", row.values[currentIndex])
        }
    }
    Slider {
        id: valueSlider
        objectName: "deviceSlider"
        visible: row.continuous
        Layout.fillWidth: true
        from: row.values.length ? row.values[0] : 0
        to: row.values.length ? row.values[row.values.length - 1] : 1
        stepSize: row.values.length > 1 ? row.values[1] - row.values[0] : 1
        value: row.available ? row.reported : from
        Accessible.name: row.field.label
        onMoved: { if (!pressed) commitTimer.restart(); }
        onPressedChanged: { if (!pressed) commitTimer.restart(); }
        Timer { id: commitTimer; interval: 250; onTriggered: row.app.invoke("SetDeviceField", row.field.name, "", Math.round(valueSlider.value)) }
    }
    Text { textFormat: Text.PlainText; visible: row.needsAmbient && row.app.deviceFields.anc !== 2; text: "Available when Ambient sound is selected."; color: row.app.theme.secondaryText; font.pixelSize: 12 }
}
