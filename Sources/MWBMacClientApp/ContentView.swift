// ContentView.swift
// 菜单栏弹出面板。
//
// 设计约束：Popover 的可视高度有限（13" 屏约 600pt），塞不下「全部设置 + 4 台机器矩阵 + 日志」。
// 所以这一版做了三件事：
//   1. 机器矩阵从 2 行大卡片压成 **单行 4 个小芯片**（高度从 ~120pt 降到 ~34pt）；
//   2. 日志**移出面板**，改为独立窗口（面板左下角一个入口按钮，⌘L 也能开）；
//   3. 低频使用的设置（本机名称 / 分辨率映射 / 槽位 / 开机自动连接 / 文件传输）
//      收进「高级设置」折叠区，默认收起。
// 外层再套 ScrollView + 高度上限，保证任何情况下所有内容都能滚到。

import SwiftUI
import AppKit
import MWBMacClientCore

struct ContentView: View {
    /// 用**显式注入**（@ObservedObject）而不是 @EnvironmentObject。
    ///
    /// 原因：@EnvironmentObject 依赖 SwiftUI 的环境传递，在做**离屏快照**
    /// （NSHostingView / ImageRenderer）时实测拿不到对象，抛
    /// `Fatal error: No ObservableObject of type AppState found`。
    /// 改成显式注入后，面板既能正常显示，也能被离屏渲染做版式自检，
    /// 而且依赖关系一眼可见（调用方必须把 state 传进来）。
    @ObservedObject var state: AppState
    @State private var showAdvanced = false

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) { panelBody }
            .frame(width: 372)
            .frame(maxHeight: 560)
            .disabled(state.connecting)
    }

    /// 面板实体内容。**刻意与外面的滚动容器分开**：
    /// ImageRenderer 渲染 ScrollView 只会得到一片空白，拆开后才能做「版式自检」离屏快照。
    var panelBody: some View {
        VStack(alignment: .leading, spacing: 8) {
                header
                Divider()

                SectionTitle("Windows 主机")
                row("IP 地址") { TextField("192.168.1.100", text: $state.host).textFieldStyle(.roundedBorder) }
                row("端口 / 密钥") {
                    HStack(spacing: 6) {
                        TextField("15101", text: $state.portText)
                            .frame(width: 60).textFieldStyle(.roundedBorder)
                        SecureField("配对码", text: $state.securityKey).textFieldStyle(.roundedBorder)
                    }
                }

                Divider()
                SectionTitle("屏幕方位（Windows 屏幕在本机的哪一侧）")
                Picker("", selection: $state.edge) {
                    Text("左").tag(SwitchEdge.left)
                    Text("右").tag(SwitchEdge.right)
                    Text("上").tag(SwitchEdge.top)
                    Text("下").tag(SwitchEdge.bottom)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                // 长说明收进 tooltip（悬停才看），避免占掉面板高度 ——
                // 这一条说明有 3 行，是「显示不全」的主要元凶之一。
                Toggle("控制 Windows 时隐藏并锁定本机光标", isOn: $state.lockCursorWhileRemote)
                    .help("开启后鼠标跨到 Windows 时，Mac 上的光标会【隐藏】并把位置钉在屏幕边缘，"
                          + "回到本机时自动恢复显示。"
                          + "隐藏靠 CGDisplayHideCursor（实测有效），退出/断开/紧急热键都会恢复，"
                          + "不会留下一个看不见的光标。")

                HStack(spacing: 8) {
                    Button {
                        state.runCursorLockSelfTest()
                    } label: {
                        Label("锁定自检", systemImage: "scope").font(.caption)
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(state.connected)
                    .help("不需要连接 Windows：点一下，然后在这 6 秒里晃动鼠标，Mac 光标若停住不动即说明锁定生效。")

                    Button {
                        state.runSwitchSelfTest()
                    } label: {
                        Label("跨屏自检", systemImage: "arrow.left.arrow.right").font(.caption)
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(state.connected)
                    .help("不需要连接 Windows：用合成事件跑一遍「滑出到对端 → 浅进一段 → 推回本机」，"
                          + "验证鼠标回得来、且交回本机后不会被立刻弹回去。")
                    Spacer()
                }

                Divider()
                matrixSection

                Divider()
                advancedSection

                Divider()
                statusSection

                HStack(spacing: 8) {
                    Button {
                        NSApp.sendAction(#selector(AppDelegate.showLogWindow(_:)), to: nil, from: nil)
                    } label: {
                        Label("查看日志", systemImage: "doc.text.magnifyingglass").font(.caption)
                    }
                    .buttonStyle(.bordered).controlSize(.small)

                    Spacer()
                    Text("⌘Q 退出").font(.caption2).foregroundStyle(.secondary)
                }
        }
        .padding(12)
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(state.connected ? .green : (state.connecting ? .orange : .red))
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text("Mouse Without Borders").font(.headline)
                Text(state.controllingRemote ? "⟶ 正在控制 Windows" : state.statusText)
                    .font(.caption)
                    .foregroundStyle(state.controllingRemote ? .blue : .secondary)
                    .lineLimit(1).truncationMode(.tail)
            }
            Spacer()
            Button(state.connected ? "断开" : "连接") {
                state.connected ? state.disconnect() : state.connect()
            }
            .buttonStyle(.borderedProminent)
            .tint(state.connected ? .red : .accentColor)
            .disabled(state.connecting)

            Button { state.quit() } label: {
                Image(systemName: "power").font(.caption)
            }
            .buttonStyle(.bordered)
            .help("退出 MWB（也会恢复鼠标光标）")
        }
    }

    // MARK: - 机器矩阵（单行 4 芯片）

    private var matrixSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                SectionTitle("机器矩阵（最多 4 台）")
                Spacer()
                if let m = state.matrix, m.receivedMatrix {
                    Text(m.twoRow ? "2×2" : "1×4")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                    if m.wrap {
                        Text("环绕").font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }
            }

            HStack(spacing: 5) {
                ForEach(0..<4, id: \.self) { i in
                    slotChip(state.matrix?.slots[safe: i], selfSlot: state.matrix?.selfSlot, id: i + 1)
                }
            }

            // 没连上时不显示提示行 —— 少一行就少 ~14pt，SectionTitle 已经说明了用途。
            if let m = state.matrix {
                Text(matrixHintShort)
                    .font(.system(size: 9.5)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
            }
        }
    }

    private func slotChip(_ s: MachineSlot?, selfSlot: Int?, id: Int) -> some View {
        let isSelf = (selfSlot == id)
        let occupied = s?.occupied ?? false
        let online = s?.online ?? false
        let dot: Color = isSelf ? .blue : (online ? .green : (occupied ? .orange : Color.secondary.opacity(0.3)))
        let name = s?.name ?? ""
        return VStack(spacing: 2) {
            HStack(spacing: 3) {
                Circle().fill(dot).frame(width: 6, height: 6)
                Text("\(id)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            Text(occupied ? name : "—")
                .font(.system(size: 10))
                .lineLimit(1).truncationMode(.middle)
                .foregroundStyle(occupied ? Color.primary : Color.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 5).padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 5).fill(dot.opacity(0.09)))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(dot.opacity(isSelf ? 0.65 : 0.28)))
        .help(tooltip(s, id: id, isSelf: isSelf, online: online, occupied: occupied, name: name))
    }

    private func tooltip(_ s: MachineSlot?, id: Int, isSelf: Bool, online: Bool,
                         occupied: Bool, name: String) -> String {
        var t = "槽位 \(id)：\(occupied ? name : "空")"
        if isSelf { t += "（本机）" } else if online { t += "（在线）" }
        else if occupied { t += "（离线）" }
        return t
    }

    private var matrixHintShort: String {
        guard let m = state.matrix else { return "连接后显示 4 台机器的布局与联机状态" }
        if !m.receivedMatrix { return "在线 \(m.onlineCount) 台 · 还没收到 Windows 下发的布局包" }
        return "在线 \(m.onlineCount) 台 · 本机槽位 \(m.selfSlot.map(String.init) ?? "?")"
    }

    // MARK: - 高级设置（折叠）

    private var advancedSection: some View {
        DisclosureGroup(isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 8) {
                row("本机名称") {
                    TextField("MacBook-Pro-2", text: $state.machineName).textFieldStyle(.roundedBorder)
                }

                HStack(spacing: 6) {
                    Text("远端分辨率").font(.caption).foregroundStyle(.secondary).frame(width: 84, alignment: .leading)
                    TextField("1920", text: $state.remoteW).frame(width: 56).textFieldStyle(.roundedBorder)
                    Text("×").foregroundStyle(.secondary)
                    TextField("1080", text: $state.remoteH).frame(width: 56).textFieldStyle(.roundedBorder)
                    Spacer()
                }
                .disabled(state.proportionalMapping)
                .opacity(state.proportionalMapping ? 0.4 : 1)

                Toggle("按本机屏幕比例映射（推荐）", isOn: $state.proportionalMapping)
                    .font(.caption)
                Text(state.proportionalMapping
                     ? "协议原生做法：跨过本机整个屏幕宽 = 跨过 Windows 整个屏幕宽，与对端分辨率无关。"
                     : "按对端像素 1:1：填错会让 Windows 光标明显偏快/偏慢。")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                row("本机槽位") {
                    Picker("", selection: $state.slotText) {
                        Text("自动").tag("auto")
                        Text("1").tag("1")
                        Text("2").tag("2")
                        Text("3").tag("3")
                        Text("4").tag("4")
                    }
                    .labelsHidden().pickerStyle(.segmented)
                }

                Toggle("启动后自动连接", isOn: $state.autoConnect).font(.caption)

                Divider()
                SectionTitle("文件传输")
                Toggle("拖文件到屏幕边缘即发送", isOn: $state.dropDockEnabled).font(.caption)
                Toggle("Finder 复制文件(Cmd+C)自动同步", isOn: $state.clipboardFileEnabled).font(.caption)
                row("端口") {
                    TextField("自动", text: $state.filePortText)
                        .frame(width: 76).textFieldStyle(.roundedBorder)
                }
                Text("留空 = MWB 原生剪贴板通道（主通道端口-1，即 15100）。Windows 端用 MWB 自带拖放实现接收，无需额外程序。")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !state.fileActivity.isEmpty {
                    Text(state.fileActivity).font(.caption2).foregroundStyle(.blue)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 6)
        } label: {
            SectionTitle("高级设置")
        }
    }

    // MARK: - 状态 / 权限

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            if state.captureOK && state.axTrusted && state.inputMonitoringOK {
                // 一切正常时压成一行，把垂直空间留给别的内容
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 10)).foregroundStyle(.green)
                    Text("键鼠捕获已就绪")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("鼠标 \(state.tapEvents) · 键盘 \(state.keyEvents)")
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Button { state.retryCapture() } label: {
                        Image(systemName: "arrow.clockwise").font(.caption)
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                    .help("重建事件捕获")
                    .disabled(!state.connected)
                }
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.shield.fill")
                        .foregroundStyle(.orange)
                    Text("事件捕获未建立，键鼠无法跨屏")
                        .font(.caption).fontWeight(.medium)
                    Spacer()
                    Button { state.retryCapture() } label: {
                        Image(systemName: "arrow.clockwise").font(.caption)
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(!state.connected)
                }

                HStack(spacing: 12) {
                    permissionChip("辅助功能（鼠标）", ok: state.axTrusted)
                    permissionChip("输入监控（键盘）", ok: state.inputMonitoringOK)
                    Spacer()
                    Text("鼠标 \(state.tapEvents) · 键盘 \(state.keyEvents)")
                        .font(.caption2).foregroundStyle(.secondary)
                }

                // 说明文字压到各一行 —— 之前四行提示把面板顶出了 560pt 上限。
                if !state.inputMonitoringOK {
                    Text("「输入监控」未授权：键盘事件会被系统静默丢弃（鼠标不受影响）。")
                        .font(.caption2).foregroundStyle(.orange)
                        .lineLimit(1).truncationMode(.tail)
                } else if state.keyEvents == 0 {
                    Text("输入监控已授权但没收到键盘事件：敲一下键盘看数字是否增长。")
                        .font(.caption2).foregroundStyle(.orange)
                        .lineLimit(1).truncationMode(.tail)
                }

                HStack(spacing: 6) {
                    Button("授权辅助功能") { state.openAccessibilitySettings() }
                        .font(.caption2).buttonStyle(.bordered)
                    Button("授权输入监控") { state.openInputMonitoringSettings() }
                        .font(.caption2).buttonStyle(.bordered)
                    Spacer()
                }
                // 用 tooltip 承载「退出重开」提示，避免挤在按钮行里被截断。
                .help("点按钮会弹出系统授权框并把 MWB 自动加进列表；"
                      + "勾选后请**完全退出 MWB 再重开**（「输入监控」对已运行进程不即时生效）。")
            }
        }
    }

    private func permissionChip(_ title: String, ok: Bool) -> some View {
        HStack(spacing: 3) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 9))
                .foregroundStyle(ok ? .green : .orange)
            Text(title).font(.system(size: 10))
                .foregroundStyle(ok ? .secondary : .primary)
        }
    }

    private func row(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.secondary).frame(width: 84, alignment: .leading)
            content()
        }
    }
}

private struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.caption).fontWeight(.semibold).foregroundStyle(.primary)
    }
}

/// 供「版式自检」离屏快照用：渲染**面板全部内容**（高度不限）。
///
/// 用途：拿到「内容总高度」，与 Popover 上限 560pt 对比即可判断是否会显示不全。
/// 因为 ContentView 已改成显式注入 state，这里直接透传即可，不再需要环境对象，
/// 也就绕开了 `NSHostingView`/`ImageRenderer` 拿不到 `@EnvironmentObject` 的问题。
struct PanelSnapshot: View {
    @ObservedObject var state: AppState
    var body: some View {
        ContentView(state: state).panelBody
    }
}

/// 供「版式自检」离屏快照用：渲染**真实 Popover 外层**（ScrollView + 372×≤560）。
/// 用途：还原用户实际看到的那个下拉窗口。
struct PopoverSnapshot: View {
    @ObservedObject var state: AppState
    var body: some View {
        ContentView(state: state)
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
