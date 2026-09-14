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
            onPeerConnected?(conn)
        }
    }

    public func stop() {
        running = false
        if listenFD >= 0 { Darwin.close(listenFD); listenFD = -1 }
    }
}
