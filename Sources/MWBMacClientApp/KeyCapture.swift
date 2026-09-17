// KeyCapture.swift
// 界面层的「按键捕获」：点一下按钮，然后**直接按**要用的组合键，自动填进输入框。
//
// 【为什么不是"只能手打"】
// 手打组合键要求用户先学会 MWB 的写法（`cmd+shift+z`），错一个字母就静默失效。
// 捕获走的是真实键盘事件，用户按什么就是什么，永远不会写错。
//
// 【为什么用 `addLocalMonitorForEvents` 而不是全局监听】
// 局部监听只在**本 App 是当前活动 App**时收到事件（弹出面板就是这种情况），
// 好处是：捕获期间绝对不会影响别的 App，也不会把我们看不懂的按键吞掉。
// 代价是必须保证 App 真的活动 —— 所以 `begin` 里显式 `NSApp.activate`。
//
// 【为什么把事件吞掉（返回 nil）】
// 不吞的话：捕获 ⌘C 会顺手让面板里的文本框执行一次复制、或者"咚"一声提示音。
// 捕获期间这一次按键的语义就是"告诉我是什么键"，不该再有别的副作用。
//
// 【Esc 取消 + 12 秒超时】
// 万一把捕获状态忘了（面板被收起、App 失去活动状态），局部监听可能再也收不到键，
// 界面上就会一直显示「正在捕获…」。给一个超时兜底，避免用户以为程序卡死。

import SwiftUI
import AppKit
import MWBMacClientCore

/// 全局唯一的捕获引擎。
///
/// 【刻意不加 `@MainActor`】所有调用点本来就都在主线程（NSEvent 局部监听、SwiftUI 按钮、
/// 面板收起回调），标注 `@MainActor` 反而会让 `NSPopoverDelegate` 这类非隔离回调
/// 调不进来（Swift 5 语言模式下这就是硬错误），只会逼着调用方到处写
/// `DispatchQueue.main.async`，徒增复杂度。
final class KeyCaptureEngine: ObservableObject {
    static let shared = KeyCaptureEngine()

    /// 是否正在等用户按键。
    @Published private(set) var capturing = false
    /// 正在为哪个字段捕获（界面用来高亮对应的那个按钮）。
    @Published private(set) var target = ""
    /// 只按住修饰键时的实时预览（`⌘⇧`），证明键盘事件确实被我们收到了。
    @Published private(set) var preview = ""
    /// 一句给用户的话（"按 Esc 取消" / 拒绝原因）。
    @Published private(set) var hint = ""

    private var monitor: Any?
    private var timeout: Timer?
    private var handler: ((String) -> Void)?

    private init() {}

    /// 开始捕获。`target` 只是给界面看的标签，`handler` 收到最终组合键串。
    func begin(target: String, handler: @escaping (String) -> Void) {
        cancel()
        self.target = target
        self.handler = handler
        self.preview = ""
        self.hint = "请直接按组合键（例如 ⌘⇧Z）；只按 Esc 取消"
        capturing = true

        // 面板是 key window，但 App 不一定在前台 —— 局部监听要求 App 活动，
        // 不激活的话会出现"点了捕获却毫无反应"。
        NSApp.activate(ignoringOtherApps: true)

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] e in
            guard let self else { return e }
            return self.handle(e) ? nil : e      // true = 吞掉这次事件
        }

        // 超时兜底：12 秒还没按出个所以然就自动结束，不留下"卡在捕获中"的假象
        timeout?.invalidate()
        timeout = Timer.scheduledTimer(withTimeInterval: 12, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.capturing else { return }
                self.cancel()
                self.hint = "捕获超时（12 秒没等到按键）。面板被收起时 App 不再是活动状态，会收不到按键。"
            }
        }
    }

    /// 返回 true 表示这次事件已被处理（调用方应把它吞掉）。
    private func handle(_ e: NSEvent) -> Bool {
        guard capturing else { return false }
        let f = e.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if e.type == .flagsChanged {
            // 只是按住/松开修饰键：给个预览，继续等主键
            preview = KeyCaptureMap.modifierPreview(cmd: f.contains(.command),
                                                    ctrl: f.contains(.control),
                                                    alt: f.contains(.option),
                                                    shift: f.contains(.shift))
            return true
        }

        guard e.type == .keyDown, !e.isARepeat else { return true }

        // Esc 单独按 = 取消（⌘Esc 之类的组合仍当普通组合键处理）
        if e.keyCode == 53 && f.isEmpty {
            cancel(note: "已取消捕获")
            return true
        }

        guard let chord = KeyCaptureMap.chord(keyCode: e.keyCode,
                                             characters: e.charactersIgnoringModifiers,
                                             cmd: f.contains(.command),
                                             ctrl: f.contains(.control),
                                             alt: f.contains(.option),
                                             shift: f.contains(.shift)) else {
            // 两种拒绝：按了裸可打印键 / 键码不认识。都要说清楚，别让用户干等
            if KeyCaptureMap.modifierKeyCodes.contains(e.keyCode) {
                hint = "修饰键本身要配一个主键（例如 ⌘⇧Z）"
            } else {
                hint = "「\(e.charactersIgnoringModifiers ?? "?")」单独用会抢走正常打字 —— "
                     + "请按住 ⌘ / ⌃ / ⌥ / ⇧ 再按它，或改用 F11 这类功能键"
            }
            return true
        }

        let done = handler
        let shown = KeyCaptureMap.pretty(chord)
        cancel(note: "已捕获 \(shown)（\(chord)）")
        done?(chord)
        return true
    }

    /// 取消捕获。`note` 是留给用户的一句话（不传就把提示清空）。
    func cancel(note: String? = nil) {
        monitor.map { NSEvent.removeMonitor($0) }
        monitor = nil
        timeout?.invalidate()
        timeout = nil
        handler = nil
        capturing = false
        target = ""
        preview = ""
        hint = note ?? ""
    }
}

// MARK: - 按钮

/// 一个「捕获按键」小按钮。
///
/// 捕获中会变成红点在录制 + 显示实时按下的修饰键，让用户确认键盘被听到了。
struct ChordCaptureButton: View {
    @ObservedObject private var engine = KeyCaptureEngine.shared
    /// 给界面看的标签（与 `target` 比较，用于高亮"正在捕获的是这一个"）。
    let target: String
    /// 是否只用图标（默认 true，省地方）；`false` = 带文字。
    ///
    /// ⚠️ 属性声明顺序 = 合成 init 的参数顺序，而**闭包参数必须在最后**，
    /// 否则调用处 `ChordCaptureButton(target: x) { … }` 的尾随闭包匹配不上。
    var compact = true
    /// 捕获到的组合键串（如 `cmd+shift+z`）。
    let onCaptured: (String) -> Void

    private var active: Bool { engine.capturing && engine.target == target }

    var body: some View {
        Button {
            if engine.capturing { engine.cancel(note: "已取消捕获") }
            else { engine.begin(target: target, handler: onCaptured) }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: active ? "record.circle.fill" : "keyboard")
                    .font(.system(size: 10))
                    .foregroundStyle(active ? .red : .primary)
                if !compact {
                    Text(active ? (engine.preview.isEmpty ? "按键…" : engine.preview) : "捕获按键")
                        .font(.system(size: 10))
                } else if active && !engine.preview.isEmpty {
                    Text(engine.preview).font(.system(size: 10, design: .monospaced))
                }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.mini)
        .help("点一下，然后直接按你想用的组合键，会自动填进左边的输入框（Esc 取消）")
    }
}

/// 捕获结果的一行提示（放在按钮附近，让用户知道"键盘确实被收到了"）。
struct ChordCaptureHint: View {
    @ObservedObject private var engine = KeyCaptureEngine.shared

    var body: some View {
        if !engine.hint.isEmpty {
            Text(engine.hint)
                .font(.system(size: 9.5))
                .foregroundStyle(engine.capturing ? Color.orange : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
