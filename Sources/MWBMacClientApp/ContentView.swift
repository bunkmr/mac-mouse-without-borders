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
//
// 【2026-10-06 改版】「屏幕方位 / 机器矩阵 / 本机槽位」三处控件合并成一张
// **可拖动的「屏幕布局」棋盘** —— 它们本来是同一件事（几台机器怎么摆）却占了三块地方。
// 见 `screenLayoutSection`。

import SwiftUI
import AppKit
import UniformTypeIdentifiers
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
        case .basics:   return L("基础设置")
        case .transfer: return L("文件传输")
        case .keys:     return L("键盘映射")
        case .help:     return L("日志和帮助")
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
    /// 「本机方块」是否正在被拖动（用于落点判定与视觉反馈）。
    @State private var draggingSelfSlot: Int? = nil
    /// 当前高亮的落点格子（拖到哪一格上面）。
    @State private var dropTargetSlot: Int? = nil

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
                Text(state.controllingRemote ? L("⟶ 正在控制 Windows") : state.statusText)
                    .font(.caption)
                    .foregroundStyle(state.controllingRemote ? .blue : .secondary)
                    .lineLimit(1).truncationMode(.tail)
            }
            Spacer()
            Button(state.connected ? L("断开") : L("连接")) {
                state.connected ? state.disconnect() : state.connect()
            }
            .buttonStyle(.borderedProminent)
            .tint(state.connected ? .red : .accentColor)
            .disabled(state.connecting)

            Button { state.quit() } label: {
                Image(systemName: "power").font(.caption)
            }
            .buttonStyle(.bordered)
            .help(L("退出 MWB（也会恢复鼠标光标）"))
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
        .help(LF("%@（共 %d 页）", t.title, PanelTab.allCases.count))
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
                Label(L("查看日志"), systemImage: "doc.text.magnifyingglass").font(.caption)
            }
            .buttonStyle(.bordered).controlSize(.small)

            Spacer()
            Text(L("⌘Q 退出")).font(.caption2).foregroundStyle(.secondary)
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

    /// 待机唤醒区块（v1.4.3）。
    ///
    /// ★ **必须**单独抽成 view、且文案放静态属性：直接内联进 `basicsTab` 的 VStack
    ///   会让那个表达式的类型推断超时 ——
    ///   `error: the compiler is unable to type-check this expression in reasonable time`。
    ///   诱因是「长字符串字面量 + 多层嵌套 ViewBuilder」。2026-09-17 改版与
    ///   （2026-09-19 / 2026-10-06）都栽在同一处，所以这里刻意拆干净。
    @ViewBuilder
    private var standbyWakeSection: some View {
        Divider()
        SectionTitle(L("待机唤醒（屏幕熄灭后仍可被 Windows 键鼠唤醒）"))
        Toggle(L("屏幕熄灭后仍可被 Windows 鼠标唤醒"), isOn: $state.standbyWakeEnabled)
            .help(Self.standbyHelp)
        Toggle(L("仅在插电时生效（电池时照常深度睡眠）"), isOn: $state.standbyWakeACOnly)
            .disabled(!state.standbyWakeEnabled)
            .help(Self.standbyHelpAcOnly)
        HStack(spacing: 8) {
            Text(standbyStatusLine).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button {
                state.runStandbyWakeSelfTest()
            } label: {
                Label(L("唤醒自检"), systemImage: "sun.max").font(.caption)
            }
            .buttonStyle(.bordered).controlSize(.small)
            .help(Self.standbyHelpTest)
        }
    }

    private var standbyStatusLine: String {
        guard state.standbyWakeEnabled else { return L("已关闭") }
        return state.standbyStatusText
            + (state.standbyWakeCount > 0 ? LF(" · 已唤醒 %d 次", state.standbyWakeCount) : "")
    }

    private static let standbyHelp = """
    开启后：本 App 会持有一条「阻止系统空闲睡眠」断言 —— 屏幕照常熄灭省电，但系统不再进入空闲睡眠。于是 MWB 一直在线（心跳照发、包照收、Windows 面板里本机不会掉线），Windows 鼠标撞到本机边缘时就能立刻点亮屏幕并接管。

    ⚠️ 它挡不住「手动睡眠」和「合盖」—— 那是真挂起：进程被冻结、socket 不再收包。这不是本 App 的限制，是 macOS 的机制（改 MWB 协议也没用）。真要「睡死还能被叫醒」，只能靠硬件级 WoL：有线网 + pmset womp + 对端发魔术包。
    """

    private static let standbyHelpAcOnly = """
    笔记本电池供电时不阻止睡眠，避免悄悄掉续航；一旦插上电源会在 5 秒内自动生效。
    想电池时也生效，把这个开关关掉即可（代价是电池模式下不再深度睡眠）。
    """

    private static let standbyHelpTest = """
    不需要连接 Windows：点一下，屏幕会熄灭 3 秒后自动点亮。
    这 6 秒内请不要碰键鼠 —— 一碰，屏幕会被真实输入提前点亮，自检结论就不作数了。
    """

    private var basicsTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(L("Windows 主机"))
            row(L("IP 地址")) {
                TextField("192.168.1.100", text: $state.host).textFieldStyle(.roundedBorder)
            }
            row(L("端口 / 密钥")) {
                HStack(spacing: 6) {
                    TextField("15101", text: $state.portText)
                        .frame(width: 60).textFieldStyle(.roundedBorder)
                    SecureField(L("配对码"), text: $state.securityKey).textFieldStyle(.roundedBorder)
                }
            }

            screenLayoutSection

            Divider()
            // 长说明收进 tooltip（悬停才看），避免占掉面板高度。
            Toggle(L("控制 Windows 时隐藏并锁定本机光标"), isOn: $state.lockCursorWhileRemote)
                .help("开启后鼠标跨到 Windows 时，Mac 上的光标会【隐藏】并把位置钉在屏幕边缘，"
                      + "回到本机时自动恢复显示。"
                      + "隐藏靠 CGDisplayHideCursor（实测有效），退出/断开/紧急热键都会恢复，"
                      + "不会留下一个看不见的光标。")

            HStack(spacing: 8) {
                Button {
                    state.runCursorLockSelfTest()
                } label: {
                    Label(L("锁定自检"), systemImage: "scope").font(.caption)
                }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(state.connected)
                .help("不需要连接 Windows：点一下，然后在这 6 秒里晃动鼠标，Mac 光标若停住不动即说明锁定生效。")

                Button {
                    state.runSwitchSelfTest()
                } label: {
                    Label(L("跨屏自检"), systemImage: "arrow.left.arrow.right").font(.caption)
                }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(state.connected)
                .help("不需要连接 Windows：用合成事件跑一遍「滑出到对端 → 浅进一段 → 推回本机」，"
                      + "验证鼠标回得来、且交回本机后不会被立刻弹回去。")
                Spacer()
            }

            standbyWakeSection

            Divider()
            SectionTitle(L("本机"))
            localMachineSection

            Divider()
            // ★ 「语言」这一栏**必须双语常显**（不走 L() 翻译）：
            //   它是"切错了语言的人"唯一的自救入口 —— 全站只有这里不能跟着语言变。
            //   顺序随当前语言摆动，读起来才自然。
            SectionTitle(Lang.isEnglish ? "Language / 语言" : "语言 / Language")
            languageSection

            Divider()
            SectionTitle(L("连接状态"))
            statusSection
        }
        .padding(12)
    }

    // MARK: - 屏幕布局（合并「屏幕方位 / 机器矩阵 / 本机槽位」）

    /// 棋盘是否 2×2（否则 1×4 一行）。来源是对端下发的 Matrix 包。
    private var layoutTwoRow: Bool { state.matrix?.twoRow ?? true }

    /// 当前 4 个槽位（没连上时是 4 个空格子）。
    private var layoutSlots: [MachineSlot] {
        state.matrix?.slots ?? (1...4).map { MachineSlot(id: $0) }
    }

    /// 本机占哪个槽。优先用设置里的显式槽位，其次用矩阵学到的，
    /// 都没有就先摆在 1 号格（**纯展示**，不影响协议 —— 未连接时也得让用户能拖动自己的方块）。
    private var selfSlotForBoard: Int? {
        if let t = Int(state.slotText), (1...4).contains(t) { return t }
        return state.matrix?.selfSlot ?? 1
    }

    /// 对端（Windows）占哪个槽 —— 取第一个"有名字且不是本机"的槽位。
    private var peerSlotForBoard: Int? {
        guard let m = state.matrix else { return nil }
        return m.slots.first { $0.occupied && $0.name != state.machineName }?.id
    }

    /// 由相对位置推导出来的滑出方向。
    private var derivedEdge: (edge: SwitchEdge, guessed: Bool)? {
        guard let s = selfSlotForBoard, let p = peerSlotForBoard, s != p else { return nil }
        return ScreenLayout.exitEdge(selfSlot: s, peerSlot: p, twoRow: layoutTwoRow)
    }

    /// 详情行：说明当前布局是从哪来的。
    private var layoutHint: String {
        guard let m = state.matrix else { return L("连接后显示 4 台机器的布局与联机状态") }
        if !m.receivedMatrix { return LF("在线 %d 台 · 还没收到 Windows 下发的布局", m.onlineCount) }
        let slot = selfSlotForBoard.map(String.init) ?? "?"
        if let d = derivedEdge {
            let dir = Self.edgeName(d.edge)
            return LF("在线 %d 台 · 本机槽位 %@", m.onlineCount, slot)
                + " · " + (d.guessed
                    ? LF("Windows 位于对角，按「%@」推测", dir)
                    : LF("Windows 在「%@」侧", dir))
        }
        return LF("在线 %d 台 · 本机槽位 %@", m.onlineCount, slot)
    }

    private static func edgeName(_ e: SwitchEdge) -> String {
        switch e {
        case .left:   return L("左")
        case .right:  return L("右")
        case .top:    return L("上")
        case .bottom: return L("下")
        }
    }

    /// **合并后的单一控件**：一张可拖动的 2×2 / 1×4 棋盘。
    ///
    /// 三处旧控件在这里合一：
    ///   · 「机器矩阵」→ 就是这张棋盘本身；
    ///   · 「本机槽位」→ 把**本机方块拖到别的格子**（也可点格子）；
    ///   · 「屏幕方位」→ 由本机与对端的相对位置**推导**，下方的方向按钮只是它的快捷改法。
    /// 参考同类软件（Synergy / Barrier / Input Leap）的 "Screens & Links"：
    /// 方位本就是"图上的相对位置"，不该再单开一个下拉框。
    private var screenLayoutSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack(spacing: 6) {
                SectionTitle(L("屏幕布局"))
                Spacer()
                if let m = state.matrix, m.receivedMatrix {
                    Text(m.twoRow ? "2×2" : "1×4")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                    if m.wrap {
                        Text(L("环绕")).font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }
            }

            boardGrid

            Text(layoutHint)
                .font(.system(size: 9.5)).foregroundStyle(.secondary)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)

            edgeRow

            HStack(spacing: 6) {
                if state.slotText != "auto" {
                    Button {
                        state.slotText = "auto"
                        if let d = derivedEdge { state.edge = d.edge }
                    } label: {
                        Label(L("槽位自动（由 Windows 学习）"), systemImage: "arrow.uturn.backward")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.borderless)
                    .help(L("布局由 Windows 下发的机器矩阵推导；手动改动会覆盖推导结果。"))
                }
                Spacer()
            }
        }
    }

    /// 棋盘本体。格子 = 槽位；本机方块可拖，也可以直接点一下格子把它搬过去。
    private var boardGrid: some View {
        let twoRow = layoutTwoRow
        let cols = twoRow ? 2 : 4
        let rows = twoRow ? 2 : 1
        return VStack(spacing: 5) {
            ForEach(0..<rows, id: \.self) { r in
                HStack(spacing: 5) {
                    ForEach(0..<cols, id: \.self) { c in
                        slotTile(r * cols + c + 1)
                    }
                }
            }
        }
    }

    private func slotTile(_ slot: Int) -> some View {
        let s = layoutSlots[safe: slot - 1]
        let isSelf = (selfSlotForBoard == slot)
        let isPeer = (peerSlotForBoard == slot)
        let occupied = (s?.occupied ?? false) || isSelf
        let online = s?.online ?? false
        let dot: Color = isSelf ? .blue : (online ? .green : (isPeer ? .orange : Color.secondary.opacity(0.3)))
        let name = isSelf ? state.machineName : (s?.name ?? "")
        let targeted = (dropTargetSlot == slot)

        return VStack(spacing: 2) {
            HStack(spacing: 3) {
                Circle().fill(dot).frame(width: 6, height: 6)
                Text("\(slot)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if isSelf {
                    Text(L("本机")).font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.blue)
                }
            }
            Text(occupied ? name : L("空"))
                .font(.system(size: 10))
                .lineLimit(1).truncationMode(.middle)
                .foregroundStyle(occupied ? Color.primary : Color.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 5).padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 5).fill(dot.opacity(targeted ? 0.22 : 0.09)))
        .overlay(RoundedRectangle(cornerRadius: 5)
            .stroke(dot.opacity(targeted ? 0.95 : (isSelf ? 0.65 : 0.28)),
                    lineWidth: targeted ? 1.6 : 1))
        .contentShape(Rectangle())
        .onTapGesture { moveSelf(to: slot) }
        .onDrag {
            // 只有本机方块能被拖走 —— 对端在哪个槽是它自己的事，我们改不了。
            guard isSelf else {
                return NSItemProvider(object: "mwb-none" as NSString)
            }
            draggingSelfSlot = slot
            return NSItemProvider(object: "mwb-self" as NSString)
        }
        .onDrop(of: [UTType.text], isTargeted: Binding(
            get: { dropTargetSlot == slot },
            set: { dropTargetSlot = $0 ? slot : (dropTargetSlot == slot ? nil : dropTargetSlot) }
        )) { providers in
            guard draggingSelfSlot != nil else { return false }
            providers.first?.loadObject(ofClass: NSString.self) { obj, _ in
                DispatchQueue.main.async {
                    let payload = (obj as? NSString).map(String.init) ?? ""
                    if payload == "mwb-self" { moveSelf(to: slot) }
                    draggingSelfSlot = nil
                    dropTargetSlot = nil
                }
            }
            return true
        }
        .help(LF("槽位 %d：%@", slot, occupied ? name : L("空")))
    }

    /// 把本机搬到某个槽位；若能推导出方向就顺手同步（这就是"拖动即设方位"）。
    private func moveSelf(to slot: Int) {
        guard (1...4).contains(slot) else { return }
        draggingSelfSlot = nil
        dropTargetSlot = nil
        guard selfSlotForBoard != slot else { return }
        state.slotText = "\(slot)"
        // 对端位置已知 → 立刻按新相对位置刷新滑出方向；未知（未连接）则保持用户当前选择。
        if let p = peerSlotForBoard, p != slot,
           let d = ScreenLayout.exitEdge(selfSlot: slot, peerSlot: p, twoRow: layoutTwoRow) {
            state.edge = d.edge
        }
    }

    /// 方位快捷改法（等价于把 Windows 拖到那一侧）。棋盘上移不动对端，所以保留这一行。
    ///
    /// 【为什么拆成两行】原先写成一句 `鼠标从本机 [左|右|上|下] 边缘滑出（Windows 在这一侧）`，
    /// 面板净宽只有 ~324pt，中英两种语言都会把尾巴截掉（`.lineLimit(1)` + `.tail`），
    /// 而且中英断句位置不同 ⇒ 英文渲染成 "Cursor exits this … edge (Windows is…" 更难看。
    /// 现在把说明挪到独立一行并允许换行，两种语言都不会被裁。
    private var edgeRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            row(L("跨越边缘")) {
                Picker("", selection: $state.edge) {
                    Text(L("左")).tag(SwitchEdge.left)
                    Text(L("右")).tag(SwitchEdge.right)
                    Text(L("上")).tag(SwitchEdge.top)
                    Text(L("下")).tag(SwitchEdge.bottom)
                }
                .labelsHidden().pickerStyle(.segmented)
                .frame(width: 148)
            }
            Text(L("鼠标从本机这一侧边缘滑出，Windows 就在那个方向。"))
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 本机身份与坐标映射（原「高级设置」的第一段）

    @ViewBuilder
    private var localMachineSection: some View {
        row(L("本机名称")) {
            TextField("MacBook-Pro", text: $state.machineName).textFieldStyle(.roundedBorder)
        }

        HStack(spacing: 6) {
            Text(L("远端分辨率")).font(.caption).foregroundStyle(.secondary).frame(width: 84, alignment: .leading)
            TextField("1920", text: $state.remoteW).frame(width: 56).textFieldStyle(.roundedBorder)
            Text("×").foregroundStyle(.secondary)
            TextField("1080", text: $state.remoteH).frame(width: 56).textFieldStyle(.roundedBorder)
            Spacer()
        }
        .disabled(state.proportionalMapping)
        .opacity(state.proportionalMapping ? 0.4 : 1)

        Toggle(L("按本机屏幕比例映射（推荐）"), isOn: $state.proportionalMapping)
            .font(.caption)
        Text(state.proportionalMapping
             ? L("协议原生做法：跨过本机整个屏幕宽 = 跨过 Windows 整个屏幕宽，与对端分辨率无关。")
             : L("按对端像素 1:1：填错会让 Windows 光标明显偏快/偏慢。"))
            .font(.caption2).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        Toggle(L("启动后自动连接"), isOn: $state.autoConnect).font(.caption)
    }

    // MARK: - 界面语言

    /// 语言设置。默认**跟随系统**（首选语言是 zh* 就中文，其余英文）。
    private var languageSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            row(L("界面语言")) {
                Picker("", selection: $state.appLanguage) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .labelsHidden().pickerStyle(.menu).frame(maxWidth: 180)
            }
            Text(L("语言切换即时生效。日志内容始终为中文（排查用）。"))
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - ② 文件传输

    private var transferTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(L("文件传输"))
            Toggle(L("拖文件到屏幕边缘即发送"), isOn: $state.dropDockEnabled).font(.caption)
            Toggle(L("Finder 复制文件(Cmd+C)自动同步"), isOn: $state.clipboardFileEnabled).font(.caption)
            row(L("端口")) {
                TextField(L("自动"), text: $state.filePortText)
                    .frame(width: 76).textFieldStyle(.roundedBorder)
            }
            Text(L("留空 = MWB 原生剪贴板通道（主通道端口-1，即 15100）。Windows 端用 MWB 自带拖放实现接收，无需额外程序。"))
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !state.fileActivity.isEmpty {
                Text(state.fileActivity).font(.caption2).foregroundStyle(.blue)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            SectionTitle(L("剪贴板"))
            Toggle(L("同步图片剪贴板"), isOn: $state.clipboardImageEnabled).font(.caption)
            Text(L("文本一直同步。图片按 MWB 原生做法传 PNG；超过 1MB 自动改走「发心跳 → 对端回连拉取」，不必额外设置。"))
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(L("注：>1MB 的图要在「把控制权交回 Windows」的那一刻才会推送，稍等 1~2 秒。"))
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()
            SectionTitle(L("通道"))
            channelRow(L("控制通道"), L("TCP 15101 —— 键鼠事件 + 文本剪贴板，变化即推。"))
            channelRow(L("文件 / 图片"), L("TCP 15100 —— 独立于控制通道，互不阻塞。"))
            channelRow(L("接收位置"), L("图片剪贴板内容直接写进本机剪贴板；其它文件落在「桌面/MouseWithoutBorders/」。"))
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
                SectionTitle(L("Command 键"))
                row(L("Command 键")) {
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
                SectionTitle(L("鼠标按键"))
                Text(L("每个按键可分别设置「点按 / 按住滚动 / 按住拖动」在本机与远端的动作，按键可随时增删。"))
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
        DisclosureGroup(L("自定义按键映射（每行 `本机 = 远端`）"), isExpanded: $showKeyMapping) {
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
                    Text(LF("已捕获：%@ = %@ —— 两边都按完会自动写成一行",
                            pendingSrc.isEmpty ? "…" : KeyCaptureMap.pretty(pendingSrc),
                            pendingDst.isEmpty ? "…" : KeyCaptureMap.pretty(pendingDst)))
                        .font(.caption2).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ChordCaptureHint()

                Text(L("例：`cmd+shift+z = ctrl+y`、`cmd+d = ctrl+d`。也可以点上面两个「捕获按键」：先按本机要用的组合，再按远端要映射到的组合。`#` 开头是注释。"))
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
            SectionTitle(L("日志"))
            HStack(spacing: 8) {
                Button {
                    NSApp.sendAction(#selector(AppDelegate.showLogWindow(_:)), to: nil, from: nil)
                } label: {
                    Label(L("打开日志窗口"), systemImage: "doc.text.magnifyingglass").font(.caption)
                }
                .buttonStyle(.bordered).controlSize(.small)
                Spacer()
                Text("⌘L").font(.caption2).foregroundStyle(.secondary)
            }
            helpBody(L("日志文件 `/tmp/mwb_gui.log`（上一次 `/tmp/mwb_gui.prev.log`）。终端里 `tail -f /tmp/mwb_gui.log` 可实时观察。"))
            helpBody(L("需要逐包级细节时，用 `MWB_VERBOSE=1` 启动，会打印每个鼠标/键盘包的数值。"))

            Divider()
            SectionTitle(L("快速上手"))
            helpLine("1", L("本页签左侧「基础设置」里填 Windows 的 IP 与配对码 → 点「连接」。"))
            helpLine("2", L("鼠标推到屏幕边缘即跨到 Windows（方位在基础设置里选）。"))
            helpLine("3", L("文本、图片、文件剪贴板自动双向同步，无需额外操作。"))
            helpLine("4", L("侧键 / 滚轮 / 组合键在「键盘映射」页签里逐项设置。"))

            Divider()
            SectionTitle(L("遇到问题"))
            helpQA(L("键盘在 Windows 上没反应"),
                   L("系统设置 → 隐私与安全性 → 输入监控，勾上 MWB 后「完全退出再重开」（该权限对已运行进程不即时生效）。授权入口在「基础设置」页签底部。"))
            helpQA(L("鼠标只能推到屏幕 2/3 处"),
                   L("本机接了 Sidecar（随航）副屏时坐标基准会变；断开随航再试。"))
            helpQA(L("大图片剪贴板传不过去"),
                   L("超过 1MB 的图要在把控制权交回 Windows 的那一刻才推送，稍等 1~2 秒。"))
            helpQA(L("面板里的设置改了没生效"),
                   L("除「立刻生效」的开关外，改完请断开再连一次，让对端重新握手。"))
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

    // MARK: - 状态 / 权限

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            if state.captureOK && state.axTrusted && state.inputMonitoringOK {
                // 一切正常时压成一行，把垂直空间留给别的内容
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 10)).foregroundStyle(.green)
                    Text(L("键鼠捕获已就绪"))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(LF("鼠标 %@ · 键盘 %@", "\(state.tapEvents)", "\(state.keyEvents)"))
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Button { state.retryCapture() } label: {
                        Image(systemName: "arrow.clockwise").font(.caption)
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                    .help(L("重建事件捕获"))
                    .disabled(!state.connected)
                }
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.shield.fill")
                        .foregroundStyle(.orange)
                    Text(L("事件捕获未建立，键鼠无法跨屏"))
                        .font(.caption).fontWeight(.medium)
                    Spacer()
                    Button { state.retryCapture() } label: {
                        Image(systemName: "arrow.clockwise").font(.caption)
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(!state.connected)
                }

                HStack(spacing: 12) {
                    permissionChip(L("辅助功能（鼠标）"), ok: state.axTrusted)
                    permissionChip(L("输入监控（键盘）"), ok: state.inputMonitoringOK)
                    Spacer()
                    Text(LF("鼠标 %@ · 键盘 %@", "\(state.tapEvents)", "\(state.keyEvents)"))
                        .font(.caption2).foregroundStyle(.secondary)
                }

                // 说明文字压到各一行 —— 之前四行提示把面板顶出了 560pt 上限。
                if !state.inputMonitoringOK {
                    Text(L("「输入监控」未授权：键盘事件会被系统静默丢弃（鼠标不受影响）。"))
                        .font(.caption2).foregroundStyle(.orange)
                        .lineLimit(1).truncationMode(.tail)
                } else if state.keyEvents == 0 {
                    Text(L("输入监控已授权但没收到键盘事件：敲一下键盘看数字是否增长。"))
                        .font(.caption2).foregroundStyle(.orange)
                        .lineLimit(1).truncationMode(.tail)
                }

                HStack(spacing: 6) {
                    Button(L("授权辅助功能")) { state.openAccessibilitySettings() }
                        .font(.caption2).buttonStyle(.bordered)
                    Button(L("授权输入监控")) { state.openInputMonitoringSettings() }
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
            // ⚠️ `.fixedSize(horizontal: false, vertical: true)` 不能省：
            // 标签宽被钉死 84pt，而右侧若是 Picker/TextField 这类"有固有宽度"的控件，
            // SwiftUI 会宁可把标签**截断**（英文 "Interface language" → "Interface langu…"）
            // 也不给它第二行的高度。显式放开纵向，让它换行而不是省略。
            Text(title).font(.caption).foregroundStyle(.secondary)
                .frame(width: 84, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
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
