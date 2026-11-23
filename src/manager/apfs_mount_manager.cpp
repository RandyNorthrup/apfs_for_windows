// Copyright (c) 2026 Randy Northrup. All rights reserved.
//
// APFS for Windows mount manager: per-user notification-area (tray) process and
// management window. The manager never owns filesystem state; every action is a
// request to apfs_mount_service.exe, which forwards to the LocalSystem service
// over its control channel when the caller cannot apply the change directly.

#include <QAction>
#include <QApplication>
#include <QBrush>
#include <QClipboard>
#include <QColor>
#include <QCoreApplication>
#include <QDateTime>
#include <QDesktopServices>
#include <QDir>
#include <QFileInfo>
#include <QFont>
#include <QGuiApplication>
#include <QHBoxLayout>
#include <QHash>
#include <QHeaderView>
#include <QIcon>
#include <QInputDialog>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLabel>
#include <QLocalServer>
#include <QLocalSocket>
#include <QMainWindow>
#include <QMenu>
#include <QMessageBox>
#include <QPainter>
#include <QPainterPath>
#include <QPen>
#include <QPixmap>
#include <QPlainTextEdit>
#include <QPointer>
#include <QProcess>
#include <QPushButton>
#include <QRect>
#include <QScreen>
#include <QSettings>
#include <QSplitter>
#include <QStatusBar>
#include <QStringList>
#include <QStyle>
#include <QSystemTrayIcon>
#include <QTableWidget>
#include <QTextStream>
#include <QTimer>
#include <QToolBar>
#include <QUrl>
#include <QVBoxLayout>

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <functional>
#include <memory>
#include <utility>

#ifdef Q_OS_WIN
#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#endif

#ifndef APFS_PROJECT_VERSION
#define APFS_PROJECT_VERSION "0.0.0"
#endif

namespace {

constexpr char kManagerInstanceServerPrefix[] = "ApfsForWindowsMountManager.Instance";
constexpr char kProductName[] = "APFS for Windows";
constexpr char kProjectUrl[] = "https://github.com/RandyNorthrup/apfs_for_windows";
constexpr int kServiceCommandTimeoutMs = 75000;
constexpr int kEjectSettleTimeoutMs = 45000;
constexpr int kEjectPollIntervalMs = 1000;
constexpr int kHealthPollIntervalMs = 8000;
constexpr int kNotificationDurationMs = 6000;
constexpr int kInstancePingTimeoutMs = 1000;

// ---------------------------------------------------------------------------
// Console attachment for the CLI modes of a GUI-subsystem executable.
// ---------------------------------------------------------------------------

void attachParentConsoleIfNeeded() {
#ifdef Q_OS_WIN
    const HANDLE out = GetStdHandle(STD_OUTPUT_HANDLE);
    if (out != nullptr && out != INVALID_HANDLE_VALUE && GetFileType(out) != FILE_TYPE_UNKNOWN) {
        return;  // Redirected to a pipe or file (CTest, scripts): already usable.
    }
    if (AttachConsole(ATTACH_PARENT_PROCESS)) {
        FILE* stream = nullptr;
        freopen_s(&stream, "CONOUT$", "w", stdout);
        freopen_s(&stream, "CONOUT$", "w", stderr);
    }
#endif
}

void printJson(const QJsonObject& object) {
    QTextStream(stdout) << QJsonDocument(object).toJson(QJsonDocument::Indented);
}

void printUsage() {
    QTextStream(stdout)
        << "Usage: apfs_mount_manager [--tray|--status|--self-test|--version|--help]\n"
        << "  --tray       Start in the notification area without opening the window.\n"
        << "  --status     Print service health as JSON and exit.\n"
        << "  --self-test  Run manager UI contract checks and exit.\n"
        << "  --version    Print the product version and exit.\n"
        << "  --help       Print this help and exit.\n";
}

// ---------------------------------------------------------------------------
// Paths and environment
// ---------------------------------------------------------------------------

QString installedServiceExe() {
#ifdef Q_OS_WIN
    const QString programFiles =
        qEnvironmentVariable("ProgramFiles", QStringLiteral("C:\\Program Files"));
    return QDir(programFiles).filePath(QStringLiteral("APFS for Windows/apfs_mount_service.exe"));
#else
    return {};
#endif
}

QString serviceExePath() {
    const QString appLocal =
        QDir(QCoreApplication::applicationDirPath()).filePath(QStringLiteral("apfs_mount_service.exe"));
    if (QFileInfo::exists(appLocal)) {
        return appLocal;
    }
    const QString installed = installedServiceExe();
    if (QFileInfo::exists(installed)) {
        return installed;
    }
    return appLocal;
}

QString serviceLogDir() {
    const QString base = qEnvironmentVariable("ProgramData", QStringLiteral("C:\\ProgramData"));
    return QDir(base).filePath(QStringLiteral("APFS for Windows/logs"));
}

// Named pipes live in a machine-wide namespace. Scope the single-instance
// channel to the interactive session so each signed-in user gets a tray.
QString instanceServerName() {
    QString suffix = QStringLiteral("default");
#ifdef Q_OS_WIN
    DWORD sessionId = 0;
    if (ProcessIdToSessionId(GetCurrentProcessId(), &sessionId)) {
        suffix = QString::number(sessionId);
    }
#endif
    return QStringLiteral("%1.%2").arg(QString::fromLatin1(kManagerInstanceServerPrefix), suffix);
}

// Mirrors sak::isWindowsRawDevicePath (the rule the service and worker apply).
bool looksLikeRawDeviceTarget(const QString& target) {
    QString path = target.trimmed();
    path.replace(QLatin1Char('/'), QLatin1Char('\\'));
    if (path.startsWith(QStringLiteral("\\\\.\\"))) {
        return true;
    }
    if (path.startsWith(QStringLiteral("\\\\?\\PhysicalDrive"), Qt::CaseInsensitive) ||
        path.startsWith(QStringLiteral("\\\\?\\GLOBALROOT\\"), Qt::CaseInsensitive)) {
        return true;
    }
    if (path.startsWith(QStringLiteral("\\\\?\\Volume{"), Qt::CaseInsensitive)) {
        const qsizetype close = path.indexOf(QLatin1Char('}'));
        return close > 0 && (close == path.size() - 1 ||
                             (close == path.size() - 2 && path.endsWith(QLatin1Char('\\'))));
    }
    return false;
}

QString compactJson(const QJsonObject& object) {
    return QString::fromUtf8(QJsonDocument(object).toJson(QJsonDocument::Indented));
}

QJsonObject parseServiceOutput(const QByteArray& stdoutBytes,
                               const QByteArray& stderrBytes,
                               int exitCode,
                               const QStringList& args) {
    QJsonParseError parseError{};
    const QJsonDocument document = QJsonDocument::fromJson(stdoutBytes, &parseError);
    if (parseError.error != QJsonParseError::NoError || !document.isObject()) {
        return QJsonObject{{QStringLiteral("ok"), false},
                           {QStringLiteral("exit_code"), exitCode},
                           {QStringLiteral("args"), QJsonArray::fromStringList(args)},
                           {QStringLiteral("stdout"), QString::fromUtf8(stdoutBytes)},
                           {QStringLiteral("stderr"), QString::fromUtf8(stderrBytes)},
                           {QStringLiteral("parse_error"), parseError.errorString()}};
    }
    QJsonObject object = document.object();
    object.insert(QStringLiteral("ok"), exitCode == 0);
    if (!stderrBytes.isEmpty()) {
        object.insert(QStringLiteral("stderr"), QString::fromUtf8(stderrBytes));
    }
    return object;
}

// Blocking variant for the CLI modes only (--status, --self-test).
QJsonObject runServiceCommandSync(const QStringList& args, int* exitCode) {
    QProcess process;
    process.start(serviceExePath(), args);
    if (!process.waitForStarted(5000) || !process.waitForFinished(kServiceCommandTimeoutMs)) {
        process.kill();
        process.waitForFinished(3000);
        *exitCode = 124;
        return QJsonObject{{QStringLiteral("ok"), false},
                           {QStringLiteral("error"), QStringLiteral("service command did not complete")},
                           {QStringLiteral("args"), QJsonArray::fromStringList(args)}};
    }
    *exitCode = process.exitStatus() == QProcess::NormalExit ? process.exitCode() : 125;
    return parseServiceOutput(process.readAllStandardOutput(),
                              process.readAllStandardError(),
                              *exitCode,
                              args);
}

QString errorTextFrom(const QJsonObject& result, const QString& fallback) {
    for (const char* key : {"error", "stderr", "parse_error"}) {
        const QString text = result.value(QLatin1String(key)).toString().trimmed();
        if (!text.isEmpty()) {
            return text;
        }
    }
    return fallback;
}

// ---------------------------------------------------------------------------
// Health model
// ---------------------------------------------------------------------------

enum class HealthState { Unknown, Ok, Idle, Warning, Error };

struct MountView {
    QString target;
    QString mount;
    QString root;
    QString label;
    QString fileSystem;
    bool enabled{true};
    bool ejected{false};
    bool exists{false};
    bool readOnly{true};
    bool rawWrites{false};
    bool collision{false};
    QStringList entries;

    bool mounted() const { return enabled && exists; }
};

MountView mountFromJson(const QJsonObject& object) {
    MountView view;
    view.target = object.value(QStringLiteral("target")).toString();
    view.mount = object.value(QStringLiteral("mount")).toString();
    view.root = object.value(QStringLiteral("root")).toString();
    view.label = object.value(QStringLiteral("volume_label")).toString();
    view.fileSystem = object.value(QStringLiteral("file_system")).toString();
    view.enabled = object.value(QStringLiteral("enabled")).toBool(true);
    view.ejected = object.value(QStringLiteral("ejected")).toBool(false);
    view.exists = object.value(QStringLiteral("exists")).toBool(false);
    view.readOnly = object.value(QStringLiteral("read_only")).toBool(true);
    view.rawWrites = object.value(QStringLiteral("allow_raw_writes")).toBool(false);
    view.collision = object.value(QStringLiteral("mount_collision")).toBool(false);
    for (const auto& entry : object.value(QStringLiteral("entries")).toArray()) {
        view.entries.append(entry.toObject().value(QStringLiteral("name")).toString());
    }
    return view;
}

struct HealthSnapshot {
    bool received{false};
    bool commandOk{false};
    bool serviceInstalled{false};
    QString serviceStatus;
    QString errorText;
    QList<MountView> mounts;
    QJsonObject raw;

    bool serviceRunning() const {
        return serviceStatus.compare(QStringLiteral("running"), Qt::CaseInsensitive) == 0;
    }
    int mountedCount() const {
        return static_cast<int>(
            std::count_if(mounts.cbegin(), mounts.cend(), [](const MountView& m) { return m.mounted(); }));
    }
    bool anyCollision() const {
        return std::any_of(mounts.cbegin(), mounts.cend(), [](const MountView& m) {
            return m.enabled && m.collision;
        });
    }
    HealthState state() const {
        if (!received) {
            return HealthState::Unknown;
        }
        if (!serviceInstalled || !serviceRunning()) {
            return HealthState::Error;
        }
        if (anyCollision()) {
            return HealthState::Warning;
        }
        return mountedCount() > 0 ? HealthState::Ok : HealthState::Idle;
    }
    const MountView* findByTarget(const QString& target) const {
        for (const MountView& m : mounts) {
            if (m.target == target) {
                return &m;
            }
        }
        return nullptr;
    }
};

HealthSnapshot snapshotFromJson(const QJsonObject& health) {
    HealthSnapshot snapshot;
    snapshot.received = true;
    snapshot.raw = health;
    snapshot.commandOk = health.value(QStringLiteral("ok")).toBool(false);
    const QJsonObject service = health.value(QStringLiteral("service")).toObject();
    snapshot.serviceInstalled = service.value(QStringLiteral("installed")).toBool(false);
    snapshot.serviceStatus = service.value(QStringLiteral("status")).toString();
    if (!snapshot.commandOk) {
        snapshot.errorText = errorTextFrom(health, QStringLiteral("The APFS service did not respond."));
    }
    for (const auto& value : health.value(QStringLiteral("mounts")).toArray()) {
        snapshot.mounts.append(mountFromJson(value.toObject()));
    }
    return snapshot;
}

QString modeText(const MountView& mount) {
    if (mount.readOnly) {
        return QStringLiteral("Read-only");
    }
    return QStringLiteral("Read/write");
}

QString statusText(const MountView& mount) {
    if (!mount.enabled) {
        return QStringLiteral("Automount off");
    }
    if (mount.ejected) {
        return QStringLiteral("Unmounted");
    }
    if (mount.collision) {
        return QStringLiteral("Drive letter in use");
    }
    return mount.exists ? QStringLiteral("Mounted") : QStringLiteral("Not connected");
}

QString displayName(const MountView& mount) {
    const QString label = mount.label.trimmed().isEmpty() ? QStringLiteral("APFS volume") : mount.label;
    return mount.mount.isEmpty() ? label : QStringLiteral("%1 (%2)").arg(label, mount.mount);
}

QString serviceStatusText(const HealthSnapshot& snapshot) {
    if (!snapshot.received) {
        return QStringLiteral("Checking service…");
    }
    if (!snapshot.serviceInstalled) {
        return QStringLiteral("Service not installed");
    }
    if (!snapshot.serviceRunning()) {
        const QString status = snapshot.serviceStatus.isEmpty() ? QStringLiteral("unavailable")
                                                                : snapshot.serviceStatus;
        return QStringLiteral("Service %1").arg(status);
    }
    const int mounted = snapshot.mountedCount();
    if (mounted == 0) {
        return QStringLiteral("Service running · no volumes mounted");
    }
    return mounted == 1 ? QStringLiteral("Service running · 1 volume mounted")
                        : QStringLiteral("Service running · %1 volumes mounted").arg(mounted);
}

QString trayToolTip(const HealthSnapshot& snapshot) {
    QStringList lines{QString::fromLatin1(kProductName), serviceStatusText(snapshot)};
    for (const MountView& mount : snapshot.mounts) {
        if (mount.mounted()) {
            lines.append(QStringLiteral("%1 %2").arg(displayName(mount), modeText(mount)));
        }
    }
    // Windows limits notification-area tooltips to 127 characters.
    QString text = lines.join(QLatin1Char('\n'));
    if (text.size() > 120) {
        text = text.left(117) + QStringLiteral("...");
    }
    return text;
}

// ---------------------------------------------------------------------------
// Icon rendering: stacked AP/FS mark with an optional state badge, drawn per
// size so the notification area gets crisp pixels at every DPI.
// ---------------------------------------------------------------------------

QPixmap renderMark(int size, HealthState state) {
    QPixmap pixmap(size, size);
    pixmap.fill(Qt::transparent);
    QPainter painter(&pixmap);
    painter.setRenderHint(QPainter::Antialiasing, true);
    painter.setRenderHint(QPainter::TextAntialiasing, true);

    const qreal s = static_cast<qreal>(size);
    const qreal stroke = std::max<qreal>(1.0, s / 32.0);
    const qreal inset = stroke / 2.0 + (size <= 20 ? 0.0 : s * 0.04);
    const QRectF background(inset, inset, s - 2 * inset, s - 2 * inset);
    const QColor accent(80, 176, 214);
    painter.setPen(QPen(accent, stroke));
    painter.setBrush(QColor(20, 42, 58));
    painter.drawRoundedRect(background, s * 0.14, s * 0.14);

    const qreal mid = s / 2.0;
    painter.setPen(QPen(accent, std::max<qreal>(1.0, s / 42.0)));
    painter.drawLine(QPointF(background.left() + s * 0.16, mid),
                     QPointF(background.right() - s * 0.16, mid));

    QFont font(QStringLiteral("Segoe UI"));
    font.setBold(true);
    font.setPixelSize(std::max(6, static_cast<int>(s * (size <= 24 ? 0.40 : 0.31))));
    font.setLetterSpacing(QFont::PercentageSpacing, size <= 24 ? 92.0 : 100.0);
    font.setHintingPreference(size <= 32 ? QFont::PreferFullHinting : QFont::PreferNoHinting);
    painter.setFont(font);
    painter.setPen(Qt::white);
    const QRectF top(background.left(), background.top(), background.width(), mid - background.top());
    const QRectF bottom(background.left(), mid, background.width(), background.bottom() - mid);
    painter.drawText(top, Qt::AlignCenter, QStringLiteral("AP"));
    painter.drawText(bottom, Qt::AlignCenter, QStringLiteral("FS"));

    QColor badge;
    switch (state) {
    case HealthState::Ok:
        badge = QColor(46, 160, 67);
        break;
    case HealthState::Warning:
        badge = QColor(219, 154, 4);
        break;
    case HealthState::Error:
        badge = QColor(207, 34, 46);
        break;
    case HealthState::Idle:
    case HealthState::Unknown:
        break;
    }
    if (badge.isValid()) {
        const qreal radius = std::max<qreal>(3.0, s * 0.21);
        const QPointF center(s - radius - stroke * 0.25, s - radius - stroke * 0.25);
        painter.setPen(QPen(QColor(255, 255, 255), std::max<qreal>(1.0, s / 24.0)));
        painter.setBrush(badge);
        painter.drawEllipse(center, radius, radius);
        if (size >= 32) {
            painter.setPen(QPen(Qt::white, std::max<qreal>(1.5, s / 20.0), Qt::SolidLine, Qt::RoundCap,
                                Qt::RoundJoin));
            const qreal r = radius * 0.5;
            if (state == HealthState::Ok) {
                QPainterPath check;
                check.moveTo(center + QPointF(-r, 0));
                check.lineTo(center + QPointF(-r * 0.25, r * 0.7));
                check.lineTo(center + QPointF(r, -r * 0.6));
                painter.setBrush(Qt::NoBrush);
                painter.drawPath(check);
            } else if (state == HealthState::Error) {
                painter.drawLine(center + QPointF(-r * 0.75, -r * 0.75), center + QPointF(r * 0.75, r * 0.75));
                painter.drawLine(center + QPointF(-r * 0.75, r * 0.75), center + QPointF(r * 0.75, -r * 0.75));
            } else {
                painter.drawLine(center + QPointF(0, -r), center + QPointF(0, r * 0.25));
                painter.drawPoint(center + QPointF(0, r * 0.85));
            }
        }
    }
    painter.end();
    return pixmap;
}

QIcon stackedApfsIcon(HealthState state = HealthState::Unknown) {
    QIcon icon;
    for (int size : {16, 20, 24, 32, 40, 48, 64, 96, 128, 256}) {
        icon.addPixmap(renderMark(size, state));
    }
    return icon;
}

// ---------------------------------------------------------------------------
// Per-user preferences
// ---------------------------------------------------------------------------

QSettings& userSettings() {
    static QSettings settings(QSettings::NativeFormat, QSettings::UserScope,
                              QString::fromLatin1(kProductName),
                              QStringLiteral("Mount Manager"));
    return settings;
}

bool notificationsEnabled() {
    return userSettings().value(QStringLiteral("notifications"), true).toBool();
}

void setNotificationsEnabled(bool enabled) {
    userSettings().setValue(QStringLiteral("notifications"), enabled);
}

// The installer starts the tray for every user from HKLM\...\Run. Each user can
// opt out here; a tray started with --tray then exits immediately.
bool startAtSignInEnabled() {
    return userSettings().value(QStringLiteral("startAtSignIn"), true).toBool();
}

void setStartAtSignIn(bool enabled) {
    userSettings().setValue(QStringLiteral("startAtSignIn"), enabled);
    userSettings().sync();
}

QStringList freeDriveLetters(const QString& keep) {
    QStringList letters;
#ifdef Q_OS_WIN
    const DWORD used = GetLogicalDrives();
    for (int i = 3; i < 26; ++i) {  // D: through Z:
        const QString letter = QStringLiteral("%1:").arg(QChar(static_cast<char16_t>(u'A' + i)));
        if ((used & (1u << i)) == 0 || letter.compare(keep, Qt::CaseInsensitive) == 0) {
            letters.append(letter);
        }
    }
#else
    Q_UNUSED(keep);
#endif
    return letters;
}

// ---------------------------------------------------------------------------
// Asynchronous service client. Commands run one at a time so a policy change is
// never interleaved with another; health polls coalesce.
// ---------------------------------------------------------------------------

class ServiceClient final : public QObject {
public:
    using Callback = std::function<void(const QJsonObject& result, int exitCode)>;

    explicit ServiceClient(QObject* parent) : QObject(parent) {}
    ~ServiceClient() override {
        queue_.clear();
        if (active_) {
            // Disconnect first so a process killed during shutdown cannot call
            // back into a half-destroyed controller.
            active_->disconnect(this);
            active_->kill();
            active_->waitForFinished(2000);
        }
    }

    void run(const QStringList& args, Callback callback) {
        queue_.append({args, std::move(callback)});
        pump();
    }

    bool busy() const { return active_ != nullptr; }
    bool hasQueuedArgs(const QString& firstArg) const {
        if (active_ && activeArgs_.value(0) == firstArg) {
            return true;
        }
        return std::any_of(queue_.cbegin(), queue_.cend(), [&](const Pending& p) {
            return p.args.value(0) == firstArg;
        });
    }

private:
    struct Pending {
        QStringList args;
        Callback callback;
    };

    void pump() {
        if (active_ || queue_.isEmpty()) {
            return;
        }
        Pending next = queue_.takeFirst();
        activeArgs_ = next.args;
        auto* process = new QProcess(this);
        active_ = process;
        auto finished = std::make_shared<bool>(false);
        auto complete = [this, process, finished, callback = std::move(next.callback)](const QJsonObject& result, int code) {
            if (*finished) {
                return;
            }
            *finished = true;
            if (callback) {
                callback(result, code);
            }
            active_ = nullptr;
            activeArgs_.clear();
            process->deleteLater();
            QTimer::singleShot(0, this, [this]() { pump(); });
        };
        auto* timer = new QTimer(process);
        timer->setSingleShot(true);
        connect(timer, &QTimer::timeout, this, [process, complete, args = next.args]() {
            process->kill();
            complete(QJsonObject{{QStringLiteral("ok"), false},
                                 {QStringLiteral("error"), QStringLiteral("The APFS service did not respond in time.")},
                                 {QStringLiteral("args"), QJsonArray::fromStringList(args)}},
                     124);
        });
        connect(process, &QProcess::finished, this,
                [process, complete, args = next.args](int exitCode, QProcess::ExitStatus status) {
                    const int code = status == QProcess::NormalExit ? exitCode : 125;
                    complete(parseServiceOutput(process->readAllStandardOutput(),
                                                process->readAllStandardError(),
                                                code,
                                                args),
                             code);
                });
        connect(process, &QProcess::errorOccurred, this,
                [process, complete, args = next.args](QProcess::ProcessError error) {
                    if (error != QProcess::FailedToStart) {
                        return;
                    }
                    complete(QJsonObject{{QStringLiteral("ok"), false},
                                         {QStringLiteral("error"),
                                          QStringLiteral("Unable to start %1: %2")
                                              .arg(QDir::toNativeSeparators(process->program()),
                                                   process->errorString())},
                                         {QStringLiteral("args"), QJsonArray::fromStringList(args)}},
                             126);
                });
        timer->start(kServiceCommandTimeoutMs);
        process->start(serviceExePath(), next.args);
    }

    QList<Pending> queue_;
    QPointer<QProcess> active_;
    QStringList activeArgs_;
};

// ---------------------------------------------------------------------------
// Controller: owns the health state and every user action, shared by the tray
// menu and the window.
// ---------------------------------------------------------------------------

class Controller final : public QObject {
public:
    using Listener = std::function<void()>;

    explicit Controller(QObject* parent) : QObject(parent), client_(new ServiceClient(this)) {
        pollTimer_.setInterval(kHealthPollIntervalMs);
        connect(&pollTimer_, &QTimer::timeout, this, [this]() { refresh(); });
        ejectTimer_.setInterval(kEjectPollIntervalMs);
        connect(&ejectTimer_, &QTimer::timeout, this, [this]() {
            if (pendingEjects_.isEmpty()) {
                ejectTimer_.stop();
                return;
            }
            refresh();
        });
    }

    void start() {
        refresh();
        pollTimer_.start();
    }

    const HealthSnapshot& snapshot() const { return snapshot_; }
    bool commandInFlight() const { return commandsInFlight_ > 0; }

    void addListener(Listener listener) { listeners_.append(std::move(listener)); }
    void setNotifier(std::function<void(const QString&, const QString&, QSystemTrayIcon::MessageIcon)> n) {
        notifier_ = std::move(n);
    }
    void setStatusSink(std::function<void(const QString&)> sink) { statusSink_ = std::move(sink); }

    void refresh() {
        if (client_->hasQueuedArgs(QStringLiteral("--health"))) {
            return;
        }
        client_->run({QStringLiteral("--health")}, [this](const QJsonObject& result, int) {
            applyHealth(snapshotFromJson(result));
        });
    }

    void discover(QWidget* parent) {
        // The service owns raw-disk access; ask it to rescan now rather than
        // probing disks as the (usually non-administrator) signed-in user.
        runCommand(parent, {QStringLiteral("--rescan")},
                   QStringLiteral("Searching for APFS devices…"),
                   QStringLiteral("Device search requested"),
                   QStringLiteral("Device Search Failed"),
                   QStringLiteral("The APFS service did not accept the request."));
    }

    void openMount(const MountView& mount, QWidget* parent) {
        if (!mount.mounted() || mount.root.isEmpty()) {
            QMessageBox::information(parent, QString::fromLatin1(kProductName),
                                     QStringLiteral("%1 is not mounted.").arg(displayName(mount)));
            return;
        }
        QDesktopServices::openUrl(QUrl::fromLocalFile(mount.root));
    }

    void unmount(const MountView& mount, QWidget* parent) {
        QString detail = QStringLiteral("Unmount %1?\n\nClose any files open on the volume first.")
                             .arg(displayName(mount));
        if (!mount.readOnly) {
            detail += QStringLiteral(" Pending writes are flushed before the volume is released.");
        }
        detail += QStringLiteral("\n\nIt mounts again the next time the device is connected, or "
                                 "when you choose Mount.");
        if (!confirm(parent, QStringLiteral("Unmount APFS Volume"), detail)) {
            return;
        }
        const QString target = mount.target;
        const QString letter = mount.mount;
        runCommand(parent,
                   {QStringLiteral("--eject"), QStringLiteral("--target"), target},
                   QStringLiteral("Unmounting %1…").arg(letter),
                   QStringLiteral("Unmounting %1… writes are being flushed").arg(letter),
                   QStringLiteral("Unmount Failed"),
                   QStringLiteral("The APFS volume was not unmounted."),
                   [this, target, letter](const QJsonObject& result) {
                       const bool ok = result.value(QStringLiteral("ejected")).toBool(false);
                       if (ok) {
                           pendingEjects_.insert(target, QDateTime::currentMSecsSinceEpoch() + kEjectSettleTimeoutMs);
                           pendingEjectLetters_.insert(target, letter);
                           ejectTimer_.start();
                       }
                       return ok;
                   });
    }

    void mountNow(const MountView& mount, QWidget* parent) {
        runCommand(parent,
                   {QStringLiteral("--set-enabled"), QStringLiteral("--target"), mount.target,
                    QStringLiteral("--enabled"), QStringLiteral("true")},
                   QStringLiteral("Mounting %1…").arg(mount.mount),
                   QStringLiteral("Mount requested for %1").arg(mount.mount),
                   QStringLiteral("Mount Failed"),
                   QStringLiteral("The APFS volume was not mounted."));
    }

    void toggleReadOnly(const MountView& mount, QWidget* parent) {
        const bool makeWritable = mount.readOnly;
        const QString detail =
            makeWritable
                ? QStringLiteral("Enable read/write access for %1?\n\nThe service verifies the exact "
                                 "APFS target and its safety policy before enabling writes. Sealed, "
                                 "encrypted, and unsupported volumes stay read-only.")
                      .arg(displayName(mount))
                : QStringLiteral("Make %1 read-only?").arg(displayName(mount));
        if (!confirm(parent, QStringLiteral("Change Access Mode"), detail)) {
            return;
        }
        QStringList args{QStringLiteral("--set-policy"), QStringLiteral("--target"), mount.target,
                         makeWritable ? QStringLiteral("--read-write") : QStringLiteral("--read-only")};
        if (makeWritable && looksLikeRawDeviceTarget(mount.target)) {
            args.append(QStringLiteral("--allow-raw-writes"));
        }
        runCommand(parent, args, QStringLiteral("Changing access mode…"),
                   makeWritable ? QStringLiteral("%1 is now read/write").arg(mount.mount)
                                : QStringLiteral("%1 is now read-only").arg(mount.mount),
                   QStringLiteral("Access Mode Not Changed"),
                   QStringLiteral("The access mode was not changed."));
    }

    void toggleAutomount(const MountView& mount, QWidget* parent) {
        const bool enable = !mount.enabled;
        if (!enable &&
            !confirm(parent, QStringLiteral("Turn Off Automount"),
                     QStringLiteral("Turn off automount for %1?\n\nThe volume is unmounted and stays "
                                    "unmounted until automount is turned back on.")
                         .arg(displayName(mount)))) {
            return;
        }
        runCommand(parent,
                   {QStringLiteral("--set-enabled"), QStringLiteral("--target"), mount.target,
                    QStringLiteral("--enabled"), enable ? QStringLiteral("true") : QStringLiteral("false")},
                   QStringLiteral("Updating automount…"),
                   enable ? QStringLiteral("Automount on for %1").arg(mount.mount)
                          : QStringLiteral("Automount off for %1").arg(mount.mount),
                   QStringLiteral("Automount Not Changed"),
                   QStringLiteral("The automount setting was not changed."));
    }

    void changeLetter(const MountView& mount, QWidget* parent) {
        const QStringList letters = freeDriveLetters(mount.mount);
        if (letters.isEmpty()) {
            QMessageBox::warning(parent, QStringLiteral("Change Drive Letter"),
                                 QStringLiteral("No drive letters are free."));
            return;
        }
        bool ok = false;
        const int current = static_cast<int>(std::max<qsizetype>(0, letters.indexOf(mount.mount.toUpper())));
        const QString chosen = QInputDialog::getItem(
            parent, QStringLiteral("Change Drive Letter"),
            QStringLiteral("Drive letter for %1:").arg(displayName(mount)), letters, current, false, &ok);
        if (!ok || chosen.isEmpty() || chosen.compare(mount.mount, Qt::CaseInsensitive) == 0) {
            return;
        }
        runCommand(parent,
                   {QStringLiteral("--set-mount"), QStringLiteral("--target"), mount.target,
                    QStringLiteral("--mount"), chosen},
                   QStringLiteral("Changing drive letter…"),
                   QStringLiteral("Volume moved to %1").arg(chosen),
                   QStringLiteral("Drive Letter Not Changed"),
                   QStringLiteral("The drive letter was not changed."));
    }

private:
    static bool confirm(QWidget* parent, const QString& title, const QString& text) {
        return QMessageBox::question(parent, title, text, QMessageBox::Yes | QMessageBox::No,
                                     QMessageBox::No) == QMessageBox::Yes;
    }

    void runCommand(QWidget* parent,
                    const QStringList& args,
                    const QString& progress,
                    const QString& success,
                    const QString& failureTitle,
                    const QString& failureFallback,
                    std::function<bool(const QJsonObject&)> extraCheck = {}) {
        ++commandsInFlight_;
        status(progress);
        notifyListeners();
        QPointer<QWidget> owner(parent);
        client_->run(args, [this, owner, success, failureTitle, failureFallback,
                            extraCheck = std::move(extraCheck)](const QJsonObject& result, int code) {
            --commandsInFlight_;
            const bool ok = code == 0 && (!extraCheck || extraCheck(result));
            if (ok) {
                status(success);
            } else {
                status(failureTitle);
                QMessageBox::warning(owner.data(), failureTitle, errorTextFrom(result, failureFallback));
            }
            refresh();
            notifyListeners();
        });
    }

    void applyHealth(HealthSnapshot next) {
        if (snapshot_.received) {
            announceChanges(snapshot_, next);
        }
        snapshot_ = std::move(next);
        settlePendingEjects();
        notifyListeners();
    }

    // The service acknowledges an eject before its worker has flushed and
    // released the volume; tell the user it is safe only once it is gone.
    void settlePendingEjects() {
        const qint64 now = QDateTime::currentMSecsSinceEpoch();
        for (auto it = pendingEjects_.begin(); it != pendingEjects_.end();) {
            const MountView* mount = snapshot_.findByTarget(it.key());
            const QString letter = pendingEjectLetters_.value(it.key());
            if (snapshot_.commandOk && (!mount || !mount->mounted())) {
                status(QStringLiteral("%1 unmounted. It is safe to disconnect the device.").arg(letter));
                if (notifier_) {
                    notifier_(QStringLiteral("Safe to disconnect"),
                              QStringLiteral("%1 is unmounted. You can disconnect the device.").arg(letter),
                              QSystemTrayIcon::Information);
                }
                pendingEjectLetters_.remove(it.key());
                it = pendingEjects_.erase(it);
            } else if (now > it.value()) {
                status(QStringLiteral("%1 is still busy").arg(letter));
                if (notifier_) {
                    notifier_(QStringLiteral("Volume still in use"),
                              QStringLiteral("%1 has not finished unmounting. Do not disconnect it yet; close any "
                                             "open files and try again.")
                                  .arg(letter),
                              QSystemTrayIcon::Warning);
                }
                pendingEjectLetters_.remove(it.key());
                it = pendingEjects_.erase(it);
            } else {
                ++it;
            }
        }
    }

    void announceChanges(const HealthSnapshot& before, const HealthSnapshot& after) {
        if (!notifier_ || !notificationsEnabled()) {
            return;
        }
        if (before.serviceRunning() && !after.serviceRunning()) {
            notifier_(QStringLiteral("APFS service stopped"),
                      QStringLiteral("APFS volumes are unavailable until the service restarts."),
                      QSystemTrayIcon::Critical);
        } else if (!before.serviceRunning() && after.serviceRunning() && before.serviceInstalled) {
            notifier_(QStringLiteral("APFS service running"), serviceStatusText(after),
                      QSystemTrayIcon::Information);
        }
        for (const MountView& mount : after.mounts) {
            const MountView* old = before.findByTarget(mount.target);
            const bool wasMounted = old && old->mounted();
            if (mount.mounted() && !wasMounted) {
                notifier_(QStringLiteral("APFS volume mounted"),
                          QStringLiteral("%1 is ready (%2).").arg(displayName(mount), modeText(mount).toLower()),
                          QSystemTrayIcon::Information);
            } else if (!mount.mounted() && wasMounted && after.serviceRunning() &&
                       !pendingEjects_.contains(mount.target)) {
                notifier_(QStringLiteral("APFS volume removed"),
                          QStringLiteral("%1 is no longer mounted.").arg(displayName(*old)),
                          QSystemTrayIcon::Information);
            }
            if (mount.enabled && mount.collision && !(old && old->collision)) {
                notifier_(QStringLiteral("Drive letter in use"),
                          QStringLiteral("%1 cannot mount at %2 because the letter is taken. Choose another "
                                         "letter in APFS for Windows.")
                              .arg(mount.label.isEmpty() ? QStringLiteral("An APFS volume") : mount.label,
                                   mount.mount),
                          QSystemTrayIcon::Warning);
            }
        }
        for (const MountView& old : before.mounts) {
            if (old.mounted() && !after.findByTarget(old.target) && after.serviceRunning()) {
                notifier_(QStringLiteral("APFS volume removed"),
                          QStringLiteral("%1 is no longer mounted.").arg(displayName(old)),
                          QSystemTrayIcon::Information);
            }
        }
    }

    void status(const QString& text) {
        if (statusSink_) {
            statusSink_(text);
        }
    }

    void notifyListeners() {
        for (const Listener& listener : listeners_) {
            listener();
        }
    }

    ServiceClient* client_;
    QTimer pollTimer_;
    QTimer ejectTimer_;
    QHash<QString, qint64> pendingEjects_;
    QHash<QString, QString> pendingEjectLetters_;
    HealthSnapshot snapshot_;
    int commandsInFlight_{0};
    QList<Listener> listeners_;
    std::function<void(const QString&, const QString&, QSystemTrayIcon::MessageIcon)> notifier_;
    std::function<void(const QString&)> statusSink_;
};

// ---------------------------------------------------------------------------
// About dialog
// ---------------------------------------------------------------------------

void showAbout(QWidget* parent) {
    QMessageBox box(parent);
    box.setWindowTitle(QStringLiteral("About %1").arg(QString::fromLatin1(kProductName)));
    box.setIconPixmap(renderMark(64, HealthState::Unknown));
    box.setTextFormat(Qt::RichText);
    box.setText(QStringLiteral("<b>%1</b><br>Version %2").arg(QString::fromLatin1(kProductName),
                                                              QStringLiteral(APFS_PROJECT_VERSION)));
    box.setInformativeText(
        QStringLiteral("Native APFS volumes in Windows Explorer.<br><br>"
                       "Copyright &copy; 2026 Randy Northrup.<br>"
                       "Licensed under the GNU Affero General Public License v3 or later.<br>"
                       "Uses WinFsp, Qt, and LZFSE; see THIRD_PARTY_LICENSES.md.<br><br>"
                       "<a href=\"%1\">%1</a>")
            .arg(QString::fromLatin1(kProjectUrl)));
    box.setStandardButtons(QMessageBox::Ok);
    box.exec();
}

// ---------------------------------------------------------------------------
// Window
// ---------------------------------------------------------------------------

class MountManagerWindow final : public QMainWindow {
public:
    explicit MountManagerWindow(Controller* controller) : controller_(controller) {
        setWindowTitle(QString::fromLatin1(kProductName));
        setMinimumSize(780, 440);

        auto* central = new QWidget(this);
        auto* layout = new QVBoxLayout(central);
        layout->setContentsMargins(12, 12, 12, 12);
        layout->setSpacing(8);

        auto* header = new QHBoxLayout;
        stateIcon_ = new QLabel(central);
        stateIcon_->setFixedSize(32, 32);
        header->addWidget(stateIcon_);
        auto* titleColumn = new QVBoxLayout;
        auto* title = new QLabel(QStringLiteral("APFS Volumes"), central);
        title->setObjectName(QStringLiteral("titleLabel"));
        QFont titleFont = title->font();
        titleFont.setPointSize(titleFont.pointSize() + 3);
        titleFont.setBold(true);
        title->setFont(titleFont);
        title->setAccessibleName(QStringLiteral("Mounted APFS volumes"));
        serviceLabel_ = new QLabel(central);
        serviceLabel_->setAccessibleName(QStringLiteral("Service status"));
        titleColumn->addWidget(title);
        titleColumn->addWidget(serviceLabel_);
        header->addLayout(titleColumn, 1);
        layout->addLayout(header);

        splitter_ = new QSplitter(Qt::Vertical, central);
        splitter_->setChildrenCollapsible(true);
        table_ = new QTableWidget(splitter_);
        table_->setColumnCount(6);
        table_->setHorizontalHeaderLabels({QStringLiteral("Drive"), QStringLiteral("Volume"),
                                           QStringLiteral("Access"), QStringLiteral("Status"),
                                           QStringLiteral("Automount"), QStringLiteral("Device")});
        table_->setSelectionBehavior(QAbstractItemView::SelectRows);
        table_->setSelectionMode(QAbstractItemView::SingleSelection);
        table_->setEditTriggers(QAbstractItemView::NoEditTriggers);
        table_->setAlternatingRowColors(true);
        table_->verticalHeader()->setVisible(false);
        table_->setAccessibleName(QStringLiteral("APFS mount table"));
        table_->setAccessibleDescription(QStringLiteral("List of configured APFS mounts."));
        table_->setContextMenuPolicy(Qt::CustomContextMenu);
        auto* headerView = table_->horizontalHeader();
        headerView->setStretchLastSection(true);
        for (int col : {0, 2, 3, 4}) {
            headerView->setSectionResizeMode(col, QHeaderView::ResizeToContents);
        }
        headerView->setSectionResizeMode(1, QHeaderView::Stretch);

        detail_ = new QPlainTextEdit(splitter_);
        detail_->setReadOnly(true);
        detail_->setLineWrapMode(QPlainTextEdit::NoWrap);
        detail_->setAccessibleName(QStringLiteral("Service health JSON"));
        detail_->setAccessibleDescription(QStringLiteral("Raw service health response."));
        detail_->setVisible(false);
        splitter_->addWidget(table_);
        splitter_->addWidget(detail_);
        splitter_->setStretchFactor(0, 4);
        splitter_->setStretchFactor(1, 2);
        layout->addWidget(splitter_, 1);

        emptyLabel_ = new QLabel(
            QStringLiteral("No APFS volumes yet. Connect an APFS device; it mounts automatically. "
                           "Use Search for Devices if a connected device does not appear."),
            central);
        emptyLabel_->setWordWrap(true);
        emptyLabel_->setAlignment(Qt::AlignCenter);
        layout->addWidget(emptyLabel_);
        setCentralWidget(central);

        auto* toolbar = addToolBar(QStringLiteral("Mount actions"));
        toolbar->setMovable(false);
        toolbar->setObjectName(QStringLiteral("mountActions"));
        auto makeButton = [&](QStyle::StandardPixmap icon, const QString& text, const QString& accessible) {
            auto* button = new QPushButton(style()->standardIcon(icon), text, toolbar);
            button->setMinimumHeight(32);
            button->setFocusPolicy(Qt::StrongFocus);
            button->setAccessibleName(accessible);
            button->setToolTip(accessible);
            toolbar->addWidget(button);
            return button;
        };
        refreshButton_ = makeButton(QStyle::SP_BrowserReload, QStringLiteral("Refresh"),
                                    QStringLiteral("Refresh mount list"));
        discoverButton_ = makeButton(QStyle::SP_DriveHDIcon, QStringLiteral("Search for Devices"),
                                     QStringLiteral("Discover APFS volumes"));
        openButton_ = makeButton(QStyle::SP_DirOpenIcon, QStringLiteral("Open"),
                                 QStringLiteral("Open selected mount in Explorer"));
        letterButton_ = makeButton(QStyle::SP_DriveHDIcon, QStringLiteral("Drive Letter"),
                                   QStringLiteral("Change selected APFS drive letter"));
        modeButton_ = makeButton(QStyle::SP_DialogApplyButton, QStringLiteral("Read/Write"),
                                 QStringLiteral("Change selected APFS read write mode"));
        policyButton_ = makeButton(QStyle::SP_DialogApplyButton, QStringLiteral("Automount Off"),
                                   QStringLiteral("Enable or disable selected APFS automount"));
        unmountButton_ = makeButton(QStyle::SP_DialogCloseButton, QStringLiteral("Unmount"),
                                    QStringLiteral("Unmount selected APFS volume"));
        toolbar->addSeparator();
        detailsButton_ = makeButton(QStyle::SP_FileDialogDetailedView, QStringLiteral("Diagnostics"),
                                    QStringLiteral("Show or hide service diagnostics"));
        detailsButton_->setCheckable(true);
        copyButton_ = makeButton(QStyle::SP_FileDialogContentsView, QStringLiteral("Copy JSON"),
                                 QStringLiteral("Copy service health JSON"));

        connect(refreshButton_, &QPushButton::clicked, this, [this]() {
            statusBar()->showMessage(QStringLiteral("Refreshing…"));
            controller_->refresh();
        });
        connect(discoverButton_, &QPushButton::clicked, this, [this]() { controller_->discover(this); });
        connect(openButton_, &QPushButton::clicked, this, [this]() { withSelected(&Controller::openMount); });
        connect(letterButton_, &QPushButton::clicked, this,
                [this]() { withSelected(&Controller::changeLetter); });
        connect(modeButton_, &QPushButton::clicked, this,
                [this]() { withSelected(&Controller::toggleReadOnly); });
        connect(policyButton_, &QPushButton::clicked, this,
                [this]() { withSelected(&Controller::toggleAutomount); });
        connect(unmountButton_, &QPushButton::clicked, this, [this]() {
            const MountView* mount = selectedMount();
            withSelected(mount && mount->ejected && mount->enabled ? &Controller::mountNow : &Controller::unmount);
        });
        connect(detailsButton_, &QPushButton::toggled, detail_, &QWidget::setVisible);
        connect(copyButton_, &QPushButton::clicked, this, [this]() {
            QApplication::clipboard()->setText(compactJson(controller_->snapshot().raw));
            statusBar()->showMessage(QStringLiteral("Diagnostics copied"), 3000);
        });
        connect(table_, &QTableWidget::itemSelectionChanged, this, [this]() { updateButtonState(); });
        connect(table_, &QTableWidget::cellDoubleClicked, this,
                [this](int, int) { withSelected(&Controller::openMount); });
        connect(table_, &QWidget::customContextMenuRequested, this, [this](const QPoint& pos) {
            const MountView* mount = selectedMount();
            if (!mount) {
                return;
            }
            QMenu menu(this);
            populateMountMenu(&menu, *mount, controller_, this);
            menu.exec(table_->viewport()->mapToGlobal(pos));
        });

        statusBar()->showMessage(QStringLiteral("Ready"));
        controller_->addListener([this]() { render(); });
        render();
        fitToScreen();
    }

    // Builds the per-volume action set shared by the tray submenu and the
    // table context menu.
    static void populateMountMenu(QMenu* menu, const MountView& mount, Controller* controller, QWidget* parent) {
        const bool busy = controller->commandInFlight();
        QAction* open = menu->addAction(QStringLiteral("Open in Explorer"));
        open->setEnabled(mount.mounted());
        QObject::connect(open, &QAction::triggered, menu, [controller, mount, parent]() {
            controller->openMount(mount, parent);
        });
        menu->addSeparator();
        QAction* writable = menu->addAction(QStringLiteral("Read/write access"));
        writable->setCheckable(true);
        writable->setChecked(!mount.readOnly);
        writable->setEnabled(!busy);
        QObject::connect(writable, &QAction::triggered, menu, [controller, mount, parent]() {
            controller->toggleReadOnly(mount, parent);
        });
        QAction* automount = menu->addAction(QStringLiteral("Mount automatically"));
        automount->setCheckable(true);
        automount->setChecked(mount.enabled);
        automount->setEnabled(!busy);
        QObject::connect(automount, &QAction::triggered, menu, [controller, mount, parent]() {
            controller->toggleAutomount(mount, parent);
        });
        QAction* letter = menu->addAction(QStringLiteral("Change drive letter…"));
        letter->setEnabled(!busy);
        QObject::connect(letter, &QAction::triggered, menu, [controller, mount, parent]() {
            controller->changeLetter(mount, parent);
        });
        menu->addSeparator();
        if (mount.ejected && mount.enabled) {
            QAction* mountAction = menu->addAction(QStringLiteral("Mount"));
            mountAction->setEnabled(!busy);
            QObject::connect(mountAction, &QAction::triggered, menu, [controller, mount, parent]() {
                controller->mountNow(mount, parent);
            });
        } else {
            QAction* unmount = menu->addAction(QStringLiteral("Unmount"));
            unmount->setEnabled(!busy && mount.mounted());
            QObject::connect(unmount, &QAction::triggered, menu, [controller, mount, parent]() {
                controller->unmount(mount, parent);
            });
        }
    }

    QJsonObject selfTestResult(const QIcon& trayIcon, const QMenu& trayMenu, const HealthSnapshot& health) const {
        QJsonArray trayActions;
        bool hasTrayOpenAction = false;
        bool hasTrayExitAction = false;
        for (const QAction* action : trayMenu.actions()) {
            if (!action || action->isSeparator() || action->text().isEmpty()) {
                continue;
            }
            const QString text = action->text();
            trayActions.append(text);
            hasTrayOpenAction = hasTrayOpenAction || text == QStringLiteral("Open");
            hasTrayExitAction = hasTrayExitAction || text == QStringLiteral("Exit");
        }
        bool stateIconsRender = true;
        for (HealthState state :
             {HealthState::Unknown, HealthState::Ok, HealthState::Idle, HealthState::Warning, HealthState::Error}) {
            for (int size : {16, 32}) {
                stateIconsRender = stateIconsRender && !renderMark(size, state).toImage().isNull();
            }
        }
        return QJsonObject{{QStringLiteral("component"), QStringLiteral("apfs_mount_manager")},
                           {QStringLiteral("version"), QStringLiteral(APFS_PROJECT_VERSION)},
                           {QStringLiteral("ui"), QStringLiteral("available")},
                           {QStringLiteral("accessible_table_name"), table_->accessibleName()},
                           {QStringLiteral("mount_rows"), table_->rowCount()},
                           {QStringLiteral("health_ok"), health.commandOk},
                           {QStringLiteral("service_status"), health.serviceStatus},
                           {QStringLiteral("has_refresh_button"), !refreshButton_->accessibleName().isEmpty()},
                           {QStringLiteral("has_discover_button"), !discoverButton_->accessibleName().isEmpty()},
                           {QStringLiteral("has_open_button"), !openButton_->accessibleName().isEmpty()},
                           {QStringLiteral("has_letter_button"), !letterButton_->accessibleName().isEmpty()},
                           {QStringLiteral("has_mode_button"), !modeButton_->accessibleName().isEmpty()},
                           {QStringLiteral("has_policy_button"), !policyButton_->accessibleName().isEmpty()},
                           {QStringLiteral("has_unmount_button"), !unmountButton_->accessibleName().isEmpty()},
                           {QStringLiteral("has_copy_button"), !copyButton_->accessibleName().isEmpty()},
                           {QStringLiteral("tray_icon_available"), !trayIcon.isNull()},
                           {QStringLiteral("tray_state_icons_render"), stateIconsRender},
                           {QStringLiteral("tray_context_actions"), trayActions},
                           {QStringLiteral("has_tray_open_action"), hasTrayOpenAction},
                           {QStringLiteral("has_tray_exit_action"), hasTrayExitAction},
                           {QStringLiteral("instance_channel"), instanceServerName()},
                           {QStringLiteral("quit_on_last_window_closed"), QApplication::quitOnLastWindowClosed()}};
    }

    void showAndActivate() {
        if (isMinimized()) {
            showNormal();
        } else {
            show();
        }
        raise();
        activateWindow();
        controller_->refresh();
    }

    void setStatusMessage(const QString& text) { statusBar()->showMessage(text, 6000); }

private:
    using MountAction = void (Controller::*)(const MountView&, QWidget*);

    void withSelected(MountAction action) {
        const MountView* mount = selectedMount();
        if (!mount) {
            return;
        }
        const MountView copy = *mount;  // The snapshot may change while a dialog is open.
        (controller_->*action)(copy, this);
    }

    void fitToScreen() {
        const QScreen* screen = QGuiApplication::primaryScreen();
        if (!screen) {
            return;
        }
        const QRect available = screen->availableGeometry();
        resize(std::min(std::max(width(), 900), available.width() - 80),
               std::min(std::max(height(), 520), available.height() - 80));
    }

    const MountView* selectedMount() const {
        const int row = table_->currentRow();
        if (row < 0) {
            return nullptr;
        }
        const QTableWidgetItem* item = table_->item(row, 0);
        if (!item) {
            return nullptr;
        }
        return controller_->snapshot().findByTarget(item->data(Qt::UserRole).toString());
    }

    void render() {
        const HealthSnapshot& snapshot = controller_->snapshot();
        stateIcon_->setPixmap(renderMark(32, snapshot.state()));
        serviceLabel_->setText(snapshot.commandOk || !snapshot.received
                                   ? serviceStatusText(snapshot)
                                   : QStringLiteral("%1 — %2").arg(serviceStatusText(snapshot),
                                                                   snapshot.errorText.left(160)));
        detail_->setPlainText(compactJson(snapshot.raw));

        const QString selectedTarget = [this]() {
            const QTableWidgetItem* item = table_->currentRow() >= 0 ? table_->item(table_->currentRow(), 0)
                                                                     : nullptr;
            return item ? item->data(Qt::UserRole).toString() : QString();
        }();
        table_->setRowCount(static_cast<int>(snapshot.mounts.size()));
        int reselect = -1;
        for (int row = 0; row < snapshot.mounts.size(); ++row) {
            const MountView& mount = snapshot.mounts.at(row);
            const QStringList values{mount.mount,
                                     mount.label.isEmpty() ? QStringLiteral("APFS volume") : mount.label,
                                     modeText(mount),
                                     statusText(mount),
                                     mount.enabled ? QStringLiteral("On") : QStringLiteral("Off"),
                                     mount.target};
            for (int col = 0; col < values.size(); ++col) {
                auto* item = new QTableWidgetItem(values.at(col));
                item->setToolTip(values.at(col));
                if (col == 0) {
                    item->setData(Qt::UserRole, mount.target);
                }
                if (col == 3) {
                    if (mount.collision) {
                        item->setForeground(QBrush(QColor(176, 106, 0)));
                    } else if (!mount.mounted()) {
                        item->setForeground(QBrush(palette().color(QPalette::PlaceholderText)));
                    }
                }
                table_->setItem(row, col, item);
            }
            if (mount.target == selectedTarget) {
                reselect = row;
            }
        }
        if (reselect >= 0) {
            table_->selectRow(reselect);
        } else if (!snapshot.mounts.isEmpty() && table_->currentRow() < 0) {
            table_->selectRow(0);
        }
        emptyLabel_->setVisible(snapshot.received && snapshot.mounts.isEmpty());
        if (snapshot.received && !controller_->commandInFlight() &&
            statusBar()->currentMessage() == QStringLiteral("Refreshing…")) {
            statusBar()->showMessage(QStringLiteral("Updated %1").arg(QDateTime::currentDateTime().toString(
                                         QStringLiteral("h:mm:ss AP"))),
                                     4000);
        }
        updateButtonState();
    }

    void updateButtonState() {
        const MountView* mount = selectedMount();
        const bool busy = controller_->commandInFlight();
        const bool hasMount = mount != nullptr;
        discoverButton_->setEnabled(!busy);
        openButton_->setEnabled(hasMount && mount->mounted());
        letterButton_->setEnabled(hasMount && !busy);
        modeButton_->setEnabled(hasMount && !busy);
        modeButton_->setText(hasMount && !mount->readOnly ? QStringLiteral("Make Read-Only")
                                                          : QStringLiteral("Make Read/Write"));
        policyButton_->setEnabled(hasMount && !busy);
        policyButton_->setText(hasMount && !mount->enabled ? QStringLiteral("Turn On Automount")
                                                           : QStringLiteral("Turn Off Automount"));
        const bool ejected = hasMount && mount->ejected && mount->enabled;
        unmountButton_->setText(ejected ? QStringLiteral("Mount") : QStringLiteral("Unmount"));
        unmountButton_->setEnabled(hasMount && !busy && (ejected || mount->mounted()));
        copyButton_->setEnabled(controller_->snapshot().received);
        if (busy) {
            if (!QApplication::overrideCursor()) {
                QApplication::setOverrideCursor(Qt::BusyCursor);
            }
        } else {
            while (QApplication::overrideCursor()) {
                QApplication::restoreOverrideCursor();
            }
        }
    }

    Controller* controller_;
    QLabel* stateIcon_{nullptr};
    QLabel* serviceLabel_{nullptr};
    QLabel* emptyLabel_{nullptr};
    QSplitter* splitter_{nullptr};
    QTableWidget* table_{nullptr};
    QPlainTextEdit* detail_{nullptr};
    QPushButton* refreshButton_{nullptr};
    QPushButton* discoverButton_{nullptr};
    QPushButton* openButton_{nullptr};
    QPushButton* letterButton_{nullptr};
    QPushButton* modeButton_{nullptr};
    QPushButton* policyButton_{nullptr};
    QPushButton* unmountButton_{nullptr};
    QPushButton* detailsButton_{nullptr};
    QPushButton* copyButton_{nullptr};
};

// ---------------------------------------------------------------------------
// Tray
// ---------------------------------------------------------------------------

class TrayController final : public QObject {
public:
    TrayController(Controller* controller, MountManagerWindow* window, QApplication* app)
        : controller_(controller), window_(window), app_(app), icon_(this) {
        for (HealthState state :
             {HealthState::Unknown, HealthState::Ok, HealthState::Idle, HealthState::Warning, HealthState::Error}) {
            icons_.insert(static_cast<int>(state), stackedApfsIcon(state));
        }
        icon_.setIcon(icons_.value(static_cast<int>(HealthState::Unknown)));
        icon_.setToolTip(QString::fromLatin1(kProductName));
        rebuildMenu();
        icon_.setContextMenu(&menu_);

        connect(&menu_, &QMenu::aboutToShow, this, [this]() {
            rebuildMenu();
            controller_->refresh();
        });
        connect(&icon_, &QSystemTrayIcon::activated, this, [this](QSystemTrayIcon::ActivationReason reason) {
            if (reason == QSystemTrayIcon::Trigger || reason == QSystemTrayIcon::DoubleClick) {
                window_->showAndActivate();
            }
        });
        connect(&icon_, &QSystemTrayIcon::messageClicked, this, [this]() { window_->showAndActivate(); });
        controller_->addListener([this]() { render(); });
        controller_->setNotifier([this](const QString& title, const QString& body,
                                        QSystemTrayIcon::MessageIcon level) {
            if (QSystemTrayIcon::supportsMessages() && icon_.isVisible()) {
                icon_.showMessage(title, body, level, kNotificationDurationMs);
            }
        });
    }

    void show() { icon_.show(); }
    QIcon currentIcon() const { return icons_.value(static_cast<int>(HealthState::Unknown)); }
    QMenu& menu() { return menu_; }

private:
    void render() {
        const HealthSnapshot& snapshot = controller_->snapshot();
        icon_.setIcon(icons_.value(static_cast<int>(snapshot.state())));
        icon_.setToolTip(trayToolTip(snapshot));
        if (!menu_.isVisible()) {
            rebuildMenu();
        }
    }

    // A menu action that opened a dialog is still on the stack while the dialog
    // runs its own event loop; rebuilding then would delete that action.
    static bool menuRebuildSafe() { return QApplication::activeModalWidget() == nullptr; }

    // Actions may be rebuilt while one of them is still running its slot (a
    // modal dialog opened from the menu spins a nested event loop), so old
    // actions and submenus are detached and deleted later, never in place.
    void rebuildMenu() {
        if (!menuRebuildSafe()) {
            return;
        }
        for (QAction* action : menu_.actions()) {
            menu_.removeAction(action);
            if (QMenu* sub = action->menu()) {
                sub->deleteLater();
            } else if (action->parent() == &menu_) {
                action->deleteLater();
            }
        }
        const HealthSnapshot& snapshot = controller_->snapshot();

        QAction* status = menu_.addAction(serviceStatusText(snapshot));
        status->setEnabled(false);
        menu_.addSeparator();

        int shown = 0;
        for (const MountView& mount : snapshot.mounts) {
            QMenu* sub = menu_.addMenu(QStringLiteral("%1 — %2").arg(displayName(mount), statusText(mount)));
            sub->setIcon(window_->style()->standardIcon(mount.mounted() ? QStyle::SP_DriveHDIcon
                                                                         : QStyle::SP_DriveCDIcon));
            MountManagerWindow::populateMountMenu(sub, mount, controller_, window_);
            ++shown;
        }
        if (shown == 0) {
            QAction* none = menu_.addAction(snapshot.received ? QStringLiteral("No APFS volumes")
                                                              : QStringLiteral("Loading…"));
            none->setEnabled(false);
        }
        QAction* discover = menu_.addAction(QStringLiteral("Search for APFS devices"));
        discover->setEnabled(!controller_->commandInFlight());
        connect(discover, &QAction::triggered, this, [this]() { controller_->discover(nullptr); });
        menu_.addSeparator();

        QAction* open = menu_.addAction(QStringLiteral("Open"));
        QFont bold = open->font();
        bold.setBold(true);
        open->setFont(bold);
        connect(open, &QAction::triggered, this, [this]() { window_->showAndActivate(); });

        QMenu* settings = menu_.addMenu(QStringLiteral("Settings"));
        QAction* startup = settings->addAction(QStringLiteral("Start at sign-in"));
        startup->setCheckable(true);
        startup->setChecked(startAtSignInEnabled());
        connect(startup, &QAction::toggled, this, [](bool on) { setStartAtSignIn(on); });
        QAction* notify = settings->addAction(QStringLiteral("Show notifications"));
        notify->setCheckable(true);
        notify->setChecked(notificationsEnabled());
        connect(notify, &QAction::toggled, this, [](bool on) { setNotificationsEnabled(on); });

        QAction* logs = menu_.addAction(QStringLiteral("View logs"));
        connect(logs, &QAction::triggered, this, []() {
            QDesktopServices::openUrl(QUrl::fromLocalFile(serviceLogDir()));
        });
        QAction* about = menu_.addAction(QStringLiteral("About %1").arg(QString::fromLatin1(kProductName)));
        connect(about, &QAction::triggered, this, [this]() { showAbout(window_->isVisible() ? window_ : nullptr); });
        menu_.addSeparator();

        QAction* exit = menu_.addAction(QStringLiteral("Exit"));
        exit->setToolTip(QStringLiteral("Close the tray icon. Mounted volumes stay available."));
        connect(exit, &QAction::triggered, this, [this]() {
            icon_.hide();
            app_->quit();
        });
    }

    Controller* controller_;
    MountManagerWindow* window_;
    QApplication* app_;
    QSystemTrayIcon icon_;
    QMenu menu_;
    QHash<int, QIcon> icons_;
};

}  // namespace

int main(int argc, char* argv[]) {
    QStringList rawArgs;
    for (int i = 1; i < argc; ++i) {
        rawArgs.append(QString::fromLocal8Bit(argv[i]));
    }
    const auto hasArg = [&rawArgs](const char* name) {
        return rawArgs.contains(QLatin1String(name), Qt::CaseInsensitive);
    };
    const bool cliMode = hasArg("--help") || hasArg("-h") || hasArg("/?") || hasArg("--status") ||
                         hasArg("--self-test") || hasArg("--version");
    if (cliMode) {
        attachParentConsoleIfNeeded();
    }
    if (hasArg("--help") || hasArg("-h") || hasArg("/?")) {
        QCoreApplication app(argc, argv);
        printUsage();
        return 0;
    }
    if (hasArg("--version")) {
        QTextStream(stdout) << kProductName << ' ' << APFS_PROJECT_VERSION << '\n';
        return 0;
    }
    if (hasArg("--status")) {
        QCoreApplication app(argc, argv);
        int exitCode = 0;
        const QJsonObject health = runServiceCommandSync({QStringLiteral("--health")}, &exitCode);
        printJson({{QStringLiteral("component"), QStringLiteral("apfs_mount_manager")},
                   {QStringLiteral("version"), QStringLiteral(APFS_PROJECT_VERSION)},
                   {QStringLiteral("ui"), QStringLiteral("available")},
                   {QStringLiteral("service_exe"), serviceExePath()},
                   {QStringLiteral("health"), health}});
        return exitCode == 0 ? 0 : 1;
    }

    QApplication app(argc, argv);
    QApplication::setApplicationName(QString::fromLatin1(kProductName));
    QApplication::setApplicationDisplayName(QString::fromLatin1(kProductName));
    QApplication::setApplicationVersion(QStringLiteral(APFS_PROJECT_VERSION));
    QApplication::setOrganizationName(QString::fromLatin1(kProductName));
    QApplication::setQuitOnLastWindowClosed(false);
    QApplication::setWindowIcon(stackedApfsIcon());

    Controller controller(&app);
    MountManagerWindow window(&controller);
    TrayController tray(&controller, &window, &app);

    if (hasArg("--self-test")) {
        int exitCode = 0;
        const HealthSnapshot health =
            snapshotFromJson(runServiceCommandSync({QStringLiteral("--health")}, &exitCode));
        const QJsonObject result = window.selfTestResult(tray.currentIcon(), tray.menu(), health);
        printJson(result);
        return result.value(QStringLiteral("health_ok")).toBool(false) &&
                       result.value(QStringLiteral("tray_state_icons_render")).toBool(false)
                   ? 0
                   : 1;
    }

    if (hasArg("--tray") && !startAtSignInEnabled()) {
        return 0;  // This user turned off "Start at sign-in".
    }

    const QString channel = instanceServerName();
    {
        QLocalSocket existingInstance;
        existingInstance.connectToServer(channel);
        if (existingInstance.waitForConnected(kInstancePingTimeoutMs)) {
            existingInstance.write(hasArg("--tray") ? "ping" : "show");
            existingInstance.flush();
            existingInstance.waitForBytesWritten(kInstancePingTimeoutMs);
            return 0;
        }
    }

    QLocalServer instanceServer;
    instanceServer.setSocketOptions(QLocalServer::UserAccessOption);
    if (!instanceServer.listen(channel)) {
        QLocalServer::removeServer(channel);
        if (!instanceServer.listen(channel)) {
            QMessageBox::critical(nullptr, QString::fromLatin1(kProductName),
                                  QStringLiteral("Unable to start the mount manager instance."));
            return 1;
        }
    }
    QObject::connect(&instanceServer, &QLocalServer::newConnection, &app, [&instanceServer, &window]() {
        while (instanceServer.hasPendingConnections()) {
            QLocalSocket* socket = instanceServer.nextPendingConnection();
            QObject::connect(socket, &QLocalSocket::disconnected, socket, &QObject::deleteLater);
            auto handle = [socket, &window]() {
                const QByteArray command = socket->readAll().trimmed();
                if (command.isEmpty()) {
                    return;
                }
                socket->disconnectFromServer();
                if (command == QByteArrayLiteral("show")) {
                    window.showAndActivate();
                }
            };
            QObject::connect(socket, &QLocalSocket::readyRead, socket, handle);
            if (socket->bytesAvailable() > 0) {
                handle();
            }
        }
    });

    controller.setStatusSink([&window](const QString& text) { window.setStatusMessage(text); });
    tray.show();
    controller.start();

    if (!hasArg("--tray")) {
        window.showAndActivate();
    }
    return app.exec();
}
