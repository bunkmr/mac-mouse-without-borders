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

    /// 当前是否有一条**已通过双向认证**的链路。
    ///
    /// ★ 与 `run()` 的返回值**不是一回事**：首连失败时 `run(retryOnFirstFailure: true)`
    ///   同样返回 `.success`（语义是"客户端已启动"），此时本属性为 `false`。
    ///   面板要区分「已连接」与「等待对端上线（自动重连中）」，就得读它。
    public private(set) var linkEstablished = false

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
    /// 跨屏待机唤醒（v1.4.3）：持有防睡眠断言 + 远端键鼠到达时点亮屏幕。
    /// 机制与「为什么不能靠协议唤醒」见 `StandbyGuard.swift` 顶部长注释。
    ///
    /// ⚠️ 指向**进程共享单例**，不是每个 Client 各持一个：App 启动时连接流程会起两个
    /// Client（2026-09-19 实测），各持一个 Guard 就会创建两条断言、泄漏一条。
    public var standby: StandbyGuard { StandbyGuard.shared }
    /// 「屏幕熄灭后仍可被 Windows 键鼠唤醒」总开关。
    /// nil 时回落到 MWB_STANDBY_WAKE 环境变量（=1 开启），再回落到 **false**（保持历史行为）。
    public var preferredStandbyWake: Bool? = nil
    /// 待机唤醒是否**只在插电时**生效（电池供电时照常深度睡眠）。
    /// nil 时回落到 MWB_STANDBY_AC_ONLY（=0 = 电池也生效），再回落到 **true**。
    public var preferredStandbyWakeACOnly: Bool? = nil
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
    /// 发送线程空闲时的轮询间隔（秒）。
    ///
    /// 【为什么不能"无限期 wait"】只靠信号量的话，只要有**任何一条路径**让
    /// "信箱里有帧、却没人再发信号"，鼠标移动就**永久**停住 —— 而键盘/点击走的是
    /// 另一条同步发送路径，照样通。于是现象极具迷惑性：
    /// 「连接正常、键盘能用，就是鼠标不动、Windows 屏幕上连光标都看不到」。
    /// 定时唤醒把最坏情况从"永久卡死"降级为"最多 0.2s 的滞后"。
    static let mouseSenderIdlePoll: TimeInterval = 0.2
    /// 上一次**真的写进 socket** 的时刻（由发送线程在成功后更新）。
    ///
    /// 必须与 `sendMouseMovePacket` 里那个"生成率"计数器分开看：那个统计的是"造了多少帧"，
    /// 而"造出来了却一帧都没发出去"正是本 bug 的形态（日志里显示 99Hz，看着一切正常）。
    private var mouseDeliveredAt = Date.distantPast
    /// 自愈重启的节流时刻（避免"链路正常但信箱长期压着帧"时反复重启刷日志）。
    private var mouseStallHandledAt = Date.distantPast
    /// 累计自愈重启次数（日志里会报，便于回头判断这套兜底有没有真的在起作用）。
    private var mouseStallRestarts = 0
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
        // 新线程从"现在"开始计交付时刻：给它 1 个 watchdog 周期的宽限，
        // 免得刚起来就被判定成"卡住"而反复自杀重启。
        mouseDeliveredAt = Date()
        let t = Thread { [weak self] in
            while let s0 = self, s0.mouseSenderGeneration == gen {
                // ★ 定时唤醒，而不是无限期 `wait()`。
                //
                // 【为什么】信号量那套"只在空→非空时唤醒"的约定，**任何一次破坏都是永久性故障**：
                //   ① 发送失败 `break` 时信箱里可能还压着更新的一帧 → 投递方以为"信箱非空、
                //      发送线程本来就会取"，于是再也不 signal，而线程已经睡死；
                //   ② 线程被 `stopMouseMoveSender()` 停掉后若没人重启（**实测就是这条**：
                //      `handleLinkDead` 会停线程，而"自动重连成功"只重启了接收循环）——
                //      之后每一帧都只会把信箱里的旧帧顶掉，永远不出去。
                //   症状：键盘、点击、滚轮全部正常（它们不走信箱），**只有鼠标移动彻底不动**，
                //   而日志里"鼠标包发送率"照样 100Hz+（那个数统计的是"造帧"，不是"发帧"）。
                // 定时唤醒后，上面两种情形最多各自多滞后 0.2s，且早晚会自己好。
                _ = s0.mouseMailboxSignal.wait(timeout: .now() + Self.mouseSenderIdlePoll)
                // 一次唤醒把信箱取干：取的永远是"当下最新"的那一帧，
                // 中间被顶掉的帧不会发出去（这正是省 CPU 的地方）。
                while let s = self, s.mouseSenderGeneration == gen,
                      let p = s.mouseMailbox.takeLatest() {
                    if case .failure(let e) = s.connection.send(p) {
                        s.handleSendFailure(e)
                        // 失败时信箱里可能还压着更新的一帧：补一次信号。
                        // （即使漏了，上面的定时唤醒也会兜住；这里只是把延迟压到最小。）
                        if s.mouseMailbox.isPending { s.mouseMailboxSignal.signal() }
                        break               // 链路有问题时别再闷头发，交给看门狗
                    }
                    s.sendFailStreak = 0
                    s.mouseDeliveredAt = Date()
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

    // MARK: - 鼠标发送线程自愈（supervisor）

    /// 兜底自愈：发送线程若已经"停摆"（信箱压着位置却久久一帧都没交付）就重起一条。
    ///
    /// 这是**覆盖面最广**的一道保险：无论线程是被谁、以什么方式停掉的
    /// （断链、重连、未来的新退出路径，甚至将来有人误删了某处的重启调用），
    /// 只要鼠标还压着帧没发出去，1 秒内就会自愈并留下一条日志。
    /// 由 `startMouseSenderSupervisor()` 的 1s 定时器周期调用。
    /// 判据本体抽在 `MouseSenderSupervisor`（纯逻辑，可离线自检）。
    func checkMouseSenderHealth(now: Date = Date()) {
        let deliveredAgo = now.timeIntervalSince(mouseDeliveredAt)
        let handledAgo = now.timeIntervalSince(mouseStallHandledAt)
        guard MouseSenderSupervisor.shouldRestart(isPending: mouseMailbox.isPending,
                                                 deliveredAgo: deliveredAgo,
                                                 linkDead: linkDead,
                                                 handledAgo: handledAgo) else { return }
        mouseStallHandledAt = now
        mouseStallRestarts += 1
        log("[MWB] ⚠️ 鼠标发送线程已停摆（信箱里压着位置，"
            + "\(String(format: "%.1f", deliveredAgo))s 一帧都没发出去）→ 已自动重启"
            + "（累计第 \(mouseStallRestarts) 次）。"
            + "如果你正好遇到「键盘能用、鼠标不动 / Windows 上看不到光标」，就是它救的场")
        startMouseMoveSender()
    }

    /// 发送线程是否活着（线程对象存在且未结束）。用于日志与自检。
    var mouseSenderAlive: Bool {
        guard let t = mouseSenderThread else { return false }
        return !t.isFinished && !t.isCancelled
    }

    // MARK: - 鼠标发送线程的哨兵定时器

    private var mouseSupervisor: DispatchSourceTimer?
    /// 上次汇报时信箱的累计计数（用来算"这一轮投递/实发各多少"）。
    private var mouseStatSubmitted = 0
    private var mouseStatSent = 0

    /// 每 1 秒看一眼"该不该重启鼠标发送线程"。
    ///
    /// 放在主队列：重启线程、打日志都按主线程语义走，跟其它链路事件一致。
    /// 1s/次的代价可以忽略，换来的是**任何原因**导致的发送线程停摆都能在 1 秒内自愈。
    private func startMouseSenderSupervisor() {
        mouseSupervisor?.cancel()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(200))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            guard self.input.isControllingRemote else {
                // 控制权在本机时，信箱里压着的旧位置属于正常残留（没人该发它）——
                // 顺手丢掉，免得下一轮控制刚开始就先把一帧陈坐标甩给对端。
                self.mouseMailbox.discardPending()
                return
            }
            self.checkMouseSenderHealth()
        }
        t.resume()
        mouseSupervisor = t
    }

    /// 故障注入：只为验证"哨兵自愈"这条兜底真的会上膛，正常使用不会触发。
    ///
    /// `MWB_SIMULATE_MOUSE_SENDER_STALL=<秒数>`（默认 3）→ 到点用 `stopMouseMoveSender()`
    /// **原样复现「断链重连之后」的那个状态**（线程代号作废、线程退出），随后每 0.5s 往信箱投一帧
    /// （模拟用户还在动鼠标），持续 20 次。
    /// 预期日志（这是自检判据）：
    ///   ① `[故障注入] 已停线程（线程存活=false）`
    ///   ② 1~2s 内 `⚠️ 鼠标发送线程已停摆 … → 已自动重启`（**哨兵在干活**）
    ///   ③ 之后那条 `鼠标包发送率 … ｜ 信箱投递 N 实发 M` 里 `实发 ≥ 1`（帧真的被取走发出去了）
    ///
    /// 【为什么要重复投帧】哨兵只在"控制远端"时才判停摆（控制权在本机时信箱里的残留帧属于正常，
    /// 会被主动丢掉）。配合 `MWB_CURSOR_SELFTEST=send`（它会把状态置成"正在控制对端"）才能命中。
    private func startFaultInjectionIfRequested() {
        guard let raw = ProcessInfo.processInfo.environment["MWB_SIMULATE_MOUSE_SENDER_STALL"],
              !raw.isEmpty else { return }
        let delay = Double(raw) ?? 3.0
        log("[MWB] [故障注入] \(delay)s 后将停掉鼠标发送线程（模拟断链重连后的状态），验证哨兵自愈")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.stopMouseMoveSender()
            self.log("[MWB] [故障注入] 已停线程（线程存活=\(self.mouseSenderAlive)）；"
                     + "接下来每 0.5s 投一帧，应在 1~2s 内看到哨兵重启并把这些帧发出去")
            self.injectMouseFrames(remaining: 20)
        }
    }

    private func injectMouseFrames(remaining: Int) {
        guard remaining > 0 else { return }
        var p = DataPacket(type: .mouse)
        p.mouseFlags = InputController.mouseMoveFlag
        p.mouseX = 32767
        p.mouseY = 32767
        if !mouseMailbox.submit(p) { mouseMailboxSignal.signal() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.injectMouseFrames(remaining: remaining - 1)
        }
    }

    /// 故障注入之二：**伪造一次链路死亡**，走的是完全真实的那条路径
    /// （`handleLinkDead` → 交回控制权 → 退避重连 → 重连成功 → 重启鼠标发送线程）。
    ///
    /// `MWB_SIMULATE_LINK_DEAD=<秒数>` → 到点调 `handleLinkDead("故障注入…")`。
    /// 这是**主修复**（"重连后没人重启发送线程"）的直接验证，预期日志：
    ///   ① `✗ 故障注入：伪造链路死亡 → 立即把控制权交回 Mac，并开始自动重连…`
    ///   ② `[重连] 第 1 次尝试将在 0.5s 后开始` → `[连接] 开始重连 …`
    ///   ③ **`[重连] ✓ 链路已恢复（鼠标发送线程已重启）`** ← 判据就是这一行里的括号
    ///   ④ 之后的 `鼠标包发送率 … ｜ 信箱投递 N 实发 M` 里 `实发` 继续增长
    /// 对端在线时约 6s 走完；对端不在线时会一直在退避重连（日志会刷 ✗ 失败，属预期）。
    private func startReconnectFaultInjectionIfRequested() {
        guard let raw = ProcessInfo.processInfo.environment["MWB_SIMULATE_LINK_DEAD"],
              let delay = Double(raw) else { return }
        log("[MWB] [故障注入] \(delay)s 后将伪造一次链路死亡（走真实的重连与恢复路径）")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.handleLinkDead("故障注入：伪造链路死亡")
        }
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
        // ★ 已 `stop()` 的 Client 是终态：绝不再把自己拉回链路，也绝不排重连。
        guard !stopped else { return }
        linkDead = true
        linkEstablished = false
        // 本次断链还没试过重连 ⇒ 清掉"上次失败类型"，第一次重连按**探测间隔**快试
        //（对端可能只是重启了一下，5 秒内就该接回来）。
        lastConnectError = nil
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

    /// 首次连接就失败 ⇒ 转入重连循环（**不再把整个客户端丢掉**）。
    ///
    /// ★ 这是 2026-10-08「Mac 先开机、Windows 后开机 ⇒ Mac 老半天不连」的修复核心。
    ///   旧实现由 `AppDelegate` 在失败分支直接 `c.stop()`：既**关掉了回连监听**，
    ///   又让"只由 `handleLinkDead` 触发"的重连循环根本没机会启动（那个入口要求
    ///   "曾经连上过"）。于是 Mac 会永久躺平 —— 自己不重连、对端也回连不进来，
    ///   只能手动点一次「连接」。
    ///   现在把"首连失败"和"运行中断链"统一成同一件事：客户端继续活着，
    ///   在后台按「探测间隔 / 握手退避」自动接上对端。
    private func enterReconnectMode(afterFirstFailure error: MWBConnectionError) {
        lastConnectError = error
        linkDead = true
        linkEstablished = false
        reconnectAttempts = 0
        handshakeFailStreak = 0
        handshakeSilentStreak = 0
        reconnectScheduled = false
        let hint: String
        switch error {
        case .connectFailed:
            hint = "对端主机不可达（未开机 / 不在网 / MWB 未在监听）—— 将以 "
                + "\(Int(Self.peerProbeInterval))s 间隔做**轻量探测**，对端一上线立即建立连接"
        case .handshakeFailed:
            hint = "对端在线但 MWB 尚未就绪 —— 将按握手退避重试"
                + "（刻意放慢：刚启动的 MWB 被连接洪水撞上会判 invalidkey 并自我保护退出）"
        default:
            hint = "将以探测间隔重试"
        }
        log("[MWB] ⓘ 首次连接未成功（\(error)）：\(hint)。"
            + "回连监听**保持开启** —— 对端开机后也可能主动连回来，无需手动点「连接」。")
        onLinkDown?("等待对端上线（自动重连中）")
        scheduleReconnect()
    }

    /// 单次「对端不在线」探测之后，多久再探一次（秒）。
    ///
    /// ★★ 把「**检测对端在不在**」与「**建立连接**」拆开，是 2026-10-08 这一版的核心 ★★
    ///
    /// 过去的实现只有一个手段（主动 TCP connect + 握手），它同时承担"探测"与"建连"
    /// 两种职责，于是必然二选一得难看：
    ///   · 敲得勤 ⇒ 对端刚启动的那 10~60 秒里被撞出一串 `invalidkey`，把它的
    ///     `too many connections` 自我保护打出来（2026-09-22 / 10-06 两起事故）；
    ///   · 敲得懒 ⇒ 退避封顶到 600s，对端明明已经开机，我们还要干等最多 10 分钟
    ///     —— 这正是用户报的「Windows 开了，Mac 老半天不连」。
    ///
    /// 拆开之后各用各的节奏：
    ///   · `connectFailed`（TCP 都连不上：主机不在 / 15101 没人监听）
    ///     ⇒ SYN 根本到不了对端的 MWB，**对它零成本** ⇒ 可以探得密：5 秒一次，
    ///       换来"对端一上线，10 秒内就接上"（5s 间隔 + 一次约 5s 的连接超时）。
    ///   · `handshakeFailed`（TCP 通了 = 对端 accept 了）⇒ 这才**有成本**，
    ///     交给下面那条 `handshakeFailBackoff` 慢慢来。
    public static let peerProbeInterval: Double = 5

    /// 握手失败（对端在线但 MWB 未就绪）时按**连续失败次数**递增的退避。
    ///
    /// 只服务于"对端在线、15101 也在 accept，但配置还没加载完"这一个场景：
    /// 此时每一次握手都会被判 `invalidkey` 并计入它的连接数，密集重试会把刚起来的
    /// MWB 打进 `too many connections` 自我保护（它自己就退出了）。
    /// 对端启动窗口约 10~60 秒，所以第一次失败等 30s、第二次 60s 就足以跨过窗口，
    /// 同时把"窗口内撞击次数"压在 2 次以内（离它的阈值 9 还差得远）。
    public static func handshakeFailBackoff(streak: Int) -> Double {
        let n = max(1, streak)
        switch n {
        case 1...3:  return 30.0
        case 4...6:  return 60.0
        case 7...10: return 180.0
        default:     return 600.0
        }
    }

    /// 「**对端进程没在处理这条连接**」型的握手失败（预热块零字节超时）退避曲线。
    ///
    /// ★★ 为什么它敢比 `handshakeFailBackoff` 快一个数量级 ★★
    ///
    /// 那两条曲线里"必须慢"的全部理由是**对端会记账**：对端 MWB 收到我们的连接、
    /// 判定 `invalidkey`，攒到 9 次就打出 `too many connections` 自我保护退出
    ///（2026-09-22 / 10-06 两起事故）。
    ///
    /// 而"零字节超时"这一类的物理含义恰恰是**对端进程没有 accept / 没有读**
    /// —— 那是内核 accept 队列在替它握手（所以 `connect()` 会成功），
    /// 应用一字节都没看见，**记账根本无从发生**。典型场景就是
    /// **Windows 的连接待机（Modern Standby）**：网卡在工作、用户态被冻结。
    ///
    /// 实测（2026-10-08 11:15~11:21）：对端在待机窗口里连着 5 次"零字节超时"，
    /// 全程 TCP 连得上、却 8 秒读不到任何数据；等到 11:21:28 它一醒，
    /// 立刻就正常握手了。若按 600s 封顶，这一步会白等 10 分钟。
    ///
    /// ★ 反过来说：**只要对端回了一个字节，就会落回 `handshakeFailBackoff`** ——
    ///   真正危险的那种"MWB 正在启动、配置没加载完"必定会回 `invalidkey`，
    ///   所以安全性一点没让步。
    public static func handshakeSilentBackoff(streak: Int) -> Double {
        let n = max(1, streak)
        switch n {
        case 1...4:  return 30.0
        case 5...10: return 60.0
        default:     return 120.0
        }
    }

    /// **历史曲线**（v1.4.4 及以前真正在用的退避）：0.5/1/2/4/8 → 8 → 30 → 60 → 180 → 600s。
    ///
    /// 现在**不再用它调度** —— 它把"探测"和"建连"混成同一个动作，正是上面说的问题。
    /// 保留下来只为让自检能做**新旧对照**（把两代曲线的代价摆在一起看）。
    /// 重连退避时长（秒）。**抽成纯函数是为了能被自检盯住** —— 这条曲线直接决定
    /// 「对端整夜离线时会不会被我们轰死」，属于必须可回归的东西。
    ///
    /// 曲线：0.5 / 1 / 2 / 4 / 8（前 5 次，对端重启通常几十秒内回来，重试要快）
    ///       → 8（6~10 次）→ 30（11~30 次）→ 60（31~60 次）
    ///       → 180（61~120 次）→ **600（121 次起的稳态：10 分钟一次）**。
    ///
    /// ★★ 稳态必须是「分钟级的稀疏探测」，不能是「60s 永不停歇地敲门」 ★★
    ///
    /// 2026-10-06 实测（本版回归的对象）：对端从 23:33 断到次日 10:00，7.5 小时里我们
    /// 按 60s 封顶重连了 **590 次**。Windows 早上启动 MWB 时，在**它自己配置还没加载完的
    /// 那个窗口期**里被我们每分钟一次的敲门连着撞上，连判 9 个 `invalidkey`，累计到达
    /// MWB 的自我保护阈值 → `too many connections` → 它把自己终止了（用户看到弹框）。
    ///
    /// 关键从来不是"总次数"，而是**稳态间隔与对端启动窗口的比例**：
    /// 启动窗口约 10~60 秒 —— 间隔 60s 时撞上的概率约 50%，而且会**连着撞好几次**；
    /// 间隔 600s 时撞上概率约 10%，且**最多只撞 1 次**，凑不满连接数阈值。
    /// ⇒ 对端离线越久，我们越要**安静**。「更努力地敲」只会把对方刚起来的服务打死。
    public static func reconnectBackoffDelay(attempt: Int) -> Double {
        let n = max(1, attempt)
        switch n {
        case 1...5: return 0.5 * pow(2.0, Double(n - 1))   // 0.5, 1, 2, 4, 8
        case 6...10: return 8.0
        case 11...30: return 30.0
        case 31...60: return 60.0
        case 61...120: return 180.0
        default: return 600.0                              // 稳态：10 分钟一次
        }
    }

    /// 重连调度回归自检 —— 判据从「总次数」升级为「**对端开机后多久接上**」。
    ///
    /// 回归对象是三代行为：
    ///   ① 2026-09-22：曲线封顶 8s 且永不放弃 ⇒ 对端关机 9 小时被敲 2400+ 次，
    ///      一开机就被打进 `too many connections`（Windows 上 MWB 弹框自己关了）；
    ///   ② 2026-10-06：封顶放宽到 60s 但密度没变 ⇒ 7.5 小时 590 次，照样把刚启动的 MWB 打死；
    ///   ③ 2026-10-08：改成 600s 稳态后确实安静了，可**代价是慢** —— 对端开机后最长要等
    ///      10 分钟才试下一次，用户的观感就是「Windows 开了，Mac 老半天不连」。
    ///
    /// ⇒ 本版把「探测」与「建连」拆成两条节奏，判据也随之变成**四件事**：
    ///     A. 探测间隔 3~5s（够快，又不至于变成刷子）
    ///     B. **对端开机后 ≤10s 内恢复**（一个探测周期 + 一次连接超时）
    ///     C. 对端启动窗口（60s）内**握手**次数 ≤2 —— 握手是唯一有成本的动作，对端阈值是 9
    ///     D. 对端"在线但一直就绪不了"时，9 小时内握手总次数 <100
    public static func reconnectBackoffSelfTest() -> Bool {
        var bad = 0
        func check(_ okFlag: Bool, _ desc: String, _ detail: String = "") {
            print("  \(okFlag ? "✓" : "✗") \(desc)\(detail.isEmpty ? "" : "  —— \(detail)")")
            if !okFlag { bad += 1 }
        }

        // ── A. 探测间隔
        check(peerProbeInterval <= 5 && peerProbeInterval >= 3,
              "对端不在线时的探测间隔 = \(Int(peerProbeInterval))s（判据 3~5s）")

        // ── B. 对端开机后最坏多久接上（一个探测周期 + 一次连接超时，最坏是刚好错过一拍）
        let connectTimeout = 5.0
        let recovery = peerProbeInterval + connectTimeout
        check(recovery <= 10,
              "对端开机后最坏恢复时间 = \(Int(peerProbeInterval))s 探测 + \(Int(connectTimeout))s 连接超时"
              + " = \(Int(recovery))s（判据 ≤10s）",
              "对照：上一代(600s 稳态) 对端开机后最长要等满一整档 = 600s")

        // ── C. 对端启动窗口内会做几次**握手**（唯一有成本的动作）
        //      模式：探到 TCP 通 → 立即握手 → 失败（窗口内）→ 退避 → 再握手 → …
        var t = 0.0, streak = 0, handshakesInWindow = 0
        while t < 60 {
            handshakesInWindow += 1
            streak += 1
            t += handshakeFailBackoff(streak: streak)
        }
        check(handshakesInWindow <= 2,
              "对端启动窗口(60s)内握手 \(handshakesInWindow) 次（判据 ≤2；对端自我保护阈值是 9）")

        // ── D. 对端"在线但一直就绪不了"：9 小时握手总次数
        t = 0; streak = 0; var handshakesIn9h = 0
        while t < 32400 {
            handshakesIn9h += 1
            streak += 1
            t += handshakeFailBackoff(streak: streak) + connectTimeout
        }
        var legacy9h = 0
        t = 0
        while t < 32400 { t += reconnectBackoffDelay(attempt: legacy9h + 1) + connectTimeout; legacy9h += 1 }
        check(handshakesIn9h < 100,
              "对端在线但就绪不了 · 9 小时握手总次数 = \(handshakesIn9h) 次（判据 <100）",
              "对照：上一代曲线 \(legacy9h) 次（真正的代价在 B：对端开机后它还要等满一整档）")

        // ── 曲线断点（防止有人改错档位）
        check(handshakeFailBackoff(streak: 1) == 30 && handshakeFailBackoff(streak: 3) == 30
              && handshakeFailBackoff(streak: 4) == 60 && handshakeFailBackoff(streak: 6) == 60
              && handshakeFailBackoff(streak: 7) == 180 && handshakeFailBackoff(streak: 11) == 600
              && handshakeFailBackoff(streak: 99) == 600,
              "握手退避断点：30 / 60 / 180 / 600s")

        // ── E. 零字节型（对端进程没在响应）的退避：必须**更快**，但仍不许无限敲门
        //
        //     判据来自 2026-10-08 实测：对端在连接待机窗口里连着 5 次零字节超时，
        //     醒来后立刻就能握手。若沿用 600s 封顶，这里要白等 10 分钟。
        var ts = 0.0, sStreak = 0, silentIn9h = 0
        while ts < 32400 {
            silentIn9h += 1
            sStreak += 1
            ts += handshakeSilentBackoff(streak: sStreak) + connectTimeout
        }
        check(handshakeSilentBackoff(streak: 999) <= 120,
              "零字节型握手失败退避封顶 = \(Int(handshakeSilentBackoff(streak: 999)))s（判据 ≤120s）",
              "对照：有响应型封顶 600s —— 对端不记账，所以允许更密")
        check(handshakeSilentBackoff(streak: 999) > 30,
              "零字节型退避封顶仍 >30s（不许退化成高频敲门）")
        check(silentIn9h < 300,
              "零字节型 · 9 小时握手总次数 = \(silentIn9h) 次（判据 <300）",
              "同一场景下上一代曲线是 \(handshakesIn9h) 次")
        check(handshakeSilentBackoff(streak: 1) == 30 && handshakeSilentBackoff(streak: 4) == 30
              && handshakeSilentBackoff(streak: 5) == 60 && handshakeSilentBackoff(streak: 10) == 60
              && handshakeSilentBackoff(streak: 11) == 120,
              "零字节型退避断点：30 / 60 / 120s")
        // ★ 两条曲线在**第一档必须相同**（都是 30s）—— 刚失败一次时还没到"看清楚代价"的时候，
        //   不应该让代码路径产生行为分叉，否则回归时很难解释。
        check(handshakeSilentBackoff(streak: 1) == handshakeFailBackoff(streak: 1),
              "两条曲线第一档一致（都是 30s）")

        return bad == 0
    }

    /// 安排下一次重连。**延迟由「上一次失败是谁的错」决定**（见前面两条曲线的说明）：
    ///
    ///   · `connectFailed` → `peerProbeInterval`（5s）：对端主机不在 / 15101 没人监听，
    ///     SYN 到不了 MWB，对它零成本 ⇒ 探得密，换来"对端一上线就接上"。
    ///   · `handshakeFailed` → `handshakeFailBackoff(streak)`（30/60/180/600s）：
    ///     对端 accept 了但没就绪，每一次都在它的账上记一笔 ⇒ 必须慢。
    ///   · 还没失败过（刚断链 / 刚启动）→ 也走 5s：先快速试一次，再按结果分流。
    private func scheduleReconnect() {
        // ★ 已 `stop()` ⇒ 永不排队。这是杀掉僵尸循环的第一道闸。
        guard !stopped else { return }
        guard !reconnectScheduled else { return }
        reconnectScheduled = true
        reconnectAttempts += 1
        reconnectAttemptsTotal += 1

        let delay: Double
        /// 0 = 轻量探测；1 = 有响应的握手失败；2 = 零字节的握手失败。
        var kind = 0
        if case .some(.handshakeFailed) = lastConnectError {
            handshakeFailStreak += 1
            if connection.lastHandshakeSawNoData {
                // 对端进程没在处理这条连接（连接待机 / 已退出）—— 它没记账，可以用中等档。
                kind = 2
                handshakeSilentStreak += 1
                delay = Self.handshakeSilentBackoff(streak: handshakeSilentStreak)
            } else {
                // 对端回了字节但协议/密钥对不上 —— 这种**每次都在它账上记一笔**，必须慢。
                kind = 1
                handshakeSilentStreak = 0
                delay = Self.handshakeFailBackoff(streak: handshakeFailStreak)
            }
        } else {
            // 对端压根不在线（或还没失败过）：轻量探测，不对 MWB 造成任何压力。
            handshakeFailStreak = 0
            handshakeSilentStreak = 0
            delay = Self.peerProbeInterval
        }

        log("[MWB] [重连] 第 \(reconnectAttempts) 次尝试将在 \(String(format: "%.1f", delay))s 后开始"
            + (kind == 2
               ? "（对端**进程没在响应** —— 预热块零字节超时 \(handshakeSilentStreak) 次；"
                 + "多半是 Windows 在连接待机/休眠：网卡还在，应用被冻结。"
                 + "这类连接对端不记账，所以按中等节奏敲门，它一醒来就能接上）"
               : kind == 1
               ? "（握手已连续失败 \(handshakeFailStreak) 次 → 放慢：对端 MWB 未就绪时密集敲门"
                 + "会被它判 invalidkey 并打进自我保护）"
               : "（对端不在线 → 轻量探测；对端一上线立刻建立连接）"))
        // 长时间连不上时给一条可操作的提示（别让用户对着刷屏日志毫无头绪）。
        if reconnectAttempts == 20 || reconnectAttempts == 120 || reconnectAttempts % 600 == 0 {
            log("[MWB] [重连] ⓘ 已连续重试 \(reconnectAttempts) 次仍未连上。若 Windows 已开机："
                + "① 确认托盘里有 Mouse Without Borders 且在运行（它有自我保护，可能已自行退出）；"
                + "② 核对两边安全码一致。本机正以 \(Int(Self.peerProbeInterval))s 间隔做轻量探测 —— "
                + "对端一上线会自动接上，无需手动点「连接」。")
        }
        // ★ 代际号：`retryNow()` 会把它 +1，用来作废"已经排好但还没到期"的那一次 ——
        //   否则会出现两次重连并行（两个 socket、两条接收线程）。
        reconnectGeneration += 1
        let gen = reconnectGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            // ★★ 第二道闸，也是本次（2026-10-08 僵尸重连洪水）修复的关键 ★★
            //    `stop()` 之后到点的重连块**必须**作废。旧代码这里只有下面那条 `linkDead`
            //    判断，而 `stop()` 恰好把 `linkDead` 置成了 `true` ⇒ 语义撞车，
            //    僵尸循环正是从这一行溜过去、从此永不停止的。
            guard !self.stopped else { self.reconnectScheduled = false; return }
            guard gen == self.reconnectGeneration else { return }   // 已被 retryNow 取代
            // ⚠️ 注意这条判断的**正向**语义：`linkDead == true` 才继续（"链路已断，该重连"）。
            //    它**不是**"是否已停用"—— 那是 `stopped` 的职责，别再把两者混用。
            guard self.linkDead else { self.reconnectScheduled = false; return }
            self.reconnectInFlight = true
            DispatchQueue.global(qos: .userInitiated).async {
                self.armConnectWatchdog(tag: "重连第 \(self.reconnectAttempts) 次")
                let r = self.connection.reconnect()
                self.disarmConnectWatchdog()
                DispatchQueue.main.async {
                    self.reconnectInFlight = false
                    // 记下这次失败的类型：**下一次的延迟由它决定**（5s 轻量探测 vs 慢速握手退避）。
                    if case .failure(let e) = r { self.lastConnectError = e }
                    self.reconnectScheduled = false
                    switch r {
                    case .success:
                        self.linkDead = false
                        self.linkEstablished = true
                        // 重连成功 ⇒ 静默计时归零。不归零的话，看门狗会拿"断链前那次
                        // 收到包的时刻"来判，刚连上就立刻又被判死，陷入无谓的死循环。
                        self.lastInboundAt = Date()
                        self.lastConnectError = nil
                        self.sendFailStreak = 0
                        self.sendFailLogCount = 0
                        self.reconnectAttempts = 0
                        self.handshakeFailStreak = 0
                        self.handshakeSilentStreak = 0
                        // ★ 首连就没成功过的话，"运行态"（心跳 / 剪贴板 / 输入捕获 /
                        //   文件传输 / 接收循环）到现在还一次都没起过 —— run() 里那条路径
                        //   没走到。这里是它们唯一的启动点（runtimeStarted 守卫保证只做一次）。
                        self.startRuntimeIfNeeded()
                        self.announceHello()
                        // ★★ 必须重新起一条鼠标发送线程。
                        //
                        // 【为什么】`handleLinkDead` 会 `stopMouseMoveSender()`（把旧线程的代号作废，
                        // 它随即退出），而重连成功只重启了**接收**循环 —— 没有人重启发送线程。
                        // 于是重连之后：键盘/点击/滚轮照常（它们不走信箱、直接同步 send），
                        // **鼠标移动却永远发不出去**（帧全被压在信箱里轮着被顶掉），
                        // 在 Windows 侧的表现就是「屏幕上连光标都不显示」。
                        // 这正是 2026-09-19 用户报的那个 bug，且只在"断过一次线"之后出现。
                        self.startMouseMoveSender()
                        self.log("[MWB] [重连] ✓ 链路已恢复（鼠标发送线程已重启），键鼠可以继续跨屏")
                        self.onLinkUp?()
                    case .failure(let e):
                        self.log("[MWB] [重连] ✗ 失败: \(e)")
                        self.scheduleReconnect()
                    }
                }
            }
        }
    }

    /// 外部事件（系统从睡眠唤醒 / 网络路径变化 / 用户点「连接」）触发的**立刻重试**：
    /// 清空退避阶梯，马上试一次。
    ///
    /// 【为什么必须有】对端"不在线"期间的探测间隔虽然是 5s，但只要途中撞上过一次
    /// `handshakeFailed`，退避就会爬到 180~600s 那一档 —— 而"Mac 刚被唤醒 / 网络刚恢复"
    /// 恰恰是**对端最可能已经就绪**的时刻。此时应当立刻探一次，而不是干等那一档走完。
    public func retryNow(reason: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.linkDead else { return }
            // ★ 已 `stop()` ⇒ 不响应任何"立刻重试"（否则僵尸会借外部事件复活）。
            guard !self.stopped else { return }
            // 已经有一轮在飞 → 不必再加一条，它马上会给出结果。
            guard !self.reconnectInFlight else {
                self.log("[MWB] [重连] ⚡ 收到「\(reason)」—— 已有一轮尝试在进行，不重复发起")
                return
            }
            self.log("[MWB] [重连] ⚡ 收到「\(reason)」→ 清空退避，立即重试")
            // 作废"已排好但还没到期"的那一次，否则两个重连会并行。
            self.reconnectGeneration += 1
            self.reconnectScheduled = false
            self.reconnectAttempts = 0
            self.handshakeFailStreak = 0
            self.handshakeSilentStreak = 0
            self.lastConnectError = nil
            self.scheduleReconnect()
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

    /// 本 Client 是否已被 `stop()` **永久停用**（终态，不可复活）。
    ///
    /// ★★【为什么必须有这个标志 —— 2026-10-08 实测到的僵尸重连洪水】★★
    /// `stop()` 过去只做了 `linkDead = true` 来隐含表达"用户主动断开、别再自动重连"，
    /// 但 `scheduleReconnect()` 里那个"延时到点后要不要继续重连"的闸门**恰好**是
    ///     `guard self.linkDead else { self.reconnectScheduled = false; return }`
    /// —— 即 `linkDead == true` 是**放行**条件。两处语义撞车，后果是：
    ///     **`stop()` 不但没停掉待发的重连，反而正好把它放行。**
    /// 现场证据（`/tmp/mwb_gui.log`，v1.4.6）：
    ///   · 面板每点一次「连接」就 `connect()` 新建一个 Client，同时 `client?.stop()` 旧的；
    ///   · 旧 Client 的延时重连块照旧到点执行 → `connection.reconnect()` → 失败 → 再排一次
    ///     ⇒ **一条永不停止的僵尸重连循环**；
    ///   · 13 次点击 = 12 条僵尸循环，合计 **~2.3 次 TCP connect/秒**轰对端
    ///     （12:25:17→12:30:57 共 924 次尝试，计数器走到第 85 次）。
    /// 这既是对端 `too many connections` / `invalidkey` 自我保护的直接来源，
    /// 也让"面板显示的那个 Client"和"真正持有链路的 Client"可能不是一个。
    ///
    /// ⇒ 一律用这个**独立的终态标志**来判断，不要再借用 `linkDead`。
    private var stopped = false

    // MARK: - 入站静默看门狗（半开连接的唯一发现手段）

    /// 最近一次收到**任何**入站包的时刻。
    ///
    /// 【为什么不能用"最后一次发出鼠标包"之类的信号代替】半开连接的形态是
    /// 「我们写得出去、对端一个字都不回」，所以判据必须只看**入站**方向。
    private var lastInboundAt = Date()

    /// 对端静默看门狗（1 秒一跳）。
    private var inboundSilenceWatchdog: DispatchSourceTimer?

    /// 静默阈值（秒）。`MWB_INBOUND_SILENCE` 可覆盖 —— 自检与现场调参用。
    private let inboundSilenceTimeout: TimeInterval = {
        if let s = ProcessInfo.processInfo.environment["MWB_INBOUND_SILENCE"],
           let v = Double(s), v > 0 {
            return v
        }
        return InboundSilence.defaultTimeout
    }()

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

    /// **单调递增**的重连尝试总数 —— 只给自检/诊断用。
    ///
    /// 与 `reconnectAttempts`（"连续次数"，成功或 `retryNow` 时会被清零）不同，
    /// 它只增不减，因此能回答那个关键问题：
    /// **`stop()` 之后还有没有人在偷偷重连？**
    /// `--zombie-stop-selftest` 就是靠它在 stop 前后各取一次快照来判定的。
    public private(set) var reconnectAttemptsTotal = 0
    /// 是否已有一轮重连**正在进行**（`retryNow()` 靠它避免重复发起）。
    private var reconnectInFlight = false
    /// 重连代际号：`retryNow()` 把它 +1 来作废"已排好但还没到期"的那一次。
    private var reconnectGeneration = 0
    /// 上一次**重连尝试**失败的类型 —— 下一次的延迟由它决定：
    /// `connectFailed`（对端不在）⇒ 5s 轻量探测；`handshakeFailed`（对端未就绪）⇒ 慢速退避。
    /// `nil` = 还没失败过（刚断链 / 刚启动）。
    private var lastConnectError: MWBConnectionError?
    /// 「握手失败」的连续次数（`connectFailed` 会把它清零）。
    private var handshakeFailStreak = 0
    /// 「对端进程根本没在处理这条连接」的连续次数（预热块**零字节**超时，见
    /// `MWBConnection.lastHandshakeSawNoData`）。
    ///
    /// 【为什么要跟 `handshakeFailStreak` 分开】两者的**代价**是反的：
    ///   · 有响应的握手失败 ⇒ 对端进程活着、每敲一次它都记账 ⇒ 必须慢（封顶 600s）；
    ///   · 零字节的握手失败 ⇒ 对端进程压根没 accept/没处理（连接待机、已退出）
    ///     ⇒ 没有任何记账 ⇒ 可以快一点（封顶 120s），换来"对端一醒来就接上"。
    /// `connectFailed` 会把两个都清零。
    private var handshakeSilentStreak = 0

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

    /// 启动客户端。
    ///
    /// - Parameter retryOnFirstFailure: 首次连接失败时**不放弃**，转入与「运行中断链」
    ///   **完全相同**的重连状态机，同时保持回连监听常驻。GUI 用 `true`；CLI 工具传
    ///   `false`，这样"到底连上没有"仍然是一个干净的返回值。
    ///
    ///   ★ 为什么需要这个开关（2026-10-08 用户报「Windows 开机后 Mac 老半天不连」）：
    ///     旧实现里首次连接失败 = `AppDelegate` 直接 `c.stop()`，于是
    ///       ① **回连监听被一起关掉**（`lsof` 里连 `:15101 LISTEN` 都没有）；
    ///       ② 重连循环只由 `handleLinkDead` 触发，而它只在"曾经连上过"之后才可能跑。
    ///     两条叠加 ⇒ **Mac 先开机、Windows 后开机**这个顺序下 Mac 会永久躺平：
    ///     自己不重连、对端也回连不进来，只能手点一次「连接」。
    ///     现在首连失败也进重连循环，且监听不被收 —— 对端一上线，两条路都能自动接上。
    ///
    /// - Note: 返回 `.success` 只代表"客户端已启动（监听在跑、重连循环在跑）"，
    ///   **不代表链路已建立**。要区分二者请读 `linkEstablished`。
    public func run(retryOnFirstFailure: Bool = true) -> Result<Void, MWBConnectionError> {
        // ★ 已 `stop()` 的 Client 是**终态**，绝不允许复活 —— 复活就等于又造一条僵尸重连
        //   循环（见 `stopped` 属性上的长注释）。调用方应当新建一个 `MWBClient`。
        guard !stopped else {
            log("[MWB] ✗ 该客户端已 stop()（终态）→ 拒绝再次 run()。请新建一个 MWBClient。")
            return .failure(.connectFailed(NSError(
                domain: "MWB", code: -3,
                userInfo: [NSLocalizedDescriptionKey: "客户端已停止（终态），不能复用"])))
        }
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

        // ★★ 连接回调必须在 `connect()` **之前**挂好 ★★
        //   首连失败时本 Client 会转入重连循环，而重连成功后"收到的包"与"读侧断开信号"
        //   都依赖这两个闭包 —— 若照旧挂在成功路径上，那条重连链路会**收不到任何包**
        //   （在 Windows 侧的表现就是对端屏幕上连光标都不出现）。
        //   它们是纯赋值、不建立任何资源，提前挂没有副作用。
        //
        // ⚠️ 别强捕获 `connection`：它是 self 的属性，而它自己又持有这个闭包 → 循环引用。
        connection.onPacket = { [weak self] p in
            guard let self else { return }
            self.handle(p, from: self.connection)
        }
        // 读侧断开信号：**比等写失败快得多**（心跳 4s 一颗，而写失败要等下一次发送）。
        // 收到就立刻走同一条降级路径：交回控制权 + 自动重连。
        connection.onDisconnected = { [weak self] reason in
            self?.handleLinkDead(reason)
        }

        // ★ 起看门狗再连：对端静默时不能无限期挂住（见 armConnectWatchdog 说明）。
        armConnectWatchdog(tag: "首次连接 \(host):\(port)")
        let r = connection.connect()
        guard case .success = r else {
            disarmConnectWatchdog()
            log("[MWB] 连接/握手失败: \(r)")
            if retryOnFirstFailure, case .failure(let e) = r {
                enterReconnectMode(afterFirstFailure: e)
                // 语义 = "客户端已启动"（监听在跑、重连循环在跑），**不是**"链路已建立"。
                return .success(())
            }
            return r
        }
        disarmConnectWatchdog()
        linkEstablished = true
        // 刚握完手 ⇒ 静默计时从"现在"起算（否则会拿开机前的旧时刻去判，一上线就被判死）。
        lastInboundAt = Date()
        log("[MWB] 握手阶段结束，进入运行态")
        startRuntimeIfNeeded()
        connection.startReceiveLoop()
        return .success(())
    }

    /// 运行态初始化 —— **只做一次**。
    ///
    /// 与 `run()` 从前的内联实现逐句对应，只是搬成了独立函数：现在有**两条路**会走到这里 ——
    /// ① `run()` 首次连接成功；② 首连失败后，重连循环里**第一次**连上。
    /// `runtimeStarted` 守卫保证只执行一次：里面全是"起线程 / 起定时器 / 注册观察者"，
    /// 重复执行就是资源泄漏（多条接收线程、多个心跳定时器、重复的输入捕获……）。
    private var runtimeStarted = false
    private func startRuntimeIfNeeded() {
        guard !runtimeStarted else { return }
        runtimeStarted = true
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

        // 鼠标移动包改由**独立线程**异步发送（信箱只留最新一帧）——
        // 必须在 run() 末尾起：此时连接、密钥、socket 都已就绪。
        startMouseMoveSender()
        // 哨兵：万一发送线程以任何方式停摆（断链、重连、将来新加的退出路径…），
        // 1 秒内自动重启它。没有这道保险时，故障形态是"键盘能用、鼠标完全不动"。
        startMouseSenderSupervisor()
        startFaultInjectionIfRequested()
        startReconnectFaultInjectionIfRequested()

        // ★ 「顶到边缘时链路还活着吗」—— 注入给输入层。
        //
        // 【为什么必须有】2026-10-08 实测到一次"假交接"：11:21:20 我们已把主动连接
        //   `fd=5` 关掉（正在重连），11:21:22 用户把鼠标顶到边缘，**控制权照样交了出去**，
        //   紧接着就是 `⚠️ 发送失败 writeFailed`。对用户来说，这比"连不上"更难受 ——
        //   本机光标不见了、对端却毫无反应，看着像 App 坏了。
        //   链路没建立时就不该交出控制权。
        input.linkAliveProbe = { [weak self] in
            guard let self else { return false }
            return self.linkEstablished && !self.linkDead
        }

        // ★ 入站静默看门狗：**半开连接**（对端主机在、应用被冻结/已退出）的唯一发现手段。
        //   `SO_KEEPALIVE` 与写失败都发现不了它，见 `InboundSilence` 文件头的事故记录。
        startInboundSilenceWatchdog()
    }

    // MARK: - 入站静默看门狗

    /// 启动 1 秒一跳的静默检查。
    ///
    /// 跑在**主队列**：`handleLinkDead` 要求主线程（它要碰 UI 回调与重连状态机）。
    private func startInboundSilenceWatchdog() {
        guard inboundSilenceWatchdog == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(200))
        t.setEventHandler { [weak self] in self?.checkInboundSilence() }
        t.resume()
        inboundSilenceWatchdog = t
        log("[MWB] 入站静默看门狗已启动：阈值 \(Int(inboundSilenceTimeout))s"
            + "（对端正常时持续发包；静默超过该时长即判定链路已废）")
    }

    private func checkInboundSilence() {
        let ago = Date().timeIntervalSince(lastInboundAt)
        guard InboundSilence.isStale(lastInboundAgo: ago,
                                     linkEstablished: linkEstablished,
                                     linkDead: linkDead,
                                     timeout: inboundSilenceTimeout) else { return }
        log("[MWB] ✗ " + InboundSilence.explain(silentFor: ago, timeout: inboundSilenceTimeout))
        // 复用**完全相同**的降级路径（交回控制权 + 停鼠标发送线程 + 自动重连）。
        // 不另立新路，是为了让「半开」与「读侧收到 EOF」这两种断链表现完全一致。
        handleLinkDead("对端静默 \(Int(ago))s（半开连接）")
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
            // ★ origin = .clipboardAnnounce：对端宣布的是**剪贴板内容**。
            //   若它把图片当文件发（微信输入法等剪贴板管理器会把图片落成临时 PNG），
            //   我们按图片收进剪贴板，而不是扔到桌面（见 `PayloadOrigin`）。
            switch ch.fetchPayload(from: self.host, postAction: .other, origin: .clipboardAnnounce) {
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
        // 把目标 ID 一并打出来：这是**定向包**，`Des` 必须是学到的对端 MachineID，
        // 广播 0xFF 对端不认（§7.19 身份三项）。排查"交给控制权后对端没反应"时，
        // 第一眼就该看这里的 des 是 0xFF 还是真实 ID。
        let targetDesc = (target == 0xFF) ? "0xFF(广播)"
                                          : "0x" + String(target, radix: 16)
        log("[MWB] [剪贴板] 控制权交给 Windows → 补发 MachineSwitched(77) des=\(targetDesc)"
            + (lastBigClipboardBeatAt != nil ? "（本机有刚复制的大载荷，等它回连 15100 拉）" : ""))
        if case .failure(let e) = connection.send(p) { handleSendFailure(e) }
    }

    private func startReturnListener(machineID: UInt32) {
        let lis = MWBListener(port: port, securityKey: securityKey, machineName: connection.machineName)
        lis.onLog = { [weak self] s in self?.log("[MWB] \(s)") }
        lis.onPeerConnected = { [weak self] conn in
            conn.onLog = { [weak self] s in self?.log("[MWB] \(s)") }
            // ⚠️ 必须 weak conn：conn 自己持有这个闭包，强捕获就是循环引用。
            conn.onPacket = { [weak self, weak conn] p in
                guard let self, let conn else { return }
                self.handle(p, from: conn)
            }
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
        // 跨屏待机唤醒：显式属性 > 环境变量 > 默认关（保持历史行为，别悄悄改用户的耗电习惯）。
        // 开启后：持有「阻止系统空闲睡眠」断言（屏幕照常熄灭省电）+ 远端键鼠包到达时点亮屏幕。
        let standbyOn = preferredStandbyWake ?? (env["MWB_STANDBY_WAKE"] == "1")
        let standbyACOnly = preferredStandbyWakeACOnly ?? (env["MWB_STANDBY_AC_ONLY"] != "0")
        standby.log = { [weak self] s in self?.log(s) }
        standby.configure(enabled: standbyOn, acOnly: standbyACOnly)
        // 登记本 Client 为"活跃持有者"：断言只在**至少有一个连接在线**时才持有 ——
        // 全部断开后要还系统一个正常的睡眠策略。
        standby.setActive(true, from: self)
        log("[MWB] 待机唤醒=\(standbyOn ? "开" : "关")"
            + (standbyOn ? "（\(standbyACOnly ? "仅插电时生效" : "电池也生效")）"
                          + " —— 屏幕熄灭后系统不进入空闲睡眠，Windows 鼠标晃过来即刻点亮"
                          + "；注意：手动睡眠 / 合盖 仍是真挂起，那只能靠有线 WoL"
                         : " —— 屏幕熄灭一段时间后系统会正常深度睡眠（此状态下收不到任何网络包）"))

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

        // 「鼠标包发送率」日志里追加**真实投递**统计（造帧 vs 实发 vs 积压 vs 线程存活）。
        // 这一段是 2026-09-19 那个 bug 的直接产物：当时日志只看得到造帧数（100Hz+），
        // 完全看不出"一帧都没发出去"，排查绕了很大一圈。
        input.mouseDeliveryProbe = { [weak self] in
            guard let self else { return "" }
            let sub = self.mouseMailbox.submitted
            let sen = self.mouseMailbox.sent
            let dSub = sub - self.mouseStatSubmitted
            let dSent = sen - self.mouseStatSent
            self.mouseStatSubmitted = sub
            self.mouseStatSent = sen
            return " ｜ 信箱投递 \(dSub) 实发 \(dSent)"
                 + (self.mouseMailbox.isPending ? " 积压=有(1帧)" : " 积压=无")
                 + (self.mouseSenderAlive ? "" : " ⚠️发送线程已停")
        }

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
        // ★★ 第一件事：把它标成**终态** ★★
        //
        // 必须放在最前面（而不是等到末尾），因为下面每一句都可能触发回调：
        //   · `connection.send(byeBye)` 失败 → `handleLinkDead`；
        //   · `connection.close()` → 读侧 EOF → `onDisconnected` → `handleLinkDead`；
        // 而 `handleLinkDead` 的下一步就是 `scheduleReconnect()`。
        // 终态标志先落上，三处闸门（scheduleReconnect / retryNow / handleLinkDead）立刻生效，
        // 才不会再出现"刚 stop 就又给自己排了一次重连"。
        let alreadyStopped = stopped
        stopped = true
        if !alreadyStopped {
            log("[MWB] 客户端已 stop()（终态）：不再重连、不再收包、不再持有资源")
        }

        // ① 先停鼠标发送线程：否则 ByeBye 之后还可能冒出一帧过期位置，
        //    对端会看到一个"已经道别了还在动"的机器。
        stopMouseMoveSender()
        // 哨兵也一起停：`linkDead = true` 之后它本来就不会重启线程，
        // 但留着一个每秒跑的空定时器没有意义（下次 run() 会重新起）。
        mouseSupervisor?.cancel()
        mouseSupervisor = nil

        // ★ 时间源一并收掉：心跳 / 入站静默看门狗 / 连接阶段看门狗。
        //   过去这三个没管 —— 已 stop 的 Client 会继续发心跳、继续判"对端静默"，
        //   判死后调 `handleLinkDead`（现在被 `stopped` 闸住，但定时器本身也不该留着）。
        //   这属于僵尸客户端的"资源尾巴"，一并清掉。
        heartbeatSource?.cancel()
        heartbeatSource = nil
        inboundSilenceWatchdog?.cancel()
        inboundSilenceWatchdog = nil
        connectWatchdog?.cancel()
        connectWatchdog = nil

        // 注销本 Client：**全部**连接都下线后守护才会撤下断言（把正常睡眠策略还给系统）。
        // 这里刻意不调 `standby.stop()` —— 启动时可能还有另一个 Client 在线，
        // 无条件 stop 会把它的断言一起撤掉（2026-09-19 实测到两个 Client 并存）。
        standby.setActive(false, from: self)

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

        // ③ 停止接受回连，并把已经收下的回连一起关掉。
        //    不这么做的话：用户断开后 Windows 还会回连进来，挂在一条"已停用客户端"上
        //    （对象被监听器持有 → fd 不回收），而 Windows 那边会以为会话还在。
        listener?.stop()
        listener = nil

        // ④ 立刻关掉 socket：让对端马上看到 FIN，而不是等它的超时。
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

    /// `conn` = 收到这个包的那条连接。同一个 `MWBClient` 可能同时有两条活跃连接
    /// （出站主连 + Windows 回连进来的那条），剪贴板分片缓冲必须**按连接隔离**，
    /// 否则两条连接的分片会交错，且并发写同一数组会堆破坏（见 `ClipboardSync.batches`）。
    private func handle(_ p: DataPacket, from conn: MWBConnection) {
        // ★★ 收到**任何**入站包就刷新静默计时器 —— 这是半开连接看门狗的唯一输入。
        //    放在最前面：无论这个包后面走哪个分支、甚至解包失败，都说明"对端还活着"。
        lastInboundAt = Date()
        noteInbound()      // 链路探针：用 MWB 自己的 TCP 流的到达节奏量链路抖动
        if verbose {
            log("[MWB] ← type=\(p.type) id=\(p.id) src=\(p.src) des=\(p.des) name='\(p.machineName)'")
        }
        // 对端发来的每个包都带着它的机器 ID，顺手记下来。
        // 文件拖放要用它当定向包的目标：PowerToys 的 DragDropStep08_2 要求
        // `package.Des == 自己的 MachineID` 才认，用 0xFF 广播是无效的。
        //
        // ⚠️ 但**握手期的 `Handshake(126)` / `Hi(2)` 不能信**：它们的 `Src` 是**随机模板值**
        //    （本次日志实证：同一台 Windows 连续三次握手给出 0xace667cc / 0xad52e65e / 0xddcf05a7，
        //     三个都不一样；真 MachineID 只在 `HandshakeAck.Src` 里，= 0x307e878d）。
        //    早先这里"见包就学"，于是每次重连后 `peerID` 都会被学成垃圾值 ——
        //    而它是**定向包的唯一目标**（`ClipboardDragDropOperation(75)` 与
        //    `handedControlToRemote()` 发的 `MachineSwitched(77)` 都要求 `Des == 对端真 ID`，
        //    广播 0xFF 无效，见 §7.19 身份三项）⇒ 重连后的一段时间里拖放 / >1MB 剪贴板会**静默失效**，
        //    直到下一次心跳把 peerID 纠正过来。心跳与绝大多数包带的都是真 ID，所以这个坑一直被掩盖。
        let srcIsTrustworthy = p.type != .handshake && p.type != .hi
        if srcIsTrustworthy, p.src != 0, p.src != 0xFF, p.src != connection.myID {
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
            // 跨屏待机唤醒：屏幕若已熄灭，这一包就是"把屏幕叫醒"的信号。
            // 放在所有分支之前 —— 即便是投放态收尾包 / 被"我方在控制远端"守卫丢弃的包，
            // 都足以说明"对面有人在动鼠标"，该把屏幕点亮（见 StandbyGuard）。
            standby.noteRemoteActivity()
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
            // 键盘包同样算"远端有人在操作" —— 屏幕上没接麦克风/鼠标也能被键盘叫醒。
            standby.noteRemoteActivity()
            input.injectKeyboard(vk: p.keyVk, flags: p.keyFlags)

        case PackageType.clipboardText.rawValue:
            // 远端剪贴板文本分片（每片 48 字节，铺在 byte16..63）
            clipboard.appendRemoteChunk(p.raw48, isImage: false, source: conn)

        case PackageType.clipboardImage.rawValue:
            // 远端剪贴板图片分片：同样是 byte16..63 铺 48 字节，但载荷是 **PNG 原始字节**，
            // 不能拿去当文本解压 —— 用 isImage 标记分开累积，到 ClipboardDataEnd 再走图片分支。
            clipboard.appendRemoteChunk(p.raw48, isImage: true, source: conn)

        case PackageType.clipboardDataEnd.rawValue:
            // 结束标记 —— 到这一刻才按批次类型整体处理（图片解码 / 文本解压拆包）
            clipboard.finishRemote(source: conn)

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

    // MARK: - 自检：`stop()` 必须是终态（回归 2026-10-08 僵尸重连洪水）

    /// 【它回答什么】调用 `stop()` 之后，这个 Client 到底还会不会偷偷重连？
    ///
    /// 【回归对象】`stop()` 过去用 `linkDead = true` 表达"停用"，而 `scheduleReconnect()`
    ///   的延时块恰好用 `linkDead == true` 作为**放行**条件（`guard self.linkDead else { return }`）
    ///   —— 两处语义撞车 ⇒ `stop()` 不但没停掉已排好的重连，反而正好给它放行。
    ///   面板上每点一次「连接」都会 `connect()` 新建 Client 并 `stop()` 旧的，于是旧 Client
    ///   变成**永不停止的僵尸重连循环**。实测（`/tmp/mwb_gui.log`）：13 次点击 → 12 条僵尸，
    ///   12:25:17→12:30:57 共 **924** 次 TCP connect 尝试（≈2.3 次/秒）。
    ///
    /// 【判据】
    ///   ① 首连失败后**必须真的进入重连循环**（否则这个自检就是空跑，测不出任何东西）；
    ///   ② `stop()` 之后静置 12s（> 2 个探测周期），重连计数**一个都不许涨**；
    ///   ③ 已 `stop()` 的 Client 再 `run()` 必须被拒（终态不可复活）。
    ///
    /// ⚠️ 端口技巧：先自己 `bind()` 一个 socket 但**不 `listen()`**。
    ///   不这么做的话，Client 自己的回连监听会先绑上该端口，我们就会连到"自己"上
    ///   造出一条假连接（握手上挂 8 秒），自检既慢又不确定。bind 不 listen ⇒
    ///   对端内核直接回 RST ⇒ `connectFailed` 立刻返回。
    public static func zombieStopSelfTest() -> Never {
        let port: UInt16 = 54991

        // 占位 socket：只 bind，不 listen。
        let guardFD = socket(AF_INET, SOCK_STREAM, 0)
        var reuse: Int32 = 1
        _ = setsockopt(guardFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(guardFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bound != 0 {
            print("⚠️ 占位端口 \(port) bind 失败（errno=\(errno)）—— 若该端口恰好有人在监听，结论不可靠")
        }

        var pass = 0, total = 0
        var fails: [String] = []
        func check(_ ok: Bool, _ desc: String) {
            total += 1
            if ok { pass += 1 } else { fails.append(desc) }
        }
        func finish() {
            if guardFD >= 0 { close(guardFD) }
            print("僵尸重连自检（回归「stop() 之后旧 Client 仍在偷偷重连」）")
            for f in fails { print("  ✗ \(f)") }
            print("\n结果: \(pass)/\(total) 通过")
            exit(fails.isEmpty ? 0 : 2)
        }

        let client = MWBClient(host: "127.0.0.1", port: port,
                               securityKey: "zombie-selftest", machineName: "zombie-selftest")
        let runResult = client.run()
        var runOK = false
        if case .success = runResult { runOK = true }
        check(runOK, "首连失败时 run() 仍应返回 .success（语义=客户端已启动）")

        let firstDeadline = Date().addingTimeInterval(8)
        func waitForFirstAttempt() {
            if client.reconnectAttemptsTotal < 1 && Date() < firstDeadline {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { waitForFirstAttempt() }
                return
            }
            let before = client.reconnectAttemptsTotal
            check(before >= 1,
                  "首连失败后应真的进入重连循环（实测 \(before) 次；为 0 说明本自检在空跑）")

            client.stop()

            // 静置 12s（≥2 个 5s 轻量探测周期）。是僵尸的话这里必然继续涨。
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
                let after = client.reconnectAttemptsTotal
                check(after == before,
                      "stop() 之后不得再有任何重连尝试（stop 前 \(before) → stop 后 \(after)）")

                var refused = false
                if case .failure = client.run() { refused = true }
                check(refused, "已 stop() 的 Client 再 run() 必须失败（终态不得复活）")

                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    let after2 = client.reconnectAttemptsTotal
                    check(after2 == before,
                          "被拒的 run() 之后也不得重连（\(before) → \(after2)）")
                    finish()
                }
            }
        }
        waitForFirstAttempt()

        // 只跑主队列：本自检里的等待与 `scheduleReconnect()` 的延时块都走主队列。
        dispatchMain()
    }
}
