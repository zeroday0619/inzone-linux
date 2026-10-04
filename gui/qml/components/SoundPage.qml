import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts

ColumnLayout {
    id: page
    objectName: "soundPage"
    required property var app
    property var equalizerDraft: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    property bool equalizerDirty: false
    property bool equalizerSubmitting: false
    property bool presetSubmitting: false
    readonly property var frequencies: ["31.5", "63", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]
    readonly property var presetIds: Object.keys(app.state.presets || {})
    spacing: 16
    function loadEqualizer() {
        equalizerDraft = app.options.eq ? app.options.eq.slice() : [0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
        equalizerDirty = false;
    }
    function changeBand(index, value) {
        var next = equalizerDraft.slice();
        next[index] = Math.round(value);
        equalizerDraft = next;
        equalizerDirty = true;
    }
    Connections {
        target: page.app
        function onSelectedProfileIdChanged() { page.loadEqualizer(); }
        function onOptionsChanged() { if (!page.equalizerDirty && !page.equalizerSubmitting && !page.presetSubmitting) page.loadEqualizer(); }
    }
    Connections {
        target: page.app.backend
        function onBusyChanged() {
            if (page.app.backend.busy || (!page.equalizerSubmitting && !page.presetSubmitting)) return;
            if (page.app.backend.errorMessage.length === 0) page.loadEqualizer();
            page.equalizerSubmitting = false;
            page.presetSubmitting = false;
        }
    }
    Component.onCompleted: loadEqualizer()

    Surface {
        theme: page.app.theme
        Layout.fillWidth: true
        contentItem: ColumnLayout {
            spacing: 20
            SectionHeading { theme: page.app.theme; title: "Sound profile"; description: "Switch listening settings while your applications keep playing."; Layout.fillWidth: true }
            RowLayout {
                Layout.fillWidth: true
                spacing: 12
                ChoiceBox {
                    theme: page.app.theme
                    id: profilePicker
                    objectName: "profileSelector"
                    Layout.fillWidth: true
                    model: page.app.profiles
                    textRole: "name"
                    valueRole: "id"
                    currentIndex: page.app.profiles.findIndex(function(profile) { return profile.id === page.app.selectedProfileId; })
                    enabled: page.app.canChange && count > 0
                    Accessible.name: "Sound profile"
                    onActivated: page.app.selectedProfileId = currentValue
                }
                ActionButton { theme: page.app.theme; objectName: "applyProfileButton"; text: "Apply profile"; primary: true; enabled: page.app.canChange && page.app.selectedProfile !== null; onClicked: page.app.invoke("ActivateProfile", page.app.selectedProfileId, "", 0) }
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                Text { textFormat: Text.PlainText; text: page.app.selectedProfile ? (page.app.selectedProfile.built_in ? "Built-in profile" : "Custom profile") : "No profiles available"; color: page.app.theme.secondaryText; font.pixelSize: 12; Layout.fillWidth: true }
                ActionButton { theme: page.app.theme; text: "Create profile"; subtle: true; enabled: page.app.canChange && page.app.selectedProfile !== null; onClicked: page.app.openProfileDialog(false) }
                ActionButton { theme: page.app.theme; text: "Rename"; subtle: true; enabled: page.app.canChange && page.app.selectedProfile !== null && !page.app.selectedProfile.built_in; onClicked: page.app.openProfileDialog(true) }
                ActionButton { theme: page.app.theme; text: "Delete"; subtle: true; destructive: true; enabled: page.app.canChange && page.app.selectedProfile !== null && !page.app.selectedProfile.built_in; onClicked: page.app.confirmDeleteProfile() }
            }
        }
    }

    Surface {
        theme: page.app.theme
        objectName: "equalizerPanel"
        visible: page.app.selectedProfile !== null
        Layout.fillWidth: true
        contentItem: ColumnLayout {
            spacing: 20
            RowLayout {
                Layout.fillWidth: true
                SectionHeading { theme: page.app.theme; title: "Equalizer"; description: "Ten bands. Fine-tune the details."; Layout.fillWidth: true }
                VerifiedSwitch { backend: page.app.backend; text: "Enabled"; reportedChecked: page.app.options.eq_enable === true; enabled: page.app.canChange && page.app.selectedProfile !== null; Accessible.name: "Enable equalizer"; onToggled: page.app.changeOption("eq_enable", checked) }
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: 12
                ChoiceBox {
                    theme: page.app.theme
                    id: presetPicker
                    Layout.fillWidth: true
                    model: page.presetIds.map(function(identifier) { return page.app.state.presets[identifier]; })
                    enabled: page.app.canChange && count > 0
                    Accessible.name: "Sony sound preset"
                }
                ActionButton { theme: page.app.theme; text: "Use Sony preset"; enabled: page.app.canChange && page.app.selectedProfile !== null && presetPicker.currentIndex >= 0; onClicked: { page.presetSubmitting = true; page.app.invoke("ApplyPreset", page.app.selectedProfileId, page.presetIds[presetPicker.currentIndex], 0); } }
            }
            Rectangle {
                Layout.fillWidth: true
                implicitHeight: 216
                radius: 6
                color: page.app.theme.background
                RowLayout {
                    anchors.fill: parent
                    anchors.margins: 12
                    spacing: 4
                    ColumnLayout {
                        Layout.preferredWidth: 28
                        Layout.fillHeight: true
                        Text { textFormat: Text.PlainText; text: "+12"; color: page.app.theme.secondaryText; font.pixelSize: 10; Layout.topMargin: 30 }
                        Item { Layout.fillHeight: true }
                        Text { textFormat: Text.PlainText; text: "0"; color: page.app.theme.secondaryText; font.pixelSize: 10 }
                        Item { Layout.fillHeight: true }
                        Text { textFormat: Text.PlainText; text: "−12"; color: page.app.theme.secondaryText; font.pixelSize: 10; Layout.bottomMargin: 28 }
                    }
                    Repeater {
                        model: page.frequencies
                        delegate: ColumnLayout {
                            required property int index
                            required property string modelData
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            spacing: 6
                            Text { textFormat: Text.PlainText; text: (page.equalizerDraft[index] > 0 ? "+" : "") + page.equalizerDraft[index]; color: page.app.theme.accentText; font.pixelSize: 12; font.weight: Font.DemiBold; Layout.alignment: Qt.AlignHCenter }
                            Slider {
                                objectName: "equalizerBand" + index
                                orientation: Qt.Vertical
                                Layout.fillHeight: true
                                Layout.alignment: Qt.AlignHCenter
                                from: -12; to: 12; stepSize: 1
                                value: page.equalizerDraft[index]
                                enabled: page.app.canChange && page.app.selectedProfile !== null
                                Accessible.name: modelData + " Hz equalizer gain in decibels"
                                onMoved: page.changeBand(index, value)
                            }
                            Text { textFormat: Text.PlainText; text: modelData; color: page.app.theme.secondaryText; font.pixelSize: 11; Layout.alignment: Qt.AlignHCenter }
                        }
                    }
                }
            }
            RowLayout {
                Layout.fillWidth: true
                Text { textFormat: Text.PlainText; text: page.equalizerDirty ? "Unsaved equalizer changes" : "Frequency (Hz) · Gain (dB)"; color: page.app.theme.secondaryText; font.pixelSize: 12; Layout.fillWidth: true }
                ActionButton { theme: page.app.theme; objectName: "equalizerDiscardButton"; text: "Discard"; subtle: true; visible: page.equalizerDirty; enabled: page.app.canChange; onClicked: page.loadEqualizer() }
                ActionButton { theme: page.app.theme; text: "Reset bands"; subtle: true; enabled: page.app.canChange && page.app.selectedProfile !== null; onClicked: { page.equalizerDraft = [0,0,0,0,0,0,0,0,0,0]; page.equalizerDirty = true; } }
                ActionButton { theme: page.app.theme; objectName: "equalizerApplyButton"; text: "Apply equalizer"; primary: true; enabled: page.app.canChange && page.equalizerDirty; onClicked: { page.equalizerSubmitting = true; page.app.invoke("SetProfileOptions", page.app.selectedProfileId, JSON.stringify({eq: page.equalizerDraft, eq_enable: true}), 0); } }
            }
        }
    }

    Surface {
        theme: page.app.theme
        visible: page.app.selectedProfile !== null
        Layout.fillWidth: true
        contentItem: ColumnLayout {
            spacing: 20
            SectionHeading { theme: page.app.theme; title: "Sound processing"; description: "Settings for " + page.app.profileName(page.app.selectedProfileId); Layout.fillWidth: true }
            SettingRow {
                theme: page.app.theme; title: "Dynamic range compression"; description: "Reduce the difference between quiet and loud sounds."; Layout.fillWidth: true
                VerifiedChoiceBox {
                    backend: page.app.backend; theme: page.app.theme; model: ["Off", "Low", "High"]; reportedIndex: page.app.options.drc === undefined ? -1 : page.app.options.drc; enabled: page.app.canChange && page.app.selectedProfile !== null; Accessible.name: "Dynamic range compression"; onActivated: page.app.changeOption("drc", currentIndex); Layout.preferredWidth: 160 }
            }
            SettingRow {
                theme: page.app.theme; title: "Automatic output level"; description: "Keep playback loudness more consistent."; Layout.fillWidth: true
                VerifiedSwitch { backend: page.app.backend; reportedChecked: page.app.options.output_alc === true; enabled: page.app.canChange && page.app.selectedProfile !== null; Accessible.name: "Automatic output level"; onToggled: page.app.changeOption("output_alc", checked) }
            }
            SettingRow {
                theme: page.app.theme; title: "Sound mode"; Layout.fillWidth: true
                VerifiedChoiceBox {
                    backend: page.app.backend; theme: page.app.theme; model: ["Standard", "Immersive"]; reportedIndex: page.app.options.sound_mode === "immersive" ? 1 : 0; enabled: page.app.canChange && page.app.selectedProfile !== null; Accessible.name: "Sound mode"; onActivated: page.app.changeOption("sound_mode", currentIndex === 1 ? "immersive" : "standard"); Layout.preferredWidth: 160 }
            }
            SettingRow {
                theme: page.app.theme; title: "Base equalization"; description: "Apply the profile’s underlying frequency response."; Layout.fillWidth: true
                VerifiedSwitch { backend: page.app.backend; reportedChecked: page.app.options.base_eq === true; enabled: page.app.canChange && page.app.selectedProfile !== null; Accessible.name: "Base equalization"; onToggled: page.app.changeOption("base_eq", checked) }
            }
            SettingRow {
                theme: page.app.theme; title: "Spatial audio response"; description: "Personalized requires a previously imported HRTF."; Layout.fillWidth: true
                VerifiedChoiceBox {
                    backend: page.app.backend; theme: page.app.theme; model: ["Standard", "Personalized"]; reportedIndex: page.app.options.hrtf === "personal" ? 1 : 0; enabled: page.app.canChange && page.app.selectedProfile !== null; Accessible.name: "Spatial audio response"; onActivated: page.app.changeOption("hrtf", currentIndex === 1 ? "personal" : "standard"); Layout.preferredWidth: 160 }
            }
        }
    }
    Surface {
        theme: page.app.theme
        Layout.fillWidth: true
        contentItem: ColumnLayout {
            spacing: 20
            SectionHeading { theme: page.app.theme; title: "Output volume"; description: "Adjust the Game and Chat playback channels."; Layout.fillWidth: true }
            HostVolume { app: page.app; title: "Game"; field: "game_volume"; Layout.fillWidth: true }
            HostVolume { app: page.app; title: "Chat"; field: "chat_volume"; Layout.fillWidth: true }
            Repeater { model: page.app.fields(["game_chat", "headphone_volume"]); delegate: DeviceField { required property var modelData; app: page.app; field: modelData; Layout.fillWidth: true } }
        }
    }
}
