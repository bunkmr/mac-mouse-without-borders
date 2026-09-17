// MouseMappingView.swift
// 高级设置里的「鼠标按键」区块。
//
// 【它解决什么】
//   ① 按键**可增删** —— 不再是写死的「后退 / 前进」两个下拉框；
//   ② 按键号**自动捕获** —— 用户点「自动捕获」后按一下鼠标，程序自己认出来是几号，
//      不必去猜、也不必数（macOS 内部 0 基、鼠标包装 1 基，差 1 很容易搞反）；
//   ③ 每个按键 3 种手势 × 2 个侧位 = 6 项独立设置：
//        · 点按        → 键序列（本机 / 远端各一份）
//        · 按住 + 滚动 → 功能（放大缩小、水平滚动、滚动缩放…）
//        · 按住 + 拖动 → 功能（旋转、滚动导航…）
//   ④ 滚轮方向反转（本机 → 远端 / 远端 → 本机各一个开关）。
//
// 【为什么「本机 / 远端」要分开设】侧键的用途天然分两种场景：
//   光标还在 Mac 上时希望它干本机的事（比如 ⌘C），推过去之后希望它干 Windows 的事
//   （Ctrl+C）。合成一栏就只能二选一，实际用起来必然别扭。

import SwiftUI
import MWBMacClientCore

// MARK: - 下拉选项的编解码

/// Picker 的 tag ↔ `MouseActionSpec` 互转。
///
/// tag 规则（用字符串是为了让 Picker 能一步选到"常用组合键"）：
///   `""`        不映射（原样转发）
///   `"@zoomIn"` 预置动作（`@` + `MouseAction.rawValue`）
///   `"ctrl+c"`  一个具体的组合键（落成 `.custom`，用户不必手打）
///   `"@custom"` 自定义（选中后旁边出现输入框）
enum MouseActionChoice {
    static let offTag = ""
    static let customTag = "@custom"

    /// 常用组合键：一步可选，省去手打。
    /// 这里**只放跨平台语义一致的**（Ctrl 系），不放 ⌘ 系 —— 用户按 ⌘ 记、
    /// 到了 Windows 却要按 Ctrl，手打一次反而更清楚。本机侧要 ⌘ 的话选"自定义"填 `cmd+c`。
    static let commonChords: [(tag: String, name: String)] = [
        ("ctrl+c", "复制 Ctrl+C"),
        ("ctrl+v", "粘贴 Ctrl+V"),
        ("ctrl+x", "剪切 Ctrl+X"),
        ("ctrl+z", "撤销 Ctrl+Z"),
        ("ctrl+y", "重做 Ctrl+Y"),
        ("ctrl+a", "全选 Ctrl+A"),
        ("ctrl+s", "保存 Ctrl+S"),
        ("ctrl+f", "查找 Ctrl+F"),
        ("ctrl+w", "关闭标签 Ctrl+W"),
        ("ctrl+t", "新建标签 Ctrl+T"),
        ("ctrl+tab", "下个标签 Ctrl+Tab"),
        ("alt+tab", "切换窗口 Alt+Tab"),
        ("ctrl+shift+esc", "任务管理器 Ctrl+Shift+Esc"),
    ]

    static func tag(for spec: MouseActionSpec) -> String {
        switch spec.action {
        case .off:
            return offTag
        case .custom:
            return spec.custom.isEmpty ? customTag : spec.custom
        default:
            return "@" + spec.action.rawValue
        }
    }

    static func spec(for tag: String) -> MouseActionSpec {
        if tag.isEmpty { return MouseActionSpec(.off) }
        if tag == customTag { return MouseActionSpec(.custom, custom: "") }
        if tag.hasPrefix("@") {
            let raw = String(tag.dropFirst())
            return MouseActionSpec(MouseAction(rawValue: raw) ?? .off)
        }
        return MouseActionSpec(.custom, custom: tag)
    }

    /// 某个 tag 在界面上的说明文案（只对预置动作有内容）。
    static func hint(for tag: String) -> String? {
        guard tag.hasPrefix("@") else { return nil }
        let raw = String(tag.dropFirst())
        return MouseAction(rawValue: raw)?.hint
    }
}

// MARK: - 区块

/// **CPU 定位用**：`MWB_MOUSE_SKIP=capture,hints,toggles,cards,summary` 里列出的部分不渲染。
///
/// 【背景】2026-09-17 用户报「展开高级设置 CPU 猛涨」：实测折叠 0.9%、展开 13~40%。
/// 逐块跳过定位到「鼠标按键」区块（跳过它 13% → 2.8%），但清空按键数据（无卡片）仍有 13%，
/// 说明贵的是这一块**固定内容**里某几种视图。这些开关把固定内容再切细。
/// 不设环境变量时全部正常渲染。
func mwbMouseSkipped(_ name: String) -> Bool {
    let raw = ProcessInfo.processInfo.environment["MWB_MOUSE_SKIP"] ?? ""
    return raw.split(separator: ",").contains { $0.trimmingCharacters(in: .whitespaces) == name }
}

struct MouseMappingSection: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if state.mouseBindings.isEmpty {
                Text("还没有配置任何按键。点下面的「自动捕获」再按一下鼠标上的键即可添加"
                     + "（左键 / 右键除外）。")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !mwbMouseSkipped("cards") {
                ForEach(Array(state.mouseBindings.enumerated()), id: \.element.id) { idx, b in
                    // `.equatable()`：见 MouseButtonCard 的说明（跳过无关刷新，否则 12 个
                    // 下拉菜单会被每秒重建、持续烧 CPU）。
                    MouseButtonCard(state: state, index: idx, binding: b).equatable()
                }
            }

            if !mwbMouseSkipped("capture") {
                HStack(spacing: 8) {
                    Button(state.capturingMouseButton ? "正在捕获…" : "自动捕获鼠标按键…") {
                        state.beginMouseButtonCapture()
                    }
                    .font(.caption)
                    .disabled(state.capturingMouseButton)
                    .help("点一下，然后按一下鼠标上要配置的那个键（不是键盘）")

                    if state.capturingMouseButton {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                }
            }

            if !state.mouseCaptureHint.isEmpty {
                Text(state.mouseCaptureHint)
                    .font(.caption2)
                    .foregroundStyle(state.mouseCaptureHint.hasPrefix("已添加") ? .green : .orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // 键盘侧的捕获提示（与鼠标捕获共用一个引擎的文案出口）
            ChordCaptureHint()

            if !mwbMouseSkipped("summary") {
                Text(state.mouseBindingsSummary)
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !mwbMouseSkipped("toggles") {
                Divider()
                Toggle("按键号 3/4 互换（后退键被识别成前进时勾选）",
                       isOn: $state.swapSideButtons)
                    .font(.caption)
                    // 编号口径那段有 5 行，正文放不下（面板可用高度只有 ~624pt），
                    // 而它只在"键号真的反了"时才会看 → 收进 tooltip。
                    .help(Self.numberingHint)

                Divider()
                Text("滚轮方向反转（Mac「自然滚动」与 Windows 正负相反，两个方向独立）")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                HStack(spacing: 14) {
                    Toggle("本机 → Windows", isOn: $state.scrollReverseToRemote).font(.caption)
                    Toggle("Windows → 本机", isOn: $state.scrollReverseFromRemote).font(.caption)
                    Spacer()
                }
            }
        }
    }

    /// 「编号口径」说明。
    /// 单独拎成静态属性是给 SwiftUI 的表达式瘦身 —— 这段拼接塞在 body 里
    /// 会让类型推断超时（实测 "unable to type-check in reasonable time"）。
    static let numberingHint: String = {
        var s = "编号口径：macOS 内部按 0 基计数（号 3 = 第 4 个键、号 4 = 第 5 个键），"
        s += "鼠标包装 / 驱动 / Windows 按 1 基叫「Button 4 / Button 5」。"
        s += "绝大多数鼠标的「后退」= 物理按键 4，也正是 macOS 号 3；"
        s += "少数鼠标（Razer 系、个别罗技/无牌）HID 描述符把两个附加键反过来报，"
        s += "勾上这里即可整体翻转，捕获与 Windows 注入双向同时生效。"
        s += "日志里每次按侧键都会打出「macOS 号 + 物理按键号」，可据此确认。"
        return s
    }()
}

// MARK: - 单个按键的卡片

private struct MouseButtonCard: View, Equatable {
    /// ★ 刻意**不是** `@ObservedObject`，并且类型实现 `Equatable`、调用处加 `.equatable()` ——
    ///   这三件事合起来是**性能关键**，不是写法偏好：
    ///
    ///   面板连着 Windows 时，每 1.5 秒有一次健康轮询会写 `AppState` 的多个 `@Published`
    ///   （鼠标/键盘事件数、机器矩阵、输入监控状态）。而 `MouseMappingSection` 观察整个
    ///   `AppState`，于是**每一次轮询都会让整块鼠标设置重算一遍**：2 张卡片 × 6 个下拉
    ///   菜单 = 12 个 `.menu` Picker（每个约 50 项、还带 4 个分组）被反复重建，
    ///   实测持续吃掉 13~20% CPU（用户反馈「一打开高级设置 CPU 猛涨」就是这么来的）。
    ///
    ///   把相等性收窄到「编号 + 这一份按键配置」之后，无关轮询会被 SwiftUI 直接跳过；
    ///   用户真的改了配置 → `binding` 变了 → 相等性不成立 → 照常重算，行为不变。
    let state: AppState
    let index: Int
    let binding: MouseButtonBinding

    static func == (l: Self, r: Self) -> Bool {
        l.index == r.index && l.binding == r.binding
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "computermouse").font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(binding.displayName).font(.caption).fontWeight(.medium)
                Spacer()
                Button {
                    state.removeMouseBinding(id: binding.id)
                } label: {
                    Image(systemName: "trash").font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .help("删除这个按键的配置")
            }

            gestureRow("点按", mac: \.macTap, win: \.winTap)
            gestureRow("按住滚动", mac: \.macScroll, win: \.winScroll)
            gestureRow("按住拖动", mac: \.macDrag, win: \.winDrag)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
    }

    // MARK: 一行手势 = 本机 + 远端

    private func gestureRow(_ title: String,
                            mac: WritableKeyPath<MouseButtonBinding, MouseActionSpec>,
                            win: WritableKeyPath<MouseButtonBinding, MouseActionSpec>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .leading)
                Text("本机").font(.system(size: 10))
                actionPicker(specBinding(mac))
                Text("远端").font(.system(size: 10))
                actionPicker(specBinding(win))
            }
            // 只在选了「自定义组合键…」时才出现的输入框（避免长期占地方）
            if currentSpec(mac).action == .custom {
                customField("本机 " + title, specBinding(mac))
            }
            if currentSpec(win).action == .custom {
                customField("远端 " + title, specBinding(win))
            }
        }
    }

    private func currentSpec(_ kp: WritableKeyPath<MouseButtonBinding, MouseActionSpec>) -> MouseActionSpec {
        guard state.mouseBindings.indices.contains(index) else { return MouseActionSpec() }
        return state.mouseBindings[index][keyPath: kp]
    }

    private func specBinding(_ kp: WritableKeyPath<MouseButtonBinding, MouseActionSpec>) -> Binding<MouseActionSpec> {
        Binding(
            get: {
                guard state.mouseBindings.indices.contains(index) else { return MouseActionSpec() }
                return state.mouseBindings[index][keyPath: kp]
            },
            set: { newValue in
                guard state.mouseBindings.indices.contains(index) else { return }
                state.mouseBindings[index][keyPath: kp] = newValue
            }
        )
    }

    private func actionPicker(_ spec: Binding<MouseActionSpec>) -> some View {
        Picker("", selection: tagBinding(spec)) {
            Text("不映射").tag(MouseActionChoice.offTag)

            ForEach(MouseActionGroup.allCases) { g in
                Section(g.displayName) {
                    ForEach(MouseAction.allCases.filter { $0.group == g && $0 != .off && $0 != .custom }) { a in
                        Text(a.displayName).tag("@" + a.rawValue)
                    }
                }
            }

            Section("常用组合键") {
                ForEach(MouseActionChoice.commonChords, id: \.tag) { c in
                    Text(c.name).tag(c.tag)
                }
            }

            Text("自定义组合键…").tag(MouseActionChoice.customTag)
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(maxWidth: 128)
        .help(MouseActionChoice.hint(for: MouseActionChoice.tag(for: spec.wrappedValue))
              ?? "该手势在本机 / 远端要执行的动作")
    }

    /// Picker 用 String tag，写回时转成 `MouseActionSpec`。
    private func tagBinding(_ spec: Binding<MouseActionSpec>) -> Binding<String> {
        Binding(
            get: { MouseActionChoice.tag(for: spec.wrappedValue) },
            set: { spec.wrappedValue = MouseActionChoice.spec(for: $0) }
        )
    }

    /// 「自定义组合键」的输入行 = 输入框 + **捕获按钮**。
    ///
    /// 【为什么要捕获按钮】手打要先学会 `cmd+shift+z` 这套写法，错一个字母就静默失效；
    /// 捕获走真实键盘事件，用户按什么就是什么。捕获到的串会直接写进输入框（仍是文本，
    /// 想手改也可以）。
    private func customField(_ label: String, _ spec: Binding<MouseActionSpec>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
                TextField("按右侧按钮捕获，或手打 ctrl+shift+z", text: Binding(
                    get: { spec.wrappedValue.custom },
                    set: { spec.wrappedValue.custom = $0 }
                ))
                .font(.system(size: 10, design: .monospaced))
                .textFieldStyle(.roundedBorder)

                ChordCaptureButton(target: "鼠标·" + label) { chord in
                    spec.wrappedValue = MouseActionSpec(.custom, custom: chord)
                }

                // 解析失败要**当场**告诉用户，否则他会以为"设了但没生效"
                Image(systemName: spec.wrappedValue.isActive ? "checkmark.circle.fill"
                                                             : "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(spec.wrappedValue.isActive ? .green : .orange)
                    .help(spec.wrappedValue.isActive
                          ? "将发送：\(KeyCaptureMap.pretty(spec.wrappedValue.custom))"
                          : "这套写法解析不出来，此时不会接管该手势（保留原行为）")
            }
            if spec.wrappedValue.isActive {
                Text("按下去会发送 \(KeyCaptureMap.pretty(spec.wrappedValue.custom))"
                     + "（线路串 `\(spec.wrappedValue.custom)`）")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 52)
    }
}
