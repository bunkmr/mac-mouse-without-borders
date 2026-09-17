// ClipboardChannel.swift
// MWB **原生**剪贴板/文件通道（端口 TcpPort = 15100，主通道是 TcpPort+1 = 15101）。
//
// 【为什么必须单独一条 TCP】
// PowerToys 只在「剪贴板通道」上收发剪贴板与文件数据，主通道(15101)只走键鼠/心跳/握手。
// 键鼠包走主通道、文件字节走剪贴板通道 —— 这是它的架构，不是可选项。
// 之前我们用自建的 MWBXFER1 协议 + 15110 端口 + Windows 侧 Python agent 绕过它，
// 现改为直接实现原生通道，Windows 端**无需任何额外程序**。
//
// 权威来源：PowerToys `src/modules/MouseWithoutBorders/App/`
//   Core/Clipboard.cs        —— ShakeHand / GetRemoteClipboard / ReceiveAndProcessClipboardDataCore
//   Class/SocketStuff.cs     —— SendClipboardData / SendFile / AcceptConnectionAndSendClipboardData
//   Core/DragDrop.cs         —— 拖放时序（Step01..Step12）
//   Core/DATA.cs / ClipboardPostAction.cs / Package.cs —— 结构体与常量
//
// ---------------------------------------------------------------- 线格式
//
// 1) 握手（ShakeHand，**双方对称、都是先发后收**）：
//      发：16 字节随机块（预热 CBC 链）→ 64 字节头包
//      收：16 字节预热块 → 64 字节头包
//    头包 = DATA 结构，Type 取 Clipboard(69) 或 ClipboardPush(79)，
//    offset 16 = PostAction，offset 32..63 = MachineName。
//
//    谁发哪个类型决定谁推数据：
//      **数据持有方发 ClipboardPush(79)；请求方发 Clipboard(69)。**
//    交换之后，每一边看「对端发的是哪个」：
//      对端发 Clipboard(69)   → 本端负责【发送】数据
//      对端发 ClipboardPush(79) → 本端负责【接收】数据
//
// 2) 数据帧（SendClipboardData）：**没有额外长度前缀**，靠一个 1024 字节定长头描述：
//      头 = UTF-16LE("{字节数}*{路径}")，其余补 0，**固定 1024 字节**
//      （接收端 `deStream.ReadEx(header, 0, 1024)` 写死读这么多）
//    随后就是文件原始字节。
//      - 接收端按 `Path.GetFileName(路径)` 取名 —— 所以路径里放 macOS 的绝对路径没问题，
//        Windows 只取最后一段文件名。
//      - 头里若以 "image"/"text" 开头，则走剪贴板内存流分支；普通路径才是文件分支。
//
// 3) 落点：PostAction = Desktop(1) 时，Windows 把文件存到
//      %USERPROFILE%\Desktop\MouseWithoutBorders\<文件名>  然后打开该文件夹。
//
// 4) 收尾：发完直接关 socket（PowerToys 用 s.Close(10)）。接收端读到 0 字节即结束，
//    并按头里的字节数校验完整性。
//
// ------------------------------------------------------- 加密（复用主通道同一套）
// 与本机 Windows 端一致：PBKDF2-HMAC-SHA1 / 固定 salt / 固定 IV，无明文 salt+IV 头，
// 连接后先互发 16 字节预热块。见 Crypto.swift 顶部说明。
// （注意：PowerToys 的 main 分支后来改成了「每流 32 字节明文 salt+IV + PBKDF2-SHA512/100000」，
//   但本机对端不是那个版本 —— 以实测为准，与主通道保持完全一致。）

import Foundation
import Darwin

// MARK: - 通道数据载荷

/// 剪贴板通道上传输的三种载荷。
///
/// PowerToys 靠 1024 字节定长头里的「文件名」区分它们（`SocketStuff.SendClipboardData`）：
///   - `"{字节数}*image"`  → 剪贴板图片（**PNG 原始字节**）
///   - `"{字节数}*text"`   → 剪贴板文本（**DEFLATE 压缩后的多格式打包串**）
///   - `"{字节数}*{真实路径}"` → 文件
/// 判定用 `StartsWith("image"/"text", CurrentCultureIgnoreCase)`，所以这里也按前缀判。
public enum MWBClipboardPayload {
    /// 剪贴板图片：PNG 原始字节（线上就是这个，不再包一层）。
    case image(Data)
    /// 剪贴板文本：已经 DEFLATE 压缩过的打包串字节（交给 ClipboardSync 解压 + 拆包）。
    case textWire([UInt8])
    /// 文件：落盘后的本地 URL。
    case file(URL)

    /// 通道头里用的类型名。只对「内存型」载荷有意义。
    public var wireName: String? {
        switch self {
        case .image:           return "image"
        case .textWire:        return "text"
        case .file:            return nil
        }
    }

    public var isImage: Bool { if case .image = self { return true }; return false }
    public var byteCount: Int {
        switch self {
        case .image(let d):     return d.count
        case .textWire(let b):  return b.count
        case .file:             return 0
        }
    }
}

// MARK: - 错误

public enum MWBClipboardError: Error, LocalizedError {
    case connectFailed(String)
    case handshakeFailed(String)
    case ioFailed(String)
    case noStagedFile
    case rejected(String)
    case prepareFailed(String)

    public var errorDescription: String? {
        switch self {
        case .connectFailed(let s):  return "无法连接剪贴板通道: \(s)"
        case .handshakeFailed(let s): return "剪贴板通道握手失败: \(s)"
        case .ioFailed(let s):       return "剪贴板通道传输失败: \(s)"
        case .noStagedFile:          return "没有待发送的文件"
        case .rejected(let s):       return "对端拒绝: \(s)"
        case .prepareFailed(let s):  return "预处理失败: \(s)"
        }
    }
}

// MARK: - PostAction

/// 对齐 PowerToys `ClipboardPostAction.cs`：Other=0 / Desktop=1 / Mspaint=2。
public enum MWBPostAction: UInt32 {
    case other = 0
    case desktop = 1
    case mspaint = 2

    public var name: String {
        switch self {
        case .other:   return "other"
        case .desktop: return "desktop"
        case .mspaint: return "mspaint"
        }
    }
}

// MARK: - 通道

public final class MWBClipboardChannel {

    // MARK: 配置

    public let securityKey: String
    public let machineName: String
    /// 本机机器 ID（必须与主通道注册到 Windows 机器矩阵里的那个 ID 一致，
    /// 否则 Windows 的 ShakeHand 会在 `ResolveID(name) == package.Src` 这一步拒绝我们）。
    public var myID: UInt32
    /// 从主通道自校准学到的 16 位魔数。剪贴板通道头包同样带上，保持一致。
    public var magic: UInt16 = 0x3555
    /// 剪贴板通道端口 = TcpPort（主通道是 TcpPort + 1）。
    public let port: UInt16

    public var onLog: ((String) -> Void)?
    /// 收到对端推来的载荷后回调（Windows → Mac 方向）：文件 / 剪贴板图片 / 剪贴板文本。
    public var onPayloadReceived: ((MWBClipboardPayload) -> Void)?

    /// 待发送的暂存文件（拖放时写入；对端来拉时读它）。
    /// ★ MWB 原生协议一次只传**一个**文件（`LastDragDropFile` 是单个字符串），
    ///   多文件/目录必须先打包成一个文件再发。
    public var stagedFile: URL?

    /// 待发送的**大剪贴板载荷**（图片 > 1MB、或超大文本）。
    ///
    /// 【为什么需要它】超过 `Clipboard.MAX_CLIPBOARD_DATA_SIZE_CAN_BE_SENT_INSTANTLY_TCP`（1MB）
    /// 时 PowerToys 不直推，而是发 `Clipboard(69)` 心跳包，等对端回连 15100 来拉。
    /// 对端来拉的那一刻，数据必须还在 —— 就存在这里，由 `handleInbound`（对端直连）
    /// 或 `pushClipboardPayload`（对端发 ClipboardAsk 让我们反向推）送出去。
    public var pendingClipboardPayload: MWBClipboardPayload?

    private var listenFD: Int32 = -1
    private var acceptThread: Thread?
    private var running = false

    public init(port: UInt16, securityKey: String, machineName: String, myID: UInt32) {
        self.port = port
        self.securityKey = securityKey
        self.machineName = machineName
        self.myID = myID
    }

    private func log(_ s: String) { onLog?(s) }

    // MARK: - 监听（Windows 主动来拉时要连到我们 15100）

    @discardableResult
    public func startListener() -> Bool {
        guard listenFD < 0 else { return true }

        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            log("[剪贴板] socket 创建失败: errno=\(errno)")
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
            log("[剪贴板] 端口 \(port) 绑定失败: errno=\(errno)（剪贴板通道被占用？）")
            Darwin.close(fd)
            return false
        }
        guard Darwin.listen(fd, 8) == 0 else {
            log("[剪贴板] listen 失败: errno=\(errno)")
            Darwin.close(fd)
            return false
        }

        listenFD = fd
        running = true
        log("[剪贴板] 已在 \(port) 端口监听（MWB 原生剪贴板/文件通道，主通道是 \(port + 1)）")

        acceptThread = Thread { [weak self] in self?.acceptLoop() }
        acceptThread?.name = "MWBClipboardListener"
        acceptThread?.start()
        return true
    }

    private func acceptLoop() {
        var tv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(listenFD, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        while running {
            var remote = sockaddr()
            var len = socklen_t(MemoryLayout<sockaddr>.size)
            let peerFD = Darwin.accept(listenFD, &remote, &len)
            if peerFD < 0 { continue }
            Thread { [weak self] in
                guard let self else { Darwin.close(peerFD); return }
                self.handleInbound(fd: peerFD)
            }.start()
        }
    }

    /// 处理一条来自对端的剪贴板连接。我们在这里永远是「数据持有方」。
    private func handleInbound(fd: Int32) {
        defer { Darwin.close(fd) }
        applySocketOptions(fd: fd)
        log("[剪贴板] 对端连入（\(hostOf(fd))），开始 ShakeHand…")

        let session: Session
        switch shakeHand(fd: fd, weAreDataHolder: true, post: .desktop) {
        case .success(let s): session = s
        case .failure(let e):
            log("[剪贴板] ✗ \(e.localizedDescription)")
            return
        }
        log("[剪贴板] ShakeHand 成功 ✓ 对端=\(session.peerName) 对端要求推送=\(session.peerIsPusher)")

        if session.peerIsPusher {
            // 对端发的是 ClipboardPush(79) → 它要推数据给我们（Windows → Mac）
            switch receiveData(fd: fd, dec: session.dec, postAction: session.peerPostAction) {
            case .success(let payload): onPayloadReceived?(payload)
            case .failure(let e):       log("[剪贴板] ✗ 接收失败: \(e.localizedDescription)")
            }
        } else {
            // 对端发的是 Clipboard(69) → 它在向我们要数据，我们推给它。
            // 优先级：暂存文件（拖放）> 待发送的大剪贴板载荷（图片/文本 > 1MB）。
            if let file = stagedFile {
                switch sendDraggedFile(fd: fd, enc: session.enc, file: file) {
                case .success(let n): log("[剪贴板] ✓ 已推送 \(file.lastPathComponent)（\(fmtBytes(n))）→ 对端将存到 桌面\\MouseWithoutBorders\\")
                case .failure(let e): log("[剪贴板] ✗ 推送失败: \(e.localizedDescription)")
                }
            } else if let payload = pendingClipboardPayload {
                switch sendClipboardPayload(fd: fd, enc: session.enc, payload: payload) {
                case .success(let n):
                    log("[剪贴板] ✓ 对端拉取：已推送剪贴板载荷（\(payloadWiredName(payload))，\(fmtBytes(n))）")
                    pendingClipboardPayload = nil
                case .failure(let e):
                    log("[剪贴板] ✗ 剪贴板载荷推送失败: \(e.localizedDescription)")
                }
            } else {
                log("[剪贴板] ⚠️ 对端来拉取，但既没有暂存文件也没有待推送的剪贴板载荷 —— 可能信令与数据未同步")
                return
            }
        }
    }

    /// 反向推送待发送的大剪贴板载荷（对端发 ClipboardAsk(78) 时用；对称于 `pushStagedFile`）。
    public func pushClipboardPayload(to host: String) -> Result<Int64, MWBClipboardError> {
        guard let payload = pendingClipboardPayload else {
            return .failure(.rejected("没有待推送的剪贴板载荷"))
        }
        let fd = connectSocket(host: host, port: port)
        guard fd >= 0 else {
            return .failure(.connectFailed("\(host):\(port)（Windows MWB 是否在运行？防火墙是否放行 \(port)？）"))
        }
        defer { Darwin.close(fd) }
        applySocketOptions(fd: fd)

        let session: Session
        switch shakeHand(fd: fd, weAreDataHolder: true, post: .other) {
        case .success(let s): session = s
        case .failure(let e): return .failure(e)
        }
        // 与 pushStagedFile 同理：对端回 Push 也可能表示「它接收」，这里不判角色、直接推。
        let r = sendClipboardPayload(fd: fd, enc: session.enc, payload: payload)
        if case .success = r { pendingClipboardPayload = nil }
        return r
    }

    private func payloadWiredName(_ p: MWBClipboardPayload) -> String {
        switch p {
        case .image:    return "图片(PNG)"
        case .textWire: return "文本"
        case .file:     return "文件"
        }
    }

    /// 主动连到对端的剪贴板通道并把暂存文件推过去。
    /// 用于「对端发来 ClipboardAsk(78)、我们无法被它连入」的场景（对称于 PowerToys 的
    /// `ConnectToRemoteClipboardSocket` + `clientPushData = true`）。
    public func pushStagedFile(to host: String) -> Result<Int64, MWBClipboardError> {
        guard let file = stagedFile else { return .failure(.noStagedFile) }
        let fd = connectSocket(host: host, port: port)
        guard fd >= 0 else {
            return .failure(.connectFailed("\(host):\(port)（Windows MWB 是否在运行？防火墙是否放行 \(port)？）"))
        }
        defer { Darwin.close(fd) }
        applySocketOptions(fd: fd)

        let session: Session
        switch shakeHand(fd: fd, weAreDataHolder: true, post: .desktop) {
        case .success(let s): session = s
        case .failure(let e): return .failure(e)
        }
        // ★ 这里**不判断** session.peerIsPusher，直接推。
        //
        // 实测（对真实 Windows 端）：我们连过去发 ClipboardPush(79)，对端回的**也是**
        // ClipboardPush —— 因为它的剪贴板端口处理器 `SendOrReceiveClipboardData` 初始就
        // `clientPushData = true`。它读到我们的 ClipboardPush 后 clientPushData 仍为 true，
        // 于是走 `ReceiveAndProcessClipboardData`，即【它接收、我们发送】。
        //
        // PowerToys 自己的 ClipboardAsk 分支（Receiver.cs `case PackageType.ClipboardAsk`）
        // 也是 ShakeHand 之后**无条件**调用 SendClipboardData —— 完全同构。
        // 若在这里按「对端也发 Push 就报角色冲突」拒绝，反而会把这条唯一可用的路堵死。
        //
        // 顺带一个重要收益：`postAction` 取自**我们**发的头包
        // （`ShakeHand` 里 `postAction = package.PostAction`），所以我们把 PostAction 设成
        // Desktop(1)，对端就会按 desktop 分支落到 `桌面\MouseWithoutBorders\` 并打开该文件夹。
        return sendDraggedFile(fd: fd, enc: session.enc, file: file)
    }

    public func stop() {
        running = false
        if listenFD >= 0 { Darwin.close(listenFD); listenFD = -1 }
    }

    /// 主动去对端拉数据（Windows → Mac 方向）：文件、剪贴板图片、剪贴板文本都可能。
    ///
    /// 对称于 PowerToys `Clipboard.ConnectAndGetData`：请求方发 `Clipboard(69)`，
    /// 数据持有方回 `ClipboardPush(79)`，于是本端负责接收。
    /// 拿到的是文件还是剪贴板内容，**由对端头里的类型名决定**（见 `MWBClipboardPayload`）。
    public func fetchPayload(from host: String, postAction: MWBPostAction = .other)
        -> Result<MWBClipboardPayload, MWBClipboardError> {
        let fd = connectSocket(host: host, port: port)
        guard fd >= 0 else {
            return .failure(.connectFailed("\(host):\(port)（Windows MWB 是否在运行？防火墙是否放行 \(port)？）"))
        }
        defer { Darwin.close(fd) }
        applySocketOptions(fd: fd)

        let session: Session
        switch shakeHand(fd: fd, weAreDataHolder: false, post: postAction) {
        case .success(let s): session = s
        case .failure(let e): return .failure(e)
        }
        guard session.peerIsPusher else {
            // 对端也发了 Clipboard(69) —— 双方都以为自己是请求方，协议上不该出现
            return .failure(.rejected("对端未接管推送角色（双方角色冲突）"))
        }
        return receiveData(fd: fd, dec: session.dec, postAction: postAction.rawValue)
    }

    /// 只要文件的旧接口（拖放路径专用）。对端推来的是剪贴板内容时判为失败。
    public func fetchFile(from host: String, postAction: MWBPostAction = .other) -> Result<URL, MWBClipboardError> {
        switch fetchPayload(from: host, postAction: postAction) {
        case .failure(let e): return .failure(e)
        case .success(.file(let u)): return .success(u)
        case .success(let other):
            return .failure(.rejected("对端推来的不是文件（\(payloadWiredName(other))）"))
        }
    }

    // MARK: - 握手

    private struct Session {
        let enc: CBCContext
        let dec: CBCContext
        let peerIsPusher: Bool
        let peerName: String
        let peerPostAction: UInt32
    }

    /// 与 PowerToys `Clipboard.ShakeHand` 逐句对齐：**先发预热块 + 头包，再收预热块 + 头包**。
    /// 顺序不能颠倒 —— 双方都是先发后收，所以不会互相等死。
    private func shakeHand(fd: Int32, weAreDataHolder: Bool, post: MWBPostAction) -> Result<Session, MWBClipboardError> {
        let key: [UInt8]
        switch MWBCrypto.deriveKey(securityKey: securityKey) {
        case .success(let k): key = k
        case .failure(let e): return .failure(.ioFailed("密钥派生失败 \(e)"))
        }
        let iv = MWBCrypto.legacyIV()
        let enc = CBCContext(key: key, iv: iv)
        let dec = CBCContext(key: key, iv: iv)

        // ① 16 字节预热块（先推进我方 CBC 链）
        let dummy = MWBCrypto.randomBytes(16)
        switch enc.encrypt(dummy) {
        case .failure(let e): return .failure(.ioFailed("预热块加密失败 \(e)"))
        case .success(let ct):
            if let err = writeAll(fd, ct) { return .failure(err) }
        }

        // ② 64 字节头包：数据持有方发 ClipboardPush(79)，请求方发 Clipboard(69)
        var hdr = DataPacket(type: weAreDataHolder ? .clipboardPush : .clipboard, src: myID, des: 0)
        hdr.postAction = post.rawValue
        hdr.machineName = machineName
        // ★★ 头包**绝不能盖魔数/校验和章**（byte1..3 必须保持 0）★★
        //
        // PowerToys 的 `Clipboard.ShakeHand` 是直接 `enStream.Write(package.Bytes, 0, 64)`，
        // 绕过了 `TcpSendData`（盖章只发生在 TcpSendData 里），所以线路上 byte1..3 = 0。
        // 而接收端 `DATA.Type` 是 **4 字节**（`enum PackageType` 默认底层 int，显式布局在 offset 0），
        // 于是 `package.Type` = bytes[0] | bytes[1]<<8 | bytes[2]<<16 | bytes[3]<<24。
        // 一旦我们盖上章，Type 就变成 79|checksum<<8|magic<<16 这种巨值，
        // `package.Type is Clipboard or ClipboardPush` 判定失败 →
        // "Unexpected package type" → handShaken=false → 对端直接 close。
        //
        // 实测代价：不修这条时，剪贴板通道永远握手失败；且小文件推送会因写进内核缓冲而**假性成功**，
        // 只有 >= 几十 KB 才会以 EPIPE(errno=32) 暴露。
        // 注意：主通道仍然**必须**盖章 —— 那边走 TcpSendData/TcpReceiveData，
        // 对端会 `ProcessReceivedDataEx` 校验 magic/checksum 并清零 byte1..3。
        var hdrBuf = hdr.serialize()
        switch enc.encrypt(hdrBuf) {
        case .failure(let e): return .failure(.ioFailed("头包加密失败 \(e)"))
        case .success(let ct):
            if let err = writeAll(fd, ct) { return .failure(err) }
        }

        // ③ 读对端预热块（必须消耗掉，否则后面整条链错位）
        switch readAll(fd, 16) {
        case .failure(let e): return .failure(e)
        case .success(let blk): _ = dec.decrypt(blk)
        }

        // ④ 读对端头包
        let peerRaw: [UInt8]
        switch readAll(fd, 64) {
        case .failure(let e): return .failure(.handshakeFailed(e.localizedDescription))
        case .success(let b): peerRaw = b
        }
        guard case .success(let plain) = dec.decrypt(peerRaw) else {
            return .failure(.handshakeFailed("对端头包解密失败（加密参数不匹配）"))
        }
        guard let p = DataPacket.parse(plain) else {
            return .failure(.handshakeFailed("对端头包无法解析"))
        }
        guard p.type == .clipboard || p.type == .clipboardPush else {
            return .failure(.handshakeFailed("对端头包类型异常: \(p.type)"))
        }

        // 对端发 ClipboardPush(79) → 它要推数据给我们；发 Clipboard(69) → 它在等我们推。
        let peerIsPusher = (p.type == .clipboardPush)
        return .success(Session(enc: enc, dec: dec,
                                peerIsPusher: peerIsPusher,
                                peerName: p.machineName.isEmpty ? "unknown" : p.machineName,
                                peerPostAction: p.postAction))
    }

    // MARK: - 发送数据（SendClipboardData）

    /// 1024 字节 UTF-16LE 定长头 + 文件原始字节。
    private func sendDraggedFile(fd: Int32, enc: CBCContext, file: URL) -> Result<Int64, MWBClipboardError> {
        let size: Int64
        switch sendDataHeader(fd: fd, enc: enc, file: file) {
        case .failure(let e): return .failure(e)
        case .success(let n): size = n
        }
        guard let fh = FileHandle(forReadingAtPath: file.path) else {
            return .failure(.ioFailed("无法打开文件: \(file.path)"))
        }
        defer { try? fh.close() }

        // 文件字节。CBC 要求每次喂进去的都是 16 的整数倍，
        // 所以最后一片不足 16 时补 0 —— 接收端只认头里声明的字节数，多余的直接丢弃。
        log("[剪贴板] 开始推送 \(file.lastPathComponent)（\(fmtBytes(size))）…")
        var sent: Int64 = 0
        let chunk = 64 * 1024                     // 已是 16 的倍数
        while true {
            let data = fh.readData(ofLength: chunk)
            if data.isEmpty { break }
            var bytes = [UInt8](data)
            if bytes.count % MWBCrypto.blockSize != 0 {
                let pad = MWBCrypto.blockSize - (bytes.count % MWBCrypto.blockSize)
                bytes.append(contentsOf: [UInt8](repeating: 0, count: pad))
            }
            switch enc.encrypt(bytes) {
            case .failure(let e): return .failure(.ioFailed("数据加密失败 \(e)"))
            case .success(let ct):
                if let err = writeAll(fd, ct) { return .failure(err) }
            }
            sent += Int64(data.count)
        }
        return .success(sent)
    }

    /// 只发 1024 字节定长数据头，不发文件内容。返回声明的字节数。
    /// 拆出来是为了诊断：单独发头之后可以 poll 一下，看对端是「接受后在等数据」还是「直接关连接拒绝」。
    private func sendDataHeader(fd: Int32, enc: CBCContext, file: URL,
                                overrideHeader: String? = nil) -> Result<Int64, MWBClipboardError> {
        let attrs = try? FileManager.default.attributesOfItem(atPath: file.path)
        guard let size = (attrs?[.size] as? NSNumber)?.int64Value else {
            return .failure(.ioFailed("读不到文件大小: \(file.path)"))
        }
        // ① 1024 字节头。格式与 PowerToys 完全一致："{字节数}*{路径}"（UTF-16LE）
        //    接收端只取路径的最后一段当文件名，所以放 macOS 绝对路径是安全的。
        var hbuf = [UInt8](repeating: 0, count: 1024)
        let header = overrideHeader ?? "\(size)*\(file.path)"
        var i = 0
        for u in header.utf16 {
            if i + 1 >= 1024 { break }
            hbuf[i]     = UInt8(u & 0xFF)
            hbuf[i + 1] = UInt8((u >> 8) & 0xFF)
            i += 2
        }
        switch enc.encrypt(hbuf) {
        case .failure(let e): return .failure(.ioFailed("头加密失败 \(e)"))
        case .success(let ct):
            if let err = writeAll(fd, ct) { return .failure(err) }
        }
        return .success(size)
    }

    /// 诊断：握手 → 只发数据头 → poll 1.5s，判断对端是「接受」还是「拒绝」。
    ///
    /// 【为什么要这个】Windows 的 `Clipboard.ShakeHand` 会校验
    /// `ResolveID(MachineName) == Src && IsConnectedTo(Src)`；任一不满足就 `s.Close()`。
    /// 但它在拒绝前**先**把自己的头包发出来了，所以「能读到对端头包」并不能证明被接受。
    /// 唯一可靠的判据是：发完头之后连接是保持（=接受）还是被关（=拒绝）。
    ///
    /// - Parameter malformedHeader: true 时发一个**故意非法**的头（size 字段不是数字）。
    ///   PowerToys 的 `ReceiveAndProcessClipboardDataCore` 在解析头失败时是 `return`（**不关连接**），
    ///   所以：发坏头后连接若**保持** = ShakeHand 校验通过、问题在后面的落盘环节；
    ///   若仍被**关闭** = 拒绝发生在 `ShakeHand` 校验那一步（根本没走到读头）。
    public func diagnose(host: String, malformedHeader: Bool = false) -> String {
        guard let file = stagedFile else { return "✗ 没有暂存文件" }
        let fd = connectSocket(host: host, port: port)
        guard fd >= 0 else { return "✗ 无法连接 \(host):\(port)" }
        defer { Darwin.close(fd) }
        applySocketOptions(fd: fd)

        var out = ""
        let session: Session
        switch shakeHand(fd: fd, weAreDataHolder: true, post: .desktop) {
        case .failure(let e): return "✗ ShakeHand 失败: \(e.localizedDescription)"
        case .success(let s): session = s
        }
        out += "① ShakeHand: 对端=\(session.peerName) 对端要求推送=\(session.peerIsPusher) 对端PostAction=\(session.peerPostAction)\n"

        // ② 发头。malformedHeader=true 时头里 size 字段是 "notanumber"
        switch sendDataHeader(fd: fd, enc: session.enc, file: file,
                              overrideHeader: malformedHeader ? "notanumber*\(file.path)" : nil) {
        case .failure(let e): return out + "✗ 发头失败: \(e.localizedDescription)"
        case .success(let n):
            out += "② 已发 1024 字节头（\(malformedHeader ? "【故意非法】" : "")声明 \(n) 字节，"
                + "本机ID=\(myID) 机器名=\(machineName)）\n"
        }

        // ③ poll：接受 = 对端在等文件数据（无事件，超时）；拒绝 = 对端立即关闭（POLLIN→recv=0 或 POLLHUP）
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let r = poll(&pfd, 1, 1500)
        if r == 0 { return out + "③ 1.5s 无事件 → 连接保持 = 【接受】✓" }
        if r < 0 { return out + "✗ poll errno=\(errno)" }
        if (pfd.revents & Int16(POLLIN)) != 0 {
            var b: UInt8 = 0
            let n = Darwin.recv(fd, &b, 1, 0)
            if n == 0 { return out + "③ 对端已关闭连接（recv=0）→ 【拒绝】✗" }
            if n < 0 { return out + "③ recv errno=\(errno) → 【拒绝/复位】✗" }
            return out + "③ 对端发来 \(n) 字节（revents=\(pfd.revents)）"
        }
        if (pfd.revents & (Int16(POLLHUP) | Int16(POLLERR))) != 0 {
            return out + "③ revents=\(pfd.revents) → 连接挂断 = 【拒绝】✗"
        }
        return out + "③ revents=\(pfd.revents)"
    }

    // MARK: - 接收数据（Windows → Mac）

    /// 接收一帧数据。类型由 1024 字节头里的名字决定（对齐 PowerToys
    /// `ReceiveAndProcessClipboardDataCore` 的 `StartsWith("image"/"text")` 判定）：
    ///   `image`  → 剪贴板图片，收进内存（PNG 原始字节）
    ///   `text`   → 剪贴板文本，收进内存（DEFLATE 压缩的打包串）
    ///   其它     → 文件，落盘到 `桌面/MouseWithoutBorders/`
    private func receiveData(fd: Int32, dec: CBCContext, postAction: UInt32)
        -> Result<MWBClipboardPayload, MWBClipboardError> {
        // ① 1024 字节头
        let headRaw: [UInt8]
        switch readAll(fd, 1024) {
        case .failure(let e): return .failure(e)
        case .success(let b): headRaw = b
        }
        guard case .success(let plain) = dec.decrypt(headRaw) else {
            return .failure(.ioFailed("头解密失败"))
        }
        var units: [UInt16] = []
        var j = 0
        while j + 1 < plain.count {
            let u = UInt16(plain[j]) | (UInt16(plain[j + 1]) << 8)
            if u == 0 { break }
            units.append(u)
            j += 2
        }
        let header = String(decoding: units, as: UTF16.self)
        let parts = header.split(separator: "*", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let size = Int64(parts[0]) else {
            return .failure(.ioFailed("头格式异常: \(header.prefix(80))"))
        }
        let remotePath = String(parts[1])
        // ★★ 必须把 Windows 的反斜杠归一化，否则整条路径会变成文件名 ★★
        //
        // 对端发来的头里是 **Windows 路径**，实测长这样：
        //   C:\Users\bunkr\Desktop\MouseWithoutBorders\PixPin_2026-08-30_21-39-51.png
        // 而 `NSString.lastPathComponent` **只认 "/"** —— 遇到反斜杠路径它会原样返回，
        // 于是我们把「整条路径」当成了文件名。更坑的是 macOS 里 ":" 是合法字符
        // 但 Finder 会把它**显示成 "/"**，所以用户看到的名字就是一条完整路径
        // （2026-09-14 用户报的「文件名有问题是整个路径」就是这个）。
        // 修法：先把 "\" 换成 "/"，再取末段；最后把残留的 ":" 换成 "_" 兜底。
        let normalized = remotePath.replacingOccurrences(of: "\\", with: "/")
        var baseName = (normalized as NSString).lastPathComponent
        baseName = baseName.replacingOccurrences(of: ":", with: "_")
        guard !baseName.isEmpty, baseName != ".", baseName != ".." else {
            return .failure(.ioFailed("对端给出的文件名不可用: \(remotePath.suffix(80))"))
        }

        // ② 是不是剪贴板内容？（内存型载荷，不落盘）
        let lower = baseName.lowercased()
        let isImageWire = lower.hasPrefix("image")
        let isTextWire  = lower.hasPrefix("text")
        let toMemory = isImageWire || isTextWire

        let out: FileHandle?
        let dest: URL?
        if toMemory {
            log("[剪贴板] 对端来剪贴板\(isImageWire ? "图片" : "文本")：\(fmtBytes(size))")
            dest = nil
            out = nil
        } else {
            log("[剪贴板] 对端来文件：\(baseName)（\(fmtBytes(size))）"
                + (baseName == remotePath ? "" : "  原始路径=\(remotePath)"))
            // 落点：桌面\MouseWithoutBorders\（与 Windows 端 postAction=desktop 的习惯对齐）
            let home = FileManager.default.homeDirectoryForCurrentUser
            let dir = home.appendingPathComponent("Desktop/MouseWithoutBorders", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var d = dir.appendingPathComponent(baseName)
            // 重名自动加序号，避免覆盖
            var n = 1
            while FileManager.default.fileExists(atPath: d.path) {
                let stem = (baseName as NSString).deletingPathExtension
                let ext = (baseName as NSString).pathExtension
                let name = ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)"
                d = dir.appendingPathComponent(name)
                n += 1
            }
            FileManager.default.createFile(atPath: d.path, contents: nil)
            guard let fh = FileHandle(forWritingAtPath: d.path) else {
                return .failure(.ioFailed("无法写入 \(d.path)"))
            }
            dest = d
            out = fh
        }
        defer { try? out?.close() }

        // ③ 读 size 字节（按 16 对齐收，多收的丢掉）
        var buf: [UInt8] = []
        if toMemory { buf.reserveCapacity(Int(max(0, size))) }
        var remaining = size
        while remaining > 0 {
            let want = Int(min(Int64(64 * 1024), remaining))
            let aligned = (want + 15) / 16 * 16
            let raw: [UInt8]
            switch readAll(fd, aligned) {
            case .failure(let e): return .failure(e)
            case .success(let b): raw = b
            }
            guard case .success(let pt) = dec.decrypt(raw) else {
                return .failure(.ioFailed("数据解密失败"))
            }
            let take = Int(min(Int64(pt.count), remaining))
            if toMemory {
                buf.append(contentsOf: pt[0..<take])
            } else {
                out?.write(Data(pt[0..<take]))
            }
            remaining -= Int64(take)
        }

        if isImageWire {
            log("[剪贴板] ✓ 已收到图片（\(fmtBytes(Int64(buf.count)))，"
                + "PNG 魔数=\(ClipboardSync.looksLikePNG(Data(buf)) ? "✓" : "✗")）")
            return .success(.image(Data(buf)))
        }
        if isTextWire {
            log("[剪贴板] ✓ 已收到文本（压缩后 \(fmtBytes(Int64(buf.count)))）")
            return .success(.textWire(buf))
        }
        guard let dest else { return .failure(.ioFailed("落盘路径缺失")) }
        log("[剪贴板] ✓ 已保存到 \(dest.path)")
        return .success(.file(dest))
    }

    // MARK: - 发送剪贴板载荷（供对端来拉时用）

    /// 把一个内存型剪贴板载荷按 `SendClipboardData` 的格式发出去：
    /// 1024 字节定长头 `"{字节数}*image"` / `"{字节数}*text"` + 原始字节。
    ///
    /// ★ 头里的类型名**必须**是 `image` / `text`（小写即可，对端不区分大小写），
    ///   否则 Windows 会把它当文件存到磁盘上，而不是放进剪贴板。
    /// ★ 文件型载荷交给 `sendDraggedFile`（那条路会带上真实路径）。
    @discardableResult
    private func sendClipboardPayload(fd: Int32, enc: CBCContext, payload: MWBClipboardPayload)
        -> Result<Int64, MWBClipboardError> {
        let bytes: [UInt8]
        let name: String
        switch payload {
        case .file(let url):
            return sendDraggedFile(fd: fd, enc: enc, file: url)
        case .image(let d):
            bytes = [UInt8](d)
            name = "image"
        case .textWire(let b):
            bytes = b
            name = "text"
        }
        guard !bytes.isEmpty else { return .failure(.ioFailed("剪贴板载荷为空")) }

        var hbuf = [UInt8](repeating: 0, count: 1024)
        let header = "\(bytes.count)*\(name)"
        var i = 0
        for u in header.utf16 {
            if i + 1 >= 1024 { break }
            hbuf[i]     = UInt8(u & 0xFF)
            hbuf[i + 1] = UInt8((u >> 8) & 0xFF)
            i += 2
        }
        switch enc.encrypt(hbuf) {
        case .failure(let e): return .failure(.ioFailed("头加密失败 \(e)"))
        case .success(let ct):
            if let err = writeAll(fd, ct) { return .failure(err) }
        }

        // 数据体：CBC 要求每次喂进去的都是 16 的整数倍，末片补 0；
        // 对端只按头里声明的字节数收，多余的丢弃。
        var offset = 0
        let chunk = 64 * 1024
        while offset < bytes.count {
            let n = min(chunk, bytes.count - offset)
            var blk = Array(bytes[offset..<(offset + n)])
            if blk.count % MWBCrypto.blockSize != 0 {
                let pad = MWBCrypto.blockSize - (blk.count % MWBCrypto.blockSize)
                blk.append(contentsOf: [UInt8](repeating: 0, count: pad))
            }
            switch enc.encrypt(blk) {
            case .failure(let e): return .failure(.ioFailed("数据加密失败 \(e)"))
            case .success(let ct):
                if let err = writeAll(fd, ct) { return .failure(err) }
            }
            offset += n
        }
        return .success(Int64(bytes.count))
    }

    // MARK: - socket 工具

    private func applySocketOptions(fd: Int32) {
        var one: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        // 握手给 30s（对齐 PowerToys CLIPBOARD_HANDSHAKE_TIMEOUT），之后小一点避免长期悬挂
        var tv = timeval(tv_sec: 30, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    private func connectSocket(host: String, port: UInt16) -> Int32 {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM,
                             ai_protocol: IPPROTO_TCP, ai_addrlen: 0, ai_canonname: nil,
                             ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host.cString(using: .utf8), String(port), &hints, &res) == 0, let info = res else {
            return -1
        }
        defer { freeaddrinfo(res) }
        var p = info
        while true {
            let fd = socket(p.pointee.ai_family, p.pointee.ai_socktype, p.pointee.ai_protocol)
            if fd >= 0 {
                var tv = timeval(tv_sec: 6, tv_usec: 0)
                setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                if connect(fd, p.pointee.ai_addr, p.pointee.ai_addrlen) == 0 { return fd }
                Darwin.close(fd)
            }
            if let next = p.pointee.ai_next { p = next } else { break }
        }
        return -1
    }

    private func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> MWBClipboardError? {
        var off = 0
        while off < bytes.count {
            let n = bytes.withUnsafeBytes { buf -> ssize_t in
                Darwin.send(fd, buf.baseAddress!.advanced(by: off), bytes.count - off, 0)
            }
            if n <= 0 { return .ioFailed("socket 写入失败 (errno=\(errno))") }
            off += n
        }
        return nil
    }

    private func readAll(_ fd: Int32, _ n: Int) -> Result<[UInt8], MWBClipboardError> {
        if n == 0 { return .success([]) }
        var buf = [UInt8](repeating: 0, count: n)
        var got = 0
        while got < n {
            let r = buf.withUnsafeMutableBytes { raw -> ssize_t in
                Darwin.recv(fd, raw.baseAddress!.advanced(by: got), n - got, 0)
            }
            if r <= 0 {
                return .failure(.handshakeFailed("socket 读取中断 (已收 \(got)/\(n), errno=\(errno))"))
            }
            got += r
        }
        return .success(buf)
    }

    private func hostOf(_ fd: Int32) -> String {
        var peer = sockaddr_in()
        var plen = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard getpeername(fd, withUnsafeMutablePointer(to: &peer) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { $0 }
        }, &plen) == 0 else { return "unknown" }
        var ip = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        var a = peer.sin_addr
        inet_ntop(AF_INET, &a, &ip, socklen_t(INET_ADDRSTRLEN))
        return String(cString: ip)
    }

    /// 只做一次握手并立刻断开 —— 用来在真实环境判定 15100 通道是否可用。
    public func probe(host: String) -> String {
        let fd = connectSocket(host: host, port: port)
        guard fd >= 0 else { return "✗ 无法连接 \(host):\(port)" }
        defer { Darwin.close(fd) }
        applySocketOptions(fd: fd)
        switch shakeHand(fd: fd, weAreDataHolder: true, post: .desktop) {
        case .success(let s):
            return "✓ 握手成功：对端=\(s.peerName)，对端要求推送=\(s.peerIsPusher)，对端 PostAction=\(s.peerPostAction)"
        case .failure(let e):
            return "✗ \(e.localizedDescription)"
        }
    }
}

// MARK: - 工具

func fmtBytes(_ b: Int64) -> String {
    if b < 1024 { return "\(b) B" }
    if b < 1024 * 1024 { return String(format: "%.1f KB", Double(b) / 1024) }
    if b < 1024 * 1024 * 1024 { return String(format: "%.1f MB", Double(b) / 1024 / 1024) }
    return String(format: "%.2f GB", Double(b) / 1024 / 1024 / 1024)
}
