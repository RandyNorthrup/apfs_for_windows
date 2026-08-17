// Copyright (c) 2026 Randy Northrup. All rights reserved.

#include "sak/partition_apfs_file_system_reader.h"
#include "sak/partition_file_system_detector.h"
#include "sak/partition_raw_device_io.h"

#include <QCoreApplication>
#include <QCommandLineOption>
#include <QCommandLineParser>
#include <QCryptographicHash>
#include <QIODevice>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QTextStream>
#include <QUuid>

#include <algorithm>
#include <cstdint>
#include <memory>
#include <optional>

namespace {

constexpr quint64 kSectorBytes = 512;
constexpr quint64 kGptHeaderOffset = kSectorBytes;
constexpr char kGptSignature[] = "EFI PART";
constexpr uint64_t kFallbackProbeBytes = 1024ULL * 1024ULL * 1024ULL;

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

struct PartitionCandidate {
    int index{0};
    QString type_guid;
    QString unique_guid;
    QString name;
    uint64_t offset_bytes{0};
    uint64_t size_bytes{0};
};

QVector<PartitionCandidate> readGpt(QIODevice* device) {
    QVector<PartitionCandidate> partitions;
    const QByteArray header = readAt(device, kGptHeaderOffset, 512);
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
                                             .type_guid = typeGuid,
                                             .unique_guid = guidString(entry, 16),
                                             .name = utf16Name(entry, 56, 72),
                                             .offset_bytes = firstLba * kSectorBytes,
                                             .size_bytes = (lastLba - firstLba + 1) *
                                                           kSectorBytes});
    }
    return partitions;
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
        const auto available = static_cast<qint64>(std::min<uint64_t>(
            static_cast<uint64_t>(maxSize), size_ - position_));
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

QJsonArray listRoot(QIODevice* device, int maxEntries) {
    QJsonArray entries;
    const auto listing =
        sak::PartitionApfsFileSystemReader::listDirectory(device, QStringLiteral("/"), maxEntries);
    for (const auto& entry : listing.entries) {
        entries.append(QJsonObject{{QStringLiteral("name"), entry.name},
                                   {QStringLiteral("path"), entry.path},
                                   {QStringLiteral("type"), entry.type},
                                   {QStringLiteral("object_id"), QString::number(entry.object_id)},
                                   {QStringLiteral("size_bytes"),
                                    QString::number(entry.size_bytes)},
                                   {QStringLiteral("hard_link_count"),
                                    QString::number(entry.hard_link_count)},
                                   {QStringLiteral("directory"), entry.directory},
                                   {QStringLiteral("regular_file"), entry.regular_file},
                                   {QStringLiteral("symlink"), entry.symlink}});
    }
    return entries;
}

QJsonArray stringListToJson(const QStringList& values) {
    QJsonArray out;
    for (const auto& value : values) {
        out.append(value);
    }
    return out;
}

QJsonObject readFileJson(QIODevice* device, const QString& path, uint64_t maxBytes) {
    const auto file = sak::PartitionApfsFileSystemReader::readFile(device, path, maxBytes);
    QJsonArray xattrs;
    for (const auto& xattr : file.xattrs) {
        xattrs.append(QJsonObject{{QStringLiteral("name"), xattr.first},
                                  {QStringLiteral("size_bytes"),
                                   QString::number(xattr.second.size())}});
    }
    return QJsonObject{
        {QStringLiteral("path"), path},
        {QStringLiteral("ok"), file.ok},
        {QStringLiteral("volume_name"), file.volume_name},
        {QStringLiteral("blockers"), stringListToJson(file.blockers)},
        {QStringLiteral("warnings"), stringListToJson(file.warnings)},
        {QStringLiteral("size_bytes"), QString::number(file.data.size())},
        {QStringLiteral("sha256"),
         QString::fromLatin1(QCryptographicHash::hash(file.data, QCryptographicHash::Sha256)
                                 .toHex())},
        {QStringLiteral("xattrs"), xattrs}};
}

QJsonObject debugFileJson(QIODevice* device, const QString& path) {
    const auto debug = sak::PartitionApfsFileSystemReader::debugFile(device, path);
    QJsonArray xattrs;
    for (const auto& xattr : debug.xattrs) {
        xattrs.append(QJsonObject{{QStringLiteral("name"), xattr.name},
                                  {QStringLiteral("object_id"),
                                   QString::number(xattr.object_id)},
                                  {QStringLiteral("size_bytes"),
                                   QString::number(xattr.size_bytes)},
                                  {QStringLiteral("embedded"), xattr.embedded}});
    }
    QJsonArray extents;
    for (const auto& extent : debug.extents) {
        extents.append(QJsonObject{
            {QStringLiteral("role"), extent.role},
            {QStringLiteral("owner_id"), QString::number(extent.owner_id)},
            {QStringLiteral("logical_offset"), QString::number(extent.logical_offset)},
            {QStringLiteral("length"), QString::number(extent.length)},
            {QStringLiteral("physical_block"), QString::number(extent.physical_block)},
            {QStringLiteral("physical_byte_offset"),
             QString::number(extent.physical_byte_offset)},
            {QStringLiteral("flags"), QString::number(extent.flags)},
            {QStringLiteral("crypto_id"), QString::number(extent.crypto_id)},
            {QStringLiteral("physical_block_in_container"),
             extent.physical_block_in_container},
            {QStringLiteral("physical_byte_offset_in_container"),
             extent.physical_byte_offset_in_container}});
    }
    return QJsonObject{{QStringLiteral("path"), debug.path},
                       {QStringLiteral("ok"), debug.ok},
                       {QStringLiteral("file_system"), debug.file_system},
                       {QStringLiteral("volume_name"), debug.volume_name},
                       {QStringLiteral("blockers"), stringListToJson(debug.blockers)},
                       {QStringLiteral("warnings"), stringListToJson(debug.warnings)},
                       {QStringLiteral("block_size"), QString::number(debug.block_size)},
                       {QStringLiteral("block_count"), QString::number(debug.block_count)},
                       {QStringLiteral("directory_parent_id"),
                        QString::number(debug.directory_parent_id)},
                       {QStringLiteral("directory_name"), debug.directory_name},
                       {QStringLiteral("file_id"), QString::number(debug.file_id)},
                       {QStringLiteral("directory_type"), debug.directory_type},
                       {QStringLiteral("inode_object_id"),
                        QString::number(debug.inode_object_id)},
                       {QStringLiteral("inode_private_id"),
                        QString::number(debug.inode_private_id)},
                       {QStringLiteral("inode_size"), QString::number(debug.inode_size)},
                       {QStringLiteral("inode_mode"), debug.inode_mode},
                       {QStringLiteral("inode_created_time_ns"),
                        QString::number(debug.inode_created_time_ns)},
                       {QStringLiteral("inode_modified_time_ns"),
                        QString::number(debug.inode_modified_time_ns)},
                       {QStringLiteral("inode_changed_time_ns"),
                        QString::number(debug.inode_changed_time_ns)},
                       {QStringLiteral("inode_accessed_time_ns"),
                        QString::number(debug.inode_accessed_time_ns)},
                       {QStringLiteral("inode_write_generation_counter"),
                        static_cast<qint64>(debug.inode_write_generation_counter)},
                       {QStringLiteral("inode_bsd_flags"),
                        static_cast<qint64>(debug.inode_bsd_flags)},
                       {QStringLiteral("inode_owner_id"),
                        static_cast<qint64>(debug.inode_owner_id)},
                       {QStringLiteral("inode_group_id"),
                        static_cast<qint64>(debug.inode_group_id)},
                       {QStringLiteral("inode_sparse"), debug.inode_sparse},
                       {QStringLiteral("has_decmpfs"), debug.has_decmpfs},
                       {QStringLiteral("decmpfs_algo"),
                        static_cast<int>(debug.decmpfs_algo)},
                       {QStringLiteral("decmpfs_uncompressed_size"),
                        QString::number(debug.decmpfs_uncompressed_size)},
                       {QStringLiteral("decmpfs_size_bytes"),
                        QString::number(debug.decmpfs_size_bytes)},
                       {QStringLiteral("resource_fork_object_id"),
                        QString::number(debug.resource_fork_object_id)},
                       {QStringLiteral("xattrs"), xattrs},
                       {QStringLiteral("extents"), extents}};
}

QJsonObject partitionToJson(QIODevice* device,
                            const PartitionCandidate& partition,
                            bool includeListing,
                            int maxEntries) {
    QJsonObject out{{QStringLiteral("index"), partition.index},
                    {QStringLiteral("type_guid"), partition.type_guid},
                    {QStringLiteral("unique_guid"), partition.unique_guid},
                    {QStringLiteral("name"), partition.name},
                    {QStringLiteral("offset_bytes"), QString::number(partition.offset_bytes)},
                    {QStringLiteral("size_bytes"), QString::number(partition.size_bytes)}};
    QString error;
    const auto detection = sak::PartitionFileSystemDetector::detectFromDevice(
        device, partition.offset_bytes, partition.size_bytes, &error);
    if (detection.has_value()) {
        out.insert(QStringLiteral("detection"), detectionToJson(*detection));
        if (includeListing &&
            detection->file_system.compare(QStringLiteral("APFS"), Qt::CaseInsensitive) == 0) {
            WindowDevice window(device, partition.offset_bytes, partition.size_bytes);
            if (window.open(QIODevice::ReadOnly)) {
                out.insert(QStringLiteral("root_entries"), listRoot(&window, maxEntries));
            }
        }
    } else if (!error.isEmpty()) {
        out.insert(QStringLiteral("detection_error"), error);
    }
    return out;
}

}  // namespace

int main(int argc, char* argv[]) {
    QCoreApplication app(argc, argv);
    QCoreApplication::setApplicationName(QStringLiteral("apfs_probe"));
    QCoreApplication::setApplicationVersion(QStringLiteral(APFS_PROJECT_VERSION));

    QCommandLineParser parser;
    parser.setApplicationDescription(QStringLiteral("Read-only APFS raw/image probe."));
    parser.addHelpOption();
    parser.addVersionOption();
    QCommandLineOption targetOption{{QStringLiteral("target")},
                                    QStringLiteral("Image path, raw partition, or physical disk."),
                                    QStringLiteral("path")};
    QCommandLineOption listRootOption{{QStringLiteral("list-root")},
                                      QStringLiteral("List APFS root entries when detected.")};
    QCommandLineOption maxEntriesOption{{QStringLiteral("max-entries")},
                                        QStringLiteral("Maximum APFS root entries to list."),
                                        QStringLiteral("count"),
                                        QStringLiteral("200")};
    QCommandLineOption readFileOption{{QStringLiteral("read-file")},
                                       QStringLiteral("Read APFS file and report SHA-256."),
                                       QStringLiteral("path")};
    QCommandLineOption debugFileOption{{QStringLiteral("debug-file")},
                                       QStringLiteral("Report APFS file inode/xattr/extent metadata."),
                                       QStringLiteral("path")};
    QCommandLineOption maxReadBytesOption{{QStringLiteral("max-read-bytes")},
                                           QStringLiteral("Maximum file bytes to read."),
                                           QStringLiteral("bytes"),
                                          QStringLiteral("536870912")};
    parser.addOption(targetOption);
    parser.addOption(listRootOption);
    parser.addOption(maxEntriesOption);
    parser.addOption(readFileOption);
    parser.addOption(debugFileOption);
    parser.addOption(maxReadBytesOption);
    parser.process(app);

    const QString target = parser.value(targetOption).trimmed();
    if (target.isEmpty()) {
        QTextStream(stderr) << "--target is required" << Qt::endl;
        return 2;
    }

    QString error;
    auto device = sak::openFileOrRawDeviceReadOnly(target, &error);
    if (!device) {
        QTextStream(stderr) << "open failed: " << error << Qt::endl;
        return 3;
    }

    const int maxEntries = std::max(1, parser.value(maxEntriesOption).toInt());
    QJsonObject report{{QStringLiteral("tool"), QStringLiteral("apfs_probe")},
                       {QStringLiteral("target"), target},
                       {QStringLiteral("device_size_bytes"),
                        QString::number(std::max<qint64>(0, device->size()))},
                       {QStringLiteral("read_only"), true}};

    const auto partitions = readGpt(device.get());
    QJsonArray partitionArray;
    for (const auto& partition : partitions) {
        partitionArray.append(
            partitionToJson(device.get(), partition, parser.isSet(listRootOption), maxEntries));
    }
    report.insert(QStringLiteral("gpt_partitions"), partitionArray);

    QString detectError;
    const uint64_t wholeSize = device->size() > 0 ? static_cast<uint64_t>(device->size())
                                                  : kFallbackProbeBytes;
    const auto wholeDetection =
        sak::PartitionFileSystemDetector::detectFromDevice(device.get(), 0, wholeSize, &detectError);
    if (wholeDetection.has_value()) {
        report.insert(QStringLiteral("whole_device_detection"), detectionToJson(*wholeDetection));
        if (parser.isSet(listRootOption) &&
            wholeDetection->file_system.compare(QStringLiteral("APFS"), Qt::CaseInsensitive) == 0) {
            report.insert(QStringLiteral("whole_device_root_entries"),
                          listRoot(device.get(), maxEntries));
        }
        if (parser.isSet(readFileOption) &&
            wholeDetection->file_system.compare(QStringLiteral("APFS"), Qt::CaseInsensitive) == 0) {
            report.insert(QStringLiteral("whole_device_read_file"),
                          readFileJson(device.get(),
                                       parser.value(readFileOption),
                                       parser.value(maxReadBytesOption).toULongLong()));
        }
        if (parser.isSet(debugFileOption) &&
            wholeDetection->file_system.compare(QStringLiteral("APFS"), Qt::CaseInsensitive) == 0) {
            report.insert(QStringLiteral("whole_device_debug_file"),
                          debugFileJson(device.get(), parser.value(debugFileOption)));
        }
    } else if (!detectError.isEmpty()) {
        report.insert(QStringLiteral("whole_device_detection_error"), detectError);
    }

    QTextStream(stdout) << QJsonDocument(report).toJson(QJsonDocument::Indented);
    return 0;
}
