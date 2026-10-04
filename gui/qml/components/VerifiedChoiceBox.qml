import QtQuick

ChoiceBox {
    id: control
    required property QtObject backend
    property int reportedIndex: -1
    currentIndex: reportedIndex
    Connections {
        target: control.backend
        function onBusyChanged() {
            if (!control.backend.busy) {
                control.currentIndex = Qt.binding(function() { return control.reportedIndex; });
            }
        }
    }
}
