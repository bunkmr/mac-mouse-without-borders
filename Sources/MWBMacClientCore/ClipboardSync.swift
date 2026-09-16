// ClipboardSync.swift
// 剪贴板文本跨屏同步（走 MWB 原生协议，主 15101 socket）。
//
// 【协议事实】（逐行核对 PowerToys src/modules/MouseWithoutBorders/App/Core/Clipboard.cs）
//  源端：文本 -> 打包串 -> Encoding.Unicode(UTF-16LE) 字节 -> 裸 DEFLATE（DeflateStream）
//        -> 切成 48 字节/片 -> 每片塞进 64 字节大包的 byte16..63
//        -> 包 Type=ClipboardText(124)、Des=ID.ALL(0xFF)、走主 socket
//        -> 最后补一个 Type=ClipboardDataEnd(76) 的空包收尾（**接收端到它才整体解压**）
//  接收端：Receiver.cs 的 ClipboardText case **没有任何门禁**（不要求先握手、
//        不依赖 SwitchToMachine），直接把 byte16..63 追加进内存流，收到 76 才解压。
//        => 我们可以在已建立的连接上**主动推**剪贴板，无需次级 socket。
//  末片：不足 48 字节时补 0；真实长度由 DEFLATE 流自身的结束符决定。
//
// ★★★ 最容易踩的坑：**载荷不是纯文本，是一个多格式打包串** ★★★
//   "TXT"+纯文本 + SEP + "HTM"+CF_HTML全文 + SEP [+ "RTF"+RTF源 + SEP]
//   SEP = "{4CFF57F7-BEDD-43d5-AE8F-27A61E886F2F}"
//   Windows 接收端会按 SEP 切分、砍掉前 3 字符、按 TXT/HTM/RTF 分发到不同剪贴板格式。
//   编解码细节与踩坑经过见 `ClipboardBundle.swift`。
//   （2026-09-16 用户报的「企业微信复制后粘到 Mac 变成 TXT…{GUID}HTMVersion:0.9…」
//     就是因为这里少了拆包这一步。）

import Foundation
import AppKit

public final class ClipboardSync {
    public static let shared = ClipboardSync()

    /// 本地剪贴板文本变化时回调（应把它按 MWB 协议推给对端）。
    public var onLocalText: ((String) -> Void)?
    /// 诊断日志回调。
    public var onLog: ((String) -> Void)?

    /// 是否启用剪贴板同步。
    public var enabled = true
    /// 是否把对端带来的富文本类型（HTML / RTF）一并写进本机剪贴板。
    ///
    /// 开着的行为才和 Windows 上原生 MWB 一致：粘进文本框得到干净文字，
    /// 粘进 Word / 微信这类富文本 App 能保留格式。
    /// 需要退回「只写纯文本」做对照时，设环境变量 `MWB_CLIP_RICH=0`。
    public var richFormatsEnabled = true
    /// 单次同步的压缩后字节上限（MWB 的即时推送阈值就是 1MB，超过它会改走拉取流程）。
    private let maxBytes = 1_000_000

    private let pasteboard = NSPasteboard.general
    private var lastChangeCount: Int
    private var lastSentText: String?
    private var pollTimer: DispatchSourceTimer?

    /// 远端分片的累积缓冲，收到 ClipboardDataEnd 后整体解压。
    private var pending: [UInt8] = []
    private var pendingFrom: Date?

    private func log(_ s: String) { onLog?(s) }

    public init() {
        self.lastChangeCount = NSPasteboard.general.changeCount
        if ProcessInfo.processInfo.environment["MWB_CLIP_RICH"] == "0" {
            self.richFormatsEnabled = false
        }
    }

    // MARK: - 本地 -> 远端

    /// 开始轮询本机剪贴板（在主队列上跑，NSPasteboard 线程安全规则最省心）。
    public func startMonitoring(interval: TimeInterval = 0.35) {
        stopMonitoring()
        lastChangeCount = pasteboard.changeCount
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(120))
        t.setEventHandler { [weak self] in self?.pollLocal() }
        t.resume()
        pollTimer = t
    }

    public func stopMonitoring() {
        pollTimer?.cancel()
        pollTimer = nil
    }

    /// 轮询一次本机剪贴板；文本变化则回调出去。返回本次要同步的文本。
    @discardableResult
    public func pollLocal() -> String? {
        guard enabled else { return nil }
        let cc = pasteboard.changeCount
        guard cc != lastChangeCount else { return nil }
        lastChangeCount = cc

        // 只同步纯文本。Finder 复制文件（NSURL 类型）由文件通道处理，
        // 这里读 string 通常为 nil，自然不会误发。
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return nil }
        guard text != lastSentText else { return nil }
        lastSentText = text
        log("[剪贴板] 本机复制了 \(text.count) 个字符，正在发送…")
        onLocalText?(text)
        return text
    }

    /// 把文本编码成 MWB 的线格式分片（打包串 + UTF-16LE + 裸 DEFLATE，48 字节/片）。
    /// 返回 nil 表示文本为空或压缩失败。
    ///
    /// ★ 必须打上 `TXT` 前缀与分隔符。Windows 端 `SetClipboardData` 是按前缀分发的：
    ///   发裸文本虽然会落到它的 else 兜底分支侥幸可用，但会记一条
    ///   "Invalid clipboard format received!"，而且**文本若以 TXT/HTM/RTF 开头会被砍掉前 3 个字符**。
    public func encodeForWire(_ text: String) -> [UInt8]? {
        guard let packed = MWBClipboardBundle.pack(text: text) else { return nil }
        guard let bytes = MWBDeflate.encodeText(packed), !bytes.isEmpty else { return nil }
        guard bytes.count <= maxBytes else {
            log("[剪贴板] ⚠️ 文本过大（压缩后 \(bytes.count) 字节），已跳过同步")
            return nil
        }
        return bytes
    }

    // MARK: - 远端 -> 本地

    /// 累积一个远端 ClipboardText(124) 分片。
    public func appendRemoteChunk(_ bytes: [UInt8]) {
        if pendingFrom == nil || Date().timeIntervalSince(pendingFrom!) > 5 {
            pending.removeAll(keepingCapacity: true)   // 上一批没收到 End，丢弃重来
        }
        pendingFrom = Date()
        pending.append(contentsOf: bytes)
        // 防御：万一对方一直不发 End，别让内存无限增长
        if pending.count > maxBytes { pending.removeAll(keepingCapacity: true); pendingFrom = nil }
    }

    /// 收到 ClipboardDataEnd(76)：整体解压、拆包并写入本机剪贴板。
    /// 返回写入的纯文本（nil 表示解压失败或内容为空）。
    @discardableResult
    public func finishRemote() -> String? {
        let data = pending
        pending.removeAll(keepingCapacity: true)
        pendingFrom = nil
        guard !data.isEmpty else { return nil }

        guard let raw = MWBDeflate.decodeText(data) else {
            log("[剪贴板] ⚠️ 远端剪贴板解压失败（\(data.count) 字节，可能是压缩格式不匹配）")
            return nil
        }
        guard !raw.isEmpty else { return nil }

        // ★ 关键一步：解压出来的不是纯文本，是 "TXT…SEP…HTM…SEP" 这样的多格式打包串。
        let parts = MWBClipboardBundle.parse(raw)
        let shape = "TXT=\(parts.text?.count ?? 0) HTM=\(parts.html?.count ?? 0) RTF=\(parts.rtf?.count ?? 0)"
        writeBundle(parts)

        let plain = parts.text
            ?? parts.html.map(MWBClipboardBundle.plainText(fromHTML:))
            ?? ""
        log("[剪贴板] ← 已从 Windows 接收（\(parts.sawTaggedEntry ? "打包串" : "裸文本") \(shape)）")
        return plain.isEmpty ? nil : plain
    }

    /// 远端批次是否正在累积中。
    public var hasPendingRemote: Bool { !pending.isEmpty }

    /// 丢弃当前远端批次（例如对端推的是我们不支持的图片剪贴板，
    /// 若不丢弃会被当作文本去解压，得到一堆乱码）。
    public func dropPending() {
        pending.removeAll(keepingCapacity: true)
        pendingFrom = nil
    }

    // MARK: - 读写本机剪贴板

    public func readText() -> String? { pasteboard.string(forType: .string) }

    /// 把拆包结果写进本机剪贴板（对齐 Windows 端 `SetClipboardData` 的分发行为）：
    ///   `.string` ← TXT 条目；`.html` ← HTM 条目（已剥 CF_HTML 头）；`.rtf` ← RTF 条目。
    /// 没有 TXT 条目时，从 HTM 里粗略取纯文本兜底，保证纯文本框也粘得出东西。
    ///
    /// fromRemote=true 时同步更新 lastChangeCount/lastSentText，
    /// 避免刚写进去的内容又被当成「本机复制」推回对端（剪贴板回环）。
    public func writeBundle(_ parts: MWBClipboardBundle.Parts, fromRemote: Bool = true) {
        var plain = parts.text
        if plain == nil, let h = parts.html, !h.isEmpty {
            plain = MWBClipboardBundle.plainText(fromHTML: h)
        }

        let hasHTML = richFormatsEnabled && !(parts.html?.isEmpty ?? true)
        let hasRTF  = richFormatsEnabled && !(parts.rtf?.isEmpty ?? true)
        guard !(plain?.isEmpty ?? true) || hasHTML || hasRTF else {
            log("[剪贴板] ⚠️ 对端发来的内容解析后为空，已跳过写入（不动本机剪贴板）")
            return
        }

        pasteboard.clearContents()
        if let t = plain, !t.isEmpty { pasteboard.setString(t, forType: .string) }
        if hasHTML, let d = parts.html!.data(using: .utf8) {
            pasteboard.setData(d, forType: .html)
        }
        if hasRTF, let d = rtfData(parts.rtf!) {
            pasteboard.setData(d, forType: .rtf)
        }

        let cc = pasteboard.changeCount
        lastChangeCount = cc
        if fromRemote { lastSentText = plain }
    }

    /// RTF 是面向字节的格式（Windows 侧多为 ASCII，中文走 `\uNNNN` 转义）；
    /// 非 ASCII 时退回 UTF-8，都失败就不放这个类型，免得写出一个坏 RTF。
    private func rtfData(_ rtf: String) -> Data? {
        if let a = rtf.data(using: .ascii) { return a }
        return rtf.data(using: .utf8)
    }

    /// 只写纯文本（不带富文本类型）。保留给需要「干净文本」的场景。
    public func writeText(_ text: String, fromRemote: Bool = false) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let cc = pasteboard.changeCount
        lastChangeCount = cc
        if fromRemote { lastSentText = text }
    }

    public func readImage() -> NSImage? {
        if let data = pasteboard.data(forType: .tiff) { return NSImage(data: data) }
        if let data = pasteboard.data(forType: .png) { return NSImage(data: data) }
        return nil
    }

    public func writeImage(_ image: NSImage) {
        guard let tiff = image.tiffRepresentation else { return }
        pasteboard.clearContents()
        pasteboard.setData(tiff, forType: .tiff)
        lastChangeCount = pasteboard.changeCount
    }
}
