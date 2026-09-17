// MouseBinding.swift
// 可编程鼠标键：把「鼠标按键 + 手势」映射成「本机 Mac / 远端 Windows 要执行的动作」。
//
// 【为什么需要这一层】
// 老版本把「后退 / 前进」两个侧键**写死**在界面上，只能映射一个组合键，
// 也不能改是哪两个键。现实里的鼠标有 3~15 个键（侧键、DPI 键、滚轮左右拨、
// 拇指键、指托键…），而且「同一个键在不同手势下」的期望完全不一样：
//   · 点一下        → 复制 / 粘贴（键序列）
//   · 按住 + 滚动   → 放大缩小 / 水平滚动 / 缩放
//   · 按住 + 拖动   → 旋转 / 滚动导航
// 所以这里把「按键」做成**可增删的表**，每个键有 3 手势 × 2 侧位 = 6 个独立设置。
//
// 【统一表示：动作 = VK 序列】
// 不论「放大」还是「用户自定义组合键」，最终都落成一串 Windows 虚拟键码
// （按下顺序；抬起由调用方按逆序走）：
//   · **远端**执行 → 把这串 VK 直接打进 MWB 的 KEYBDATA 包（协议里本来就是 VK）
//   · **本机**执行 → 用 InputController 既有的 `vkToMac` 表翻成 Mac keycode 本机注入
// 这样「功能清单」与「两边怎么实现」解耦：加一个新功能只要在下表加一行，
// 而且**离线可断言**（`mwbmac --mouse-map-selftest`）。
//
// 【为什么"点按"要延迟 120ms 才发】
// 按下侧键的那一刻无法知道用户是「点一下」还是「按住去滚动 / 拖动」。
// 老版本是「按下即发」，于是"按住滚动"会先误触发一次点按动作（很别扭）。
// 现在的判定：按下**先不发**；松手即发（手感上零延迟）；若按住超过 120ms
// 既没松手也没滚动 / 拖动，就当点按发出去；一旦检测到滚动或拖动，永久取消本次点按。

import Foundation

// MARK: - 动作分组（界面下拉用）

public enum MouseActionGroup: String, CaseIterable, Identifiable {
    case basic, zoom, scroll, system, rotate

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .basic:  return "基本"
        case .zoom:   return "缩放"
        case .scroll: return "滚动"
        case .system: return "系统"
        case .rotate: return "旋转"
        }
    }
}

// MARK: - 动作清单

/// 一个鼠标手势在**某一侧**（本机 Mac / 远端 Windows）要执行的动作。
///
/// 命名用 `off` 而不是 `none`：`none` 与 `Optional.none` 在 Swift 里会打架，
/// 每次写 `.none` 编译器都要警告一次「Assuming you mean MouseAction.none」。
public enum MouseAction: String, Codable, CaseIterable, Identifiable {
    case off
    case custom
    case zoomIn
    case zoomOut
    case scrollVertical
    case scrollHorizontal
    case scrollZoom
    case launchpad
    case missionControl
    case showDesktop
    case appWindows
    case rotateCW
    case rotateCCW

    public var id: String { rawValue }

    public var group: MouseActionGroup {
        switch self {
        case .off, .custom:                                   return .basic
        case .zoomIn, .zoomOut:                               return .zoom
        case .scrollVertical, .scrollHorizontal, .scrollZoom: return .scroll
        case .launchpad, .missionControl, .showDesktop,
             .appWindows:                                     return .system
        case .rotateCW, .rotateCCW:                           return .rotate
        }
    }

    public var displayName: String {
        switch self {
        case .off:              return "不映射（原样转发）"
        case .custom:           return "自定义组合键…"
        case .zoomIn:           return "放大"
        case .zoomOut:          return "缩小"
        case .scrollVertical:   return "垂直滚动 / 滚动导航"
        case .scrollHorizontal: return "水平滚动"
        case .scrollZoom:       return "滚动缩放（Cmd/Ctrl + 滚轮）"
        case .launchpad:        return "启动台 / 开始菜单"
        case .missionControl:   return "空间调度中心 / 任务视图"
        case .showDesktop:      return "显示桌面"
        case .appWindows:       return "应用窗口 / 任务视图"
        case .rotateCW:         return "向右旋转"
        case .rotateCCW:        return "向左旋转"
        }
    }

    /// 这个动作是不是「轴改写」而不是「键序列」。
    /// 轴类动作没有键序列，由捕获侧直接改写滚轮 / 位移。
    public var axisOp: MouseAxisOp? {
        switch self {
        case .scrollVertical:   return .vertical
        case .scrollHorizontal: return .horizontal
        case .scrollZoom:       return .zoom
        default:                return nil
        }
    }

    /// 本机（Mac）要有 App 级动作、无法用按键表达的那几个。
    public var localAppAction: LocalAppAction? {
        switch self {
        // 启动台在 macOS 上没有系统级快捷键（各机器 F4 含义不同），只能直接打开 App。
        case .launchpad: return .launchpad
        default:         return nil
        }
    }

    // MARK: 键序列（VK，按下顺序）

    /// 本机（Mac）执行时的 VK 序列。`custom` 是用户在界面上填的组合键串。
    ///
    /// 【为什么用 VK 而不是 Mac keycode】本机的 keycode 表（`vkToMac`）已经存在且
    /// 双向可逆，统一用 VK 表示可以让两侧共用同一份定义，也便于离线断言。
    public func localVKs(custom: String = "") -> [Int32]? {
        switch self {
        case .off:
            return nil
        case .custom:
            return MWBChord.parse(custom)?.wireVKList
        case .zoomIn:
            return [0x5B, 0xBB]              // ⌘=
        case .zoomOut:
            return [0x5B, 0xBD]              // ⌘-
        case .missionControl:
            return [0x11, 0x26]              // ⌃↑
        case .appWindows:
            return [0x11, 0x28]              // ⌃↓
        case .showDesktop:
            return [0x7A]                    // F11
        case .rotateCW:
            return [0x5B, 0x52]              // ⌘R（依赖目标 App）
        case .rotateCCW:
            return [0x5B, 0x10, 0x52]        // ⌘⇧R（依赖目标 App）
        // 轴类与本机 App 级动作没有键序列
        case .scrollVertical, .scrollHorizontal, .scrollZoom, .launchpad:
            return nil
        }
    }

    /// 远端（Windows）执行时的 VK 序列。
    public func remoteVKs(custom: String = "") -> [Int32]? {
        switch self {
        case .off:
            return nil
        case .custom:
            return MWBChord.parse(custom)?.wireVKList
        case .zoomIn:
            return [0x11, 0xBB]              // Ctrl+=（浏览器 / 看图 / Office 通用放大）
        case .zoomOut:
            return [0x11, 0xBD]              // Ctrl+-
        case .launchpad:
            return [0x5B]                    // Win（开始菜单）
        case .missionControl, .appWindows:
            return [0x5B, 0x09]              // Win+Tab（任务视图）
        case .showDesktop:
            return [0x5B, 0x44]              // Win+D
        case .rotateCW:
            return [0x11, 0x52]              // Ctrl+R（依赖目标 App）
        case .rotateCCW:
            return [0x11, 0x10, 0x52]        // Ctrl+Shift+R（依赖目标 App）
        case .scrollVertical, .scrollHorizontal, .scrollZoom:
            return nil
        }
    }

    /// 界面上的一句说明（用户在高级设置里直接看到）。
    public var hint: String? {
        switch self {
        case .zoomIn, .zoomOut:
            return "标准快捷键：Mac ⌘=/⌘-，Windows Ctrl+=/Ctrl+-（浏览器、看图、Office 通用）。"
        case .launchpad:
            return "Mac 打开「启动台」，Windows 按 Win 键开「开始菜单」。"
        case .missionControl:
            return "Mac ⌃↑（调度中心），Windows Win+Tab（任务视图）。"
        case .appWindows:
            return "Mac ⌃↓（应用窗口），Windows Win+Tab（任务视图）。"
        case .showDesktop:
            return "Mac F11，Windows Win+D。若 Mac 上没反应，请在「系统设置 → 键盘 → 键盘快捷键 → 调度中心」里给「显示桌面」勾上 F11。"
        case .rotateCW, .rotateCCW:
            return "旋转没有系统级统一快捷键，默认给的是常见值（Mac ⌘R / ⌘⇧R，Windows Ctrl+R / Ctrl+Shift+R），"
                 + "不同 App 不一样 —— 请在目标 App 里确认，或用「自定义组合键」改成它真正认识的键。"
        case .scrollVertical, .scrollHorizontal, .scrollZoom:
            return "轴改写：按住该键时滚轮（或鼠标位移）不再发出普通滚动，而是被改成这里选的方向 / 缩放。"
        case .custom:
            return "写法同「自定义映射」：`cmd+shift+z`、`ctrl+alt+1`。跨屏时按**远端**语义解释。"
        case .off:
            return nil
        }
    }
}

/// 轴改写类动作。
public enum MouseAxisOp: String, Codable {
    /// 垂直滚动（默认行为，用于明确接管"按住时也垂直滚动"）
    case vertical
    /// 水平滚动（滚轮的 Y 增量改成 X 增量）
    case horizontal
    /// 滚动缩放（滚轮 → Cmd/Ctrl + 滚轮）
    case zoom
}

/// 只能在 App 层做、没法用按键序列表达的本机动作。
public enum LocalAppAction: String {
    case launchpad
}

// MARK: - 单个手势的设置

/// 「某个键 + 某个手势 + 某一侧」的一项设置。
public struct MouseActionSpec: Codable, Equatable, Hashable {
    public var action: MouseAction = .off
    /// `action == .custom` 时用户填的组合键。
    public var custom: String = ""

    public init() {}

    public init(_ action: MouseAction, custom: String = "") {
        self.action = action
        self.custom = custom
    }

    /// 这条设置会不会真正接管该手势。
    /// 自定义但填错了（解析不出来）视为**未接管** —— 宁可保留原行为，
    /// 也不要因为一个错字把用户的侧键变成"什么都不做"。
    public var isActive: Bool {
        switch action {
        case .off:    return false
        case .custom: return MWBChord.parse(custom) != nil
        default:      return true
        }
    }

    /// 界面上的一行摘要。
    public var summary: String {
        switch action {
        case .off:    return "—"
        case .custom: return custom.isEmpty ? "自定义（未填写）" : custom
        default:      return action.displayName
        }
    }
}

// MARK: - 一个鼠标键

/// 一个鼠标按键的完整行为定义。
public struct MouseButtonBinding: Codable, Identifiable, Equatable {
    public var id: UUID = UUID()
    /// macOS 的 `mouseEventButtonNumber`：0=左 1=右 2=中 3=第 4 键 4=第 5 键 …
    /// 界面上一律换算成 **1 基**的「物理按键号」显示（见 `physicalLabel`）。
    public var macButton: Int
    /// 用户给它起的名字（空 = 只用自动名）。
    public var note: String = ""

    // ① 点按：本机 / 远端各一份（键序列 或 轴）
    public var macTap = MouseActionSpec()
    public var winTap = MouseActionSpec()
    // ② 按住 + 滚动
    public var macScroll = MouseActionSpec()
    public var winScroll = MouseActionSpec()
    // ③ 按住 + 拖动
    public var macDrag = MouseActionSpec()
    public var winDrag = MouseActionSpec()

    public init(macButton: Int, note: String = "") {
        self.macButton = macButton
        self.note = note
    }

    private enum CodingKeys: String, CodingKey {
        case id, macButton, note
        case macTap, winTap, macScroll, winScroll, macDrag, winDrag
    }

    /// 手写解码：以后再加字段时，老数据缺字段也不会整条解码失败
    /// （Swift 自动合成的 `init(from:)` 对缺失 key 会直接抛错）。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id        = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        macButton = (try? c.decode(Int.self, forKey: .macButton)) ?? 3
        note      = (try? c.decode(String.self, forKey: .note)) ?? ""
        macTap    = (try? c.decode(MouseActionSpec.self, forKey: .macTap)) ?? MouseActionSpec()
        winTap    = (try? c.decode(MouseActionSpec.self, forKey: .winTap)) ?? MouseActionSpec()
        macScroll = (try? c.decode(MouseActionSpec.self, forKey: .macScroll)) ?? MouseActionSpec()
        winScroll = (try? c.decode(MouseActionSpec.self, forKey: .winScroll)) ?? MouseActionSpec()
        macDrag   = (try? c.decode(MouseActionSpec.self, forKey: .macDrag)) ?? MouseActionSpec()
        winDrag   = (try? c.decode(MouseActionSpec.self, forKey: .winDrag)) ?? MouseActionSpec()
    }

    /// 界面标题：「按键 4（通常为「后退」） — 后退」。
    public var displayName: String {
        let base = "按键 \(MouseBindingStore.physicalLabel(macButton))"
        return note.isEmpty ? base : "\(base) — \(note)"
    }

    /// 该键在某一侧是否至少有一项设置会生效（用于判断"要不要吞掉原按键"）。
    public func hasAnyAction(remote: Bool) -> Bool {
        if remote {
            return winTap.isActive || winScroll.isActive || winDrag.isActive
        }
        return macTap.isActive || macScroll.isActive || macDrag.isActive
    }
}

// MARK: - 表

/// 可增删的鼠标键表 + 持久化（存成 JSON 字符串进 UserDefaults）。
public struct MouseBindingStore {
    public private(set) var bindings: [MouseButtonBinding] = []

    public init() {}

    public init(json: String?) { load(json: json) }

    // MARK: 编号口径

    /// macOS 0 基按键号 → 用户视角的「物理按键号（1 基）」。
    ///
    /// ★ 这条务必记住：macOS 的 `mouseEventButtonNumber` 是 **0 基**
    /// （0=左 1=右 2=中 3=第 4 键 4=第 5 键），而鼠标包装 / 驱动面板 / Windows
    /// 一律按 **1 基**叫「Button 4 / Button 5」。只打一个号，用户看到的永远
    /// 比自己的鼠标少 1，必然怀疑「后退/前进接反了」（2026-09-17 用户就为此问过）。
    public static func physicalLabel(_ macNumber: Int) -> String {
        let n = macNumber + 1
        switch macNumber {
        case 0:  return "\(n)（左键）"
        case 1:  return "\(n)（右键）"
        case 2:  return "\(n)（中键）"
        case 3:  return "\(n)（通常为「后退」）"
        case 4:  return "\(n)（通常为「前进」）"
        default: return "\(n)"
        }
    }

    // MARK: 增删查

    public func binding(for macButton: Int) -> MouseButtonBinding? {
        bindings.first { $0.macButton == macButton }
    }

    public mutating func add(macButton: Int, note: String = "") -> Bool {
        guard !bindings.contains(where: { $0.macButton == macButton }) else { return false }
        bindings.append(MouseButtonBinding(macButton: macButton, note: note))
        bindings.sort { $0.macButton < $1.macButton }
        return true
    }

    public mutating func remove(id: UUID) {
        bindings.removeAll { $0.id == id }
    }

    /// 放入 / 替换一条（按 `macButton` 去重）。
    /// 供上层用自己的 `@Published` 数组重建表 —— 数组才是 SwiftUI 的观察对象，
    /// store 只是「落盘 / 下发」的载体。
    public mutating func upsert(_ b: MouseButtonBinding) {
        bindings.removeAll { $0.macButton == b.macButton }
        bindings.append(b)
        bindings.sort { $0.macButton < $1.macButton }
    }

    public mutating func update(_ b: MouseButtonBinding) {
        guard let i = bindings.firstIndex(where: { $0.id == b.id }) else { return }
        bindings[i] = b
        bindings.sort { $0.macButton < $1.macButton }
    }

    // MARK: 持久化

    public mutating func load(json: String?) {
        guard let s = json, !s.isEmpty, let d = s.data(using: .utf8) else {
            bindings = []; return
        }
        bindings = (try? JSONDecoder().decode([MouseButtonBinding].self, from: d)) ?? []
        bindings.sort { $0.macButton < $1.macButton }
    }

    public func json() -> String {
        guard let d = try? JSONEncoder().encode(bindings) else { return "[]" }
        return String(data: d, encoding: .utf8) ?? "[]"
    }

    /// 从 v1.4 及更早的「后退 / 前进两个下拉框」迁移过来。
    /// 只在表为空时执行，不会覆盖用户已经建好的表。
    public mutating func migrateFromLegacy(backChord: String, forwardChord: String) {
        guard bindings.isEmpty else { return }
        var made: [MouseButtonBinding] = []
        if !backChord.isEmpty, MWBChord.parse(backChord) != nil {
            var b = MouseButtonBinding(macButton: 3, note: "后退（旧设置迁移）")
            b.winTap = MouseActionSpec(.custom, custom: backChord)
            made.append(b)
        }
        if !forwardChord.isEmpty, MWBChord.parse(forwardChord) != nil {
            var b = MouseButtonBinding(macButton: 4, note: "前进（旧设置迁移）")
            b.winTap = MouseActionSpec(.custom, custom: forwardChord)
            made.append(b)
        }
        bindings = made
    }

    public var isEmpty: Bool { bindings.isEmpty }

    /// 界面上的「已配置 N 个按键」回显。
    public var summary: String {
        if bindings.isEmpty { return "尚未添加任何按键（侧键将按原样作为鼠标按键转发）" }
        let names = bindings.map { MouseBindingStore.physicalLabel($0.macButton) }
        return "已配置 \(bindings.count) 个按键：\(names.joined(separator: "、"))"
    }

    // MARK: 离线自检

    /// 供 `mwbmac --mouse-map-selftest` 使用。
    /// 【为什么要断言这些】动作表是"数据"，最容易在改一处时把另一处改坏，
    /// 而它在真机上表现为「某个侧键突然什么都不做」，排查成本极高。
    public static func selfTest() -> (Int, Int, [String]) {
        var pass = 0, total = 0
        var fails: [String] = []
        func check(_ name: String, _ ok: Bool) {
            total += 1
            if ok { pass += 1 } else { fails.append(name) }
        }

        // ① 编号口径：0 基 → 1 基
        check("macOS 号 3 → 物理按键 4", physicalLabel(3).hasPrefix("4"))
        check("macOS 号 4 → 物理按键 5", physicalLabel(4).hasPrefix("5"))

        // ② 键序列：本机 / 远端各一份，且方向正确
        check("本机放大 = ⌘=", MouseAction.zoomIn.localVKs() == [0x5B, 0xBB])
        check("远端放大 = Ctrl+=", MouseAction.zoomIn.remoteVKs() == [0x11, 0xBB])
        check("远端开始菜单 = 单按 Win 键", MouseAction.launchpad.remoteVKs() == [0x5B])
        check("远端任务视图 = Win+Tab", MouseAction.missionControl.remoteVKs() == [0x5B, 0x09])
        check("远端显示桌面 = Win+D", MouseAction.showDesktop.remoteVKs() == [0x5B, 0x44])
        check("本机调度中心 = ⌃↑", MouseAction.missionControl.localVKs() == [0x11, 0x26])
        check("本机显示桌面 = F11", MouseAction.showDesktop.localVKs() == [0x7A])
        check("本机启动台没有键序列（走 App 动作）",
              MouseAction.launchpad.localVKs() == nil && MouseAction.launchpad.localAppAction == .launchpad)
        check("不映射时两侧都没有序列",
              MouseAction.off.localVKs() == nil && MouseAction.off.remoteVKs() == nil)

        // ③ 自定义组合键走同一套 VK 表示
        //    顺序规则：修饰键在前（Ctrl→Alt→Shift→Win），主键在最后 —— 与 `MWBChord.wireVKList` 一致
        check("自定义 cmd+shift+z → 本机序列",
              MouseAction.custom.localVKs(custom: "cmd+shift+z") == [0x10, 0x5B, 0x5A])
        check("自定义串写错时给 nil（不接管）",
              MouseAction.custom.localVKs(custom: "cmd+nosuch") == nil)
        check("自定义串写错时远端也给 nil",
              MouseAction.custom.remoteVKs(custom: "cmd+nosuch") == nil)

        // ④ 轴类动作必须没有键序列（否则会被当成"发一串键"而不是改轴）
        for a in [MouseAction.scrollVertical, .scrollHorizontal, .scrollZoom] {
            check("轴动作 \(a.rawValue) 无键序列",
                  a.localVKs() == nil && a.remoteVKs() == nil && a.axisOp != nil)
        }
        check("垂直滚动 → .vertical", MouseAction.scrollVertical.axisOp == .vertical)
        check("水平滚动 → .horizontal", MouseAction.scrollHorizontal.axisOp == .horizontal)
        check("滚动缩放 → .zoom", MouseAction.scrollZoom.axisOp == .zoom)

        // ⑤ 除 off / 轴类 / 本机 App 动作外，每个动作两侧都至少要能给出一半
        for a in MouseAction.allCases where a != .off && a.axisOp == nil {
            check("动作 \(a.rawValue) 至少有一侧可用",
                  a.localVKs(custom: "ctrl+c") != nil
                  || a.remoteVKs(custom: "ctrl+c") != nil
                  || a.localAppAction != nil)
        }

        // ⑥ spec 的 isActive：错字不该"接管"
        var s = MouseActionSpec()
        check("off 不接管", !s.isActive)
        s = MouseActionSpec(.custom, custom: "ctrl+c")
        check("自定义（正确）接管", s.isActive)
        s = MouseActionSpec(.custom, custom: "ctrl+nosuch")
        check("自定义（写错）不接管", !s.isActive)
        s = MouseActionSpec(.zoomIn)
        check("预置动作接管", s.isActive)

        // ⑦ 表：增 / 删 / 查 / 排序
        var store = MouseBindingStore()
        check("空表", store.isEmpty)
        _ = store.add(macButton: 4)
        _ = store.add(macButton: 3, note: "后退")
        check("添加后按按键号排序", store.bindings.map { $0.macButton } == [3, 4])
        check("重复添加同一个按键被拒", store.add(macButton: 3) == false)
        check("按号查得到", store.binding(for: 3)?.note == "后退")
        check("查不到的号返回 nil", store.binding(for: 9) == nil)
        if let id = store.binding(for: 4)?.id { store.remove(id: id) }
        check("删除生效", store.bindings.count == 1)

        // ⑧ JSON 往返（持久化的唯一路径，必须无损）
        var b = MouseButtonBinding(macButton: 5, note: "拇指键")
        b.macTap = MouseActionSpec(.custom, custom: "cmd+c")
        b.winTap = MouseActionSpec(.custom, custom: "ctrl+c")
        b.winScroll = MouseActionSpec(.zoomIn)
        b.macDrag = MouseActionSpec(.missionControl)
        store = MouseBindingStore()
        _ = store.add(macButton: 5, note: "拇指键")
        if var x = store.binding(for: 5) { x.macTap = b.macTap; x.winTap = b.winTap
            x.winScroll = b.winScroll; x.macDrag = b.macDrag; store.update(x) }
        let round = MouseBindingStore(json: store.json())
        check("JSON 往返：按键号", round.binding(for: 5)?.macButton == 5)
        check("JSON 往返：备注", round.binding(for: 5)?.note == "拇指键")
        check("JSON 往返：本机点按", round.binding(for: 5)?.macTap.custom == "cmd+c")
        check("JSON 往返：远端点按", round.binding(for: 5)?.winTap.custom == "ctrl+c")
        check("JSON 往返：远端按住滚动", round.binding(for: 5)?.winScroll.action == .zoomIn)
        check("JSON 往返：本机按住拖动", round.binding(for: 5)?.macDrag.action == .missionControl)

        // ⑨ 老数据缺字段不能整条炸掉（跨版本升级时的保命线）
        let legacy = #"[{"macButton":3}]"#
        let legacyStore = MouseBindingStore(json: legacy)
        check("老数据（只有 macButton）能解码", legacyStore.bindings.count == 1)
        check("老数据缺字段兜底为 off", legacyStore.binding(for: 3)?.winTap.action == .off)

        // ⑩ 坏 JSON 要退化成空表，不能崩
        check("坏 JSON → 空表", MouseBindingStore(json: "{{{").isEmpty)

        // ⑪ 旧设置迁移：只在空表时发生
        var m = MouseBindingStore()
        m.migrateFromLegacy(backChord: "ctrl+c", forwardChord: "ctrl+v")
        check("迁移出两条", m.bindings.count == 2)
        check("迁移到物理按键 4", m.binding(for: 3)?.winTap.custom == "ctrl+c")
        _ = m.add(macButton: 7)
        m.migrateFromLegacy(backChord: "ctrl+x", forwardChord: "")
        check("表非空时迁移不生效", m.bindings.count == 3)

        // ⑫ hasAnyAction：决定"要不要吞掉原按键"
        var hb = MouseButtonBinding(macButton: 6)
        check("全空 = 不吞", !hb.hasAnyAction(remote: true) && !hb.hasAnyAction(remote: false))
        hb.winScroll = MouseActionSpec(.scrollHorizontal)
        check("远端按住滚动有值 = 吞", hb.hasAnyAction(remote: true))
        check("本机无值 = 不吞", !hb.hasAnyAction(remote: false))

        return (pass, total, fails)
    }
}
