#ifndef QUICK_UNZIP_ARCHIVE_BRIDGE_H
#define QUICK_UNZIP_ARCHIVE_BRIDGE_H
#include <stdint.h>
#include <stddef.h>
#include <sys/types.h>
// Minimal declarations of the stable public libarchive C ABI. macOS ships
// libarchive.dylib, but does not ship its headers in every SDK installation.
struct archive;
struct archive_entry;
#define ARCHIVE_OK 0
#define ARCHIVE_EOF 1
#define ARCHIVE_WARN (-20)
#define ARCHIVE_FORMAT_RAW 0x90000
struct archive *archive_read_new(void);
int archive_read_support_filter_all(struct archive *);
int archive_read_support_format_all(struct archive *);
int archive_read_support_format_raw(struct archive *);
int archive_read_add_passphrase(struct archive *, const char *);
int archive_read_set_options(struct archive *, const char *);
int archive_read_open_filename(struct archive *, const char *, size_t);
int archive_read_next_header(struct archive *, struct archive_entry **);
ssize_t archive_read_data(struct archive *, void *, size_t);
int archive_read_data_skip(struct archive *);
int archive_read_free(struct archive *);
int archive_format(struct archive *);
const char *archive_format_name(struct archive *);
int archive_filter_count(struct archive *);
const char *archive_filter_name(struct archive *, int);
int64_t archive_filter_bytes(struct archive *, int);
const char *archive_error_string(struct archive *);
const char *archive_version_string(void);
const char *archive_entry_pathname(struct archive_entry *);
const char *archive_entry_pathname_utf8(struct archive_entry *);
const char *archive_entry_symlink(struct archive_entry *);
const char *archive_entry_hardlink(struct archive_entry *);
int64_t archive_entry_size(struct archive_entry *);
unsigned int archive_entry_filetype(struct archive_entry *);
mode_t archive_entry_perm(struct archive_entry *);
time_t archive_entry_mtime(struct archive_entry *);
long archive_entry_mtime_nsec(struct archive_entry *);
int archive_entry_mtime_is_set(struct archive_entry *);
int archive_entry_is_encrypted(struct archive_entry *);
#endif
