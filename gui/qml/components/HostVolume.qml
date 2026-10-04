import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts

ColumnLayout {
    id: row
    required property var app
    required property string field
    required property string title
    readonly property var reported: app.hostLevels[field]
    readonly property bool available: typeof reported === "number"
    Connections {
        target: row.app.backend
        function onBusyChanged() {
            if (!row.app.backend.busy) {
                volume.value = Qt.binding(function() { return row.available ? row.reported : 0; });
            }
        }
    }
    spacing: 8
    enabled: app.canChange && available
    RowLayout {
        Layout.fillWidth: true
        Text { textFormat: Text.PlainText; text: row.title; font.pixelSize: 14; color: row.enabled ? app.theme.text : app.theme.disabledText; Layout.fillWidth: true }
        Text { textFormat: Text.PlainText; text: available ? Math.round(volume.value) + "%" : "Unavailable"; font.pixelSize: 13; color: app.theme.secondaryText }
    }
    Slider {
        id: volume
        objectName: "hostVolume_" + row.field
        Layout.fillWidth: true
        from: 0; to: 100; stepSize: 1
        value: row.available ? row.reported : 0
        Accessible.name: row.title
        onMoved: { if (!pressed) commitTimer.restart(); }
        onPressedChanged: { if (!pressed) commitTimer.restart(); }
        Timer { id: commitTimer; interval: 200; onTriggered: app.invoke("SetHostField", row.field, "", Math.round(volume.value)) }
    }
}
