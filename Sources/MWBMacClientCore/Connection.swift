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

    private var input: InputStream?
    private var output: OutputStream?
    private var socketFD: Int32 = -1
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
    public func attach(fd: Int32) -> Result<Void, MWBConnectionError> {
        socketFD = fd
        applySocketOptions(fd: fd)
        var readStream: Unmanaged<CFReadStream>?
        var writeStream: Unmanaged<CFWriteStream>?
        CFStreamCreatePairWithSocket(nil, CFSocketNativeHandle(fd), &readStream, &writeStream)
        guard let rs = readStream?.takeRetainedValue(),
              let ws = writeStream?.takeRetainedValue() else {
            Darwin.close(fd)
            return .failure(.connectFailed(NSError(domain: "MWB", code: -4)))
        }
        self.input = rs as Stream as? InputStream
        self.output = ws as Stream as? OutputStream
        self.input?.open()
        self.output?.open()
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
        var readStream: Unmanaged<CFReadStream>?
        var writeStream: Unmanaged<CFWriteStream>?
        CFStreamCreatePairWithSocket(nil, CFSocketNativeHandle(sock), &readStream, &writeStream)
        guard let rs = readStream?.takeRetainedValue(),
              let ws = writeStream?.takeRetainedValue() else {
            Darwin.close(sock)
            return .failure(.connectFailed(NSError(domain: "MWB", code: -4)))
        }
        self.input = rs as Stream as? InputStream
        self.output = ws as Stream as? OutputStream
        self.input?.open()
        self.output?.open()
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

    /// 给 socket 设两个关键选项（主动连接与被动接受两条路径都要设）。
    ///
    /// 1. **TCP_NODELAY** —— 不设的话 Nagle 会把我们每 5ms 一颗的小鼠标包攒起来
    ///    再发（还会和 delayed-ACK 互相等，最坏叠加 ~40ms）。对端收到的是
    ///    「一批一批」的坐标，看起来就是**鼠标延时、闪烁、一顿一顿，像回报率不对**。
    ///    PowerToys 的 MWB 自己也是 `TcpClient.NoDelay = true`。
    /// 2. **SO_SNDTIMEO = 2s** —— `send()` 是阻塞写且持有 sendLock；若对端不读了，
    ///    没有写超时会把主线程（事件回调）和接收线程（回显心跳）一起永久卡死。
    ///    有超时则退化成 `writeFailed`，交给 Client 的看门狗去做降级 + 重连。
    private func applySocketOptions(fd: Int32) {
        var one: Int32 = 1
        _ = setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        withUnsafePointer(to: &tv) { p in
            _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, p, socklen_t(MemoryLayout<timeval>.size))
        }
        log("[连接] socket 选项: TCP_NODELAY=on 写超时=2s")
    }

    /// 断链自愈：关掉旧 socket，重新建连 + 重新握手，然后重启接收循环。
    ///
    /// 由 `Client` 的看门狗在连续写失败时调用。`connect()` 内部已经把
    /// `isClosed` 复位并重跑 `establishSession()`（含 magic 自校准与注册心跳），
    /// 所以这里只需要补上「关旧的」和「重启接收线程」两步。
    public func reconnect() -> Result<Void, MWBConnectionError> {
        log("[连接] 开始重连 \(host):\(port) …")
        close()
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
        isClosed = true
        onDisconnected?("对端已关闭连接或读超时")
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
        guard !isClosed, let out = output else { return .failure(.writeFailed) }
        var total = 0
        while total < data.count {
            // ★ 直接用缓冲区指针写，不要 `Array(data[total...])`：
            //   那样每次发送都要**再分配并拷贝一份**整包数据。鼠标移动包 200Hz、
            //   键盘/心跳也在同一条路上，这个拷贝纯属白烧 CPU 和内存带宽。
            let n = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return out.write(base.advanced(by: total)
                                     .assumingMemoryBound(to: UInt8.self),
                                 maxLength: data.count - total)
            }
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
        guard let input = input else { return .failure(.readFailed) }
        var buf = [UInt8](repeating: 0, count: count)
        var total = 0
        while total < count {
            let n = input.read(&buf[total], maxLength: count - total)
            if n < 0 { return .failure(.readFailed) }
            if n == 0 { return .failure(.readFailed) } // 对端关闭 / 超时
            total += n
        }
        return .success(buf)
    }

    public func close() {
        isClosed = true
        // 先 shutdown 再关：阻塞中的 read() 会立刻被唤醒并返回 0，
        // 接收线程才能及时退出。否则重连时旧线程会一直挂在 read 上不释放。
        if socketFD >= 0 { shutdown(socketFD, SHUT_RDWR) }
        input?.close()
        output?.close()
        if socketFD >= 0 { Darwin.close(socketFD); socketFD = -1 }
    }
}
