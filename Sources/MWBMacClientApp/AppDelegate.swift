// AppDelegate.swift
// 菜单栏应用：状态项 + 弹出面板 + 连接状态管理 + 配置持久化。

import AppKit
import SwiftUI
import Combine
import Darwin
import SystemConfiguration
import MWBMacClientCore

private let UD = UserDefaults.standard
private enum K {
    static let host = "host", port = "port", key = "securityKey", name = "machineName"
    static let edge = "edge", rw = "remoteW", rh = "remoteH"
    static let filePort = "filePort", fileEnabled = "fileEnabled"
    static let dock = "dropDock", clipFile = "clipboardFile", auto = "autoConnect"
    static let proportional = "proportionalMapping"
    static let slot = "matrixSlot"
    static let lockCursor = "lockCursorWhileRemote"
}

final class AppState: ObservableObject {

    // MARK: - 持久化配置

    @Published var host: String            { didSet { UD.set(host, forKey: K.host) } }
    @Published var portText: String        { didSet { UD.set(portText, forKey: K.port) } }
    @Published var securityKey: String     { didSet { UD.set(securityKey, forKey: K.key) } }
    @Published var machineName: String     { didSet { UD.set(machineName, forKey: K.name) } }
    @Published var edge: SwitchEdge        { didSet { UD.set(edge.rawValue, forKey: K.edge) } }
    @Published var remoteW: String         { didSet { UD.set(remoteW, forKey: K.rw) } }
    @Published var remoteH: String         { didSet { UD.set(remoteH, forKey: K.rh) } }
    @Published var filePortText: String    { didSet { UD.set(filePortText, forKey: K.filePort) } }
    @Published var dropDockEnabled: Bool   { didSet { UD.set(dropDockEnabled, forKey: K.dock) } }
    @Published var clipboardFileEnabled: Bool { didSet { UD.set(clipboardFileEnabled, forKey: K.clipFile) } }
    /// 启动后自动连接
    @Published var autoConnect: Bool { didSet { UD.set(autoConnect, forKey: K.auto) } }
    /// 位移映射：true = 按本机屏幕比例（协议原生做法，不用管对端分辨率）；
    /// false = 按对端像素 1:1（需要填对端真实分辨率）。
    @Published var proportionalMapping: Bool { didSet { UD.set(proportionalMapping, forKey: K.proportional) } }
    /// 本机在 MWB 机器矩阵里的槽位："auto"（自动，由 Windows 下发的布局学习）或 "1".."4"。
    @Published var slotText: String { didSet { UD.set(slotText, forKey: K.slot) } }
    /// 控制 Windows 期间把本机光标钉在屏幕边缘（实测唯一有效的锁定方式）。
    @Published var lockCursorWhileRemote: Bool { didSet { UD.set(lockCursorWhileRemote, forKey: K.lockCursor) } }

    // MARK: - 运行状态

    @Published var connected = false
    @Published var connecting = false
    @Published var statusText = "未连接"
    @Published var axTrusted = AXIsProcessTrusted()
    /// 事件捕获是否真正建立成功 —— 这才是「能否跨屏」的真实判据。
    /// AXIsProcessTrusted() 只覆盖「辅助功能」，而 CGEventTap 还需要「输入监控」，
    /// 两者缺一 tap 都会创建失败，因此以实际 tap 状态为准。
    @Published var captureOK = false
    /// 当前控制权是否交给了远端（Windows）。
    @Published var controllingRemote = false
    /// tap 已实际收到的本地输入事件数 —— 判断「输入监控」是否真生效的唯一硬指标。
    @Published var tapEvents: Int64 = 0
    /// tap 已收到的键盘类事件数。「鼠标事件在涨、这个是 0」= 输入监控未生效。
    @Published var keyEvents: Int64 = 0
    /// 「输入监控」授权是否已生效 —— macOS 上键盘事件走这一项，是键盘能否跨屏的唯一开关。
    @Published var inputMonitoringOK = CGPreflightListenEventAccess()
    /// 机器矩阵快照：最多 4 台机器的槽位与联机状态。
    @Published var matrix: MatrixSnapshot?
    @Published var logLines: [String] = []
    /// 日志窗口是否自动滚到底部（独立日志窗口用）。
    @Published var logAutoScroll = true

    private var client: MWBClient?
    private var pollTimer: Timer?

    init() {
        // 首次运行给一组可直接用的默认值，之后一律读回上次的设置
        func localName() -> String {
            if let ln = SCDynamicStoreCopyLocalHostName(nil) as String?, !ln.isEmpty { return ln }
            var buf = [CChar](repeating: 0, count: 256)
            if gethostname(&buf, buf.count) == 0 {
                var h = String(cString: buf)
                if h.hasSuffix(".local") { h = String(h.dropLast(6)) }
                return h.replacingOccurrences(of: " ", with: "-")
            }
            return "Mac"
        }
        self.host         = UD.string(forKey: K.host) ?? ""
        self.portText     = UD.string(forKey: K.port) ?? "15101"
        self.securityKey  = UD.string(forKey: K.key) ?? ""
        self.machineName  = UD.string(forKey: K.name) ?? localName()
        self.edge         = SwitchEdge(rawValue: UD.string(forKey: K.edge) ?? "right") ?? .right
        self.remoteW      = UD.string(forKey: K.rw) ?? "1920"
        self.remoteH      = UD.string(forKey: K.rh) ?? "1080"
        // 留空 = 自动用「主通道端口 - 1」（MWB 原生剪贴板/文件通道，15100）。
        // 旧的 15110 是历史自建协议端口，留着会覆盖自动推导，必须迁移掉。
        if let legacy = UD.string(forKey: K.filePort), legacy == "15110" {
            UD.removeObject(forKey: K.filePort)
        }
        self.filePortText = UD.string(forKey: K.filePort) ?? ""
        self.dropDockEnabled      = UD.object(forKey: K.dock) == nil ? true : UD.bool(forKey: K.dock)
        self.clipboardFileEnabled = UD.object(forKey: K.clipFile) == nil ? true : UD.bool(forKey: K.clipFile)
        self.autoConnect = UD.bool(forKey: K.auto)
        self.proportionalMapping = UD.object(forKey: K.proportional) == nil
            ? true : UD.bool(forKey: K.proportional)
        self.slotText = UD.string(forKey: K.slot) ?? "auto"
        self.lockCursorWhileRemote = UD.object(forKey: K.lockCursor) == nil
            ? true : UD.bool(forKey: K.lockCursor)
    }

    // MARK: - 日志

    /// 日志同时落一份到 /tmp/mwb_gui.log，方便从终端 tail 排查
    private let logFile = URL(fileURLWithPath: "/tmp/mwb_gui.log")
    private let logQueue = DispatchQueue(label: "mwb.log.file")
    private static let logTime: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()

    func appendLog(_ s: String) {
        // 带毫秒时间戳：排查「切过去又被立刻踢回」这类时序问题时没有时间戳根本看不出来
        let line = "[\(Self.logTime.string(from: Date()))] \(s)"
        DispatchQueue.main.async {
            self.logLines.append(line)
            if self.logLines.count > 200 { self.logLines.removeFirst(self.logLines.count - 200) }
        }
        logQueue.async {
            guard let d = (line + "\n").data(using: .utf8) else { return }
            if let fh = try? FileHandle(forWritingTo: self.logFile) {
                fh.seekToEndOfFile(); fh.write(d); try? fh.close()
            } else {
                try? d.write(to: self.logFile)
            }
        }
    }

    /// 等待日志队列把已排队的行全部落盘。
    ///
    /// 【为什么必须有】`appendLog` 是**异步**写盘（`logQueue.async`）。退出路径
    /// （SIGTERM 处理器）在记录完最后一波日志后立刻 `exit(0)`，进程会当场消失，
    /// 队列里没跑完的块全部丢失 —— 实测：退出时 `[GUI] 收到退出信号` 能看到，
    /// 紧跟着 `[MWB] 已向对端发送 ByeBye` 却**永远看不到**，让人误以为 ByeBye 没发。
    /// 退出前 `sync` 一次（barrier 语义）即可保证最后一波日志完整。
    func flushLog() { logQueue.sync {} }

    /// 启动时轮转日志：旧的一份挪到 `/tmp/mwb_gui.prev.log`（只留一代），再开新日志。
    ///
    /// 2026-09-14 加：原先启动时直接清空日志，结果一次重启就把用户刚做完的
    /// 「Win→Mac 拖放失败」实测记录整段抹掉，排查只能重来一遍。
    fileprivate func rotateLogOnStart() {
        let fm = FileManager.default
        let prev = URL(fileURLWithPath: "/tmp/mwb_gui.prev.log")
        try? fm.removeItem(at: prev)
        if fm.fileExists(atPath: logFile.path) {
            try? fm.moveItem(at: logFile, to: prev)
        }
        try? Data().write(to: logFile)
    }

    // MARK: - 连接控制

    func connect() {
        guard let port = UInt16(portText), !host.isEmpty, !securityKey.isEmpty else {
            statusText = "请先填写 Windows 主机 IP 与安全密钥"
            return
        }
        axTrusted = AXIsProcessTrusted()
        connecting = true
        statusText = "连接中…"
        logLines.removeAll()

        // 注意：所有配置要在 run() 之前设好 —— run() 内部会据此建立连接
        let c = MWBClient(host: host, port: port, securityKey: securityKey, machineName: machineName)
        c.preferredEdge = edge
        // 位移映射方式：默认按本机屏幕比例（协议原生，与对端分辨率无关）
        c.preferredMotionScale = proportionalMapping ? .proportional : .pixelExact
        // 控制远端时把本机光标钉在屏幕边缘
        c.preferredLockCursor = lockCursorWhileRemote
        if let w = Double(remoteW), let h = Double(remoteH), w > 0, h > 0 {
            c.preferredRemoteSize = CGSize(width: w, height: h)
        }
        c.fileHostOverride = host
        // 空字符串 -> nil，交给 Client 自动推导 clipPort = 主通道端口 - 1
        c.filePortOverride = UInt16(filePortText.trimmingCharacters(in: .whitespaces))
        c.dropDockEnabled = dropDockEnabled
        c.clipboardFileEnabled = clipboardFileEnabled
        // 本机矩阵槽位：auto = 由 Windows 下发的布局学习；指定 1..4 则按槽位上报
        c.preferredSlot = UInt32(slotText)
        // 机器矩阵（4 个联机状态）变化 -> 刷新面板
        c.onMatrixChanged = { [weak self] in
            DispatchQueue.main.async { self?.matrix = c.matrix.snapshot() }
        }
        c.onLog = { [weak self] s in
            self?.appendLog(s)
            // 关键状态同步到 UI 顶部
            if s.contains("双向认证完成") { DispatchQueue.main.async { self?.peerName = extractName(s) } }
            if s.contains("[文件]") { DispatchQueue.main.async { self?.fileActivity = s } }
        }

        c.onCaptureStatus = { [weak self] ok, msg in
            DispatchQueue.main.async { self?.captureOK = ok }
        }

        // 链路看门狗：断链时 Client 已自动把控制权交回本机并开始重连，
        // 这里只负责把状态反映到面板上（否则用户会以为"鼠标卡在 Windows 里"）。
        c.onLinkDown = { [weak self] reason in
            DispatchQueue.main.async {
                self?.connected = false
                self?.controllingRemote = false
                self?.statusText = reason
                self?.appendLog("[GUI] 链路断开：\(reason)")
            }
        }
        c.onLinkUp = { [weak self] in
            DispatchQueue.main.async {
                self?.connected = true
                self?.statusText = "已重新连接"
                self?.appendLog("[GUI] 链路已恢复")
            }
        }

        // 控制权切换 -> 面板顶部状态实时反映「本机 / Windows」
        c.input.onSwitchChanged = { [weak self] remote in
            DispatchQueue.main.async { self?.controllingRemote = remote }
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.appendLog("[GUI] 开始连接 \(port) …")
            let result = c.run()
            DispatchQueue.main.async {
                self?.connecting = false
                switch result {
                case .success:
                    self?.client = c
                    self?.connected = true
                    self?.startHealthPolling()
                    self?.matrix = c.matrix.snapshot()
                    self?.statusText = "已连接 \(self?.peerName ?? "")"
                    self?.appendLog("[GUI] 连接成功")
                case .failure(let e):
                    self?.connected = false
                    self?.statusText = "连接失败: \(e)"
                    self?.appendLog("[GUI] 连接失败: \(e)")
                }
            }
        }
    }

    func disconnect() {
        pollTimer?.invalidate(); pollTimer = nil
        // 断开前必须恢复光标联动，否则解耦状态下光标会推不动
        client?.stop()
        client?.connection.close()
        client = nil
        connected = false
        controllingRemote = false
        tapEvents = 0
        keyEvents = 0
        matrix = nil
        peerName = ""
        statusText = "已断开"
    }

    /// 退出 App。
    /// 顺序很重要：先断开 + 恢复光标联动，再 terminate ——
    /// 处于「已解耦」状态退出会让用户的光标推不动，只能注销/重启才能恢复。
    func quit() {
        appendLog("[GUI] 退出 MWB")
        disconnect()
        InputController.shared.releaseCursor()
        NSApp.terminate(nil)
    }

    /// 轮询捕获健康度：让面板能显示「到底有没有真的收到本地输入事件」。
    /// 授权界面里勾了不代表生效 —— 事件数为 0 就一定是 permissions 没落到这个二进制上。
    private func startHealthPolling() {
        DispatchQueue.main.async {
            self.pollTimer?.invalidate()
            self.pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
                guard let self, let c = self.client else { return }
                let h = c.input.captureHealth()
                let snap = c.matrix.snapshot()
                let listening = CGPreflightListenEventAccess()
                DispatchQueue.main.async {
                    self.tapEvents = h.events
                    self.keyEvents = h.keyEvents
                    self.matrix = snap          // 在线/离线是时间相关的，周期刷新
                    self.inputMonitoringOK = listening
                }
            }
        }
    }

    /// 用户勾完权限后不必重启 App —— 直接重建事件捕获即可。
    func retryCapture() {
        axTrusted = AXIsProcessTrusted()
        guard let c = client else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            c.retryCapture()
        }
    }

    /// 光标锁定自检（**不需要连接 Windows**）。
    /// 把本机光标钉在当前点 6 秒，期间应用会自己模拟鼠标乱动，最后给出 ✅/❌ 结论。
    /// 兜底接线：让核心层（InputController）的诊断日志一定能落到 GUI 日志里。
    ///
    /// 只在没人接线时生效。正常连接时由 `Client.configureInput()` 接（那条路径也写日志），
    /// 但自检/快照这类"不连接就跑"的场景没有连接过程 —— 不兜底的话诊断日志会全丢。
    /// 2026-09-14 的跨屏自检就踩过这个坑：自检确实跑了、也打了结论，
    /// 但一行都没落盘，看起来像"自检根本没执行"。
    func wireCoreLogging() {
        if InputController.shared.onDiagnostic == nil {
            InputController.shared.onDiagnostic = { [weak self] s in self?.appendLog(s) }
        }
    }

    func runCursorLockSelfTest(anchorOverride: CGPoint? = nil, keepSending: Bool = false) {
        let anchorDesc = anchorOverride.map { " 锚点=预置(\(Int($0.x)),\(Int($0.y)))" } ?? " 锚点=当前光标位置"
        appendLog("[GUI] 光标锁定自检：开始（6 秒，应用会自己投递移动事件模拟鼠标乱动）"
                  + anchorDesc
                  + (keepSending ? " 发包=开（复现真实跨屏负载）" : " 发包=关"))
        wireCoreLogging()
        DispatchQueue.main.async {
            let ok = InputController.shared.startCursorLockSelfTest(seconds: 6,
                                                                   anchorOverride: anchorOverride,
                                                                   keepSending: keepSending)
            if !ok {
                self.appendLog("[GUI] 自检无法开始：事件捕获没建立（缺「辅助功能 / 输入监控」授权）")
                return
            }
            if !keepSending {
                self.controllingRemote = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 6.3) {
                    if !self.connected { self.controllingRemote = false }
                }
            }
        }
    }

    @Published var peerName: String = ""
    @Published var fileActivity: String = ""

    /// 跨屏自检（**不需要连接 Windows**）。
    ///
    /// 用合成事件复现「从边缘滑出去 → 只浅浅深入一段 → 再推回本机」这条路径，
    /// 并检查"交回本机后压住边缘不会被立刻弹回对端"。
    /// 用来当场验证「鼠标过去之后回不来」这类**几何 + 时序**问题。
    func runSwitchSelfTest() {
        appendLog("[GUI] 跨屏自检：开始（约 1.5 秒，期间请**别动鼠标**）")
        wireCoreLogging()
        DispatchQueue.main.async {
            let ok = InputController.shared.startSwitchSelfTest()
            if !ok {
                self.appendLog("[GUI] 跨屏自检无法开始：事件捕获没建立（缺「辅助功能 / 输入监控」授权）")
            }
        }
    }

    func openAccessibilitySettings() {
        // 用系统权限请求 API：会弹出官方授权对话框，用户确认后系统自动把本 app 加进列表
        if !AXIsProcessTrusted() { _ = CGRequestPostEventAccess() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            self.axTrusted = AXIsProcessTrusted()
            NSWorkspace.shared.open(
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
    }

    func openInputMonitoringSettings() {
        // 输入监控没有「已授权」的独立查询，用 preflight 判断并请求
        if !CGPreflightListenEventAccess() { _ = CGRequestListenEventAccess() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            self.axTrusted = AXIsProcessTrusted()
            NSWorkspace.shared.open(
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
        }
    }
}

private func extractName(_ s: String) -> String {
    // 形如 "[MWB] [握手] 双向认证完成 ✓  对端机器名 = MyPC"
    if let r = s.range(of: "=") { return String(s[r.upperBound...]).trimmingCharacters(in: .whitespaces) }
    return ""
}

// MARK: - 菜单栏

final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // 纯菜单栏应用，不占 Dock
        installMainMenu()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = item.button {
            btn.image = menuIcon()
            btn.image?.isTemplate = true
            btn.toolTip = "Mouse Without Borders"
            btn.action = #selector(togglePopover(_:))
            btn.target = self
            btn.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item

        popover.contentViewController = NSHostingController(rootView: ContentView(state: state))
        popover.behavior = .transient

        // 状态变化时刷新菜单栏图标
        state.$connected.sink { [weak self] on in
            DispatchQueue.main.async { self?.statusItem?.button?.image = self?.menuIcon(on) }
        }.store(in: &cancellables)

        // 启动日志每次重开。⚠️ 但**不能直接清空** —— 2026-09-14 踩过这个坑：
        // 重启应用把用户上一次实测的日志整段抹掉，而那正是要排查的那一次（拖放失败）。
        // 改成"轮转一代"：旧日志挪到 /tmp/mwb_gui.prev.log，再开新日志。
        state.rotateLogOnStart()
        // 立刻把核心层的诊断出口接上：自检/快照等"不连接就跑"的场景没有连接过程，
        // 不在这里兜底的话，那些诊断日志会一行都落不了盘。
        state.wireCoreLogging()
        // 未授权时直接调用系统权限请求 API —— 会弹出官方授权对话框，
        // 用户点「打开系统设置」后系统会**自动把本 app 加入列表**，
        // 比让用户在列表里手动找／手动 + 添加可靠得多。
        //   CGRequestPostEventAccess  → 辅助功能（发送键鼠事件）
        //   CGRequestListenEventAccess→ 输入监控（捕获键鼠事件）
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            if !AXIsProcessTrusted() { _ = CGRequestPostEventAccess() }
            if !CGPreflightListenEventAccess() { _ = CGRequestListenEventAccess() }
            self?.state.axTrusted = AXIsProcessTrusted()
        }

        // 自检/快照模式下不自动连接 —— 避免连接状态干扰自检判定。
        // 例外：MWB_CURSOR_SELFTEST=send 需要**真的连上**才能复现"边发包边控制"的负载，
        // 所以那种情况下要放行 autoConnect。
        let cursorSelftestRaw = ProcessInfo.processInfo.environment["MWB_CURSOR_SELFTEST"]?.lowercased() ?? ""
        let cursorSelftestWantsConnection = cursorSelftestRaw.contains("send")
        let debugMode = (ProcessInfo.processInfo.environment["MWB_CURSOR_SELFTEST"] != nil
                            && !cursorSelftestWantsConnection)
            || ProcessInfo.processInfo.environment["MWB_SWITCH_SELFTEST"] != nil
            || ProcessInfo.processInfo.environment["MWB_RENDER_PANEL"] != nil
        if state.autoConnect && !debugMode {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.state.connect()
            }
        }

        // 协议自测：MWB_AUTOCONNECT=host:port（可配 MWB_KEY=<配对码>）启动即自动连接。
        //
        // 【为什么需要它】链路看门狗 / 自动重连这类逻辑只有在"连上之后对端突然消失"
        // 的场景里才会跑，而真实 Windows 端不一定随时在线（2026-09-14 排障时它就不通）。
        // 配合本仓库 CLI 的 `mwbmac --listen`（纯监听模式），就能在**完全本机**的环境里
        // 跑通「连上 → 断链 → 看门狗交回控制权 → 自动重连 → 恢复」整条链路，
        // 不必依赖对端机器在线。
        if let spec = ProcessInfo.processInfo.environment["MWB_AUTOCONNECT"] {
            let parts = spec.split(separator: ":")
            if let h = parts.first, !h.isEmpty {
                state.host = String(h)
                if parts.count > 1, let p = UInt16(parts[1]) { state.portText = String(p) }
                if let k = ProcessInfo.processInfo.environment["MWB_KEY"] { state.securityKey = k }
                state.appendLog("[GUI] MWB_AUTOCONNECT=\(spec) → 将于 1.5s 后自动连接")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    self?.state.connect()
                }
            }
        }

        // 自检模式：MWB_CURSOR_SELFTEST=<值> 启动时自动跑一次光标锁定自检
        // （给自动化验证和「一句话就能复现」用）。
        //
        // 值可以是这几个关键字的组合（大小写不敏感）：
        //   =1      锚点=当前光标位置，不发包
        //   =edge  先把光标挪到**屏幕左边缘**再取锚点 —— 复现真实跨屏条件（锚点 x≈0）
        //   =send  **保留发包**并自动连接 Windows —— 复现真实跨屏负载
        //          （★ 最重要：默认自检不发包，测不出"tap 被系统禁用"这一类成因）
        //
        // 配合 MWB_SELFTEST_EXIT=1 就能无人值守拿到结论。
        if let raw = ProcessInfo.processInfo.environment["MWB_CURSOR_SELFTEST"] {
            let v = raw.lowercased()
            let keepSending = v.contains("send")
            // 锚点预置（CG 坐标，左上原点）。用来做"锚点位置"的对照实验：
            //   edge    → 屏幕左边缘（x=0，复现真实跨屏）
            //   edgeN   → 左边缘 + 内缩 N px（二分定位是否边界坐标本身的问题）
            //   center  → 屏幕中央（对照组）
            //   x=N[,M] → 直接指定坐标
            let frame = CGDisplayBounds(CGMainDisplayID())
            let cur = CGEvent(source: nil)?.location ?? CGPoint(x: 400, y: 400)
            var anchor: CGPoint? = nil
            if v.contains("center") {
                anchor = CGPoint(x: frame.midX, y: frame.midY)
            } else if let r = v.range(of: "edge") {
                let rest = v[r.upperBound...].drop(while: { $0 == "=" })
                let n = Double(rest.prefix(while: { $0.isNumber || $0 == "." })) ?? 0
                anchor = CGPoint(x: frame.minX + CGFloat(n), y: cur.y)
            } else if let r = v.range(of: "x=") {
                let rest = v[r.upperBound...]
                let parts = rest.split(separator: ",")
                let nx = Double((parts.first ?? "").prefix(while: { $0.isNumber || $0 == "." })) ?? 0
                let ny = parts.count > 1
                    ? (Double(parts[1].prefix(while: { $0.isNumber || $0 == "." })) ?? Double(cur.y))
                    : Double(cur.y)
                anchor = CGPoint(x: CGFloat(nx), y: CGFloat(ny))
            }
            // 发包模式需要真的连上 Windows，所以延后到连接建立之后再跑。
            let delay: Double = keepSending ? 5.0 : 2.0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.state.runCursorLockSelfTest(anchorOverride: anchor, keepSending: keepSending)
            }
            if ProcessInfo.processInfo.environment["MWB_SELFTEST_EXIT"] != nil {
                // 延迟 + 6s 自检 + 余量
                DispatchQueue.main.asyncAfter(deadline: .now() + (keepSending ? 12.5 : 9.5)) { exit(0) }
            }
        }

        // 跨屏切换自检：MWB_SWITCH_SELFTEST=1
        // 用合成事件复现「从边缘滑出去、只浅进一段、再推回来」，
        // 验证"回得来"以及"交回本机后不会被立刻弹回对端"。
        if ProcessInfo.processInfo.environment["MWB_SWITCH_SELFTEST"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                _ = InputController.shared.startSwitchSelfTest()
            }
            if ProcessInfo.processInfo.environment["MWB_SELFTEST_EXIT"] != nil {
                // 2s 延迟 + 1.5s 自检 + 余量
                DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { exit(0) }
            }
        }

        // 调试：MWB_RENDER_PANEL=/path.png 时把配置面板离屏渲染成 PNG。
        // 菜单栏可能被设成自动隐藏（点不到图标），这个开关用来目视检查版式是否完整。
        //
        // 【为什么不用 ImageRenderer】ImageRenderer + @EnvironmentObject 在本机实测
        // 必崩：`Fatal error: No ObservableObject of type AppState found`（8:39 复现）。
        // 改用 NSHostingView —— 它走的是真实视图层级 + 布局管线，环境对象注入可靠，
        // 再用 cacheDisplay 抓成位图。
        //
        // 会产出两张：
        //   <out>                 面板**全部内容**（高度不限）→ 看内容总高，判断会不会显示不全
        //   <out 同目录>/popover.png  真实 Popover（372×≤560）→ 看用户实际所见
        if let out = ProcessInfo.processInfo.environment["MWB_RENDER_PANEL"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self else { return }

                /// 把一个 SwiftUI 视图塞进离屏 NSHostingView，抓成 PNG。
                /// - Parameter intrinsicHeight: true = 高度由内容决定；false = 用 maxHeight 封顶
                @discardableResult
                func snap<V: View>(_ view: V, to path: String, maxHeight: CGFloat) -> CGSize? {
                    let host = NSHostingView(rootView: view)
                    host.frame = NSRect(x: 0, y: 0, width: 372, height: 80)
                    host.layoutSubtreeIfNeeded()
                    let h = min(max(host.fittingSize.height, 80), maxHeight)
                    host.frame = NSRect(x: 0, y: 0, width: 372, height: h)
                    host.layoutSubtreeIfNeeded()

                    // 放进一个不显示的窗口，保证 SwiftUI 真正走上屏管线。
                    let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 372, height: h),
                                       styleMask: [.borderless], backing: .buffered, defer: false)
                    win.contentView = host
                    win.layoutIfNeeded()

                    defer { win.contentView = nil }
                    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                        self.state.appendLog("[GUI] 快照失败：拿不到位图缓存 (\(path))")
                        return nil
                    }
                    host.cacheDisplay(in: host.bounds, to: rep)
                    guard let png = rep.representation(using: .png, properties: [:]) else {
                        self.state.appendLog("[GUI] 快照失败：PNG 编码失败 (\(path))")
                        return nil
                    }
                    do {
                        try png.write(to: URL(fileURLWithPath: path))
                        let size = CGSize(width: host.bounds.width, height: host.bounds.height)
                        self.state.appendLog("[GUI] 快照已写入 \(path) "
                            + "(\(Int(size.width))x\(Int(size.height)))")
                        return size
                    } catch {
                        self.state.appendLog("[GUI] 快照写盘失败 \(path): \(error)")
                        return nil
                    }
                }

                // ① 全部内容（高度给足，看真实总高）
                let full = snap(PanelSnapshot(state: self.state)
                                    .frame(width: 372)
                                    .background(Color(nsColor: .windowBackgroundColor)),
                                to: out, maxHeight: 20_000)
                if let full {
                    self.state.appendLog("[GUI] 面板内容总高 = \(Int(full.height))pt（Popover 上限 560pt）"
                        + (full.height > 560 ? " ⚠️ 超出，需滚动" : " ✅ 可完整显示"))
                }

                // ② 真实 Popover 外观
                let dir = (out as NSString).deletingLastPathComponent
                snap(PopoverSnapshot(state: self.state)
                        .background(Color(nsColor: .windowBackgroundColor)),
                     to: dir + "/popover.png", maxHeight: 560)

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(0) }
            }
        }

        // 调试：MWB_SHOW_PANEL=1 时启动后自动弹出配置面板
        // （菜单栏被设成自动隐藏时没法点图标，这个开关方便目视检查版式）
        if ProcessInfo.processInfo.environment["MWB_SHOW_PANEL"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                self?.togglePopover(nil)
            }
        }

        installSignalHandlers()
    }

    /// 命令行退出（`pkill -x MWBMacClientApp` / `kill`）也必须恢复光标联动。
    ///
    /// 默认 SIGTERM 会直接终止进程，**不走 applicationWillTerminate** ——
    /// 如果当时正处于「已解耦」状态，用户的光标会推不动，只能注销/重启恢复。
    /// 用 DispatchSourceSignal 把处理搬回主队列执行（信号处理函数里不能调用 CG API）。
    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT] {
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in
                self?.state.appendLog("[GUI] 收到退出信号，正在恢复光标联动后退出")
                self?.state.disconnect()
                InputController.shared.releaseCursor()
                // ★ 先把日志队列排空再退：否则上面这几行的落盘会被 exit(0) 掐掉
                //   （曾经因此看不到 ByeBye 的确认，白怀疑了一轮）。
                self?.state.flushLog()
                exit(0)
            }
            src.resume()
            signal(sig, SIG_IGN)   // 交给 DispatchSource 处理，避免默认终止
            signalSources.append(src)
        }
    }

    private var signalSources: [DispatchSourceSignal] = []

    private var cancellables = Set<AnyCancellable>()

    /// 退出时务必恢复「鼠标 → 光标」联动。
    /// 否则 App 在解耦状态被杀掉，用户的光标会推不动，只能注销/重启才能恢复。
    func applicationWillTerminate(_ notification: Notification) {
        MWBMacClientCore.InputController.shared.releaseCursor()
    }

    private func menuIcon(_ on: Bool = false) -> NSImage? {
        let name = on ? "cursorarrow.rays" : "cursorarrow"
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "MWB")
        return img
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let btn = statusItem?.button else { return }
        // 右键直接给快捷菜单（连接/断开 + 退出），不用先开面板再找按钮
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu(from: btn)
            return
        }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            state.axTrusted = AXIsProcessTrusted()
            popover.show(relativeTo: btn.bounds, of: btn, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    // MARK: - 退出 / 菜单

    /// 纯菜单栏（accessory）应用默认没有主菜单，⌘Q 不会生效。
    /// 手工装一个最小主菜单，让 ⌘Q 能正常退出。
    private func installMainMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 MWB",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 MWB", action: #selector(quitApp(_:)), keyEquivalent: "q")
        quit.target = self
        appMenu.addItem(quit)
        appItem.submenu = appMenu
        // 「查看日志」也挂到主菜单，方便 ⌘L 打开独立日志窗口
        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "视图")
        let logsItem = NSMenuItem(title: "查看日志", action: #selector(showLogWindow(_:)), keyEquivalent: "l")
        logsItem.target = self
        viewMenu.addItem(logsItem)
        viewItem.submenu = viewMenu
        NSApp.mainMenu = mainMenu
    }

    private func showContextMenu(from btn: NSStatusBarButton) {
        let menu = NSMenu()
        let toggle = NSMenuItem(title: state.connected ? "断开连接" : "连接到 Windows",
                                action: #selector(ctxToggleConnect(_:)), keyEquivalent: "")
        toggle.target = self
        toggle.isEnabled = !state.connecting
        menu.addItem(toggle)
        menu.addItem(.separator())
        let logs = NSMenuItem(title: "查看日志…", action: #selector(showLogWindow(_:)), keyEquivalent: "l")
        logs.target = self
        menu.addItem(logs)
        let selfTest = NSMenuItem(title: "光标锁定自检（6 秒）",
                                  action: #selector(ctxCursorSelfTest(_:)), keyEquivalent: "")
        selfTest.target = self
        selfTest.isEnabled = !state.connected
        menu.addItem(selfTest)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 MWB", action: #selector(quitApp(_:)), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: btn.bounds.minY - 4), in: btn)
    }

    @objc private func ctxToggleConnect(_ sender: Any?) {
        state.connected ? state.disconnect() : state.connect()
    }

    @objc private func quitApp(_ sender: Any?) { state.quit() }

    @objc private func ctxCursorSelfTest(_ sender: Any?) { state.runCursorLockSelfTest() }

    // MARK: - 日志窗口
    //
    // 日志不再塞在菜单栏下拉面板里（面板高度有限，日志会把其它设置挤到屏幕外）。
    // 改为独立的可缩放窗口，需要时再打开；面板只留一个入口按钮。

    private var logWindow: NSWindow?

    @objc func showLogWindow(_ sender: Any?) {
        if let w = logWindow {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 440),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = "MWB 运行日志"
        w.isReleasedWhenClosed = false
        w.contentViewController = NSHostingController(
            rootView: MWBLogView(state: state))
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        logWindow = w
    }
}
