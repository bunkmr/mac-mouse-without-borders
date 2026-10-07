// Localization.swift
// 界面语言：跟随系统 / 简体中文 / English。
//
// 【为什么不用 Localizable.strings + .lproj】
//   本工程是 SwiftPM 可执行文件，再由 build_app.sh 组装成 .app。SwiftUI 的
//   `Text("字面量")` 走 `Bundle.main` 查 .lproj 资源 —— 而 SwiftPM 的资源包是
//   独立 .bundle，不在 Bundle.main 里，需要额外把 .lproj 拷进 app bundle、还要处理
//   `defaultLocalization`，链路长且容易"看着配好了其实没生效"。
//   更关键的是：面板里大量文案走的是**自定义 helper**（SectionTitle / row / helpQA…），
//   它们收的是 `String`，`Text` 的自动本地化根本覆盖不到。
//   ⇒ 用一个显式的 `L()` 表，键就是中文原文，行为完全可控、可自检。
//
// 【约定】
//   · 源码里所有面向用户的文案仍**以中文书写**（便于阅读与维护），外面套 `L(...)`。
//   · 中文模式下 `L()` 原样返回，零开销。
//   · 英文模式下查 `en` 表；查不到就**回退中文**（不会出现空白）。
//   · 带插值的句子用 `LF("在线 %d 台", n)`，键里写 `%d`/`%@`。

import Foundation

// MARK: - 语言

public enum AppLanguage: String, CaseIterable, Identifiable {
    case system, zh, en

    public var id: String { rawValue }

    /// 下拉里显示的名字。`.system` 跟着当前语言走，另外两个用各自的本名。
    public var displayName: String {
        switch self {
        case .system: return L("跟随系统")
        case .zh:     return "简体中文"
        case .en:     return "English"
        }
    }

    /// 把「跟随系统」解析成真正的语言。
    public var resolved: AppLanguage {
        guard self == .system else { return self }
        return AppLanguage.systemResolved
    }

    /// 系统首选语言里第一个 `zh*` 就当简体中文，其余一律英文。
    /// （不区分简繁：本项目的翻译表只有一份中文。）
    public static var systemResolved: AppLanguage {
        let first = Locale.preferredLanguages.first?.lowercased() ?? "en"
        return first.hasPrefix("zh") ? .zh : .en
    }
}

/// 全局当前语言。`AppState.appLanguage` 一变就写这里，随后面板重算即可刷新全部文案。
public enum Lang {
    public static var current: AppLanguage = .system
    public static var isEnglish: Bool { current.resolved == .en }
}

/// 取本地化文案。键 = 中文原文。
public func L(_ zh: String) -> String {
    guard Lang.isEnglish else { return zh }
    return Self_enTable[zh] ?? zh
}

/// 带插值的本地化。键里用 `%d` / `%@`（与 `String(format:)` 一致）。
public func LF(_ zh: String, _ args: CVarArg...) -> String {
    guard Lang.isEnglish else { return String(format: zh, arguments: args) }
    let fmt = Self_enTable[zh] ?? zh
    return String(format: fmt, arguments: args)
}

// MARK: - 翻译表

/// 键 = 中文原文（与源码里的字面量**逐字相同**，包括空格与标点）。
///
/// ⚠️ 改中文文案时**必须同步改这里**，否则那一句会静默退回中文。
/// `--lang-selftest` 会核对"表里的键都能被 L() 命中"，但**查不出"源码有、表里没有"**
/// —— 那个只能靠 grep 中文文案 + 人工过一遍。
let Self_enTable: [String: String] = [
    // ---- 页签 / 顶栏 / 底栏 ----
    "基础设置": "Basics",
    "文件传输": "File Transfer",
    "键盘映射": "Key Mapping",
    "日志和帮助": "Logs & Help",
    "⟶ 正在控制 Windows": "⟶ Controlling Windows",
    "断开": "Disconnect",
    "连接": "Connect",
    "退出 MWB（也会恢复鼠标光标）": "Quit MWB (restores the mouse cursor)",
    "%@（共 %d 页）": "%@ (tab %d of %d)",
    "查看日志": "View Log",
    "⌘Q 退出": "⌘Q to quit",

    // ---- 基础设置 · 主机 ----
    "Windows 主机": "Windows Host",
    "IP 地址": "IP address",
    "端口 / 密钥": "Port / Key",
    "配对码": "Pairing key",

    // ---- 屏幕布局（合并后的单一控件）----
    "屏幕布局": "Screen Layout",
    "拖动本机方块到别的格子即可换槽位；方块之间的相对位置决定鼠标从哪条边滑出去。":
        "Drag your own tile to another cell to change its slot; the relative position of the tiles decides which edge the cursor exits from.",
    "本机": "This Mac",
    "空": "empty",
    "在线 %d 台": "%d online",
    "在线 %d 台 · 本机槽位 %@": "%d online · this Mac is slot %@",
    "在线 %d 台 · 还没收到 Windows 下发的布局": "%d online · no layout pushed by Windows yet",
    "连接后显示 4 台机器的布局与联机状态": "Shows the 4-machine layout and online state once connected",
    "槽位 %d：%@": "Slot %d: %@",
    "槽位 %d：%@（本机）": "Slot %d: %@ (this Mac)",
    "槽位 %d：%@（在线）": "Slot %d: %@ (online)",
    "槽位 %d：%@（离线）": "Slot %d: %@ (offline)",
    "本机槽位": "This Mac's slot",
    "自动": "Auto",
    // ⚠️ 刻意**不收录** "2×2" / "1×4"：中英同形，收了就是"译文==原文"的无效条目，
    //    自检会判失败。查不到时回退中文，结果字符串完全一样。
    "环绕": "wrap",
    "跨越边缘": "Switch edge",
    "鼠标从本机这一侧边缘滑出，Windows 就在那个方向。":
        "The cursor leaves this Mac on that side — Windows is there.",
    "左": "Left",
    "右": "Right",
    "上": "Top",
    "下": "Bottom",
    "布局由 Windows 下发的机器矩阵推导；手动改动会覆盖推导结果。":
        "Derived from the machine matrix Windows pushes; changing it here overrides the derivation.",
    "槽位自动（由 Windows 学习）": "Slot: Auto (learned from Windows)",
    "Windows 在「%@」侧": "Windows is on the “%@” side",
    "Windows 位于对角，按「%@」推测": "Windows sits diagonally — assuming “%@”",
    "语言切换即时生效。日志内容始终为中文（排查用）。":
        "Language changes apply immediately. Log output stays in Chinese (for troubleshooting).",

    // ---- 光标 / 待机 ----
    "控制 Windows 时隐藏并锁定本机光标": "Hide and lock the local cursor while controlling Windows",
    "锁定自检": "Lock test",
    "跨屏自检": "Cross-screen test",
    "待机唤醒（屏幕熄灭后仍可被 Windows 键鼠唤醒）":
        "Wake on standby (Windows input can still wake this Mac with the screen off)",
    "屏幕熄灭后仍可被 Windows 鼠标唤醒": "Let Windows input wake this Mac after the screen turns off",
    "仅在插电时生效（电池时照常深度睡眠）":
        "Only when plugged in (still deep-sleeps on battery)",
    "唤醒自检": "Wake test",
    "已关闭": "Off",
    " · 已唤醒 %d 次": " · woken %d×",
    // StandbyGuard（Core 层）产出的状态原文
    "生效中": "Active",
    "生效中（仅插电）": "Active (plugged in only)",
    "待连接": "Waiting for connection",
    "待命（电池供电，暂不阻止睡眠）": "Standby (on battery, sleep not blocked)",
    "未生效": "Inactive",

    // ---- 本机 ----
    "本机名称": "Machine name",
    "远端分辨率": "Remote resolution",
    "按本机屏幕比例映射（推荐）": "Map by this Mac's screen ratio (recommended)",
    "协议原生做法：跨过本机整个屏幕宽 = 跨过 Windows 整个屏幕宽，与对端分辨率无关。":
        "Native protocol behaviour: crossing this Mac's full width equals crossing Windows' full width, regardless of resolution.",
    "按对端像素 1:1：填错会让 Windows 光标明显偏快/偏慢。":
        "1:1 pixel mapping: a wrong value makes the Windows cursor noticeably too fast or too slow.",
    "启动后自动连接": "Connect automatically at launch",

    // ---- 语言 ----
    "语言": "Language",
    "界面语言": "Interface language",
    "跟随系统": "Follow System",

    // ---- 连接状态 ----
    "连接状态": "Connection",
    "键鼠捕获已就绪": "Input capture ready",
    "鼠标 %@ · 键盘 %@": "Mouse %@ · Keyboard %@",
    "重建事件捕获": "Rebuild input capture",
    "事件捕获未建立，键鼠无法跨屏": "Input capture unavailable — cross-screen input is disabled",
    "辅助功能（鼠标）": "Accessibility (mouse)",
    "输入监控（键盘）": "Input Monitoring (keyboard)",
    "「输入监控」未授权：键盘事件会被系统静默丢弃（鼠标不受影响）。":
        "Input Monitoring not granted: keyboard events are silently dropped (mouse is unaffected).",
    "输入监控已授权但没收到键盘事件：敲一下键盘看数字是否增长。":
        "Input Monitoring granted but no keyboard events: type a key and see whether the counter increases.",
    "授权辅助功能": "Grant Accessibility",
    "授权输入监控": "Grant Input Monitoring",

    // ---- 文件传输页 ----
    //（"文件传输" 已在页签区收录，此处不重复 —— **字典字面量的重复键会在运行时 trap**）
    "拖文件到屏幕边缘即发送": "Send a file by dragging it to the screen edge",
    "Finder 复制文件(Cmd+C)自动同步": "Auto-sync files copied in Finder (⌘C)",
    "端口": "Port",
    "留空 = MWB 原生剪贴板通道（主通道端口-1，即 15100）。Windows 端用 MWB 自带拖放实现接收，无需额外程序。":
        "Empty = the native MWB clipboard channel (main port − 1, i.e. 15100). Windows receives with its built-in drag-and-drop; no extra program needed.",
    "剪贴板": "Clipboard",
    "同步图片剪贴板": "Sync image clipboard",
    "文本一直同步。图片按 MWB 原生做法传 PNG；超过 1MB 自动改走「发心跳 → 对端回连拉取」，不必额外设置。":
        "Text always syncs. Images are sent as PNG per the native MWB protocol; above 1 MB they switch to “beat → peer dials back to pull”. No setup needed.",
    "注：>1MB 的图要在「把控制权交回 Windows」的那一刻才会推送，稍等 1~2 秒。":
        "Note: images >1 MB are pushed the moment control is handed back to Windows — wait 1–2 s.",
    "通道": "Channels",
    "控制通道": "Control",
    "文件 / 图片": "File / Image",
    "接收位置": "Received files",
    "TCP 15101 —— 键鼠事件 + 文本剪贴板，变化即推。":
        "TCP 15101 — keyboard/mouse events + text clipboard, pushed on change.",
    "TCP 15100 —— 独立于控制通道，互不阻塞。":
        "TCP 15100 — independent of the control channel, non-blocking.",
    "图片剪贴板内容直接写进本机剪贴板；其它文件落在「桌面/MouseWithoutBorders/」。":
        "Clipboard images go straight into this Mac's clipboard; other files land in Desktop/MouseWithoutBorders/.",

    // ---- 键盘映射页 ----
    "Command 键": "Command key",
    "鼠标按键": "Mouse buttons",
    "每个按键可分别设置「点按 / 按住滚动 / 按住拖动」在本机与远端的动作，按键可随时增删。":
        "Each button can map click / hold-scroll / hold-drag actions on this Mac and remotely; buttons can be added or removed anytime.",
    "自定义按键映射（每行 `本机 = 远端`）": "Custom key mapping (one `local = remote` per line)",
    "已捕获：%@ = %@ —— 两边都按完会自动写成一行":
        "Captured: %@ = %@ — a line is written once both sides are pressed",
    "例：`cmd+shift+z = ctrl+y`、`cmd+d = ctrl+d`。也可以点上面两个「捕获按键」：先按本机要用的组合，再按远端要映射到的组合。`#` 开头是注释。":
        "e.g. `cmd+shift+z = ctrl+y`, `cmd+d = ctrl+d`. You can also click the two “capture” buttons: press the local chord first, then the remote one. Lines starting with `#` are comments.",

    // ---- 帮助页 ----
    "日志": "Log",
    "打开日志窗口": "Open log window",
    "日志文件 `/tmp/mwb_gui.log`（上一次 `/tmp/mwb_gui.prev.log`）。终端里 `tail -f /tmp/mwb_gui.log` 可实时观察。":
        "Log file `/tmp/mwb_gui.log` (previous run: `/tmp/mwb_gui.prev.log`). Watch it live with `tail -f /tmp/mwb_gui.log`.",
    "需要逐包级细节时，用 `MWB_VERBOSE=1` 启动，会打印每个鼠标/键盘包的数值。":
        "For per-packet detail, launch with `MWB_VERBOSE=1` to print every mouse/keyboard packet.",
    "快速上手": "Quick start",
    "本页签左侧「基础设置」里填 Windows 的 IP 与配对码 → 点「连接」。":
        "In the Basics tab, fill in Windows' IP and pairing key → click Connect.",
    "鼠标推到屏幕边缘即跨到 Windows（方位在基础设置里选）。":
        "Push the mouse to the screen edge to cross to Windows (direction is set in the layout board).",
    "文本、图片、文件剪贴板自动双向同步，无需额外操作。":
        "Text, image and file clipboard sync both ways automatically.",
    "侧键 / 滚轮 / 组合键在「键盘映射」页签里逐项设置。":
        "Side buttons, wheel and chords are configured in the Key Mapping tab.",
    "遇到问题": "Troubleshooting",
    "键盘在 Windows 上没反应": "Keyboard does nothing on Windows",
    "系统设置 → 隐私与安全性 → 输入监控，勾上 MWB 后「完全退出再重开」（该权限对已运行进程不即时生效）。授权入口在「基础设置」页签底部。":
        "System Settings → Privacy & Security → Input Monitoring, tick MWB, then fully quit and relaunch (the permission does not apply to a running process). The entry point is at the bottom of the Basics tab.",
    "鼠标只能推到屏幕 2/3 处": "Mouse stops at 2/3 of the screen",
    "本机接了 Sidecar（随航）副屏时坐标基准会变；断开随航再试。":
        "With a Sidecar display attached the coordinate origin changes; disconnect Sidecar and retry.",
    "大图片剪贴板传不过去": "Large image clipboard does not transfer",
    "超过 1MB 的图要在把控制权交回 Windows 的那一刻才推送，稍等 1~2 秒。":
        "Images over 1 MB are pushed when control is handed back to Windows — wait 1–2 s.",
    "面板里的设置改了没生效": "A setting in the panel had no effect",
    "除「立刻生效」的开关外，改完请断开再连一次，让对端重新握手。":
        "Except for switches that apply instantly, disconnect and reconnect so the peer re-handshakes.",

    // ---- 鼠标映射区块 ----
    "还没有配置任何按键。点下面的「自动捕获」再按一下鼠标上的键即可添加（左键 / 右键除外）。":
        "No buttons configured yet. Click “Auto-capture” below and press a mouse button to add one (left/right excluded).",
    "正在捕获…": "Capturing…",
    "自动捕获鼠标按键…": "Auto-capture a mouse button…",
    "点一下，然后按一下鼠标上要配置的那个键（不是键盘）":
        "Click, then press the mouse button you want to configure (not the keyboard)",
    "按键号 3/4 互换（后退键被识别成前进时勾选）":
        "Swap button numbers 3/4 (tick if Back is detected as Forward)",
    "滚轮方向反转（Mac「自然滚动」与 Windows 正负相反，两个方向独立）":
        "Reverse wheel direction (macOS natural scrolling is opposite to Windows; each direction is independent)",
    "本机 → Windows": "This Mac → Windows",
    "Windows → 本机": "Windows → This Mac",
    "点按": "Click",
    "按住滚动": "Hold + scroll",
    "按住拖动": "Hold + drag",
    "远端": "Remote",
    "删除这个按键的配置": "Delete this button's mapping",
    "不映射": "No mapping",
    "常用组合键": "Common chords",
    "自定义组合键…": "Custom chord…",
    "该手势在本机 / 远端要执行的动作": "Action for this gesture locally / remotely",
    "按右侧按钮捕获，或手打 ctrl+shift+z": "Capture with the button, or type e.g. ctrl+shift+z",
    "将发送：%@": "Will send: %@",
    "这套写法解析不出来，此时不会接管该手势（保留原行为）":
        "This chord cannot be parsed; the gesture will not be intercepted (original behaviour kept)",
    "按下去会发送 %@（线路串 `%@`）": "Pressing it sends %@ (wire form `%@`)",
    "复制 Ctrl+C": "Copy Ctrl+C",
    "粘贴 Ctrl+V": "Paste Ctrl+V",
    "剪切 Ctrl+X": "Cut Ctrl+X",
    "撤销 Ctrl+Z": "Undo Ctrl+Z",
    "重做 Ctrl+Y": "Redo Ctrl+Y",
    "全选 Ctrl+A": "Select All Ctrl+A",
    "保存 Ctrl+S": "Save Ctrl+S",
    "查找 Ctrl+F": "Find Ctrl+F",
    "关闭标签 Ctrl+W": "Close Tab Ctrl+W",
    "新建标签 Ctrl+T": "New Tab Ctrl+T",
    "下个标签 Ctrl+Tab": "Next Tab Ctrl+Tab",
    "切换窗口 Alt+Tab": "Switch Window Alt+Tab",
    "任务管理器 Ctrl+Shift+Esc": "Task Manager Ctrl+Shift+Esc",

    // ---- 日志窗口 ----
    "MWB 运行日志": "MWB Log",
    "（%d 行）": "(%d lines)",
    "自动滚动": "Auto-scroll",
    "复制全部": "Copy All",
    "在 Finder 中显示": "Reveal in Finder",
    "清空": "Clear",
    "日志文件：/tmp/mwb_gui.log —— 也可在终端里 `tail -f /tmp/mwb_gui.log` 实时观察。":
        "Log file: /tmp/mwb_gui.log — or watch it live with `tail -f /tmp/mwb_gui.log`.",

    // ---- 菜单 ----
    "关于 MWB": "About MWB",
    "退出 MWB": "Quit MWB",
    "视图": "View",
    "断开连接": "Disconnect",
    "连接到 Windows": "Connect to Windows",
    "查看日志…": "View Log…",
    "光标锁定自检（6 秒）": "Cursor lock test (6 s)",

    // ---- AppState 状态文案 ----
    "未连接": "Not connected",
    "连接中…": "Connecting…",
    "已断开": "Disconnected",
    "已重新连接": "Reconnected",
    "请先填写 Windows 主机 IP 与安全密钥": "Enter the Windows host IP and security key first",
    "连接成功": "Connected",
    "连接失败: %@": "Connection failed: %@",
    "已连接 %@": "Connected to %@",
]

// MARK: - 自检

public enum LocalizationSelfTest {
    /// 断言：① 表不为空 ② 每条的值非空 ③ 没有"值 == 键"的无效条目
    /// ④ 抽查若干关键键在英文下确实变了 ⑤ 中文模式下原样返回。
    public static func run() -> Bool {
        var fails: [String] = []
        if Self_enTable.isEmpty { fails.append("翻译表为空") }
        for (k, v) in Self_enTable {
            if k.isEmpty { fails.append("存在空键") }
            if v.isEmpty { fails.append("键「\(k)」的译文为空") }
            if v == k { fails.append("键「\(k)」译文与原文相同（无效条目）") }
        }
        // 抽查
        let saved = Lang.current
        defer { Lang.current = saved }
        Lang.current = .en
        for probe in ["基础设置", "屏幕布局", "查看日志", "断开"] {
            if L(probe) == probe { fails.append("英文模式下「\(probe)」没有翻译") }
        }
        let f = LF("在线 %d 台", 3)
        if !f.contains("3") { fails.append("带插值的文案没有替换：\(f)") }
        Lang.current = .zh
        if L("基础设置") != "基础设置" { fails.append("中文模式下不该改文案") }
        if LF("在线 %d 台", 3) != "在线 3 台" { fails.append("中文模式插值不对：\(LF("在线 %d 台", 3))") }

        print("  \(fails.isEmpty ? "✓" : "✗") 翻译表 \(Self_enTable.count) 条" +
              (fails.isEmpty ? "：非空、无自映射、中英切换与插值均正确"
                             : "：\n    " + fails.prefix(8).joined(separator: "\n    ")))
        return fails.isEmpty
    }
}
