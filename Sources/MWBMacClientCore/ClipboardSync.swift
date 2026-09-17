// ClipboardSync.swift
// 剪贴板跨屏同步（文本 + 图片，走 MWB 原生协议，主 15101 socket）。
//
// 【协议事实】（逐行核对 PowerToys src/modules/MouseWithoutBorders/App/Core/Clipboard.cs、
//  App/Helper/FormHelper.cs、App/Class/SocketStuff.cs）
//
// ① 文本：打包串 -> Encoding.Unicode(UTF-16LE) -> 裸 DEFLATE（DeflateStream）
//        -> 切成 48 字节/片 -> 每片塞进 64 字节大包的 byte16..63
//        -> 包 Type=ClipboardText(124)、Des=ID.ALL(0xFF)、走主 socket
// ② 图片：**PNG 原始字节，不压缩、不做任何编码**（FormHelper.cs: `im.Save(ms, ImageFormat.Png)`）
//        -> 同样切 48 字节/片 -> 包 Type=ClipboardImage(125)
//        接收端 `Image.FromStream(m)` ⇒ 必须是 PNG/JPEG 这类**自带格式的图片流**，
//        不能是裸像素/TIFF 头（Windows GDI+ 不认后者）。
// ③ 两者都以 Type=ClipboardDataEnd(76) 的空包收尾，接收端到它才整体处理。
// ④ **1MB 阈值**：`Clipboard.MAX_CLIPBOARD_DATA_SIZE_CAN_BE_SENT_INSTANTLY_TCP = 1MB`。
//    超过它就不直推了，改发 `Clipboard(69)`（心跳包）让对端**回来拉**：
//    对端在本机 15100 通道上握手，我们用 1024 字节定长头 `"{字节数}*image"` /
//    `"{字节数}*text"` 声明类型再发原始字节（见 SocketStuff.SendClipboardData）。
//    图片上限 `MAX_IMAGE_SIZE = 50MB`。
//
// ★★★ 最容易踩的坑：**文本载荷不是纯文本，是一个多格式打包串** ★★★
//   "TXT"+纯文本 + SEP + "HTM"+CF_HTML全文 + SEP [+ "RTF"+RTF源 + SEP]
//   SEP = "{4CFF57F7-BEDD-43d5-AE8F-27A61E886F2F}"
//   Windows 接收端会按 SEP 切分、砍掉前 3 字符、按 TXT/HTM/RTF 分发到不同剪贴板格式。
//   编解码细节与踩坑经过见 `ClipboardBundle.swift`。
//
// ★ 图片与文本的**优先级**：PowerToys 的 helper 是 `ContainsText()` 先于 `ContainsImage()`。
//   但浏览器里「复制图片」的剪贴板同时带图片和一段 URL 文本，纯文本优先会让我们
//   把 URL 当内容发过去、图片永远过不去。所以这里用「有图 && （没文本 或 文本就是个 URL）」
//   判定为图片，其余情况文本优先 —— 并且在日志里打出选了哪条路，便于事后核对。

import Foundation
import AppKit

public final class ClipboardSync {
    public static let shared = ClipboardSync()

    /// 本地剪贴板文本变化时回调（应把它按 MWB 协议推给对端）。
    public var onLocalText: ((String) -> Void)?
    /// 本地剪贴板图片变化时回调。参数是 **PNG 字节**（直接就是线上格式，无需再编码）。
    /// 调用方按大小决定走「即时分片推送」还是「发心跳等对端来拉」。
    public var onLocalImage: ((Data) -> Void)?
    /// 诊断日志回调。
    public var onLog: ((String) -> Void)?

    /// 是否启用剪贴板同步。
    public var enabled = true
    /// 是否同步图片剪贴板（关闭后只同步文本）。
    public var imageEnabled = true
    /// 是否把对端带来的富文本类型（HTML / RTF）一并写进本机剪贴板。
    ///
    /// 开着的行为才和 Windows 上原生 MWB 一致：粘进文本框得到干净文字，
    /// 粘进 Word / 微信这类富文本 App 能保留格式。
    /// 需要退回「只写纯文本」做对照时，设环境变量 `MWB_CLIP_RICH=0`。
    public var richFormatsEnabled = true

    /// 即时分片推送的上限，对齐 PowerToys
    /// `Clipboard.MAX_CLIPBOARD_DATA_SIZE_CAN_BE_SENT_INSTANTLY_TCP = 1024 * 1024`。
    /// 超过就发 `Clipboard(69)` 心跳包、让对端回来拉（效率高得多：认 64KB 一块，不是 48 字节一小包）。
    public static let instantLimit = 1024 * 1024
    /// 单张图片上限，对齐 PowerToys `FormHelper.MAX_IMAGE_SIZE = 50MB`。
    public static let imageLimit = 50 * 1024 * 1024
    /// 线上分片大小，对齐 PowerToys `Clipboard.DATA_SIZE = 48`。
    public static let chunkSize = 48

    private let pasteboard = NSPasteboard.general
    private var lastChangeCount: Int
    private var lastSentText: String?
    private var lastSentImageDigest: Int?
    private var pollTimer: DispatchSourceTimer?

    /// 远端分片的累积缓冲（文本与图片共用一条，用 `pendingIsImage` 区分批次）。
    private var pending: [UInt8] = []
    private var pendingIsImage = false
    private var pendingFrom: Date?

    private func log(_ s: String) { onLog?(s) }

    public init() {
        self.lastChangeCount = NSPasteboard.general.changeCount
        let env = ProcessInfo.processInfo.environment
        if env["MWB_CLIP_RICH"] == "0" { self.richFormatsEnabled = false }
        if env["MWB_CLIP_IMAGE"] == "0" { self.imageEnabled = false }
    }

    // MARK: - 分片工具（线上格式，客户端与自检共用）

    /// 把字节流切成 48 字节一片；末片不足则**补 0**（与 PowerToys 一致：
    /// 真实长度由接收端累积到 ClipboardDataEnd 后按自身格式判断，末片的 0 会被忽略）。
    public static func chunk(_ bytes: [UInt8], size: Int = ClipboardSync.chunkSize) -> [[UInt8]] {
        guard size > 0 else { return [] }
        var out: [[UInt8]] = []
        var i = 0
        while i < bytes.count {
            let n = min(size, bytes.count - i)
            var buf = [UInt8](repeating: 0, count: size)
            for k in 0..<n { buf[k] = bytes[i + k] }
            out.append(buf)
            i += size
        }
        return out
    }

    /// 判断一段字节是否像 PNG（8 字节魔数）。
    public static func looksLikePNG(_ d: Data) -> Bool {
        let magic: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard d.count >= magic.count else { return false }
        return Array(d.prefix(magic.count)) == magic
    }

    /// 剪贴板通道上声明类型用的「文件名」（PowerToys 只认 "image"/"text" 前缀）。
    public static func wireName(isImage: Bool) -> String { isImage ? "image" : "text" }

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

    /// 轮询一次本机剪贴板；文本变化则回调出去。返回本次要同步的文本（图片返回 nil）。
    @discardableResult
    public func pollLocal() -> String? {
        guard enabled else { return nil }
        let cc = pasteboard.changeCount
        guard cc != lastChangeCount else { return nil }
        lastChangeCount = cc

        let text = pasteboard.string(forType: .string)

        // ---- 图片优先的判据 ----
        // 有图片 且（没有纯文本 或 纯文本就是一个 URL）→ 判定为「复制的是图片」。
        // ★ 但**「能当文件读」的剪贴板一律让给文件通道**：Finder 里 ⌘C 一个 .png/.jpg 时，
        //   剪贴板常常同时带 `public.file-url` 与**缩略图**（TIFF/PICT），若在这里走图片分支，
        //   发过去的就是那张缩略小图 —— 用户看到的现象是"复制照片过去变成一张很小很糊的图"。
        //   文件通道（`Client.checkClipboardFiles`）会把原文件完整送过去，语义才对。
        if imageEnabled, !hasLocalFileURL(), hasLocalImage(),
           text == nil || text!.isEmpty || Self.looksLikeURL(text!) {
            if let png = localImagePNG(), !png.isEmpty {
                let digest = png.hashValue
                if digest != lastSentImageDigest {
                    lastSentImageDigest = digest
                    lastSentText = nil
                    log("[剪贴板] 本机复制了图片（PNG \(fmtBytes(Int64(png.count)))）"
                        + (text?.isEmpty == false ? "（剪贴板另有 URL 文本，已按图片处理）" : "")
                        + "，正在发送…")
                    onLocalImage?(png)
                    return nil
                }
                return nil
            }
        }

        // ---- 文本 ----
        guard text != nil, !(text!.isEmpty) else { return nil }
        guard text != lastSentText else { return nil }
        lastSentText = text
        lastSentImageDigest = nil
        log("[剪贴板] 本机复制了 \(text!.count) 个字符，正在发送…")
        onLocalText?(text!)
        return text
    }

    /// 把文本编码成 MWB 的线格式分片（打包串 + UTF-16LE + 裸 DEFLATE，48 字节/片）。
    /// 返回 nil 表示文本为空或压缩失败。**这条路径同时用于「即时推送」和「对端来拉」**
    /// （对端来拉时把整串写进 15100 通道，头里声明 `"{字节数}*text"`）。
    ///
    /// ★ 必须打上 `TXT` 前缀与分隔符。Windows 端 `SetClipboardData` 是按前缀分发的：
    ///   发裸文本虽然会落到它的 else 兜底分支侥幸可用，但会记一条
    ///   "Invalid clipboard format received!"，而且**文本若以 TXT/HTM/RTF 开头会被砍掉前 3 个字符**。
    public func encodeForWire(_ text: String) -> [UInt8]? {
        guard let packed = MWBClipboardBundle.pack(text: text) else { return nil }
        guard let bytes = MWBDeflate.encodeText(packed), !bytes.isEmpty else { return nil }
        return bytes
    }

    /// 本机剪贴板里有没有图片数据。
    private func hasLocalImage() -> Bool {
        pasteboard.data(forType: .png) != nil || pasteboard.data(forType: .tiff) != nil
    }

    /// 本机剪贴板能不能当「文件」读出来（Finder ⌘C、以及部分 App 复制图片时附带的临时文件）。
    /// 为 true 时图片分支要让位 —— 否则会把文件缩略图当成"复制的图片"发出去。
    private func hasLocalFileURL() -> Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: nil)
    }

    /// 取本机图片并转成 PNG 字节。
    /// 已经是 PNG 就原样用（体积最小）；否则从 TIFF 转（截图、Skim、预览复制的多为此）。
    private func localImagePNG() -> Data? {
        if let d = pasteboard.data(forType: .png), !d.isEmpty { return d }
        guard let tiff = pasteboard.data(forType: .tiff),
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// 一段文本是否只是个网址（浏览器复制图片时会附带的干扰项）。
    private static func looksLikeURL(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.contains("\n") else { return false }
        let l = t.lowercased()
        return l.hasPrefix("http://") || l.hasPrefix("https://")
    }

    // MARK: - 远端 -> 本地

    /// 累积一个远端剪贴板分片（ClipboardText(124) 或 ClipboardImage(125) 的 byte16..63）。
    ///
    /// 一批数据必须同类型 —— 中途换类型说明上一批丢了 End，直接丢弃重来。
    public func appendRemoteChunk(_ bytes: [UInt8], isImage: Bool = false) {
        let stale = pendingFrom.map { Date().timeIntervalSince($0) > 5 } ?? true
        if stale || (!pending.isEmpty && pendingIsImage != isImage) {
            pending.removeAll(keepingCapacity: true)
        }
        pendingIsImage = isImage
        pendingFrom = Date()
        pending.append(contentsOf: bytes)
        // 防御：万一对方一直不发 End，别让内存无限增长
        let cap = isImage ? Self.imageLimit : Self.instantLimit
        if pending.count > cap { pending.removeAll(keepingCapacity: true); pendingFrom = nil }
    }

    /// 收到 ClipboardDataEnd(76)：按批次类型整体处理（图片直接解码，文本解压 + 拆包）。
    /// 返回写入的纯文本（图片或失败返回 nil）。
    @discardableResult
    public func finishRemote() -> String? {
        let data = pending
        let isImage = pendingIsImage
        pending.removeAll(keepingCapacity: true)
        pendingFrom = nil
        pendingIsImage = false
        guard !data.isEmpty else { return nil }

        if isImage {
            _ = acceptRemoteImage(Data(data))
            return nil
        }
        return acceptRemoteWireText(data)
    }

    /// 接收**线上格式的文本字节**（DEFLATE 压缩的打包串）。
    /// 两条来源都用它：主 socket 的 ClipboardText 分片、以及 15100 通道拉回来的 `*text` 数据。
    @discardableResult
    public func acceptRemoteWireText(_ deflated: [UInt8]) -> String? {
        guard let raw = MWBDeflate.decodeText(deflated) else {
            log("[剪贴板] ⚠️ 远端剪贴板解压失败（\(deflated.count) 字节，可能是压缩格式不匹配）")
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
        log("[剪贴板] ← 已从 Windows 接收文本（\(parts.sawTaggedEntry ? "打包串" : "裸文本") \(shape)）")
        return plain.isEmpty ? nil : plain
    }

    /// 接收 PNG 字节并写进本机剪贴板。
    /// 来源：主 socket 的 ClipboardImage(125) 分片累积，或 15100 通道拉回的 `*image` 数据。
    @discardableResult
    public func acceptRemoteImage(_ png: Data) -> Bool {
        guard imageEnabled else {
            log("[剪贴板] 收到远端图片（\(fmtBytes(Int64(png.count)))），但图片同步已在设置里关闭，已忽略")
            return false
        }
        guard let img = NSImage(data: png) else {
            log("[剪贴板] ⚠️ 远端图片解码失败（\(png.count) 字节，"
                + "前 8 字节=\(png.prefix(8).map { String(format: "%02x", $0) }.joined())）")
            return false
        }
        writeImage(img, png: png)
        log("[剪贴板] ← 已从 Windows 接收图片（\(fmtBytes(Int64(png.count)))"
            + (Self.looksLikePNG(png) ? " PNG" : " 非 PNG") + "）")
        return true
    }

    /// 远端批次是否正在累积中。
    public var hasPendingRemote: Bool { !pending.isEmpty }

    /// 丢弃当前远端批次（例如对端推的是我们不支持的类型）。
    public func dropPending() {
        pending.removeAll(keepingCapacity: true)
        pendingFrom = nil
        pendingIsImage = false
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
        lastSentImageDigest = nil
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
        lastSentImageDigest = nil
        if fromRemote { lastSentText = text }
    }

    public func readImage() -> NSImage? {
        if let data = pasteboard.data(forType: .tiff) { return NSImage(data: data) }
        if let data = pasteboard.data(forType: .png) { return NSImage(data: data) }
        return nil
    }

    /// 写图片进本机剪贴板。同时放 `.png` 与 `.tiff` 两种类型 ——
    /// Mac 上多数 App（预览/微信/备忘录）认 TIFF，而 PNG 体积小、也是我们推给 Windows 的格式。
    public func writeImage(_ image: NSImage, png: Data? = nil) {
        pasteboard.clearContents()
        if let png, !png.isEmpty { pasteboard.setData(png, forType: .png) }
        if let tiff = image.tiffRepresentation { pasteboard.setData(tiff, forType: .tiff) }
        let cc = pasteboard.changeCount
        lastChangeCount = cc
        lastSentImageDigest = png?.hashValue
        lastSentText = nil
    }

    // MARK: - 离线自检（图片线格式）

    /// 图片剪贴板线格式的离线断言，供 `mwbmac --clip-image-selftest` 使用。
    /// 返回 (通过数, 总数, 失败说明)。
    public static func imageSelfTest() -> (Int, Int, [String]) {
        var pass = 0, total = 0
        var fails: [String] = []
        func check(_ name: String, _ ok: Bool) {
            total += 1
            if ok { pass += 1 } else { fails.append(name) }
        }

        // ① 分片：末片补 0、片数正确、按 48 字节对齐
        //   100 字节 → 3 片：前两片满，第 3 片只有 4 个真字节（下标 0..3），从下标 4 起补 0。
        let data = [UInt8](repeating: 0xAB, count: 100)
        let chunks = chunk(data)
        check("100 字节 → 3 片", chunks.count == 3)
        check("每片都是 48 字节", chunks.allSatisfy { $0.count == 48 })
        check("末片真数据 4 字节 + 其余补 0",
              chunks[2][0] == 0xAB && chunks[2][3] == 0xAB
              && chunks[2][4] == 0 && chunks[2][47] == 0)

        // ② 重组：按真实长度截断后必须与原数据逐字节相同
        var flat: [UInt8] = []
        for c in chunks { flat.append(contentsOf: c) }
        let rebuilt = Array(flat.prefix(data.count))
        check("分片 → 重组 逐字节一致", rebuilt == data)

        // ③ 空数据不该产出任何片（避免发一个只有 End 的空批次）
        check("空数据 → 0 片", chunk([]).isEmpty)

        // ④ 48 的整数倍不额外补片
        check("96 字节 → 2 片", chunk([UInt8](repeating: 1, count: 96)).count == 2)

        // ⑤ 真实 PNG 往返：用一段最小合法 PNG 头 + 随机体，模拟 1MB 级别的图片
        var png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        var seed: UInt32 = 0x1234_5678
        for _ in 0..<(512 * 1024) {                    // 512KB，约 10923 片
            seed = seed &* 1_103_515_245 &+ 12_345
            png.append(UInt8((seed >> 16) & 0xFF))
        }
        let pngData = Data(png)
        check("PNG 魔数判定 ✓", looksLikePNG(pngData))
        check("非 PNG 不误判 ✓", !looksLikePNG(Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])))
        let big = chunk(png)
        var flat2: [UInt8] = []
        flat2.reserveCapacity(big.count * 48)
        for c in big { flat2.append(contentsOf: c) }
        check("512KB PNG 分片重组一致", Array(flat2.prefix(png.count)) == png)
        check("512KB PNG 片数 = ceil(524296/48)", big.count == (png.count + 47) / 48)
        // 512KB < 1MB → 仍走 48 字节/片直推；阈值判定本身也是要守的契约（对齐 PowerToys）
        check("512KB PNG 仍走即时推送（< 1MB 阈值）", png.count < instantLimit)
        check("1MB + 1 字节 判定为需要回拉", 1024 * 1024 + 1 > instantLimit)
        check("恰好 1MB 判定为即时推送", 1024 * 1024 <= instantLimit)

        // ⑥ 通道类型名（PowerToys 只认前缀 "image"/"text"）
        check("通道类型名 image", wireName(isImage: true) == "image")
        check("通道类型名 text", wireName(isImage: false) == "text")

        // ⑦ 阈值常量必须与 PowerToys 一致，否则对端不会按我们预期的方式回拉
        check("即时推送阈值 = 1MB", instantLimit == 1024 * 1024)

        return (pass, total, fails)
    }
}
