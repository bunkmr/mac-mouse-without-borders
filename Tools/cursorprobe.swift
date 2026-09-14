// 独立光标探针：以 ~60Hz 采样**真实**光标位置，报告整场移动范围。
//
// 用途：验证「控制远端时本机光标有没有真的被钉住」。
// 与 App 内部的自检互补 —— App 用改写逻辑自己判断，这个探针是**第三方视角**，
// 读的是 WindowServer 里光标的实际位置，App 的日志说破天也改不了这个数。
//
// 用法: swiftc -O cursorprobe.swift -o cursorprobe && ./cursorprobe [秒数]

import CoreGraphics
import Foundation

let dur = Double(CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "8") ?? 8.0

var minX = Double.greatestFiniteMagnitude
var maxX = -Double.greatestFiniteMagnitude
var minY = Double.greatestFiniteMagnitude
var maxY = -Double.greatestFiniteMagnitude
var n = 0

let t0 = Date()
while Date().timeIntervalSince(t0) < dur {
    if let e = CGEvent(source: nil) {
        let p = e.location
        minX = min(minX, p.x); maxX = max(maxX, p.x)
        minY = min(minY, p.y); maxY = max(maxY, p.y)
        n += 1
    }
    usleep(16_000)   // ≈60Hz
}

let rx = Int(maxX - minX), ry = Int(maxY - minY)
print("PROBE 样本=\(n)  位移范围 X=\(rx)px Y=\(ry)px"
      + "  坐标 X=[\(Int(minX)),\(Int(maxX))] Y=[\(Int(minY)),\(Int(maxY))]")
if rx <= 3 && ry <= 3 {
    print("PROBE 结论: ✅ 光标全程钉死（范围 ≤3px）")
} else if rx <= 40 && ry <= 40 {
    print("PROBE 结论: ⚠️ 光标有可见抖动（范围 \(max(rx, ry))px）—— 锁定基本生效但有失守")
} else {
    print("PROBE 结论: ❌ 光标在移动（范围 \(max(rx, ry))px）—— 锁定没生效")
}
