// Copyright (c) 2026 Randy Northrup. All rights reserved.

#include "sak/partition_apfs_file_system_reader.h"
#include "sak/partition_file_system_detector.h"
#include "sak/partition_raw_device_io.h"

#include <QCoreApplication>
#include <QBuffer>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QIODevice>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLocalServer>
#include <QLocalSocket>
#include <QProcess>
#include <QProcessEnvironment>
#include <QSet>
#include <QStringList>
#include <QTemporaryDir>
#include <QTextStream>

#ifdef Q_OS_WIN
#include <windows.h>
#include <dbt.h>
#include <winioctl.h>

#include <algorithm>
#include <array>
#include <chrono>
#include <cstdint>
#include <future>
#include <memory>
#include <mutex>
#include <optional>
#include <thread>
#include <vector>
#endif

namespace {

constexpr wchar_t kServiceName[] = L"ApfsForWindowsMountService";
constexpr wchar_t kDisplayName[] = L"APFS for Windows Mount Service";
constexpr int kDefaultMaxPhysicalDrives = 32;
constexpr DWORD kServiceWaitSliceMs = 1000;
constexpr qint64 kServiceSyncIntervalMs = 5000;
constexpr int kControlSocketTimeoutMs = 3000;
constexpr qint64 kMaxLogBytes = 8LL * 1024LL * 1024LL;
constexpr quint64 kSectorBytes = 512;
constexpr quint64 kFallbackProbeBytes = 1024ULL * 1024ULL * 1024ULL;
constexpr char kGptSignature[] = "EFI PART";
constexpr char kApfsGptTypeGuid[] = "{7c3457ef-0000-11aa-aa11-00306543ecac}";
constexpr char kLocalControlServerName[] = "ApfsForWindowsMountService.Control";

void printJson(const QJsonObject& object) {
    QTextStream(stdout) << QJsonDocument(object).toJson(QJsonDocument::Indented);
}

#ifdef Q_OS_WIN
SERVICE_STATUS_HANDLE g_statusHandle = nullptr;
SERVICE_STATUS g_status{};
HANDLE g_stopEvent = nullptr;
HANDLE g_resyncEvent = nullptr;
HDEVNOTIFY g_deviceNotification = nullptr;
std::mutex g_configMutex;
std::mutex g_logMutex;
std::once_flag g_logPruneOnce;

constexpr GUID kDiskDeviceInterfaceGuid = {0x53f56307,
                                           0xb6bf,
                                           0x11d0,
                                           {0x94, 0xf2, 0x00, 0xa0, 0xc9, 0x1e, 0xfb, 0x8b}};
constexpr DWORD kDeviceChangeSettleMs = 750;

struct MountConfig {
    QString target;
    QString mount;
    bool read_only{true};
    bool allow_raw_writes{false};
    bool enabled{true};
};

struct WorkerHandle {
    MountConfig config;
    std::unique_ptr<QProcess> process;
    QDateTime last_start_attempt_utc;
    int start_count{0};
    int failed_start_count{0};
};

struct PartitionCandidate {
    int index{0};
    QString scheme;
    QString type_guid;
    uint8_t mbr_type{0};
    QString unique_guid;
    QString name;
    uint64_t offset_bytes{0};
    uint64_t size_bytes{0};
};

struct DiscoveredApfsVolume {
    int disk_index{0};
    QString target;
    QString kind;
    PartitionCandidate partition;
    sak::PartitionFileSystemDetection detection;
    QJsonArray root_entries;
};

struct DiscoveryScan {
    QJsonArray disks;
    QVector<DiscoveredApfsVolume> volumes;
};

void processControlServer(QLocalServer* server);

QString winError(DWORD code) {
    LPWSTR buffer = nullptr;
    const DWORD length = FormatMessageW(FORMAT_MESSAGE_ALLOCATE_BUFFER |
                                            FORMAT_MESSAGE_FROM_SYSTEM |
                                            FORMAT_MESSAGE_IGNORE_INSERTS,
                                        nullptr,
                                        code,
                                        MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT),
                                        reinterpret_cast<LPWSTR>(&buffer),
                                        0,
                                        nullptr);
    QString text;
    if (length > 0 && buffer) {
        text = QString::fromWCharArray(buffer, static_cast<int>(length)).trimmed();
    }
    if (buffer) {
        LocalFree(buffer);
    }
    return text.isEmpty() ? QStringLiteral("Win32 error %1").arg(code) : text;
}

QString executablePath() {
    std::array<wchar_t, 32768> buffer{};
    const DWORD length = GetModuleFileNameW(nullptr, buffer.data(), static_cast<DWORD>(buffer.size()));
    if (length == 0 || length >= buffer.size()) {
        return {};
    }
    return QString::fromWCharArray(buffer.data(), static_cast<int>(length));
}

QString programDataRoot() {
    const QString overrideRoot = qEnvironmentVariable("APFS_FOR_WINDOWS_PROGRAMDATA_ROOT").trimmed();
    if (!overrideRoot.isEmpty()) {
        return overrideRoot;
    }
    const QString base = qEnvironmentVariable("ProgramData", QStringLiteral("C:\\ProgramData"));
    return QDir(base).filePath(QStringLiteral("APFS for Windows"));
}

QString configPath() {
    return QDir(programDataRoot()).filePath(QStringLiteral("mounts.json"));
}

QString logDir() {
    return QDir(programDataRoot()).filePath(QStringLiteral("logs"));
}

void rotateLogIfNeeded(const QString& path) {
    const QFileInfo info(path);
    if (!info.exists() || info.size() < kMaxLogBytes) {
        return;
    }

    const QString archivePath = path + QStringLiteral(".1");
    QFile::remove(archivePath);
    if (info.size() > kMaxLogBytes * 2) {
        QFile::remove(path);
        return;
    }
    QFile::rename(path, archivePath);
}

void pruneLegacyOversizedLogs() {
    QDir directory(logDir());
    const QFileInfoList files = directory.entryInfoList(
        {QStringLiteral("*.log"), QStringLiteral("*.trace.txt")}, QDir::Files);
    for (const QFileInfo& info : files) {
        rotateLogIfNeeded(info.absoluteFilePath());
    }
}

void appendServiceLog(const QString& message) {
    QDir().mkpath(logDir());
    std::scoped_lock lock(g_logMutex);
    std::call_once(g_logPruneOnce, pruneLegacyOversizedLogs);
    const QString path = QDir(logDir()).filePath(QStringLiteral("apfs_mount_service.log"));
    rotateLogIfNeeded(path);
    QFile file(path);
    if (!file.open(QIODevice::WriteOnly | QIODevice::Append | QIODevice::Text)) {
        return;
    }
    QTextStream(&file) << QDateTime::currentDateTimeUtc().toString(Qt::ISODateWithMs) << " "
                       << message << Qt::endl;
}

QVector<MountConfig> readMountConfig(QString* error = nullptr) {
    std::scoped_lock lock(g_configMutex);
    QVector<MountConfig> mounts;
    QFile file(configPath());
    if (!file.exists()) {
        return mounts;
    }
    if (!file.open(QIODevice::ReadOnly)) {
        if (error) {
            *error = QStringLiteral("Unable to open %1").arg(configPath());
        }
        return mounts;
    }
    QJsonParseError parseError{};
    const QJsonDocument document = QJsonDocument::fromJson(file.readAll(), &parseError);
    if (parseError.error != QJsonParseError::NoError || !document.isObject()) {
        if (error) {
            *error = QStringLiteral("Invalid mount config: %1").arg(parseError.errorString());
        }
        return mounts;
    }
    const QJsonArray array = document.object().value(QStringLiteral("mounts")).toArray();
    for (const auto& value : array) {
        const QJsonObject object = value.toObject();
        MountConfig config{.target = object.value(QStringLiteral("target")).toString().trimmed(),
                           .mount = object.value(QStringLiteral("mount")).toString().trimmed(),
                           .read_only = object.value(QStringLiteral("read_only")).toBool(true),
                           .allow_raw_writes =
                               object.value(QStringLiteral("allow_raw_writes")).toBool(false),
                           .enabled = object.value(QStringLiteral("enabled")).toBool(true)};
        if (!config.target.isEmpty() && !config.mount.isEmpty()) {
            mounts.append(config);
        }
    }
    return mounts;
}

QJsonObject mountConfigJson(const MountConfig& mount) {
    return QJsonObject{{QStringLiteral("target"), mount.target},
                       {QStringLiteral("mount"), mount.mount},
                       {QStringLiteral("read_only"), mount.read_only},
                       {QStringLiteral("allow_raw_writes"), mount.allow_raw_writes},
                       {QStringLiteral("enabled"), mount.enabled}};
}

bool writeMountConfig(const QVector<MountConfig>& mounts, QString* error = nullptr) {
    std::scoped_lock lock(g_configMutex);
    QDir().mkpath(programDataRoot());
    QJsonArray array;
    for (const auto& mount : mounts) {
        array.append(mountConfigJson(mount));
    }
    QFile file(configPath());
    if (!file.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
        if (error) {
            *error = QStringLiteral("Unable to write %1").arg(configPath());
        }
        return false;
    }
    file.write(QJsonDocument(QJsonObject{{QStringLiteral("mounts"), array}}).toJson(QJsonDocument::Indented));
    return true;
}

QString argumentValue(const QStringList& args, const QString& name) {
    const int index = args.indexOf(name);
    if (index >= 0 && index + 1 < args.size()) {
        return args.at(index + 1);
    }
    return {};
}

int argumentIntValue(const QStringList& args, const QString& name, int fallback) {
    bool ok = false;
    const int value = argumentValue(args, name).toInt(&ok);
    return ok ? value : fallback;
}

quint16 le16(const QByteArray& bytes, qsizetype offset) {
    const auto* p = reinterpret_cast<const uchar*>(bytes.constData() + offset);
    return static_cast<quint16>(p[0] | (p[1] << 8));
}

quint32 le32(const QByteArray& bytes, qsizetype offset) {
    const auto* p = reinterpret_cast<const uchar*>(bytes.constData() + offset);
    return static_cast<quint32>(p[0] | (p[1] << 8) | (p[2] << 16) | (p[3] << 24));
}

quint64 le64(const QByteArray& bytes, qsizetype offset) {
    quint64 value = 0;
    for (int i = 7; i >= 0; --i) {
        value = (value << 8) | static_cast<uchar>(bytes.at(offset + i));
    }
    return value;
}

QByteArray readAt(QIODevice* device, quint64 offset, qsizetype length) {
    if (!device || !device->seek(static_cast<qint64>(offset))) {
        return {};
    }
    return device->read(length);
}

QString guidString(const QByteArray& entry, qsizetype offset) {
    if (entry.size() < offset + 16) {
        return {};
    }
    const quint32 d1 = le32(entry, offset);
    const quint16 d2 = le16(entry, offset + 4);
    const quint16 d3 = le16(entry, offset + 6);
    QString tail;
    for (int i = 8; i < 16; ++i) {
        tail += QStringLiteral("%1").arg(static_cast<uchar>(entry.at(offset + i)),
                                         2,
                                         16,
                                         QLatin1Char('0'));
    }
    return QStringLiteral("{%1-%2-%3-%4-%5}")
        .arg(d1, 8, 16, QLatin1Char('0'))
        .arg(d2, 4, 16, QLatin1Char('0'))
        .arg(d3, 4, 16, QLatin1Char('0'))
        .arg(tail.left(4), tail.mid(4));
}

bool isZeroGuid(const QString& guid) {
    return guid.compare(QStringLiteral("{00000000-0000-0000-0000-000000000000}"),
                        Qt::CaseInsensitive) == 0;
}

QString utf16Name(const QByteArray& entry, qsizetype offset, qsizetype bytes) {
    QString out;
    for (qsizetype i = 0; i + 1 < bytes; i += 2) {
        const quint16 ch = le16(entry, offset + i);
        if (ch == 0) {
            break;
        }
        out.append(QChar(ch));
    }
    return out.trimmed();
}

QVector<PartitionCandidate> readGpt(QIODevice* device) {
    QVector<PartitionCandidate> partitions;
    const QByteArray header = readAt(device, kSectorBytes, 512);
    if (header.size() < 92 || header.left(8) != QByteArray(kGptSignature, 8)) {
        return partitions;
    }

    const quint64 entryLba = le64(header, 72);
    const quint32 entryCount = le32(header, 80);
    const quint32 entrySize = le32(header, 84);
    if (entryLba == 0 || entryCount == 0 || entrySize < 128 || entrySize > 4096) {
        return partitions;
    }

    const quint64 tableOffset = entryLba * kSectorBytes;
    const quint64 tableBytes = static_cast<quint64>(entryCount) * entrySize;
    if (tableBytes > 16ULL * 1024ULL * 1024ULL) {
        return partitions;
    }

    const QByteArray table = readAt(device, tableOffset, static_cast<qsizetype>(tableBytes));
    if (static_cast<quint64>(table.size()) < tableBytes) {
        return partitions;
    }

    for (quint32 i = 0; i < entryCount; ++i) {
        const qsizetype base = static_cast<qsizetype>(i * entrySize);
        const QByteArray entry = table.mid(base, static_cast<qsizetype>(entrySize));
        const QString typeGuid = guidString(entry, 0);
        if (typeGuid.isEmpty() || isZeroGuid(typeGuid)) {
            continue;
        }
        const quint64 firstLba = le64(entry, 32);
        const quint64 lastLba = le64(entry, 40);
        if (lastLba < firstLba) {
            continue;
        }
        partitions.append(PartitionCandidate{.index = static_cast<int>(i + 1),
                                             .scheme = QStringLiteral("GPT"),
                                             .type_guid = typeGuid,
                                             .unique_guid = guidString(entry, 16),
                                             .name = utf16Name(entry, 56, 72),
                                             .offset_bytes = firstLba * kSectorBytes,
                                             .size_bytes = (lastLba - firstLba + 1) *
                                                           kSectorBytes});
    }
    return partitions;
}

QVector<PartitionCandidate> readMbr(QIODevice* device) {
    QVector<PartitionCandidate> partitions;
    const QByteArray sector = readAt(device, 0, static_cast<qsizetype>(kSectorBytes));
    if (sector.size() < static_cast<qsizetype>(kSectorBytes) ||
        static_cast<uchar>(sector.at(510)) != 0x55 ||
        static_cast<uchar>(sector.at(511)) != 0xaa) {
        return partitions;
    }

    constexpr qsizetype kPartitionTableOffset = 446;
    constexpr qsizetype kPartitionEntryBytes = 16;
    for (int i = 0; i < 4; ++i) {
        const qsizetype base = kPartitionTableOffset + i * kPartitionEntryBytes;
        const uint8_t type = static_cast<uint8_t>(sector.at(base + 4));
        const quint32 firstLba = le32(sector, base + 8);
        const quint32 sectorCount = le32(sector, base + 12);
        if (type == 0 || type == 0xee || sectorCount == 0) {
            continue;
        }

        const quint64 offsetBytes = static_cast<quint64>(firstLba) * kSectorBytes;
        const quint64 sizeBytes = static_cast<quint64>(sectorCount) * kSectorBytes;
        const qint64 deviceBytes = device ? device->size() : 0;
        if (deviceBytes > 0 &&
            (offsetBytes >= static_cast<quint64>(deviceBytes) ||
             sizeBytes > static_cast<quint64>(deviceBytes) - offsetBytes)) {
            continue;
        }

        partitions.append(PartitionCandidate{.index = i + 1,
                                             .scheme = QStringLiteral("MBR"),
                                             .mbr_type = type,
                                             .offset_bytes = offsetBytes,
                                             .size_bytes = sizeBytes});
    }
    return partitions;
}

QVector<PartitionCandidate> readPartitions(QIODevice* device) {
    QVector<PartitionCandidate> partitions = readGpt(device);
    if (!partitions.isEmpty()) {
        return partitions;
    }
    return readMbr(device);
}

class WindowDevice final : public QIODevice {
public:
    WindowDevice(QIODevice* base, uint64_t offset, uint64_t size)
        : base_(base), offset_(offset), size_(size) {}

    bool open(OpenMode mode) override {
        if ((mode & WriteOnly) != 0 || !base_) {
            return false;
        }
        position_ = 0;
        return QIODevice::open(ReadOnly);
    }

    bool isSequential() const override { return false; }
    qint64 size() const override { return static_cast<qint64>(size_); }
    qint64 pos() const override { return static_cast<qint64>(position_); }

    bool seek(qint64 pos) override {
        if (pos < 0 || static_cast<uint64_t>(pos) > size_) {
            return false;
        }
        position_ = static_cast<uint64_t>(pos);
        return QIODevice::seek(pos);
    }

protected:
    qint64 readData(char* data, qint64 maxSize) override {
        if (!base_ || !data || maxSize < 0 || position_ >= size_) {
            return -1;
        }
        const auto available = static_cast<qint64>(
            std::min<uint64_t>(static_cast<uint64_t>(maxSize), size_ - position_));
        if (available == 0) {
            return 0;
        }
        if (!base_->seek(static_cast<qint64>(offset_ + position_))) {
            return -1;
        }
        const qint64 got = base_->read(data, available);
        if (got > 0) {
            position_ += static_cast<uint64_t>(got);
        }
        return got;
    }

    qint64 writeData(const char*, qint64) override { return -1; }

private:
    QIODevice* base_{nullptr};
    uint64_t offset_{0};
    uint64_t size_{0};
    uint64_t position_{0};
};

QString serviceStateName(DWORD state) {
    switch (state) {
    case SERVICE_STOPPED:
        return QStringLiteral("stopped");
    case SERVICE_START_PENDING:
        return QStringLiteral("start_pending");
    case SERVICE_STOP_PENDING:
        return QStringLiteral("stop_pending");
    case SERVICE_RUNNING:
        return QStringLiteral("running");
    case SERVICE_CONTINUE_PENDING:
        return QStringLiteral("continue_pending");
    case SERVICE_PAUSE_PENDING:
        return QStringLiteral("pause_pending");
    case SERVICE_PAUSED:
        return QStringLiteral("paused");
    default:
        return QStringLiteral("unknown_%1").arg(state);
    }
}

QString startTypeName(DWORD startType) {
    switch (startType) {
    case SERVICE_AUTO_START:
        return QStringLiteral("automatic");
    case SERVICE_BOOT_START:
        return QStringLiteral("boot");
    case SERVICE_DEMAND_START:
        return QStringLiteral("manual");
    case SERVICE_DISABLED:
        return QStringLiteral("disabled");
    case SERVICE_SYSTEM_START:
        return QStringLiteral("system");
    default:
        return QStringLiteral("unknown_%1").arg(startType);
    }
}

QString failureActionTypeName(SC_ACTION_TYPE type) {
    switch (type) {
    case SC_ACTION_NONE:
        return QStringLiteral("none");
    case SC_ACTION_RESTART:
        return QStringLiteral("restart");
    case SC_ACTION_REBOOT:
        return QStringLiteral("reboot");
    case SC_ACTION_RUN_COMMAND:
        return QStringLiteral("run_command");
    default:
        return QStringLiteral("unknown_%1").arg(static_cast<DWORD>(type));
    }
}

QJsonObject queryServiceRecoveryPolicy(SC_HANDLE service) {
    QJsonObject recovery;
    DWORD bytesNeeded = 0;
    QueryServiceConfig2W(service, SERVICE_CONFIG_FAILURE_ACTIONS, nullptr, 0, &bytesNeeded);
    if (bytesNeeded != 0) {
        auto buffer = std::make_unique<BYTE[]>(bytesNeeded);
        auto* actions = reinterpret_cast<SERVICE_FAILURE_ACTIONSW*>(buffer.get());
        if (QueryServiceConfig2W(service,
                                 SERVICE_CONFIG_FAILURE_ACTIONS,
                                 buffer.get(),
                                 bytesNeeded,
                                 &bytesNeeded)) {
            QJsonArray actionArray;
            for (DWORD i = 0; i < actions->cActions; ++i) {
                const SC_ACTION& action = actions->lpsaActions[i];
                actionArray.append(QJsonObject{
                    {QStringLiteral("type"), failureActionTypeName(action.Type)},
                    {QStringLiteral("delay_ms"), QString::number(action.Delay)}});
            }
            recovery.insert(QStringLiteral("reset_seconds"),
                            QString::number(actions->dwResetPeriod));
            recovery.insert(QStringLiteral("restart_action_count"),
                            static_cast<int>(std::count_if(actions->lpsaActions,
                                                           actions->lpsaActions + actions->cActions,
                                                           [](const SC_ACTION& action) {
                                                               return action.Type == SC_ACTION_RESTART;
                                                           })));
            recovery.insert(QStringLiteral("actions"), actionArray);
        } else {
            recovery.insert(QStringLiteral("actions_error"), winError(GetLastError()));
        }
    } else {
        recovery.insert(QStringLiteral("reset_seconds"), QStringLiteral("0"));
        recovery.insert(QStringLiteral("restart_action_count"), 0);
        recovery.insert(QStringLiteral("actions"), QJsonArray{});
    }

    SERVICE_FAILURE_ACTIONS_FLAG flag{};
    bytesNeeded = 0;
    if (QueryServiceConfig2W(service,
                             SERVICE_CONFIG_FAILURE_ACTIONS_FLAG,
                             reinterpret_cast<LPBYTE>(&flag),
                             sizeof(flag),
                             &bytesNeeded)) {
        recovery.insert(QStringLiteral("non_crash_failures_enabled"),
                        flag.fFailureActionsOnNonCrashFailures != FALSE);
    } else {
        recovery.insert(QStringLiteral("non_crash_failure_error"), winError(GetLastError()));
    }
    return recovery;
}

bool configureServiceRecoveryPolicy(SC_HANDLE service, QString* error = nullptr) {
    std::array<SC_ACTION, 3> actions{SC_ACTION{SC_ACTION_RESTART, 5000},
                                     SC_ACTION{SC_ACTION_RESTART, 30000},
                                     SC_ACTION{SC_ACTION_RESTART, 60000}};
    SERVICE_FAILURE_ACTIONSW failureActions{};
    failureActions.dwResetPeriod = 86400;
    failureActions.cActions = static_cast<DWORD>(actions.size());
    failureActions.lpsaActions = actions.data();
    if (!ChangeServiceConfig2W(service, SERVICE_CONFIG_FAILURE_ACTIONS, &failureActions)) {
        if (error) {
            *error = QStringLiteral("ChangeServiceConfig2 failure actions failed: %1")
                         .arg(winError(GetLastError()));
        }
        return false;
    }

    SERVICE_FAILURE_ACTIONS_FLAG failureFlag{};
    failureFlag.fFailureActionsOnNonCrashFailures = TRUE;
    if (!ChangeServiceConfig2W(service, SERVICE_CONFIG_FAILURE_ACTIONS_FLAG, &failureFlag)) {
        if (error) {
            *error = QStringLiteral("ChangeServiceConfig2 failure flag failed: %1")
                         .arg(winError(GetLastError()));
        }
        return false;
    }
    return true;
}

bool stopServiceAndWait(SC_HANDLE service,
                        DWORD timeoutMs,
                        bool* stopRequested,
                        bool* alreadyStopped,
                        QString* error = nullptr) {
    const ULONGLONG deadline = GetTickCount64() + timeoutMs;
    bool observedActive = false;
    SERVICE_STATUS_PROCESS status{};
    DWORD bytesNeeded = 0;
    while (true) {
        if (!QueryServiceStatusEx(service,
                                  SC_STATUS_PROCESS_INFO,
                                  reinterpret_cast<LPBYTE>(&status),
                                  sizeof(status),
                                  &bytesNeeded)) {
            if (error) {
                *error = QStringLiteral("QueryServiceStatusEx failed: %1").arg(winError(GetLastError()));
            }
            return false;
        }
        if (status.dwCurrentState == SERVICE_STOPPED) {
            if (alreadyStopped && !observedActive && (!stopRequested || !*stopRequested)) {
                *alreadyStopped = true;
            }
            return true;
        }
        observedActive = true;

        const bool transitionPending = status.dwCurrentState == SERVICE_START_PENDING ||
                                       status.dwCurrentState == SERVICE_STOP_PENDING ||
                                       status.dwCurrentState == SERVICE_CONTINUE_PENDING ||
                                       status.dwCurrentState == SERVICE_PAUSE_PENDING;
        if (!transitionPending && (!stopRequested || !*stopRequested)) {
            SERVICE_STATUS controlStatus{};
            if (ControlService(service, SERVICE_CONTROL_STOP, &controlStatus)) {
                if (stopRequested) {
                    *stopRequested = true;
                }
            } else {
                const DWORD stopError = GetLastError();
                if (stopError != ERROR_SERVICE_NOT_ACTIVE &&
                    stopError != ERROR_SERVICE_CANNOT_ACCEPT_CTRL) {
                    if (error) {
                        *error = QStringLiteral("ControlService stop failed: %1")
                                     .arg(winError(stopError));
                    }
                    return false;
                }
            }
        }
        if (GetTickCount64() >= deadline) {
            if (error) {
                *error = QStringLiteral("Service did not stop before timeout; current state: %1")
                             .arg(serviceStateName(status.dwCurrentState));
            }
            return false;
        }
        Sleep(500);
    }
}

QJsonObject queryInstalledService() {
    QJsonObject out{{QStringLiteral("name"), QString::fromWCharArray(kServiceName)},
                    {QStringLiteral("installed"), false}};
    SC_HANDLE scm = OpenSCManagerW(nullptr, nullptr, SC_MANAGER_CONNECT);
    if (!scm) {
        out.insert(QStringLiteral("error"), winError(GetLastError()));
        return out;
    }
    SC_HANDLE service =
        OpenServiceW(scm, kServiceName, SERVICE_QUERY_STATUS | SERVICE_QUERY_CONFIG);
    if (!service) {
        out.insert(QStringLiteral("error"), winError(GetLastError()));
        CloseServiceHandle(scm);
        return out;
    }

    out.insert(QStringLiteral("installed"), true);
    SERVICE_STATUS_PROCESS status{};
    DWORD bytesNeeded = 0;
    if (QueryServiceStatusEx(service,
                             SC_STATUS_PROCESS_INFO,
                             reinterpret_cast<LPBYTE>(&status),
                             sizeof(status),
                             &bytesNeeded)) {
        out.insert(QStringLiteral("status"), serviceStateName(status.dwCurrentState));
        out.insert(QStringLiteral("process_id"), QString::number(status.dwProcessId));
    } else {
        out.insert(QStringLiteral("status_error"), winError(GetLastError()));
    }

    DWORD configBytesNeeded = 0;
    QueryServiceConfigW(service, nullptr, 0, &configBytesNeeded);
    if (configBytesNeeded != 0) {
        auto buffer = std::make_unique<BYTE[]>(configBytesNeeded);
        auto* config = reinterpret_cast<QUERY_SERVICE_CONFIGW*>(buffer.get());
        if (QueryServiceConfigW(service, config, configBytesNeeded, &configBytesNeeded)) {
            out.insert(QStringLiteral("start_type"), startTypeName(config->dwStartType));
            out.insert(QStringLiteral("binary_path"), QString::fromWCharArray(config->lpBinaryPathName));
        } else {
            out.insert(QStringLiteral("config_error"), winError(GetLastError()));
        }
    }
    out.insert(QStringLiteral("recovery"), queryServiceRecoveryPolicy(service));

    CloseServiceHandle(service);
    CloseServiceHandle(scm);
    return out;
}

QJsonObject detectionToJson(const sak::PartitionFileSystemDetection& detection) {
    QJsonArray details;
    for (const auto& detail : detection.details) {
        details.append(detail);
    }
    return QJsonObject{{QStringLiteral("file_system"), detection.file_system},
                       {QStringLiteral("source"), detection.source},
                       {QStringLiteral("total_bytes"), QString::number(detection.total_bytes)},
                       {QStringLiteral("free_bytes"), QString::number(detection.free_bytes)},
                       {QStringLiteral("details"), details}};
}

bool isApfsDetection(const sak::PartitionFileSystemDetection& detection) {
    return detection.file_system.compare(QStringLiteral("APFS"), Qt::CaseInsensitive) == 0;
}

QJsonArray listRootEntries(QIODevice* device, int maxEntries) {
    QJsonArray entries;
    if (!device || !device->isOpen()) {
        return entries;
    }
    const auto listing = sak::PartitionApfsFileSystemReader::listDirectory(
        device, QStringLiteral("/"), maxEntries);
    for (const auto& entry : listing.entries) {
        entries.append(QJsonObject{{QStringLiteral("name"), entry.name},
                                   {QStringLiteral("path"), entry.path},
                                   {QStringLiteral("type"), entry.type},
                                   {QStringLiteral("object_id"),
                                    QString::number(entry.object_id)},
                                   {QStringLiteral("size_bytes"),
                                    QString::number(entry.size_bytes)},
                                   {QStringLiteral("directory"), entry.directory},
                                   {QStringLiteral("regular_file"), entry.regular_file},
                                   {QStringLiteral("symlink"), entry.symlink}});
    }
    return entries;
}

QJsonObject partitionToJson(const PartitionCandidate& partition) {
    QJsonObject out{{QStringLiteral("index"), partition.index},
                    {QStringLiteral("scheme"), partition.scheme},
                    {QStringLiteral("offset_bytes"), QString::number(partition.offset_bytes)},
                    {QStringLiteral("size_bytes"), QString::number(partition.size_bytes)}};
    if (partition.scheme.compare(QStringLiteral("GPT"), Qt::CaseInsensitive) == 0) {
        out.insert(QStringLiteral("type_guid"), partition.type_guid);
        out.insert(QStringLiteral("unique_guid"), partition.unique_guid);
        out.insert(QStringLiteral("name"), partition.name);
    } else if (partition.scheme.compare(QStringLiteral("MBR"), Qt::CaseInsensitive) == 0) {
        out.insert(QStringLiteral("mbr_type"),
                   QStringLiteral("0x%1").arg(partition.mbr_type, 2, 16, QLatin1Char('0')));
    }
    return out;
}

QJsonObject discoveredVolumeToJson(const DiscoveredApfsVolume& volume) {
    QJsonObject out{{QStringLiteral("disk_index"), volume.disk_index},
                    {QStringLiteral("target"), volume.target},
                    {QStringLiteral("kind"), volume.kind},
                    {QStringLiteral("detection"), detectionToJson(volume.detection)},
                    {QStringLiteral("root_entries"), volume.root_entries}};
    if (volume.partition.index != 0) {
        out.insert(QStringLiteral("partition"), partitionToJson(volume.partition));
    }
    return out;
}

QString physicalDrivePath(int diskIndex) {
    return QStringLiteral("\\\\.\\PhysicalDrive%1").arg(diskIndex);
}

QString partitionDevicePath(int diskIndex, int partitionIndex) {
    return QStringLiteral("\\\\?\\GLOBALROOT\\Device\\Harddisk%1\\Partition%2")
        .arg(diskIndex)
        .arg(partitionIndex);
}

DiscoveryScan discoverApfsVolumes(int maxPhysicalDrives, bool includeRootEntries) {
    DiscoveryScan scan;
    const int maxDrives = std::clamp(maxPhysicalDrives, 0, 128);
    for (int disk = 0; disk < maxDrives; ++disk) {
        const QString target = physicalDrivePath(disk);
        QJsonObject diskJson{{QStringLiteral("disk_index"), disk},
                             {QStringLiteral("target"), target}};

        QString openError;
        auto device = sak::openFileOrRawDeviceReadOnly(target, &openError);
        if (!device) {
            diskJson.insert(QStringLiteral("open_ok"), false);
            diskJson.insert(QStringLiteral("open_error"), openError);
            scan.disks.append(diskJson);
            continue;
        }

        diskJson.insert(QStringLiteral("open_ok"), true);
        const uint64_t deviceSize =
            device->size() > 0 ? static_cast<uint64_t>(device->size()) : kFallbackProbeBytes;
        diskJson.insert(QStringLiteral("size_bytes"), QString::number(deviceSize));

        QString wholeError;
        std::optional<DiscoveredApfsVolume> wholeVolume;
        const auto wholeDetection =
            sak::PartitionFileSystemDetector::detectFromDevice(device.get(),
                                                               0,
                                                               deviceSize,
                                                               &wholeError);
        if (wholeDetection.has_value()) {
            diskJson.insert(QStringLiteral("whole_device_detection"),
                            detectionToJson(*wholeDetection));
            if (isApfsDetection(*wholeDetection)) {
                DiscoveredApfsVolume volume;
                volume.disk_index = disk;
                volume.target = target;
                volume.kind = QStringLiteral("whole_device");
                volume.detection = *wholeDetection;
                if (includeRootEntries) {
                    device->seek(0);
                    volume.root_entries = listRootEntries(device.get(), 100);
                }
                wholeVolume = std::move(volume);
            }
        } else if (!wholeError.isEmpty()) {
            diskJson.insert(QStringLiteral("whole_device_detection_error"), wholeError);
        }

        QJsonArray partitionArray;
        QJsonArray gptPartitionArray;
        bool apfsPartitionAtDeviceStart = false;
        const QVector<PartitionCandidate> partitions = readPartitions(device.get());
        for (const auto& partition : partitions) {
            QJsonObject partitionJson = partitionToJson(partition);
            QString partitionError;
            const auto partitionDetection =
                sak::PartitionFileSystemDetector::detectFromDevice(device.get(),
                                                                   partition.offset_bytes,
                                                                   partition.size_bytes,
                                                                   &partitionError);
            if (partitionDetection.has_value()) {
                partitionJson.insert(QStringLiteral("detection"),
                                     detectionToJson(*partitionDetection));
                if (isApfsDetection(*partitionDetection)) {
                    apfsPartitionAtDeviceStart = apfsPartitionAtDeviceStart ||
                                                 partition.offset_bytes == 0;
                    DiscoveredApfsVolume volume;
                    volume.disk_index = disk;
                    volume.target = partitionDevicePath(disk, partition.index);
                    volume.kind = partition.scheme.compare(QStringLiteral("GPT"),
                                                           Qt::CaseInsensitive) == 0
                                      ? QStringLiteral("gpt_partition")
                                      : QStringLiteral("mbr_partition");
                    volume.partition = partition;
                    volume.detection = *partitionDetection;
                    if (includeRootEntries) {
                        WindowDevice window(device.get(),
                                            partition.offset_bytes,
                                            partition.size_bytes);
                        if (window.open(QIODevice::ReadOnly)) {
                            volume.root_entries = listRootEntries(&window, 100);
                        }
                    }
                    scan.volumes.append(volume);
                }
            } else if (!partitionError.isEmpty() ||
                       partition.type_guid.compare(QString::fromLatin1(kApfsGptTypeGuid),
                                                   Qt::CaseInsensitive) == 0) {
                partitionJson.insert(QStringLiteral("detection_error"), partitionError);
            }
            partitionArray.append(partitionJson);
            if (partition.scheme.compare(QStringLiteral("GPT"), Qt::CaseInsensitive) == 0) {
                gptPartitionArray.append(partitionJson);
            }
        }
        diskJson.insert(QStringLiteral("partitions"), partitionArray);
        diskJson.insert(QStringLiteral("gpt_partitions"), gptPartitionArray);
        if (wholeVolume.has_value() && !apfsPartitionAtDeviceStart) {
            scan.volumes.append(std::move(*wholeVolume));
        }
        scan.disks.append(diskJson);
    }
    return scan;
}

QSet<QChar> usedDriveLetters(const QVector<MountConfig>& mounts) {
    QSet<QChar> used;
    const DWORD mask = GetLogicalDrives();
    for (int i = 0; i < 26; ++i) {
        if ((mask & (1u << i)) != 0) {
            used.insert(QChar(QLatin1Char(static_cast<char>('A' + i))));
        }
    }
    for (const auto& mount : mounts) {
        const QString trimmed = mount.mount.trimmed().toUpper();
        if (trimmed.size() >= 2 && trimmed.at(1) == QLatin1Char(':')) {
            used.insert(trimmed.at(0));
        }
    }
    return used;
}

QString nextAvailableMount(QSet<QChar>* used) {
    for (QChar letter = QChar(QLatin1Char('Z')); letter >= QChar(QLatin1Char('D'));
         letter = QChar(letter.unicode() - 1)) {
        if (!used->contains(letter)) {
            used->insert(letter);
            return QStringLiteral("%1:").arg(letter);
        }
    }
    return {};
}

std::optional<MountConfig> preferredMountForTarget(const QVector<MountConfig>& preferredMounts,
                                                   const QString& target) {
    const auto found = std::find_if(preferredMounts.begin(),
                                    preferredMounts.end(),
                                    [&](const MountConfig& mount) {
                                        return mount.target.compare(target, Qt::CaseInsensitive) ==
                                               0;
                                    });
    if (found == preferredMounts.end()) {
        return std::nullopt;
    }
    return *found;
}

QString canonicalDiscoveredTarget(const QString& target,
                                  const QVector<DiscoveredApfsVolume>& volumes,
                                  bool* wasAlias = nullptr) {
    if (wasAlias) {
        *wasAlias = false;
    }
    for (const auto& volume : volumes) {
        if (volume.partition.index != 0 && volume.partition.offset_bytes == 0 &&
            target.compare(physicalDrivePath(volume.disk_index), Qt::CaseInsensitive) == 0) {
            if (wasAlias) {
                *wasAlias = true;
            }
            return volume.target;
        }
    }
    for (const auto& volume : volumes) {
        if (target.compare(volume.target, Qt::CaseInsensitive) == 0) {
            return volume.target;
        }
    }
    return target;
}

struct ParsedRawTarget {
    int disk_index{-1};
    int partition_index{0};
};

std::optional<ParsedRawTarget> parseRawTarget(const QString& target) {
    const QString physicalPrefix = QStringLiteral("\\\\.\\PhysicalDrive");
    if (target.startsWith(physicalPrefix, Qt::CaseInsensitive)) {
        bool ok = false;
        const int disk = target.mid(physicalPrefix.size()).toInt(&ok);
        if (ok && disk >= 0) {
            return ParsedRawTarget{.disk_index = disk};
        }
        return std::nullopt;
    }

    const QString partitionPrefix = QStringLiteral("\\\\?\\GLOBALROOT\\Device\\Harddisk");
    if (!target.startsWith(partitionPrefix, Qt::CaseInsensitive)) {
        return std::nullopt;
    }
    const QString suffix = target.mid(partitionPrefix.size());
    const QString marker = QStringLiteral("\\Partition");
    const qsizetype markerIndex = suffix.indexOf(marker, 0, Qt::CaseInsensitive);
    if (markerIndex <= 0) {
        return std::nullopt;
    }
    bool diskOk = false;
    bool partitionOk = false;
    const int disk = suffix.left(markerIndex).toInt(&diskOk);
    const int partition = suffix.mid(markerIndex + marker.size()).toInt(&partitionOk);
    if (!diskOk || !partitionOk || disk < 0 || partition <= 0) {
        return std::nullopt;
    }
    return ParsedRawTarget{.disk_index = disk, .partition_index = partition};
}

std::optional<quint64> windowsPartitionOffset(const QString& target, DWORD* error = nullptr) {
    if (error) {
        *error = ERROR_SUCCESS;
    }
    const std::wstring path = target.toStdWString();
    HANDLE handle = CreateFileW(path.c_str(),
                                0,
                                FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                                nullptr,
                                OPEN_EXISTING,
                                FILE_ATTRIBUTE_NORMAL,
                                nullptr);
    if (handle == INVALID_HANDLE_VALUE) {
        if (error) {
            *error = GetLastError();
        }
        return std::nullopt;
    }

    PARTITION_INFORMATION_EX information{};
    DWORD returned = 0;
    const BOOL ok = DeviceIoControl(handle,
                                    IOCTL_DISK_GET_PARTITION_INFO_EX,
                                    nullptr,
                                    0,
                                    &information,
                                    sizeof(information),
                                    &returned,
                                    nullptr);
    const DWORD ioctlError = ok ? ERROR_SUCCESS : GetLastError();
    CloseHandle(handle);
    if (!ok || information.StartingOffset.QuadPart < 0) {
        if (error) {
            *error = ioctlError;
        }
        return std::nullopt;
    }
    return static_cast<quint64>(information.StartingOffset.QuadPart);
}

std::optional<QString> rawTargetIdentity(const QString& target,
                                         const QVector<DiscoveredApfsVolume>& volumes) {
    const std::optional<ParsedRawTarget> parsed = parseRawTarget(target);
    if (!parsed.has_value()) {
        return std::nullopt;
    }

    quint64 offset = 0;
    if (parsed->partition_index != 0) {
        const auto discovered = std::find_if(
            volumes.begin(), volumes.end(), [&](const DiscoveredApfsVolume& volume) {
                return volume.disk_index == parsed->disk_index &&
                       volume.partition.index == parsed->partition_index;
            });
        if (discovered != volumes.end()) {
            offset = discovered->partition.offset_bytes;
        } else {
            const std::optional<quint64> queried = windowsPartitionOffset(target);
            if (!queried.has_value()) {
                return std::nullopt;
            }
            offset = *queried;
        }
    }
    return QStringLiteral("disk:%1:offset:%2").arg(parsed->disk_index).arg(offset);
}

bool targetsReferToSameRawRegion(const QString& left,
                                 const QString& right,
                                 const QVector<DiscoveredApfsVolume>& volumes) {
    if (left.compare(right, Qt::CaseInsensitive) == 0) {
        return true;
    }
    const std::optional<QString> leftIdentity = rawTargetIdentity(left, volumes);
    const std::optional<QString> rightIdentity = rawTargetIdentity(right, volumes);
    return leftIdentity.has_value() && rightIdentity.has_value() &&
           *leftIdentity == *rightIdentity;
}

int targetIdentityDiagnostic(const QStringList& args) {
    const QString target = argumentValue(args, QStringLiteral("--target")).trimmed();
    const std::optional<ParsedRawTarget> parsed = parseRawTarget(target);
    DWORD offsetError = ERROR_SUCCESS;
    std::optional<quint64> partitionOffset;
    if (parsed.has_value() && parsed->partition_index != 0) {
        partitionOffset = windowsPartitionOffset(target, &offsetError);
    }
    const std::optional<QString> identity = rawTargetIdentity(target, {});
    const bool ok = parsed.has_value() && identity.has_value();
    printJson(QJsonObject{
        {QStringLiteral("component"), QStringLiteral("apfs_mount_service")},
        {QStringLiteral("check"), QStringLiteral("target_identity")},
        {QStringLiteral("ok"), ok},
        {QStringLiteral("target"), target},
        {QStringLiteral("parsed"), parsed.has_value()},
        {QStringLiteral("disk_index"), parsed.has_value() ? parsed->disk_index : -1},
        {QStringLiteral("partition_index"), parsed.has_value() ? parsed->partition_index : -1},
        {QStringLiteral("partition_offset_bytes"),
         partitionOffset.has_value() ? QJsonValue(QString::number(*partitionOffset)) : QJsonValue()},
        {QStringLiteral("win32_error"), static_cast<qint64>(offsetError)},
        {QStringLiteral("win32_error_message"),
         offsetError == ERROR_SUCCESS ? QString() : winError(offsetError)},
        {QStringLiteral("identity"),
         identity.has_value() ? QJsonValue(*identity) : QJsonValue()}});
    return ok ? 0 : 1;
}

bool canonicalizeDiscoveredMountAliases(QVector<MountConfig>* mounts,
                                        const QVector<DiscoveredApfsVolume>& volumes,
                                        QJsonArray* actions = nullptr) {
    QVector<MountConfig> normalized;
    QVector<bool> exactTargets;
    QVector<std::optional<QString>> identities;
    bool changed = false;

    for (const auto& mount : *mounts) {
        bool wasAlias = false;
        MountConfig candidate = mount;
        candidate.target = canonicalDiscoveredTarget(mount.target, volumes, &wasAlias);

        const std::optional<ParsedRawTarget> parsedCandidate = parseRawTarget(candidate.target);
        const bool candidateIsExact = !wasAlias && parsedCandidate.has_value() &&
                                      parsedCandidate->partition_index != 0;
        const std::optional<QString> candidateIdentity =
            rawTargetIdentity(candidate.target, volumes);

        qsizetype duplicateIndex = -1;
        for (qsizetype i = 0; i < normalized.size(); ++i) {
            if (normalized.at(i).target.compare(candidate.target, Qt::CaseInsensitive) == 0 ||
                (candidateIdentity.has_value() && identities.at(i).has_value() &&
                 *candidateIdentity == *identities.at(i))) {
                duplicateIndex = i;
                break;
            }
        }
        if (duplicateIndex < 0) {
            normalized.append(candidate);
            exactTargets.append(candidateIsExact);
            identities.append(candidateIdentity);
            if (wasAlias) {
                changed = true;
                if (actions) {
                    actions->append(QJsonObject{
                        {QStringLiteral("action"), QStringLiteral("canonicalized")},
                        {QStringLiteral("from_target"), mount.target},
                        {QStringLiteral("to_target"), candidate.target},
                        {QStringLiteral("mount"), candidate.mount}});
                }
            }
            continue;
        }

        changed = true;
        const bool replaceAliasWithExact = candidateIsExact && !exactTargets.at(duplicateIndex);
        const MountConfig removed =
            replaceAliasWithExact ? normalized.at(duplicateIndex) : candidate;
        if (replaceAliasWithExact) {
            normalized[duplicateIndex] = candidate;
            exactTargets[duplicateIndex] = true;
            identities[duplicateIndex] = candidateIdentity;
        }
        if (actions) {
            actions->append(QJsonObject{
                {QStringLiteral("action"), QStringLiteral("removed_duplicate_alias")},
                {QStringLiteral("target"), removed.target},
                {QStringLiteral("mount"), removed.mount},
                {QStringLiteral("kept_mount"), normalized.at(duplicateIndex).mount}});
        }
    }

    if (changed) {
        *mounts = std::move(normalized);
    }
    return changed;
}

bool mergeDiscoveredMounts(QVector<MountConfig>* mounts,
                           const QVector<DiscoveredApfsVolume>& volumes,
                           QJsonArray* added,
                           const QVector<MountConfig>& preferredMounts = {}) {
    bool changed = false;
    QSet<QChar> usedLetters = usedDriveLetters(*mounts);
    for (const auto& volume : volumes) {
        const bool exists = std::any_of(mounts->begin(),
                                        mounts->end(),
                                        [&](const MountConfig& mount) {
                                            return targetsReferToSameRawRegion(
                                                mount.target, volume.target, volumes);
                                        });
        if (exists) {
            continue;
        }

        MountConfig newMount{.target = volume.target,
                             .read_only = false,
                             .allow_raw_writes = true,
                             .enabled = true};
        const std::optional<MountConfig> preferred =
            preferredMountForTarget(preferredMounts, volume.target);
        if (preferred.has_value()) {
            newMount.mount = preferred->mount;
            newMount.read_only = preferred->read_only;
            newMount.allow_raw_writes = preferred->allow_raw_writes;
            newMount.enabled = preferred->enabled;
        } else {
            newMount.mount = nextAvailableMount(&usedLetters);
        }
        if (newMount.mount.isEmpty()) {
            if (added) {
                added->append(QJsonObject{{QStringLiteral("target"), volume.target},
                                          {QStringLiteral("added"), false},
                                          {QStringLiteral("error"),
                                           QStringLiteral("no free drive letters")}});
            }
            continue;
        }

        mounts->append(newMount);
        if (added) {
            QJsonObject object = mountConfigJson(newMount);
            object.insert(QStringLiteral("kind"), volume.kind);
            added->append(object);
        }
        changed = true;
    }
    return changed;
}

QVector<MountConfig> readMountConfigWithAutoDiscovery(
    QString* error = nullptr,
    const QVector<MountConfig>& preferredMounts = {}) {
    QVector<MountConfig> mounts = readMountConfig(error);
    if (error && !error->isEmpty()) {
        return mounts;
    }

    const DiscoveryScan scan = discoverApfsVolumes(kDefaultMaxPhysicalDrives, false);
    QJsonArray aliasActions;
    QJsonArray added;
    const bool aliasesChanged =
        canonicalizeDiscoveredMountAliases(&mounts, scan.volumes, &aliasActions);
    const bool mountsAdded = mergeDiscoveredMounts(&mounts, scan.volumes, &added, preferredMounts);
    if (aliasesChanged || mountsAdded) {
        QString writeError;
        if (writeMountConfig(mounts, &writeError)) {
            if (!aliasActions.isEmpty()) {
                appendServiceLog(QStringLiteral("Canonicalized APFS target aliases: %1")
                                     .arg(QString::fromUtf8(QJsonDocument(aliasActions).toJson(
                                         QJsonDocument::Compact))));
            }
            if (!added.isEmpty()) {
                appendServiceLog(QStringLiteral("Auto-discovered APFS mounts: %1")
                                     .arg(QString::fromUtf8(QJsonDocument(added).toJson(
                                         QJsonDocument::Compact))));
            }
        } else {
            appendServiceLog(writeError);
        }
    }
    return mounts;
}

QString mountRootPath(const QString& mount) {
    QString root = mount.trimmed();
    if (root.size() == 2 && root.endsWith(QLatin1Char(':'))) {
        root.append(QLatin1Char('\\'));
    }
    return root;
}

QString normalizeDriveMount(QString mount) {
    mount = mount.trimmed().toUpper();
    if (mount.size() == 1 && mount.at(0).isLetter()) {
        mount.append(QLatin1Char(':'));
    }
    if (mount.size() == 2 && mount.at(0).isLetter() && mount.at(1) == QLatin1Char(':')) {
        return mount;
    }
    return {};
}

bool driveLetterInUse(const QString& mount) {
    const QString normalized = normalizeDriveMount(mount);
    if (normalized.isEmpty()) {
        return false;
    }
    const int bit = normalized.at(0).toLatin1() - 'A';
    return bit >= 0 && bit < 26 && (GetLogicalDrives() & (1u << bit)) != 0;
}

bool looksLikeRawDeviceTarget(const QString& target) {
    return target.contains(QStringLiteral("\\\\.\\PhysicalDrive"), Qt::CaseInsensitive) ||
           target.contains(QStringLiteral("\\\\?\\GLOBALROOT\\Device\\Harddisk"),
                           Qt::CaseInsensitive);
}

bool serviceMayEnableRawWritesForTarget(const QString& target, QString* error = nullptr) {
    if (!looksLikeRawDeviceTarget(target)) {
        return true;
    }

    QString openError;
    auto device = sak::openFileOrRawDeviceReadOnly(target, &openError);
    if (!device) {
        if (error) {
            *error = QStringLiteral("Raw write target cannot be opened for APFS verification: %1 (%2)")
                         .arg(target, openError);
        }
        return false;
    }

    const uint64_t deviceSize =
        device->size() > 0 ? static_cast<uint64_t>(device->size()) : kFallbackProbeBytes;
    QString detectionError;
    const auto detection = sak::PartitionFileSystemDetector::detectFromDevice(device.get(),
                                                                               0,
                                                                               deviceSize,
                                                                               &detectionError);
    if (!detection.has_value() || !isApfsDetection(*detection)) {
        if (error) {
            *error = QStringLiteral("Raw write target does not contain a verified APFS signature: %1 (%2)")
                         .arg(target,
                              detectionError.isEmpty() ? QStringLiteral("not APFS")
                                                       : detectionError);
        }
        return false;
    }
    return true;
}

QJsonObject mountHealthJson(const MountConfig& mount) {
    const QString root = mountRootPath(mount.mount);
    const DWORD attributes = GetFileAttributesW(reinterpret_cast<LPCWSTR>(root.utf16()));
    const bool rootExists = attributes != INVALID_FILE_ATTRIBUTES;
    wchar_t volumeName[MAX_PATH + 1]{};
    wchar_t fileSystemName[MAX_PATH + 1]{};
    const bool volumeInfoAvailable =
        rootExists &&
        GetVolumeInformationW(reinterpret_cast<LPCWSTR>(root.utf16()),
                              volumeName,
                              MAX_PATH,
                              nullptr,
                              nullptr,
                              nullptr,
                              fileSystemName,
                              MAX_PATH);
    const QString fileSystem =
        volumeInfoAvailable ? QString::fromWCharArray(fileSystemName) : QString();
    const bool exists = volumeInfoAvailable &&
                        fileSystem.compare(QStringLiteral("APFS"), Qt::CaseInsensitive) == 0;
    QJsonArray entries;
    if (exists) {
        const QFileInfoList infos = QDir(root).entryInfoList(
            QDir::NoDotAndDotDot | QDir::AllEntries, QDir::Name | QDir::DirsFirst);
        for (const QFileInfo& info : infos) {
            entries.append(QJsonObject{{QStringLiteral("name"), info.fileName()},
                                       {QStringLiteral("directory"), info.isDir()},
                                       {QStringLiteral("size_bytes"), QString::number(info.size())}});
        }
    }
    return QJsonObject{{QStringLiteral("target"), mount.target},
                       {QStringLiteral("mount"), mount.mount},
                       {QStringLiteral("root"), root},
                       {QStringLiteral("read_only"), mount.read_only},
                       {QStringLiteral("allow_raw_writes"), mount.allow_raw_writes},
                       {QStringLiteral("enabled"), mount.enabled},
                       {QStringLiteral("exists"), exists},
                       {QStringLiteral("root_exists"), rootExists},
                       {QStringLiteral("mount_collision"), rootExists && !exists},
                       {QStringLiteral("file_system"), fileSystem},
                       {QStringLiteral("volume_label"),
                        volumeInfoAvailable ? QString::fromWCharArray(volumeName) : QString()},
                       {QStringLiteral("entries"), entries}};
}

std::optional<bool> parseBoolValue(const QString& value) {
    const QString normalized = value.trimmed().toLower();
    if (normalized == QStringLiteral("true") || normalized == QStringLiteral("1") ||
        normalized == QStringLiteral("yes") || normalized == QStringLiteral("on")) {
        return true;
    }
    if (normalized == QStringLiteral("false") || normalized == QStringLiteral("0") ||
        normalized == QStringLiteral("no") || normalized == QStringLiteral("off")) {
        return false;
    }
    return std::nullopt;
}

QJsonObject configErrorJson(int code, const QString& error) {
    return QJsonObject{{QStringLiteral("component"), QStringLiteral("apfs_mount_service")},
                       {QStringLiteral("ok"), false},
                       {QStringLiteral("exit_code"), code},
                       {QStringLiteral("error"), error}};
}

QJsonObject addMountConfigJson(const QString& target,
                               const QString& mount,
                               bool readOnly,
                               bool allowRawWrites,
                               bool viaService,
                               int* exitCode = nullptr) {
    if (target.isEmpty() || mount.isEmpty()) {
        if (exitCode) {
            *exitCode = 2;
        }
        return configErrorJson(2, QStringLiteral("--add-mount requires --target and --mount"));
    }
    if (viaService && allowRawWrites) {
        if (exitCode) {
            *exitCode = 8;
        }
        return configErrorJson(
            8,
            QStringLiteral("Raw write policy changes require elevated local service CLI."));
    }

    QString error;
    QVector<MountConfig> mounts = readMountConfig(&error);
    if (!error.isEmpty()) {
        if (exitCode) {
            *exitCode = 3;
        }
        return configErrorJson(3, error);
    }
    mounts.erase(std::remove_if(mounts.begin(),
                                mounts.end(),
                                [&](const MountConfig& existing) {
                                    return existing.mount.compare(mount, Qt::CaseInsensitive) == 0 ||
                                           existing.target.compare(target, Qt::CaseInsensitive) == 0;
                                }),
                 mounts.end());
    mounts.append(MountConfig{.target = target,
                              .mount = mount,
                              .read_only = readOnly,
                              .allow_raw_writes = allowRawWrites,
                              .enabled = true});
    if (!writeMountConfig(mounts, &error)) {
        if (exitCode) {
            *exitCode = 4;
        }
        return configErrorJson(4, error);
    }
    if (viaService && g_resyncEvent) {
        SetEvent(g_resyncEvent);
    }
    if (exitCode) {
        *exitCode = 0;
    }
    return QJsonObject{{QStringLiteral("component"), QStringLiteral("apfs_mount_service")},
                       {QStringLiteral("ok"), true},
                       {QStringLiteral("config"), configPath()},
                       {QStringLiteral("added"), true},
                       {QStringLiteral("target"), target},
                       {QStringLiteral("mount"), mount},
                       {QStringLiteral("read_only"), readOnly},
                       {QStringLiteral("allow_raw_writes"), allowRawWrites},
                       {QStringLiteral("enabled"), true},
                       {QStringLiteral("via_service"), viaService}};
}

QJsonObject removeMountConfigJson(const QString& target,
                                  const QString& mount,
                                  bool viaService,
                                  int* exitCode = nullptr) {
    if (target.isEmpty() && mount.isEmpty()) {
        if (exitCode) {
            *exitCode = 2;
        }
        return configErrorJson(2, QStringLiteral("--remove-mount requires --target or --mount"));
    }

    QString error;
    QVector<MountConfig> mounts = readMountConfig(&error);
    if (!error.isEmpty()) {
        if (exitCode) {
            *exitCode = 3;
        }
        return configErrorJson(3, error);
    }

    QJsonArray removed;
    mounts.erase(std::remove_if(mounts.begin(),
                                mounts.end(),
                                [&](const MountConfig& existing) {
                                    const bool targetMatch =
                                        !target.isEmpty() &&
                                        existing.target.compare(target, Qt::CaseInsensitive) == 0;
                                    const bool mountMatch =
                                        !mount.isEmpty() &&
                                        existing.mount.compare(mount, Qt::CaseInsensitive) == 0;
                                    if (targetMatch || mountMatch) {
                                        removed.append(mountConfigJson(existing));
                                        return true;
                                    }
                                    return false;
                                }),
                 mounts.end());

    if (!writeMountConfig(mounts, &error)) {
        if (exitCode) {
            *exitCode = 4;
        }
        return configErrorJson(4, error);
    }
    if (viaService && g_resyncEvent) {
        SetEvent(g_resyncEvent);
    }
    if (exitCode) {
        *exitCode = 0;
    }
    return QJsonObject{{QStringLiteral("component"), QStringLiteral("apfs_mount_service")},
                       {QStringLiteral("ok"), true},
                       {QStringLiteral("config"), configPath()},
                       {QStringLiteral("removed"), !removed.isEmpty()},
                       {QStringLiteral("removed_count"), removed.size()},
                       {QStringLiteral("removed_mounts"), removed},
                       {QStringLiteral("via_service"), viaService}};
}

QJsonObject setMountConfigJson(const QString& target,
                               const QString& mount,
                               bool viaService,
                               int* exitCode = nullptr) {
    if (target.isEmpty() || mount.isEmpty()) {
        if (exitCode) {
            *exitCode = 2;
        }
        return configErrorJson(2,
                               QStringLiteral("--set-mount requires --target and a drive-letter --mount"));
    }

    QString error;
    QVector<MountConfig> mounts = readMountConfig(&error);
    if (!error.isEmpty()) {
        if (exitCode) {
            *exitCode = 3;
        }
        return configErrorJson(3, error);
    }

    auto targetIt = std::find_if(mounts.begin(),
                                 mounts.end(),
                                 [&](const MountConfig& existing) {
                                     return existing.target.compare(target, Qt::CaseInsensitive) ==
                                            0;
                                 });
    if (targetIt == mounts.end()) {
        if (exitCode) {
            *exitCode = 5;
        }
        return configErrorJson(5, QStringLiteral("Configured target not found: %1").arg(target));
    }

    const QString oldMount = targetIt->mount;
    const bool noChange = oldMount.compare(mount, Qt::CaseInsensitive) == 0;
    const bool configConflict = std::any_of(mounts.begin(),
                                            mounts.end(),
                                            [&](const MountConfig& existing) {
                                                return existing.target.compare(
                                                           target, Qt::CaseInsensitive) != 0 &&
                                                       existing.mount.compare(
                                                           mount, Qt::CaseInsensitive) == 0;
                                            });
    if (configConflict) {
        if (exitCode) {
            *exitCode = 6;
        }
        return configErrorJson(6, QStringLiteral("Mount already configured: %1").arg(mount));
    }
    if (!noChange && driveLetterInUse(mount)) {
        if (exitCode) {
            *exitCode = 7;
        }
        return configErrorJson(7, QStringLiteral("Drive letter already in use: %1").arg(mount));
    }

    targetIt->mount = mount;
    const MountConfig updated = *targetIt;
    if (!writeMountConfig(mounts, &error)) {
        if (exitCode) {
            *exitCode = 4;
        }
        return configErrorJson(4, error);
    }
    if (viaService && g_resyncEvent) {
        SetEvent(g_resyncEvent);
    }
    if (exitCode) {
        *exitCode = 0;
    }
    return QJsonObject{{QStringLiteral("component"), QStringLiteral("apfs_mount_service")},
                       {QStringLiteral("ok"), true},
                       {QStringLiteral("config"), configPath()},
                       {QStringLiteral("changed"), !noChange},
                       {QStringLiteral("target"), target},
                       {QStringLiteral("old_mount"), oldMount},
                       {QStringLiteral("mount"), updated.mount},
                       {QStringLiteral("read_only"), updated.read_only},
                       {QStringLiteral("allow_raw_writes"), updated.allow_raw_writes},
                       {QStringLiteral("enabled"), updated.enabled},
                       {QStringLiteral("via_service"), viaService}};
}

QJsonObject setMountEnabledConfigJson(const QString& target,
                                      std::optional<bool> enabled,
                                      bool viaService,
                                      int* exitCode = nullptr) {
    if (target.isEmpty() || !enabled.has_value()) {
        if (exitCode) {
            *exitCode = 2;
        }
        return configErrorJson(
            2,
            QStringLiteral("--set-enabled requires --target and --enabled true|false"));
    }

    QString error;
    QVector<MountConfig> mounts = readMountConfig(&error);
    if (!error.isEmpty()) {
        if (exitCode) {
            *exitCode = 3;
        }
        return configErrorJson(3, error);
    }

    auto targetIt = std::find_if(mounts.begin(),
                                 mounts.end(),
                                 [&](const MountConfig& existing) {
                                     return existing.target.compare(target, Qt::CaseInsensitive) ==
                                            0;
                                 });
    if (targetIt == mounts.end()) {
        if (exitCode) {
            *exitCode = 5;
        }
        return configErrorJson(5, QStringLiteral("Configured target not found: %1").arg(target));
    }

    const bool oldEnabled = targetIt->enabled;
    targetIt->enabled = enabled.value();
    const MountConfig updated = *targetIt;
    if (!writeMountConfig(mounts, &error)) {
        if (exitCode) {
            *exitCode = 4;
        }
        return configErrorJson(4, error);
    }
    if (viaService && g_resyncEvent) {
        SetEvent(g_resyncEvent);
    }
    if (exitCode) {
        *exitCode = 0;
    }
    return QJsonObject{{QStringLiteral("component"), QStringLiteral("apfs_mount_service")},
                       {QStringLiteral("ok"), true},
                       {QStringLiteral("config"), configPath()},
                       {QStringLiteral("changed"), oldEnabled != updated.enabled},
                       {QStringLiteral("target"), target},
                       {QStringLiteral("mount"), updated.mount},
                       {QStringLiteral("old_enabled"), oldEnabled},
                       {QStringLiteral("enabled"), updated.enabled},
                       {QStringLiteral("read_only"), updated.read_only},
                       {QStringLiteral("allow_raw_writes"), updated.allow_raw_writes},
                       {QStringLiteral("via_service"), viaService}};
}

QJsonObject setMountPolicyConfigJson(const QString& target,
                                     bool readOnly,
                                     bool allowRawWrites,
                                     bool viaService,
                                     int* exitCode = nullptr) {
    if (target.isEmpty()) {
        if (exitCode) {
            *exitCode = 2;
        }
        return configErrorJson(2, QStringLiteral("--set-policy requires --target"));
    }
    if (viaService && !readOnly && looksLikeRawDeviceTarget(target) && !allowRawWrites) {
        if (exitCode) {
            *exitCode = 8;
        }
        return configErrorJson(
            8,
            QStringLiteral("Raw device read/write policy requires explicit raw-write opt in."));
    }
    QString rawWriteError;
    if (viaService && allowRawWrites &&
        !serviceMayEnableRawWritesForTarget(target, &rawWriteError)) {
        if (exitCode) {
            *exitCode = 8;
        }
        return configErrorJson(8, rawWriteError);
    }

    QString error;
    QVector<MountConfig> mounts = readMountConfig(&error);
    if (!error.isEmpty()) {
        if (exitCode) {
            *exitCode = 3;
        }
        return configErrorJson(3, error);
    }

    auto targetIt = std::find_if(mounts.begin(),
                                 mounts.end(),
                                 [&](const MountConfig& existing) {
                                     return existing.target.compare(target, Qt::CaseInsensitive) ==
                                            0;
                                 });
    if (targetIt == mounts.end()) {
        if (exitCode) {
            *exitCode = 5;
        }
        return configErrorJson(5, QStringLiteral("Configured target not found: %1").arg(target));
    }

    const bool oldReadOnly = targetIt->read_only;
    const bool oldAllowRawWrites = targetIt->allow_raw_writes;
    targetIt->read_only = readOnly;
    targetIt->allow_raw_writes = readOnly ? false : allowRawWrites;
    const MountConfig updated = *targetIt;
    if (!writeMountConfig(mounts, &error)) {
        if (exitCode) {
            *exitCode = 4;
        }
        return configErrorJson(4, error);
    }
    if (viaService && g_resyncEvent) {
        SetEvent(g_resyncEvent);
    }
    if (exitCode) {
        *exitCode = 0;
    }
    return QJsonObject{{QStringLiteral("component"), QStringLiteral("apfs_mount_service")},
                       {QStringLiteral("ok"), true},
                       {QStringLiteral("config"), configPath()},
                       {QStringLiteral("changed"), oldReadOnly != updated.read_only ||
                                                   oldAllowRawWrites != updated.allow_raw_writes},
                       {QStringLiteral("target"), target},
                       {QStringLiteral("mount"), updated.mount},
                       {QStringLiteral("old_read_only"), oldReadOnly},
                       {QStringLiteral("old_allow_raw_writes"), oldAllowRawWrites},
                       {QStringLiteral("read_only"), updated.read_only},
                       {QStringLiteral("allow_raw_writes"), updated.allow_raw_writes},
                       {QStringLiteral("enabled"), updated.enabled},
                       {QStringLiteral("via_service"), viaService}};
}

QJsonObject applyControlRequest(const QJsonObject& request) {
    const QString command = request.value(QStringLiteral("command")).toString().trimmed();
    if (command == QStringLiteral("add_mount")) {
        int exitCode = 0;
        const QJsonObject response = addMountConfigJson(
            request.value(QStringLiteral("target")).toString().trimmed(),
            request.value(QStringLiteral("mount")).toString().trimmed(),
            request.value(QStringLiteral("read_only")).toBool(true),
            request.value(QStringLiteral("allow_raw_writes")).toBool(false),
            true,
            &exitCode);
        Q_UNUSED(exitCode);
        return response;
    }
    if (command == QStringLiteral("remove_mount")) {
        int exitCode = 0;
        const QJsonObject response = removeMountConfigJson(
            request.value(QStringLiteral("target")).toString().trimmed(),
            request.value(QStringLiteral("mount")).toString().trimmed(),
            true,
            &exitCode);
        Q_UNUSED(exitCode);
        return response;
    }
    if (command == QStringLiteral("set_mount")) {
        int exitCode = 0;
        const QJsonObject response = setMountConfigJson(
            request.value(QStringLiteral("target")).toString().trimmed(),
            normalizeDriveMount(request.value(QStringLiteral("mount")).toString().trimmed()),
            true,
            &exitCode);
        Q_UNUSED(exitCode);
        return response;
    }
    if (command == QStringLiteral("set_enabled")) {
        int exitCode = 0;
        const QJsonObject response = setMountEnabledConfigJson(
            request.value(QStringLiteral("target")).toString().trimmed(),
            parseBoolValue(request.value(QStringLiteral("enabled")).toVariant().toString()),
            true,
            &exitCode);
        Q_UNUSED(exitCode);
        return response;
    }
    if (command == QStringLiteral("set_policy")) {
        int exitCode = 0;
        const QJsonObject response = setMountPolicyConfigJson(
            request.value(QStringLiteral("target")).toString().trimmed(),
            request.value(QStringLiteral("read_only")).toBool(true),
            request.value(QStringLiteral("allow_raw_writes")).toBool(false),
            true,
            &exitCode);
        Q_UNUSED(exitCode);
        return response;
    }
    return configErrorJson(2, QStringLiteral("Unsupported service command: %1").arg(command));
}

std::optional<QJsonObject> sendControlRequestToServer(const QJsonObject& request,
                                                      const QString& serverName,
                                                      QString* error = nullptr) {
    QLocalSocket socket;
    socket.connectToServer(serverName);
    if (!socket.waitForConnected(kControlSocketTimeoutMs)) {
        if (error) {
            *error = QStringLiteral("service IPC connect failed: %1").arg(socket.errorString());
        }
        return std::nullopt;
    }

    QByteArray payload = QJsonDocument(request).toJson(QJsonDocument::Compact);
    payload.append('\n');
    if (socket.write(payload) != payload.size() ||
        !socket.waitForBytesWritten(kControlSocketTimeoutMs)) {
        if (error) {
            *error = QStringLiteral("service IPC write failed: %1").arg(socket.errorString());
        }
        return std::nullopt;
    }

    while (!socket.canReadLine()) {
        if (!socket.waitForReadyRead(kControlSocketTimeoutMs)) {
            if (error) {
                *error = QStringLiteral("service IPC response timed out: %1").arg(socket.errorString());
            }
            return std::nullopt;
        }
    }
    QJsonParseError parseError{};
    const QJsonDocument document = QJsonDocument::fromJson(socket.readLine().trimmed(), &parseError);
    if (parseError.error != QJsonParseError::NoError || !document.isObject()) {
        if (error) {
            *error = QStringLiteral("service IPC response parse failed: %1")
                         .arg(parseError.errorString());
        }
        return std::nullopt;
    }
    return document.object();
}

std::optional<QJsonObject> sendControlRequest(const QJsonObject& request, QString* error = nullptr) {
    return sendControlRequestToServer(request, QString::fromLatin1(kLocalControlServerName), error);
}

bool printServiceFallbackIfOk(const QJsonObject& request,
                              const QString& directError,
                              QString* fallbackError = nullptr) {
    QString ipcError;
    const std::optional<QJsonObject> response = sendControlRequest(request, &ipcError);
    if (!response.has_value()) {
        if (fallbackError) {
            *fallbackError = QStringLiteral("%1\n%2").arg(directError, ipcError).trimmed();
        }
        return false;
    }
    if (!response->value(QStringLiteral("ok")).toBool(false)) {
        if (fallbackError) {
            *fallbackError = QStringLiteral("%1\n%2")
                                 .arg(directError,
                                      response->value(QStringLiteral("error")).toString())
                                 .trimmed();
        }
        return false;
    }
    printJson(response.value());
    return true;
}

int addMount(const QStringList& args) {
    const QString target = argumentValue(args, QStringLiteral("--target")).trimmed();
    const QString mount = argumentValue(args, QStringLiteral("--mount")).trimmed();
    const bool readOnly = !args.contains(QStringLiteral("--read-write"), Qt::CaseInsensitive);
    const bool allowRawWrites =
        args.contains(QStringLiteral("--allow-raw-writes"), Qt::CaseInsensitive);
    int exitCode = 0;
    const QJsonObject response =
        addMountConfigJson(target, mount, readOnly, allowRawWrites, false, &exitCode);
    if (exitCode != 0) {
        const QString directError = response.value(QStringLiteral("error")).toString();
        const QJsonObject request{{QStringLiteral("command"), QStringLiteral("add_mount")},
                                  {QStringLiteral("target"), target},
                                  {QStringLiteral("mount"), mount},
                                  {QStringLiteral("read_only"), readOnly},
                                  {QStringLiteral("allow_raw_writes"), allowRawWrites}};
        QString fallbackError;
        if (printServiceFallbackIfOk(request, directError, &fallbackError)) {
            return 0;
        }
        if (!fallbackError.isEmpty()) {
            QTextStream(stderr) << fallbackError << Qt::endl;
        } else if (directError.isEmpty()) {
            QTextStream(stderr) << "Unable to add mount" << Qt::endl;
        } else {
            QTextStream(stderr) << directError << Qt::endl;
        }
        return exitCode;
    }
    printJson(response);
    return 0;
}

int setMount(const QStringList& args) {
    const QString target = argumentValue(args, QStringLiteral("--target")).trimmed();
    const QString requestedMount = argumentValue(args, QStringLiteral("--mount")).trimmed();
    const QString mount = normalizeDriveMount(requestedMount);
    int exitCode = 0;
    const QJsonObject response = setMountConfigJson(target, mount, false, &exitCode);
    if (exitCode != 0) {
        const QString directError = response.value(QStringLiteral("error")).toString();
        const QJsonObject request{{QStringLiteral("command"), QStringLiteral("set_mount")},
                                  {QStringLiteral("target"), target},
                                  {QStringLiteral("mount"), mount}};
        QString fallbackError;
        if (printServiceFallbackIfOk(request, directError, &fallbackError)) {
            return 0;
        }
        if (!fallbackError.isEmpty()) {
            QTextStream(stderr) << fallbackError << Qt::endl;
        } else if (directError.isEmpty()) {
            QTextStream(stderr) << "Unable to set mount" << Qt::endl;
        } else {
            QTextStream(stderr) << directError << Qt::endl;
        }
        return exitCode;
    }
    printJson(response);
    return 0;
}

int setMountEnabled(const QStringList& args) {
    const QString target = argumentValue(args, QStringLiteral("--target")).trimmed();
    const QString enabledText = argumentValue(args, QStringLiteral("--enabled")).trimmed();
    const std::optional<bool> enabled = parseBoolValue(enabledText);
    int exitCode = 0;
    const QJsonObject response = setMountEnabledConfigJson(target, enabled, false, &exitCode);
    if (exitCode != 0) {
        const QString directError = response.value(QStringLiteral("error")).toString();
        const QJsonObject request{{QStringLiteral("command"), QStringLiteral("set_enabled")},
                                  {QStringLiteral("target"), target},
                                  {QStringLiteral("enabled"), enabledText}};
        QString fallbackError;
        if (printServiceFallbackIfOk(request, directError, &fallbackError)) {
            return 0;
        }
        if (!fallbackError.isEmpty()) {
            QTextStream(stderr) << fallbackError << Qt::endl;
        } else if (directError.isEmpty()) {
            QTextStream(stderr) << "Unable to set mount enabled state" << Qt::endl;
        } else {
            QTextStream(stderr) << directError << Qt::endl;
        }
        return exitCode;
    }
    printJson(response);
    return 0;
}

int setMountPolicy(const QStringList& args) {
    const QString target = argumentValue(args, QStringLiteral("--target")).trimmed();
    const bool readWrite = args.contains(QStringLiteral("--read-write"), Qt::CaseInsensitive);
    const bool readOnly = !readWrite;
    const bool allowRawWrites =
        args.contains(QStringLiteral("--allow-raw-writes"), Qt::CaseInsensitive);
    int exitCode = 0;
    const QJsonObject response =
        setMountPolicyConfigJson(target, readOnly, allowRawWrites, false, &exitCode);
    if (exitCode != 0) {
        const QString directError = response.value(QStringLiteral("error")).toString();
        const QJsonObject request{{QStringLiteral("command"), QStringLiteral("set_policy")},
                                  {QStringLiteral("target"), target},
                                  {QStringLiteral("read_only"), readOnly},
                                  {QStringLiteral("allow_raw_writes"), allowRawWrites}};
        QString fallbackError;
        if (printServiceFallbackIfOk(request, directError, &fallbackError)) {
            return 0;
        }
        if (!fallbackError.isEmpty()) {
            QTextStream(stderr) << fallbackError << Qt::endl;
        } else if (directError.isEmpty()) {
            QTextStream(stderr) << "Unable to set mount policy" << Qt::endl;
        } else {
            QTextStream(stderr) << directError << Qt::endl;
        }
        return exitCode;
    }
    printJson(response);
    return 0;
}

int clearMounts() {
    QString error;
    if (!writeMountConfig({}, &error)) {
        QTextStream(stderr) << error << Qt::endl;
        return 4;
    }
    printJson({{QStringLiteral("component"), QStringLiteral("apfs_mount_service")},
               {QStringLiteral("config"), configPath()},
               {QStringLiteral("cleared"), true}});
    return 0;
}

int removeMount(const QStringList& args) {
    const QString target = argumentValue(args, QStringLiteral("--target")).trimmed();
    const QString mount = argumentValue(args, QStringLiteral("--mount")).trimmed();
    int exitCode = 0;
    const QJsonObject response = removeMountConfigJson(target, mount, false, &exitCode);
    if (exitCode != 0) {
        const QString directError = response.value(QStringLiteral("error")).toString();
        const QJsonObject request{{QStringLiteral("command"), QStringLiteral("remove_mount")},
                                  {QStringLiteral("target"), target},
                                  {QStringLiteral("mount"), mount}};
        QString fallbackError;
        if (printServiceFallbackIfOk(request, directError, &fallbackError)) {
            return 0;
        }
        if (!fallbackError.isEmpty()) {
            QTextStream(stderr) << fallbackError << Qt::endl;
        } else if (directError.isEmpty()) {
            QTextStream(stderr) << "Unable to remove mount" << Qt::endl;
        } else {
            QTextStream(stderr) << directError << Qt::endl;
        }
        return exitCode;
    }
    printJson(response);
    return 0;
}

int listMounts() {
    QString error;
    const QVector<MountConfig> mounts = readMountConfig(&error);
    if (!error.isEmpty()) {
        QTextStream(stderr) << error << Qt::endl;
        return 3;
    }
    QJsonArray array;
    for (const auto& mount : mounts) {
        array.append(mountConfigJson(mount));
    }
    printJson({{QStringLiteral("component"), QStringLiteral("apfs_mount_service")},
               {QStringLiteral("config"), configPath()},
               {QStringLiteral("mounts"), array}});
    return 0;
}

int selfTestControlRequests() {
    QTemporaryDir temp;
    if (!temp.isValid()) {
        QTextStream(stderr) << "Unable to create temporary ProgramData root" << Qt::endl;
        return 1;
    }
    qputenv("APFS_FOR_WINDOWS_PROGRAMDATA_ROOT", temp.path().toUtf8());

    const QString target = temp.filePath(QStringLiteral("fixture.apfs"));
    const QJsonObject addResponse =
        applyControlRequest(QJsonObject{{QStringLiteral("command"), QStringLiteral("add_mount")},
                                        {QStringLiteral("target"), target},
                                        {QStringLiteral("mount"), QStringLiteral("Q:")},
                                        {QStringLiteral("read_only"), true},
                                        {QStringLiteral("allow_raw_writes"), false}});
    const QJsonObject rawDeniedResponse = applyControlRequest(
        QJsonObject{{QStringLiteral("command"), QStringLiteral("add_mount")},
                    {QStringLiteral("target"), QStringLiteral("\\\\.\\PhysicalDrive99")},
                    {QStringLiteral("mount"), QStringLiteral("R:")},
                    {QStringLiteral("read_only"), false},
                    {QStringLiteral("allow_raw_writes"), true}});
    const QJsonObject disableResponse =
        applyControlRequest(QJsonObject{{QStringLiteral("command"), QStringLiteral("set_enabled")},
                                        {QStringLiteral("target"), target},
                                        {QStringLiteral("enabled"), false}});
    const QJsonObject writePolicyResponse =
        applyControlRequest(QJsonObject{{QStringLiteral("command"), QStringLiteral("set_policy")},
                                        {QStringLiteral("target"), target},
                                        {QStringLiteral("read_only"), false},
                                        {QStringLiteral("allow_raw_writes"), false}});
    const QJsonObject readOnlyPolicyResponse =
        applyControlRequest(QJsonObject{{QStringLiteral("command"), QStringLiteral("set_policy")},
                                        {QStringLiteral("target"), target},
                                        {QStringLiteral("read_only"), true},
                                        {QStringLiteral("allow_raw_writes"), false}});
    const QJsonObject rawReadWriteDeniedResponse = applyControlRequest(
        QJsonObject{{QStringLiteral("command"), QStringLiteral("set_policy")},
                    {QStringLiteral("target"), QStringLiteral("\\\\.\\PhysicalDrive99")},
                    {QStringLiteral("read_only"), false},
                    {QStringLiteral("allow_raw_writes"), false}});
    const QJsonObject removeResponse =
        applyControlRequest(QJsonObject{{QStringLiteral("command"), QStringLiteral("remove_mount")},
                                        {QStringLiteral("target"), target}});

    const bool ok = addResponse.value(QStringLiteral("ok")).toBool(false) &&
                    addResponse.value(QStringLiteral("via_service")).toBool(false) &&
                    !rawDeniedResponse.value(QStringLiteral("ok")).toBool(true) &&
                    rawDeniedResponse.value(QStringLiteral("exit_code")).toInt() == 8 &&
                    disableResponse.value(QStringLiteral("ok")).toBool(false) &&
                    writePolicyResponse.value(QStringLiteral("ok")).toBool(false) &&
                    writePolicyResponse.value(QStringLiteral("read_only")).toBool(true) == false &&
                    readOnlyPolicyResponse.value(QStringLiteral("ok")).toBool(false) &&
                    readOnlyPolicyResponse.value(QStringLiteral("read_only")).toBool(false) &&
                    !rawReadWriteDeniedResponse.value(QStringLiteral("ok")).toBool(true) &&
                    rawReadWriteDeniedResponse.value(QStringLiteral("exit_code")).toInt() == 8 &&
                    removeResponse.value(QStringLiteral("ok")).toBool(false) &&
                    removeResponse.value(QStringLiteral("removed_count")).toInt() == 1;

    printJson({{QStringLiteral("component"), QStringLiteral("apfs_mount_service")},
               {QStringLiteral("check"), QStringLiteral("service_control_request_self_test")},
               {QStringLiteral("ok"), ok},
               {QStringLiteral("program_data_root"), temp.path()},
               {QStringLiteral("add_response"), addResponse},
               {QStringLiteral("raw_denied_response"), rawDeniedResponse},
               {QStringLiteral("disable_response"), disableResponse},
               {QStringLiteral("write_policy_response"), writePolicyResponse},
               {QStringLiteral("read_only_policy_response"), readOnlyPolicyResponse},
               {QStringLiteral("raw_read_write_denied_response"), rawReadWriteDeniedResponse},
               {QStringLiteral("remove_response"), removeResponse}});
    return ok ? 0 : 1;
}

int selfTestControlIpc() {
    QTemporaryDir temp;
    if (!temp.isValid()) {
        QTextStream(stderr) << "Unable to create temporary ProgramData root" << Qt::endl;
        return 1;
    }
    qputenv("APFS_FOR_WINDOWS_PROGRAMDATA_ROOT", temp.path().toUtf8());

    const QString serverName =
        QStringLiteral("%1.SelfTest.%2").arg(QString::fromLatin1(kLocalControlServerName))
            .arg(QCoreApplication::applicationPid());
    QLocalServer::removeServer(serverName);
    QLocalServer server;
    server.setSocketOptions(QLocalServer::UserAccessOption |
                            QLocalServer::GroupAccessOption |
                            QLocalServer::OtherAccessOption);
    if (!server.listen(serverName)) {
        QTextStream(stderr) << "Unable to listen on self-test IPC server: "
                            << server.errorString() << Qt::endl;
        return 1;
    }

    const QString target = temp.filePath(QStringLiteral("ipc-fixture.apfs"));
    const QJsonObject request{{QStringLiteral("command"), QStringLiteral("add_mount")},
                              {QStringLiteral("target"), target},
                              {QStringLiteral("mount"), QStringLiteral("S:")},
                              {QStringLiteral("read_only"), true},
                              {QStringLiteral("allow_raw_writes"), false}};
    auto future = std::async(std::launch::async, [request, serverName]() {
        QString error;
        const std::optional<QJsonObject> response =
            sendControlRequestToServer(request, serverName, &error);
        if (response.has_value()) {
            return response.value();
        }
        return configErrorJson(125, error);
    });

    const auto deadline = std::chrono::steady_clock::now() +
                          std::chrono::milliseconds(kControlSocketTimeoutMs);
    while (future.wait_for(std::chrono::milliseconds(0)) != std::future_status::ready &&
           std::chrono::steady_clock::now() < deadline) {
        processControlServer(&server);
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }

    bool timedOut = false;
    QJsonObject response;
    if (future.wait_for(std::chrono::milliseconds(0)) == std::future_status::ready) {
        response = future.get();
    } else {
        timedOut = true;
        response = configErrorJson(124, QStringLiteral("IPC self-test timed out."));
    }

    server.close();
    QLocalServer::removeServer(serverName);
    const QVector<MountConfig> mounts = readMountConfig();
    const bool configPersisted =
        std::any_of(mounts.begin(), mounts.end(), [&](const MountConfig& mount) {
            return mount.target.compare(target, Qt::CaseInsensitive) == 0 &&
                   mount.mount.compare(QStringLiteral("S:"), Qt::CaseInsensitive) == 0 &&
                   mount.read_only && !mount.allow_raw_writes && mount.enabled;
        });
    const bool ok = !timedOut && response.value(QStringLiteral("ok")).toBool(false) &&
                    response.value(QStringLiteral("via_service")).toBool(false) &&
                    configPersisted;

    printJson({{QStringLiteral("component"), QStringLiteral("apfs_mount_service")},
               {QStringLiteral("check"), QStringLiteral("service_control_ipc_self_test")},
               {QStringLiteral("ok"), ok},
               {QStringLiteral("server"), serverName},
               {QStringLiteral("program_data_root"), temp.path()},
               {QStringLiteral("timed_out"), timedOut},
               {QStringLiteral("config_persisted"), configPersisted},
               {QStringLiteral("response"), response}});
    return ok ? 0 : 1;
}

int serviceHealth() {
    QString error;
    const QVector<MountConfig> mounts = readMountConfig(&error);
    QJsonArray mountHealth;
    for (const auto& mount : mounts) {
        mountHealth.append(mountHealthJson(mount));
    }
    QJsonObject out{{QStringLiteral("component"), QStringLiteral("apfs_mount_service")},
                    {QStringLiteral("config"), configPath()},
                    {QStringLiteral("service"), queryInstalledService()},
                    {QStringLiteral("mounts"), mountHealth}};
    if (!error.isEmpty()) {
        out.insert(QStringLiteral("config_error"), error);
    }
    printJson(out);
    return error.isEmpty() ? 0 : 3;
}

int discoverApfs(const QStringList& args) {
    const int maxDrives =
        argumentIntValue(args, QStringLiteral("--max-physical-drives"), kDefaultMaxPhysicalDrives);
    const bool includeRoot = !args.contains(QStringLiteral("--no-root-entries"),
                                            Qt::CaseInsensitive);
    const DiscoveryScan scan = discoverApfsVolumes(maxDrives, includeRoot);
    QJsonArray volumes;
    for (const auto& volume : scan.volumes) {
        volumes.append(discoveredVolumeToJson(volume));
    }
    printJson({{QStringLiteral("component"), QStringLiteral("apfs_mount_service")},
               {QStringLiteral("scan"), QStringLiteral("apfs_discovery")},
               {QStringLiteral("max_physical_drives"), std::clamp(maxDrives, 0, 128)},
               {QStringLiteral("disks"), scan.disks},
               {QStringLiteral("volumes"), volumes}});
    return 0;
}

int partitionParserSelfTest() {
    QByteArray image(2 * 1024 * 1024, '\0');
    image[510] = static_cast<char>(0x55);
    image[511] = static_cast<char>(0xaa);
    constexpr qsizetype entry = 446;
    image[entry + 4] = static_cast<char>(0x06);
    const auto writeLe32 = [&](qsizetype offset, quint32 value) {
        for (int i = 0; i < 4; ++i) {
            image[offset + i] = static_cast<char>((value >> (i * 8)) & 0xff);
        }
    };
    writeLe32(entry + 8, 2048);
    writeLe32(entry + 12, 1024);

    QBuffer device(&image);
    const bool opened = device.open(QIODevice::ReadOnly);
    const QVector<PartitionCandidate> partitions = opened ? readPartitions(&device)
                                                           : QVector<PartitionCandidate>{};
    const bool regularOk = partitions.size() == 1 && partitions.first().index == 1 &&
                           partitions.first().scheme == QStringLiteral("MBR") &&
                           partitions.first().mbr_type == 0x06 &&
                           partitions.first().offset_bytes == 1024ULL * 1024ULL &&
                           partitions.first().size_bytes == 512ULL * 1024ULL;

    QByteArray hybridImage = image;
    for (int i = 0; i < 4; ++i) {
        hybridImage[entry + 8 + i] = 0;
    }
    QBuffer hybridDevice(&hybridImage);
    const bool hybridOpened = hybridDevice.open(QIODevice::ReadOnly);
    const QVector<PartitionCandidate> hybridPartitions =
        hybridOpened ? readPartitions(&hybridDevice) : QVector<PartitionCandidate>{};
    const bool hybridOk = hybridPartitions.size() == 1 &&
                          hybridPartitions.first().index == 1 &&
                          hybridPartitions.first().scheme == QStringLiteral("MBR") &&
                          hybridPartitions.first().offset_bytes == 0 &&
                          hybridPartitions.first().size_bytes == 512ULL * 1024ULL;

    DiscoveredApfsVolume hybridVolume;
    hybridVolume.disk_index = 7;
    hybridVolume.target = partitionDevicePath(7, 1);
    hybridVolume.kind = QStringLiteral("mbr_partition");
    hybridVolume.partition = PartitionCandidate{.index = 1,
                                                 .scheme = QStringLiteral("MBR"),
                                                 .mbr_type = 0x06,
                                                 .offset_bytes = 0,
                                                 .size_bytes = 512ULL * 1024ULL};
    DiscoveredApfsVolume wholeDeviceVolume;
    wholeDeviceVolume.disk_index = 7;
    wholeDeviceVolume.target = physicalDrivePath(7);
    wholeDeviceVolume.kind = QStringLiteral("whole_device");
    const QVector<DiscoveredApfsVolume> hybridVolumes{wholeDeviceVolume, hybridVolume};

    QVector<MountConfig> migratedMounts{
        MountConfig{.target = physicalDrivePath(7),
                    .mount = QStringLiteral("U:"),
                    .read_only = false,
                    .allow_raw_writes = true,
                    .enabled = true}};
    const bool migrated = canonicalizeDiscoveredMountAliases(&migratedMounts, hybridVolumes);
    const bool migrationOk = migrated && migratedMounts.size() == 1 &&
                             migratedMounts.first().target == hybridVolume.target &&
                             migratedMounts.first().mount == QStringLiteral("U:") &&
                             !migratedMounts.first().read_only &&
                             migratedMounts.first().allow_raw_writes;

    QVector<MountConfig> duplicateMounts{
        MountConfig{.target = physicalDrivePath(7),
                    .mount = QStringLiteral("U:"),
                    .read_only = true,
                    .allow_raw_writes = false,
                    .enabled = true},
        MountConfig{.target = hybridVolume.target,
                    .mount = QStringLiteral("V:"),
                    .read_only = false,
                    .allow_raw_writes = true,
                    .enabled = true}};
    const bool deduplicated =
        canonicalizeDiscoveredMountAliases(&duplicateMounts, hybridVolumes);
    const bool deduplicationOk = deduplicated && duplicateMounts.size() == 1 &&
                                 duplicateMounts.first().target == hybridVolume.target &&
                                 duplicateMounts.first().mount == QStringLiteral("V:") &&
                                 !duplicateMounts.first().read_only &&
                                 duplicateMounts.first().allow_raw_writes;

    QVector<MountConfig> automaticMounts;
    QJsonArray automaticAdded;
    const bool automaticAddedMount =
        mergeDiscoveredMounts(&automaticMounts, {hybridVolume}, &automaticAdded);
    const bool automaticWritableOk =
        automaticAddedMount && automaticMounts.size() == 1 &&
        !automaticMounts.first().read_only && automaticMounts.first().allow_raw_writes &&
        automaticMounts.first().enabled && automaticAdded.size() == 1;

    QVector<MountConfig> restoredMounts;
    const QVector<MountConfig> preferredReadOnly{
        MountConfig{.target = hybridVolume.target,
                    .mount = QStringLiteral("T:"),
                    .read_only = true,
                    .allow_raw_writes = false,
                    .enabled = true}};
    const bool restoredPreferred =
        mergeDiscoveredMounts(&restoredMounts, {hybridVolume}, nullptr, preferredReadOnly);
    const bool preferredPolicyOk = restoredPreferred && restoredMounts.size() == 1 &&
                                   restoredMounts.first().mount == QStringLiteral("T:") &&
                                   restoredMounts.first().read_only &&
                                   !restoredMounts.first().allow_raw_writes;

    const bool ok = regularOk && hybridOk && migrationOk && deduplicationOk &&
                    automaticWritableOk && preferredPolicyOk;
    printJson(QJsonObject{{QStringLiteral("component"), QStringLiteral("apfs_mount_service")},
                          {QStringLiteral("check"), QStringLiteral("partition_parser_self_test")},
                          {QStringLiteral("ok"), ok},
                          {QStringLiteral("partition_count"), partitions.size()},
                          {QStringLiteral("hybrid_partition_count"), hybridPartitions.size()},
                          {QStringLiteral("hybrid_alias_migration_ok"), migrationOk},
                          {QStringLiteral("hybrid_alias_deduplication_ok"), deduplicationOk},
                          {QStringLiteral("automatic_discovery_writable_ok"), automaticWritableOk},
                          {QStringLiteral("preferred_policy_preserved_ok"), preferredPolicyOk},
                          {QStringLiteral("partition"),
                           partitions.isEmpty() ? QJsonObject{}
                                                : partitionToJson(partitions.first())}});
    return ok ? 0 : 1;
}

int configureDiscoveredMounts(const QStringList& args) {
    const int maxDrives =
        argumentIntValue(args, QStringLiteral("--max-physical-drives"), kDefaultMaxPhysicalDrives);
    QString error;
    QVector<MountConfig> mounts = readMountConfig(&error);
    if (!error.isEmpty()) {
        QTextStream(stderr) << error << Qt::endl;
        return 3;
    }

    const DiscoveryScan scan = discoverApfsVolumes(maxDrives, true);
    QJsonArray aliasActions;
    QJsonArray added;
    const bool aliasesChanged =
        canonicalizeDiscoveredMountAliases(&mounts, scan.volumes, &aliasActions);
    const bool mountsAdded = mergeDiscoveredMounts(&mounts, scan.volumes, &added);
    const bool changed = aliasesChanged || mountsAdded;
    if (changed && !writeMountConfig(mounts, &error)) {
        QTextStream(stderr) << error << Qt::endl;
        return 4;
    }

    QJsonArray configured;
    for (const auto& mount : mounts) {
        configured.append(mountConfigJson(mount));
    }
    QJsonArray volumes;
    for (const auto& volume : scan.volumes) {
        volumes.append(discoveredVolumeToJson(volume));
    }
    printJson({{QStringLiteral("component"), QStringLiteral("apfs_mount_service")},
               {QStringLiteral("scan"), QStringLiteral("apfs_discovery")},
               {QStringLiteral("config"), configPath()},
               {QStringLiteral("changed"), changed},
               {QStringLiteral("alias_actions"), aliasActions},
               {QStringLiteral("added_mounts"), added},
               {QStringLiteral("configured_mounts"), configured},
               {QStringLiteral("volumes"), volumes}});
    return 0;
}

QStringList workerArguments(const MountConfig& mount) {
    QStringList args{QStringLiteral("--target"),
                     mount.target,
                     QStringLiteral("--mount"),
                     mount.mount};
    if (!mount.read_only) {
        args.append(QStringLiteral("--read-write"));
    }
    if (mount.allow_raw_writes) {
        args.append(QStringLiteral("--allow-raw-writes"));
    }
    return args;
}

QVector<MountConfig> enabledMounts(const QVector<MountConfig>& mounts) {
    QVector<MountConfig> enabled;
    for (const auto& mount : mounts) {
        if (mount.enabled) {
            enabled.append(mount);
        }
    }
    return enabled;
}

bool mountTargetAvailable(const MountConfig& mount, QString* error = nullptr) {
    QString openError;
    auto device = sak::openFileOrRawDeviceReadOnly(mount.target, &openError);
    if (!device) {
        if (error) {
            *error = QStringLiteral("open failed: %1").arg(openError);
        }
        return false;
    }
    const uint64_t size = device->size() > 0 ? static_cast<uint64_t>(device->size())
                                             : kFallbackProbeBytes;
    QString detectError;
    const auto detection =
        sak::PartitionFileSystemDetector::detectFromDevice(device.get(), 0, size, &detectError);
    if (!detection.has_value() || !isApfsDetection(*detection)) {
        if (error) {
            *error = detectError.isEmpty() ? QStringLiteral("target is not APFS")
                                           : detectError;
        }
        return false;
    }
    return true;
}

QVector<MountConfig> runnableMounts(const QVector<MountConfig>& mounts) {
    QVector<MountConfig> runnable;
    for (const auto& mount : enabledMounts(mounts)) {
        QString error;
        if (mountTargetAvailable(mount, &error)) {
            runnable.append(mount);
            continue;
        }
        appendServiceLog(QStringLiteral("Skipping unavailable APFS mount %1 -> %2: %3")
                             .arg(mount.target, mount.mount, error));
    }
    return runnable;
}

std::unique_ptr<QProcess> createWorkerProcess(const MountConfig& mount) {
    const QFileInfo serviceInfo(executablePath());
    const QString serviceDir = serviceInfo.absolutePath();
    const QString winFspBin = QStringLiteral("C:\\Program Files (x86)\\WinFsp\\bin");
    QDir().mkpath(logDir());

    auto process = std::make_unique<QProcess>();
    QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
    env.insert(QStringLiteral("PATH"),
               serviceDir + QStringLiteral(";") + winFspBin + QStringLiteral(";") +
                   env.value(QStringLiteral("PATH")));
    env.insert(QStringLiteral("APFS_WORKER_TRACE"),
               QDir(logDir()).filePath(QStringLiteral("worker-%1.trace.txt")
                                           .arg(mount.mount.left(1))));
    process->setProcessEnvironment(env);
    process->setStandardOutputFile(QDir(logDir()).filePath(
        QStringLiteral("worker-%1.stdout.txt").arg(mount.mount.left(1))));
    process->setStandardErrorFile(QDir(logDir()).filePath(
        QStringLiteral("worker-%1.stderr.txt").arg(mount.mount.left(1))));
    return process;
}

bool startWorker(WorkerHandle* worker, const QString& reason) {
    if (!worker) {
        return false;
    }
    worker->last_start_attempt_utc = QDateTime::currentDateTimeUtc();
    worker->process = createWorkerProcess(worker->config);

    const QFileInfo serviceInfo(executablePath());
    const QString serviceDir = serviceInfo.absolutePath();
    const QString workerExe = QDir(serviceDir).filePath(QStringLiteral("apfs_winfs_worker.exe"));
    worker->process->start(workerExe, workerArguments(worker->config));
    if (!worker->process->waitForStarted(10000)) {
        worker->failed_start_count += 1;
        appendServiceLog(QStringLiteral("Failed to start worker for %1 -> %2: %3")
                             .arg(worker->config.target,
                                  worker->config.mount,
                                  worker->process->errorString()));
        worker->process.reset();
        return false;
    }

    worker->start_count += 1;
    worker->failed_start_count = 0;
    appendServiceLog(QStringLiteral("Started worker pid %1 for %2 -> %3 (%4, start %5)")
                         .arg(worker->process->processId())
                         .arg(worker->config.target,
                              worker->config.mount,
                              reason)
                         .arg(worker->start_count));
    return true;
}

std::vector<WorkerHandle> startConfiguredWorkers() {
    std::vector<WorkerHandle> workers;
    QString error;
    const QVector<MountConfig> mounts = readMountConfigWithAutoDiscovery(&error);
    if (!error.isEmpty()) {
        appendServiceLog(error);
        return workers;
    }

    for (const auto& mount : runnableMounts(mounts)) {
        WorkerHandle worker;
        worker.config = mount;
        startWorker(&worker, QStringLiteral("service-start"));
        workers.push_back(std::move(worker));
    }
    return workers;
}

bool sameWorkerConfig(const MountConfig& left, const MountConfig& right) {
    return left.target.compare(right.target, Qt::CaseInsensitive) == 0 &&
           left.mount.compare(right.mount, Qt::CaseInsensitive) == 0 &&
           left.read_only == right.read_only &&
           left.allow_raw_writes == right.allow_raw_writes &&
           left.enabled == right.enabled;
}

QVector<MountConfig> activeWorkerConfigs(const std::vector<WorkerHandle>& workers) {
    QVector<MountConfig> configs;
    for (const auto& worker : workers) {
        configs.append(worker.config);
    }
    return configs;
}

bool containsConfig(const QVector<MountConfig>& configs, const MountConfig& wanted) {
    return std::any_of(configs.begin(),
                       configs.end(),
                       [&](const MountConfig& config) {
                           return sameWorkerConfig(config, wanted);
                       });
}

bool containsWorker(const std::vector<WorkerHandle>& workers, const MountConfig& wanted) {
    return std::any_of(workers.begin(),
                       workers.end(),
                       [&](const WorkerHandle& worker) {
                           return sameWorkerConfig(worker.config, wanted);
                       });
}

void stopWorker(WorkerHandle* worker, const QString& reason) {
    if (!worker || !worker->process || worker->process->state() == QProcess::NotRunning) {
        return;
    }
    appendServiceLog(QStringLiteral("Stopping worker pid %1 for %2 (%3)")
                         .arg(worker->process->processId())
                         .arg(worker->config.mount, reason));
    worker->process->terminate();
    if (!worker->process->waitForFinished(3000)) {
        worker->process->kill();
        worker->process->waitForFinished(3000);
    }
}

void syncConfiguredWorkers(std::vector<WorkerHandle>* workers) {
    QString error;
    const QVector<MountConfig> desired =
        runnableMounts(readMountConfigWithAutoDiscovery(&error, activeWorkerConfigs(*workers)));
    if (!error.isEmpty()) {
        appendServiceLog(error);
        return;
    }

    for (auto it = workers->begin(); it != workers->end();) {
        if (containsConfig(desired, it->config)) {
            ++it;
            continue;
        }
        stopWorker(&(*it), QStringLiteral("config-sync-remove"));
        appendServiceLog(QStringLiteral("Removed worker mapping for %1 -> %2")
                             .arg(it->config.target, it->config.mount));
        it = workers->erase(it);
    }

    for (const auto& mount : desired) {
        if (containsWorker(*workers, mount)) {
            continue;
        }
        WorkerHandle worker;
        worker.config = mount;
        startWorker(&worker, QStringLiteral("config-sync"));
        workers->push_back(std::move(worker));
    }
}

void superviseWorkers(std::vector<WorkerHandle>* workers) {
    const QDateTime now = QDateTime::currentDateTimeUtc();
    for (auto& worker : *workers) {
        if (worker.process) {
            worker.process->waitForFinished(0);
        }
        if (worker.process && worker.process->state() != QProcess::NotRunning) {
            continue;
        }
        if (worker.process) {
            appendServiceLog(QStringLiteral("Worker exited for %1 -> %2: exit_code=%3 exit_status=%4 error=%5")
                                 .arg(worker.config.target,
                                      worker.config.mount,
                                      QString::number(worker.process->exitCode()),
                                      QString::number(static_cast<int>(worker.process->exitStatus())),
                                      worker.process->errorString()));
            worker.process.reset();
        }
        if (worker.last_start_attempt_utc.isValid() &&
            worker.last_start_attempt_utc.msecsTo(now) < 5000) {
            continue;
        }
        startWorker(&worker, QStringLiteral("supervisor"));
    }
}

void stopWorkers(std::vector<WorkerHandle>* workers) {
    for (auto& worker : *workers) {
        stopWorker(&worker, QStringLiteral("service-stop"));
    }
    workers->clear();
}

void setServiceStatus(DWORD state, DWORD win32ExitCode = NO_ERROR, DWORD waitHintMs = 0) {
    g_status.dwServiceType = SERVICE_WIN32_OWN_PROCESS;
    g_status.dwCurrentState = state;
    g_status.dwControlsAccepted = state == SERVICE_RUNNING ? SERVICE_ACCEPT_STOP : 0;
    g_status.dwWin32ExitCode = win32ExitCode;
    g_status.dwWaitHint = waitHintMs;
    SetServiceStatus(g_statusHandle, &g_status);
}

bool isStorageDeviceEvent(DWORD eventType) {
    return eventType == DBT_DEVICEARRIVAL || eventType == DBT_DEVICEREMOVECOMPLETE ||
           eventType == DBT_DEVNODES_CHANGED;
}

QString deviceEventName(DWORD eventType) {
    switch (eventType) {
    case DBT_DEVICEARRIVAL:
        return QStringLiteral("arrival");
    case DBT_DEVICEREMOVECOMPLETE:
        return QStringLiteral("remove-complete");
    case DBT_DEVNODES_CHANGED:
        return QStringLiteral("devnodes-changed");
    default:
        return QStringLiteral("event-%1").arg(eventType);
    }
}

bool registerDiskDeviceNotifications() {
    DEV_BROADCAST_DEVICEINTERFACE_W filter{};
    filter.dbcc_size = sizeof(filter);
    filter.dbcc_devicetype = DBT_DEVTYP_DEVICEINTERFACE;
    filter.dbcc_classguid = kDiskDeviceInterfaceGuid;
    g_deviceNotification =
        RegisterDeviceNotificationW(g_statusHandle, &filter, DEVICE_NOTIFY_SERVICE_HANDLE);
    if (!g_deviceNotification) {
        appendServiceLog(QStringLiteral("Disk device notification registration failed: %1")
                             .arg(winError(GetLastError())));
        return false;
    }
    appendServiceLog(QStringLiteral("Registered disk device notifications for APFS resync"));
    return true;
}

void unregisterDiskDeviceNotifications() {
    if (g_deviceNotification) {
        UnregisterDeviceNotification(g_deviceNotification);
        g_deviceNotification = nullptr;
        appendServiceLog(QStringLiteral("Unregistered disk device notifications"));
    }
}

void writeControlResponse(QLocalSocket* socket, const QJsonObject& response) {
    if (!socket) {
        return;
    }
    QByteArray payload = QJsonDocument(response).toJson(QJsonDocument::Compact);
    payload.append('\n');
    socket->write(payload);
    socket->waitForBytesWritten(kControlSocketTimeoutMs);
    socket->disconnectFromServer();
}

void processControlConnection(QLocalSocket* socket) {
    if (!socket) {
        return;
    }
    while (!socket->canReadLine()) {
        if (!socket->waitForReadyRead(kControlSocketTimeoutMs)) {
            writeControlResponse(
                socket,
                configErrorJson(124,
                                QStringLiteral("Timed out waiting for service command payload.")));
            return;
        }
    }

    QJsonParseError parseError{};
    const QJsonDocument request =
        QJsonDocument::fromJson(socket->readLine().trimmed(), &parseError);
    if (parseError.error != QJsonParseError::NoError || !request.isObject()) {
        writeControlResponse(socket,
                             configErrorJson(2,
                                             QStringLiteral("Invalid service command JSON: %1")
                                                 .arg(parseError.errorString())));
        return;
    }
    writeControlResponse(socket, applyControlRequest(request.object()));
}

void processControlServer(QLocalServer* server) {
    if (!server || !server->isListening()) {
        return;
    }
    bool timedOut = false;
    server->waitForNewConnection(0, &timedOut);
    for (int handled = 0; handled < 8 && server->hasPendingConnections(); ++handled) {
        std::unique_ptr<QLocalSocket> socket(server->nextPendingConnection());
        processControlConnection(socket.get());
    }
}

DWORD WINAPI serviceControlHandler(DWORD control, DWORD eventType, LPVOID, LPVOID) {
    if (control == SERVICE_CONTROL_STOP && g_stopEvent) {
        setServiceStatus(SERVICE_STOP_PENDING, NO_ERROR, 2000);
        SetEvent(g_stopEvent);
        return NO_ERROR;
    }
    if (control == SERVICE_CONTROL_DEVICEEVENT && isStorageDeviceEvent(eventType)) {
        appendServiceLog(QStringLiteral("Disk device event %1; scheduling APFS resync")
                             .arg(deviceEventName(eventType)));
        if (g_resyncEvent) {
            SetEvent(g_resyncEvent);
        }
        return NO_ERROR;
    }
    return ERROR_CALL_NOT_IMPLEMENTED;
}

void WINAPI serviceMain(DWORD, LPWSTR*) {
    g_statusHandle = RegisterServiceCtrlHandlerExW(kServiceName, serviceControlHandler, nullptr);
    if (!g_statusHandle) {
        return;
    }
    setServiceStatus(SERVICE_START_PENDING, NO_ERROR, 2000);
    g_stopEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (!g_stopEvent) {
        setServiceStatus(SERVICE_STOPPED, GetLastError());
        return;
    }
    g_resyncEvent = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    if (!g_resyncEvent) {
        const DWORD error = GetLastError();
        CloseHandle(g_stopEvent);
        g_stopEvent = nullptr;
        setServiceStatus(SERVICE_STOPPED, error);
        return;
    }
    registerDiskDeviceNotifications();

    QLocalServer controlServer;
    QLocalServer::removeServer(QString::fromLatin1(kLocalControlServerName));
    controlServer.setSocketOptions(QLocalServer::UserAccessOption |
                                   QLocalServer::GroupAccessOption |
                                   QLocalServer::OtherAccessOption);
    if (controlServer.listen(QString::fromLatin1(kLocalControlServerName))) {
        appendServiceLog(QStringLiteral("Service control IPC listening on %1")
                             .arg(QString::fromLatin1(kLocalControlServerName)));
    } else {
        appendServiceLog(QStringLiteral("Service control IPC unavailable: %1")
                             .arg(controlServer.errorString()));
    }

    std::vector<WorkerHandle> workers = startConfiguredWorkers();
    setServiceStatus(SERVICE_RUNNING);
    QDateTime lastSync = QDateTime::currentDateTimeUtc();
    HANDLE waitHandles[] = {g_stopEvent, g_resyncEvent};
    for (;;) {
        const DWORD waitResult =
            WaitForMultipleObjects(static_cast<DWORD>(std::size(waitHandles)),
                                   waitHandles,
                                   FALSE,
                                   kServiceWaitSliceMs);
        if (waitResult == WAIT_OBJECT_0) {
            break;
        }
        processControlServer(&controlServer);
        const bool deviceSyncRequested = waitResult == WAIT_OBJECT_0 + 1;
        if (deviceSyncRequested) {
            Sleep(kDeviceChangeSettleMs);
        }
        const QDateTime now = QDateTime::currentDateTimeUtc();
        if (deviceSyncRequested || lastSync.msecsTo(now) >= kServiceSyncIntervalMs) {
            syncConfiguredWorkers(&workers);
            lastSync = QDateTime::currentDateTimeUtc();
        }
        superviseWorkers(&workers);
    }

    setServiceStatus(SERVICE_STOP_PENDING, NO_ERROR, 1000);
    controlServer.close();
    QLocalServer::removeServer(QString::fromLatin1(kLocalControlServerName));
    stopWorkers(&workers);
    unregisterDiskDeviceNotifications();
    CloseHandle(g_resyncEvent);
    g_resyncEvent = nullptr;
    CloseHandle(g_stopEvent);
    g_stopEvent = nullptr;
    setServiceStatus(SERVICE_STOPPED);
}

int installService() {
    const QString path = executablePath();
    if (path.isEmpty()) {
        QTextStream(stderr) << "Unable to resolve executable path" << Qt::endl;
        return 2;
    }
    const QString command = QStringLiteral("\"%1\"").arg(path);
    SC_HANDLE scm = OpenSCManagerW(nullptr, nullptr, SC_MANAGER_CREATE_SERVICE);
    if (!scm) {
        QTextStream(stderr) << "OpenSCManager failed: " << winError(GetLastError()) << Qt::endl;
        return 3;
    }
    SC_HANDLE service = CreateServiceW(scm,
                                       kServiceName,
                                       kDisplayName,
                                       SERVICE_ALL_ACCESS,
                                       SERVICE_WIN32_OWN_PROCESS,
                                       SERVICE_AUTO_START,
                                       SERVICE_ERROR_NORMAL,
                                       reinterpret_cast<LPCWSTR>(command.utf16()),
                                       nullptr,
                                       nullptr,
                                       nullptr,
                                       nullptr,
                                       nullptr);
    bool created = true;
    if (!service) {
        const DWORD error = GetLastError();
        if (error != ERROR_SERVICE_EXISTS) {
            CloseServiceHandle(scm);
            QTextStream(stderr) << "CreateService failed: " << winError(error) << Qt::endl;
            return 4;
        }
        created = false;
        service = OpenServiceW(scm, kServiceName, SERVICE_CHANGE_CONFIG | SERVICE_QUERY_CONFIG);
        if (!service) {
            const DWORD openError = GetLastError();
            CloseServiceHandle(scm);
            QTextStream(stderr) << "Open existing service failed: " << winError(openError)
                                << Qt::endl;
            return 5;
        }
        if (!ChangeServiceConfigW(service,
                                  SERVICE_NO_CHANGE,
                                  SERVICE_AUTO_START,
                                  SERVICE_ERROR_NORMAL,
                                  reinterpret_cast<LPCWSTR>(command.utf16()),
                                  nullptr,
                                  nullptr,
                                  nullptr,
                                  nullptr,
                                  nullptr,
                                  kDisplayName)) {
            const DWORD configError = GetLastError();
            CloseServiceHandle(service);
            CloseServiceHandle(scm);
            QTextStream(stderr) << "ChangeServiceConfig failed: " << winError(configError)
                                << Qt::endl;
            return 6;
        }
    }
    QString recoveryError;
    if (!configureServiceRecoveryPolicy(service, &recoveryError)) {
        CloseServiceHandle(service);
        CloseServiceHandle(scm);
        QTextStream(stderr) << recoveryError << Qt::endl;
        return 7;
    }
    const QJsonObject recovery = queryServiceRecoveryPolicy(service);
    CloseServiceHandle(service);
    CloseServiceHandle(scm);
    printJson({{QStringLiteral("component"), QStringLiteral("apfs_mount_service")},
               {QStringLiteral("installed"), true},
               {QStringLiteral("created"), created},
               {QStringLiteral("start_type"), QStringLiteral("automatic")},
               {QStringLiteral("recovery"), recovery}});
    return 0;
}

int uninstallService() {
    SC_HANDLE scm = OpenSCManagerW(nullptr, nullptr, SC_MANAGER_CONNECT);
    if (!scm) {
        QTextStream(stderr) << "OpenSCManager failed: " << winError(GetLastError()) << Qt::endl;
        return 3;
    }
    SC_HANDLE service = OpenServiceW(scm, kServiceName, SERVICE_STOP | DELETE | SERVICE_QUERY_STATUS);
    if (!service) {
        const DWORD error = GetLastError();
        CloseServiceHandle(scm);
        QTextStream(stderr) << "OpenService failed: " << winError(error) << Qt::endl;
        return error == ERROR_SERVICE_DOES_NOT_EXIST ? 0 : 4;
    }
    bool stopRequested = false;
    bool alreadyStopped = false;
    QString stopError;
    const bool stopped =
        stopServiceAndWait(service, 30000, &stopRequested, &alreadyStopped, &stopError);
    if (!stopped) {
        CloseServiceHandle(service);
        CloseServiceHandle(scm);
        QTextStream(stderr) << stopError << Qt::endl;
        return 6;
    }
    if (!DeleteService(service)) {
        const DWORD error = GetLastError();
        CloseServiceHandle(service);
        CloseServiceHandle(scm);
        QTextStream(stderr) << "DeleteService failed: " << winError(error) << Qt::endl;
        return 7;
    }
    CloseServiceHandle(service);
    CloseServiceHandle(scm);
    printJson({{QStringLiteral("component"), QStringLiteral("apfs_mount_service")},
               {QStringLiteral("uninstalled"), true},
               {QStringLiteral("stop_requested"), stopRequested},
               {QStringLiteral("already_stopped"), alreadyStopped},
               {QStringLiteral("stopped_before_delete"), stopped}});
    return 0;
}

int runServiceDispatcher() {
    SERVICE_TABLE_ENTRYW table[] = {{const_cast<LPWSTR>(kServiceName), serviceMain},
                                    {nullptr, nullptr}};
    if (!StartServiceCtrlDispatcherW(table)) {
        QTextStream(stderr) << "StartServiceCtrlDispatcher failed: "
                            << winError(GetLastError()) << Qt::endl;
        return 5;
    }
    return 0;
}

int runConsole() {
    QString error;
    const QVector<MountConfig> mounts = readMountConfig(&error);
    QJsonArray array;
    for (const auto& mount : mounts) {
        array.append(mountConfigJson(mount));
    }
    printJson({{QStringLiteral("component"), QStringLiteral("apfs_mount_service")},
               {QStringLiteral("status"), QStringLiteral("console-ok")},
               {QStringLiteral("auto_start_goal"), true},
               {QStringLiteral("auto_discovery"), true},
               {QStringLiteral("service_name"), QString::fromWCharArray(kServiceName)},
               {QStringLiteral("config"), configPath()},
               {QStringLiteral("configured_mounts"), array}});
    return 0;
}

int selfTestLogRotation() {
    QTemporaryDir temporaryRoot;
    if (!temporaryRoot.isValid()) {
        return 1;
    }
    qputenv("APFS_FOR_WINDOWS_PROGRAMDATA_ROOT", temporaryRoot.path().toUtf8());
    QDir().mkpath(logDir());

    const QString servicePath =
        QDir(logDir()).filePath(QStringLiteral("apfs_mount_service.log"));
    const QString legacyWorkerPath =
        QDir(logDir()).filePath(QStringLiteral("worker-legacy.trace.txt"));
    for (const QString& path : {servicePath, legacyWorkerPath}) {
        QFile oversized(path);
        if (!oversized.open(QIODevice::WriteOnly) ||
            !oversized.resize(kMaxLogBytes * 2 + 1)) {
            return 1;
        }
    }

    appendServiceLog(QStringLiteral("log-rotation-self-test"));
    const QFileInfo serviceInfo(servicePath);
    const QFileInfo legacyWorkerInfo(legacyWorkerPath);
    const bool ok = serviceInfo.exists() && serviceInfo.size() > 0 &&
                    serviceInfo.size() < kMaxLogBytes && !legacyWorkerInfo.exists();
    printJson({{QStringLiteral("component"), QStringLiteral("apfs_mount_service")},
               {QStringLiteral("check"), QStringLiteral("log_rotation")},
               {QStringLiteral("ok"), ok},
               {QStringLiteral("max_log_bytes"), QString::number(kMaxLogBytes)},
               {QStringLiteral("service_log_bytes"), QString::number(serviceInfo.size())},
               {QStringLiteral("legacy_worker_log_removed"), !legacyWorkerInfo.exists()}});
    return ok ? 0 : 1;
}
#endif

}  // namespace

int main(int argc, char* argv[]) {
    QCoreApplication app(argc, argv);
    const QStringList args = app.arguments();

#ifdef Q_OS_WIN
    if (args.contains(QStringLiteral("--install"), Qt::CaseInsensitive)) {
        return installService();
    }
    if (args.contains(QStringLiteral("--uninstall"), Qt::CaseInsensitive)) {
        return uninstallService();
    }
    if (args.contains(QStringLiteral("--add-mount"), Qt::CaseInsensitive)) {
        return addMount(args);
    }
    if (args.contains(QStringLiteral("--set-mount"), Qt::CaseInsensitive)) {
        return setMount(args);
    }
    if (args.contains(QStringLiteral("--set-enabled"), Qt::CaseInsensitive)) {
        return setMountEnabled(args);
    }
    if (args.contains(QStringLiteral("--set-policy"), Qt::CaseInsensitive)) {
        return setMountPolicy(args);
    }
    if (args.contains(QStringLiteral("--clear-mounts"), Qt::CaseInsensitive)) {
        return clearMounts();
    }
    if (args.contains(QStringLiteral("--remove-mount"), Qt::CaseInsensitive)) {
        return removeMount(args);
    }
    if (args.contains(QStringLiteral("--list-mounts"), Qt::CaseInsensitive)) {
        return listMounts();
    }
    if (args.contains(QStringLiteral("--discover-apfs"), Qt::CaseInsensitive)) {
        return discoverApfs(args);
    }
    if (args.contains(QStringLiteral("--self-test-partitions"), Qt::CaseInsensitive)) {
        return partitionParserSelfTest();
    }
    if (args.contains(QStringLiteral("--target-identity"), Qt::CaseInsensitive)) {
        return targetIdentityDiagnostic(args);
    }
    if (args.contains(QStringLiteral("--configure-discovered"), Qt::CaseInsensitive)) {
        return configureDiscoveredMounts(args);
    }
    if (args.contains(QStringLiteral("--health"), Qt::CaseInsensitive)) {
        return serviceHealth();
    }
    if (args.contains(QStringLiteral("--self-test-control"), Qt::CaseInsensitive)) {
        return selfTestControlRequests();
    }
    if (args.contains(QStringLiteral("--self-test-ipc"), Qt::CaseInsensitive)) {
        return selfTestControlIpc();
    }
    if (args.contains(QStringLiteral("--self-test-log-rotation"), Qt::CaseInsensitive)) {
        return selfTestLogRotation();
    }
    if (args.contains(QStringLiteral("--run-console"), Qt::CaseInsensitive)) {
        return runConsole();
    }
    return runServiceDispatcher();
#else
    Q_UNUSED(args);
    printJson({{QStringLiteral("component"), QStringLiteral("apfs_mount_service")},
               {QStringLiteral("status"), QStringLiteral("windows-only")}});
    return 0;
#endif
}
