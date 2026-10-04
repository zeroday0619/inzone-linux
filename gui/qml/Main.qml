import QtQuick
import QtQuick.Window
import QtQuick.Controls.Basic
import QtQuick.Layouts
import "components"

ApplicationWindow {
    id: window
    required property QtObject backend
    width: Math.min(1180, Screen.width)
    height: Math.min(840, Screen.height)
    minimumWidth: 640
    minimumHeight: 360
    visible: true
    title: "INZONE — Headset control"
    font.pixelSize: 14
    color: theme.background

    property bool darkMode: Qt.styleHints.colorScheme === Qt.Dark
    readonly property bool compactNavigation: width < 900
    readonly property int pageMargin: width < 900 ? 16 : 32
    readonly property real usableDialogHeight: Qt.inputMethod.visible && Qt.inputMethod.keyboardRectangle.height > 0
        ? Math.min(height, Qt.inputMethod.keyboardRectangle.y) : height
    readonly property real keyboardInset: Math.max(0, height - usableDialogHeight)
    property int currentPage: 0
    readonly property bool showingAbout: currentPage === 4
    property string selectedProfileId: ""
    property var state: parseState(backend.stateJSON)
    readonly property var profiles: state.profiles || []
    readonly property var selectedProfile: profiles.find(function(profile) { return profile.id === selectedProfileId; }) || null
    readonly property var options: selectedProfile ? selectedProfile.options : {}
    readonly property var device: state.device || {}
    readonly property var deviceFields: device.fields || {}
    readonly property var hostLevels: state.host_levels || {}
    readonly property bool canChange: backend.connected && !backend.busy
    readonly property bool canChangeDevice: canChange && device.connected === true
    readonly property var pages: [
        {title: "Sound", subtitle: "Shape the way you listen.", icon: "sound"},
        {title: "Microphone", subtitle: "Make every conversation clear.", icon: "microphone"},
        {title: "Headset", subtitle: "Set up your INZONE H9 II.", icon: "headset"},
        {title: "App profiles", subtitle: "The right sound for each application.", icon: "apps"},
        {title: "About", subtitle: "Application and developer information.", icon: "info"}
    ]
    property QtObject theme: QtObject {
        readonly property color background: darkMode ? "#202020" : "#f5f5f5"
        readonly property color sidebar: darkMode ? "#262626" : "#f0f0f0"
        readonly property color surface: darkMode ? "#2c2c2c" : "#ffffff"
        readonly property color text: darkMode ? "#f5f5f5" : "#242424"
        readonly property color secondaryText: darkMode ? "#c2c2c2" : "#616161"
        readonly property color disabledText: darkMode ? "#999999" : "#8a8a8a"
        readonly property color border: darkMode ? "#414141" : "#e0e0e0"
        readonly property color controlBorder: darkMode ? "#666666" : "#b3b3b3"
        readonly property color hover: darkMode ? "#383838" : "#ebebeb"
        readonly property color pressed: darkMode ? "#424242" : "#e0e0e0"
        readonly property color disabledSurface: darkMode ? "#303030" : "#f0f0f0"
        readonly property color accent: "#0f6cbd"
        readonly property color accentHover: "#115ea3"
        readonly property color accentPressed: "#0c3b5e"
        readonly property color accentText: darkMode ? "#77b7f7" : "#0f6cbd"
        readonly property color accentSurface: darkMode ? "#193a53" : "#e8f2fc"
        readonly property color focus: darkMode ? "#ffffff" : "#242424"
        readonly property color danger: darkMode ? "#ffb3b3" : "#a4262c"
        readonly property color errorSurface: darkMode ? "#442626" : "#fdf3f4"
        readonly property color success: darkMode ? "#9fd89f" : "#107c10"
    }
    palette.window: theme.background
    palette.windowText: theme.text
    palette.base: theme.surface
    palette.alternateBase: theme.sidebar
    palette.text: theme.text
    palette.button: theme.surface
    palette.buttonText: theme.text
    palette.highlight: theme.accent
    palette.highlightedText: "#ffffff"
    palette.mid: theme.controlBorder
    palette.light: theme.border
    palette.dark: theme.border

    function parseState(text) {
        try {
            var result = JSON.parse(text || "{}");
            return result && typeof result === "object" && !Array.isArray(result) ? result : {};
        }
        catch (error) { return {}; }
    }
    function invoke(method, first, second, value) {
        if (canChange) backend.invoke(method, first || "", second || "", value || 0);
    }
    function changeOption(name, value) {
        if (!selectedProfile) return;
        var changes = {};
        changes[name] = value;
        invoke("SetProfileOptions", selectedProfileId, JSON.stringify(changes), 0);
    }
    function profileName(identifier) {
        var profile = profiles.find(function(value) { return value.id === identifier; });
        return profile ? profile.name : identifier || "No active profile";
    }
    function fields(names) {
        return (state.device_fields || []).filter(function(field) { return names.indexOf(field.name) >= 0; });
    }
    function openProfileDialog(rename) {
        profileDialog.rename = rename;
        profileNameField.text = rename && selectedProfile ? selectedProfile.name : "";
        profileDialog.open();
        profileNameField.forceActiveFocus();
    }
    function synchronizeSelection() {
        var entries = state.profiles || [];
        if (!entries.some(function(profile) { return profile.id === selectedProfileId; })) {
            selectedProfileId = window.state.active_profile || (entries.length ? entries[0].id : "");
        }
    }
    function revealFocusedControl() {
        var focused = activeFocusItem;
        var viewport = contentScroll.contentItem;
        if (!focused || !viewport) return;
        var ancestor = focused;
        while (ancestor && ancestor !== viewport) ancestor = ancestor.parent;
        if (!ancestor) return;
        var position = focused.mapToItem(viewport, 0, 0);
        var availableHeight = viewport.height;
        var keyboard = Qt.inputMethod.keyboardRectangle;
        if (Qt.inputMethod.visible && keyboard.height > 0) {
            var viewportPosition = viewport.mapToItem(window.contentItem, 0, 0);
            availableHeight = Math.max(0, Math.min(availableHeight, keyboard.y - viewportPosition.y));
        }
        var target = viewport.contentY;
        if (position.y < 8) target += position.y - 8;
        else if (position.y + focused.height > availableHeight - 8) {
            target += position.y + focused.height - availableHeight + 8;
        }
        viewport.contentY = Math.max(0, Math.min(target, Math.max(0, viewport.contentHeight - viewport.height)));
    }
    onActiveFocusItemChanged: Qt.callLater(revealFocusedControl)
    onHeightChanged: Qt.callLater(revealFocusedControl)
    Connections {
        target: Qt.inputMethod
        function onKeyboardRectangleChanged() { Qt.callLater(window.revealFocusedControl); }
        function onVisibleChanged() { Qt.callLater(window.revealFocusedControl); }
    }
    onStateChanged: Qt.callLater(synchronizeSelection)
    onCurrentPageChanged: Qt.callLater(function() {
        contentScroll.contentItem.contentY = 0;
        revealFocusedControl();
    })
    Component.onCompleted: { synchronizeSelection(); backend.refresh(); }
    Timer { interval: 100; repeat: true; running: true; onTriggered: backend.poll() }
    Timer { interval: 5000; repeat: true; running: true; onTriggered: { if (!backend.busy) backend.refresh(); } }
    Shortcut { sequence: "Ctrl+R"; onActivated: { if (!backend.busy) backend.refresh(); } }
    Shortcut { sequence: "Ctrl+1"; onActivated: currentPage = 0 }
    Shortcut { sequence: "Ctrl+2"; onActivated: currentPage = 1 }
    Shortcut { sequence: "Ctrl+3"; onActivated: currentPage = 2 }
    Shortcut { sequence: "Ctrl+4"; onActivated: currentPage = 3 }
    Shortcut { sequence: "Ctrl+5"; onActivated: currentPage = 4 }

    RowLayout {
        objectName: "guiRoot"
        anchors.fill: parent
        spacing: 0
        Rectangle {
            Layout.preferredWidth: window.compactNavigation ? 72 : 220
            Layout.fillHeight: true
            color: theme.sidebar
            Rectangle { anchors.right: parent.right; width: 1; height: parent.height; color: theme.border }
            ColumnLayout {
                anchors.fill: parent
                anchors.margins: window.compactNavigation ? 8 : 16
                spacing: 8
                RowLayout {
                    Layout.topMargin: window.compactNavigation ? 0 : 16
                    Layout.bottomMargin: window.compactNavigation ? 0 : 32
                    Layout.leftMargin: 12
                    spacing: 12
                    LineIcon { kind: "headset"; strokeColor: theme.accentText; Layout.preferredWidth: 28; Layout.preferredHeight: 28 }
                    Text { textFormat: Text.PlainText; visible: !window.compactNavigation; text: "INZONE"; color: theme.text; font.pixelSize: 22; font.weight: Font.DemiBold; font.letterSpacing: 1.5 }
                }
                Text { textFormat: Text.PlainText; visible: !window.compactNavigation; text: "INZONE CONTROL"; color: theme.secondaryText; font.pixelSize: 10; font.weight: Font.DemiBold; font.letterSpacing: 1.2; Layout.leftMargin: 12; Layout.bottomMargin: 8 }
                Repeater {
                    model: window.pages
                    delegate: Button {
                        required property int index
                        required property var modelData
                        objectName: "navigation" + index
                        Layout.fillWidth: true
                        implicitHeight: 44
                        checkable: true
                        checked: window.currentPage === index
                        Accessible.name: modelData.title
                        ToolTip.text: modelData.title
                        ToolTip.visible: window.compactNavigation && hovered
                        onClicked: window.currentPage = index
                        contentItem: RowLayout {
                            spacing: 12
                            LineIcon { kind: modelData.icon; strokeColor: parent.parent.checked ? theme.accentText : theme.secondaryText; Layout.leftMargin: 12 }
                            Text { textFormat: Text.PlainText; visible: !window.compactNavigation; text: modelData.title; color: theme.text; font.pixelSize: 14; font.weight: window.currentPage === index ? Font.DemiBold : Font.Normal; Layout.fillWidth: true }
                        }
                        background: Rectangle {
                            radius: 6
                            color: parent.checked ? theme.surface : parent.hovered ? theme.hover : "transparent"
                            border.width: parent.visualFocus ? 2 : 0
                            border.color: theme.focus
                            Rectangle { visible: window.currentPage === index; width: 3; height: 20; radius: 2; color: theme.accentText; anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter }
                        }
                    }
                }
                Item { Layout.fillHeight: true }
                Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: theme.border; Layout.bottomMargin: 12 }
                RowLayout {
                    Layout.leftMargin: 12
                    spacing: 8
                    Rectangle { implicitWidth: 7; implicitHeight: 7; radius: 4; color: backend.connected ? theme.success : theme.disabledText }
                    Text { textFormat: Text.PlainText; visible: !window.compactNavigation; text: backend.connected ? "Service connected" : "Service unavailable"; color: theme.secondaryText; font.pixelSize: 12 }
                }
                Text { textFormat: Text.PlainText; visible: !window.compactNavigation; text: "Linux headset control"; color: theme.secondaryText; font.pixelSize: 11; Layout.leftMargin: 12; Layout.topMargin: 4; Layout.bottomMargin: 12 }
            }
        }
        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0
            RowLayout {
                objectName: "headerRow"
                Layout.fillWidth: true
                Layout.margins: window.pageMargin
                Layout.bottomMargin: 24
                ColumnLayout {
                    objectName: "headerTitle"
                    spacing: 8
                    Layout.fillWidth: true
                    Text { textFormat: Text.PlainText; text: window.pages[currentPage].title; color: theme.text; font.pixelSize: window.compactNavigation ? 26 : 30; font.weight: Font.DemiBold; Layout.fillWidth: true }
                    Text { textFormat: Text.PlainText; visible: window.width >= 720; text: window.pages[currentPage].subtitle; color: theme.secondaryText; font.pixelSize: 14; Layout.fillWidth: true }
                }
                ActionButton { theme: window.theme; text: darkMode ? "Light theme" : "Dark theme"; subtle: true; onClicked: darkMode = !darkMode }
                ActionButton { objectName: "refreshButton"; theme: window.theme; text: "Refresh"; visible: !window.showingAbout; enabled: !backend.busy; onClicked: backend.refresh(); ToolTip.text: "Refresh status (Ctrl+R)"; ToolTip.visible: hovered }
            }
            ProgressBar { Layout.fillWidth: true; implicitHeight: 3; indeterminate: true; visible: backend.busy && !window.showingAbout }
            ScrollView {
                id: contentScroll
                objectName: "contentScroll"
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                contentWidth: availableWidth
                ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
                ColumnLayout {
                    width: contentScroll.availableWidth - window.pageMargin * 2
                    x: window.pageMargin
                    spacing: 16
                    Rectangle {
                        Layout.fillWidth: true
                        implicitHeight: connectionLabel.implicitHeight + 32
                        objectName: "connectionWarning"
                        visible: !backend.connected && !window.showingAbout
                        radius: 6; color: theme.errorSurface; border.color: theme.border
                        Text { textFormat: Text.PlainText; id: connectionLabel; anchors.fill: parent; anchors.margins: 16; text: "The INZONE service is unavailable. Start the user service, then select Refresh."; color: theme.danger; font.pixelSize: 13; wrapMode: Text.WordWrap }
                    }
                    Rectangle {
                        Layout.fillWidth: true
                        implicitHeight: messageLayout.implicitHeight + 24
                        visible: !window.showingAbout && (backend.errorMessage.length > 0 || backend.notice.length > 0)
                        radius: 6; color: backend.errorMessage.length ? theme.errorSurface : theme.accentSurface; border.color: theme.border
                        RowLayout {
                            id: messageLayout
                            anchors.fill: parent; anchors.margins: 12
                            Text { textFormat: Text.PlainText; text: backend.errorMessage || backend.notice; color: backend.errorMessage.length ? theme.danger : theme.text; font.pixelSize: 13; Layout.fillWidth: true; wrapMode: Text.WrapAnywhere; Accessible.role: Accessible.AlertMessage }
                            ActionButton { theme: window.theme; text: "Dismiss"; subtle: true; onClicked: backend.dismissMessage() }
                        }
                    }
                    Surface {
                        objectName: "headsetSummary"
                        visible: !window.showingAbout
                        theme: window.theme
                        Layout.fillWidth: true
                        padding: 20
                        contentItem: RowLayout {
                            spacing: 16
                            Rectangle { implicitWidth: 48; implicitHeight: 48; radius: 8; color: theme.accentSurface; LineIcon { anchors.centerIn: parent; width: 30; height: 30; kind: "headset"; strokeColor: theme.accentText } }
                            ColumnLayout {
                                spacing: 5
                                Layout.fillWidth: true
                                Text { textFormat: Text.PlainText; text: "INZONE H9 II"; color: theme.text; font.pixelSize: 16; font.weight: Font.DemiBold; Layout.fillWidth: true }
                                Text { textFormat: Text.PlainText; text: window.state.device_error ? "Headset status unavailable" : device.connected ? "Connected via USB transceiver" : "Headset disconnected"; color: theme.secondaryText; font.pixelSize: 12; Layout.fillWidth: true }
                            }
                            ColumnLayout {
                                spacing: 5
                                Text { textFormat: Text.PlainText; text: device.battery && device.battery.percent !== null && device.battery.percent !== undefined ? device.battery.percent + "% battery" : "Battery unavailable"; color: theme.text; font.pixelSize: 13; Layout.alignment: Qt.AlignRight }
                                Text { textFormat: Text.PlainText; text: "Active · " + window.profileName(window.state.active_profile); color: theme.accentText; font.pixelSize: 12; Layout.alignment: Qt.AlignRight }
                            }
                        }
                    }
                    Text { textFormat: Text.PlainText; text: window.state.device_error || ""; visible: text.length > 0 && currentPage < 3; Layout.fillWidth: true; color: theme.secondaryText; font.pixelSize: 12; wrapMode: Text.WordWrap }
                    Text { textFormat: Text.PlainText; text: window.state.audio_error || ""; visible: text.length > 0 && currentPage < 2; Layout.fillWidth: true; color: theme.danger; font.pixelSize: 12; wrapMode: Text.WordWrap }
                    Text { textFormat: Text.PlainText; text: window.state.profile_error || ""; visible: text.length > 0 && currentPage < 2; Layout.fillWidth: true; color: theme.danger; font.pixelSize: 12; wrapMode: Text.WordWrap }
                    SoundPage { app: window; Layout.fillWidth: true; visible: currentPage === 0 }
                    MicrophonePage { app: window; Layout.fillWidth: true; visible: currentPage === 1 }
                    HeadsetPage { app: window; Layout.fillWidth: true; visible: currentPage === 2 }
                    ApplicationsPage { app: window; Layout.fillWidth: true; visible: currentPage === 3 }
                    AboutPage { app: window; Layout.fillWidth: true; visible: window.showingAbout }
                    Item { Layout.preferredHeight: 16 + window.keyboardInset }
                }
            }
            Text { textFormat: Text.PlainText; text: window.showingAbout ? "INZONE Linux · Community-developed headset control" : backend.busy ? "Applying changes…" : "Changes are verified by the INZONE service."; color: theme.secondaryText; font.pixelSize: 11; Layout.leftMargin: window.pageMargin; Layout.topMargin: 12; Layout.bottomMargin: 12 }
        }
    }

    Item {
        id: dialogArea
        parent: Overlay.overlay
        width: parent ? parent.width : window.width
        height: window.usableDialogHeight
    }
    Dialog {
        id: profileDialog
        objectName: "profileDialog"
        property bool rename: false
        parent: dialogArea
        anchors.centerIn: parent
        width: Math.min(420, parent.width - 32)
        title: rename ? "Rename profile" : "Create profile"
        modal: true
        standardButtons: Dialog.Save | Dialog.Cancel
        onOpened: {
            standardButton(Dialog.Save).enabled = Qt.binding(function() { return profileNameField.text.trim().length > 0; });
            profileNameField.forceActiveFocus();
        }
        onAccepted: {
            Qt.inputMethod.commit();
            window.invoke(rename ? "RenameProfile" : "CreateProfile", rename ? window.selectedProfileId : profileNameField.text.trim(), rename ? profileNameField.text.trim() : window.selectedProfileId, 0);
        }
        ColumnLayout {
            anchors.fill: parent
            spacing: 12
            Label { textFormat: Text.PlainText; text: "Profile name" }
            TextField { id: profileNameField; objectName: "profileNameField"; Layout.fillWidth: true; maximumLength: 80; selectByMouse: true; Accessible.name: "Profile name"
                Keys.onReturnPressed: function(event) { event.accepted = inputMethodComposing; }
                Keys.onEnterPressed: function(event) { event.accepted = inputMethodComposing; } }
            Label { textFormat: Text.PlainText; visible: !profileDialog.rename; text: "Based on " + window.profileName(window.selectedProfileId); color: theme.secondaryText; wrapMode: Text.WordWrap; Layout.fillWidth: true }
        }
    }
    Dialog {
        id: deleteDialog
        objectName: "deleteProfileDialog"
        parent: dialogArea
        anchors.centerIn: parent
        width: Math.min(420, parent.width - 32)
        title: "Delete profile"
        modal: true
        standardButtons: Dialog.Yes | Dialog.Cancel
        onAccepted: window.invoke("DeleteProfile", selectedProfileId, "", 0)
        contentItem: Label { textFormat: Text.PlainText; text: "Delete “" + window.profileName(window.selectedProfileId) + "”? This removes its saved settings."; wrapMode: Text.WordWrap }
    }
    function confirmDeleteProfile() { deleteDialog.open(); }
}
