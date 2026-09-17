// MachineMatrix.swift
// MWB 机器矩阵（最多 4 台机器）状态跟踪 —— 给 GUI 显示「4 个联机状态」用。
//
// 协议依据（已对 PowerToys 源码 + Somiona/mwb-client-macos 的
// docs/protocol/03. state and topology management.md 逐条核对）：
//  - 机器 ID **不是**随机 GUID，而是 1..4 的**物理槽位序号**（ID.NONE=0 / ID.ALL=255 广播）。
//    机器名 → 槽位 的映射由对端广播的 Matrix 包建立（协议里叫 MachinePool）。
//  - Matrix 包 = 64 字节大包：Type = 128 | 布局标志，Src = 槽位(1..4)，
//    byte32..63 = 该槽位机器的 ASCII 名字（空格补齐）。
//    布局标志：bit1(2)=环绕 MatrixSwapFlag，bit2(4)=2×2 MatrixTwoRowFlag。
//    第 4 个（Src==4）是权威包 —— 收到它才提交整张矩阵。
//  - 存活：TCP 已连 或 最近一次心跳在超时窗口内。协议给的 HEARTBEAT_TIMEOUT 是
//    25 分钟（太宽松，不适合做 UI 状态），这里另用一个秒级的「在线窗口」。

import Foundation

/// 矩阵里的一个槽位（对应 MWB 的 Machine1..Machine4）。
public struct MachineSlot: Identifiable, Equatable {
    /// 1..4
    public let id: Int
    /// 该槽位的机器名（ASCII，来自 Matrix 包或心跳的扩展机器名）
    public var name: String = ""
    /// 最近一次收到该机器任何消息的时间（Matrix / Hello / Heartbeat / Awake）
    public var lastSeen: Date?
    /// 该槽位名字是不是**从 Matrix 包**来的（权威），false = 从心跳推测
    public var fromMatrix: Bool = false

    public var occupied: Bool { !name.isEmpty }

    /// 在线判据：最近 10 秒内有过消息（MWB 心跳是秒级的）。
    /// 名字在但长时间没消息 = 已注册但离线。
    public var online: Bool {
        guard let t = lastSeen else { return false }
        return Date().timeIntervalSince(t) < 10
    }
}

/// 矩阵快照（GUI 渲染用，值类型，可安全跨线程传递）。
///
/// `Equatable` 是给 GUI 的性能开关用的：健康轮询每 1.5 秒取一次快照，只有**真的变了**
/// 才写回 `@Published` —— 否则每 1.5 秒都会触发一次全面板重算（实测那一次重算很贵，
/// 见 `MouseButtonCard` 的说明）。所有成员都是值类型，合成实现即可。
public struct MatrixSnapshot: Equatable {
    public var slots: [MachineSlot]
    /// 本机所在槽位（1..4）。nil = 还没确定
    public var selfSlot: Int?
    /// selfSlot 是否只是「推测」出来的（没收到 Matrix 也没配过）
    public var selfSlotGuessed: Bool
    /// 2×2 布局（否则 1×4 一行）
    public var twoRow: Bool
    /// 鼠标环绕（Circle 模式）
    public var wrap: Bool
    /// 是否收到过权威 Matrix 包
    public var receivedMatrix: Bool
    /// 在线机器数（含本机）
    public var onlineCount: Int
}

public final class MachineMatrix {

    private let lock = NSLock()
    private var _slots: [MachineSlot] = (1...4).map { MachineSlot(id: $0) }
    private var _twoRow = true
    private var _wrap = false
    private var _receivedMatrix = false
    private var _selfName = ""
    private var _selfSlot: Int?
    /// 暂存：收齐 4 个 Matrix 包再一次性提交（协议要求）
    private var pending: [Int: String] = [:]
    /// 待输出的矩阵变化日志（Client 取走转成 GUI 日志）
    private var _log: String = ""

    /// 变化回调（已切到主线程）。
    public var onChange: (() -> Void)?

    public init() {}

    // MARK: - 写入（接收循环线程调用）

    /// 设置本机名字（用于在矩阵里标出「本机」）。
    public func setSelfName(_ name: String) {
        lock.lock(); _selfName = name; lock.unlock()
        notify()
    }

    /// 用户在本机显式指定的槽位（1..4）。nil = 由对端 Matrix 学习。
    public func setConfiguredSelfSlot(_ slot: Int?) {
        lock.lock()
        if let s = slot, (1...4).contains(s) { _selfSlot = s } else { _selfSlot = nil }
        lock.unlock()
        notify()
    }

    /// 处理一个 Matrix 包（Type = 128 | 布局标志，Src = 槽位）。
    public func apply(matrixPacket p: DataPacket) {
        let flags = Int(p.type.rawValue & 0x7F)      // 去掉最高位的「是矩阵包」标志
        let slot = Int(p.src)
        guard (1...4).contains(slot) else { return }

        lock.lock()
        _twoRow = (flags & 4) != 0
        _wrap   = (flags & 2) != 0
        pending[slot] = p.machineName
        // 协议：第 4 个包是权威包，或已收齐 4 个槽位 → 提交
        let committed = (pending.count == 4) || (slot == 4)
        if committed {
            for (idx, name) in pending where (1...4).contains(idx) {
                _slots[idx - 1].name = name.trimmingCharacters(in: .whitespaces)
                _slots[idx - 1].fromMatrix = true
                _slots[idx - 1].lastSeen = Date()
            }
            _receivedMatrix = true
            pending.removeAll()
        }
        if !_selfName.isEmpty {
            for (i, s) in _slots.enumerated() where s.name == _selfName { _selfSlot = i + 1 }
        }
        if committed {
            let detail = _slots.map { $0.occupied ? "\($0.id)=\($0.name)" : "\($0.id)=—" }
                .joined(separator: "  ")
            var s = "[机器矩阵] 已同步 Windows 下发的布局：\(_twoRow ? "2×2" : "1×4")"
            if _wrap { s += " · 环绕开" }
            s += "   \(detail)"
            if let ss = _selfSlot { s += "   本机槽位=\(ss)" }
            _log = s
        }
        lock.unlock()

        if committed { notify() }
    }

    /// 取走待输出的矩阵日志（无则返回 nil）。
    public func takeLog() -> String? {
        lock.lock(); defer { lock.unlock() }
        guard !_log.isEmpty else { return nil }
        let s = _log; _log = ""; return s
    }

    /// 收到对端任何消息（Hello / Heartbeat / Awake）时更新存活与名字。
    public func noteSeen(src: UInt32, name: String) {
        let now = Date()
        let n = name.trimmingCharacters(in: .whitespaces)
        let slotFromSrc = Int(src)

        lock.lock()
        var changed = false
        if !n.isEmpty, n == _selfName {
            // 是我们自己（对端的广播里带上我们的名字）→ 记录槽位
            if let i = _slots.firstIndex(where: { $0.name == n }) { _selfSlot = i + 1 }
        } else if !n.isEmpty, let i = _slots.firstIndex(where: { $0.name == n }) {
            _slots[i].lastSeen = now
            changed = true
        } else if !n.isEmpty, (1...4).contains(slotFromSrc), _slots[slotFromSrc - 1].name.isEmpty {
            // 槽位还没登记：按 Src（= 槽位序号）先落进去
            _slots[slotFromSrc - 1].name = n
            _slots[slotFromSrc - 1].lastSeen = now
            changed = true
        } else if !n.isEmpty, let i = _slots.firstIndex(where: { $0.name.isEmpty }) {
            // 没有可用的槽位序号（对端用了非槽位 ID）：放进第一个空槽
            _slots[i].name = n
            _slots[i].lastSeen = now
            changed = true
        } else if (1...4).contains(slotFromSrc) {
            _slots[slotFromSrc - 1].lastSeen = now
            changed = true
        }
        lock.unlock()
        if changed { notify() }
    }

    /// 收到 ByeBye：把该机器标记为离线。
    public func noteByeBye(name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        lock.lock()
        for i in _slots.indices where n.isEmpty || _slots[i].name == n { _slots[i].lastSeen = nil }
        lock.unlock()
        notify()
    }

    /// 断开连接时：所有非本机槽位标为离线。
    public func markPeersOffline() {
        lock.lock()
        for i in _slots.indices where _slots[i].name != _selfName { _slots[i].lastSeen = nil }
        lock.unlock()
        notify()
    }

    // MARK: - 读取（GUI 主线程调用）

    public func snapshot() -> MatrixSnapshot {
        lock.lock()
        var slots = _slots
        var selfSlot = _selfSlot
        var guessed = false

        // 保证界面上永远能看到本机那一台
        if !_selfName.isEmpty {
            if let i = slots.firstIndex(where: { $0.name == _selfName }) {
                selfSlot = i + 1
            } else if let s = selfSlot, (1...4).contains(s) {
                slots[s - 1].name = _selfName
                slots[s - 1].lastSeen = Date()
            } else if let i = slots.firstIndex(where: { $0.name.isEmpty }) {
                selfSlot = i + 1
                slots[i].name = _selfName
                slots[i].lastSeen = Date()
                guessed = true
            }
        }
        let twoRow = _twoRow, wrap = _wrap, got = _receivedMatrix
        lock.unlock()

        return MatrixSnapshot(slots: slots, selfSlot: selfSlot, selfSlotGuessed: guessed,
                              twoRow: twoRow, wrap: wrap, receivedMatrix: got,
                              onlineCount: slots.filter { $0.online }.count)
    }

    private func notify() {
        guard let cb = onChange else { return }
        DispatchQueue.main.async { cb() }
    }
}
