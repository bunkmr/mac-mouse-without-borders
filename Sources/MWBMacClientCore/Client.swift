// Client.swift
// 客户端编排：连接(含握手/注册)、包分发、心跳保活、剪贴板、双向捕获。

import Foundation
import AppKit

// Windows 鼠标消息（与 InputController 对齐）
private let WM_MOUSEMOVE: Int32   = 0x0200
private let WM_LBUTTONDOWN: Int32 = 0x0201
private let WM_LBUTTONUP: Int32   = 0x0202
private let WM_RBUTTONDOWN: Int32 = 0x0204
private let WM_RBUTTONUP: Int32   = 0x0205
private let WM_MBUTTONDOWN: Int32 = 0x0207
private let WM_MBUTTONUP: Int32   = 0x0208
private let WM_MOUSEWHEEL: Int32  = 0x020A

public final class MWBClient {
    public let connection: MWBConnection
    public let input = InputController.shared
    public let clipboard = ClipboardSync.shared
    /// 机器矩阵（最多 4 台）状态 —— 面板里显示「4 个联机状态」用。
    public let matrix = MachineMatrix()

    public var peerID: UInt32 = 0
    public var peerName: String = ""

    /// 矩阵状态变化回调（面板刷新用）。
    public var onMatrixChanged: (() -> Void)?

    /// 跨屏文件传输（走 **MWB 原生剪贴板协议**，端口 = 主通道 - 1；Windows 端无需任何额外程序）
    public let fileTransfer = FileTransferClient()
    /// MWB 原生剪贴板通道实例（15100）。
    public private(set) var clipboardChannel: MWBClipboardChannel?
    /// 对端（Windows）是否已进入「投放态」—— 即它正拖文件过来，等鼠标抬起就去拉取。
    private var peerIsDropping = false
    /// 投放态看门狗：`peerIsDropping` 若长期没人收尾（对端信令丢了 / 用户中途按 Esc 取消），
    /// 会让**之后**任意一次左键抬起都被误判成"投放收尾"并去拉文件。
    private var dropWatchdog: DispatchSourceTimer?
    /// 投放态中收到过多少个「非位移」远端鼠标包（诊断用；判断 Windows 有没有发松手过来）。
    private var dropMouseProbe = 0
    /// Hi 包日志限流（Windows 在拖放/切机器时会一秒连发十几个，原样打印会冲爆面板）。
    private var hiLogCount = 0
    private var lastHiLogAt = Date.distantPast
    /// 上一次「因为对端心跳包 Clipboard(69) 而去拉大剪贴板」的时间（3 秒去重）。
    private var lastBigClipboardPullAt: Date?
    /// 最近一次「对端宣布它剪贴板里有大数据」的时间（心跳包 Clipboard(69) / 切机通知 MachineSwitched）。
    /// 对齐 PowerToys `Clipboard.BIG_CLIPBOARD_DATA_TIMEOUT = 30000`：超过 30 秒就不再回连去拉，
    /// 免得对着一个早失效的心跳白发一轮连接、刷一屏失败日志。
    private var lastBigClipboardBeatAt: Date?
    /// 屏幕边缘投放带（拖文件过去即发送）
    private let dropPanel = EdgeDropPanel()
    private var lastClipFiles: [String] = []
    private var lastClipChangeCount: Int = -1

    // MARK: - 可供 GUI / 调用方显式指定的配置（优先级高于环境变量）

    /// Windows 屏幕相对本机的方位。nil 时回落到 MWB_EDGE 环境变量，再回落到 .right
    public var preferredEdge: SwitchEdge? = nil
    /// 远端参考分辨率。**仅当 motionScale == .pixelExact 时才有意义**（1:1 像素映射）。
    /// nil 时回落到 MWB_REMOTE_W/H，再回落到 1920x1080
    public var preferredRemoteSize: CGSize? = nil
    /// 位移换算方式。nil 时回落到 MWB_MOTION_SCALE 环境变量，再回落到 .proportional
    public var preferredMotionScale: MotionScale? = nil
    /// 控制远端期间是否把本机光标钉在屏幕边缘（默认 true）。
    /// nil 时回落到 MWB_LOCK_CURSOR 环境变量（=0 关闭），再回落到 true。
    public var preferredLockCursor: Bool? = nil
    /// 文件通道对端地址。nil 时与 MWB 对端 IP 相同
    public var fileHostOverride: String? = nil
    /// 文件通道端口。nil 时回落到 MWB_FILE_PORT，再回落到 **主通道端口 - 1**（即 MWB 的 TcpPort）
    public var filePortOverride: UInt16? = nil
    /// 是否启用屏幕边缘投放带
    public var dropDockEnabled: Bool = true
    /// 是否启用「Finder 复制文件即自动同步」
    public var clipboardFileEnabled: Bool = true
    /// 本机在 MWB 机器矩阵里的槽位（1..4）。nil = 自动（随机 ID，由对端 Matrix 学习槽位）。
    ///
    /// 协议里机器 ID 就是 1..4 的物理槽位序号，不是随机 GUID。填对槽位能让
    /// Windows 面板里的布局和我们对齐；不填也能正常工作（保持历史行为）。
    public var preferredSlot: UInt32? = nil
    /// 日志回调。设了就走回调，不再 print（GUI 用）
    public var onLog: ((String) -> Void)?
    /// 事件捕获是否真正可用（false = 缺辅助功能/输入监控授权，键鼠无法跨屏）
    public var onCaptureStatus: ((Bool, String) -> Void)?
    public private(set) var captureOK = false

    /// 用户勾完权限后无需重启整个 App，直接重试建立事件捕获。
    public func retryCapture() {
        input.startCapture()
    }

    private func log(_ s: String) {
        if let h = onLog { h(s) } else { print(s) }
    }

    // MARK: - 链路看门狗

    // MARK: - 鼠标移动包：合流 + 独立发送线程

    /// 鼠标移动包的「最新值信箱」（见 `MouseMoveMailbox.swift`）。
    let mouseMailbox = MouseMoveMailbox()
    /// 移动包是否走**异步合流**（默认开）。
    ///
    /// `MWB_MOUSE_ASYNC=0` 关掉它 → 回到"在事件 tap 回调里同步写 socket"的老行为。
    /// 保留这个开关的唯一目的是**做对照实验**：CPU 这种指标受采样噪声影响很大，
    /// 只有"同一份二进制、交替跑 A/B"得到的差值才可信（本项目已多次被噪声误导）。
    let mouseAsyncSend = ProcessInfo.processInfo.environment["MWB_MOUSE_ASYNC"] != "0"
    /// 唤醒发送线程的信号量。只在信箱"空 → 非空"时 signal 一次。
    let mouseMailboxSignal = DispatchSemaphore(value: 0)
    private var mouseSenderThread: Thread?
    /// 发送线程的**代际号**（只增不减）。
    ///
    /// 【为什么不能用 Bool】与本项目捕获线程踩过的坑一模一样：`startMouseMoveSender()`
    /// 第一行就调 `stopMouseMoveSender()`，若用 Bool 就是"设 true → 立刻设回 false"，
    /// 而旧线程此刻多半还阻塞在信号量上，醒来读到的已经是被重置的 false →
    /// **旧线程永不退出**，下一次进入远端就会有两个发送线程同时写同一条 socket。
    /// 代际号让旧线程无论如何都能识别出"我不是当代"。
    private var mouseSenderGeneration = 0
    /// 上次汇报合流效果的时刻 / 当时的合并计数（每 5 秒最多汇报一次，且只在真的合并过时才打）。
    private var mouseMailboxReportAt = Date.distantPast
    private var mouseMailboxReportedCoalesced = 0

    /// 起一条**专门发鼠标移动包**的线程。
    ///
    /// 【为什么是独立线程而不是 GCD 队列】发送必须严格串行（CBC 链式加密 + socket 字节流
    /// 不允许交错），一条常驻线程最省事也最可预期；`connection.send` 内部还有 `sendLock`
    /// 兜住与其它线程（剪贴板/按键/心跳）的并发写。
    ///
    /// 【为什么 `userInteractive`】这一条线程直接决定远端光标的跟手程度，
    /// 必须能抢到 CPU，不能排在后台任务后面。
    private func startMouseMoveSender() {
        stopMouseMoveSender()
        mouseSenderGeneration += 1
        let gen = mouseSenderGeneration
        let t = Thread { [weak self] in
            while let s0 = self, s0.mouseSenderGeneration == gen {
                s0.mouseMailboxSignal.wait()
                // 一次唤醒把信箱取干：取的永远是"当下最新"的那一帧，
                // 中间被顶掉的帧不会发出去（这正是省 CPU 的地方）。
                while let s = self, s.mouseSenderGeneration == gen,
                      let p = s.mouseMailbox.takeLatest() {
                    if case .failure(let e) = s.connection.send(p) {
                        s.handleSendFailure(e)
                        break               // 链路有问题时别再闷头发，交给看门狗
                    }
                    s.sendFailStreak = 0
                    s.reportMouseMailboxIfNeeded()
                }
            }
        }
        t.name = "MWBMouseSend"
        t.qualityOfService = .userInteractive
        mouseSenderThread = t
        t.start()
    }

    private func stopMouseMoveSender() {
        mouseSenderGeneration += 1           // 旧线程看到代号变了就退出
        mouseMailbox.discardPending()        // 过期的位置不要再打扰对端
        mouseMailboxSignal.signal()          // 让阻塞在 wait 上的线程醒来看一眼代号
        mouseSenderThread = nil
    }

    /// 每 5 秒最多汇报一次"合流省掉了多少帧"——用来确认这套机制真的在起作用。
    /// 只在**合并计数有增长**时才打，避免安静时刷屏。
    private func reportMouseMailboxIfNeeded() {
        let now = Date()
        guard now.timeIntervalSince(mouseMailboxReportAt) > 5 else { return }
        let c = mouseMailbox.coalesced
        guard c > mouseMailboxReportedCoalesced else { return }
        mouseMailboxReportAt = now
        mouseMailboxReportedCoalesced = c
        log("[MWB] 鼠标移动包合流：\(mouseMailbox.summary)"
            + " —— 发送线程只顾得上发最新的，过期位置直接丢掉（不阻塞事件 tap）")
    }

    /// 统一处理发送失败：限流打日志 + 连续失败到阈值就判定链路死亡。
    ///
    /// 【为什么不能只打一行日志了事】`writeRaw` 返回 `.writeFailed` 时，socket 在
    /// 阻塞模式下 `write()` 返回 ≤0，意味着对端已关闭 / RST / 写超时 —— 这类错误
    /// 不会自愈。旧实现只是打日志继续发，结果：
    ///   ① 日志被 1869 行 `writeFailed` 刷屏，有价值的诊断信息全被冲掉；
    ///   ② 输入仍被吞在本机（本机光标还锁在屏幕边缘），用户看到的是
    ///      「鼠标在 Windows 上延时不跟手、一顿一顿，像回报率不对」，
    ///      根本想不到是链路已经断了 —— 这就是 2026-09-14 那次投诉的真相。
    private func handleSendFailure(_ e: MWBConnectionError) {
        if Thread.isMainThread {
            handleSendFailureOnMain(e)
        } else {
            DispatchQueue.main.async { [weak self] in self?.handleSendFailureOnMain(e) }
        }
    }

    private func handleSendFailureOnMain(_ e: MWBConnectionError) {
        sendFailStreak += 1
        sendFailLogCount += 1
        // 限流：第 1 次 + 每 200 次。刷屏本身还会占主线程做文件写入。
        if sendFailLogCount == 1 || sendFailLogCount % 200 == 0 {
            log("[MWB] ⚠️ 发送失败(累计 \(sendFailLogCount) 次, 连续 \(sendFailStreak) 次): \(e)")
        }
        guard sendFailStreak >= 3 else { return }
        handleLinkDead("链路已断开（连续 \(sendFailStreak) 次发送失败）")
    }

    /// 判定链路死亡并降级。两个入口：写失败（连续 3 次）与读侧 EOF（接收循环退出）。
    ///
    /// 必须做的事：① 立刻把控制权交回本机（否则输入被吞、光标锁在边缘，
    /// 用户会以为"鼠标卡在 Windows 里"）；② 按退避自动重连。
    private func handleLinkDead(_ reason: String) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.handleLinkDead(reason) }
            return
        }
        guard !linkDead else { return }
        linkDead = true
        // 链路已死：停掉鼠标发送线程，别让它在死 socket 上继续闷头发。
        // （重连成功后 run() 会重新起一条。）
        stopMouseMoveSender()
        log("[MWB] ✗ \(reason) → 立即把控制权交回 Mac，并开始自动重连…")
        input.forceReleaseRemote(reason: reason)
        // 断链时清掉拖放态：否则"陈旧的投放态"会让恢复连接后的第一次左键抬起
        // 被误判成投放收尾，触发一次莫名其妙的文件拉取。
        peerIsDropping = false
        dropWatchdog?.cancel()
        dropWatchdog = nil
        input.finishFileDrop()
        onLinkDown?(reason)
        scheduleReconnect()
    }

    /// 退避重连：0.5s → 1s → 2s → 4s → 8s（封顶）。
    /// 重连本身是阻塞 I/O（最长连超时 5s + 握手 8s），必须丢到后台线程，
    /// 否则会把主线程的事件处理和 UI 一起卡住。
    private func scheduleReconnect() {
        guard !reconnectScheduled else { return }
        reconnectScheduled = true
        reconnectAttempts += 1
        let delay = min(0.5 * pow(2.0, Double(min(reconnectAttempts - 1, 4))), 8.0)
        log("[MWB] [重连] 第 \(reconnectAttempts) 次尝试将在 \(String(format: "%.1f", delay))s 后开始")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            guard self.linkDead else { self.reconnectScheduled = false; return }
            DispatchQueue.global(qos: .userInitiated).async {
                self.armConnectWatchdog(tag: "重连第 \(self.reconnectAttempts) 次")
                let r = self.connection.reconnect()
                self.disarmConnectWatchdog()
                DispatchQueue.main.async {
                    self.reconnectScheduled = false
                    switch r {
                    case .success:
                        self.linkDead = false
                        self.sendFailStreak = 0
                        self.sendFailLogCount = 0
                        self.reconnectAttempts = 0
                        self.announceHello()
                        self.log("[MWB] [重连] ✓ 链路已恢复，键鼠可以继续跨屏")
                        self.onLinkUp?()
                    case .failure(let e):
                        self.log("[MWB] [重连] ✗ 失败: \(e)")
                        self.scheduleReconnect()
                    }
                }
            }
        }
    }

    // MARK: - 链路看门狗状态

    /// 连续发送失败次数（任何一次成功即清零）。
    /// `write()` 在阻塞 socket 上返回 ≤0，只可能是对端已关闭 / RST / 写超时，
    /// 都不是能自愈的瞬时错误 —— 所以连续几次就足以判定链路已死。
    private var sendFailStreak = 0
    /// 发送失败日志条数（用于限流：只打第 1 次和每 200 次）。
    private var sendFailLogCount = 0
    /// 链路是否已被判定为断开（断开期间不再转发输入，等重连）。
    private var linkDead = false

    // MARK: - 连接阶段看门狗（2026-09-14 新增）

    /// 本次连接是否已经完成握手。
    private var didHandshake = false
    private var connectWatchdog: DispatchSourceTimer?

    /// 起一个一次性看门狗：`15s` 内没完成握手就**强制断开**，让上层走重连。
    ///
    /// 【为什么必须有】对端把 TCP 接下来却"不回嘴"时（Windows 的 MWB 主线程卡住、
    /// 或它那边遗留了半开会话），我们会**永久卡**在读预热块的阻塞 read 上。
    /// 原因是 `Connection.setRecvTimeout` 用的是 `SO_RCVTIMEO` —— 它**对 NSInputStream 不生效**
    /// （NSStream 走的是自己的同步读路径），所以握手那 8s 超时形同虚设。
    /// 实测（2026-09-14）：对端静默时进程无限期挂住，UI 永远停在「连接中…」，
    /// **既不报错也不重连**，看起来像软件死了。
    ///
    /// 对策：超时就调 `connection.close()` —— 它内部先做 `shutdown(SHUT_RDWR)`，
    /// 会**立刻唤醒**阻塞中的 read，让 `connect()` 正常返回失败；
    /// 再走 `handleLinkDead` 既有的退避重连，链路就能自愈。
    private func armConnectWatchdog(tag: String) {
        connectWatchdog?.cancel()
        didHandshake = false
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + 15)
        t.setEventHandler { [weak self] in
            guard let self, !self.didHandshake else { return }
            self.log("[MWB] ✗ 连接阶段超时（15s 内未完成握手，\(tag)）——"
                     + "对端接受了 TCP 却不响应握手；已强制断开并准备重连。"
                     + "若反复出现，请在 **Windows 上重启 Mouse Without Borders**。")
            self.connection.close()
            self.handleLinkDead("连接阶段超时（对端未响应握手）")
        }
        t.resume()
        connectWatchdog = t
    }

    /// 握手完成，撤掉看门狗。
    private func disarmConnectWatchdog() {
        didHandshake = true
        connectWatchdog?.cancel()
        connectWatchdog = nil
    }
    /// 是否已排了一次重连（避免重复排队）。
    private var reconnectScheduled = false
    private var reconnectAttempts = 0

    /// 链路断开 / 恢复回调（GUI 用来更新状态与提示）。
    public var onLinkDown: ((String) -> Void)?
    public var onLinkUp: (() -> Void)?

    private var heartbeatSource: DispatchSourceTimer?
    private var listener: MWBListener?
    private let host: String
    private let port: UInt16
    private let securityKey: String

    public init(host: String, port: UInt16, securityKey: String, machineName: String, myID: UInt32 = 2) {
        self.host = host
        self.port = port
        self.securityKey = securityKey
        self.connection = MWBConnection(host: host, port: port, securityKey: securityKey,
                                       machineName: machineName, myID: myID)
    }

    /// 启动客户端。成功返回后，连接与接收循环已在后台运行。
    public func run() -> Result<Void, MWBConnectionError> {
        // 握手 + 注册已在此完成
        connection.onLog = { [weak self] s in self?.log("[MWB] \(s)") }

        // 同一进程内所有连接共用一个机器 ID。
        // MWB 协议里这个 ID 就是**矩阵槽位序号(1..4)**；用户显式指定就用它，
        // 否则退回随机 ID（历史行为，对端靠名字把我们对上槽位）。
        let mid: UInt32 = preferredSlot ?? UInt32.random(in: 1...UInt32.max - 1)
        connection.myID = mid

        // 机器矩阵观察器：把自己登记进去，并把对端下发的布局变化转成日志
        matrix.setSelfName(connection.machineName)
        matrix.setConfiguredSelfSlot(preferredSlot.map { Int($0) })
        matrix.onChange = { [weak self] in
            guard let self else { return }
            if let s = self.matrix.takeLog() { self.log(s) }
            self.onMatrixChanged?()
        }

        // MWB 是网状互联：Windows 会反向连回来，必须先起监听器，
        // 否则 Windows 侧不会把本机加入机器矩阵（连上后立刻沉默、UI 里看不到本机）。
        startReturnListener(machineID: mid)

        // ★ 起看门狗再连：对端静默时不能无限期挂住（见 armConnectWatchdog 说明）。
        armConnectWatchdog(tag: "首次连接 \(host):\(port)")
        let r = connection.connect()
        guard case .success = r else {
            disarmConnectWatchdog()
            log("[MWB] 连接/握手失败: \(r)")
            return r
        }
        disarmConnectWatchdog()
        log("[MWB] 握手阶段结束，进入运行态")

        connection.onPacket = { [weak self] p in self?.handle(p) }
        // 读侧断开信号：**比等写失败快得多**（心跳 4s 一颗，而写失败要等下一次发送）。
        // 收到就立刻走同一条降级路径：交回控制权 + 自动重连。
        connection.onDisconnected = { [weak self] reason in
            self?.handleLinkDead(reason)
        }

        // 主动广播 Hello，让对端把我们加进机器池
        announceHello()

        // 心跳保活：周期性广播 HeartbeatEx 维持机器矩阵（Windows 也会发心跳，我们回显）
        startHeartbeat()

        // 剪贴板同步（走 MWB 原生协议：文本 = UTF-16LE + 裸 DEFLATE + 48 字节分片；
        // 图片 = PNG 原始字节 + 48 字节分片；超过 1MB 改发 Clipboard(69) 心跳让对端来拉）
        clipboard.onLog = { [weak self] s in self?.log("[MWB] \(s)") }
        clipboard.onLocalText = { [weak self] text in
            self?.sendClipboardText(text)
        }
        clipboard.onLocalImage = { [weak self] png in
            self?.sendClipboardImage(png)
        }
        clipboard.startMonitoring()

        // 捕获本地输入 -> 转发给 Windows
        // 关键：只有光标顶到屏幕边缘、控制权交给 Windows 之后才转发，
        // 否则 Windows 光标会变成本机鼠标的"影子"，一动就同步跟着动。
        input.onDiagnostic = { [weak self] s in self?.log(s) }
        configureInput()
        // 捕获到本地输入 -> 转发给 Windows
        // 关键：只有光标顶到屏幕边缘、控制权交给 Windows 之后才转发，
        // 否则 Windows 光标会变成本机鼠标的"影子"，一动就同步跟着动。
        input.onCaptured = { [weak self] p in
            guard let self else { return }
            self.lastSentInputAt = Date()
            var packet = p
            packet.des = 0xFF
            if self.verbose {
                let detail = packet.type == .mouse
                    ? "flags=0x\(String(format: "%x", packet.mouseFlags)) x=\(packet.mouseX) y=\(packet.mouseY)"
                    : "vk=0x\(String(format: "%x", packet.keyVk)) flags=\(packet.keyFlags)"
                self.log("[MWB] → \(packet.type) \(detail)")
            }
            // ★ 鼠标**移动**包走信箱（异步、只留最新一帧），**绝不在这里同步写 socket**。
            //
            // 【为什么必须分开】这个闭包是在 **CGEventTap 回调线程**上跑的（移动包直接来自
            //  `handleMouseMoved`），也在**主线程**上跑（5ms 补发定时器）。而 `connection.send`
            //  最终是 `CFWriteStreamWrite` —— 阻塞写，写超时 2s。放在这里意味着：
            //    · 链路一抖（本机 WiFi 实测每 500ms 一次 60~85ms 尖峰），tap 回调就被同步写卡住，
            //      系统在等我们返回 → **整个输入流一起停顿**（"跨屏一顿一顿、不跟手"的根因之一）；
            //    · 主线程被卡住时，连"补发最后一帧"的定时器、面板刷新都会一起停。
            //  移动包的位置是幂等的，合并掉过期帧没有任何副作用；点击/滚轮/按键包则照旧
            //  同步发出（它们必须保序、不能丢，而且速率是人的手速，不构成压力）。
            if self.mouseAsyncSend,
               packet.type == .mouse, packet.mouseFlags == InputController.mouseMoveFlag {
                // 只有"空 → 非空"这一次要唤醒发送线程：信箱非空时它本来就会一直取。
                if !self.mouseMailbox.submit(packet) { self.mouseMailboxSignal.signal() }
                return
            }
            // 发送失败：交给看门狗统一处理（限流打日志；连续失败则判定链路死亡、
            // 交回控制权并自动重连）。成功后清零连续失败计数。
            if case .failure(let e) = self.connection.send(packet) {
                self.handleSendFailure(e)
            } else {
                self.sendFailStreak = 0
            }
        }
        input.onCaptureStatus = { [weak self] ok, msg in
            self?.log("[MWB] \(msg)")
            self?.captureOK = ok
            self?.onCaptureStatus?(ok, msg)
        }
        input.startCapture()

        // 一次性的捕获健康度自检：tap 建好了不等于真的能收到事件。
        reportCaptureHealth()

        // 「输入监控」授权自愈：授权后对已运行进程未必即时生效，周期检查并自动重建捕获。
        startPermissionWatch()

        // 跨屏文件传输（自建通道 + 边缘投放带 + 剪贴板文件同步）
        configureFileTransfer()

        // 开始接收循环
        connection.startReceiveLoop()

        // 鼠标移动包改由**独立线程**异步发送（信箱只留最新一帧）——
        // 必须在 run() 末尾起：此时连接、密钥、socket 都已就绪。
        startMouseMoveSender()
        return .success(())
    }

    // MARK: - 跨屏文件传输

    private func configureFileTransfer() {
        let env = ProcessInfo.processInfo.environment
        if let h = fileHostOverride ?? env["MWB_FILE_HOST"] { fileTransfer.host = h }
        else { fileTransfer.host = host }

        // MWB 端口约定（PowerToys SocketStuff.cs）：
        //     skMessageServer   = new TcpServer(TcpPort + 1, …)   ← 主通道（键鼠/握手）15101
        //     skClipboardServer = new TcpServer(TcpPort,     …)   ← 剪贴板/文件通道      15100
        // 所以我们连的主通道端口 -1 就是剪贴板端口。
        let clipPort = filePortOverride
            ?? (UInt16(env["MWB_FILE_PORT"] ?? "") ?? (port > 1 ? port - 1 : 15100))
        fileTransfer.port = clipPort
        fileTransfer.securityKey = securityKey
        fileTransfer.onLog = { [weak self] s in self?.log(s) }

        // ---- MWB 原生剪贴板通道 ----
        // 复用主通道的机器 ID 与自校准过的魔数：Windows 的 ShakeHand 会校验
        // `ResolveID(MachineName) == package.Src`，用错 ID 会被直接拒绝。
        let ch = MWBClipboardChannel(port: clipPort,
                                     securityKey: securityKey,
                                     machineName: connection.machineName,
                                     myID: connection.myID)
        ch.magic = connection.learnedMagic
        ch.onLog = { [weak self] s in self?.log(s) }
        ch.onPayloadReceived = { [weak self] payload in
            guard let self else { return }
            // 三种载荷分流：文件 → 原有收尾（Finder 定位）；图片/文本 → 交给 ClipboardSync 写板。
            // ★ 文本载荷（*text）走的是 15100 通道，是与主通道分片**完全等价**的另一种封装，
            //   所以这里必须复用同一个解压/拆包函数，不能另写一套。
            switch payload {
            case .file(let url):
                self.handleReceivedFile(url)
            case .image(let png):
                _ = self.clipboard.acceptRemoteImage(png)
            case .textWire(let bytes):
                _ = self.clipboard.acceptRemoteWireText(bytes)
            }
        }
        fileTransfer.channel = ch
        fileTransfer.signalDragDrop = { [weak self] url in self?.signalDragDropToPeer(url) }
        clipboardChannel = ch
        // Windows 要主动来拉文件/大剪贴板，所以必须监听。
        // ★ 现在**无条件开**：除了拖放与 Cmd+C 复制文件，还多了一条「大剪贴板图片/文本」的
        //   拉取通道 —— 只要对方发过 Clipboard(69) 心跳，它就会回连我们的 15100。
        ch.startListener()

        // 边缘投放带（AppKit 必须在主线程初始化）
        if dropDockEnabled {
            dropPanel.edge = input.switchEdge
            dropPanel.onLog = { [weak self] s in self?.log(s) }
            dropPanel.onFiles = { [weak self] urls in self?.sendFiles(urls) }
            DispatchQueue.main.async { [weak self] in self?.dropPanel.start() }
        }

        // 端到端自测钩子：MWB_FILEDROP_SELFTEST=<文件路径>
        // 走的是**和真实拖放完全相同**的生产路径：
        //   sendFiles → FileTransfer.send（必要时打包）→ signalDragDropToPeer
        //   → 主通道发 ClipboardDragDrop(70)+ClipboardDragDropOperation(75) → 补发远端鼠标抬起
        //   → 对端 Step10 GetRemoteClipboard → 连回本机 15100 拉文件。
        // 有了它，不必用鼠标拖也能验证整条原生通道（否则只能靠人肉拖拽）。
        if let p = env["MWB_FILEDROP_SELFTEST"], !p.isEmpty {
            let url = URL(fileURLWithPath: p)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard let self else { return }
                self.log("[MWB] [自测] MWB_FILEDROP_SELFTEST：按真实拖放路径投放 "
                         + "\(url.lastPathComponent)（对端应回连本机 15100 拉取）")
                self.sendFiles([url])
            }
        }

        // 光标锁定回归自检钩子：MWB_LOCK_SELFTEST=<秒数>（不给秒数默认 8）。
        //
        // 【为什么需要】光标锁定 2026-09-14 一天内回归了两次（hide 降到 2Hz、
        // 后台进程 hide 不生效），而验证它必须真把鼠标推到边缘持续晃动 ——
        // 人肉重复第三次必然偷懒，"改坏了没人发现"就会复发。
        // 这个钩子强制进入控制态若干秒，日志里的 `可见性=已隐藏` 就是客观判据。
        // 锚点取当前光标位置，不会把光标甩到角落；到点自动恢复。
        //
        // 用法（注意别用 launchctl setenv —— 非特权上下文会报
        // "Not privileged to set domain environment"）：
        //   pkill -x MWBMacClientApp
        //   MWB_LOCK_SELFTEST=8 /Applications/MWB.app/Contents/MacOS/MWBMacClientApp
        //   /tmp/cursorwatch 14          # 进程外的只读判据，两侧都对上才算过
        //
        // 【⚠️ 不要用 `open --env`】2026-09-16 实测：本机 macOS 15.2 上
        // `open --env K=V /Applications/MWB.app`（选项放前面、放后面都试过）
        // **环境变量传不进被测进程**，钩子静默不触发 —— 会让你误判"自检通过"。
        // 必须像上面那样直接跑 bundle 里的可执行文件（shell 直接继承 env）。
        // 代价：这样起的实例归调用方 shell 管，命令一结束就被回收，
        // 所以只适合自检；自检完用 `open /Applications/MWB.app` 起回正常实例。
        if let s = env["MWB_LOCK_SELFTEST"] {
            let secs = Double(s) ?? 8.0
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.input.runLockSelfTest(seconds: secs)
            }
        }

        // 捕获线程泄漏（CPU 100%）回归自检钩子：MWB_CAPTURE_REBUILD_SELFTEST=<秒数>（默认 5）。
        //
        // 【为什么需要】2026-09-16 定位到一个「MWB 常量占满一个 CPU 核」的 bug：
        // 捕获线程原来用共享 Bool 做取消标志，stopCapture() 置 true 后
        // startCapture() 立刻置回 false，旧线程读到时已是 false → **永不退出**；
        // 且它的 tap 已被 invalidate、runloop 里没有源，CFRunLoopRunInMode 因 mode 为空
        // **立即返回**（不阻塞）→ while 变成纯空转。
        // 触发条件是「同一进程内 startCapture 被调用第二次」，而这只在**断线重连**时发生，
        // 人肉很难稳定复现（当时是一次 11:10 的重连后残留了 3 小时）。
        // 这个钩子直接重放该路径：stopCapture → startCapture。
        //
        // 判据（两条都要）：
        //   ① 日志出现 `输入捕获线程 #N 已退出（被新一代取代）` —— 旧线程真的退了；
        //   ② 后面的 `活着的捕获线程=1`（不是 2）。
        // 外部再用 `sample <pid> 3` 复核：应只有一个 MWBCapture 线程且停在 mach_msg。
        //
        // 用法（**不能用 `open --env`，实测传不进去**，见上面 MWB_LOCK_SELFTEST 的说明）：
        //   pkill -x MWBMacClientApp
        //   MWB_CAPTURE_REBUILD_SELFTEST=3 /Applications/MWB.app/Contents/MacOS/MWBMacClientApp
        //
        // 2026-09-16 实测结论（修复后）：
        //   [自测] 重建前 活着的捕获线程=1
        //   输入捕获线程 #2 已退出（被新一代取代） 当前活着的捕获线程=0   ← 同一毫秒退出
        //   [自测] 重建后 活着的捕获线程=1 —— ✅ 通过（旧线程已退出，无泄漏）
        // 修复前同一路径会留下 2 个线程，其中一个空转吃满一个核（见 liveCaptureThreadCount 注释）。
        if let s = env["MWB_CAPTURE_REBUILD_SELFTEST"] {
            let delay = Double(s) ?? 5.0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                self.log("[MWB] [自测] MWB_CAPTURE_REBUILD_SELFTEST：模拟重连重建事件捕获"
                         + "（stopCapture → startCapture）"
                         + " 重建前 活着的捕获线程=\(self.input.liveCaptureThreadCount)")
                self.input.stopCapture()
                self.input.startCapture()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                    guard let self else { return }
                    let n = self.input.liveCaptureThreadCount
                    self.log("[MWB] [自测] 重建后 活着的捕获线程=\(n) —— "
                             + (n == 1 ? "✅ 通过（旧线程已退出，无泄漏）"
                                       : "❌ 失败（\(n) 个线程存活，会吃满 CPU）"))
                }
            }
        }

        // Finder 里 Cmd+C 复制文件 -> 自动同步到 Windows
        if clipboardFileEnabled && env["MWB_NOCLIPFILE"] == nil {
            // 先对齐当前 changeCount，否则启动瞬间会把剪贴板里已有的文件误发一次
            DispatchQueue.main.async { [weak self] in
                self?.lastClipChangeCount = NSPasteboard.general.changeCount
            }
            startClipboardFileWatch()
        }

        log("[MWB] 文件传输: MWB 原生剪贴板通道 \(fileTransfer.host):\(clipPort)"
            + "（主通道 \(port)。Windows 端无需额外程序，走它自己的拖放实现）"
            + (dropDockEnabled ? "  投放带=开(\(input.switchEdge)边缘)" : "  投放带=关")
            + (clipboardFileEnabled ? "  复制即传=开" : "  复制即传=关"))
    }

    /// 发出 MWB **原生**拖放信令，让 Windows 进入「可接收」状态并主动来拉文件。
    ///
    /// 严格照 PowerToys `Core/DragDrop.cs` 的时序（我们扮演 DragDropStep06 那台机器）：
    ///   ① `SendClipboardBeatDragDrop()` → 广播 `ClipboardDragDrop(70)`：
    ///      对端 `DragDropStep08` → `GetNameOfMachineWithClipboardData()`，
    ///      记下「哪台机器手里有拖拽文件」。Src 必须是本机 ID（对端按 ID 反查机器名）。
    ///   ② `SendDropBegin()` → 定向 `ClipboardDragDropOperation(75)`：
    ///      对端 `DragDropStep08_2` 要求 `Des == 自己的 MachineID`，据此置 IsDropping 并弹投放图标。
    ///   ③ 对端 `DragDropStep09(WM_LBUTTONUP)` → `DragDropStep10()`
    ///      → `Clipboard.GetRemoteClipboard("desktop")` → 连回本机 15100 拉文件。
    ///      而 Step09 挂在鼠标钩子上、只对「远端注入」的事件生效 ——
    ///      我们把文件丢在本机边缘时对端等不到这次抬起，必须由我们补发（③）。
    private func signalDragDropToPeer(_ file: URL) {
        guard let ch = clipboardChannel else {
            log("[MWB] [文件] ✗ 剪贴板通道未就绪，无法发出拖放信令")
            return
        }
        ch.stagedFile = file

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let myID = self.connection.myID
            let name = self.connection.machineName

            // ① 广播「本机有拖拽文件」
            var beat = DataPacket(type: .clipboardDragDrop, src: myID, des: 0xFF)
            beat.machineName = name
            if case .failure(let e) = self.connection.send(beat) {
                self.log("[MWB] [文件] ✗ 拖放广播发送失败: \(e)")
                return
            }

            // ② 定向让接收方进入投放态
            let target = self.peerID
            if target == 0 || target == 0xFF {
                self.log("[MWB] [文件] ⚠️ 还没学到对端机器 ID，投放信令改为广播 ——"
                         + " 若对端没反应，通常是它从未发过心跳过来")
            }
            var op = DataPacket(type: .clipboardDragDropOp, src: myID,
                                des: (target == 0 || target == 0xFF) ? 0xFF : target)
            op.machineName = name
            if case .failure(let e) = self.connection.send(op) {
                self.log("[MWB] [文件] ✗ 投放信令发送失败: \(e)")
                return
            }

            // ③ 补一次「远端鼠标抬起」—— 这是触发对端 GetRemoteClipboard("desktop") 的唯一开关。
            //    包序由同一条 TCP 保证，这里只留一点余量让对端先处理完信令再看到抬起。
            Thread.sleep(forTimeInterval: 0.12)
            self.input.sendSyntheticMouseUp()

            self.log("[MWB] [文件] 已发出 MWB 原生拖放信令（PostAction=desktop）"
                     + " → 等待对端拉取 \(file.lastPathComponent)")
        }
    }

    /// 反向：对端（Windows）在它那边松手投放后，我们去它的剪贴板通道把文件拉回来。
    /// 对应 PowerToys 的 `DragDropStep10` → `Clipboard.GetRemoteClipboard("desktop")`，
    /// 只是方向相反（它当数据持有方，我们当请求方）。
    private func fetchFileFromPeer() {
        guard let ch = clipboardChannel else { return }
        log("[MWB] [文件] 松手投放 → 主动拉取…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            switch ch.fetchFile(from: self.host) {
            case .success(let url):
                self.handleReceivedFile(url)
            case .failure(let e):
                self.log("[MWB] [文件] ✗ 拉取失败: \(e.localizedDescription)")
            }
            self.notifyPeerDragFinished()
        }
    }

    /// 收到文件后的**统一收尾**：日志 + 把 Finder 拉到该文件上（打开所在文件夹并选中它）。
    ///
    /// ★ 两条接收路径都必须走这里：
    ///   ① 对端主动连入推送（`ClipboardChannel.onFileReceived` → `handleInbound`）
    ///   ② **我们主动去拉取**（`fetchFileFromPeer` → `fetchFile`）—— Windows→Mac 拖放走的是这条。
    ///
    /// 以前只有 ① 调了 Finder，② 只写日志，于是用户从 Windows 拖文件过来之后
    /// **屏幕上毫无反馈**，根本不知道文件落在哪（2026-09-14 用户报的第 2 条）。
    ///
    /// 与 PowerToys 的 desktop 分支对齐：它那边也是「落到 桌面\MouseWithoutBorders\ 并打开该文件夹」。
    /// 这里用 `activateFileViewerSelecting` —— 既打开了文件夹，又选中了刚到的文件，一眼可见落点。
    /// 必须在主线程调用。若觉得抢焦点烦，删掉这段即可，落点不受影响。
    private func handleReceivedFile(_ url: URL) {
        log("[MWB] [文件] ✓ 已收到 \(url.lastPathComponent) → \(url.path)")
        let dir = url.deletingLastPathComponent()
        DispatchQueue.main.async {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        // ★ 0.4s 后回检：Finder 到底有没有真的到前台？
        //
        // 为什么要回检：`activateFileViewerSelecting` 在**非活跃应用**里调用时，
        // macOS 的抢焦点保护可能只开窗、不把 Finder 带到前面 —— 用户看到的就是
        // 「拖过来了但屏幕上什么都没发生」（2026-09-14 用户报的第 2 条）。
        // 这里既留下了**可验证**的日志，又准备了兜底（直接 open 目录）。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            if front == "com.apple.finder" {
                self.log("[MWB] [文件] 已打开所在文件夹并在 Finder 中选中该文件 ✓")
            } else {
                self.log("[MWB] [文件] Finder 未到前台（当前前台=\(front ?? "?")），改为直接打开目录兜底")
                NSWorkspace.shared.open(dir)
            }
        }
    }

    /// 告诉 Windows「这次拖拽收尾了」：补发一个鼠标抬起包。
    ///
    /// 【为什么必须补】物理鼠标在 Mac 上。拖放一开始我们就把控制权交回了本机，
    /// 并且**故意没有**补发抬起（补发了 Windows 会以为拖拽被取消、清掉待传文件）。
    /// 文件拿到之后必须把最后这一拍补上，否则 Windows 侧会一直以为左键还按着 ——
    /// 那边表现为点击/拖拽行为错乱（点一下变成拖拽）。
    private func notifyPeerDragFinished() {
        input.sendSyntheticMouseUp()
        log("[MWB] [文件] 已通知对端拖拽结束（补发抬起包）")
    }

    /// 轮询系统剪贴板，检测到「文件」被复制（Finder Cmd+C）就推送到 Windows。
    private func startClipboardFileWatch() {
        DispatchQueue.global(qos: .background).async { [weak self] in
            while true {
                Thread.sleep(forTimeInterval: 0.8)
                self?.checkClipboardFiles()
            }
        }
    }

    private func checkClipboardFiles() {
        let pb = NSPasteboard.general
        let cc = pb.changeCount
        guard cc != lastClipChangeCount else { return }
        lastClipChangeCount = cc

        guard let objs = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] else { return }
        let paths = objs.map { $0.path }
        guard !paths.isEmpty, paths != lastClipFiles else { return }
        lastClipFiles = paths

        let names = paths.prefix(3).map { URL(fileURLWithPath: $0).lastPathComponent }
            + (paths.count > 3 ? ["…共\(paths.count)个"] : [])
        log("[MWB] [文件] 检测到复制: \(names.joined(separator: ", "))")
        sendFiles(objs)
    }

    private func sendFiles(_ urls: [URL]) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            switch self.fileTransfer.send(fileURLs: urls) {
            case .success(let msg):
                self.log("[MWB] [文件] ✓ \(msg)")
            case .failure(let e):
                self.log("[MWB] [文件] ✗ \(e.localizedDescription)")
            }
        }
    }

    // MARK: - 剪贴板同步

    /// 把一段文本按 MWB 协议推给 Windows：
    /// 文本 -> UTF-16LE -> 裸 DEFLATE -> 48 字节/片 -> 每片一个 64 字节 ClipboardText(124) 包
    /// -> 最后一个 ClipboardDataEnd(76) 空包收尾（接收端到它才整体解压）。
    private func sendClipboardText(_ text: String) {
        guard let wire = clipboard.encodeForWire(text) else { return }
        // >1MB（压缩后）别走 48 字节/片的直推：20 万个小包既慢又容易堵住链路。
        // 对齐 PowerToys：改发心跳 Clipboard(69)，数据留在通道里等对端回连 15100 拉（一次 64KB）。
        if wire.count > ClipboardSync.instantLimit {
            clipboardChannel?.pendingClipboardPayload = .textWire(wire)
            announceBigClipboard(reason: "文本压缩后 \(fmtBytes(Int64(wire.count))) 超过 1MB 即时推送阈值")
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let chunk = 48
            var index = 0
            var sent = 0
            while index < wire.count {
                let len = min(chunk, wire.count - index)
                var buf = [UInt8](repeating: 0, count: chunk)   // 末片补 0，与 PowerToys 一致
                for i in 0..<len { buf[i] = wire[index + i] }

                var p = DataPacket(type: .clipboardText, src: self.connection.myID, des: 0xFF)
                p.raw48 = buf
                if case .failure(let e) = self.connection.send(p) {
                    self.handleSendFailure(e)
                    return
                }
                index += chunk
                sent += 1
            }
            let end = DataPacket(type: .clipboardDataEnd, src: self.connection.myID, des: 0xFF)
            if case .failure(let e) = self.connection.send(end) {
                self.handleSendFailure(e)
                return
            }
            self.log("[MWB] [剪贴板] → 已发送 \(sent) 个分片（\(wire.count) 字节压缩数据）")
        }
    }

    /// 把一张图片按 MWB 协议推给 Windows。
    ///
    /// 【协议事实】图片载荷是 **PNG 原始字节，不做任何压缩/编码**
    /// （PowerToys `FormHelper.cs`: `im.Save(ms, ImageFormat.Png)`），
    /// 对端用 `Image.FromStream` 直接读 —— 所以必须是 PNG/JPEG 这类自带格式的图片流。
    ///
    /// 两条路（对齐 PowerToys `CheckClipboardEx` 的 1MB 阈值）：
    ///   ≤ 1MB：48 字节/片 → 每片一个 ClipboardImage(125) 包 → ClipboardDataEnd(76) 收尾；
    ///   > 1MB：48 字节一小包的效率太低（3MB 图 = 6 万多个包），改发 Clipboard(69) 心跳包，
    ///          PNG 留在 `clipboardChannel.pendingClipboardPayload`，等对端回连 15100 拉走
    ///          （那边一次 64KB，快两个数量级）。
    private func sendClipboardImage(_ png: Data) {
        guard png.count <= ClipboardSync.imageLimit else {
            log("[MWB] [剪贴板] ⚠️ 图片过大（\(fmtBytes(Int64(png.count))) > 50MB），已跳过"
                + "（对齐 PowerToys FormHelper.MAX_IMAGE_SIZE）")
            return
        }
        if png.count > ClipboardSync.instantLimit {
            clipboardChannel?.pendingClipboardPayload = .image(png)
            announceBigClipboard(reason: "图片 \(fmtBytes(Int64(png.count))) 超过 1MB 即时推送阈值")
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let chunks = ClipboardSync.chunk([UInt8](png))
            var sent = 0
            for c in chunks {
                var p = DataPacket(type: .clipboardImage, src: self.connection.myID, des: 0xFF)
                p.raw48 = c
                if case .failure(let e) = self.connection.send(p) {
                    self.handleSendFailure(e)
                    return
                }
                sent += 1
            }
            let end = DataPacket(type: .clipboardDataEnd, src: self.connection.myID, des: 0xFF)
            if case .failure(let e) = self.connection.send(end) {
                self.handleSendFailure(e)
                return
            }
            self.log("[MWB] [剪贴板] → 已发送图片 \(sent) 个分片（PNG \(fmtBytes(Int64(png.count)))）")
        }
    }

    /// 广播 `Clipboard(69)` 心跳包：告诉对端「我剪贴板里有大块数据，你回来拉」。
    ///
    /// 对齐 PowerToys `Common.SendClipboardBeat()`（`SendPackage(ID.ALL, PackageType.Clipboard)`）。
    /// 对端收到后会在切换机器时（Windows 侧 `MachineSwitched` → `GetRemoteClipboard`）
    /// 回连我们的 15100 通道拉数据；拉不进来时会改发 `ClipboardAsk(78)` 让我们反向推。
    private func announceBigClipboard(reason: String) {
        var p = DataPacket(type: .clipboard, src: connection.myID, des: 0xFF)
        p.machineName = connection.machineName
        log("[MWB] [剪贴板] \(reason) —— 改发心跳包 Clipboard(69)，"
            + "等对端回连 \(clipboardChannel?.port ?? 0) 拉取")
        lastBigClipboardBeatAt = Date()
        if case .failure(let e) = connection.send(p) { handleSendFailure(e) }
    }

    /// 对端发来 `Clipboard(69)` 心跳包 → 它剪贴板里有大块数据（>1MB 的图片/文本，
    /// 或它 Cmd+C 复制的文件），我们主动去它的剪贴板通道拉回来。
    ///
    /// 对齐 PowerToys `Clipboard.GetRemoteClipboard`（它那边挂在 `MachineSwitched` 上，
    /// 我们这里**直接拉**：数据早一点到，用户切过去时剪贴板已经就绪）。
    ///
    /// 去重：心跳触发 3 秒内只拉一次（避免对端连续心跳把连接打爆）；
    /// `retry=true`（切机通知带来的一次补拉）只挡 0.5 秒 —— 首次拉取失败时它才有意义。
    private func pullBigClipboardFromPeer(retry: Bool = false) {
        guard let ch = clipboardChannel else { return }
        let now = Date()
        let guardWindow: TimeInterval = retry ? 0.5 : 3
        if let last = lastBigClipboardPullAt, now.timeIntervalSince(last) < guardWindow { return }
        lastBigClipboardPullAt = now
        log("[MWB] [剪贴板] 对端宣布有大块剪贴板数据 → 主动去 \(host):\(ch.port) 拉取…"
            + (retry ? "（切机补拉）" : ""))
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            switch ch.fetchPayload(from: self.host, postAction: .other) {
            case .success(let payload):
                switch payload {
                case .image(let png):      _ = self.clipboard.acceptRemoteImage(png)
                case .textWire(let bytes): _ = self.clipboard.acceptRemoteWireText(bytes)
                case .file(let url):       self.handleReceivedFile(url)
                }
            case .failure(let e):
                self.log("[MWB] [剪贴板] ✗ 拉取大剪贴板失败: \(e.localizedDescription)")
            }
        }
    }

    /// 把控制权交给 Windows 时调用（`input.onSwitchChanged(true)`）。
    ///
    /// ★ 补发 `MachineSwitched(77)` —— 这是 PowerToys 里 **"离开方通知接手方"** 的包，
    ///   Windows 的 `Clipboard.GetRemoteClipboard` 就挂在它上面（`Receiver.cs` 的
    ///   `case PackageType.MachineSwitched`：`Des == 自己` 且 30 秒内收到过心跳 → 去拉）。
    ///
    /// 没有这个包，**>1MB 的载荷永远到不了 Windows**：
    ///   ≤1MB 我们走 48 字节/片直推（`ClipboardImage(125)` / `ClipboardText(124)`），
    ///   >1MB 只能"发心跳 + 等对端来拉"，而对端唯一会来拉的时机就是这个包。
    ///   真实照片基本都 >1MB，所以缺了它 = 大图必丢（这正是"照片过不去"的那一环）。
    ///
    /// 语义上我们是对的：交出控制权的是我们，Windows 是接手方 —— 与 PowerToys 一致。
    public func handedControlToRemote() {
        guard connection.myID != 0 else { return }
        let target = (peerID == 0 || peerID == 0xFF) ? 0xFF : peerID
        var p = DataPacket(type: .machineSwitched, src: connection.myID, des: target)
        p.machineName = connection.machineName
        log("[MWB] [剪贴板] 控制权交给 Windows → 补发 MachineSwitched(77)"
            + (lastBigClipboardBeatAt != nil ? "（本机有刚复制的大载荷，等它回连 15100 拉）" : ""))
        if case .failure(let e) = connection.send(p) { handleSendFailure(e) }
    }

    private func startReturnListener(machineID: UInt32) {
        let lis = MWBListener(port: port, securityKey: securityKey, machineName: connection.machineName)
        lis.onLog = { [weak self] s in self?.log("[MWB] \(s)") }
        lis.onPeerConnected = { [weak self] conn in
            conn.onLog = { [weak self] s in self?.log("[MWB] \(s)") }
            conn.onPacket = { [weak self] p in self?.handle(p) }
            conn.startReceiveLoop()
        }
        if lis.start(sharedMachineID: machineID) {
            listener = lis
        }
    }

    /// Windows 屏幕相对本机的摆放方向 —— 决定从哪条边缘"撞出去"。
    /// 用 MWB_EDGE=left|right|top|bottom 指定，默认 right。
    private func configureInput() {
        let env = ProcessInfo.processInfo.environment
        // 优先级: 显式属性 > 环境变量 > 默认 right
        if let e = preferredEdge {
            input.switchEdge = e
        } else if let raw = env["MWB_EDGE"]?.lowercased(),
                  let e = SwitchEdge(rawValue: raw) {
            input.switchEdge = e
        }
        if let s = preferredRemoteSize {
            input.remoteScreenSize = s
        } else if let w = env["MWB_REMOTE_W"].flatMap(Double.init),
                  let h = env["MWB_REMOTE_H"].flatMap(Double.init) {
            input.remoteScreenSize = CGSize(width: w, height: h)
        }
        // 位移换算方式：显式属性 > 环境变量 > 默认 proportional
        if let m = preferredMotionScale {
            input.motionScale = m
        } else if let raw = env["MWB_MOTION_SCALE"]?.lowercased(),
                  let m = MotionScale(rawValue: raw) {
            input.motionScale = m
        }
        // 控制远端时是否锁定本机光标：显式属性 > 环境变量(MWB_LOCK_CURSOR=0) > 默认开
        if let lk = preferredLockCursor {
            input.lockCursorWhileRemote = lk
        } else if env["MWB_LOCK_CURSOR"] == "0" {
            input.lockCursorWhileRemote = false
        }
        // 每帧重申「光标解耦」：默认开。MWB_ASSOC_PERFRAME=0 可关掉，仅供对照实验。
        // （关掉是 2026-09-14 那次"锁不住"回归的成因，正常使用别动它。）
        if env["MWB_ASSOC_PERFRAME"] == "0" {
            input.assertAssocPerFrame = false
            log("[MWB] ⚠️ 已关闭「每帧重申光标解耦」（MWB_ASSOC_PERFRAME=0）—— 仅用于对照实验，"
                + "正常使用必须保持默认开，否则光标会锁不住")
        }
        log("[MWB] 光标锁定=\(input.lockCursorWhileRemote ? "开（控制 Windows 时本机光标钉在屏幕边缘）" : "关")"
            + " 每帧重申解耦=\(input.assertAssocPerFrame ? "开" : "关")")
        log("[MWB] 切换边缘=\(input.switchEdge)"
             + (input.motionScale == .proportional
                ? " 位移映射=按本机屏幕比例（与对端分辨率无关）"
                : " 位移映射=按对端像素1:1 远端分辨率=\(Int(input.remoteScreenSize.width))x\(Int(input.remoteScreenSize.height))"))
        log("[MWB] 撞到该边缘即接管 Windows；反向推回来或按 Control+Option+Esc 收回本机")

        // ★★ Win → Mac 文件拖放的**收尾触发**：本机左键抬起。
        //
        // 对齐 PowerToys：`DragDropStep09(int wParam)` 挂在鼠标钩子上，判据只有
        // `wParam == WM_LBUTTONUP && IsDropping` → `DragDropStep10()` → 拉取文件；
        // 而 `local`（本机是否负责处理）定义为 `NewDesMachineID == Common.MachineID`，
        // 即**松手发生在"投放目标机"本地**。本机就是那个目标机
        // （`ClipboardDragDropOperation` 点名了我们的 MachineID），物理鼠标也在 Mac 上，
        // 所以这一拍只可能出现在本机 tap 里、**不会**从 Windows 发回来。
        //
        // 旧实现只等"远端鼠标包里的 LBUTTONUP"，永远等不到 —— 这就是
        // 「Windows 拖到 Mac 松手毫无反应」的根因。
        input.onLocalLeftMouseUp = { [weak self] in
            guard let self, self.peerIsDropping else { return }
            self.peerIsDropping = false
            self.dropWatchdog?.cancel()
            self.dropWatchdog = nil
            self.input.finishFileDrop()
            self.log("[MWB] [文件] 本机松手（本地左键抬起）→ 主动拉取…"
                     + "（对齐 DragDropStep09→Step10）")
            self.fetchFileFromPeer()
        }
    }

    /// 投放态看门狗：20s 内没被收尾就取消，避免"陈旧的投放态"把之后的一次普通点击
    /// 误判成拖放收尾（那会弹出一次莫名其妙的文件拉取）。
    private func armDropWatchdog() {
        dropWatchdog?.cancel()
        dropMouseProbe = 0
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + 20)
        t.setEventHandler { [weak self] in
            guard let self, self.peerIsDropping else { return }
            self.peerIsDropping = false
            self.input.finishFileDrop()
            self.log("[MWB] [文件] 投放态 20s 未收尾（对端没发取消、本机也没检测到松手）→ 已复位。"
                     + " 若你确实拖了文件过来却没反应，请把这段日志发给开发者。")
        }
        t.resume()
        dropWatchdog = t
    }

    /// 广播 Hello 把自己登记到对端机器池。连上后立刻发一次，稍后再补一次。
    private func announceHello() {
        let send = { [weak self] in
            guard let self else { return }
            var p = DataPacket(type: .hello, src: self.connection.myID, des: 0xFF)
            p.machineName = self.connection.machineName
            _ = self.connection.send(p)
        }
        send()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.6) { send() }
    }

    private func startHeartbeat() {
        let src = DispatchSource.makeTimerSource(queue: .global(qos: .background))
        src.schedule(deadline: .now() + 4, repeating: 4)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            var p = DataPacket(type: .heartbeatEx, src: self.connection.myID, des: 0xFF)
            p.machineName = self.connection.machineName
            _ = self.connection.send(p)
        }
        src.resume()
        heartbeatSource = src
    }

    private let verbose = ProcessInfo.processInfo.environment["MWB_VERBOSE"] != nil
    /// 最近一次向对端发出控制包的时间，用于判断控制权归属。
    private var lastSentInputAt = Date.distantPast

    /// 捕获健康度自检：tap 创建成功 ≠ 真能收到事件（缺「输入监控」授权时尤其容易静默失效）。
    /// 检查两次（8 秒 / 20 秒），因为用户可能在启动后才开始敲键盘。
    private func reportCaptureHealth() {
        for delay in [8.0, 20.0] {
            DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                let h = self.input.captureHealth()
                if !h.active {
                    self.log("[MWB] ⚠️ 输入捕获未建立 —— 键鼠无法跨屏，请检查辅助功能/输入监控授权")
                } else if h.events == 0 {
                    self.log("[MWB] ℹ️ 尚未收到任何本地输入事件（如果刚启动还没动过鼠标/键盘，可忽略）。"
                        + " 若确实动了却无反应，就是「辅助功能 / 输入监控」授权没落到本 App 上")
                } else if h.keyEvents == 0 {
                    // ⚠️ 这条**不是**故障判据 —— 用户还没敲过键盘时 keyEvents 天然为 0。
                    // 旧文案把它写成"硬判据"，于是每次启动都误报一次，把人骗去翻权限设置。
                    // 真正的判据是"已经敲了键盘却仍然为 0"，那才需要处理。
                    self.log("[MWB] ℹ️ 已收到 \(h.events) 个鼠标事件，键盘事件暂为 0。"
                        + " 若你还没敲过键盘，这条可以忽略；若敲了数字也不涨，"
                        + "才是「输入监控」授权没生效（系统设置 → 隐私与安全性 → 输入监控 → 勾选 MWB，"
                        + "然后完全退出 MWB 再重开）")
                } else {
                    self.log("[MWB] 输入捕获健康 ✓ 鼠标事件 \(h.events) 个 / 键盘事件 \(h.keyEvents) 个")
                }
            }
        }
    }

    /// 「输入监控」是键盘能否跨屏的唯一开关。
    ///
    /// macOS 上鼠标事件走「辅助功能」、键盘事件走「输入监控」，是两套独立授权。
    /// 只授辅助功能时 tap 照样建得起来、鼠标照常到达，但**键盘事件被静默丢弃**
    /// （表现为：鼠标跨得过去、键盘完全没反应）。用户授权后对已运行进程未必即时生效，
    /// 所以这里周期检查：一旦授权生效而键盘事件仍为 0，就自动重建一次事件捕获。
    private var permissionWatchTimer: DispatchSourceTimer?
    private var autoRebuilds = 0
    /// 键盘事件是否曾经到达过。**一旦到过就永久封闭"重建捕获"这条路。**
    private var keyboardEverSeen = false
    /// 全程最多自动重建几次。**必须全局封顶，且不能因为 keyEvents 归零而重置。**
    ///
    /// 【为什么这么严格】「键盘事件 == 0」本身**不是故障证据** ——
    /// 用户没敲键盘时它天然就是 0。旧实现只要看到 0 就重建，于是空闲时每 5 秒
    /// 会把事件 tap 拆掉再建一次（日志里连刷「自动重建事件捕获（第 1/2/3 次）」），
    /// 重建期间的按键会全部丢失 —— **反倒亲手制造出"键盘偶尔失灵"**。
    /// 而 startCapture() 还会顺带重置光标锁定，若正好在跨屏操作中执行会直接打断用户。
    private static let maxAutoRebuilds = 2

    private func startPermissionWatch() {
        // 【为什么第一件事就是判这条】本方法在 `input.startCapture()` **之后**调用 ——
        // 也就是进入这里时，事件 tap 已经**带着当前权限**建好了。
        //
        // 若此刻「输入监控」已授权，那 tap 天生就能收到键盘事件，
        // "授权对已运行进程不即时生效"这个前提压根不成立 → 巡检/重建全是多余动作。
        // 旧实现缺这个判断，于是每次启动都会因为「用户还没敲键盘 → keyEvents == 0」
        // 白白把事件 tap 拆掉重建（顺带 releaseCursor 打断跨屏锁定），
        // 重建窗口内的按键还会全丢 —— 属于自己制造"键盘偶尔失灵"。
        //
        // 只有「启动时未授权」才真的需要巡检：等用户在系统设置里补上授权后自愈。
        if CGPreflightListenEventAccess() {
            log("[MWB] 「输入监控」启动时已授权 → 捕获天生有效，跳过权限巡检（不重建事件捕获）")
            return
        }
        log("[MWB] 「输入监控」启动时未授权 → 进入权限巡检，等待授权生效后自动重建捕获")

        let t = DispatchSource.makeTimerSource(queue: .global(qos: .background))
        // 首次检查给 10s：让用户有机会先敲几下键盘，避免一上来就误判成"授权没生效"。
        t.schedule(deadline: .now() + 10, repeating: 5)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            guard CGPreflightListenEventAccess() else { return }   // 还没授权，等
            let h = self.input.captureHealth()

            // ① 键盘事件真的到了 → 记下并永久收工（不需要再巡检）
            if h.keyEvents > 0 {
                guard !self.keyboardEverSeen else { return }
                self.keyboardEverSeen = true
                self.log("[MWB] 键盘捕获确认可用 ✓（已收到 \(h.keyEvents) 个键盘事件）→ 停止权限巡检")
                self.permissionWatchTimer?.cancel()
                self.permissionWatchTimer = nil
                return
            }
            // ② 已经确认过键盘可用（后续的 0 只是"用户没在敲"）→ 绝不再动它
            guard !self.keyboardEverSeen else { return }
            // ③ 正在控制 Windows 时不能重建：startCapture 会先释放光标锁定，
            //    把正在进行的跨屏操作打断。
            guard !self.input.isControllingRemote else { return }
            guard self.autoRebuilds < Self.maxAutoRebuilds else {
                if self.autoRebuilds == Self.maxAutoRebuilds {
                    self.autoRebuilds += 1        // 只抱怨一次
                    self.log("[MWB] 键盘事件始终没有出现，已停止自动重建捕获（共 \(Self.maxAutoRebuilds) 次）。"
                             + "若键盘确实跨不过去：系统设置 → 隐私与安全性 → 输入监控 → 勾选 MWB，"
                             + "然后**完全退出 MWB 再重新打开**（该授权对已运行进程不即时生效）")
                }
                return
            }
            self.autoRebuilds += 1
            let why = h.active ? "键盘事件始终为 0（「输入监控」授权可能未生效）" : "输入捕获未建立"
            self.log("[MWB] \(why) → 重建事件捕获（第 \(self.autoRebuilds)/\(Self.maxAutoRebuilds) 次）。"
                     + "请在接下来 5 秒内敲几下键盘；键盘一有事件我就停止重建")
            self.input.startCapture()
        }
        t.resume()
        permissionWatchTimer = t
    }

    /// 主动停止：**先向对端道别（ByeBye）**，再关闭链路并释放输入（GUI 断开/退出时调用）。
    ///
    /// ★ 2026-09-14 修：旧实现只做本地清理、**不发 ByeBye**，于是 Windows 侧的 MWB
    ///   一直以为我们还连着（它只能等 TCP 超时/半开检测，而它并不总是能检测到）。
    ///   结果就是：**每次重启 Mac 端之后，Windows 的端口 TCP 可达却不再响应握手**，
    ///   必须跑到 Windows 上重启 Mouse Without Borders 才能恢复。
    ///   实测证据：一次 Mac 端重启后 `netstat` 里留下一堆 FIN_WAIT_1/FIN_WAIT_2，
    ///   对端既不应答握手、也不做 FIN 收尾 —— 典型"以为会话还在"的表现。
    ///   PowerToys 自己在退出时是会 `SendByeBye` 的，我们对齐它。
    public func stop() {
        // ① 先停鼠标发送线程：否则 ByeBye 之后还可能冒出一帧过期位置，
        //    对端会看到一个"已经道别了还在动"的机器。
        stopMouseMoveSender()

        permissionWatchTimer?.cancel()
        permissionWatchTimer = nil
        dropWatchdog?.cancel()
        dropWatchdog = nil
        peerIsDropping = false
        input.finishFileDrop()

        // ① 道别：让对端把我们摘出机器池、释放会话。
        //    链路已经断了（linkDead）时发送没有意义，跳过以免刷错误日志。
        if !linkDead {
            var bye = DataPacket(type: .byeBye, src: connection.myID, des: 0xFF)
            bye.machineName = connection.machineName
            switch connection.send(bye) {
            case .success: log("[MWB] 已向对端发送 ByeBye（礼貌断开，避免对端卡住会话）")
            case .failure(let e): log("[MWB] ByeBye 发送失败（忽略）: \(e)")
            }
        }

        // ② 标记链路已断：抑制 close() 之后由读侧失败触发的 handleLinkDead →
        //    自动重连（用户主动断开时绝不能再自己连回来）。
        linkDead = true
        reconnectScheduled = false

        // ③ 立刻关掉 socket：让对端马上看到 FIN，而不是等它的超时。
        connection.close()
        matrix.markPeersOffline()
        input.releaseCursor()
    }

    // MARK: - 入站包节奏探针（`MWB_LATPROBE=1` 或存在 /tmp/mwb_latprobe 时启用）

    /// 【它回答什么】"卡顿到底是不是网络"这个争论，用 MWB **自己的那条 TCP 加密流**来量。
    ///
    /// Windows 侧会持续发 Hi/心跳包（实测约 10 个/秒，很稳），所以入站包的**到达间隔**
    /// 就是链路抖动的一个天然探针：若间隔里反复冒出 100ms+ 的空洞，说明链路在周期性停顿
    /// （网卡/AP/TCP 重传）；若只有个位数 ms，则链路本身是干净的。
    ///
    /// 比 `ping` 更可信：ping 走 ICMP/UDP 且可能被对端防火墙屏蔽，而这里走的是
    /// **与鼠标包完全相同的那一条 TCP 连接**，还顺带覆盖了 TCP 层的重传/队头阻塞。
    private let inboundProbeOn = ProcessInfo.processInfo.environment["MWB_LATPROBE"] == "1"
        || FileManager.default.fileExists(atPath: "/tmp/mwb_latprobe")
    private var inboundFirstSeen = false
    private var inboundCount = 0
    private var inboundLastAt = Date.distantPast
    private var inboundLastReportAt = Date.distantPast
    private var inboundMaxGapMs = 0.0
    private var inboundGapsOver100 = 0
    private var inboundGapDesc = ""

    private func noteInbound() {
        guard inboundProbeOn else { return }
        let now = Date()
        if !inboundFirstSeen {
            inboundFirstSeen = true
            inboundLastAt = now
            inboundLastReportAt = now
            return
        }
        inboundCount += 1
        let gap = now.timeIntervalSince(inboundLastAt)
        inboundLastAt = now
        if gap * 1000 > inboundMaxGapMs {
            inboundMaxGapMs = gap * 1000
            if gap > 0.1 { inboundGapDesc = String(format: "%.0fms", gap * 1000) }
        }
        if gap > 0.1 { inboundGapsOver100 += 1 }

        let span = now.timeIntervalSince(inboundLastReportAt)
        guard span >= 3 else { return }
        log("【链路探针】\(Int(span))s内 收到 \(inboundCount) 包"
            + " 最大到达间隔=\(Int(inboundMaxGapMs))ms(>100ms:\(inboundGapsOver100)次)"
            + (inboundGapDesc.isEmpty ? "" : " 最大空洞=\(inboundGapDesc)"))
        inboundCount = 0
        inboundMaxGapMs = 0
        inboundGapsOver100 = 0
        inboundGapDesc = ""
        inboundLastReportAt = now
    }

    private func handle(_ p: DataPacket) {
        noteInbound()      // 链路探针：用 MWB 自己的 TCP 流的到达节奏量链路抖动
        if verbose {
            log("[MWB] ← type=\(p.type) id=\(p.id) src=\(p.src) des=\(p.des) name='\(p.machineName)'")
        }
        // 对端发来的每个包都带着它的机器 ID，顺手记下来。
        // 文件拖放要用它当定向包的目标：PowerToys 的 DragDropStep08_2 要求
        // `package.Des == 自己的 MachineID` 才认，用 0xFF 广播是无效的。
        if p.src != 0, p.src != 0xFF, p.src != connection.myID {
            if peerID != p.src {
                peerID = p.src
                log("[MWB] 学到对端 MachineID = 0x\(String(p.src, radix: 16)) (\(p.src))，来自 \(p.type)")
            }
        }
        switch p.type.rawValue {
        case PackageType.hi.rawValue:
            // 对端询问 -> 回应 Hello，把自己加入对端机器池
            var r = DataPacket(type: .hello, src: connection.myID, des: p.src)
            r.machineName = connection.machineName
            _ = connection.send(r)
            if !p.machineName.isEmpty { peerName = p.machineName }
            matrix.noteSeen(src: p.src, name: p.machineName)
            // 日志限流：Windows 在拖放/切换投放目标时会连发这个包（实测 1 秒十几个）。
            // 原样刷屏不只是难看 —— 面板日志刷新跑在主线程，而光标锁定的 30Hz 定时器
            // 也在主队列上，刷屏会拖慢锁定重申（"锁不住"的一个次生成因）。
            hiLogCount += 1
            if Date().timeIntervalSince(lastHiLogAt) > 5 {
                let extra = hiLogCount > 1 ? "（近 5s 内共 \(hiLogCount) 次，已折叠）" : ""
                lastHiLogAt = Date()
                hiLogCount = 0
                log("[MWB] 收到 Hi, 已回应 Hello"
                    + " (对端=\(p.machineName.isEmpty ? peerName : p.machineName))\(extra)")
            }

        case PackageType.heartbeat.rawValue, PackageType.heartbeatEx.rawValue,
             PackageType.heartbeatExL2.rawValue, PackageType.heartbeatExL3.rawValue:
            // 回显心跳，维持连接
            var r = DataPacket(type: p.type, src: connection.myID, des: p.src)
            r.machineName = connection.machineName
            _ = connection.send(r)
            if p.src != 0 && p.src != 0xFF { peerID = p.src }
            if !p.machineName.isEmpty { peerName = p.machineName }
            matrix.noteSeen(src: p.src, name: p.machineName)

        case PackageType.handshake.rawValue, PackageType.handshakeAck.rawValue,
             PackageType.hello.rawValue, PackageType.awake.rawValue:
            // 握手尾声会有残留 Ack；Hello/Awake 只需回显即可，不必刷屏。
            var r = DataPacket(type: .hello, src: connection.myID, des: p.src)
            r.machineName = connection.machineName
            _ = connection.send(r)
            matrix.noteSeen(src: p.src, name: p.machineName)

        case PackageType.byeBye.rawValue:
            log("[MWB] 收到 ByeBye, 断开")
            matrix.noteByeBye(name: p.machineName)
            connection.close()

        case PackageType.hideMouse.rawValue:
            // HideMouse: 隐藏非活动机器上的光标。由 Windows 侧主导，本机无需动作，静默即可。
            break

        case PackageType.machineSwitched.rawValue:
            // MachineSwitched(77)：**离开方**通知「接手方」现在轮到它了。PowerToys 的
            // `Clipboard.GetRemoteClipboard` 就挂在这个包上（`Receiver.cs` 里：
            // `Des == 自己` 且 30 秒内收到过心跳 → 去拉对端剪贴板）。
            //   · Windows 把控制权交给我们时 → Des=本机 ID → 我们去拉它的大载荷
            //     （>1MB 的图片/文本，或它 Ctrl+C 复制的文件）；
            //   · 我们交给 Windows 时由 `handedControlToRemote()` 反发同样的包。
            // 没收到过心跳就不动（对齐 PowerToys `BIG_CLIPBOARD_DATA_TIMEOUT = 30s`），
            // 也不打日志 —— 切机很频繁，保持安静（原注释的意图）。
            if (p.des == connection.myID || p.des == 0xFF),
               let beat = lastBigClipboardBeatAt,
               Date().timeIntervalSince(beat) < 30 {
                pullBigClipboardFromPeer(retry: true)
            }
            break

        case PackageType.mouse.rawValue:
            // 【诊断】投放态中把对端发来的「非位移」鼠标包记下来 —— 这是判断
            // 「Windows 到底有没有把松手那一拍发过来」的唯一直接证据。
            // 实测（2026-09-14）：物理鼠标在 Mac 上，抬起是**本地事件**，
            // 所以这里通常一个都不会出现；它出现就说明那台机器是反过来的布局。
            if peerIsDropping, p.mouseFlags != WM_MOUSEMOVE {
                dropMouseProbe += 1
                if dropMouseProbe <= 20 {
                    log("[MWB] [文件] 投放态中收到远端鼠标包 flags=0x\(String(p.mouseFlags, radix: 16))"
                        + "（本机期望的松手是 0x\(String(WM_LBUTTONUP, radix: 16))）")
                }
            }
            // ★ 对端拖着文件在我们这一侧松手 —— 这一拍必须**先**处理，放在 isControllingRemote
            //   守卫之前：拖放收尾与"谁在控制"无关（文件已经在对面被拖起来了），
            //   若此刻我方恰好仍被判定为控制方，这次抬起会被下面的 break 吃掉，
            //   文件就永远拉不回来（Windows → Mac 方向会表现为"松手后毫无反应"）。
            //   ※ 仅当物理鼠标在 Windows 侧时才会走到这里；绝大多数情况下
            //     Win→Mac 的松手是本机左键抬起（见 InputController.onLocalLeftMouseUp）。
            if peerIsDropping, p.mouseFlags == WM_LBUTTONUP {
                peerIsDropping = false
                dropWatchdog?.cancel()
                dropWatchdog = nil
                input.finishFileDrop()
                input.injectMouseButton(flags: p.mouseFlags, nx: p.mouseX, ny: p.mouseY,
                                        xButton: p.mouseWheel)
                fetchFileFromPeer()
                break
            }
            // 我方正在控制远端时：对端发来的鼠标包一概忽略并丢弃。
            // 否则两边会互相抢控制权 —— 表现为「刚切过去就被踢回本机」，
            // 而且一旦被踢回，键盘包也就跟着不发了（键盘失灵的真正原因）。
            if input.isControllingRemote {
                let idle = Date().timeIntervalSince(lastSentInputAt)
                if idle > 2.0 {
                    log("[MWB] ⚠️ 对端仍在发鼠标包（我方已 \(String(format: "%.1f", idle))s 未发包）→ 让出控制权")
                    input.setControllingRemote(false, reason: "对端发来鼠标包")
                }
                break
            }
            if p.mouseFlags == WM_MOUSEWHEEL {
                input.injectMouseWheel(delta: p.mouseWheel)
            } else if p.mouseFlags == WM_MOUSEMOVE {
                input.injectMouseMove(nx: p.mouseX, ny: p.mouseY)
            } else {
                input.injectMouseButton(flags: p.mouseFlags, nx: p.mouseX, ny: p.mouseY,
                                        xButton: p.mouseWheel)
            }

        case PackageType.keyboard.rawValue:
            input.injectKeyboard(vk: p.keyVk, flags: p.keyFlags)

        case PackageType.clipboardText.rawValue:
            // 远端剪贴板文本分片（每片 48 字节，铺在 byte16..63）
            clipboard.appendRemoteChunk(p.raw48, isImage: false)

        case PackageType.clipboardImage.rawValue:
            // 远端剪贴板图片分片：同样是 byte16..63 铺 48 字节，但载荷是 **PNG 原始字节**，
            // 不能拿去当文本解压 —— 用 isImage 标记分开累积，到 ClipboardDataEnd 再走图片分支。
            clipboard.appendRemoteChunk(p.raw48, isImage: true)

        case PackageType.clipboardDataEnd.rawValue:
            // 结束标记 —— 到这一刻才按批次类型整体处理（图片解码 / 文本解压拆包）
            clipboard.finishRemote()

        case PackageType.clipboard.rawValue:
            // ★ Clipboard(69) 是「剪贴板心跳包」：对端有**大块**剪贴板数据（>1MB 的图片/文本，
            //   或它 Cmd+C 复制的文件），直推通道放不下，让我们回连它的 15100 拉。
            //   以前这个包被并进下面的静默分支，于是「Win 上复制大图 → Mac 粘不出来」
            //   且日志里毫无痕迹。
            guard p.src != connection.myID else { break }   // 自己广播的不理
            pullBigClipboardFromPeer()

        case PackageType.clipboardAsk.rawValue:
            // 对端（Windows）连不进我们的剪贴板通道，于是发 ClipboardAsk 让我们**反向推**过去。
            // 对称于 PowerToys Receiver.cs 的 ClipboardAsk 分支（它那边是 clientPushData = true）。
            guard p.des == connection.myID || p.des == 0xFF else { break }
            guard let ch = clipboardChannel else { break }
            let who = p.machineName.isEmpty ? peerName : p.machineName

            // 大剪贴板载荷（图片/文本 >1MB）优先：它比暂存文件更"新"（刚复制的）。
            if let payload = ch.pendingClipboardPayload {
                log("[MWB] [剪贴板] 对端 \(who) 主动索要 → 反向推送剪贴板载荷"
                    + "（\(fmtBytes(Int64(payload.byteCount)))）…")
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    guard let self else { return }
                    switch ch.pushClipboardPayload(to: self.host) {
                    case .success(let n):
                        self.log("[MWB] [剪贴板] ✓ 剪贴板载荷反向推送完成（\(fmtBytes(n))）")
                    case .failure(let e):
                        self.log("[MWB] [剪贴板] ✗ 剪贴板载荷反向推送失败: \(e.localizedDescription)")
                    }
                }
                break
            }

            guard let staged = ch.stagedFile else {
                log("[MWB] [文件] 对端索要数据，但本机既没有待推送剪贴板载荷也没有暂存文件")
                break
            }
            log("[MWB] [文件] 对端 \(who) 主动索要 → 反向推送 \(staged.lastPathComponent)…")
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                switch ch.pushStagedFile(to: self.host) {
                case .success(let n):
                    self.log("[MWB] [文件] ✓ 反向推送完成（\(fmtBytes(n))）")
                case .failure(let e):
                    self.log("[MWB] [文件] ✗ 反向推送失败: \(e.localizedDescription)")
                }
            }

        case PackageType.clipboardDragDrop.rawValue:
            // 对端说它手里有拖拽文件（DragDropStep08）。记下机器名，等它抬起鼠标时我们去拉。
            if !p.machineName.isEmpty { peerName = p.machineName }
            log("[MWB] [文件] 对端 \(peerName) 开始拖拽文件（ClipboardDragDrop）——"
                + " 等它在本机侧松手时会主动拉取")

        case PackageType.clipboardDragDropOp.rawValue:
            // DragDropStep08_2：对端点的投放目标是本机，它进入「投放态」。
            // ⚠️ Windows 在拖拽过程中会**反复**发这个包（实测 9s 内 20 次，
            //   每次换投放目标都会发；日志原样打印会把面板刷爆）。
            //   只在 false→true 那一刻打一条，并挂上看门狗。
            guard p.des == connection.myID || p.des == 0xFF else { break }
            if !peerIsDropping {
                peerIsDropping = true
                // ★ 立刻把控制权交回本机（拖文件全程按着左键，边缘退出逻辑不放行）。
                //   见 InputController.fileDropInProgress 的说明。
                input.fileDropInProgress = true
                log("[MWB] [文件] 对端进入投放态（ClipboardDragDropOperation）—— 等本机松手")
                armDropWatchdog()
            }
            break

        case PackageType.clipboardDragDropEnd.rawValue:
            // DragDropStep12：对端把拖拽收回了，取消投放。
            if peerIsDropping {
                peerIsDropping = false
                dropWatchdog?.cancel()
                dropWatchdog = nil
                input.finishFileDrop()
                log("[MWB] [文件] 对端取消了拖拽（ClipboardDragDropEnd）")
            }

        case PackageType.explorerDragDrop.rawValue:
            // ExplorerDragDrop(72)：旧式「资源管理器拖放」信令。
            // PowerToys 现版本走的是 ClipboardDragDrop(70) / ClipboardDragDropOperation(75)，
            // 主 socket 上正常不该出现它；一旦出现，说明对端用的是**另一条拖放路径**，
            // 必须留下痕迹 —— 以前它被并进下面那组的静默分支，导致
            // 「Win→Mac 拖放收不到任何事件」时完全无从判断对端到底发没发东西。
            log("[MWB] [文件] 收到 ExplorerDragDrop(72) —— 对端走的是旧式拖放信令"
                + "（src=0x\(String(p.src, radix: 16)) des=0x\(String(p.des, radix: 16))）")

        case PackageType.clipboardPush.rawValue, PackageType.clipboardCapture.rawValue:
            // 这两类是「剪贴板次级 socket」上的包，走主 socket 时不该出现，静默即可
            // （以前会把它们打进「未处理包类型」刷屏）。
            // 注意：Clipboard(69) 已单独处理（剪贴板心跳包），不在这里。
            break

        default:
            if p.type.isMatrix {
                // Matrix(128|布局标志)：Src = 槽位(1..4)，机器名在 byte32..63。
                // 收到第 4 个（或收齐 4 个）才提交整张布局。
                matrix.apply(matrixPacket: p)
                break
            }
            log("[MWB] 未处理包类型 \(p.type) (src=\(p.src))")
        }
    }
}
