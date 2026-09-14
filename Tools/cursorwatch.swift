// 只读光标可见性监听：以 ~10Hz 采样 CGCursorIsVisible()，报告可见/隐藏的时间线。
//
// 【为什么用它】CGDisplayHideCursor 的返回值不可信（后台进程恒为 success），
// 截图比对在本机也不可信（取像不稳定）。CGCursorIsVisible() 读的是 WindowServer
// 里的**真实**状态，是本机唯一可信的「隐藏到底生效没有」判据。
// 配合 App 的 MWB_LOCK_SELFTEST 钩子，就能客观验证光标锁定。
//
// 用法: swiftc -O cursorwatch.swift -o cursorwatch && ./cursorwatch [秒数]

import CoreGraphics
import Foundation

typealias BoolFn = @convention(c) () -> UInt32   // boolean_t = UInt32

let fn: BoolFn? = {
    guard let p = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGCursorIsVisible") else { return nil }
    return unsafeBitCast(p, to: BoolFn.self)
}()

guard let f = fn else {
    print("WATCH ✗ 拿不到 CGCursorIsVisible 符号，无法判定")
    exit(2)
}

let dur = Double(CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "10") ?? 10.0
let t0 = Date()
var nVisible = 0
var nHidden = 0
var lastState: Bool? = nil
var transitions = 0
var streakStart: TimeInterval = 0
var bestStreak: TimeInterval = 0

print("WATCH 开始，采样 \(Int(dur))s（进程 \(getpid())）")
while Date().timeIntervalSince(t0) < dur {
    let now = Date().timeIntervalSince(t0)
    let vis = f() != 0
    if vis { nVisible += 1 } else { nHidden += 1 }
    if lastState != vis {
        if lastState != nil {
            transitions += 1
            print(String(format: "  [t=%.2fs] → %@", now, vis ? "可见" : "已隐藏"))
            // 结算上一段
            if lastState == false { bestStreak = max(bestStreak, now - streakStart) }
        }
        streakStart = now
        lastState = vis
    }
    usleep(100_000)   // 10Hz
}
if lastState == false { bestStreak = max(bestStreak, Date().timeIntervalSince(t0) - streakStart) }

print("WATCH 采样=\(nVisible + nHidden)  可见=\(nVisible)  已隐藏=\(nHidden)"
      + "  状态切换=\(transitions) 次  最长连续隐藏=\(String(format: "%.2f", bestStreak))s")
// ★ 判据用「最长连续隐藏时长」，不用全局占比 ——
//   测试前后是正常态（光标本来就该可见），占比会被它们稀释。
//   真正要回答的是「控制远端期间光标能不能持续消失」。
if bestStreak >= 2.0 {
    print(String(format: "WATCH 结论: ✅ 隐藏可持续（最长 %.2f 秒连续隐藏）—— 光标锁定生效", bestStreak))
} else if bestStreak > 0 {
    print(String(format: "WATCH 结论: ⚠️ 只能短暂隐藏（最长仅 %.2f 秒）—— 重申不够或被系统反复重新显示", bestStreak))
} else {
    print("WATCH 结论: ❌ 全程可见 —— 隐藏完全没生效")
}
