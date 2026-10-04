import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts

ColumnLayout {
    id: page
    objectName: "aboutPage"
    required property var app
    property string linkError: ""
    spacing: 16

    function openLink(url) {
        linkError = Qt.openUrlExternally(url) ? "" : "Unable to open the link. Check the default application for this address.";
    }

    Surface {
        theme: page.app.theme
        Layout.fillWidth: true
        contentItem: RowLayout {
            spacing: 20
            Rectangle {
                implicitWidth: 64
                implicitHeight: 64
                radius: 12
                color: page.app.theme.accentSurface
                Layout.alignment: Qt.AlignTop
                LineIcon { anchors.centerIn: parent; width: 40; height: 40; kind: "headset"; strokeColor: page.app.theme.accentText }
            }
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 10
                Text { objectName: "applicationNameLabel"; textFormat: Text.PlainText; text: "INZONE Control"; color: page.app.theme.text; font.pixelSize: 24; font.weight: Font.DemiBold; wrapMode: Text.WordWrap; Layout.fillWidth: true }
                Text { objectName: "applicationVersionLabel"; textFormat: Text.PlainText; text: Qt.application.version ? "Version " + Qt.application.version : "Development build"; color: page.app.theme.accentText; font.pixelSize: 14; wrapMode: Text.WordWrap; Layout.fillWidth: true }
                Text { textFormat: Text.PlainText; text: "Headset control and audio profiles for Sony INZONE H9 II on Linux."; color: page.app.theme.secondaryText; font.pixelSize: 14; wrapMode: Text.WordWrap; Layout.fillWidth: true }
            }
        }
    }

    GridLayout {
        columns: page.app.compactNavigation ? 1 : 2
        columnSpacing: 16
        rowSpacing: 16
        Layout.fillWidth: true
        Surface {
            theme: page.app.theme
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.preferredWidth: 1
            contentItem: ColumnLayout {
                spacing: 14
                SectionHeading { theme: page.app.theme; title: "Developer"; Layout.fillWidth: true }
                Text { objectName: "developerNameLabel"; textFormat: Text.PlainText; text: "Euiseo Cha"; color: page.app.theme.text; font.pixelSize: 18; font.weight: Font.DemiBold; wrapMode: Text.WordWrap; Layout.fillWidth: true }
                Text { textFormat: Text.PlainText; text: "zeroday0619"; color: page.app.theme.secondaryText; font.pixelSize: 14; Layout.fillWidth: true }
                TextEdit {
                    objectName: "developerEmailLabel"
                    textFormat: TextEdit.PlainText
                    text: "escha@zeroday0619.dev"
                    color: page.app.theme.secondaryText
                    font.pixelSize: 13
                    readOnly: true
                    selectByMouse: true
                    selectByKeyboard: true
                    wrapMode: TextEdit.WrapAnywhere
                    Accessible.name: "Developer email: " + text
                    Layout.fillWidth: true
                }
                Item { Layout.fillHeight: true }
                ActionButton { theme: page.app.theme; text: "Developer profile"; Layout.fillWidth: true; onClicked: page.openLink("https://github.com/zeroday0619") }
            }
        }
        Surface {
            theme: page.app.theme
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.preferredWidth: 1
            contentItem: ColumnLayout {
                spacing: 14
                SectionHeading { theme: page.app.theme; title: "Project"; description: "Source code, documentation, and support."; Layout.fillWidth: true }
                ActionButton { objectName: "projectWebsiteButton"; theme: page.app.theme; text: "Source code and documentation"; Layout.fillWidth: true; onClicked: page.openLink("https://github.com/zeroday0619/inzone-linux") }
                ActionButton { objectName: "reportIssueButton"; theme: page.app.theme; text: "Report an issue"; Layout.fillWidth: true; onClicked: page.openLink("https://github.com/zeroday0619/inzone-linux/issues") }
                Item { Layout.fillHeight: true }
            }
        }
    }

    Surface {
        theme: page.app.theme
        Layout.fillWidth: true
        contentItem: ColumnLayout {
            spacing: 14
            SectionHeading { theme: page.app.theme; title: "License and acknowledgments"; Layout.fillWidth: true }
            Text { objectName: "licenseLabel"; textFormat: Text.PlainText; text: "MIT License · Copyright © 2026 Euiseo Cha"; color: page.app.theme.text; font.pixelSize: 14; wrapMode: Text.WordWrap; Layout.fillWidth: true }
            Text { textFormat: Text.PlainText; text: "This independent community project is not affiliated with or endorsed by Sony. Sony and INZONE are trademarks of Sony Group Corporation. Third-party components and Sony audio assets retain their respective licenses."; color: page.app.theme.secondaryText; font.pixelSize: 13; wrapMode: Text.WordWrap; Layout.fillWidth: true }
            RowLayout {
                Layout.alignment: Qt.AlignLeft
                spacing: 8
                ActionButton { objectName: "licenseButton"; theme: page.app.theme; text: "View license"; onClicked: page.openLink("https://github.com/zeroday0619/inzone-linux/blob/main/LICENSE") }
                ActionButton { objectName: "aboutDependenciesButton"; theme: page.app.theme; text: "Dependencies and licenses"; onClicked: dependenciesDialog.open() }
            }
        }
    }
    DependenciesDialog { id: dependenciesDialog; app: page.app }
    Text { textFormat: Text.PlainText; text: page.linkError; visible: text.length > 0; color: page.app.theme.danger; font.pixelSize: 13; wrapMode: Text.WordWrap; Layout.fillWidth: true; Accessible.role: Accessible.AlertMessage }
}
