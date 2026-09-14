// Deflate.swift
// 裸 DEFLATE（raw deflate）编解码 —— MWB 剪贴板文本协议要求。
//
// 关键事实（已逐行核对 PowerToys/MouseWithoutBorders）：
//   - 源端把文本先转成 **UTF-16LE** 字节（Common.GetBytesU = Encoding.Unicode.GetBytes），
//   - 再用 .NET 的 DeflateStream(CompressionMode.Compress) 压缩；
//   - .NET 的 DeflateStream 输出的是 **裸 DEFLATE**（RFC1951），没有 zlib 两字节头与 adler32 尾。
//   - 接收端同样用 DeflateStream(Decompress) 解压，再按 UTF-16 拼回字符串。
// 所以这里必须用 windowBits = -15 的原始流，不能走 zlib 默认入口。

import Foundation
import CZlibShim

public enum MWBDeflate {
    /// 裸 DEFLATE 压缩。
    public static func compress(_ data: [UInt8]) -> [UInt8]? {
        var outPtr: UnsafeMutablePointer<UInt8>?
        var outLen = 0
        let rc: Int32 = data.withUnsafeBufferPointer { buf in
            mwb_raw_deflate(buf.baseAddress, buf.count, &outPtr, &outLen)
        }
        guard rc == 0, let p = outPtr else { return nil }
        defer { mwb_free(p) }
        return Array(UnsafeBufferPointer(start: p, count: outLen))
    }

    /// 裸 DEFLATE 解压。输入尾部可能带对端补的 0，解压器会在流结束符处自然停止。
    public static func decompress(_ data: [UInt8]) -> [UInt8]? {
        guard !data.isEmpty else { return nil }
        var outPtr: UnsafeMutablePointer<UInt8>?
        var outLen = 0
        let rc: Int32 = data.withUnsafeBufferPointer { buf in
            mwb_raw_inflate(buf.baseAddress, buf.count, &outPtr, &outLen)
        }
        guard rc == 0, let p = outPtr else { return nil }
        defer { mwb_free(p) }
        return Array(UnsafeBufferPointer(start: p, count: outLen))
    }

    // MARK: - 文本便捷方法（UTF-16LE，与 MWB 的 Encoding.Unicode 对齐）

    /// 文本 -> 线上字节（UTF-16LE + 裸 DEFLATE）。返回 nil 表示压缩失败。
    public static func encodeText(_ text: String) -> [UInt8]? {
        compress(Array(text.data(using: .utf16LittleEndian) ?? Data()))
    }

    /// 线上字节 -> 文本（裸 DEFLATE 解压 + UTF-16LE 解码）。
    public static func decodeText(_ data: [UInt8]) -> String? {
        guard let raw = decompress(data), !raw.isEmpty else { return nil }
        var s = String(data: Data(raw), encoding: .utf16LittleEndian)
        if s == nil {
            // 兜底：万一对端发的是 UTF-8（例如未来 MWB 改了编码），再试一次。
            s = String(data: Data(raw), encoding: .utf8)
        }
        return s
    }
}
