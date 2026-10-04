import QtQuick
import QtQuick.Controls.Basic

Switch {
    id: control
    required property QtObject backend
    property bool reportedChecked: false
    checked: reportedChecked
    Connections {
        target: control.backend
        function onBusyChanged() {
            if (!control.backend.busy) {
                control.checked = Qt.binding(function() { return control.reportedChecked; });
            }
        }
    }
}
