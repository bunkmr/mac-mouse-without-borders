// Listener.swift
// MWB 是网状互联：每台机器都会主动连别人，也会被别人连回来。
// 只出不进的话，Windows 侧不会把本机加入机器矩阵（表现为连上后立刻沉默、
// Since MWB UI 看不到这台 Mac）。因此必须在同一端口上监听并接受回连。
//
// 回连的处理流程与主动连接完全对称（实测）：
//   AES key/IV 相同 -> 发 16 字节预热块 -> 互发 10 个 Handshake -> 校验 Ack。

import Foundation
import Darwin

public final class MWBListener {
    public let port: UInt16
    public let securityKey: String
    public let machineName: String

    private var listenFD: Int32 = -1
    private var thread: Thread?
    private var running = false

    /// 已接受、且**仍然活着**的回连。
    ///
    /// ★★ 必须持强引用 —— 2026-09-23 回连风暴的根因就在这里"没人持有"：
    ///   `serve()` 里的 `conn` 是局部变量，`MWBConnection.startReceiveLoop()` 又是
    ///   `[weak self]`（线程不持有对象），于是**握手成功的一瞬间对象就析构**：
    ///   `deinit` 关掉 fd → 对端看到 RST → Windows 的 `REOPEN_WHEN_WSAECONNRESET`
    ///   立刻重连 → 再被 RST …… 打成每秒 3 次、永不停止的连接洪水，
    ///   最后把对端自己的 `too many connections` 保护也打出来。
    ///   现场铁证：旧版本 14 小时只有 **5** 次回连；出问题的版本 30 小时 **13313** 次。
    ///   顺带这也是"同一条回连的数据没人收"的根因（接收循环根本来不及跑）。
    private var live: [MWBConnection] = []
    private let liveLock = NSLock()

    /// 同时最多保留多少条回连。正常 MWB 只会维持 1~2 条，这只是防洪水兜底。
    public var maxLiveConnections = 24

    /// 当前还活着的回连条数（诊断用）。
    public var liveConnectionCount: Int {
        liveLock.lock(); defer { liveLock.unlock() }
        return live.count
    }

    /// 每条回连建立后回调（通常在这里启动接收循环）。
    public var onPeerConnected: ((MWBConnection) -> Void)?
    public var onLog: ((String) -> Void)?

    public init(port: UInt16, securityKey: String, machineName: String) {
        self.port = port
        self.securityKey = securityKey
        self.machineName = machineName
    }

    public func start(sharedMachineID: UInt32) -> Bool {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            onLog?("[监听] socket 创建失败: errno=\(errno)")
            return false
        }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = INADDR_ANY.bigEndian

        let bindRes = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                Darwin.bind(fd, sp, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindRes == 0 else {
            onLog?("[监听] 端口 \(port) 绑定失败: errno=\(errno)（可能有其他实例占用）")
            Darwin.close(fd)
            return false
        }
        guard Darwin.listen(fd, 8) == 0 else {
            onLog?("[监听] listen 失败: errno=\(errno)")
            Darwin.close(fd)
            return false
        }

        listenFD = fd
        running = true
        onLog?("[监听] 已在 \(port) 端口监听 Windows 回连")

        thread = Thread { [weak self] in
            self?.acceptLoop(sharedMachineID: sharedMachineID)
        }
        thread?.name = "MWBListener"
        thread?.start()
        return true
    }

    private func acceptLoop(sharedMachineID: UInt32) {
        var tv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(listenFD, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        while running {
            var remote = sockaddr()
            var len = socklen_t(MemoryLayout<sockaddr>.size)
            let peerFD = Darwin.accept(listenFD, &remote, &len)
            if peerFD < 0 { continue }

            Thread { [weak self] in
                guard let self else { Darwin.close(peerFD); return }
                self.serve(peerFD: peerFD, id: sharedMachineID)
            }.start()
        }
    }

    private func serve(peerFD: Int32, id: UInt32) {
        var peer = sockaddr_in()
        var plen = socklen_t(MemoryLayout<sockaddr_in>.size)
        var hostStr = "unknown"
        if getpeername(peerFD, withUnsafeMutablePointer(to: &peer) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { $0 }
            }, &plen) == 0 {
            var ip = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var a = peer.sin_addr
            inet_ntop(AF_INET, &a, &ip, socklen_t(INET_ADDRSTRLEN))
            hostStr = String(cString: ip)
        }

        onLog?("[监听] 收到来自 \(hostStr) 的回连，开始握手…")
        let conn = MWBConnection(host: hostStr, port: port,
                                 securityKey: securityKey,
                                 machineName: machineName, myID: id)
        conn.onLog = onLog
        conn.roleLabel = "回连"
        switch conn.attach(fd: peerFD) {
        case .failure(let e):
            onLog?("[监听] 回连绑定失败: \(e)")
            return
        case .success: break
        }
        switch conn.establishSession() {
        case .failure(let e):
            onLog?("[监听] 回连握手失败: \(e)")
            conn.close()
        case .success:
            onLog?("[监听] 回连握手成功 ✓  \(hostStr)")
            // ★ 顺序很重要：**先接住**再交给上层。反过来做的话，只要上层不留引用，
            //   对象在 `serve()` 返回时就没了（见 `live` 的注释）。
            adopt(conn)
            onPeerConnected?(conn)
        }
    }

    /// 收下一条回连：清理已死的、登记新的、必要时回收最旧的。
    ///
    /// 与 `serve()` 成功路径共用同一条代码路径，所以能直接拿它做回归自检。
    func adopt(_ conn: MWBConnection) {
        var trimmed: [MWBConnection] = []
        liveLock.lock()
        live.removeAll { $0.closed }          // 顺手把已经死掉的清出去
        live.append(conn)
        while live.count > maxLiveConnections {
            trimmed.append(live.removeFirst())
        }
        let count = live.count
        liveLock.unlock()

        if !trimmed.isEmpty {
            onLog?("[监听] 活跃回连超过 \(maxLiveConnections) 条，回收最旧的 \(trimmed.count) 条")
        }
        if count > 2 {
            onLog?("[监听] 当前活跃回连 \(count) 条（正常应为 1~2 条）")
        }
        for old in trimmed { old.close() }   // 别在锁里做 I/O
    }

    public func stop() {
        running = false
        if listenFD >= 0 { Darwin.close(listenFD); listenFD = -1 }
        liveLock.lock()
        let all = live
        live.removeAll()
        liveLock.unlock()
        for c in all { c.close() }
    }

    // MARK: - 回归自检

    /// 回归对象 = 2026-09-23「回连风暴」：监听器收下回连后**没人持有**它的强引用，
    /// 握手成功的一瞬间对象就析构 → `deinit` 关 fd → 对端 RST → 疯狂重连。
    ///
    /// 判据（四条，各钉住一个真实故障面）：
    ///   ① 断开我们本地那份引用后，对象**仍然活着**（= 监听器真的接住了）；
    ///   ② 回收上限生效（洪水时不会无限堆积 fd）；
    ///   ③ 被回收掉的那条**已关闭且被释放**（不留僵尸 fd）；
    ///   ④ `stop()` 之后 live 清空、且仍活着的连接都被关掉。
    ///
    /// 有效性由构造保证：把 `adopt` 里的 `live.append(conn)` 去掉，①必失败；
    /// 把 `live.removeAll { $0.closed }` 与上限回收去掉，②必失败。
    public static func retentionSelfTest() -> Bool {
        var ok = 0, total = 0
        let lis = MWBListener(port: 1, securityKey: "selftest", machineName: "MT")
        lis.maxLiveConnections = 3

        // ① 接得住：显式断掉本地强引用，只留监听器那一份
        total += 1
        weak var weakA: MWBConnection?
        var strongA: MWBConnection? = MWBConnection(host: "127.0.0.1", port: 1,
                                                    securityKey: "selftest", machineName: "MT")
        weakA = strongA
        lis.adopt(strongA!)
        strongA = nil
        if weakA == nil {
            print("  ✗ 回连没被接住：强引用一断就析构（对端会看到 RST → 风暴）")
        } else if lis.liveConnectionCount == 1 {
            ok += 1
            print("  ✓ 回连被接住（本地引用断开后对象仍活着）")
        } else {
            print("  ✗ 对象活着但没登记进 live（live=\(lis.liveConnectionCount)）")
        }

        // ② 上限回收
        total += 1
        var kept: [MWBConnection] = []
        for _ in 0..<10 {
            let c = MWBConnection(host: "127.0.0.1", port: 1,
                                  securityKey: "selftest", machineName: "MT")
            kept.append(c)
            lis.adopt(c)
        }
        if lis.liveConnectionCount == 3 {
            ok += 1
            print("  ✓ 超出上限后回收最旧的（live=3，上限 3）")
        } else {
            print("  ✗ 上限没生效：live=\(lis.liveConnectionCount)，期望 3")
        }

        // ③ 被回收的那条已关闭 + 已释放
        total += 1
        if weakA == nil {
            ok += 1
            print("  ✓ 被回收的回连已关闭并释放（无僵尸 fd）")
        } else {
            print("  ✗ 被回收的回连仍被持有（僵尸 fd）")
        }

        // ④ stop() 关干净
        total += 1
        let inLive = Array(kept.suffix(3))
        lis.stop()
        let allClosed = inLive.allSatisfy { $0.closed }
        if lis.liveConnectionCount == 0 && allClosed {
            ok += 1
            print("  ✓ stop() 清空并关闭了全部回连")
        } else {
            print("  ✗ stop() 没关干净：live=\(lis.liveConnectionCount) 都已关闭=\(allClosed)")
        }

        print("  结果: \(ok)/\(total)")
        return ok == total
    }
}
