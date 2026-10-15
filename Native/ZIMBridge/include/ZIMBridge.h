#ifndef ATLAS_ZIM_BRIDGE_H
#define ATLAS_ZIM_BRIDGE_H
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
// All returned pointers are owned by the caller; exceptions never cross the C ABI.
typedef void * AZArchive;
typedef struct { char *path; char *title; char *mime; uint64_t size; } AZItem;
typedef struct { char *path; char *title; } AZMatch;
AZArchive az_open(const char *path, char **error);
void az_close(AZArchive archive);
int az_info(AZArchive archive, const char *path, AZItem *item, char **error);
int az_read(AZArchive archive, const char *path, uint64_t offset, size_t length, void **data, size_t *count, char **error);
int az_search(AZArchive archive, const char *query, int limit, AZMatch **matches, int *count, char **error);
int az_fulltext(AZArchive archive, const char *query, int limit, AZMatch **matches, int *count, char **error);
// Results [offset, offset+limit) of a full-text search (limit at most 500) and libzim's estimate of all matches.
int az_fulltext_page(AZArchive archive, const char *query, int offset, int limit, AZMatch **matches, int *count, int *estimated, char **error);
int az_has_fulltext(AZArchive archive);
// A metadata value the archive stores about itself (Title, Name, Language, Description, Date, Flavour, Tags…).
// Returns 0 when the archive has no such value.
int az_metadata(AZArchive archive, const char *name, char **value, char **error);
// The archive's UUID as text.
int az_uuid(AZArchive archive, char **value);
// The HTML article each path leads to after redirects: exactly `count` results, in order, with an
// empty path where a path isn't an article. Reads only directory entries, never article data.
int az_resolve_paths(AZArchive archive, const char *const *paths, int count, AZMatch **matches, int *resolved, char **error);
uint64_t az_entry_count(AZArchive archive);
int az_articles(AZArchive archive, uint64_t offset, int limit, AZMatch **matches, int *count, uint64_t *next, char **error);
int az_validate(AZArchive archive, char **error);
void az_free(void *pointer);
void az_item_free(AZItem *item);
void az_matches_free(AZMatch *matches, int count);

// gzip streams (Wikimedia's .sql.gz table dumps), through zlib.
typedef void * AZGzip;
AZGzip az_gz_open(const char *path);
// Up to `length` decompressed bytes; 0 at the end, -1 on error.
int az_gz_read(AZGzip file, void *buffer, int length);
// How far into the compressed file reading has got, for progress.
long long az_gz_offset(AZGzip file);
void az_gz_close(AZGzip file);
// Writing, used by tests to make fixtures.
AZGzip az_gz_create(const char *path);
int az_gz_write(AZGzip file, const void *buffer, int length);
#ifdef __cplusplus
}
#endif
#endif
