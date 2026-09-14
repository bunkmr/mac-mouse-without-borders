// FileTransfer.swift
// 跨屏文件传输 —— **走 MWB 原生剪贴板协议**（不再有自建协议/独立端口/Windows 侧 agent）。
//
// 【历史】早期版本走自建通道：magic "MWBXFER1" + 独立端口 15110 + Windows 侧
// `Tools/mwb_file_agent.py` 接收。那套能用，但等于在 MWB 之外又养了一套协议：
//   - Windows 端必须额外跑一个 Python 程序，还得单独放行端口；
//   - 与 MWB 自身的剪贴板/拖放能力完全割裂，MWB 设置里的「传输文件」开关也不生效。
// 现在改为直接复用 MWB 原生的剪贴板通道（端口 TcpPort = 15100），
// Windows 侧**零额外程序**，用的是 PowerToys 自己的拖放实现。
//
// 【流程】本类只负责「准备文件 + 暂存 + 触发信令」，真正的字节由通道层收发：
//   1. 打包：多个文件或目录 → 先打成一个 zip（**MWB 原生一次只传一个文件**，
//      它的 `LastDragDropFile` 就是个单值字符串）；
//   2. 暂存到 `MWBClipboardChannel.stagedFile`；
//   3. 调 `signalDragDrop` 让 Client 发出 MWB 拖放信令
//      （ClipboardDragDrop 广播 + ClipboardDragDropOperation 定向 + 合成一次鼠标抬起）；
//   4. Windows 侧收到信令后，会**主动连回我们 15100** 拉取文件，
//      按 PostAction=Desktop 落到 `%USERPROFILE%\Desktop\MouseWithoutBorders\`；
//      若它连不进来，会改发 ClipboardAsk(78)，由 Client 触发 `pushStagedFile` 反向推送。
//
// 【落点差异（要注意）】MWB 的 desktop 分支不是「拖进某个文件夹」，而是
//   存到桌面的 MouseWithoutBorders 子目录并**打开该文件夹**。这是 PowerToys 自己的行为，
//   我们沿用原生语义，不另造一套。

import Foundation

public enum FileTransferError: Error, LocalizedError {
    case noFiles
    case prepareFailed(String)
    case notReady(String)

    public var errorDescription: String? {
        switch self {
        case .noFiles:              return "没有可发送的文件"
        case .prepareFailed(let s): return "预处理失败: \(s)"
        case .notReady(let s):      return "通道未就绪: \(s)"
        }
    }
}

public final class FileTransferClient {

    // MARK: - 配置

    /// 对端地址（仅用于日志/反向推送）。
    public var host: String = ""
    /// 剪贴板通道端口 = 主通道端口 - 1（MWB 约定：TcpPort=15100 剪贴板，TcpPort+1=15101 主通道）。
    public var port: UInt16 = 15100
    public var securityKey: String = ""
    public var onLog: ((String) -> Void)?
    /// 进度回调（保留签名；MWB 原生通道按 64KB 块推送，不再单独汇报进度）
    public var onProgress: ((Int64, Int64) -> Void)?

    /// 真正的 MWB 原生剪贴板通道（由 Client 注入）。
    public var channel: MWBClipboardChannel?
    /// 发送拖放信令（由 Client 注入）。
    public var signalDragDrop: ((URL) -> Void)?

    /// 上一次打包出来的临时 zip，下次发送时清掉（传输是异步的，不能发完就删）。
    private var pendingTemp: URL?
    private let lock = NSLock()

    public init() {}

    private func log(_ s: String) { onLog?(s) }

    // MARK: - 对外入口

    /// 发送文件到对端（走 MWB 原生协议）。请在后台线程调用。
    ///
    /// 返回成功只代表「已暂存并发出拖放信令」，真正的字节由对端拉取时按需发送。
    public func send(fileURLs urls: [URL]) -> Result<String, Error> {
        guard !urls.isEmpty else { return .failure(FileTransferError.noFiles) }
        guard let channel else { return .failure(FileTransferError.notReady("剪贴板通道未初始化")) }

        let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        for u in urls where !existing.contains(u) {
            log("[文件] 跳过不存在的路径: \(u.lastPathComponent)")
        }
        guard !existing.isEmpty else { return .failure(FileTransferError.noFiles) }

        // ① 打包：单个普通文件直接用；其余（多文件 / 目录）打成一个 zip
        let prepared: URL
        var isTemp = false
        if existing.count == 1, !isDirectory(existing[0]) {
            prepared = existing[0]
        } else {
            switch makeZip(existing) {
            case .success(let z): prepared = z; isTemp = true
            case .failure(let e): return .failure(e)
            }
        }

        // ② 清掉上一轮的临时包，再暂存本轮的
        lock.lock()
        let old = pendingTemp
        pendingTemp = isTemp ? prepared : nil
        lock.unlock()
        if let old { try? FileManager.default.removeItem(at: old) }

        channel.stagedFile = prepared
        log("[文件] 已暂存 \(prepared.lastPathComponent)（\(fmtBytes(fileSize(prepared)))）"
            + (isTemp ? "  ← 由 \(existing.count) 项打包而成" : ""))

        // ③ 发拖放信令，让对端进入「可接收」状态并主动来拉
        guard let signalDragDrop else {
            return .failure(FileTransferError.notReady("拖放信令未接线"))
        }
        signalDragDrop(prepared)

        return .success("已发起传输：\(prepared.lastPathComponent)"
            + "（\(fmtBytes(fileSize(prepared)))）—— 对端将存到 桌面\\MouseWithoutBorders\\")
    }

    /// 取消当前暂存（拖拽中途撤回时调用）。
    public func cancelStaged() {
        channel?.stagedFile = nil
    }

    public var hasStagedFile: Bool { channel?.stagedFile != nil }
    public var stagedFile: URL? { channel?.stagedFile }

    // MARK: - 打包

    private func isDirectory(_ url: URL) -> Bool {
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &d) && d.boolValue
    }

    private func fileSize(_ url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path))
            .flatMap { ($0[.size] as? NSNumber)?.int64Value } ?? 0
    }

    /// 把若干文件/目录打成一个 zip。
    ///
    /// 单个目录 → `ditto --keepParent`（保留顶层目录名，解压出来是个文件夹）。
    /// 多个条目 → 先全部拷进一个临时目录再 `--keepParent`，这样解压出来同样是
    /// 一个包裹目录，不会把文件散落一地。
    private func makeZip(_ urls: [URL]) -> Result<URL, Error> {
        let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory())
        let stamp = UUID().uuidString.prefix(8)

        var sources: [URL] = urls
        var parentName: String?
        var staging: URL?

        if urls.count > 1 {
            let dir = tmpRoot.appendingPathComponent("mwb-pack-\(stamp)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                for u in urls {
                    try FileManager.default.copyItem(at: u, to: dir.appendingPathComponent(u.lastPathComponent))
                }
            } catch {
                return .failure(FileTransferError.prepareFailed("暂存待打包文件失败: \(error.localizedDescription)"))
            }
            staging = dir
            parentName = dir.lastPathComponent
            sources = [dir]
        } else {
            parentName = urls[0].lastPathComponent
        }

        let out = tmpRoot.appendingPathComponent("mwb-\(stamp)-\(parentName ?? "files").zip")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        // --norsrc / --noextattr：不带 __MACOSX 与资源 fork，Windows 解压才干净
        p.arguments = ["-c", "-k", "--norsrc", "--noextattr", "--keepParent",
                       sources[0].path, out.path]
        p.standardOutput = nil
        p.standardError = nil
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            return .failure(FileTransferError.prepareFailed("ditto 无法启动: \(error.localizedDescription)"))
        }
        if let staging { try? FileManager.default.removeItem(at: staging) }
        guard p.terminationStatus == 0 else {
            return .failure(FileTransferError.prepareFailed("打包失败(\(p.terminationStatus))"))
        }
        return .success(out)
    }
}
