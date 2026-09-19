// ContentView.swift
// 菜单栏弹出面板（**页签版**）。
//
// 版式（自上而下，只有中间那块会滚动）：
//   ┌─ header   连接状态 + 断开 / 退出      ← 固定在最上面，切页签不动
//   ├─ tabBar   基础设置 | 文件传输 | 键盘映射 | 日志和帮助
//   ├─ ScrollView（当前页签的内容）
//   └─ footer   查看日志 / ⌘Q
//
// 【为什么从「折叠区」改成「页签」】面板高度被系统限死在 ~748pt
// （主屏可见高度 776 − 28，见 `panelHeight`），而设置项只增不减。
// 原先把低频项塞进「高级设置」折叠区，等于「想找的东西要展开两层才看得到」，
// 展开后又塞不下、得在小窗里来回滚。
// 页签把这个矛盾解开了：**页签栏常驻**，切换只花一次点击，每页只装一组相关选项。
//
// 附带好处（性能）：非当前页签的视图**根本不在视图树里** ——
// 例如「键盘映射」页签那 2 张卡片 × 6 个 `.menu` 下拉菜单（每个约 50 项），
// 只要不在这一页就不会被无关的状态刷新拖着重算。
// 2026-09-17 那次「打开面板 CPU 猛涨到 40%」的根因正是「轮询 → 全面板重算 → 下拉菜单重建」，
// 页签从结构上把这条路径切断了。相关修复（`MouseButtonCard.equatable()`、
// 日志合并发布）也仍然保留，两道保险。

import SwiftUI
import AppKit
import MWBMacClientCore

/// 面板页签：按「用户脑子里的同一件事」分组。
///
/// rawValue 用英文是为了能直接写进环境变量（`MWB_RENDER_TAB=keys`）做离屏版式自检，
/// 中文标题另由 `title` 给出。
enum PanelTab: String, CaseIterable, Identifiable {
    case basics, transfer, keys, help

    var id: String { rawValue }

    var title: String {
        switch self {
        case .basics:   return "基础设置"
        case .transfer: return "文件传输"
        case .keys:     return "键盘映射"
        case .help:     return "日志和帮助"
        }
    }
}

struct ContentView: View {
    /// 用**显式注入**（@ObservedObject）而不是 @EnvironmentObject。
    ///
    /// 原因：@EnvironmentObject 依赖 SwiftUI 的环境传递，在做**离屏快照**
    /// （NSHostingView / ImageRenderer）时实测拿不到对象，抛
    /// `Fatal error: No ObservableObject of type AppState found`。
    /// 改成显式注入后，面板既能正常显示，也能被离屏渲染做版式自检，
    /// 而且依赖关系一眼可见（调用方必须把 state 传进来）。
    @ObservedObject var state: AppState

    /// 展开类区块（自定义映射）默认是否展开。
    ///
    /// 平时**收起**。只要在做离屏渲染（`MWB_RENDER_PANEL=`）就默认展开 ——
    /// 快照必须能一眼看全里面长什么样，否则拍出来的永远只有封面。
    /// 需要对照组时用 `MWB_RENDER_ADVANCED=0` 强制收起。
    private static var expandByDefault: Bool {
        let env = ProcessInfo.processInfo.environment
        if env["MWB_RENDER_ADVANCED"] == "0" { return false }
        return env["MWB_RENDER_ADVANCED"] != nil || env["MWB_RENDER_PANEL"] != nil
    }

    /// 初始页签。`MWB_RENDER_TAB=transfer|keys|help` 可让离屏快照直接拍某一页。
    private static var initialTab: PanelTab {
        PanelTab(rawValue: ProcessInfo.processInfo.environment["MWB_RENDER_TAB"] ?? "") ?? .basics
    }

    @State private var activeTab = ContentView.initialTab
    /// 「自定义映射」区块是否展开（离屏自检时要能看到捕获按键）。
    @State private var showKeyMapping = ContentView.expandByDefault

    // MARK: - 「捕获两下写一行」的临时状态

    /// 捕获按钮的标签（也是"正在捕获的是哪一个"的判据，两个务必不同）。
    private static let captureSourceTarget = "映射表·本机组合"
    private static let captureDestTarget   = "映射表·远端组合"

    /// 已捕获、但还没凑成一对的本机组合。
    @State private var pendingSrc = ""
    /// 已捕获、但还没凑成一对的远端组合。
    @State private var pendingDst = ""

    /// 两侧都捕获到 → 拼成一行写进映射表，并清空待填状态。
    ///
    /// 为什么不给"添加"按钮：多一次点击、多一个可能忘按的按钮。
    /// 按完第二个键就落行，用户马上能在下面的"已生效 N 条"里看到结果。
    private func commitCapturePair() {
        guard !pendingSrc.isEmpty, !pendingDst.isEmpty else { return }
        var s = state.keyMappingSpec
        if !s.isEmpty, !s.hasSuffix("\n") { s += "\n" }
        s += "\(pendingSrc) = \(pendingDst)\n"
        state.keyMappingSpec = s
        pendingSrc = ""
        pendingDst = ""
    }

    // MARK: - 面板高度

    /// 弹出面板的高度（pt）。
    ///
    /// 【为什么是动态算的】过去写死 `maxHeight: 560`，而内容只有 478pt ——
    /// 一进「高级设置」就得在小窗口里来回滚，用户反馈"弹出的面板太短"。
    /// 现在撑到「屏幕放得下的最大高度」：理论上限取原值的两倍（1120pt），
    /// 屏幕装不下时取屏幕允许的最大值（`visibleFrame` 已扣掉菜单栏与程序坞）。
    ///
    /// ⚠️ 不要用 `NSScreen.main` 判断"哪块屏有菜单栏"——它的语义是
    /// 「当前接收键盘事件的窗口所在屏」（无 key window 时会跟着鼠标跑）。
    /// 菜单栏永远在 `NSScreen.screens[0]`（主显示器）上，所以取它。
    static var panelHeight: CGFloat {
        let visible = (NSScreen.screens.first ?? NSScreen.main)?.visibleFrame.height ?? 900
        // -28pt：给状态项下方的箭头与窗口阴影留余量，否则会被系统挤回上面去
        return max(560, min(1120, visible - 28))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            tabBar
            Divider()
            ScrollView(.vertical, showsIndicators: true) { tabBody }
                // 连接过程中只锁内容，**页签仍可切**（否则用户以为界面卡死了）
                .disabled(state.connecting)
            Divider()
            footer
        }
        .frame(width: 372, height: Self.panelHeight)
    }

    // MARK: - 顶部固定条（切页签不动）

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
        .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8)
    }

    // MARK: - 页签栏

    private var tabBar: some View {
        HStack(spacing: 3) {
            ForEach(PanelTab.allCases) { t in tabButton(t) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    /// 单个页签按钮。
    ///
    /// 刻意不用 `Picker(.segmented)`：4 个中文页签在 372pt 宽的面板里会挤到自动截断，
    /// 而自定义按钮能把字号压到 11.5pt 并把高亮做成"底色卡片"，宽度完全可控。
    private func tabButton(_ t: PanelTab) -> some View {
        let on = (activeTab == t)
        return Button {
            activeTab = t
        } label: {
            Text(t.title)
                .font(.system(size: 11.5, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? Color.accentColor : Color.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(on ? Color.accentColor.opacity(0.13) : Color.clear)
        )
        .help("\(t.title)（共 \(PanelTab.allCases.count) 页）")
    }

    /// 底部固定条。
    ///
    /// 刻意**不放进 ScrollView**：面板被撑高之后，若它跟着内容滚，"查看日志"这类入口
    /// 就会时有时无地跑位；固定住更符合"这是面板的底栏"的直觉。
    private var footer: some View {
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
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    // MARK: - 当前页签的内容

    /// 面板当前页签的实体内容。**刻意与外面的滚动容器分开**：
    /// ImageRenderer 渲染 ScrollView 只会得到一片空白，拆开后才能做「版式自检」离屏快照。
    @ViewBuilder
    var tabBody: some View {
        switch activeTab {
        case .basics:   basicsTab
        case .transfer: transferTab
        case .keys:     keysTab
        case .help:     helpTab
        }
    }

    // MARK: - ① 基础设置

    private var basicsTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("Windows 主机")
            row("IP 地址") {
                TextField("192.168.1.100", text: $state.host).textFieldStyle(.roundedBorder)
            }
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

            if !mwbAdvSkipped("base") {
                Divider()
                SectionTitle("本机")
                localMachineSection
            }

            Divider()
            SectionTitle("连接状态")
            statusSection
        }
        .padding(12)
    }

    /// 本机身份与坐标映射（原「高级设置」的第一段）。
    @ViewBuilder
    private var localMachineSection: some View {
        row("本机名称") {
            TextField("MacBook-Pro", text: $state.machineName).textFieldStyle(.roundedBorder)
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
    }

    // MARK: - ② 文件传输

    private var transferTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("文件传输")
            Toggle("拖文件到屏幕边缘即发送", isOn: $state.dropDockEnabled).font(.caption)
            Toggle("Finder 复制文件(Cmd+C)自动同步", isOn: $state.clipboardFileEnabled).font(.caption)
            row("端口") {
                TextField("自动", text: $state.filePortText)
                    .frame(width: 76).textFieldStyle(.roundedBorder)
            }
            Text("留空 = MWB 原生剪贴板通道（主通道端口-1，即 15100）。"
                 + "Windows 端用 MWB 自带拖放实现接收，无需额外程序。")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !state.fileActivity.isEmpty {
                Text(state.fileActivity).font(.caption2).foregroundStyle(.blue)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            SectionTitle("剪贴板")
            Toggle("同步图片剪贴板", isOn: $state.clipboardImageEnabled).font(.caption)
            Text("文本一直同步。图片按 MWB 原生做法传 PNG；超过 1MB 自动改走"
                 + "「发心跳 → 对端回连拉取」，不必额外设置。")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("注：>1MB 的图要在「把控制权交回 Windows」的那一刻才会推送，稍等 1~2 秒。")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()
            SectionTitle("通道")
            channelRow("控制通道", "TCP 15101 —— 键鼠事件 + 文本剪贴板，变化即推。")
            channelRow("文件 / 图片", "TCP 15100 —— 独立于控制通道，互不阻塞。")
            channelRow("接收位置", "由 Windows 端 MWB 决定；实测落在对端「桌面」。")
        }
        .padding(12)
    }

    private func channelRow(_ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.secondary)
                .frame(width: 84, alignment: .leading)
            Text(detail).font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - ③ 键盘映射

    private var keysTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !mwbAdvSkipped("cmd") {
                SectionTitle("Command 键")
                row("Command 键") {
                    Picker("", selection: $state.commandKeyMode) {
                        ForEach(CommandKeyMode.allCases) { m in
                            Text(m.displayName).tag(m)
                        }
                    }
                    .labelsHidden().pickerStyle(.menu).frame(maxWidth: 200)
                }
                Text(state.commandKeyMode.hint)
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !mwbAdvSkipped("mouse") {
                Divider()
                SectionTitle("鼠标按键")
                Text("每个按键可分别设置「点按 / 按住滚动 / 按住拖动」在本机与远端的动作，按键可随时增删。")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                MouseMappingSection(state: state)
            }

            if !mwbAdvSkipped("editor") {
                Divider()
                customMappingSection
            }
        }
        .padding(12)
    }

    /// 文本形式的自定义映射表（每行 `本机 = 远端`），带两下捕获自动落行。
    private var customMappingSection: some View {
        DisclosureGroup("自定义按键映射（每行 `本机 = 远端`）", isExpanded: $showKeyMapping) {
            VStack(alignment: .leading, spacing: 4) {
                TextEditor(text: $state.keyMappingSpec)
                    .font(.system(size: 10.5, design: .monospaced))
                    .frame(height: 72)
                    .overlay(RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.secondary.opacity(0.3)))

                // ★ 两下捕获自动写一行 —— 手打 `cmd+shift+z = ctrl+y` 这套写法
                //   要求用户先学会语法，错一个字母就静默不生效（界面上只有个黄三角）。
                HStack(spacing: 6) {
                    ChordCaptureButton(target: Self.captureSourceTarget, compact: false) {
                        pendingSrc = $0; commitCapturePair()
                    }
                    ChordCaptureButton(target: Self.captureDestTarget, compact: false) {
                        pendingDst = $0; commitCapturePair()
                    }
                    Spacer()
                }
                .padding(.top, 1)

                if !pendingSrc.isEmpty || !pendingDst.isEmpty {
                    Text("已捕获：\(pendingSrc.isEmpty ? "…" : KeyCaptureMap.pretty(pendingSrc))"
                         + " = \(pendingDst.isEmpty ? "…" : KeyCaptureMap.pretty(pendingDst))"
                         + " —— 两边都按完会自动写成一行")
                        .font(.caption2).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ChordCaptureHint()

                Text("例：`cmd+shift+z = ctrl+y`、`cmd+d = ctrl+d`。"
                     + "也可以点上面两个「捕获按键」：先按本机要用的组合，再按远端要映射到的组合。"
                     + "`#` 开头是注释。")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(state.keyMappingSummary)
                    .font(.caption2)
                    .foregroundStyle(state.keyMappingSummary.contains("无法解析") ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 2)
        }
        .font(.caption)
    }

    // MARK: - ④ 日志和帮助

    private var helpTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("日志")
            HStack(spacing: 8) {
                Button {
                    NSApp.sendAction(#selector(AppDelegate.showLogWindow(_:)), to: nil, from: nil)
                } label: {
                    Label("打开日志窗口", systemImage: "doc.text.magnifyingglass").font(.caption)
                }
                .buttonStyle(.bordered).controlSize(.small)
                Spacer()
                Text("⌘L").font(.caption2).foregroundStyle(.secondary)
            }
            helpBody("日志文件 `/tmp/mwb_gui.log`（上一次 `/tmp/mwb_gui.prev.log`）。"
                     + "终端里 `tail -f /tmp/mwb_gui.log` 可实时观察。")
            helpBody("需要逐包级细节时，用 `MWB_VERBOSE=1` 启动，会打印每个鼠标/键盘包的数值。")

            Divider()
            SectionTitle("快速上手")
            helpLine("1", "本页签左侧「基础设置」里填 Windows 的 IP 与配对码 → 点「连接」。")
            helpLine("2", "鼠标推到屏幕边缘即跨到 Windows（方位在基础设置里选）。")
            helpLine("3", "文本、图片、文件剪贴板自动双向同步，无需额外操作。")
            helpLine("4", "侧键 / 滚轮 / 组合键在「键盘映射」页签里逐项设置。")

            Divider()
            SectionTitle("遇到问题")
            helpQA("键盘在 Windows 上没反应",
                   "系统设置 → 隐私与安全性 → 输入监控，勾上 MWB 后「完全退出再重开」"
                   + "（该权限对已运行进程不即时生效）。授权入口在「基础设置」页签底部。")
            helpQA("鼠标只能推到屏幕 2/3 处",
                   "本机接了 Sidecar（随航）副屏时坐标基准会变；断开随航再试。")
            helpQA("大图片剪贴板传不过去",
                   "超过 1MB 的图要在把控制权交回 Windows 的那一刻才推送，稍等 1~2 秒。")
            helpQA("面板里的设置改了没生效",
                   "除「立刻生效」的开关外，改完请断开再连一次，让对端重新握手。")
        }
        .padding(12)
    }

    private func helpBody(_ s: String) -> some View {
        Text(s).font(.caption2).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func helpLine(_ no: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(no).font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary).frame(width: 12, alignment: .leading)
            Text(text).font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func helpQA(_ q: String, _ a: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(q).font(.system(size: 10.5, weight: .medium))
            Text(a).font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
                      + "勾选后请「完全退出 MWB 再重开」（「输入监控」对已运行进程不即时生效）。")
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

/// **CPU 定位用**：`MWB_ADV_SKIP=mouse,editor,base,cmd` 里列出的区块直接不渲染。
///
/// 【为什么需要】「面板某处烧 CPU」这种问题，抓栈只能看到 SwiftUI 框架内部在空转，
/// 看不出是哪个子视图。唯一可靠的办法是"砍掉一半再看还涨不涨"，所以在渲染层留一个
/// 可逐块关闭的开关。定位完成后本开关保持无害（不设环境变量就全渲染）。
func mwbAdvSkipped(_ name: String) -> Bool {
    let raw = ProcessInfo.processInfo.environment["MWB_ADV_SKIP"] ?? ""
    return raw.split(separator: ",").contains { $0.trimmingCharacters(in: .whitespaces) == name }
}

private struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.caption).fontWeight(.semibold).foregroundStyle(.primary)
    }
}

/// 供「版式自检」离屏快照用：渲染**当前页签的全部内容**（高度不限）。
///
/// 用途：拿到某个页签的「内容总高度」，与面板高度对比即可判断是否会显示不全。
/// `MWB_RENDER_TAB=keys` 之类可以指定拍哪一页。
/// 因为 ContentView 已改成显式注入 state，这里直接透传即可，不再需要环境对象，
/// 也就绕开了 `NSHostingView`/`ImageRenderer` 拿不到 `@EnvironmentObject` 的问题。
struct PanelSnapshot: View {
    @ObservedObject var state: AppState
    var body: some View {
        ContentView(state: state).tabBody
    }
}

/// 供「版式自检」离屏快照用：渲染**真实 Popover 外层**（header + 页签 + 滚动区 + footer）。
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
