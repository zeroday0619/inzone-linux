import QtQuick
import QtQuick.Layouts

ColumnLayout {
    required property QtObject theme
    property string title
    property string description
    spacing: 4
    Text { textFormat: Text.PlainText; text: title; color: theme.text; font.pixelSize: 18; font.weight: Font.DemiBold; Layout.fillWidth: true }
    Text { textFormat: Text.PlainText; text: description; visible: text.length > 0; color: theme.secondaryText; font.pixelSize: 13; wrapMode: Text.WordWrap; Layout.fillWidth: true }
}
