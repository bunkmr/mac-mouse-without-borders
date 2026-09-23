// Connection.swift
// TCP 连接 + 加密层 + 握手 + 收发包循环。
//
// 【实测锁定】（针对真实 Windows 端抓包穷举所得）
//  1. TCP 连接端口 15101（键鼠）/ 15100（剪贴板）。
//  2. AES-256-CBC，key = PBKDF2-HMAC-SHA1(UTF8(安全密钥), UTF16LE("18446744073709551615"), 50000, 32)，
//     IV = ASCII("1844674407370955")。收发同 key/IV，但各维护一条 CBC 链。
//  3. 无明文 salt/IV 头交换。连接建立后双方立刻互发一个 16 字节随机块预热 CBC 链，
//     该块必须被消耗掉，否则后续所有包的解密全部错位。
//  4. 握手: 发送 10 个 Handshake(126)（含随机 Machine1-4 挑战）；
//     收到对端 Handshake → 回 HandshakeAck(127) = 挑战按位取反；
//     收到与自己挑战匹配的 Ack → 双向认证完成。
//  5. magic(byte2..3, 16 位小端) 对端强校验；其推导公式未能反推，
//     故采用自校准：首个 checksum 合法的对端包到来时直接采用它的 magic。

import Foundation

public enum MWBConnectionError: Error {
    case connectFailed(Error)
    case handshakeFailed
    case readFailed
    case writeFailed
    case cryptoError(MWBCryptoError)
}

public final class MWBConnection {
    public let host: String
    public let port: UInt16
    public let securityKey: String
    public let machineName: String
    /// 本机机器 ID（同进程内所有连接共享同一个 ID）。
    public var myID: UInt32

    /// ★ 只用**裸 fd** 做 I/O，不再走 `CFStream`（NSStream）。
    ///
    /// 【为什么必须去掉 CFStream】`CFStreamCreatePairWithSocket` 会**自己再 dup 一份 fd**：
    /// 2026-09-23 实测 `lsof` 里**同一个 socket 出现在两个 fd 上**（同一内核地址、两个 fd 号）。
    /// 后果是"关不掉"—— 只 `Darwin.close(我们那份)` 时 TCP 连接**依然 ESTABLISHED**
    /// （CFStream 那份还开着），于是每次 `reconnect()` 都留下一条**僵尸连接**：
    /// 现场实测一个实例攒了 4 条到 Windows 的僵尸 ESTABLISHED 连接 + 6 个关不掉的 fd，
    /// 对端看到"同一个 Mac 开了 4 条连接"便反复 `Closing duplicated socket`。
    /// 换成裸 fd 后，"谁持有 fd / 什么时候真正关掉"才是确定的。
    ///
    /// 附带收益：`SO_RCVTIMEO` 现在真的生效了（旧注释见 `Client.armConnectWatchdog`：
    /// 它对 NSInputStream 无效）。目前**故意不设**读超时，保持"阻塞到有数据/EOF"的语义。
    private var socketFD: Int32 = -1

    /// 这条连接的角色，只用于日志与自检定位（"主动" / "回连"）。
    public var roleLabel = "主动"
    private var encryptCtx: CBCContext?
    private var decryptCtx: CBCContext?
    private var magic: UInt16 = 0
    private var magicLearned = false
    private var nextPacketID: UInt32 = 1
    private var receiveThread: Thread?
    private var isClosed = false

    /// 序列化「加密 + 写出」。
    ///
    /// ★ 这是本项目最隐蔽也最致命的一个并发缺陷的修复点。
    /// `send()` 会被三个线程同时调用：
    ///   ① 主线程      —— 键鼠事件回调（onCaptured）
    ///   ② 接收线程    —— handle() 里回显 Hello / 心跳 / Ack
    ///   ③ 剪贴板后台队列 —— 文本分片推送
    /// 而 AES-CBC 是**有状态的链**（每个包的密文依赖前一个包的最后一块），socket
    /// 字节流也不允许交错。没有锁时两个线程会各自推进同一条链、把密文互相插队，
    /// 对端拿单条链解密必然整体错位 → checksum 全失败 → MWB 判定我们非法并断 TCP。
    ///
    /// 现场表现（2026-09-14 日志实锤）：用着用着突然「鼠标延时不跟手、一顿一顿」，
    /// 之后 writeFailed 刷了 1869 行，而连接其实早就死了。
    /// 用递归锁是因为 send() 持锁后 writeRaw() 还会再取一次。
    private let sendLock = NSRecursiveLock()

    /// 接收线程的代际号。重连会换一个新的接收线程；旧线程退出时靠它判断
    /// "我还是不是当前那一个"，避免旧线程把新连接标记成已关闭。
    /// 访问一律走下面的存取器（会加 stateLock）。
    private let stateLock = NSLock()
    private var _receiveGeneration = 0
    private var receiveGeneration: Int {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _receiveGeneration }
        set { stateLock.lock(); _receiveGeneration = newValue; stateLock.unlock() }
    }

    public var onPacket: ((DataPacket) -> Void)?
    public var onLog: ((String) -> Void)?
    /// 读侧断开（对端关闭 / 读超时 / 字节流错位）时回调。
    /// 这是链路死掉的**最早**信号 —— 比等写失败快一个心跳周期。
    public var onDisconnected: ((String) -> Void)?

    /// 握手阶段自校准出来的 16 位魔数。
    /// 剪贴板通道（15100）要复用它：那边虽然不跑握手，但头包同样带上魔数保持一致。
    public var learnedMagic: UInt16 { magic }

    public init(host: String, port: UInt16, securityKey: String, machineName: String, myID: UInt32 = 0) {
        self.host = host
        self.port = port
        self.securityKey = securityKey
        self.machineName = machineName
        self.myID = myID
    }

    // MARK: - 连接 + 握手

    public func connect() -> Result<Void, MWBConnectionError> {
        isClosed = false
        switch establishSocket() {
        case .failure(let e): return .failure(e)
        case .success: break
        }
        return establishSession()
    }

    /// 把已 accept 的 socket fd 挂到本连接上（供回连监听器使用）。
    ///
    /// ⚠️ 挂上之后**调用方必须持有这个连接对象**（见 `MWBListener.adopt`）：
    /// 对象一析构，`deinit` 就会把 fd 关掉，对端立刻看到 RST。
    public func attach(fd: Int32) -> Result<Void, MWBConnectionError> {
        socketFD = fd
        applySocketOptions(fd: fd)
        return .success(())
    }

    /// 在已就绪的 socket 上跑完整加密握手（主动连接与被动接受都要走这套流程，
    /// 实测 MWB 两端行为对称：都是先发 16 字节预热块，再发 10 个 Handshake）。
    public func establishSession() -> Result<Void, MWBConnectionError> {
        // 1) 密钥与 IV（实测：PBKDF2-SHA1 / 固定 salt / 固定 IV）
        let key: [UInt8]
        switch MWBCrypto.deriveKey(securityKey: securityKey) {
        case .success(let k): key = k
        case .failure(let e): return .failure(.cryptoError(e))
        }
        let iv = MWBCrypto.legacyIV()
        encryptCtx = CBCContext(key: key, iv: iv)
        decryptCtx = CBCContext(key: key, iv: iv)

        if myID == 0 { myID = UInt32.random(in: 1...UInt32.max - 1) }
        if myID == 255 { myID = 1 }

        log("[连接] socket 就绪; AES key=\(key.prefix(8).map { String(format: "%02x", $0) }.joined())… IV=\(String(decoding: iv, as: UTF8.self))")

        // 2) 虚拟 16 字节块：预热 CBC 链（对端也会发，后面接收时要消耗掉）
        let dummy = MWBCrypto.randomBytes(16)
        switch encryptCtx!.encrypt(dummy) {
        case .failure(let e): return .failure(.cryptoError(e))
        case .success(let ct):
            switch writeRaw(ct) { case .failure(let e): return .failure(e); case .success: break }
        }
        log("[连接] 已发送 CBC 预热块")

        // 3) 握手（内部完成 magic 自校准）
        switch doHandshake() {
        case .failure(let e): return .failure(e)
        case .success: break
        }

        // 4) 注册：广播 HeartbeatEx
        var hb = DataPacket(type: .heartbeatEx, src: myID, des: 255)
        hb.machineName = machineName
        if case .failure(let e) = send(hb) {
            log("[连接] 注册心跳发送失败: \(e)")
        }

        log("[连接] 已与 \(host):\(port) 完成双向认证并注册")
        return .success(())
    }

    private func log(_ s: String) { onLog?(s) }

    private func doHandshake() -> Result<Void, MWBConnectionError> {
        setRecvTimeout(seconds: 8)
        defer { setRecvTimeout(seconds: 0) }

        guard let dec = decryptCtx else { return .failure(.cryptoError(.aesFailed)) }

        // 3a) 消耗对端的 16 字节预热块
        //
        // ★ 这一读成不成功，是区分两种**完全不同**故障的唯一判据（2026-09-14 踩坑记录）：
        //    （甲）对端一个字节都没发 → 对端要么残留了半开会话（我们上次退出没发 ByeBye）、
        //          要么根本没在跑 MWB、要么端口被别的程序占着；
        //    （乙）对端发了字节、但解密成乱码 → 才是真正的「安全密钥不对」。
        // 以前的代码两种情况都打「安全密钥不正确」，把排查方向直接引到密钥上，
        // 白查了一轮 —— 所以这里必须分开报，并且明确说「这不是密钥问题」。
        switch readRaw(16) {
        case .failure:
            log("[握手] ✗ 对端在超时内**没有发送任何数据**（未读到 16 字节预热块）")
            log("[握手]    → 这不是密钥问题。常见原因：① 对端残留了半开会话"
                + "（我们上次退出时没发 ByeBye）② 对端 MWB 没在运行 ③ 对端 15101 被别的程序占着")
            return .failure(.handshakeFailed)
        case .success(let blk):
            _ = dec.decrypt(blk)
        }

        // 3b) 读首个包，仅用 checksum 判定 -> 自校准 magic
        //     预热块既然读到了，说明对端在正常说话；此时 checksum 不过才是真的密钥/协议不匹配。
        guard let first = receiveRawPacket(), MWBCrypto.checksumValid(first) else {
            log("[握手] 首包 checksum 校验失败 —— 安全密钥不正确或对方并非 MWB")
            return .failure(.handshakeFailed)
        }
        magic = MWBCrypto.readMagic(first)
        magicLearned = true
        log("[握手] magic 自校准成功 = 0x\(String(magic, radix: 16)) (来自对端)")

        // 3c) 构造我方挑战并发送 10 个 Handshake
        var hs = DataPacket(type: .handshake, id: myID, src: myID, des: 255)
        let c = MWBCrypto.randomBytes(16)
        hs.machine1 = readU32(c, 0)
        hs.machine2 = readU32(c, 4)
        hs.machine3 = readU32(c, 8)
        hs.machine4 = readU32(c, 12)
        hs.machineName = machineName

        let expect1 = ~hs.machine1
        let expect2 = ~hs.machine2
        let expect3 = ~hs.machine3
        let expect4 = ~hs.machine4

        log("[握手] 本机ID=0x\(String(myID, radix: 16))，发送 10 个 Handshake 挑战…")
        for i in 0..<10 {
            var p = hs
            p.id = myID &+ UInt32(i)
            switch send(p) { case .failure(let e): return .failure(e); case .success: break }
        }

        // 3d) 先把刚才那个包处理掉，再进入循环
        var buf = first
        MWBCrypto.clearStamp(&buf)
        if let p = DataPacket.parse(buf) {
            if case .failure(let e) = handleHandshakePacket(p, our: (expect1, expect2, expect3, expect4)) {
                if case .handshakeFailed = e { log("[握手] 首个包处理异常") ; return .failure(e) }
            } else if handshakeDone {
                return .success(())
            }
        }

        // 3e) 循环处理后续包
        for _ in 0..<40 {
            guard let buf2 = receiveRawPacket() else {
                log("[握手] 接收超时/中断")
                return .failure(.readFailed)
            }
            guard MWBCrypto.validatePacket(buf2, magic: magic) else {
                log("[握手] 收到校验失败的包，忽略")
                continue
            }
            var b = buf2
            MWBCrypto.clearStamp(&b)
            guard let p = DataPacket.parse(b) else { continue }
            if handshakeDone { return .success(()) }
            _ = handleHandshakePacket(p, our: (expect1, expect2, expect3, expect4))
            if handshakeDone { return .success(()) }
        }
        return .failure(.handshakeFailed)
    }

    private var handshakeDone = false

    /// 收到 Handshake 就回 Ack；收到与自己挑战匹配的 Ack 就标记完成。
    private func handleHandshakePacket(_ p: DataPacket,
                                       our: (UInt32, UInt32, UInt32, UInt32)) -> Result<Void, MWBConnectionError> {
        if p.type == .handshake {
            log("[握手] 收到对端 Handshake (src=0x\(String(p.src, radix: 16)))，回送 Ack")
            var ack = DataPacket(type: .handshakeAck, id: p.id, src: myID, des: p.src)
            ack.machine1 = ~p.machine1
            ack.machine2 = ~p.machine2
            ack.machine3 = ~p.machine3
            ack.machine4 = ~p.machine4
            ack.machineName = machineName
            return send(ack)
        } else if p.type == .handshakeAck {
            if p.machine1 == our.0 && p.machine2 == our.1 &&
               p.machine3 == our.2 && p.machine4 == our.3 {
                log("[握手] 双向认证完成 ✓  对端机器名 = \(p.machineName)"
                    + "  对端 MachineID = 0x\(String(p.src, radix: 16)) (\(p.src))"
                    + "  [本机ID = 0x\(String(myID, radix: 16)) (\(myID))]")
                handshakeDone = true
            }
            return .success(())
        }
        return .success(())
    }

    private func readU32(_ b: [UInt8], _ off: Int) -> UInt32 {
        (UInt32(b[off]) << 24) | (UInt32(b[off + 1]) << 16) | (UInt32(b[off + 2]) << 8) | UInt32(b[off + 3])
    }

    // MARK: - Socket

    private func establishSocket() -> Result<Void, MWBConnectionError> {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        hints.ai_family = AF_UNSPEC
        var res: UnsafeMutablePointer<addrinfo>?
        if getaddrinfo(host, "\(port)", &hints, &res) != 0 || res == nil {
            return .failure(.connectFailed(NSError(domain: "MWB", code: -2,
                userInfo: [NSLocalizedDescriptionKey: "DNS 解析失败: \(host)"])))
        }
        defer { freeaddrinfo(res) }

        var sock: Int32 = -1
        var connected = false
        var info = res
        while let ai = info {
            let fd = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
            if fd < 0 { info = ai.pointee.ai_next; continue }

            let flags = fcntl(fd, F_GETFL, 0)
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

            let r = Darwin.connect(fd, ai.pointee.ai_addr, socklen_t(ai.pointee.ai_addrlen))
            if r == 0 {
                connected = true
            } else if errno == EINPROGRESS {
                var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                let pr = poll(&pfd, 1, 5000)
                if pr > 0 && (pfd.revents & Int16(POLLOUT)) != 0 {
                    var err = 0
                    var len = socklen_t(MemoryLayout<Int32>.size)
                    getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
                    connected = (err == 0)
                }
            }

            if connected {
                let f = fcntl(fd, F_GETFL, 0)
                _ = fcntl(fd, F_SETFL, f & ~O_NONBLOCK)
                applySocketOptions(fd: fd)
                sock = fd
                break
            }
            Darwin.close(fd)
            info = ai.pointee.ai_next
        }

        guard connected, sock >= 0 else {
            return .failure(.connectFailed(NSError(domain: "MWB", code: -3,
                userInfo: [NSLocalizedDescriptionKey: "无法连接 \(host):\(port)（超时或被拒绝）"])))
        }

        socketFD = sock
        return .success(())
    }

    private func setRecvTimeout(seconds: Int) {
        guard socketFD >= 0 else { return }
        var tv = timeval()
        tv.tv_sec = seconds
        tv.tv_usec = 0
        withUnsafePointer(to: &tv) { ptr in
            _ = setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, ptr, socklen_t(MemoryLayout<timeval>.size))
        }
    }

    /// ★★ 2026-09-23 事故：`SIGPIPE` 会**静默杀进程**，且默认不可捕获、不留任何痕迹。
    ///
    /// 【现象】App 莫名其妙消失：`/tmp/mwb_gui.log` 在断链重连的半截处**突然断掉**
    ///   （既没有 `[GUI] 收到退出信号`，也没有 `[GUI] 退出 MWB`），
    ///   `DiagnosticReports/` 里**没有任何崩溃报告**（因为 SIGPIPE 不是崩溃，是"正常"终止）。
    ///   唯一能查出真相的地方是系统日志：
    ///     `launchd: exited due to SIGPIPE | sent by MWBMacClientApp[PID], ran for …`
    ///   实测 2026-09-23 一天被杀 **3 次**：16:06:42 / 17:01:07（存活仅 10s）/ 18:04:14。
    ///
    /// 【根因：本工程自己引入的回归】v1.4.3 把 I/O 从 `CFStreamCreatePairWithSocket`
    ///   换成裸 fd 后，**丢掉了 CFStream 内建的等价的 `SO_NOSIGPIPE` 保护**。
    ///   于是「链路刚断、socket 已 RST，而发送线程还在往里写」的那个窗口里，
    ///   内核直接给进程抛 SIGPIPE → 默认动作 = terminate ⇒ 无日志无报告地死掉。
    ///   （写失败本该只是 `writeFailed` → 看门狗重连，却被升级成了进程级死亡。）
    ///
    /// 【双保险】① 进程级 `signal(SIGPIPE, SIG_IGN)`（兜底，防将来别处再踩）；
    ///          ② 每个 socket 上 `SO_NOSIGPIPE`（精准，macOS 特有）；
    ///   两者齐备后，往死 socket 写只会返回 `-1` + `EPIPE`，走正常失败路径。
    ///   自检：`--sigpipe-selftest`（阳性对照 `--sigpipe-selftest-raw` 必须被 141 杀掉）。
    private static let sigpipeIgnored: Void = {
        signal(SIGPIPE, SIG_IGN)
    }()

    /// 幂等：确保进程级已忽略 `SIGPIPE`（任何 socket 建立前都应完成）。
    public static func installSIGPIPEIgnore() {
        _ = sigpipeIgnored
    }

    /// 给 socket 设三个关键选项（主动连接与被动接受两条路径都要设）。
    ///
    /// 1. **TCP_NODELAY** —— 不设的话 Nagle 会把我们每 5ms 一颗的小鼠标包攒起来
    ///    再发（还会和 delayed-ACK 互相等，最坏叠加 ~40ms）。对端收到的是
    ///    「一批一批」的坐标，看起来就是**鼠标延时、闪烁、一顿一顿，像回报率不对**。
    ///    PowerToys 的 MWB 自己也是 `TcpClient.NoDelay = true`。
    /// 2. **SO_SNDTIMEO = 2s** —— `send()` 是阻塞写且持有 sendLock；若对端不读了，
    ///    没有写超时会把主线程（事件回调）和接收线程（回显心跳）一起永久卡死。
    ///    有超时则退化成 `writeFailed`，交给 Client 的看门狗去做降级 + 重连。
    /// 3. **SO_NOSIGPIPE** —— 关键中的关键，见上方 `sigpipeIgnored` 的整段事故说明：
    ///    少了它，「往已被 RST 的 socket 写」不是一次普通的写失败，而是**进程静默死亡**。
    private func applySocketOptions(fd: Int32) {
        Self.applyCoreSocketOptions(fd: fd)
        log("[连接] socket 选项: TCP_NODELAY=on 写超时=2s 忽略SIGPIPE=on")
    }

    /// 纯 `setsockopt` 部分（独立成 `static`，好让自检能在真实 socket 上
    /// `getsockopt` 读回来断言"真的设进去了"，而不是只断言"函数被调过"）。
    static func applyCoreSocketOptions(fd: Int32) {
        installSIGPIPEIgnore()               // ★ ① 进程级兜底
        var one: Int32 = 1
        _ = setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        // ★ ② 本 socket 精准豁免：写死连接时只回 EPIPE，不再抛 SIGPIPE
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        withUnsafePointer(to: &tv) { p in
            _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, p, socklen_t(MemoryLayout<timeval>.size))
        }
    }

    /// 只设 `SO_NOSIGPIPE`（+ 进程级兜底）。
    ///
    /// 给**自己管理超时**的裸 fd 用 —— 典型是剪贴板通道（它有独立的 6s 超时，
    /// 不能套用主通道那套 `SO_SNDTIMEO = 2s`）。但「往死 socket 写不能杀进程」
    /// 这条对所有 socket 一视同仁：剪贴板通道同样会往对端已经消失的 socket 写。
    /// 见 `sigpipeIgnored` 的事故说明。
    public static func noSIGPIPE(fd: Int32) {
        installSIGPIPEIgnore()
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    /// 断链自愈：关掉旧 socket，重新建连 + 重新握手，然后重启接收循环。
    ///
    /// 由 `Client` 的看门狗在连续写失败时调用。
    ///
    /// ★★ **本方法复用同一个 `MWBConnection` 对象**，所以除了「关旧的 / 重开接收线程」，
    ///    还必须把**会话级状态清干净**。`close()` 只关 socket、只置 `isClosed`，从不碰这些标记。
    ///
    /// 【2026-09-20 定案：不清 `handshakeDone` 会造出"假连接"】
    ///   `handshakeDone` 只在成功匹配对端 `HandshakeAck` 时置 true，**此前没有任何地方把它
    ///   置回 false**。于是每次出站重连，`doHandshake()` 的 3d 步会在处理完**第一个**包之后
    ///   直接命中 `else if handshakeDone { return .success(()) }` —— **根本不等对端的 Ack**
    ///   就宣布握手成功。日志指纹非常干净：
    ///     · 回连（`MWBListener` 每次**新建**对象）→ 有 "[握手] 双向认证完成 ✓ … MachineID = …"；
    ///     · 出站重连（走本方法，复用对象）→ **没有**那一行，却照样打
    ///       "[连接] 已与 … 完成双向认证并注册"。（GUI 日志对重复内容去重，所以早期没看出来。）
    ///   平时对端健康时这套"跳过验证"还能凑合（双方各自都收到了对方的 Ack）；
    ///   可一旦对端**此刻并未真正就绪**——最典型就是 **Windows 刚从睡眠唤醒**——Mac 就会
    ///   连上一条对端不处理的连接：TCP 写成功、日志全绿、UI 显示"已连接"，
    ///   但对端收不到任何包 ⇒ **鼠标推过去连光标都不出现**（这正是用户 09-20 报的现象）。
    public func reconnect() -> Result<Void, MWBConnectionError> {
        log("[连接] 开始重连 \(host):\(port) …")

        // ① 先作废旧接收线程的代际号，再 close。
        //    否则有个窄窗口：旧线程从 read 返回 0 后被系统调度延迟，等它走到 `receiveLoop`
        //    尾部时 `connect()` 可能已经把 `isClosed` 复位成 false，于是那句
        //    `guard receiveGeneration == gen, !isClosed else { return }` 成立，
        //    旧线程会替**新**连接打上「对端已关闭连接或读超时」——新连接刚建好就被判死。
        receiveGeneration += 1
        close()

        // ② 会话级状态清零（见上方注释）。
        handshakeDone = false
        magicLearned = false
        magic = 0
        log("[连接] 会话状态已重置（handshakeDone / magicLearned）—— 本次将**真正等待**对端 Ack")
        // 注意：`nextPacketID` **故意不重置** —— 对端按 `Id` 去重（50 条环形），
        //      重连后从天真的小数字重新开始，可能撞上对端环里残留的旧 Id 而被丢弃。
        //      让它一路递增下去即可（UInt32 循环空间远大于任何会话时长）。

        let r = connect()
        if case .success = r { startReceiveLoop() }
        return r
    }

    // MARK: - 发送

    @discardableResult
    public func send(_ packet: DataPacket) -> Result<Void, MWBConnectionError> {
        // ★ 整个「分配包号 → 序列化 → 加戳 → 加密 → 写出」必须是一个不可分割的临界区。
        //    原因见 sendLock 的注释：CBC 链有状态、socket 字节流不允许交错，
        //    而 send() 会被主线程/接收线程/剪贴板队列三处并发调用。
        sendLock.lock()
        defer { sendLock.unlock() }
        guard let ctx = encryptCtx else { return .failure(.cryptoError(.aesFailed)) }
        guard !isClosed else { return .failure(.writeFailed) }
        var p = packet
        if p.id == 0 { p.id = nextPacketID; nextPacketID += 1 }
        if p.src == 0 { p.src = myID }
        var buf = p.serialize()
        MWBCrypto.stampPacket(&buf, magic: magic)
        switch ctx.encrypt(buf) {
        case .failure(let e): return .failure(.cryptoError(e))
        case .success(let cipher): return writeRaw(cipher)
        }
    }

    // MARK: - 接收

    public func startReceiveLoop() {
        receiveGeneration += 1
        let gen = receiveGeneration
        receiveThread = Thread { [weak self] in self?.receiveLoop(generation: gen) }
        receiveThread?.name = "MWBReceive"
        receiveThread?.start()
    }

    /// 接收循环的每次尝试结果。必须把"读失败"和"解出坏包"分开 ——
    /// 前者是链路真没了，后者只是这一颗包坏了，处理方式完全不同。
    private enum ReceiveOutcome {
        case packet(DataPacket)
        case badPacket
        case readFailed
    }

    private func receiveLoop(generation gen: Int) {
        var consecutiveBad = 0
        loop: while !isClosed {
            switch receiveOutcome() {
            case .packet(let p):
                consecutiveBad = 0
                onPacket?(p)
            case .badPacket:
                // 历史实现是"只要解出一个坏包就直接 break" —— 于是一次偶发的校验失败
                // 就让接收永久静默（对端还在发，我们却什么都收不到了）。
                // 现在：单颗坏包容忍；连续一大堆坏包才说明字节流已错位（例如 CBC 链被
                // 并发破坏），此时必须放弃这条连接重来。
                consecutiveBad += 1
                if consecutiveBad >= 20 {
                    onLog?("[接收] 连续 \(consecutiveBad) 个包校验失败，字节流已错位，放弃本连接")
                    break loop
                }
            case .readFailed:
                break loop
            }
        }
        // 代际保护：重连会启动新的接收线程，旧线程退出时**不能**再去标记新连接。
        guard receiveGeneration == gen, !isClosed else { return }
        // ★ 用 close() 而不是只置 isClosed：读失败 = 对端已经走了，**必须把 fd 还回去**。
        //   2026-09-22 实测：只标记不关 fd ⇒ `lsof` 里堆了 8 个 `CLOSED` 的已死连接
        //   （Windows 每次回连我们 15101 都会留下一个，永不回收）。fd 是有限资源，
        //   而且这些僵尸连接还会让「一个 Client 持几条连接」的语义变得不可信。
        close()
        onDisconnected?("对端已关闭连接或读超时")
    }

    /// 这条连接是否已关闭（监听器用它来清理死掉的回连）。
    /// 只是个**尽力而为的快照**：并发下可能读到旧值，用来做数组清理足够。
    public var closed: Bool { isClosed }

    /// 兜底：对象销毁时确保 socket 一定被关掉（正常路径由 `close()` 负责）。
    ///
    /// ⚠️ 这里**打日志是故意的**：2026-09-23 的回连风暴就是"回连对象没人持有、
    /// 出了作用域立刻析构"造成的 —— 析构即关 fd，对端看到 RST，Windows 的
    /// `REOPEN_WHEN_WSAECONNRESET` 立刻重连，于是打成每秒 3 次的风暴。
    /// 出现这行日志 = 又有人忘了持有连接。
    deinit {
        if socketFD >= 0 {
            onLog?("[连接] ⚠️ \(roleLabel)连接对象析构时 socket 仍开着（fd=\(socketFD)）→ 关闭")
            Darwin.close(socketFD)
            socketFD = -1
        }
    }

    /// 接收循环专用：把读失败 / 坏包 / 正常包三种情况分开返回。
    private func receiveOutcome() -> ReceiveOutcome {
        guard let dec = decryptCtx else { return .readFailed }
        guard case .success(let c1) = readRaw(DataPacket.smallSize) else { return .readFailed }
        guard case .success(var p1) = dec.decrypt(c1) else { return .badPacket }
        let typeByte = PackageType(rawValue: UInt32(p1[0]))
        if DataPacket.isBigType(typeByte) {
            guard case .success(let c2) = readRaw(DataPacket.smallSize) else { return .readFailed }
            guard case .success(let p2) = dec.decrypt(c2) else { return .badPacket }
            p1.append(contentsOf: p2)
        }
        if !magicLearned {
            guard MWBCrypto.checksumValid(p1) else { return .badPacket }
            magic = MWBCrypto.readMagic(p1)
            magicLearned = true
        }
        guard MWBCrypto.validatePacket(p1, magic: magic) else { return .badPacket }
        var b = p1
        MWBCrypto.clearStamp(&b)
        guard let pkt = DataPacket.parse(b) else { return .badPacket }
        return .packet(pkt)
    }

    /// 读取一个完整包（含大包后半段）的原始明文，不做任何校验。
    private func receiveRawPacket() -> [UInt8]? {
        guard let dec = decryptCtx else { return nil }
        switch readRaw(DataPacket.smallSize) {
        case .failure: return nil
        case .success(let c1):
            switch dec.decrypt(c1) {
            case .failure: return nil
            case .success(var p1):
                let typeByte = PackageType(rawValue: UInt32(p1[0]))
                if DataPacket.isBigType(typeByte) {
                    switch readRaw(DataPacket.smallSize) {
                    case .failure: return nil
                    case .success(let c2):
                        switch dec.decrypt(c2) {
                        case .failure: return nil
                        case .success(let p2):
                            p1.append(contentsOf: p2)
                            return p1
                        }
                    }
                } else {
                    return p1
                }
            }
        }
    }

    /// 整包接收并校验（magic + checksum）。magic 尚未校准时会从首个合法包自动学习。
    private func receivePacket() -> DataPacket? {
        guard let buf = receiveRawPacket() else { return nil }
        if !magicLearned {
            guard MWBCrypto.checksumValid(buf) else {
                log("[接收] 包校验失败(密钥不符导致乱码)")
                return nil
            }
            magic = MWBCrypto.readMagic(buf)
            magicLearned = true
        }
        guard MWBCrypto.validatePacket(buf, magic: magic) else {
            log("[接收] 包校验失败(magic/checksum)")
            return nil
        }
        var b = buf
        MWBCrypto.clearStamp(&b)
        return DataPacket.parse(b)
    }

    public func receiveOne() -> DataPacket? { receivePacket() }

    // MARK: - 原始读写

    private func writeRaw(_ data: [UInt8]) -> Result<Void, MWBConnectionError> {
        // 递归锁：send() 已经持锁时这里再取一次（同一线程，NSRecursiveLock 不阻塞）
        sendLock.lock()
        defer { sendLock.unlock() }
        let fd = socketFD
        guard !isClosed, fd >= 0 else { return .failure(.writeFailed) }
        var total = 0
        while total < data.count {
            // ★ 直接用缓冲区指针写，不要 `Array(data[total...])`：
            //   那样每次发送都要**再分配并拷贝一份**整包数据。鼠标移动包 200Hz、
            //   键盘/心跳也在同一条路上，这个拷贝纯属白烧 CPU 和内存带宽。
            let n = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return Darwin.write(fd, base.advanced(by: total), data.count - total)
            }
            if n < 0 && errno == EINTR { continue }   // 被信号打断：重来，不算失败
            // n <= 0 只可能是：对端已关闭 / RST / 写超时(SO_SNDTIMEO)。
            // 注意可能是**半包**（total > 0）—— 那意味着这条连接的字节流已经错位，
            // 必须让上层看门狗走重连，绝不能在错位的流上继续写。
            if n <= 0 {
                if total > 0 {
                    log("[连接] ⚠️ 半包后写入失败（已写 \(total)/\(data.count) 字节），连接不可用")
                }
                return .failure(.writeFailed)
            }
            total += n
        }
        return .success(())
    }

    private func readRaw(_ count: Int) -> Result<[UInt8], MWBConnectionError> {
        let fd = socketFD
        guard fd >= 0 else { return .failure(.readFailed) }
        var buf = [UInt8](repeating: 0, count: count)
        var total = 0
        while total < count {
            let n = Darwin.read(fd, &buf[total], count - total)
            if n < 0 && errno == EINTR { continue }
            if n < 0 { return .failure(.readFailed) }
            if n == 0 { return .failure(.readFailed) } // 对端关闭（EOF）/ 被 shutdown 唤醒
            total += n
        }
        return .success(buf)
    }

    public func close() {
        isClosed = true
        // 先 shutdown 再关：阻塞中的 read() 会立刻被唤醒并返回 0，
        // 接收线程才能及时退出。否则重连时旧线程会一直挂在 read 上不释放。
        let fd = socketFD
        guard fd >= 0 else { return }
        socketFD = -1
        shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
        log("[连接] 已关闭 \(roleLabel)连接 fd=\(fd)")
    }

    // MARK: - 回归自检

    /// 回归对象 = 2026-09-23「SIGPIPE 静默杀进程」。
    ///
    /// 判据的设计要点：**不去读信号处置的值**（`sig_t` 是 C 函数指针，Swift 里不遵循
    /// `Equatable`，位转比较既绕又脆），而是直接验**行为**：
    ///   · ② 是「socket 级豁免」的证明 —— 走真实 `applyCoreSocketOptions` 后在
    ///     `getsockopt` 读回 `SO_NOSIGPIPE = 1`（不是"函数被调过"这种弱断言）；
    ///   · ③ 是「进程级兜底」的证明 —— 用一个**故意不设任何 socket 选项**的裸 socketpair，
    ///     若 `SIG_IGN` 没生效，这一行就会把自检进程直接杀掉（根本走不到最后的"通过"）。
    ///
    /// **有效性由独立阳性子命令保证**：`--sigpipe-selftest-raw` 把处置恢复默认后做同一操作，
    /// 必须真的被 SIGPIPE 杀掉（退出码 141）。那边若能正常返回，说明此环境压根不产生
    /// SIGPIPE ⇒ 本用例是空跑，必须重设计（而不是"通过"）。
    public static func sigpipeSelfTest() -> Bool {
        var pass = 0, fail = 0
        func check(_ ok: Bool, _ name: String, _ detail: String = "") {
            if ok { pass += 1; print("  ✓ \(name)\(detail.isEmpty ? "" : "（\(detail)）")") }
            else { fail += 1; print("  ✗ \(name)\(detail.isEmpty ? "" : "（\(detail)）")") }
        }

        print("SIGPIPE 防护自检（回归「断链重连窗口里 App 无声消失」）")

        // ① 先把进程级兜底装上（幂等）
        installSIGPIPEIgnore()
        check(true, "进程级兜底 installSIGPIPEIgnore() 已执行（幂等）")

        // ② socket 级：SO_NOSIGPIPE 真的落到了 fd 上
        let probe = socket(AF_INET, SOCK_STREAM, 0)
        if probe >= 0 {
            applyCoreSocketOptions(fd: probe)
            var v: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            let r = getsockopt(probe, SOL_SOCKET, SO_NOSIGPIPE, &v, &len)
            check(r == 0 && v == 1, "socket 级 SO_NOSIGPIPE = 1",
                  "getsockopt 返回 \(r)，读回值 \(v)")
            Darwin.close(probe)
        } else {
            check(false, "socket 级 SO_NOSIGPIPE = 1", "socket() 创建失败（errno=\(errno)）")
        }

        // ③ 行为：往「对端已关闭」的 socket 写 —— 必须是普通的 -1/EPIPE，而不是把进程带走。
        //    ★ 这里**故意不调 applyCoreSocketOptions**，专测进程级兜底。
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            check(false, "写已死 socket 返回 EPIPE 且进程存活", "socketpair 创建失败（errno=\(errno)）")
            print("\n结果: \(pass)/\(pass + fail) 通过")
            return false
        }
        Darwin.close(fds[1])                 // 对端关闭 ⇒ 本地再写必然 EPIPE
        var byte: UInt8 = 0x41
        var n: Int = 0
        var e: Int32 = 0
        for _ in 0..<8 {                     // 头一两次可能写进缓冲，多写几次直到失败
            n = Darwin.write(fds[0], &byte, 1)
            if n < 0 { e = errno; break }
        }
        Darwin.close(fds[0])
        check(n < 0 && e == EPIPE, "写已死 socket → -1/EPIPE 且进程存活",
              "write 返回 \(n)，errno = \(e)\(e == EPIPE ? " (EPIPE)" : "")")

        print("\n结果: \(pass)/\(pass + fail) 通过")
        return fail == 0
    }

    /// 阳性对照：把 `SIGPIPE` 恢复成默认处置（`SIG_DFL`）后做**同一个写操作**。
    /// 预期：本进程被 SIGPIPE 杀死 ⇒ 退出码 141（128 + 13），**永远不会正常返回**。
    /// 若返回了 97/98/99，说明该环境下"写已死 socket"不产生 SIGPIPE，
    /// `sigpipeSelfTest()` 就是空跑 —— 阳性对照存在的意义就是把这个可能性钉死。
    public static func sigpipeNegativeControl() -> Int32 {
        print("阳性对照：恢复 SIGPIPE 默认处置，往已死 socket 写 —— 预期本进程被信号杀死（141）")
        signal(SIGPIPE, SIG_DFL)
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            print("⚠️ socketpair 创建失败，本对照无效"); return 99
        }
        Darwin.close(fds[1])
        var byte: UInt8 = 0x41
        for _ in 0..<8 {
            let n = Darwin.write(fds[0], &byte, 1)
            if n < 0 {
                let e = errno
                Darwin.close(fds[0])
                print("⚠️ 写返回 -1/errno=\(e) 但**没有**收到 SIGPIPE —— 本对照无效，自检设计需重做")
                return 98
            }
        }
        Darwin.close(fds[0])
        print("⚠️ 全部写成功、既没失败也没收到信号 —— 本对照无效")
        return 97
    }

    /// 回归对象 = 2026-09-20「假连接」：
    /// `reconnect()` 复用同一个 `MWBConnection` 对象，却忘了清 `handshakeDone`
    /// ⇒ `doHandshake()` 不等对端 `HandshakeAck` 就宣布成功
    /// ⇒ Windows 睡醒后 Mac 连上一条"对端不处理"的连接，鼠标推过去连光标都不出现。
    ///
    /// **本用例的有效性由构造保证**：先把三个标记显式伪造成"已握手过"的状态，
    /// 再去掉 `reconnect()` 里那三行重置 —— 唯一的清除来源就没了，自检必然失败。
    ///
    /// 说明：`reconnect()` 会真去连 `127.0.0.1:1`，那是必然立刻 `ECONNREFUSED` 的地址；
    /// 重置发生在 `connect()` **之前**，所以连接失败不影响本用例的判据。
    public static func reconnectResetSelfTest() -> Bool {
        let c = MWBConnection(host: "127.0.0.1", port: 1,
                              securityKey: "selftest-not-used", machineName: "selftest", myID: 2)
        // 伪造"上一次会话已经握手完成"的现场
        c.handshakeDone = true
        c.magicLearned = true
        c.magic = 0x1234

        // 前置断言：三个标记确实可读可写。少了这一步，"reconnect 后变 false"
        // 有可能只是"压根没设进去"的假通过 —— 那就等于测了个空。
        guard c.handshakeDone, c.magicLearned, c.magic == 0x1234 else {
            print("  ✗ 前置条件不成立：会话标记无法被伪造，本自检无效")
            return false
        }

        _ = c.reconnect()      // 连不上是预期的；关键是它必须先清状态

        var pass = 0
        let total = 3
        if !c.handshakeDone {
            pass += 1
            print("  ✓ handshakeDone 已重置（不会再跳过等待对端 Ack）")
        } else {
            print("  ✗ handshakeDone 残留 true —— 重连仍是「假握手」")
        }
        if !c.magicLearned {
            pass += 1
            print("  ✓ magicLearned 已重置（接收侧会重新自校准魔数）")
        } else {
            print("  ✗ magicLearned 残留 true")
        }
        if c.magic == 0 {
            pass += 1
            print("  ✓ magic 已清零")
        } else {
            print("  ✗ magic 残留 0x\(String(c.magic, radix: 16))")
        }
        print("  结果: \(pass)/\(total) 通过")
        return pass == total
    }
}
