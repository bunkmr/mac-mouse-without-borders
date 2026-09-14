// mwb_zlib.h
// 原始 DEFLATE（raw deflate，RFC1951，不带 zlib 2 字节头/4 字节校验尾）的极小封装。
//
// 【为什么需要它】MWB 的剪贴板文本在发送前用 .NET 的 DeflateStream 压缩，
// 那是**裸 DEFLATE**，没有 zlib 头尾。macOS 的 Compression 框架（COMPRESSION_ZLIB）
// 与 zlib 的默认入口都带 zlib 包裹，直接互操作会解压失败；
// 只有把 windowBits 设成负值（-15）才是裸流。所以这里直接用 libz 并把 windowBits 取负。

#ifndef MWB_ZLIB_H
#define MWB_ZLIB_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// 裸 DEFLATE 压缩。成功返回 0，并把 malloc 出来的缓冲区写到 *out / *outLen（调用方用 mwb_free 释放）。
int mwb_raw_deflate(const uint8_t *src, size_t srcLen, uint8_t **out, size_t *outLen);

/// 裸 DEFLATE 解压。成功返回 0，并把 malloc 出来的缓冲区写到 *out / *outLen。
int mwb_raw_inflate(const uint8_t *src, size_t srcLen, uint8_t **out, size_t *outLen);

/// 释放上面两个函数返回的缓冲区。
void mwb_free(void *p);

#ifdef __cplusplus
}
#endif

#endif /* MWB_ZLIB_H */
