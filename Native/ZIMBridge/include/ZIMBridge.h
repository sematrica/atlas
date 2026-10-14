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
uint64_t az_entry_count(AZArchive archive);
int az_articles(AZArchive archive, uint64_t offset, int limit, AZMatch **matches, int *count, uint64_t *next, char **error);
int az_validate(AZArchive archive, char **error);
void az_free(void *pointer);
void az_item_free(AZItem *item);
void az_matches_free(AZMatch *matches, int count);
#ifdef __cplusplus
}
#endif
#endif
