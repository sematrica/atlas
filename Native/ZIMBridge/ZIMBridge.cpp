#include "ZIMBridge.h"
#include <zim/archive.h>
#include <zim/item.h>
#include <zim/suggestion.h>
#include <zim/search.h>
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
static void copyMatches(const std::vector<std::pair<std::string,std::string>>& rows, AZMatch **matches, int *count) {
    *count=(int)rows.size(); *matches=static_cast<AZMatch *>(calloc(rows.size(),sizeof(AZMatch)));
    if(!*matches && !rows.empty()) throw std::bad_alloc();
    for(size_t i=0;i<rows.size();++i) {(*matches)[i].path=strdup(rows[i].first.c_str());(*matches)[i].title=strdup(rows[i].second.c_str());}
}
int az_has_fulltext(AZArchive archive) {try {return static_cast<Reader *>(archive)->archive.hasFulltextIndex();} catch(...) {return 0;}}
uint64_t az_entry_count(AZArchive archive) {try {return static_cast<Reader *>(archive)->archive.getEntryCount();} catch(...) {return 0;}}
int az_fulltext(AZArchive archive,const char *query,int limit,AZMatch **matches,int *count,char **error) {
    try {
        auto& archiveRef=static_cast<Reader *>(archive)->archive;
        if(!archiveRef.hasFulltextIndex()) throw std::runtime_error("No full-text index in this archive");
        zim::Searcher searcher(archiveRef);zim::Query q;q.setQuery(query);
        auto search=searcher.search(q);auto results=search.getResults(0,std::min(std::max(limit,1),100));
        std::vector<std::pair<std::string,std::string>> rows;
        for(auto it=results.begin();it!=results.end();++it) rows.emplace_back(it.getPath(),it.getTitle());
        copyMatches(rows,matches,count);return 1;
    } AZ_CATCH
}
int az_fulltext_page(AZArchive archive,const char *query,int offset,int limit,AZMatch **matches,int *count,int *estimated,char **error) {
    try {
        auto& archiveRef=static_cast<Reader *>(archive)->archive;
        if(!archiveRef.hasFulltextIndex()) throw std::runtime_error("No full-text index in this archive");
        zim::Searcher searcher(archiveRef);zim::Query q;q.setQuery(query);
        auto search=searcher.search(q);
        *estimated=search.getEstimatedMatches();
        auto results=search.getResults(std::max(offset,0),std::min(std::max(limit,1),500));
        std::vector<std::pair<std::string,std::string>> rows;
        for(auto it=results.begin();it!=results.end();++it) rows.emplace_back(it.getPath(),it.getTitle());
        copyMatches(rows,matches,count);return 1;
    } AZ_CATCH
}
int az_resolve_paths(AZArchive archive,const char *const *paths,int count,AZMatch **matches,int *resolved,char **error) {
    try {
        auto& a=static_cast<Reader *>(archive)->archive;
        std::vector<std::pair<std::string,std::string>> rows;
        rows.reserve(std::max(count,0));
        for(int i=0;i<count;++i) {
            std::string path,title;
            try {
                if(paths && paths[i] && *paths[i]) {
                    auto item=a.getEntryByPath(paths[i]).getItem(true);
                    if(item.getMimetype().find("text/html")!=std::string::npos) {path=item.getPath();title=item.getTitle();}
                }
            } catch(const std::exception &) {}
            rows.emplace_back(path,title);
        }
        copyMatches(rows,matches,resolved);return 1;
    } AZ_CATCH
}
int az_articles(AZArchive archive,uint64_t offset,int limit,AZMatch **matches,int *count,uint64_t *next,char **error) {
    try {
        auto& a=static_cast<Reader *>(archive)->archive;
        const uint64_t end=std::min<uint64_t>(a.getEntryCount(),offset+std::min(std::max(limit,1),256));
        std::vector<std::pair<std::string,std::string>> rows;
        for(auto i=offset;i<end;++i) {
            auto entry=a.getEntryByPath(static_cast<zim::entry_index_type>(i));
            if(entry.isRedirect()) continue;
            auto item=entry.getItem();
            if(item.getMimetype().find("text/html")!=std::string::npos) rows.emplace_back(item.getPath(),item.getTitle());
        }
        *next=end;copyMatches(rows,matches,count);return 1;
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
