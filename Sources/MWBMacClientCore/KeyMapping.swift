// KeyMapping.swift
// 跨屏快捷键映射：把 Mac 上的按键组合翻译成 Windows 上的按键组合。
//
// 【为什么需要】
// MWB 原生把 Mac 的 **Command** 映射成 **Windows 键**（VK_LWIN 0x5B）——
// 这是「Command ↔ Windows 键」的对等映射，符合 PowerToys 的原始设计。
// 但绝大多数人的肌肉记忆是「Cmd+C = 复制」，跨屏到 Windows 上就变成 Win+C
// （打开搜索/聊天侧栏），表现成「我在鼠标上设的 Cmd+C 跨屏过去没反应，还弹了个别的东西」。
//
// 所以这里提供三层、逐层更细的控制：
//   ① `CommandKeyMode` —— Command 键的语义：原生(Cmd↔Win) / Cmd→Ctrl(推荐) / Cmd→Alt
//   ② 鼠标按键 → 远端组合键（例：侧键「后退」= ctrl+c）—— 直接解决"鼠标快捷键跨屏失效"
//   ③ 自由映射表 —— 本机组合 = 远端组合（每行一条，例：cmd+shift+z = ctrl+y）
//
// 【方向约定】源组合按 **Mac 的物理修饰键** 写（cmd / ctrl / alt / shift），
// 目标组合按 **Windows 的按键** 写（ctrl / alt / shift / win / 具体键名）。
// 这样即便 ① 选了非原生模式，映射表也不会跟着漂。
//
// 【为什么不是「按 3 字符前缀分发」那套】这套映射发生在**捕获侧**（Mac 按键 → 线路包），
// 与剪贴板打包串无关，不共享任何协议细节。

import Foundation

// MARK: - Command 键语义

/// Mac 的 Command 键跨屏到 Windows 时翻译成什么。
public enum CommandKeyMode: String, CaseIterable, Identifiable {
    /// 原生 MWB 行为：Cmd ↔ Windows 键。
    case native
    /// 推荐：Cmd → Ctrl。于是 Cmd+C/V/A/S/Z 在 Windows 上就是复制/粘贴/全选/保存/撤销。
    case asControl
    /// Cmd → Alt（少数 App 把 Alt 当命令键；一般不用）。
    case asAlt

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .native:    return "原生（Cmd ↔ Windows 键）"
        case .asControl: return "Cmd → Ctrl（推荐）"
        case .asAlt:     return "Cmd → Alt"
        }
    }

    public var hint: String {
        switch self {
        case .native:
            return "对端收到 Windows 键。Cmd+C 在 Windows 上是 Win+C（打开搜索/聊天），不是复制。"
        case .asControl:
            return "按 Mac 习惯用：鼠标/键盘上的 Cmd+C 跨屏过去就是 Windows 的 Ctrl+C（复制）。"
        case .asAlt:
            return "对端收到 Alt。仅在目标 App 把 Alt 当命令键时才需要。"
        }
    }

    /// 捕获：本机 Command 按下/抬起时，代发的 Windows 虚拟键码。
    public var captureVK: Int32 {
        switch self {
        case .native:    return 0x5B   // VK_LWIN
        case .asControl: return 0x11   // VK_CONTROL
        case .asAlt:     return 0x12   // VK_MENU
        }
    }

    /// 注入：远端发来哪些虚拟键码时，本机改注入 Command（与捕获方向对称）。
    public var remoteVKs: Set<Int32> {
        switch self {
        case .native:    return []
        case .asControl: return [0x11, 0xA2, 0xA3]           // Ctrl / LCtrl / RCtrl
        case .asAlt:     return [0x12, 0xA4, 0xA5]           // Alt / LAlt / RAlt
        }
    }
}

// MARK: - 组合键

/// 一个组合键 = 修饰键集合 + 一个主键（Windows 虚拟键码）。
public struct MWBChord: Equatable, CustomStringConvertible {
    public var cmd = false
    public var ctrl = false
    public var alt = false
    public var shift = false
    /// Windows 虚拟键码（主键）。
    public var vk: Int32 = 0

    public init(cmd: Bool = false, ctrl: Bool = false, alt: Bool = false,
                shift: Bool = false, vk: Int32) {
        self.cmd = cmd; self.ctrl = ctrl; self.alt = alt; self.shift = shift; self.vk = vk
    }

    /// 修饰键的 Windows VK，按「先修饰后主键、释放时逆序」的常规顺序。
    public var modifierVKs: [Int32] {
        var out: [Int32] = []
        if ctrl { out.append(0x11) }
        if alt { out.append(0x12) }
        if shift { out.append(0x10) }
        if cmd { out.append(0x5B) }
        return out
    }

    /// 会真正发到线上的 VK 序列（按下顺序）：先修饰键、后主键。
    /// 日志里带上它，一眼就能看出「到底发了哪几个包、有没有漏修饰键」。
    public var wireVKList: [Int32] { modifierVKs + [vk] }

    /// 去掉修饰键，只比较主键与修饰集合是否与给定值一致。
    public func matches(cmd: Bool, ctrl: Bool, alt: Bool, shift: Bool, vk: Int32) -> Bool {
        self.vk == vk && self.cmd == cmd && self.ctrl == ctrl && self.alt == alt && self.shift == shift
    }

    public var description: String {
        var parts: [String] = []
        if cmd { parts.append("cmd") }
        if ctrl { parts.append("ctrl") }
        if alt { parts.append("alt") }
        if shift { parts.append("shift") }
        parts.append(MWBChord.name(for: vk))
        return parts.joined(separator: "+")
    }

    // MARK: 解析

    /// 键名 → Windows VK。字母/数字直接给，其余走这张表。
    public static let namedKeys: [String: Int32] = [
        "enter": 0x0D, "return": 0x0D, "tab": 0x09, "esc": 0x1B, "escape": 0x1B,
        "space": 0x20, "spacebar": 0x20, "backspace": 0x08, "delete": 0x2E, "del": 0x2E,
        "insert": 0x2D, "ins": 0x2D, "home": 0x24, "end": 0x23,
        "pageup": 0x21, "pgup": 0x21, "pagedown": 0x22, "pgdn": 0x22,
        "left": 0x25, "up": 0x26, "right": 0x27, "down": 0x28,
        "minus": 0xBD, "-": 0xBD, "equal": 0xBB, "plus": 0xBB, "=": 0xBB,
        "comma": 0xBC, ",": 0xBC, "period": 0xBE, ".": 0xBE,
        "slash": 0xBF, "/": 0xBF, "backslash": 0xDC, "\\": 0xDC,
        "semicolon": 0xBA, ";": 0xBA, "quote": 0xDE, "'": 0xDE,
        "bracketleft": 0xDB, "[": 0xDB, "bracketright": 0xDD, "]": 0xDD,
        "grave": 0xC0, "`": 0xC0, "capslock": 0x14, "printscreen": 0x2C,
        "f1": 0x70, "f2": 0x71, "f3": 0x72, "f4": 0x73, "f5": 0x74, "f6": 0x75,
        "f7": 0x76, "f8": 0x77, "f9": 0x78, "f10": 0x79, "f11": 0x7A, "f12": 0x7B,
        // F13–F24：Windows 侧是正常虚拟键码（0x7C..0x87），本机注入表没覆盖，
        // 但**解析必须认**（手写 `f13` 时不该被判成"写法错误"而静默失效）。
        "f13": 0x7C, "f14": 0x7D, "f15": 0x7E, "f16": 0x7F, "f17": 0x80, "f18": 0x81,
        "f19": 0x82, "f20": 0x83, "f21": 0x84, "f22": 0x85, "f23": 0x86, "f24": 0x87,
    ]

    /// VK → 键名（用于回显；缺失时给 `0xNN`）。
    public static func name(for vk: Int32) -> String {
        if let hit = namedKeys.first(where: { $0.value == vk }) { return hit.key }
        if vk >= 0x41, vk <= 0x5A { return String(UnicodeScalar(UInt8(vk))).lowercased() }
        if vk >= 0x30, vk <= 0x39 { return String(UnicodeScalar(UInt8(vk))) }
        return String(format: "0x%02x", vk)
    }

    /// 解析形如 `cmd+c` / `ctrl+shift+z` / `alt+f4` / `cmd+=` 的组合。
    ///
    /// 修饰键别名：cmd/command/win/super/meta、ctrl/control/ctl、alt/opt/option/menu、shift。
    /// 结尾的 `+` 视为 `=`（`cmd+=` 这种写法在分号切分里会丢掉主键）。
    public static func parse(_ raw: String) -> MWBChord? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty else { return nil }
        if s.hasSuffix("+") { s += "plus" }

        var chord = MWBChord(vk: 0)
        var sawKey = false
        for token in s.split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch token {
            case "cmd", "command", "win", "super", "meta": chord.cmd = true
            case "ctrl", "control", "ctl":                 chord.ctrl = true
            case "alt", "opt", "option", "menu":           chord.alt = true
            case "shift":                                  chord.shift = true
            case "":                                       return nil
            default:
                guard !sawKey else { return nil }          // 只允许一个主键
                guard let vk = keyVK(token) else { return nil }
                chord.vk = vk
                sawKey = true
            }
        }
        return sawKey ? chord : nil
    }

    private static func keyVK(_ token: String) -> Int32? {
        if let v = namedKeys[token] { return v }
        if token.count == 1, let c = token.uppercased().unicodeScalars.first,
           c.value >= 0x41, c.value <= 0x5A {
            return Int32(c.value)                        // a..z → 0x41..0x5A
        }
        if token.count == 1, let c = token.unicodeScalars.first, c.value >= 0x30, c.value <= 0x39 {
            return Int32(c.value)                        // 0..9 → 0x30..0x39
        }
        return nil
    }
}

// MARK: - 映射表

/// 自由映射表：每行 `本机组合 = 远端组合`。`#` 开头的行为注释，空行忽略。
public struct KeyMappingTable {
    public private(set) var rules: [(src: MWBChord, dst: MWBChord)] = []
    /// 解析失败的行（原样保留字符串，便于在界面上提示用户）。
    public private(set) var badLines: [String] = []

    public init() {}

    public init(spec: String) {
        load(spec)
    }

    public mutating func load(_ spec: String) {
        rules.removeAll()
        badLines.removeAll()
        for raw in spec.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }

            // 支持 `=` 与 `->` 两种分隔符（前者好打，后者不与 Ctrl+= 这类主键混淆）
            let halves: (String, String)
            if let r = line.range(of: "->") {
                halves = (String(line[line.startIndex..<r.lowerBound]), String(line[r.upperBound...]))
            } else if let i = line.firstIndex(of: "=") {
                halves = (String(line[line.startIndex..<i]), String(line[line.index(after: i)...]))
            } else {
                badLines.append(line); continue
            }

            guard let src = MWBChord.parse(halves.0), let dst = MWBChord.parse(halves.1) else {
                badLines.append(line)
                continue
            }
            rules.append((src, dst))
        }
    }

    public var isEmpty: Bool { rules.isEmpty }

    /// 找一条能从 `(修饰键, 主键)` 命中的规则。
    public func match(cmd: Bool, ctrl: Bool, alt: Bool, shift: Bool, vk: Int32) -> MWBChord? {
        for r in rules where r.src.matches(cmd: cmd, ctrl: ctrl, alt: alt, shift: shift, vk: vk) {
            return r.dst
        }
        return nil
    }

    /// 回显（界面上显示"已生效 N 条"）。
    public var summary: String {
        var s = "已生效 \(rules.count) 条"
        if !badLines.isEmpty { s += "；\(badLines.count) 条无法解析：\(badLines.prefix(2).joined(separator: " / "))" }
        return s
    }

    // MARK: 离线自检

    /// 解析器自检，供 `mwbmac --keymap-selftest` 使用。
    public static func selfTest() -> (Int, Int, [String]) {
        var pass = 0, total = 0
        var fails: [String] = []
        func check(_ name: String, _ ok: Bool) {
            total += 1
            if ok { pass += 1 } else { fails.append(name) }
        }

        // ① 基础解析
        let a = MWBChord.parse("cmd+c")
        check("cmd+c 解析出 cmd 修饰 + VK_C", a?.cmd == true && a?.vk == 0x43
              && a?.ctrl == false && a?.alt == false && a?.shift == false)
        let b = MWBChord.parse("CTRL + Shift + Z")   // 大小写与空格都要容忍
        check("ctrl+shift+z 容忍大小写/空格", b?.ctrl == true && b?.shift == true && b?.vk == 0x5A)
        let c = MWBChord.parse("alt+f4")
        check("alt+f4 → VK 0x73", c?.alt == true && c?.vk == 0x73)
        let d = MWBChord.parse("cmd+=")
        check("cmd+= （结尾加号）→ VK 0xBB", d?.cmd == true && d?.vk == 0xBB)
        check("win+e ≡ cmd+e", MWBChord.parse("win+e") == MWBChord.parse("cmd+e"))
        check("opt+1 ≡ alt+1", MWBChord.parse("opt+1") == MWBChord.parse("alt+1"))
        check("数字键 VK = ASCII", MWBChord.parse("ctrl+7")?.vk == 0x37)

        // ② 非法输入必须被拒（否则会把用户的错字悄悄变成"某个组合"）
        check("空串被拒", MWBChord.parse("") == nil)
        check("纯修饰键被拒", MWBChord.parse("cmd") == nil)
        check("两个主键被拒", MWBChord.parse("cmd+ab") == nil)
        check("未知键名被拒", MWBChord.parse("cmd+nosuchkey") == nil)

        // ③ 修饰键 VK 顺序：先修饰、后主键（Ctrl→Alt→Shift→Win 与注入约定一致）
        check("修饰键顺序", MWBChord.parse("cmd+alt+shift+ctrl+x")?.modifierVKs == [0x11, 0x12, 0x10, 0x5B])

        // ④ 映射表：多行 / 注释 / 坏行
        var t = KeyMappingTable()
        t.load("""
        # 注释行
        cmd+shift+z = ctrl+y
        cmd+d = ctrl+d

        cmd+nosuch = ctrl+o
        """)
        check("映射表载入 2 条规则", t.rules.count == 2)
        check("坏行被记录（不是静默丢弃）", t.badLines == ["cmd+nosuch = ctrl+o"])

        // ⑤ 命中判定：必须**整组**匹配，不能只看主键
        let hit = t.match(cmd: true, ctrl: false, alt: false, shift: true, vk: 0x5A)
        check("cmd+shift+z 命中 → ctrl+y", hit?.ctrl == true && hit?.vk == 0x59)
        check("cmd+z（少了 shift）不命中", t.match(cmd: true, ctrl: false, alt: false, shift: false, vk: 0x5A) == nil)
        check("shift+z 不命中", t.match(cmd: false, ctrl: false, alt: false, shift: true, vk: 0x5A) == nil)

        // ⑥ Command 键语义
        check("原生模式捕获 VK = Win 键", CommandKeyMode.native.captureVK == 0x5B)
        check("Cmd→Ctrl 捕获 VK = Ctrl", CommandKeyMode.asControl.captureVK == 0x11)
        check("Cmd→Ctrl 注入侧把远端 Ctrl 换回 Command", CommandKeyMode.asControl.remoteVKs.contains(0x11))
        check("原生模式不动远端的键", CommandKeyMode.native.remoteVKs.isEmpty)
        check("Cmd→Alt 与 Cmd→Ctrl 不重叠", CommandKeyMode.asAlt.remoteVKs.isDisjoint(with: CommandKeyMode.asControl.remoteVKs))

        return (pass, total, fails)
    }
}
