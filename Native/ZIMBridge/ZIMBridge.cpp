#include "ZIMBridge.h"
#include <zim/archive.h>
#include <zim/item.h>
#include <zim/suggestion.h>
#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <stdexcept>
#include <vector>
#include <memory>

struct Reader {
    zim::Archive archive;
    zim::SuggestionSearcher suggestions;
    explicit Reader(const char *path): archive(path), suggestions(archive) {}
};
static void fail(char **error, const char *message) { if(error) *error = strdup(message); }
#define AZ_CATCH catch(const std::exception &e) { fail(error, e.what()); return 0; } catch(...) { fail(error, "Unknown ZIM error"); return 0; }
static zim::Item itemFor(Reader *reader, const char *path) {
    return (path && *path ? reader->archive.getEntryByPath(path) : reader->archive.getMainEntry()).getItem(true);
}
AZArchive az_open(const char *path, char **error) {
    try { return new Reader(path); } catch(const std::exception &e) { fail(error,e.what()); return nullptr; }
    catch(...) { fail(error,"Unable to open ZIM"); return nullptr; }
}
void az_close(AZArchive archive) { delete static_cast<Reader *>(archive); }
int az_info(AZArchive archive, const char *path, AZItem *out, char **error) {
    try {
        auto item = itemFor(static_cast<Reader *>(archive),path);
        out->path = strdup(item.getPath().c_str()); out->title = strdup(item.getTitle().c_str());
        out->mime = strdup(item.getMimetype().c_str()); out->size = item.getSize(); return 1;
    } AZ_CATCH
}
int az_read(AZArchive archive, const char *path, uint64_t offset, size_t length, void **data, size_t *count, char **error) {
    try {
        auto item = itemFor(static_cast<Reader *>(archive),path);
        if(offset > item.getSize()) throw std::out_of_range("Resource offset out of range");
        auto blob = item.getData(offset,std::min<uint64_t>(length,item.getSize()-offset));
        *count = blob.size(); *data = nullptr;
        if (*count) {
            *data = malloc(*count);
            if(!*data) throw std::bad_alloc();
            memcpy(*data,blob.data(),*count);
        }
        return 1;
    } AZ_CATCH
}
int az_search(AZArchive archive, const char *query, int limit, AZMatch **matches, int *count, char **error) {
    try {
        auto search = static_cast<Reader *>(archive)->suggestions.suggest(query);
        auto results = search.getResults(0,std::min(std::max(limit,1),100));
        std::vector<std::pair<std::string,std::string>> rows;
        for(auto it=results.begin();it!=results.end();++it) rows.emplace_back(it->getPath(),it->getTitle());
        *count = (int)rows.size(); *matches = static_cast<AZMatch *>(calloc(rows.size(),sizeof(AZMatch)));
        if(!*matches && !rows.empty()) throw std::bad_alloc();
        for(size_t i=0;i<rows.size();++i) {
            (*matches)[i].path=strdup(rows[i].first.c_str()); (*matches)[i].title=strdup(rows[i].second.c_str());
        }
        return 1;
    } AZ_CATCH
}
int az_validate(AZArchive archive, char **error) {
    try { if(!static_cast<Reader *>(archive)->archive.check()) throw std::runtime_error("ZIM checksum mismatch"); return 1; } AZ_CATCH
}
void az_free(void *pointer) { free(pointer); }
void az_item_free(AZItem *item) { free(item->path); free(item->title); free(item->mime); }
void az_matches_free(AZMatch *matches,int count) {
    for(int i=0;i<count;++i) { free(matches[i].path); free(matches[i].title); } free(matches);
}
