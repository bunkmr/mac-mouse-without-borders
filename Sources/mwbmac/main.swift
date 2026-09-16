// main.swift — 无界面协议测试入口
// 用法: mwbmac <windows-host> <port> <securityKey> [machineName] [myID]
// 用途: 验证与 Windows 端 Mouse Without Borders 的连接、加密握手、Hello/Heartbeat 互通。
//       鼠标/键盘注入与本地捕获需要“辅助功能/输入监控”授权，无授权时会静默失败（属于正常）。

import Foundation
import MWBMacClientCore
import SystemConfiguration
import Darwin
import AppKit

// 无缓冲 stdout，避免被外部 kill 时丢失日志（管道下 Swift print 默认块缓冲）
setvbuf(stdout, nil, Int32(_IONBF), 0)

let args = CommandLine.arguments

// MARK: - 剪贴板打包串离线自测
//
// 用法: mwbmac --clip-bundle-selftest
//
// 纯离线断言：不碰系统剪贴板、不联网、不启动 UI。
// 核心用例是用户 2026-09-16 实际粘贴出来的那条乱码原文 —— 拆包后必须只剩干净的纯文本。
if args.count > 1 && args[1] == "--clip-bundle-selftest" {
    let SEP = MWBClipboardBundle.separator
    var pass = 0, fail = 0
    func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        if ok { pass += 1; print("  ✓ \(name)") }
        else { fail += 1; print("  ✗ \(name)" + (detail.isEmpty ? "" : "  → " + detail)) }
    }

    print("剪贴板打包串自测（分隔符 \(SEP)）\n")

    print("[1] 用户实际报的乱码原串")
    let garbled = "TXT昨天整理了一下 帮忙看看有什么问题吗" + SEP
        + "HTMVersion:0.9\nStartHTML:0000000117\nEndHTML:0000000246\n"
        + "StartFragment:0000000153\nEndFragment:0000000210\nSourceURL:\n"
        + "<html>\n<body>\n<!--StartFragment-->昨天整理了一下&nbsp;帮忙看看有什么问题吗<!--EndFragment-->\n</body>\n</html>"
        + SEP
    let g = MWBClipboardBundle.parse(garbled)
    check("纯文本 = 原文", g.text == "昨天整理了一下 帮忙看看有什么问题吗", "得到 \(g.text ?? "nil")")
    check("不含 TXT 前缀", !(g.text ?? "").hasPrefix("TXT"))
    check("不含分隔符 GUID", !(g.text ?? "").contains(SEP))
    check("HTML 已剥掉 CF_HTML 头", !(g.html ?? "").contains("Version:0.9"),
          "得到 \(g.html?.prefix(30) ?? "nil")")
    check("HTML 从 <html> 开始", (g.html ?? "").hasPrefix("<html>"))
    check("已识别为打包串", g.sawTaggedEntry)

    print("\n[2] 打包 → 拆包 往返")
    let packed = MWBClipboardBundle.pack(text: "勾选保留理由",
                                         html: "<html><body>勾选保留理由</body></html>",
                                         rtf: "{\\rtf1 勾选}")
    check("打包串以 TXT 条目开头", (packed ?? "").hasPrefix("TXT勾选保留理由" + SEP),
          "得到 \(packed?.prefix(20) ?? "nil")")
    let rt = MWBClipboardBundle.parse(packed ?? "")
    check("往返 纯文本", rt.text == "勾选保留理由", "得到 \(rt.text ?? "nil")")
    check("往返 HTML", rt.html == "<html><body>勾选保留理由</body></html>", "得到 \(rt.html ?? "nil")")
    check("往返 RTF", rt.rtf == "{\\rtf1 勾选}", "得到 \(rt.rtf ?? "nil")")

    print("\n[3] 边界：裸文本（无分隔符）绝不能被砍掉前 3 个字符")
    for raw in ["HTM是超文本标记语言", "TXT文件说明", "RTF是什么东西", "普通一句话"] {
        let p = MWBClipboardBundle.parse(raw)
        check("「\(raw)」原样保留", p.text == raw, "得到 \(p.text ?? "nil")")
        check("「\(raw)」未被误判成打包串", !p.sawTaggedEntry)
    }

    print("\n[4] 边界：只有 HTM 条目、没有 TXT")
    let htmlOnly = "HTM<html><body>只有网页版<br>第二行</body></html>" + SEP
    let h = MWBClipboardBundle.parse(htmlOnly)
    let fallback = MWBClipboardBundle.plainText(fromHTML: h.html ?? "")
    check("text 为 nil（确实没有 TXT）", h.text == nil)
    check("从 HTML 兜底出纯文本", fallback.contains("只有网页版") && fallback.contains("第二行"),
          "得到 \(fallback)")

    print("\n[5] 边界：空串 / 只有分隔符")
    check("空串 → 无内容", MWBClipboardBundle.parse("").isEmpty)
    check("只有分隔符 → 无内容", MWBClipboardBundle.parse(SEP + SEP).isEmpty)

    print("\n结果: \(pass) 通过, \(fail) 失败")
    exit(fail == 0 ? 0 : 2)
}

// MARK: - 剪贴板写入自测（真机 pasteboard 往返）
//
// 用法: mwbmac --clip-write-selftest
//
// 把「拆包 → 写本机剪贴板 → 读回」这条真实链路跑一遍（只跳过 socket）：
// 这是整条接收链里最容易出错、也最该实测的一步 —— 多类型同时写进去之后，
// 纯文本框到底还能不能读到干净文字、HTML 是不是真的成了 public.html。
//
// 【副作用】会短暂占用系统剪贴板（写入→读回→还原原字符串，毫秒级窗口）。
// 只能还原纯文本部分，其他类型不还原 —— 这是自测，不是给用户用的功能。
if args.count > 1 && args[1] == "--clip-write-selftest" {
    let pb = NSPasteboard.general
    let savedString = pb.string(forType: .string)
    let savedTypes = (pb.types ?? []).map { $0.rawValue }

    let SEP = MWBClipboardBundle.separator
    let garbled = "TXT昨天整理了一下 帮忙看看有什么问题吗" + SEP
        + "HTMVersion:0.9\nStartHTML:0000000117\nEndHTML:0000000246\n"
        + "StartFragment:0000000153\nEndFragment:0000000210\nSourceURL:\n"
        + "<html>\n<body>\n<!--StartFragment-->昨天整理了一下&nbsp;帮忙看看有什么问题吗<!--EndFragment-->\n</body>\n</html>"
        + SEP

    var pass = 0, fail = 0
    func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        if ok { pass += 1; print("  ✓ \(name)") }
        else { fail += 1; print("  ✗ \(name)" + (detail.isEmpty ? "" : "  → " + detail)) }
    }

    print("剪贴板写入自测（真机 pasteboard）")
    print("写入前类型: \(savedTypes.joined(separator: ", "))\n")

    let sync = ClipboardSync.shared
    sync.writeBundle(MWBClipboardBundle.parse(garbled))

    let outTypes = (pb.types ?? []).map { $0.rawValue }
    let outString = pb.string(forType: .string)
    let outHTML = pb.data(forType: .html).flatMap { String(data: $0, encoding: .utf8) }

    print("写入后类型: \(outTypes.joined(separator: ", "))\n")
    check("纯文本 = 原文", outString == "昨天整理了一下 帮忙看看有什么问题吗", "得到 \(outString ?? "nil")")
    check("纯文本不含 TXT 前缀", !(outString ?? "").hasPrefix("TXT"))
    check("纯文本不含分隔符 GUID", !(outString ?? "").contains(SEP))
    check("带上了 public.html 类型", outTypes.contains("public.html"))
    check("HTML 从 <html> 开始", (outHTML ?? "").hasPrefix("<html>"), "得到 \(outHTML?.prefix(25) ?? "nil")")
    check("HTML 不含 CF_HTML 头", !(outHTML ?? "").contains("Version:0.9"))

    // 还原（只能还原纯文本）
    pb.clearContents()
    if let s = savedString { pb.setString(s, forType: .string) }

    print("\n结果: \(pass) 通过, \(fail) 失败（原剪贴板纯文本已还原）")
    exit(fail == 0 ? 0 : 2)
}

guard args.count >= 4 else {
    fputs("用法: mwbmac <windows-host> <port> <securityKey> [machineName] [myID]\n", stderr)
    exit(1)
}

let host = args[1]
let port = UInt16(args[2]) ?? 15101
let key = args[3]

/// MWB 靠「机器名」识别每台机器，Windows 端 MWB 里填的名字必须和这里发出的完全一致，
/// 否则对方会把我们当成未知机器 → 不加进机器矩阵 → 认证通过但之后完全静默。
/// 规则与 Windows 一致: 用主机名原样(小写/含连字符)，不要空格。
/// 优先 LocalHostName(MacBook-Pro-2)，其次 hostname 去掉 .local，最后兜底 "Mac"。
func defaultMachineName() -> String {
    var candidates: [String] = []

    // 1) LocalHostName (系统设置→共享 里的名称, 如 "MacBook-Pro-2")
    if let ln = SCDynamicStoreCopyLocalHostName(nil) as String? {
        candidates.append(ln)
    }
    // 2) hostname 去掉 .local 后缀
    var buf = [CChar](repeating: 0, count: 256)
    if gethostname(&buf, buf.count) == 0 {
        var h = String(cString: buf)
        if h.hasSuffix(".local") { h = String(h.dropLast(".local".count)) }
        candidates.append(h)
    }
    if let c = SCDynamicStoreCopyComputerName(nil, nil) as String? { candidates.append(c) }
    for c in candidates {
        // MWB 不接受空格: "MacBook Pro" -> "MacBook-Pro"
        let cleaned = c.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleaned.isEmpty { return cleaned.replacingOccurrences(of: " ", with: "-") }
    }
    return "Mac"
}

let name = args.count > 4 ? args[4] : defaultMachineName()
let myID = args.count > 5 ? (UInt32(args[5]) ?? 2) : 2

// MARK: - 伪对端模式（自测 / 排障用）
//
// 用法: mwbmac --peer <port> <securityKey> [machineName] [myID]
//
// 在本机扮演一次「Windows 侧」，只在一个端口上监听、接受一个回连、完成握手，
// 之后静默到进程被杀。
//
// 【为什么必须单独写，不能直接复用 MWBConnection】我们的客户端在握手时是**后手**：
// 它要先读到对端发来的第一个包，才能自校准 magic（magic 的推导公式未能反推，
// 见 Connection.swift 顶部说明）。两个我们自己的实例互连会**双双卡在等对方先发**，
// 握手永远完不成 —— 这正是第一次自测失败的原因。真实 Windows 端是先发那个包的一方。
// 所以这里显式补上「先发一个带 magic 的包」这一步。
//
// 用途：链路看门狗 / 自动重连这类"先连上、再让对端消失"的逻辑，真实 Windows 端
// 不一定随时在线；配上 App 的 MWB_AUTOCONNECT=127.0.0.1:<port>，
// 就能在**完全本机**的环境里跑通「连上 → 断链 → 交回控制权 → 自动重连 → 恢复」。
func readN(_ fd: Int32, _ n: Int) -> [UInt8]? {
    var buf = [UInt8](repeating: 0, count: n)
    var got = 0
    while got < n {
        let r = Darwin.read(fd, &buf[got], n - got)
        if r <= 0 { return nil }
        got += r
    }
    return buf
}

func writeN(_ fd: Int32, _ data: [UInt8]) -> Bool {
    var sent = 0
    while sent < data.count {
        let r = data.withUnsafeBytes { p -> Int in
            Darwin.write(fd, p.baseAddress!.advanced(by: sent), data.count - sent)
        }
        if r <= 0 { return false }
        sent += r
    }
    return true
}

/// 扮演 Windows 侧跑完握手；连接断开时返回。
func serveFakePeer(peerFD: Int32, key: String, name: String, fakeID: UInt32, magic: UInt16) {
    guard case .success(let k) = MWBCrypto.deriveKey(securityKey: key) else {
        print("[伪对端] 密钥派生失败")
        return
    }
    // 发/收各一条 CBC 链，与真实实现一致
    let outCtx = CBCContext(key: k, iv: MWBCrypto.legacyIV())
    let inCtx  = CBCContext(key: k, iv: MWBCrypto.legacyIV())

    func sendPacket(_ p: DataPacket) -> Bool {
        var buf = p.serialize()
        MWBCrypto.stampPacket(&buf, magic: magic)
        guard case .success(let ct) = outCtx.encrypt(buf) else { return false }
        return writeN(peerFD, ct)
    }

    // ① 读对端 16 字节预热块，并回自己的
    guard readN(peerFD, 16) != nil else { return }
    guard case .success(let warm) = outCtx.encrypt(MWBCrypto.randomBytes(16)), writeN(peerFD, warm) else { return }

    // ② ★ 主动发第一个包（真实 Windows 端的行为）。
    //    对端收到它会用 checksum 判定合法并学走 magic=0x3555。
    var hello = DataPacket(type: .heartbeatEx, src: fakeID, des: 255)
    hello.machineName = name
    guard sendPacket(hello) else { return }
    print("[伪对端] 已发首个包（magic=0x\(String(magic, radix: 16))），等对端握手…")

    var ackCount = 0
    while true {
        guard let c1 = readN(peerFD, DataPacket.smallSize) else { return }
        guard case .success(var plain) = inCtx.decrypt(c1) else { continue }
        // big 类包由两段 32 字节拼成
        let t = PackageType(rawValue: UInt32(plain[0]))
        if DataPacket.isBigType(t) {
            guard let c2 = readN(peerFD, DataPacket.smallSize),
                  case .success(let p2) = inCtx.decrypt(c2) else { return }
            plain.append(contentsOf: p2)
        }
        guard MWBCrypto.validatePacket(plain, magic: magic) else { continue }
        var b = plain
        MWBCrypto.clearStamp(&b)
        guard let pkt = DataPacket.parse(b) else { continue }

        if pkt.type == .handshake {
            var ack = DataPacket(type: .handshakeAck, id: pkt.id, src: fakeID, des: pkt.src)
            ack.machine1 = ~pkt.machine1
            ack.machine2 = ~pkt.machine2
            ack.machine3 = ~pkt.machine3
            ack.machine4 = ~pkt.machine4
            ack.machineName = name
            guard sendPacket(ack) else { return }
            ackCount += 1
            if ackCount == 1 { print("[伪对端] ✓ 已回送 HandshakeAck，双向认证应已完成") }
        } else if pkt.type == .heartbeatEx || pkt.type == .heartbeat {
            // 回显心跳，维持连接（与真实实现一致）
            var r = DataPacket(type: pkt.type, src: fakeID, des: pkt.src)
            r.machineName = name
            _ = sendPacket(r)
        }
    }
}

// MARK: - 剪贴板通道探针
//
// 用法: mwbmac --clip-probe <host> <clipPort> <securityKey> <machineName> <myID>
//
// 只做一次 MWB **原生剪贴板通道**的 ShakeHand 就断开。
// 【为什么要它】剪贴板通道（15100）与主通道是两条独立 TCP，握手也不同：
// 主通道跑 10 个 Handshake 挑战，剪贴板通道只交换「16 字节预热块 + 64 字节头包」。
// 想确认「同一套 legacy 固定 salt/IV 加密在剪贴板通道上是否也成立」，
// 跑这个探针一条命令就有结论，不必启动完整 UI 去猜。
if args[1] == "--clip-probe" {
    guard args.count >= 6 else {
        fputs("用法: mwbmac --clip-probe <host> <clipPort> <securityKey> <machineName> <myID>\n", stderr)
        exit(1)
    }
    let pHost = args[2]
    let pPort = UInt16(args[3]) ?? 15100
    let pKey  = args[4]
    let pName = args[5]
    let pID   = args.count > 6 ? (UInt32(args[6]) ?? 2) : 2

    print("剪贴板通道探针: 目标 \(pHost):\(pPort)  机器名=\(pName)  本机ID=\(pID)")
    let ch = MWBClipboardChannel(port: pPort, securityKey: pKey, machineName: pName, myID: pID)
    ch.onLog = { print("[探针] \($0)") }
    let result = ch.probe(host: pHost)
    print("探针结果: \(result)")
    exit(result.hasPrefix("✓") ? 0 : 2)
}

// MARK: - 剪贴板通道推送测试
//
// 用法: mwbmac --clip-push <host> <clipPort> <securityKey> <machineName> <myID> <filePath>
//
// 走 MWB 原生剪贴板通道把一个文件推给对端（PostAction=Desktop）。
// 用来在真实环境验证「握手 → 1024 字节定长头 → 文件字节」整条链路，
// 以及确认对端确实把它落到 桌面\MouseWithoutBorders\。
if args[1] == "--clip-push" {
    guard args.count >= 7 else {
        fputs("用法: mwbmac --clip-push <host> <clipPort> <securityKey> <machineName> <myID> <filePath>\n", stderr)
        exit(1)
    }
    let pHost = args[2]
    let pPort = UInt16(args[3]) ?? 15100
    let pKey  = args[4]
    let pName = args[5]
    let pID   = UInt32(args[6]) ?? 2
    let pFile = URL(fileURLWithPath: args[7])

    print("剪贴板通道推送: \(pFile.path) → \(pHost):\(pPort)  机器名=\(pName)  本机ID=\(pID)")
    let ch = MWBClipboardChannel(port: pPort, securityKey: pKey, machineName: pName, myID: pID)
    ch.onLog = { print("[推送] \($0)") }
    ch.stagedFile = pFile
    switch ch.pushStagedFile(to: pHost) {
    case .success(let n):
        print("✓ 推送完成：\(n) 字节。请到 Windows 的 桌面\\MouseWithoutBorders\\ 查看。")
        exit(0)
    case .failure(let e):
        print("✗ 推送失败: \(e.localizedDescription)")
        exit(2)
    }
}

// MARK: - 剪贴板通道接受性诊断
//
// 用法: mwbmac --clip-diag <host> <clipPort> <securityKey> <machineName> <myID> <filePath>
//
// 握手 + 只发 1024 字节头 + poll，判定对端是【接受】还是【拒绝】。
// 【为什么需要】Windows 拒绝前也会先把它的头包发出来，所以「读到对端头包」不能证明被接受；
// 而小文件推送即使被拒绝也可能因为写进内核缓冲而假性成功（只有 >= 几十 KB 才会暴露 EPIPE）。
if args[1] == "--clip-diag" {
    guard args.count >= 7 else {
        fputs("用法: mwbmac --clip-diag <host> <clipPort> <securityKey> <machineName> <myID> <filePath>\n", stderr)
        exit(1)
    }
    let pHost = args[2]
    let pPort = UInt16(args[3]) ?? 15100
    let pKey  = args[4]
    let pName = args[5]
    let pID   = UInt32(args[6]) ?? 2
    let pFile = URL(fileURLWithPath: args[7])

    print("剪贴板通道诊断: \(pHost):\(pPort)  机器名=\(pName)  本机ID=\(pID)  文件=\(pFile.lastPathComponent)")
    let ch = MWBClipboardChannel(port: pPort, securityKey: pKey, machineName: pName, myID: pID)
    ch.onLog = { print("[诊断] \($0)") }
    ch.stagedFile = pFile
    print(ch.diagnose(host: pHost))
    exit(0)
}

// MARK: - 剪贴板通道「坏头」诊断
//
// 用法: mwbmac --clip-diag-bad <host> <clipPort> <securityKey> <machineName> <myID> <filePath>
//
// 发一个**故意非法**的数据头（size 字段不是数字）。PowerToys 在解析失败时是 return（不关连接），
// 所以：连接保持 = 已经越过 ShakeHand 校验（问题在落盘环节）；连接被关 = 拒绝发生在 ShakeHand。
if args[1] == "--clip-diag-bad" {
    guard args.count >= 7 else {
        fputs("用法: mwbmac --clip-diag-bad <host> <clipPort> <securityKey> <machineName> <myID> <filePath>\n", stderr)
        exit(1)
    }
    let pHost = args[2]
    let pPort = UInt16(args[3]) ?? 15100
    let pKey  = args[4]
    let pName = args[5]
    let pID   = UInt32(args[6]) ?? 2
    let pFile = URL(fileURLWithPath: args[7])

    print("剪贴板通道坏头诊断: \(pHost):\(pPort)  机器名=\(pName)  本机ID=\(pID)")
    let ch = MWBClipboardChannel(port: pPort, securityKey: pKey, machineName: pName, myID: pID)
    ch.onLog = { print("[坏头] \($0)") }
    ch.stagedFile = pFile
    print(ch.diagnose(host: pHost, malformedHeader: true))
    exit(0)
}

if args[1] == "--peer" || args[1] == "--listen" {
    // 自己建监听 socket，**不能**复用 MWBListener —— 它内部有独立的 accept 循环，
    // 会和这里抢同一个连接，导致一半连接走它那套（在对端也是我们时会死锁）的握手。
    let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { print("socket 创建失败 errno=\(errno)"); exit(1) }
    var yes: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = UInt16(port).bigEndian
    addr.sin_addr.s_addr = INADDR_ANY.bigEndian
    let br = withUnsafePointer(to: &addr) { p in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard br == 0, Darwin.listen(fd, 8) == 0 else {
        print("端口 \(port) 绑定/监听失败 errno=\(errno)（是否已被占用？）")
        exit(1)
    }
    print("伪对端模式：端口 \(port)，机器名 \(name)，id \(myID)。Ctrl+C 退出。")
    let t = Thread {
        while true {
            var remote = sockaddr()
            var len = socklen_t(MemoryLayout<sockaddr>.size)
            let pfd = Darwin.accept(fd, &remote, &len)
            if pfd < 0 { continue }
            print("[伪对端] 收到连接 fd=\(pfd)，开始接管…")
            let th = Thread {
                serveFakePeer(peerFD: pfd, key: key, name: name, fakeID: 0xAA860F4, magic: 0x3555)
                print("[伪对端] 连接结束，关闭 fd=\(pfd)")
                Darwin.close(pfd)
            }
            th.name = "FakePeerConn"
            th.start()
        }
    }
    t.name = "FakePeerAccept"
    t.start()
    RunLoop.main.run()
    exit(0)
}

print("连接 \(host):\(port)  name=\(name)  id=\(myID)")
print("注意: Windows 端 MWB 中登记的机器名必须与上面的 name 完全一致（大小写不敏感，但字符要对）")
let client = MWBClient(host: host, port: port, securityKey: key, machineName: name, myID: myID)

switch client.run() {
case .success:
    print("已连接。将持续打印收到的包；按 Ctrl+C 退出。")
    RunLoop.main.run()
case .failure(let e):
    print("连接失败: \(e)")
    exit(1)
}
