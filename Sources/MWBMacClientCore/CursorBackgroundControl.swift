// CursorBackgroundControl.swift
// 「后台进程隐藏光标」的解锁开关 + 光标可见性的**客观**判定。
//
// 【为什么需要这个文件】
//
// Apple 对 `CGDisplayHideCursor` 的文档原话是：
//   "This function hides the cursor regardless of its current location. ...
//    **In most cases, the caller must be the foreground application to affect the cursor.**"
//
// 我们的 App 是 `LSUIElement` 的后台菜单栏应用，**永远不在前台**。
// 于是 `CGDisplayHideCursor()` 会**返回 `.success` 但什么都不做** ——
// 这正是 2026-09-14 那次「日志里 hide=1021次，用户却看得见光标满屏跑」的根因。
// 教训：**绝不能拿 `CGDisplayHideCursor` 的返回值当判据**，它只会骗人。
//
// WindowServer 留了一个未公开的 per-connection 开关 `SetsCursorInBackground`：
// 置为 true 之后，这条连接上的光标操作就被允许在**后台**生效。
// Apple DTS 工程师在开发者论坛（thread 756199）里确认过这就是「后台控制光标」的标准做法。
//
// 【判定手段】
// `CGCursorIsVisible()` 读的是 WindowServer 里的真实状态，进程内怎么改都伪造不了 ——
// 这是唯一可信的「隐藏到底生效没有」判据（此前用 `screencapture` 逐帧比对的做法已被证伪：
// 本机取像不稳定，同一状态间隔 0.5s 的两张图差异可达 90%）。

import Foundation
import CoreFoundation
import CoreGraphics
import Darwin

/// 光标隐藏的底层能力封装（后台解锁 + 可见性查询）。
public enum CursorBackgroundControl {

    // MARK: - 私有符号绑定

    private typealias CGSConnectionID = UInt32
    private typealias SetConnectionPropertyFn =
        @convention(c) (CGSConnectionID, CGSConnectionID,
                        UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Int32
    private typealias DefaultConnectionFn = @convention(c) () -> CGSConnectionID
    private typealias BoolFn = @convention(c) () -> UInt32   // boolean_t = UInt32

    /// `RTLD_DEFAULT`：在**已加载的**镜像里找符号（CoreGraphics/ApplicationServices 一定已加载）。
    private static let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)

    private static func sym<T>(_ name: String, as: T.Type) -> T? {
        guard let rtldDefault, let p = dlsym(rtldDefault, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }

    // MARK: - 可见性查询（客观判据）

    /// 光标此刻在 WindowServer 里**是否可见**。
    /// - Returns: `true` 可见 / `false` 已隐藏 / `nil` 表示本机拿不到该符号。
    public static func isCursorVisible() -> Bool? {
        guard let f = sym("CGCursorIsVisible", as: BoolFn.self) else { return nil }
        return f() != 0
    }

    /// 供日志用的中文描述。
    public static func visibilityDescription() -> String {
        switch isCursorVisible() {
        case .some(true):  return "可见★"
        case .some(false): return "已隐藏"
        case .none:        return "N/A"
        }
    }

    // MARK: - 后台解锁

    private static var didEnable = false
    private static var enableResult: Bool?

    /// 解锁「后台进程控制光标」。**幂等**，可随意重复调用。
    /// - Returns: true=已解锁；false=私有符号缺失/设置失败（此时应降级为「只锁位置、不隐藏」）。
    @discardableResult
    public static func enableBackgroundCursorControl() -> Bool {
        if didEnable { return enableResult ?? false }
        didEnable = true

        guard let connFn = sym("_CGSDefaultConnection", as: DefaultConnectionFn.self),
              let propFn = sym("CGSSetConnectionProperty", as: SetConnectionPropertyFn.self) else {
            enableResult = false
            return false
        }
        let conn = connFn()
        let key = "SetsCursorInBackground" as CFString
        let keyPtr = Unmanaged.passUnretained(key).toOpaque()
        let valPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(kCFBooleanTrue!).toOpaque())
        let err = propFn(conn, conn, keyPtr, valPtr)
        enableResult = (err == 0)
        return err == 0
    }

    /// 第一次调用时做解锁并把结果写进日志；之后是空操作。
    public static func enableOnce(report: ((String) -> Void)? = nil) {
        if didEnable { return }
        let ok = enableBackgroundCursorControl()
        let vis = visibilityDescription()
        if ok {
            report?("[MWB] 已解锁「后台进程控制光标」(SetsCursorInBackground) —— "
                    + "隐藏光标自此刻起才真正生效（当前可见性=\(vis)）")
        } else {
            report?("[MWB] ⚠️ 无法解锁「后台进程控制光标」—— CGDisplayHideCursor 会**返回 success 但不生效**，"
                    + "控制远端时本机光标可能仍然可见（当前可见性=\(vis)）")
        }
    }
}
