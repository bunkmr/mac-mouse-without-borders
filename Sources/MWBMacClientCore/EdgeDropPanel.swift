// EdgeDropPanel.swift
// 屏幕边缘的「文件投放带」—— 把文件拖到边缘松手，即传给 Windows。
//
// 设计要点：
//  - 常驻一条贴边透明窗口，平时 ignoresMouseEvents = true，绝不干扰「撞边缘切换控制权」。
//  - 仅当鼠标按下（必然是拖拽的前奏）时才临时打开鼠标事件，拖拽结束立刻关掉。
//    这样既不影响日常使用，又保证拖文件过来时窗口能成为 drop target。
//  - 拖拽进入时高亮，给出视觉反馈。

import AppKit

// MARK: - 投放区视图

private final class DropView: NSView {

    var onFiles: (([URL]) -> Void)?
    var onHoverChanged: ((Bool) -> Void)?
    private var hovering = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // 同时接受文件 URL 与文字（后者可把拖进来的文本当 txt 发送）
        registerForDraggedTypes([.fileURL, .string])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 未实现") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        hovering = true
        onHoverChanged?(true)
        needsDisplay = true
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        hovering = false
        onHoverChanged?(false)
        needsDisplay = true
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer {
            hovering = false
            onHoverChanged?(false)
            needsDisplay = true
        }
        let pb = sender.draggingPasteboard
        var urls: [URL] = []
        if let objs = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            urls = objs
        }
        if urls.isEmpty, let s = pb.string(forType: .string), !s.isEmpty {
            // 拖进来的是纯文本：落成临时 txt 再发
            let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("mwb-dragged-\(UUID().uuidString.prefix(8)).txt")
            try? s.data(using: .utf8)?.write(to: tmp)
            urls = [tmp]
        }
        guard !urls.isEmpty else { return false }
        onFiles?(urls)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard hovering else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
        bounds.fill()
        let path = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5))
        NSColor.controlAccentColor.withAlphaComponent(0.85).setStroke()
        path.lineWidth = 3
        path.stroke()
    }

    override var isFlipped: Bool { false }
}

// MARK: - 边缘投放带

public final class EdgeDropPanel: NSObject {

    public var onFiles: (([URL]) -> Void)?
    public var onLog: ((String) -> Void)?

    /// 贴在屏幕的哪条边（与键鼠切换边缘一致）
    public var edge: SwitchEdge = .right

    private var panel: NSPanel?
    private var dropView: DropView?
    private var monitors: [Any] = []
    private var armed = false

    public override init() { super.init() }

    /// 必须在主线程调用。
    public func start() {
        guard panel == nil else { return }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)   // 不显示 Dock 图标、不抢焦点

        guard let screen = NSScreen.main else {
            onLog?("[投放带] 无法获取主屏幕，已禁用")
            return
        }

        let f = screen.frame
        let thickness: CGFloat = 56
        let rect: NSRect
        switch edge {
        case .right:  rect = NSRect(x: f.maxX - thickness, y: f.minY, width: thickness, height: f.height)
        case .left:   rect = NSRect(x: f.minX, y: f.minY, width: thickness, height: f.height)
        case .top:    rect = NSRect(x: f.minX, y: f.maxY - thickness, width: f.width, height: thickness)
        case .bottom: rect = NSRect(x: f.minX, y: f.minY, width: f.width, height: thickness)
        }

        let p = NSPanel(contentRect: rect,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true            // 平时完全透明于鼠标
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false

        let v = DropView(frame: NSRect(origin: .zero, size: rect.size))
        v.onFiles = { [weak self] urls in
            guard let self else { return }
            let names = urls.prefix(3).map { $0.lastPathComponent }
                + (urls.count > 3 ? ["…共\(urls.count)个"] : [])
            self.onLog?("[投放带] 收到拖放: \(names.joined(separator: ", "))")
            self.onFiles?(urls)
        }
        p.contentView = v
        p.orderFrontRegardless()

        self.panel = p
        self.dropView = v

        // 仅在鼠标按下期间「武装」窗口，避免影响边缘切换
        let down = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            DispatchQueue.main.async { self?.setArmed(true) }
        }
        let up = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self?.setArmed(false) }
        }
        monitors.append(contentsOf: [down, up].compactMap { $0 })

        onLog?("[投放带] 已启动（\(edge) 边缘，宽 56px）— 拖文件到该边缘松手即发送")
    }

    public func stop() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
        panel?.orderOut(nil)
        panel = nil
    }

    private func setArmed(_ on: Bool) {
        guard armed != on else { return }
        armed = on
        panel?.ignoresMouseEvents = !on
    }
}
