#include "InzoneGuiRuntime.h"

#include <QCoreApplication>
#include <QDir>
#include <QFileInfo>
#include <QFile>
#include <QGuiApplication>
#include <QIcon>
#include <QImage>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QQuickWindow>
#include <QResource>
#include <QSaveFile>
#include <QScreen>
#include <QSGRendererInterface>
#include <QString>
#include <QTimer>
#include <QWindow>
#include <cstdio>
#include <cstdlib>

static void initializeResources()
{
    Q_INIT_RESOURCE(inzone_icons);
}

namespace {
bool smokeTest = false;
bool nativeWaylandRequired = false;
QString screenshotPath;
QString diagnosticsPath;
QString platformSelection;

[[noreturn]] void fail(const QString &message)
{
    std::fprintf(stderr, "%s\n", message.toLocal8Bit().constData());
    std::exit(EXIT_FAILURE);
}

QString renderingBackend(QQuickWindow *window)
{
    switch (window->rendererInterface()->graphicsApi()) {
    case QSGRendererInterface::Software: return QStringLiteral("software");
    case QSGRendererInterface::OpenVG: return QStringLiteral("openvg");
    case QSGRendererInterface::OpenGL: return QStringLiteral("opengl");
    case QSGRendererInterface::Direct3D11: return QStringLiteral("direct3d11");
    case QSGRendererInterface::Vulkan: return QStringLiteral("vulkan");
    case QSGRendererInterface::Metal: return QStringLiteral("metal");
    case QSGRendererInterface::Null: return QStringLiteral("null");
    case QSGRendererInterface::Direct3D12: return QStringLiteral("direct3d12");
    default: return QStringLiteral("unknown");
    }
}

void writeDiagnostics(QQuickWindow *window)
{
    QJsonArray screens;
    for (QScreen *screen : QGuiApplication::screens()) {
        screens.append(QJsonObject{
            {QStringLiteral("name"), screen->name()},
            {QStringLiteral("width"), screen->geometry().width()},
            {QStringLiteral("height"), screen->geometry().height()},
            {QStringLiteral("devicePixelRatio"), screen->devicePixelRatio()},
            {QStringLiteral("logicalDotsPerInch"), screen->logicalDotsPerInch()},
        });
    }
    const QJsonObject diagnostics{
        {QStringLiteral("version"), 1},
        {QStringLiteral("qtVersion"), QString::fromLatin1(qVersion())},
        {QStringLiteral("platformName"), QGuiApplication::platformName()},
        {QStringLiteral("platformSelection"), platformSelection},
        {QStringLiteral("nativeWayland"), QGuiApplication::platformName().startsWith(QStringLiteral("wayland"))},
        {QStringLiteral("desktopFileName"), QGuiApplication::desktopFileName()},
        {QStringLiteral("applicationName"), QCoreApplication::applicationName()},
        {QStringLiteral("applicationVersion"), QCoreApplication::applicationVersion()},
        {QStringLiteral("applicationDisplayName"), QGuiApplication::applicationDisplayName()},
        {QStringLiteral("organizationName"), QCoreApplication::organizationName()},
        {QStringLiteral("organizationDomain"), QCoreApplication::organizationDomain()},
        {QStringLiteral("windowIconAvailable"), !QGuiApplication::windowIcon().isNull()},
        {QStringLiteral("renderingBackend"), renderingBackend(window)},
        {QStringLiteral("screenCount"), int(screens.size())},
        {QStringLiteral("screens"), screens},
        {QStringLiteral("window"), QJsonObject{
            {QStringLiteral("width"), window->width()},
            {QStringLiteral("height"), window->height()},
            {QStringLiteral("devicePixelRatio"), window->devicePixelRatio()},
            {QStringLiteral("screenName"), window->screen() ? window->screen()->name() : QString()},
            {QStringLiteral("visible"), window->isVisible()},
            {QStringLiteral("exposed"), window->isExposed()},
        }},
    };
    const QByteArray document = QJsonDocument(diagnostics).toJson(QJsonDocument::Indented);
    if (diagnosticsPath == QStringLiteral("-")) {
        if (std::fwrite(document.constData(), 1, document.size(), stdout) != size_t(document.size()))
            fail(QStringLiteral("Unable to write INZONE GUI diagnostics to standard output."));
        std::fflush(stdout);
        return;
    }
    QSaveFile output(diagnosticsPath);
    if (!output.open(QIODevice::WriteOnly) || output.write(document) != document.size() || !output.commit())
        fail(QStringLiteral("Unable to save INZONE GUI diagnostics: %1").arg(output.errorString()));
}

void checkWindow()
{
    for (QWindow *window : QGuiApplication::allWindows()) {
        auto *quickWindow = qobject_cast<QQuickWindow *>(window);
        if (!quickWindow || !quickWindow->isVisible() || quickWindow->transientParent())
            continue;
        if (!screenshotPath.isEmpty()) {
            const QImage image = quickWindow->grabWindow();
            if (image.isNull() || !image.save(screenshotPath))
                fail(QStringLiteral("Unable to save the INZONE window screenshot."));
        }
        if (!diagnosticsPath.isEmpty())
            writeDiagnostics(quickWindow);
        if (smokeTest)
            QCoreApplication::quit();
        return;
    }
    fail(QStringLiteral("The INZONE application did not create a visible Qt Quick window."));
}

void finishApplicationSetup()
{
    if (nativeWaylandRequired && !QGuiApplication::platformName().startsWith(QStringLiteral("wayland")))
        fail(QStringLiteral("The Wayland session did not initialize a native Qt Wayland platform."));
    QGuiApplication::setWindowIcon(QIcon::fromTheme(
        QStringLiteral("dev.zeroday0619"), QIcon(QStringLiteral(":/inzone/dev.zeroday0619.svg"))));
}

void scheduleApplicationSetup()
{
    // Qt's core startup hooks run before the GUI platform exists, so icon setup waits for the event loop.
    QTimer::singleShot(0, QCoreApplication::instance(), finishApplicationSetup);
    if (smokeTest || !screenshotPath.isEmpty() || !diagnosticsPath.isEmpty())
        QTimer::singleShot(2000, QCoreApplication::instance(), checkWindow);
}
}

Q_COREAPP_STARTUP_FUNCTION(scheduleApplicationSetup)

extern "C" void inzone_gui_configure(bool smoke_test, const char *screenshot_path,
                                     const char *diagnostics_path, bool platform_argument)
{
    initializeResources();
    // A private Qt SDK must load matching QML and platform plugins instead of the desktop's Qt version.
    const QDir executableDirectory(QFileInfo(QFileInfo(QStringLiteral("/proc/self/exe")).canonicalFilePath()).absolutePath());
    const QString privateQt = executableDirectory.filePath(QStringLiteral("../lib/inzone-linux/qt"));
    if (QFileInfo::exists(privateQt + QStringLiteral("/plugins/platforms"))) {
        qputenv("QT_PLUGIN_PATH", QFile::encodeName(privateQt + QStringLiteral("/plugins")));
        qputenv("QML_IMPORT_PATH", QFile::encodeName(privateQt + QStringLiteral("/qml")));
        qputenv("QML2_IMPORT_PATH", QFile::encodeName(privateQt + QStringLiteral("/qml")));
        qputenv("QT_QUICK_CONTROLS_STYLE", "Basic");
    }
    smokeTest = smoke_test;
    screenshotPath = QString::fromUtf8(screenshot_path);
    diagnosticsPath = QString::fromUtf8(diagnostics_path);

    // QtBridge creates QGuiApplication after the Swift QApp initializer returns.
    QCoreApplication::setApplicationName(QStringLiteral("dev.zeroday0619"));
    QCoreApplication::setApplicationVersion(QStringLiteral(INZONE_APPLICATION_VERSION));
    QGuiApplication::setApplicationDisplayName(QStringLiteral("INZONE Control"));
    QGuiApplication::setDesktopFileName(QStringLiteral("dev.zeroday0619"));

    if (platform_argument) {
        platformSelection = QStringLiteral("command-line");
    } else if (!qEnvironmentVariableIsEmpty("QT_QPA_PLATFORM")) {
        platformSelection = QStringLiteral("environment");
    } else if (qEnvironmentVariable("XDG_SESSION_TYPE").compare(QStringLiteral("wayland"), Qt::CaseInsensitive) == 0
               || !qEnvironmentVariableIsEmpty("WAYLAND_DISPLAY")
               || !qEnvironmentVariableIsEmpty("WAYLAND_SOCKET")) {
        // A single platform choice makes connection failures visible instead of falling back to XWayland.
        qputenv("QT_QPA_PLATFORM", "wayland");
        nativeWaylandRequired = true;
        platformSelection = QStringLiteral("wayland-session");
    } else {
        platformSelection = QStringLiteral("qt-default");
    }
}
