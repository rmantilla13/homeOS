#include <QCommandLineParser>
#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QSettings>

#include "backend/SupabaseClient.h"
#include "hardware/DisplayController.h"
#include "hardware/SystemController.h"
#include "models/Assistant.h"
#include "models/FamilyStore.h"
#include "voice/VoiceClient.h"

// Environment variables win over the saved settings so a device can be
// reconfigured without touching its config file.
static QString setting(QSettings &settings, const char *env, const QString &key)
{
    const QString fromEnv = qEnvironmentVariable(env);
    return fromEnv.isEmpty() ? settings.value(key).toString() : fromEnv;
}

int main(int argc, char *argv[])
{
    QGuiApplication app(argc, argv);
    QGuiApplication::setOrganizationName("homeOS");
    QGuiApplication::setApplicationName("display");
    QGuiApplication::setApplicationVersion(QStringLiteral(HOMEOS_VERSION));

    QCommandLineParser parser;
    parser.setApplicationDescription("Ohana wall display");
    parser.addHelpOption();
    parser.addVersionOption();
    QCommandLineOption windowed("windowed", "Run in a window instead of full screen (development).");
    QCommandLineOption demo("demo", "Ignore backend settings and show sample data.");
    // Read by Main.qml; registered here so the parser doesn't reject it.
    QCommandLineOption noKeyboard("no-keyboard", "Don't load the on-screen keyboard.");
    parser.addOptions({windowed, demo, noKeyboard});
    parser.process(app);

    QSettings settings;
    const QString url = setting(settings, "HOMEOS_SUPABASE_URL", "backend/url");
    const QString anonKey = setting(settings, "HOMEOS_SUPABASE_ANON_KEY", "backend/anonKey");

    SupabaseClient client(QUrl(url), anonKey);
    client.setRefreshToken(setting(settings, "HOMEOS_DEVICE_REFRESH_TOKEN", "device/refreshToken"));

    FamilyStore store(&client, parser.isSet(demo));
    store.setMediaApiUrl(setting(settings, "HOMEOS_MEDIA_URL", "media/url"));

    // The on-device voice service (wake word, speech in and out) is optional.
    QString voiceUrl = setting(settings, "HOMEOS_VOICE_URL", "voice/url");
    if (voiceUrl.isEmpty())
        voiceUrl = QStringLiteral("ws://127.0.0.1:8765");
    VoiceClient voice{QUrl(voiceUrl)};

    Assistant assistant(&client, &store, &voice);
    DisplayController display;
    app.installEventFilter(&display);
    SystemController system;
    system.start();

    qmlRegisterSingletonInstance("HomeOS.Core", 1, 0, "Store", &store);
    qmlRegisterSingletonInstance("HomeOS.Core", 1, 0, "Device", &display);
    qmlRegisterSingletonInstance("HomeOS.Core", 1, 0, "System", &system);
    qmlRegisterSingletonInstance("HomeOS.Core", 1, 0, "AI", &assistant);
    qmlRegisterSingletonInstance("HomeOS.Core", 1, 0, "Voice", &voice);
    qmlRegisterUncreatableType<ChatModel>("HomeOS.Core", 1, 0, "ChatModel", "Owned by AI");

    QQmlApplicationEngine engine;
    engine.addImportPath(QStringLiteral("qrc:/"));
    engine.rootContext()->setContextProperty("startWindowed", parser.isSet(windowed));

    const QUrl mainUrl(QStringLiteral("qrc:/HomeOS/qml/Main.qml"));
    QObject::connect(
        &engine, &QQmlApplicationEngine::objectCreated, &app,
        [mainUrl](QObject *obj, const QUrl &objUrl) {
            if (!obj && objUrl == mainUrl)
                QCoreApplication::exit(1);
        },
        Qt::QueuedConnection);
    engine.load(mainUrl);

    store.start();
    voice.start();
    return app.exec();
}
