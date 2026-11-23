// Copyright (c) 2026 Randy Northrup. All rights reserved.

#include "sak/apfs_compression.h"
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
#include <QHash>
#include <QIODevice>
#include <QJsonDocument>
#include <QJsonObject>
#include <QMutex>
#include <QMutexLocker>
#include <QProcess>
#include <QRegularExpression>
#include <QSet>
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
#include <unordered_map>
#include <vector>

#if APFS_HAVE_WINFSP
#include <windows.h>
#include <winternl.h>
#ifndef PNTSTATUS
using PNTSTATUS = NTSTATUS *;
#endif
#include <sddl.h>
#include <winfsp/winfsp.h>
#endif

namespace {

constexpr uint64_t kFallbackProbeBytes = 1024ULL * 1024ULL * 1024ULL;
constexpr uint64_t kDefaultMaxFileReadBytes =
    std::numeric_limits<uint64_t>::max();
constexpr uint64_t kDefaultMaxMutationBytes = 64ULL * 1024ULL * 1024ULL;
constexpr uint64_t kAllocationUnit = 4096;
constexpr uint64_t kWindowsEpochOffset100Ns = 116'444'736'000'000'000ULL;
constexpr uint32_t kBsdFlagUserImmutable = 0x00000002U;
constexpr uint32_t kBsdFlagUserHidden = 0x00008000U;
constexpr uint32_t kBsdFlagUserArchive = 0x00010000U;
constexpr qint64 kMaxTraceBytes = 8LL * 1024LL * 1024LL;
constexpr int kTestFaultExitCode = 197;
constexpr QLatin1StringView
    kTestFaultBeforeImageReplace("before-image-replace");
constexpr QLatin1StringView kTestFaultAfterImageReplace("after-image-replace");
constexpr int kWindowsEaMaxNameBytes = 127;
constexpr QLatin1StringView kWindowsEaAliasPrefix("APFS.XATTR.");
constexpr char kWindowsEaAliasValueVersion = 1;
constexpr uint64_t kApfsVolumeRootObjectId = 2;

QByteArray windowsEaAliasPrefixBytes() {
  return QByteArray(kWindowsEaAliasPrefix.data(), kWindowsEaAliasPrefix.size());
}

bool isContentCriticalXattr(const QByteArray &name) {
  return name == QByteArray(sak::kApfsXattrNameCompressed) ||
         name == QByteArray(sak::kApfsXattrNameResourceFork) ||
         name == QByteArray("com.apple.fs.symlink");
}

bool isDirectWindowsEaName(const QString &name, QByteArray *bytes = nullptr) {
  const QByteArray ascii = name.toLatin1();
  static constexpr QLatin1StringView kForbidden("\\/:*?\"<>|,+=[];");
  if (ascii.isEmpty() || ascii.size() > kWindowsEaMaxNameBytes ||
      ascii.contains('\0') || QString::fromLatin1(ascii) != name ||
      name.startsWith(kWindowsEaAliasPrefix, Qt::CaseInsensitive) ||
      std::any_of(ascii.cbegin(), ascii.cend(),
                  [](char value) {
                    const auto byte = static_cast<unsigned char>(value);
                    return byte < 0x20 || byte > 0x7e;
                  }) ||
      std::any_of(ascii.cbegin(), ascii.cend(), [](char value) {
        return kForbidden.contains(QLatin1Char(value));
      })) {
    return false;
  }
  if (bytes) {
    *bytes = ascii;
  }
  return true;
}

QByteArray encodeBase32(const QByteArray &bytes) {
  static constexpr char kAlphabet[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
  QByteArray encoded;
  encoded.reserve((bytes.size() * 8 + 4) / 5);
  uint32_t buffer = 0;
  int bits = 0;
  for (const char value : bytes) {
    buffer = (buffer << 8U) | static_cast<unsigned char>(value);
    bits += 8;
    while (bits >= 5) {
      bits -= 5;
      encoded.append(kAlphabet[(buffer >> bits) & 0x1fU]);
    }
  }
  if (bits != 0) {
    encoded.append(kAlphabet[(buffer << (5 - bits)) & 0x1fU]);
  }
  return encoded;
}

std::optional<QByteArray> decodeBase32(const QByteArray &encoded) {
  if (encoded.isEmpty()) {
    return std::nullopt;
  }
  QByteArray decoded;
  decoded.reserve(encoded.size() * 5 / 8);
  uint32_t buffer = 0;
  int bits = 0;
  for (const char character : encoded.toUpper()) {
    uint32_t value = 0;
    if (character >= 'A' && character <= 'Z') {
      value = static_cast<uint32_t>(character - 'A');
    } else if (character >= '2' && character <= '7') {
      value = static_cast<uint32_t>(character - '2' + 26);
    } else {
      return std::nullopt;
    }
    buffer = (buffer << 5U) | value;
    bits += 5;
    if (bits >= 8) {
      bits -= 8;
      decoded.append(static_cast<char>((buffer >> bits) & 0xffU));
    }
  }
  if (encodeBase32(decoded) != encoded.toUpper()) {
    return std::nullopt;
  }
  return decoded;
}

bool decodeWindowsEaAlias(const QByteArray &wireName, QString *name) {
  const QByteArray prefix = windowsEaAliasPrefixBytes();
  if (wireName.left(prefix.size()).toUpper() != prefix) {
    return false;
  }
  const auto decoded = decodeBase32(wireName.mid(prefix.size()));
  if (!decoded.has_value() || decoded->isEmpty() ||
      decoded->size() > kWindowsEaMaxNameBytes || decoded->contains('\0')) {
    return false;
  }
  const QString text = QString::fromUtf8(*decoded);
  if (text.isEmpty() || text.toUtf8() != *decoded) {
    return false;
  }
  if (name) {
    *name = text;
  }
  return true;
}

QByteArray encodeWindowsEaAlias(const QString &name) {
  return windowsEaAliasPrefixBytes() + encodeBase32(name.toUtf8());
}

QString windowsEaCaseKey(const QString &name) { return name.toCaseFolded(); }

QSet<QString> windowsEaCollisionKeys(const QVector<QString> &names) {
  QHash<QString, QString> firstNameByKey;
  QSet<QString> collisions;
  for (const QString &name : names) {
    const QString key = windowsEaCaseKey(name);
    const auto first = firstNameByKey.constFind(key);
    if (first == firstNameByKey.cend()) {
      firstNameByKey.insert(key, name);
    } else if (*first != name) {
      collisions.insert(key);
    }
  }
  return collisions;
}

struct WindowsEaPolicyMutation {
  QString name;
  bool remove{false};
  bool aliased{false};
};

bool validateWindowsEaMutations(QVector<QString> names,
                                const QVector<WindowsEaPolicyMutation> &mutations) {
  for (const WindowsEaPolicyMutation &mutation : mutations) {
    const bool exactExists = names.contains(mutation.name);
    const QString key = windowsEaCaseKey(mutation.name);
    const bool differentCaseExists = std::any_of(
        names.cbegin(), names.cend(), [&](const QString &name) {
          return name != mutation.name && windowsEaCaseKey(name) == key;
        });
    if (differentCaseExists && (!exactExists || !mutation.aliased)) {
      return false;
    }
    if (mutation.remove) {
      names.removeAll(mutation.name);
    } else if (!exactExists) {
      names.append(mutation.name);
    }
  }
  return true;
}

bool windowsEaPolicySelfTest() {
  const QVector<QString> collisionNames{QStringLiteral("user.Proof"),
                                        QStringLiteral("user.proof"),
                                        QStringLiteral("user.unique")};
  const QSet<QString> collisionKeys = windowsEaCollisionKeys(collisionNames);
  const QString collisionKey = windowsEaCaseKey(QStringLiteral("user.Proof"));
  return collisionKeys.contains(collisionKey) &&
         !collisionKeys.contains(windowsEaCaseKey(QStringLiteral("user.unique"))) &&
         !validateWindowsEaMutations(
             {QStringLiteral("user.Proof")},
             {{QStringLiteral("user.proof"), false, false}}) &&
         !validateWindowsEaMutations(
             {QStringLiteral("user.Proof"), QStringLiteral("user.proof")},
             {{QStringLiteral("user.Proof"), false, false}}) &&
         validateWindowsEaMutations(
             {QStringLiteral("user.Proof"), QStringLiteral("user.proof")},
             {{QStringLiteral("user.Proof"), false, true}}) &&
         validateWindowsEaMutations(
             {QStringLiteral("user.Proof")},
             {{QStringLiteral("user.Proof"), false, false}}) &&
         !validateWindowsEaMutations(
             {},
             {{QStringLiteral("user.Proof"), false, false},
              {QStringLiteral("user.proof"), false, false}});
}

QString writableMountPolicyBlocker(
    const sak::PartitionApfsFileReadResult::VolumePolicy &policy) {
  if (!policy.known) {
    return QStringLiteral("APFS volume write policy is unknown");
  }
  if (policy.sealed) {
    return QStringLiteral("sealed APFS volumes are read-only");
  }
  if (policy.encrypted) {
    return policy.per_file_keys
               ? QStringLiteral("per-file-key encrypted APFS volumes are read-only")
               : QStringLiteral("FileVault APFS volumes are read-only");
  }
  return {};
}

bool apfsVolumePolicySelfTest() {
  using VolumePolicy = sak::PartitionApfsFileReadResult::VolumePolicy;
  VolumePolicy normal;
  normal.known = true;
  VolumePolicy sealed = normal;
  sealed.sealed = true;
  VolumePolicy fileVault = normal;
  fileVault.encrypted = true;
  fileVault.one_key = true;
  VolumePolicy perFile = normal;
  perFile.encrypted = true;
  perFile.per_file_keys = true;
  return writableMountPolicyBlocker(normal).isEmpty() &&
         !writableMountPolicyBlocker(VolumePolicy{}).isEmpty() &&
         !writableMountPolicyBlocker(sealed).isEmpty() &&
         !writableMountPolicyBlocker(fileVault).isEmpty() &&
         !writableMountPolicyBlocker(perFile).isEmpty();
}

QString normalizeApfsPath(const QString &input) {
  // Do not trim: Win32 already strips trailing spaces and dots before a
  // request reaches the file system, and APFS names may legitimately begin or
  // end with other Unicode whitespace.
  QString path = input;
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

QString parentPath(const QString &path) {
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

QString baseName(const QString &path) {
  const QString normalized = normalizeApfsPath(path);
  if (normalized == QStringLiteral("/")) {
    return QStringLiteral("/");
  }
  const qsizetype slash = normalized.lastIndexOf(QLatin1Char('/'));
  return slash >= 0 ? normalized.mid(slash + 1) : normalized;
}

bool isRootChildPath(const QString &path) {
  const QString normalized = normalizeApfsPath(path);
  return normalized != QStringLiteral("/") &&
         normalized.count(QLatin1Char('/')) == 1 &&
         !baseName(normalized).isEmpty();
}

QStringList pathComponents(const QString &path) {
  QString normalized = normalizeApfsPath(path);
  if (normalized == QStringLiteral("/")) {
    return {};
  }
  if (normalized.startsWith(QLatin1Char('/'))) {
    normalized.remove(0, 1);
  }
  return normalized.split(QLatin1Char('/'), Qt::SkipEmptyParts);
}

bool splitMutableFilePath(const QString &path, QString *parentDirectoryPath,
                          QString *fileName) {
  const QStringList parts = pathComponents(path);
  if (parts.isEmpty()) {
    return false;
  }
  if (parentDirectoryPath) {
    if (parts.size() == 1) {
      parentDirectoryPath->clear();
    } else {
      *parentDirectoryPath =
          QStringLiteral("/") +
          parts.mid(0, parts.size() - 1).join(QLatin1Char('/'));
    }
  }
  if (fileName) {
    *fileName = parts.last();
  }
  return true;
}

bool splitMutableRootDirectoryPath(const QString &path,
                                   QString *directoryName) {
  const QStringList parts = pathComponents(path);
  if (parts.isEmpty()) {
    return false;
  }
  if (directoryName) {
    *directoryName = parts.join(QLatin1Char('/'));
  }
  return true;
}

bool splitDirectoryCreatePath(const QString &path, QString *parentDirectoryPath,
                              QString *directoryName) {
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
          QStringLiteral("/") +
          parts.mid(0, parts.size() - 1).join(QLatin1Char('/'));
    }
  }
  return true;
}

bool looksLikeWindowsRawTarget(const QString &target) {
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

// The core caps listings at max_entries and only reports the cap as a
// warning; ask for everything and fail closed if it still truncates.
constexpr int kUnlimitedListing = std::numeric_limits<int>::max();

bool listingTruncated(const sak::PartitionApfsFileReadResult &listing) {
  return std::any_of(listing.warnings.cbegin(), listing.warnings.cend(),
                     [](const QString &warning) {
                       return warning.contains(QStringLiteral("truncated"),
                                               Qt::CaseInsensitive);
                     });
}

// Directory enumeration order: case-insensitive, ties broken by exact code
// units. The resume marker must use the same comparator.
bool directoryNameLess(const QString &left, const QString &right) {
  const int folded = left.compare(right, Qt::CaseInsensitive);
  if (folded != 0) {
    return folded < 0;
  }
  return left < right;
}

QMutex gTraceMutex;

bool processIsAlive(qint64 processId) {
  if (processId <= 0 || processId > std::numeric_limits<DWORD>::max()) {
    return false;
  }
  HANDLE process =
      OpenProcess(SYNCHRONIZE, FALSE, static_cast<DWORD>(processId));
  if (!process) {
    return GetLastError() == ERROR_ACCESS_DENIED;
  }
  const DWORD wait = WaitForSingleObject(process, 0);
  CloseHandle(process);
  return wait == WAIT_TIMEOUT;
}

void trace(const QString &message) {
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
  QTextStream(&file) << QDateTime::currentDateTimeUtc().toString(
                            Qt::ISODateWithMs)
                     << " " << message << Qt::endl;
}

std::atomic_bool gStopRequested{false};
HANDLE gShutdownComplete{nullptr};
constexpr DWORD kConsoleCloseShutdownWaitMs = 4500;
constexpr DWORD kStopPollIntervalMs = 250;

BOOL WINAPI consoleHandler(DWORD controlType) {
  switch (controlType) {
  case CTRL_C_EVENT:
  case CTRL_BREAK_EVENT:
  case CTRL_CLOSE_EVENT:
  case CTRL_SHUTDOWN_EVENT:
    // Only request the stop; the main thread owns the orderly shutdown
    // (flush, stop dispatcher, remove mount point, delete file system).
    gStopRequested = true;
    if ((controlType == CTRL_CLOSE_EVENT ||
         controlType == CTRL_SHUTDOWN_EVENT) &&
        gShutdownComplete) {
      // The process is terminated as soon as this handler returns for close
      // and shutdown events, so give the main thread time to unmount.
      WaitForSingleObject(gShutdownComplete, kConsoleCloseShutdownWaitMs);
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

uint64_t fileTimeFromUnixNs(uint64_t unixNs) {
  const uint64_t ticks = unixNs / 100;
  if (ticks > std::numeric_limits<uint64_t>::max() - kWindowsEpochOffset100Ns) {
    return std::numeric_limits<uint64_t>::max();
  }
  return ticks + kWindowsEpochOffset100Ns;
}

uint64_t unixNsFromFileTime(uint64_t fileTime) {
  if (fileTime <= kWindowsEpochOffset100Ns) {
    return 0;
  }
  const uint64_t ticks = fileTime - kWindowsEpochOffset100Ns;
  if (ticks > std::numeric_limits<uint64_t>::max() / 100) {
    return std::numeric_limits<uint64_t>::max();
  }
  return ticks * 100;
}

std::wstring wide(const QString &value) { return value.toStdWString(); }

QString fromWide(PWSTR value) {
  return normalizeApfsPath(value ? QString::fromWCharArray(value)
                                 : QStringLiteral("/"));
}

void copyVolumeLabel(const QString &label, FSP_FSCTL_VOLUME_INFO *volumeInfo) {
  const std::wstring labelWide = wide(label.left(32));
  const auto bytes = static_cast<UINT16>(std::min<size_t>(
      labelWide.size() * sizeof(wchar_t), sizeof(volumeInfo->VolumeLabel)));
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
  uint32_t hardLinks{1};
  uint64_t createdTimeNs{0};
  uint64_t modifiedTimeNs{0};
  uint64_t changedTimeNs{0};
  uint64_t accessedTimeNs{0};
  uint32_t writeGenerationCounter{0};
  uint32_t bsdFlags{0};
  uint32_t ownerId{0};
  uint32_t groupId{0};
  uint16_t inodeMode{0};
};

// Shared per-path state for every open handle of the same file name. WinFsp
// keeps one kernel file node per name and posts Cleanup(Delete) only on the
// last outstanding cleanup of that name, so the user-mode node mirrors that
// identity. Every field except the atomics is guarded by `mutex`.
struct FileNode {
  FileNode() = default;
  FileNode(const FileNode &) = delete;
  FileNode &operator=(const FileNode &) = delete;
  ~FileNode() {
    if (stagedWriteFileBacked && !stagedWritePath.isEmpty()) {
      QFile::remove(stagedWritePath);
    }
  }

  QMutex mutex;
  uint64_t nodeId{0};
  QString key;
  ResolvedEntry entry;
  // Handles that have been opened but not yet cleaned up.
  int openHandles{0};
  // Handles that have been opened but not yet closed.
  int references{0};
  // The node is no longer reachable by name (deleted or replaced).
  bool detached{false};
  bool createdByCreate{false};
  bool stagedWriteActive{false};
  bool stagedWriteDirty{false};
  bool deletePending{false};
  QByteArray stagedWriteData;
  QString stagedWritePath;
  bool stagedWriteFileBacked{false};
  // Cross-node hard-link count propagation without taking a second node
  // mutex: writers publish here, the owning node applies it under its lock.
  std::atomic<uint64_t> publishedObjectId{0};
  std::atomic<uint32_t> pendingHardLinks{0};
};

// Per-handle WinFsp file descriptor (UmFileContextIsUserContext2 = 1). Each
// Open/Create returns a fresh FileContext, and WinFsp posts exactly one Close
// for it.
struct FileContext {
  uint64_t handleId{0};
  std::shared_ptr<FileNode> node;
  bool cleanedUp{false};
};

// Locks a node for one WinFsp callback and keeps the lock-free hard-link
// propagation fields in sync with the guarded entry.
class NodeGuard {
public:
  explicit NodeGuard(FileNode *node) : node_(node) {
    if (node_) {
      node_->mutex.lock();
      const uint32_t links = node_->pendingHardLinks.exchange(0);
      if (links != 0) {
        node_->entry.hardLinks = links;
      }
    }
  }
  ~NodeGuard() {
    if (node_) {
      node_->publishedObjectId = node_->entry.objectId;
      node_->mutex.unlock();
    }
  }
  NodeGuard(const NodeGuard &) = delete;
  NodeGuard &operator=(const NodeGuard &) = delete;

private:
  FileNode *node_;
};

FileNode *nodeOf(PVOID fileContext) {
  auto *context = reinterpret_cast<FileContext *>(fileContext);
  return context ? context->node.get() : nullptr;
}

struct EaMutationCollectContext {
  QVector<sak::PartitionApfsXattrMutation> mutations;
  QVector<WindowsEaPolicyMutation> policyMutations;
};

NTSTATUS collectEaMutation(FSP_FILE_SYSTEM *, PVOID contextValue,
                           PFILE_FULL_EA_INFORMATION ea) {
  if (!contextValue || !ea || ea->EaNameLength == 0 || ea->Flags != 0) {
    return STATUS_EA_LIST_INCONSISTENT;
  }
  const QByteArray wireName(ea->EaName, ea->EaNameLength);
  const auto *value =
      reinterpret_cast<const char *>(ea->EaName) + ea->EaNameLength + 1;
  QString decodedName;
  QByteArray decodedBytes;
  QByteArray decodedValue;
  bool remove = ea->EaValueLength == 0;
  bool aliased = false;
  const QByteArray aliasPrefix = windowsEaAliasPrefixBytes();
  if (wireName.left(aliasPrefix.size()).toUpper() == aliasPrefix) {
    aliased = true;
    if (!decodeWindowsEaAlias(wireName, &decodedName)) {
      return STATUS_EA_LIST_INCONSISTENT;
    }
    decodedBytes = decodedName.toUtf8();
    if (!remove) {
      if (*value != kWindowsEaAliasValueVersion) {
        return STATUS_EA_LIST_INCONSISTENT;
      }
      decodedValue = QByteArray(value + 1, ea->EaValueLength - 1);
    }
  } else {
    decodedName = QString::fromLatin1(wireName);
    QByteArray validatedName;
    if (!isDirectWindowsEaName(decodedName, &validatedName) ||
        validatedName != wireName) {
      return STATUS_EA_LIST_INCONSISTENT;
    }
    decodedBytes = validatedName;
    decodedValue = QByteArray(value, ea->EaValueLength);
  }
  if (isContentCriticalXattr(decodedBytes)) {
    return STATUS_EA_LIST_INCONSISTENT;
  }
  auto *context = static_cast<EaMutationCollectContext *>(contextValue);
  context->mutations.append(
      {.name = decodedName, .value = decodedValue, .remove = remove});
  context->policyMutations.append(
      {.name = decodedName, .remove = remove, .aliased = aliased});
  return STATUS_SUCCESS;
}

class ApfsMountState {
public:
  ~ApfsMountState() {
    if (securityDescriptor_) {
      LocalFree(securityDescriptor_);
    }
  }

  NTSTATUS openTarget(const QString &target, uint64_t maxFileReadBytes,
                      bool readOnly, bool allowRawWrites,
                      const QString &testFaultExitPhase,
                      const QString &testFaultPath, QString *error) {
    target_ = target;
    readOnly_ = readOnly;
    allowRawWrites_ = allowRawWrites;
    maxFileReadBytes_ =
        maxFileReadBytes == 0 ? kDefaultMaxFileReadBytes : maxFileReadBytes;
    createdTime_ = currentFileTime();
    rawTarget_ = looksLikeWindowsRawTarget(target_);
    testFaultExitPhase_ = testFaultExitPhase;
    testFaultPath_ = normalizeApfsPath(testFaultPath);
    if (!rawTarget_) {
      recoverAndCleanImageMutationTemps();
    }
    if (!readOnly_ && rawTarget_ && !allowRawWrites_) {
      if (error) {
        *error = QStringLiteral("raw APFS write mount requires "
                                "--allow-raw-writes and explicit media proof");
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
    const uint64_t size = device_->size() > 0
                              ? static_cast<uint64_t>(device_->size())
                              : kFallbackProbeBytes;
    const auto detection = sak::PartitionFileSystemDetector::detectFromDevice(
        device_.get(), 0, size, &detectError);
    if (!detection.has_value() ||
        detection->file_system.compare(QStringLiteral("APFS"),
                                       Qt::CaseInsensitive) != 0) {
      if (error) {
        *error = detectError.isEmpty() ? QStringLiteral("target is not APFS")
                                       : detectError;
      }
      return STATUS_UNRECOGNIZED_VOLUME;
    }

    targetContainerBytes_ =
        detection->total_bytes != 0 ? detection->total_bytes : size;

    readerSession_ =
        std::make_unique<sak::PartitionApfsFileSystemReaderSession>(
            device_.get());
    const auto root = readerSession_->listDirectory(QStringLiteral("/"), 1);
    {
      QMutexLocker volumeLocker(&volumeInfoMutex_);
      totalBytes_ = detection->total_bytes;
      freeBytes_ = detection->free_bytes;
      if (!root.volume_name.trimmed().isEmpty()) {
        volumeLabel_ = root.volume_name.trimmed().left(32);
      }
      if (volumeLabel_.isEmpty()) {
        volumeLabel_ = QStringLiteral("APFS");
      }
    }
    if (!root.blockers.isEmpty()) {
      if (error) {
        *error = root.blockers.join(QStringLiteral("; "));
      }
      return STATUS_ACCESS_DENIED;
    }
    if (!readOnly_) {
      const QString blocker = writableMountPolicyBlocker(root.volume_policy);
      if (!blocker.isEmpty()) {
        if (error) {
          *error = blocker;
        }
        return STATUS_MEDIA_WRITE_PROTECTED;
      }
    }

    if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
            readOnly_
                ? L"O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;FR;;;BU)(A;;FR;;;WD)"
                : L"O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;FA;;;BU)(A;;FA;;;"
                  L"WD)",
            SDDL_REVISION_1, &securityDescriptor_, &securityDescriptorSize_)) {
      if (error) {
        *error = QStringLiteral("security descriptor creation failed");
      }
      return FspNtStatusFromWin32(GetLastError());
    }

    return STATUS_SUCCESS;
  }

  void setMountPoint(const QString &mountPoint) {
    mountPoint_ = QDir::toNativeSeparators(mountPoint);
  }

  NTSTATUS volumeInfo(FSP_FSCTL_VOLUME_INFO *info) const {
    QMutexLocker locker(&volumeInfoMutex_);
    info->TotalSize = totalBytes_;
    info->FreeSize = freeBytes_;
    copyVolumeLabel(volumeLabel_, info);
    return STATUS_SUCCESS;
  }

  NTSTATUS resolvePath(const QString &path, ResolvedEntry *resolved) {
    const QString normalized = normalizeApfsPath(path);
    QMutexLocker locker(&ioMutex_);
    return resolvePathNoLock(normalized, resolved);
  }

  NTSTATUS readFile(const FileNode *node, uint64_t offset, ULONG length,
                    void *buffer, PULONG transferred) {
    if (!node) {
      return STATUS_INVALID_PARAMETER;
    }
    const ResolvedEntry &entry = node->entry;
    if (entry.directory) {
      return STATUS_INVALID_DEVICE_REQUEST;
    }
    if (node->stagedWriteActive) {
      if (node->stagedWriteFileBacked) {
        return readHostFileBytes(node->stagedWritePath, offset, length,
                                 buffer, transferred);
      }
      return readBytes(node->stagedWriteData, offset, length, buffer,
                       transferred);
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
    const NTSTATUS readerStatus = ensureReaderNoLock();
    if (!NT_SUCCESS(readerStatus)) {
      return readerStatus;
    }
    const auto file =
        readerSession_->readFileRange(entry.path, offset, bytesNeeded);
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

  NTSTATUS listDirectory(const ResolvedEntry &directory, PWSTR marker,
                         void *buffer, ULONG length, PULONG transferred) {
    if (!directory.directory) {
      return STATUS_NOT_A_DIRECTORY;
    }

    QMutexLocker locker(&ioMutex_);
    const NTSTATUS readerStatus = ensureReaderNoLock();
    if (!NT_SUCCESS(readerStatus)) {
      return readerStatus;
    }
    const auto listing =
        readerSession_->listDirectory(directory.path, kUnlimitedListing);
    if (!listing.blockers.isEmpty()) {
      return STATUS_OBJECT_NAME_NOT_FOUND;
    }
    if (listingTruncated(listing)) {
      trace(QStringLiteral("directory listing truncated: %1")
                .arg(directory.path));
      return STATUS_INSUFFICIENT_RESOURCES;
    }

    QVector<sak::PartitionApfsFileEntry> entries = listing.entries;
    std::sort(entries.begin(), entries.end(),
              [](const auto &left, const auto &right) {
                return directoryNameLess(left.name, right.name);
              });

    const QString markerName =
        marker ? QString::fromWCharArray(marker) : QString{};
    for (const auto &entry : entries) {
      // Resume strictly after the marker using the exact sort order, so names
      // that differ only by case are neither skipped nor repeated.
      if (!markerName.isEmpty() &&
          !directoryNameLess(markerName, entry.name)) {
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

  NTSTATUS securityByName(const QString &path, PUINT32 attributes,
                          PSECURITY_DESCRIPTOR descriptor,
                          SIZE_T *descriptorSize) {
    ResolvedEntry entry;
    NTSTATUS status = resolvePath(path, &entry);
    if (!NT_SUCCESS(status)) {
      return status;
    }
    if (attributes) {
      *attributes = attributesFor(entry);
    }
    return copySecurity(entry, descriptor, descriptorSize);
  }

  NTSTATUS copySecurity(const ResolvedEntry &, PSECURITY_DESCRIPTOR descriptor,
                        SIZE_T *descriptorSize) const {
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

  void fillFileInfo(const ResolvedEntry &entry,
                    FSP_FSCTL_FILE_INFO *info) const {
    std::memset(info, 0, sizeof(*info));
    info->FileAttributes = attributesFor(entry);
    info->AllocationSize = alignAllocation(entry.sizeBytes);
    info->FileSize = entry.sizeBytes;
    info->CreationTime = entry.createdTimeNs != 0
                             ? fileTimeFromUnixNs(entry.createdTimeNs)
                             : createdTime_;
    info->LastAccessTime = entry.accessedTimeNs != 0
                               ? fileTimeFromUnixNs(entry.accessedTimeNs)
                               : createdTime_;
    info->LastWriteTime = entry.modifiedTimeNs != 0
                              ? fileTimeFromUnixNs(entry.modifiedTimeNs)
                              : createdTime_;
    info->ChangeTime = entry.changedTimeNs != 0
                           ? fileTimeFromUnixNs(entry.changedTimeNs)
                           : createdTime_;
    info->IndexNumber = entry.objectId == 0 ? 1 : entry.objectId;
    info->HardLinks = std::max<uint32_t>(1, entry.hardLinks);
    info->ReparseTag = entry.symlink ? IO_REPARSE_TAG_SYMLINK : 0;
    trace(QStringLiteral("FileInfo path=%1 object=%2 links=%3")
              .arg(entry.path)
              .arg(info->IndexNumber)
              .arg(info->HardLinks));
  }

  uint32_t serialNumber() const {
    const QByteArray hash =
        QCryptographicHash::hash(target_.toUtf8(), QCryptographicHash::Md5);
    uint32_t serial = 0;
    std::memcpy(&serial, hash.constData(), sizeof(serial));
    return serial == 0 ? 0x41504653U : serial;
  }

  QString volumeLabel() const {
    QMutexLocker locker(&volumeInfoMutex_);
    return volumeLabel_;
  }
  bool readOnly() const { return readOnly_; }

  // Opens one WinFsp handle on an already resolved entry. Handles of the same
  // path share one FileNode (staged data, delete-pending, size); `fresh`
  // forces a new node, used right after Create.
  FileContext *openHandle(const ResolvedEntry &entry, bool createdByCreate,
                          bool fresh, FSP_FSCTL_FILE_INFO *info) {
    std::unique_ptr<FileContext> context(new (std::nothrow) FileContext);
    if (!context) {
      return nullptr;
    }
    const QString key = normalizeApfsPath(entry.path);
    std::shared_ptr<FileNode> node;
    bool joined = false;
    {
      QMutexLocker locker(&contextMutex_);
      const auto found = nodes_.constFind(key);
      if (!fresh && found != nodes_.cend() && *found && !(*found)->detached) {
        node = *found;
        joined = true;
      } else {
        node = std::shared_ptr<FileNode>(new (std::nothrow) FileNode);
        if (!node) {
          return nullptr;
        }
        node->nodeId = nextNodeId_++;
        node->key = key;
        node->entry = entry;
        node->entry.path = key;
        node->createdByCreate = createdByCreate;
        node->publishedObjectId = entry.objectId;
        if (found != nodes_.cend() && *found) {
          (*found)->detached = true;
        }
        nodes_.insert(key, node);
      }
      ++node->openHandles;
      ++node->references;
      context->handleId = nextHandleId_++;
      context->node = node;
    }
    FileContext *raw = context.get();
    {
      NodeGuard guard(node.get());
      // A joined node keeps its staged view; otherwise refresh the metadata
      // from the fresh lookup so another alias' changes become visible.
      if (joined && !node->stagedWriteActive && node->entry.path == key) {
        node->entry = entry;
        node->entry.path = key;
      }
      if (info) {
        fillFileInfo(node->entry, info);
      }
    }
    QMutexLocker locker(&contextMutex_);
    handles_.emplace(raw, std::move(context));
    return raw;
  }

  // WinFsp Cleanup. Caller must hold the node lock. Cleanup(Delete) is always
  // the last outstanding cleanup of the name because POSIX unlink semantics
  // are not enabled. Any other cleanup commits dirty staged data, so closing a
  // writer's handle persists its writes even while readers keep the name
  // open; the clean stage is kept for those readers and dropped on last Close.
  void cleanupHandle(FileContext *context, ULONG flags) {
    FileNode *node = context->node.get();
    int remainingHandles = 0;
    {
      QMutexLocker locker(&contextMutex_);
      if (!context->cleanedUp) {
        context->cleanedUp = true;
        --node->openHandles;
      }
      remainingHandles = node->openHandles;
    }
    if ((flags & FspCleanupDelete) != 0) {
      node->deletePending = true;
      const NTSTATUS status = deleteFile(node);
      trace(QStringLiteral("CleanupDeleteDone status=0x%1")
                .arg(static_cast<quint32>(status), 8, 16, QLatin1Char('0')));
      if (NT_SUCCESS(status)) {
        detachNode(node, node->entry.directory);
      } else {
        // The name still exists; do not suppress later flushes on it.
        node->deletePending = false;
      }
      return;
    }
    if (node->stagedWriteDirty) {
      const NTSTATUS status = flushFile(node, nullptr);
      trace(QStringLiteral("CleanupFlushDone status=0x%1 remaining=%2")
                .arg(static_cast<quint32>(status), 8, 16, QLatin1Char('0'))
                .arg(remainingHandles));
    }
  }

  // WinFsp Close: exactly one per handle. Frees the handle; the last close of
  // a node commits any write that arrived after the last cleanup, then
  // discards the staged data and forgets the node.
  void closeHandle(FileContext *context) {
    if (!context) {
      return;
    }
    const std::shared_ptr<FileNode> node = context->node;
    bool lastReference = false;
    {
      QMutexLocker locker(&contextMutex_);
      if (node) {
        if (!context->cleanedUp) {
          context->cleanedUp = true;
          --node->openHandles;
        }
        --node->references;
        lastReference = node->references <= 0;
      }
      handles_.erase(context);
    }
    if (!node || !lastReference) {
      return;
    }
    NodeGuard guard(node.get());
    bool detached = false;
    {
      QMutexLocker locker(&contextMutex_);
      detached = node->detached;
    }
    if (node->stagedWriteDirty && !node->deletePending && !detached) {
      const NTSTATUS status = flushFile(node.get(), nullptr);
      trace(QStringLiteral("CloseFlushDone %1 status=0x%2")
                .arg(node->entry.path)
                .arg(static_cast<quint32>(status), 8, 16, QLatin1Char('0')));
    } else if (node->stagedWriteDirty) {
      trace(QStringLiteral("CloseDiscardDirty %1 detached=%2 delete=%3")
                .arg(node->entry.path)
                .arg(detached)
                .arg(node->deletePending));
    }
    bool forget = false;
    {
      QMutexLocker locker(&contextMutex_);
      if (node->references <= 0) {
        const auto found = nodes_.constFind(node->key);
        if (found != nodes_.cend() && found->get() == node.get()) {
          nodes_.erase(found);
        }
        node->detached = true;
        forget = true;
      }
    }
    if (forget) {
      discardStagedWrite(node.get());
    }
  }

  // Orderly shutdown: commit every dirty staged write still held by an open
  // handle. Returns the number of nodes whose flush failed.
  int flushAllNodes() {
    std::vector<std::shared_ptr<FileNode>> nodes;
    {
      QMutexLocker locker(&contextMutex_);
      nodes.reserve(static_cast<size_t>(nodes_.size()));
      for (const auto &node : std::as_const(nodes_)) {
        if (node && !node->detached) {
          nodes.push_back(node);
        }
      }
    }
    int failures = 0;
    for (const auto &node : nodes) {
      NodeGuard guard(node.get());
      if (!node->stagedWriteDirty || node->deletePending) {
        continue;
      }
      const NTSTATUS status = flushFile(node.get(), nullptr);
      trace(QStringLiteral("ShutdownFlush %1 status=0x%2")
                .arg(node->entry.path)
                .arg(static_cast<quint32>(status), 8, 16, QLatin1Char('0')));
      if (!NT_SUCCESS(status)) {
        ++failures;
      }
    }
    return failures;
  }

  NTSTATUS createNode(const QString &path, bool directory,
                      FileContext **outContext, FSP_FSCTL_FILE_INFO *info) {
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
    const NTSTATUS existingStatus = resolvePath(normalized, &existing);
    if (existingStatus == STATUS_SUCCESS) {
      return STATUS_OBJECT_NAME_COLLISION;
    }
    if (existingStatus != STATUS_OBJECT_NAME_NOT_FOUND) {
      return existingStatus;
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

    auto *context = openHandle(created, true, true, info);
    if (!context) {
      return STATUS_INSUFFICIENT_RESOURCES;
    }
    *outContext = context;
    return STATUS_SUCCESS;
  }

  NTSTATUS overwriteFile(FileNode *node, FSP_FSCTL_FILE_INFO *info) {
    if (readOnly_) {
      return STATUS_MEDIA_WRITE_PROTECTED;
    }
    QString directoryName;
    QString fileName;
    if (!node || node->entry.directory ||
        !splitMutableFilePath(node->entry.path, &directoryName, &fileName)) {
      return STATUS_NOT_SUPPORTED;
    }
    if (node->stagedWriteFileBacked && !node->stagedWritePath.isEmpty()) {
      QFile::remove(node->stagedWritePath);
    }
    node->stagedWriteActive = true;
    node->stagedWriteDirty = node->entry.sizeBytes != 0;
    node->stagedWriteData.clear();
    node->stagedWritePath.clear();
    node->stagedWriteFileBacked = false;
    node->entry.sizeBytes = 0;
    fillFileInfo(node->entry, info);
    return STATUS_SUCCESS;
  }

  NTSTATUS writeFile(FileNode *node, const void *buffer, uint64_t offset,
                     ULONG length, BOOLEAN writeToEndOfFile,
                     BOOLEAN constrainedIo, PULONG transferred,
                     FSP_FSCTL_FILE_INFO *info) {
    *transferred = 0;
    if (readOnly_) {
      return STATUS_MEDIA_WRITE_PROTECTED;
    }
    QString directoryName;
    QString fileName;
    if (!node || node->entry.directory ||
        !splitMutableFilePath(node->entry.path, &directoryName, &fileName)) {
      return STATUS_NOT_SUPPORTED;
    }
    if (constrainedIo) {
      // Paging/constrained I/O must never change the file size: clip to the
      // current end of file, and treat writes at or past it as no-ops.
      const uint64_t currentSize = node->entry.sizeBytes;
      if (offset >= currentSize) {
        fillFileInfo(node->entry, info);
        return STATUS_SUCCESS;
      }
      length = static_cast<ULONG>(
          std::min<uint64_t>(length, currentSize - offset));
      writeToEndOfFile = FALSE;
    }
    if (length == 0) {
      fillFileInfo(node->entry, info);
      return STATUS_SUCCESS;
    }

    QByteArray data;
    const bool staged =
        node->createdByCreate || node->stagedWriteActive;
    NTSTATUS status = STATUS_SUCCESS;
    if (staged) {
      status = ensureStagedWriteData(node);
      if (!NT_SUCCESS(status)) {
        return status;
      }
      data = node->stagedWriteData;
    } else {
      status = readMutableBytes(node->entry, &data);
      if (!NT_SUCCESS(status)) {
        return status;
      }
    }
    const uint64_t stagedSize = node->stagedWriteFileBacked
                                    ? node->entry.sizeBytes
                                    : static_cast<uint64_t>(data.size());
    const uint64_t writeOffset = writeToEndOfFile ? stagedSize : offset;
    if (length > std::numeric_limits<uint64_t>::max() - writeOffset) {
      return STATUS_FILE_TOO_LARGE;
    }
    const uint64_t requiredSize = writeOffset + length;
    if (staged && rawTarget_ &&
        (node->stagedWriteFileBacked ||
         requiredSize > kDefaultMaxMutationBytes)) {
      status = ensureFileBackedStage(node, data);
      if (!NT_SUCCESS(status)) {
        return status;
      }
      status =
          writeStagedFile(node, buffer, writeOffset, length, requiredSize);
      if (!NT_SUCCESS(status)) {
        return status;
      }
      node->stagedWriteActive = true;
      node->stagedWriteDirty = true;
      node->entry.sizeBytes =
          std::max<uint64_t>(node->entry.sizeBytes, requiredSize);
      *transferred = length;
      fillFileInfo(node->entry, info);
      return STATUS_SUCCESS;
    }
    if (writeOffset > kDefaultMaxMutationBytes ||
        length >
            kDefaultMaxMutationBytes -
                std::min<uint64_t>(writeOffset, kDefaultMaxMutationBytes)) {
      return STATUS_FILE_TOO_LARGE;
    }
    const qsizetype required = static_cast<qsizetype>(requiredSize);
    if (required > data.size()) {
      data.resize(required);
    }
    std::memcpy(data.data() + writeOffset, buffer, length);

    if (staged) {
      node->stagedWriteData = data;
      node->stagedWriteActive = true;
      node->stagedWriteDirty = true;
      node->entry.sizeBytes = static_cast<uint64_t>(data.size());
      *transferred = length;
      fillFileInfo(node->entry, info);
      return STATUS_SUCCESS;
    }

    status = commitFileWrite(node->entry.path, data, &node->entry);
    if (NT_SUCCESS(status)) {
      *transferred = length;
      fillFileInfo(node->entry, info);
    }
    return status;
  }

  NTSTATUS setFileSize(FileNode *node, uint64_t newSize,
                       BOOLEAN setAllocationSize, FSP_FSCTL_FILE_INFO *info) {
    if (readOnly_) {
      return STATUS_MEDIA_WRITE_PROTECTED;
    }
    QString directoryName;
    QString fileName;
    if (!node || node->entry.directory ||
        !splitMutableFilePath(node->entry.path, &directoryName, &fileName)) {
      return STATUS_NOT_SUPPORTED;
    }
    const bool staged =
        node->createdByCreate || node->stagedWriteActive;
    if (newSize > kDefaultMaxMutationBytes && !(staged && rawTarget_)) {
      return STATUS_FILE_TOO_LARGE;
    }
    if (setAllocationSize && newSize >= node->entry.sizeBytes) {
      fillFileInfo(node->entry, info);
      return STATUS_SUCCESS;
    }

    QByteArray data;
    NTSTATUS status = STATUS_SUCCESS;
    if (staged) {
      status = ensureStagedWriteData(node);
      if (!NT_SUCCESS(status)) {
        return status;
      }
      if (rawTarget_ && (node->stagedWriteFileBacked ||
                         newSize > kDefaultMaxMutationBytes)) {
        status = ensureFileBackedStage(node, node->stagedWriteData);
        if (!NT_SUCCESS(status)) {
          return status;
        }
        QFile file(node->stagedWritePath);
        if (!file.open(QIODevice::ReadWrite) ||
            !file.resize(static_cast<qint64>(newSize))) {
          return STATUS_ACCESS_DENIED;
        }
        node->stagedWriteActive = true;
        node->stagedWriteDirty = true;
        node->entry.sizeBytes = newSize;
        fillFileInfo(node->entry, info);
        return STATUS_SUCCESS;
      }
      data = node->stagedWriteData;
    } else {
      status = readMutableBytes(node->entry, &data);
      if (!NT_SUCCESS(status)) {
        return status;
      }
    }
    data.resize(static_cast<qsizetype>(newSize));
    if (staged) {
      node->stagedWriteData = data;
      node->stagedWriteActive = true;
      node->stagedWriteDirty = true;
      node->entry.sizeBytes = static_cast<uint64_t>(data.size());
      fillFileInfo(node->entry, info);
      return STATUS_SUCCESS;
    }
    status = commitFileWrite(node->entry.path, data, &node->entry);
    if (NT_SUCCESS(status)) {
      fillFileInfo(node->entry, info);
    }
    return status;
  }

  NTSTATUS canDelete(const FileNode *node) {
    if (readOnly_) {
      return STATUS_MEDIA_WRITE_PROTECTED;
    }
    if (!node) {
      return STATUS_NOT_SUPPORTED;
    }
    if (node->entry.directory) {
      QString directoryName;
      if (!splitMutableRootDirectoryPath(node->entry.path, &directoryName)) {
        return STATUS_NOT_SUPPORTED;
      }
      QMutexLocker locker(&ioMutex_);
      const NTSTATUS readerStatus = ensureReaderNoLock();
      if (!NT_SUCCESS(readerStatus)) {
        return readerStatus;
      }
      const auto listing =
          readerSession_->listDirectory(node->entry.path, 1);
      if (!listing.ok || !listing.blockers.isEmpty()) {
        return STATUS_ACCESS_DENIED;
      }
      return listing.entries.isEmpty() ? STATUS_SUCCESS
                                       : STATUS_DIRECTORY_NOT_EMPTY;
    }
    QString directoryName;
    QString fileName;
    if (!splitMutableFilePath(node->entry.path, &directoryName, &fileName)) {
      return STATUS_NOT_SUPPORTED;
    }
    return STATUS_SUCCESS;
  }

  NTSTATUS deleteFile(FileNode *node) {
    if (readOnly_) {
      return STATUS_MEDIA_WRITE_PROTECTED;
    }
    if (!node) {
      return STATUS_NOT_SUPPORTED;
    }
    trace(QStringLiteral("Delete %1 directory=%2")
              .arg(node->entry.path)
              .arg(node->entry.directory));
    if (!node->entry.directory) {
      discardStagedWrite(node);
    }
    if (node->entry.directory) {
      QString parentDirectoryPath;
      QString directoryName;
      if (!splitDirectoryCreatePath(node->entry.path, &parentDirectoryPath,
                                    &directoryName)) {
        return STATUS_NOT_SUPPORTED;
      }
      return commitDirectoryDelete(node->entry.path);
    }
    QString directoryName;
    QString fileName;
    if (!splitMutableFilePath(node->entry.path, &directoryName, &fileName)) {
      return STATUS_NOT_SUPPORTED;
    }
    return commitFileDelete(node->entry.path);
  }

  NTSTATUS renameFile(FileNode *node, const QString &oldPath,
                      const QString &newPath, bool replaceIfExists) {
    if (readOnly_) {
      return STATUS_MEDIA_WRITE_PROTECTED;
    }
    const QString normalizedOld = normalizeApfsPath(oldPath);
    const QString normalizedNew = normalizeApfsPath(newPath);
    if (!node) {
      return STATUS_NOT_SUPPORTED;
    }
    if (node->stagedWriteDirty) {
      const NTSTATUS flushStatus = flushFile(node, nullptr);
      if (!NT_SUCCESS(flushStatus)) {
        return flushStatus;
      }
    }
    if (node->entry.directory) {
      QString oldParentDirectoryPath;
      QString oldDirectoryName;
      QString newParentDirectoryPath;
      QString newDirectoryName;
      if (!splitDirectoryCreatePath(normalizedOld, &oldParentDirectoryPath,
                                    &oldDirectoryName) ||
          !splitDirectoryCreatePath(normalizedNew, &newParentDirectoryPath,
                                    &newDirectoryName)) {
        return STATUS_NOT_SUPPORTED;
      }
      if (replaceIfExists) {
        // MoveFileEx(MOVEFILE_REPLACE_EXISTING) sets this even when the
        // target is absent; only an existing, different target is refused
        // (replacing a directory is not supported).
        ResolvedEntry existing;
        const NTSTATUS existingStatus = resolvePath(normalizedNew, &existing);
        if (NT_SUCCESS(existingStatus)) {
          if (existing.objectId != node->entry.objectId) {
            return STATUS_ACCESS_DENIED;
          }
        } else if (existingStatus != STATUS_OBJECT_NAME_NOT_FOUND) {
          return existingStatus;
        }
      }
      ResolvedEntry updated;
      NTSTATUS status =
          commitDirectoryRename(normalizedOld, normalizedNew, &updated);
      if (NT_SUCCESS(status)) {
        node->entry = updated;
        rekeyNode(node, normalizedOld, normalizedNew, true);
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
        if (existing.objectId != node->entry.objectId) {
          return replaceFileByRename(node, normalizedOld, normalizedNew);
        }
      } else if (existingStatus != STATUS_OBJECT_NAME_NOT_FOUND) {
        return existingStatus;
      }
    }

    ResolvedEntry updated;
    NTSTATUS status = commitFileRename(normalizedOld, normalizedNew, &updated);
    if (NT_SUCCESS(status)) {
      node->entry = updated;
      rekeyNode(node, normalizedOld, normalizedNew, false);
    }
    return status;
  }

  // Rename-over-existing without a core primitive for it. The target is first
  // moved aside to a hidden unique name in its own directory, so a failure of
  // the main rename can put it back instead of losing the user's file.
  NTSTATUS replaceFileByRename(FileNode *node, const QString &normalizedOld,
                               const QString &normalizedNew) {
    const QString asidePath = normalizeApfsPath(
        parentPath(normalizedNew) + QStringLiteral("/.apfs-replace-%1.tmp").arg(
            QUuid::createUuid().toString(QUuid::Id128)));
    ResolvedEntry aside;
    NTSTATUS status = commitFileRename(normalizedNew, asidePath, &aside);
    if (!NT_SUCCESS(status)) {
      trace(QStringLiteral("replace: moving target aside failed %1 -> %2")
                .arg(normalizedNew, asidePath));
      return status;
    }

    ResolvedEntry updated;
    status = commitFileRename(normalizedOld, normalizedNew, &updated);
    if (!NT_SUCCESS(status)) {
      ResolvedEntry restored;
      const NTSTATUS restoreStatus =
          commitFileRename(asidePath, normalizedNew, &restored);
      if (!NT_SUCCESS(restoreStatus)) {
        trace(QStringLiteral("replace: rename failed and restoring the "
                             "original target failed; it is preserved at %1")
                  .arg(asidePath));
      }
      return status;
    }
    node->entry = updated;
    rekeyNode(node, normalizedOld, normalizedNew, false);

    const NTSTATUS deleteStatus = commitFileDelete(asidePath);
    if (!NT_SUCCESS(deleteStatus)) {
      // The rename itself succeeded; only the replaced copy lingers.
      trace(QStringLiteral("replace: removing replaced target %1 failed "
                           "status=0x%2")
                .arg(asidePath)
                .arg(static_cast<quint32>(deleteStatus), 8, 16,
                     QLatin1Char('0')));
    }
    return STATUS_SUCCESS;
  }

  // Moves a renamed node (and, for directories, any cached descendants) to its
  // new key. A stale node already at the destination is detached so it can
  // never be joined or flushed over the renamed file.
  void rekeyNode(FileNode *node, const QString &oldPath, const QString &newPath,
                 bool directory) {
    QMutexLocker locker(&contextMutex_);
    std::shared_ptr<FileNode> self;
    const auto current = nodes_.constFind(node->key);
    if (current != nodes_.cend() && current->get() == node) {
      self = *current;
      nodes_.erase(current);
    }
    const auto occupant = nodes_.constFind(newPath);
    if (occupant != nodes_.cend()) {
      if (*occupant && occupant->get() != node) {
        (*occupant)->detached = true;
      }
      nodes_.erase(occupant);
    }
    if (directory) {
      // WinFsp refuses to rename a directory with open descendants; any left
      // here are cleaned-up handles awaiting Close. Detach them rather than
      // touch their entries without their locks.
      const QString prefix = oldPath + QLatin1Char('/');
      for (auto it = nodes_.begin(); it != nodes_.end();) {
        if (it.key().startsWith(prefix)) {
          if (it.value()) {
            it.value()->detached = true;
          }
          it = nodes_.erase(it);
        } else {
          ++it;
        }
      }
    }
    node->key = newPath;
    if (self && !self->detached) {
      nodes_.insert(newPath, self);
    }
  }

  // Forgets a deleted node so a later Create/Open of the same name starts
  // from a fresh node.
  void detachNode(FileNode *node, bool directory) {
    QMutexLocker locker(&contextMutex_);
    const auto found = nodes_.constFind(node->key);
    if (found != nodes_.cend() && found->get() == node) {
      nodes_.erase(found);
    }
    node->detached = true;
    if (directory) {
      const QString prefix = node->key + QLatin1Char('/');
      for (auto it = nodes_.begin(); it != nodes_.end();) {
        if (it.key().startsWith(prefix)) {
          if (it.value()) {
            it.value()->detached = true;
          }
          it = nodes_.erase(it);
        } else {
          ++it;
        }
      }
    }
  }

#if defined(FSP_FILE_SYSTEM_INTERFACE_HAS_CREATE_HARD_LINK)
  NTSTATUS createHardLink(FileNode *node, const QString &newPath,
                          bool replaceIfExists,
                          FSP_FSCTL_FILE_INFO *fileInfo) {
    if (readOnly_) {
      return STATUS_MEDIA_WRITE_PROTECTED;
    }
    if (!node || node->entry.directory || !node->entry.regularFile ||
        node->entry.symlink) {
      return STATUS_NOT_SUPPORTED;
    }
    if (replaceIfExists) {
      return STATUS_NOT_SUPPORTED;
    }
    if (node->stagedWriteDirty) {
      const NTSTATUS flushStatus = flushFile(node, nullptr);
      if (!NT_SUCCESS(flushStatus)) {
        return flushStatus;
      }
    }

    ResolvedEntry linked;
    const NTSTATUS status =
        commitFileHardLink(node->entry.path, newPath, &linked);
    if (!NT_SUCCESS(status)) {
      return status;
    }
    node->entry.hardLinks = linked.hardLinks;
    updateOpenContextHardLinks(node, node->entry.objectId, linked.hardLinks);
    fillFileInfo(node->entry, fileInfo);
    return STATUS_SUCCESS;
  }
#endif

  NTSTATUS flushFile(FileNode *node, FSP_FSCTL_FILE_INFO *info) {
    if (!node) {
      return STATUS_INVALID_PARAMETER;
    }
    if (!node->stagedWriteDirty) {
      if (info) {
        fillFileInfo(node->entry, info);
      }
      return STATUS_SUCCESS;
    }
    if (readOnly_) {
      return STATUS_MEDIA_WRITE_PROTECTED;
    }
    if (node->entry.directory || node->deletePending) {
      if (info) {
        fillFileInfo(node->entry, info);
      }
      return STATUS_SUCCESS;
    }
    trace(QStringLiteral("StagedFlush %1 bytes=%2 file_backed=%3")
              .arg(node->entry.path)
              .arg(node->entry.sizeBytes)
              .arg(node->stagedWriteFileBacked));
    NTSTATUS status =
        node->stagedWriteFileBacked
            ? commitFileWriteFromPath(node->entry.path,
                                      node->stagedWritePath,
                                      node->entry.sizeBytes, &node->entry)
            : commitFileWrite(node->entry.path, node->stagedWriteData,
                              &node->entry);
    trace(QStringLiteral("StagedFlushDone status=0x%1")
              .arg(static_cast<quint32>(status), 8, 16, QLatin1Char('0')));
    if (NT_SUCCESS(status)) {
      // Keep the (now clean) stage while handles remain open: other handles
      // of this node keep reading and writing it without re-reading the file
      // (which is impossible for large raw-target stages). The last Close
      // discards it.
      node->stagedWriteDirty = false;
      if (info) {
        fillFileInfo(node->entry, info);
      }
    }
    return status;
  }

  NTSTATUS setBasicInfoCallback(FileNode *node, UINT32 fileAttributes,
                                UINT64 creationTime, UINT64 lastAccessTime,
                                UINT64 lastWriteTime, UINT64 changeTime,
                                FSP_FSCTL_FILE_INFO *fileInfo) {
    return setBasicInfo(node, fileAttributes, creationTime, lastAccessTime,
                        lastWriteTime, changeTime, fileInfo);
  }

  NTSTATUS setSecurityCallback(FileNode *node,
                               SECURITY_INFORMATION securityInformation,
                               PSECURITY_DESCRIPTOR modificationDescriptor) {
    return setSecurity(node, securityInformation, modificationDescriptor);
  }

  NTSTATUS getEaCallback(FileNode *node, PFILE_FULL_EA_INFORMATION ea,
                         ULONG eaLength, PULONG bytesTransferred) {
    return getEa(node, ea, eaLength, bytesTransferred);
  }

  NTSTATUS setEaCallback(FSP_FILE_SYSTEM *fileSystem, FileNode *node,
                         PFILE_FULL_EA_INFORMATION ea, ULONG eaLength,
                         FSP_FSCTL_FILE_INFO *fileInfo) {
    return setEa(fileSystem, node, ea, eaLength, fileInfo);
  }

  NTSTATUS getReparsePointByNameCallback(const QString &path, PVOID buffer,
                                         PSIZE_T size) {
    return getReparsePointByName(path, buffer, size);
  }

  NTSTATUS getReparsePointCallback(const FileNode *node, PVOID buffer,
                                   PSIZE_T size) {
    return getReparsePoint(node, buffer, size);
  }

  NTSTATUS setReparsePointCallback(FileNode *node, PVOID buffer,
                                   SIZE_T size) {
    return setReparsePoint(node, buffer, size);
  }

  NTSTATUS deleteReparsePointCallback(FileNode *node, PVOID buffer,
                                      SIZE_T size) {
    return deleteReparsePoint(node, buffer, size);
  }

private:
  static NTSTATUS readBytes(const QByteArray &data, uint64_t offset,
                            ULONG length, void *buffer, PULONG transferred) {
    if (offset >= static_cast<uint64_t>(data.size())) {
      return STATUS_END_OF_FILE;
    }
    const uint64_t available = static_cast<uint64_t>(data.size()) - offset;
    const ULONG toCopy =
        static_cast<ULONG>(std::min<uint64_t>(length, available));
    std::memcpy(buffer, data.constData() + offset, toCopy);
    *transferred = toCopy;
    return STATUS_SUCCESS;
  }

  static bool fitsQint64(uint64_t value) {
    return value <= static_cast<uint64_t>(std::numeric_limits<qint64>::max());
  }

  static NTSTATUS readHostFileBytes(const QString &path, uint64_t offset,
                                    ULONG length, void *buffer,
                                    PULONG transferred) {
    *transferred = 0;
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly)) {
      return STATUS_ACCESS_DENIED;
    }
    const uint64_t size =
        file.size() >= 0 ? static_cast<uint64_t>(file.size()) : 0;
    if (offset >= size) {
      return STATUS_END_OF_FILE;
    }
    if (!fitsQint64(offset) || !file.seek(static_cast<qint64>(offset))) {
      return STATUS_ACCESS_DENIED;
    }
    const ULONG toRead =
        static_cast<ULONG>(std::min<uint64_t>(length, size - offset));
    const QByteArray chunk = file.read(static_cast<qint64>(toRead));
    if (chunk.size() < 0) {
      return STATUS_ACCESS_DENIED;
    }
    std::memcpy(buffer, chunk.constData(), static_cast<size_t>(chunk.size()));
    *transferred = static_cast<ULONG>(chunk.size());
    return STATUS_SUCCESS;
  }

  QString stagedTempPath(const FileNode *node) const {
    return QDir::temp().filePath(
        QStringLiteral("apfs-winfs-stage-%1-%2.tmp")
            .arg(node ? node->nodeId : 0)
            .arg(QUuid::createUuid().toString(QUuid::Id128)));
  }

  NTSTATUS ensureFileBackedStage(FileNode *node,
                                 const QByteArray &initialData) const {
    if (!node || node->entry.directory) {
      return STATUS_NOT_SUPPORTED;
    }
    if (node->stagedWriteFileBacked) {
      return STATUS_SUCCESS;
    }
    const uint64_t initialSize = static_cast<uint64_t>(initialData.size());
    const uint64_t targetSize =
        std::max<uint64_t>(node->entry.sizeBytes, initialSize);
    if (!fitsQint64(targetSize)) {
      return STATUS_FILE_TOO_LARGE;
    }
    const QString path = stagedTempPath(node);
    QFile file(path);
    if (!file.open(QIODevice::WriteOnly)) {
      return STATUS_ACCESS_DENIED;
    }
    if (!initialData.isEmpty() &&
        file.write(initialData) != initialData.size()) {
      file.close();
      QFile::remove(path);
      return STATUS_ACCESS_DENIED;
    }
    if (targetSize != initialSize &&
        !file.resize(static_cast<qint64>(targetSize))) {
      file.close();
      QFile::remove(path);
      return STATUS_ACCESS_DENIED;
    }
    file.close();
    node->stagedWritePath = path;
    node->stagedWriteFileBacked = true;
    node->stagedWriteData.clear();
    return STATUS_SUCCESS;
  }

  NTSTATUS writeStagedFile(FileNode *node, const void *buffer,
                           uint64_t offset, ULONG length,
                           uint64_t requiredSize) const {
    if (!node || !node->stagedWriteFileBacked ||
        node->stagedWritePath.isEmpty()) {
      return STATUS_INVALID_PARAMETER;
    }
    if (!fitsQint64(offset) || !fitsQint64(requiredSize)) {
      return STATUS_FILE_TOO_LARGE;
    }
    QFile file(node->stagedWritePath);
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
    if (length != 0 && file.write(static_cast<const char *>(buffer),
                                  static_cast<qint64>(length)) !=
                           static_cast<qint64>(length)) {
      return STATUS_ACCESS_DENIED;
    }
    if (requiredSize > static_cast<uint64_t>(file.size()) &&
        !file.resize(static_cast<qint64>(requiredSize))) {
      return STATUS_ACCESS_DENIED;
    }
    return STATUS_SUCCESS;
  }

  NTSTATUS ensureStagedWriteData(FileNode *node) {
    if (!node || node->entry.directory) {
      return STATUS_NOT_SUPPORTED;
    }
    if (node->stagedWriteActive) {
      return STATUS_SUCCESS;
    }
    if (node->createdByCreate && node->entry.sizeBytes == 0) {
      node->stagedWriteData.clear();
      node->stagedWriteActive = true;
      return STATUS_SUCCESS;
    }
    NTSTATUS status =
        readMutableBytes(node->entry, &node->stagedWriteData);
    if (!NT_SUCCESS(status)) {
      return status;
    }
    node->stagedWriteActive = true;
    return STATUS_SUCCESS;
  }

  void discardStagedWrite(FileNode *node) const {
    if (!node) {
      return;
    }
    if (node->stagedWriteFileBacked) {
      QFile::remove(node->stagedWritePath);
    }
    node->stagedWritePath.clear();
    node->stagedWriteFileBacked = false;
    node->stagedWriteData.clear();
    node->stagedWriteActive = false;
    node->stagedWriteDirty = false;
  }

  NTSTATUS resolvePathNoLock(const QString &normalized,
                             ResolvedEntry *resolved) {
    const NTSTATUS readerStatus = ensureReaderNoLock();
    if (!NT_SUCCESS(readerStatus)) {
      return readerStatus;
    }
    if (normalized == QStringLiteral("/")) {
      const auto root = readerSession_->debugFile(normalized);
      if (!root.ok || !root.blockers.isEmpty()) {
        trace(QStringLiteral("resolve root inode failed: %1")
                  .arg(root.blockers.join(QStringLiteral("; "))));
        return STATUS_OBJECT_NAME_NOT_FOUND;
      }
      if (resolved) {
        *resolved = ResolvedEntry{.path = QStringLiteral("/"),
                                  .name = QStringLiteral(""),
                                  .directory = true,
                                  .regularFile = false,
                                  .symlink = false,
                                  .objectId = kApfsVolumeRootObjectId,
                                  .sizeBytes = 0,
                                  .hardLinks = 1,
                                  .createdTimeNs = root.inode_created_time_ns,
                                  .modifiedTimeNs = root.inode_modified_time_ns,
                                  .changedTimeNs = root.inode_changed_time_ns,
                                  .accessedTimeNs = root.inode_accessed_time_ns,
                                  .writeGenerationCounter =
                                      root.inode_write_generation_counter,
                                  .bsdFlags = root.inode_bsd_flags,
                                  .ownerId = root.inode_owner_id,
                                  .groupId = root.inode_group_id,
                                  .inodeMode = root.inode_mode};
      }
      return STATUS_SUCCESS;
    }

    const auto listing =
        readerSession_->listDirectory(parentPath(normalized), kUnlimitedListing);
    if (!listing.blockers.isEmpty()) {
      return STATUS_OBJECT_NAME_NOT_FOUND;
    }
    if (listingTruncated(listing)) {
      trace(QStringLiteral("parent listing truncated while resolving %1")
                .arg(normalized));
      return STATUS_INSUFFICIENT_RESOURCES;
    }

    const QString wanted = baseName(normalized);
    std::optional<sak::PartitionApfsFileEntry> fallback;
    for (const auto &entry : listing.entries) {
      if (entry.name == wanted) {
        return fillResolved(entry, normalized, resolved);
      }
      if (!fallback.has_value() &&
          entry.name.compare(wanted, Qt::CaseInsensitive) == 0) {
        fallback = entry;
      }
    }
    if (fallback.has_value()) {
      return fillResolved(*fallback, normalized, resolved);
    }
    return STATUS_OBJECT_NAME_NOT_FOUND;
  }

  NTSTATUS fillResolved(const sak::PartitionApfsFileEntry &entry,
                        const QString &path, ResolvedEntry *resolved) const {
    if (resolved) {
      *resolved = ResolvedEntry{.path = normalizeApfsPath(path),
                                .name = entry.name,
                                .directory = entry.directory,
                                .regularFile = entry.regular_file,
                                .symlink = entry.symlink,
                                .objectId = entry.object_id,
                                .sizeBytes = entry.size_bytes,
                                .hardLinks = entry.hard_link_count,
                                .createdTimeNs = entry.created_time_ns,
                                .modifiedTimeNs = entry.modified_time_ns,
                                .changedTimeNs = entry.changed_time_ns,
                                .accessedTimeNs = entry.accessed_time_ns,
                                .writeGenerationCounter =
                                    entry.write_generation_counter,
                                .bsdFlags = entry.bsd_flags,
                                .ownerId = entry.owner_id,
                                .groupId = entry.group_id,
                                .inodeMode = entry.inode_mode};
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
    options.evidence_id =
        rawTarget_ ? QStringLiteral("apfs_for_windows.raw_mount_rw")
                   : QStringLiteral("apfs_for_windows.image_mount_rw");
    return options;
  }

  QString mutationTempPathNoLock(const QString &operation) const {
    const QFileInfo targetInfo(target_);
    const QString dir = targetInfo.absoluteDir().absolutePath();
    const QString name = QStringLiteral(".%1-%2-%3-%4.apfs")
                             .arg(targetInfo.fileName(), operation)
                             .arg(QCoreApplication::applicationPid())
                             .arg(QUuid::createUuid().toString(QUuid::Id128));
    return QDir(dir).filePath(name);
  }

  void recoverAndCleanImageMutationTemps() const {
    const QFileInfo targetInfo(target_);
    QDir directory(targetInfo.absoluteDir());
    const QString prefix = QStringLiteral(".%1-").arg(targetInfo.fileName());
    const QRegularExpression ownedTemp(
        QStringLiteral("^\\.%1-[a-z]+-(\\d+)-[0-9a-f]+\\.apfs$")
            .arg(QRegularExpression::escape(targetInfo.fileName())),
        QRegularExpression::CaseInsensitiveOption);
    QFileInfoList candidates = directory.entryInfoList(
        {prefix + QStringLiteral("*.apfs")}, QDir::Files, QDir::Time);

    if (!targetInfo.exists()) {
      for (const QFileInfo &candidate : candidates) {
        const QRegularExpressionMatch match =
            ownedTemp.match(candidate.fileName());
        if (!match.hasMatch() ||
            !candidate.fileName().contains(QStringLiteral("-backup-"),
                                           Qt::CaseInsensitive) ||
            processIsAlive(match.captured(1).toLongLong())) {
          continue;
        }
        if (QFile::rename(candidate.absoluteFilePath(), target_)) {
          break;
        }
      }
    }

    if (!QFileInfo::exists(target_)) {
      return;
    }
    candidates = directory.entryInfoList({prefix + QStringLiteral("*.apfs")},
                                         QDir::Files, QDir::Time);
    for (const QFileInfo &candidate : candidates) {
      const QRegularExpressionMatch match =
          ownedTemp.match(candidate.fileName());
      if (match.hasMatch() && !processIsAlive(match.captured(1).toLongLong())) {
        QFile::remove(candidate.absoluteFilePath());
      }
    }
  }

  // Every reader use goes through this: a failed post-commit reload leaves
  // readerSession_ null, and the next callback retries instead of crashing.
  NTSTATUS ensureReaderNoLock() {
    if (readerSession_) {
      return STATUS_SUCCESS;
    }
    QString reloadError;
    const NTSTATUS status = reloadTargetNoLock(&reloadError);
    if (!NT_SUCCESS(status) || !readerSession_) {
      trace(QStringLiteral("reader unavailable: %1").arg(reloadError));
      return STATUS_DEVICE_NOT_READY;
    }
    return STATUS_SUCCESS;
  }

  void reloadAfterReplaceFailureNoLock() {
    QString reloadError;
    const NTSTATUS status = reloadTargetNoLock(&reloadError);
    if (!NT_SUCCESS(status)) {
      trace(QStringLiteral("reload after replace failure failed: %1; reader "
                           "stays offline until the next successful reload")
                .arg(reloadError));
    }
  }

  NTSTATUS reloadTargetNoLock(QString *error = nullptr) {
    QString openError;
    auto newDevice = sak::openFileOrRawDeviceReadOnly(target_, &openError);
    if (!newDevice) {
      if (error) {
        *error = QStringLiteral("reopen failed: %1").arg(openError);
      }
      return STATUS_ACCESS_DENIED;
    }

    QString detectError;
    const uint64_t size = newDevice->size() > 0
                              ? static_cast<uint64_t>(newDevice->size())
                              : kFallbackProbeBytes;
    const auto detection = sak::PartitionFileSystemDetector::detectFromDevice(
        newDevice.get(), 0, size, &detectError);
    if (!detection.has_value() ||
        detection->file_system.compare(QStringLiteral("APFS"),
                                       Qt::CaseInsensitive) != 0) {
      if (error) {
        *error = detectError.isEmpty() ? QStringLiteral("target is not APFS")
                                       : detectError;
      }
      return STATUS_UNRECOGNIZED_VOLUME;
    }

    auto newReaderSession =
        std::make_unique<sak::PartitionApfsFileSystemReaderSession>(
            newDevice.get());
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
    targetContainerBytes_ =
        detection->total_bytes != 0 ? detection->total_bytes : size;
    QMutexLocker volumeLocker(&volumeInfoMutex_);
    totalBytes_ = detection->total_bytes;
    freeBytes_ = detection->free_bytes;
    if (!root.volume_name.trimmed().isEmpty()) {
      volumeLabel_ = root.volume_name.trimmed().left(32);
    }
    return STATUS_SUCCESS;
  }

  bool replaceTargetWithTempNoLock(const QString &tempPath, QString *error) {
    const QString backupPath = mutationTempPathNoLock(QStringLiteral("backup"));
    QFile::remove(backupPath);
    const std::wstring target = target_.toStdWString();
    const std::wstring replacement = tempPath.toStdWString();
    const std::wstring backup = backupPath.toStdWString();
    if (!ReplaceFileW(target.c_str(), replacement.c_str(), backup.c_str(),
                      REPLACEFILE_WRITE_THROUGH, nullptr, nullptr)) {
      const DWORD replaceError = GetLastError();
      if (error) {
        *error = QStringLiteral(
                     "atomic APFS image replacement failed: Win32 error %1")
                     .arg(replaceError);
      }
      QFile::remove(tempPath);
      return false;
    }
    QFile::remove(backupPath);
    return true;
  }

  void maybeExitForTestFault(QLatin1StringView phase, const QString &path,
                             uint64_t mutationBytes) const {
    if (mutationBytes == 0 || rawTarget_ || testFaultExitPhase_ != phase ||
        normalizeApfsPath(path) != testFaultPath_) {
      return;
    }
    trace(QStringLiteral("TestFaultExit phase=%1 path=%2 bytes=%3 code=%4")
              .arg(phase, testFaultPath_)
              .arg(mutationBytes)
              .arg(kTestFaultExitCode));
    ExitProcess(kTestFaultExitCode);
  }

  NTSTATUS resultStatus(
      const QString &operation,
      const sak::PartitionApfsImageCheckpointCommitResult &result) const {
    if (result.ok) {
      return STATUS_SUCCESS;
    }
    trace(QStringLiteral("%1 failed: %2")
              .arg(operation, result.blockers.join(QStringLiteral("; "))));
    const QString blockers = result.blockers.join(QLatin1Char(' '));
    // The current write engine must re-collect the whole volume per commit and
    // cannot when any directory holds 1,000+ entries or nests deeper than 16
    // levels. Report that as a write-protected volume, not as a permission
    // problem on the file the user touched.
    if (blockers.contains(QStringLiteral("too many entries to preserve safely"),
                          Qt::CaseInsensitive) ||
        blockers.contains(QStringLiteral("is nested deeper than"),
                          Qt::CaseInsensitive)) {
      return STATUS_MEDIA_WRITE_PROTECTED;
    }
    if (blockers.contains(QStringLiteral("already exists"),
                          Qt::CaseInsensitive)) {
      return STATUS_OBJECT_NAME_COLLISION;
    }
    if (blockers.contains(QStringLiteral("not found"), Qt::CaseInsensitive)) {
      return STATUS_OBJECT_NAME_NOT_FOUND;
    }
    if (blockers.contains(QStringLiteral("exceeds"), Qt::CaseInsensitive)) {
      return STATUS_FILE_TOO_LARGE;
    }
    if (blockers.contains(QStringLiteral("not empty"), Qt::CaseInsensitive)) {
      return STATUS_DIRECTORY_NOT_EMPTY;
    }
    return STATUS_ACCESS_DENIED;
  }

  NTSTATUS commitFileWrite(const QString &path, const QByteArray &data,
                           ResolvedEntry *updated) {
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
        maybeExitForTestFault(kTestFaultBeforeImageReplace, normalized,
                              static_cast<uint64_t>(data.size()));
        QString replaceError;
        if (!replaceTargetWithTempNoLock(tempPath, &replaceError)) {
          trace(QStringLiteral("write replace failed: %1").arg(replaceError));
          reloadAfterReplaceFailureNoLock();
          return STATUS_ACCESS_DENIED;
        }
        maybeExitForTestFault(kTestFaultAfterImageReplace, normalized,
                              static_cast<uint64_t>(data.size()));
      } else {
        QFile::remove(tempPath);
      }
    }

    const NTSTATUS mutationStatus =
        resultStatus(QStringLiteral("file-write"), result);
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

  NTSTATUS commitFileWriteFromPath(const QString &path, const QString &dataPath,
                                   uint64_t dataSize, ResolvedEntry *updated) {
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

    const NTSTATUS mutationStatus =
        resultStatus(QStringLiteral("file-write-stream"), result);
    QString reloadError;
    const NTSTATUS reloadStatus = reloadTargetNoLock(&reloadError);
    if (!NT_SUCCESS(reloadStatus)) {
      trace(QStringLiteral("reload after stream write failed: %1")
                .arg(reloadError));
      return reloadStatus;
    }
    if (!NT_SUCCESS(mutationStatus)) {
      return mutationStatus;
    }
    return resolvePathNoLock(normalized, updated);
  }

  NTSTATUS commitFileDelete(const QString &path) {
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
          reloadAfterReplaceFailureNoLock();
          return STATUS_ACCESS_DENIED;
        }
      } else {
        QFile::remove(tempPath);
      }
    }

    const NTSTATUS mutationStatus =
        resultStatus(QStringLiteral("file-delete"), result);
    QString reloadError;
    const NTSTATUS reloadStatus = reloadTargetNoLock(&reloadError);
    if (!NT_SUCCESS(reloadStatus)) {
      trace(QStringLiteral("reload after delete failed: %1").arg(reloadError));
      return reloadStatus;
    }
    return mutationStatus;
  }

  NTSTATUS commitDirectoryCreate(const QString &path, ResolvedEntry *updated) {
    const QString normalized = normalizeApfsPath(path);
    QString parentDirectoryPath;
    QString directoryName;
    if (!splitDirectoryCreatePath(normalized, &parentDirectoryPath,
                                  &directoryName)) {
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
          trace(QStringLiteral("directory create replace failed: %1")
                    .arg(replaceError));
          reloadAfterReplaceFailureNoLock();
          return STATUS_ACCESS_DENIED;
        }
      } else {
        QFile::remove(tempPath);
      }
    }

    const NTSTATUS mutationStatus =
        resultStatus(QStringLiteral("directory-create"), result);
    QString reloadError;
    const NTSTATUS reloadStatus = reloadTargetNoLock(&reloadError);
    if (!NT_SUCCESS(reloadStatus)) {
      trace(QStringLiteral("reload after directory create failed: %1")
                .arg(reloadError));
      return reloadStatus;
    }
    if (!NT_SUCCESS(mutationStatus)) {
      return mutationStatus;
    }
    return resolvePathNoLock(normalized, updated);
  }

  NTSTATUS commitDirectoryDelete(const QString &path) {
    const QString normalized = normalizeApfsPath(path);
    QString parentDirectoryPath;
    QString directoryName;
    if (!splitDirectoryCreatePath(normalized, &parentDirectoryPath,
                                  &directoryName)) {
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
          trace(QStringLiteral("directory delete replace failed: %1")
                    .arg(replaceError));
          reloadAfterReplaceFailureNoLock();
          return STATUS_ACCESS_DENIED;
        }
      } else {
        QFile::remove(tempPath);
      }
    }

    const NTSTATUS mutationStatus =
        resultStatus(QStringLiteral("directory-delete"), result);
    QString reloadError;
    const NTSTATUS reloadStatus = reloadTargetNoLock(&reloadError);
    if (!NT_SUCCESS(reloadStatus)) {
      trace(QStringLiteral("reload after directory delete failed: %1")
                .arg(reloadError));
      return reloadStatus;
    }
    return mutationStatus;
  }

  NTSTATUS commitDirectoryRename(const QString &oldPath, const QString &newPath,
                                 ResolvedEntry *updated) {
    const QString normalizedOld = normalizeApfsPath(oldPath);
    const QString normalizedNew = normalizeApfsPath(newPath);
    QString oldParentDirectoryPath;
    QString oldDirectoryName;
    QString newParentDirectoryPath;
    QString newDirectoryName;
    if (!splitDirectoryCreatePath(normalizedOld, &oldParentDirectoryPath,
                                  &oldDirectoryName) ||
        !splitDirectoryCreatePath(normalizedNew, &newParentDirectoryPath,
                                  &newDirectoryName)) {
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
          trace(QStringLiteral("directory rename replace failed: %1")
                    .arg(replaceError));
          reloadAfterReplaceFailureNoLock();
          return STATUS_ACCESS_DENIED;
        }
      } else {
        QFile::remove(tempPath);
      }
    }

    const NTSTATUS mutationStatus =
        resultStatus(QStringLiteral("directory-rename"), result);
    QString reloadError;
    const NTSTATUS reloadStatus = reloadTargetNoLock(&reloadError);
    if (!NT_SUCCESS(reloadStatus)) {
      trace(QStringLiteral("reload after directory rename failed: %1")
                .arg(reloadError));
      return reloadStatus;
    }
    if (!NT_SUCCESS(mutationStatus)) {
      return mutationStatus;
    }
    return resolvePathNoLock(normalizedNew, updated);
  }

  NTSTATUS commitFileRename(const QString &oldPath, const QString &newPath,
                            ResolvedEntry *updated) {
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
          reloadAfterReplaceFailureNoLock();
          return STATUS_ACCESS_DENIED;
        }
      } else {
        QFile::remove(tempPath);
      }
    }

    const NTSTATUS mutationStatus =
        resultStatus(QStringLiteral("file-rename"), result);
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

#if defined(FSP_FILE_SYSTEM_INTERFACE_HAS_CREATE_HARD_LINK)
  NTSTATUS commitFileHardLink(const QString &sourcePath,
                              const QString &linkPath,
                              ResolvedEntry *updated) {
    const QString normalizedSource = normalizeApfsPath(sourcePath);
    const QString normalizedLink = normalizeApfsPath(linkPath);
    QString sourceParentPath;
    QString sourceFileName;
    QString linkParentPath;
    QString linkFileName;
    if (!splitMutableFilePath(normalizedSource, &sourceParentPath,
                              &sourceFileName) ||
        !splitMutableFilePath(normalizedLink, &linkParentPath, &linkFileName)) {
      return STATUS_NOT_SUPPORTED;
    }

    QMutexLocker locker(&ioMutex_);
    readerSession_.reset();
    device_.reset();
    QString tempPath;
    sak::PartitionApfsImageCheckpointCommitResult result;
    if (rawTarget_) {
      result = sak::PartitionApfsWriter::commitRawFileHardlink(
          {.target_path = target_,
           .target_container_bytes = targetContainerBytes_,
           .source_file_name = sourceFileName,
           .link_file_name = linkFileName,
           .source_parent_directory_path = sourceParentPath,
           .link_parent_directory_path = linkParentPath,
           .target_mutation_confirmed = allowRawWrites_,
           .allow_raw_device_target = allowRawWrites_,
           .options = writerOptions()});
    } else {
      tempPath = mutationTempPathNoLock(QStringLiteral("hardlink"));
      result = sak::PartitionApfsWriter::commitImageOnlyFileHardlink(
          {.source_image_path = target_,
           .written_image_path = tempPath,
           .source_file_name = sourceFileName,
           .link_file_name = linkFileName,
           .source_parent_directory_path = sourceParentPath,
           .link_parent_directory_path = linkParentPath,
           .options = writerOptions()});
      if (result.ok) {
        QString replaceError;
        if (!replaceTargetWithTempNoLock(tempPath, &replaceError)) {
          trace(QStringLiteral("hard-link replace failed: %1")
                    .arg(replaceError));
          reloadAfterReplaceFailureNoLock();
          return STATUS_ACCESS_DENIED;
        }
      } else {
        QFile::remove(tempPath);
      }
    }

    const NTSTATUS mutationStatus =
        resultStatus(QStringLiteral("file-hardlink"), result);
    QString reloadError;
    const NTSTATUS reloadStatus = reloadTargetNoLock(&reloadError);
    if (!NT_SUCCESS(reloadStatus)) {
      trace(QStringLiteral("reload after hard link failed: %1")
                .arg(reloadError));
      return reloadStatus;
    }
    if (!NT_SUCCESS(mutationStatus)) {
      return mutationStatus;
    }
    return resolvePathNoLock(normalizedLink, updated);
  }

  // Called with `self` locked. Other nodes are never locked here (that could
  // deadlock against a concurrent link on another alias); they pick the new
  // count up in NodeGuard on their next callback.
  void updateOpenContextHardLinks(const FileNode *self, uint64_t objectId,
                                  uint32_t hardLinks) {
    QMutexLocker locker(&contextMutex_);
    for (const auto &node : std::as_const(nodes_)) {
      if (node && node.get() != self && node->publishedObjectId == objectId) {
        node->pendingHardLinks = hardLinks;
      }
    }
  }
#endif

  NTSTATUS
  commitInodeMetadata(const QString &path, bool directory,
                      const sak::PartitionApfsInodeMetadataUpdate &metadata,
                      ResolvedEntry *updated) {
    const QString normalized = normalizeApfsPath(path);
    QString parentDirectoryPath;
    QString targetName;
    if (normalized == QStringLiteral("/")) {
      if (!directory) {
        return STATUS_NOT_SUPPORTED;
      }
      targetName = QStringLiteral("/");
    } else if (!splitDirectoryCreatePath(normalized, &parentDirectoryPath,
                                         &targetName)) {
      return STATUS_NOT_SUPPORTED;
    }

    QMutexLocker locker(&ioMutex_);
    readerSession_.reset();
    device_.reset();
    QString tempPath;
    sak::PartitionApfsImageCheckpointCommitResult result;
    if (rawTarget_) {
      result = sak::PartitionApfsWriter::commitRawInodeMetadata(
          {.target_path = target_,
           .target_container_bytes = targetContainerBytes_,
           .target_name = targetName,
           .parent_directory_path = parentDirectoryPath,
           .target_is_directory = directory,
           .metadata = metadata,
           .target_mutation_confirmed = allowRawWrites_,
           .allow_raw_device_target = allowRawWrites_,
           .options = writerOptions()});
    } else {
      tempPath = mutationTempPathNoLock(QStringLiteral("metadata"));
      result = sak::PartitionApfsWriter::commitImageOnlyInodeMetadata(
          {.source_image_path = target_,
           .written_image_path = tempPath,
           .target_name = targetName,
           .parent_directory_path = parentDirectoryPath,
           .target_is_directory = directory,
           .metadata = metadata,
           .options = writerOptions()});
      if (result.ok) {
        QString replaceError;
        if (!replaceTargetWithTempNoLock(tempPath, &replaceError)) {
          trace(
              QStringLiteral("metadata replace failed: %1").arg(replaceError));
          reloadAfterReplaceFailureNoLock();
          return STATUS_ACCESS_DENIED;
        }
      } else {
        QFile::remove(tempPath);
      }
    }

    const NTSTATUS mutationStatus =
        resultStatus(QStringLiteral("inode-metadata"), result);
    QString reloadError;
    const NTSTATUS reloadStatus = reloadTargetNoLock(&reloadError);
    if (!NT_SUCCESS(reloadStatus)) {
      trace(QStringLiteral("reload after metadata update failed: %1")
                .arg(reloadError));
      return reloadStatus;
    }
    if (!NT_SUCCESS(mutationStatus)) {
      return mutationStatus;
    }
    return resolvePathNoLock(normalized, updated);
  }

  NTSTATUS setBasicInfo(FileNode *node, UINT32 fileAttributes,
                        UINT64 creationTime, UINT64 lastAccessTime,
                        UINT64 lastWriteTime, UINT64 changeTime,
                        FSP_FSCTL_FILE_INFO *fileInfo) {
    if (readOnly_) {
      return STATUS_MEDIA_WRITE_PROTECTED;
    }
    if (!node) {
      return STATUS_INVALID_PARAMETER;
    }
    if (node->stagedWriteDirty) {
      const NTSTATUS flushStatus = flushFile(node, nullptr);
      if (!NT_SUCCESS(flushStatus)) {
        return flushStatus;
      }
    }
    sak::PartitionApfsInodeMetadataUpdate update;
    if (fileAttributes != INVALID_FILE_ATTRIBUTES) {
      uint32_t bsdFlags = node->entry.bsdFlags;
      const auto assignFlag = [&bsdFlags, fileAttributes](uint32_t windowsFlag,
                                                          uint32_t bsdFlag) {
        if ((fileAttributes & windowsFlag) != 0) {
          bsdFlags |= bsdFlag;
        } else {
          bsdFlags &= ~bsdFlag;
        }
      };
      assignFlag(FILE_ATTRIBUTE_READONLY, kBsdFlagUserImmutable);
      assignFlag(FILE_ATTRIBUTE_HIDDEN, kBsdFlagUserHidden);
      assignFlag(FILE_ATTRIBUTE_ARCHIVE, kBsdFlagUserArchive);
      update.update_bsd_flags = bsdFlags != node->entry.bsdFlags;
      update.bsd_flags = bsdFlags;
    }
    if (creationTime != 0) {
      update.update_created_time = true;
      update.created_time_ns = unixNsFromFileTime(creationTime);
    }
    if (lastAccessTime != 0) {
      update.update_accessed_time = true;
      update.accessed_time_ns = unixNsFromFileTime(lastAccessTime);
    }
    if (lastWriteTime != 0) {
      update.update_modified_time = true;
      update.modified_time_ns = unixNsFromFileTime(lastWriteTime);
    }
    if (changeTime != 0) {
      update.update_changed_time = true;
      update.changed_time_ns = unixNsFromFileTime(changeTime);
    }
    const bool changed =
        update.update_bsd_flags || update.update_created_time ||
        update.update_accessed_time || update.update_modified_time ||
        update.update_changed_time;
    if (changed) {
      const NTSTATUS status =
          commitInodeMetadata(node->entry.path, node->entry.directory,
                              update, &node->entry);
      if (!NT_SUCCESS(status)) {
        return status;
      }
    }
    fillFileInfo(node->entry, fileInfo);
    return STATUS_SUCCESS;
  }

  NTSTATUS setSecurity(FileNode *node,
                       SECURITY_INFORMATION securityInformation,
                       PSECURITY_DESCRIPTOR modificationDescriptor) {
    if (readOnly_) {
      return STATUS_MEDIA_WRITE_PROTECTED;
    }
    if (!node || !modificationDescriptor) {
      return STATUS_INVALID_PARAMETER;
    }
    const bool setOwner =
        (securityInformation & OWNER_SECURITY_INFORMATION) != 0;
    const bool setGroup =
        (securityInformation & GROUP_SECURITY_INFORMATION) != 0;
    const bool setMode = (securityInformation & DACL_SECURITY_INFORMATION) != 0;
    if (!setOwner && !setGroup && !setMode) {
      // SACL/label-only changes have no APFS representation.
      return STATUS_SUCCESS;
    }
    // Merge against this inode's own POSIX-derived descriptor, so mode bits
    // are computed relative to the inode's real owner and group. Fall back to
    // the volume descriptor only if the mapping is unavailable.
    PSECURITY_DESCRIPTOR inodeDescriptor = nullptr;
    const NTSTATUS mapStatus = FspPosixMapPermissionsToSecurityDescriptor(
        node->entry.ownerId, node->entry.groupId,
        static_cast<UINT32>(node->entry.inodeMode & 07777U), &inodeDescriptor);
    PSECURITY_DESCRIPTOR base =
        NT_SUCCESS(mapStatus) && inodeDescriptor ? inodeDescriptor
                                                 : securityDescriptor_;
    PSECURITY_DESCRIPTOR merged = nullptr;
    NTSTATUS status = FspSetSecurityDescriptor(base, securityInformation,
                                               modificationDescriptor, &merged);
    if (inodeDescriptor) {
      FspDeleteSecurityDescriptor(
          inodeDescriptor,
          (NTSTATUS(*)())FspPosixMapPermissionsToSecurityDescriptor);
    }
    if (!NT_SUCCESS(status)) {
      return status;
    }
    uint32_t ownerId = 0;
    uint32_t groupId = 0;
    uint32_t mode = 0;
    status = FspPosixMapSecurityDescriptorToPermissions(merged, &ownerId,
                                                        &groupId, &mode);
    FspDeleteSecurityDescriptor(merged,
                                (NTSTATUS(*)())FspSetSecurityDescriptor);
    if (!NT_SUCCESS(status)) {
      return status;
    }
    sak::PartitionApfsInodeMetadataUpdate update;
    update.update_inode_mode = setMode;
    update.inode_mode = static_cast<uint16_t>(mode);
    update.update_owner_id = setOwner;
    update.owner_id = ownerId;
    update.update_group_id = setGroup;
    update.group_id = groupId;
    update.update_changed_time = true;
    update.changed_time_ns = unixNsFromFileTime(currentFileTime());
    if (node->stagedWriteDirty) {
      const NTSTATUS flushStatus = flushFile(node, nullptr);
      if (!NT_SUCCESS(flushStatus)) {
        return flushStatus;
      }
    }
    return commitInodeMetadata(node->entry.path, node->entry.directory,
                               update, &node->entry);
  }

  NTSTATUS getEa(FileNode *node, PFILE_FULL_EA_INFORMATION ea,
                 ULONG eaLength, PULONG bytesTransferred) {
    if (!node || !bytesTransferred) {
      return STATUS_INVALID_PARAMETER;
    }
    *bytesTransferred = 0;
    struct WindowsEaRecord {
      QByteArray name;
      QByteArray value;
    };
    QVector<WindowsEaRecord> attributes;
    QVector<QPair<QString, QByteArray>> apfsAttributes;
    {
      QMutexLocker locker(&ioMutex_);
      const NTSTATUS readerStatus = ensureReaderNoLock();
      if (!NT_SUCCESS(readerStatus)) {
        return readerStatus;
      }
      const auto read = readerSession_->readXattrs(node->entry.path);
      if (!read.ok || !read.blockers.isEmpty()) {
        trace(QStringLiteral("read EAs failed: %1")
                  .arg(read.blockers.join(QStringLiteral("; "))));
        return STATUS_ACCESS_DENIED;
      }
      for (const auto &attribute : read.xattrs) {
        const QByteArray apfsName = attribute.first.toUtf8();
        if (apfsName.isEmpty() || apfsName.size() > kWindowsEaMaxNameBytes ||
            apfsName.contains('\0') ||
            QString::fromUtf8(apfsName).toUtf8() != apfsName ||
            isContentCriticalXattr(apfsName)) {
          continue;
        }
        apfsAttributes.append(attribute);
      }
    }
    QVector<QString> apfsNames;
    apfsNames.reserve(apfsAttributes.size());
    for (const auto &attribute : std::as_const(apfsAttributes)) {
      apfsNames.append(attribute.first);
    }
    const QSet<QString> collisionKeys = windowsEaCollisionKeys(apfsNames);
    for (const auto &attribute : std::as_const(apfsAttributes)) {
        QByteArray wireName;
        QByteArray wireValue = attribute.second;
        if (!isDirectWindowsEaName(attribute.first, &wireName) ||
            collisionKeys.contains(windowsEaCaseKey(attribute.first))) {
          wireName = encodeWindowsEaAlias(attribute.first);
          wireValue.prepend(kWindowsEaAliasValueVersion);
        }
        if (wireName.size() <= std::numeric_limits<UCHAR>::max() &&
            wireValue.size() <= std::numeric_limits<USHORT>::max()) {
          attributes.append({wireName, wireValue});
        }
      }
    std::sort(attributes.begin(), attributes.end(),
              [](const auto &left, const auto &right) {
                return left.name.toUpper() < right.name.toUpper();
              });
    for (const auto &attribute : attributes) {
      const ULONG singleLength = static_cast<ULONG>(
          FIELD_OFFSET(FILE_FULL_EA_INFORMATION, EaName) +
          attribute.name.size() + 1 + attribute.value.size());
      QByteArray storage(static_cast<qsizetype>(singleLength), '\0');
      auto *single =
          reinterpret_cast<PFILE_FULL_EA_INFORMATION>(storage.data());
      single->Flags = 0;
      single->EaNameLength = static_cast<UCHAR>(attribute.name.size());
      single->EaValueLength = static_cast<USHORT>(attribute.value.size());
      std::memcpy(single->EaName, attribute.name.constData(),
                  static_cast<size_t>(attribute.name.size()));
      std::memcpy(single->EaName + attribute.name.size() + 1,
                  attribute.value.constData(),
                  static_cast<size_t>(attribute.value.size()));
      if (!FspFileSystemAddEa(single, ea, eaLength, bytesTransferred)) {
        return STATUS_SUCCESS;
      }
    }
    FspFileSystemAddEa(nullptr, ea, eaLength, bytesTransferred);
    return STATUS_SUCCESS;
  }

  NTSTATUS setEa(FSP_FILE_SYSTEM *fileSystem, FileNode *node,
                 PFILE_FULL_EA_INFORMATION ea, ULONG eaLength,
                 FSP_FSCTL_FILE_INFO *fileInfo) {
    if (readOnly_) {
      return STATUS_MEDIA_WRITE_PROTECTED;
    }
    if (!node || !fileInfo || (eaLength != 0 && !ea)) {
      return STATUS_INVALID_PARAMETER;
    }
    EaMutationCollectContext collected;
    const NTSTATUS parseStatus = FspFileSystemEnumerateEa(
        fileSystem, collectEaMutation, &collected, ea, eaLength);
    if (!NT_SUCCESS(parseStatus)) {
      return parseStatus;
    }
    if (!collected.mutations.isEmpty()) {
      if (node->stagedWriteDirty) {
        const NTSTATUS flushStatus = flushFile(node, nullptr);
        if (!NT_SUCCESS(flushStatus)) {
          return flushStatus;
        }
      }
      QMutexLocker eaMutationLocker(&eaMutationMutex_);
      QVector<QString> existingNames;
      {
        QMutexLocker ioLocker(&ioMutex_);
        const NTSTATUS readerStatus = ensureReaderNoLock();
        if (!NT_SUCCESS(readerStatus)) {
          return readerStatus;
        }
        const auto read = readerSession_->readXattrs(node->entry.path);
        if (!read.ok || !read.blockers.isEmpty()) {
          trace(QStringLiteral("read EAs before mutation failed: %1")
                    .arg(read.blockers.join(QStringLiteral("; "))));
          return STATUS_ACCESS_DENIED;
        }
        existingNames.reserve(read.xattrs.size());
        for (const auto &xattr : read.xattrs) {
          existingNames.append(xattr.first);
        }
      }
      if (!validateWindowsEaMutations(existingNames,
                                      collected.policyMutations)) {
        return STATUS_OBJECT_NAME_COLLISION;
      }
      sak::PartitionApfsInodeMetadataUpdate update;
      update.update_changed_time = true;
      update.changed_time_ns = unixNsFromFileTime(currentFileTime());
      update.xattr_mutations = std::move(collected.mutations);
      const NTSTATUS status =
          commitInodeMetadata(node->entry.path, node->entry.directory,
                              update, &node->entry);
      if (!NT_SUCCESS(status)) {
        return status;
      }
    }
    fillFileInfo(node->entry, fileInfo);
    return STATUS_SUCCESS;
  }

  NTSTATUS readSymbolicLinkTarget(const ResolvedEntry &entry, QString *target) {
    if (!entry.symlink) {
      return STATUS_NOT_A_REPARSE_POINT;
    }
    QMutexLocker locker(&ioMutex_);
    const NTSTATUS readerStatus = ensureReaderNoLock();
    if (!NT_SUCCESS(readerStatus)) {
      return readerStatus;
    }
    const auto read = readerSession_->readXattrs(entry.path);
    if (!read.ok || !read.blockers.isEmpty()) {
      trace(QStringLiteral("read symbolic-link target failed: %1")
                .arg(read.blockers.join(QStringLiteral("; "))));
      return STATUS_ACCESS_DENIED;
    }
    for (const auto &xattr : read.xattrs) {
      if (xattr.first != QStringLiteral("com.apple.fs.symlink")) {
        continue;
      }
      QByteArray value = xattr.second;
      while (value.endsWith('\0')) {
        value.chop(1);
      }
      *target = QString::fromUtf8(value);
      return target->isEmpty() ? STATUS_IO_REPARSE_DATA_INVALID
                               : STATUS_SUCCESS;
    }
    return STATUS_IO_REPARSE_DATA_INVALID;
  }

  NTSTATUS buildSymbolicLinkReparseData(const ResolvedEntry &entry,
                                        QByteArray *bytes) {
    QString target;
    NTSTATUS status = readSymbolicLinkTarget(entry, &target);
    if (!NT_SUCCESS(status)) {
      return status;
    }
    const bool relative = !target.startsWith(QLatin1Char('/'));
    QString printName;
    QString substituteName;
    if (relative) {
      printName = QDir::toNativeSeparators(target);
      substituteName = printName;
    } else {
      if (mountPoint_.isEmpty()) {
        return STATUS_IO_REPARSE_TAG_NOT_HANDLED;
      }
      QString mount = mountPoint_;
      while (mount.endsWith(QLatin1Char('\\'))) {
        mount.chop(1);
      }
      printName = mount + QDir::toNativeSeparators(target);
      substituteName = QStringLiteral("\\??\\") + printName;
    }
    const std::wstring substitute = wide(substituteName);
    const std::wstring print = wide(printName);
    const size_t pathBytes =
        (substitute.size() + print.size()) * sizeof(wchar_t);
    const size_t fixedBytes =
        FIELD_OFFSET(REPARSE_DATA_BUFFER, SymbolicLinkReparseBuffer.PathBuffer);
    if (pathBytes > std::numeric_limits<USHORT>::max() ||
        fixedBytes + pathBytes > std::numeric_limits<USHORT>::max()) {
      return STATUS_NAME_TOO_LONG;
    }
    bytes->resize(static_cast<qsizetype>(fixedBytes + pathBytes));
    bytes->fill('\0');
    auto *data = reinterpret_cast<PREPARSE_DATA_BUFFER>(bytes->data());
    data->ReparseTag = IO_REPARSE_TAG_SYMLINK;
    data->ReparseDataLength =
        static_cast<USHORT>(bytes->size() - REPARSE_DATA_BUFFER_HEADER_SIZE);
    data->SymbolicLinkReparseBuffer.SubstituteNameOffset = 0;
    data->SymbolicLinkReparseBuffer.SubstituteNameLength =
        static_cast<USHORT>(substitute.size() * sizeof(wchar_t));
    data->SymbolicLinkReparseBuffer.PrintNameOffset =
        data->SymbolicLinkReparseBuffer.SubstituteNameLength;
    data->SymbolicLinkReparseBuffer.PrintNameLength =
        static_cast<USHORT>(print.size() * sizeof(wchar_t));
    data->SymbolicLinkReparseBuffer.Flags =
        relative ? SYMLINK_FLAG_RELATIVE : 0;
    wchar_t *pathBuffer = data->SymbolicLinkReparseBuffer.PathBuffer;
    std::memcpy(pathBuffer, substitute.data(),
                data->SymbolicLinkReparseBuffer.SubstituteNameLength);
    std::memcpy(reinterpret_cast<char *>(pathBuffer) +
                    data->SymbolicLinkReparseBuffer.PrintNameOffset,
                print.data(), data->SymbolicLinkReparseBuffer.PrintNameLength);
    return STATUS_SUCCESS;
  }

  NTSTATUS getReparsePointByName(const QString &path, PVOID buffer,
                                 PSIZE_T size) {
    ResolvedEntry entry;
    const NTSTATUS resolveStatus = resolvePath(path, &entry);
    if (!NT_SUCCESS(resolveStatus)) {
      return resolveStatus;
    }
    if (!entry.symlink) {
      return STATUS_NOT_A_REPARSE_POINT;
    }
    if (!buffer) {
      return STATUS_SUCCESS;
    }
    QByteArray data;
    const NTSTATUS status = buildSymbolicLinkReparseData(entry, &data);
    if (!NT_SUCCESS(status)) {
      return status;
    }
    if (!size || data.size() > static_cast<qsizetype>(*size)) {
      return STATUS_BUFFER_TOO_SMALL;
    }
    *size = static_cast<SIZE_T>(data.size());
    std::memcpy(buffer, data.constData(), data.size());
    return STATUS_SUCCESS;
  }

  NTSTATUS getReparsePoint(const FileNode *node, PVOID buffer,
                           PSIZE_T size) {
    if (!node) {
      return STATUS_INVALID_PARAMETER;
    }
    QByteArray data;
    const NTSTATUS status = buildSymbolicLinkReparseData(node->entry, &data);
    if (!NT_SUCCESS(status)) {
      return status;
    }
    if (!size || data.size() > static_cast<qsizetype>(*size)) {
      return STATUS_BUFFER_TOO_SMALL;
    }
    *size = static_cast<SIZE_T>(data.size());
    std::memcpy(buffer, data.constData(), data.size());
    return STATUS_SUCCESS;
  }

  NTSTATUS parseSymbolicLinkReparseData(PVOID buffer, SIZE_T size,
                                        QString *target) const {
    const size_t fixedBytes =
        FIELD_OFFSET(REPARSE_DATA_BUFFER, SymbolicLinkReparseBuffer.PathBuffer);
    if (!buffer || size < fixedBytes) {
      return STATUS_IO_REPARSE_DATA_INVALID;
    }
    const auto *data = reinterpret_cast<PREPARSE_DATA_BUFFER>(buffer);
    if (data->ReparseTag != IO_REPARSE_TAG_SYMLINK ||
        static_cast<size_t>(data->ReparseDataLength) +
                REPARSE_DATA_BUFFER_HEADER_SIZE >
            size) {
      return STATUS_IO_REPARSE_TAG_NOT_HANDLED;
    }
    const size_t available = size - fixedBytes;
    const USHORT printOffset = data->SymbolicLinkReparseBuffer.PrintNameOffset;
    const USHORT printLength = data->SymbolicLinkReparseBuffer.PrintNameLength;
    const USHORT substituteOffset =
        data->SymbolicLinkReparseBuffer.SubstituteNameOffset;
    const USHORT substituteLength =
        data->SymbolicLinkReparseBuffer.SubstituteNameLength;
    const bool usePrint = printLength != 0;
    const size_t offset = usePrint ? printOffset : substituteOffset;
    const size_t length = usePrint ? printLength : substituteLength;
    if ((offset & 1U) != 0 || (length & 1U) != 0 || offset > available ||
        length > available - offset) {
      return STATUS_IO_REPARSE_DATA_INVALID;
    }
    const auto *path = reinterpret_cast<const wchar_t *>(
        reinterpret_cast<const char *>(
            data->SymbolicLinkReparseBuffer.PathBuffer) +
        offset);
    QString parsed = QString::fromWCharArray(
        path, static_cast<qsizetype>(length / sizeof(wchar_t)));
    if ((data->SymbolicLinkReparseBuffer.Flags & SYMLINK_FLAG_RELATIVE) == 0) {
      if (parsed.startsWith(QStringLiteral("\\??\\"))) {
        parsed.remove(0, 4);
      }
      QString mount = mountPoint_;
      while (mount.endsWith(QLatin1Char('\\'))) {
        mount.chop(1);
      }
      // Require a separator boundary so C:\mnt\apfsX is not mistaken for a
      // path under the C:\mnt\apfs mount point.
      if (mount.isEmpty() || !parsed.startsWith(mount, Qt::CaseInsensitive) ||
          (parsed.size() > mount.size() &&
           parsed.at(mount.size()) != QLatin1Char('\\') &&
           parsed.at(mount.size()) != QLatin1Char('/'))) {
        return STATUS_IO_REPARSE_TAG_NOT_HANDLED;
      }
      parsed.remove(0, mount.size());
      if (!parsed.startsWith(QLatin1Char('\\')) &&
          !parsed.startsWith(QLatin1Char('/'))) {
        parsed.prepend(QLatin1Char('\\'));
      }
    }
    parsed.replace(QLatin1Char('\\'), QLatin1Char('/'));
    if (parsed.isEmpty() || parsed.contains(QChar::Null)) {
      return STATUS_IO_REPARSE_DATA_INVALID;
    }
    *target = parsed;
    return STATUS_SUCCESS;
  }

  NTSTATUS setReparsePoint(FileNode *node, PVOID buffer, SIZE_T size) {
    if (readOnly_) {
      return STATUS_MEDIA_WRITE_PROTECTED;
    }
    if (!node || node->entry.directory || node->entry.sizeBytes != 0) {
      return STATUS_INVALID_PARAMETER;
    }
    if (node->entry.symlink) {
      QByteArray current;
      NTSTATUS status = buildSymbolicLinkReparseData(node->entry, &current);
      if (!NT_SUCCESS(status)) {
        return status;
      }
      status = FspFileSystemCanReplaceReparsePoint(
          current.data(), static_cast<SIZE_T>(current.size()), buffer, size);
      if (!NT_SUCCESS(status)) {
        return status;
      }
    }
    QString target;
    NTSTATUS status = parseSymbolicLinkReparseData(buffer, size, &target);
    if (!NT_SUCCESS(status)) {
      return status;
    }
    sak::PartitionApfsInodeMetadataUpdate update;
    update.update_changed_time = true;
    update.changed_time_ns = unixNsFromFileTime(currentFileTime());
    update.update_symbolic_link_target = true;
    update.symbolic_link_target = target;
    return commitInodeMetadata(node->entry.path, false, update,
                               &node->entry);
  }

  NTSTATUS deleteReparsePoint(FileNode *node, PVOID buffer, SIZE_T size) {
    if (readOnly_) {
      return STATUS_MEDIA_WRITE_PROTECTED;
    }
    if (!node || !node->entry.symlink) {
      return STATUS_NOT_A_REPARSE_POINT;
    }
    QByteArray current;
    NTSTATUS status = buildSymbolicLinkReparseData(node->entry, &current);
    if (!NT_SUCCESS(status)) {
      return status;
    }
    status = FspFileSystemCanReplaceReparsePoint(
        current.data(), static_cast<SIZE_T>(current.size()), buffer, size);
    if (!NT_SUCCESS(status)) {
      return status;
    }
    sak::PartitionApfsInodeMetadataUpdate update;
    update.update_changed_time = true;
    update.changed_time_ns = unixNsFromFileTime(currentFileTime());
    update.update_symbolic_link_target = true;
    return commitInodeMetadata(node->entry.path, false, update,
                               &node->entry);
  }

  NTSTATUS readMutableBytes(const ResolvedEntry &entry, QByteArray *data) {
    data->clear();
    if (entry.sizeBytes > kDefaultMaxMutationBytes) {
      return STATUS_FILE_TOO_LARGE;
    }
    if (entry.sizeBytes == 0) {
      return STATUS_SUCCESS;
    }
    QMutexLocker locker(&ioMutex_);
    const NTSTATUS readerStatus = ensureReaderNoLock();
    if (!NT_SUCCESS(readerStatus)) {
      return readerStatus;
    }
    const auto file = readerSession_->readFile(entry.path, entry.sizeBytes);
    if (!file.ok || !file.blockers.isEmpty()) {
      trace(QStringLiteral("read for mutation failed: %1")
                .arg(file.blockers.join(QStringLiteral("; "))));
      return STATUS_ACCESS_DENIED;
    }
    *data = file.data;
    return STATUS_SUCCESS;
  }

  uint32_t attributesFor(const ResolvedEntry &entry) const {
    uint32_t attributes =
        (readOnly_ || (entry.bsdFlags & kBsdFlagUserImmutable) != 0)
            ? FILE_ATTRIBUTE_READONLY
            : 0;
    if ((entry.bsdFlags & kBsdFlagUserHidden) != 0) {
      attributes |= FILE_ATTRIBUTE_HIDDEN;
    }
    if ((entry.bsdFlags & kBsdFlagUserArchive) != 0) {
      attributes |= FILE_ATTRIBUTE_ARCHIVE;
    }
    if (entry.directory) {
      attributes |= FILE_ATTRIBUTE_DIRECTORY;
    }
    if (entry.symlink) {
      attributes |= FILE_ATTRIBUTE_REPARSE_POINT;
    }
    if (attributes == 0) {
      attributes = FILE_ATTRIBUTE_NORMAL;
    }
    return attributes;
  }

  bool addDirInfo(const ResolvedEntry &entry, const QString &name, void *buffer,
                  ULONG length, PULONG transferred) const {
    const std::wstring wideName = wide(name);
    const size_t bytes = wideName.size() * sizeof(wchar_t);
    const size_t storageSize = sizeof(FSP_FSCTL_DIR_INFO) + bytes;
    auto storage = std::make_unique<char[]>(storageSize);
    auto *dirInfo = reinterpret_cast<FSP_FSCTL_DIR_INFO *>(storage.get());
    std::memset(dirInfo, 0, storageSize);
    dirInfo->Size = static_cast<UINT16>(storageSize);
    fillFileInfo(entry, &dirInfo->FileInfo);
    if (bytes != 0) {
      std::memcpy(dirInfo->FileNameBuf, wideName.data(), bytes);
    }
    return FspFileSystemAddDirInfo(dirInfo, buffer, length, transferred) !=
           FALSE;
  }

  QString target_;
  QString mountPoint_;
  QString volumeLabel_{QStringLiteral("APFS")};
  QString testFaultExitPhase_;
  QString testFaultPath_;
  std::unique_ptr<QIODevice> device_;
  std::unique_ptr<sak::PartitionApfsFileSystemReaderSession> readerSession_;
  mutable QMutex ioMutex_;
  mutable QMutex eaMutationMutex_;
  // Guards nodes_, handles_ and the id counters. Never acquire a node mutex
  // while holding it.
  mutable QMutex contextMutex_;
  QHash<QString, std::shared_ptr<FileNode>> nodes_;
  std::unordered_map<FileContext *, std::unique_ptr<FileContext>> handles_;
  uint64_t nextHandleId_{1};
  uint64_t nextNodeId_{1};
  // Guards totalBytes_, freeBytes_ and volumeLabel_.
  mutable QMutex volumeInfoMutex_;
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

ApfsMountState *stateOf(FSP_FILE_SYSTEM *fileSystem) {
  return reinterpret_cast<ApfsMountState *>(fileSystem->UserContext);
}

NTSTATUS GetReparsePointByName(FSP_FILE_SYSTEM *fileSystem, PVOID,
                               PWSTR fileName, BOOLEAN, PVOID buffer,
                               PSIZE_T size) {
  const NTSTATUS status =
      stateOf(fileSystem)
          ->getReparsePointByNameCallback(fromWide(fileName), buffer, size);
  trace(QStringLiteral("GetReparsePointByName %1 buffer=%2 status=0x%3")
            .arg(fromWide(fileName))
            .arg(buffer != nullptr)
            .arg(static_cast<quint32>(status), 8, 16, QLatin1Char('0')));
  return status;
}

NTSTATUS FsGetVolumeInfo(FSP_FILE_SYSTEM *fileSystem,
                         FSP_FSCTL_VOLUME_INFO *volumeInfo) {
  return stateOf(fileSystem)->volumeInfo(volumeInfo);
}

NTSTATUS FsSetVolumeLabel(FSP_FILE_SYSTEM *, PWSTR, FSP_FSCTL_VOLUME_INFO *) {
  return STATUS_MEDIA_WRITE_PROTECTED;
}

NTSTATUS FsGetSecurityByName(FSP_FILE_SYSTEM *fileSystem, PWSTR fileName,
                             PUINT32 attributes,
                             PSECURITY_DESCRIPTOR descriptor,
                             SIZE_T *descriptorSize) {
  const NTSTATUS status = stateOf(fileSystem)
                              ->securityByName(fromWide(fileName), attributes,
                                               descriptor, descriptorSize);
  if (status == STATUS_OBJECT_NAME_NOT_FOUND &&
      FspFileSystemFindReparsePoint(fileSystem, GetReparsePointByName, nullptr,
                                    fileName, attributes)) {
    return STATUS_REPARSE;
  }
  return status;
}

NTSTATUS FsCreate(FSP_FILE_SYSTEM *fileSystem, PWSTR fileName,
                  UINT32 createOptions, UINT32, UINT32 fileAttributes,
                  PSECURITY_DESCRIPTOR, UINT64, PVOID *fileContext,
                  FSP_FSCTL_FILE_INFO *fileInfo) {
  trace(QStringLiteral("Create %1 attrs=0x%2")
            .arg(fromWide(fileName))
            .arg(fileAttributes, 8, 16, QLatin1Char('0')));
  FileContext *context = nullptr;
  const bool directory = (fileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0 ||
                         (createOptions & FILE_DIRECTORY_FILE) != 0;
  const NTSTATUS status =
      stateOf(fileSystem)
          ->createNode(fromWide(fileName), directory, &context, fileInfo);
  if (NT_SUCCESS(status)) {
    *fileContext = context;
  }
  trace(QStringLiteral("CreateDone %1 status=0x%2")
            .arg(fromWide(fileName))
            .arg(static_cast<quint32>(status), 8, 16, QLatin1Char('0')));
  return status;
}

NTSTATUS FsOpen(FSP_FILE_SYSTEM *fileSystem, PWSTR fileName, UINT32, UINT32,
                PVOID *fileContext, FSP_FSCTL_FILE_INFO *fileInfo) {
  trace(QStringLiteral("Open %1").arg(fromWide(fileName)));
  ResolvedEntry entry;
  NTSTATUS status =
      stateOf(fileSystem)->resolvePath(fromWide(fileName), &entry);
  if (!NT_SUCCESS(status)) {
    return status;
  }
  auto *context =
      stateOf(fileSystem)->openHandle(entry, false, false, fileInfo);
  if (!context) {
    return STATUS_INSUFFICIENT_RESOURCES;
  }
  *fileContext = context;
  return STATUS_SUCCESS;
}

NTSTATUS FsOverwrite(FSP_FILE_SYSTEM *fileSystem, PVOID fileContext, UINT32,
                     BOOLEAN, UINT64, FSP_FSCTL_FILE_INFO *fileInfo) {
  FileNode *node = nodeOf(fileContext);
  NodeGuard guard(node);
  trace(QStringLiteral("Overwrite %1")
            .arg(node ? node->entry.path : QStringLiteral("<null>")));
  return stateOf(fileSystem)->overwriteFile(node, fileInfo);
}

VOID FsCleanup(FSP_FILE_SYSTEM *fileSystem, PVOID fileContext, PWSTR,
               ULONG flags) {
  auto *context = reinterpret_cast<FileContext *>(fileContext);
  FileNode *node = nodeOf(fileContext);
  if (!context || !node) {
    return;
  }
  NodeGuard guard(node);
  trace(QStringLiteral("Cleanup %1 flags=0x%2")
            .arg(node->entry.path)
            .arg(flags, 8, 16, QLatin1Char('0')));
  stateOf(fileSystem)->cleanupHandle(context, flags);
}

VOID FsClose(FSP_FILE_SYSTEM *fileSystem, PVOID fileContext) {
  auto *context = reinterpret_cast<FileContext *>(fileContext);
  trace(QStringLiteral("Close handle=%1").arg(context ? context->handleId : 0));
  stateOf(fileSystem)->closeHandle(context);
}

NTSTATUS FsRead(FSP_FILE_SYSTEM *fileSystem, PVOID fileContext, PVOID buffer,
                UINT64 offset, ULONG length, PULONG transferred) {
  *transferred = 0;
  FileNode *node = nodeOf(fileContext);
  if (!node) {
    return STATUS_INVALID_PARAMETER;
  }
  NodeGuard guard(node);
  trace(QStringLiteral("Read %1 offset=%2 length=%3")
            .arg(node->entry.path)
            .arg(offset)
            .arg(length));
  const NTSTATUS status =
      stateOf(fileSystem)->readFile(node, offset, length, buffer, transferred);
  trace(QStringLiteral("ReadDone status=0x%1 transferred=%2")
            .arg(static_cast<quint32>(status), 8, 16, QLatin1Char('0'))
            .arg(*transferred));
  return status;
}

NTSTATUS FsWrite(FSP_FILE_SYSTEM *fileSystem, PVOID fileContext, PVOID buffer,
                 UINT64 offset, ULONG length, BOOLEAN writeToEndOfFile,
                 BOOLEAN constrainedIo, PULONG transferred,
                 FSP_FSCTL_FILE_INFO *fileInfo) {
  *transferred = 0;
  FileNode *node = nodeOf(fileContext);
  NodeGuard guard(node);
  trace(QStringLiteral("Write %1 offset=%2 length=%3 eof=%4 constrained=%5")
            .arg(node ? node->entry.path : QStringLiteral("<null>"))
            .arg(offset)
            .arg(length)
            .arg(writeToEndOfFile)
            .arg(constrainedIo));
  const NTSTATUS status =
      stateOf(fileSystem)
          ->writeFile(node, buffer, offset, length, writeToEndOfFile,
                      constrainedIo, transferred, fileInfo);
  trace(QStringLiteral("WriteDone status=0x%1 transferred=%2")
            .arg(static_cast<quint32>(status), 8, 16, QLatin1Char('0'))
            .arg(*transferred));
  return status;
}

NTSTATUS FsFlush(FSP_FILE_SYSTEM *fileSystem, PVOID fileContext,
                 FSP_FSCTL_FILE_INFO *fileInfo) {
  FileNode *node = nodeOf(fileContext);
  if (!node) {
    // Volume flush: nothing is cached outside per-file staging.
    return STATUS_SUCCESS;
  }
  NodeGuard guard(node);
  trace(QStringLiteral("Flush %1").arg(node->entry.path));
  const NTSTATUS status = stateOf(fileSystem)->flushFile(node, fileInfo);
  trace(QStringLiteral("FlushDone status=0x%1")
            .arg(static_cast<quint32>(status), 8, 16, QLatin1Char('0')));
  return status;
}

NTSTATUS FsGetFileInfo(FSP_FILE_SYSTEM *fileSystem, PVOID fileContext,
                       FSP_FSCTL_FILE_INFO *fileInfo) {
  FileNode *node = nodeOf(fileContext);
  if (!node) {
    return STATUS_INVALID_PARAMETER;
  }
  NodeGuard guard(node);
  trace(QStringLiteral("GetFileInfo %1").arg(node->entry.path));
  stateOf(fileSystem)->fillFileInfo(node->entry, fileInfo);
  return STATUS_SUCCESS;
}

NTSTATUS FsSetBasicInfo(FSP_FILE_SYSTEM *fileSystem, PVOID fileContext,
                        UINT32 fileAttributes, UINT64 creationTime,
                        UINT64 lastAccessTime, UINT64 lastWriteTime,
                        UINT64 changeTime, FSP_FSCTL_FILE_INFO *fileInfo) {
  FileNode *node = nodeOf(fileContext);
  NodeGuard guard(node);
  trace(QStringLiteral("SetBasicInfo %1")
            .arg(node ? node->entry.path : QStringLiteral("<null>")));
  return stateOf(fileSystem)
      ->setBasicInfoCallback(node, fileAttributes, creationTime,
                             lastAccessTime, lastWriteTime, changeTime,
                             fileInfo);
}

NTSTATUS FsSetFileSize(FSP_FILE_SYSTEM *fileSystem, PVOID fileContext,
                       UINT64 newSize, BOOLEAN setAllocationSize,
                       FSP_FSCTL_FILE_INFO *fileInfo) {
  FileNode *node = nodeOf(fileContext);
  NodeGuard guard(node);
  trace(QStringLiteral("SetFileSize %1 size=%2 allocation=%3")
            .arg(node ? node->entry.path : QStringLiteral("<null>"))
            .arg(newSize)
            .arg(setAllocationSize));
  return stateOf(fileSystem)
      ->setFileSize(node, newSize, setAllocationSize, fileInfo);
}

NTSTATUS FsCanDelete(FSP_FILE_SYSTEM *fileSystem, PVOID fileContext, PWSTR) {
  FileNode *node = nodeOf(fileContext);
  NodeGuard guard(node);
  trace(QStringLiteral("CanDelete %1")
            .arg(node ? node->entry.path : QStringLiteral("<null>")));
  const NTSTATUS status = stateOf(fileSystem)->canDelete(node);
  trace(QStringLiteral("CanDeleteDone status=0x%1")
            .arg(static_cast<quint32>(status), 8, 16, QLatin1Char('0')));
  return status;
}

NTSTATUS FsRename(FSP_FILE_SYSTEM *fileSystem, PVOID fileContext,
                  PWSTR fileName, PWSTR newFileName, BOOLEAN replaceIfExists) {
  FileNode *node = nodeOf(fileContext);
  NodeGuard guard(node);
  trace(QStringLiteral("Rename %1 -> %2 replace=%3")
            .arg(fromWide(fileName), fromWide(newFileName))
            .arg(replaceIfExists));
  return stateOf(fileSystem)
      ->renameFile(node, fromWide(fileName), fromWide(newFileName),
                   replaceIfExists != FALSE);
}

#if defined(FSP_FILE_SYSTEM_INTERFACE_HAS_CREATE_HARD_LINK)
NTSTATUS FsCreateHardLink(FSP_FILE_SYSTEM *fileSystem, PVOID fileContext,
                          PWSTR fileName, PWSTR newFileName,
                          BOOLEAN replaceIfExists,
                          FSP_FSCTL_FILE_INFO *fileInfo) {
  FileNode *node = nodeOf(fileContext);
  NodeGuard guard(node);
  trace(QStringLiteral("CreateHardLink %1 -> %2 replace=%3")
            .arg(fromWide(fileName), fromWide(newFileName))
            .arg(replaceIfExists));
  return stateOf(fileSystem)
      ->createHardLink(node, fromWide(newFileName), replaceIfExists != FALSE,
                       fileInfo);
}
#endif

NTSTATUS FsGetSecurity(FSP_FILE_SYSTEM *fileSystem, PVOID fileContext,
                       PSECURITY_DESCRIPTOR descriptor,
                       SIZE_T *descriptorSize) {
  FileNode *node = nodeOf(fileContext);
  if (!node) {
    return STATUS_INVALID_PARAMETER;
  }
  NodeGuard guard(node);
  return stateOf(fileSystem)
      ->copySecurity(node->entry, descriptor, descriptorSize);
}

NTSTATUS FsSetSecurity(FSP_FILE_SYSTEM *fileSystem, PVOID fileContext,
                       SECURITY_INFORMATION securityInformation,
                       PSECURITY_DESCRIPTOR modificationDescriptor) {
  FileNode *node = nodeOf(fileContext);
  NodeGuard guard(node);
  trace(QStringLiteral("SetSecurity %1 info=0x%2")
            .arg(node ? node->entry.path : QStringLiteral("<null>"))
            .arg(static_cast<quint32>(securityInformation), 8, 16,
                 QLatin1Char('0')));
  return stateOf(fileSystem)
      ->setSecurityCallback(node, securityInformation, modificationDescriptor);
}

NTSTATUS FsGetEa(FSP_FILE_SYSTEM *fileSystem, PVOID fileContext,
                 PFILE_FULL_EA_INFORMATION ea, ULONG eaLength,
                 PULONG bytesTransferred) {
  FileNode *node = nodeOf(fileContext);
  NodeGuard guard(node);
  const NTSTATUS status = stateOf(fileSystem)
                              ->getEaCallback(node, ea, eaLength,
                                              bytesTransferred);
  trace(QStringLiteral("GetEa status=0x%1 bytes=%2")
            .arg(static_cast<quint32>(status), 8, 16, QLatin1Char('0'))
            .arg(bytesTransferred ? *bytesTransferred : 0));
  return status;
}

NTSTATUS FsSetEa(FSP_FILE_SYSTEM *fileSystem, PVOID fileContext,
                 PFILE_FULL_EA_INFORMATION ea, ULONG eaLength,
                 FSP_FSCTL_FILE_INFO *fileInfo) {
  FileNode *node = nodeOf(fileContext);
  NodeGuard guard(node);
  const NTSTATUS status =
      stateOf(fileSystem)
          ->setEaCallback(fileSystem, node, ea, eaLength, fileInfo);
  trace(QStringLiteral("SetEa status=0x%1")
            .arg(static_cast<quint32>(status), 8, 16, QLatin1Char('0')));
  return status;
}

NTSTATUS FsResolveReparsePoints(FSP_FILE_SYSTEM *fileSystem, PWSTR fileName,
                                UINT32 reparsePointIndex,
                                BOOLEAN resolveLastPathComponent,
                                PIO_STATUS_BLOCK ioStatus, PVOID buffer,
                                PSIZE_T size) {
  const NTSTATUS status = FspFileSystemResolveReparsePoints(
      fileSystem, GetReparsePointByName, nullptr, fileName, reparsePointIndex,
      resolveLastPathComponent, ioStatus, buffer, size);
  trace(QStringLiteral("ResolveReparsePoints %1 index=%2 last=%3 status=0x%4")
            .arg(fromWide(fileName))
            .arg(reparsePointIndex)
            .arg(resolveLastPathComponent)
            .arg(static_cast<quint32>(status), 8, 16, QLatin1Char('0')));
  return status;
}

NTSTATUS FsGetReparsePoint(FSP_FILE_SYSTEM *fileSystem, PVOID fileContext,
                           PWSTR, PVOID buffer, PSIZE_T size) {
  FileNode *node = nodeOf(fileContext);
  NodeGuard guard(node);
  const NTSTATUS status =
      stateOf(fileSystem)->getReparsePointCallback(node, buffer, size);
  trace(QStringLiteral("GetReparsePoint status=0x%1")
            .arg(static_cast<quint32>(status), 8, 16, QLatin1Char('0')));
  return status;
}

NTSTATUS FsSetReparsePoint(FSP_FILE_SYSTEM *fileSystem, PVOID fileContext,
                           PWSTR, PVOID buffer, SIZE_T size) {
  FileNode *node = nodeOf(fileContext);
  NodeGuard guard(node);
  const NTSTATUS status =
      stateOf(fileSystem)->setReparsePointCallback(node, buffer, size);
  trace(QStringLiteral("SetReparsePoint status=0x%1")
            .arg(static_cast<quint32>(status), 8, 16, QLatin1Char('0')));
  return status;
}

NTSTATUS FsDeleteReparsePoint(FSP_FILE_SYSTEM *fileSystem, PVOID fileContext,
                              PWSTR, PVOID buffer, SIZE_T size) {
  FileNode *node = nodeOf(fileContext);
  NodeGuard guard(node);
  const NTSTATUS status =
      stateOf(fileSystem)->deleteReparsePointCallback(node, buffer, size);
  trace(QStringLiteral("DeleteReparsePoint status=0x%1")
            .arg(static_cast<quint32>(status), 8, 16, QLatin1Char('0')));
  return status;
}

NTSTATUS FsReadDirectory(FSP_FILE_SYSTEM *fileSystem, PVOID fileContext, PWSTR,
                         PWSTR marker, PVOID buffer, ULONG length,
                         PULONG transferred) {
  *transferred = 0;
  FileNode *node = nodeOf(fileContext);
  if (!node) {
    return STATUS_INVALID_PARAMETER;
  }
  ResolvedEntry directory;
  {
    NodeGuard guard(node);
    directory = node->entry;
  }
  trace(QStringLiteral("ReadDirectory %1 marker=%2 length=%3")
            .arg(directory.path)
            .arg(marker ? QString::fromWCharArray(marker)
                        : QStringLiteral("<null>"))
            .arg(length));
  const NTSTATUS status =
      stateOf(fileSystem)
          ->listDirectory(directory, marker, buffer, length, transferred);
  trace(QStringLiteral("ReadDirectoryDone status=0x%1 transferred=%2")
            .arg(static_cast<quint32>(status), 8, 16, QLatin1Char('0'))
            .arg(*transferred));
  return status;
}

FSP_FILE_SYSTEM_INTERFACE *apfsInterface() {
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
    iface.GetEa = FsGetEa;
    iface.SetEa = FsSetEa;
    iface.ReadDirectory = FsReadDirectory;
    iface.ResolveReparsePoints = FsResolveReparsePoints;
    iface.GetReparsePoint = FsGetReparsePoint;
    iface.SetReparsePoint = FsSetReparsePoint;
    iface.DeleteReparsePoint = FsDeleteReparsePoint;
#if defined(FSP_FILE_SYSTEM_INTERFACE_HAS_CREATE_HARD_LINK)
    iface.CreateHardLink = FsCreateHardLink;
#endif
    initialized = true;
  }
  return &iface;
}

NTSTATUS runMount(const QString &target, const QString &mountPoint,
                  uint64_t maxFileReadBytes, bool readOnly, bool allowRawWrites,
                  const QString &testFaultExitPhase,
                  const QString &testFaultPath, HANDLE stopEvent) {
  ApfsMountState state;
  QString error;
  NTSTATUS status =
      state.openTarget(target, maxFileReadBytes, readOnly, allowRawWrites,
                       testFaultExitPhase, testFaultPath, &error);
  if (!NT_SUCCESS(status)) {
    QTextStream(stderr) << error << Qt::endl;
    return status;
  }
  state.setMountPoint(mountPoint);

  FSP_FSCTL_VOLUME_PARAMS params{};
  params.Version = sizeof(FSP_FSCTL_VOLUME_PARAMS);
  params.SectorSize = static_cast<UINT16>(kAllocationUnit);
  params.SectorsPerAllocationUnit = 1;
  params.MaxComponentLength = 255 * sizeof(WCHAR);
  params.VolumeCreationTime = currentFileTime();
  params.VolumeSerialNumber = state.serialNumber();
  // APFS hard-link aliases share inode metadata, but WinFsp caches metadata per
  // pathname. Disable that cache so link-count changes stay coherent across
  // every alias after create or delete.
  params.FileInfoTimeout = 0;
  // FileContext is a per-handle descriptor (one Close per Open/Create), not a
  // per-name node; shared per-name state lives in ApfsMountState::nodes_.
  params.UmFileContextIsUserContext2 = 1;
  params.CaseSensitiveSearch = 1;
  params.CasePreservedNames = 1;
  params.UnicodeOnDisk = 1;
  params.PersistentAcls = 1;
  params.ExtendedAttributes = 1;
  params.CasePreservedExtendedAttributes = 1;
  params.ReparsePoints = 1;
  params.ReparsePointsAccessCheck = 0;
  params.ReadOnlyVolume = readOnly ? 1 : 0;
  params.PostCleanupWhenModifiedOnly = 0;
  params.AlwaysUseDoubleBuffering = 1;
#if defined(FSP_FILE_SYSTEM_INTERFACE_HAS_CREATE_HARD_LINK)
  params.HardLinks = readOnly ? 0 : 1;
#endif
  wcscpy_s(params.FileSystemName, L"APFS");

  FSP_FILE_SYSTEM *fileSystem = nullptr;
  std::wstring devicePath = L"" FSP_FSCTL_DISK_DEVICE_NAME;
  status = FspFileSystemCreate(devicePath.data(), &params, apfsInterface(),
                               &fileSystem);
  if (!NT_SUCCESS(status)) {
    QTextStream(stderr) << "FspFileSystemCreate failed: 0x" << Qt::hex << status
                        << Qt::endl;
    return status;
  }

  fileSystem->UserContext = &state;
  const std::wstring mountWide = wide(mountPoint);
  status = FspFileSystemSetMountPoint(
      fileSystem,
      mountWide.empty() ? nullptr : const_cast<PWSTR>(mountWide.c_str()));
  if (!NT_SUCCESS(status)) {
    QTextStream(stderr) << "FspFileSystemSetMountPoint failed: 0x" << Qt::hex
                        << status << Qt::endl;
    FspFileSystemDelete(fileSystem);
    return status;
  }

  gShutdownComplete = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  SetConsoleCtrlHandler(consoleHandler, TRUE);
  status = FspFileSystemStartDispatcher(fileSystem, 0);
  if (!NT_SUCCESS(status)) {
    QTextStream(stderr) << "FspFileSystemStartDispatcher failed: 0x" << Qt::hex
                        << status << Qt::endl;
    FspFileSystemDelete(fileSystem);
    if (gShutdownComplete) {
      SetEvent(gShutdownComplete);
    }
    return status;
  }

  QTextStream(stdout) << "mounted " << mountPoint << " as "
                      << (readOnly ? "read-only" : "read-write")
                      << " APFS volume " << state.volumeLabel() << Qt::endl;
  QString stopReason = QStringLiteral("console control");
  while (!gStopRequested) {
    if (!stopEvent) {
      Sleep(kStopPollIntervalMs);
      continue;
    }
    const DWORD wait = WaitForSingleObject(stopEvent, kStopPollIntervalMs);
    if (wait == WAIT_OBJECT_0) {
      stopReason = QStringLiteral("stop event");
      break;
    }
    if (wait == WAIT_FAILED) {
      trace(QStringLiteral("stop event wait failed: Win32 error %1")
                .arg(GetLastError()));
      Sleep(kStopPollIntervalMs);
    }
  }
  trace(QStringLiteral("Shutdown requested by %1").arg(stopReason));

  // Orderly unmount: commit staged writes while the volume is still live,
  // stop the dispatcher so no new callbacks arrive, commit anything that
  // raced in, then remove the mount point and delete the file system.
  int flushFailures = state.flushAllNodes();
  FspFileSystemStopDispatcher(fileSystem);
  flushFailures += state.flushAllNodes();
  FspFileSystemRemoveMountPoint(fileSystem);
  FspFileSystemDelete(fileSystem);
  if (flushFailures != 0) {
    QTextStream(stderr) << "unmount: " << flushFailures
                        << " staged write(s) failed to commit" << Qt::endl;
  }
  QTextStream(stdout) << "unmounted " << mountPoint << Qt::endl;
  if (gShutdownComplete) {
    SetEvent(gShutdownComplete);
  }
  return STATUS_SUCCESS;
}

#endif

void printStatus(bool eaPolicyReady, bool volumePolicyReady) {
  const bool selfTestsReady = eaPolicyReady && volumePolicyReady;
  QJsonObject status{
      {QStringLiteral("component"), QStringLiteral("apfs_winfs_worker")},
      {QStringLiteral("ea_case_collision_policy"),
       eaPolicyReady ? QStringLiteral("aliased_fail_closed")
                     : QStringLiteral("self_test_failed")},
      {QStringLiteral("protected_volume_write_policy"),
       volumePolicyReady
           ? QStringLiteral("sealed_and_encrypted_fail_closed")
           : QStringLiteral("self_test_failed")},
      {QStringLiteral("filesystem_owned_xattr_policy"),
       QStringLiteral("immutable_fail_closed")},
#if APFS_HAVE_WINFSP
      {QStringLiteral("status"),
       selfTestsReady ? QStringLiteral("ready")
                      : QStringLiteral("self_test_failed")},
      {QStringLiteral("winfsp_sdk"), QStringLiteral("found")},
#if APFS_WINFSP_NATIVE_HARDLINKS
      {QStringLiteral("native_hard_links"), true},
#else
      {QStringLiteral("native_hard_links"), false},
#endif
      {QStringLiteral("production_build"), APFS_PRODUCTION_BUILD != 0},
      {QStringLiteral("winfsp_callbacks"),
       QStringLiteral("read_only_and_guarded_image_rw_apfs")}};
#else
      {QStringLiteral("status"), QStringLiteral("scaffold")},
      {QStringLiteral("winfsp_sdk"), QStringLiteral("missing")},
      {QStringLiteral("winfsp_callbacks"), QStringLiteral("unavailable")}};
#endif
  QTextStream(stdout) << QJsonDocument(status).toJson(QJsonDocument::Indented);
}

} // namespace

#if APFS_HAVE_WINFSP
// The WinFsp DLL is delay-loaded and comes only from the official WinFsp
// installation (HKLM InstallDir, under Program Files). A plain LoadLibrary
// search, as FspLoad does first, could pick up a planted DLL from the search
// path in this LocalSystem process.
bool loadInstalledWinFsp(QString *error) {
  static bool loaded = false;
  if (loaded) {
    return true;
  }
  wchar_t installDir[MAX_PATH]{};
  DWORD size = sizeof(installDir);
  if (RegGetValueW(HKEY_LOCAL_MACHINE, L"" FSP_FSCTL_PRODUCT_FULL_REGKEY,
                   L"InstallDir", RRF_RT_REG_SZ, nullptr, installDir,
                   &size) != ERROR_SUCCESS) {
    *error = QStringLiteral(
        "WinFsp is not installed. Install WinFsp 2.2 or later (APFS for "
        "Windows Setup installs it automatically).");
    return false;
  }
  std::wstring dll(installDir);
  if (!dll.empty() && dll.back() != L'\\') {
    dll.push_back(L'\\');
  }
  dll += L"bin\\" FSP_FSCTL_PRODUCT_FILE_NAME "-" FSP_FSCTL_PRODUCT_FILE_ARCH ".dll";
  if (!LoadLibraryExW(dll.c_str(), nullptr, LOAD_WITH_ALTERED_SEARCH_PATH)) {
    *error = QStringLiteral("Unable to load the WinFsp runtime from %1: Win32 error %2")
                 .arg(QString::fromStdWString(dll))
                 .arg(GetLastError());
    return false;
  }
  loaded = true;
  return true;
}
#endif

int main(int argc, char *argv[]) {
  QCoreApplication app(argc, argv);
  QCoreApplication::setApplicationName(QStringLiteral("apfs_winfs_worker"));
  QCoreApplication::setApplicationVersion(QStringLiteral(APFS_PROJECT_VERSION));

  QCommandLineParser parser;
  parser.setApplicationDescription(QStringLiteral("WinFsp APFS mount worker."));
  parser.addHelpOption();
  parser.addVersionOption();
  QCommandLineOption statusOption{
      {QStringLiteral("status")},
      QStringLiteral("Print worker readiness JSON and exit.")};
  QCommandLineOption targetOption{
      {QStringLiteral("target")},
      QStringLiteral("APFS image, raw partition, or physical disk."),
      QStringLiteral("path")};
  QCommandLineOption mountOption{
      {QStringLiteral("mount")},
      QStringLiteral("Drive letter or directory mount point."),
      QStringLiteral("path")};
  QCommandLineOption maxReadOption{
      {QStringLiteral("max-file-read-bytes")},
      QStringLiteral("Maximum bytes read from one APFS file."),
      QStringLiteral("bytes"),
      QString::number(kDefaultMaxFileReadBytes)};
  QCommandLineOption readWriteOption{
      {QStringLiteral("read-write")},
      QStringLiteral("Mount writable. Image targets only unless "
                     "--allow-raw-writes is also present.")};
  QCommandLineOption allowRawWritesOption{
      {QStringLiteral("allow-raw-writes")},
      QStringLiteral("Allow direct raw-device APFS mutation after external "
                     "media confirmation.")};
  QCommandLineOption testFaultExitPhaseOption{
      {QStringLiteral("test-fault-exit-phase")},
      QStringLiteral("Test only: exit before or after image replacement."),
      QStringLiteral("phase")};
  QCommandLineOption testFaultPathOption{
      {QStringLiteral("test-fault-path")},
      QStringLiteral("Test only: exact APFS path that triggers process exit."),
      QStringLiteral("path")};
  QCommandLineOption stopEventOption{
      {QStringLiteral("stop-event")},
      QStringLiteral("Name of an existing event; when it is signaled the worker "
                     "flushes, unmounts and exits 0."),
      QStringLiteral("name")};
  parser.addOption(statusOption);
  parser.addOption(targetOption);
  parser.addOption(mountOption);
  parser.addOption(maxReadOption);
  parser.addOption(readWriteOption);
  parser.addOption(allowRawWritesOption);
  parser.addOption(testFaultExitPhaseOption);
  parser.addOption(testFaultPathOption);
  parser.addOption(stopEventOption);
  parser.process(app);

  if (parser.isSet(statusOption) ||
      (!parser.isSet(targetOption) && !parser.isSet(mountOption))) {
    const bool eaPolicyReady = windowsEaPolicySelfTest();
    const bool volumePolicyReady = apfsVolumePolicySelfTest();
    printStatus(eaPolicyReady, volumePolicyReady);
    return eaPolicyReady && volumePolicyReady ? 0 : 5;
  }

#if !APFS_HAVE_WINFSP
  QTextStream(stderr) << "WinFsp SDK/runtime is required for mounting."
                      << Qt::endl;
  return 4;
#else
  QString winFspError;
  if (!loadInstalledWinFsp(&winFspError)) {
    QTextStream(stderr) << winFspError << Qt::endl;
    return 7;
  }
  const QString target = parser.value(targetOption).trimmed();
  const QString mount = parser.value(mountOption).trimmed();
  if (target.isEmpty() || mount.isEmpty()) {
    QTextStream(stderr) << "--target and --mount are required for mount mode"
                        << Qt::endl;
    return 2;
  }
  const uint64_t maxRead = parser.value(maxReadOption).toULongLong();
  const bool readOnly = !parser.isSet(readWriteOption);
  const bool allowRawWrites = parser.isSet(allowRawWritesOption);
  const QString testFaultExitPhase =
      parser.value(testFaultExitPhaseOption).trimmed().toLower();
  const QString testFaultPath = parser.value(testFaultPathOption).trimmed();
  const bool testFaultRequested =
      !testFaultExitPhase.isEmpty() || !testFaultPath.isEmpty();
  if (testFaultRequested &&
      (testFaultPath.isEmpty() ||
       (testFaultExitPhase != kTestFaultBeforeImageReplace &&
        testFaultExitPhase != kTestFaultAfterImageReplace))) {
    QTextStream(stderr) << "test fault requires --test-fault-path and phase "
                           "before-image-replace or after-image-replace"
                        << Qt::endl;
    return 2;
  }
  if (testFaultRequested && (readOnly || looksLikeWindowsRawTarget(target) ||
                             !QFileInfo(target).isFile())) {
    QTextStream(stderr)
        << "test fault exits are restricted to writable image files"
        << Qt::endl;
    return 2;
  }
  HANDLE stopEvent = nullptr;
  if (parser.isSet(stopEventOption)) {
    const QString stopEventName = parser.value(stopEventOption);
    if (stopEventName.isEmpty()) {
      QTextStream(stderr) << "--stop-event requires an event name" << Qt::endl;
      return 2;
    }
    const std::wstring stopEventWide = wide(stopEventName);
    stopEvent = OpenEventW(SYNCHRONIZE, FALSE, stopEventWide.c_str());
    if (!stopEvent) {
      QTextStream(stderr) << "cannot open stop event \"" << stopEventName
                          << "\": Win32 error " << GetLastError() << Qt::endl;
      return 6;
    }
  }
  const NTSTATUS status =
      runMount(target, mount, maxRead, readOnly, allowRawWrites,
               testFaultExitPhase, testFaultPath, stopEvent);
  if (stopEvent) {
    CloseHandle(stopEvent);
  }
  if (NT_SUCCESS(status)) {
    return 0;
  }
  return static_cast<int>(status & 0xFFFF);
#endif
}
