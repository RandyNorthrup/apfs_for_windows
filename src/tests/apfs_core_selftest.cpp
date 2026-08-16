// Copyright (c) 2026 Randy Northrup. All rights reserved.

#include "sak/partition_apfs_file_system_reader.h"
#include "sak/partition_apfs_writer.h"

#include <QCoreApplication>
#include <QCryptographicHash>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSet>
#include <QTemporaryDir>
#include <QTextStream>

#include <algorithm>
#include <cstdint>

namespace {

QJsonArray toJson(const QStringList& values) {
    QJsonArray out;
    for (const auto& value : values) {
        out.append(value);
    }
    return out;
}

QString sha256Hex(const QByteArray& bytes) {
    return QString::fromLatin1(QCryptographicHash::hash(bytes, QCryptographicHash::Sha256).toHex());
}

void appendProof(QJsonArray* proofs, const QString& step, const QJsonObject& data = {}) {
    QJsonObject proof{{QStringLiteral("step"), step}, {QStringLiteral("ok"), true}};
    for (auto it = data.begin(); it != data.end(); ++it) {
        proof.insert(it.key(), it.value());
    }
    proofs->append(proof);
}

int fail(const QString& step, const QString& message, const QStringList& blockers = {}) {
    QJsonObject out{{QStringLiteral("tool"), QStringLiteral("apfs_core_selftest")},
                    {QStringLiteral("ok"), false},
                    {QStringLiteral("failed_step"), step},
                    {QStringLiteral("message"), message},
                    {QStringLiteral("blockers"), toJson(blockers)}};
    QTextStream(stderr) << QJsonDocument(out).toJson(QJsonDocument::Indented);
    return 1;
}

bool rootHas(const sak::PartitionApfsFileReadResult& listing,
             const QString& name,
             bool expectedDirectory = false) {
    for (const auto& entry : listing.entries) {
        if (entry.name == name && entry.directory == expectedDirectory) {
            return true;
        }
    }
    return false;
}

bool rootHasSymlink(const sak::PartitionApfsFileReadResult& listing, const QString& name) {
    for (const auto& entry : listing.entries) {
        if (entry.name == name && entry.symlink) {
            return true;
        }
    }
    return false;
}

const sak::PartitionApfsFileEntry* findEntry(const sak::PartitionApfsFileReadResult& listing,
                                             const QString& name) {
    for (const auto& entry : listing.entries) {
        if (entry.name == name) {
            return &entry;
        }
    }
    return nullptr;
}

int verifySymlink(const QString& imagePath,
                  const QString& path,
                  const QString& expectedName,
                  const QString& expectedTarget,
                  QJsonArray* proofs) {
    const auto listing = sak::PartitionApfsFileSystemReader::listDirectoryFromImage(
        imagePath, QStringLiteral("/"), 100);
    if (!listing.ok || !rootHasSymlink(listing, expectedName)) {
        return fail(QStringLiteral("verify symlink %1").arg(path),
                    QStringLiteral("symbolic-link directory entry missing"),
                    listing.blockers);
    }
    QFile image(imagePath);
    if (!image.open(QIODevice::ReadOnly)) {
        return fail(QStringLiteral("verify symlink %1").arg(path),
                    QStringLiteral("unable to open image"));
    }
    const auto debug = sak::PartitionApfsFileSystemReader::debugFile(&image, path);
    bool targetXattr = false;
    const uint64_t targetBytes = static_cast<uint64_t>(expectedTarget.toUtf8().size() + 1);
    for (const auto& xattr : debug.xattrs) {
        if (xattr.name == QStringLiteral("com.apple.fs.symlink") &&
            xattr.size_bytes == targetBytes) {
            targetXattr = true;
            break;
        }
    }
    constexpr uint16_t modeTypeMask = 0170000;
    constexpr uint16_t symlinkMode = 0120000;
    if (!debug.ok || debug.directory_type != 10 ||
        (debug.inode_mode & modeTypeMask) != symlinkMode ||
        (debug.inode_mode & 0777) != 0755 || !targetXattr) {
        return fail(QStringLiteral("verify symlink %1").arg(path),
                    QStringLiteral("symbolic-link inode or target xattr mismatch"),
                    debug.blockers);
    }
    appendProof(proofs,
                QStringLiteral("verify symlink %1").arg(path),
                {{QStringLiteral("directory_type"), debug.directory_type},
                 {QStringLiteral("inode_mode"), debug.inode_mode},
                 {QStringLiteral("target_bytes"), QString::number(targetBytes)}});
    return 0;
}

int verifyRead(const QString& imagePath,
               const QString& path,
               const QByteArray& expected,
               QJsonArray* proofs) {
    const auto read = sak::PartitionApfsFileSystemReader::readFileFromImage(
        imagePath, path, static_cast<uint64_t>(expected.size()));
    if (!read.ok) {
        return fail(QStringLiteral("read %1").arg(path),
                    QStringLiteral("readFileFromImage failed"),
                    read.blockers);
    }
    if (read.data != expected) {
        return fail(QStringLiteral("read %1").arg(path),
                    QStringLiteral("readback content mismatch"));
    }
    appendProof(proofs,
                QStringLiteral("read %1").arg(path),
                {{QStringLiteral("bytes"), QString::number(read.data.size())},
                 {QStringLiteral("sha256"), sha256Hex(read.data)}});
    return 0;
}

int verifyRangeRead(const QString& imagePath,
                    const QString& path,
                    uint64_t offset,
                    uint64_t length,
                    const QByteArray& expected,
                    QJsonArray* proofs) {
    QFile image(imagePath);
    if (!image.open(QIODevice::ReadOnly)) {
        return fail(QStringLiteral("range read %1").arg(path),
                    QStringLiteral("unable to open image"));
    }
    const auto read = sak::PartitionApfsFileSystemReader::readFileRange(
        &image, path, offset, length);
    if (!read.ok) {
        return fail(QStringLiteral("range read %1").arg(path),
                    QStringLiteral("readFileRange failed"),
                    read.blockers);
    }
    if (read.data != expected) {
        return fail(QStringLiteral("range read %1").arg(path),
                    QStringLiteral("range content mismatch"));
    }
    sak::PartitionApfsFileSystemReaderSession session(&image);
    const auto sessionRead = session.readFileRange(path, offset, length);
    const auto repeatedSessionRead = session.readFileRange(path, offset, length);
    if (!sessionRead.ok || !repeatedSessionRead.ok) {
        QStringList blockers = sessionRead.blockers;
        blockers.append(repeatedSessionRead.blockers);
        return fail(QStringLiteral("session range read %1").arg(path),
                    QStringLiteral("persistent reader session failed"),
                    blockers);
    }
    if (sessionRead.data != expected || repeatedSessionRead.data != expected) {
        return fail(QStringLiteral("session range read %1").arg(path),
                    QStringLiteral("persistent reader session content mismatch"));
    }
    appendProof(proofs,
                QStringLiteral("range read %1").arg(path),
                {{QStringLiteral("offset"), QString::number(offset)},
                 {QStringLiteral("requested_bytes"), QString::number(length)},
                 {QStringLiteral("returned_bytes"), QString::number(read.data.size())},
                 {QStringLiteral("sha256"), sha256Hex(read.data)},
                 {QStringLiteral("session_repeat_ok"), true}});
    return 0;
}

sak::PartitionApfsWriteOptions certifiedImageOnlyOptions() {
    sak::PartitionApfsWriteOptions options;
    options.enable_experimental_writer = true;
    options.destructive_certification_evidence = true;
    options.max_payload_bytes = 64ULL * 1024ULL;
    options.evidence_id = QStringLiteral("apfs_for_windows.core_selftest");
    return options;
}

sak::PartitionApfsWriteOptions certifiedRawOptions(uint64_t maxPayloadBytes) {
    sak::PartitionApfsWriteOptions options = certifiedImageOnlyOptions();
    options.image_only = false;
    options.raw_media_hardware_certification_evidence = true;
    options.max_payload_bytes = maxPayloadBytes;
    options.evidence_id = QStringLiteral("apfs_for_windows.core_selftest.raw_file_backed");
    return options;
}

QByteArray largeProofData() {
    QByteArray largeData(16 * 1024 * 1024, '\0');
    for (qsizetype i = 0; i < largeData.size(); ++i) {
        largeData[i] = static_cast<char>('A' + (i % 23));
    }
    return largeData;
}

bool buildInterruptedCheckpointImage(const QString& beforePath,
                                     const QString& committedPath,
                                     const QString& outputPath,
                                     const QSet<quint64>& omittedBlocks,
                                     quint64* changedBlocks,
                                     quint64* omittedChangedBlocks) {
    QFile::remove(outputPath);
    if (!QFile::copy(beforePath, outputPath)) {
        return false;
    }

    QFile before(beforePath);
    QFile committed(committedPath);
    QFile output(outputPath);
    if (!before.open(QIODevice::ReadOnly) || !committed.open(QIODevice::ReadOnly) ||
        !output.open(QIODevice::ReadWrite) || before.size() != committed.size()) {
        return false;
    }

    constexpr qint64 blockSize = 4096;
    quint64 changed = 0;
    quint64 omitted = 0;
    for (quint64 block = 0; block * blockSize < static_cast<quint64>(before.size()); ++block) {
        const QByteArray oldBytes = before.read(blockSize);
        const QByteArray newBytes = committed.read(blockSize);
        if (oldBytes.size() != newBytes.size()) {
            return false;
        }
        if (oldBytes == newBytes) {
            continue;
        }
        ++changed;
        if (omittedBlocks.contains(block)) {
            ++omitted;
            continue;
        }
        if (!output.seek(static_cast<qint64>(block * blockSize)) ||
            output.write(newBytes) != newBytes.size()) {
            return false;
        }
    }
    if (!output.flush()) {
        return false;
    }
    if (changedBlocks) {
        *changedBlocks = changed;
    }
    if (omittedChangedBlocks) {
        *omittedChangedBlocks = omitted;
    }
    return true;
}

int verifyCheckpointView(const QString& imagePath,
                         const QByteArray& seedData,
                         bool expectInserted,
                         QJsonArray* proofs,
                         const QString& phase) {
    const auto listing = sak::PartitionApfsFileSystemReader::listDirectoryFromImage(
        imagePath, QStringLiteral("/"), 20);
    if (!listing.ok) {
        return fail(phase, QStringLiteral("interrupted checkpoint is not readable"), listing.blockers);
    }
    if (!rootHas(listing, QStringLiteral("seed.txt")) ||
        rootHas(listing, QStringLiteral("inserted.txt")) != expectInserted) {
        return fail(phase, QStringLiteral("checkpoint selected unexpected file-tree generation"));
    }
    const auto seedRead = sak::PartitionApfsFileSystemReader::readFileFromImage(
        imagePath, QStringLiteral("/seed.txt"), static_cast<uint64_t>(seedData.size()));
    if (!seedRead.ok || seedRead.data != seedData) {
        return fail(phase, QStringLiteral("seed file changed across checkpoint interruption"),
                    seedRead.blockers);
    }
    appendProof(proofs,
                phase,
                {{QStringLiteral("selected_generation"),
                  expectInserted ? QStringLiteral("new") : QStringLiteral("old")},
                 {QStringLiteral("seed_sha256"), sha256Hex(seedRead.data)}});
    return 0;
}

}  // namespace

int main(int argc, char* argv[]) {
    QCoreApplication app(argc, argv);
    QCoreApplication::setApplicationName(QStringLiteral("apfs_core_selftest"));
    QCoreApplication::setApplicationVersion(QStringLiteral("0.1.0"));

    const QStringList args = app.arguments();
    const int makeImageIndex = args.indexOf(QStringLiteral("--make-image"));
    const QString makeImagePath =
        makeImageIndex >= 0 && makeImageIndex + 1 < args.size()
            ? QFileInfo(args.at(makeImageIndex + 1)).absoluteFilePath()
            : QString{};
    const int makeLargeImageIndex = args.indexOf(QStringLiteral("--make-large-image"));
    const QString makeLargeImagePath =
        makeLargeImageIndex >= 0 && makeLargeImageIndex + 1 < args.size()
            ? QFileInfo(args.at(makeLargeImageIndex + 1)).absoluteFilePath()
            : QString{};

    QTemporaryDir temp;
    if (!temp.isValid()) {
        return fail(QStringLiteral("tempdir"), QStringLiteral("temporary directory failed"));
    }

    const auto options = certifiedImageOnlyOptions();
    const QByteArray seedData("APFS for Windows copied-core seed proof");
    const QByteArray insertedData("APFS for Windows copied-core insert proof");
    const QByteArray replacementData("APFS for Windows copied-core replacement proof");
    const QDir tempDir(temp.path());
    QJsonArray proofs;

    const QString seedImage = tempDir.filePath(QStringLiteral("seed.apfs"));
    const auto seed = sak::PartitionApfsWriter::buildImageOnlyFormatImageWithSeedFile(
        {.image_path = seedImage,
         .target_container_bytes = 64ULL * 1024ULL * 1024ULL,
         .block_size_bytes = 4096,
         .volume_name = QStringLiteral("APFSWINSELF"),
         .seed_file_name = QStringLiteral("seed.txt"),
         .seed_file_data = seedData,
         .options = options});
    if (!seed.ok) {
        return fail(QStringLiteral("format seed image"),
                    QStringLiteral("buildImageOnlyFormatImageWithSeedFile failed"),
                    seed.blockers);
    }
    if (!QFileInfo::exists(seedImage)) {
        return fail(QStringLiteral("format seed image"), QStringLiteral("image file missing"));
    }
    appendProof(&proofs,
                QStringLiteral("format seed image"),
                {{QStringLiteral("image_sha256"), seed.image_sha256}});

    const auto seedListing =
        sak::PartitionApfsFileSystemReader::listDirectoryFromImage(seedImage, QStringLiteral("/"), 20);
    if (!seedListing.ok) {
        return fail(QStringLiteral("list seed root"),
                    QStringLiteral("listDirectoryFromImage failed"),
                    seedListing.blockers);
    }
    if (seedListing.volume_name != QStringLiteral("APFSWINSELF") ||
        !rootHas(seedListing, QStringLiteral("seed.txt"))) {
        return fail(QStringLiteral("list seed root"), QStringLiteral("seed entry missing"));
    }
    appendProof(&proofs,
                QStringLiteral("list seed root"),
                {{QStringLiteral("volume"), seedListing.volume_name},
                 {QStringLiteral("entries"), seedListing.entries.size()}});
    if (const int rc = verifyRead(seedImage, QStringLiteral("/seed.txt"), seedData, &proofs);
        rc != 0) {
        return rc;
    }
    if (const int rc = verifyRangeRead(seedImage,
                                       QStringLiteral("/seed.txt"),
                                       5,
                                       11,
                                       seedData.mid(5, 11),
                                       &proofs);
        rc != 0) {
        return rc;
    }
    if (const int rc = verifyRangeRead(seedImage,
                                       QStringLiteral("/seed.txt"),
                                       static_cast<uint64_t>(seedData.size()) + 1,
                                       4096,
                                       {},
                                       &proofs);
        rc != 0) {
        return rc;
    }

    if (!makeLargeImagePath.isEmpty() && makeImagePath.isEmpty()) {
        const QByteArray largeData = largeProofData();
        sak::PartitionApfsWriteOptions largeOptions = options;
        largeOptions.max_payload_bytes = static_cast<uint64_t>(largeData.size());
        const QString largeFileImage = tempDir.filePath(QStringLiteral("large-file-minimal.apfs"));
        const auto largeFile = sak::PartitionApfsWriter::commitImageOnlyFileInsert(
            {.source_image_path = seedImage,
             .written_image_path = largeFileImage,
             .file_name = QStringLiteral("large.bin"),
             .file_data = largeData,
             .options = largeOptions});
        if (!largeFile.ok) {
            return fail(QStringLiteral("make large image"),
                        QStringLiteral("commitImageOnlyFileInsert failed"),
                        largeFile.blockers);
        }
        if (const int rc =
                verifyRead(largeFileImage, QStringLiteral("/large.bin"), largeData, &proofs);
            rc != 0) {
            return rc;
        }
        const QFileInfo imageInfo(makeLargeImagePath);
        QDir().mkpath(imageInfo.absolutePath());
        QFile::remove(makeLargeImagePath);
        if (!QFile::copy(largeFileImage, makeLargeImagePath)) {
            return fail(QStringLiteral("make large image"),
                        QStringLiteral("unable to copy large-file image"));
        }
        appendProof(&proofs,
                    QStringLiteral("make large image"),
                    {{QStringLiteral("path"), makeLargeImagePath},
                     {QStringLiteral("large_file_bytes"),
                      QString::number(largeData.size())},
                     {QStringLiteral("large_file_sha256"), sha256Hex(largeData)}});
        QJsonObject out{{QStringLiteral("tool"), QStringLiteral("apfs_core_selftest")},
                        {QStringLiteral("ok"), true},
                        {QStringLiteral("proofs"), proofs}};
        QTextStream(stdout) << QJsonDocument(out).toJson(QJsonDocument::Indented);
        return 0;
    }

    const QString insertedImage = tempDir.filePath(QStringLiteral("inserted.apfs"));
    const auto insert = sak::PartitionApfsWriter::commitImageOnlyFileInsert(
        {.source_image_path = seedImage,
         .written_image_path = insertedImage,
         .file_name = QStringLiteral("inserted.txt"),
         .file_data = insertedData,
         .options = options});
    if (!insert.ok) {
        return fail(QStringLiteral("commit file insert"),
                    QStringLiteral("commitImageOnlyFileInsert failed"),
                    insert.blockers);
    }
    appendProof(&proofs,
                QStringLiteral("commit file insert"),
                {{QStringLiteral("previous_xid"), QString::number(insert.previous_xid)},
                 {QStringLiteral("new_xid"), QString::number(insert.new_xid)}});
    if (const int rc =
            verifyRead(insertedImage, QStringLiteral("/inserted.txt"), insertedData, &proofs);
        rc != 0) {
        return rc;
    }
    if (const int rc = verifyRead(insertedImage, QStringLiteral("/seed.txt"), seedData, &proofs);
        rc != 0) {
        return rc;
    }

    const QString symlinkImage = tempDir.filePath(QStringLiteral("symlink.apfs"));
    const QString symlinkTarget = QStringLiteral("seed.txt");
    const auto symlinkInsert = sak::PartitionApfsWriter::commitImageOnlyFileInsert(
        {.source_image_path = insertedImage,
         .written_image_path = symlinkImage,
         .file_name = QStringLiteral("seed-link"),
         .symbolic_link_target = symlinkTarget,
         .options = options});
    if (!symlinkInsert.ok) {
        return fail(QStringLiteral("commit symbolic link insert"),
                    QStringLiteral("commitImageOnlyFileInsert failed"),
                    symlinkInsert.blockers);
    }
    if (const int rc = verifySymlink(symlinkImage,
                                     QStringLiteral("/seed-link"),
                                     QStringLiteral("seed-link"),
                                     symlinkTarget,
                                     &proofs);
        rc != 0) {
        return rc;
    }
    const QString symlinkPreservedImage =
        tempDir.filePath(QStringLiteral("symlink-preserved.apfs"));
    const auto preserveSymlink = sak::PartitionApfsWriter::commitImageOnlyFileInsert(
        {.source_image_path = symlinkImage,
         .written_image_path = symlinkPreservedImage,
         .file_name = QStringLiteral("after-link.txt"),
         .file_data = QByteArray("mutation after symbolic link"),
         .options = options});
    if (!preserveSymlink.ok) {
        return fail(QStringLiteral("preserve symbolic link across mutation"),
                    QStringLiteral("commitImageOnlyFileInsert failed"),
                    preserveSymlink.blockers);
    }
    if (const int rc = verifySymlink(symlinkPreservedImage,
                                     QStringLiteral("/seed-link"),
                                     QStringLiteral("seed-link"),
                                     symlinkTarget,
                                     &proofs);
        rc != 0) {
        return rc;
    }

    const QString metadataImage = tempDir.filePath(QStringLiteral("metadata.apfs"));
    const auto metadata = sak::PartitionApfsWriter::commitImageOnlyInodeMetadata(
        {.source_image_path = symlinkPreservedImage,
         .written_image_path = metadataImage,
         .target_name = QStringLiteral("seed.txt"),
         .metadata = {.update_created_time = true,
                      .created_time_ns = 1'600'000'000'100'000'000ULL,
                      .update_modified_time = true,
                      .modified_time_ns = 1'600'000'000'200'000'000ULL,
                      .update_changed_time = true,
                      .changed_time_ns = 1'600'000'000'300'000'000ULL,
                      .update_accessed_time = true,
                      .accessed_time_ns = 1'600'000'000'400'000'000ULL,
                      .update_inode_mode = true,
                      .inode_mode = 0600,
                      .update_bsd_flags = true,
                      .bsd_flags = 0x00008002U,
                      .update_owner_id = true,
                      .owner_id = 501,
                      .update_group_id = true,
                      .group_id = 20},
         .options = options});
    if (!metadata.ok) {
        return fail(QStringLiteral("commit inode metadata"),
                    QStringLiteral("commitImageOnlyInodeMetadata failed"),
                    metadata.blockers);
    }
    const auto metadataListing = sak::PartitionApfsFileSystemReader::listDirectoryFromImage(
        metadataImage, QStringLiteral("/"), 100);
    const auto* metadataEntry = findEntry(metadataListing, QStringLiteral("seed.txt"));
    if (!metadataListing.ok || metadataEntry == nullptr ||
        metadataEntry->created_time_ns != 1'600'000'000'100'000'000ULL ||
        metadataEntry->modified_time_ns != 1'600'000'000'200'000'000ULL ||
        metadataEntry->changed_time_ns != 1'600'000'000'300'000'000ULL ||
        metadataEntry->accessed_time_ns != 1'600'000'000'400'000'000ULL ||
        (metadataEntry->inode_mode & 0777) != 0600 || metadataEntry->bsd_flags != 0x00008002U ||
        metadataEntry->owner_id != 501 || metadataEntry->group_id != 20) {
        return fail(QStringLiteral("verify inode metadata"),
                    QStringLiteral("inode metadata mismatch"),
                    metadataListing.blockers);
    }
    if (const int rc = verifyRead(metadataImage, QStringLiteral("/seed.txt"), seedData, &proofs);
        rc != 0) {
        return rc;
    }
    appendProof(&proofs,
                QStringLiteral("verify inode metadata"),
                {{QStringLiteral("mode"), metadataEntry->inode_mode},
                 {QStringLiteral("bsd_flags"), QString::number(metadataEntry->bsd_flags)},
                 {QStringLiteral("owner"), QString::number(metadataEntry->owner_id)},
                 {QStringLiteral("group"), QString::number(metadataEntry->group_id)}});

    const QString xattrImage = tempDir.filePath(QStringLiteral("xattr.apfs"));
    sak::PartitionApfsInodeMetadataUpdate xattrUpdate;
    xattrUpdate.xattr_mutations.append(
        {.name = QStringLiteral("user.apfswin_roundtrip"),
         .value = QByteArray("Windows EA payload")});
    const auto xattrSet = sak::PartitionApfsWriter::commitImageOnlyInodeMetadata(
        {.source_image_path = metadataImage,
         .written_image_path = xattrImage,
         .target_name = QStringLiteral("seed.txt"),
         .metadata = xattrUpdate,
         .options = options});
    if (!xattrSet.ok) {
        return fail(QStringLiteral("commit embedded xattr"),
                    QStringLiteral("commitImageOnlyInodeMetadata failed"),
                    xattrSet.blockers);
    }
    const auto xattrRead = sak::PartitionApfsFileSystemReader::readFileFromImage(
        xattrImage, QStringLiteral("/seed.txt"), static_cast<uint64_t>(seedData.size()));
    const bool xattrPresent = std::any_of(
        xattrRead.xattrs.cbegin(), xattrRead.xattrs.cend(), [](const auto& xattr) {
            return xattr.first == QStringLiteral("user.apfswin_roundtrip") &&
                   xattr.second == QByteArray("Windows EA payload");
        });
    if (!xattrRead.ok || !xattrPresent || xattrRead.data != seedData) {
        return fail(QStringLiteral("verify embedded xattr"),
                    QStringLiteral("xattr or file payload mismatch"),
                    xattrRead.blockers);
    }
    appendProof(&proofs,
                QStringLiteral("verify embedded xattr"),
                {{QStringLiteral("name"), QStringLiteral("user.apfswin_roundtrip")},
                 {QStringLiteral("bytes"), 18}});

    const QString xattrRemovedImage = tempDir.filePath(QStringLiteral("xattr-removed.apfs"));
    sak::PartitionApfsInodeMetadataUpdate xattrRemove;
    xattrRemove.xattr_mutations.append(
        {.name = QStringLiteral("user.apfswin_roundtrip"), .remove = true});
    const auto xattrDelete = sak::PartitionApfsWriter::commitImageOnlyInodeMetadata(
        {.source_image_path = xattrImage,
         .written_image_path = xattrRemovedImage,
         .target_name = QStringLiteral("seed.txt"),
         .metadata = xattrRemove,
         .options = options});
    const auto afterXattrDelete = sak::PartitionApfsFileSystemReader::readFileFromImage(
        xattrRemovedImage, QStringLiteral("/seed.txt"), static_cast<uint64_t>(seedData.size()));
    const bool xattrStillPresent = std::any_of(
        afterXattrDelete.xattrs.cbegin(), afterXattrDelete.xattrs.cend(), [](const auto& xattr) {
            return xattr.first == QStringLiteral("user.apfswin_roundtrip");
        });
    if (!xattrDelete.ok || !afterXattrDelete.ok || xattrStillPresent ||
        afterXattrDelete.data != seedData) {
        return fail(QStringLiteral("delete embedded xattr"),
                    QStringLiteral("xattr delete or file preservation failed"),
                    xattrDelete.blockers + afterXattrDelete.blockers);
    }
    appendProof(&proofs, QStringLiteral("delete embedded xattr"));

    sak::PartitionApfsInodeMetadataUpdate protectedXattr;
    protectedXattr.xattr_mutations.append(
        {.name = QStringLiteral("com.apple.decmpfs"), .value = QByteArray("blocked")});
    const auto protectedResult = sak::PartitionApfsWriter::commitImageOnlyInodeMetadata(
        {.source_image_path = xattrRemovedImage,
         .written_image_path = tempDir.filePath(QStringLiteral("protected-xattr.apfs")),
         .target_name = QStringLiteral("seed.txt"),
         .metadata = protectedXattr,
         .options = options});
    if (protectedResult.ok || protectedResult.blockers.isEmpty()) {
        return fail(QStringLiteral("reject content-critical xattr"),
                    QStringLiteral("protected xattr mutation did not fail closed"));
    }
    appendProof(&proofs, QStringLiteral("reject content-critical xattr"));

    const QString emptyImage = tempDir.filePath(QStringLiteral("empty-for-link.apfs"));
    const auto emptyInsert = sak::PartitionApfsWriter::commitImageOnlyFileInsert(
        {.source_image_path = xattrRemovedImage,
         .written_image_path = emptyImage,
         .file_name = QStringLiteral("converted-link"),
         .options = options});
    if (!emptyInsert.ok) {
        return fail(QStringLiteral("insert empty link placeholder"),
                    QStringLiteral("commitImageOnlyFileInsert failed"),
                    emptyInsert.blockers);
    }
    const QString convertedLinkImage = tempDir.filePath(QStringLiteral("converted-link.apfs"));
    const auto convertedLink = sak::PartitionApfsWriter::commitImageOnlyInodeMetadata(
        {.source_image_path = emptyImage,
         .written_image_path = convertedLinkImage,
         .target_name = QStringLiteral("converted-link"),
         .metadata = {.update_symbolic_link_target = true,
                      .symbolic_link_target = QStringLiteral("seed.txt")},
         .options = options});
    if (!convertedLink.ok) {
        return fail(QStringLiteral("convert file to symbolic link"),
                    QStringLiteral("commitImageOnlyInodeMetadata failed"),
                    convertedLink.blockers);
    }
    if (const int rc = verifySymlink(convertedLinkImage,
                                     QStringLiteral("/converted-link"),
                                     QStringLiteral("converted-link"),
                                     QStringLiteral("seed.txt"),
                                     &proofs);
        rc != 0) {
        return rc;
    }
    const QString clearedLinkImage = tempDir.filePath(QStringLiteral("cleared-link.apfs"));
    const auto clearedLink = sak::PartitionApfsWriter::commitImageOnlyInodeMetadata(
        {.source_image_path = convertedLinkImage,
         .written_image_path = clearedLinkImage,
         .target_name = QStringLiteral("converted-link"),
         .metadata = {.update_symbolic_link_target = true},
         .options = options});
    if (!clearedLink.ok) {
        return fail(QStringLiteral("clear symbolic link"),
                    QStringLiteral("commitImageOnlyInodeMetadata failed"),
                    clearedLink.blockers);
    }
    const auto clearedListing = sak::PartitionApfsFileSystemReader::listDirectoryFromImage(
        clearedLinkImage, QStringLiteral("/"), 100);
    const auto* clearedEntry = findEntry(clearedListing, QStringLiteral("converted-link"));
    if (!clearedListing.ok || clearedEntry == nullptr || !clearedEntry->regular_file ||
        clearedEntry->symlink || clearedEntry->size_bytes != 0) {
        return fail(QStringLiteral("verify cleared symbolic link"),
                    QStringLiteral("cleared link is not an empty regular file"),
                    clearedListing.blockers);
    }
    appendProof(&proofs, QStringLiteral("verify cleared symbolic link"));

    if (insert.checkpoint_map_block == 0 || insert.superblock_block == 0 ||
        insert.checkpoint_map_block == insert.superblock_block) {
        return fail(QStringLiteral("checkpoint interruption setup"),
                    QStringLiteral("commit did not report distinct publication blocks"));
    }
    const QString beforeCheckpointMap =
        tempDir.filePath(QStringLiteral("interrupted-before-checkpoint-map.apfs"));
    quint64 changedBeforeMap = 0;
    quint64 omittedBeforeMap = 0;
    if (!buildInterruptedCheckpointImage(seedImage,
                                         insertedImage,
                                         beforeCheckpointMap,
                                         {0, insert.checkpoint_map_block, insert.superblock_block},
                                         &changedBeforeMap,
                                         &omittedBeforeMap) ||
        omittedBeforeMap != 3) {
        return fail(QStringLiteral("checkpoint interruption before map"),
                    QStringLiteral("unable to synthesize pre-publication checkpoint image"));
    }
    if (const int rc = verifyCheckpointView(beforeCheckpointMap,
                                            seedData,
                                            false,
                                            &proofs,
                                            QStringLiteral("checkpoint interruption before map"));
        rc != 0) {
        return rc;
    }

    const QString beforeSuperblock =
        tempDir.filePath(QStringLiteral("interrupted-before-superblock.apfs"));
    quint64 changedBeforeSuperblock = 0;
    quint64 omittedBeforeSuperblock = 0;
    if (!buildInterruptedCheckpointImage(seedImage,
                                         insertedImage,
                                         beforeSuperblock,
                                         {0, insert.superblock_block},
                                         &changedBeforeSuperblock,
                                         &omittedBeforeSuperblock) ||
        omittedBeforeSuperblock != 2) {
        return fail(QStringLiteral("checkpoint interruption before superblock"),
                    QStringLiteral("unable to synthesize map-only checkpoint image"));
    }
    if (const int rc = verifyCheckpointView(beforeSuperblock,
                                            seedData,
                                            false,
                                            &proofs,
                                            QStringLiteral("checkpoint interruption before superblock"));
        rc != 0) {
        return rc;
    }
    const QString beforePrimaryAnchor =
        tempDir.filePath(QStringLiteral("interrupted-before-primary-anchor.apfs"));
    quint64 changedBeforePrimaryAnchor = 0;
    quint64 omittedBeforePrimaryAnchor = 0;
    if (!buildInterruptedCheckpointImage(seedImage,
                                         insertedImage,
                                         beforePrimaryAnchor,
                                         {0},
                                         &changedBeforePrimaryAnchor,
                                         &omittedBeforePrimaryAnchor) ||
        omittedBeforePrimaryAnchor != 1) {
        return fail(QStringLiteral("checkpoint interruption before primary anchor"),
                    QStringLiteral("unable to synthesize ring-only checkpoint image"));
    }
    if (const int rc = verifyCheckpointView(
            beforePrimaryAnchor,
            seedData,
            true,
            &proofs,
            QStringLiteral("checkpoint interruption before primary anchor"));
        rc != 0) {
        return rc;
    }
    if (const int rc = verifyCheckpointView(insertedImage,
                                            seedData,
                                            true,
                                            &proofs,
                                            QStringLiteral("checkpoint publication complete"));
        rc != 0) {
        return rc;
    }
    appendProof(&proofs,
                QStringLiteral("checkpoint rollback boundary"),
                {{QStringLiteral("changed_blocks"), QString::number(changedBeforeMap)},
                 {QStringLiteral("checkpoint_map_block"),
                  QString::number(insert.checkpoint_map_block)},
                 {QStringLiteral("superblock_block"), QString::number(insert.superblock_block)},
                 {QStringLiteral("primary_anchor_block"), QStringLiteral("0")},
                 {QStringLiteral("pre_map_omitted_changed_blocks"),
                  QString::number(omittedBeforeMap)},
                 {QStringLiteral("pre_superblock_omitted_changed_blocks"),
                  QString::number(omittedBeforeSuperblock)},
                 {QStringLiteral("pre_primary_anchor_omitted_changed_blocks"),
                  QString::number(omittedBeforePrimaryAnchor)},
                 {QStringLiteral("map_phase_changed_blocks"),
                  QString::number(changedBeforeSuperblock)},
                 {QStringLiteral("primary_anchor_phase_changed_blocks"),
                  QString::number(changedBeforePrimaryAnchor)},
                 {QStringLiteral("old_or_new_only"), true}});

    const QString replacedImage = tempDir.filePath(QStringLiteral("replaced.apfs"));
    const auto replace = sak::PartitionApfsWriter::commitImageOnlyFileWrite(
        {.source_image_path = insertedImage,
         .written_image_path = replacedImage,
         .file_name = QStringLiteral("seed.txt"),
         .file_data = replacementData,
         .options = options});
    if (!replace.ok) {
        return fail(QStringLiteral("commit file replace"),
                    QStringLiteral("commitImageOnlyFileWrite failed"),
                    replace.blockers);
    }
    appendProof(&proofs,
                QStringLiteral("commit file replace"),
                {{QStringLiteral("previous_xid"), QString::number(replace.previous_xid)},
                 {QStringLiteral("new_xid"), QString::number(replace.new_xid)}});
    if (const int rc =
            verifyRead(replacedImage, QStringLiteral("/seed.txt"), replacementData, &proofs);
        rc != 0) {
        return rc;
    }

    const QString renamedImage = tempDir.filePath(QStringLiteral("renamed.apfs"));
    const auto rename = sak::PartitionApfsWriter::commitImageOnlyFileRename(
        {.source_image_path = replacedImage,
         .written_image_path = renamedImage,
         .file_name = QStringLiteral("inserted.txt"),
         .new_file_name = QStringLiteral("renamed.txt"),
         .options = options});
    if (!rename.ok) {
        return fail(QStringLiteral("commit file rename"),
                    QStringLiteral("commitImageOnlyFileRename failed"),
                    rename.blockers);
    }
    appendProof(&proofs,
                QStringLiteral("commit file rename"),
                {{QStringLiteral("previous_xid"), QString::number(rename.previous_xid)},
                 {QStringLiteral("new_xid"), QString::number(rename.new_xid)}});
    if (const int rc =
            verifyRead(renamedImage, QStringLiteral("/renamed.txt"), insertedData, &proofs);
        rc != 0) {
        return rc;
    }

    const QString deletedImage = tempDir.filePath(QStringLiteral("deleted.apfs"));
    const auto deleted = sak::PartitionApfsWriter::commitImageOnlyFileDelete(
        {.source_image_path = renamedImage,
         .written_image_path = deletedImage,
         .file_name = QStringLiteral("seed.txt"),
         .options = options});
    if (!deleted.ok) {
        return fail(QStringLiteral("commit file delete"),
                    QStringLiteral("commitImageOnlyFileDelete failed"),
                    deleted.blockers);
    }
    appendProof(&proofs,
                QStringLiteral("commit file delete"),
                {{QStringLiteral("previous_xid"), QString::number(deleted.previous_xid)},
                 {QStringLiteral("new_xid"), QString::number(deleted.new_xid)}});
    const auto deletedListing =
        sak::PartitionApfsFileSystemReader::listDirectoryFromImage(deletedImage, QStringLiteral("/"), 20);
    if (!deletedListing.ok) {
        return fail(QStringLiteral("list deleted root"),
                    QStringLiteral("listDirectoryFromImage failed"),
                    deletedListing.blockers);
    }
    if (rootHas(deletedListing, QStringLiteral("seed.txt")) ||
        !rootHas(deletedListing, QStringLiteral("renamed.txt"))) {
        return fail(QStringLiteral("list deleted root"), QStringLiteral("delete result mismatch"));
    }
    appendProof(&proofs,
                QStringLiteral("list deleted root"),
                {{QStringLiteral("entries"), deletedListing.entries.size()}});

    const QString directoryImage = tempDir.filePath(QStringLiteral("directory.apfs"));
    const auto directoryCreate = sak::PartitionApfsWriter::commitImageOnlyDirectoryCreate(
        {.source_image_path = deletedImage,
         .written_image_path = directoryImage,
         .directory_name = QStringLiteral("Proof Folder"),
         .options = options});
    if (!directoryCreate.ok) {
        return fail(QStringLiteral("commit directory create"),
                    QStringLiteral("commitImageOnlyDirectoryCreate failed"),
                    directoryCreate.blockers);
    }
    appendProof(&proofs,
                QStringLiteral("commit directory create"),
                {{QStringLiteral("previous_xid"), QString::number(directoryCreate.previous_xid)},
                 {QStringLiteral("new_xid"), QString::number(directoryCreate.new_xid)}});

    const QByteArray childData("APFS for Windows copied-core child write proof");
    const QString childImage = tempDir.filePath(QStringLiteral("child.apfs"));
    const auto childWrite = sak::PartitionApfsWriter::commitImageOnlyDirectoryChildWrite(
        {.source_image_path = directoryImage,
         .written_image_path = childImage,
         .directory_name = QStringLiteral("Proof Folder"),
         .file_name = QStringLiteral("child.txt"),
         .file_data = childData,
         .options = options});
    if (!childWrite.ok) {
        return fail(QStringLiteral("commit directory child write"),
                    QStringLiteral("commitImageOnlyDirectoryChildWrite failed"),
                    childWrite.blockers);
    }
    appendProof(&proofs,
                QStringLiteral("commit directory child write"),
                {{QStringLiteral("previous_xid"), QString::number(childWrite.previous_xid)},
                 {QStringLiteral("new_xid"), QString::number(childWrite.new_xid)}});
    if (const int rc =
            verifyRead(childImage, QStringLiteral("/Proof Folder/child.txt"), childData, &proofs);
        rc != 0) {
        return rc;
    }

    const QString childRenamedImage = tempDir.filePath(QStringLiteral("child-renamed.apfs"));
    const auto childRename = sak::PartitionApfsWriter::commitImageOnlyDirectoryChildRename(
        {.source_image_path = childImage,
         .written_image_path = childRenamedImage,
         .directory_name = QStringLiteral("Proof Folder"),
         .file_name = QStringLiteral("child.txt"),
         .new_file_name = QStringLiteral("renamed-child.txt"),
         .options = options});
    if (!childRename.ok) {
        return fail(QStringLiteral("commit directory child rename"),
                    QStringLiteral("commitImageOnlyDirectoryChildRename failed"),
                    childRename.blockers);
    }
    appendProof(&proofs,
                QStringLiteral("commit directory child rename"),
                {{QStringLiteral("previous_xid"), QString::number(childRename.previous_xid)},
                 {QStringLiteral("new_xid"), QString::number(childRename.new_xid)}});
    if (const int rc = verifyRead(childRenamedImage,
                                  QStringLiteral("/Proof Folder/renamed-child.txt"),
                                  childData,
                                  &proofs);
        rc != 0) {
        return rc;
    }

    const QString movedImage = tempDir.filePath(QStringLiteral("child-moved-root.apfs"));
    const auto moveToRoot = sak::PartitionApfsWriter::commitImageOnlyFileMove(
        {.source_image_path = childRenamedImage,
         .written_image_path = movedImage,
         .source_directory_name = QStringLiteral("Proof Folder"),
         .file_name = QStringLiteral("renamed-child.txt"),
         .destination_directory_name = QString(),
         .new_file_name = QStringLiteral("child-root.txt"),
         .options = options});
    if (!moveToRoot.ok) {
        return fail(QStringLiteral("commit child move to root"),
                    QStringLiteral("commitImageOnlyFileMove failed"),
                    moveToRoot.blockers);
    }
    appendProof(&proofs,
                QStringLiteral("commit child move to root"),
                {{QStringLiteral("previous_xid"), QString::number(moveToRoot.previous_xid)},
                 {QStringLiteral("new_xid"), QString::number(moveToRoot.new_xid)}});
    if (const int rc = verifyRead(movedImage, QStringLiteral("/child-root.txt"), childData, &proofs);
        rc != 0) {
        return rc;
    }

    const QString directoryDeletedImage = tempDir.filePath(QStringLiteral("directory-deleted.apfs"));
    const auto directoryDelete = sak::PartitionApfsWriter::commitImageOnlyDirectoryDelete(
        {.source_image_path = movedImage,
         .written_image_path = directoryDeletedImage,
         .directory_name = QStringLiteral("Proof Folder"),
         .options = options});
    if (!directoryDelete.ok) {
        return fail(QStringLiteral("commit directory delete"),
                    QStringLiteral("commitImageOnlyDirectoryDelete failed"),
                    directoryDelete.blockers);
    }
    appendProof(&proofs,
                QStringLiteral("commit directory delete"),
                {{QStringLiteral("previous_xid"), QString::number(directoryDelete.previous_xid)},
                 {QStringLiteral("new_xid"), QString::number(directoryDelete.new_xid)}});
    const auto directoryDeletedListing =
        sak::PartitionApfsFileSystemReader::listDirectoryFromImage(
            directoryDeletedImage, QStringLiteral("/"), 20);
    if (!directoryDeletedListing.ok) {
        return fail(QStringLiteral("list directory-deleted root"),
                    QStringLiteral("listDirectoryFromImage failed"),
                    directoryDeletedListing.blockers);
    }
    if (rootHas(directoryDeletedListing, QStringLiteral("Proof Folder"), true) ||
        !rootHas(directoryDeletedListing, QStringLiteral("child-root.txt")) ||
        !rootHas(directoryDeletedListing, QStringLiteral("renamed.txt"))) {
        return fail(QStringLiteral("list directory-deleted root"),
                    QStringLiteral("directory mutation result mismatch"));
    }
    appendProof(&proofs,
                QStringLiteral("list directory-deleted root"),
                {{QStringLiteral("entries"), directoryDeletedListing.entries.size()}});

    const QString nestedRootImage = tempDir.filePath(QStringLiteral("nested-root.apfs"));
    const auto nestedRootCreate = sak::PartitionApfsWriter::commitImageOnlyDirectoryCreate(
        {.source_image_path = directoryDeletedImage,
         .written_image_path = nestedRootImage,
         .directory_name = QStringLiteral("docs"),
         .options = options});
    if (!nestedRootCreate.ok) {
        return fail(QStringLiteral("commit nested root create"),
                    QStringLiteral("commitImageOnlyDirectoryCreate failed"),
                    nestedRootCreate.blockers);
    }
    appendProof(&proofs,
                QStringLiteral("commit nested root create"),
                {{QStringLiteral("previous_xid"), QString::number(nestedRootCreate.previous_xid)},
                 {QStringLiteral("new_xid"), QString::number(nestedRootCreate.new_xid)}});

    const QString nestedChildImage = tempDir.filePath(QStringLiteral("nested-child.apfs"));
    const auto nestedChildCreate = sak::PartitionApfsWriter::commitImageOnlyDirectoryCreate(
        {.source_image_path = nestedRootImage,
         .written_image_path = nestedChildImage,
         .directory_name = QStringLiteral("sub"),
         .parent_directory_path = QStringLiteral("/docs"),
         .options = options});
    if (!nestedChildCreate.ok) {
        return fail(QStringLiteral("commit nested child create"),
                    QStringLiteral("commitImageOnlyDirectoryCreate failed"),
                    nestedChildCreate.blockers);
    }
    appendProof(&proofs,
                QStringLiteral("commit nested child create"),
                {{QStringLiteral("previous_xid"), QString::number(nestedChildCreate.previous_xid)},
                 {QStringLiteral("new_xid"), QString::number(nestedChildCreate.new_xid)}});

    const QByteArray nestedPathData("APFS arbitrary nested write proof");
    const QString nestedWriteImage = tempDir.filePath(QStringLiteral("nested-write.apfs"));
    const auto nestedWrite = sak::PartitionApfsWriter::commitImageOnlyFileWrite(
        {.source_image_path = nestedChildImage,
         .written_image_path = nestedWriteImage,
         .file_name = QStringLiteral("deep.txt"),
         .file_data = nestedPathData,
         .parent_directory_path = QStringLiteral("/docs/sub"),
         .options = options});
    if (!nestedWrite.ok) {
        return fail(QStringLiteral("commit nested arbitrary file write"),
                    QStringLiteral("commitImageOnlyFileWrite failed"),
                    nestedWrite.blockers);
    }
    appendProof(&proofs,
                QStringLiteral("commit nested arbitrary file write"),
                {{QStringLiteral("previous_xid"), QString::number(nestedWrite.previous_xid)},
                 {QStringLiteral("new_xid"), QString::number(nestedWrite.new_xid)}});
    if (const int rc = verifyRead(nestedWriteImage,
                                  QStringLiteral("/docs/sub/deep.txt"),
                                  nestedPathData,
                                  &proofs);
        rc != 0) {
        return rc;
    }

    const QString nestedRenameImage = tempDir.filePath(QStringLiteral("nested-rename.apfs"));
    const auto nestedRename = sak::PartitionApfsWriter::commitImageOnlyFileRename(
        {.source_image_path = nestedWriteImage,
         .written_image_path = nestedRenameImage,
         .file_name = QStringLiteral("deep.txt"),
         .new_file_name = QStringLiteral("deep-renamed.txt"),
         .parent_directory_path = QStringLiteral("/docs/sub"),
         .options = options});
    if (!nestedRename.ok) {
        return fail(QStringLiteral("commit nested arbitrary file rename"),
                    QStringLiteral("commitImageOnlyFileRename failed"),
                    nestedRename.blockers);
    }
    if (const int rc = verifyRead(nestedRenameImage,
                                  QStringLiteral("/docs/sub/deep-renamed.txt"),
                                  nestedPathData,
                                  &proofs);
        rc != 0) {
        return rc;
    }

    const QString nestedDeleteImage = tempDir.filePath(QStringLiteral("nested-delete.apfs"));
    const auto nestedDelete = sak::PartitionApfsWriter::commitImageOnlyFileDelete(
        {.source_image_path = nestedRenameImage,
         .written_image_path = nestedDeleteImage,
         .file_name = QStringLiteral("deep-renamed.txt"),
         .parent_directory_path = QStringLiteral("/docs/sub"),
         .options = options});
    if (!nestedDelete.ok) {
        return fail(QStringLiteral("commit nested arbitrary file delete"),
                    QStringLiteral("commitImageOnlyFileDelete failed"),
                    nestedDelete.blockers);
    }

    const QString nestedDirRenamedImage = tempDir.filePath(QStringLiteral("nested-dir-renamed.apfs"));
    const auto nestedDirRename = sak::PartitionApfsWriter::commitImageOnlyDirectoryRename(
        {.source_image_path = nestedDeleteImage,
         .written_image_path = nestedDirRenamedImage,
         .directory_name = QStringLiteral("sub"),
         .new_directory_name = QStringLiteral("sub-renamed"),
         .parent_directory_path = QStringLiteral("/docs"),
         .new_parent_directory_path = QStringLiteral("/docs"),
         .options = options});
    if (!nestedDirRename.ok) {
        return fail(QStringLiteral("commit nested directory rename"),
                    QStringLiteral("commitImageOnlyDirectoryRename failed"),
                    nestedDirRename.blockers);
    }
    const auto renamedNestedListing = sak::PartitionApfsFileSystemReader::listDirectoryFromImage(
        nestedDirRenamedImage, QStringLiteral("/docs"), 20);
    if (!renamedNestedListing.ok ||
        !rootHas(renamedNestedListing, QStringLiteral("sub-renamed"), true)) {
        return fail(QStringLiteral("list nested directory rename"),
                    QStringLiteral("renamed nested directory missing"),
                    renamedNestedListing.blockers);
    }

    const QString nestedDirDeletedImage = tempDir.filePath(QStringLiteral("nested-dir-deleted.apfs"));
    const auto nestedDirDelete = sak::PartitionApfsWriter::commitImageOnlyDirectoryDelete(
        {.source_image_path = nestedDirRenamedImage,
         .written_image_path = nestedDirDeletedImage,
         .directory_name = QStringLiteral("sub-renamed"),
         .parent_directory_path = QStringLiteral("/docs"),
         .options = options});
    if (!nestedDirDelete.ok) {
        return fail(QStringLiteral("commit nested directory delete"),
                    QStringLiteral("commitImageOnlyDirectoryDelete failed"),
                    nestedDirDelete.blockers);
    }

    const QString docsDeletedImage = tempDir.filePath(QStringLiteral("docs-deleted.apfs"));
    const auto docsDelete = sak::PartitionApfsWriter::commitImageOnlyDirectoryDelete(
        {.source_image_path = nestedDirDeletedImage,
         .written_image_path = docsDeletedImage,
         .directory_name = QStringLiteral("docs"),
         .options = options});
    if (!docsDelete.ok) {
        return fail(QStringLiteral("commit docs directory delete"),
                    QStringLiteral("commitImageOnlyDirectoryDelete failed"),
                    docsDelete.blockers);
    }
    appendProof(&proofs,
                QStringLiteral("commit arbitrary nested file and directory mutations"),
                QJsonObject{{QStringLiteral("image"), docsDeletedImage}});

    const QString renameParentImage = tempDir.filePath(QStringLiteral("rename-parent.apfs"));
    const auto renameParentCreate = sak::PartitionApfsWriter::commitImageOnlyDirectoryCreate(
        {.source_image_path = docsDeletedImage,
         .written_image_path = renameParentImage,
         .directory_name = QStringLiteral("Rename Parent"),
         .options = options});
    if (!renameParentCreate.ok) {
        return fail(QStringLiteral("commit rename parent create"),
                    QStringLiteral("commitImageOnlyDirectoryCreate failed"),
                    renameParentCreate.blockers);
    }
    const QByteArray directoryMoveData("APFS directory file move proof");
    const QString renameFileImage = tempDir.filePath(QStringLiteral("rename-file.apfs"));
    const auto renameFileWrite = sak::PartitionApfsWriter::commitImageOnlyDirectoryChildWrite(
        {.source_image_path = renameParentImage,
         .written_image_path = renameFileImage,
         .directory_name = QStringLiteral("Rename Parent"),
         .file_name = QStringLiteral("proof.txt"),
         .file_data = directoryMoveData,
         .options = options});
    if (!renameFileWrite.ok) {
        return fail(QStringLiteral("commit rename child file write"),
                    QStringLiteral("commitImageOnlyDirectoryChildWrite failed"),
                    renameFileWrite.blockers);
    }
    const QString moveParentImage = tempDir.filePath(QStringLiteral("move-parent.apfs"));
    const auto moveParentCreate = sak::PartitionApfsWriter::commitImageOnlyDirectoryCreate(
        {.source_image_path = renameFileImage,
         .written_image_path = moveParentImage,
         .directory_name = QStringLiteral("Move Parent"),
         .options = options});
    if (!moveParentCreate.ok) {
        return fail(QStringLiteral("commit move parent create"),
                    QStringLiteral("commitImageOnlyDirectoryCreate failed"),
                    moveParentCreate.blockers);
    }
    const QString movedFileImage = tempDir.filePath(QStringLiteral("moved-file.apfs"));
    const auto fileMove = sak::PartitionApfsWriter::commitImageOnlyFileMove(
        {.source_image_path = moveParentImage,
         .written_image_path = movedFileImage,
         .source_directory_name = QStringLiteral("Rename Parent"),
         .file_name = QStringLiteral("proof.txt"),
         .destination_directory_name = QStringLiteral("Move Parent"),
         .new_file_name = QStringLiteral("proof-moved.txt"),
         .options = options});
    if (!fileMove.ok) {
        return fail(QStringLiteral("commit directory file move"),
                    QStringLiteral("commitImageOnlyFileMove failed"),
                    fileMove.blockers);
    }
    appendProof(&proofs,
                QStringLiteral("commit directory file move"),
                QJsonObject{{QStringLiteral("previous_xid"), QString::number(fileMove.previous_xid)},
                            {QStringLiteral("new_xid"), QString::number(fileMove.new_xid)}});
    if (const int rc = verifyRead(movedFileImage,
                                  QStringLiteral("/Move Parent/proof-moved.txt"),
                                  directoryMoveData,
                                  &proofs);
        rc != 0) {
        return rc;
    }
    const QString movedFileDeletedImage = tempDir.filePath(QStringLiteral("moved-file-deleted.apfs"));
    const auto movedFileDelete = sak::PartitionApfsWriter::commitImageOnlyDirectoryChildDelete(
        {.source_image_path = movedFileImage,
         .written_image_path = movedFileDeletedImage,
         .directory_name = QStringLiteral("Move Parent"),
         .file_name = QStringLiteral("proof-moved.txt"),
         .options = options});
    if (!movedFileDelete.ok) {
        return fail(QStringLiteral("commit moved directory file delete"),
                    QStringLiteral("commitImageOnlyDirectoryChildDelete failed"),
                    movedFileDelete.blockers);
    }
    const QString moveParentDeletedImage = tempDir.filePath(QStringLiteral("move-parent-deleted.apfs"));
    const auto moveParentDelete = sak::PartitionApfsWriter::commitImageOnlyDirectoryDelete(
        {.source_image_path = movedFileDeletedImage,
         .written_image_path = moveParentDeletedImage,
         .directory_name = QStringLiteral("Move Parent"),
         .options = options});
    if (!moveParentDelete.ok) {
        return fail(QStringLiteral("commit move parent delete"),
                    QStringLiteral("commitImageOnlyDirectoryDelete failed"),
                    moveParentDelete.blockers);
    }
    const QString renameParentDeletedImage =
        tempDir.filePath(QStringLiteral("rename-parent-deleted.apfs"));
    const auto renameParentDelete = sak::PartitionApfsWriter::commitImageOnlyDirectoryDelete(
        {.source_image_path = moveParentDeletedImage,
         .written_image_path = renameParentDeletedImage,
         .directory_name = QStringLiteral("Rename Parent"),
         .options = options});
    if (!renameParentDelete.ok) {
        return fail(QStringLiteral("commit rename parent delete"),
                    QStringLiteral("commitImageOnlyDirectoryDelete failed"),
                    renameParentDelete.blockers);
    }
    appendProof(&proofs,
                QStringLiteral("clean directory file-move proof"),
                QJsonObject{{QStringLiteral("image"), renameParentDeletedImage}});

    const QByteArray largeData = largeProofData();
    sak::PartitionApfsWriteOptions largeOptions = options;
    largeOptions.max_payload_bytes = static_cast<uint64_t>(largeData.size());
    const QString largeFileImage = tempDir.filePath(QStringLiteral("large-file.apfs"));
    const auto largeFile = sak::PartitionApfsWriter::commitImageOnlyFileInsert(
        {.source_image_path = renameParentDeletedImage,
         .written_image_path = largeFileImage,
         .file_name = QStringLiteral("large.bin"),
         .file_data = largeData,
         .options = largeOptions});
    if (!largeFile.ok) {
        return fail(QStringLiteral("commit large file insert"),
                    QStringLiteral("commitImageOnlyFileInsert failed"),
                    largeFile.blockers);
    }
    appendProof(&proofs,
                QStringLiteral("commit large file insert"),
                {{QStringLiteral("bytes"), QString::number(largeData.size())},
                 {QStringLiteral("sha256"), sha256Hex(largeData)}});
    if (const int rc = verifyRead(largeFileImage, QStringLiteral("/large.bin"), largeData, &proofs);
        rc != 0) {
        return rc;
    }

    sak::PartitionApfsWriter::setRawDeviceTargetPredicateForTesting(
        [largeFileImage](const QString& path) {
            return QFileInfo(path).absoluteFilePath() == QFileInfo(largeFileImage).absoluteFilePath();
        });
    const uint64_t largeTargetBytes = static_cast<uint64_t>(QFileInfo(largeFileImage).size());
    const auto rawOptions = certifiedRawOptions(static_cast<uint64_t>(largeData.size()));
    sak::PartitionApfsRawDirectoryMutationCommitRequest rawCreateRequest;
    rawCreateRequest.target_path = largeFileImage;
    rawCreateRequest.target_container_bytes = largeTargetBytes;
    rawCreateRequest.directory_name = QStringLiteral("Raw Large Metadata");
    rawCreateRequest.target_mutation_confirmed = true;
    rawCreateRequest.allow_raw_device_target = true;
    rawCreateRequest.options = rawOptions;
    const auto rawDirectoryCreate =
        sak::PartitionApfsWriter::commitRawDirectoryCreate(rawCreateRequest);
    if (!rawDirectoryCreate.ok) {
        sak::PartitionApfsWriter::setRawDeviceTargetPredicateForTesting({});
        return fail(QStringLiteral("commit raw large metadata directory create"),
                    QStringLiteral("commitRawDirectoryCreate failed"),
                    rawDirectoryCreate.blockers);
    }
    appendProof(&proofs,
                QStringLiteral("commit raw large metadata directory create"),
                {{QStringLiteral("previous_xid"), QString::number(rawDirectoryCreate.previous_xid)},
                 {QStringLiteral("new_xid"), QString::number(rawDirectoryCreate.new_xid)}});

    sak::PartitionApfsRawDirectoryMutationCommitRequest rawSubCreateRequest;
    rawSubCreateRequest.target_path = largeFileImage;
    rawSubCreateRequest.target_container_bytes = largeTargetBytes;
    rawSubCreateRequest.directory_name = QStringLiteral("Raw Sub");
    rawSubCreateRequest.parent_directory_path = QStringLiteral("/Raw Large Metadata");
    rawSubCreateRequest.target_mutation_confirmed = true;
    rawSubCreateRequest.allow_raw_device_target = true;
    rawSubCreateRequest.options = rawOptions;
    const auto rawSubCreate = sak::PartitionApfsWriter::commitRawDirectoryCreate(rawSubCreateRequest);
    if (!rawSubCreate.ok) {
        sak::PartitionApfsWriter::setRawDeviceTargetPredicateForTesting({});
        return fail(QStringLiteral("commit raw nested directory create"),
                    QStringLiteral("commitRawDirectoryCreate failed"),
                    rawSubCreate.blockers);
    }

    sak::PartitionApfsRawDirectoryRenameCommitRequest rawSubRenameRequest;
    rawSubRenameRequest.target_path = largeFileImage;
    rawSubRenameRequest.target_container_bytes = largeTargetBytes;
    rawSubRenameRequest.directory_name = QStringLiteral("Raw Sub");
    rawSubRenameRequest.new_directory_name = QStringLiteral("Raw Sub Renamed");
    rawSubRenameRequest.parent_directory_path = QStringLiteral("/Raw Large Metadata");
    rawSubRenameRequest.new_parent_directory_path = QStringLiteral("/Raw Large Metadata");
    rawSubRenameRequest.target_mutation_confirmed = true;
    rawSubRenameRequest.allow_raw_device_target = true;
    rawSubRenameRequest.options = rawOptions;
    const auto rawSubRename =
        sak::PartitionApfsWriter::commitRawDirectoryRename(rawSubRenameRequest);
    if (!rawSubRename.ok) {
        sak::PartitionApfsWriter::setRawDeviceTargetPredicateForTesting({});
        return fail(QStringLiteral("commit raw nested directory rename"),
                    QStringLiteral("commitRawDirectoryRename failed"),
                    rawSubRename.blockers);
    }

    const QByteArray rawStreamData("APFS raw streaming nested file proof");
    const QString rawStreamPath = tempDir.filePath(QStringLiteral("raw-stream-payload.bin"));
    QFile rawStreamFile(rawStreamPath);
    if (!rawStreamFile.open(QIODevice::WriteOnly) ||
        rawStreamFile.write(rawStreamData) != rawStreamData.size()) {
        sak::PartitionApfsWriter::setRawDeviceTargetPredicateForTesting({});
        return fail(QStringLiteral("write raw stream payload"),
                    QStringLiteral("temporary payload write failed"));
    }
    rawStreamFile.close();

    sak::PartitionApfsRawFileInsertCommitRequest rawFileWriteRequest;
    rawFileWriteRequest.target_path = largeFileImage;
    rawFileWriteRequest.target_container_bytes = largeTargetBytes;
    rawFileWriteRequest.file_name = QStringLiteral("stream.bin");
    rawFileWriteRequest.file_data_path = rawStreamPath;
    rawFileWriteRequest.file_data_stream_size = static_cast<uint64_t>(rawStreamData.size());
    rawFileWriteRequest.parent_directory_path =
        QStringLiteral("/Raw Large Metadata/Raw Sub Renamed");
    rawFileWriteRequest.target_mutation_confirmed = true;
    rawFileWriteRequest.allow_raw_device_target = true;
    rawFileWriteRequest.options = rawOptions;
    const auto rawFileWrite = sak::PartitionApfsWriter::commitRawFileWrite(rawFileWriteRequest);
    if (!rawFileWrite.ok) {
        sak::PartitionApfsWriter::setRawDeviceTargetPredicateForTesting({});
        return fail(QStringLiteral("commit raw nested stream file write"),
                    QStringLiteral("commitRawFileWrite failed"),
                    rawFileWrite.blockers);
    }
    if (const int rc = verifyRead(largeFileImage,
                                  QStringLiteral("/Raw Large Metadata/Raw Sub Renamed/stream.bin"),
                                  rawStreamData,
                                  &proofs);
        rc != 0) {
        sak::PartitionApfsWriter::setRawDeviceTargetPredicateForTesting({});
        return rc;
    }

    sak::PartitionApfsRawFileRenameCommitRequest rawFileRenameRequest;
    rawFileRenameRequest.target_path = largeFileImage;
    rawFileRenameRequest.target_container_bytes = largeTargetBytes;
    rawFileRenameRequest.file_name = QStringLiteral("stream.bin");
    rawFileRenameRequest.new_file_name = QStringLiteral("stream-renamed.bin");
    rawFileRenameRequest.parent_directory_path =
        QStringLiteral("/Raw Large Metadata/Raw Sub Renamed");
    rawFileRenameRequest.target_mutation_confirmed = true;
    rawFileRenameRequest.allow_raw_device_target = true;
    rawFileRenameRequest.options = rawOptions;
    const auto rawFileRename =
        sak::PartitionApfsWriter::commitRawFileRename(rawFileRenameRequest);
    if (!rawFileRename.ok) {
        sak::PartitionApfsWriter::setRawDeviceTargetPredicateForTesting({});
        return fail(QStringLiteral("commit raw nested file rename"),
                    QStringLiteral("commitRawFileRename failed"),
                    rawFileRename.blockers);
    }

    sak::PartitionApfsRawFileMoveCommitRequest rawFileMoveRequest;
    rawFileMoveRequest.target_path = largeFileImage;
    rawFileMoveRequest.target_container_bytes = largeTargetBytes;
    rawFileMoveRequest.source_directory_name =
        QStringLiteral("/Raw Large Metadata/Raw Sub Renamed");
    rawFileMoveRequest.file_name = QStringLiteral("stream-renamed.bin");
    rawFileMoveRequest.destination_directory_name.clear();
    rawFileMoveRequest.new_file_name = QStringLiteral("stream-root.bin");
    rawFileMoveRequest.target_mutation_confirmed = true;
    rawFileMoveRequest.allow_raw_device_target = true;
    rawFileMoveRequest.options = rawOptions;
    const auto rawFileMove = sak::PartitionApfsWriter::commitRawFileMove(rawFileMoveRequest);
    if (!rawFileMove.ok) {
        sak::PartitionApfsWriter::setRawDeviceTargetPredicateForTesting({});
        return fail(QStringLiteral("commit raw nested file move"),
                    QStringLiteral("commitRawFileMove failed"),
                    rawFileMove.blockers);
    }
    if (const int rc =
            verifyRead(largeFileImage, QStringLiteral("/stream-root.bin"), rawStreamData, &proofs);
        rc != 0) {
        sak::PartitionApfsWriter::setRawDeviceTargetPredicateForTesting({});
        return rc;
    }

    sak::PartitionApfsRawFileDeleteCommitRequest rawFileDeleteRequest;
    rawFileDeleteRequest.target_path = largeFileImage;
    rawFileDeleteRequest.target_container_bytes = largeTargetBytes;
    rawFileDeleteRequest.file_name = QStringLiteral("stream-root.bin");
    rawFileDeleteRequest.target_mutation_confirmed = true;
    rawFileDeleteRequest.allow_raw_device_target = true;
    rawFileDeleteRequest.options = rawOptions;
    const auto rawFileDelete =
        sak::PartitionApfsWriter::commitRawFileDelete(rawFileDeleteRequest);
    if (!rawFileDelete.ok) {
        sak::PartitionApfsWriter::setRawDeviceTargetPredicateForTesting({});
        return fail(QStringLiteral("commit raw moved file delete"),
                    QStringLiteral("commitRawFileDelete failed"),
                    rawFileDelete.blockers);
    }

    sak::PartitionApfsRawDirectoryMutationCommitRequest rawSubDeleteRequest;
    rawSubDeleteRequest.target_path = largeFileImage;
    rawSubDeleteRequest.target_container_bytes = largeTargetBytes;
    rawSubDeleteRequest.directory_name = QStringLiteral("Raw Sub Renamed");
    rawSubDeleteRequest.parent_directory_path = QStringLiteral("/Raw Large Metadata");
    rawSubDeleteRequest.target_mutation_confirmed = true;
    rawSubDeleteRequest.allow_raw_device_target = true;
    rawSubDeleteRequest.options = rawOptions;
    const auto rawSubDelete =
        sak::PartitionApfsWriter::commitRawDirectoryDelete(rawSubDeleteRequest);
    if (!rawSubDelete.ok) {
        sak::PartitionApfsWriter::setRawDeviceTargetPredicateForTesting({});
        return fail(QStringLiteral("commit raw nested directory delete"),
                    QStringLiteral("commitRawDirectoryDelete failed"),
                    rawSubDelete.blockers);
    }

    sak::PartitionApfsRawDirectoryRenameCommitRequest rawParentRenameRequest;
    rawParentRenameRequest.target_path = largeFileImage;
    rawParentRenameRequest.target_container_bytes = largeTargetBytes;
    rawParentRenameRequest.directory_name = QStringLiteral("Raw Large Metadata");
    rawParentRenameRequest.new_directory_name = QStringLiteral("Raw Large Metadata Renamed");
    rawParentRenameRequest.target_mutation_confirmed = true;
    rawParentRenameRequest.allow_raw_device_target = true;
    rawParentRenameRequest.options = rawOptions;
    const auto rawParentRename =
        sak::PartitionApfsWriter::commitRawDirectoryRename(rawParentRenameRequest);
    if (!rawParentRename.ok) {
        sak::PartitionApfsWriter::setRawDeviceTargetPredicateForTesting({});
        return fail(QStringLiteral("commit raw parent directory rename"),
                    QStringLiteral("commitRawDirectoryRename failed"),
                    rawParentRename.blockers);
    }

    if (const int rc = verifyRead(largeFileImage, QStringLiteral("/large.bin"), largeData, &proofs);
        rc != 0) {
        sak::PartitionApfsWriter::setRawDeviceTargetPredicateForTesting({});
        return rc;
    }

    sak::PartitionApfsRawDirectoryMutationCommitRequest rawDeleteRequest;
    rawDeleteRequest.target_path = largeFileImage;
    rawDeleteRequest.target_container_bytes = largeTargetBytes;
    rawDeleteRequest.directory_name = QStringLiteral("Raw Large Metadata Renamed");
    rawDeleteRequest.target_mutation_confirmed = true;
    rawDeleteRequest.allow_raw_device_target = true;
    rawDeleteRequest.options = rawOptions;
    const auto rawDirectoryDelete =
        sak::PartitionApfsWriter::commitRawDirectoryDelete(rawDeleteRequest);
    sak::PartitionApfsWriter::setRawDeviceTargetPredicateForTesting({});
    if (!rawDirectoryDelete.ok) {
        return fail(QStringLiteral("commit raw large metadata directory delete"),
                    QStringLiteral("commitRawDirectoryDelete failed"),
                    rawDirectoryDelete.blockers);
    }
    appendProof(&proofs,
                QStringLiteral("commit raw large metadata directory delete"),
                {{QStringLiteral("previous_xid"), QString::number(rawDirectoryDelete.previous_xid)},
                 {QStringLiteral("new_xid"), QString::number(rawDirectoryDelete.new_xid)}});
    if (const int rc = verifyRead(largeFileImage, QStringLiteral("/large.bin"), largeData, &proofs);
        rc != 0) {
        return rc;
    }
    const auto rawDeletedListing =
        sak::PartitionApfsFileSystemReader::listDirectoryFromImage(
            largeFileImage, QStringLiteral("/"), 40);
    if (!rawDeletedListing.ok) {
        return fail(QStringLiteral("list raw large metadata root"),
                    QStringLiteral("listDirectoryFromImage failed"),
                    rawDeletedListing.blockers);
    }
    if (rootHas(rawDeletedListing, QStringLiteral("Raw Large Metadata"), true) ||
        rootHas(rawDeletedListing, QStringLiteral("Raw Large Metadata Renamed"), true) ||
        !rootHas(rawDeletedListing, QStringLiteral("large.bin"))) {
        return fail(QStringLiteral("list raw large metadata root"),
                    QStringLiteral("raw metadata mutation result mismatch"));
    }
    appendProof(&proofs,
                QStringLiteral("list raw large metadata root"),
                {{QStringLiteral("entries"), rawDeletedListing.entries.size()}});

    if (!makeImagePath.isEmpty()) {
        const QFileInfo imageInfo(makeImagePath);
        QDir().mkpath(imageInfo.absolutePath());
        QFile::remove(makeImagePath);
        if (!QFile::copy(deletedImage, makeImagePath)) {
            return fail(QStringLiteral("make image"), QStringLiteral("unable to copy final image"));
        }
        appendProof(&proofs,
                    QStringLiteral("make image"),
                    {{QStringLiteral("path"), makeImagePath}});
    }

    if (!makeLargeImagePath.isEmpty()) {
        const QFileInfo imageInfo(makeLargeImagePath);
        QDir().mkpath(imageInfo.absolutePath());
        QFile::remove(makeLargeImagePath);
        if (!QFile::copy(largeFileImage, makeLargeImagePath)) {
            return fail(QStringLiteral("make large image"),
                        QStringLiteral("unable to copy large-file image"));
        }
        appendProof(&proofs,
                    QStringLiteral("make large image"),
                    {{QStringLiteral("path"), makeLargeImagePath},
                     {QStringLiteral("large_file_bytes"),
                      QString::number(largeData.size())},
                     {QStringLiteral("large_file_sha256"), sha256Hex(largeData)}});
    }

    QJsonObject out{{QStringLiteral("tool"), QStringLiteral("apfs_core_selftest")},
                    {QStringLiteral("ok"), true},
                    {QStringLiteral("proofs"), proofs}};
    QTextStream(stdout) << QJsonDocument(out).toJson(QJsonDocument::Indented);
    return 0;
}
