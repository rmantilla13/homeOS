#include <QCommandLineParser>
#include <QFile>
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

// The kiosk draws on the HDMI panel. Set that before QGuiApplication, which
// reads the platform plugin once. A desktop session (DISPLAY or WAYLAND) and
// an explicit QT_QPA_PLATFORM, including the offscreen CI run, are left alone.
// --windowed is the development window and must not take the DRM device.
static void preparePanelPlatform(int argc, char **argv)
{
    for (int i = 1; i < argc; ++i) {
        if (qstrcmp(argv[i], "--windowed") == 0)
            return;
    }
    const bool platformSet = !qEnvironmentVariableIsEmpty("QT_QPA_PLATFORM");
    const bool desktop = !qEnvironmentVariableIsEmpty("DISPLAY")
        || !qEnvironmentVariableIsEmpty("WAYLAND_DISPLAY");
    if (!platformSet && !desktop)
        qputenv("QT_QPA_PLATFORM", QByteArrayLiteral("eglfs"));
    if (qgetenv("QT_QPA_PLATFORM") != "eglfs")
        return;
    if (qEnvironmentVariableIsEmpty("QT_QPA_EGLFS_INTEGRATION"))
        qputenv("QT_QPA_EGLFS_INTEGRATION", QByteArrayLiteral("eglfs_kms"));
    if (qEnvironmentVariableIsEmpty("QT_QPA_EGLFS_KMS_CONFIG")
        && QFile::exists(QStringLiteral("/etc/homeos/kms.json")))
        qputenv("QT_QPA_EGLFS_KMS_CONFIG", QByteArrayLiteral("/etc/homeos/kms.json"));
    if (qEnvironmentVariableIsEmpty("QT_QPA_EGLFS_HIDECURSOR"))
        qputenv("QT_QPA_EGLFS_HIDECURSOR", QByteArrayLiteral("1"));
    // The console may already have a mode. Set it again so the text console
    // does not stay on HDMI while this process is running.
    if (qEnvironmentVariableIsEmpty("QT_QPA_EGLFS_ALWAYS_SET_MODE"))
        qputenv("QT_QPA_EGLFS_ALWAYS_SET_MODE", QByteArrayLiteral("1"));
}

int main(int argc, char *argv[])
{
    preparePanelPlatform(argc, argv);
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

    // A running process with no screen leaves the text console on HDMI and
    // looks healthy to systemctl. Exit so Restart= tries again once the
    // panel or the DRM device is there.
    if (QGuiApplication::screens().isEmpty()) {
        qCritical("homeOS display: no screen. The HDMI device was not opened.");
        return 1;
    }

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
