// Copyright (c) 2026 Randy Northrup. All rights reserved.

#include "sak/partition_apfs_file_system_reader.h"
#include "sak/partition_apfs_writer.h"
#include "sak/partition_file_system_detector.h"
#include "sak/partition_raw_device_io.h"

#include <QByteArray>
#include <QCommandLineOption>
#include <QCommandLineParser>
#include <QCoreApplication>
#include <QCryptographicHash>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QIODevice>
#include <QJsonDocument>
#include <QJsonObject>
#include <QMutex>
#include <QMutexLocker>
#include <QProcess>
#include <QString>
#include <QStringList>
#include <QTextStream>
#include <QUuid>
#include <QVector>

#include <algorithm>
#include <atomic>
#include <cstdint>
#include <cstring>
#include <limits>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#if APFS_HAVE_WINFSP
#include <windows.h>
#include <winternl.h>
#ifndef PNTSTATUS
using PNTSTATUS = NTSTATUS*;
#endif
#include <sddl.h>
#include <winfsp/winfsp.h>
#endif

namespace {

constexpr uint64_t kFallbackProbeBytes = 1024ULL * 1024ULL * 1024ULL;
constexpr uint64_t kDefaultMaxFileReadBytes = std::numeric_limits<uint64_t>::max();
constexpr uint64_t kDefaultMaxMutationBytes = 64ULL * 1024ULL * 1024ULL;
constexpr uint64_t kAllocationUnit = 4096;
constexpr qint64 kMaxTraceBytes = 8LL * 1024LL * 1024LL;

QString normalizeApfsPath(const QString& input) {
    QString path = input.trimmed();
    path.replace(QLatin1Char('\\'), QLatin1Char('/'));
    while (path.contains(QStringLiteral("//"))) {
        path.replace(QStringLiteral("//"), QStringLiteral("/"));
    }
    if (path.isEmpty() || path == QStringLiteral("/")) {
        return QStringLiteral("/");
    }
    if (!path.startsWith(QLatin1Char('/'))) {
        path.prepend(QLatin1Char('/'));
    }
    while (path.size() > 1 && path.endsWith(QLatin1Char('/'))) {
        path.chop(1);
    }
    return path;
}

QString parentPath(const QString& path) {
    const QString normalized = normalizeApfsPath(path);
    if (normalized == QStringLiteral("/")) {
        return QStringLiteral("/");
    }
    const qsizetype slash = normalized.lastIndexOf(QLatin1Char('/'));
    if (slash <= 0) {
        return QStringLiteral("/");
    }
    return normalized.left(slash);
}

QString baseName(const QString& path) {
    const QString normalized = normalizeApfsPath(path);
    if (normalized == QStringLiteral("/")) {
        return QStringLiteral("/");
    }
    const qsizetype slash = normalized.lastIndexOf(QLatin1Char('/'));
    return slash >= 0 ? normalized.mid(slash + 1) : normalized;
}

bool isRootChildPath(const QString& path) {
    const QString normalized = normalizeApfsPath(path);
    return normalized != QStringLiteral("/") &&
           normalized.count(QLatin1Char('/')) == 1 &&
           !baseName(normalized).isEmpty();
}

QStringList pathComponents(const QString& path) {
    QString normalized = normalizeApfsPath(path);
    if (normalized == QStringLiteral("/")) {
        return {};
    }
    if (normalized.startsWith(QLatin1Char('/'))) {
        normalized.remove(0, 1);
    }
    return normalized.split(QLatin1Char('/'), Qt::SkipEmptyParts);
}

bool splitMutableFilePath(const QString& path, QString* parentDirectoryPath, QString* fileName) {
    const QStringList parts = pathComponents(path);
    if (parts.isEmpty()) {
        return false;
    }
    if (parentDirectoryPath) {
        if (parts.size() == 1) {
            parentDirectoryPath->clear();
        } else {
            *parentDirectoryPath =
                QStringLiteral("/") + parts.mid(0, parts.size() - 1).join(QLatin1Char('/'));
        }
    }
    if (fileName) {
        *fileName = parts.last();
    }
    return true;
}

bool splitMutableRootDirectoryPath(const QString& path, QString* directoryName) {
    const QStringList parts = pathComponents(path);
    if (parts.isEmpty()) {
        return false;
    }
    if (directoryName) {
        *directoryName = parts.join(QLatin1Char('/'));
    }
    return true;
}

bool splitDirectoryCreatePath(const QString& path, QString* parentDirectoryPath, QString* directoryName) {
    const QStringList parts = pathComponents(path);
    if (parts.isEmpty()) {
        return false;
    }
    if (directoryName) {
        *directoryName = parts.last();
    }
    if (parentDirectoryPath) {
        if (parts.size() == 1) {
            parentDirectoryPath->clear();
        } else {
            *parentDirectoryPath =
                QStringLiteral("/") + parts.mid(0, parts.size() - 1).join(QLatin1Char('/'));
        }
    }
    return true;
}

bool looksLikeWindowsRawTarget(const QString& target) {
    return target.startsWith(QStringLiteral("\\\\.\\"), Qt::CaseInsensitive) ||
           target.startsWith(QStringLiteral("\\\\?\\"), Qt::CaseInsensitive);
}

uint64_t alignAllocation(uint64_t size) {
    if (size == 0) {
        return 0;
    }
    if (size > std::numeric_limits<uint64_t>::max() - (kAllocationUnit - 1)) {
        return size;
    }
    return ((size + kAllocationUnit - 1) / kAllocationUnit) * kAllocationUnit;
}

#if APFS_HAVE_WINFSP

QMutex gTraceMutex;

void trace(const QString& message) {
    const QString path = QString::fromLocal8Bit(qgetenv("APFS_WORKER_TRACE"));
    if (path.isEmpty()) {
        return;
    }
    QMutexLocker locker(&gTraceMutex);
    const QFileInfo traceInfo(path);
    if (traceInfo.exists() && traceInfo.size() >= kMaxTraceBytes) {
        const QString archivePath = path + QStringLiteral(".1");
        QFile::remove(archivePath);
        if (traceInfo.size() > kMaxTraceBytes * 2) {
            QFile::remove(path);
        } else {
            QFile::rename(path, archivePath);
        }
    }
    QFile file(path);
    if (!file.open(QIODevice::WriteOnly | QIODevice::Append | QIODevice::Text)) {
        return;
    }
    QTextStream(&file) << QDateTime::currentDateTimeUtc().toString(Qt::ISODateWithMs) << " "
                       << message << Qt::endl;
}

std::atomic_bool gStopRequested{false};
FSP_FILE_SYSTEM* gFileSystemForSignal{nullptr};

BOOL WINAPI consoleHandler(DWORD controlType) {
    switch (controlType) {
    case CTRL_C_EVENT:
    case CTRL_BREAK_EVENT:
    case CTRL_CLOSE_EVENT:
    case CTRL_SHUTDOWN_EVENT:
        gStopRequested = true;
        if (gFileSystemForSignal) {
            FspFileSystemStopDispatcher(gFileSystemForSignal);
        }
        return TRUE;
    default:
        return FALSE;
    }
}

uint64_t currentFileTime() {
    FILETIME fileTime{};
    GetSystemTimeAsFileTime(&fileTime);
    ULARGE_INTEGER value{};
    value.LowPart = fileTime.dwLowDateTime;
    value.HighPart = fileTime.dwHighDateTime;
    return value.QuadPart;
}

std::wstring wide(const QString& value) {
    return value.toStdWString();
}

QString fromWide(PWSTR value) {
    return normalizeApfsPath(value ? QString::fromWCharArray(value) : QStringLiteral("/"));
}

void copyVolumeLabel(const QString& label, FSP_FSCTL_VOLUME_INFO* volumeInfo) {
    const std::wstring labelWide = wide(label.left(32));
    const auto bytes = static_cast<UINT16>(
        std::min<size_t>(labelWide.size() * sizeof(wchar_t), sizeof(volumeInfo->VolumeLabel)));
    volumeInfo->VolumeLabelLength = bytes;
    std::memset(volumeInfo->VolumeLabel, 0, sizeof(volumeInfo->VolumeLabel));
    if (bytes != 0) {
        std::memcpy(volumeInfo->VolumeLabel, labelWide.data(), bytes);
    }
}

struct ResolvedEntry {
    QString path;
    QString name;
    bool directory{false};
    bool regularFile{false};
    bool symlink{false};
    uint64_t objectId{1};
    uint64_t sizeBytes{0};
};

struct FileContext {
    uint64_t handleId{0};
    ResolvedEntry entry;
    bool createdByThisHandle{false};
    bool stagedWriteActive{false};
    bool stagedWriteDirty{false};
    bool deletePending{false};
    bool closed{false};
    QByteArray stagedWriteData;
    QString stagedWritePath;
    bool stagedWriteFileBacked{false};
};

class ApfsMountState {
public:
    ~ApfsMountState() {
        if (securityDescriptor_) {
            LocalFree(securityDescriptor_);
        }
    }

    NTSTATUS openTarget(const QString& target,
                        uint64_t maxFileReadBytes,
                        bool readOnly,
                        bool allowRawWrites,
                        QString* error) {
        target_ = target;
        readOnly_ = readOnly;
        allowRawWrites_ = allowRawWrites;
        maxFileReadBytes_ = maxFileReadBytes == 0 ? kDefaultMaxFileReadBytes : maxFileReadBytes;
        createdTime_ = currentFileTime();
        rawTarget_ = looksLikeWindowsRawTarget(target_);
        if (!readOnly_ && rawTarget_ && !allowRawWrites_) {
            if (error) {
                *error = QStringLiteral(
                    "raw APFS write mount requires --allow-raw-writes and explicit media proof");
            }
            return STATUS_ACCESS_DENIED;
        }
        QString openError;
        device_ = sak::openFileOrRawDeviceReadOnly(target, &openError);
        if (!device_) {
            if (error) {
                *error = QStringLiteral("open failed: %1").arg(openError);
            }
            return STATUS_ACCESS_DENIED;
        }

        QString detectError;
        const uint64_t size = device_->size() > 0 ? static_cast<uint64_t>(device_->size())
                                                  : kFallbackProbeBytes;
        const auto detection =
            sak::PartitionFileSystemDetector::detectFromDevice(device_.get(), 0, size, &detectError);
        if (!detection.has_value() ||
            detection->file_system.compare(QStringLiteral("APFS"), Qt::CaseInsensitive) != 0) {
            if (error) {
                *error = detectError.isEmpty() ? QStringLiteral("target is not APFS")
                                               : detectError;
            }
            return STATUS_UNRECOGNIZED_VOLUME;
        }

        totalBytes_ = detection->total_bytes;
        freeBytes_ = detection->free_bytes;
        targetContainerBytes_ = detection->total_bytes != 0 ? detection->total_bytes : size;

        readerSession_ =
            std::make_unique<sak::PartitionApfsFileSystemReaderSession>(device_.get());
        const auto root = readerSession_->listDirectory(QStringLiteral("/"), 1);
        if (!root.volume_name.trimmed().isEmpty()) {
            volumeLabel_ = root.volume_name.trimmed().left(32);
        }
        if (volumeLabel_.isEmpty()) {
            volumeLabel_ = QStringLiteral("APFS");
        }
        if (!root.blockers.isEmpty()) {
            if (error) {
                *error = root.blockers.join(QStringLiteral("; "));
            }
            return STATUS_ACCESS_DENIED;
        }

        if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
                readOnly_ ? L"O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;FR;;;BU)(A;;FR;;;WD)"
                          : L"O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;FA;;;BU)(A;;FA;;;WD)",
                SDDL_REVISION_1,
                &securityDescriptor_,
                &securityDescriptorSize_)) {
            if (error) {
                *error = QStringLiteral("security descriptor creation failed");
            }
            return FspNtStatusFromWin32(GetLastError());
        }

        return STATUS_SUCCESS;
    }

    NTSTATUS volumeInfo(FSP_FSCTL_VOLUME_INFO* info) const {
        info->TotalSize = totalBytes_;
        info->FreeSize = freeBytes_;
        copyVolumeLabel(volumeLabel_, info);
        return STATUS_SUCCESS;
    }

    NTSTATUS resolvePath(const QString& path, ResolvedEntry* resolved) {
        const QString normalized = normalizeApfsPath(path);
        QMutexLocker locker(&ioMutex_);
        return resolvePathNoLock(normalized, resolved);
    }

    NTSTATUS readFile(const FileContext* context,
                      uint64_t offset,
                      ULONG length,
                      void* buffer,
                      PULONG transferred) {
        if (!context) {
            return STATUS_INVALID_PARAMETER;
        }
        const ResolvedEntry& entry = context->entry;
        if (entry.directory) {
            return STATUS_INVALID_DEVICE_REQUEST;
        }
        if (context->stagedWriteActive) {
            if (context->stagedWriteFileBacked) {
                return readHostFileBytes(context->stagedWritePath, offset, length, buffer, transferred);
            }
            return readBytes(context->stagedWriteData, offset, length, buffer, transferred);
        }
        if (offset >= entry.sizeBytes) {
            return STATUS_END_OF_FILE;
        }
        if (offset >= maxFileReadBytes_) {
            return STATUS_END_OF_FILE;
        }
        const uint64_t available = std::min<uint64_t>(entry.sizeBytes - offset,
                                                      maxFileReadBytes_ - offset);
        const uint64_t bytesNeeded = std::min<uint64_t>(length, available);

        QMutexLocker locker(&ioMutex_);
        const auto file = readerSession_->readFileRange(entry.path, offset, bytesNeeded);
        if (!file.ok || !file.blockers.isEmpty()) {
            return STATUS_ACCESS_DENIED;
        }
        if (file.data.isEmpty()) {
            return STATUS_END_OF_FILE;
        }
        const ULONG toCopy = static_cast<ULONG>(
            std::min<uint64_t>(length, static_cast<uint64_t>(file.data.size())));
        std::memcpy(buffer, file.data.constData(), toCopy);
        *transferred = toCopy;
        return STATUS_SUCCESS;
    }

    NTSTATUS listDirectory(const ResolvedEntry& directory,
                           PWSTR marker,
                           void* buffer,
                           ULONG length,
                           PULONG transferred) {
        if (!directory.directory) {
            return STATUS_NOT_A_DIRECTORY;
        }

        QMutexLocker locker(&ioMutex_);
        const auto listing = readerSession_->listDirectory(
            directory.path, sak::kPartitionApfsDefaultBrowseEntryLimit);
        if (!listing.blockers.isEmpty()) {
            return STATUS_OBJECT_NAME_NOT_FOUND;
        }

        QVector<sak::PartitionApfsFileEntry> entries = listing.entries;
        std::sort(entries.begin(), entries.end(), [](const auto& left, const auto& right) {
            const int ci = left.name.compare(right.name, Qt::CaseInsensitive);
            if (ci != 0) {
                return ci < 0;
            }
            return left.name < right.name;
        });

        const QString markerName = marker ? QString::fromWCharArray(marker) : QString{};
        for (const auto& entry : entries) {
            if (!markerName.isEmpty() &&
                entry.name.compare(markerName, Qt::CaseInsensitive) <= 0) {
                continue;
            }
            ResolvedEntry resolved;
            fillResolved(entry, entry.path, &resolved);
            if (!addDirInfo(resolved, entry.name, buffer, length, transferred)) {
                return STATUS_SUCCESS;
            }
        }
        FspFileSystemAddDirInfo(nullptr, buffer, length, transferred);
        return STATUS_SUCCESS;
    }

    NTSTATUS securityByName(const QString& path,
                            PUINT32 attributes,
                            PSECURITY_DESCRIPTOR descriptor,
                            SIZE_T* descriptorSize) {
        ResolvedEntry entry;
        NTSTATUS status = resolvePath(path, &entry);
        if (!NT_SUCCESS(status)) {
            return status;
        }
        if (attributes) {
            *attributes = attributesFor(entry);
        }
        return copySecurity(descriptor, descriptorSize);
    }

    NTSTATUS copySecurity(PSECURITY_DESCRIPTOR descriptor, SIZE_T* descriptorSize) const {
        if (!descriptorSize) {
            return STATUS_SUCCESS;
        }
        if (securityDescriptorSize_ > *descriptorSize) {
            *descriptorSize = securityDescriptorSize_;
            return STATUS_BUFFER_OVERFLOW;
        }
        *descriptorSize = securityDescriptorSize_;
        if (descriptor && securityDescriptorSize_ != 0) {
            std::memcpy(descriptor, securityDescriptor_, securityDescriptorSize_);
        }
        return STATUS_SUCCESS;
    }

    void fillFileInfo(const ResolvedEntry& entry, FSP_FSCTL_FILE_INFO* info) const {
        std::memset(info, 0, sizeof(*info));
        info->FileAttributes = attributesFor(entry);
        info->AllocationSize = alignAllocation(entry.sizeBytes);
        info->FileSize = entry.sizeBytes;
        info->CreationTime = createdTime_;
        info->LastAccessTime = createdTime_;
        info->LastWriteTime = createdTime_;
        info->ChangeTime = createdTime_;
        info->IndexNumber = entry.objectId == 0 ? 1 : entry.objectId;
        info->HardLinks = 1;
    }

    uint32_t serialNumber() const {
        const QByteArray hash = QCryptographicHash::hash(target_.toUtf8(),
                                                         QCryptographicHash::Md5);
        uint32_t serial = 0;
        std::memcpy(&serial, hash.constData(), sizeof(serial));
        return serial == 0 ? 0x41504653U : serial;
    }

    QString volumeLabel() const { return volumeLabel_; }
    bool readOnly() const { return readOnly_; }

    FileContext* openContext(const ResolvedEntry& entry, bool createdByThisHandle = false) {
        std::unique_ptr<FileContext> context(new (std::nothrow) FileContext);
        if (!context) {
            return nullptr;
        }
        context->entry = entry;
        context->createdByThisHandle = createdByThisHandle;
        QMutexLocker locker(&contextMutex_);
        context->handleId = nextHandleId_++;
        auto* raw = context.get();
        activeContexts_.push_back(std::move(context));
        return raw;
    }

    void closeContext(FileContext* context) {
        if (!context) {
            return;
        }
        QMutexLocker locker(&contextMutex_);
        for (auto it = activeContexts_.begin(); it != activeContexts_.end(); ++it) {
            if (it->get() == context) {
                context->closed = true;
                retiredContexts_.push_back(std::move(*it));
                activeContexts_.erase(it);
                pruneRetiredContextsNoLock();
                return;
            }
        }
        context->closed = true;
    }

    QJsonObject contextStats() const {
        QMutexLocker locker(&contextMutex_);
        return QJsonObject{{QStringLiteral("active"), static_cast<int>(activeContexts_.size())},
                           {QStringLiteral("retired"), static_cast<int>(retiredContexts_.size())}};
    }

    NTSTATUS createNode(const QString& path,
                        bool directory,
                        FileContext** outContext,
                        FSP_FSCTL_FILE_INFO* info) {
        if (readOnly_) {
            return STATUS_MEDIA_WRITE_PROTECTED;
        }
        const QString normalized = normalizeApfsPath(path);
        QString directoryName;
        QString fileName;
        if (directory) {
            if (!splitMutableRootDirectoryPath(normalized, &directoryName)) {
                return STATUS_NOT_SUPPORTED;
            }
        } else if (!splitMutableFilePath(normalized, &directoryName, &fileName)) {
            return STATUS_NOT_SUPPORTED;
        }

        ResolvedEntry existing;
        if (resolvePath(normalized, &existing) == STATUS_SUCCESS) {
            return STATUS_OBJECT_NAME_COLLISION;
        }

        ResolvedEntry created{.path = normalized,
                              .name = baseName(normalized),
                              .directory = directory,
                              .regularFile = !directory,
                              .symlink = false,
                              .objectId = 0,
                              .sizeBytes = 0};
        NTSTATUS status = directory ? commitDirectoryCreate(normalized, &created)
                                    : commitFileWrite(normalized, {}, &created);
        if (!NT_SUCCESS(status)) {
            return status;
        }

        auto* context = openContext(created, true);
        if (!context) {
            return STATUS_INSUFFICIENT_RESOURCES;
        }
        *outContext = context;
        fillFileInfo(created, info);
        return STATUS_SUCCESS;
    }

    NTSTATUS overwriteFile(FileContext* context, FSP_FSCTL_FILE_INFO* info) {
        if (readOnly_) {
            return STATUS_MEDIA_WRITE_PROTECTED;
        }
        QString directoryName;
        QString fileName;
        if (!context || context->entry.directory ||
            !splitMutableFilePath(context->entry.path, &directoryName, &fileName)) {
            return STATUS_NOT_SUPPORTED;
        }
        if (context->createdByThisHandle) {
            context->stagedWriteActive = true;
            context->stagedWriteDirty = context->entry.sizeBytes != 0;
            context->stagedWriteData.clear();
            context->entry.sizeBytes = 0;
            fillFileInfo(context->entry, info);
            return STATUS_SUCCESS;
        }
        NTSTATUS status = commitFileWrite(context->entry.path, {}, &context->entry);
        if (NT_SUCCESS(status)) {
            fillFileInfo(context->entry, info);
        }
        return status;
    }

    NTSTATUS writeFile(FileContext* context,
                       const void* buffer,
                       uint64_t offset,
                       ULONG length,
                       BOOLEAN writeToEndOfFile,
                       PULONG transferred,
                       FSP_FSCTL_FILE_INFO* info) {
        *transferred = 0;
        if (readOnly_) {
            return STATUS_MEDIA_WRITE_PROTECTED;
        }
        QString directoryName;
        QString fileName;
        if (!context || context->entry.directory ||
            !splitMutableFilePath(context->entry.path, &directoryName, &fileName)) {
            return STATUS_NOT_SUPPORTED;
        }
        if (length == 0) {
            fillFileInfo(context->entry, info);
            return STATUS_SUCCESS;
        }

        QByteArray data;
        const bool staged = context->createdByThisHandle || context->stagedWriteActive;
        NTSTATUS status = STATUS_SUCCESS;
        if (staged) {
            status = ensureStagedWriteData(context);
            if (!NT_SUCCESS(status)) {
                return status;
            }
            data = context->stagedWriteData;
        } else {
            status = readMutableBytes(context->entry, &data);
            if (!NT_SUCCESS(status)) {
                return status;
            }
        }
        const uint64_t stagedSize =
            context->stagedWriteFileBacked ? context->entry.sizeBytes
                                           : static_cast<uint64_t>(data.size());
        const uint64_t writeOffset = writeToEndOfFile ? stagedSize : offset;
        if (length > std::numeric_limits<uint64_t>::max() - writeOffset) {
            return STATUS_FILE_TOO_LARGE;
        }
        const uint64_t requiredSize = writeOffset + length;
        if (staged && rawTarget_ &&
            (context->stagedWriteFileBacked || requiredSize > kDefaultMaxMutationBytes)) {
            status = ensureFileBackedStage(context, data);
            if (!NT_SUCCESS(status)) {
                return status;
            }
            status = writeStagedFile(context, buffer, writeOffset, length, requiredSize);
            if (!NT_SUCCESS(status)) {
                return status;
            }
            context->stagedWriteActive = true;
            context->stagedWriteDirty = true;
            context->entry.sizeBytes = std::max<uint64_t>(context->entry.sizeBytes, requiredSize);
            *transferred = length;
            fillFileInfo(context->entry, info);
            return STATUS_SUCCESS;
        }
        if (writeOffset > kDefaultMaxMutationBytes ||
            length > kDefaultMaxMutationBytes - std::min<uint64_t>(writeOffset, kDefaultMaxMutationBytes)) {
            return STATUS_FILE_TOO_LARGE;
        }
        const qsizetype required = static_cast<qsizetype>(requiredSize);
        if (required > data.size()) {
            data.resize(required);
        }
        std::memcpy(data.data() + writeOffset, buffer, length);

        if (staged) {
            context->stagedWriteData = data;
            context->stagedWriteActive = true;
            context->stagedWriteDirty = true;
            context->entry.sizeBytes = static_cast<uint64_t>(data.size());
            *transferred = length;
            fillFileInfo(context->entry, info);
            return STATUS_SUCCESS;
        }

        status = commitFileWrite(context->entry.path, data, &context->entry);
        if (NT_SUCCESS(status)) {
            *transferred = length;
            fillFileInfo(context->entry, info);
        }
        return status;
    }

    NTSTATUS setFileSize(FileContext* context,
                         uint64_t newSize,
                         BOOLEAN setAllocationSize,
                         FSP_FSCTL_FILE_INFO* info) {
        if (readOnly_) {
            return STATUS_MEDIA_WRITE_PROTECTED;
        }
        QString directoryName;
        QString fileName;
        if (!context || context->entry.directory ||
            !splitMutableFilePath(context->entry.path, &directoryName, &fileName)) {
            return STATUS_NOT_SUPPORTED;
        }
        const bool staged = context->createdByThisHandle || context->stagedWriteActive;
        if (newSize > kDefaultMaxMutationBytes && !(staged && rawTarget_)) {
            return STATUS_FILE_TOO_LARGE;
        }
        if (setAllocationSize && newSize >= context->entry.sizeBytes) {
            fillFileInfo(context->entry, info);
            return STATUS_SUCCESS;
        }

        QByteArray data;
        NTSTATUS status = STATUS_SUCCESS;
        if (staged) {
            status = ensureStagedWriteData(context);
            if (!NT_SUCCESS(status)) {
                return status;
            }
            if (rawTarget_ &&
                (context->stagedWriteFileBacked || newSize > kDefaultMaxMutationBytes)) {
                status = ensureFileBackedStage(context, context->stagedWriteData);
                if (!NT_SUCCESS(status)) {
                    return status;
                }
                QFile file(context->stagedWritePath);
                if (!file.open(QIODevice::ReadWrite) ||
                    !file.resize(static_cast<qint64>(newSize))) {
                    return STATUS_ACCESS_DENIED;
                }
                context->stagedWriteActive = true;
                context->stagedWriteDirty = true;
                context->entry.sizeBytes = newSize;
                fillFileInfo(context->entry, info);
                return STATUS_SUCCESS;
            }
            data = context->stagedWriteData;
        } else {
            status = readMutableBytes(context->entry, &data);
            if (!NT_SUCCESS(status)) {
                return status;
            }
        }
        data.resize(static_cast<qsizetype>(newSize));
        if (staged) {
            context->stagedWriteData = data;
            context->stagedWriteActive = true;
            context->stagedWriteDirty = true;
            context->entry.sizeBytes = static_cast<uint64_t>(data.size());
            fillFileInfo(context->entry, info);
            return STATUS_SUCCESS;
        }
        status = commitFileWrite(context->entry.path, data, &context->entry);
        if (NT_SUCCESS(status)) {
            fillFileInfo(context->entry, info);
        }
        return status;
    }

    NTSTATUS canDelete(const FileContext* context) {
        if (readOnly_) {
            return STATUS_MEDIA_WRITE_PROTECTED;
        }
        if (!context) {
            return STATUS_NOT_SUPPORTED;
        }
        if (context->entry.directory) {
            QString directoryName;
            if (!splitMutableRootDirectoryPath(context->entry.path, &directoryName)) {
                return STATUS_NOT_SUPPORTED;
            }
            QMutexLocker locker(&ioMutex_);
            const auto listing = readerSession_->listDirectory(context->entry.path, 1);
            if (!listing.ok || !listing.blockers.isEmpty()) {
                return STATUS_ACCESS_DENIED;
            }
            return listing.entries.isEmpty() ? STATUS_SUCCESS : STATUS_DIRECTORY_NOT_EMPTY;
        }
        QString directoryName;
        QString fileName;
        if (!splitMutableFilePath(context->entry.path, &directoryName, &fileName)) {
            return STATUS_NOT_SUPPORTED;
        }
        return STATUS_SUCCESS;
    }

    NTSTATUS deleteFile(FileContext* context) {
        if (readOnly_) {
            return STATUS_MEDIA_WRITE_PROTECTED;
        }
        if (!context) {
            return STATUS_NOT_SUPPORTED;
        }
        trace(QStringLiteral("Delete %1 directory=%2")
                  .arg(context->entry.path)
                  .arg(context->entry.directory));
        if (!context->entry.directory) {
            discardStagedWrite(context);
        }
        if (context->entry.directory) {
            QString parentDirectoryPath;
            QString directoryName;
            if (!splitDirectoryCreatePath(context->entry.path, &parentDirectoryPath, &directoryName)) {
                return STATUS_NOT_SUPPORTED;
            }
            return commitDirectoryDelete(context->entry.path);
        }
        QString directoryName;
        QString fileName;
        if (!splitMutableFilePath(context->entry.path, &directoryName, &fileName)) {
            return STATUS_NOT_SUPPORTED;
        }
        return commitFileDelete(context->entry.path);
    }

    NTSTATUS renameFile(FileContext* context,
                        const QString& oldPath,
                        const QString& newPath,
                        bool replaceIfExists) {
        if (readOnly_) {
            return STATUS_MEDIA_WRITE_PROTECTED;
        }
        const QString normalizedOld = normalizeApfsPath(oldPath);
        const QString normalizedNew = normalizeApfsPath(newPath);
        if (!context) {
            return STATUS_NOT_SUPPORTED;
        }
        if (context->stagedWriteDirty) {
            const NTSTATUS flushStatus = flushFile(context, nullptr);
            if (!NT_SUCCESS(flushStatus)) {
                return flushStatus;
            }
        }
        if (context->entry.directory) {
            QString oldParentDirectoryPath;
            QString oldDirectoryName;
            QString newParentDirectoryPath;
            QString newDirectoryName;
            if (!splitDirectoryCreatePath(normalizedOld, &oldParentDirectoryPath, &oldDirectoryName) ||
                !splitDirectoryCreatePath(normalizedNew, &newParentDirectoryPath, &newDirectoryName)) {
                return STATUS_NOT_SUPPORTED;
            }
            if (replaceIfExists) {
                return STATUS_ACCESS_DENIED;
            }
            ResolvedEntry updated;
            NTSTATUS status = commitDirectoryRename(normalizedOld, normalizedNew, &updated);
            if (NT_SUCCESS(status)) {
                context->entry = updated;
            }
            return status;
        }
        QString oldDirectory;
        QString oldFile;
        QString newDirectory;
        QString newFile;
        if (!splitMutableFilePath(normalizedOld, &oldDirectory, &oldFile) ||
            !splitMutableFilePath(normalizedNew, &newDirectory, &newFile)) {
            return STATUS_NOT_SUPPORTED;
        }
        if (replaceIfExists) {
            ResolvedEntry existing;
            const NTSTATUS existingStatus = resolvePath(normalizedNew, &existing);
            if (NT_SUCCESS(existingStatus)) {
                if (existing.directory) {
                    return STATUS_ACCESS_DENIED;
                }
                if (existing.objectId != context->entry.objectId) {
                    const NTSTATUS deleteStatus = commitFileDelete(normalizedNew);
                    if (!NT_SUCCESS(deleteStatus)) {
                        return deleteStatus;
                    }
                }
            } else if (existingStatus != STATUS_OBJECT_NAME_NOT_FOUND) {
                return existingStatus;
            }
        }

        ResolvedEntry updated;
        NTSTATUS status = commitFileRename(normalizedOld, normalizedNew, &updated);
        if (NT_SUCCESS(status)) {
            context->entry = updated;
        }
        return status;
    }

    NTSTATUS flushFile(FileContext* context, FSP_FSCTL_FILE_INFO* info) {
        if (!context) {
            return STATUS_INVALID_PARAMETER;
        }
        if (!context->stagedWriteDirty) {
            if (info) {
                fillFileInfo(context->entry, info);
            }
            return STATUS_SUCCESS;
        }
        if (readOnly_) {
            return STATUS_MEDIA_WRITE_PROTECTED;
        }
        if (context->entry.directory || context->deletePending) {
            if (info) {
                fillFileInfo(context->entry, info);
            }
            return STATUS_SUCCESS;
        }
        trace(QStringLiteral("StagedFlush %1 bytes=%2 file_backed=%3")
                  .arg(context->entry.path)
                  .arg(context->entry.sizeBytes)
                  .arg(context->stagedWriteFileBacked));
        NTSTATUS status = context->stagedWriteFileBacked
                              ? commitFileWriteFromPath(context->entry.path,
                                                        context->stagedWritePath,
                                                        context->entry.sizeBytes,
                                                        &context->entry)
                              : commitFileWrite(context->entry.path,
                                                context->stagedWriteData,
                                                &context->entry);
        trace(QStringLiteral("StagedFlushDone status=0x%1")
                  .arg(static_cast<quint32>(status), 8, 16, QLatin1Char('0')));
        if (NT_SUCCESS(status)) {
            context->stagedWriteDirty = false;
            context->stagedWriteActive = false;
            if (context->stagedWriteFileBacked) {
                QFile::remove(context->stagedWritePath);
            }
            context->stagedWritePath.clear();
            context->stagedWriteFileBacked = false;
            context->stagedWriteData.clear();
            if (info) {
                fillFileInfo(context->entry, info);
            }
        }
        return status;
    }

private:
    static NTSTATUS readBytes(const QByteArray& data,
                              uint64_t offset,
                              ULONG length,
                              void* buffer,
                              PULONG transferred) {
        if (offset >= static_cast<uint64_t>(data.size())) {
            return STATUS_END_OF_FILE;
        }
        const uint64_t available = static_cast<uint64_t>(data.size()) - offset;
        const ULONG toCopy = static_cast<ULONG>(std::min<uint64_t>(length, available));
        std::memcpy(buffer, data.constData() + offset, toCopy);
        *transferred = toCopy;
        return STATUS_SUCCESS;
    }

    static bool fitsQint64(uint64_t value) {
        return value <= static_cast<uint64_t>(std::numeric_limits<qint64>::max());
    }

    static NTSTATUS readHostFileBytes(const QString& path,
                                      uint64_t offset,
                                      ULONG length,
                                      void* buffer,
                                      PULONG transferred) {
        *transferred = 0;
        QFile file(path);
        if (!file.open(QIODevice::ReadOnly)) {
            return STATUS_ACCESS_DENIED;
        }
        const uint64_t size = file.size() >= 0 ? static_cast<uint64_t>(file.size()) : 0;
        if (offset >= size) {
            return STATUS_END_OF_FILE;
        }
        if (!fitsQint64(offset) || !file.seek(static_cast<qint64>(offset))) {
            return STATUS_ACCESS_DENIED;
        }
        const ULONG toRead = static_cast<ULONG>(std::min<uint64_t>(length, size - offset));
        const QByteArray chunk = file.read(static_cast<qint64>(toRead));
        if (chunk.size() < 0) {
            return STATUS_ACCESS_DENIED;
        }
        std::memcpy(buffer, chunk.constData(), static_cast<size_t>(chunk.size()));
        *transferred = static_cast<ULONG>(chunk.size());
        return STATUS_SUCCESS;
    }

    QString stagedTempPath(const FileContext* context) const {
        return QDir::temp().filePath(
            QStringLiteral("apfs-winfs-stage-%1-%2.tmp")
                .arg(context ? context->handleId : 0)
                .arg(QUuid::createUuid().toString(QUuid::Id128)));
    }

    NTSTATUS ensureFileBackedStage(FileContext* context, const QByteArray& initialData) const {
        if (!context || context->entry.directory) {
            return STATUS_NOT_SUPPORTED;
        }
        if (context->stagedWriteFileBacked) {
            return STATUS_SUCCESS;
        }
        const uint64_t initialSize = static_cast<uint64_t>(initialData.size());
        const uint64_t targetSize = std::max<uint64_t>(context->entry.sizeBytes, initialSize);
        if (!fitsQint64(targetSize)) {
            return STATUS_FILE_TOO_LARGE;
        }
        const QString path = stagedTempPath(context);
        QFile file(path);
        if (!file.open(QIODevice::WriteOnly)) {
            return STATUS_ACCESS_DENIED;
        }
        if (!initialData.isEmpty() && file.write(initialData) != initialData.size()) {
            file.close();
            QFile::remove(path);
            return STATUS_ACCESS_DENIED;
        }
        if (targetSize != initialSize && !file.resize(static_cast<qint64>(targetSize))) {
            file.close();
            QFile::remove(path);
            return STATUS_ACCESS_DENIED;
        }
        file.close();
        context->stagedWritePath = path;
        context->stagedWriteFileBacked = true;
        context->stagedWriteData.clear();
        return STATUS_SUCCESS;
    }

    NTSTATUS writeStagedFile(FileContext* context,
                             const void* buffer,
                             uint64_t offset,
                             ULONG length,
                             uint64_t requiredSize) const {
        if (!context || !context->stagedWriteFileBacked || context->stagedWritePath.isEmpty()) {
            return STATUS_INVALID_PARAMETER;
        }
        if (!fitsQint64(offset) || !fitsQint64(requiredSize)) {
            return STATUS_FILE_TOO_LARGE;
        }
        QFile file(context->stagedWritePath);
        if (!file.open(QIODevice::ReadWrite)) {
            return STATUS_ACCESS_DENIED;
        }
        if (offset > static_cast<uint64_t>(file.size()) &&
            !file.resize(static_cast<qint64>(offset))) {
            return STATUS_ACCESS_DENIED;
        }
        if (!file.seek(static_cast<qint64>(offset))) {
            return STATUS_ACCESS_DENIED;
        }
        if (length != 0 &&
            file.write(static_cast<const char*>(buffer), static_cast<qint64>(length)) !=
                static_cast<qint64>(length)) {
            return STATUS_ACCESS_DENIED;
        }
        if (requiredSize > static_cast<uint64_t>(file.size()) &&
            !file.resize(static_cast<qint64>(requiredSize))) {
            return STATUS_ACCESS_DENIED;
        }
        return STATUS_SUCCESS;
    }

    NTSTATUS ensureStagedWriteData(FileContext* context) {
        if (!context || context->entry.directory) {
            return STATUS_NOT_SUPPORTED;
        }
        if (context->stagedWriteActive) {
            return STATUS_SUCCESS;
        }
        if (context->createdByThisHandle && context->entry.sizeBytes == 0) {
            context->stagedWriteData.clear();
            context->stagedWriteActive = true;
            return STATUS_SUCCESS;
        }
        NTSTATUS status = readMutableBytes(context->entry, &context->stagedWriteData);
        if (!NT_SUCCESS(status)) {
            return status;
        }
        context->stagedWriteActive = true;
        return STATUS_SUCCESS;
    }

    void discardStagedWrite(FileContext* context) const {
        if (!context) {
            return;
        }
        if (context->stagedWriteFileBacked) {
            QFile::remove(context->stagedWritePath);
        }
        context->stagedWritePath.clear();
        context->stagedWriteFileBacked = false;
        context->stagedWriteData.clear();
        context->stagedWriteActive = false;
        context->stagedWriteDirty = false;
    }

    void pruneRetiredContextsNoLock() {
        constexpr size_t kRetiredContextLimit = 4096;
        while (retiredContexts_.size() > kRetiredContextLimit) {
            retiredContexts_.erase(retiredContexts_.begin());
        }
    }

    NTSTATUS resolvePathNoLock(const QString& normalized, ResolvedEntry* resolved) {
        if (normalized == QStringLiteral("/")) {
            if (resolved) {
                *resolved = ResolvedEntry{.path = QStringLiteral("/"),
                                          .name = QStringLiteral(""),
                                          .directory = true,
                                          .regularFile = false,
                                          .symlink = false,
                                          .objectId = 1,
                                          .sizeBytes = 0};
            }
            return STATUS_SUCCESS;
        }

        const auto listing = readerSession_->listDirectory(
            parentPath(normalized), sak::kPartitionApfsDefaultBrowseEntryLimit);
        if (!listing.blockers.isEmpty()) {
            return STATUS_OBJECT_NAME_NOT_FOUND;
        }

        const QString wanted = baseName(normalized);
        std::optional<sak::PartitionApfsFileEntry> fallback;
        for (const auto& entry : listing.entries) {
            if (entry.name == wanted) {
                return fillResolved(entry, normalized, resolved);
            }
            if (!fallback.has_value() && entry.name.compare(wanted, Qt::CaseInsensitive) == 0) {
                fallback = entry;
            }
        }
        if (fallback.has_value()) {
            return fillResolved(*fallback, normalized, resolved);
        }
        return STATUS_OBJECT_NAME_NOT_FOUND;
    }

    NTSTATUS fillResolved(const sak::PartitionApfsFileEntry& entry,
                          const QString& path,
                          ResolvedEntry* resolved) const {
        if (resolved) {
            *resolved = ResolvedEntry{.path = normalizeApfsPath(path),
                                      .name = entry.name,
                                      .directory = entry.directory,
                                      .regularFile = entry.regular_file,
                                      .symlink = entry.symlink,
                                      .objectId = entry.object_id,
                                      .sizeBytes = entry.size_bytes};
        }
        return STATUS_SUCCESS;
    }

    sak::PartitionApfsWriteOptions writerOptions() const {
        sak::PartitionApfsWriteOptions options;
        options.enable_experimental_writer = true;
        options.destructive_certification_evidence = true;
        options.image_only = !rawTarget_;
        options.raw_media_hardware_certification_evidence = rawTarget_;
        options.max_payload_bytes = kDefaultMaxMutationBytes;
        options.evidence_id = rawTarget_ ? QStringLiteral("apfs_for_windows.raw_mount_rw")
                                         : QStringLiteral("apfs_for_windows.image_mount_rw");
        return options;
    }

    QString mutationTempPathNoLock(const QString& operation) const {
        const QFileInfo targetInfo(target_);
        const QString dir = targetInfo.absoluteDir().absolutePath();
        const QString name = QStringLiteral(".%1-%2-%3.apfs")
                                 .arg(targetInfo.fileName(), operation, QUuid::createUuid().toString(QUuid::Id128));
        return QDir(dir).filePath(name);
    }

    NTSTATUS reloadTargetNoLock(QString* error = nullptr) {
        QString openError;
        auto newDevice = sak::openFileOrRawDeviceReadOnly(target_, &openError);
        if (!newDevice) {
            if (error) {
                *error = QStringLiteral("reopen failed: %1").arg(openError);
            }
            return STATUS_ACCESS_DENIED;
        }

        QString detectError;
        const uint64_t size = newDevice->size() > 0 ? static_cast<uint64_t>(newDevice->size())
                                                    : kFallbackProbeBytes;
        const auto detection =
            sak::PartitionFileSystemDetector::detectFromDevice(newDevice.get(), 0, size, &detectError);
        if (!detection.has_value() ||
            detection->file_system.compare(QStringLiteral("APFS"), Qt::CaseInsensitive) != 0) {
            if (error) {
                *error = detectError.isEmpty() ? QStringLiteral("target is not APFS")
                                               : detectError;
            }
            return STATUS_UNRECOGNIZED_VOLUME;
        }

        auto newReaderSession =
            std::make_unique<sak::PartitionApfsFileSystemReaderSession>(newDevice.get());
        const auto root = newReaderSession->listDirectory(QStringLiteral("/"), 1);
        if (!root.blockers.isEmpty()) {
            if (error) {
                *error = root.blockers.join(QStringLiteral("; "));
            }
            return STATUS_ACCESS_DENIED;
        }

        readerSession_.reset();
        device_ = std::move(newDevice);
        readerSession_ = std::move(newReaderSession);
        totalBytes_ = detection->total_bytes;
        freeBytes_ = detection->free_bytes;
        targetContainerBytes_ = detection->total_bytes != 0 ? detection->total_bytes : size;
        if (!root.volume_name.trimmed().isEmpty()) {
            volumeLabel_ = root.volume_name.trimmed().left(32);
        }
        return STATUS_SUCCESS;
    }

    bool replaceTargetWithTempNoLock(const QString& tempPath, QString* error) {
        const QString backupPath = mutationTempPathNoLock(QStringLiteral("backup"));
        QFile::remove(backupPath);
        if (!QFile::rename(target_, backupPath)) {
            if (error) {
                *error = QStringLiteral("unable to move mounted image to backup");
            }
            QFile::remove(tempPath);
            return false;
        }
        if (!QFile::rename(tempPath, target_)) {
            QFile::rename(backupPath, target_);
            if (error) {
                *error = QStringLiteral("unable to promote APFS mutation image");
            }
            QFile::remove(tempPath);
            return false;
        }
        QFile::remove(backupPath);
        return true;
    }

    NTSTATUS resultStatus(const QString& operation,
                          const sak::PartitionApfsImageCheckpointCommitResult& result) const {
        if (result.ok) {
            return STATUS_SUCCESS;
        }
        trace(QStringLiteral("%1 failed: %2").arg(operation, result.blockers.join(QStringLiteral("; "))));
        const QString blockers = result.blockers.join(QLatin1Char(' '));
        if (blockers.contains(QStringLiteral("already exists"), Qt::CaseInsensitive)) {
            return STATUS_OBJECT_NAME_COLLISION;
        }
        if (blockers.contains(QStringLiteral("not found"), Qt::CaseInsensitive)) {
            return STATUS_OBJECT_NAME_NOT_FOUND;
        }
        if (blockers.contains(QStringLiteral("exceeds"), Qt::CaseInsensitive)) {
            return STATUS_FILE_TOO_LARGE;
        }
        if (blockers.contains(QStringLiteral("empty"), Qt::CaseInsensitive)) {
            return STATUS_DIRECTORY_NOT_EMPTY;
        }
        return STATUS_ACCESS_DENIED;
    }

    NTSTATUS commitFileWrite(const QString& path, const QByteArray& data, ResolvedEntry* updated) {
        if (static_cast<uint64_t>(data.size()) > kDefaultMaxMutationBytes) {
            return STATUS_FILE_TOO_LARGE;
        }
        const QString normalized = normalizeApfsPath(path);
        QString parentDirectoryPath;
        QString fileName;
        if (!splitMutableFilePath(normalized, &parentDirectoryPath, &fileName)) {
            return STATUS_NOT_SUPPORTED;
        }

        QMutexLocker locker(&ioMutex_);
        readerSession_.reset();
        device_.reset();
        QString tempPath;
        sak::PartitionApfsImageCheckpointCommitResult result;
        if (rawTarget_) {
            result = sak::PartitionApfsWriter::commitRawFileWrite(
                {.target_path = target_,
                 .target_container_bytes = targetContainerBytes_,
                 .file_name = fileName,
                 .file_data = data,
                 .parent_directory_path = parentDirectoryPath,
                 .target_mutation_confirmed = allowRawWrites_,
                 .allow_raw_device_target = allowRawWrites_,
                 .options = writerOptions()});
        } else {
            tempPath = mutationTempPathNoLock(QStringLiteral("write"));
            result = sak::PartitionApfsWriter::commitImageOnlyFileWrite(
                {.source_image_path = target_,
                 .written_image_path = tempPath,
                 .file_name = fileName,
                 .file_data = data,
                 .parent_directory_path = parentDirectoryPath,
                 .options = writerOptions()});
            if (result.ok) {
                QString replaceError;
                if (!replaceTargetWithTempNoLock(tempPath, &replaceError)) {
                    trace(QStringLiteral("write replace failed: %1").arg(replaceError));
                    reloadTargetNoLock();
                    return STATUS_ACCESS_DENIED;
                }
            } else {
                QFile::remove(tempPath);
            }
        }

        const NTSTATUS mutationStatus = resultStatus(QStringLiteral("file-write"), result);
        QString reloadError;
        const NTSTATUS reloadStatus = reloadTargetNoLock(&reloadError);
        if (!NT_SUCCESS(reloadStatus)) {
            trace(QStringLiteral("reload after write failed: %1").arg(reloadError));
            return reloadStatus;
        }
        if (!NT_SUCCESS(mutationStatus)) {
            return mutationStatus;
        }
        return resolvePathNoLock(normalized, updated);
    }

    NTSTATUS commitFileWriteFromPath(const QString& path,
                                     const QString& dataPath,
                                     uint64_t dataSize,
                                     ResolvedEntry* updated) {
        if (dataPath.isEmpty() || !QFileInfo::exists(dataPath)) {
            return STATUS_OBJECT_NAME_NOT_FOUND;
        }
        if (!rawTarget_) {
            if (dataSize > kDefaultMaxMutationBytes || !fitsQint64(dataSize)) {
                return STATUS_FILE_TOO_LARGE;
            }
            QFile file(dataPath);
            if (!file.open(QIODevice::ReadOnly)) {
                return STATUS_ACCESS_DENIED;
            }
            const QByteArray data = file.readAll();
            if (static_cast<uint64_t>(data.size()) != dataSize) {
                return STATUS_ACCESS_DENIED;
            }
            return commitFileWrite(path, data, updated);
        }

        const QString normalized = normalizeApfsPath(path);
        QString parentDirectoryPath;
        QString fileName;
        if (!splitMutableFilePath(normalized, &parentDirectoryPath, &fileName)) {
            return STATUS_NOT_SUPPORTED;
        }

        QMutexLocker locker(&ioMutex_);
        readerSession_.reset();
        device_.reset();
        const auto result = sak::PartitionApfsWriter::commitRawFileWrite(
            {.target_path = target_,
             .target_container_bytes = targetContainerBytes_,
             .file_name = fileName,
             .file_data_path = dataPath,
             .file_data_stream_size = dataSize,
             .parent_directory_path = parentDirectoryPath,
             .target_mutation_confirmed = allowRawWrites_,
             .allow_raw_device_target = allowRawWrites_,
             .options = writerOptions()});

        const NTSTATUS mutationStatus = resultStatus(QStringLiteral("file-write-stream"), result);
        QString reloadError;
        const NTSTATUS reloadStatus = reloadTargetNoLock(&reloadError);
        if (!NT_SUCCESS(reloadStatus)) {
            trace(QStringLiteral("reload after stream write failed: %1").arg(reloadError));
            return reloadStatus;
        }
        if (!NT_SUCCESS(mutationStatus)) {
            return mutationStatus;
        }
        return resolvePathNoLock(normalized, updated);
    }

    NTSTATUS commitFileDelete(const QString& path) {
        const QString normalized = normalizeApfsPath(path);
        QString parentDirectoryPath;
        QString fileName;
        if (!splitMutableFilePath(normalized, &parentDirectoryPath, &fileName)) {
            return STATUS_NOT_SUPPORTED;
        }

        QMutexLocker locker(&ioMutex_);
        readerSession_.reset();
        device_.reset();
        QString tempPath;
        sak::PartitionApfsImageCheckpointCommitResult result;
        if (rawTarget_) {
            result = sak::PartitionApfsWriter::commitRawFileDelete(
                {.target_path = target_,
                 .target_container_bytes = targetContainerBytes_,
                 .file_name = fileName,
                 .parent_directory_path = parentDirectoryPath,
                 .target_mutation_confirmed = allowRawWrites_,
                 .allow_raw_device_target = allowRawWrites_,
                 .options = writerOptions()});
        } else {
            tempPath = mutationTempPathNoLock(QStringLiteral("delete"));
            result = sak::PartitionApfsWriter::commitImageOnlyFileDelete(
                {.source_image_path = target_,
                 .written_image_path = tempPath,
                 .file_name = fileName,
                 .parent_directory_path = parentDirectoryPath,
                 .options = writerOptions()});
            if (result.ok) {
                QString replaceError;
                if (!replaceTargetWithTempNoLock(tempPath, &replaceError)) {
                    trace(QStringLiteral("delete replace failed: %1").arg(replaceError));
                    reloadTargetNoLock();
                    return STATUS_ACCESS_DENIED;
                }
            } else {
                QFile::remove(tempPath);
            }
        }

        const NTSTATUS mutationStatus = resultStatus(QStringLiteral("file-delete"), result);
        QString reloadError;
        const NTSTATUS reloadStatus = reloadTargetNoLock(&reloadError);
        if (!NT_SUCCESS(reloadStatus)) {
            trace(QStringLiteral("reload after delete failed: %1").arg(reloadError));
            return reloadStatus;
        }
        return mutationStatus;
    }

    NTSTATUS commitDirectoryCreate(const QString& path, ResolvedEntry* updated) {
        const QString normalized = normalizeApfsPath(path);
        QString parentDirectoryPath;
        QString directoryName;
        if (!splitDirectoryCreatePath(normalized, &parentDirectoryPath, &directoryName)) {
            return STATUS_NOT_SUPPORTED;
        }

        QMutexLocker locker(&ioMutex_);
        readerSession_.reset();
        device_.reset();
        QString tempPath;
        sak::PartitionApfsImageCheckpointCommitResult result;
        if (rawTarget_) {
            sak::PartitionApfsRawDirectoryMutationCommitRequest request;
            request.target_path = target_;
            request.target_container_bytes = targetContainerBytes_;
            request.directory_name = directoryName;
            request.parent_directory_path = parentDirectoryPath;
            request.target_mutation_confirmed = allowRawWrites_;
            request.allow_raw_device_target = allowRawWrites_;
            request.options = writerOptions();
            result = sak::PartitionApfsWriter::commitRawDirectoryCreate(request);
        } else {
            tempPath = mutationTempPathNoLock(QStringLiteral("mkdir"));
            result = sak::PartitionApfsWriter::commitImageOnlyDirectoryCreate(
                {.source_image_path = target_,
                 .written_image_path = tempPath,
                  .directory_name = directoryName,
                  .parent_directory_path = parentDirectoryPath,
                  .options = writerOptions()});
            if (result.ok) {
                QString replaceError;
                if (!replaceTargetWithTempNoLock(tempPath, &replaceError)) {
                    trace(QStringLiteral("directory create replace failed: %1").arg(replaceError));
                    reloadTargetNoLock();
                    return STATUS_ACCESS_DENIED;
                }
            } else {
                QFile::remove(tempPath);
            }
        }

        const NTSTATUS mutationStatus = resultStatus(QStringLiteral("directory-create"), result);
        QString reloadError;
        const NTSTATUS reloadStatus = reloadTargetNoLock(&reloadError);
        if (!NT_SUCCESS(reloadStatus)) {
            trace(QStringLiteral("reload after directory create failed: %1").arg(reloadError));
            return reloadStatus;
        }
        if (!NT_SUCCESS(mutationStatus)) {
            return mutationStatus;
        }
        return resolvePathNoLock(normalized, updated);
    }

    NTSTATUS commitDirectoryDelete(const QString& path) {
        const QString normalized = normalizeApfsPath(path);
        QString parentDirectoryPath;
        QString directoryName;
        if (!splitDirectoryCreatePath(normalized, &parentDirectoryPath, &directoryName)) {
            return STATUS_NOT_SUPPORTED;
        }

        QMutexLocker locker(&ioMutex_);
        readerSession_.reset();
        device_.reset();
        QString tempPath;
        sak::PartitionApfsImageCheckpointCommitResult result;
        if (rawTarget_) {
            sak::PartitionApfsRawDirectoryMutationCommitRequest request;
            request.target_path = target_;
            request.target_container_bytes = targetContainerBytes_;
            request.directory_name = directoryName;
            request.parent_directory_path = parentDirectoryPath;
            request.target_mutation_confirmed = allowRawWrites_;
            request.allow_raw_device_target = allowRawWrites_;
            request.options = writerOptions();
            result = sak::PartitionApfsWriter::commitRawDirectoryDelete(request);
        } else {
            tempPath = mutationTempPathNoLock(QStringLiteral("rmdir"));
            result = sak::PartitionApfsWriter::commitImageOnlyDirectoryDelete(
                {.source_image_path = target_,
                 .written_image_path = tempPath,
                 .directory_name = directoryName,
                 .parent_directory_path = parentDirectoryPath,
                 .options = writerOptions()});
            if (result.ok) {
                QString replaceError;
                if (!replaceTargetWithTempNoLock(tempPath, &replaceError)) {
                    trace(QStringLiteral("directory delete replace failed: %1").arg(replaceError));
                    reloadTargetNoLock();
                    return STATUS_ACCESS_DENIED;
                }
            } else {
                QFile::remove(tempPath);
            }
        }

        const NTSTATUS mutationStatus = resultStatus(QStringLiteral("directory-delete"), result);
        QString reloadError;
        const NTSTATUS reloadStatus = reloadTargetNoLock(&reloadError);
        if (!NT_SUCCESS(reloadStatus)) {
            trace(QStringLiteral("reload after directory delete failed: %1").arg(reloadError));
            return reloadStatus;
        }
        return mutationStatus;
    }

    NTSTATUS commitDirectoryRename(const QString& oldPath,
                                   const QString& newPath,
                                   ResolvedEntry* updated) {
        const QString normalizedOld = normalizeApfsPath(oldPath);
        const QString normalizedNew = normalizeApfsPath(newPath);
        QString oldParentDirectoryPath;
        QString oldDirectoryName;
        QString newParentDirectoryPath;
        QString newDirectoryName;
        if (!splitDirectoryCreatePath(normalizedOld, &oldParentDirectoryPath, &oldDirectoryName) ||
            !splitDirectoryCreatePath(normalizedNew, &newParentDirectoryPath, &newDirectoryName)) {
            return STATUS_NOT_SUPPORTED;
        }

        QMutexLocker locker(&ioMutex_);
        readerSession_.reset();
        device_.reset();
        QString tempPath;
        sak::PartitionApfsImageCheckpointCommitResult result;
        if (rawTarget_) {
            result = sak::PartitionApfsWriter::commitRawDirectoryRename(
                {.target_path = target_,
                 .target_container_bytes = targetContainerBytes_,
                 .directory_name = oldDirectoryName,
                 .new_directory_name = newDirectoryName,
                 .parent_directory_path = oldParentDirectoryPath,
                 .new_parent_directory_path = newParentDirectoryPath,
                 .target_mutation_confirmed = allowRawWrites_,
                 .allow_raw_device_target = allowRawWrites_,
                 .options = writerOptions()});
        } else {
            tempPath = mutationTempPathNoLock(QStringLiteral("renamedir"));
            result = sak::PartitionApfsWriter::commitImageOnlyDirectoryRename(
                {.source_image_path = target_,
                 .written_image_path = tempPath,
                 .directory_name = oldDirectoryName,
                 .new_directory_name = newDirectoryName,
                 .parent_directory_path = oldParentDirectoryPath,
                 .new_parent_directory_path = newParentDirectoryPath,
                 .options = writerOptions()});
            if (result.ok) {
                QString replaceError;
                if (!replaceTargetWithTempNoLock(tempPath, &replaceError)) {
                    trace(QStringLiteral("directory rename replace failed: %1").arg(replaceError));
                    reloadTargetNoLock();
                    return STATUS_ACCESS_DENIED;
                }
            } else {
                QFile::remove(tempPath);
            }
        }

        const NTSTATUS mutationStatus = resultStatus(QStringLiteral("directory-rename"), result);
        QString reloadError;
        const NTSTATUS reloadStatus = reloadTargetNoLock(&reloadError);
        if (!NT_SUCCESS(reloadStatus)) {
            trace(QStringLiteral("reload after directory rename failed: %1").arg(reloadError));
            return reloadStatus;
        }
        if (!NT_SUCCESS(mutationStatus)) {
            return mutationStatus;
        }
        return resolvePathNoLock(normalizedNew, updated);
    }

    NTSTATUS commitFileRename(const QString& oldPath,
                              const QString& newPath,
                              ResolvedEntry* updated) {
        const QString normalizedOld = normalizeApfsPath(oldPath);
        const QString normalizedNew = normalizeApfsPath(newPath);
        QString oldDirectoryPath;
        QString oldFile;
        QString newDirectoryPath;
        QString newFile;
        if (!splitMutableFilePath(normalizedOld, &oldDirectoryPath, &oldFile) ||
            !splitMutableFilePath(normalizedNew, &newDirectoryPath, &newFile)) {
            return STATUS_NOT_SUPPORTED;
        }

        QMutexLocker locker(&ioMutex_);
        readerSession_.reset();
        device_.reset();
        QString tempPath;
        sak::PartitionApfsImageCheckpointCommitResult result;
        if (rawTarget_) {
            if (oldDirectoryPath == newDirectoryPath) {
                result = sak::PartitionApfsWriter::commitRawFileRename(
                    {.target_path = target_,
                     .target_container_bytes = targetContainerBytes_,
                     .file_name = oldFile,
                     .new_file_name = newFile,
                     .parent_directory_path = oldDirectoryPath,
                     .target_mutation_confirmed = allowRawWrites_,
                     .allow_raw_device_target = allowRawWrites_,
                     .options = writerOptions()});
            } else {
                result = sak::PartitionApfsWriter::commitRawFileMove(
                    {.target_path = target_,
                     .target_container_bytes = targetContainerBytes_,
                     .source_directory_name = oldDirectoryPath,
                     .file_name = oldFile,
                     .destination_directory_name = newDirectoryPath,
                     .new_file_name = newFile,
                     .target_mutation_confirmed = allowRawWrites_,
                     .allow_raw_device_target = allowRawWrites_,
                     .options = writerOptions()});
            }
        } else {
            tempPath = mutationTempPathNoLock(QStringLiteral("rename"));
            if (oldDirectoryPath == newDirectoryPath) {
                result = sak::PartitionApfsWriter::commitImageOnlyFileRename(
                    {.source_image_path = target_,
                     .written_image_path = tempPath,
                     .file_name = oldFile,
                     .new_file_name = newFile,
                     .parent_directory_path = oldDirectoryPath,
                     .options = writerOptions()});
            } else {
                result = sak::PartitionApfsWriter::commitImageOnlyFileMove(
                    {.source_image_path = target_,
                     .written_image_path = tempPath,
                     .source_directory_name = oldDirectoryPath,
                     .file_name = oldFile,
                     .destination_directory_name = newDirectoryPath,
                     .new_file_name = newFile,
                     .options = writerOptions()});
            }
            if (result.ok) {
                QString replaceError;
                if (!replaceTargetWithTempNoLock(tempPath, &replaceError)) {
                    trace(QStringLiteral("rename replace failed: %1").arg(replaceError));
                    reloadTargetNoLock();
                    return STATUS_ACCESS_DENIED;
                }
            } else {
                QFile::remove(tempPath);
            }
        }

        const NTSTATUS mutationStatus = resultStatus(QStringLiteral("file-rename"), result);
        QString reloadError;
        const NTSTATUS reloadStatus = reloadTargetNoLock(&reloadError);
        if (!NT_SUCCESS(reloadStatus)) {
            trace(QStringLiteral("reload after rename failed: %1").arg(reloadError));
            return reloadStatus;
        }
        if (!NT_SUCCESS(mutationStatus)) {
            return mutationStatus;
        }
        return resolvePathNoLock(normalizedNew, updated);
    }

    NTSTATUS readMutableBytes(const ResolvedEntry& entry, QByteArray* data) {
        data->clear();
        if (entry.sizeBytes > kDefaultMaxMutationBytes) {
            return STATUS_FILE_TOO_LARGE;
        }
        if (entry.sizeBytes == 0) {
            return STATUS_SUCCESS;
        }
        QMutexLocker locker(&ioMutex_);
        const auto file = readerSession_->readFile(entry.path, entry.sizeBytes);
        if (!file.ok || !file.blockers.isEmpty()) {
            trace(QStringLiteral("read for mutation failed: %1")
                      .arg(file.blockers.join(QStringLiteral("; "))));
            return STATUS_ACCESS_DENIED;
        }
        *data = file.data;
        return STATUS_SUCCESS;
    }

    uint32_t attributesFor(const ResolvedEntry& entry) const {
        uint32_t attributes = readOnly_ ? FILE_ATTRIBUTE_READONLY : 0;
        if (entry.directory) {
            attributes |= FILE_ATTRIBUTE_DIRECTORY;
        } else {
            attributes |= FILE_ATTRIBUTE_ARCHIVE;
        }
        if (entry.symlink) {
            attributes |= FILE_ATTRIBUTE_REPARSE_POINT;
        }
        return attributes;
    }

    bool addDirInfo(const ResolvedEntry& entry,
                    const QString& name,
                    void* buffer,
                    ULONG length,
                    PULONG transferred) const {
        const std::wstring wideName = wide(name);
        const size_t bytes = wideName.size() * sizeof(wchar_t);
        const size_t storageSize = sizeof(FSP_FSCTL_DIR_INFO) + bytes;
        auto storage = std::make_unique<char[]>(storageSize);
        auto* dirInfo = reinterpret_cast<FSP_FSCTL_DIR_INFO*>(storage.get());
        std::memset(dirInfo, 0, storageSize);
        dirInfo->Size = static_cast<UINT16>(storageSize);
        fillFileInfo(entry, &dirInfo->FileInfo);
        if (bytes != 0) {
            std::memcpy(dirInfo->FileNameBuf, wideName.data(), bytes);
        }
        return FspFileSystemAddDirInfo(dirInfo, buffer, length, transferred) != FALSE;
    }

    QString target_;
    QString volumeLabel_{QStringLiteral("APFS")};
    std::unique_ptr<QIODevice> device_;
    std::unique_ptr<sak::PartitionApfsFileSystemReaderSession> readerSession_;
    mutable QMutex ioMutex_;
    mutable QMutex contextMutex_;
    std::vector<std::unique_ptr<FileContext>> activeContexts_;
    std::vector<std::unique_ptr<FileContext>> retiredContexts_;
    uint64_t nextHandleId_{1};
    uint64_t totalBytes_{0};
    uint64_t freeBytes_{0};
    uint64_t targetContainerBytes_{0};
    uint64_t maxFileReadBytes_{kDefaultMaxFileReadBytes};
    uint64_t createdTime_{0};
    bool readOnly_{true};
    bool rawTarget_{false};
    bool allowRawWrites_{false};
    PSECURITY_DESCRIPTOR securityDescriptor_{nullptr};
    ULONG securityDescriptorSize_{0};
};

ApfsMountState* stateOf(FSP_FILE_SYSTEM* fileSystem) {
    return reinterpret_cast<ApfsMountState*>(fileSystem->UserContext);
}

NTSTATUS FsGetVolumeInfo(FSP_FILE_SYSTEM* fileSystem, FSP_FSCTL_VOLUME_INFO* volumeInfo) {
    return stateOf(fileSystem)->volumeInfo(volumeInfo);
}

NTSTATUS FsSetVolumeLabel(FSP_FILE_SYSTEM*, PWSTR, FSP_FSCTL_VOLUME_INFO*) {
    return STATUS_MEDIA_WRITE_PROTECTED;
}

NTSTATUS FsGetSecurityByName(FSP_FILE_SYSTEM* fileSystem,
                             PWSTR fileName,
                             PUINT32 attributes,
                             PSECURITY_DESCRIPTOR descriptor,
                             SIZE_T* descriptorSize) {
    return stateOf(fileSystem)->securityByName(fromWide(fileName),
                                               attributes,
                                               descriptor,
                                               descriptorSize);
}

NTSTATUS FsCreate(FSP_FILE_SYSTEM* fileSystem,
                  PWSTR fileName,
                  UINT32 createOptions,
                  UINT32,
                  UINT32 fileAttributes,
                  PSECURITY_DESCRIPTOR,
                  UINT64,
                  PVOID* fileContext,
                  FSP_FSCTL_FILE_INFO* fileInfo) {
    trace(QStringLiteral("Create %1 attrs=0x%2")
              .arg(fromWide(fileName))
              .arg(fileAttributes, 8, 16, QLatin1Char('0')));
    FileContext* context = nullptr;
    const bool directory =
        (fileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0 ||
        (createOptions & FILE_DIRECTORY_FILE) != 0;
    const NTSTATUS status = stateOf(fileSystem)->createNode(fromWide(fileName),
                                                            directory,
                                                            &context,
                                                            fileInfo);
    if (NT_SUCCESS(status)) {
        *fileContext = context;
    }
    trace(QStringLiteral("CreateDone %1 status=0x%2")
              .arg(fromWide(fileName))
              .arg(static_cast<quint32>(status), 8, 16, QLatin1Char('0')));
    return status;
}

NTSTATUS FsOpen(FSP_FILE_SYSTEM* fileSystem,
                PWSTR fileName,
                UINT32,
                UINT32,
                PVOID* fileContext,
                FSP_FSCTL_FILE_INFO* fileInfo) {
    trace(QStringLiteral("Open %1").arg(fromWide(fileName)));
    ResolvedEntry entry;
    NTSTATUS status = stateOf(fileSystem)->resolvePath(fromWide(fileName), &entry);
    if (!NT_SUCCESS(status)) {
        return status;
    }
    auto* context = stateOf(fileSystem)->openContext(entry);
    if (!context) {
        return STATUS_INSUFFICIENT_RESOURCES;
    }
    *fileContext = context;
    stateOf(fileSystem)->fillFileInfo(entry, fileInfo);
    return STATUS_SUCCESS;
}

NTSTATUS FsOverwrite(FSP_FILE_SYSTEM* fileSystem,
                     PVOID fileContext,
                     UINT32,
                     BOOLEAN,
                     UINT64,
                     FSP_FSCTL_FILE_INFO* fileInfo) {
    auto* context = reinterpret_cast<FileContext*>(fileContext);
    trace(QStringLiteral("Overwrite %1")
              .arg(context ? context->entry.path : QStringLiteral("<null>")));
    return stateOf(fileSystem)->overwriteFile(context, fileInfo);
}

VOID FsCleanup(FSP_FILE_SYSTEM* fileSystem, PVOID fileContext, PWSTR, ULONG flags) {
    auto* context = reinterpret_cast<FileContext*>(fileContext);
    trace(QStringLiteral("Cleanup %1 flags=0x%2")
              .arg(context ? context->entry.path : QStringLiteral("<null>"))
              .arg(flags, 8, 16, QLatin1Char('0')));
    if (context && (flags & FspCleanupDelete) != 0) {
        context->deletePending = true;
        const NTSTATUS status = stateOf(fileSystem)->deleteFile(context);
        trace(QStringLiteral("CleanupDeleteDone status=0x%1")
                  .arg(static_cast<quint32>(status), 8, 16, QLatin1Char('0')));
    } else if (context) {
        const NTSTATUS status = stateOf(fileSystem)->flushFile(context, nullptr);
        trace(QStringLiteral("CleanupFlushDone status=0x%1")
                  .arg(static_cast<quint32>(status), 8, 16, QLatin1Char('0')));
    }
}

VOID FsClose(FSP_FILE_SYSTEM* fileSystem, PVOID fileContext) {
    auto* context = reinterpret_cast<FileContext*>(fileContext);
    trace(QStringLiteral("Close %1 handle=%2")
              .arg(context ? context->entry.path : QStringLiteral("<null>"))
              .arg(context ? context->handleId : 0));
    stateOf(fileSystem)->closeContext(context);
}

NTSTATUS FsRead(FSP_FILE_SYSTEM* fileSystem,
                PVOID fileContext,
                PVOID buffer,
                UINT64 offset,
                ULONG length,
                PULONG transferred) {
    *transferred = 0;
    const auto* context = reinterpret_cast<FileContext*>(fileContext);
    trace(QStringLiteral("Read %1 offset=%2 length=%3")
              .arg(context ? context->entry.path : QStringLiteral("<null>"))
              .arg(offset)
              .arg(length));
    if (!context) {
        return STATUS_INVALID_PARAMETER;
    }
    const NTSTATUS status =
        stateOf(fileSystem)->readFile(context, offset, length, buffer, transferred);
    trace(QStringLiteral("ReadDone status=0x%1 transferred=%2")
              .arg(static_cast<quint32>(status), 8, 16, QLatin1Char('0'))
              .arg(*transferred));
    return status;
}

NTSTATUS FsWrite(FSP_FILE_SYSTEM* fileSystem,
                 PVOID fileContext,
                 PVOID buffer,
                 UINT64 offset,
                 ULONG length,
                 BOOLEAN writeToEndOfFile,
                 BOOLEAN,
                 PULONG transferred,
                 FSP_FSCTL_FILE_INFO* fileInfo) {
    auto* context = reinterpret_cast<FileContext*>(fileContext);
    trace(QStringLiteral("Write %1 offset=%2 length=%3 eof=%4")
              .arg(context ? context->entry.path : QStringLiteral("<null>"))
              .arg(offset)
              .arg(length)
              .arg(writeToEndOfFile));
    const NTSTATUS status = stateOf(fileSystem)->writeFile(context,
                                                           buffer,
                                                           offset,
                                                           length,
                                                           writeToEndOfFile,
                                                           transferred,
                                                           fileInfo);
    trace(QStringLiteral("WriteDone status=0x%1 transferred=%2")
              .arg(static_cast<quint32>(status), 8, 16, QLatin1Char('0'))
              .arg(*transferred));
    return status;
}

NTSTATUS FsFlush(FSP_FILE_SYSTEM* fileSystem, PVOID fileContext, FSP_FSCTL_FILE_INFO* fileInfo) {
    auto* context = reinterpret_cast<FileContext*>(fileContext);
    trace(QStringLiteral("Flush %1").arg(context ? context->entry.path : QStringLiteral("<null>")));
    if (!context) {
        return STATUS_SUCCESS;
    }
    const NTSTATUS status = stateOf(fileSystem)->flushFile(context, fileInfo);
    trace(QStringLiteral("FlushDone status=0x%1")
              .arg(static_cast<quint32>(status), 8, 16, QLatin1Char('0')));
    return status;
}

NTSTATUS FsGetFileInfo(FSP_FILE_SYSTEM* fileSystem,
                       PVOID fileContext,
                       FSP_FSCTL_FILE_INFO* fileInfo) {
    const auto* context = reinterpret_cast<FileContext*>(fileContext);
    trace(QStringLiteral("GetFileInfo %1")
              .arg(context ? context->entry.path : QStringLiteral("<null>")));
    if (!context) {
        return STATUS_INVALID_PARAMETER;
    }
    stateOf(fileSystem)->fillFileInfo(context->entry, fileInfo);
    return STATUS_SUCCESS;
}

NTSTATUS FsSetBasicInfo(FSP_FILE_SYSTEM* fileSystem,
                        PVOID fileContext,
                        UINT32,
                        UINT64,
                        UINT64,
                        UINT64,
                        UINT64,
                        FSP_FSCTL_FILE_INFO* fileInfo) {
    auto* context = reinterpret_cast<FileContext*>(fileContext);
    trace(QStringLiteral("SetBasicInfo %1")
              .arg(context ? context->entry.path : QStringLiteral("<null>")));
    if (stateOf(fileSystem)->readOnly()) {
        return STATUS_MEDIA_WRITE_PROTECTED;
    }
    if (!context) {
        return STATUS_INVALID_PARAMETER;
    }
    stateOf(fileSystem)->fillFileInfo(context->entry, fileInfo);
    return STATUS_SUCCESS;
}

NTSTATUS FsSetFileSize(FSP_FILE_SYSTEM* fileSystem,
                       PVOID fileContext,
                       UINT64 newSize,
                       BOOLEAN setAllocationSize,
                       FSP_FSCTL_FILE_INFO* fileInfo) {
    auto* context = reinterpret_cast<FileContext*>(fileContext);
    trace(QStringLiteral("SetFileSize %1 size=%2 allocation=%3")
              .arg(context ? context->entry.path : QStringLiteral("<null>"))
              .arg(newSize)
              .arg(setAllocationSize));
    return stateOf(fileSystem)->setFileSize(context, newSize, setAllocationSize, fileInfo);
}

NTSTATUS FsCanDelete(FSP_FILE_SYSTEM* fileSystem, PVOID fileContext, PWSTR) {
    const auto* context = reinterpret_cast<FileContext*>(fileContext);
    trace(QStringLiteral("CanDelete %1")
              .arg(context ? context->entry.path : QStringLiteral("<null>")));
    const NTSTATUS status = stateOf(fileSystem)->canDelete(context);
    trace(QStringLiteral("CanDeleteDone status=0x%1")
              .arg(static_cast<quint32>(status), 8, 16, QLatin1Char('0')));
    return status;
}

NTSTATUS FsRename(FSP_FILE_SYSTEM* fileSystem,
                  PVOID fileContext,
                  PWSTR fileName,
                  PWSTR newFileName,
                  BOOLEAN replaceIfExists) {
    auto* context = reinterpret_cast<FileContext*>(fileContext);
    trace(QStringLiteral("Rename %1 -> %2 replace=%3")
              .arg(fromWide(fileName), fromWide(newFileName))
              .arg(replaceIfExists));
    return stateOf(fileSystem)->renameFile(context,
                                           fromWide(fileName),
                                           fromWide(newFileName),
                                           replaceIfExists != FALSE);
}

NTSTATUS FsGetSecurity(FSP_FILE_SYSTEM* fileSystem,
                       PVOID,
                       PSECURITY_DESCRIPTOR descriptor,
                       SIZE_T* descriptorSize) {
    return stateOf(fileSystem)->copySecurity(descriptor, descriptorSize);
}

NTSTATUS FsSetSecurity(FSP_FILE_SYSTEM* fileSystem,
                       PVOID fileContext,
                       SECURITY_INFORMATION,
                       PSECURITY_DESCRIPTOR) {
    auto* context = reinterpret_cast<FileContext*>(fileContext);
    trace(QStringLiteral("SetSecurity %1")
              .arg(context ? context->entry.path : QStringLiteral("<null>")));
    if (stateOf(fileSystem)->readOnly()) {
        return STATUS_MEDIA_WRITE_PROTECTED;
    }
    if (!context) {
        return STATUS_INVALID_PARAMETER;
    }
    return STATUS_SUCCESS;
}

NTSTATUS FsReadDirectory(FSP_FILE_SYSTEM* fileSystem,
                         PVOID fileContext,
                         PWSTR,
                         PWSTR marker,
                         PVOID buffer,
                         ULONG length,
                         PULONG transferred) {
    *transferred = 0;
    const auto* context = reinterpret_cast<FileContext*>(fileContext);
    trace(QStringLiteral("ReadDirectory %1 marker=%2 length=%3")
              .arg(context ? context->entry.path : QStringLiteral("<null>"))
              .arg(marker ? QString::fromWCharArray(marker) : QStringLiteral("<null>"))
              .arg(length));
    if (!context) {
        return STATUS_INVALID_PARAMETER;
    }
    const NTSTATUS status =
        stateOf(fileSystem)->listDirectory(context->entry, marker, buffer, length, transferred);
    trace(QStringLiteral("ReadDirectoryDone status=0x%1 transferred=%2")
              .arg(static_cast<quint32>(status), 8, 16, QLatin1Char('0'))
              .arg(*transferred));
    return status;
}

FSP_FILE_SYSTEM_INTERFACE* apfsInterface() {
    static FSP_FILE_SYSTEM_INTERFACE iface{};
    static bool initialized = false;
    if (!initialized) {
        iface.GetVolumeInfo = FsGetVolumeInfo;
        iface.SetVolumeLabel = FsSetVolumeLabel;
        iface.GetSecurityByName = FsGetSecurityByName;
        iface.Create = FsCreate;
        iface.Open = FsOpen;
        iface.Overwrite = FsOverwrite;
        iface.Cleanup = FsCleanup;
        iface.Close = FsClose;
        iface.Read = FsRead;
        iface.Write = FsWrite;
        iface.Flush = FsFlush;
        iface.GetFileInfo = FsGetFileInfo;
        iface.SetBasicInfo = FsSetBasicInfo;
        iface.SetFileSize = FsSetFileSize;
        iface.CanDelete = FsCanDelete;
        iface.Rename = FsRename;
        iface.GetSecurity = FsGetSecurity;
        iface.SetSecurity = FsSetSecurity;
        iface.ReadDirectory = FsReadDirectory;
        initialized = true;
    }
    return &iface;
}

NTSTATUS runMount(const QString& target,
                  const QString& mountPoint,
                  uint64_t maxFileReadBytes,
                  bool readOnly,
                  bool allowRawWrites) {
    ApfsMountState state;
    QString error;
    NTSTATUS status = state.openTarget(target, maxFileReadBytes, readOnly, allowRawWrites, &error);
    if (!NT_SUCCESS(status)) {
        QTextStream(stderr) << error << Qt::endl;
        return status;
    }

    FSP_FSCTL_VOLUME_PARAMS params{};
    params.Version = sizeof(FSP_FSCTL_VOLUME_PARAMS);
    params.SectorSize = static_cast<UINT16>(kAllocationUnit);
    params.SectorsPerAllocationUnit = 1;
    params.MaxComponentLength = 255 * sizeof(WCHAR);
    params.VolumeCreationTime = currentFileTime();
    params.VolumeSerialNumber = state.serialNumber();
    params.FileInfoTimeout = 1000;
    params.CaseSensitiveSearch = 1;
    params.CasePreservedNames = 1;
    params.UnicodeOnDisk = 1;
    params.PersistentAcls = 1;
    params.ReadOnlyVolume = readOnly ? 1 : 0;
    params.PostCleanupWhenModifiedOnly = 0;
    params.AlwaysUseDoubleBuffering = 1;
    wcscpy_s(params.FileSystemName, L"APFS");

    FSP_FILE_SYSTEM* fileSystem = nullptr;
    std::wstring devicePath = L"" FSP_FSCTL_DISK_DEVICE_NAME;
    status = FspFileSystemCreate(devicePath.data(), &params, apfsInterface(), &fileSystem);
    if (!NT_SUCCESS(status)) {
        QTextStream(stderr) << "FspFileSystemCreate failed: 0x" << Qt::hex << status << Qt::endl;
        return status;
    }

    fileSystem->UserContext = &state;
    const std::wstring mountWide = wide(mountPoint);
    status = FspFileSystemSetMountPoint(fileSystem,
                                        mountWide.empty() ? nullptr
                                                          : const_cast<PWSTR>(mountWide.c_str()));
    if (!NT_SUCCESS(status)) {
        QTextStream(stderr) << "FspFileSystemSetMountPoint failed: 0x" << Qt::hex << status
                            << Qt::endl;
        FspFileSystemDelete(fileSystem);
        return status;
    }

    SetConsoleCtrlHandler(consoleHandler, TRUE);
    status = FspFileSystemStartDispatcher(fileSystem, 0);
    if (!NT_SUCCESS(status)) {
        QTextStream(stderr) << "FspFileSystemStartDispatcher failed: 0x" << Qt::hex << status
                            << Qt::endl;
        FspFileSystemDelete(fileSystem);
        return status;
    }

    gFileSystemForSignal = fileSystem;
    QTextStream(stdout) << "mounted " << mountPoint << " as "
                        << (readOnly ? "read-only" : "read-write") << " APFS volume "
                        << state.volumeLabel() << Qt::endl;
    while (!gStopRequested) {
        Sleep(250);
    }
    FspFileSystemRemoveMountPoint(fileSystem);
    FspFileSystemStopDispatcher(fileSystem);
    FspFileSystemDelete(fileSystem);
    return STATUS_SUCCESS;
}

#endif

void printStatus() {
    QJsonObject status{{QStringLiteral("component"), QStringLiteral("apfs_winfs_worker")},
#if APFS_HAVE_WINFSP
                       {QStringLiteral("status"), QStringLiteral("ready")},
                       {QStringLiteral("winfsp_sdk"), QStringLiteral("found")},
                       {QStringLiteral("winfsp_callbacks"),
                        QStringLiteral("read_only_and_guarded_image_rw_apfs")}};
#else
                       {QStringLiteral("status"), QStringLiteral("scaffold")},
                       {QStringLiteral("winfsp_sdk"), QStringLiteral("missing")},
                       {QStringLiteral("winfsp_callbacks"), QStringLiteral("unavailable")}};
#endif
    QTextStream(stdout) << QJsonDocument(status).toJson(QJsonDocument::Indented);
}

}  // namespace

int main(int argc, char* argv[]) {
    QCoreApplication app(argc, argv);
    QCoreApplication::setApplicationName(QStringLiteral("apfs_winfs_worker"));
    QCoreApplication::setApplicationVersion(QStringLiteral("0.1.0"));

    QCommandLineParser parser;
    parser.setApplicationDescription(QStringLiteral("WinFsp APFS mount worker."));
    parser.addHelpOption();
    parser.addVersionOption();
    QCommandLineOption statusOption{{QStringLiteral("status")},
                                    QStringLiteral("Print worker readiness JSON and exit.")};
    QCommandLineOption targetOption{{QStringLiteral("target")},
                                    QStringLiteral("APFS image, raw partition, or physical disk."),
                                    QStringLiteral("path")};
    QCommandLineOption mountOption{{QStringLiteral("mount")},
                                   QStringLiteral("Drive letter or directory mount point."),
                                   QStringLiteral("path")};
    QCommandLineOption maxReadOption{{QStringLiteral("max-file-read-bytes")},
                                     QStringLiteral("Maximum bytes read from one APFS file."),
                                     QStringLiteral("bytes"),
                                     QString::number(kDefaultMaxFileReadBytes)};
    QCommandLineOption readWriteOption{{QStringLiteral("read-write")},
                                       QStringLiteral("Mount writable. Image targets only unless --allow-raw-writes is also present.")};
    QCommandLineOption allowRawWritesOption{{QStringLiteral("allow-raw-writes")},
                                            QStringLiteral("Allow direct raw-device APFS mutation after external media confirmation.")};
    parser.addOption(statusOption);
    parser.addOption(targetOption);
    parser.addOption(mountOption);
    parser.addOption(maxReadOption);
    parser.addOption(readWriteOption);
    parser.addOption(allowRawWritesOption);
    parser.process(app);

    if (parser.isSet(statusOption) ||
        (!parser.isSet(targetOption) && !parser.isSet(mountOption))) {
        printStatus();
        return 0;
    }

#if !APFS_HAVE_WINFSP
    QTextStream(stderr) << "WinFsp SDK/runtime is required for mounting." << Qt::endl;
    return 4;
#else
    const QString target = parser.value(targetOption).trimmed();
    const QString mount = parser.value(mountOption).trimmed();
    if (target.isEmpty() || mount.isEmpty()) {
        QTextStream(stderr) << "--target and --mount are required for mount mode" << Qt::endl;
        return 2;
    }
    const uint64_t maxRead = parser.value(maxReadOption).toULongLong();
    const bool readOnly = !parser.isSet(readWriteOption);
    const bool allowRawWrites = parser.isSet(allowRawWritesOption);
    const NTSTATUS status = runMount(target, mount, maxRead, readOnly, allowRawWrites);
    if (NT_SUCCESS(status)) {
        return 0;
    }
    return static_cast<int>(status & 0xFFFF);
#endif
}
