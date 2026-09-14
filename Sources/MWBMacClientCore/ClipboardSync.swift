// ClipboardSync.swift
// 剪贴板文本跨屏同步（走 MWB 原生协议，主 15101 socket）。
//
// 【协议事实】（逐行核对 PowerToys src/modules/MouseWithoutBorders/App/Core/Clipboard.cs）
//  源端：文本 -> Encoding.Unicode(UTF-16LE) 字节 -> 裸 DEFLATE（DeflateStream）
//        -> 切成 48 字节/片 -> 每片塞进 64 字节大包的 byte16..63
//        -> 包 Type=ClipboardText(124)、Des=ID.ALL(0xFF)、走主 socket
//        -> 最后补一个 Type=ClipboardDataEnd(76) 的空包收尾（**接收端到它才整体解压**）
//  接收端：Receiver.cs 的 ClipboardText case **没有任何门禁**（不要求先握手、
//        不依赖 SwitchToMachine），直接把 byte16..63 追加进内存流，收到 76 才解压。
//        => 我们可以在已建立的连接上**主动推**剪贴板，无需次级 socket。
//  末片：不足 48 字节时补 0；真实长度由 DEFLATE 流自身的结束符决定。

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

    /// 把文本编码成 MWB 的线格式分片（UTF-16LE + 裸 DEFLATE，48 字节/片）。
    /// 返回 nil 表示文本为空或压缩失败。
    public func encodeForWire(_ text: String) -> [UInt8]? {
        guard let bytes = MWBDeflate.encodeText(text), !bytes.isEmpty else { return nil }
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

    /// 收到 ClipboardDataEnd(76)：整体解压并写入本机剪贴板。
    /// 返回写入成功的文本（nil 表示解压失败或内容为空）。
    @discardableResult
    public func finishRemote() -> String? {
        let data = pending
        pending.removeAll(keepingCapacity: true)
        pendingFrom = nil
        guard !data.isEmpty else { return nil }

        guard let text = MWBDeflate.decodeText(data) else {
            log("[剪贴板] ⚠️ 远端剪贴板解压失败（\(data.count) 字节，可能是压缩格式不匹配）")
            return nil
        }
        guard !text.isEmpty else { return nil }

        writeText(text, fromRemote: true)
        log("[剪贴板] ← 已从 Windows 接收 \(text.count) 个字符")
        return text
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

    /// 写入本机剪贴板。fromRemote=true 时同步更新 lastChangeCount/lastSentText，
    /// 避免刚写进去的内容又被当成「本机复制」推回对端（剪贴板回环）。
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
