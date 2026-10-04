import QtQuick
import QtQuick.Controls.Basic

Button {
    id: control
    required property QtObject theme
    property bool primary: false
    property bool subtle: false
    property bool destructive: false
    implicitHeight: 36
    implicitWidth: Math.max(80, contentItem.implicitWidth + 28)
    leftPadding: 14
    rightPadding: 14
    focusPolicy: Qt.StrongFocus
    Accessible.name: text
    contentItem: Text { textFormat: Text.PlainText;
        text: control.text
        font: control.font
        color: !control.enabled ? theme.disabledText : control.primary ? "#ffffff" : control.destructive ? theme.danger : theme.text
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideRight
    }
    background: Rectangle {
        radius: 4
        color: !control.enabled ? theme.disabledSurface : control.primary ? (control.down ? theme.accentPressed : control.hovered ? theme.accentHover : theme.accent) : control.down ? theme.pressed : control.hovered ? theme.hover : control.subtle ? "transparent" : theme.surface
        border.color: control.visualFocus ? theme.focus : control.primary || control.subtle ? "transparent" : theme.controlBorder
        border.width: control.visualFocus ? 2 : 1
    }
}
