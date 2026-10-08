// InboundSilence.swift
// 「对端静默」看门狗 —— 判据（纯函数）＋ 离线自检。
//
// ─────────────────────────────────────────────────────────────────────────────
// 【它解决什么：半开连接会让 App 永远显示"已连接"】
//
// 2026-10-08 实测现场（Windows 睡眠恢复之后）：
//   · App 面板显示「已连接」；
//   · 鼠标推到边缘**控制权确实交出去了**（日志有 `控制权已切换到 Windows ⟶`），
//     但 Windows 那边连光标都不出现，用户连推几次都被弹回来；
//   · 日志一切正常：`信箱投递 1351 实发 1209 积压=无`，**没有一条写失败**；
//   · 真正说话的是 `nettop`（按连接计字节）：
//         bytes_in  冻结在 **1296** —— 10 秒里 5 次采样纹丝不动，
//                   而 1296 恰好只够握手那一轮；
//         bytes_out 每 4 秒稳定 +64（我们自己的心跳），已涨到 96 KB。
//     ⇒ **对端从握手之后一个字节都没回过，而我们的写全部"成功"。**
//
// 这就是教科书上的**半开连接（half-open）**：
//   · 对端**主机**还在（内核照常 ACK 我们的数据、`connect` 也照常成功）；
//   · 对端**应用**已经不处理这条连接了 —— Windows 进入「连接待机（Modern Standby /
//     S0ix）」时网卡仍在工作而用户态被冻结；或者对端 MWB 已经退出/卡死。
//
// 【为什么原来发现不了】两道防线同时对这种情况失效：
//   ① 读侧：`Connection.doHandshake()` 结束时 `setRecvTimeout(seconds: 0)`，
//      `read()` 于是**永久阻塞**在"等数据"上 —— 对端不发也不关，接收线程一辈子不返回，
//      `onDisconnected` 永远不会被触发；
//   ② 写侧：对端内核还在 ACK，`write()` 照样成功，`sendFailStreak` 永远是 0。
//   `SO_KEEPALIVE` 也救不了：它探的是"主机在不在"，而主机恰恰是在的。
//
// 所以只剩一条路：**用「对端多久没跟我们说话」来判断链路。**
//
// 【阈值为什么是 15 秒】对端（Windows 上的 MWB）正常时**持续**发包：
//   Mac 每 4 秒发一颗 HeartbeatEx，对端收到会回显；对端自己也有心跳与矩阵维护包。
//   15 秒 ≈ 3~4 个心跳周期 —— 健康链路绝无可能出现这种静默，
//   而对端一旦冻结/退出，15 秒内就能发现并主动断开重连。
//
// 自检：`mwbmac --inbound-silence-selftest`（离线纯逻辑，不需要网络）。

import Foundation

public enum InboundSilence {

    /// 默认静默阈值（秒）。见文件头「阈值为什么是 15 秒」。
    public static let defaultTimeout: TimeInterval = 15

    /// 判定「链路已废，该主动断开重连」。
    ///
    /// 四个条件缺一不可：
    ///   · `linkEstablished` —— 只有"自认为已连上"时才谈得上"对端静默"；
    ///     正在重连（未建立）时频繁判死只会把退避搅乱。
    ///   · `!linkDead`       —— 已经在重连流程里了，不要重复触发（否则会刷屏并抢代际号）。
    ///   · `lastInboundAgo`  —— 距最后一次收到**任何**入站包的时间（不是"最后一条鼠标包"）。
    ///   · 严格 `>` 阈值      —— 等号不算，避免正好卡在阈值上反复抖动。
    public static func isStale(lastInboundAgo: TimeInterval,
                               linkEstablished: Bool,
                               linkDead: Bool,
                               timeout: TimeInterval = InboundSilence.defaultTimeout) -> Bool {
        guard linkEstablished, !linkDead else { return false }
        return lastInboundAgo > timeout
    }

    /// 给日志/面板用的一句话（把"这是半开连接"讲清楚，免得又去翻密钥和权限）。
    public static func explain(silentFor seconds: TimeInterval, timeout: TimeInterval) -> String {
        "对端已静默 \(Int(seconds))s（阈值 \(Int(timeout))s）—— 这是**半开连接**："
        + "对端主机还在（TCP 仍 ESTABLISHED、我们的写也全成功），但它一个包都不回了。"
        + "最常见的原因：Windows 进入了连接待机/睡眠（网卡还在、应用被冻结），"
        + "或对端 MWB 已退出、卡死。→ 主动断开并重连。"
    }

    // MARK: - 离线自检

    /// 纯逻辑自检：不需要网络、不需要对端。
    ///
    /// 【为什么要自检】这套判据一旦写错，两个方向都是灾难：
    ///   · 判得太松（该触发不触发）→ 回到本次事故：App 永远显示"已连接"，鼠标永远跨不过去；
    ///   · 判得太紧（不该触发却触发）→ 健康链路被反复掐断重连，而每次重连都要在对端
    ///     连接账上记一笔，攒够 9 次会打出对端的 `too many connections` 自我保护。
    /// 所以这里把边界和组合都钉死。
    public static func selfTest() -> (pass: Int, total: Int, fails: [String]) {
        var pass = 0
        var fails: [String] = []
        func check(_ name: String, _ cond: Bool) {
            if cond { pass += 1 } else { fails.append(name) }
        }

        let T = InboundSilence.defaultTimeout

        // ① 阈值本身：必须是"分钟级以下、又远大于心跳周期"的那个区间
        check("默认阈值在 10~30s 之间（当前 \(Int(T))s）", T >= 10 && T <= 30)
        check("阈值至少容纳 2 个心跳周期(4s×2=8s)", T >= 8)

        // ② 典型故障现场：已连上、未在重连、对端安静了 5 分钟 → 必须判死
        check("已连上 + 对端静默 300s → 判死",
              isStale(lastInboundAgo: 300, linkEstablished: true, linkDead: false))

        // ③ 健康链路：刚收到过包 → 绝不判死（哪怕只早了 0.1s）
        check("刚收到包(0.1s 前) → 不判死",
              !isStale(lastInboundAgo: 0.1, linkEstablished: true, linkDead: false))

        // ④ 边界：恰好等于阈值不算（用 > 而非 >=），避免卡在阈值上抖动
        check("静默恰等于阈值 \(Int(T))s → 不判死",
              !isStale(lastInboundAgo: T, linkEstablished: true, linkDead: false))
        check("静默 阈值+0.001s → 判死",
              isStale(lastInboundAgo: T + 0.001, linkEstablished: true, linkDead: false))

        // ⑤ 还没连上（正在重连/开机等待）时，静默多久都不该由本判据判死
        check("未建立链路 + 静默 300s → 不判死（重连流程自己管）",
              !isStale(lastInboundAgo: 300, linkEstablished: false, linkDead: false))

        // ⑥ 已在重连流程里 → 不重复触发（否则会抢代际号、刷屏）
        check("已在重连(linkDead) + 静默 300s → 不判死",
              !isStale(lastInboundAgo: 300, linkEstablished: true, linkDead: true))
        check("两个条件都不满足叠加 → 仍不判死",
              !isStale(lastInboundAgo: 300, linkEstablished: false, linkDead: true))

        // ⑦ 阈值可注入（自检/现场调参用），且注入后同样遵守严格大于
        check("自定义阈值 5s：静默 6s → 判死",
              isStale(lastInboundAgo: 6, linkEstablished: true, linkDead: false, timeout: 5))
        check("自定义阈值 5s：静默 5s → 不判死",
              !isStale(lastInboundAgo: 5, linkEstablished: true, linkDead: false, timeout: 5))

        // ⑧ 组合穷举：只有 (已连上 ∧ 未重连 ∧ 超过阈值) 这一种组合为真
        var trueCases = 0
        var mismatches = 0
        for established in [true, false] {
            for dead in [true, false] {
                for ago in [0.5, T + 0.5] {
                    let r = isStale(lastInboundAgo: ago, linkEstablished: established,
                                    linkDead: dead, timeout: T)
                    let want = established && !dead && ago > T
                    if r != want {
                        mismatches += 1
                        fails.append("组合穷举: established=\(established) dead=\(dead) "
                                     + "ago=\(ago) → \(r)，期望 \(want)")
                    }
                    if r { trueCases += 1 }
                }
            }
        }
        check("8 种组合穷举全部一致", mismatches == 0)
        check("8 种组合里恰有 1 种为真", trueCases == 1)

        // ⑨ 说明文案必须点出"半开连接"这个定性，否则排查时又会被引到密钥/授权上去
        let text = explain(silentFor: 300, timeout: T)
        check("说明文案含「半开连接」", text.contains("半开连接"))
        check("说明文案含实际静默秒数 300", text.contains("300"))
        check("说明文案含阈值 \(Int(T))", text.contains("\(Int(T))"))

        return (pass, pass + fails.count, fails)
    }
}
