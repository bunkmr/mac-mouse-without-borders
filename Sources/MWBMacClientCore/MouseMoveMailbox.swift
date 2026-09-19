// MouseMoveMailbox.swift
// 鼠标移动包的「最新值信箱」——只保留最新一帧，旧的直接丢掉。
//
// 【为什么需要它：三个理由，缺一个都不划算】
//
// ① **移动包的位置是幂等的**：第 N 帧天然覆盖第 N−1 帧。跟键盘不一样 ——
//    键盘丢一个按键就是"少打一个字"，所以键盘包绝不能合并；鼠标位置不存在这个问题。
//
// ② **不能阻塞事件 tap**。移动包原来的发送路径是
//    `CGEventTap 回调 → onCaptured → connection.send → CFWriteStreamWrite`，
//    而这条 socket 是**阻塞**的（写超时 2s，见 Connection 的 socket 选项）。
//    于是一旦链路抖动（本机 WiFi 实测每 500ms 有一次 60~85ms 尖峰），
//    **tap 回调就被同步写卡住** —— 系统在等我们返回，整个输入流一起停顿。
//    表现就是"跨屏鼠标一顿一顿、不跟手"，而日志里各项指标都正常。
//    有了信箱，tap 那边只做一次加锁赋值就返回，写由独立线程负责。
//
// ③ **消费者慢一点，代价就该小一点**。200Hz 输入 / 消费者跟不上时，
//    老实现会把积压的每一帧都发出去 —— 送的全是过期位置，白烧 CPU、白占带宽。
//    信箱让"过期帧"自然消失：投递 200 帧、消费端只跟得上 150 帧，就只发 150 帧，
//    而且发出的每一帧都尽量新。**最后一帧一定会被送出去**（信箱里始终留着最新的）。
//
// 【线程安全】所有状态都在 NSLock 后面。投递方是 tap 线程/主线程，取走方是发送线程。
// 自检：`mwbmac --mouse-mailbox-selftest`（离线纯逻辑，不需要网络）。

import Foundation

public final class MouseMoveMailbox {
    private let lock = NSLock()
    private var latest: DataPacket?

    /// 累计投递帧数。
    public private(set) var submitted = 0
    /// 因为被更新的一帧顶掉而**没有单独发送**的帧数（合并掉的量，越多说明省得越多）。
    public private(set) var coalesced = 0
    /// 累计取走并发出的帧数。
    public private(set) var sent = 0

    public init() {}

    /// 投递一帧最新位置。
    ///
    /// 返回 `true` = 信箱里原来**已经有一帧还没被取走**，这一帧把它顶掉了。
    /// 调用方据此决定要不要唤醒发送线程：**只有在"空 → 非空"的那一次才需要唤醒**，
    /// 否则信箱非空时发送线程本来就会一直取（多唤醒只会白转一圈）。
    @discardableResult
    public func submit(_ packet: DataPacket) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let replaced = latest != nil
        if replaced { coalesced += 1 }
        latest = packet
        submitted += 1
        return replaced
    }

    /// 取走当前最新的一帧（没有则返回 nil）。
    public func takeLatest() -> DataPacket? {
        lock.lock()
        defer { lock.unlock() }
        guard let v = latest else { return nil }
        latest = nil
        sent += 1
        return v
    }

    /// 丢弃尚未发出的那一帧（断线/停止发送时用，避免用过期位置去打扰对端）。
    public func discardPending() {
        lock.lock()
        defer { lock.unlock() }
        latest = nil
    }

    /// 当前信箱里是否还压着一帧。
    public var isPending: Bool {
        lock.lock()
        defer { lock.unlock() }
        return latest != nil
    }

    /// 给日志用的一句话。
    public var summary: String {
        lock.lock()
        defer { lock.unlock() }
        let pct = submitted > 0 ? Double(coalesced) / Double(submitted) * 100 : 0
        return "投递 \(submitted) 帧 / 实发 \(sent) 帧 / 合并掉 \(coalesced) 帧"
             + String(format: "（%.0f%%）", pct)
    }

    // MARK: - 离线自检

    /// 纯逻辑自检：不需要网络、不需要对端。
    ///
    /// 【为什么要自检】这套逻辑一旦写错，症状是"鼠标偶尔跳一下/最后一帧丢在邮箱里没发出去"，
    /// 在真机上极难复现、更难归因。这里用 9 组断言把"覆盖、取走、单帧、顺序"钉死。
    public static func selfTest() -> (pass: Int, total: Int, fails: [String]) {
        var pass = 0
        var fails: [String] = []
        func check(_ name: String, _ cond: Bool) {
            if cond { pass += 1 } else { fails.append(name) }
        }
        func pkt(_ x: Int32, _ y: Int32) -> DataPacket {
            var p = DataPacket(type: .mouse)
            p.mouseFlags = InputController.mouseMoveFlag
            p.mouseX = x
            p.mouseY = y
            return p
        }

        // ① 空信箱：取不到东西，也不该崩
        let m1 = MouseMoveMailbox()
        check("空信箱取走 → nil", m1.takeLatest() == nil)
        check("空信箱 isPending = false", !m1.isPending)

        // ② 投递一帧 → 原样取回（位置不能变）
        let m2 = MouseMoveMailbox()
        let r = m2.submit(pkt(100, 200))
        check("空信箱投递返回 false（没顶掉别人）", r == false)
        let got = m2.takeLatest()
        check("取回的就是刚才那一帧", got?.mouseX == 100 && got?.mouseY == 200)
        check("取走后信箱为空", !m2.isPending)
        check("取走后不能重复取", m2.takeLatest() == nil)

        // ③ 连续投递 1000 帧 → 只留最新那帧，其余全算合并
        let m3 = MouseMoveMailbox()
        m3.submit(pkt(0, 0))
        for i in 1...999 { m3.submit(pkt(Int32(i), Int32(i))) }
        let newest = m3.takeLatest()
        check("1000 帧只留最新（x=999）", newest?.mouseX == 999)
        check("合并计数 = 999", m3.coalesced == 999)
        check("投递计数 = 1000", m3.submitted == 1000)
        check("实发计数 = 1", m3.sent == 1)

        // ④ 顶掉的判定：非空时投递必须返回 true（否则发送线程不会被唤醒 → 最后一帧丢在信箱里）
        let m4 = MouseMoveMailbox()
        m4.submit(pkt(1, 1))
        check("非空信箱再投递 → 返回 true（顶掉旧帧）", m4.submit(pkt(2, 2)) == true)
        check("取走 → 再投递返回 false（空→非空，需唤醒）",
              { _ = m4.takeLatest(); return m4.submit(pkt(3, 3)) }() == false)

        // ⑤ 交替投递/取走：每一帧都不该丢
        let m5 = MouseMoveMailbox()
        var seen: [Int32] = []
        for i in 0..<50 {
            m5.submit(pkt(Int32(i), 0))
            if let v = m5.takeLatest() { seen.append(v.mouseX) }
        }
        check("交替投递/取走：50 帧全取到且顺序正确", seen == (0..<50).map { Int32($0) })
        check("交替场景没有合并丢失", m5.coalesced == 0)

        // ⑥ 断线丢弃：discardPending 之后取不到，且不影响历史计数
        let m6 = MouseMoveMailbox()
        m6.submit(pkt(7, 7))
        m6.discardPending()
        check("discardPending 后取不到东西", m6.takeLatest() == nil)
        check("discardPending 不改动实发计数", m6.sent == 0)

        // ⑦ 最后一帧必定能送出去：投递 N 帧、每次只取一帧，最后取到的必须是最后一帧
        let m7 = MouseMoveMailbox()
        for i in 0..<10 { m7.submit(pkt(Int32(i), 0)) }
        var last: Int32 = -1
        while let v = m7.takeLatest() { last = v.mouseX }
        check("取干净后最后取到的是第 9 帧", last == 9)

        // ⑧ 并发不崩（tap 线程投递 / 发送线程取走各 1 万次）
        let m8 = MouseMoveMailbox()
        let q = DispatchQueue(label: "mailbox.selftest", attributes: .concurrent)
        let group = DispatchGroup()
        for _ in 0..<2 {
            group.enter()
            q.async {
                for i in 0..<10_000 { _ = m8.takeLatest(); m8.submit(pkt(Int32(i), 0)) }
                group.leave()
            }
        }
        group.wait()
        check("并发投递/取走 2 万次后仍自洽（投递=取走+合并+信箱里剩的）",
              m8.submitted == m8.sent + m8.coalesced + (m8.isPending ? 1 : 0))

        // ⑨ 投递的包类型/坐标不被信箱改动
        let m9 = MouseMoveMailbox()
        m9.submit(pkt(65534, 1))
        let q9 = m9.takeLatest()
        check("邮箱不篡改包内容（flags/x/y 原样）",
              q9?.mouseFlags == InputController.mouseMoveFlag && q9?.mouseX == 65534 && q9?.mouseY == 1)
        check("summary 文案包含实际帧数", m9.summary.contains("投递 1 帧"))

        return (pass, pass + fails.count, fails)
    }
}

// MARK: - 鼠标发送线程的哨兵判据

/// 「该不该把鼠标移动包的发送线程重启一次」——**纯函数**，与网络/线程无关，可离线自检。
///
/// 【为什么要有它】`MouseMoveMailbox` 那套"只在空→非空时唤醒发送线程"的约定，
/// 只要有任何一条路径破坏它（最常见的一条：**断链时 `handleLinkDead` 停掉了发送线程，
/// 而"自动重连成功"只重启了接收循环**），鼠标移动就会**永久**停住：
/// 每一帧都只是把信箱里的旧帧顶掉、永远发不出去。
/// 而键盘/点击/滚轮走的是另一条同步发送路径，照样通 ——
/// 于是现象是「连接正常、键盘能用，就是鼠标不动、**Windows 屏幕上连光标都看不到**」
/// （PowerToys 侧跨屏时显示的是它自己画的假光标，只有收到鼠标包才会显示）。
///
/// 判据四个条件缺一不可：
///   · `isPending`      —— 信箱里确实压着一帧没发（有活没干完，才谈得上"停摆"）；
///   · `deliveredAgo >` —— 已经这么久没有**真正写进 socket**（注意：不是"造帧"）；
///   · `!linkDead`      —— 链路已死时重启没意义，重连成功那条路径会负责重启；
///   · `handledAgo >`   —— 节流，避免反复重启刷日志。
///
/// 自检：`mwbmac --mouse-sender-supervisor-selftest`
public enum MouseSenderSupervisor {
    /// 判定"停摆"。阈值默认：1s 没交付过 + 5s 内没处理过。
    public static func shouldRestart(isPending: Bool,
                                     deliveredAgo: TimeInterval,
                                     linkDead: Bool,
                                     handledAgo: TimeInterval,
                                     stallSeconds: TimeInterval = 1.0,
                                     cooldown: TimeInterval = 5.0) -> Bool {
        guard isPending, !linkDead else { return false }
        return deliveredAgo > stallSeconds && handledAgo > cooldown
    }

    /// 离线自检：把边界条件钉死（含 2026-09-19 那次故障的真实参数组合）。
    public static func selfTest() -> (pass: Int, total: Int, fails: [String]) {
        var pass = 0
        var fails: [String] = []
        func check(_ name: String, _ cond: Bool) {
            if cond { pass += 1 } else { fails.append(name) }
        }

        // ① 典型故障现场：断链重连之后 —— 链路已恢复(linkDead=false)、信箱压着位置、
        //    已经 12s 没有任何真正的交付、且距上次处理很久（从没处理过）。
        check("断链重连后（有帧/久未交付/链路活）→ 该重启",
              shouldRestart(isPending: true, deliveredAgo: 12, linkDead: false,
                            handledAgo: .greatestFiniteMagnitude))

        // ② 信箱空 = 没活干：鼠标没动时本来就该是空的，绝不能据此重启
        check("信箱空（没压帧）→ 不重启",
              !shouldRestart(isPending: false, deliveredAgo: 99, linkDead: false,
                             handledAgo: 99))

        // ③ 链路已死：重启也没用，交给"重连成功"那条路径
        check("链路已死 → 不重启",
              !shouldRestart(isPending: true, deliveredAgo: 99, linkDead: true, handledAgo: 99))

        // ④ 刚刚交付过：说明发送线程在正常工作（哪怕信箱里还压着下一帧）
        check("0.5s 前刚交付过 → 不重启（还没到 1s 判据）",
              !shouldRestart(isPending: true, deliveredAgo: 0.5, linkDead: false,
                             handledAgo: .greatestFiniteMagnitude))

        // ⑤ 节流：刚处理过一次（重启过），别在冷却期内反复重启
        check("距上次处理 2s（冷却 5s 未到）→ 不重启",
              !shouldRestart(isPending: true, deliveredAgo: 99, linkDead: false, handledAgo: 2))

        // ⑥ 边界：正好等于阈值不算（用 > 而非 >=），避免"卡在阈值上"抖动
        check("deliveredAgo 恰等于阈值 1.0 → 不重启",
              !shouldRestart(isPending: true, deliveredAgo: 1.0, linkDead: false,
                             handledAgo: .greatestFiniteMagnitude))
        check("handledAgo 恰等于冷却 5.0 → 不重启",
              !shouldRestart(isPending: true, deliveredAgo: 99, linkDead: false, handledAgo: 5.0))

        // ⑦ 阈值可调（自检/实验用）
        check("自定义阈值（0.2s/0.1s）下 0.5s 未交付 → 该重启",
              shouldRestart(isPending: true, deliveredAgo: 0.5, linkDead: false,
                            handledAgo: 1, stallSeconds: 0.2, cooldown: 0.1))

        // ⑧ 组合穷举：只有 (有帧 ∧ 链路活 ∧ 超时 ∧ 过冷却) 这一种组合为真
        var trueCases = 0
        var comboMismatch = 0
        for pending in [true, false] {
            for dead in [true, false] {
                for delivered in [0.1, 9.0] {
                    for handled in [0.5, 9.0] {
                        let r = shouldRestart(isPending: pending, deliveredAgo: delivered,
                                              linkDead: dead, handledAgo: handled,
                                              stallSeconds: 1.0, cooldown: 5.0)
                        let want = pending && !dead && delivered > 1.0 && handled > 5.0
                        if r != want {
                            comboMismatch += 1
                            fails.append("组合穷举: pending=\(pending) dead=\(dead) "
                                         + "delivered=\(delivered) handled=\(handled) "
                                         + "→ \(r)，期望 \(want)")
                        }
                        if r { trueCases += 1 }
                    }
                }
            }
        }
        check("16 种组合穷举全部一致", comboMismatch == 0)
        check("16 种组合里恰有 1 种为真", trueCases == 1)

        return (pass, pass + fails.count, fails)
    }
}
