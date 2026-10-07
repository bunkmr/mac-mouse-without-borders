// ScreenLayout.swift
// 「屏幕布局」的几何推导。
//
// 【它解决什么】原先把「屏幕方位」「机器矩阵」「本机槽位」拆成了三处控件，彼此重复：
//   · 「屏幕方位」= 鼠标从哪条边滑出去（`InputController.switchEdge`）
//   · 「机器矩阵」= Windows 下发的 4 个槽位与联机状态
//   · 「本机槽位」= 本机占哪个槽（`Client.preferredSlot`）
//   三者在用户脑子里其实是**同一件事**：几台机器怎么摆。
//   合并后只剩一张「屏幕布局」棋盘，**方向由本机与对端的相对位置推导出来** ——
//   用户只要把自己的方块拖到正确的格子，不必再去理解"槽位"和"方位"的对应关系。
//
// 【协议依据】MWB 的机器池最多 4 台，槽位号 1..4 就是**物理位置**：
//   2×2 布局（Matrix 包 bit2 = MatrixTwoRowFlag）：1 2 / 3 4  （行优先）
//   1×4 布局（无该 bit）：                          1 2 3 4
//   （bit1 = MatrixSwapFlag 是"环绕"，只影响跨过最后一台后是否圈回第一台，
//     不改变相邻关系，所以推导方向时不需要它。）
//
// ★ 参考同类软件（Synergy / Barrier / Input Leap）的做法："Screens & Links" 就是一张
//   可拖动的屏幕棋盘，方位由图上的相对位置决定，而不是另开一个下拉框。

import Foundation
import CoreGraphics
import AppKit

public enum ScreenLayout {

    // MARK: - 出界判定（多显示器）

    /// 光标是否已经顶到**整块 Mac 桌面**在指定方向上的外边界。
    ///
    /// ★★ 必须传「所有显示器的并集」，**不能**传"光标所在那块屏"的 frame ★★
    ///
    /// 2026-10-06 事故（用户原话：「这个 Mac 本身自己在最右边了，但是鼠标还是可以往右穿越」）：
    /// 现场是**外接屏在左、MacBook 内建屏在右**：
    /// ```
    ///   MR2430（主）      x 0    .. 1536
    ///   Built-in Retina   x 1536 .. 3264     ← 在右侧
    /// ```
    /// 旧代码用「光标所在那块屏」的 frame 判边缘（`loc.x <= f.minX + 1`）：
    ///   · 光标还在外接屏 → `f.minX = 0`，要 x ≤ 1 才触发（看着是对的）；
    ///   · 光标一移进**内建屏** → `f` 换成内建屏，`f.minX = 1536`，
    ///     于是 `x ≈ 1536` 立刻满足 `x ≤ f.minX + 1` ⇒
    ///     **鼠标只是往右挪到内建屏上，就被判成"撞到了左边缘"，立刻跨到 Windows。**
    ///   ⇒ 内屏之间的**接缝**被误当成了出界点。判据只该看**整块桌面的外边界**。
    ///
    /// 取并集而不是「主屏」还有个好处：`.right` 方向也一并修好了 ——
    /// 用主屏时 `f.maxX = 1536`（接缝）会提前触发，用并集则是 x ≥ 3263（真正的最右边）。
    public static func hitsEdge(_ location: CGPoint, edge: SwitchEdge,
                                desktopBounds: CGRect) -> Bool {
        switch edge {
        case .left:   return location.x <= desktopBounds.minX + 1
        case .right:  return location.x >= desktopBounds.maxX - 1
        // CGEvent.location 是**左上原点**：y 越小越靠上。
        case .top:    return location.y <= desktopBounds.minY + 1
        case .bottom: return location.y >= desktopBounds.maxY - 1
        }
    }

    /// 若干个屏幕矩形求并 —— 即整块 Mac 桌面在 CG 坐标下的外接矩形。
    /// 传空数组时回落到一个 1920x1080 的保守值（绝不返回 `.null`，否则所有比较都失真）。
    public static func desktopBounds(_ frames: [CGRect]) -> CGRect {
        guard let first = frames.first else { return CGRect(x: 0, y: 0, width: 1920, height: 1080) }
        return frames.dropFirst().reduce(first) { $0.union($1) }
    }

    // MARK: - 屏幕矩形（唯一换算入口）

    /// 所有屏幕在 **CG 全局坐标系（左上原点）** 下的矩形。
    ///
    /// `NSScreen.frame` 是 AppKit 坐标（左下原点），直接和 `CGEvent.location` 混用会错，
    /// 尤其是边缘判断和 `CGWarpMouseCursorPosition`（它要求的正是 CG 坐标）。
    ///
    /// ★ 这里必须是**唯一**的 AppKit→CG 换算点：以前 `InputController` 里另有一份私有实现，
    ///   真机自检要复用它就只能抄一遍 —— 两份实现迟早会漂移。
    public static func currentScreenFramesCG() -> [CGRect] {
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

    // MARK: - 真机多屏出界自检

    /// 用**当前这台机器真实的屏幕排列**验证出界判定。
    ///
    /// 回归 2026-10-06「这个 Mac 自己在最右边了，但鼠标还是可以往右穿越」。
    ///
    /// 做法（不移动光标、不接管对端，用户正常使用时也能安全跑）：
    ///   在整个桌面上撒一批探测点，对每个方向分别用
    ///     ① 旧判据 = "光标所在那块屏"的 frame（**只在本自检里复刻**，生产代码已删）
    ///     ② 新判据 = 整块桌面的外框（`hitsEdge`，生产代码用的就是它）
    ///   求值，然后断言：
    ///     · 新判据**绝不**在桌面内部触发 —— 内屏之间的接缝不是出界点；
    ///     · 新判据在真正的外边界上**必须**触发 —— 否则自检就是空跑（阳性对照）。
    ///   同时把"旧判据会误触发多少次"打出来，让这次回归有据可查。
    public static func realMachineEdgeSelfTest() -> Bool {
        var fails: [String] = []
        func check(_ name: String, _ cond: Bool) { if !cond { fails.append(name) } }

        let frames = currentScreenFramesCG()
        let desk = desktopBounds(frames)
        print("屏幕(CG 左上原点)：")
        for (i, f) in frames.enumerated() {
            print("  [\(i)] x\(Int(f.minX))..\(Int(f.maxX))  y\(Int(f.minY))..\(Int(f.maxY))"
                  + "  \(Int(f.width))x\(Int(f.height))")
        }
        print("桌面外框：x\(Int(desk.minX))..\(Int(desk.maxX))  y\(Int(desk.minY))..\(Int(desk.maxY))"
              + "（\(frames.count) 块屏）")

        /// 旧判据（用"光标所在那块屏"的 frame）在下方 probe 里内联复刻：
        /// 每个探测点都要先取出"它落在哪块屏"再比较，写成闭包反而绕。
        var probes = 0
        var newFalsePositives: [String] = []
        var oldFalsePositives = 0
        var boundaryHits: [SwitchEdge: Int] = [:]

        // ⚠️ 取样必须**精确落到屏幕边界与接缝那一列像素**上：判据是
        //   `x <= minX + 1` 这种 1~2px 的窗口，只用「从 +3 起、步长 7」的网格
        //   会整整错开接缝（x=1536）和桌面最外沿（x=0 / x=3264）——
        //   上一版自检就是这样测出「外边界触发 0 次」的**假失败**（其实是根本没探到）。
        var xs = Set<CGFloat>()
        var ys = Set<CGFloat>()
        for s in frames {
            xs.insert(s.minX); xs.insert(s.minX + 1); xs.insert(s.midX)
            xs.insert(s.maxX - 1); xs.insert(s.maxX)
            ys.insert(s.minY); ys.insert(s.minY + 1); ys.insert(s.midY)
            ys.insert(s.maxY - 1); ys.insert(s.maxY)
        }
        xs.insert(desk.minX); xs.insert(desk.maxX)
        ys.insert(desk.minY); ys.insert(desk.maxY)
        for x in stride(from: desk.minX, through: desk.maxX, by: 11) { xs.insert(x) }
        for y in stride(from: desk.minY, through: desk.maxY, by: 11) { ys.insert(y) }

        for y in ys {
            for x in xs {
                let loc = CGPoint(x: x, y: y)
                // 只探"桌面范围内"的点；外边界那条线也要探（`CGRect.contains` 是左闭右开，
                // 用它会把 x == maxX 整整一条漏掉，所以要自己比较）。
                guard loc.x >= desk.minX, loc.x <= desk.maxX,
                      loc.y >= desk.minY, loc.y <= desk.maxY else { continue }
                // 该点所属的那块屏（旧判据用的就是它）。外边界上未必严格落在某块屏内部，
                // 放宽 1px 找最近的宿主屏即可。
                guard let host = frames.first(where: { $0.insetBy(dx: -1, dy: -1).contains(loc) })
                        ?? frames.first(where: { $0.contains(loc) }) else { continue }
                probes += 1
                for e in [SwitchEdge.left, .right, .top, .bottom] {
                    let new = hitsEdge(loc, edge: e, desktopBounds: desk)
                    let old: Bool
                    switch e {
                    case .left:   old = loc.x <= host.minX + 1
                    case .right:  old = loc.x >= host.maxX - 1
                    case .top:    old = loc.y <= host.minY + 1
                    case .bottom: old = loc.y >= host.maxY - 1
                    }
                    if new {
                        boundaryHits[e, default: 0] += 1
                        // 新判据触发点必须贴在**桌面外边界**上
                        let onOuter: Bool
                        switch e {
                        case .left:   onOuter = loc.x <= desk.minX + 2
                        case .right:  onOuter = loc.x >= desk.maxX - 2
                        case .top:    onOuter = loc.y <= desk.minY + 2
                        case .bottom: onOuter = loc.y >= desk.maxY - 2
                        }
                        if !onOuter {
                            newFalsePositives.append(
                                "\(e.rawValue) 在桌面内部误触发 @(\(Int(x)),\(Int(y)))")
                        }
                    }
                    // 旧判据会触发、新判据不触发 ⇒ 这正是被修掉的那类误触发
                    if old && !new { oldFalsePositives += 1 }
                }
            }
        }

        print("探测点 \(probes) 个 × 4 方向；"
              + "新判据在外边界触发 \(boundaryHits.values.reduce(0, +)) 次"
              + "（左\(boundaryHits[.left] ?? 0)/右\(boundaryHits[.right] ?? 0)"
              + "/上\(boundaryHits[.top] ?? 0)/下\(boundaryHits[.bottom] ?? 0)）")
        print("旧判据（按「所在屏」）会在**桌面内部**误触发 \(oldFalsePositives) 次"
              + (frames.count > 1 ? "  ← 这就是「往右挪鼠标却从左边缘跨屏」的来源" : ""))

        // 断言 ①：新判据不得在桌面内部触发（内屏接缝不是出界点）
        check("新判据在桌面内部零误触发", newFalsePositives.isEmpty)
        for m in newFalsePositives.prefix(5) { print("    ⚠️ \(m)") }

        // 断言 ②（阳性对照）：外边界必须能触发几个方向，否则说明探测或判据失效、自检是空跑
        check("外边界必须能触发（阳性对照）", boundaryHits.values.reduce(0, +) > 0)

        // 断言 ③：多屏时，接缝确有必要区分 —— 旧判据若一次都不误触发，说明现场没覆盖到该场景
        if frames.count > 1 {
            check("多屏现场确实能暴露旧判据的缺陷（旧误触发 > 0）", oldFalsePositives > 0)
        }

        print(fails.isEmpty
              ? "  ✓ 出界判定真机自检通过（\(frames.count) 块屏；内屏接缝不触发，外边界正常触发）"
              : "  ✗ 出界判定真机自检失败：\n    " + fails.joined(separator: "\n    "))
        return fails.isEmpty
    }

    /// 由「本机槽位 / 对端槽位」推导鼠标该从哪条边滑出去。
    ///
    /// - Returns: `(方向, 是否属于对角线兜底推测)`；槽位非法或两台占同一槽时返回 nil。
    ///
    /// 对角线（2×2 里的 1↔4 / 2↔3）没有唯一答案 —— 里世界既可能横着走也可能竖着走。
    /// 这里**横向优先**（键鼠共享里左右并排是最常见的摆法），并把 `guessed` 置真，
    /// 界面据此提示"这是推测，可手动改"。
    public static func exitEdge(selfSlot: Int, peerSlot: Int, twoRow: Bool)
        -> (edge: SwitchEdge, guessed: Bool)? {
        guard (1...4).contains(selfSlot), (1...4).contains(peerSlot), selfSlot != peerSlot else {
            return nil
        }
        if twoRow {
            let sRow = (selfSlot - 1) / 2, sCol = (selfSlot - 1) % 2
            let pRow = (peerSlot - 1) / 2, pCol = (peerSlot - 1) % 2
            if sRow == pRow { return (pCol > sCol ? .right : .left, false) }
            if sCol == pCol { return (pRow > sRow ? .bottom : .top, false) }
            return (pCol > sCol ? .right : .left, true)          // 对角 → 横向优先
        }
        return (peerSlot > selfSlot ? .right : .left, false)      // 1×4 只有左右
    }

    /// 棋盘上每个槽位的 (行, 列)，供界面摆放方块。
    public static func cell(of slot: Int, twoRow: Bool) -> (row: Int, col: Int) {
        guard (1...4).contains(slot) else { return (0, 0) }
        if twoRow { return ((slot - 1) / 2, (slot - 1) % 2) }
        return (0, slot - 1)
    }

    /// 反向：把「本机在某方向边缘」翻译成"对端应该落在哪个槽位"。
    ///
    /// 用于"用户直接点方向"的场景（未连接时没有对端槽位）：先按当前棋盘算出目标槽，
    /// 之后仍以槽位为准 —— 这样"拖动方块"和"点方向"两条操作不会互相打架。
    public static func peerSlot(forEdge edge: SwitchEdge, selfSlot: Int, twoRow: Bool) -> Int? {
        guard (1...4).contains(selfSlot) else { return nil }
        let sRow = twoRow ? (selfSlot - 1) / 2 : 0
        let sCol = twoRow ? (selfSlot - 1) % 2 : selfSlot - 1
        let cols = twoRow ? 2 : 4
        let rows = twoRow ? 2 : 1
        let (dRow, dCol): (Int, Int)
        switch edge {
        case .left:   (dRow, dCol) = (0, -1)
        case .right:  (dRow, dCol) = (0,  1)
        case .top:    (dRow, dCol) = (-1, 0)
        case .bottom: (dRow, dCol) = (1,  0)
        }
        var r = sRow + dRow, c = sCol + dCol
        // 溢出时按"环绕"折叠回棋盘内（与 MWB 的 Circle 模式语义一致：
        // 从最左边滑出会到达最右边那台，而不是出界）。
        if r < 0 { r += rows } else if r >= rows { r -= rows }
        if c < 0 { c += cols } else if c >= cols { c -= cols }
        let slot = r * cols + c + 1
        return slot == selfSlot ? nil : slot
    }

    // MARK: - 自检

    /// 把关键几何钉死：方向推导 + 反向映射必须**互为逆运算**（在非对角情形下）。
    public static func selfTest() -> Bool {
        var fails: [String] = []
        func check(_ name: String, _ cond: Bool) { if !cond { fails.append(name) } }

        // 2×2：1=左上 2=右上 3=左下 4=右下
        check("2×2 本机1→对端2 应为右", exitEdge(selfSlot: 1, peerSlot: 2, twoRow: true)?.edge == .right)
        check("2×2 本机2→对端1 应为左", exitEdge(selfSlot: 2, peerSlot: 1, twoRow: true)?.edge == .left)
        check("2×2 本机1→对端3 应为下", exitEdge(selfSlot: 1, peerSlot: 3, twoRow: true)?.edge == .bottom)
        check("2×2 本机3→对端1 应为上", exitEdge(selfSlot: 3, peerSlot: 1, twoRow: true)?.edge == .top)
        check("2×2 本机2→对端4 应为下", exitEdge(selfSlot: 2, peerSlot: 4, twoRow: true)?.edge == .bottom)
        check("2×2 本机4→对端3 应为左", exitEdge(selfSlot: 4, peerSlot: 3, twoRow: true)?.edge == .left)

        // 对角 → 横向优先，且必须标记为"推测"
        let d1 = exitEdge(selfSlot: 1, peerSlot: 4, twoRow: true)
        check("2×2 对角 1→4 = 右 + 推测", d1?.edge == .right && d1?.guessed == true)
        let d2 = exitEdge(selfSlot: 2, peerSlot: 3, twoRow: true)
        check("2×2 对角 2→3 = 左 + 推测", d2?.edge == .left && d2?.guessed == true)
        check("非对角不得标推测", exitEdge(selfSlot: 1, peerSlot: 2, twoRow: true)?.guessed == false)

        // 1×4 一行
        check("1×4 1→2 应为右", exitEdge(selfSlot: 1, peerSlot: 2, twoRow: false)?.edge == .right)
        check("1×4 4→1 应为左", exitEdge(selfSlot: 4, peerSlot: 1, twoRow: false)?.edge == .left)

        // 非法输入一律 nil（而不是猜一个）
        check("同槽返回 nil", exitEdge(selfSlot: 2, peerSlot: 2, twoRow: true) == nil)
        check("槽位 0 返回 nil", exitEdge(selfSlot: 0, peerSlot: 2, twoRow: true) == nil)
        check("槽位 5 返回 nil", exitEdge(selfSlot: 1, peerSlot: 5, twoRow: true) == nil)

        // 棋盘坐标
        do { let c = cell(of: 3, twoRow: true); check("2×2 槽3 = 行1 列0", c.row == 1 && c.col == 0) }
        do { let c = cell(of: 3, twoRow: false); check("1×4 槽3 = 行0 列2", c.row == 0 && c.col == 2) }

        // 反向映射：非对角情形必须与 exitEdge 互为逆
        for (s, p) in [(1, 2), (2, 1), (1, 3), (3, 1), (4, 3), (2, 4)] {
            guard let e = exitEdge(selfSlot: s, peerSlot: p, twoRow: true)?.edge,
                  let back = peerSlot(forEdge: e, selfSlot: s, twoRow: true) else {
                fails.append("逆运算 本机\(s)/对端\(p) 取不到方向"); continue
            }
            check("逆运算 本机\(s)/对端\(p)：方向 \(e.rawValue) 应回到槽 \(p)", back == p)
        }
        // 边界环绕：本机在 1（左上）点"左" → 折回同一行的第 2 列 = 槽 2
        check("环绕 本机1 点左 → 槽2", peerSlot(forEdge: .left, selfSlot: 1, twoRow: true) == 2)
        check("1×4 环绕 本机1 点左 → 末槽4", peerSlot(forEdge: .left, selfSlot: 1, twoRow: false) == 4)

        // ⑥ ★ 多显示器出界判定（回归 2026-10-06「Mac 在最右边，鼠标却还能往右跨」）
        //
        // 用**用户现场的精确坐标**，不是编的：
        //   MR2430（主）      x 0    .. 1536   y 0 .. 864
        //   Built-in Retina   x 1536 .. 3264   y -253 .. 864   ← 在右侧
        let main = CGRect(x: 0, y: 0, width: 1536, height: 864)
        let builtin = CGRect(x: 1536, y: -253, width: 1728, height: 1117)
        let desk = desktopBounds([main, builtin])
        check("桌面外框 = 全并集", desk == CGRect(x: 0, y: -253, width: 3264, height: 1117))

        // 单屏：桌面外框 == 那块屏，行为与旧版一致（不能把单屏改坏）
        let solo = desktopBounds([main])
        check("单屏 左边缘触发", hitsEdge(CGPoint(x: 0, y: 400), edge: .left, desktopBounds: solo))
        check("单屏 右边缘触发", hitsEdge(CGPoint(x: 1536, y: 400), edge: .right, desktopBounds: solo))
        check("单屏 屏幕中间不触发", !hitsEdge(CGPoint(x: 768, y: 400), edge: .left, desktopBounds: solo))

        // ★ 事故本体：光标在主屏与内建屏的**接缝**上。
        //   接缝 x=1536 在内建屏上是 minX，旧代码（按"所在屏"）会判成左边缘 ⇒ 往右移也跨屏。
        //   按整块桌面的外框，它只是内部接缝，**任何方向都不该触发**。
        let seam = CGPoint(x: 1536, y: 400)
        check("接缝处 不应触发左", !hitsEdge(seam, edge: .left, desktopBounds: desk))
        check("接缝处 不应触发右", !hitsEdge(seam, edge: .right, desktopBounds: desk))
        check("内建屏内部(x=2000) 不应触发左",
              !hitsEdge(CGPoint(x: 2000, y: 400), edge: .left, desktopBounds: desk))
        // 真正的最左/最右仍然要触发
        check("最左(x=0) 触发左", hitsEdge(CGPoint(x: 0, y: 400), edge: .left, desktopBounds: desk))
        check("最右(x=3264) 触发右", hitsEdge(CGPoint(x: 3264, y: 400), edge: .right, desktopBounds: desk))
        // 内建屏比主屏高（y 到 -253）⇒ 上方边界由内建屏决定，取并集才算得对
        check("最上(y=-253) 触发上", hitsEdge(CGPoint(x: 2000, y: -253), edge: .top, desktopBounds: desk))
        check("外接屏顶部(y=0) 不触发上（内建屏还在上面）",
              !hitsEdge(CGPoint(x: 700, y: 0), edge: .top, desktopBounds: desk))
        // 空数组兜底不能是 .null（否则所有比较都失真）
        check("空屏幕数组有兜底", desktopBounds([]).width > 0 && desktopBounds([]).height > 0)

        print(fails.isEmpty
              ? "  ✓ 屏幕布局推导全过（2×2 / 1×4 / 对角推测 / 非法输入 / 逆运算 / 环绕 / 多屏出界）"
              : "  ✗ 屏幕布局推导失败：\n    " + fails.joined(separator: "\n    "))
        return fails.isEmpty
    }
}
