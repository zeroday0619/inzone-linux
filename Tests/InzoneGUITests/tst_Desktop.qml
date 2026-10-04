import QtQuick
import QtQuick.Window
import QtQuick.Controls.Basic
import QtTest
import "../../gui/qml" as Gui

TestCase {
    id: testCase
    name: "InzoneDesktop"
    property var desktop: null

    QtObject {
        id: mockBackend
        property string stateJSON: "{}"
        property bool connected: true
        property bool busy: false
        property bool refreshing: false
        property string errorMessage: ""
        property string notice: ""
        property var calls: []
        function refresh() {}
        function poll() {}
        function dismissMessage() { errorMessage = ""; notice = ""; }
        function invoke(method, first, second, value) {
            calls = calls.concat([{method: method, first: first, second: second, value: value}]);
            errorMessage = "";
            busy = true;
        }
    }
    Component { id: desktopComponent; Gui.Main { backend: mockBackend } }

    function fixture() {
        function options() {
            return {eq: [0,0,0,0,0,0,0,0,0,0], eq_enable: false, drc: 0,
                    output_alc: false, mic_agc: false, hrtf: "standard",
                    sound_mode: "standard", base_eq: true};
        }
        return {version: 1, active_profile: "balanced",
                profiles: [{id: "balanced", name: "Balanced", built_in: true, options: options()},
                           {id: "music", name: "Music", built_in: true, options: options()}],
                device: {connected: true, fields: {anc: 0, ambient_level: 4, voice_focus: 0}},
                device_fields: [{name: "anc", label: "Noise control", values: [0,1,2], labels: ["Off","Noise cancelling","Ambient sound"]},
                                {name: "ambient_level", label: "Ambient level", values: [1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20], labels: []},
                                {name: "voice_focus", label: "Voice focus", values: [0,1], labels: ["Off","On"]}],
                host_levels: {game_volume: 60, chat_volume: 50, mic_volume: 70, mic_mute: false},
                presets: {flat: "Flat"}, automation: {enabled: false, rules: []}};
    }
    function init() {
        mockBackend.busy = false;
        mockBackend.refreshing = false;
        mockBackend.connected = true;
        mockBackend.errorMessage = "";
        mockBackend.notice = "";
        mockBackend.calls = [];
        mockBackend.stateJSON = JSON.stringify(fixture());
        desktop = desktopComponent.createObject(null);
        verify(desktop !== null);
        desktop.requestActivate();
        tryCompare(desktop, "active", true);
        verify(waitForRendering(desktop.contentItem));
    }
    function cleanup() {
        desktop.close();
        desktop.destroy();
        desktop = null;
        wait(0);
    }
    function control(name) {
        var result = findChild(desktop, name);
        verify(result !== null, "Missing control: " + name);
        return result;
    }
    function revealControl(item) {
        item.forceActiveFocus();
        tryCompare(item, "activeFocus", true);
        var viewport = control("contentScroll").contentItem;
        tryVerify(function() {
            var position = item.mapToItem(viewport, 0, 0);
            return position.y >= 0 && position.y + item.height <= viewport.height;
        });
    }
    function test_initialStateDoesNotMutate() {
        compare(desktop.selectedProfileId, "balanced");
        compare(control("profileSelector").currentIndex, 0);
        compare(mockBackend.calls.length, 0);
        mockBackend.stateJSON = JSON.stringify(fixture());
        wait(30);
        compare(mockBackend.calls.length, 0);
    }
    function test_profileSelectionRequiresApply() {
        var selector = control("profileSelector");
        selector.currentIndex = 1;
        selector.activated(1);
        compare(desktop.selectedProfileId, "music");
        compare(mockBackend.calls.length, 0);
        control("applyProfileButton").clicked();
        compare(mockBackend.calls.length, 1);
        compare(mockBackend.calls[0].method, "ActivateProfile");
        compare(mockBackend.calls[0].first, "music");
    }
    function test_failedEqualizerApplyPreservesDraft() {
        var page = control("soundPage");
        page.changeBand(0, 7);
        control("equalizerApplyButton").clicked();
        compare(mockBackend.calls[0].method, "SetProfileOptions");
        compare(JSON.parse(mockBackend.calls[0].second).eq[0], 7);
        verify(page.equalizerDirty);
        mockBackend.errorMessage = "The audio graph rejected this change.";
        mockBackend.busy = false;
        mockBackend.stateJSON = JSON.stringify(fixture());
        wait(30);
        verify(page.equalizerDirty);
        compare(page.equalizerDraft[0], 7);
        verify(!page.equalizerSubmitting);
    }
    function test_successfulEqualizerApplyUsesAcknowledgedState() {
        var page = control("soundPage");
        page.changeBand(2, -4);
        control("equalizerApplyButton").clicked();
        var state = fixture();
        state.profiles[0].options.eq[2] = -4;
        state.profiles[0].options.eq_enable = true;
        mockBackend.stateJSON = JSON.stringify(state);
        mockBackend.busy = false;
        wait(30);
        verify(!page.equalizerDirty);
        compare(page.equalizerDraft[2], -4);
    }
    function test_backgroundRefreshPreservesDraft() {
        var page = control("soundPage");
        page.changeBand(9, 3);
        mockBackend.refreshing = true;
        var state = fixture();
        state.host_levels.mic_volume = 30;
        mockBackend.stateJSON = JSON.stringify(state);
        mockBackend.refreshing = false;
        wait(30);
        verify(page.equalizerDirty);
        compare(page.equalizerDraft[9], 3);
        verify(control("equalizerApplyButton").enabled);
        compare(mockBackend.calls.length, 0);
        control("equalizerDiscardButton").clicked();
        verify(!page.equalizerDirty);
        compare(page.equalizerDraft[9], 0);
    }
    function test_busyDisablesMutations() {
        mockBackend.busy = true;
        verify(!control("applyProfileButton").enabled);
        verify(!control("profileSelector").enabled);
        desktop.invoke("ActivateProfile", "music", "", 0);
        compare(mockBackend.calls.length, 0);
    }
    function test_unknownDisconnectedState() {
        mockBackend.connected = false;
        mockBackend.stateJSON = "{}";
        wait(30);
        compare(desktop.selectedProfile, null);
        verify(!control("equalizerPanel").visible);
        verify(!control("applyProfileButton").enabled);
        desktop.invoke("SetHostField", "mic_volume", "", 50);
        compare(mockBackend.calls.length, 0);
    }
    function test_keyboardFocusScrollsIntoView() {
        desktop.height = 680;
        var volume = control("hostVolume_game_volume");
        var scroll = control("contentScroll");
        volume.forceActiveFocus(Qt.TabFocusReason);
        wait(50);
        var position = volume.mapToItem(scroll.contentItem, 0, 0);
        verify(position.y >= 0 && position.y + volume.height <= scroll.height,
               "Keyboard-focused volume control must remain inside the viewport.");
        compare(mockBackend.calls.length, 0);
    }
    function test_deleteDialogHasKeyboardFocus() {
        desktop.confirmDeleteProfile();
        wait(30);
        tryCompare(control("deleteProfileDialog"), "activeFocus", true);
        keyClick(Qt.Key_Escape);
        tryVerify(function() { return !control("deleteProfileDialog").visible; });
        compare(mockBackend.calls.length, 0);
    }
    function test_compactViewportKeepsFieldsAccessible() {
        desktop.showNormal();
        tryCompare(desktop, "visibility", Window.Windowed);
        verify(waitForRendering(desktop.contentItem));
        desktop.width = 640;
        desktop.height = 360;
        tryCompare(desktop, "width", 640);
        tryCompare(desktop, "height", 360);
        desktop.currentPage = 3;
        wait(50);
        verify(desktop.compactNavigation);
        var scroll = control("contentScroll");
        var fields = ["applicationNameInput", "applicationProfileSelector", "applicationPriorityInput"];
        for (var index = 0; index < fields.length; index++) {
            var field = control(fields[index]);
            field.forceActiveFocus(Qt.TabFocusReason);
            wait(30);
            var position = field.mapToItem(scroll.contentItem, 0, 0);
            verify(position.x >= 0 && position.x + field.width <= scroll.width,
                   fields[index] + " must fit the logical viewport width.");
            verify(position.y >= 0 && position.y + field.height <= scroll.height,
                   fields[index] + " must remain visible when focused.");
        }
        desktop.currentPage = 0;
        control("soundPage").changeBand(0, 1);
        var apply = control("equalizerApplyButton");
        apply.forceActiveFocus(Qt.TabFocusReason);
        tryVerify(function() {
            var position = apply.mapToItem(scroll.contentItem, 0, 0);
            return position.x + apply.width <= scroll.width
                && position.y >= 0 && position.y + apply.height <= scroll.height;
        }, 5000, "Equalizer actions must fit the logical viewport after navigation and focus settle.");
        compare(mockBackend.calls.length, 0);
    }
    function test_unicodeProfileNameRemainsLiteral() {
        desktop.openProfileDialog(false);
        control("profileNameField").text = "마이크 프로필 日本語";
        control("profileDialog").accept();
        compare(mockBackend.calls[0].first, "마이크 프로필 日本語");
    }
    function test_profileDialogFitsCompactResize() {
        desktop.openProfileDialog(false);
        desktop.showNormal();
        tryCompare(desktop, "visibility", Window.Windowed);
        verify(waitForRendering(desktop.contentItem));
        desktop.width = 640;
        desktop.height = 360;
        tryCompare(desktop, "width", 640);
        tryCompare(desktop, "height", 360);
        wait(50);
        var dialog = control("profileDialog");
        verify(dialog.x >= 0 && dialog.y >= 0);
        verify(dialog.x + dialog.width <= desktop.width);
        verify(dialog.y + dialog.height <= desktop.height);
        compare(mockBackend.calls.length, 0);
    }
    function test_ambientControlsRequireAmbientMode() {
        desktop.currentPage = 2;
        wait(30);
        var noiseControl = control("noiseControlFields").itemAt(0);
        verify(!findChild(noiseControl, "deviceToggle").visible);
        verify(findChild(noiseControl, "deviceChoice").visible);
        verify(!findChild(noiseControl, "deviceSlider").visible);
        var ambient = control("noiseControlFields").itemAt(1);
        verify(!findChild(ambient, "deviceToggle").visible);
        verify(!findChild(ambient, "deviceChoice").visible);
        verify(findChild(ambient, "deviceSlider").visible);
        var focus = control("noiseControlFields").itemAt(2);
        verify(findChild(focus, "deviceToggle").visible);
        verify(!findChild(focus, "deviceChoice").visible);
        verify(!findChild(focus, "deviceSlider").visible);
        verify(!control("noiseControlFields").itemAt(1).enabled);
        var state = fixture();
        state.device.fields.anc = 2;
        mockBackend.stateJSON = JSON.stringify(state);
        wait(30);
        verify(control("noiseControlFields").itemAt(1).enabled);
        compare(mockBackend.calls.length, 0);
    }
    function test_profileCreationRequiresConfirmation() {
        desktop.openProfileDialog(false);
        var dialog = control("profileDialog");
        var name = control("profileNameField");
        verify(dialog.visible);
        tryCompare(name, "activeFocus", true);
        verify(!dialog.standardButton(Dialog.Save).enabled);
        compare(mockBackend.calls.length, 0);
        name.text = "Studio";
        verify(dialog.standardButton(Dialog.Save).enabled);
        dialog.accept();
        compare(mockBackend.calls.length, 1);
        compare(mockBackend.calls[0].method, "CreateProfile");
        compare(mockBackend.calls[0].first, "Studio");
        compare(mockBackend.calls[0].second, "balanced");
    }
    function test_failedMicrophoneGainRestoresReportedState() {
        desktop.currentPage = 1;
        wait(50);
        var gain = control("microphoneGainSwitch");
        verify(!gain.checked);
        revealControl(gain);
        mouseClick(gain);
        compare(mockBackend.calls.length, 1);
        verify(gain.checked);
        mockBackend.errorMessage = "Microphone gain could not be applied.";
        mockBackend.busy = false;
        wait(30);
        verify(!gain.checked);
    }
    function test_failedNoiseControlRestoresReportedState() {
        desktop.currentPage = 2;
        wait(30);
        var field = control("noiseControlFields").itemAt(0);
        var choice = findChild(field, "deviceChoice");
        choice.currentIndex = 2;
        choice.activated(2);
        compare(mockBackend.calls[0].method, "SetDeviceField");
        compare(mockBackend.calls[0].value, 2);
        mockBackend.errorMessage = "Headset did not acknowledge noise control.";
        mockBackend.busy = false;
        compare(choice.currentIndex, 0);
    }
    function test_failedMicrophoneVolumeRestoresReportedState() {
        desktop.currentPage = 1;
        wait(50);
        var volume = control("hostVolume_mic_volume");
        compare(volume.value, 70);
        revealControl(volume);
        mouseClick(volume, volume.width * 0.4, volume.height / 2);
        tryCompare(mockBackend, "busy", true);
        compare(mockBackend.calls[0].method, "SetHostField");
        compare(mockBackend.calls[0].first, "mic_volume");
        verify(volume.value !== 70);
        mockBackend.errorMessage = "Microphone volume could not be applied.";
        mockBackend.busy = false;
        compare(volume.value, 70);
    }
    function test_profileDialogKeyboardCancel() {
        desktop.openProfileDialog(false);
        var dialog = control("profileDialog");
        tryCompare(control("profileNameField"), "activeFocus", true);
        keyClick(Qt.Key_Escape);
        tryVerify(function() { return !dialog.visible; });
        compare(mockBackend.calls.length, 0);
    }
    function test_renameAndDeleteUseProfileIdentifier() {
        var state = fixture();
        state.profiles.push({id: "custom-studio", name: "Studio", built_in: false, options: state.profiles[0].options});
        mockBackend.stateJSON = JSON.stringify(state);
        desktop.selectedProfileId = "custom-studio";
        desktop.openProfileDialog(true);
        compare(control("profileNameField").text, "Studio");
        control("profileNameField").text = "Recording";
        control("profileDialog").accept();
        compare(mockBackend.calls[0].method, "RenameProfile");
        compare(mockBackend.calls[0].first, "custom-studio");
        compare(mockBackend.calls[0].second, "Recording");
        mockBackend.busy = false;
        desktop.confirmDeleteProfile();
        var dialog = control("deleteProfileDialog");
        verify(dialog.visible);
        compare(mockBackend.calls.length, 1);
        dialog.accept();
        compare(mockBackend.calls[1].method, "DeleteProfile");
        compare(mockBackend.calls[1].first, "custom-studio");
    }
}
