// MWBLogView.swift
// 独立日志窗口 —— 把日志从菜单栏下拉面板里搬出来，避免面板被日志挤到显示不全。

import SwiftUI
import AppKit
import MWBMacClientCore

struct MWBLogView: View {
    /// 同 ContentView：显式注入而非 @EnvironmentObject，避免离屏/包装渲染时找不到对象。
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("MWB 运行日志")
                    .font(.headline)
                Text("（\(state.logLines.count) 行）")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Toggle("自动滚动", isOn: $state.logAutoScroll)
                    .toggleStyle(.switch).controlSize(.mini)
                Button("复制全部") { copyAll() }
                    .controlSize(.small)
                Button("在 Finder 中显示") { revealFile() }
                    .controlSize(.small)
                Button("清空") { state.logLines.removeAll() }
                    .controlSize(.small)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(state.logLines.enumerated()), id: \.offset) { i, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(i)
                        }
                    }
                    .padding(6)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.25)))
                .onChange(of: state.logLines.count) { _ in
                    guard state.logAutoScroll, let last = state.logLines.indices.last else { return }
                    proxy.scrollTo(last, anchor: .bottom)
                }
            }

            Text("日志文件：/tmp/mwb_gui.log —— 也可在终端里 `tail -f /tmp/mwb_gui.log` 实时观察。")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(minWidth: 520, minHeight: 320)
    }

    private func copyAll() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(state.logLines.joined(separator: "\n"), forType: .string)
    }

    private func revealFile() {
        NSWorkspace.shared.activateFileViewerSelecting(
            [URL(fileURLWithPath: "/tmp/mwb_gui.log")])
    }
}
