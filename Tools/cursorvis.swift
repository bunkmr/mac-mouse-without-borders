// 光标可见性探针：客观判定「隐藏光标到底生效没有」。
//
// 为什么需要它：
//   CGDisplayHideCursor 的返回值**不能**当判据 —— Apple 文档明确写着
//   "In most cases, the caller must be the foreground application to affect the cursor"，
//   后台进程调用会**返回 success 但毫无效果**。之前的 hide=1021次 日志就是这样骗过了我们。
//
// 本探针用 CGCursorIsVisible()（WindowServer 的真实状态，进程内改不了）做判据，
// 并对照验证 SetsCursorInBackground 私有属性是否能解锁「后台隐藏光标」。
//
// 用法: swiftc -O cursorvis.swift -o cursorvis && ./cursorvis

import CoreGraphics
import Foundation

// ── 私有符号 ────────────────────────────────────────────────────────────────
typealias CGSConnectionID = UInt32
typealias CGSSetConnectionPropertyFn =
    @convention(c) (CGSConnectionID, CGSConnectionID, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Int32
typealias CGSDefaultConnectionFn = @convention(c) () -> CGSConnectionID
typealias BoolFn = @convention(c) () -> UInt32   // boolean_t = UInt32

func sym<T>(_ name: String, as: T.Type) -> T? {
    guard let p = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
    return unsafeBitCast(p, to: T.self)
}

let cursorIsVisible = sym("CGCursorIsVisible", as: BoolFn.self)
let cursorDrawnInFB = sym("CGCursorIsDrawnInFramebuffer", as: BoolFn.self)
let defaultConn = sym("_CGSDefaultConnection", as: CGSDefaultConnectionFn.self)
let setConnProp = sym("CGSSetConnectionProperty", as: CGSSetConnectionPropertyFn.self)

func visible() -> String {
    guard let f = cursorIsVisible else { return "N/A" }
    return f() != 0 ? "可见" : "已隐藏"
}
func drawn() -> String {
    guard let f = cursorDrawnInFB else { return "N/A" }
    return f() != 0 ? "已画入帧缓冲" : "未画入"
}

print("=== 探针：本进程 = \(ProcessInfo.processInfo.processName) (PID \(getpid())) ===")
print("符号可用性: CGCursorIsVisible=\(cursorIsVisible != nil)"
      + " CGCursorIsDrawnInFramebuffer=\(cursorDrawnInFB != nil)"
      + " _CGSDefaultConnection=\(defaultConn != nil)"
      + " CGSSetConnectionProperty=\(setConnProp != nil)")
print()
print("[0] 基线            : \(visible()) / \(drawn())")

// ── 实验 A：直接 CGDisplayHideCursor（后台进程，不加私有属性）────────────────
print("\n--- 实验 A：裸调 CGDisplayHideCursor（复现「返回 success 但没效果」）---")
var aOK = 0
for _ in 0..<3 { if CGDisplayHideCursor(CGMainDisplayID()) == .success { aOK += 1 } }
print("      CGDisplayHideCursor 返回 success ×\(aOK)")
usleep(400_000)
let aRes = visible()
print("      结果: \(aRes) / \(drawn())")
if aRes == "可见" { print("      ⇒ ❌ 证实：返回值 success 但光标仍可见（后台进程限制）") }
else { print("      ⇒ ✅ 本机裸调居然生效了") }

var restore1 = 0
while restore1 < 6 { _ = CGDisplayShowCursor(CGMainDisplayID()); restore1 += 1 }
usleep(300_000)
print("      恢复后: \(visible())")

// ── 实验 B：SetsCursorInBackground + CGDisplayHideCursor ──────────────────
print("\n--- 实验 B：SetsCursorInBackground 私有属性 + CGDisplayHideCursor ---")
if let connFn = defaultConn, let propFn = setConnProp {
    let conn = connFn()
    let key = "SetsCursorInBackground" as CFString
    let keyPtr = Unmanaged.passUnretained(key).toOpaque()
    let valPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(kCFBooleanTrue!).toOpaque())
    let r = propFn(conn, conn, keyPtr, valPtr)
    print("      CGSSetConnectionProperty(\"SetsCursorInBackground\", true) → \(r)（0=成功）")
    var bOK = 0
    for _ in 0..<3 { if CGDisplayHideCursor(CGMainDisplayID()) == .success { bOK += 1 } }
    usleep(400_000)
    let bRes = visible()
    print("      结果: \(bRes) / \(drawn())")
    if bRes == "已隐藏" { print("      ⇒ ✅✅ 这个组合能让后台进程真正隐藏光标 —— 这就是要固化进 App 的修法") }
    else { print("      ⇒ ❌ 仍无效，需要换方案") }
    // 保持隐藏几秒，让调用方可以肉眼确认
    print("\n      保持隐藏 4 秒（可以肉眼看一眼屏幕）…")
    for _ in 0..<400 { CGDisplayHideCursor(CGMainDisplayID()); usleep(10_000) }
    print("      保持期结束: \(visible())")
    // 恢复
    var n = 0
    while n < 1000 { _ = CGDisplayShowCursor(CGMainDisplayID()); n += 1 }
    usleep(400_000)
    print("      恢复后: \(visible()) / \(drawn())")
} else {
    print("      ✗ 私有符号缺失，无法测试")
}
print("\n=== 完 ===")
