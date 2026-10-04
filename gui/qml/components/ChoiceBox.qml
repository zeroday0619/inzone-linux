import QtQuick
import QtQuick.Controls.Basic

ComboBox {
    id: control
    required property QtObject theme
    implicitHeight: 36
    leftPadding: 12
    rightPadding: 32
    background: Rectangle {
        radius: 4
        color: control.enabled ? control.down ? theme.pressed : control.hovered ? theme.hover : theme.surface : theme.disabledSurface
        border.color: control.visualFocus ? theme.focus : theme.controlBorder
        border.width: control.visualFocus ? 2 : 1
    }
    contentItem: Text { textFormat: Text.PlainText;
        text: control.displayText
        font: control.font
        color: control.enabled ? theme.text : theme.disabledText
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideRight
    }
    delegate: ItemDelegate {
        required property int index
        width: control.width
        text: control.textAt(index)
        highlighted: control.highlightedIndex === index
        contentItem: Text { textFormat: Text.PlainText;
            text: parent.text
            font: control.font
            color: theme.text
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
        }
    }
    indicator: Canvas {
        x: control.width - width - 12
        y: (control.height - height) / 2
        width: 10; height: 6
        property color strokeColor: control.enabled ? theme.text : theme.disabledText
        onStrokeColorChanged: requestPaint()
        onPaint: {
            var context = getContext("2d");
            context.reset(); context.strokeStyle = strokeColor; context.lineWidth = 1.5;
            context.beginPath(); context.moveTo(1, 1); context.lineTo(5, 5); context.lineTo(9, 1); context.stroke();
        }
    }
}
