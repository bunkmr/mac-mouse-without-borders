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

// ★ 最早期就把 SIGPIPE 兜底装上（2026-09-23 事故：默认处置会让进程在断链重连时无声消失）。
//   Connection 内部建 socket 时还会再调一次（幂等），这里只是把窗口前移到"任何 I/O 之前"。
MWBConnection.installSIGPIPEIgnore()

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

// `--clip-image-selftest`：图片剪贴板**线格式**的离线断言（不碰系统剪贴板、不联网）。
// 判据来自对 PowerToys `FormHelper.cs` / `Clipboard.cs` / `SocketStuff.cs` 的逐行核对：
//   图片载荷 = **PNG 原始字节，不压缩** → 48 字节/片 → 包 Type=ClipboardImage(125)
//   → ClipboardDataEnd(76) 收尾；>1MB 改发 Clipboard(69) 心跳，对端回连 15100 时
//   头里声明 `"{字节数}*image"`。
if args.count > 1 && args[1] == "--clip-image-selftest" {
    let (pass, total, fails) = ClipboardSync.imageSelfTest()
    print("图片剪贴板线格式自测")
    for f in fails { print("  ✗ \(f)") }
    print("\n结果: \(pass)/\(total) 通过")
    exit(fails.isEmpty ? 0 : 2)
}

// ---- 可编程鼠标键：功能清单 → 两侧键序列的映射自测 ----
//
// 这张表是「数据」，最容易在改一处时把另一处带坏，而它在真机上表现为
// 「某个侧键突然什么都不做」，排查成本极高 → 必须离线可断言。
// ---- 鼠标移动包「最新值信箱」：离线纯逻辑断言（不需要网络/对端） ----
//
// 【为什么必须离线断言】这套逻辑写错的症状是"远端光标偶尔跳一下 / 最后一帧压在信箱里
// 没送出去"，真机上极难复现也极难归因；而它恰恰是跨屏 CPU 与跟手度优化的关键路径。
if args.count > 1 && args[1] == "--mouse-mailbox-selftest" {
    let (pass, total, fails) = MouseMoveMailbox.selfTest()
    print("鼠标移动包信箱自测")
    for f in fails { print("  ✗ \(f)") }
    print("\n结果: \(pass)/\(total) 通过")
    exit(fails.isEmpty ? 0 : 2)
}

// ---- 鼠标发送线程的哨兵判据（"该不该重启发送线程"）：离线纯逻辑断言 ----
//
// 【为什么必须离线断言】对应 bug 的现场极其反直觉：连接正常、键盘能用、日志里
// "鼠标包发送率"还有 100Hz+（那统计的是造帧数），**只有鼠标移动彻底不动**，
// 而 Windows 侧连光标都不显示（它跨屏时用自己画的假光标，只有收到鼠标包才显示）。
// 判据要是写错，要么救不回来（漏判），要么在鼠标静止时疯狂重启线程（误判）。
if args.count > 1 && args[1] == "--mouse-sender-supervisor-selftest" {
    let (pass, total, fails) = MouseSenderSupervisor.selfTest()
    print("鼠标发送线程哨兵判据自测")
    for f in fails { print("  ✗ \(f)") }
    print("\n结果: \(pass)/\(total) 通过")
    exit(fails.isEmpty ? 0 : 2)
}

if args.count > 1 && args[1] == "--input-inject-race-selftest" {
    // 回归 2026-09-14 的 SIGSEGV：两条接收线程并发改 InputController 的远端注入状态
    // （栈 = Set._Variant.insert ← injectMouseButton ← MWBClient.handle）。
    print("远端注入共享状态并发自检（回归「Set 并发修改崩溃」）")
    let ok = InputController.injectRaceSelfTest()
    print("\n结果: \(ok ? "通过" : "失败")")
    exit(ok ? 0 : 2)
}

if args.count > 1 && args[1] == "--clip-origin-selftest" {
    // 回归 2026-10-06「每复制一次就往桌面扔一张照片」：
    // Windows 把剪贴板图片当**文件**发（微信输入法会把图片落成临时 PNG），
    // 我们若按文件落盘，桌面就会被照片塞满。判据 = 来源（剪贴板宣布 vs 拖放）。
    print("剪贴板接收归类自检（回归「复制一次就往桌面扔照片」）")
    let ok = ClipboardIntakeSelfTest.run()
    print("\n结果: \(ok ? "通过" : "失败")")
    exit(ok ? 0 : 2)
}

if args.count > 1 && args[1] == "--screen-layout-selftest" {
    // 合并「屏幕方位 / 机器矩阵 / 本机槽位」三处重复控件后的几何推导。
    print("屏幕布局推导自检（方位由本机/对端相对槽位推导）")
    let ok = ScreenLayout.selfTest()
    print("\n结果: \(ok ? "通过" : "失败")")
    exit(ok ? 0 : 2)
}

if args.count > 1 && args[1] == "--edge-region-selftest" {
    // 用**当前这台机器真实的屏幕排列**验证出界判定。
    // 回归 2026-10-06「Mac 自己在最右边了，但鼠标还是可以往右穿越」：
    // 旧判据按"光标所在那块屏"取边界，多显示器时**内屏接缝**被误当成出界点。
    print("出界判定 · 真机多屏自检（不移动光标、不接管对端）")
    let ok = ScreenLayout.realMachineEdgeSelfTest()
    print("\n结果: \(ok ? "通过" : "失败")")
    exit(ok ? 0 : 2)
}

if args.count > 1 && args[1] == "--lang-selftest" {
    print("界面语言翻译表自检（跟随系统 / 简体中文 / English）")
    let ok = LocalizationSelfTest.run()
    print("\n结果: \(ok ? "通过" : "失败")")
    exit(ok ? 0 : 2)
}

if args.count > 1 && args[1] == "--clip-race-selftest" {
    // 回归 2026-09-19 的 SIGABRT：多连接并发收剪贴板分片 → 共享缓冲堆破坏（free_medium_botch）。
    print("剪贴板分片并发自检（回归「Windows 截图后 App 退出」）")
    let ok = ClipboardSync.raceSelfTest()
    print("\n结果: \(ok ? "通过" : "失败")")
    exit(ok ? 0 : 2)
}

if args.count > 1 && args[1] == "--reconnect-backoff-selftest" {
    // 回归「对端刚开机就被我们轰死」这一族事故（Windows 上 MWB 弹框自己关了 + Mac 连不上）：
    //   · 2026-09-22：退避长期封顶 8s 且永不放弃，对端离线 9 小时轰 2400+ 次；
    //   · 2026-10-06：封顶放宽到 60s，但"永不停歇"没改，7.5 小时仍是 590 次，
    //     照样把刚启动、配置尚未加载完的 MWB 连判 9 个 invalidkey 后打进
    //     `too many connections` 自我保护退出（用户今早看到的那个弹框）。
    // ⇒ 判据已从"总次数"升级为「总次数 < 200 **且** 稳态间隔 ≥ 600s」。
    print("重连退避曲线自检（回归「Windows 端 MWB 被连接洪水打进自我保护」）")
    let ok = MWBClient.reconnectBackoffSelfTest()
    print("\n结果: \(ok ? "通过" : "失败")")
    exit(ok ? 0 : 2)
}

if args.count > 1 && args[1] == "--sigpipe-selftest" {
    // 回归 2026-09-23「App 静默消失」：裸 fd I/O 改造丢掉了 CFStream 内建的
    // SO_NOSIGPIPE 保护 ⇒ 断链窗口里往已 RST 的 socket 写会抛 SIGPIPE，
    // 而 SIGPIPE 默认动作 = 直接终止进程（不可捕获、无日志、无崩溃报告）。
    // 实测一天被杀 3 次（16:06:42 / 17:01:07 / 18:04:14）。
    let ok = MWBConnection.sigpipeSelfTest()
    exit(ok ? 0 : 2)
}

if args.count > 1 && args[1] == "--sigpipe-selftest-raw" {
    // 阳性对照：恢复 SIGPIPE 默认处置后做同一个写操作 —— 必须被信号杀掉（退出码 141）。
    // 若这里打印出任何文字并正常退出，说明自检在空跑。
    exit(MWBConnection.sigpipeNegativeControl())
}

if args.count > 1 && args[1] == "--listener-retention-selftest" {
    // 回归 2026-09-23「回连风暴」：MWBListener 接受回连后**没人持有** MWBConnection，
    // 握手成功的一瞬间对象就析构 → deinit 关 fd → 对端 RST →
    // Windows 的 REOPEN_WHEN_WSAECONNRESET 立刻重连 → 每秒 3 次、永不停止。
    print("回连持有自检（回归「监听器不持有回连 → 对端 RST → 重连风暴」）")
    let ok = MWBListener.retentionSelfTest()
    print("\n结果: \(ok ? "通过" : "失败")")
    exit(ok ? 0 : 2)
}

if args.count > 1 && args[1] == "--conn-reconnect-reset-selftest" {
    // 回归 2026-09-20「假连接」：出站重连复用同一个 MWBConnection 对象，
    // 却不清 handshakeDone ⇒ doHandshake() 不等对端 HandshakeAck 就宣布成功
    // ⇒ Windows 睡醒后 Mac 连上一条对端不处理的连接（日志全绿、UI 显示"已连接"，但鼠标没反应）。
    print("重连会话状态重置自检（回归「Win 睡眠唤醒后鼠标推过去无光标」）")
    let ok = MWBConnection.reconnectResetSelfTest()
    print("\n结果: \(ok ? "通过" : "失败")")
    exit(ok ? 0 : 2)
}

if args.count > 1 && args[1] == "--standby-guard-selftest" {
    let (pass, total, fails) = StandbyGuard.selfTest()
    print("跨屏待机唤醒判据自测（当前供电：\(StandbyGuard.isOnACDescription())）")
    for f in fails { print("  ✗ \(f)") }
    print("\n结果: \(pass)/\(total) 通过")
    exit(fails.isEmpty ? 0 : 2)
}

if args.count > 1 && args[1] == "--mouse-map-selftest" {
    let (pass, total, fails) = MouseBindingStore.selfTest()
    print("鼠标按键映射自测")
    for f in fails { print("  ✗ \(f)") }
    print("\n结果: \(pass)/\(total) 通过")
    exit(fails.isEmpty ? 0 : 2)
}

// ---- 键盘捕获：macOS 键码 → 组合键串（高级设置里"按一下键就填进去"用的映射） ----
//
// 【为什么必须离线断言】这张表产出的字符串会直接落进配置（`cmd+shift+z` 这种）。
// 只要有一个键码映射错，用户在界面上按下去就会被判"非法组合"、设置静默失效，
// 而这类错误在同一批映射里往往只错一个键，极难在真机上定位。
if args.count > 1 && args[1] == "--keycap-selftest" {
    let (pass, total, fails) = KeyCaptureMap.selfTest()
    print("键盘捕获映射自测")
    for f in fails { print("  ✗ \(f)") }
    print("\n结果: \(pass)/\(total) 通过")
    exit(fails.isEmpty ? 0 : 2)
}

// ---- 自定义映射表（每行 `本机 = 远端`）的解析器自测 ----
if args.count > 1 && args[1] == "--keymap-selftest" {
    let (pass, total, fails) = KeyMappingTable.selfTest()
    print("自定义映射表自测")
    for f in fails { print("  ✗ \(f)") }
    print("\n结果: \(pass)/\(total) 通过")
    exit(fails.isEmpty ? 0 : 2)
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
/// 优先 LocalHostName(MacBook-Pro)，其次 hostname 去掉 .local，最后兜底 "Mac"。
func defaultMachineName() -> String {
    var candidates: [String] = []

    // 1) LocalHostName (系统设置→共享 里的名称, 如 "MacBook-Pro")
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

    // ⚠️ 必须串行：CBC 链里每段密文都参与下一段，而下面的"投喂鼠标"线程会与主循环
    //    并发发包 —— 不加锁两条链会互相踩坏（对端直接解密失败，表现为"连上但什么都不通"）。
    let sendLock = NSLock()
    func sendPacket(_ p: DataPacket) -> Bool {
        sendLock.lock()
        defer { sendLock.unlock() }
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

    // ③ 可选：定时投喂 Mouse(123) 包 —— 这是**端到端验证「跨屏待机唤醒」的唯一办法**
    //    （真机上"从 Windows 把鼠标晃过来"没法脚本化）。
    //    用法：MWB_FAKE_MOUSE_EVERY=3  → 连接建立后每 3 秒发一个鼠标移动包。
    //    预期（App 侧）：屏幕若已熄灭，日志出现
    //    「☀️ 屏幕已熄灭，收到远端键鼠包 → 已声明用户活动点亮屏幕」，且屏幕真的亮起来。
    if let every = Double(ProcessInfo.processInfo.environment["MWB_FAKE_MOUSE_EVERY"] ?? ""),
       every > 0 {
        print("[伪对端] 已开启鼠标包投喂：每 \(every)s 一个 Mouse(123)")
        fflush(stdout)
        let t = Thread {
            var i = 0
            while true {
                Thread.sleep(forTimeInterval: every)
                i += 1
                var m = DataPacket(type: .mouse, src: fakeID, des: 0)
                m.mouseFlags = InputController.mouseMoveFlag
                m.mouseX = 32767          // 归一化坐标中点：对端只关心"有人动了鼠标"
                m.mouseY = 32767
                if sendPacket(m) { print("[伪对端] → 已投喂第 \(i) 个 Mouse(123)") }
                fflush(stdout)
            }
        }
        t.name = "FakePeerMouseFeed"
        t.start()
    }

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
