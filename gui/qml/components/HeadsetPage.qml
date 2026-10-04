import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts

ColumnLayout {
    id: page
    objectName: "headsetPage"
    required property var app
    spacing: 16
    Surface {
        theme: page.app.theme
        Layout.fillWidth: true
        contentItem: ColumnLayout {
            spacing: 24
            SectionHeading { theme: page.app.theme; title: "Noise control"; description: "Choose how much of the world you hear."; Layout.fillWidth: true }
            Repeater { objectName: "noiseControlFields"; model: page.app.fields(["anc", "ambient_level", "voice_focus"]); delegate: DeviceField { required property var modelData; app: page.app; field: modelData; Layout.fillWidth: true } }
        }
    }
    Surface {
        theme: page.app.theme
        Layout.fillWidth: true
        contentItem: ColumnLayout {
            spacing: 20
            SectionHeading { theme: page.app.theme; title: "Noise control button"; description: "Choose the modes included in the headset button cycle."; Layout.fillWidth: true }
            Repeater { model: page.app.fields(["toggle_off", "toggle_nc", "toggle_ambient"]); delegate: DeviceField { required property var modelData; app: page.app; field: modelData; Layout.fillWidth: true } }
        }
    }
    Surface {
        theme: page.app.theme
        Layout.fillWidth: true
        contentItem: ColumnLayout {
            spacing: 24
            SectionHeading { theme: page.app.theme; title: "Power and startup"; Layout.fillWidth: true }
            Repeater { model: page.app.fields(["nc_startup", "bt_startup", "auto_power"]); delegate: DeviceField { required property var modelData; app: page.app; field: modelData; Layout.fillWidth: true } }
        }
    }
    Surface {
        theme: page.app.theme
        Layout.fillWidth: true
        contentItem: ColumnLayout {
            spacing: 24
            SectionHeading { theme: page.app.theme; title: "Voice guidance"; Layout.fillWidth: true }
            Repeater { model: page.app.fields(["language", "guidance"]); delegate: DeviceField { required property var modelData; app: page.app; field: modelData; Layout.fillWidth: true } }
        }
    }
    Surface {
        theme: page.app.theme
        Layout.fillWidth: true
        contentItem: ColumnLayout {
            spacing: 16
            SectionHeading { theme: page.app.theme; title: "Device information"; Layout.fillWidth: true }
            SettingRow { theme: page.app.theme; title: "Headset firmware"; Layout.fillWidth: true; Text { textFormat: Text.PlainText; text: page.app.device.firmware && page.app.device.firmware.headset ? page.app.device.firmware.headset : "Unavailable"; color: page.app.theme.secondaryText; font.pixelSize: 13 } }
            SettingRow { theme: page.app.theme; title: "Transceiver firmware"; Layout.fillWidth: true; Text { textFormat: Text.PlainText; text: page.app.device.firmware && page.app.device.firmware.dongle ? page.app.device.firmware.dongle : "Unavailable"; color: page.app.theme.secondaryText; font.pixelSize: 13 } }
        }
    }
}
