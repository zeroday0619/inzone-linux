import QtQuick
import QtQuick.Layouts

RowLayout {
    id: row
    required property QtObject theme
    property string title
    property string description
    default property alias controls: controlLayout.data
    spacing: 24
    implicitHeight: Math.max(48, labelLayout.implicitHeight)
    ColumnLayout {
        id: labelLayout
        Layout.fillWidth: true
        spacing: 4
        Text { textFormat: Text.PlainText; text: row.title; color: theme.text; font.pixelSize: 14; Layout.fillWidth: true; wrapMode: Text.WordWrap }
        Text { textFormat: Text.PlainText; text: row.description; visible: text.length > 0; color: theme.secondaryText; font.pixelSize: 12; Layout.fillWidth: true; wrapMode: Text.WordWrap }
    }
    RowLayout { id: controlLayout; spacing: 8 }
}
