import QtQuick

Canvas {
    id: icon
    property string kind: "sound"
    property color strokeColor: "#242424"
    implicitWidth: 22
    implicitHeight: 22
    onKindChanged: requestPaint()
    onStrokeColorChanged: requestPaint()
    onPaint: {
        var context = getContext("2d");
        context.reset();
        context.scale(width / 24, height / 24);
        context.strokeStyle = strokeColor;
        context.lineWidth = 1.65;
        context.lineCap = "round";
        context.lineJoin = "round";
        context.beginPath();
        if (kind === "sound") {
            context.moveTo(3, 9); context.lineTo(7, 9); context.lineTo(12, 5); context.lineTo(12, 19); context.lineTo(7, 15); context.lineTo(3, 15); context.closePath();
            context.moveTo(16, 8); context.quadraticCurveTo(20, 12, 16, 16);
            context.moveTo(18.5, 5); context.quadraticCurveTo(25, 12, 18.5, 19);
        } else if (kind === "microphone") {
            context.roundedRect(9, 3, 6, 12, 3, 3);
            context.moveTo(6, 11); context.lineTo(6, 12); context.arc(12, 12, 6, Math.PI, 0, true);
            context.moveTo(12, 18); context.lineTo(12, 22); context.moveTo(8, 22); context.lineTo(16, 22);
        } else if (kind === "headset") {
            context.moveTo(4, 13); context.lineTo(4, 11); context.arc(12, 11, 8, Math.PI, 0, false); context.lineTo(20, 17);
            context.roundedRect(3, 12, 5, 8, 2, 2); context.roundedRect(16, 12, 5, 8, 2, 2);
        } else if (kind === "info") {
            context.arc(12, 12, 9, 0, Math.PI * 2);
            context.moveTo(12, 10.5); context.lineTo(12, 17);
            context.moveTo(12, 7); context.lineTo(12, 7.2);
        } else if (kind === "apps") {
            context.roundedRect(3, 3, 7, 7, 1.5, 1.5); context.roundedRect(14, 3, 7, 7, 1.5, 1.5);
            context.roundedRect(3, 14, 7, 7, 1.5, 1.5); context.roundedRect(14, 14, 7, 7, 1.5, 1.5);
        }
        context.stroke();
    }
}
