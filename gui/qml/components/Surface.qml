import QtQuick
import QtQuick.Controls.Basic

Pane {
    required property QtObject theme
    padding: 24
    background: Rectangle {
        color: theme.surface
        radius: 8
        border.color: theme.border
        border.width: 1
    }
}
