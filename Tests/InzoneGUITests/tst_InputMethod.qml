import QtQuick
import QtQuick.Controls.Basic
import QtTest
import "../../gui/qml" as Gui

TestCase {
    id: testCase
    name: "InzoneInputMethod"
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
        function dismissMessage() {}
        function invoke(method, first, second, value) {
            calls = calls.concat([{method: method, first: first, second: second, value: value}]);
        }
    }
    Component { id: desktopComponent; Gui.Main { backend: mockBackend } }

    function initTestCase() {
        verify(typeof inputMethodProbe !== "undefined", "Run these tests with the INZONE QuickTest input-method setup.");
    }

    function init() {
        mockBackend.calls = [];
        mockBackend.stateJSON = JSON.stringify({
            version: 1, active_profile: "balanced",
            profiles: [{id: "balanced", name: "Balanced", built_in: true,
                        options: {eq: [0,0,0,0,0,0,0,0,0,0], eq_enable: false, drc: 0,
                                  output_alc: false, mic_agc: false, hrtf: "standard",
                                  sound_mode: "standard", base_eq: true}}],
            device: {connected: false}, device_fields: [], host_levels: {}, presets: {},
            automation: {enabled: false, rules: []}
        });
        desktop = desktopComponent.createObject(null);
        verify(desktop !== null);
        desktop.requestActivate();
        desktop.openProfileDialog(false);
        tryVerify(function() { return inputMethodProbe.focusObjectName() === "profileNameField"; });
    }

    function cleanup() {
        if (desktop) {
            if (inputMethodProbe.focusObjectName() === "profileNameField")
                inputMethodProbe.preedit("");
            desktop.close();
            desktop.destroy();
            desktop = null;
            wait(0);
        }
    }

    function control(name) {
        var item = findChild(desktop, name);
        verify(item !== null, "Missing control: " + name);
        return item;
    }

    function test_koreanCompositionDoesNotSubmit_data() {
        return [{tag: "Return", key: Qt.Key_Return}, {tag: "Enter", key: Qt.Key_Enter}];
    }

    function test_koreanCompositionDoesNotSubmit(data) {
        var field = control("profileNameField");
        var dialog = control("profileDialog");
        verify(inputMethodProbe.commit("테스트 "));
        verify(dialog.standardButton(Dialog.Save).enabled);
        verify(inputMethodProbe.preedit("ㅎ"));
        compare(field.preeditText, "ㅎ");
        verify(field.inputMethodComposing);
        compare(field.text, "테스트 ");
        verify(inputMethodProbe.preedit("한"));
        compare(field.preeditText, "한");
        keyClick(data.key);
        verify(dialog.visible, "Confirming a composition must not close the profile dialog.");
        compare(mockBackend.calls.length, 0);
        verify(inputMethodProbe.commit("한국어 프로파일"));
        compare(field.text, "테스트 한국어 프로파일");
        compare(field.preeditText, "");
        verify(!field.inputMethodComposing);
        compare(mockBackend.calls.length, 0);
        dialog.standardButton(Dialog.Save).clicked();
        compare(mockBackend.calls.length, 1);
        compare(mockBackend.calls[0].method, "CreateProfile");
        compare(mockBackend.calls[0].first, "테스트 한국어 프로파일");
        compare(mockBackend.calls[0].second, "balanced");
    }

    function test_cancelledCompositionDoesNotChangeSavedText() {
        var field = control("profileNameField");
        field.text = "기존 이름";
        field.cursorPosition = field.text.length;
        verify(inputMethodProbe.preedit(" 변경"));
        verify(field.inputMethodComposing);
        verify(inputMethodProbe.preedit(""));
        verify(!field.inputMethodComposing);
        compare(field.text, "기존 이름");
        compare(mockBackend.calls.length, 0);
        control("profileDialog").reject();
        compare(mockBackend.calls.length, 0);
    }
}
