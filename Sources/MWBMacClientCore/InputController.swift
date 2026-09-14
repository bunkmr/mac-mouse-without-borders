// InputController.swift
// 输入注入 (Windows 控制 Mac) + 输入捕获 (Mac 控制 Windows)。
// 全部基于 CoreGraphics CGEvent，无需 C# P/Invoke。

import Foundation
import CoreGraphics
import AppKit

// Windows 鼠标消息 (dwFlags 取值)
private let WM_MOUSEMOVE: Int32   = 0x0200
private let WM_LBUTTONDOWN: Int32 = 0x0201
private let WM_LBUTTONUP: Int32   = 0x0202
private let WM_RBUTTONDOWN: Int32 = 0x0204
private let WM_RBUTTONUP: Int32   = 0x0205
private let WM_MBUTTONDOWN: Int32 = 0x0207
private let WM_MBUTTONUP: Int32   = 0x0208
private let WM_MOUSEWHEEL: Int32  = 0x020A

/// 触发切换的屏幕边缘。MWB 的行为是：光标顶到这条边并继续外推，
/// 才把控制权交给相邻机器；在此之前本地光标正常，不向对端转发任何事件。
public enum SwitchEdge: String {
    case left, right, top, bottom
}

/// 控制远端期间「本机位移 → 远端归一化位移」的换算方式。
public enum MotionScale: String {
    /// **协议原生做法**：按**本机**屏幕尺寸归一化。
    /// 归一化坐标（0..65535）存在的意义就是「谁都不需要知道对方的分辨率」：
    /// 源机按自己的 bounds 归一化，目标机按自己的 bounds 还原。
    /// 效果：跨过本机整个屏幕宽 = 跨过对端整个屏幕宽（比例一致，换分辨率不用改配置）。
    case proportional
    /// 按对端真实分辨率做 1:1 像素映射：本机移动 1 像素 = 对端移动 1 像素。
    /// 需要用户填对端分辨率，填错会让远端光标明显偏快/偏慢。
    case pixelExact
}

public final class InputController {
    public static let shared = InputController()

    // MARK: - 屏幕跨越状态机

    /// true = 控制权已交给远端（Windows），本地光标钉在边缘，事件全部转发。
    public private(set) var isControllingRemote = false
    /// 触发切换的本机边缘（Windows 屏幕的相对位置）。
    public var switchEdge: SwitchEdge = .right
    /// 切换状态变化回调。
    public var onSwitchChanged: ((Bool) -> Void)?
    /// 远端屏幕参考尺寸，用于把本地位移换算成远端归一化坐标。
    /// 仅在 `motionScale == .pixelExact` 时被使用（按对端像素 1:1 映射）。
    public var remoteScreenSize = CGSize(width: 1920, height: 1080)
    /// 位移换算方式。默认 `.proportional`（按本机屏幕尺寸归一化），无需知道对端分辨率。
    public var motionScale: MotionScale = .proportional
    /// 本次进入远端时确定下来的位移参考尺寸（proportional=本机屏幕，pixelExact=对端分辨率）。
    private var motionRefSize = CGSize(width: 1920, height: 1080)
    /// 本地光标锁定时距边缘的内缩量（像素），避免来回抖动。
    /// 2px 太贴边：退出后的 warp 落点仍在"边缘区"内，下一帧就会被判成又顶到边缘。
    /// 6px 让"退出"和"再次进入"在几何上分开。
    private let edgeInset: CGFloat = 6

    /// 虚拟远端光标位置（Windows 归一化坐标 0..65535，左上原点）。
    private var virtualRemote = CGPoint(x: 0, y: 32767)
    private var lastLocalPoint: CGPoint = .zero
    /// 进入远端时的落点。
    private var entryRemotePoint = CGPoint(x: 0, y: 32767)
    /// 从入口【沿进入方向】真正走进对端屏幕的距离（归一化单位 0..65535）。
    ///
    /// ★ 必须只算垂直于入口边的那一个轴。
    /// 旧实现用 `max(|Δx|, |Δy|)`，纵向（平行于入口边）的细微抖动就能把它顶过阈值，
    /// 于是「刚切过去 60ms 就被判成已经走远了、可以推回来」→ 两边来回抢控制权，
    /// 表现为：Mac 光标看着没锁住、键盘也发不出去（控制权一直被踢回）。
    private var inwardTravel: CGFloat = 0
    /// 已经贴住入口边、还在继续往外推的累计量（归一化单位）。
    /// 需要累计到阈值才退出 —— 单帧抖动（dx=±1）不该把控制权弹回本机。
    private var outwardPush: CGFloat = 0

    /// 允许退出的最小外推累计量（归一化）。1200 ≈ 屏宽的 1.8%（1080p 约 19px）。
    ///
    /// 【为什么从 2000 降下来】锁定之后本机光标被钉在锚点，用户"往回推"的
    /// 第一段位移都花在"把虚拟坐标从对端内部挪回入口边"上，之后才轮到累计外推量。
    /// 2000 加上前面那一段，手感上要推近 50px 才有反应 —— 用户会以为"推不回来"。
    private static let exitMinOutward: CGFloat = 1200
    /// 进入远端后的防抖宽限截止时间，期内不判定退出。
    ///
    /// ★ 这里替换掉了旧实现的 `inwardTravel > exitMinInward(4000)` 门槛。
    /// 旧做法要求"必须先沿进入方向深入对端 4000（≈94px）才有资格退出"，
    /// 而 inwardTravel 只取 max、永不衰减 —— 用户从边缘滑出去后只走了 1920
    /// （2026-09-14 09:11 日志实测），退出条件就再也无法成立，被**永久锁在 Windows 里**。
    /// 改用【时间】做迟滞：既挡得住"擦边刚进去就被弹回"，又不会把人锁死。
    private var entryGraceUntil: Date = .distantPast
    /// 交回本机后的冷却截止时间：期内一律不许再次进入远端。
    /// 没有它会出现"推回来那一瞬又被判成顶到边缘 → 立刻返回对端"的弹回现象。
    private var exitCooldownUntil: Date = .distantPast
    /// 冷却结束后仍需"物理光标先离开边缘"才重新武装边缘检测。
    /// 只靠冷却时间不够：用户推回来的惯性常常在冷却期内一直把光标压在边缘上，
    /// 冷却一过就立刻重进 —— 体感就是"回不来"。
    private var edgeRearmPending = false
    /// 进入远端时本机光标的位置（离开时恢复到同一高度，避免手感跳动）。
    private var entryLocalPoint: CGPoint = .zero
    /// 诊断用：进入远端后记录前几个位移样本与前几个键盘包。
    private var deltaProbe = 0
    private var keyProbe = 0

    /// 位移尺度自检：累计 |delta| 与 |location 差分|，各满 40 个有效样本后报一次比值。
    ///
    /// 【为什么需要它】远端速度取决于「motionRefSize 用的单位」和「delta 字段的单位」
    /// 是否一致。两者都按屏幕逻辑点计时比值 ≈ 1.0；若 delta 实际是 Retina 物理像素
    /// 而参考尺寸用的是逻辑点，比值就是 ≈ 2.0 —— 远端光标会跑两倍快，
    /// 手感就是「不跟手」。这是个纯测量，不猜。
    private var deltaAbsSum: CGFloat = 0
    private var locAbsSum: CGFloat = 0
    private var deltaScaleProbeCount = 0

    /// 已转发给 Windows 但尚未抬起（DOWN 包发过、UP 包没发）的鼠标键集合。
    /// 离开远端/断开/退出时必须补发抬起，否则 Windows 会一直停在「左键按住」状态 ——
    /// 用户会感觉那边鼠标像被粘住，点哪都是拖拽。
    private var remotePressedButtons: Set<Int32> = []

    /// 是否启用本地输入捕获（Mac 作为控制端时）。
    public var captureEnabled = false

    /// 捕获到本地输入时回调（用于转发给 Windows）。
    public var onCaptured: ((DataPacket) -> Void)?

    /// 本机左键**抬起**时回调 —— 与「是否在控制远端」无关，一定会触发。
    ///
    /// 【为什么必须有它，且必须在 swallowingInput 守卫之前】Windows → Mac 方向的
    /// 文件拖放收尾，靠的就是这一拍。对照 PowerToys 的实现可以确认：
    ///   · `DragDropStep09(int wParam)` 挂在**鼠标钩子**上，判据只有
    ///     `wParam == WM_LBUTTONUP && IsDropping` → `DragDropStep10()` → `GetRemoteClipboard("desktop")`；
    ///   · 而 `local`（是否由本机处理）的定义是 `NewDesMachineID == Common.MachineID`，
    ///     也就是说：**松手发生在"投放目标机"本地**，是本地事件，不是网络包。
    /// 本机就是那个"投放目标机"（`ClipboardDragDropOperation` 点名了我们的 MachineID）。
    /// 而物理鼠标在 Mac 上，抬起事件只出现在本机 tap 里、**不会**从 Windows 发回来 ——
    /// 所以旧实现只等"远端鼠标包里的 LBUTTONUP"，这一拍永远等不到，文件就永远拉不回来
    /// （2026-09-14 实测：日志里 ClipboardDragDrop / ClipboardDragDropOperation 都有，
    ///  但没有任何一行「松手投放 → 主动拉取」）。
    ///
    /// ⚠️ 放在 `swallowingInput` 判断之后同样是错的：用户把光标推回本机后再松手时
    /// `swallowingInput` 已为 false，那一拍会被直接放行、什么也不会发生。
    public var onLocalLeftMouseUp: (() -> Void)?

    /// 对端（Windows）把文件拖放的**投放目标**指定成了本机
    /// （即收到了点名我们的 `ClipboardDragDropOperation`）。
    ///
    /// 置为 true 时会立即做一件必要的事：**把控制权交回本机**（拖文件必须能跨过来）。
    ///
    /// 【为什么必须在收到这个包时立刻交回】
    /// 拖拽期间用户一直按着左键，而退出条件里挂着 `remotePressedButtons.isEmpty`
    /// （本意是"别把框选/拖窗口在边缘硬生生打断"）。于是拖文件过来时，
    /// 远端光标被钉在边界、控制权永远不放 —— 投放永远落不到 Mac 上。
    /// 而 PowerToys 那边的语义是：一旦它把 dropMachine 换成我们，就说明
    /// **光标已经跨到本机侧**了（`SendDropBegin`/`ChangeDropMachine` 就是这么触发的）。
    /// 所以这个包就是"该把控制权交回本机"的权威信号，比我们自己的边缘累计量更及时。
    ///
    /// 交回时**不补发**鼠标抬起包：那会让 Windows 以为拖拽已结束、
    /// 把 `LastDragDropFile` 清掉，我们就再也拉不到文件了（见 leaveRemote 的参数说明）。
    public var fileDropInProgress = false {
        didSet {
            guard fileDropInProgress, !oldValue else { return }
            if isControllingRemote {
                leaveRemote(restoreCursor: true,
                            reason: "对端把投放目标转为本机（文件拖放）",
                            releaseButtons: false)
            }
        }
    }

    /// 文件拖放收尾：清掉投放态标记，并**只清记账、不补发**对端仍按住的鼠标键
    /// （拖拽已经在 Windows 侧结束，补发抬起反而会让它的状态机错乱）。
    public func finishFileDrop() {
        fileDropInProgress = false
        remotePressedButtons.removeAll()
    }

    /// 外部（例如收到对方的鼠标包被本机注入时）强制切回本地控制。
    public func setControllingRemote(_ v: Bool, reason: String = "") {
        guard v != isControllingRemote else { return }
        if v {
            enterRemote(at: nil)
        } else {
            leaveRemote(restoreCursor: false, reason: reason)
        }
    }

    /// 保险绳：无条件恢复「鼠标 → 光标」联动。
    /// 断开连接、退出 App、按紧急热键时都必须调 ——
    /// 一旦处于解耦状态而进程又没恢复它，用户的光标就再也推不动了。
    public func releaseCursor() {
        if isControllingRemote {
            isControllingRemote = false
            onSwitchChanged?(false)
        }
        // 断开/退出时同样要清掉对端可能残留的「按住」状态。
        releaseRemoteButtons()
        // 以及本机被注入侧的「按住」状态（对端拖拽到一半掉线的情况）。
        releaseInjectedButtons()
        stopLockTimer()
        stopMouseFlushTimer()
        showSystemCursor()
        CGAssociateMouseAndMouseCursorPosition(1)
        // 统一在这里设冷却/重装：断开、退出、紧急热键、自检结束都走这条路径，
        // 避免"刚交回本机、光标还压在边缘"就立刻又被判定切走。
        exitCooldownUntil = Date().addingTimeInterval(0.5)
        edgeRearmPending = true
    }

    /// 回归自检：强制进入「控制远端」状态 `seconds` 秒，然后再退出。
    /// 用来客观验证「控制远端时本机光标到底有没有被隐藏/钉住」。
    ///
    /// 【为什么需要它】
    /// 光标锁定在 2026-09-14 一天内**回归了两次**：
    ///   ① hide 重申被"优化"成 2Hz → 连续移动时全程可见；
    ///   ② 后台进程调 `CGDisplayHideCursor` 返回 success 但不生效（`SetsCursorInBackground` 没解锁）。
    /// 而验证它必须真的把鼠标推到屏幕边缘再持续移动 —— 人肉重复第三次一定会偷懒，
    /// 于是"改坏了却没人发现"就必然复发。有了这个钩子，一条命令就能拿到客观判据。
    ///
    /// 用法：`MWB_LOCK_SELFTEST=8` 启动（见 Client.swift 的 env 钩子）。
    /// 判据看日志里的 `可见性=已隐藏` 与心跳的 `失守=` 次数。
    ///
    /// 锚点取**当前光标位置**，所以不会把光标甩到屏幕角落；测试结束自动恢复。
    public func runLockSelfTest(seconds: Double) {
        guard !isControllingRemote else {
            diag("[MWB] [自检] 已在控制远端，跳过锁定自检")
            return
        }
        // ★ 锚点必须落在**真正的切换边缘**上，不能用"当前光标位置"。
        //
        // 2026-09-14 踩过：锚点设在屏幕中央后，`enterRemote` 的退出判据
        // （向内/向外位移相对锚点算）失去几何依据，光标抖 3px 就被判定
        // "推出边缘" → 控制态反复进出，日志看起来像"隐藏时好时坏"，
        // 其实是自检把自己的状态机搞崩了，不是隐藏的问题。
        let cur = trueCursorLocation() ?? CGPoint(x: 20, y: 20)
        let f = localScreenFrame(containing: cur)
        let anchor: CGPoint
        switch switchEdge {
        case .left:   anchor = CGPoint(x: f.minX, y: cur.y)
        case .right:  anchor = CGPoint(x: f.maxX - 1, y: cur.y)
        case .top:    anchor = CGPoint(x: cur.x, y: f.minY)
        case .bottom: anchor = CGPoint(x: cur.x, y: f.maxY - 1)
        }
        diag("[MWB] [自检] 锁定自检开始：强制进入控制态 \(Int(seconds))s"
             + "（锚点=\(switchEdge.rawValue) 边缘 (\(Int(anchor.x)),\(Int(anchor.y)))"
             + " —— 期间请尽量晃动鼠标，这才是真实工况）")
        // 先把光标搬到锚点再进入控制态：否则第一次 engageCursorLock 会看到
        // "光标还在屏幕中央"，把这段初始搬运误记成「失守 665px」，污染位移指标。
        CGWarpMouseCursorPosition(anchor)
        enterRemote(at: anchor)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self else { return }
            // 判据用**整场隐藏采样占比**，不用末尾瞬时值 ——
            // 末尾那一次可能刚好落在退出之后，会把好结果误报成坏结果。
            let ratio = self.cursorHiddenRatio
            let pct = ratio.map { Int($0 * 100) } ?? -1
            let ok = (ratio ?? 0) >= 0.5
            self.diag("[MWB] [自检] 锁定自检结束：隐藏采样=\(self.hiddenSampleText())"
                      + " 最大偏移=\(Int(self.lockMaxDeviation.rounded()))px"
                      + " 失守=\(self.lockWarpCount)次"
                      + (ratio == nil ? "  ⚠️ 拿不到 CGCursorIsVisible，无法判定"
                         : ok ? "  ✅ 光标隐藏生效（占比 \(pct)%）—— 这就是用户要的「锁定」"
                              : "  ❌ 隐藏占比只有 \(pct)% —— 没生效，需要继续排查"))
            self.leaveRemote(restoreCursor: true, reason: "锁定自检结束")
            self.exitCooldownUntil = Date().addingTimeInterval(0.5)
            self.edgeRearmPending = true
            // 把光标放回自检前的位置，免得用户发现光标莫名跑到了屏幕边缘。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                CGWarpMouseCursorPosition(cur)
            }
        }
    }

    /// 保险绳：把仍处于「注入按住」状态的鼠标键补发抬起包。
    /// 对端拖拽到一半掉线/被断开时，不补发会让本机鼠标永久卡在按住状态。
    private func releaseInjectedButtons() {
        guard !injectedButtonDown.isEmpty else { return }
        let raw0 = injectedButtonDown
        injectedButtonDown.removeAll()
        let pos = trueCursorLocation() ?? .zero
        for raw in raw0 {
            let t: CGEventType
            let b: CGMouseButton
            if raw == CGMouseButton.right.rawValue {
                t = .rightMouseUp; b = .right
            } else if raw == CGMouseButton.center.rawValue {
                t = .otherMouseUp; b = .center
            } else {
                t = .leftMouseUp; b = .left
            }
            if let ev = CGEvent(mouseEventSource: nil, mouseType: t,
                                mouseCursorPosition: pos, mouseButton: b) {
                ev.setIntegerValueField(.eventSourceUserData, value: Self.injectedTag)
                ev.post(tap: CGEventTapLocation.cghidEventTap)
            }
        }
        diag("[MWB] 已补发本机鼠标抬起（避免本机卡在拖拽态）")
    }

    // MARK: - 光标锁定（控制远端期间把本机光标钉在屏幕边缘）
    //
    // ★★ 这一节是在 macOS 15 上做了一组对照实验之后重写的。四种常见做法逐个验过：
    //
    //   ① CGAssociateMouseAndMouseCursorPosition(0) —— Apple 文档原文是
    //      "disconnect the mouse and cursor **while an application is in the foreground**"。
    //      我们是被签成 LSUIElement 的后台菜单栏应用，永远不在前台，
    //      所以它**返回 success 却毫无效果** —— 这就是「鼠标已经到 Windows 了，
    //      Mac 的光标还在跟着动」的根因之一。
    //   ② 在活动 CGEventTap 里 `return nil` 吞掉 mouseMoved —— **也拦不住光标**。
    //      对照实验：让 tap 自己报告「看到并吞掉了 60 个移动事件」，光标照样移动 480px。
    //      吞事件只影响「App 收不收得到」，不影响光标位置。
    //   ③ CGDisplayHideCursor —— ★ **有效，但有前提**（2026-09-14 第二次修正）。
    //      原先记的"后台应用隐藏不了"是对的，只是当时用"截图逐帧比对"去证，
    //      而本机 `screencapture` 取像不稳定（同状态间隔 0.5s 差异可达 90%），
    //      于是结论被当成"错判"推翻了 —— 结果绕了一大圈又踩回来。
    //      **真相**：Apple 文档写明 "the caller must be the foreground application"，
    //      我们（LSUIElement 后台应用）调它会**返回 .success 但完全不生效**。
    //      2026-09-14 用 `CGCursorIsVisible()` 客观实测：裸调 → 仍"可见"；
    //      先设 `SetsCursorInBackground=true` 再调 → 立刻"已隐藏"。
    //      所以必须先调 `CursorBackgroundControl.enableOnce()`
    //      （见 CursorBackgroundControl.swift），hide 才真正生效。
    //      ⚠️ **永远不要拿 CGDisplayHideCursor 的返回值当判据** —— 它恒为 success。
    //         要判就用 `CursorBackgroundControl.visibilityDescription()`。
    //      它是**计数式** API：hide 一次多隐一层，必须调同样次数的 show 才恢复；
    //      系统在切 App / 真实设备输入等时机还会把光标重新显示出来，所以要重申。
    //      实现见 hideSystemCursor() / showSystemCursor()：自己记账 + **100Hz**（10ms 节流）
    //      重申 + 退出时按账本多冲 3 次。这才是用户要的「消失」那一半。
    //      ⚠️ 重申频率不能降：真实设备输入会让系统把光标重新显示，
    //         事件到达率是 100~1000Hz，重申低于它就会出现「继续移动时全程可见」。
    //         2026-09-14 的第一次回归就是因为这里被"优化"成了 2Hz。
    //      ⚠️ 它是**全局**状态（不是只影响本应用）：漏调 show → 用户永久失去光标。
    //      因此所有退出路径都必须恢复：releaseCursor()、leaveRemote()、SIGTERM 收尾。
    //   ④ ★ 真正「钉住位置」的做法：**把事件里的坐标改写成锚点，然后照常放行**。
    //      WindowServer 收到的就是「光标在锚点」，于是它自己把光标钉在那里。
    //      对照实验（同一组 60 个移动事件）：
    //        改写 location 后放行 → 位移 0px      ✅
    //        只把 delta 清零后放行 → 位移 480px   ❌（所以改的是 location，不是 delta）
    //        return nil 吞掉      → 位移 480px   ❌（所以**必须放行**）
    //      ——「改写 + 放行」同时满足了「光标不动」和「本机 App 不影响」两个诉求。
    //
    //   解耦调用保留，纯粹当「万一某台机器上前台化之后它生效」的免费保险；
    //   另有一个 30Hz 定时器做兜底 warp（没有鼠标事件时也能把光标拉回锚点，
    //   事件 tap 万一被系统禁用，也靠它把光标按在锚点附近）。

    /// 本机光标是否处于「锁定」状态（正在控制远端）。
    public var cursorLocked: Bool { isControllingRemote }

    /// 控制远端期间是否把本机光标钉在屏幕边缘。默认开。
    /// 关掉后本机光标会跟着物理鼠标在 Mac 上乱跑（不推荐，仅用于排查）。
    public var lockCursorWhileRemote = true

    /// 是否在**每个**鼠标移动事件里重申 `CGAssociateMouseAndMouseCursorPosition(0)`。
    ///
    /// ★ 2026-09-14 修正（上一版把这里"优化"错了）：
    /// 上一版为了省掉一点 IPC 开销，把它降成「只在进入远端时调一次」，
    /// 结果立刻被反馈「鼠标到 Windows 之后又锁不住了」。根因是——
    /// 「把事件坐标改写成锚点」这一招**只有在光标已解耦的前提下才拦得住光标**：
    /// 解耦时 WindowServer 不拿设备位移驱动光标，于是我们给的坐标说了算；
    /// 一旦关联被恢复（切前台 App、系统注入事件等时机都会），
    /// 设备位移重新直接驱动光标，改写 location 就形同虚设。
    /// 关闭的代价只是每次事件几十微秒，相对 1000Hz 的鼠标流可以忽略，
    /// 所以直接每帧重申，不再做这种"优化"。
    public var assertAssocPerFrame = true

    /// 锁定期间是否把事件的**设备位移字段清零**（默认开）。
    ///
    /// 只改写 `event.location` 挡不住 WindowServer 内部「位置 += 设备 delta」那条腿，
    /// 它会继续累加、并在真实设备输入到来时一次性追平，造成"锁一两秒后跳一下"。
    /// 与 `assertAssocPerFrame` 一起构成完整锁定。
    /// `MWB_ZERO_DELTA=0` 可关掉，仅用于对照实验。
    public var zeroDeltaWhileLocked = true

    /// 锁定期间被「兜底 warp」拽回光标的次数。
    /// 正常锁定时**应当恒为 0**（事件坐标改写已经把光标钉住了）；
    /// 一旦这个数字持续增长，就是「关联被恢复、改写没拦住」的硬证据 ——
    /// 用户看到的"光标一顿一顿"也正是它造成的。
    public private(set) var lockWarpCount = 0
    /// 事件 tap 被系统禁用（超时/用户输入）的累计次数。
    ///
    /// 非 0 就意味着**存在"锁定逻辑完全不执行"的时间窗口**——这是「光标锁不住」
    /// 一条独立于改写逻辑的成因，而且只看代码是看不出来的，必须靠这个计数暴露。
    public private(set) var tapDisabledCount = 0
    /// 最近一次 tap 被禁用的时刻（用于判断失守是否与禁用窗口重合）。
    private var lastTapDisabledAt = Date.distantPast
    /// 锁定期间**真实光标**相对锚点的最大偏移（px）。
    ///
    /// 【为什么必须有它】只看"终测位移"会被兜底 warp 掩盖：失守一次立刻被拉回，
    /// 终测仍是 0px，自检显示 ✅ 而用户明明看见光标在跳。只有把**整场最大值**记下来，
    /// "锁没锁住"才是可量化的。
    public private(set) var lockMaxDeviation: CGFloat = 0

    /// 重申解耦的次数（诊断用）。
    public private(set) var assocReassertCount = 0

    /// ★ 光标可见性的**连续**采样（客观判据，控制远端期间每帧采一次）。
    ///
    /// 【为什么必须连续采样，不能只在末尾看一眼】
    /// `CGDisplayHideCursor` 的返回值恒为 success（后台进程里是假的），
    /// 截图比对在本机也不可信。唯一可信的是 `CGCursorIsVisible()`，
    /// 但它只反映**采样那一瞬间**的状态 —— 2026-09-14 的自检就吃了这个亏：
    /// 末尾那一次刚好落在「状态机退出、光标已归还」之后，于是误报
    /// "❌ 光标仍然可见"，而实际上整场有 80% 的采样是"已隐藏"。
    /// 记成比例才既有代表性又防误判。
    public private(set) var cursorVisSampleTotal = 0
    public private(set) var cursorVisSampleHidden = 0

    /// 最近一次采样的可见性（nil = 本机拿不到该 API）。
    public private(set) var lastCursorVisible: Bool?

    /// 「控制远端期间，光标处于已隐藏状态」的采样占比（0…1）。无采样时返回 nil。
    public var cursorHiddenRatio: Double? {
        guard cursorVisSampleTotal > 0 else { return nil }
        return Double(cursorVisSampleHidden) / Double(cursorVisSampleTotal)
    }

    private func sampleCursorVisibility() {
        guard let vis = CursorBackgroundControl.isCursorVisible() else { return }
        lastCursorVisible = vis
        cursorVisSampleTotal += 1
        if !vis { cursorVisSampleHidden += 1 }
    }

    /// 「隐藏采样」的可读文本，例如 `99%（137/138）`。
    /// 这是判断「控制远端时光标有没有真的消失」的**唯一可信指标**。
    public func hiddenSampleText() -> String {
        guard let r = cursorHiddenRatio else { return "N/A" }
        return String(format: "%.0f%%（%d/%d）", r * 100, cursorVisSampleHidden, cursorVisSampleTotal)
    }

    private func resetCursorVisibilitySamples() {
        cursorVisSampleTotal = 0
        cursorVisSampleHidden = 0
    }

    private var lockTimer: DispatchSourceTimer?

    /// 上一次「锁定健康度」心跳日志的时刻（每 2s 一条，见 engageCursorLock）。
    private var lastLockHealthAt = Date.distantPast

    /// 上一次「兜底 warp」的时刻。
    /// warp 自己会派生一个 mouseMoved 事件回到 tap 里，其 delta 是「锚点 − 跑掉的当前位置」
    /// —— 不滤掉的话，这个补偿位移会被当成用户输入再发给对端，远端光标就会抽搐。
    private var lastWarpAt = Date.distantPast

    // MARK: - 鼠标移动包限流
    //
    // 【为什么要限流】锁定期间用户发现"光标推不动"，会本能地加大动作幅度和频率，
    // 事件率很容易冲到 200Hz 以上。旧实现每个 mouseMoved 都发一个 TCP 包，
    // 发送缓冲被顶满之后对端光标开始一顿一顿的 —— 这就是"过去之后有点卡"的来源。
    //
    // 位置是**绝对值**、且 virtualRemote 每帧都在累加，所以限流只降低中间点的密度，
    // 不影响最终落点；再用一个 50Hz 的补发定时器保证"最后一次位置"不丢。

    /// 上次给对端发鼠标移动包的时间。
    private var lastMouseSendAt = Date.distantPast
    /// 有位置更新被限流挡下、还没发出去。
    private var mouseFlushPending = false
    /// 限流补发定时器（与限流阈值同频，保证"最后一次位置"最多滞后一个间隔）。
    private var mouseFlushTimer: DispatchSourceTimer?
    /// 鼠标移动包最小发送间隔（5ms ≈ 200Hz）。
    ///
    /// ★ 2026-09-14 从 8ms 收紧到 5ms：用户反馈"Windows 里光标不跟手"。
    /// 位置包是绝对值且每帧累加，限流只降中间点密度；但阈值越大，
    /// 快速移动时对端的采样就越稀、越像"一格一格跳"。200Hz 足以覆盖
    /// 常见鼠标上报率，同时仍能把 1000Hz 事件流削掉 80%。
    private static let mouseMinInterval: TimeInterval = 0.005

    /// 读取**真实**光标位置（CG 左上原点）。
    ///
    /// ⚠️ 绝对不要用 `CGEvent(source: nil)?.location` 来测"光标有没有跑掉"。
    /// 本进程挂了 CGEventTap，而 `CGEventCreate(NULL)` 返回的是**本进程事件流里
    /// 最近一次事件**的位置 —— 而我们在 handleMouseMoved 里做的正是
    /// 「把每个事件的 location 改写成锚点」。于是这个读数**恒等于锚点**，
    /// 偏差恒为 0，兜底 warp 永远不会触发 → 锁定形同虚设。
    ///
    /// 2026-09-14 实锤：贴边自检日志里"整场最大偏移 0px / 失守 0 次"，
    /// 而**独立探针**（另一个没有 tap 的进程）同时测到真实光标跑了 476~768px。
    /// 也就是说：只要用 CGEvent(source:nil) 当判据，"锁不住"就永远测不出来。
    ///
    /// `NSEvent.mouseLocation`（AppKit 左下原点）是直接向 WindowServer 查询的，
    /// 不经过本进程的事件流，因此不受改写污染。这里换算成 CG 的左上原点。
    ///
    /// ⚠️ **不要**改用 `screencapture` 截图来判断锁定/隐藏是否生效 ——
    /// 2026-09-14 实测本机取像不可靠：同一状态相隔 0.5s 的两张图差异可达 90%
    /// （背景本身在变），而且 `-C`（强制画光标）与不画之间的语义不一致。
    /// 结论：截图既不能证明"锁住"，也不能证明"隐藏了"。判据只用本函数 +
    /// 计数（lockMaxDeviation / lockWarpCount / tapDisabledCount / hideCursorCount）。
    func trueCursorLocation() -> CGPoint? {
        guard let main = NSScreen.screens.first else { return nil }
        let p = NSEvent.mouseLocation
        return CGPoint(x: p.x, y: main.frame.maxY - p.y)
    }

    /// 是否已由我们隐藏了系统光标（以及我们累计 hide 了多少次）。
    ///
    /// 【为什么要隐藏光标，而不是只把它"钉住"】
    /// 把光标钉在锚点是**位置控制**：一旦某帧 WindowsServer 的内部 delta 累加
    /// 或者系统把关联恢复，光标就会在 Mac 屏上乱跑（本机实测：独立探针测到
    /// 一次跑掉 276~768px）。而"用户看得见光标在 Mac 上乱跑"正是最直观的抱怨
    /// （用户原话：「在 mac 的鼠标并没有失焦消失或固定」）。
    /// 隐藏光标是**显示层控制**，与位置控制相互独立 —— 位置万一漏了，用户也看不见，
    /// 这才是真正"消失"的那一半。
    ///
    /// ⚠️ `CGDisplayHideCursor` 是**计数式**的：每调一次就多隐一层，
    /// 必须相应调同样次数的 `CGDisplayShowCursor` 才能恢复。
    /// 所以这里自己记账（`hideCursorCount`），退出时按账本冲掉 ——
    /// 否则用户的光标会永久消失（这是最严重的事故）。
    private var hideCursorCount = 0
    private var lastHideCursorAt = Date.distantPast

    private func hideSystemCursor() {
        guard lockCursorWhileRemote else { return }
        // ★★★ 第一件要做的事：解锁「后台进程控制光标」★★★
        //
        // 2026-09-14 第二次修正（第一次只改了频率，没解决根本问题）：
        // 用户反馈「hide 计到 1021 次了，光标还是跟着 Windows 一起动」。
        // 用独立探针（CGCursorIsVisible 判定）实测证实：
        //   · 裸调 CGDisplayHideCursor → **返回 success ×3，光标仍然「可见」**；
        //   · 先设 SetsCursorInBackground=true 再 hide → 立刻变成「已隐藏」。
        // 原因就是 Apple 文档那句 "the caller must be the foreground application" ——
        // 我们是 LSUIElement 后台应用，所以 hide 一直被系统静默丢弃。
        // 下面这行是幂等的，放在这里能保证「任何一次 hide 之前一定已经解锁」。
        CursorBackgroundControl.enableOnce { [weak self] s in self?.diag(s) }
        // ★ 节流 10ms（≈100Hz），不是 2Hz。
        //
        // 2026-09-14 修正：原来这里是 0.5s（2Hz），理由是"不让 hide 计数失控"。
        // 但那个"优化"会直接毁掉隐藏效果：系统在真实设备输入时会重新显示光标，
        // 而 2Hz 的窗口意味着**连续移动鼠标时几乎全程可见**（这正是用户报的
        // "跨越到 win 后本机光标还在满屏跑"）。事件的到达率是 100~1000Hz，
        // 所以重申频率必须跟事件同量级。10ms 节流下 hide 计数上界 ≈100/秒，
        // 一次 10 分钟的控制 ≈6 万次，退出时按账本冲销的代价只有几十毫秒。
        guard Date().timeIntervalSince(lastHideCursorAt) > 0.01 else { return }
        lastHideCursorAt = Date()
        if CGDisplayHideCursor(CGMainDisplayID()) == .success { hideCursorCount += 1 }
    }

    /// 按账本把 hide 全部冲掉。**任何退出路径（断开/收权/紧急热键/进程退出）都必须调**。
    private func showSystemCursor() {
        guard hideCursorCount > 0 else { return }
        // 多冲 3 次做保险（计数漂移时宁可多 show，多调无副作用）。
        for _ in 0..<(hideCursorCount + 3) {
            _ = CGDisplayShowCursor(CGMainDisplayID())
        }
        diag("[MWB] 光标已恢复显示（冲掉 \(hideCursorCount) 次 hide）")
        hideCursorCount = 0
        lastHideCursorAt = .distantPast
    }

    /// 重申解耦 + 重申隐藏 + （必要时）把光标 warp 回锚点。由 30Hz 兜底定时器调用。
    ///
    /// 真正「钉住」是 handleMouseMoved 里的**事件坐标改写**在做（见本节说明 ④）；
    /// 这个定时器负责两件事：① 在没有鼠标事件时也把解耦状态顶住；
    /// ② 万一关联还是被系统恢复了，把已经跑掉的光标拉回来（并记账）。
    private func engageCursorLock() {
        hideSystemCursor()
        // 采一次「光标到底隐没隐」——连续采样才不会被瞬时状态骗到（见计数器注释）。
        sampleCursorVisibility()
        if lockCursorWhileRemote,
           CGAssociateMouseAndMouseCursorPosition(0) == .success {
            assocReassertCount += 1
        }
        if lockCursorWhileRemote {
            // 只在光标**真的偏离**锚点时才 warp —— 而这个 warp 本身就是「失守」的信号：
            // 事件坐标改写生效时，光标根本不会离开锚点（实测位移 0px）。
            // 因此这里每次都记账 + 打一条带累计数的日志，让「锁不住」可见、可量化。
            // ★ 必须用 trueCursorLocation()（NSEvent 直查 WindowServer）。
            //   用 CGEvent(source:nil) 会被本进程的事件坐标改写污染 → 读数恒为锚点 → 永不触发。
            let cur = trueCursorLocation() ?? entryLocalPoint
            let dev = max(abs(cur.x - entryLocalPoint.x), abs(cur.y - entryLocalPoint.y))
            if dev > lockMaxDeviation { lockMaxDeviation = dev }
            if dev > 2 {
                CGWarpMouseCursorPosition(entryLocalPoint)
                lastWarpAt = Date()
                lockWarpCount += 1
                if lockWarpCount <= 3 || lockWarpCount % 20 == 0 {
                    diag("[MWB] ⚠️ 锁定失守第 \(lockWarpCount) 次：真实光标偏离锚点"
                         + " (\(Int(cur.x)),\(Int(cur.y))) vs "
                         + "(\(Int(entryLocalPoint.x)),\(Int(entryLocalPoint.y)))"
                         + " 偏移(\(Int(cur.x - entryLocalPoint.x)),\(Int(cur.y - entryLocalPoint.y)))"
                         + " —— 已拉回（锁定方式=\(zeroDeltaWhileLocked ? "改写+清零位移" : "仅改写")"
                         + " 解耦重申=\(assertAssocPerFrame ? "每帧" : "仅进入时")）")
                }
            }
            // ⚠️ 这里**不要**动 lastLocalPoint：它被 handleMouseMoved 用来做
            // "事件没带 delta 时退回 location 差分"的兜底。把它重置成锚点，
            // 会让那一帧的差分恒为 0（2026-09-14 跨屏自检日志里的
            // "位移采样#2 dx=0 loc=(0,400)" 就是这么来的）。
        }
        if !lockReported {
            lockReported = true
            let cur = trueCursorLocation() ?? .zero
            diag("[MWB] 光标锁定: 开关=\(lockCursorWhileRemote ? "开" : "★关★（这就是锁不住的原因）")"
                 + " 锚点=(\(Int(entryLocalPoint.x)),\(Int(entryLocalPoint.y)))"
                 + " 当前光标=(\(Int(cur.x)),\(Int(cur.y)))"
                 + " 方式=改写坐标+清零设备位移+每帧重申解耦"
                 + "(零位移=\(zeroDeltaWhileLocked) 重申=\(assertAssocPerFrame))"
                 + " 可见性=\(CursorBackgroundControl.visibilityDescription())"
                 + " 隐藏采样=\(hiddenSampleText())"
                 + " tap被禁用累计=\(tapDisabledCount)次")
            lastLockHealthAt = Date()
        }

        // ★ 锁定健康度心跳（每 2s）：跨屏控制期间持续交代"锁得到底怎么样"。
        // 只在进入那一刻报一次是不够的 —— 失守往往发生在中途某一瞬间，
        // 而用户反馈的"锁不住"正是那个瞬间。心跳让下一次实测直接可判。
        if Date().timeIntervalSince(lastLockHealthAt) > 2.0 {
            lastLockHealthAt = Date()
            let now = trueCursorLocation() ?? .zero
            diag("[MWB] 锁定心跳: 当前=(\(Int(now.x)),\(Int(now.y)))"
                 + " 锚点=(\(Int(entryLocalPoint.x)),\(Int(entryLocalPoint.y)))"
                 + " 最大偏移=\(Int(lockMaxDeviation.rounded()))px 失守=\(lockWarpCount)次"
                 + " 解耦重申=\(assocReassertCount) hide=\(hideCursorCount)次"
                 + " 可见性=\(CursorBackgroundControl.visibilityDescription())"
                 + " 隐藏采样=\(hiddenSampleText())"
                 + " tap禁用=\(tapDisabledCount)次")
        }
    }

    // MARK: - 鼠标移动包：限流 + 末位补发

    /// 把当前 virtualRemote 位置发给对端（默认带 8ms 限流）。
    ///
    /// - Parameter force: true 时无视限流立即发送（进入远端的第一包、补发定时器）。
    private func sendMouseMovePacket(force: Bool = false) {
        let now = Date()
        if !force, now.timeIntervalSince(lastMouseSendAt) < Self.mouseMinInterval {
            // 被限流挡下：只置个标记，由补发定时器把"最后一次位置"送出去。
            mouseFlushPending = true
            return
        }
        lastMouseSendAt = now
        mouseFlushPending = false
        var p = DataPacket(type: .mouse)
        p.mouseFlags = WM_MOUSEMOVE
        p.mouseX = Int32(virtualRemote.x)
        p.mouseY = Int32(virtualRemote.y)
        onCaptured?(p)

        // 发包率统计（每 5 秒一条）：用于定位「远端不跟手」到底卡在哪一环。
        // 若这里显示 ~200Hz 而远端仍不跟手，瓶颈就不在限流，而在网络或对端注入。
        mouseSendCount += 1
        let span = now.timeIntervalSince(lastMouseStatAt)
        if span > 5 {
            diag("[MWB] 鼠标包发送率 = \(mouseSendCount) 包 / \(String(format: "%.1f", span))s"
                 + " ≈ \(Int(Double(mouseSendCount) / span))Hz"
                 + "（上限 \(Int(1.0 / Self.mouseMinInterval))Hz）")
            mouseSendCount = 0
            lastMouseStatAt = now
        }
    }

    private var mouseSendCount = 0
    private var lastMouseStatAt = Date()

    /// 合成一次「远端鼠标抬起」并立刻发出。
    ///
    /// 【为什么文件拖放需要它】PowerToys 的拖放时序里，真正触发接收端去拉文件的是
    /// `DragDropStep09(WM_LBUTTONUP)` → `DragDropStep10()` → `Clipboard.GetRemoteClipboard("desktop")`。
    /// `DragDropStep09` 挂在**鼠标钩子**上，判据只有 `wParam == WM_LBUTTONUP && IsDropping`。
    ///
    /// ⚠️ 这里原来写着"它只对 `!local`（对端注入）的事件生效" —— **那是错的**，
    /// 也正是 Mac→Win 之外那个方向长期不工作的认知来源。实际定义是
    /// `local = (NewDesMachineID == Common.MachineID)`，即**"本机是不是投放目标机"**：
    /// 投放目标机（MachineY）无论那一拍是物理产生还是被注入进来，都会走 Step10 去拉文件。
    /// 我们是把文件拖到本机边缘松手，光标并没有真的跨到 Windows 上去，
    /// 所以 Windows 侧永远等不到那次抬起 —— 必须由我们按当前虚拟坐标补发一个抬起包，
    /// 让它那边的钩子看到 WM_LBUTTONUP 从而触发拉取。
    ///
    /// 用当前 virtualRemote 而不是 (0,0)：`virtualRemote` 记录的是「最后一次发送给对端的坐标」，
    /// 通常就停在我们当初离开对端的那条边缘附近，因此不会把对端光标拽到屏幕角落。
    ///
    /// ★ 这里**不能**加 `isControllingRemote` 守卫：拖放落点在 Mac 边缘时，
    ///   控制权往往已经交回本机了，加了守卫就永远不会发，功能直接失效。
    @discardableResult
    public func sendSyntheticMouseUp(_ flag: Int32? = nil) -> Bool {
        var p = DataPacket(type: .mouse)
        // 默认左键抬起；WM_* 是文件私有常量，不能直接当 public 函数的默认值，故用 nil 兜底。
        p.mouseFlags = flag ?? WM_LBUTTONUP
        p.mouseX = Int32(virtualRemote.x)
        p.mouseY = Int32(virtualRemote.y)
        onCaptured?(p)
        return true
    }

    /// 限流补发定时器：只要还有被挡下的位置没发，就立刻补发一次。
    /// 有了它，用户停手时对端光标一定停在正确落点，不会有半帧的残留偏移。
    /// 周期 = mouseMinInterval（5ms）：把"最后一帧位置"的滞后压到一个限流间隔内。
    private func startMouseFlushTimer() {
        stopMouseFlushTimer()
        lastMouseSendAt = .distantPast
        mouseFlushPending = false
        mouseSendCount = 0
        lastMouseStatAt = Date()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + Self.mouseMinInterval,
                   repeating: Self.mouseMinInterval, leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in
            guard let self, self.isControllingRemote, self.mouseFlushPending else { return }
            self.sendMouseMovePacket(force: true)
        }
        t.resume()
        mouseFlushTimer = t
    }

    private func stopMouseFlushTimer() {
        mouseFlushTimer?.cancel()
        mouseFlushTimer = nil
        mouseFlushPending = false
    }

    private var lockReported = false

    // MARK: - 光标锁定自检

    /// 自检截止时间。期间 isControllingRemote = true，但跳过「推出边缘交回控制权」等逻辑，
    /// 也**不吞**点击/滚轮/键盘（那 6 秒里用户仍然要能正常操作本机）。
    public var selfTestUntil: Date = .distantPast
    public var isSelfTesting: Bool { Date() < selfTestUntil }

    /// 「本机输入是否应该被吞掉并转发给对端」。
    /// 与 isControllingRemote 的区别只有一处：自检期间虽然 isControllingRemote = true，
    /// 但点击/键盘必须照常落到本机（否则用户会以为电脑卡死了）。
    private var swallowingInput: Bool { isControllingRemote && !isSelfTesting }

    private var savedOnCaptured: ((DataPacket) -> Void)?

    // MARK: - 自检用的「假鼠标」

    private var fakeMouseTimer: DispatchSourceTimer?
    private var fakeMouseCount = 0

    /// 自检期间扮演「乱动的物理鼠标」：以 30Hz 投递**未打标记**的 mouseMoved 事件。
    ///
    /// 【为什么由应用自己投递】post 合成事件需要「辅助功能」授权；本应用已获授权。
    /// 而且 CGEventTap 就挂在 cghidEventTap 上，post 出去的事件**一定会从同一个 tap 回来**
    /// （见 `injectedTag` 那段说明），所以能真实地走一遍锁定逻辑。
    ///
    /// 【为什么特意不打 injectedTag】打了标记会被 tap 原样放行、不参与锁定逻辑，
    /// 那就等于什么都没测到。这里要的正是「被当成真实本机鼠标事件」。
    private func startFakeMouse(seconds: TimeInterval) {
        stopFakeMouse()
        fakeMouseCount = 0
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 0.25, repeating: 0.033)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.fakeMouseCount += 1
            let i = self.fakeMouseCount
            // 【为什么要显式带 delta】真实鼠标事件的 location 是系统**由设备 delta 推出来**的；
            // 这里把 delta 一并写上，让事件尽量贴近物理鼠标的形态。
            // ⚠️ 但**别指望这样一来自检就能判定位置锁定**（2026-09-14 实锤）：
            //    合成事件是用 `mouseCursorPosition:` **显式指定坐标**投递的，
            //    系统会照搬这个坐标去摆光标 —— 这跟"设备 delta 驱动"不是同一条路。
            //    所以哪怕锁定逻辑完全正确、哪怕带上了 delta，光标照样被搬到指定坐标
            //    （独立探针实测：喂合成位移 5s，光标范围 668px）。
            //    → 本自检只能验"代码路径在跑"，位置结论必须靠 live 测试。
            //
            // 【为什么改成单向漂移】来回横跳的位置序列即使没锁住也可能碰巧回到起点；
            // 让目标位置单调远离锚点，一旦锁定失效，终测位移必然很大，无法误判。
            let step: CGFloat = 4
            let target = CGPoint(x: self.entryLocalPoint.x + step * CGFloat(i),
                                 y: self.entryLocalPoint.y + step * CGFloat(i) * 0.5)
            if let e = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                               mouseCursorPosition: target, mouseButton: .left) {
                e.setIntegerValueField(.mouseEventDeltaX, value: Int64(step))
                e.setIntegerValueField(.mouseEventDeltaY, value: Int64(step * 0.5))
                e.post(tap: .cghidEventTap)
            }
        }
        t.resume()
        fakeMouseTimer = t
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            self?.stopFakeMouse()
        }
    }

    private func stopFakeMouse() {
        fakeMouseTimer?.cancel()
        fakeMouseTimer = nil
    }

    /// 光标锁定自检：**不需要连接 Windows**。
    ///
    /// ★★ 2026-09-14 据实收窄适用范围：本自检**只能证明「锁定代码路径全程在跑」**
    /// （投递了 N 个事件、事件 tap 没被系统禁用、解耦被逐帧重申），
    /// **不能证明「光标真的被钉在锚点」**。三条判据路全部堵死，详见函数体内说明：
    /// 进程内读数被自己的 tap 污染（实测报 0px 而真实跑了 344px）、
    /// 合成事件自带显式坐标必定搬动光标、`screencapture` 在本机不可信。
    /// 所以它的价值是**回归检测**（tap 被禁用 / 事件没投递出来这类硬故障）；
    /// 「位置有没有钉住」只能由 live 测试（连上对端、真人拖鼠标）给出。
    /// - Parameter anchorAtLeftEdge: true 时先把光标挪到**左边缘**再取锚点。
    ///
    ///   【为什么要这个变体】真实跨屏时，用户是把光标推到屏幕边缘才触发的，
    ///   所以锚点 x≈0（贴边）；而默认自检的锚点在屏幕**中央**。
    ///   "贴边"这个条件本身可能影响锁定（光标已被系统钳在边界），
    ///   两者必须分开测，否则自检通过 ≠ 真实场景通过。
    /// - Parameter keepSending: true 时**保留** `onCaptured`（照常往对端发包）。
    ///
    ///   【为什么这个变体最重要】默认自检把 `onCaptured` 置 nil，即"不发包"，
    ///   而**真实跨屏时每帧都在发网络包**。发包会让事件 tap 回调变慢，
    ///   一旦超过系统阈值，macOS 就会**禁用整个 tap** —— 那之后锁定逻辑一行都不执行，
    ///   光标必然自由移动。不保留发包，这个成因**永远测不出来**（自检永远 ✅）。
    ///   所以"发着包跑自检"才是与真实场景等价的验证条件。
    @discardableResult
    public func startCursorLockSelfTest(seconds: TimeInterval = 6,
                                       anchorOverride: CGPoint? = nil,
                                       keepSending: Bool = false) -> Bool {
        if !tapActive { startCapture() }
        guard tapActive else {
            diag("[MWB] 光标锁定自检失败：事件捕获未建立（缺「辅助功能 / 输入监控」授权）")
            return false
        }
        if isControllingRemote { releaseCursor() }
        if keepSending {
            savedOnCaptured = nil            // 不动 onCaptured，照常发包（真实条件）
            diag("[MWB] 光标锁定自检：**保留发包**（复现真实跨屏负载）—— onCaptured=\(onCaptured == nil ? "nil(未接线)" : "已接线")")
        } else {
            savedOnCaptured = onCaptured
            onCaptured = nil                 // 自检期间不往对端发包
        }
        selfTestUntil = Date().addingTimeInterval(seconds)

        if let target = anchorOverride {
            CGWarpMouseCursorPosition(target)
            usleep(60_000)                    // 给 WindowServer 落位时间，否则读到的是旧坐标
            diag("[MWB] 自检锚点预置: 目标=(\(Int(target.x)),\(Int(target.y)))")
        }

        entryLocalPoint = trueCursorLocation() ?? CGPoint(x: 100, y: 100)
        entryRemotePoint = .zero
        virtualRemote = CGPoint(x: 32767, y: 32767)
        motionRefSize = CGSize(width: 1920, height: 1080)
        inwardTravel = 0
        outwardPush = 0
        lockReported = false
        lockWarpCount = 0
        lockMaxDeviation = 0
        tapDisabledCount = 0
        assocReassertCount = 0
        isControllingRemote = true
        onSwitchChanged?(true)
        engageCursorLock()
        startLockTimer()
        // 假鼠标在最后 0.4s 停下，留出settle时间再测量。
        startFakeMouse(seconds: max(seconds - 0.4, 0.5))
        diag("[MWB] 光标锁定自检开始（\(Int(seconds)) 秒）：应用会自己投递 \(Int(seconds * 30)) 个合成移动事件"
             + " —— 用于验证**锁定代码路径全程在跑**（tap 未被禁用）。"
             + "⚠️ 本自检**不能**判定光标是否真被钉住（合成事件自带坐标 + 进程内读数被污染），"
             + "位置结论请看 live 测试。锚点=(\(Int(entryLocalPoint.x)),\(Int(entryLocalPoint.y)))")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.isControllingRemote else { return }
            self.stopFakeMouse()
            // 先测量、后 releaseCursor（releaseCursor 会把光标挪回锚点）。
            // ⚠️ 下面这个读数**不可信**，只用来确认"代码有没有在跑"，绝不当判据 ——
            //    详见本块末尾的说明。
            let now = self.trueCursorLocation() ?? .zero
            let dist = hypot(now.x - self.entryLocalPoint.x, now.y - self.entryLocalPoint.y)
            let n = self.fakeMouseCount
            let warps = self.lockWarpCount
            let assoc = self.assocReassertCount
            let maxDev = self.lockMaxDeviation
            let tdis = self.tapDisabledCount
            let hides = self.hideCursorCount
            //
            // ★★ 2026-09-14 复核：本自检**在原理上就无法判定"光标有没有被钉住"**。
            //    三条路全部堵死，别再试图用它给出 ✅/❌：
            //
            //    ① **进程内读数被自己的 tap 污染**。本进程挂了 tap 且会改写事件坐标，
            //       于是 `CGEvent(source: nil)?.location` 和 `NSEvent.mouseLocation`
            //       **都恒等于锚点**。实锤：自检报"整场最大偏移 0px、失守 0 次"，
            //       而同一时刻**进程外探针**测到真实光标移动了 344px。
            //       （上一版把读数从 CGEvent 换成 NSEvent 就以为修好了 —— 没修好。）
            //    ② **合成事件自带显式坐标**。假鼠标投递的是 `mouseCursorPosition:` 给定
            //       坐标的合成事件，系统会照搬该坐标去摆光标；这与真实设备"delta 驱动"
            //       的路径不同。所以就算锁定逻辑 100% 正确，合成事件也照样把光标搬走。
            //       独立探针实测：喂合成位移 5s → 光标范围 668px（无条件 warp 也压不住瞬时值）。
            //    ③ **截图法也不可信**：本机 `screencapture` 同状态相隔 0.5s 的两张图
            //       差异可达 90%（背景本身在变），且系统"辅助功能缩放"开着时画面还会被放大。
            //       曾想用 `CGCursorIsVisible()`/`CGCursorIsDrawnInFramebuffer()` 绕开，
            //       但这两个 API 在现代 macOS 上已是**空壳**（恒返回 0/1，不随 hide/show 变化）。
            //
            //    → 所以本自检只如实汇报**能诚实汇报的部分**：锁定代码路径有没有全程在跑。
            //      位置结论只能由 **live 测试（连上对端，真人拖鼠标）** 给出。
            if tdis == 0 && n > 0 {
                self.diag("[MWB] 锁定自检：✅ 锁定代码路径全程在跑（投递 \(n) 个合成事件；"
                          + "tap 未被禁用；解耦重申 \(assoc) 次；累计 hide \(hides) 次）"
                          + " —— 这一项可信。"
                          + " ⚠️ 但**光标是否真被钉住，本自检测不出**："
                          + "进程内读数被自己的 tap 污染（本次报位移 \(Int(dist.rounded()))px、"
                          + "整场最大偏移 \(Int(maxDev.rounded()))px，均**不可信**），"
                          + "且合成事件自带显式坐标、必定搬动光标。"
                          + "位置结论请用 live 测试，或进程外探针（无 tap 的独立进程读 CGEvent.location）。")
            } else {
                self.diag("[MWB] ❌ 锁定自检发现**可信的**故障："
                          + (tdis > 0 ? "事件 tap 被系统禁用 \(tdis) 次" : "")
                          + (n == 0 ? " 没有投递出任何移动事件" : "")
                          + " —— 意味着锁定逻辑存在**根本没执行**的时间窗口。"
                          + "（这一项与读数是否被污染无关，是硬故障。）")
            }
            self.selfTestUntil = .distantPast
            self.releaseCursor()
            // keepSending 模式下 savedOnCaptured 是 nil，**不能**拿它覆盖 onCaptured，
            // 否则会把真实连接的发包出口抹掉（之后远端就不动了）。
            if let saved = self.savedOnCaptured { self.onCaptured = saved }
            self.savedOnCaptured = nil
            self.diag("[MWB] 光标锁定自检结束，鼠标已交回本机")
        }
        return true
    }

    // MARK: - 跨屏切换自检（验证「推得回来」）

    /// 自检期间被临时占用的 edge，结束后还原。
    private var savedSwitchEdge: SwitchEdge?

    /// 无需连接 Windows：用一串**合成**的 mouseMoved 事件走一遍
    /// 「跨到对端 → 只浅浅往里走一段（复现 2026-09-14 那次 1920）→ 推回边缘」，
    /// 然后断言控制权确实交回了本机；再检查"刚交回就被弹回去"的毛病。
    ///
    /// 【为什么必须有这个自检】那次 bug 是"从边缘滑出去、只走进对端 1920
    /// （< 旧门槛 4000）就**永久回不来**"，是纯几何 + 时序问题 ——
    /// 靠手工推鼠标根本没法稳定复现，必须用确定性的事件序列跑一遍。
    ///
    /// 合成事件**特意不打 injectedTag**：打了标记会被 tap 原样放行、不参与边缘逻辑，
    /// 那就等于什么都没测到。
    @discardableResult
    public func startSwitchSelfTest() -> Bool {
        if !tapActive { startCapture() }
        guard tapActive else {
            diag("[MWB] 跨屏自检失败：事件捕获未建立（缺「辅助功能 / 输入监控」授权）")
            return false
        }
        if isControllingRemote { releaseCursor() }

        savedOnCaptured = onCaptured
        onCaptured = nil                     // 自检不发真实包
        savedSwitchEdge = switchEdge
        switchEdge = .left                   // 复现用户这次出问题的布局（Windows 在左）
        exitCooldownUntil = .distantPast
        edgeRearmPending = false

        let y0: CGFloat = 400
        diag("[MWB] 跨屏自检开始（约 1.5s，请**别动鼠标**）：合成事件模拟"
             + "「从右往左滑出 → 只深入 45px(≈1920) → 再推回左边缘」")

        // ① 跨到对端
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.postSyntheticMove(CGPoint(x: 0, y: y0))
        }
        // ② 只往对端里走 45px（归一化 ≈1920，正是日志里那个值）—— 旧代码到此即失效
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
            guard let self else { return }
            self.diag("[MWB] 跨屏自检#1 已进入对端=\(self.isControllingRemote ? "✅" : "❌")"
                      + " 虚拟位置=(\(Int(self.virtualRemote.x)),\(Int(self.virtualRemote.y)))")
            self.postSyntheticMove(CGPoint(x: -45, y: y0))
        }
        // ③ 宽限期(0.2s)过后，逐步往回推：每步 10px ≈ 归一化 427
        let outward: [CGFloat] = [0, 10, 20, 30, 40, 50, 60, 70, 80, 90]
        for (i, x) in outward.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55 + Double(i) * 0.03) { [weak self] in
                self?.postSyntheticMove(CGPoint(x: x, y: y0))
            }
        }
        // ④ 结论：能不能推回来
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.05) { [weak self] in
            guard let self else { return }
            if self.isControllingRemote {
                self.diag("[MWB] ❌ 跨屏自检未通过：只深入 1920 之后就推不回来了"
                          + "（虚拟位置=(\(Int(self.virtualRemote.x)),\(Int(self.virtualRemote.y)))"
                          + " 向内=\(Int(self.inwardTravel)) 外推=\(Int(self.outwardPush))）")
            } else {
                self.diag("[MWB] ✅ 跨屏自检通过：只浅进 1920 也能顺利推回本机")
            }
        }
        // ⑤ 弹回检查：交回本机后立刻把光标压回边缘，不应被立刻切走
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.10) { [weak self] in
            self?.postSyntheticMove(CGPoint(x: 0, y: y0))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.30) { [weak self] in
            guard let self else { return }
            self.diag(self.isControllingRemote
                      ? "[MWB] ❌ 弹回检查未通过：刚交回本机就被判成顶到边缘、立刻又切走"
                      : "[MWB] ✅ 弹回检查通过：交回本机后压住边缘不会立刻又切走")
        }
        // ⑥ 收尾：还原环境，并把光标挪回屏幕中间（别把用户的光标扔在边缘）
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.45) { [weak self] in
            guard let self else { return }
            if self.isControllingRemote { self.releaseCursor() }
            if let e = self.savedSwitchEdge { self.switchEdge = e }
            self.savedSwitchEdge = nil
            self.onCaptured = self.savedOnCaptured
            self.savedOnCaptured = nil
            let f = self.localScreenFrame(containing: CGPoint(x: 100, y: 100))
            CGWarpMouseCursorPosition(CGPoint(x: f.midX, y: f.midY))
            self.diag("[MWB] 跨屏自检结束，环境已还原")
        }
        return true
    }

    /// 投递一个**不带注入标记**的合成 mouseMoved。
    /// 它会从 cghidEventTap 回来，被完整地当成"真实本机鼠标事件"走一遍 handleMouseMoved。
    private func postSyntheticMove(_ p: CGPoint) {
        if let e = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                           mouseCursorPosition: p, mouseButton: .left) {
            e.post(tap: CGEventTapLocation.cghidEventTap)
        }
    }

    /// 锁定时钟：30Hz 兜底（重申解耦 + 必要时 warp 回锚点）。
    ///
    /// 【为什么提到 30Hz】2026-09-14 对照实验发现，即便「改写坐标 + 清零设备位移 +
    /// 每帧重申解耦」全部开启，WindowServer 仍会**偶发**把累积的设备位移一次性追平
    /// （实测失守偏移量恰为假鼠标累积漂移的整数倍，见 handleMouseMoved 里的说明）。
    /// 这种失守只能靠 warp 拉回，所以频率决定了"失守可见多久"：
    /// 4Hz → 光标能跑掉几百像素才被拉回（用户眼里就是"锁不住"）；
    /// 30Hz → 最多跑 33ms，肉眼几乎看不出来。
    /// 正常时（改写生效）这个 warp 一次都不会触发，所以提频没有额外代价。
    private func startLockTimer() {
        stopLockTimer()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: 0.033, leeway: .milliseconds(8))
        t.setEventHandler { [weak self] in self?.engageCursorLock() }
        t.resume()
        lockTimer = t
    }

    private func stopLockTimer() {
        lockTimer?.cancel()
        lockTimer = nil
    }

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var captureThread: Thread?
    private var captureThreadCancelled = false

    public init() {
        // 这里也读一次环境变量：自检路径（不连接 Windows）不经过
        // Client.configureInput()，只在那里挂环境变量的话，
        // 对照实验会出现「以为自己改了自变量、其实没改」的假结果
        // （2026-09-14 踩过：MWB_ASSOC_PERFRAME=0 看似生效，日志里却仍是 true）。
        if ProcessInfo.processInfo.environment["MWB_ASSOC_PERFRAME"] == "0" {
            assertAssocPerFrame = false
        }
        if ProcessInfo.processInfo.environment["MWB_ZERO_DELTA"] == "0" {
            zeroDeltaWhileLocked = false
        }
    }

    // MARK: - 注入：鼠标

    /// 我们本机注入事件的标记位（写进 CGEvent 的 eventSourceUserData）。
    ///
    /// 【为什么必须有】CGEventTap 挂在 cghidEventTap 上，我们自己 post 出去的注入事件
    /// **也会从同一个 tap 回来**。如果不加标记就会自己吃自己：
    ///  - 对方控制本机时，它的光标停在本机边缘（比如 x≈0），被边缘判定当成
    ///    「用户在往左推」→ 立刻抢控制权 → 两边互相抢，来回踢。
    ///  - 对方注入的键盘事件会被我们当成本地按键再转发回去 → 死循环。
    /// 打上标记后，在 handleTap 里原样放行，不参与任何本地逻辑。
    static let injectedTag: Int64 = 0x4D57_4231   // "MWB1"

    /// 本机注入时当前按下的鼠标键（CGMouseButton.rawValue）。
    /// 决定注入位移该发 mouseMoved 还是 *MouseDragged —— macOS 只有在拖拽事件类型下
    /// 才会把位移当成「按住拖动」，否则接收方只当是移动光标，框选/拖窗口无效。
    private var injectedButtonDown: Set<UInt32> = []

    /// 注入鼠标移动。X/Y 为 MWB 归一化坐标 0..65535（左上原点）。
    public func injectMouseMove(nx: Int32, ny: Int32) {
        let pos = mapNormalizedToScreen(nx: nx, ny: ny)
        let type: CGEventType
        if injectedButtonDown.contains(CGMouseButton.left.rawValue) {
            type = .leftMouseDragged
        } else if injectedButtonDown.contains(CGMouseButton.right.rawValue) {
            type = .rightMouseDragged
        } else if injectedButtonDown.contains(CGMouseButton.center.rawValue) {
            type = .otherMouseDragged
        } else {
            type = .mouseMoved
        }
        if let ev = CGEvent(mouseEventSource: nil, mouseType: type,
                            mouseCursorPosition: pos, mouseButton: .left) {
            ev.setIntegerValueField(.eventSourceUserData, value: Self.injectedTag)
            ev.post(tap: CGEventTapLocation.cghidEventTap)
        }
    }

    /// 注入鼠标按键。flags 为 Windows 鼠标消息；nx/ny 为当前归一化坐标。
    public func injectMouseButton(flags: Int32, nx: Int32, ny: Int32) {
        let pos = mapNormalizedToScreen(nx: nx, ny: ny)
        let (type, button): (CGEventType, CGMouseButton) = {
            switch flags {
            case WM_LBUTTONDOWN: return (.leftMouseDown, .left)
            case WM_LBUTTONUP:   return (.leftMouseUp, .left)
            case WM_RBUTTONDOWN: return (.rightMouseDown, .right)
            case WM_RBUTTONUP:   return (.rightMouseUp, .right)
            case WM_MBUTTONDOWN: return (.otherMouseDown, .center)
            case WM_MBUTTONUP:   return (.otherMouseUp, .center)
            default:             return (.mouseMoved, .left)
            }
        }()
        if let ev = CGEvent(mouseEventSource: nil, mouseType: type,
                            mouseCursorPosition: pos, mouseButton: button) {
            ev.setIntegerValueField(.eventSourceUserData, value: Self.injectedTag)
            ev.post(tap: CGEventTapLocation.cghidEventTap)
        }
        // 记录注入侧的按键状态，供 injectMouseMove 决定发 mouseMoved 还是 *MouseDragged。
        let isDown = (flags == WM_LBUTTONDOWN || flags == WM_RBUTTONDOWN || flags == WM_MBUTTONDOWN)
        if isDown {
            injectedButtonDown.insert(button.rawValue)
        } else {
            injectedButtonDown.remove(button.rawValue)
        }
    }

    /// 注入鼠标滚轮。delta 为 Windows 滚轮值（带方向）。
    public func injectMouseWheel(delta: Int32) {
        let notch = Int(delta) / 120
        if let ev = CGEvent(scrollWheelEvent2Source: nil, units: .line,
                            wheelCount: 1,
                            wheel1: Int32(notch), wheel2: 0, wheel3: 0) {
            ev.setIntegerValueField(.eventSourceUserData, value: Self.injectedTag)
            ev.post(tap: CGEventTapLocation.cghidEventTap)
        }
    }

    // MARK: - 注入：键盘

    /// 注入键盘事件。vk = Windows 虚拟键码；flags: 0=按下, 1=抬起（对齐 KEYBDDATA.dwFlags）。
    public func injectKeyboard(vk: Int32, flags: Int32) {
        guard let code = macKeyCode(from: vk) else {
            // 无法映射的键码保持静默忽略（可在此扩展 keyMap），绝不崩溃
            return
        }
        let keyDown = (flags & 0x80) == 0

        // 维护当前修饰键状态：Shift/Control/Alt/Command 自身按下/抬起时更新标志位，
        // 这样后续普通键（如 Shift+A）注入时才会带上正确掩码，得到大写/组合效果。
        if let mask = Self.modifierMask[vk] {
            if keyDown {
                currentModifierFlags.insert(mask)
            } else {
                currentModifierFlags.remove(mask)
            }
        }

        guard let ev = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: keyDown) else { return }
        ev.flags = currentModifierFlags
        ev.setIntegerValueField(.eventSourceUserData, value: Self.injectedTag)
        ev.post(tap: CGEventTapLocation.cghidEventTap)
    }

    // MARK: - 捕获：本地输入 -> 转发给 Windows

    /// 开始捕获本地鼠标/键盘输入（Mac 作为控制端时启用）。
    /// tap 状态变化回调：(是否可用, 说明)。GUI 用它给出准确的授权指引。
    public var onCaptureStatus: ((Bool, String) -> Void)?

    /// 事件捕获 tap 是否已真正建立。false 表示授权缺失，键鼠跨屏完全不工作。
    public private(set) var tapActive = false

    /// 诊断/状态回调（替代 print，让 GUI 与 /tmp/mwb_gui.log 都能看到）。
    public var onDiagnostic: ((String) -> Void)?
    private func diag(_ s: String) { onDiagnostic?(s) }

    /// tap 实际收到的事件数 —— 判断「到底是授权没生效还是别的环节断了」的关键指标。
    public private(set) var tapEventCount: Int64 = 0
    /// tap 实际收到的**键盘类**事件数（keyDown/keyUp/flagsChanged）。
    ///
    /// 这个数字是排查「鼠标能跨屏、键盘不能」的钥匙：
    /// macOS 上鼠标事件与键盘事件走的是**不同的 TCC 授权**（辅助功能 / 输入监控），
    /// 只授予辅助功能时 tap 能建起来、能收到鼠标事件，但**键盘事件会被静默过滤掉**。
    /// 所以「events 一直在涨、keyEvents 恒为 0」= 输入监控没生效（且多数情况需要
    /// 退出 App 重开才会真正生效，光点 ↻ 不够）。
    public private(set) var keyEventCount: Int64 = 0
    /// 最近一次收到 tap 事件的时间。
    public private(set) var lastTapEventAt: Date?

    /// 控制中心 read-only 快照：给 GUI 显示用。
    public func captureHealth() -> (active: Bool, events: Int64, keyEvents: Int64, idleSeconds: TimeInterval) {
        return (tapActive, tapEventCount, keyEventCount,
                lastTapEventAt.map { Date().timeIntervalSince($0) } ?? -1)
    }

    public func startCapture() {
        stopCapture()
        captureEnabled = true

        // tapDisabledByTimeout/tapDisabledByUserInput 必须订阅：
        // 系统会在负载高或长时间无响应时自动禁用 tap，不重新 enable 就会永远失效。
        var mask: CGEventMask = 0
        // flagsChanged 必须收：否则对端永远不知道 Ctrl/Cmd/Shift 被按下，
        // Ctrl+C、Cmd+V 这类组合键发过去就只是一个普通字母键。
        //
        // 【*MouseDragged 必须订阅】macOS 在「按住任一鼠标键 + 移动」时，
        // 发出的事件类型是 leftMouseDragged / rightMouseDragged / otherMouseDragged，
        // **不再发 mouseMoved**。只订阅 mouseMoved 的话，一按下左键位移就断流，
        // 表现就是「按住左键后远端光标不动、框选/拖拽完全失效」。
        let types: [CGEventType] = [.mouseMoved,
                                    .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                                    .leftMouseDown, .leftMouseUp,
                                    .rightMouseDown, .rightMouseUp, .otherMouseDown,
                                    .otherMouseUp, .scrollWheel, .keyDown, .keyUp,
                                    .flagsChanged,
                                    .tapDisabledByTimeout, .tapDisabledByUserInput]
        for t in types {
            mask |= CGEventMask(1) << CGEventMask(t.rawValue)
        }

        let callback: CGEventTapCallBack = { _, type, event, ref in
            guard let ref else { return Unmanaged.passUnretained(event) }
            let ctrl = Unmanaged<InputController>.fromOpaque(ref).takeUnretainedValue()
            return ctrl.handleTap(type: type, event: event)
        }

        guard let newTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            // 授权缺失时不静默 —— 这是排查「连上了但鼠标跨不过去」的第一现场。
            tapActive = false
            captureEnabled = false
            // 区分具体缺哪一项，避免用户在设置里瞎找：
            // 辅助功能授权 ≠ 输入监控授权，CGEventTap 两者都要。
            let msg: String
            if AXIsProcessTrusted() {
                msg = "⚠️ 缺少「输入监控」授权，无法捕获鼠标键盘。"
                    + " 请到「系统设置 → 隐私与安全性 → 输入监控」勾选 MWB，"
                    + " 然后在菜单栏面板点 ↻ 重试。"
            } else {
                msg = "⚠️ 缺少「辅助功能」授权，无法捕获鼠标键盘。"
                    + " 请在「系统设置 → 隐私与安全性 → 辅助功能」勾选 MWB"
                    + "（若列表里没有 MWB，点 + 添加 /Applications/MWB.app），然后在菜单栏面板点 ↻ 重试。"
            }
            onCaptureStatus?(false, msg)
            return
        }

        tap = newTap
        CGEvent.tapEnable(tap: newTap, enable: true)
        tapActive = true
        // 键表覆盖度自检：历史事故（漏了 9 个字母导致部分键跨屏静默失效）的兜底，
        // 每次建立捕获时把结论打进日志。
        verifyKeyCoverage()

        // 关键：RunLoop source 必须加在【真正运行 RunLoop 的那个线程】上。
        // 之前加在调用方线程（GUI 里是 GCD 后台队列线程），该线程的 RunLoop 从不运转，
        // 导致 tap 建好了却一个事件都收不到 —— 命令行版能工作只是碰巧主线程 RunLoop 一直在转。
        captureThreadCancelled = false
        captureThread = Thread { [weak self] in
            guard let self, let t = self.tap else { return }
            if let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0) {
                CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
            }
            while !self.captureThreadCancelled {
                _ = CFRunLoopRunInMode(.defaultMode, 0.5, true)
            }
        }
        captureThread?.name = "MWBCapture"
        captureThread?.start()

        let msg = "输入捕获已启动 ✓"
        // 权限自检：这两项是「鼠标能过、键盘不能过」的根因所在。
        // 辅助功能 = AXIsProcessTrusted()；输入监控 = CGPreflightListenEventAccess()。
        // macOS 上它们**是两套独立授权**：只授辅助功能时 tap 能建起来、鼠标事件照常到达，
        // 但键盘事件会被系统静默过滤掉（keyEventCount 恒为 0）。
        diag("[MWB] 权限自检: 辅助功能=\(AXIsProcessTrusted() ? "✓" : "✗")"
             + "  输入监控=\(CGPreflightListenEventAccess() ? "✓" : "✗")")
        if !CGPreflightListenEventAccess() {
            // 主动弹官方授权框：系统会把本 App 自动加进「输入监控」列表并高亮，
            // 比让用户在列表里手动找 / 手动 + 添加可靠得多。
            // 这一项是「鼠标能跨屏、键盘不能」的唯一开关：macOS 只授辅助功能时
            // tap 照样建得起来、鼠标事件照常到达，但**键盘事件被静默丢弃**。
            _ = CGRequestListenEventAccess()
            diag("[MWB] ⚠️ 「输入监控」未授权 —— 键盘事件会被系统静默丢弃（鼠标不受影响）。"
                 + "已弹出系统授权框，请在「隐私与安全性 → 输入监控」勾选 MWB。"
                 + "勾选后请**完全退出 MWB 再重新打开**（必要时点面板 ↻ 重建捕获）。")
        }
        onCaptureStatus?(true, msg)
    }

    /// 停止捕获（重新授权后调用 startCapture 可重试）。
    public func stopCapture() {
        // 必须恢复光标关联，否则退出后鼠标就再也推不动光标了。
        releaseCursor()
        captureThreadCancelled = true
        if let t = tap {
            CGEvent.tapEnable(tap: t, enable: false)
            CFMachPortInvalidate(t)
        }
        tap = nil
        runLoopSource = nil
        captureThread = nil
        tapActive = false
        captureEnabled = false
    }

    private func handleTap(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // ★★ 【必须放在最前面】系统把 tap 禁用掉的信号。
        //
        // 【为什么它可能是「光标锁不住」的真凶】tap 一旦被禁用，**所有事件都不再经过
        // 我们的回调** —— 也就是说事件坐标改写（锁定的核心动作）根本没机会执行，
        // 光标会跟着物理鼠标自由地满屏跑，直到我们重新启用 tap 为止。
        // 而且禁用期间本机输入也不受控（键盘会漏给本机）。
        //
        // 触发条件是「回调耗时超过系统阈值」，而**真实跨屏时每帧都要发网络包**
        // （自检时 onCaptured=nil 不发包，所以自检永远是 ✅，测不出这一类问题）。
        //
        // 以前这条分支放在 switch 末尾：能重新启用，但**没有任何日志** ——
        // 排查时完全看不见"tap 被禁用过"。现在记账 + 打日志，且提前到最前端第一时间恢复。
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            tapDisabledCount += 1
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            lastTapDisabledAt = Date()
            if tapDisabledCount <= 5 || tapDisabledCount % 20 == 0 {
                diag("[MWB] ⚠️ 事件 tap 被系统禁用第 \(tapDisabledCount) 次（\(type == .tapDisabledByTimeout ? "超时" : "用户输入")）"
                     + " —— 已立刻重新启用。禁用期间**锁定逻辑不执行**，"
                     + "若发生在跨屏控制中，本机光标会短暂自由移动。")
            }
            return Unmanaged.passUnretained(event)
        }

        guard captureEnabled else { return Unmanaged.passUnretained(event) }

        // 【必须最先判断】自己注入给对方的事件会从同一个 tap 回来。
        // 原样放行、不参与任何本地逻辑，否则会自我触发边缘切换 / 键盘回环。
        if event.getIntegerValueField(.eventSourceUserData) == Self.injectedTag {
            return Unmanaged.passUnretained(event)
        }

        // 只要有事件进来，就说明「辅助功能 + 输入监控」授权是真的生效了。
        // 这个计数是排查「连上了但鼠标跨不过去」的钥匙：为 0 就一定是授权/权限链路问题。
        tapEventCount += 1
        lastTapEventAt = Date()

        // 单独统计键盘类事件：鼠标通、键盘不通的典型原因是「输入监控」授权没落到这个二进制上
        // （macOS 对键盘事件走 kTCCServiceListenEvent，与鼠标用的辅助功能是两套授权）。
        if type == .keyDown || type == .keyUp || type == .flagsChanged {
            keyEventCount += 1
            if keyEventCount <= 3 {
                diag("[MWB] 键盘事件#\(keyEventCount) type=\(type.rawValue) 控制远端=\(isControllingRemote)")
            }
        }

        let loc = event.location

        // 紧急召回热键: Control + Option + Esc —— 无论什么状态都立刻夺回本机控制，
        // 并且无条件恢复光标联动（万一处于解耦状态，这是唯一的自救手段）。
        if type == .keyDown, isPanicKey(event) {
            leaveRemote(restoreCursor: true, reason: "紧急热键 Ctrl+Opt+Esc")
            releaseCursor()   // 兜底：万一当时并不在远端控制态，也确保恢复联动
            return nil
        }

        // ★★ 隐藏光标必须在**每一个鼠标事件**上重申，不能只靠定时器。
        //
        // 【为什么这是「控制 Windows 时本机光标还在乱跑」的关键】
        // `CGDisplayHideCursor` 设的是系统级隐藏计数，但系统会在**真实设备输入**
        // （物理鼠标移动/按键）等时机把光标重新显示出来；而我们原来的重申被节流到
        // 2Hz（0.5s 一次）。于是连续移动鼠标时「显示窗口」远长于「隐藏窗口」——
        // 用户看到的就是光标一直跟着鼠标在 Mac 屏上跑。
        // 事件级重申把这条腿压到毫秒级，内部仍保留 10ms 节流，
        // 避免 1000Hz 鼠标把 hide 计数推到天文数字。
        let isMouseType: Bool = {
            switch type {
            case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                 .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                 .otherMouseDown, .otherMouseUp, .scrollWheel:
                return true
            default:
                return false
            }
        }()
        if isMouseType, captureEnabled, isControllingRemote {
            hideSystemCursor()
        }

        switch type {
        case .mouseMoved:
            return handleMouseMoved(loc, event: event)

        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            // 拖拽位移与普通位移同源处理：远端协议里两者都是 WM_MOUSEMOVE，
            // 按键的「按住」状态由前面的 Down 包在 Windows 侧保持。
            //
            // 未控制远端时必须原样放行 —— 否则本机自己的框选、拖窗口、拖文件
            // 会被我们吞掉（tap 挂在 headInsert 位置，吞了就是真的没反应了）。
            guard isControllingRemote else { return Unmanaged.passUnretained(event) }
            return handleMouseMoved(loc, event: event)

        case .leftMouseDown, .rightMouseDown, .otherMouseDown,
             .leftMouseUp, .rightMouseUp, .otherMouseUp:
            // ★★ 本机左键抬起 = Win→Mac 拖放的「松手投放」那一拍（PowerToys DragDropStep09）。
            //    必须放在下面的 swallowingInput 守卫**之前**：用户把光标推回本机再松手时
            //    swallowingInput 已经是 false，放守卫之后就什么都不会发生（文件拉不回来）。
            //    回调方自己判断是否处于「对端投放态」，不在投放态时是空操作。
            if type == .leftMouseUp { onLocalLeftMouseUp?() }
            // 未取得远端控制权时，点击/按键都属于本机，绝不转发。
            // 自检期间同理（swallowingInput 为 false）—— 那 6 秒用户仍要能正常点本机。
            guard swallowingInput else { return Unmanaged.passUnretained(event) }
            let (downFlag, upFlag): (Int32, Int32) = {
                switch type {
                case .leftMouseDown, .leftMouseUp:   return (WM_LBUTTONDOWN, WM_LBUTTONUP)
                case .rightMouseDown, .rightMouseUp: return (WM_RBUTTONDOWN, WM_RBUTTONUP)
                default:                             return (WM_MBUTTONDOWN, WM_MBUTTONUP)
                }
            }()
            let isDown = (type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown)
            // 记录「已转发但还没抬起」的键，离开远端时补发抬起，防止 Windows 卡在拖拽态。
            if isDown { remotePressedButtons.insert(downFlag) } else { remotePressedButtons.remove(downFlag) }
            var p = DataPacket(type: .mouse)
            p.mouseFlags = isDown ? downFlag : upFlag
            p.mouseX = Int32(virtualRemote.x)
            p.mouseY = Int32(virtualRemote.y)
            onCaptured?(p)
            return nil // 远端控制时吞掉本地点击，避免同时操作两台机器

        case .scrollWheel:
            guard swallowingInput else { return Unmanaged.passUnretained(event) }
            let dy = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
            var p = DataPacket(type: .mouse)
            p.mouseFlags = WM_MOUSEWHEEL
            p.mouseWheel = Int32(dy) * 120
            onCaptured?(p)
            return nil

        case .flagsChanged:
            return handleFlagsChanged(event)

        case .keyDown, .keyUp:
            // 键盘跟随控制权：只有控制了远端才转发。
            guard swallowingInput else { return Unmanaged.passUnretained(event) }
            let rawVK = event.getIntegerValueField(.keyboardEventKeycode)
            if let wvk = windowsVK(fromMac: Int32(rawVK)) {
                var p = DataPacket(type: .keyboard)
                p.keyVk = wvk
                p.keyFlags = (type == .keyDown) ? 0 : 0x80
                if keyProbe < 4 {
                    keyProbe += 1
                    diag("[MWB] 键盘包#\(keyProbe) vk=0x\(String(wvk, radix: 16))"
                        + " \(type == .keyDown ? "按下" : "抬起")")
                }
                onCaptured?(p)
            } else if keyProbe < 4 {
                keyProbe += 1
                diag("[MWB] 键盘：Mac keycode \(rawVK) 无对应 Windows VK，已忽略")
            }
            return nil

        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // 已在 handleTap 最前面统一处理（那里会记账 + 打日志 + 立刻重新启用）。
            // 这里保留一个兜底分支，防止将来有人把前面的判断挪走。
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    // MARK: - 修饰键同步

    /// 上一次见到的修饰键状态（CGEvent.flags），用于 diff 出「哪个键变了」。
    private var lastFlags: CGEventFlags = []

    /// 只按修饰键（Ctrl/Cmd/Shift/Alt）时系统只发 flagsChanged、不发 keyDown/keyUp。
    /// 必须把变化单独补发成键盘包，否则对端收不到组合键的修饰部分。
    private func handleFlagsChanged(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let f = event.flags
        let prev = lastFlags
        lastFlags = f

        guard swallowingInput else { return Unmanaged.passUnretained(event) }

        // Mac: Shift / Control / Option(Alt) / Command(Win)
        let defs: [(CGEventFlags, Int32)] = [(.maskShift, 0x10), (.maskControl, 0x11),
                                             (.maskAlternate, 0x12), (.maskCommand, 0x5B)]
        for (mask, vk) in defs where prev.contains(mask) != f.contains(mask) {
            var p = DataPacket(type: .keyboard)
            p.keyVk = vk
            p.keyFlags = f.contains(mask) ? 0 : 0x80   // 0=按下, 0x80=抬起
            onCaptured?(p)
        }
        return nil
    }

    // MARK: - 屏幕边缘切换状态机

    private func isPanicKey(_ event: CGEvent) -> Bool {
        let flags = event.flags
        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        return keycode == 53 // Esc
            && flags.contains(.maskControl) && flags.contains(.maskAlternate)
    }

    private func handleMouseMoved(_ loc: CGPoint, event: CGEvent) -> Unmanaged<CGEvent>? {
        if !isControllingRemote {
            // 位移尺度自检（只在本机自由移动时做 —— 此时 location 差分真实有效）。
            // 目的：分辨 delta 字段的单位是「屏幕逻辑点」还是「Retina 物理像素」。
            // 比值 ≈1.0 正常；≈2.0 表示远端光标会跑两倍快，手感就是「不跟手」。
            // 只统计"像样的一次移动"（滤掉亚像素抖动），满 40 个样本报一次。
            if deltaScaleProbeCount <= 40 {
                let ddx = abs(event.getDoubleValueField(.mouseEventDeltaX))
                let ddy = abs(event.getDoubleValueField(.mouseEventDeltaY))
                let ldx = abs(loc.x - lastLocalPoint.x)
                let ldy = abs(loc.y - lastLocalPoint.y)
                if ddx + ddy >= 4, ldx + ldy >= 4 {
                    deltaScaleProbeCount += 1
                    deltaAbsSum += ddx + ddy
                    locAbsSum += ldx + ldy
                    if deltaScaleProbeCount == 40 {
                        deltaScaleProbeCount = 41        // 只报一次
                        let ratio = deltaAbsSum / max(locAbsSum, 1)
                        diag("[MWB] 位移尺度自检：Σ|delta| / Σ|locΔ| = "
                             + "\(String(format: "%.2f", ratio))"
                             + "（≈1.0 正常；≈2.0 表示 delta 是物理像素而参考尺寸是逻辑点，"
                             + "远端光标会跑 2 倍快 —— 这就是「不跟手」的一种成因）")
                    }
                }
            }
            // 本机控制中：只有顶到指定边缘才交出控制权。
            if hasCrossedEdge(loc) {
                enterRemote(at: loc)
                return nil // 吞掉这一帧，本机光标停在边缘
            }
            lastLocalPoint = loc
            return Unmanaged.passUnretained(event)
        }

        // 远端控制中：用【设备原始位移】驱动远端虚拟光标。
        //
        // 必须用 event 的 delta 字段，而不是两帧 location 的差：本机光标一旦顶到屏幕
        // 边缘就被 macOS 钳死，location 差恒为 0，远端光标会彻底不动 —— 这正是
        // 「Mac 跨不过去」的根因。而 mouseEventDeltaX/Y 是设备上报的原始位移，钳位时依然有效。
        //
        // ⚠️ delta 必须在下面「改写坐标」之前读，否则读到的是被我们改过的值。
        // 设备位移的取数自检：delta 字段 vs location 差分。
        // 两者应当**同量级**（都按屏幕逻辑点计）。若 delta 恒为 location 差分的
        // 2 倍左右，说明 delta 是物理像素而 location 是逻辑点（Retina 缩放），
        // 那运动参考尺寸也得用物理像素，否则远端光标速度会翻倍（"不跟手"的一种）。
        let locDx = loc.x - lastLocalPoint.x
        let locDy = loc.y - lastLocalPoint.y
        var dx = CGFloat(event.getDoubleValueField(.mouseEventDeltaX))
        var dy = CGFloat(event.getDoubleValueField(.mouseEventDeltaY))
        let usedFallback = (dx == 0 && dy == 0)
        if usedFallback {
            // 兜底：合成事件（例如 warp 产生）没有 delta，退回 location 差分
            dx = locDx
            dy = locDy
        }
        lastLocalPoint = loc

        // 滤掉「兜底 warp」自己派生出来的事件。
        // 它的 delta = 锚点 − 跑掉的当前位置，是锁定补偿、不是用户输入；
        // 转给对端会让远端光标莫名其妙地抽一下。
        if Date().timeIntervalSince(lastWarpAt) < 0.03 {
            dx = 0
            dy = 0
        }

        // ★ 锁住本机光标：把事件坐标改写成锚点，然后**照常放行**。
        //
        // 这是实测唯一有效的做法（见上面「光标锁定」小节说明 ④）：
        //   · 只 `return nil` 吞掉事件 —— 光标照样跟着物理鼠标跑（实测位移 480px）；
        //   · 只把 delta 清零后放行 —— 同样没用（实测位移 480px）；
        //   · 把 location 改写成锚点后放行 —— 位移 0px ✅。
        // WindowServer 会按我们给的坐标把光标放到锚点，于是光标就「钉」在屏幕边缘，
        // 既不会跟着物理鼠标在 Mac 上乱跑，也不影响本机 App（事件仍正常送达）。
        if lockCursorWhileRemote {
            // ★★ 每帧重申解耦 —— 这是 2026-09-14 修掉的回归。
            //
            // 上一版认为「本应用是 LSUIElement、不在前台，该调用是 no-op」而把它删掉，
            // 结果用户立刻反馈「鼠标到 Windows 之后又锁不住了」。实际机制是：
            //   · 光标关联是 WindowServer 的**全局状态**，任何 App 切前台、
            //     系统注入事件等时机都可能把它悄悄恢复；
            //   · 而下面「改写事件坐标」只有在**已解耦**时才拦得住光标 ——
            //     解耦时系统不拿设备位移驱动光标，我们给的坐标才说了算。
            // 也就是说：解耦不是"免费保险"，而是改写的**前提条件**，
            // 缺失它 → 改写形同虚设 → 光标又开始跟着物理鼠标跑。
            // 每次调用几十微秒，相对 1000Hz 的鼠标事件流可以忽略，不必再"优化"。
            if assertAssocPerFrame,
               CGAssociateMouseAndMouseCursorPosition(0) == .success {
                assocReassertCount += 1
            }
            event.location = entryLocalPoint
            // ★★ 同时把**设备位移清零** —— 2026-09-14 对照实验挖出来的第二个必要条件。
            //
            // WindowServer 内部有两条腿：① 事件给的 location；② 设备位移累加
            // （`光标位置 += 设备 delta`）。只改写 ① 并不妨碍 ② 继续累加，
            // 累加到某个时机（典型触发是有**真实设备输入**进来时它会重新同步光标）
            // 就会一次性把光标"追平"到累积位置 —— 表现为「锁了一两秒后光标突然跳一下」，
            // 紧接着被 10Hz 兜底 warp 拉回，肉眼看到的就是「一顿一顿」。
            //
            // 实测证据：失守时偏移量恰到好处等于累积位移 ——
            //   偏移 (216,108) == 假鼠标 1.8s 的累计 (4×30×1.8, 2×30×1.8)，
            // 且三组对照里"开/关每帧重申解耦"都出现过失守，说明它不是充分条件。
            // 清零 delta 之后两条腿都被按住，锁定才是真的。
            //
            // 顺序要紧：上面已经读过 dx/dy 并列进 lastLocalPoint 了，
            // 这里清零不会影响给对端发的位移。
            if zeroDeltaWhileLocked {
                event.setIntegerValueField(.mouseEventDeltaX, value: 0)
                event.setIntegerValueField(.mouseEventDeltaY, value: 0)
            }
        }

        // 诊断：进入远端后采样前几个位移，用来确认 delta 是否可用、符号与量级是否正确。
        if deltaProbe < 4 {
            deltaProbe += 1
            diag("[MWB] 位移采样#\(deltaProbe) dx=\(Int(dx)) dy=\(Int(dy))"
                + " loc=(\(Int(loc.x)),\(Int(loc.y)))"
                + " locΔ=(\(Int(locDx)),\(Int(locDy)))"
                + (usedFallback ? " [源=loc差分]" : " [源=delta字段]")
                + " → 远端=(\(Int(virtualRemote.x)),\(Int(virtualRemote.y)))")
        }

        virtualRemote.x = clamp65535(virtualRemote.x + dx / motionRefSize.width * 65535)
        // 两侧原点一致（MWB 归一化坐标左上原点，CGEvent.location 也是左上原点），同号累加。
        virtualRemote.y = clamp65535(virtualRemote.y + dy / motionRefSize.height * 65535)

        // 把新位置发给 Windows（带 8ms 限流，见 sendMouseMovePacket 说明）
        sendMouseMovePacket()

        // 从入口向内走过的距离 —— 用于「退回边缘」的迟滞判定，
        // 否则手指轻微回抖一格就会被立刻踢回本机，看起来像根本进不去。
        // ⚠️ 只算【垂直于入口边】的那一个轴：纵向抖动不算「走进去了」。
        let inward: CGFloat
        /// 沿入口边外侧方向的位移（正数 = 正在往外推）
        let outwardAxis: CGFloat
        /// 远端光标是否贴住了入口边
        let atBoundary: Bool
        switch switchEdge {
        case .left:   // 入口 = 对端右边缘，向内 = 往左（x 减小）
            inward = entryRemotePoint.x - virtualRemote.x
            outwardAxis = dx / motionRefSize.width * 65535
            atBoundary = virtualRemote.x >= 65535
        case .right:  // 入口 = 对端左边缘，向内 = 往右（x 增大）
            inward = virtualRemote.x - entryRemotePoint.x
            outwardAxis = -dx / motionRefSize.width * 65535
            atBoundary = virtualRemote.x <= 0
        case .top:    // 入口 = 对端下边缘（y=65535），向内 = 往上（dy<0）
            inward = entryRemotePoint.y - virtualRemote.y
            // 往外推 = 往下（dy>0）→ 必须取 +dy。
            // 旧代码写成 -dy，于是 outwardPush 永远累成负数 ——
            // **上下布局下 100% 回不到本机**（这是本次一并修掉的第二个"回不来"根因）。
            outwardAxis = dy / motionRefSize.height * 65535
            atBoundary = virtualRemote.y >= 65535
        case .bottom: // 入口 = 对端上边缘（y=0），向内 = 往下（dy>0）
            inward = virtualRemote.y - entryRemotePoint.y
            // 往外推 = 往上（dy<0）→ 必须取 -dy。旧代码写成 +dy，同样永远回不去。
            outwardAxis = -dy / motionRefSize.height * 65535
            atBoundary = virtualRemote.y <= 0
        }
        inwardTravel = max(inwardTravel, inward)
        if atBoundary && outwardAxis > 0 {
            outwardPush += outwardAxis
        } else {
            outwardPush = 0
        }

        // 反向推出入口边界 -> 控制权交回本机。三个条件缺一不可：
        //  ① 没有按住任何鼠标键（否则框选/拖窗口拖到边缘会被硬生生打断）；
        //     ★ 例外：对端正把文件投放到本机（fileDropInProgress）时**即使按着键也要放行** ——
        //       拖文件过来全程都按着左键，不放的话投放永远落不到 Mac 上（实测就是这个原因）。
        //  ② 已过进入宽限期 entryGraceUntil（不能刚进去就被弹回）；
        //  ③ 外推是持续的、累计够量（单帧抖动不算）。
        // 另：自检期间一律不许退出（自检本来就没有「对端」）。
        //
        // ★ 不再要求 `inwardTravel > exitMinInward(4000)`（旧门槛）。那个门槛配合
        //   "inwardTravel 只取 max、永不衰减"，会把"只在边缘进出、没往对端深处走"
        //   的用户**永久锁死** —— 2026-09-14 日志实测：用户从 Mac 左边缘滑出去后
        //   只走进对端 1920（< 4000），于是退出条件再也无法成立，彻底回不来。
        //   改用【时间】宽限做迟滞：既挡得住"擦边刚进就被弹回"，又不会把人锁死。
        //   inwardTravel 保留下来只用于日志诊断。
        if !isSelfTesting,
           Date() > entryGraceUntil,
           (remotePressedButtons.isEmpty || fileDropInProgress),
           outwardPush > Self.exitMinOutward {
            leaveRemote(restoreCursor: true,
                        reason: "推出边缘 dx=\(Int(dx)) dy=\(Int(dy))"
                              + " 向内=\(Int(inwardTravel)) 外推=\(Int(outwardPush))")
        }
        // ★ 必须放行（不能 return nil）：上面改写事件坐标正是靠「事件被送到
        //   WindowServer」才生效的，吞掉就等于没改（实测吞掉时光标位移 480px）。
        return Unmanaged.passUnretained(event)
    }

    private func clamp65535(_ v: CGFloat) -> CGFloat { min(max(v, 0), 65535) }

    /// 是否顶到触发边缘（并且再向外推）。
    /// 注意 CGEvent.location 是【左上原点】：y 越小越靠上。
    private func hasCrossedEdge(_ loc: CGPoint) -> Bool {
        let f = localScreenFrame(containing: loc)
        let atEdge: Bool
        switch switchEdge {
        case .right:  atEdge = loc.x >= f.maxX - 1
        case .left:   atEdge = loc.x <= f.minX + 1
        case .top:    atEdge = loc.y <= f.minY + 1     // 上边缘 = y 最小
        case .bottom: atEdge = loc.y >= f.maxY - 1     // 下边缘 = y 最大
        }

        // ① 刚交回本机的冷却期内，一律不许再进入远端。
        //    没有这一步会出现"推回来的一瞬间又被判成顶到边缘 → 立刻返回对端"的弹回。
        if Date() < exitCooldownUntil { return false }

        // ①' 对端正把文件投放到本机 —— 期间绝不再接管远端。
        //    否则刚交回控制权、光标还在边缘，就会被判成"又撞到边缘"而立刻跳回 Windows，
        //    文件永远落不到 Mac 上（投放带只认本机侧的松手）。
        if fileDropInProgress { return false }

        // ② 冷却结束后还要等物理光标真正离开边缘区，才重新武装。
        //    用户"推回来"的惯性常常把光标一直压在边缘上，只看时间的话冷却一结束
        //    就会立刻重进 —— 体感就是"回不来"。
        if edgeRearmPending {
            // 解除条件：光标离开边缘，或冷却结束后再等 0.7s。
            // 加时间上限是因为"用户退出后一直压着边缘不动"时不会产生任何事件，
            // 光靠 !atEdge 永远解除不了，会把用户锁在本机侧（推不过去）。
            if !atEdge || Date() > exitCooldownUntil.addingTimeInterval(0.7) {
                edgeRearmPending = false
            }
            return false
        }
        return atEdge
    }

    /// 进入远端控制：按屏幕摆放顺序，从对端的对应边进入。
    private func enterRemote(at loc: CGPoint?) {
        if let loc {
            let (_, ny) = mapScreenToNormalized(pos: loc)
            entryLocalPoint = loc
            switch switchEdge {
            case .right:  virtualRemote = CGPoint(x: 0, y: CGFloat(ny))          // 从对端左边缘进入
            case .left:   virtualRemote = CGPoint(x: 65535, y: CGFloat(ny))      // 从对端右边缘进入
            case .top:    virtualRemote = CGPoint(x: 32767, y: 65535)            // 从对端下边缘进入
            case .bottom: virtualRemote = CGPoint(x: 32767, y: 0)                // 从对端上边缘进入
            }
        }
        isControllingRemote = true
        // 新一轮控制开始：可见性采样归零，心跳/自检报的就是「这一场」的占比。
        resetCursorVisibilitySamples()
        lastLocalPoint = loc ?? lastLocalPoint

        // 确定「本机位移 -> 远端归一化位移」的参考尺寸。
        // proportional: 用本机屏幕尺寸 —— 与对端分辨率完全无关，换显示器也不用改配置；
        // pixelExact:   用用户填的对端分辨率 —— 本机移动 1 像素 = 对端移动 1 像素。
        let localFrame = localScreenFrame(containing: loc ?? lastLocalPoint)
        switch motionScale {
        case .proportional:
            motionRefSize = CGSize(width: localFrame.width, height: localFrame.height)
        case .pixelExact:
            motionRefSize = remoteScreenSize
        }
        diag("[MWB] 位移映射=\(motionScale == .proportional ? "按本机屏幕比例" : "按对端像素1:1")"
             + " 参考=\(Int(motionRefSize.width))x\(Int(motionRefSize.height))")

        entryRemotePoint = virtualRemote
        inwardTravel = 0
        outwardPush = 0
        // 防抖宽限：这 0.2s 内不判定退出，避免"擦着边缘过去、立刻又被弹回本机"。
        entryGraceUntil = Date().addingTimeInterval(0.20)
        // 清掉上一次退出留下的冷却/重装状态（我们是真的又进来了）。
        exitCooldownUntil = .distantPast
        edgeRearmPending = false
        deltaProbe = 0
        keyProbe = 0
        lockReported = false
        lastLockHealthAt = .distantPast

        // 关键：把「鼠标」和「光标」解耦。CGEventTap 里 return nil 只能阻止事件往下传，
        // **挡不住系统光标自己跟着鼠标跑** —— 这就是「到了 Windows 后本机光标还在动」的原因。
        // 解耦后光标不动，位移全部用来驱动远端光标；离开时再恢复关联。
        engageCursorLock()
        // 再从主线程重申一次：这一步不受捕获线程 RunLoop 状态影响，更稳。
        DispatchQueue.main.async { [weak self] in self?.engageCursorLock() }
        // 低频兜底重申（30Hz / 0.033s；其中 hide 自带 0.5s 节流 → 实际 2Hz）。
        // 防止系统在后台把"鼠标-光标"关联恢复、或把隐藏的光标重新显示出来。
        startLockTimer()
        // 限流补发定时器：保证被 8ms 限流挡下的「最后一次位置」一定送得出去
        startMouseFlushTimer()

        diag("[MWB] 控制权已切换到 Windows ⟶  (入口=\(switchEdge) 落点=\(Int(virtualRemote.x)),\(Int(virtualRemote.y)))")
        onSwitchChanged?(true)

        sendMouseMovePacket(force: true)
    }

    /// 把仍按住的鼠标键补发抬起包给 Windows。
    /// 场景：用户在 Windows 上拖拽到一半就推出边缘/断开连接，不补发抬起的话
    /// 那边会永久停在「按住左键」状态（表现为点一下变成拖拽）。
    private func releaseRemoteButtons() {
        let pending = remotePressedButtons
        guard !pending.isEmpty else { return }
        remotePressedButtons.removeAll()
        for downFlag in pending {
            let upFlag: Int32 = (downFlag == WM_LBUTTONDOWN) ? WM_LBUTTONUP
                             : (downFlag == WM_RBUTTONDOWN) ? WM_RBUTTONUP : WM_MBUTTONUP
            var p = DataPacket(type: .mouse)
            p.mouseFlags = upFlag
            p.mouseX = Int32(virtualRemote.x)
            p.mouseY = Int32(virtualRemote.y)
            onCaptured?(p)
        }
        diag("[MWB] 离开远端：已补发 \(pending.count) 个鼠标抬起包（避免对端卡在拖拽态）")
    }

    /// 交回本机控制。
    /// 外部（链路看门狗）强制把控制权交回本机。
    ///
    /// 链路断掉时必须调用：否则输入仍被吞在本机、本机光标仍锁在屏幕边缘，
    /// 用户会以为「鼠标卡在 Windows 里出不来」，而实际是包全发不出去。
    public func forceReleaseRemote(reason: String) {
        guard isControllingRemote else { return }
        leaveRemote(restoreCursor: true, reason: reason)
    }

    private func leaveRemote(restoreCursor: Bool, reason: String = "", releaseButtons: Bool = true) {
        guard isControllingRemote else { return }
        isControllingRemote = false

        // 先补发鼠标抬起，再切状态：保证 Windows 不会残留按住的键。
        // ⚠️ 唯一的例外是文件拖放（releaseButtons=false）：那时补发抬起会让 Windows
        //    的拖放状态机以为"拖拽被取消"，进而清掉待传文件（LastDragDropFile），
        //    我们就再也拉不到了。拖放路径的收尾由 finishFileDrop() 负责。
        if releaseButtons { releaseRemoteButtons() }
        // 先停掉锁定兜底定时器/限流补发定时器、恢复「鼠标 -> 光标」关联，再做 warp，
        // 否则 warp 可能被忽略。
        stopLockTimer()
        stopMouseFlushTimer()
        // ★ 必须恢复光标显示：leaveRemote 是独立于 releaseCursor 的路径
        //   （正常"推回本机"走的是这里），漏了就会留下一个**永久隐身的光标**。
        showSystemCursor()
        CGAssociateMouseAndMouseCursorPosition(1)
        // 交回本机后进入冷却：期内不许再进入远端（否则推回来的惯性会立刻把我们送回对端）。
        exitCooldownUntil = Date().addingTimeInterval(0.5)
        edgeRearmPending = true
        diag("[MWB] 控制权已回到本机 ⟵ \(reason)")
        onSwitchChanged?(false)

        if restoreCursor {
            let f = localScreenFrame(containing: lastLocalPoint)
            let target: CGPoint
            // 恢复到「进入时的高度/位置」而不是屏幕中点，手感才不会跳。
            switch switchEdge {
            case .right:  target = CGPoint(x: f.maxX - edgeInset, y: entryLocalPoint.y)
            case .left:   target = CGPoint(x: f.minX + edgeInset, y: entryLocalPoint.y)
            case .top:    target = CGPoint(x: entryLocalPoint.x, y: f.minY + edgeInset)
            case .bottom: target = CGPoint(x: entryLocalPoint.x, y: f.maxY - edgeInset)
            }
            CGWarpMouseCursorPosition(target)
            lastLocalPoint = target
        }
    }

    /// 所有屏幕在 **CG 全局坐标系（左上原点）** 下的矩形。
    /// NSScreen.frame 是 AppKit 坐标（左下原点），直接和 CGEvent.location 混用会错，
    /// 尤其是边缘判断和 CGWarpMouseCursorPosition（它要求的正是 CG 坐标）。
    private func cgScreenFrames() -> [CGRect] {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return [] }
        let base = screens.first { $0.frame.origin == .zero } ?? screens[0]
        let mainH = base.frame.height
        return screens.map { s in
            CGRect(x: s.frame.minX,
                   y: mainH - s.frame.maxY,
                   width: s.frame.width,
                   height: s.frame.height)
        }
    }

    /// 光标所在的那块屏幕（多显示器时用它判断真实的屏幕边界），返回 CG 坐标。
    private func localScreenFrame(containing loc: CGPoint) -> CGRect {
        let frames = cgScreenFrames()
        for f in frames where f.contains(loc) { return f }
        for f in frames where f.contains(lastLocalPoint) { return f }
        return frames.first ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
    }

    // MARK: - 坐标映射

    private func mainScreenSize() -> CGSize {
        if let screen = NSScreen.main {
            return screen.frame.size
        }
        return CGSize(width: 1920, height: 1080)
    }

    private func mapNormalizedToScreen(nx: Int32, ny: Int32) -> CGPoint {
        let size = mainScreenSize()
        // MWB 线格式与 CGEvent.location **同为左上原点**（已对微软开源实现逐行核对：
        // Md.Y = (e.Y - primaryScreenBounds.Top) * 65535 / screenHeight），
        // 所以这里绝不能再翻转 Y —— 之前多翻了一次，正是「上下移动是反的」的根因。
        let x = CGFloat(nx) / 65535.0 * size.width
        let y = CGFloat(ny) / 65535.0 * size.height
        return CGPoint(x: x, y: y)
    }

    private func mapScreenToNormalized(pos: CGPoint) -> (Int32, Int32) {
        let size = mainScreenSize()
        let nx = Int32(min(max(pos.x / size.width * 65535.0, 0), 65535))
        let ny = Int32(min(max(pos.y / size.height * 65535.0, 0), 65535))
        return (nx, ny)
    }

    // MARK: - 键码映射

    /// 单一数据源：Windows VK <-> Mac keycode 对照表。
    /// 两个方向的字典都从这里推导，避免两张手写表不一致。
    /// 旧版因为手写字典字面量出现重复 key（0x30 与 0x30+0），在运行时触发
    /// Dictionary.init(dictionaryLiteral:) 断言直接崩溃；这里改为 static 常量、由数组推导。
    private static let keyMap: [(vk: Int32, mac: CGKeyCode)] = [
        // 字母：A–Z 全覆盖，按 Mac keycode 升序排列
        //
        // ⚠️ 历史事故（2026-09-14）：这张表曾经漏掉 I J K L M N O P U 九个字母。
        //    表现是「跨屏到 Windows 后 y/u/i/h/j/k/n/m 之类的键打不出来」，
        //    而且**完全静默** —— windowsVK(fromMac:) 找不到映射就直接丢弃事件，
        //    日志里只留一行「Mac keycode 32 无对应 Windows VK，已忽略」（32 = U）。
        //    兜底：startCapture() 里的 verifyKeyCoverage() 会做覆盖度自检并打进日志。
        (0x41, 0x00), // A
        (0x53, 0x01), // S
        (0x44, 0x02), // D
        (0x46, 0x03), // F
        (0x48, 0x04), // H
        (0x47, 0x05), // G
        (0x5A, 0x06), // Z
        (0x58, 0x07), // X
        (0x43, 0x08), // C
        (0x56, 0x09), // V
        (0x42, 0x0B), // B
        (0x51, 0x0C), // Q
        (0x57, 0x0D), // W
        (0x45, 0x0E), // E
        (0x52, 0x0F), // R
        (0x59, 0x10), // Y
        (0x54, 0x11), // T
        (0x4F, 0x1F), // O
        (0x55, 0x20), // U
        (0x49, 0x22), // I
        (0x50, 0x23), // P
        (0x4C, 0x25), // L
        (0x4A, 0x26), // J
        (0x4B, 0x28), // K
        (0x4E, 0x2D), // N
        (0x4D, 0x2E), // M
        // 主键盘数字行
        (0x30, 0x1D), (0x31, 0x12), (0x32, 0x13), (0x33, 0x14), (0x34, 0x15),
        (0x35, 0x17), (0x36, 0x16), (0x37, 0x1A), (0x38, 0x1C), (0x39, 0x19),
        // 控制键
        (0x0D, 0x24), // Enter
        (0x1B, 0x35), // Esc
        (0x08, 0x33), // Backspace
        (0x09, 0x30), // Tab
        (0x20, 0x31), // Space
        (0x10, 0x38), // Shift（通用，按左 Shift 处理）
        (0x11, 0x3B), // Control（通用，按左 Control 处理）
        (0x12, 0x3A), // Alt/Menu（通用，按左 Option 处理）
        (0x5B, 0x37), // LWin -> Command
        (0x5C, 0x36), // RWin -> Command
        (0x5D, 0x3D), // RAlt -> RightOption
        // 左右区分的修饰键
        (0xA0, 0x38), // LShift
        (0xA1, 0x3C), // RShift
        (0xA2, 0x3B), // LControl
        (0xA3, 0x3E), // RControl
        (0xA4, 0x3A), // LAlt
        (0xA5, 0x3D), // RAlt
        // 锁定 / 功能键
        (0x14, 0x39), // CapsLock
        (0x90, 0x47), // NumLock -> Clear（Mac 无 NumLock，映射到 Clear）
        (0x91, 0x71), // ScrollLock -> F15（Mac 无对应键，近似）
        (0x13, 0x6E), // Pause（Mac 无对应键，占位）
        (0x2C, 0x6B), // PrintScreen/Snapshot -> F14（Mac 无对应键，近似）
        (0x70, 0x7A), (0x71, 0x78), (0x72, 0x63), (0x73, 0x76), // F1–F4
        (0x74, 0x60), (0x75, 0x61), (0x76, 0x62), (0x77, 0x64), // F5–F8
        (0x78, 0x65), (0x79, 0x6D), (0x7A, 0x67), (0x7B, 0x6F), // F9–F12
        // 方向键
        (0x25, 0x7B), (0x27, 0x7C), (0x28, 0x7D), (0x26, 0x7E),
        // 编辑键
        (0x2E, 0x75), // Delete（向前删除）
        // ⚠️ 下面三行的 Mac keycode 曾经写错：Home 用了「小键盘回车」0x4C、
        //    End 用了「小键盘 7」0x59、Insert 用了 Home 的 0x73。
        //    后果是这三个键跨屏后行为错乱，并且会和小键盘真正的主人抢同一个 keycode。
        (0x2D, 0x72), // Insert -> Help（Mac 无 Insert，映射到 Help）
        (0x24, 0x73), // Home
        (0x23, 0x77), // End
        (0x21, 0x74), // PageUp
        (0x22, 0x79), // PageDown
        // 小键盘
        (0x60, 0x52), (0x61, 0x53), (0x62, 0x54), (0x63, 0x55), (0x64, 0x56),
        (0x65, 0x57), (0x66, 0x58), (0x67, 0x59), (0x68, 0x5B), (0x69, 0x5C),
        (0x6A, 0x43), // 乘
        (0x6B, 0x45), // 加
        (0x6D, 0x4E), // 减
        (0x6E, 0x41), // 小数点
        (0x6F, 0x4B), // 除
        // OEM 标点键
        (0xBA, 0x29), // ;
        (0xBB, 0x18), // =
        (0xBC, 0x2B), // ,
        (0xBD, 0x1B), // -
        (0xBE, 0x2F), // .
        (0xBF, 0x2C), // /
        (0xC0, 0x32), // `
        (0xDB, 0x21), // [
        (0xDC, 0x2A), // \
        (0xDD, 0x1E), // ]
        (0xDE, 0x27), // '
    ]

    /// Windows VK -> Mac keycode（由 keyMap 推导，static 常量，不会每次调用重建）。
    private static let vkToMac: [Int32: CGKeyCode] = .init(
        keyMap.map { ($0.vk, $0.mac) }, uniquingKeysWith: { first, _ in first }
    )
    /// Mac keycode -> Windows VK（反向表，同样由 keyMap 推导，保证双向一致）。
    private static let macToVk: [CGKeyCode: Int32] = .init(
        keyMap.map { ($0.mac, $0.vk) }, uniquingKeysWith: { first, _ in first }
    )

    /// 修饰键 VK -> 对应 CGEventFlags 掩码（注入时维护修饰键状态用）。
    private static let modifierMask: [Int32: CGEventFlags] = [
        0x10: .maskShift, 0xA0: .maskShift, 0xA1: .maskShift,
        0x11: .maskControl, 0xA2: .maskControl, 0xA3: .maskControl,
        0x12: .maskAlternate, 0xA4: .maskAlternate, 0xA5: .maskAlternate,
        0x5B: .maskCommand, 0x5C: .maskCommand, 0x5D: .maskAlternate,
    ]

    /// 当前已按下的修饰键状态（注入键盘事件时附带到 CGEvent.flags）。
    private var currentModifierFlags: CGEventFlags = []

    /// Windows VK -> Mac keycode。
    private func macKeyCode(from vk: Int32) -> CGKeyCode? {
        Self.vkToMac[vk]
    }

    /// Mac keycode -> Windows VK（捕获时反向映射）。
    private func windowsVK(fromMac mac: Int32) -> Int32? {
        Self.macToVk[CGKeyCode(mac)]
    }

    /// 键表覆盖度自检：26 个字母 + 10 个数字必须全部可跨屏。
    ///
    /// 【为什么要有这个自检】历史事故（2026-09-14）：keyMap 漏掉 I J K L M N O P U
    /// 九个字母，表现是「跨屏后某些键打不出来」，而且**完全静默** ——
    /// 用户只能靠逐个按键去猜哪些坏了。这个自检在建立捕获时把结论打进日志，
    /// 缺键会明确点名，不必再靠试。
    private func verifyKeyCoverage() {
        var missing: [String] = []
        for ch in "abcdefghijklmnopqrstuvwxyz" {
            guard let a = ch.asciiValue else { continue }
            // 'a'(0x61) -> VK 0x41，ASCII 减 0x20 即为 VK
            if Self.vkToMac[Int32(a) - 0x20] == nil { missing.append(String(ch).uppercased()) }
        }
        for ch in "0123456789" {
            guard let a = ch.asciiValue else { continue }
            // '0'(0x30) -> VK 0x30，数字的 ASCII 就是 VK
            if Self.vkToMac[Int32(a)] == nil { missing.append(String(ch)) }
        }
        if missing.isEmpty {
            diag("[MWB] 键表自检 ✓ 26 字母 + 10 数字全部可跨屏")
        } else {
            diag("[MWB] ⚠️ 键表自检失败：缺失 \(missing.joined(separator: " "))"
                 + " —— 这些键跨屏后不会有任何效果（keyMap 需要补全）")
        }
    }
}
