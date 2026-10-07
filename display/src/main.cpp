#include <QCommandLineParser>
#include <QFile>
#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickWindow>
#include <QSGRendererInterface>
#include <QSettings>
#if QT_CONFIG(opengl)
#include <QOpenGLContext>
#include <QOpenGLFunctions>
#endif

#include "backend/SupabaseClient.h"
#include "hardware/DisplayController.h"
#include "hardware/PanelPower.h"
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
    // Video: HEVC decodes on the Pi 5's HEVC block through Raspberry Pi's
    // FFmpeg "drm" hwaccel (V4L2 request API); Qt then copies each frame once
    // into a GPU texture. Qt reads this once, at the first video. Streams the
    // block can't take (H.264, 4:2:2, 12-bit, no device) decode on the CPU.
    // "," in display.env turns it off, so test IsSet, not IsEmpty.
    if (!qEnvironmentVariableIsSet("QT_FFMPEG_DECODING_HW_DEVICE_TYPES"))
        qputenv("QT_FFMPEG_DECODING_HW_DEVICE_TYPES", QByteArrayLiteral("drm"));
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

// Says in the log what decodes video and what draws, so a look at the
// journal on the Pi shows whether the GPU is in use ("drawing on V3D ...").
static void reportGraphics(QQmlApplicationEngine &engine)
{
    QByteArray decoding = qgetenv("QT_FFMPEG_DECODING_HW_DEVICE_TYPES").trimmed();
    if (!qEnvironmentVariableIsSet("QT_FFMPEG_DECODING_HW_DEVICE_TYPES"))
        decoding = "auto";
    else if (decoding.isEmpty() || decoding == ",")
        decoding = "CPU only";
    qInfo("homeOS display: video decoding: %s", decoding.constData());

    auto *window = qobject_cast<QQuickWindow *>(engine.rootObjects().value(0));
    if (!window)
        return;
    // Once, at the next frame. Not sceneGraphInitialized: eglfs shows the
    // window and sets up its scene graph inside engine.load(), before this
    // runs.
    QObject::connect(
        window, &QQuickWindow::beforeRendering, window,
        [window]() {
            if (window->rendererInterface()->graphicsApi() == QSGRendererInterface::Software) {
                qWarning("homeOS display: Qt Quick is drawing in software; the GPU is not used");
                return;
            }
#if QT_CONFIG(opengl)
            if (QOpenGLContext *gl = QOpenGLContext::currentContext()) {
                const auto *renderer = reinterpret_cast<const char *>(gl->functions()->glGetString(GL_RENDERER));
                const QByteArray name = renderer ? QByteArray(renderer) : QByteArrayLiteral("an unknown OpenGL device");
                // Mesa's software rasterizers: OpenGL, but not on the GPU.
                if (name.contains("llvmpipe") || name.contains("softpipe"))
                    qWarning("homeOS display: drawing on %s, in software; the GPU is not used", name.constData());
                else
                    qInfo("homeOS display: drawing on %s", name.constData());
            }
#endif
        },
        // On the render thread, with its GL context current.
        Qt::ConnectionType(Qt::DirectConnection | Qt::SingleShotConnection));
    window->update(); // a next frame, even if nothing on screen changes
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
    const QString mediaUrl = FamilyStore::mediaApiUrlOrDefault(setting(settings, "HOMEOS_MEDIA_URL", "media/url"));
    store.setMediaApiUrl(mediaUrl);
    qInfo("homeOS display: media service: %s", qUtf8Printable(mediaUrl));

    // The on-device voice service (wake word, speech in and out) is optional.
    QString voiceUrl = setting(settings, "HOMEOS_VOICE_URL", "voice/url");
    if (voiceUrl.isEmpty())
        voiceUrl = QStringLiteral("ws://127.0.0.1:8765");
    VoiceClient voice{QUrl(voiceUrl)};

    Assistant assistant(&client, &store, &voice);
    DisplayController display;
    app.installEventFilter(&display);
    PanelPower panelPower(&display);
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
    // The on-screen keyboard's style (QtQuick/VirtualKeyboard/Styles/homeos/).
    // The keyboard builds the style's URL as <import path> + "/QtQuick/...",
    // which "qrc:/" would turn into qrc://QtQuick/..., so it gets a path of its own.
    engine.addImportPath(QStringLiteral("qrc:/keyboard"));
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
    reportGraphics(engine);

    store.start();
    voice.start();
    return app.exec();
}
