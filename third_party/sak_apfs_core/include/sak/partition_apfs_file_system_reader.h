/// @file partition_apfs_file_system_reader.h
/// @brief Read-only APFS file browser for Partition Manager.

#pragma once

#include <QByteArray>
#include <QPair>
#include <QString>
#include <QStringList>
#include <QVector>

#include <cstdint>
#include <memory>

class QIODevice;

namespace sak {

inline constexpr int kPartitionApfsDefaultBrowseEntryLimit = 1000;

struct PartitionApfsFileEntry {
    QString path;
    QString name;
    QString type;
    uint64_t object_id{0};
    uint64_t size_bytes{0};
    uint32_t hard_link_count{1};
    bool directory{false};
    bool regular_file{false};
    bool symlink{false};
    // Fixed j_inode_val metadata. Exposed so copied-core COW mutations can
    // preserve Apple-created inode identity details instead of replacing them
    // with generated-image defaults.
    uint64_t created_time_ns{0};
    uint64_t modified_time_ns{0};
    uint64_t changed_time_ns{0};
    uint64_t accessed_time_ns{0};
    uint32_t write_generation_counter{0};
    uint32_t bsd_flags{0};
    uint32_t owner_id{0};
    uint32_t group_id{0};
    uint16_t inode_mode{0};
    // Transparent decmpfs compression (inline or resource-fork), read from the inode's
    // decmpfs attribute / uncompressed-size flag during listing.
    bool compressed{false};
    // APFS_INODE_IS_SPARSE: the file has trailing/embedded holes that read as zeros.
    bool sparse{false};
    // The inode's full st_mode (type + permission bits), so a non-regular entry
    // (symlink, FIFO, socket, device) can be preserved verbatim across a mutation.
    uint16_t mode{0};
    // Identity metadata recovered from the inode (owner/group @0x48/0x4C, bsd_flags @0x44,
    // the four j_inode_val timestamps). has_inode_metadata is true only when the entry's
    // inode record was found, so an arbitrary import can preserve a real Apple file's
    // ownership/permissions/flags/times instead of stamping generated defaults.
    uint32_t uid{0};
    uint32_t gid{0};
    uint64_t create_time{0};
    uint64_t mod_time{0};
    uint64_t change_time{0};
    uint64_t access_time{0};
    bool has_inode_metadata{false};
};

struct PartitionApfsFileReadResult {
    bool ok{false};
    // True if the returned data is a prefix of a larger file (the read hit the byte
    // cap). Any caller that PERSISTS or HASHES these bytes -- export, copy-out, file
    // hash, or a read-modify-write byte patch -- MUST treat this as failure: writing
    // or hashing the prefix silently yields a short file or a wrong-file digest that
    // is indistinguishable from a complete one. Only a purely on-screen preview may
    // ignore it.
    bool truncated{false};
    QString file_system;
    QString volume_name;
    QStringList blockers;
    QStringList warnings;
    QVector<PartitionApfsFileEntry> entries;
    QByteArray data;
    // A7 (A-h): the read file's named extended attributes (ACL, Finder info, user
    // xattrs), each as (name, embedded value). Populated by readFile.
    QVector<QPair<QString, QByteArray>> xattrs;
};

struct PartitionApfsFileExtentDebug {
    QString role;
    uint64_t owner_id{0};
    uint64_t logical_offset{0};
    uint64_t length{0};
    uint64_t physical_block{0};
    uint64_t physical_byte_offset{0};
    uint64_t flags{0};
    uint64_t crypto_id{0};
    bool physical_block_in_container{false};
    bool physical_byte_offset_in_container{false};
};

struct PartitionApfsFileXattrDebug {
    QString name;
    uint64_t size_bytes{0};
    bool embedded{true};
};

struct PartitionApfsFileDebugResult {
    bool ok{false};
    QString file_system;
    QString volume_name;
    QString path;
    QStringList blockers;
    QStringList warnings;
    uint64_t block_size{0};
    uint64_t block_count{0};
    uint64_t directory_parent_id{0};
    QString directory_name;
    uint64_t file_id{0};
    uint16_t directory_type{0};
    uint64_t inode_object_id{0};
    uint64_t inode_private_id{0};
    uint64_t inode_size{0};
    uint16_t inode_mode{0};
    uint64_t inode_created_time_ns{0};
    uint64_t inode_modified_time_ns{0};
    uint64_t inode_changed_time_ns{0};
    uint64_t inode_accessed_time_ns{0};
    uint32_t inode_write_generation_counter{0};
    uint32_t inode_bsd_flags{0};
    uint32_t inode_owner_id{0};
    uint32_t inode_group_id{0};
    bool inode_sparse{false};
    bool has_decmpfs{false};
    uint32_t decmpfs_algo{0};
    uint64_t decmpfs_uncompressed_size{0};
    uint64_t decmpfs_size_bytes{0};
    uint64_t resource_fork_object_id{0};
    QVector<PartitionApfsFileXattrDebug> xattrs;
    QVector<PartitionApfsFileExtentDebug> extents;
};

struct PartitionApfsDirectoryExportResult {
    bool ok{false};
    QStringList blockers;
    QStringList warnings;
    int files_exported{0};
    int directories_exported{0};
    int symlinks_skipped{0};
    int entries_scanned{0};
    uint64_t bytes_exported{0};
};

struct PartitionApfsDirectoryExportOptions {
    int max_entries{kPartitionApfsDefaultBrowseEntryLimit};
    uint64_t max_file_bytes{0};
    uint64_t max_total_bytes{0};
};

/// Mounted reader state for repeated directory and range reads. Recreate after
/// any APFS mutation so the parsed object-map and file-tree generation stays current.
class PartitionApfsFileSystemReaderSession {
public:
    explicit PartitionApfsFileSystemReaderSession(QIODevice* device,
                                                  const QString& credential = {});
    ~PartitionApfsFileSystemReaderSession();

    PartitionApfsFileSystemReaderSession(const PartitionApfsFileSystemReaderSession&) = delete;
    PartitionApfsFileSystemReaderSession& operator=(
        const PartitionApfsFileSystemReaderSession&) = delete;

    [[nodiscard]] PartitionApfsFileReadResult listDirectory(
        const QString& path = {},
        int max_entries = kPartitionApfsDefaultBrowseEntryLimit);
    [[nodiscard]] PartitionApfsFileReadResult readFile(const QString& path,
                                                       uint64_t max_bytes);
    [[nodiscard]] PartitionApfsFileReadResult readFileRange(const QString& path,
                                                            uint64_t offset,
                                                            uint64_t length);
    /// Read named embedded xattrs without requiring a regular-file data stream.
    /// Works for regular files, directories, and symbolic links.
    [[nodiscard]] PartitionApfsFileReadResult readXattrs(const QString& path);
    /// Read fixed inode metadata and xattr/extent diagnostics for any path,
    /// including the APFS volume root.
    [[nodiscard]] PartitionApfsFileDebugResult debugFile(const QString& path);

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

class PartitionApfsFileSystemReader {
public:
    /// @p credential (optional) is the FileVault volume password or personal
    /// recovery key used to unlock a software-encrypted volume; held in memory only.
    [[nodiscard]] static PartitionApfsFileReadResult listDirectory(
        QIODevice* device,
        const QString& path = {},
        int max_entries = kPartitionApfsDefaultBrowseEntryLimit,
        const QString& credential = {});
    [[nodiscard]] static PartitionApfsFileReadResult listDirectoryFromImage(
        const QString& image_path,
        const QString& path = {},
        int max_entries = kPartitionApfsDefaultBrowseEntryLimit,
        const QString& credential = {});
    [[nodiscard]] static PartitionApfsFileReadResult readFile(QIODevice* device,
                                                              const QString& path,
                                                              uint64_t max_bytes,
                                                              const QString& credential = {});
    /// Read one logical range without materializing the file prefix. Compressed
    /// files may still require prefix/full-stream decode depending on APFS encoding.
    [[nodiscard]] static PartitionApfsFileReadResult readFileRange(
        QIODevice* device,
        const QString& path,
        uint64_t offset,
        uint64_t length,
        const QString& credential = {});
    [[nodiscard]] static PartitionApfsFileReadResult readFileFromImage(
        const QString& image_path,
        const QString& path,
        uint64_t max_bytes,
        const QString& credential = {});
    [[nodiscard]] static PartitionApfsFileReadResult readXattrs(
        QIODevice* device,
        const QString& path,
        const QString& credential = {});
    [[nodiscard]] static PartitionApfsFileReadResult readXattrsFromImage(
        const QString& image_path,
        const QString& path,
        const QString& credential = {});
    [[nodiscard]] static PartitionApfsFileDebugResult debugFile(
        QIODevice* device,
        const QString& path,
        const QString& credential = {});
    [[nodiscard]] static PartitionApfsDirectoryExportResult exportDirectoryFromImage(
        const QString& image_path,
        const QString& source_path,
        const QString& output_directory,
        const PartitionApfsDirectoryExportOptions& options);

    /// @brief True when @p child resolves (junctions/symlinks followed) to a real path at or
    ///        under the canonical @p canonical_root. Pure seam for the export junction/symlink
    ///        TOCTOU guard: fails closed on an empty root or an unresolvable/vanished child, and
    ///        rejects a sibling-prefix (Root vs RootX). Same logic guards the ext exporter.
    [[nodiscard]] static bool exportPathWithinRootForTesting(const QString& canonical_root,
                                                             const QString& child);
};

}  // namespace sak
