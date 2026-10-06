#include <QCommandLineParser>
#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QSettings>

#include "backend/SupabaseClient.h"
#include "hardware/DisplayController.h"
#include "models/FamilyStore.h"

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
    QGuiApplication::setApplicationVersion(QStringLiteral("0.1.0"));

    QCommandLineParser parser;
    parser.setApplicationDescription("homeOS wall display");
    parser.addHelpOption();
    parser.addVersionOption();
    QCommandLineOption windowed("windowed", "Run in a window instead of full screen (development).");
    QCommandLineOption demo("demo", "Ignore backend settings and show sample data.");
    parser.addOptions({windowed, demo});
    parser.process(app);

    QSettings settings;
    const QString url = setting(settings, "HOMEOS_SUPABASE_URL", "backend/url");
    const QString anonKey = setting(settings, "HOMEOS_SUPABASE_ANON_KEY", "backend/anonKey");

    SupabaseClient client(QUrl(url), anonKey);
    client.setRefreshToken(setting(settings, "HOMEOS_DEVICE_REFRESH_TOKEN", "device/refreshToken"));

    FamilyStore store(&client, parser.isSet(demo));
    DisplayController display;
    app.installEventFilter(&display);

    qmlRegisterSingletonInstance("HomeOS.Core", 1, 0, "Store", &store);
    qmlRegisterSingletonInstance("HomeOS.Core", 1, 0, "Device", &display);

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
    return app.exec();
}
