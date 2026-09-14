// Protocol.swift
// Mouse Without Borders (PowerToys) 线格式协议。
// 参考实现: Satyam52/MWBMac（已验证可配对当前 PowerToys MWB 的 macOS 客户端）。
//
// 关键事实（已逐字节核对当前 PowerToys MWB 协议，参考 Satyam52/MWBMac）:
//  - 纯 TCP，端口默认 15101（键鼠） / 15100（剪贴板）。
//  - 加密: AES-256-CBC，PBKDF2-HMAC-SHA512 派生密钥。
//      * 当前格式: 每条连接交换 32 字节明文头 [salt(16) | iv(16)]，收发各自用对方 salt/iv。
//      * 旧格式: 固定 salt = UTF16LE("18446744073709551615"), 固定 iv = ASCII("1844674407370955")。
//  - 握手前需交换一个 16 字节随机块（预热 CBC 链，先发后收）。
//  - 包结构 32 字节(小包) / 64 字节(大包，含机器名)。小端。
//  - 线格式:
//      byte0      = Type (1 字节)
//      byte1      = Checksum (2..31 的字节和)
//      byte2..3   = Magic (24-bit hash 的 top 16 位)
//      byte4..7   = ID    (int32 LE, 不可为 0)
//      byte8..11  = Src   (uint32)
//      byte12..15 = Des   (uint32, 255=broadcast)
//      byte16..31 = Payload union
//      byte32..63 = MachineName (仅大包, ASCII 空格补齐)
//  - 大包类型: Hello/Awake/Heartbeat/HeartbeatEx/Handshake/HandshakeAck/
//              Clipboard 系列 / Matrix(bit 128)。(HeartbeatEx 的 L2/L3 扩展非大包)

import Foundation

// MARK: - PackageType

/// MWB 包类型。值均 < 256，线格式用 byte0 = rawValue。
public struct PackageType: RawRepresentable, Equatable, Hashable, CustomStringConvertible {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let invalid        = PackageType(rawValue: 0xFF)
    public static let hi             = PackageType(rawValue: 2)
    public static let hello          = PackageType(rawValue: 3)
    public static let byeBye         = PackageType(rawValue: 4)
    public static let heartbeat      = PackageType(rawValue: 20)
    public static let awake          = PackageType(rawValue: 21)
    public static let hideMouse      = PackageType(rawValue: 50)
    public static let heartbeatEx    = PackageType(rawValue: 51)
    public static let heartbeatExL2  = PackageType(rawValue: 52)
    public static let heartbeatExL3  = PackageType(rawValue: 53)
    public static let clipboard      = PackageType(rawValue: 69)
    public static let clipboardDragDrop      = PackageType(rawValue: 70)
    public static let clipboardDragDropEnd   = PackageType(rawValue: 71)
    public static let explorerDragDrop       = PackageType(rawValue: 72)
    public static let clipboardCapture       = PackageType(rawValue: 73)
    public static let captureScreenCommand   = PackageType(rawValue: 74)
    public static let clipboardDragDropOp    = PackageType(rawValue: 75)
    public static let clipboardDataEnd       = PackageType(rawValue: 76)
    public static let machineSwitched = PackageType(rawValue: 77)
    public static let clipboardAsk    = PackageType(rawValue: 78)
    public static let clipboardPush   = PackageType(rawValue: 79)
    public static let nextMachine    = PackageType(rawValue: 121)
    public static let keyboard       = PackageType(rawValue: 122)
    public static let mouse          = PackageType(rawValue: 123)
    public static let clipboardText  = PackageType(rawValue: 124)
    public static let clipboardImage = PackageType(rawValue: 125)
    public static let handshake      = PackageType(rawValue: 126)
    public static let handshakeAck   = PackageType(rawValue: 127)
    public static let matrix         = PackageType(rawValue: 128)

    /// 是否为机器矩阵类包（Matrix 位被置位）
    public var isMatrix: Bool { (rawValue & 128) != 0 }

    public var description: String {
        switch rawValue {
        case 0xFF: return "Invalid"
        case 0xFE: return "Error"
        case 2:    return "Hi"
        case 3:    return "Hello"
        case 4:    return "ByeBye"
        case 20:   return "Heartbeat"
        case 21:   return "Awake"
        case 50:   return "HideMouse"
        case 51:   return "Heartbeat_ex"
        case 52:   return "Heartbeat_ex_l2"
        case 53:   return "Heartbeat_ex_l3"
        case 69:   return "Clipboard"
        case 70:   return "ClipboardDragDrop"
        case 71:   return "ClipboardDragDropEnd"
        case 72:   return "ExplorerDragDrop"
        case 73:   return "ClipboardCapture"
        case 74:   return "CaptureScreenCommand"
        case 75:   return "ClipboardDragDropOperation"
        case 76:   return "ClipboardDataEnd"
        case 77:   return "MachineSwitched"
        case 78:   return "ClipboardAsk"
        case 79:   return "ClipboardPush"
        case 121:  return "NextMachine"
        case 122:  return "Keyboard"
        case 123:  return "Mouse"
        case 124:  return "ClipboardText"
        case 125:  return "ClipboardImage"
        case 126:  return "Handshake"
        case 127:  return "HandshakeAck"
        case 128:  return "Matrix"
        default:
            return isMatrix ? "Matrix(0x\(String(rawValue, radix: 16)))" : "Unknown(\(rawValue))"
        }
    }
}

// MARK: - DataPacket

/// 对应 MWB 的 DATA 结构体。布局严格对齐稳定协议（见文件头）。
public struct DataPacket {
    public static let smallSize = 32
    public static let bigSize = 64

    public var type: PackageType
    public var id: UInt32 = 0
    public var src: UInt32 = 0
    public var des: UInt32 = 0

    // 联合区 (offset 16..<32)
    // Mouse (123): X(16) Y(20) WheelDelta(24) DwFlags(28)
    public var mouseX: Int32 = 0
    public var mouseY: Int32 = 0
    public var mouseWheel: Int32 = 0
    public var mouseFlags: Int32 = 0
    // Keyboard (122): DateTime(16, i64) wVk(24) DwFlags(28)
    public var dateTime: Int64 = 0
    public var keyVk: Int32 = 0
    public var keyFlags: Int32 = 0
    // Handshake / HandshakeAck (126/127): Machine1-4 (offset 16..<32)
    public var machine1: UInt32 = 0
    public var machine2: UInt32 = 0
    public var machine3: UInt32 = 0
    public var machine4: UInt32 = 0

    /// 剪贴板数据（ClipboardText 124 / ClipboardImage 125）：
    /// 文本/图像字节直接从 byte16 起铺满到 byte63（共 48 字节/片），
    /// **这一片里 MachineName 字段（byte32..63）不被使用**（已核对 PowerToys 源码，
    /// 发送端只设 Type/Des，随后把数据整段拷进 byte16 起）。
    /// 不足 48 字节的末片按 MWB 的做法补 0。
    public var raw48: [UInt8] = []

    /// PostAction（Clipboard 69 / ClipboardPush 79 / ClipboardAsk 78）：与 Machine1 共用 offset 16。
    ///
    /// 对齐 PowerToys `DATA.cs` 的联合区布局：
    ///   `[FieldOffset(4 + 3*4 = 16)] ClipboardPostAction PostAction`
    /// 取值见 `ClipboardPostAction.cs`：**Other = 0, Desktop = 1, Mspaint = 2**。
    /// 语义（接收端 `ReceiveAndProcessClipboardDataCore`）：
    ///   - `desktop` —— 把收到的文件存到 `%USERPROFILE%\Desktop\MouseWithoutBorders\`
    ///     并打开该文件夹（**这就是拖放传文件的落点**）；
    ///   - `mspaint` —— 屏幕截图，直接丢进画图；
    ///   - `other`   —— 存到 MWB 自己的存储目录，并把文件放进剪贴板的文件拖放列表。
    public var postAction: UInt32 = 0

    public var machineName: String = ""

    public init(type: PackageType, id: UInt32 = 0, src: UInt32 = 0, des: UInt32 = 0) {
        self.type = type
        self.id = id
        self.src = src
        self.des = des
    }

    /// 是否大包（含 32 字节机器名）。对齐稳定协议 IsBigPacket。
    public var isBig: Bool { DataPacket.isBigType(type) }

    public static func isBigType(_ t: PackageType) -> Bool {
        switch t.rawValue {
        case 3, 21, 20, 51, 126, 127,          // Hello,Awake,Heartbeat,HeartbeatEx,Handshake,Ack
             79, 69, 78, 125, 124, 76:          // Clipboard 系列
            return true
        default:
            return (t.rawValue & 128) != 0      // Matrix 位
        }
    }

    /// 是否为「数据整段铺在 byte16..63」的剪贴板包（不带机器名）。
    public var isClipboardPayload: Bool {
        type == .clipboardText || type == .clipboardImage
    }

    public var serializedSize: Int { isBig ? DataPacket.bigSize : DataPacket.smallSize }
}

// MARK: - 序列化 / 反序列化

extension DataPacket {
    /// 将包序列化为 32 或 64 字节（小端）。魔数/校验和由发送方 StampPacket 填充。
    public func serialize() -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: serializedSize)

        // byte0 = Type（单字节），byte1..3 留给校验和/魔数
        buf[0] = UInt8(truncatingIfNeeded: type.rawValue)

        writeInt32(buf: &buf, offset: 4, value: Int32(bitPattern: id))
        writeInt32(buf: &buf, offset: 8, value: Int32(bitPattern: src))
        writeInt32(buf: &buf, offset: 12, value: Int32(bitPattern: des))

        if type == .mouse {
            writeInt32(buf: &buf, offset: 16, value: mouseX)
            writeInt32(buf: &buf, offset: 20, value: mouseY)
            writeInt32(buf: &buf, offset: 24, value: mouseWheel)
            writeInt32(buf: &buf, offset: 28, value: mouseFlags)
        } else if type == .keyboard {
            writeInt64(buf: &buf, offset: 16, value: dateTime)
            writeInt32(buf: &buf, offset: 24, value: keyVk)
            writeInt32(buf: &buf, offset: 28, value: keyFlags)
        } else if type == .handshake || type == .handshakeAck {
            writeInt32(buf: &buf, offset: 16, value: Int32(bitPattern: machine1))
            writeInt32(buf: &buf, offset: 20, value: Int32(bitPattern: machine2))
            writeInt32(buf: &buf, offset: 24, value: Int32(bitPattern: machine3))
            writeInt32(buf: &buf, offset: 28, value: Int32(bitPattern: machine4))
        } else if type == .clipboard || type == .clipboardPush || type == .clipboardAsk {
            // 剪贴板通道头包：offset 16 = PostAction（与 Machine1 共用联合区）。
            writeInt32(buf: &buf, offset: 16, value: Int32(bitPattern: postAction))
        } else if isClipboardPayload {
            // 数据从 byte16 起铺满 48 字节；不足部分保持 0（与 PowerToys 的 Array.Clear + 短拷一致）。
            for i in 0..<min(48, raw48.count) { buf[16 + i] = raw48[i] }
        }

        if isBig {
            // 剪贴板数据包：byte32..63 已被数据占用，绝不能写机器名。
            // ClipboardDataEnd(76)：纯结束标记，payload 全 0，也不写机器名。
            if !isClipboardPayload && type != .clipboardDataEnd {
                let nameBytes = encodeMachineName(machineName)
                for i in 0..<32 { buf[32 + i] = nameBytes[i] }
            }
        }
        return buf
    }

    /// 从解密后的明文字节解析包。调用方需保证已通过 ValidatePacket（魔数/校验和）。
    public static func parse(_ bytes: [UInt8]) -> DataPacket? {
        guard bytes.count == smallSize || bytes.count == bigSize else { return nil }

        let typeRaw = UInt32(bytes[0])
        let type = PackageType(rawValue: typeRaw)
        guard type.rawValue != 0, type.rawValue != 0xFF else { return nil }

        var p = DataPacket(type: type)
        p.id = UInt32(bitPattern: readInt32(bytes: bytes, offset: 4))
        p.src = UInt32(bitPattern: readInt32(bytes: bytes, offset: 8))
        p.des = UInt32(bitPattern: readInt32(bytes: bytes, offset: 12))

        if type == .mouse {
            p.mouseX = readInt32(bytes: bytes, offset: 16)
            p.mouseY = readInt32(bytes: bytes, offset: 20)
            p.mouseWheel = readInt32(bytes: bytes, offset: 24)
            p.mouseFlags = readInt32(bytes: bytes, offset: 28)
        } else if type == .keyboard {
            p.dateTime = readInt64(bytes: bytes, offset: 16)
            p.keyVk = readInt32(bytes: bytes, offset: 24)
            p.keyFlags = readInt32(bytes: bytes, offset: 28)
        } else if type == .handshake || type == .handshakeAck {
            p.machine1 = UInt32(bitPattern: readInt32(bytes: bytes, offset: 16))
            p.machine2 = UInt32(bitPattern: readInt32(bytes: bytes, offset: 20))
            p.machine3 = UInt32(bitPattern: readInt32(bytes: bytes, offset: 24))
            p.machine4 = UInt32(bitPattern: readInt32(bytes: bytes, offset: 28))
        } else if type == .clipboard || type == .clipboardPush || type == .clipboardAsk {
            p.postAction = UInt32(bitPattern: readInt32(bytes: bytes, offset: 16))
        }

        if p.isClipboardPayload && bytes.count == bigSize {
            p.raw48 = Array(bytes[16..<64])
        }

        if bytes.count == bigSize {
            // 剪贴板数据包不解析机器名（那 32 字节是数据）
            if !p.isClipboardPayload {
                p.machineName = decodeMachineName(Array(bytes[32..<64]))
            }
        }
        return p
    }
}

// MARK: - 字节工具

private func encodeMachineName(_ name: String) -> [UInt8] {
    // 取前 32 个 ASCII 字符，右侧空格补齐。
    var bytes = [UInt8](name.utf8.prefix(32))
    while bytes.count < 32 { bytes.append(UInt8(ascii: " ")) }
    return bytes
}

private func decodeMachineName(_ bytes: [UInt8]) -> String {
    var end = bytes.count
    while end > 0, bytes[end - 1] == UInt8(ascii: " ") { end -= 1 }
    return String(bytes: bytes[0..<end], encoding: .ascii) ?? ""
}

private func writeInt32(buf: inout [UInt8], offset: Int, value: Int32) {
    withUnsafeBytes(of: value.littleEndian) { ptr in
        for i in 0..<4 { buf[offset + i] = ptr[i] }
    }
}

private func writeInt64(buf: inout [UInt8], offset: Int, value: Int64) {
    withUnsafeBytes(of: value.littleEndian) { ptr in
        for i in 0..<8 { buf[offset + i] = ptr[i] }
    }
}

private func readInt32(bytes: [UInt8], offset: Int) -> Int32 {
    var v: UInt32 = 0
    for i in 0..<4 { v |= UInt32(bytes[offset + i]) << (8 * i) }
    return Int32(bitPattern: v)
}

private func readInt64(bytes: [UInt8], offset: Int) -> Int64 {
    var v: UInt64 = 0
    for i in 0..<8 { v |= UInt64(bytes[offset + i]) << (8 * i) }
    return Int64(bitPattern: v)
}
