// mwb_zlib.c
// 裸 DEFLATE 压缩/解压实现（windowBits = -15 即 raw deflate）。

#include "include/mwb_zlib.h"
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

int mwb_raw_deflate(const uint8_t *src, size_t srcLen, uint8_t **out, size_t *outLen) {
    if (out == NULL || outLen == NULL) return -1;
    *out = NULL;
    *outLen = 0;
    if (src == NULL && srcLen != 0) return -1;

    z_stream zs;
    memset(&zs, 0, sizeof(zs));

    // windowBits = -15 -> 裸 DEFLATE（与 .NET DeflateStream 一致）
    int rc = deflateInit2(&zs, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY);
    if (rc != Z_OK) return rc;

    zs.next_in  = (Bytef *)src;
    zs.avail_in = (uInt)srcLen;

    size_t cap = deflateBound(&zs, (uLong)srcLen + 64);
    if (cap < 64) cap = 64;
    uint8_t *buf = (uint8_t *)malloc(cap);
    if (buf == NULL) { deflateEnd(&zs); return -2; }

    zs.next_out  = buf;
    zs.avail_out = (uInt)cap;

    rc = deflate(&zs, Z_FINISH);
    if (rc != Z_STREAM_END) {
        deflateEnd(&zs);
        free(buf);
        return rc;
    }

    *outLen = zs.total_out;
    *out = buf;
    deflateEnd(&zs);
    return 0;
}

int mwb_raw_inflate(const uint8_t *src, size_t srcLen, uint8_t **out, size_t *outLen) {
    if (out == NULL || outLen == NULL) return -1;
    *out = NULL;
    *outLen = 0;
    if (src == NULL) return -1;

    z_stream zs;
    memset(&zs, 0, sizeof(zs));

    int rc = inflateInit2(&zs, -15);   // 裸 DEFLATE
    if (rc != Z_OK) return rc;

    zs.next_in  = (Bytef *)src;
    zs.avail_in = (uInt)srcLen;

    size_t cap = srcLen * 8 + 1024;
    uint8_t *buf = (uint8_t *)malloc(cap);
    if (buf == NULL) { inflateEnd(&zs); return -2; }

    size_t used = 0;
    for (;;) {
        if (used == cap) {
            size_t ncap = cap * 2;
            uint8_t *nb = (uint8_t *)realloc(buf, ncap);
            if (nb == NULL) { inflateEnd(&zs); free(buf); return -2; }
            buf = nb;
            cap = ncap;
        }
        zs.next_out  = buf + used;
        zs.avail_out = (uInt)(cap - used);

        rc = inflate(&zs, Z_NO_FLUSH);
        used = zs.total_out;

        if (rc == Z_STREAM_END) break;
        if (rc == Z_BUF_ERROR && zs.avail_in == 0) break;   // 数据不完整（对端补的 0 之外的截断）
        if (rc != Z_OK) {
            inflateEnd(&zs);
            free(buf);
            return rc;
        }
        if (zs.avail_in == 0 && zs.avail_out != 0) break;   // 输入耗尽
    }

    *outLen = used;
    *out = buf;
    inflateEnd(&zs);
    return 0;
}

void mwb_free(void *p) {
    free(p);
}
