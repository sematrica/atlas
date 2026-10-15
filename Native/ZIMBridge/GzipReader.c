// Streaming access to gzip files (Wikimedia's .sql.gz table dumps) through zlib.
// Concatenated gzip members are read as one stream, as zlib's gzread does.
#include "ZIMBridge.h"
#include <zlib.h>

AZGzip az_gz_open(const char *path) {
    gzFile file=gzopen(path,"rb");
    if(file) gzbuffer(file,1<<20);
    return (AZGzip)file;
}
int az_gz_read(AZGzip file,void *buffer,int length) {
    if(!file || length<=0) return -1;
    return gzread((gzFile)file,buffer,(unsigned)length);
}
long long az_gz_offset(AZGzip file) {
    if(!file) return -1;
    return (long long)gzoffset((gzFile)file);
}
void az_gz_close(AZGzip file) {
    if(file) gzclose((gzFile)file);
}
AZGzip az_gz_create(const char *path) {
    return (AZGzip)gzopen(path,"wb");
}
int az_gz_write(AZGzip file,const void *buffer,int length) {
    if(!file || length<0) return -1;
    return gzwrite((gzFile)file,buffer,(unsigned)length);
}
