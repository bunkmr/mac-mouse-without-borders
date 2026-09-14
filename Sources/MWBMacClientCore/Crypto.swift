// Crypto.swift
// Mouse Without Borders 线协议加密层。
//
// 【本实现参数来自对真实 Windows 端抓包的穷举破解，
//   非来自社区文档的猜测，已实测可完成双向握手认证】
//
// 实测结论:
//  - 密钥派生: PBKDF2-HMAC-**SHA1**(UTF8(安全密钥), salt, 50000 次) -> 32 字节 AES-256 key。
//    注意是 SHA1 而非 SHA512 —— 这是社区文档普遍写错的地方（Satyam52/MWBMac 也用的 SHA512）。
//  - salt    : UTF16LE("18446744073709551615")，40 字节，固定。
//  - IV      : ASCII("1844674407370955")，16 字节，固定。收发共用。
//  - 无明文 salt/IV 头交换（PowerToys 新版的 32 字节头交换在此版本不存在）。
//  - 连接建立后先互发一个 16 字节随机块预热 CBC 链，之后首包才开始。
//  - AES-256-CBC，无填充，链式状态跨包连续（每个方向各自一条链）。
//  - Magic   : byte2..3 存放 16 位小端魔数，对端会强校验。
//    其推导公式未能反推，故采用「自校准」策略：首个校验和合法的对端包过来时
//    直接采用它的 magic 字节（见 Connection.learnMagic）。
//  - Checksum: byte1 = sum(byte[2..32]) & 0xFF（与 magic 无关，可独立校验）。

import Foundation
import CommonCrypto

public enum MWBCryptoError: Error {
    case pbkdf2Failed
    case aesFailed
    case invalidKeySize
    case magicMismatch
    case checksumMismatch
}

public enum MWBCrypto {
    public static let keySize = 32
    public static let blockSize = 16
    /// PBKDF2 迭代次数（实测 50000）。
    public static let iterations = 50_000
    /// 伪随机函数：实测为 HMAC-SHA1。
    public static let prf = CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1)

    // MARK: - 密钥派生

    /// PBKDF2-HMAC-SHA1(UTF8(安全密钥), salt, iterations, 32) -> 32 字节 AES-256 key。
    /// 默认使用实测固定的 legacy salt。
    public static func deriveKey(securityKey: String,
                                 salt: [UInt8] = MWBCrypto.legacySalt(),
                                 iterations: Int = MWBCrypto.iterations) -> Result<[UInt8], MWBCryptoError> {
        let pw = Data(securityKey.utf8)
        guard !salt.isEmpty, !pw.isEmpty else { return .failure(.aesFailed) }

        var derived = [UInt8](repeating: 0, count: keySize)
        let status = pw.withUnsafeBytes { pwPtr -> Int32 in
            salt.withUnsafeBytes { saltPtr -> Int32 in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    pwPtr.baseAddress!.assumingMemoryBound(to: CChar.self),
                    pw.count,
                    saltPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    salt.count,
                    prf,
                    UInt32(iterations),
                    &derived,
                    derived.count
                )
            }
        }
        return status == kCCSuccess ? .success(derived) : .failure(.pbkdf2Failed)
    }

    /// 固定 salt（UTF-16LE of "18446744073709551615"，40 字节）。
    public static func legacySalt() -> [UInt8] {
        let s = "18446744073709551615"
        var out = [UInt8]()
        for u in s.utf16 {
            out.append(UInt8(u & 0xFF))
            out.append(UInt8((u >> 8) & 0xFF))
        }
        return out
    }

    /// 固定 IV（ASCII of "1844674407370955"，16 字节）。
    public static func legacyIV() -> [UInt8] {
        Array("1844674407370955".utf8)
    }

    // MARK: - Magic / Checksum

    /// byte2..3 上的 16 位小端魔数。
    public static func readMagic(_ buf: [UInt8]) -> UInt16 {
        guard buf.count >= 4 else { return 0 }
        return UInt16(buf[2]) | (UInt16(buf[3]) << 8)
    }

    /// 仅校验 checksum，不校验 magic —— 用于在未知 magic 时识别合法包。
    public static func checksumValid(_ buf: [UInt8]) -> Bool {
        guard buf.count >= 32 else { return false }
        var checksum: UInt8 = 0
        for i in 2..<32 { checksum = checksum &+ buf[i] }
        return buf[1] == checksum
    }

    /// 24-bit 哈希魔数（MWB Encryption.Get24BitHash 的社区描述版本）。
    /// 实测与本版本对端的 16 位魔数并不一致，仅作为「抓不到对端包时」的兜底猜测。
    public static func get24BitHash(_ key: String, iterations: Int = MWBCrypto.iterations) -> UInt32 {
        guard !key.isEmpty else { return 0 }
        var buf = [UInt8](repeating: 0, count: 32)
        let kb = [UInt8](key.utf8)
        for i in 0..<min(kb.count, 32) { buf[i] = kb[i] }

        var hash = sha512(buf)
        for _ in 0..<iterations {
            hash = sha512(hash)
        }
        let h0 = UInt32(hash[0])
        let h1 = UInt32(hash[1])
        let hLast = UInt32(hash[hash.count - 1])
        let h2 = UInt32(hash[2])
        return (h0 << 23) | (h1 << 16) | (hLast << 8) | h2
    }

    /// 填充魔数(byte2..3, 小端)与校验和(byte1)。buf 至少 32 字节。
    public static func stampPacket(_ buf: inout [UInt8], magic: UInt16) {
        buf[2] = UInt8(magic & 0xFF)
        buf[3] = UInt8((magic >> 8) & 0xFF)
        var checksum: UInt8 = 0
        for i in 2..<32 { checksum = checksum &+ buf[i] }
        buf[1] = checksum
    }

    /// 校验魔数与校验和。两者都必须通过（对端强校验 magic）。
    public static func validatePacket(_ buf: [UInt8], magic: UInt16) -> Bool {
        guard buf.count >= 32 else { return false }
        guard readMagic(buf) == magic else { return false }
        return checksumValid(buf)
    }

    /// 校验后清零 byte1..3（便于解析）。
    public static func clearStamp(_ buf: inout [UInt8]) {
        buf[1] = 0
        buf[2] = 0
        buf[3] = 0
    }

    /// 生成随机字节（用于 dummy 预热块 / 握手挑战）。
    public static func randomBytes(_ count: Int) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &b)
        return b
    }

    // MARK: - SHA512 工具

    private static func sha512(_ data: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: Int(CC_SHA512_DIGEST_LENGTH))
        data.withUnsafeBytes { ptr in
            out.withUnsafeMutableBytes { outPtr in
                _ = CC_SHA512(ptr.baseAddress, CC_LONG(data.count),
                              outPtr.bindMemory(to: UInt8.self).baseAddress)
            }
        }
        return out
    }
}

/// 维护 AES-256-CBC 链式状态的加/解密器。key/iv 在整条连接上固定，链状态跨调用连续。
public final class CBCContext {
    private let key: [UInt8]
    private var chainIV: [UInt8]

    public init(key: [UInt8], iv: [UInt8]) {
        self.key = key
        self.chainIV = iv
    }

    public func encrypt(_ data: [UInt8]) -> Result<[UInt8], MWBCryptoError> {
        guard data.count % MWBCrypto.blockSize == 0 else { return .failure(.aesFailed) }
        var out = [UInt8](repeating: 0, count: data.count)
        var i = 0
        while i < data.count {
            let block = Array(data[i..<i + MWBCrypto.blockSize])
            let xored = (0..<MWBCrypto.blockSize).map { block[$0] ^ chainIV[$0] }
            switch CBCContext.aes256ECB(xored, key: key, encrypt: true) {
            case .success(let enc):
                for j in 0..<MWBCrypto.blockSize { out[i + j] = enc[j] }
                chainIV = enc
            case .failure(let e): return .failure(e)
            }
            i += MWBCrypto.blockSize
        }
        return .success(out)
    }

    public func decrypt(_ data: [UInt8]) -> Result<[UInt8], MWBCryptoError> {
        guard data.count % MWBCrypto.blockSize == 0 else { return .failure(.aesFailed) }
        var out = [UInt8](repeating: 0, count: data.count)
        var i = 0
        while i < data.count {
            let block = Array(data[i..<i + MWBCrypto.blockSize])
            switch CBCContext.aes256ECB(block, key: key, encrypt: false) {
            case .success(let dec):
                let xored = (0..<MWBCrypto.blockSize).map { dec[$0] ^ chainIV[$0] }
                for j in 0..<MWBCrypto.blockSize { out[i + j] = xored[j] }
            case .failure(let e): return .failure(e)
            }
            chainIV = block // 解密时下一轮 IV = 当前密文块
            i += MWBCrypto.blockSize
        }
        return .success(out)
    }

    // 单块 ECB（内部使用）
    private static func aes256ECB(_ block: [UInt8], key: [UInt8], encrypt: Bool) -> Result<[UInt8], MWBCryptoError> {
        guard key.count == MWBCrypto.keySize, block.count == MWBCrypto.blockSize else { return .failure(.invalidKeySize) }
        var out = [UInt8](repeating: 0, count: MWBCrypto.blockSize)
        let status = key.withUnsafeBytes { keyPtr -> Int32 in
            block.withUnsafeBytes { blkPtr -> Int32 in
                CCCrypt(
                    encrypt ? UInt32(kCCEncrypt) : UInt32(kCCDecrypt),
                    UInt32(kCCAlgorithmAES),
                    UInt32(kCCOptionECBMode),
                    keyPtr.baseAddress!, key.count,
                    nil,
                    blkPtr.baseAddress!, block.count,
                    &out, out.count,
                    nil
                )
            }
        }
        return status == kCCSuccess ? .success(out) : .failure(.aesFailed)
    }
}
