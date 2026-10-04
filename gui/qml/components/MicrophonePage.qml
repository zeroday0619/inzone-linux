import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts

ColumnLayout {
    id: page
    required property var app
    spacing: 16
    Surface {
        theme: page.app.theme
        Layout.fillWidth: true
        contentItem: ColumnLayout {
            spacing: 24
            SectionHeading { theme: page.app.theme; title: "Microphone input"; description: "Control your voice level and mute state."; Layout.fillWidth: true }
            HostVolume { app: page.app; field: "mic_volume"; title: "Microphone volume"; Layout.fillWidth: true }
            SettingRow {
                theme: page.app.theme; title: "Mute microphone"; description: "Mute the microphone input for applications."; Layout.fillWidth: true
                VerifiedSwitch { backend: page.app.backend; reportedChecked: page.app.hostLevels.mic_mute === true || page.app.hostLevels.mic_mute === 1; enabled: page.app.canChange && page.app.hostLevels.mic_mute !== undefined; Accessible.name: "Mute microphone"; onToggled: page.app.invoke("SetHostField", "mic_mute", "", checked ? 1 : 0) }
            }
            Text { textFormat: Text.PlainText; text: page.app.device.microphone_attached === true ? "Boom microphone attached" : page.app.device.microphone_attached === false ? "Boom microphone detached" : "Microphone attachment status unavailable"; color: page.app.theme.secondaryText; font.pixelSize: 12 }
        }
    }
    Surface {
        theme: page.app.theme
        Layout.fillWidth: true
        contentItem: ColumnLayout {
            spacing: 20
            SectionHeading { theme: page.app.theme; title: "Voice processing"; description: "Settings for " + page.app.profileName(page.app.selectedProfileId); Layout.fillWidth: true }
            SettingRow {
                theme: page.app.theme; title: "Automatic microphone gain"; description: "Adjust input gain automatically for a more even voice level."; Layout.fillWidth: true
                VerifiedSwitch { backend: page.app.backend; objectName: "microphoneGainSwitch"; reportedChecked: page.app.options.mic_agc === true; enabled: page.app.canChange && page.app.selectedProfile !== null; Accessible.name: "Automatic microphone gain"; onToggled: page.app.changeOption("mic_agc", checked) }
            }
            Text { textFormat: Text.PlainText; text: "Select a sound profile on the Sound page to change its voice processing."; color: page.app.theme.secondaryText; font.pixelSize: 12; Layout.fillWidth: true; wrapMode: Text.WordWrap }
        }
    }
    Surface {
        theme: page.app.theme
        Layout.fillWidth: true
        contentItem: ColumnLayout {
            spacing: 20
            SectionHeading { theme: page.app.theme; title: "Sidetone"; description: "Hear your voice through the headset while speaking."; Layout.fillWidth: true }
            Repeater { model: page.app.fields(["sidetone"]); delegate: DeviceField { required property var modelData; app: page.app; field: modelData; Layout.fillWidth: true } }
        }
    }
}
