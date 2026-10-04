#include <QCoreApplication>
#include <QGuiApplication>
#include <QInputMethodEvent>
#include <QQmlContext>
#include <QQmlEngine>
#include <QQuickItem>
#include <QtQuickTest/quicktest.h>

class InputMethodProbe : public QObject
{
    Q_OBJECT

public:
    using QObject::QObject;

    Q_INVOKABLE QString focusObjectName() const
    {
        QObject *focus = QGuiApplication::focusObject();
        return focus ? focus->objectName() : QString();
    }

    Q_INVOKABLE bool preedit(const QString &text)
    {
        QList<QInputMethodEvent::Attribute> attributes;
        if (!text.isEmpty())
            attributes.append(QInputMethodEvent::Attribute(QInputMethodEvent::Cursor, text.size(), 1, QVariant()));
        QInputMethodEvent event(text, attributes);
        return deliver(event);
    }

    Q_INVOKABLE bool commit(const QString &text)
    {
        QInputMethodEvent event;
        event.setCommitString(text);
        return deliver(event);
    }

private:
    bool deliver(QInputMethodEvent &event)
    {
        auto *focus = qobject_cast<QQuickItem *>(QGuiApplication::focusObject());
        if (!focus || !focus->flags().testFlag(QQuickItem::ItemAcceptsInputMethod))
            return false;
        // Sending to the real focus object exercises the application's text-input path.
        return QCoreApplication::sendEvent(focus, &event) && event.isAccepted();
    }
};

class InputMethodSetup : public QObject
{
    Q_OBJECT

public slots:
    void qmlEngineAvailable(QQmlEngine *engine)
    {
        engine->rootContext()->setContextProperty(QStringLiteral("inputMethodProbe"), &probe);
    }

private:
    InputMethodProbe probe;
};

QUICK_TEST_MAIN_WITH_SETUP(inzone_gui, InputMethodSetup)

#include "InputMethodSetup.moc"
