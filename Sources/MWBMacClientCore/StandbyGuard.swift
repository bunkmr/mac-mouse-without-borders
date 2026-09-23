// StandbyGuard.swift
// 跨屏待机唤醒（v1.4.3）：让 Mac「屏幕熄了、系统不睡」，等 Windows 的键鼠过来点亮它。
//
// ═══ 为什么不能照抄「睡眠中被网络包唤醒」═══
//
// macOS 的睡眠（`pmset sleep` 到点、手动「睡眠」、合盖）是**真挂起**：所有用户态
// 进程冻结、socket 不再收包。所以「睡着的 Mac 收到 MWB 包再醒来」在应用层
// **物理上不可能** —— 与协议无关，改协议也没用。能在睡眠中被唤醒的通路只有硬件级
// WoL（`pmset womp`，且仅**以太网**有效；Wi-Fi 上的唤醒只认 Bonjour/系统服务）。
//
// PowerToys MWB 里的 `Awake(21)` 包**也不是**唤醒包，它的语义是**反向**的：
//   `Common.SendAwakeBeat()` —— 当「本机有真实人类输入 ∧ 开了 BlockScreenSaver」时
//   广播 `Awake(21)`；对端 `Receiver` 收到后 `AddToMachinePool` + `HumanBeingDetected()`，
//   后者在「本机此刻没有新输入」时 `PokeMyself()`（随机晃 10 下鼠标）
//   ⇒ **防止对端进入屏保**。一句话：是"别睡"，不是"醒醒"。
//
// 那 Windows 为什么"鼠标一撞过去就醒"？因为它的"睡眠"多半是**仅显示器关闭**
// 或 Modern Standby：MWB 进程仍在跑、socket 仍在收，收到 `Mouse(123)` 后走
// `InputSimulation` 的 `SendInput` 注入 —— 而注入的输入会**重置系统空闲计时器**，
// 系统于是自然退出低功耗状态。也就是说：那不是 MWB 的唤醒功能，
// 是"系统压根没睡死 + 输入注入"的副产品。
//
// ═══ Mac 端的等价复刻 ═══
//
// 两件事，缺一不可：
//   ① 持有 `kIOPMAssertionTypePreventUserIdleSystemSleep` 断言
//      —— 只挡「**系统**空闲睡眠」，**不**挡「显示器睡眠」⇒ 屏幕照常熄灭省电，
//         但 MWB 进程一直在跑、心跳一直在发、包一直在收（Windows 那边也就一直
//         认为这台 Mac 在线，鼠标才推得过来）。
//   ② 收到远端键鼠包时 `IOPMAssertionDeclareUserActivity`
//      —— 声明"用户活动"，把已熄灭的显示器点亮，并重置空闲计时器。
//
// 实测（2026-09-19，`pmset displaysleepnow` 快速熄屏做判据）：
//   熄屏后显示器睡眠 = true → 调用该 API 返回 kIOReturnSuccess → 显示器睡眠 = false
//   （屏幕立即点亮）；同时断言如实出现在 `pmset -g assertions` 里
//   （`pid …(probe): PreventUserIdleSystemSleep named: "MWB standby guard probe"`）。
//
// ═══ 它做不到什么（别让用户误以为万能）═══
//   · 手动「睡眠」/ 合盖 / 到点后的**真**睡眠：断言只挡"空闲睡眠"，挡不住这些，
//     睡下去之后本模块同样无能为力（进程已冻结）。
//   · 电池模式下默认不生效（可关掉「仅插电时生效」强行开，代价是耗电）。
//   · 它不是 WoL：指望"Mac 深度睡眠中被打醒"的需求只能用有线 + `womp` + 对端发魔术包，
//     而官方 MWB 不发魔术包。

import Foundation
import CoreGraphics
import IOKit.pwr_mgt
import IOKit.ps

/// 待机守护：持有/释放防睡眠断言，并在远端键鼠到达时点亮屏幕。
///
/// 线程约定：`noteRemoteActivity()` 会被 **100Hz 的鼠标包** 调用，
/// `evaluate()` 由 5s 定时器调用 —— 两者可能并发，故全部状态读写走 `lock`。
public final class StandbyGuard {

    /// 进程内唯一实例。
    ///
    /// 【为什么必须共享】实测 App 启动时连接流程会起**两个** `MWBClient`
    /// （2026-09-19 日志：11:20:44.545 与 11:20:44.788 各走了一次「开始连接」，且两次都成功）。
    /// 若每个 Client 各持一个 Guard，就会创建**两条** PreventUserIdleSystemSleep 断言 ——
    /// 其中一条随"僵尸 Client"泄漏，表现为「断开 Windows 之后系统仍然不睡」。
    /// 共享实例 + 弱引用持有者集合，天然幂等。
    public static let shared = StandbyGuard()

    public init() {}

    /// 日志出口（由 Client 注入，本类不依赖 GUI 层）。
    public var log: ((String) -> Void)?

    /// 谁在「要」这条断言（各 Client 实例）。
    /// **弱引用**：Client 被释放后自动出列，不会留一个永远清不掉的持有者
    /// 把系统永远钉在"不睡"状态。
    private var holders = NSHashTable<AnyObject>.weakObjects()

    private let lock = NSLock()

    // ── 配置（受 lock 保护）
    private var enabled = false
    private var acOnly = true

    // ── 运行态（受 lock 保护）
    private var assertionID: IOPMAssertionID = 0
    private var timer: DispatchSourceTimer?
    private var lastDisplayCheckAt = Date.distantPast
    private var lastWakeLogAt = Date.distantPast
    private var wakeCountValue = 0
    private var lastWakeAtValue: Date?

    // MARK: - 只读状态

    public var isEnabled: Bool { lock.lock(); defer { lock.unlock() }; return enabled }
    public var isAcOnly: Bool { lock.lock(); defer { lock.unlock() }; return acOnly }
    /// 当前是否真的持有「阻止系统空闲睡眠」断言。
    public var isHolding: Bool { lock.lock(); defer { lock.unlock() }; return assertionID != 0 }
    /// 因远端键鼠而点亮屏幕的累计次数。
    public var wakeCount: Int { lock.lock(); defer { lock.unlock() }; return wakeCountValue }
    public var lastWakeAt: Date? { lock.lock(); defer { lock.unlock() }; return lastWakeAtValue }

    /// 给界面用的一句话状态。
    public var statusText: String {
        lock.lock(); defer { lock.unlock() }
        guard enabled else { return "已关闭" }
        if assertionID != 0 { return acOnly ? "生效中（仅插电）" : "生效中" }
        if holders.count == 0 { return "待连接" }
        return acOnly ? "待命（电池供电，暂不阻止睡眠）" : "未生效"
    }

    // MARK: - 配置

    /// 下发配置。值未变时依然复核一次（电源可能在这期间变了），但不刷日志。
    public func configure(enabled on: Bool, acOnly newAcOnly: Bool) {
        lock.lock()
        let changed = (enabled != on) || (acOnly != newAcOnly)
        enabled = on
        acOnly = newAcOnly
        lock.unlock()

        evaluate()
        startTimerIfNeeded()
        if changed {
            log?("[MWB] 待机唤醒：\(on ? "已开启" : "已关闭")"
                 + (on ? "（\(newAcOnly ? "仅插电时生效" : "电池也生效")）" : ""))
        }
    }

    /// 每 5s 复核一次：配置改了、或者插拔了电源，都在这里收敛。
    private func startTimerIfNeeded() {
        lock.lock()
        let needTimer = (timer == nil)
        if needTimer {
            let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            t.schedule(deadline: .now() + 5, repeating: 5)
            t.setEventHandler { [weak self] in self?.evaluate() }
            timer = t
            lock.unlock()
            t.resume()
            return
        }
        lock.unlock()
    }

    /// 某个 Client **登记 / 注销**（连接建立时登记、断开时注销）。
    ///
    /// 用「持有者集合」而不是计数器：同一个 Client 重复登记不会虚增
    /// （连接流程可能跑好几轮），被释放的 Client 也不会留下幽灵持有者。
    public func setActive(_ active: Bool, from owner: AnyObject) {
        lock.lock()
        if active { holders.add(owner) } else { holders.remove(owner) }
        lock.unlock()
        evaluate()
    }

    /// 收敛到「该不该持有断言」的当前答案。
    public func evaluate() {
        lock.lock()
        // 三个条件缺一不可：用户开了总开关、至少有一个 Client 在线、电源策略允许。
        let want = Self.shouldHold(enabled: enabled && holders.count > 0,
                                   acOnly: acOnly,
                                   onAC: Self.isOnAC())
        let holding = (assertionID != 0)
        var message: String?

        if want && !holding {
            var id: IOPMAssertionID = 0
            let r = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "MWB 跨屏待机唤醒（屏幕可熄，系统不休眠）" as CFString,
                &id)
            if r == kIOReturnSuccess {
                assertionID = id
                message = "[MWB] 🖥️ 待机唤醒已上膛：已阻止「系统空闲睡眠」（屏幕仍会正常熄灭省电）"
                    + "，Windows 那边因此始终看得到本机在线；鼠标晃过来即刻点亮屏幕"
            } else {
                message = "[MWB] ⚠️ 待机唤醒：无法创建防睡眠断言（IOReturn=\(r)）"
            }
        } else if !want && holding {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
            message = "[MWB] 🖥️ 待机唤醒已撤下：本机恢复为可正常深度睡眠"
                + (enabled && acOnly ? "（当前为电池供电）" : "")
        }
        lock.unlock()

        if let m = message { log?(m) }
    }

    /// 释放断言并停掉定时器（进程退出时调用，别把断言留在系统里）。
    public func stop() {
        lock.lock()
        holders.removeAllObjects()
        if assertionID != 0 {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
        }
        let t = timer
        timer = nil
        enabled = false
        lock.unlock()
        t?.cancel()
    }

    // MARK: - 远端活动 → 点亮屏幕

    /// 收到**远端**（Windows）键鼠包时调用。
    ///
    /// 只在「屏幕确实已经熄灭」时才动作 —— 屏幕亮着时什么都不做，避免无谓的系统调用
    /// （鼠标包 100Hz，且锁屏/亮屏期间包还会更密）。
    public func noteRemoteActivity() {
        lock.lock()
        let on = enabled
        let now = Date()
        // 屏幕状态查询节流到 0.4s：100Hz 的包没必要每次都去问 WindowServer。
        let due = now.timeIntervalSince(lastDisplayCheckAt) > 0.4
        if due { lastDisplayCheckAt = now }
        lock.unlock()

        guard on, due else { return }
        guard CGDisplayIsAsleep(CGMainDisplayID()) != 0 else { return }

        var aid: IOPMAssertionID = 0
        let r = IOPMAssertionDeclareUserActivity("MWB 远端键鼠唤起屏幕" as CFString,
                                                 kIOPMUserActiveLocal, &aid)
        guard r == kIOReturnSuccess else { return }

        lock.lock()
        wakeCountValue += 1
        lastWakeAtValue = Date()
        let n = wakeCountValue
        let shouldLog = Date().timeIntervalSince(lastWakeLogAt) > 3
        if shouldLog { lastWakeLogAt = Date() }
        lock.unlock()

        guard shouldLog else { return }
        log?("[MWB] ☀️ 屏幕已熄灭，收到远端键鼠包 → 已声明用户活动点亮屏幕"
             + "（本次运行累计第 \(n) 次）")
    }

    /// 交互式自检（**不需要 Windows**）：3s 后熄屏 → 再过 3s 声明用户活动点亮屏幕。
    /// 全程 6 秒。期间用户**不能碰键鼠** —— 一碰，系统会当作真实用户活动提前点亮，
    /// 结论就不作数了，所以日志里要反复强调。
    public func runInteractiveSelfTest() {
        let t0 = Date()
        log?("[MWB] 待机唤醒自检：3 秒后熄屏 → 再 3 秒点亮；这 6 秒内请不要触碰键鼠")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            p.arguments = ["displaysleepnow"]
            do {
                try p.run()
                p.waitUntilExit()
            } catch {
                self.log?("[MWB] ❌ 自检失败：无法调用 pmset displaysleepnow（\(error.localizedDescription)）")
                return
            }
            let dimmed = CGDisplayIsAsleep(CGMainDisplayID()) != 0
            self.log?("[MWB] 自检第 1 步：已请求熄屏（当前显示器睡眠=\(dimmed ? "是" : "否")）")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self else { return }
                var aid: IOPMAssertionID = 0
                let r = IOPMAssertionDeclareUserActivity("MWB 待机唤醒自检" as CFString,
                                                         kIOPMUserActiveLocal, &aid)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                    guard let self else { return }
                    let stillAsleep = CGDisplayIsAsleep(CGMainDisplayID()) != 0
                    let cost = String(format: "%.1f", Date().timeIntervalSince(t0))
                    if r == kIOReturnSuccess, !stillAsleep {
                        self.log?("[MWB] ✅ 自检通过：声明用户活动后屏幕已点亮（耗时 \(cost)s）"
                                  + " —— 「Windows 鼠标晃过来」走的正是这一条路径")
                    } else {
                        self.log?("[MWB] ❌ 自检未通过：IOReturn=\(r)，显示器睡眠=\(stillAsleep ? "是" : "否")"
                                  + "（若你刚才碰过键鼠，屏幕可能是被真实输入点亮的，请原样重跑一次）")
                    }
                }
            }
        }
    }

    // MARK: - 纯判据（可离线自检）

    /// 该不该持有「阻止系统空闲睡眠」断言。抽成纯函数是为了能离线穷举验证 ——
    /// 真机上"插拔电源"这个条件太难稳定复现。
    public static func shouldHold(enabled: Bool, acOnly: Bool, onAC: Bool) -> Bool {
        guard enabled else { return false }
        return acOnly ? onAC : true
    }

    /// 当前供电方式。
    public static func isOnAC() -> Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let raw = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue()
        else { return true }   // 拿不到就当作插电（台式/未知环境更可能是在插座上）
        return (raw as String) == (kIOPSACPowerValue as String)
    }

    public static func isOnACDescription() -> String {
        isOnAC() ? "AC 电源" : "电池"
    }

    /// 离线自检：穷举 `shouldHold` 的 8 种组合，期望恰好 3 种为真。
    public static func selfTest() -> (pass: Int, total: Int, fails: [String]) {
        var pass = 0, total = 0
        var fails: [String] = []
        func check(_ name: String, _ ok: Bool) {
            total += 1
            if ok { pass += 1 } else { fails.append(name) }
        }

        var truths: [(Bool, Bool, Bool)] = []
        for e in [true, false] {
            for a in [true, false] {
                for p in [true, false] {
                    let r = shouldHold(enabled: e, acOnly: a, onAC: p)
                    let want = e && (!a || p)
                    check("组合 e=\(e) acOnly=\(a) onAC=\(p) → \(r)，期望 \(want)", r == want)
                    if r { truths.append((e, a, p)) }
                }
            }
        }
        check("8 种组合里恰有 3 种为真", truths.count == 3)
        check("关闭时一律不持有", !shouldHold(enabled: false, acOnly: false, onAC: true))
        check("仅插电 + 电池 → 不持有", !shouldHold(enabled: true, acOnly: true, onAC: false))
        check("仅插电 + 插电 → 持有", shouldHold(enabled: true, acOnly: true, onAC: true))
        check("不限电源 + 电池 → 持有", shouldHold(enabled: true, acOnly: false, onAC: false))

        // 供电探测本身要能跑通（值随环境变，只验"没崩、有明确结论"）
        let ac = isOnAC()
        check("供电探测可用（当前 \(ac ? "AC" : "电池")）", ac || !ac)

        return (pass, total, fails)
    }
}
