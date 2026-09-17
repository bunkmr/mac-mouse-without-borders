// KeyCaptureMap.swift
// 「按一下键」→ 「可被 MWBChord 解析的组合键串」的纯函数映射。
//
// 【为什么需要它】
// 高级设置里的自定义快捷键过去只能**手打**（`cmd+shift+z`）。手打有三个必然的坑：
//   ① 用户得先知道 MWB 这套写法（cmd/ctrl/alt/shift + 键名），不然写 `Command+Z` 直接被判非法；
//   ② 错一个字（`cmd+shfit+z`）就静默不生效，界面上只有一个黄色小三角；
//   ③ 特殊键（F11、方向键、`,`、`=`）用文字表达很别扭，很容易写错。
// 现在改成「点一下 → 直接按组合键 → 自动填进去」，把这三个坑一次性消掉。
//
// 【为什么放在 Core 而不是 App】
// 这里**不碰 AppKit**（键码用裸数字），所以 CLI 能在没有窗口的环境下把整张表断言一遍
// （`mwbmac --keycap-selftest`）。键盘映射表属于"数据"，改一处很容易把另一处带坏，
// 而它在真机上表现为「按了没反应」，排查成本极高 —— 必须离线可断言。
//
// 【键码口径】用的是 macOS 的 `NSEvent.keyCode`（= Carbon `kVK_*`，USB HID usage 的
// 上一代编号），**不是** MWB 协议里的 Windows 虚拟键码。输出的字符串才是 VK 语义
// （交给 `MWBChord.parse` 转 VK）。

import Foundation

public enum KeyCaptureMap {

    /// 修饰键 / 切态键的键码 —— 它们**本身不能**当组合键的主键。
    ///
    /// CapsLock(57) 刻意不在这个集合里：它虽然也是"切态"，但用户可以真的想用它做热键
    /// （MWBChord 里有 `capslock` 这个名字），所以放行。
    public static let modifierKeyCodes: Set<UInt16> = [
        55, 56, 58, 59,   // 左 ⌘ ⇧ ⌥ ⌃
        60, 61, 62,       // 右 ⇧ ⌥ ⌃
        63,               // Fn / Globe（地球键）
    ]

    /// 特殊键（键名 > 1 字符）→ MWBChord 认识的键名。
    /// 这些键**允许不带修饰键**直接捕获（单独一个 F11 也是合法组合）。
    ///
    /// ★ 只收录 **F1–F12**，不收录 F13–F20：本机注入表（`InputController.keyMap`）
    /// 覆盖的是 F1–F12，F13+ 在本机侧发得出去、但注入时会静默落空。
    /// 与其给用户一个"按了没反应"的键，不如别让他选到（手写 `f13` 仍然可用）。
    public static let specialKeys: [UInt16: String] = [
        36: "enter", 48: "tab", 49: "space", 51: "backspace", 53: "esc",
        57: "capslock", 114: "insert", 117: "delete",
        115: "home", 119: "end", 116: "pageup", 121: "pagedown",
        123: "left", 124: "right", 125: "down", 126: "up",
        122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6",
        98: "f7", 100: "f8", 101: "f9", 109: "f10", 103: "f11", 111: "f12",
    ]

    /// 可打印键（US ANSI 物理位置）→ 键名字符。
    ///
    /// ★ 刻意按**物理位置**而不是 `charactersIgnoringModifiers` 取字符：
    ///   ① 按住 ⌥ 时 macOS 会把 `characters` 变成特殊符号（⌥A = `å`），按字符取必然抓错；
    ///   ② 快捷键的语义本来就是"物理位置"，换输入法 / 大小写都不该影响它。
    ///
    /// ★ 也刻意**不收小键盘**（`*` `+` `/` 与数字键盘）：MWBChord 的键名表里没有
    ///   `*` 这种写法，收进来就会产出解析不了的串 → 用户看到"设了但不生效"。
    ///   小键盘在快捷键场景里本来也没人用。
    public static let ansiKeys: [UInt16: String] = [
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v",
        11: "b", 12: "q", 13: "w", 14: "e", 15: "r", 16: "y", 17: "t",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
        24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
        30: "]", 31: "o", 32: "u", 33: "[", 34: "i", 35: "p",
        37: "l", 38: "j", 39: "'", 40: "k", 41: ";", 42: "\\",
        43: ",", 44: "/", 45: "n", 46: "m", 47: ".", 50: "`",
    ]

    /// 一次按键 → 组合键串。返回 `nil` = 「这一下不算数，继续等」。
    ///
    /// 返回 nil 的三种情况：
    ///   · 按的是修饰键本身（⌘/⇧/⌥/⌃/Fn）—— 它由 `flagsChanged` 走预览，不走主键；
    ///   · 键码不认识（极少见的外设 / 多媒体键）；
    ///   · **没有任何修饰键**时的可打印键（单独一个 `c` 当热键几乎一定是误触，
    ///     而且会抢走正常打字；不如拒绝并把理由显示给用户）。
    public static func chord(keyCode: UInt16,
                             characters: String? = nil,
                             cmd: Bool = false, ctrl: Bool = false,
                             alt: Bool = false, shift: Bool = false) -> String? {
        if modifierKeyCodes.contains(keyCode) { return nil }

        let special = specialKeys[keyCode]
        let name = special ?? ansiKeys[keyCode] ?? fallbackName(characters)

        guard let key = name, !key.isEmpty else { return nil }

        let hasModifier = cmd || ctrl || alt || shift
        // 特殊键允许裸按；可打印键必须带至少一个修饰键
        if !hasModifier && special == nil { return nil }

        var parts: [String] = []
        if cmd   { parts.append("cmd") }
        if ctrl  { parts.append("ctrl") }
        if alt   { parts.append("alt") }
        if shift { parts.append("shift") }
        parts.append(key)
        return parts.joined(separator: "+")
    }

    /// 键码表没命中时的兜底：拿系统给的字符（只留可打印的单字符）。
    private static func fallbackName(_ characters: String?) -> String? {
        guard let s = characters?.trimmingCharacters(in: .whitespacesAndNewlines),
              s.count == 1, let c = s.first,
              c.isLetter || c.isNumber || "`-=[]\\;',./".contains(c) else { return nil }
        return String(c).lowercased()
    }

    /// 「只按了修饰键」时的实时预览（界面上显示 `⌘⇧`，让用户知道键盘被听到了）。
    public static func modifierPreview(cmd: Bool = false, ctrl: Bool = false,
                                       alt: Bool = false, shift: Bool = false) -> String {
        var s = ""
        if ctrl  { s += "⌃" }
        if alt   { s += "⌥" }
        if shift { s += "⇧" }
        if cmd   { s += "⌘" }
        return s
    }

    /// 把存下来的串显示成 Mac 习惯的样子（`cmd+shift+z` → `⌘⇧Z`）。
    /// 仅用于回显，落盘的永远是 `cmd+shift+z` 这种可解析形式。
    public static func pretty(_ chord: String) -> String {
        guard let c = MWBChord.parse(chord) else { return chord }
        return modifierPreview(cmd: c.cmd, ctrl: c.ctrl, alt: c.alt, shift: c.shift)
             + MWBChord.name(for: c.vk).uppercased()
    }

    // MARK: - 离线自检

    /// 供 `mwbmac --keycap-selftest` 使用。
    public static func selfTest() -> (Int, Int, [String]) {
        var pass = 0, total = 0
        var fails: [String] = []
        func check(_ name: String, _ ok: Bool) {
            total += 1
            if ok { pass += 1 } else { fails.append(name) }
        }

        // ① 基本捕获：⌘C / ⌃⇧Z / ⌥F4
        check("⌘C → cmd+c", chord(keyCode: 8, cmd: true) == "cmd+c")
        check("⌃⇧Z → ctrl+shift+z", chord(keyCode: 6, ctrl: true, shift: true) == "ctrl+shift+z")
        check("⌥F4 → alt+f4", chord(keyCode: 118, alt: true) == "alt+f4")
        check("四修饰全上", chord(keyCode: 0, cmd: true, ctrl: true, alt: true, shift: true)
              == "cmd+ctrl+alt+shift+a")
        check("⌃⇧ 按固定顺序输出（ctrl 在 shift 前）",
              chord(keyCode: 0, ctrl: true, shift: true) == "ctrl+shift+a")

        // ② 标点：必须产出 MWBChord 认识的写法（`=` 结尾加号那套坑在 parse 里已处理）
        check("⌘= → cmd+=", chord(keyCode: 24, cmd: true) == "cmd+=")
        check("⌘, → cmd+,", chord(keyCode: 43, cmd: true) == "cmd+,")
        check("⌘/ → cmd+/", chord(keyCode: 44, cmd: true) == "cmd+/")
        check("⌘\\ → cmd+\\", chord(keyCode: 42, cmd: true) == "cmd+\\")
        check("⌘` → cmd+`", chord(keyCode: 50, cmd: true) == "cmd+`")

        // ③ 特殊键：允许裸按，键名要在 MWBChord 的白名单里
        check("裸 F11 → f11", chord(keyCode: 103) == "f11")
        check("裸 ←  → left", chord(keyCode: 123) == "left")
        check("裸 Enter → enter", chord(keyCode: 36) == "enter")
        check("裸 Tab → tab", chord(keyCode: 48) == "tab")
        check("裸 空格 → space", chord(keyCode: 49) == "space")
        check("裸 CapsLock → capslock", chord(keyCode: 57) == "capslock")
        check("⌃↑ → ctrl+up", chord(keyCode: 126, ctrl: true) == "ctrl+up")

        // ④ 必须拒绝的：修饰键本身、裸可打印键、不认识的键码
        check("⌘键本身不算主键", chord(keyCode: 55) == nil)
        check("右⇧键本身不算主键", chord(keyCode: 60) == nil)
        check("Fn/地球键不算主键", chord(keyCode: 63) == nil)
        check("裸 c 被拒（会抢走正常打字）", chord(keyCode: 8) == nil)
        check("裸 1 被拒", chord(keyCode: 18) == nil)
        check("未知键码且无字符 → nil", chord(keyCode: 250) == nil)

        // ⑤ 兜底：键码不认识时用系统字符（只收可打印单字符）
        check("兜底：键码未知但给了字符", chord(keyCode: 250, characters: "k", cmd: true) == "cmd+k")
        check("兜底：多字符不行", chord(keyCode: 250, characters: "ab", cmd: true) == nil)
        check("兜底：裸字符也要修饰键", chord(keyCode: 250, characters: "k") == nil)

        // ⑥ ★ 最要紧的性质：**所有**产出的串都必须能被 MWBChord 解析
        //    （产一个解析不了的串 = 用户看到黄三角 + 设置静默失效）
        var unparsable: [String] = []
        for (code, _) in specialKeys {
            if let s = chord(keyCode: code), MWBChord.parse(s) == nil { unparsable.append(s) }
        }
        for (code, _) in ansiKeys {
            if let s = chord(keyCode: code, cmd: true), MWBChord.parse(s) == nil { unparsable.append(s) }
        }
        check("特殊键产出的串全部可解析（\(specialKeys.count) 个键）", unparsable.isEmpty)
        if !unparsable.isEmpty { fails.append("不可解析：\(unparsable.prefix(4).joined(separator: "/"))") }

        check("产出的 ⌘= 能解析成 VK 0xBB", MWBChord.parse(chord(keyCode: 24, cmd: true) ?? "")?.vk == 0xBB)
        check("产出的 ⌃↑ 能解析成 VK 0x26", MWBChord.parse(chord(keyCode: 126, ctrl: true) ?? "")?.vk == 0x26)
        check("手写 f13 也能解析（Windows 侧可用）", MWBChord.parse("f13")?.vk == 0x7C)
        // 捕获取值必须只给"两侧都真能用"的键：F13+ 本机注入表没覆盖，不该出现在可选项里
        check("捕获表只收 F1–F12（不含 F13+）", specialKeys.count == 28
              && !specialKeys.values.contains("f13"))

        // ⑦ 预览与美化
        check("预览 ⌘⇧", modifierPreview(cmd: true, shift: true) == "⇧⌘")
        check("美化 cmd+shift+z → ⌘⇧Z", pretty("cmd+shift+z") == "⇧⌘Z")
        check("美化失败时原样返回", pretty("cmd+nosuch") == "cmd+nosuch")

        // ⑧ 键码表自检：QQ 键码 0 与 11 都在（曾经有版本漏了 b）
        check("ansi 表覆盖 0..50 的字母数字", ansiKeys[0] == "a" && ansiKeys[11] == "b"
              && ansiKeys[29] == "0" && ansiKeys[46] == "m")
        check("修饰键集合与 ansi/special 不重叠",
              Set(modifierKeyCodes).isDisjoint(with: Set(specialKeys.keys))
              && Set(modifierKeyCodes).isDisjoint(with: Set(ansiKeys.keys)))

        return (pass, total, fails)
    }
}
