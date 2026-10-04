import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import "../data/ThirdPartyNotices.js" as Notices

Dialog {
    id: dialog
    objectName: "dependenciesDialog"
    required property var app
    property string query: ""
    readonly property var components: Notices.components
    readonly property var filteredComponents: components.filter(function(component) {
        var search = query.trim().toLowerCase();
        return !search || [component.name, component.category, component.license, component.purpose].join(" ").toLowerCase().indexOf(search) >= 0;
    })
    parent: Overlay.overlay
    x: (parent.width - width) / 2
    y: Math.max(16, (app.usableDialogHeight - height) / 2)
    width: Math.min(860, app.width - 32)
    height: Math.min(720, app.usableDialogHeight - 32)
    padding: 16
    modal: true
    title: "Dependencies and licenses"
    closePolicy: Popup.CloseOnEscape
    background: Rectangle { color: dialog.app.theme.surface; radius: 8; border.color: dialog.app.theme.border }
    onOpened: filterInput.forceActiveFocus()

    function showLicense(component) {
        dependencyList.currentIndex = filteredComponents.findIndex(function(value) { return value.id === component.id; });
        licenseDialog.component = component;
        licenseDialog.linkError = "";
        licenseDialog.open();
    }

    header: Label {
        textFormat: Text.PlainText
        text: dialog.title
        color: dialog.app.theme.text
        font.pixelSize: 20
        font.weight: Font.DemiBold
        padding: 16
        wrapMode: Text.WordWrap
    }
    contentItem: ColumnLayout {
        spacing: 12
        Label {
            textFormat: Text.PlainText
            text: "Project libraries, runtime services, and build components. Versions for system components depend on the installation."
            visible: dialog.height >= 440
            color: dialog.app.theme.secondaryText
            font.pixelSize: 13
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
        }
        TextField {
            id: filterInput
            objectName: "dependencyFilter"
            placeholderText: "Filter by name, license, or category"
            Accessible.name: "Filter dependencies"
            selectByMouse: true
            Layout.fillWidth: true
            onTextChanged: dialog.query = text
            Keys.onDownPressed: {
                if (dependencyList.count > 0) {
                    dependencyList.currentIndex = 0;
                    dependencyList.forceActiveFocus();
                }
            }
        }
        ListView {
            id: dependencyList
            objectName: "dependenciesList"
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            spacing: 8
            model: dialog.filteredComponents
            boundsBehavior: Flickable.StopAtBounds
            keyNavigationEnabled: true
            activeFocusOnTab: true
            Accessible.name: "Dependencies"
            ScrollBar.vertical: ScrollBar { }
            Keys.onReturnPressed: if (currentIndex >= 0) dialog.showLicense(model[currentIndex])
            Keys.onEnterPressed: if (currentIndex >= 0) dialog.showLicense(model[currentIndex])
            delegate: Pane {
                id: entry
                required property var modelData
                required property int index
                objectName: "dependency-" + modelData.id
                width: dependencyList.width - 14
                padding: 12
                background: Rectangle {
                    color: dialog.app.theme.background
                    radius: 6
                    border.color: dependencyList.activeFocus && entry.ListView.isCurrentItem ? dialog.app.theme.focus : dialog.app.theme.border
                }
                contentItem: RowLayout {
                    spacing: 12
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 4
                        Label { textFormat: Text.PlainText; text: entry.modelData.name; font.pixelSize: 15; font.weight: Font.DemiBold; color: dialog.app.theme.text; wrapMode: Text.WordWrap; Layout.fillWidth: true }
                        Label { textFormat: Text.PlainText; text: entry.modelData.category + " · " + entry.modelData.version; font.pixelSize: 12; color: dialog.app.theme.secondaryText; wrapMode: Text.WordWrap; Layout.fillWidth: true }
                        Label { textFormat: Text.PlainText; text: entry.modelData.purpose; font.pixelSize: 12; color: dialog.app.theme.secondaryText; wrapMode: Text.WordWrap; Layout.fillWidth: true }
                        Label { textFormat: Text.PlainText; text: entry.modelData.license; font.pixelSize: 12; color: dialog.app.theme.accentText; wrapMode: Text.Wrap; Layout.fillWidth: true }
                    }
                    ActionButton {
                        objectName: "dependencyLicense-" + entry.modelData.id
                        theme: dialog.app.theme
                        text: "License"
                        Accessible.name: "License and notices for " + entry.modelData.name
                        Layout.alignment: Qt.AlignTop
                        onClicked: dialog.showLicense(entry.modelData)
                        onActiveFocusChanged: if (activeFocus) dependencyList.positionViewAtIndex(entry.index, ListView.Beginning)
                    }
                }
            }
            Label {
                anchors.centerIn: parent
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: "No matching dependencies"
                color: dialog.app.theme.secondaryText
                visible: dependencyList.count === 0
            }
        }
    }
    footer: Pane {
        padding: 16
        background: Item { }
        contentItem: RowLayout {
            Label { text: dependencyList.count + " components"; color: dialog.app.theme.secondaryText; Layout.fillWidth: true }
            ActionButton { objectName: "dependenciesCloseButton"; theme: dialog.app.theme; text: "Close"; onClicked: dialog.close() }
        }
    }

    Dialog {
        id: licenseDialog
        objectName: "dependencyLicenseDialog"
        property var component: null
        property string linkError: ""
        parent: Overlay.overlay
        x: (parent.width - width) / 2
        y: Math.max(16, (dialog.app.usableDialogHeight - height) / 2)
        width: dialog.width
        height: dialog.height
        padding: 16
        modal: true
        closePolicy: Popup.CloseOnEscape
        background: Rectangle { color: dialog.app.theme.surface; radius: 8; border.color: dialog.app.theme.border }
        onOpened: {
            licenseText.cursorPosition = 0;
            licenseScroll.contentItem.contentY = 0;
            licenseText.forceActiveFocus();
        }
        onClosed: dependencyList.forceActiveFocus()
        function openLink(url) {
            linkError = Qt.openUrlExternally(url) ? "" : "Unable to open the link. Check the default application for this address.";
        }
        header: Label {
            textFormat: Text.PlainText
            text: licenseDialog.component ? licenseDialog.component.name : "License and notices"
            color: dialog.app.theme.text
            font.pixelSize: 20
            font.weight: Font.DemiBold
            padding: 16
            wrapMode: Text.WordWrap
        }
        contentItem: ScrollView {
            id: licenseScroll
            objectName: "dependencyLicenseScroll"
            clip: true
            contentWidth: availableWidth
            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
            TextArea {
                id: licenseText
                objectName: "dependencyLicenseText"
                textFormat: TextEdit.PlainText
                text: licenseDialog.component ? licenseDialog.component.name + "\n" + licenseDialog.component.version + "\n" + licenseDialog.component.license + "\n\n" + licenseDialog.component.notice : ""
                color: dialog.app.theme.text
                font.pixelSize: 13
                readOnly: true
                selectByMouse: true
                selectByKeyboard: true
                wrapMode: TextEdit.Wrap
                Accessible.name: "License and notices"
                background: Rectangle { color: dialog.app.theme.background; radius: 4 }
            }
        }
        footer: Pane {
            padding: 16
            background: Item { }
            contentItem: ColumnLayout {
                spacing: 8
                Label { textFormat: Text.PlainText; text: licenseDialog.linkError; visible: text.length > 0; color: dialog.app.theme.danger; wrapMode: Text.WordWrap; Layout.fillWidth: true; Accessible.role: Accessible.AlertMessage }
                RowLayout {
                    Layout.fillWidth: true
                    ActionButton { theme: dialog.app.theme; text: "Source"; enabled: !!licenseDialog.component && !!licenseDialog.component.sourceUrl; onClicked: licenseDialog.openLink(licenseDialog.component.sourceUrl) }
                    ActionButton { theme: dialog.app.theme; text: "Upstream license"; visible: !!licenseDialog.component && !!licenseDialog.component.licenseUrl; onClicked: licenseDialog.openLink(licenseDialog.component.licenseUrl) }
                    Item { Layout.fillWidth: true }
                    ActionButton { objectName: "dependencyLicenseCloseButton"; theme: dialog.app.theme; text: "Back"; onClicked: licenseDialog.close() }
                }
            }
        }
    }
}
