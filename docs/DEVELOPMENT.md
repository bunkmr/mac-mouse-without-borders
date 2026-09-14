# MWB Mac Client

一个用 **Swift** 编写的 macOS 客户端，对接 Windows 端的 **Mouse Without Borders**（PowerToys 内置）。
让你的 Mac 作为 MWB mesh 中的一个双向节点：**Windows 与 Mac 的键鼠相互控制、剪贴板文本同步、文件互相拖放传输**。

> 为什么用 Swift 而不是 C#：MWB 协议本质上就是“socket 上的一串字节”，与语言无关；
> 而 Mac 端注入/捕获输入必须调用 CoreGraphics，用 Swift 直接调最干净，无需 C# P/Invoke 桥接，
> 也能直接产出原生 `.app`。

> **文件传输不带任何自建协议。** 走的是 MWB 自己的原生剪贴板/文件通道
> （主通道端口 - 1），Windows 端不需要装任何额外程序或脚本。

---

## 已实现 / 待完成

| 模块 | 状态 | 说明 |
|------|------|------|
| TCP 连接 + 加密握手 | ✅ | 实测 legacy 方案：AES-256-CBC，PBKDF2-HMAC-**SHA1**(50000)，**固定** salt/IV，无明文 salt+IV 头 |
| 包编解码 (32/64 字节) | ✅ | 逐字节对齐 PowerToys `App/Core`；4 字节 `Type`、16 字节联合区、32 字节机器名 |
| 鼠标注入 (移动/按键/滚轮) | ✅ | `CGEventPost`（需辅助功能/输入监控授权） |
| 键盘注入 | ✅ | Windows VK → Mac keycode 映射 |
| 本地输入捕获（反向控制 Win） | ✅ | `CGEventTap`（需授权） |
| 光标锁定 / 边缘切换 | ✅ | 控制远端时**隐藏**本机光标（`CGDisplayHideCursor` + **私有属性 `SetsCursorInBackground` 解锁**，100Hz 事件级重申）+ 事件坐标改写钉在锚点；判据 `CGCursorIsVisible()`，自检实测 **隐藏采样 100%、最大偏移 0px**；详见下文 |
| 剪贴板文本同步 | ✅ | 双通道：`ClipboardText(124)` 分片 + 变化通知 `Clipboard(69)` |
| **文件拖放（Mac → Windows）** | ✅ | 主通道发 `ClipboardDragDrop(70)`+`ClipboardDragDropOperation(75)`，再补发远端鼠标抬起；对端回连本机 15100 拉文件 |
| **文件拖放（Windows → Mac）** | ✅ | 对端发拖放信令 → 本机**本地左键抬起**时反向去对端 15100 拉取 → 落 `~/Desktop/MouseWithoutBorders/`，并**自动在 Finder 中打开该目录、选中文件**；2026-09-14 实拖通过（含中文名、Windows 反斜杠路径正确取到文件名） |
| 边缘投放带 UI | ✅ | 拖文件到屏幕边缘（left/right）松手即发送 |
| Finder 复制即传（Cmd+C） | ✅ | 监听剪贴板文件变化，自动走同一条原生通道 |
| UI | ✅ | 菜单栏图标 + 极简配置窗（SwiftUI） |

---

## 协议要点（逐字节核对 PowerToys 源码 + 实机验证）

### 端口（`SocketStuff.cs`）
- **主通道 = `TcpPort + 1`**（本机为 **15101**）：握手、键鼠、心跳、剪贴板文本、**拖放信令**。
- **剪贴板/文件通道 = `TcpPort`**（本机为 **15100**，即主通道 − 1）：`Clipboard.ShakeHand` + 文件字节。

### 加密（见 `Crypto.swift` 顶部）
- 密钥 = `PBKDF2-HMAC-SHA1(UTF8(安全密钥), UTF16LE("18446744073709551615"), 50000) → 32B AES-256`。
  （注意是 **SHA1/50000**，社区文档常写成 SHA512/100000，那是新版尚未发布的方案。）
- IV = ASCII `"1844674407370955"`，固定，收发共用；**没有**明文 salt+IV 头交换。
- 连接建立后先互发 **16 字节随机块**预热 CBC 链，之后首包才开始。
- AES-256-CBC，无填充；**链式状态跨包连续**（每个方向各一条链，对齐 .NET `CryptoStream`）。

### 包结构
```
偏移 0 : Type (4 字节 = byte0 包类型 | byte1 校验和 | byte2..3 魔数)   ← 见下方「最大的坑」
偏移 4 : Id  (4)     偏移 8 : Src (4)     偏移 12: Des (4)
偏移 16: 联合区 16 字节（鼠标/键盘/PostAction/Machine1..4 共用）
偏移 32: 机器名 32 字节（ASCII 空格补齐，**仅大包**；小包只有 32 字节）
```
- 小包 32 字节，大包 64 字节。
- `Des = 255 (ID.ALL)` 才是广播；**不是 0xFFFFFFFF**（`ID : uint { NONE=0, ALL=255 }`）。
- 包类型：`Mouse=123 Keyboard=122 Hello=3 Heartbeat=20 Handshake=126 Clipboard=69
  ClipboardDragDrop=70 ClipboardDragDropEnd=71 ClipboardDragDropOperation=75
  MachineSwitched=77 ClipboardAsk=78 ClipboardPush=79 ClipboardText=124 Matrix=128`。

### ⚠️ 最大的坑：`Type` 是 **4 字节**，两个通道对「魔数盖章」的要求**相反**
- 主通道走 `TcpSendData`/`TcpReceiveData`，会**盖**魔数+校验和到 byte1..3；
  对端 `ProcessReceivedDataEx` 会校验并把 byte1..3 清零。→ **主通道必须盖章。**
- 剪贴板通道的 `Clipboard.ShakeHand` 是**直接** `enStream.Write(package.Bytes, 0, 64)`，
  **绕过** `TcpSendData`，线路上 byte1..3 = 0。而接收端 `DATA.Type` 是 4 字节枚举，
  于是 `Type = bytes[0] | b1<<8 | b2<<16 | b3<<24`。
  → **剪贴板通道头包绝不能盖章**，否则 `Type` 变成巨值，
  `package.Type is Clipboard or ClipboardPush` 判定失败，对端打
  `ShakeHand: Unexpected package type` 并**直接 close**。
  - 症状极具欺骗性：**小文件推送会“成功”**（写进内核缓冲），
    只有 ≥ 几十 KB 才会以 `EPIPE (errno=32)` 暴露。

### 剪贴板通道握手（`Clipboard.ShakeHand`，**双方对称、都是先发后收**）
1. 双方各发：16 字节预热块 + 64 字节头包。
2. 头包 `Type`：**数据持有方发 `ClipboardPush(79)`；请求方发 `Clipboard(69)`**；
   `offset 16 = PostAction`（`Other=0/Desktop=1/Mspaint=2`），`offset 32..63 = 机器名`。
3. 交换后各自看「对端发的是哪个」决定谁发谁收。
4. **对端强校验**：`MachinePool.ResolveID(MachineName) == Src && IsConnectedTo(Src)`
   —— 所以机器名必须已在对方机器池里（靠主通道 `Hello`/`Heartbeat_ex` 注册），
   且主通道连接是 Established。任一不满足 → 直接 close。

### 文件数据帧（`SendClipboardData`）
- 固定 **1024 字节头**：UTF-16LE `"{字节数}*{路径}"`，其余补 0。接收端 `ReadEx(header, 0, 1024)` 写死。
- 随后是文件原始字节，**整体补 0 到 16 的整数倍**（CBC 需要）；接收端只认头里声明的字节数。
- 落点：`PostAction=Desktop(1)` → Windows 侧 `%USERPROFILE%\Desktop\MouseWithoutBorders\<文件名>`，
  Mac 侧 `~/Desktop/MouseWithoutBorders/<文件名>`。
- ★ **头里的「路径」是发送方的本地绝对路径，而且 Windows 发来的是反斜杠**
  （实测：`D:\腾讯电脑管家软件搬家\...\安责险全国风险地图（一期）接口文档V1.0.docx`）。
  `NSString.lastPathComponent` **只认 `/`** —— 直接拿它取文件名会把**整条路径**当名字；
  更坑的是 `:` 在 macOS 上合法但 Finder 会**显示成 `/`**，用户看到的就是一条完整路径当文件名。
  所以接收侧必须先把 `\` 归一化成 `/` 再取末段（再把残留的 `:` 换成 `_` 兜底）。
  见 `ClipboardChannel.receiveData()`，日志里有 `原始路径=` 便于复核。

### 拖放时序（`Core/DragDrop.cs`）
- 持有方：`DragDropStep06` → 广播 `ClipboardDragDrop(70)` + 定向 `ClipboardDragDropOperation(75)`。
- 接收方：`Step08` 记下 `LastMachineWithClipboardData`；`Step08_2` 要求
  `Des == 自己的 MachineID` 才置 `IsDropping`（**用 0xFF 广播无效**）。
- 抬起：`Step09` 挂在鼠标钩子上，条件是 `wParam == WM_LBUTTONUP && IsDropping`。
  - ★★ **`InputHook.cs` 里的 `local = (NewDesMachineID == Common.MachineID)` 含义是
    「本机就是投放目标」，不是「事件来自本机输入」。**（这里曾记反，直接导致
    Windows→Mac 拖放整整几轮不通。）因此这次抬起**由投放目标机自己产生**：
    物理抬起和注入抬起都算，但**绝不会**作为鼠标包从对端传过来。
    实现上挂在 `InputController.onLocalLeftMouseUp`（**放在吞事件的守卫之前**，
    否则被吞掉就永远等不到）。
  - ⚠️ 拖拽期间必须**立刻把控制权交回本机**（否则本机的松手事件根本到不了本机），
    但**故意不能补发抬起** —— 补了 Windows 会当成拖拽取消、清掉待传文件；
    等文件真的拉回来之后再补发。
  - Windows→Mac 实测日志链（2026-09-14 通过）：
    `对端进入投放态（ClipboardDragDropOperation）` → `本机松手（本地左键抬起）→ 主动拉取…`
    → `✓ 已收到 安责险全国风险地图（一期）接口文档V1.0.docx` → `已通知对端拖拽结束（补发抬起包）`
    → Finder 自动打开落点目录并选中该文件。

---

## 构建

> ⚠️ 项目位于网络同步卷（Resilio）时，**不要用 `swift build` 默认 `.build`**（写入极慢/卡死）。
> 一律用 `--build-path /tmp/mwbbuild` 把产物放到本地磁盘。

### 推荐：一键构建 + 安装到 /Applications
```bash
cd MWBMacClient
./build_app.sh          # 编译两个 product、组装 bundle、签名、装到 /Applications/MWB.app
open /Applications/MWB.app
```

### 只编命令行测试工具（无界面，验证协议）
```bash
swift build --build-path /tmp/mwbbuild --product mwbmac --disable-sandbox
```
常用模式：
```bash
# 剪贴板通道探针：只做一次 ShakeHand
mwbmac --clip-probe <host> <clipPort> <securityKey> <machineName> <myID>

# 剪贴板通道接受性诊断：握手 + 只发头 + poll，判定【接受】/【拒绝】
mwbmac --clip-diag     <host> <clipPort> <securityKey> <machineName> <myID> <file>
# 坏头诊断：发非法头。连接保持 = 已越过 ShakeHand 校验；被关 = 拒绝在 ShakeHand
mwbmac --clip-diag-bad <host> <clipPort> <securityKey> <machineName> <myID> <file>

# 走原生剪贴板通道推一个文件（PostAction=Desktop）
mwbmac --clip-push     <host> <clipPort> <securityKey> <machineName> <myID> <file>
```

### 端到端自测（GUI 的真实拖放路径，不用鼠标拖）
```bash
MWB_FILEDROP_SELFTEST=/path/to/file open -a /Applications/MWB.app
# 实际是直接跑二进制：env MWB_FILEDROP_SELFTEST=... /Applications/MWB.app/Contents/MacOS/MWBMacClientApp
# 走 sendFiles → FileTransfer.send → signalDragDropToPeer → 补发抬起 → 对端回连 15100 拉文件
```

### 光标锁定自检（不需要手动跨屏，可自动化）
```bash
# 强制进入「控制远端」状态 N 秒再退出，用来验证光标是否真的被隐藏/钉住。
# 锚点取**真正的切换边缘**（不是屏幕中央 —— 那会破坏退出判据的几何假设，
# 结果就是控制态被自己的状态机反复踢出，日志看起来像"隐藏时好时坏"）。
pkill -x MWBMacClientApp
MWB_LOCK_SELFTEST=8 nohup /Applications/MWB.app/Contents/MacOS/MWBMacClientApp \
    >/tmp/mwb_stdout.log 2>&1 &
sleep 3
/tmp/cursorwatch 13        # 见下：进程外的客观判据
```
> ⚠️ **不要用 `launchctl setenv` 注入**（非特权上下文报
> `Not privileged to set domain environment`）；`open --env` 实测也传不进去。
> **直接跑二进制**最可靠。

App 侧通过判据长这样：
`[自检] 锁定自检结束：隐藏采样=100%（245/245） 最大偏移=0px 失守=0次  ✅ 光标隐藏生效`

### ★「光标到底隐没隐」的可靠判据（2026-09-14 重新定性）
| 判据 | 结论 |
|------|------|
| `CGDisplayHideCursor()` 的**返回值** | ❌ **恒为 `.success`，哪怕在后台进程里完全没生效**。绝不能拿它当判据 —— 它骗过了我们整整一轮（日志 `hide=1021次`，用户却看得见光标满屏跑） |
| `screencapture -C` / 区域像素差 / 近白像素计数 | ❌ 本机**同状态**相隔 0.5s 两张图差异可达 **90%**（背景在动）；开着辅助功能缩放时画面还会被放大成像素化色块 |
| ★ **`CGCursorIsVisible()`**（`dlsym` 取符号） | ✅ **可靠**。读的是 WindowServer 里的真实状态，随 hide/show 实时变化。**旧记录里"现代 macOS 上已是空壳、恒返回 0/1、不随 hide/show 变化"是错的** —— 那次多半是在"hide 本来就没生效"的前提下测的，于是误判成它不跟随 |
| 进程内 `CGEvent(source:nil)` / `NSEvent.mouseLocation` | ⚠️ 只能做参考：被自己的 tap（事件坐标改写）污染，合成负载下会明显**低估** |
| 进程外探针 `Tools/cursorprobe.swift` | ✅ 判**位置**用它（先跑对照组自证探针可信） |

两条**独立**判据同时成立才算过：App 内部连续采样的 `隐藏采样=`，加进程外 `Tools/cursorwatch.swift`
的最长连续隐藏时长。2026-09-14 实测两者吻合（100% / 8.13s）。
```bash
swiftc -O Tools/cursorwatch.swift -o /tmp/cursorwatch   # 只读，不改光标状态
swiftc -O Tools/cursorvis.swift   -o /tmp/cursorvis     # 对照实验：裸调 hide vs 先解锁
```

---

## 光标锁定：**隐藏**才是"消失"那一半（位置钉住只是加分项）

控制 Windows 时，本机光标做了两层处理：

1. **位置钉住**（`InputController`）：每帧重申 `CGAssociate(0)`、清零事件设备位移、
   把 `event.location` 改写成锚点后放行，外加 30Hz 兜底 warp。
   自检实测「最大偏移 0px、失守 0 次」；但**合成事件下的位置结论不可外推到真实设备输入**。
2. **隐藏**（`CGDisplayHideCursor`）：★ **这才是用户"看不见光标"的可靠依据**。
   - ⚠️⚠️ **必须先解锁私有属性，否则它返回 success 但完全不生效**：
     ```c
     CGSSetConnectionProperty(_CGSDefaultConnection(), _CGSDefaultConnection(),
                              CFSTR("SetsCursorInBackground"), kCFBooleanTrue);
     ```
     Apple 对 `CGDisplayHideCursor` 的文档原话是 *"In most cases, the caller must be the
     **foreground application** to affect the cursor"* —— 我们是 `LSUIElement` 的后台菜单栏应用，
     永远不在前台，于是 hide 一直被系统**静默丢弃**。
     **这就是「日志里 hide 上千次、光标照样跟着 Windows 满屏跑」的真正根因。**
     `CGAssociateMouseAndMouseCursorPosition` 也吃同一个前台限制（文档是同款措辞）。
     实现见 `Sources/MWBMacClientCore/CursorBackgroundControl.swift`（`enableOnce()` 幂等，
     在第一次 hide 之前自动执行）。
   - **100Hz（10ms 节流）重申** + 每个鼠标事件前再重申一次。频率**不能降**：
     系统会在真实设备输入时把光标重新显示，而事件到达率是 100~1000Hz，
     重申低于它就会出现「连续移动时全程可见」（第一轮回归就是把它"优化"成了 2Hz）。
   - ⚠️ **它是计数式的**：调 N 次必须 show N 次，否则**光标永久消失**
     （deskflow #7935 就是"藏得住、恢复不回来"的真实用户级事故）。
     代码里自己记账（`hideCursorCount`），并在**所有**退出路径按账本冲销：
     `releaseCursor()`、**`leaveRemote()`（独立路径，最易漏）**、`stopCapture()`、
     `applicationWillTerminate`、**SIGTERM 处理器**（`kill` 不走 willTerminate）。
   - 验证看**日志**：`光标锁定: ... 可见性=已隐藏 隐藏采样=100%（245/245）`。
     **别用截图验收**（本机截图不可信，见上）。

---

## 连接阶段看门狗（对端静默时不再永久挂死）

`SO_RCVTIMEO` **对 `NSInputStream` 不生效**（`CFStreamCreatePairWithSocket` 拿到的流走 NSStream 自己的读路径）。
所以对端接受 TCP 却不回握手时（Windows 端 MWB 主线程卡住 / 遗留半开会话），
进程会**无限期阻塞在 read 上**，界面永远停在「连接中…」，既不报错也不重连。

现在 `Client.armConnectWatchdog()` 会在连接/重连时起 15s 一次性看门狗，超时就
`connection.close()`（内部 `shutdown(SHUT_RDWR)` 会立刻唤醒阻塞 read）→ 走既有退避重连。
日志会打 `✗ 连接阶段超时（15s 内未完成握手…）`。

> 现场特征：`nc -z` 探测 15101/15100 **都通**（监听线程活着）、ping 可能不通（Windows 默认拦 ICMP），
> 但握手就是拿不到响应。**处理办法：去 Windows 上重启 Mouse Without Borders**，Mac 端会自动重连。

---

## 运行授权（重要）

macOS 捕获/注入全局输入需要：
- **系统设置 → 隐私与安全性 → 辅助功能**：勾选 MWB。
- **系统设置 → 隐私与安全性 → 输入监控**：勾选 MWB。

未授权时 `CGEventPost` / `CGEventTap` 会静默失效（控制无效但程序照常运行）。
另外 **macOS 15+ 访问局域网** 还需要「本地网络」权限（`Info.plist` 里的
`NSLocalNetworkUsageDescription`），否则连接被静默拒绝。

`build_app.sh` 用**固定自签名证书**（MWB Local Signer）签名：
用 ad-hoc 签名时 cdhash 每次编译都变，TCC 会当成另一个程序，导致“勾了还是未授权”。

---

## 已知限制 / 下一步

1. **Windows → Mac 方向的文件拖放**：✅ **2026-09-14 实拖通过**（中文文件名、Windows 反斜杠路径均正确）。
   - **落点：`~/Desktop/MouseWithoutBorders/<文件名>`**（重名自动加 ` (1)`、` (2)`…，不覆盖）。
     落盘后会自动在 **Finder 中打开该目录并选中刚收到的文件**（对齐 PowerToys 的 `desktop` 分支）。
   - 触发链（本机角色 = **投放目标**）：
     Windows 拖起文件 → 广播 `ClipboardDragDrop(70)` + 定向 `ClipboardDragDropOperation(75)`
     → 本机 `peerIsDropping = true`，**并立刻把控制权交回本机**（否则松手事件到不了本机）
     → **本机自己的一次本地左键抬起**（`onLocalLeftMouseUp`）
     → 反向连 `Windows:15100` 发 `Clipboard(69)` 拉取（`fetchFile`）→ 落盘 → 补发抬起包收尾。
     ⚠️ 关键：抬起是**发生在投放目标机（本机）上的事件**，不是从对端传来的鼠标包。
     `InputHook.cs` 里 `local = (NewDesMachineID == Common.MachineID)` 指的是「本机是投放目标」，
     曾被记反成"只对远端注入事件生效"，直接导致这个方向几轮不通。
   - ⚠️ **前置：Windows 侧 MWB 必须勾选「传递文件 / TransferFile」** ——
     `DragDropStep01()` 第一句就是 `if (!Setting.Values.TransferFile) return;`，
     不勾的话 Windows **根本不会发**拖放信令，Mac 侧会表现为"拖过去毫无反应"。
   - ⚠️ 两个 Windows 侧硬限制：**目录不能拖**（`SendClipboardData` 只发
     `"... - Folder is not supported, zip it first!"` 的提示头）、**一次只能一个文件**
     （`LastDragDropFile` 是单值字符串）。要传多个/目录请从 Mac→Windows 或先打包。
   - ⚠️ 若 Windows 开了 `OneWayClipboardMode`（单向剪贴板），对端会直接 close。
   - 排错看这几行日志：`对端 X 开始拖拽文件（ClipboardDragDrop）`、
     `对端进入投放态（ClipboardDragDropOperation）`、`本机松手（本地左键抬起）→ 主动拉取…`、
     `✓ 已收到 X → /Users/.../Desktop/MouseWithoutBorders/X`、
     `已打开所在文件夹并在 Finder 中选中该文件`。
     只到「开始拖拽」就断了 → Windows 没发 `Operation(75)`（多半「传递文件」没勾）；
     到了「进入投放态」却等不到松手 → 本机左键抬起没被接住（检查
     `onLocalLeftMouseUp` 是否被吞事件逻辑挡掉）。
2. **键码映射**：`InputController` 覆盖常见键，特殊键（多媒体、IME 等）需扩充。
3. **机器 ID / 矩阵**：Mac 默认固定 ID=2；需在 Windows 端 MWB 设置里把 Mac 加入布局。
4. **大文件速率**：8 MB ≈ 16 s（≈0.5 MB/s），瓶颈在纯 Swift AES-CBC 加密，后续可换 CommonCrypto 批量流。
5. **多文件/目录**：MWB 原生协议一次只传**一个**文件（`LastDragDropFile` 是单个字符串），
   多文件/目录会先 `ditto` 打包成一个文件再发。
6. ⚠️ **主通道必须在线**：剪贴板通道的门控是 `ResolveID(name)==Src && IsConnectedTo(Src)`，
   而 `IsConnectedTo` 查的是**主通道的活动 socket**。所以 MWB 一旦断开（或 GUI 没运行），
   剪贴板/文件通道会**立刻开始拒绝**（症状是推送报 `EPIPE`）。
   用命令行工具单测剪贴板通道时，**GUI 必须是运行状态**。

7. ⚠️ **CLI 单测的 `<machineName>` 必须和 GUI 注册的名字逐字节相同**。
   门控里 `ResolveID(name)` 是在**对端机器池**里按名字查 ID，名字对不上就查不到 → 直接拒。
   GUI 用的是 `SCDynamicStoreCopyLocalHostName`（即 `scutil --get LocalHostName`），
   在**本机就是 `MacBook-Pro-2`**（不是 `scutil --get ComputerName` 的 `MacBook Pro`，
   也不是 `hostname` 的 `MacBook-Pro-2.local`）。
   拿错名字的现象和「主通道没在线」**一模一样**（都是 `EPIPE errno=32`），排查时先核对这一点。

   本机可用的完整实测参数：
   ```bash
   # 机器名取 LocalHostName；myID=2 是 Windows 端 MWB 给本 Mac 分配的 ID
   ./bin/mwbmac --clip-push 192.168.1.100 15100 '你的安全密钥' \
                "$(scutil --get LocalHostName)" 2 /path/to/file
   ```

---

## 目录结构
```
MWBMacClient/
├── Package.swift
├── build_app.sh            # 构建 + 签名 + 安装到 /Applications
├── start_mwb.sh
├── App/                    # 打包资源（不进 SwiftPM 编译）
│   ├── Info.plist
│   └── make_icon.py
├── Sources/
│   ├── MWBMacClientCore/   # 协议/加密/连接/输入/剪贴板/文件（核心）
│   │   ├── Protocol.swift          # 包结构与序列化（32/64 字节）
│   │   ├── Crypto.swift            # PBKDF2 + AES-CBC + 魔数/校验和
│   │   ├── Connection.swift        # 主通道连接 + 握手 + magic 自校准
│   │   ├── Listener.swift          # 接受 Windows 回连（主通道）
│   │   ├── InputController.swift   # CGEventTap / CGEventPost + 光标锁定
│   │   ├── ClipboardSync.swift     # 剪贴板文本分片收发
│   │   ├── ClipboardChannel.swift  # ★ MWB 原生剪贴板/文件通道（ShakeHand/收发文件）
│   │   ├── FileTransfer.swift      # 文件准备（打包）+ 对接原生通道
│   │   ├── MachineMatrix.swift     # 机器矩阵同步
│   │   ├── EdgeDropPanel.swift     # 屏幕边缘投放带
│   │   └── Client.swift            # 总装：连线、包分发、拖放信令
│   ├── mwbmac/             # 无界面测试/诊断入口
│   │   └── main.swift
│   └── MWBMacClientApp/    # 菜单栏 App
│       ├── MWBMacClientApp.swift
│       ├── AppDelegate.swift
│       ├── ContentView.swift
│       └── MWBLogView.swift
├── Tools/                  # 【已废弃】旧的自建协议接收端，仅作历史留存
└── README.md
```
