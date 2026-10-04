import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts

ColumnLayout {
    id: page
    required property var app
    readonly property var automation: app.state.automation || {}
    readonly property var rules: automation.rules || []
    spacing: 16
    Surface {
        theme: page.app.theme
        Layout.fillWidth: true
        contentItem: ColumnLayout {
            spacing: 20
            SectionHeading { theme: page.app.theme; title: "Automatic profile switching"; description: "Use a saved profile when a matching application is running."; Layout.fillWidth: true }
            SettingRow {
                theme: page.app.theme; title: "Enable app profiles"; description: "Higher-priority rules take precedence when several apps are running."; Layout.fillWidth: true
                VerifiedSwitch { backend: page.app.backend; reportedChecked: page.automation.enabled === true; enabled: page.app.canChange; Accessible.name: "Enable automatic app profiles"; onToggled: page.app.invoke("SetAutomationEnabled", "", "", checked ? 1 : 0) }
            }
            Text { textFormat: Text.PlainText; text: page.app.state.automation_error || ""; visible: text.length > 0; color: page.app.theme.danger; font.pixelSize: 12; Layout.fillWidth: true; wrapMode: Text.WordWrap }
        }
    }
    Surface {
        theme: page.app.theme
        Layout.fillWidth: true
        contentItem: ColumnLayout {
            spacing: 16
            SectionHeading { theme: page.app.theme; title: "Add an application"; description: "Enter the application process name, such as firefox or discord."; Layout.fillWidth: true }
            RowLayout {
                Layout.fillWidth: true
                spacing: 12
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Label { textFormat: Text.PlainText; text: "Application"; font.pixelSize: 12 }
                    TextField { id: applicationName; objectName: "applicationNameInput"; Layout.fillWidth: true; placeholderText: "Process name"; selectByMouse: true; enabled: page.app.canChange; Accessible.name: "Application process name" }
                }
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Label { textFormat: Text.PlainText; text: "Profile"; font.pixelSize: 12 }
                    ChoiceBox {
                    theme: page.app.theme; id: applicationProfile; objectName: "applicationProfileSelector"; Layout.fillWidth: true; model: page.app.profiles; textRole: "name"; valueRole: "id"; enabled: page.app.canChange; Accessible.name: "Application sound profile" }
                }
                ColumnLayout {
                    spacing: 8
                    Label { textFormat: Text.PlainText; text: "Priority"; font.pixelSize: 12 }
                    SpinBox { id: applicationPriority; objectName: "applicationPriorityInput"; from: -1000; to: 1000; value: 0; editable: true; enabled: page.app.canChange; Accessible.name: "Application priority"; Layout.preferredWidth: 130 }
                }
            }
            ActionButton { theme: page.app.theme; text: "Save app rule"; primary: true; Layout.alignment: Qt.AlignRight; enabled: page.app.canChange && applicationName.text.trim().length > 0 && applicationProfile.currentIndex >= 0; onClicked: page.app.invoke("BindApplication", applicationName.text.trim(), applicationProfile.currentValue, applicationPriority.value) }
        }
    }
    Surface {
        theme: page.app.theme
        Layout.fillWidth: true
        contentItem: ColumnLayout {
            spacing: 20
            SectionHeading { theme: page.app.theme; title: "Application rules"; description: page.rules.length + (page.rules.length === 1 ? " saved rule" : " saved rules"); Layout.fillWidth: true }
            ColumnLayout {
                visible: page.rules.length === 0
                Layout.fillWidth: true
                Layout.topMargin: 24
                Layout.bottomMargin: 24
                spacing: 12
                LineIcon { kind: "apps"; strokeColor: page.app.theme.secondaryText; width: 32; height: 32; Layout.alignment: Qt.AlignHCenter }
                Text { textFormat: Text.PlainText; text: "No application rules yet"; color: page.app.theme.text; font.pixelSize: 14; Layout.alignment: Qt.AlignHCenter }
                Text { textFormat: Text.PlainText; text: "Add an application above to choose its sound profile."; color: page.app.theme.secondaryText; font.pixelSize: 12; Layout.alignment: Qt.AlignHCenter }
            }
            Repeater {
                model: page.rules
                delegate: RowLayout {
                    required property var modelData
                    Layout.fillWidth: true
                    spacing: 16
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 6
                        Text { textFormat: Text.PlainText; text: modelData.app; color: page.app.theme.text; font.pixelSize: 14; font.weight: Font.DemiBold; Layout.fillWidth: true; elide: Text.ElideMiddle }
                        Text { textFormat: Text.PlainText; text: page.app.profileName(modelData.profile) + " · Priority " + modelData.priority; color: page.app.theme.secondaryText; font.pixelSize: 12 }
                    }
                    ActionButton { theme: page.app.theme; text: "Edit"; subtle: true; enabled: page.app.canChange; onClicked: { applicationName.text = modelData.app; applicationProfile.currentIndex = page.app.profiles.findIndex(function(profile) { return profile.id === modelData.profile; }); applicationPriority.value = modelData.priority; applicationName.forceActiveFocus(); } }
                    ActionButton { theme: page.app.theme; text: "Remove"; subtle: true; destructive: true; enabled: page.app.canChange; onClicked: page.app.invoke("RemoveApplication", modelData.app, "", 0) }
                }
            }
        }
    }
}
