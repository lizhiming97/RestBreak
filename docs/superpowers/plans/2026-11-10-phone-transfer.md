# 手机互传（LocalSend 协议）Implementation Plan

状态：未开始（做完一步就把对应的 `- [ ]` 打勾）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 星期五用 Swift 实现 LocalSend 协议 v2，手机装官方 LocalSend（鸿蒙用卓易通装安卓版）就能和 Mac 互传文件和文字，带传输记录。

**Architecture:** 新文件夹 `RestBreak/RestBreak/Transfer/`。纯逻辑（协议结构、文件名、记录、流式 HTTP 解析、接收会话）各自一个文件，单独测试；网络层是 `LocalSendServer`（NWListener，HTTP 接收）、`LocalSendDiscovery`（BSD UDP 组播 + DispatchSource）、`LocalSendClient`（URLSession，对接手机的 HTTPS 自签名证书）；`TransferCoordinator` 串起来，接灵动岛、剪贴板、记录和休息状态。设计：`docs/superpowers/specs/2026-11-10-phone-transfer-design.md`。

**Tech Stack:** Swift 6、SwiftUI/AppKit、Network.framework、Darwin socket、CryptoKit、URLSession、Swift Testing。不加第三方依赖。

---

## 通用约定

- 工程用文件夹同步（`PBXFileSystemSynchronizedRootGroup`）：在 `RestBreak/RestBreak/Transfer/`、`RestBreak/RestBreakTests/` 里新建文件会自动加入对应 target，不用改工程文件。
- 下文 `<项目>` = `/Users/lizhiming/Desktop/lizhiming/个人项目验证/桌面闹钟/有趣的项目--桌面提醒工具`。
- **跑某个测试**（`<Suite>` 换成测试结构体名）：
  ```bash
  cd "<项目>/RestBreak" && DD="$HOME/Library/Developer/Xcode/DerivedData/RestBreak-xieyihui-spike" && xcodebuild test -scheme RestBreak -destination platform=macOS -derivedDataPath "$DD" -allowProvisioningUpdates -only-testing:RestBreakTests/<Suite> 2>&1 | tail -25
  ```
  通过时末尾有 `** TEST SUCCEEDED **`；新代码还没写时是编译失败（`cannot find ... in scope`），也算「先失败」。
- 代码注释用通俗中文（用户不熟 Swift）。UI 类标 `@MainActor`。
- 提交信息结尾加 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。在本地 `main` 上提交，**绝不 `git push origin main`**。

## 文件结构

| 文件 | 职责 |
|---|---|
| Create `RestBreak/RestBreak/Transfer/LocalSendProtocol.swift` | 协议常量、设备信息 / 文件清单 JSON 结构、`NearbyDevice`、`LANAddress` |
| Create `RestBreak/RestBreak/Transfer/LocalSendDiscovery.swift` | UDP 组播收发 |
| Create `RestBreak/RestBreak/Transfer/TransferPaths.swift` | 文件名清洗、重名加序号、发送时展开文件夹（`OutgoingFile`） |
| Create `RestBreak/RestBreak/Transfer/TransferStore.swift` | 信任设备、手动地址、传输记录（30 天） |
| Create `RestBreak/RestBreak/Transfer/HTTPStreamReader.swift` | 边收边解析 HTTP 请求（头 + 定长 / 分块请求体） |
| Create `RestBreak/RestBreak/Transfer/ReceiveSession.swift` | 一次接收的令牌、进度、状态 |
| Create `RestBreak/RestBreak/Transfer/LocalSendServer.swift` | HTTP 接收端 + 每条连接 + 写文件 |
| Create `RestBreak/RestBreak/Transfer/LocalSendClient.swift` | 发送端（register / prepare-upload / upload / cancel，证书指纹） |
| Create `RestBreak/RestBreak/Transfer/TransferFolder.swift` | 保存位置：选文件夹、安全书签 |
| Create `RestBreak/RestBreak/Transfer/TransferCoordinator.swift` | 总调度：询问、收文字、记录、灵动岛、发送流程 |
| Create `RestBreak/RestBreak/Transfer/TransferSettingsPage.swift` | 设置「手机互传」页（设置 / 记录） |
| Modify `RestBreak/RestBreak/Services/LocalMCP.swift` | `HTTPReply` 补 204/409/422/500 的说明文字 |
| Modify `RestBreak/RestBreak/UI/NotchIsland.swift` | 加 `update(key:_:)`，实现 `IslandPresenting` |
| Modify `RestBreak/RestBreak/App/ReminderCoordinator.swift` | `island` 改为可共用 |
| Modify `RestBreak/RestBreak/App/BreakCoordinator.swift` | 持有 `transfer`、启动、休息结束通知 |
| Modify `RestBreak/RestBreak/App/RestBreakApp.swift` | 打开设置页回调、退出时停 |
| Modify `RestBreak/RestBreak/UI/SettingsWindow.swift` | 新页面「手机互传」+ 分段 |
| Modify `RestBreak/RestBreak/UI/StatusBarController.swift` | 菜单「发送到手机…」+ 拖文件到图标 |
| Modify `RestBreak/RestBreak.xcodeproj/project.pbxproj` | `INFOPLIST_KEY_NSLocalNetworkUsageDescription` |
| Create `RestBreak/RestBreakTests/TransferTestSupport.swift` 及各 `*Tests.swift` | 测试 |

---

### Task 1: 协议数据结构

**Files:**
- Create: `RestBreak/RestBreak/Transfer/LocalSendProtocol.swift`
- Create: `RestBreak/RestBreakTests/TransferTestSupport.swift`
- Test: `RestBreak/RestBreakTests/TransferProtocolTests.swift`

- [ ] **Step 1: 写测试辅助和失败的测试**

`RestBreak/RestBreakTests/TransferTestSupport.swift`：

```swift
import Foundation
import Testing
@testable import RestBreak

/// 手机互传测试共用：等某个条件成立（网络回调是异步的）
@MainActor
func transferWait(timeout: Duration = .seconds(3), _ condition: () -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !condition() {
        guard clock.now < deadline else {
            Issue.record("等待超时")
            return
        }
        try await Task.sleep(for: .milliseconds(20))
    }
}

/// 每个测试一个临时文件夹
func transferTempFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("friday-transfer-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// 假装是手机
let phoneInfo = LSDeviceInfo(alias: "华为手机", version: "2.0", deviceModel: "HUAWEI", deviceType: "mobile",
                             fingerprint: "phone", port: 53317, protocol: "https", download: false)
```

`RestBreak/RestBreakTests/TransferProtocolTests.swift`：

```swift
import Foundation
import Testing
@testable import RestBreak

struct TransferProtocolTests {
    @Test func 解码喊话_忽略不认识的字段() throws {
        let json = #"{"alias":"Nice Orange","version":"2.0","deviceModel":"HUAWEI","deviceType":"mobile","fingerprint":"abc","port":53317,"protocol":"https","download":true,"announce":true,"extra":1}"#
        let info = try JSONDecoder().decode(LSDeviceInfo.self, from: Data(json.utf8))
        #expect(info.alias == "Nice Orange")
        #expect(info.announce == true)
        #expect(info.protocol == "https")
        #expect(info.port == 53317)
    }

    @Test func 编码时不写空字段() throws {
        let info = LSDeviceInfo(alias: "星期五", version: "2.1", fingerprint: "f")
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(info)) as? [String: Any]
        #expect(Set(object?.keys.map { $0 } ?? []) == ["alias", "version", "fingerprint"])
    }

    @Test func 识别手机发来的文字() {
        let text = LSPrepareUploadRequest(info: phoneInfo, files: [
            "1": LSFileMeta(id: "1", fileName: "a.txt", size: 5, fileType: "text/plain", preview: "hello"),
        ])
        #expect(text.message == "hello")
        let file = LSPrepareUploadRequest(info: phoneInfo, files: [
            "1": LSFileMeta(id: "1", fileName: "a.txt", size: 5, fileType: "text/plain"),
        ])
        #expect(file.message == nil)
        let two = LSPrepareUploadRequest(info: phoneInfo, files: [
            "1": LSFileMeta(id: "1", fileName: "a.txt", size: 5, fileType: "text/plain", preview: "a"),
            "2": LSFileMeta(id: "2", fileName: "b.jpg", size: 9, fileType: "image/jpeg"),
        ])
        #expect(two.message == nil)
        #expect(two.totalSize == 14)
    }

    @Test func 设备地址() {
        let device = NearbyDevice(info: LSDeviceInfo(alias: "p", version: "2.0", fingerprint: "f", port: 53318, protocol: "https"),
                                  host: "192.168.1.8")
        #expect(device.url("upload", query: ["sessionId": "s", "fileId": "a b"]).absoluteString
                == "https://192.168.1.8:53318/api/localsend/v2/upload?fileId=a%20b&sessionId=s")
        let bare = NearbyDevice(info: LSDeviceInfo(alias: "p", version: "2.0", fingerprint: "f"), host: "10.0.0.2")
        #expect(bare.https)
        #expect(bare.port == 53317)
        #expect(NearbyDevice(info: LSDeviceInfo(alias: "p", version: "2.0", fingerprint: "f", protocol: "http"), host: "10.0.0.2").https == false)
    }

    @Test func 只认局域网地址() {
        for host in ["192.168.1.2", "10.1.2.3", "172.20.10.2", "127.0.0.1", "169.254.3.4"] {
            #expect(LANAddress.isLocal(host), "\(host)")
        }
        for host in ["8.8.8.8", "172.32.0.1", "abc", "::1", "192.168.1"] {
            #expect(!LANAddress.isLocal(host), "\(host)")
        }
    }
}
```

- [ ] **Step 2: 跑测试，确认失败**（`<Suite>` = `TransferProtocolTests`）。预期：编译失败，`cannot find 'LSDeviceInfo' in scope`。

- [ ] **Step 3: 写实现**

`RestBreak/RestBreak/Transfer/LocalSendProtocol.swift`：

```swift
import Foundation

// 手机互传（2026-11-10）：按 LocalSend 协议 v2（https://github.com/localsend/protocol）自己实现，
// 手机上装官方 LocalSend 就能和星期五互传。LocalSend 是 Apache-2.0，这里只照协议文档写，没有复制它的代码。
// 这个文件只有数据结构，不碰网络，方便测试。

enum LocalSend {
    /// 默认端口：TCP 收文件、UDP 组播发现都用它
    static let port: UInt16 = 53317
    /// 组播地址（官方说有些安卓手机只认 224.0.0.x）
    static let multicastHost = "224.0.0.167"
    /// 我们实现的协议版本
    static let version = "2.1"
    static let apiPrefix = "/api/localsend/v2/"
}

/// 设备信息：组播喊话、register、prepare-upload 里的 info 都是这一个结构，各自用到的字段不同，用不到的为 nil
struct LSDeviceInfo: Codable, Equatable, Sendable {
    var alias: String
    var version: String
    var deviceModel: String?
    var deviceType: String?
    /// HTTPS 时是证书的 SHA-256；HTTP 时是一个随机字符串。用来认出「同一台设备」、不发现自己
    var fingerprint: String
    var port: Int?
    /// "http" / "https"；没写按 https
    var `protocol`: String?
    var download: Bool?
    /// 组播里才有：true = 刚上线在喊话，别人要回应；false = 回应
    var announce: Bool?
}

/// 文件清单里的一个文件
struct LSFileMeta: Codable, Equatable, Sendable {
    var id: String
    /// 可能带相对路径（发文件夹时，如「相册/a.jpg」）
    var fileName: String
    var size: Int64
    var fileType: String
    var sha256: String?
    /// 发文字时文字内容放在这里
    var preview: String?
}

struct LSPrepareUploadRequest: Codable, Equatable, Sendable {
    var info: LSDeviceInfo
    var files: [String: LSFileMeta]

    /// 手机「发文字」：只有一个纯文本文件，文字在 preview 里（官方收到后回 204，不再传文件）
    var message: String? {
        guard files.count == 1, let file = files.values.first, let text = file.preview,
              file.fileType == "text" || file.fileType.hasPrefix("text/plain") else { return nil }
        return text
    }

    var totalSize: Int64 { files.values.reduce(0) { $0 + max(0, $1.size) } }
}

struct LSPrepareUploadResponse: Codable, Equatable, Sendable {
    var sessionId: String
    /// 文件 id → 这个文件的上传令牌（只包含同意接收的文件）
    var files: [String: String]
}

/// 附近的一台 LocalSend 设备（发文件时要用它的地址）
struct NearbyDevice: Equatable, Identifiable, Sendable {
    var fingerprint: String
    var alias: String
    var deviceModel: String?
    var host: String
    var port: Int
    var https: Bool
    var id: String { fingerprint }

    init(fingerprint: String, alias: String, deviceModel: String? = nil, host: String, port: Int, https: Bool) {
        self.fingerprint = fingerprint
        self.alias = alias
        self.deviceModel = deviceModel
        self.host = host
        self.port = port
        self.https = https
    }

    /// 从对方的设备信息 + 来源 IP 得到；对方没写端口用默认端口，没写协议按 https
    init(info: LSDeviceInfo, host: String) {
        self.init(fingerprint: info.fingerprint, alias: info.alias, deviceModel: info.deviceModel, host: host,
                  port: info.port ?? Int(LocalSend.port), https: (info.protocol ?? "https") != "http")
    }

    /// 对方某个接口的地址，如 url("upload", query: [...])
    func url(_ route: String, query: [String: String] = [:]) -> URL {
        var components = URLComponents()
        components.scheme = https ? "https" : "http"
        components.host = host
        components.port = port
        components.path = LocalSend.apiPrefix + route
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return components.url!
    }

    /// 菜单、设置页里显示：「别名（型号）」
    var displayName: String { deviceModel.map { "\(alias)（\($0)）" } ?? alias }
}

enum LANAddress {
    /// 只和局域网 / 本机地址打交道：10/8、172.16/12、192.168/16、169.254/16、127/8
    static func isLocal(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false).compactMap { UInt8($0) }
        guard parts.count == 4 else { return false }
        switch (parts[0], parts[1]) {
        case (10, _), (127, _), (192, 168), (169, 254), (172, 16...31): return true
        default: return false
        }
    }
}
```

- [ ] **Step 4: 跑测试，确认通过**（`TransferProtocolTests`）。预期 `** TEST SUCCEEDED **`。

- [ ] **Step 5: 提交**

```bash
cd "<项目>" && git add RestBreak/RestBreak/Transfer/LocalSendProtocol.swift RestBreak/RestBreakTests/TransferTestSupport.swift RestBreak/RestBreakTests/TransferProtocolTests.swift && git commit -m "手机互传：LocalSend 协议数据结构

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: 本地网络说明 + 组播发现（先验证组播在沙盒里能用）

这一步是设计里标出的风险点：沙盒 App 能不能收发组播、会不会弹「本地网络」授权。测试第一次跑时 macOS 可能弹「允许"星期五"查找本地网络上的设备」，**需要用户点「允许」**（Claude 点不了，跑之前告诉用户）。

**Files:**
- Modify: `RestBreak/RestBreak.xcodeproj/project.pbxproj`（主 App 的 Debug、Release 两处）
- Create: `RestBreak/RestBreak/Transfer/LocalSendDiscovery.swift`
- Test: `RestBreak/RestBreakTests/TransferDiscoveryTests.swift`

- [ ] **Step 1: 加「本地网络」用途说明**

```bash
cd "<项目>/RestBreak" && perl -pi -e 's/^(\t+)(INFOPLIST_KEY_NSCalendarsFullAccessUsageDescription = .*;)$/$1$2\n$1INFOPLIST_KEY_NSLocalNetworkUsageDescription = "「星期五」用它在局域网里找到你的手机、和手机互传文件（LocalSend），不会连到外网。";/' RestBreak.xcodeproj/project.pbxproj && grep -c NSLocalNetworkUsageDescription RestBreak.xcodeproj/project.pbxproj
```

预期输出 `2`。

- [ ] **Step 2: 写失败的测试**

`RestBreak/RestBreakTests/TransferDiscoveryTests.swift`：

```swift
import Foundation
import Testing
@testable import RestBreak

/// 组播发现：用一个不常用的端口，两个实例互相收发（本机组播回环默认开着）
@Suite(.serialized)
@MainActor
struct TransferDiscoveryTests {
    @Test(.enabled(if: !LocalSendDiscovery.ipv4Interfaces().isEmpty, "没有联网的网卡"))
    func 组播能发能收() async throws {
        let sender = LocalSendDiscovery(port: 53391)
        let receiver = LocalSendDiscovery(port: 53391)
        var heard: [(LSDeviceInfo, String)] = []
        receiver.onMessage = { heard.append(($0, $1)) }
        try sender.start()
        try receiver.start()
        defer { sender.stop(); receiver.stop() }

        sender.send(LSDeviceInfo(alias: "测试", version: "2.1", fingerprint: "test-fp", announce: true))
        try await transferWait { heard.contains { $0.0.fingerprint == "test-fp" } }
        let host = try #require(heard.first { $0.0.fingerprint == "test-fp" }?.1)
        #expect(LANAddress.isLocal(host))
    }

    @Test func 停了以后不再收() throws {
        let discovery = LocalSendDiscovery(port: 53392)
        try discovery.start()
        #expect(discovery.isRunning)
        discovery.stop()
        #expect(!discovery.isRunning)
    }
}
```

- [ ] **Step 3: 跑测试，确认失败**（`TransferDiscoveryTests`）。预期：编译失败，`cannot find 'LocalSendDiscovery'`。

- [ ] **Step 4: 写实现**

`RestBreak/RestBreak/Transfer/LocalSendDiscovery.swift`：

```swift
import Darwin
import Foundation

enum DiscoveryError: Error {
    case socket(Int32)
    case bind(Int32)
    case join
}

/// 组播发现：在 224.0.0.167:53317 上收别人的喊话，也能自己喊一声。
/// 用 BSD 套接字 + DispatchSource：只在真有数据到达时才醒，平时 0 唤醒（不轮询）。
/// 不用 Network.framework 的组播组：那个在苹果平台上可能要额外的受限权限。
@MainActor
final class LocalSendDiscovery {
    /// 收到一条喊话：对方信息 + 对方 IP
    var onMessage: ((LSDeviceInfo, String) -> Void)?
    private let port: UInt16
    private let group: String
    private var socket: Int32 = -1
    private var source: DispatchSourceRead?

    init(port: UInt16 = LocalSend.port, group: String = LocalSend.multicastHost) {
        self.port = port
        self.group = group
    }

    var isRunning: Bool { socket >= 0 }

    func start() throws {
        guard socket < 0 else { return }
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw DiscoveryError.socket(errno) }
        var yes: Int32 = 1
        // 允许和别的程序（比如装了官方 LocalSend 电脑版）共用这个端口
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else {
            let code = errno
            close(fd)
            throw DiscoveryError.bind(code)
        }

        // 每张 IPv4 网卡都加入组播组：Wi‑Fi 和有线同时连着时都能收到
        var joined = 0
        for interface in Self.ipv4Interfaces() {
            var request = ip_mreq(imr_multiaddr: in_addr(s_addr: inet_addr(group)), imr_interface: interface)
            if setsockopt(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &request, socklen_t(MemoryLayout<ip_mreq>.size)) == 0 {
                joined += 1
            }
        }
        guard joined > 0 else {
            close(fd)
            throw DiscoveryError.join
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.readAll() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        socket = fd
        self.source = source
    }

    func stop() {
        source?.cancel()   // 取消时会关掉套接字
        source = nil
        socket = -1
    }

    /// 喊一声（每张网卡各发一次）
    func send(_ info: LSDeviceInfo) {
        guard socket >= 0, let data = try? JSONEncoder().encode(info) else { return }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr(group)
        for interface in Self.ipv4Interfaces() {
            var outgoing = interface
            setsockopt(socket, IPPROTO_IP, IP_MULTICAST_IF, &outgoing, socklen_t(MemoryLayout<in_addr>.size))
            data.withUnsafeBytes { bytes in
                withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        _ = sendto(socket, bytes.baseAddress, data.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }
    }

    /// 有数据了：一次读完（非阻塞，读空就停）
    private func readAll() {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while socket >= 0 {
            var from = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = buffer.withUnsafeMutableBytes { bytes in
                withUnsafeMutablePointer(to: &from) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(socket, bytes.baseAddress, bytes.count, 0, $0, &length)
                    }
                }
            }
            guard count > 0 else { return }
            guard let info = try? JSONDecoder().decode(LSDeviceInfo.self, from: Data(buffer[0..<count])) else { continue }
            onMessage?(info, String(cString: inet_ntoa(from.sin_addr)))
        }
    }

    /// 本机开着的、支持组播的 IPv4 网卡（不含回环）
    nonisolated static func ipv4Interfaces() -> [in_addr] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var result: [in_addr] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(pointer.pointee.ifa_flags)
            guard let address = pointer.pointee.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, flags & IFF_MULTICAST != 0 else { continue }
            result.append(address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr })
        }
        return result
    }
}
```

- [ ] **Step 5: 跑测试，确认通过**（`TransferDiscoveryTests`）。如果弹出「本地网络」授权，请用户点「允许」后重跑。

  **如果 `组播能发能收` 失败**（收不到）：停下来记录现象（`DiscoveryError` 哪一种、有没有弹授权），按设计的退路继续：后面的任务照做，`TransferCoordinator` 里 `discovery.start()` 失败时只显示提示、靠「按 IP 添加设备」。把结论写进 `docs/transfer/2026-11-10-validation.md`（Task 14 会建这个文件，这里先建也行）。

- [ ] **Step 6: 提交**

```bash
cd "<项目>" && git add RestBreak/RestBreak.xcodeproj/project.pbxproj RestBreak/RestBreak/Transfer/LocalSendDiscovery.swift RestBreak/RestBreakTests/TransferDiscoveryTests.swift && git commit -m "手机互传：组播发现 + 本地网络用途说明

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: 文件名与路径

**Files:**
- Create: `RestBreak/RestBreak/Transfer/TransferPaths.swift`
- Test: `RestBreak/RestBreakTests/TransferPathsTests.swift`

- [ ] **Step 1: 写失败的测试**

```swift
import Foundation
import Testing
@testable import RestBreak

struct TransferPathsTests {
    @Test func 清洗文件名() {
        #expect(TransferPaths.components(of: "a.jpg") == ["a.jpg"])
        #expect(TransferPaths.components(of: "../../etc/passwd") == ["etc", "passwd"])
        #expect(TransferPaths.components(of: "/abs/x.txt") == ["abs", "x.txt"])
        #expect(TransferPaths.components(of: "相册\\2026/./b.png") == ["相册", "2026", "b.png"])
        #expect(TransferPaths.components(of: "a\u{0}b:c.txt") == ["abc.txt"])
        #expect(TransferPaths.components(of: "../..") == nil)
        #expect(TransferPaths.components(of: "  ") == nil)
    }

    @Test func 重名加序号_保留文件夹结构() throws {
        let folder = try transferTempFolder()
        FileManager.default.createFile(atPath: folder.appendingPathComponent("a.jpg").path, contents: Data())
        let first = try #require(TransferPaths.destination(for: "a.jpg", in: folder, taken: []))
        #expect(first.lastPathComponent == "a (1).jpg")
        let second = try #require(TransferPaths.destination(for: "a.jpg", in: folder, taken: [first.path]))
        #expect(second.lastPathComponent == "a (2).jpg")
        #expect(TransferPaths.destination(for: "相册/b", in: folder, taken: [])?.path
                == folder.appendingPathComponent("相册/b").path)
        #expect(TransferPaths.destination(for: "..", in: folder, taken: []) == nil)
    }

    @Test func 发送时展开文件夹_跳过隐藏文件() throws {
        let folder = try transferTempFolder()
        let album = folder.appendingPathComponent("相册/2026", isDirectory: true)
        try FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)
        try Data("1".utf8).write(to: album.appendingPathComponent("a.jpg"))
        try Data("22".utf8).write(to: folder.appendingPathComponent("相册/.DS_Store"))
        try Data("333".utf8).write(to: folder.appendingPathComponent("x.txt"))
        let files = TransferPaths.expand([folder.appendingPathComponent("相册"), folder.appendingPathComponent("x.txt")])
        #expect(files.map(\.name) == ["相册/2026/a.jpg", "x.txt"])
        #expect(files.map(\.size) == [1, 3])
    }

    @Test func 文件类型() {
        #expect(OutgoingFile.mimeType(for: "a.JPG") == "image/jpeg")
        #expect(OutgoingFile.mimeType(for: "相册/b.png") == "image/png")
        #expect(OutgoingFile.mimeType(for: "c.zzzz") == "application/octet-stream")
    }
}
```

- [ ] **Step 2: 跑测试，确认失败**（`TransferPathsTests`）。

- [ ] **Step 3: 写实现**

`RestBreak/RestBreak/Transfer/TransferPaths.swift`：

```swift
import Foundation
import UniformTypeIdentifiers

/// 要发出去的一个文件；name 可能带相对路径（发文件夹时）
struct OutgoingFile: Equatable, Sendable {
    var url: URL
    var name: String
    var size: Int64

    /// 按扩展名猜 MIME 类型（LocalSend 的 fileType）
    static func mimeType(for name: String) -> String {
        let ext = (name as NSString).pathExtension
        return UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
    }
}

enum TransferPaths {
    /// 把手机给的文件名拆成安全的路径片段：去掉 ..、.、空片段、控制字符和冒号。全被去掉返回 nil。
    /// 这样拼出来的路径一定在保存目录里面，手机没法把文件写到别处
    static func components(of fileName: String) -> [String]? {
        let parts = fileName.split(whereSeparator: { $0 == "/" || $0 == "\\" }).map { part -> String in
            var scalars = String.UnicodeScalarView()
            scalars.append(contentsOf: part.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F && $0 != ":" })
            return String(String(scalars).trimmingCharacters(in: .whitespaces).prefix(200))
        }.filter { !$0.isEmpty && $0 != "." && $0 != ".." }
        return parts.isEmpty ? nil : parts
    }

    /// 收到的文件存到哪：保留子文件夹；重名加「 (1)」「 (2)」，不覆盖。
    /// taken = 同一批里已经分配出去、还没写到磁盘的路径
    static func destination(for fileName: String, in folder: URL, taken: Set<String>,
                            fileManager: FileManager = .default) -> URL? {
        guard var parts = components(of: fileName) else { return nil }
        let name = parts.removeLast()
        var directory = folder
        for part in parts { directory.appendPathComponent(part, isDirectory: true) }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var index = 0
        while true {
            let candidate = index == 0 ? name : (ext.isEmpty ? "\(base) (\(index))" : "\(base) (\(index)).\(ext)")
            let url = directory.appendingPathComponent(candidate, isDirectory: false)
            if !taken.contains(url.path), !fileManager.fileExists(atPath: url.path) { return url }
            index += 1
        }
    }

    /// 要发送的东西：文件原样，文件夹展开成里面的文件（名字带「文件夹名/子路径」），跳过隐藏文件
    static func expand(_ urls: [URL], fileManager: FileManager = .default) -> [OutgoingFile] {
        var result: [OutgoingFile] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            guard isDirectory.boolValue else {
                result.append(OutgoingFile(url: url, name: url.lastPathComponent, size: size(of: url)))
                continue
            }
            let root = url.resolvingSymlinksInPath()
            guard let walker = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                                      options: [.skipsHiddenFiles]) else { continue }
            var inside: [OutgoingFile] = []
            for case let file as URL in walker {
                guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                let relative = file.resolvingSymlinksInPath().path.dropFirst(root.path.count + 1)
                inside.append(OutgoingFile(url: file, name: root.lastPathComponent + "/" + relative, size: size(of: file)))
            }
            result += inside.sorted { $0.name < $1.name }
        }
        return result
    }

    private static func size(of url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
}
```

- [ ] **Step 4: 跑测试，确认通过**（`TransferPathsTests`）。

- [ ] **Step 5: 提交**

```bash
cd "<项目>" && git add RestBreak/RestBreak/Transfer/TransferPaths.swift RestBreak/RestBreakTests/TransferPathsTests.swift && git commit -m "手机互传：文件名清洗、重名加序号、展开文件夹

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: 传输记录与信任设备

**Files:**
- Create: `RestBreak/RestBreak/Transfer/TransferStore.swift`
- Test: `RestBreak/RestBreakTests/TransferStoreTests.swift`

- [ ] **Step 1: 写失败的测试**

```swift
import Foundation
import Testing
@testable import RestBreak

@Suite(.serialized)
@MainActor
struct TransferStoreTests {
    private func file() throws -> URL { try transferTempFolder().appendingPathComponent("store.json") }

    @Test func 信任设备() throws {
        let store = TransferStore(fileURL: try file())
        store.trust("f", alias: "手机")
        store.trust("f", alias: "新名字")
        #expect(store.isTrusted("f"))
        #expect(store.data.trusted == [TrustedDevice(fingerprint: "f", alias: "新名字")])
        store.untrust("f")
        #expect(!store.isTrusted("f"))
    }

    @Test func 超过30天的记录自动清掉_能读回() throws {
        let url = try file()
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let old = now.addingTimeInterval(-31 * 86_400)
        let store = TransferStore(fileURL: url)
        store.add(TransferRecord(date: old, device: "旧", direction: .received, outcome: .done), now: old)
        store.add(TransferRecord(date: now, device: "新", direction: .sent, outcome: .failed), now: now)
        #expect(store.data.records.map(\.device) == ["新"])
        #expect(TransferStore(fileURL: url).data.records.map(\.device) == ["新"])
    }

    @Test func 文字太长截断() throws {
        let store = TransferStore(fileURL: try file())
        store.add(TransferRecord(date: Date(), device: "p", direction: .received, outcome: .done,
                                 text: String(repeating: "字", count: 600)))
        #expect(store.data.records.first?.text?.count == TransferStore.maxTextLength + 1)
    }

    @Test func 手动地址() throws {
        let store = TransferStore(fileURL: try file())
        store.addManualHost("192.168.1.8")
        store.addManualHost("192.168.1.8")
        #expect(store.data.manualHosts == ["192.168.1.8"])
        store.removeManualHost("192.168.1.8")
        #expect(store.data.manualHosts.isEmpty)
    }

    @Test func 没变化不写盘() throws {
        let url = try file()
        TransferStore(fileURL: url).purge()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
```

- [ ] **Step 2: 跑测试，确认失败**（`TransferStoreTests`）。

- [ ] **Step 3: 写实现**

`RestBreak/RestBreak/Transfer/TransferStore.swift`：

```swift
import Foundation

/// 点过「总是收」的设备：它发来的文件直接收
struct TrustedDevice: Codable, Equatable, Identifiable, Sendable {
    var fingerprint: String
    var alias: String
    var id: String { fingerprint }
}

/// 一次传输的记录
struct TransferRecord: Codable, Equatable, Identifiable, Sendable {
    enum Direction: String, Codable, Sendable { case received, sent }
    enum Outcome: String, Codable, Sendable { case done, failed, rejected, cancelled }
    struct File: Codable, Equatable, Sendable {
        var name: String
        var size: Int64
        /// 收到的文件存在哪 / 发出的原文件在哪；没收成为 nil
        var path: String?
        var ok: Bool
    }

    var id = UUID()
    var date: Date
    var device: String
    var direction: Direction
    var outcome: Outcome
    var files: [File] = []
    /// 收到的是一段文字时
    var text: String?

    var totalSize: Int64 { files.reduce(0) { $0 + $1.size } }
}

struct TransferData: Codable, Equatable, Sendable {
    var trusted: [TrustedDevice] = []
    var records: [TransferRecord] = []
    /// 组播不通时用户手动加的手机 IP
    var manualHosts: [String] = []
}

/// 手机互传的数据：一个 JSON 文件（沙盒容器的 Application Support/FridayTransfer/store.json）。
/// 只有真变了才写盘；超过 30 天的记录在启动和新增记录时顺手清掉（只清记录，不删文件）
@MainActor
final class TransferStore: ObservableObject {
    static let retention: TimeInterval = 30 * 86_400
    /// 记录里的文字最多留这么多字（可能是验证码，没必要全存）
    static let maxTextLength = 500

    @Published private(set) var data: TransferData
    private let fileURL: URL

    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FridayTransfer", isDirectory: true)
            .appendingPathComponent("store.json")
    }

    init(fileURL: URL = TransferStore.defaultURL) {
        self.fileURL = fileURL
        data = (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode(TransferData.self, from: $0) }
            ?? TransferData()
    }

    func isTrusted(_ fingerprint: String) -> Bool { data.trusted.contains { $0.fingerprint == fingerprint } }

    func trust(_ fingerprint: String, alias: String) {
        change {
            $0.trusted.removeAll { $0.fingerprint == fingerprint }
            $0.trusted.append(TrustedDevice(fingerprint: fingerprint, alias: alias))
        }
    }

    func untrust(_ fingerprint: String) { change { $0.trusted.removeAll { $0.fingerprint == fingerprint } } }

    func addManualHost(_ host: String) {
        change { if !$0.manualHosts.contains(host) { $0.manualHosts.append(host) } }
    }

    func removeManualHost(_ host: String) { change { $0.manualHosts.removeAll { $0 == host } } }

    func add(_ record: TransferRecord, now: Date = Date()) {
        var record = record
        if let text = record.text, text.count > Self.maxTextLength {
            record.text = String(text.prefix(Self.maxTextLength)) + "…"
        }
        change {
            $0.records.insert(record, at: 0)
            Self.prune(&$0, now: now)
        }
    }

    func purge(now: Date = Date()) { change { Self.prune(&$0, now: now) } }

    func clearRecords() { change { $0.records.removeAll() } }

    private static func prune(_ data: inout TransferData, now: Date) {
        data.records.removeAll { now.timeIntervalSince($0.date) > retention }
    }

    /// 改数据：没变化就什么都不做，变了才写盘
    private func change(_ body: (inout TransferData) -> Void) {
        var copy = data
        body(&copy)
        guard copy != data else { return }
        data = copy
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(copy).write(to: fileURL, options: .atomic)
    }
}
```

- [ ] **Step 4: 跑测试，确认通过**（`TransferStoreTests`）。

- [ ] **Step 5: 提交**

```bash
cd "<项目>" && git add RestBreak/RestBreak/Transfer/TransferStore.swift RestBreak/RestBreakTests/TransferStoreTests.swift && git commit -m "手机互传：传输记录、信任设备、手动地址

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: 流式 HTTP 读取

现有 `HTTPParser`（`Services/LocalMCP.swift`）要收齐整个请求才解析，最大 1 MB，不适合收大文件。这里新写一个边收边交出请求体的。

**Files:**
- Create: `RestBreak/RestBreak/Transfer/HTTPStreamReader.swift`
- Test: `RestBreak/RestBreakTests/HTTPStreamReaderTests.swift`

- [ ] **Step 1: 写失败的测试**

```swift
import Foundation
import Testing
@testable import RestBreak

struct HTTPStreamReaderTests {
    @Test func 头和定长请求体分段到达() throws {
        var reader = HTTPStreamReader()
        let first = reader.feed(Data("POST /api/localsend/v2/upload?sessionId=s&fileId=a%20b&token=t HTTP/1.1\r\nContent-Length: 6\r\nHost: x\r\n\r\nabc".utf8))
        guard case .head(let head) = first.first else { Issue.record("没解析出请求头"); return }
        #expect(head.method == "POST")
        #expect(head.path == "/api/localsend/v2/upload")
        #expect(head.query == ["sessionId": "s", "fileId": "a b", "token": "t"])
        #expect(head.contentLength == 6)
        #expect(Array(first.dropFirst()) == [.body(Data("abc".utf8))])
        #expect(reader.feed(Data("defXYZ".utf8)) == [.body(Data("def".utf8)), .end])
    }

    @Test func 分块请求体() {
        var reader = HTTPStreamReader()
        let first = reader.feed(Data("POST /x HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nab".utf8))
        #expect(first.count == 2)
        #expect(first.last == .body(Data("ab".utf8)))
        #expect(reader.feed(Data("c\r\n2\r\nde\r\n0\r\n\r\n".utf8)) == [.body(Data("c".utf8)), .body(Data("de".utf8)), .end])
    }

    @Test func 没有请求体() {
        var reader = HTTPStreamReader()
        let events = reader.feed(Data("GET /api/localsend/v2/info HTTP/1.1\r\n\r\n".utf8))
        #expect(events.count == 2)
        #expect(events.last == .end)
    }

    @Test func 坏请求() {
        var reader = HTTPStreamReader()
        #expect(reader.feed(Data("garbage\r\n\r\n".utf8)) == [.invalid])
        var huge = HTTPStreamReader()
        #expect(huge.feed(Data(repeating: 65, count: 70_000)) == [.invalid])
    }
}
```

- [ ] **Step 2: 跑测试，确认失败**（`HTTPStreamReaderTests`）。

- [ ] **Step 3: 写实现**

`RestBreak/RestBreak/Transfer/HTTPStreamReader.swift`：

```swift
import Foundation

/// 一个 HTTP 请求的头（头的名字都转成小写）
struct HTTPRequestHead: Equatable, Sendable {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String]

    var contentLength: Int64? { headers["content-length"].flatMap { Int64($0) } }
    var isChunked: Bool { headers["transfer-encoding"]?.lowercased().contains("chunked") == true }
}

/// 边收边解析 HTTP 请求：头收齐交出 .head，请求体按到达的块交出 .body，收完交出 .end。
/// 上传的文件不整个放进内存。支持 Content-Length 和 chunked 两种请求体
struct HTTPStreamReader {
    enum Event: Equatable, Sendable {
        case head(HTTPRequestHead)
        case body(Data)
        case end
        case invalid
    }

    private enum State {
        case head
        case fixed(remaining: Int64)
        case chunkSize
        case chunkData(remaining: Int)
        case chunkEnd
        case done
    }

    private static let lineBreak = Data("\r\n".utf8)
    private static let headEnd = Data("\r\n\r\n".utf8)
    private var buffer = Data()
    private var state = State.head

    mutating func feed(_ data: Data) -> [Event] {
        buffer.append(data)
        var events: [Event] = []
        loop: while true {
            switch state {
            case .head:
                guard let end = buffer.firstRange(of: Self.headEnd) else {
                    if buffer.count > 64_000 { fail(&events) }
                    break loop
                }
                guard let head = Self.parseHead(buffer[buffer.startIndex..<end.lowerBound]) else {
                    fail(&events)
                    break loop
                }
                buffer.removeSubrange(buffer.startIndex..<end.upperBound)
                events.append(.head(head))
                if head.isChunked {
                    state = .chunkSize
                } else if let length = head.contentLength, length > 0 {
                    state = .fixed(remaining: length)
                } else {
                    state = .done
                    events.append(.end)
                    break loop
                }
            case .fixed(let remaining):
                guard !buffer.isEmpty else { break loop }
                let take = Int(min(Int64(buffer.count), remaining))
                events.append(.body(Data(buffer.prefix(take))))
                buffer.removeFirst(take)
                if remaining == Int64(take) {
                    state = .done
                    events.append(.end)
                    break loop
                }
                state = .fixed(remaining: remaining - Int64(take))
            case .chunkSize:
                guard let lineEnd = buffer.firstRange(of: Self.lineBreak) else {
                    if buffer.count > 1_024 { fail(&events) }
                    break loop
                }
                let text = String(decoding: buffer[buffer.startIndex..<lineEnd.lowerBound], as: UTF8.self)
                    .split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                guard let size = Int(text, radix: 16), size >= 0 else {
                    fail(&events)
                    break loop
                }
                buffer.removeSubrange(buffer.startIndex..<lineEnd.upperBound)
                if size == 0 {   // 最后一块；后面的尾部字段不需要
                    state = .done
                    events.append(.end)
                    break loop
                }
                state = .chunkData(remaining: size)
            case .chunkData(let remaining):
                guard !buffer.isEmpty else { break loop }
                let take = min(buffer.count, remaining)
                events.append(.body(Data(buffer.prefix(take))))
                buffer.removeFirst(take)
                state = remaining == take ? .chunkEnd : .chunkData(remaining: remaining - take)
            case .chunkEnd:   // 每块数据后面跟一个 \r\n
                guard buffer.count >= 2 else { break loop }
                buffer.removeFirst(2)
                state = .chunkSize
            case .done:
                break loop
            }
        }
        return events
    }

    private mutating func fail(_ events: inout [Event]) {
        state = .done
        buffer = Data()
        events.append(.invalid)
    }

    private static func parseHead(_ data: Data) -> HTTPRequestHead? {
        let lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\r\n")
        let start = lines[0].split(separator: " ")
        guard start.count >= 2, let components = URLComponents(string: "http://host" + start[1]) else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return HTTPRequestHead(method: String(start[0]).uppercased(), path: components.path, query: query, headers: headers)
    }
}
```

- [ ] **Step 4: 跑测试，确认通过**（`HTTPStreamReaderTests`）。

- [ ] **Step 5: 提交**

```bash
cd "<项目>" && git add RestBreak/RestBreak/Transfer/HTTPStreamReader.swift RestBreak/RestBreakTests/HTTPStreamReaderTests.swift && git commit -m "手机互传：边收边解析的 HTTP 请求读取

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: 接收会话

**Files:**
- Create: `RestBreak/RestBreak/Transfer/ReceiveSession.swift`
- Test: `RestBreak/RestBreakTests/ReceiveSessionTests.swift`

- [ ] **Step 1: 写失败的测试**

```swift
import Foundation
import Testing
@testable import RestBreak

struct ReceiveSessionTests {
    private func make() -> ReceiveSession {
        var counter = 0
        return ReceiveSession(id: "s", sender: phoneInfo, host: "192.168.1.8",
                              files: ["a": LSFileMeta(id: "a", fileName: "a.txt", size: 3, fileType: "text/plain"),
                                      "b": LSFileMeta(id: "b", fileName: "b.bin", size: 2, fileType: "application/octet-stream")],
                              accepted: ["a": URL(fileURLWithPath: "/tmp/a.txt")],
                              makeToken: { counter += 1; return "t\(counter)" })
    }

    @Test func 只给同意的文件发令牌() {
        let session = make()
        #expect(session.tokens == ["a": "t1"])
        #expect(session.totalSize == 3)
    }

    @Test func 校验上传参数() {
        var session = make()
        #expect(session.check(sessionId: "s", fileId: "a", token: "t1", host: "192.168.1.8") == .ok)
        #expect(session.check(sessionId: nil, fileId: "a", token: "t1", host: "192.168.1.8") == .missing)
        #expect(session.check(sessionId: "s", fileId: "a", token: "错", host: "192.168.1.8") == .forbidden)
        #expect(session.check(sessionId: "s", fileId: "a", token: "t1", host: "192.168.1.9") == .forbidden)
        #expect(session.check(sessionId: "x", fileId: "a", token: "t1", host: "192.168.1.8") == .forbidden)
        #expect(session.check(sessionId: "s", fileId: "b", token: "t1", host: "192.168.1.8") == .forbidden)
        session.begin("a")
        #expect(session.check(sessionId: "s", fileId: "a", token: "t1", host: "192.168.1.8") == .forbidden)
    }

    @Test func 超出声明大小_收完() {
        var session = make()
        session.begin("a")
        #expect(session.receive(2, for: "a"))
        #expect(!session.receive(2, for: "a"))
        #expect(session.receive(1, for: "a"))
        #expect(session.receivedSize == 3)
        #expect(!session.isFinished)
        session.finish("a", ok: true)
        #expect(session.isFinished)
        #expect(session.allSucceeded)
    }
}
```

- [ ] **Step 2: 跑测试，确认失败**（`ReceiveSessionTests`）。

- [ ] **Step 3: 写实现**

`RestBreak/RestBreak/Transfer/ReceiveSession.swift`：

```swift
import Foundation

/// 一次接收（prepare-upload 同意之后，到所有文件收完或失败）：只管令牌、进度、状态，不碰网络和磁盘
struct ReceiveSession: Sendable {
    struct Entry: Equatable, Sendable {
        enum State: Equatable, Sendable { case waiting, receiving, done, failed }
        var meta: LSFileMeta
        var token: String
        var destination: URL
        var received: Int64 = 0
        var state = State.waiting
    }

    enum Check: Equatable { case ok, missing, forbidden }

    let id: String
    let sender: LSDeviceInfo
    /// 对方 IP：上传必须来自同一个地址
    let host: String
    private(set) var entries: [String: Entry]

    init(id: String = UUID().uuidString, sender: LSDeviceInfo, host: String, files: [String: LSFileMeta],
         accepted: [String: URL], makeToken: () -> String = { UUID().uuidString }) {
        self.id = id
        self.sender = sender
        self.host = host
        var entries: [String: Entry] = [:]
        for (fileId, destination) in accepted.sorted(by: { $0.key < $1.key }) {
            guard let meta = files[fileId] else { continue }
            entries[fileId] = Entry(meta: meta, token: makeToken(), destination: destination)
        }
        self.entries = entries
    }

    var tokens: [String: String] { entries.mapValues(\.token) }
    var totalSize: Int64 { entries.values.reduce(0) { $0 + $1.meta.size } }
    var receivedSize: Int64 { entries.values.reduce(0) { $0 + $1.received } }
    var isFinished: Bool { entries.values.allSatisfy { $0.state == .done || $0.state == .failed } }
    var allSucceeded: Bool { entries.values.allSatisfy { $0.state == .done } }

    /// 上传请求的参数对不对：缺参数 400；会话、令牌、来源 IP 不对或这个文件已经在传 / 传过 403
    func check(sessionId: String?, fileId: String?, token: String?, host: String) -> Check {
        guard let sessionId, let fileId, let token else { return .missing }
        guard sessionId == id, host == self.host, let entry = entries[fileId], entry.token == token,
              entry.state == .waiting else { return .forbidden }
        return .ok
    }

    mutating func begin(_ fileId: String) { entries[fileId]?.state = .receiving }

    /// 记下收到的字节；超过声明的大小返回 false（调用方要中断这个文件）
    mutating func receive(_ count: Int, for fileId: String) -> Bool {
        guard let entry = entries[fileId], entry.received + Int64(count) <= entry.meta.size else { return false }
        entries[fileId]?.received += Int64(count)
        return true
    }

    mutating func finish(_ fileId: String, ok: Bool) { entries[fileId]?.state = ok ? .done : .failed }
}
```

- [ ] **Step 4: 跑测试，确认通过**（`ReceiveSessionTests`）。

- [ ] **Step 5: 提交**

```bash
cd "<项目>" && git add RestBreak/RestBreak/Transfer/ReceiveSession.swift RestBreak/RestBreakTests/ReceiveSessionTests.swift && git commit -m "手机互传：接收会话（令牌、进度、状态）

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: 接收服务器

**Files:**
- Modify: `RestBreak/RestBreak/Services/LocalMCP.swift`（`HTTPReply.serialized` 的说明文字表）
- Create: `RestBreak/RestBreak/Transfer/LocalSendServer.swift`
- Test: `RestBreak/RestBreakTests/LocalSendServerTests.swift`

- [ ] **Step 1: 补 HTTP 状态说明**

把 `Services/LocalMCP.swift` 里

```swift
        let reason = [200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
                      404: "Not Found", 405: "Method Not Allowed", 413: "Payload Too Large"][status] ?? "Error"
```

改成

```swift
        let reason = [200: "OK", 202: "Accepted", 204: "No Content", 400: "Bad Request", 401: "Unauthorized",
                      403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed", 409: "Conflict",
                      413: "Payload Too Large", 422: "Unprocessable Content", 500: "Internal Server Error"][status] ?? "Error"
```

- [ ] **Step 2: 写失败的测试**

`RestBreak/RestBreakTests/LocalSendServerTests.swift`：

```swift
import CryptoKit
import Foundation
import Testing
@testable import RestBreak

/// 测试用的「TransferCoordinator」：决定收不收，记下发生了什么
@MainActor
final class FakeServerDelegate: LocalSendServerDelegate {
    var localInfo = LSDeviceInfo(alias: "星期五", version: "2.1", deviceModel: "Mac", deviceType: "desktop",
                                 fingerprint: "me", port: 0, protocol: "http", download: false)
    var decision: (LSPrepareUploadRequest) -> PrepareDecision = { _ in .reject }
    var registered: [LSDeviceInfo] = []
    var ended: [(session: ReceiveSession, cancelled: Bool)] = []

    func server(didRegister info: LSDeviceInfo, host: String) { registered.append(info) }
    func server(prepare request: LSPrepareUploadRequest, host: String) async -> PrepareDecision { decision(request) }
    func server(progress session: ReceiveSession) {}
    func server(ended session: ReceiveSession, cancelled: Bool) { ended.append((session, cancelled)) }
}

@Suite(.serialized)
@MainActor
struct LocalSendServerTests {
    private func start(_ delegate: FakeServerDelegate) async throws -> (LocalSendServer, String) {
        let server = LocalSendServer()
        server.delegate = delegate
        server.start(port: 0)
        try await transferWait { server.port != nil }
        return (server, "http://127.0.0.1:\(server.port ?? 0)/api/localsend/v2/")
    }

    private func post(_ url: String, _ body: Data) async throws -> (Data, Int) {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private func prepareBody(_ files: [LSFileMeta]) throws -> Data {
        try JSONEncoder().encode(LSPrepareUploadRequest(info: phoneInfo,
                                                        files: Dictionary(uniqueKeysWithValues: files.map { ($0.id, $0) })))
    }

    private func prepare(_ base: String, _ files: [LSFileMeta]) async throws -> LSPrepareUploadResponse {
        let (data, status) = try await post(base + "prepare-upload", try prepareBody(files))
        #expect(status == 200)
        return try JSONDecoder().decode(LSPrepareUploadResponse.self, from: data)
    }

    @Test func 收一个文件() async throws {
        let folder = try transferTempFolder()
        let delegate = FakeServerDelegate()
        delegate.decision = { _ in .accept(["a": folder.appendingPathComponent("子/a.txt")]) }
        let (server, base) = try await start(delegate)
        defer { server.stop() }

        let response = try await prepare(base, [LSFileMeta(id: "a", fileName: "a.txt", size: 5, fileType: "text/plain")])
        let token = try #require(response.files["a"])
        let (_, status) = try await post(base + "upload?sessionId=\(response.sessionId)&fileId=a&token=\(token)", Data("hello".utf8))
        #expect(status == 200)
        #expect(try String(contentsOf: folder.appendingPathComponent("子/a.txt"), encoding: .utf8) == "hello")
        try await transferWait { delegate.ended.count == 1 }
        #expect(delegate.ended.first?.session.allSucceeded == true)
        #expect(delegate.ended.first?.cancelled == false)
        #expect(server.session == nil)
    }

    @Test func 令牌不对_会话占用_取消() async throws {
        let folder = try transferTempFolder()
        let delegate = FakeServerDelegate()
        delegate.decision = { _ in .accept(["a": folder.appendingPathComponent("a.txt")]) }
        let (server, base) = try await start(delegate)
        defer { server.stop() }

        let response = try await prepare(base, [LSFileMeta(id: "a", fileName: "a.txt", size: 5, fileType: "text/plain")])
        #expect(try await post(base + "upload?sessionId=\(response.sessionId)&fileId=a&token=错", Data("hello".utf8)).1 == 403)
        #expect(try await post(base + "upload?fileId=a", Data()).1 == 400)
        #expect(try await post(base + "prepare-upload", try prepareBody([LSFileMeta(id: "b", fileName: "b", size: 1, fileType: "x")])).1 == 409)
        #expect(try await post(base + "cancel?sessionId=\(response.sessionId)", Data()).1 == 200)
        #expect(delegate.ended.first?.cancelled == true)
        #expect(server.session == nil)
    }

    @Test func 拒收和文字() async throws {
        let delegate = FakeServerDelegate()
        let (server, base) = try await start(delegate)
        defer { server.stop() }
        let file = LSFileMeta(id: "a", fileName: "a.txt", size: 5, fileType: "text/plain")
        #expect(try await post(base + "prepare-upload", try prepareBody([file])).1 == 403)
        delegate.decision = { _ in .message }
        #expect(try await post(base + "prepare-upload", try prepareBody([file])).1 == 204)
        #expect(try await post(base + "prepare-upload", Data("不是 JSON".utf8)).1 == 400)
    }

    @Test func 超出声明大小_校验不符() async throws {
        let folder = try transferTempFolder()
        let delegate = FakeServerDelegate()
        delegate.decision = { _ in .accept(["a": folder.appendingPathComponent("a.txt"), "b": folder.appendingPathComponent("b.txt")]) }
        let (server, base) = try await start(delegate)
        defer { server.stop() }

        let response = try await prepare(base, [
            LSFileMeta(id: "a", fileName: "a.txt", size: 2, fileType: "text/plain"),
            LSFileMeta(id: "b", fileName: "b.txt", size: 5, fileType: "text/plain", sha256: String(repeating: "0", count: 64)),
        ])
        // 声明 2 字节却发了 5 字节：服务器中断（可能回 400，也可能直接断开）
        let oversize = try? await post(base + "upload?sessionId=\(response.sessionId)&fileId=a&token=\(response.files["a"]!)", Data("hello".utf8))
        #expect(oversize?.1 != 200)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("a.txt").path))
        let (_, status) = try await post(base + "upload?sessionId=\(response.sessionId)&fileId=b&token=\(response.files["b"]!)", Data("hello".utf8))
        #expect(status == 422)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("b.txt").path))
        try await transferWait { delegate.ended.count == 1 }
        #expect(delegate.ended.first?.session.allSucceeded == false)
    }

    @Test func 校验相符() async throws {
        let folder = try transferTempFolder()
        let delegate = FakeServerDelegate()
        delegate.decision = { _ in .accept(["a": folder.appendingPathComponent("a.txt")]) }
        let (server, base) = try await start(delegate)
        defer { server.stop() }
        let hash = SHA256.hash(data: Data("hello".utf8)).map { String(format: "%02x", $0) }.joined()
        let response = try await prepare(base, [LSFileMeta(id: "a", fileName: "a.txt", size: 5, fileType: "text/plain", sha256: hash.uppercased())])
        #expect(try await post(base + "upload?sessionId=\(response.sessionId)&fileId=a&token=\(response.files["a"]!)", Data("hello".utf8)).1 == 200)
    }

    @Test func register回本机信息() async throws {
        let delegate = FakeServerDelegate()
        let (server, base) = try await start(delegate)
        defer { server.stop() }
        let (data, status) = try await post(base + "register", try JSONEncoder().encode(phoneInfo))
        #expect(status == 200)
        #expect(try JSONDecoder().decode(LSDeviceInfo.self, from: data).alias == "星期五")
        #expect(delegate.registered.map(\.fingerprint) == ["phone"])
    }

    @Test func 太久没动静就结束会话() async throws {
        let folder = try transferTempFolder()
        let delegate = FakeServerDelegate()
        delegate.decision = { _ in .accept(["a": folder.appendingPathComponent("a.txt")]) }
        let (server, base) = try await start(delegate)
        defer { server.stop() }
        server.idleTimeout = .milliseconds(300)
        _ = try await prepare(base, [LSFileMeta(id: "a", fileName: "a.txt", size: 5, fileType: "text/plain")])
        try await transferWait { delegate.ended.count == 1 }
        #expect(server.session == nil)
    }
}
```

- [ ] **Step 3: 跑测试，确认失败**（`LocalSendServerTests`）。

- [ ] **Step 4: 写实现**

`RestBreak/RestBreak/Transfer/LocalSendServer.swift`：

```swift
import CryptoKit
import Foundation
import Network

/// 有人要发文件来时，TransferCoordinator 的决定
enum PrepareDecision: Sendable {
    /// 收：文件 id → 存到哪（只包含要收的文件）
    case accept([String: URL])
    /// 是一段文字，已经处理好（回 204，不用再传）
    case message
    /// 拒收（回 403）
    case reject
}

@MainActor
protocol LocalSendServerDelegate: AnyObject {
    /// 本机的设备信息（register、info 回给对方）
    var localInfo: LSDeviceInfo { get }
    func server(didRegister info: LSDeviceInfo, host: String)
    func server(prepare request: LSPrepareUploadRequest, host: String) async -> PrepareDecision
    func server(progress session: ReceiveSession)
    /// 一次接收结束（收完、失败、超时或对方取消）
    func server(ended session: ReceiveSession, cancelled: Bool)
}

/// LocalSend 的接收端（HTTP）：在局域网上监听，处理 register / info / prepare-upload / upload / cancel。
/// 上传的文件边收边写，不整个放进内存；同一时间只接一个会话（别的 prepare-upload 回 409）。
/// 只接受局域网地址的连接。所有回调都在主线程
@MainActor
final class LocalSendServer {
    weak var delegate: LocalSendServerDelegate?
    /// 端口开好了（之后才对外喊话：喊话里要带端口）
    var onReady: (() -> Void)?
    /// 端口全被占用，开不起来
    var onFailure: ((String) -> Void)?
    private(set) var port: UInt16?
    private(set) var session: ReceiveSession?
    /// 会话里多久没收到数据就当对方走了
    var idleTimeout: Duration = .seconds(60)

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: LocalSendConnection] = [:]
    private var writers: [String: FileWriter] = [:]
    /// 正在等用户决定收不收（期间别的 prepare-upload 回 409）
    private var deciding = false
    private var idleTask: Task<Void, Never>?
    private var lastActivity = Date()
    private var lastProgress = Date.distantPast

    /// port = 0 时由系统随便挑一个（测试用）
    func start(port: UInt16 = LocalSend.port, attemptsLeft: Int = 10) {
        listener?.cancel()
        listener = nil
        let endpointPort: NWEndpoint.Port = port == 0 ? .any : NWEndpoint.Port(rawValue: port)!
        guard let listener = try? NWListener(using: .tcp, on: endpointPort) else {
            retry(after: port, attemptsLeft: attemptsLeft)
            return
        }
        self.listener = listener
        // 监听和连接都在主队列上回调
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self, self.listener === listener else { return }
                switch state {
                case .ready:
                    self.port = listener.port?.rawValue
                    self.onReady?()
                case .failed:
                    listener.cancel()
                    self.listener = nil
                    self.port = nil
                    self.retry(after: port, attemptsLeft: attemptsLeft)
                default: break
                }
            }
        }
        listener.start(queue: .main)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = nil
        for connection in connections.values { connection.close() }
        connections.removeAll()
        if session != nil { endSession(cancelled: true) }
    }

    /// 端口被占用：往后找一个
    private func retry(after port: UInt16, attemptsLeft: Int) {
        guard port != 0, attemptsLeft > 1 else {
            onFailure?("端口 \(LocalSend.port) 附近都被占用，手机暂时连不上星期五")
            return
        }
        start(port: port + 1, attemptsLeft: attemptsLeft - 1)
    }

    private func accept(_ connection: NWConnection) {
        guard let host = Self.host(of: connection.endpoint), LANAddress.isLocal(host) else {
            connection.cancel()
            return
        }
        let handler = LocalSendConnection(connection: connection, host: host, server: self)
        connections[ObjectIdentifier(handler)] = handler
        handler.start()
    }

    func closed(_ handler: LocalSendConnection) { connections[ObjectIdentifier(handler)] = nil }

    // MARK: - 小请求：register / info / prepare-upload / cancel

    func handle(_ head: HTTPRequestHead, body: Data, host: String) async -> HTTPReply {
        guard let delegate else { return HTTPReply(status: 500) }
        switch (head.method, head.path) {
        case ("POST", LocalSend.apiPrefix + "register"):
            guard let info = try? JSONDecoder().decode(LSDeviceInfo.self, from: body) else { return HTTPReply(status: 400) }
            delegate.server(didRegister: info, host: host)
            return Self.json(delegate.localInfo)
        case (_, LocalSend.apiPrefix + "info"):
            return Self.json(delegate.localInfo)
        case ("POST", LocalSend.apiPrefix + "prepare-upload"):
            return await prepare(body, host: host, delegate: delegate)
        case ("POST", LocalSend.apiPrefix + "cancel"):
            guard let session, head.query["sessionId"] == session.id, host == session.host else { return HTTPReply(status: 403) }
            endSession(cancelled: true)
            return HTTPReply(status: 200)
        default:
            return HTTPReply(status: 404)
        }
    }

    private func prepare(_ body: Data, host: String, delegate: LocalSendServerDelegate) async -> HTTPReply {
        guard session == nil, !deciding else { return HTTPReply(status: 409) }
        guard let request = try? JSONDecoder().decode(LSPrepareUploadRequest.self, from: body), !request.files.isEmpty else {
            return HTTPReply(status: 400)
        }
        deciding = true
        let decision = await delegate.server(prepare: request, host: host)
        deciding = false
        switch decision {
        case .reject:
            return HTTPReply(status: 403)
        case .message:
            return HTTPReply(status: 204)
        case .accept(let accepted):
            let session = ReceiveSession(sender: request.info, host: host, files: request.files, accepted: accepted)
            guard !session.entries.isEmpty else { return HTTPReply(status: 204) }
            self.session = session
            touch()
            return Self.json(LSPrepareUploadResponse(sessionId: session.id, files: session.tokens))
        }
    }

    // MARK: - 上传：边收边写

    enum UploadStart { case accepted(fileId: String), refused(Int) }

    /// 上传开始：校验参数，建好文件
    func beginUpload(_ head: HTTPRequestHead, host: String) -> UploadStart {
        guard var session else { return .refused(403) }
        let fileId = head.query["fileId"] ?? ""
        switch session.check(sessionId: head.query["sessionId"], fileId: head.query["fileId"], token: head.query["token"], host: host) {
        case .missing: return .refused(400)
        case .forbidden: return .refused(403)
        case .ok: break
        }
        guard let entry = session.entries[fileId] else { return .refused(403) }
        do {
            writers[fileId] = try FileWriter(url: entry.destination, wantsHash: entry.meta.sha256 != nil)
        } catch {
            session.finish(fileId, ok: false)
            self.session = session
            finishIfDone()
            return .refused(500)
        }
        session.begin(fileId)
        self.session = session
        touch()
        return .accepted(fileId: fileId)
    }

    /// 收到一段；超过声明大小或写盘失败返回 false（这个文件作废）
    func write(_ data: Data, fileId: String) -> Bool {
        guard var session, let writer = writers[fileId] else { return false }
        guard session.receive(data.count, for: fileId), (try? writer.write(data)) != nil else {
            abortUpload(fileId)
            return false
        }
        self.session = session
        touch()
        if Date().timeIntervalSince(lastProgress) >= 0.5 {   // 进度最多每 0.5 秒报一次
            lastProgress = Date()
            delegate?.server(progress: session)
        }
        return true
    }

    /// 一个文件的请求体收完：核对大小和 SHA-256，返回给对方的状态码
    func finishUpload(_ fileId: String) -> Int {
        guard var session, let writer = writers.removeValue(forKey: fileId), let entry = session.entries[fileId] else { return 403 }
        let digest = writer.close()
        var status = 200
        if entry.received != entry.meta.size {
            status = 400
        } else if let expected = entry.meta.sha256, digest?.lowercased() != expected.lowercased() {
            status = 422
        }
        if status != 200 { try? FileManager.default.removeItem(at: entry.destination) }
        session.finish(fileId, ok: status == 200)
        self.session = session
        finishIfDone()
        return status
    }

    /// 连接断了 / 出错：删掉没写完的文件
    func abortUpload(_ fileId: String) {
        guard var session, let entry = session.entries[fileId], entry.state == .receiving else { return }
        _ = writers.removeValue(forKey: fileId)?.close()
        try? FileManager.default.removeItem(at: entry.destination)
        session.finish(fileId, ok: false)
        self.session = session
        finishIfDone()
    }

    private func finishIfDone() {
        if session?.isFinished == true { endSession(cancelled: false) }
    }

    /// 结束会话：还没收完的都算失败，删掉写了一半的文件
    private func endSession(cancelled: Bool) {
        guard var session else { return }
        for (fileId, entry) in session.entries where entry.state == .waiting || entry.state == .receiving {
            _ = writers.removeValue(forKey: fileId)?.close()
            if entry.state == .receiving { try? FileManager.default.removeItem(at: entry.destination) }
            session.finish(fileId, ok: false)
        }
        self.session = nil
        idleTask?.cancel()
        idleTask = nil
        delegate?.server(ended: session, cancelled: cancelled)
    }

    /// 记下「还有动静」；会话里只有一个计时任务，到点检查最后一次动静
    private func touch() {
        lastActivity = Date()
        guard idleTask == nil else { return }
        idleTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let quiet = Duration.seconds(Date().timeIntervalSince(self.lastActivity))
                if quiet >= self.idleTimeout {
                    self.idleTask = nil
                    self.endSession(cancelled: false)
                    return
                }
                let wait = self.idleTimeout - quiet
                try? await Task.sleep(for: wait)
            }
        }
    }

    private static func json<T: Encodable>(_ value: T) -> HTTPReply {
        HTTPReply(status: 200, headers: ["Content-Type": "application/json"], body: (try? JSONEncoder().encode(value)) ?? Data())
    }

    /// 连接来源的 IPv4 地址（去掉「%en0」这类网卡后缀；IPv6 映射的 IPv4 也认）
    nonisolated static func host(of endpoint: NWEndpoint) -> String? {
        guard case .hostPort(let host, _) = endpoint else { return nil }
        switch host {
        case .ipv4(let address): return "\(address)".components(separatedBy: "%")[0]
        case .ipv6(let address): return address.asIPv4.map { "\($0)".components(separatedBy: "%")[0] }
        default: return nil
        }
    }
}

/// 写一个收到的文件，顺便算 SHA-256（对方给了校验值时）
final class FileWriter {
    private let handle: FileHandle
    private var hasher: SHA256?

    init(url: URL, wantsHash: Bool) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        handle = try FileHandle(forWritingTo: url)
        hasher = wantsHash ? SHA256() : nil
    }

    func write(_ data: Data) throws {
        try handle.write(contentsOf: data)
        hasher?.update(data: data)
    }

    /// 关闭文件；要算哈希时返回十六进制小写
    func close() -> String? {
        try? handle.close()
        return hasher?.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// 一条 HTTP 连接：收一个请求 → 回复 → 关闭
@MainActor
final class LocalSendConnection {
    /// 文件清单（JSON）最大 4 MB，够几千个文件
    static let maxBody = 4_000_000
    let host: String
    private let connection: NWConnection
    private weak var server: LocalSendServer?
    private var reader = HTTPStreamReader()
    private var head: HTTPRequestHead?
    private var body = Data()
    /// 正在上传的文件 id（这条连接是 upload 时）
    private var uploadId: String?
    /// 已经在回复了：不再读
    private var done = false

    init(connection: NWConnection, host: String, server: LocalSendServer) {
        self.connection = connection
        self.host = host
        self.server = server
    }

    func start() {
        connection.start(queue: .main)
        receive()
    }

    func close() {
        if let uploadId { server?.abortUpload(uploadId) }
        uploadId = nil
        done = true
        connection.cancel()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self, !self.done else { return }
                if let data, !data.isEmpty {
                    for event in self.reader.feed(data) {
                        self.handle(event)
                        if self.done { return }
                    }
                }
                if isComplete || error != nil {
                    self.close()
                    self.server?.closed(self)
                    return
                }
                self.receive()
            }
        }
    }

    private func handle(_ event: HTTPStreamReader.Event) {
        guard let server else { close(); return }
        switch event {
        case .invalid:
            reply(HTTPReply(status: 400))
        case .head(let head):
            self.head = head
            if head.headers["expect"]?.lowercased() == "100-continue" {
                connection.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .idempotent)
            }
            if head.method == "POST", head.path == LocalSend.apiPrefix + "upload" {
                switch server.beginUpload(head, host: host) {
                case .accepted(let fileId): uploadId = fileId
                case .refused(let status): reply(HTTPReply(status: status))
                }
            }
        case .body(let data):
            if let uploadId {
                if !server.write(data, fileId: uploadId) {
                    self.uploadId = nil
                    reply(HTTPReply(status: 400))
                }
            } else {
                body.append(data)
                if body.count > Self.maxBody { reply(HTTPReply(status: 413)) }
            }
        case .end:
            if let uploadId {
                self.uploadId = nil
                reply(HTTPReply(status: server.finishUpload(uploadId)))
                return
            }
            guard let head else { reply(HTTPReply(status: 400)); return }
            done = true   // 等回复期间不再读
            let body = self.body
            let host = self.host
            Task { [weak self] in
                let answer = await server.handle(head, body: body, host: host)
                self?.send(answer)
            }
        }
    }

    private func reply(_ reply: HTTPReply) {
        guard !done else { return }
        done = true
        send(reply)
    }

    private func send(_ reply: HTTPReply) {
        connection.send(content: reply.serialized, completion: .contentProcessed { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.connection.cancel()
                self.server?.closed(self)
            }
        })
    }
}
```

- [ ] **Step 5: 跑测试，确认通过**（`LocalSendServerTests`，再跑一遍 `LocalMCPTests` 确认没被状态文字改坏）。

- [ ] **Step 6: 提交**

```bash
cd "<项目>" && git add RestBreak/RestBreak/Services/LocalMCP.swift RestBreak/RestBreak/Transfer/LocalSendServer.swift RestBreak/RestBreakTests/LocalSendServerTests.swift && git commit -m "手机互传：接收服务器（流式写文件、令牌、校验、超时）

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: 发送客户端

**Files:**
- Create: `RestBreak/RestBreak/Transfer/LocalSendClient.swift`
- Test: `RestBreak/RestBreakTests/LocalSendClientTests.swift`

- [ ] **Step 1: 写失败的测试**（用 Task 7 的服务器当「手机」）

```swift
import Foundation
import Testing
@testable import RestBreak

/// 跨线程记进度
final class ByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64 = 0
    func set(_ bytes: Int64) { lock.withLock { value = bytes } }
    var current: Int64 { lock.withLock { value } }
}

@Suite(.serialized)
@MainActor
struct LocalSendClientTests {
    private func start(_ delegate: FakeServerDelegate) async throws -> (LocalSendServer, NearbyDevice) {
        let server = LocalSendServer()
        server.delegate = delegate
        server.start(port: 0)
        try await transferWait { server.port != nil }
        return (server, NearbyDevice(fingerprint: "me", alias: "星期五", host: "127.0.0.1", port: Int(server.port ?? 0), https: false))
    }

    @Test func 发一个文件() async throws {
        let folder = try transferTempFolder()
        let source = folder.appendingPathComponent("源.txt")
        try Data("hello world".utf8).write(to: source)
        let delegate = FakeServerDelegate()
        delegate.decision = { _ in .accept(["b": folder.appendingPathComponent("收到.txt")]) }
        let (server, device) = try await start(delegate)
        defer { server.stop() }

        let client = LocalSendClient()
        let request = LSPrepareUploadRequest(info: phoneInfo, files: ["b": LSFileMeta(id: "b", fileName: "源.txt", size: 11, fileType: "text/plain")])
        guard case .accepted(let response) = try await client.prepareUpload(request, to: device) else {
            Issue.record("对方没接收")
            return
        }
        let counter = ByteCounter()
        try await client.upload(source, to: device, sessionId: response.sessionId, fileId: "b",
                                token: try #require(response.files["b"])) { counter.set($0) }
        #expect(try String(contentsOf: folder.appendingPathComponent("收到.txt"), encoding: .utf8) == "hello world")
        #expect(counter.current == 11)
    }

    @Test func 被拒_对方离线_register() async throws {
        let delegate = FakeServerDelegate()
        let (server, device) = try await start(delegate)
        defer { server.stop() }
        let client = LocalSendClient()
        let request = LSPrepareUploadRequest(info: phoneInfo, files: ["a": LSFileMeta(id: "a", fileName: "a", size: 1, fileType: "x")])
        await #expect(throws: SendError.rejected) { try await client.prepareUpload(request, to: device) }
        #expect(try await client.register(phoneInfo, to: device).alias == "星期五")

        var gone = device
        gone.port = 9   // 没人监听的端口
        await #expect(throws: SendError.unreachable) { try await client.prepareUpload(request, to: gone) }
    }
}
```

- [ ] **Step 2: 跑测试，确认失败**（`LocalSendClientTests`）。

- [ ] **Step 3: 写实现**

`RestBreak/RestBreak/Transfer/LocalSendClient.swift`：

```swift
import CryptoKit
import Foundation

enum SendError: Error, Equatable {
    case rejected
    case busy
    case unreachable
    case failed(Int)
}

/// LocalSend 的发送端：调对方的 register / prepare-upload / upload / cancel。
/// 手机开着加密时用的是自签名证书：不查证书颁发机构，按对方喊话里的指纹（证书 SHA-256）核对；
/// 还没见过指纹的（手动按 IP 加的）先接受
final class LocalSendClient: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let lock = NSLock()
    /// "IP:端口" → 证书指纹（小写十六进制）
    private var pins: [String: String] = [:]
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 6 * 3_600
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    func pin(_ device: NearbyDevice) {
        lock.withLock { pins["\(device.host):\(device.port)"] = device.fingerprint.lowercased() }
    }

    func register(_ me: LSDeviceInfo, to device: NearbyDevice) async throws -> LSDeviceInfo {
        let (data, status) = try await post(device.url("register"), body: try JSONEncoder().encode(me), timeout: 5)
        guard status == 200, let info = try? JSONDecoder().decode(LSDeviceInfo.self, from: data) else { throw SendError.failed(status) }
        return info
    }

    enum PrepareResult: Equatable {
        case accepted(LSPrepareUploadResponse)
        /// 对方说不用传了（204）
        case nothingToSend
    }

    func prepareUpload(_ request: LSPrepareUploadRequest, to device: NearbyDevice) async throws -> PrepareResult {
        // 手机上要等人点「接收」，等久一点
        let (data, status) = try await post(device.url("prepare-upload"), body: try JSONEncoder().encode(request), timeout: 120)
        switch status {
        case 200:
            guard let response = try? JSONDecoder().decode(LSPrepareUploadResponse.self, from: data) else { throw SendError.failed(status) }
            return .accepted(response)
        case 204: return .nothingToSend
        case 403: throw SendError.rejected
        case 409: throw SendError.busy
        default: throw SendError.failed(status)
        }
    }

    /// 传一个文件（从磁盘边读边发）；progress 收到「已发字节数」，可能在任意线程
    func upload(_ file: URL, to device: NearbyDevice, sessionId: String, fileId: String, token: String,
                progress: @escaping @Sendable (Int64) -> Void) async throws {
        var request = URLRequest(url: device.url("upload", query: ["sessionId": sessionId, "fileId": fileId, "token": token]))
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let response: URLResponse
        do {
            (_, response) = try await session.upload(for: request, fromFile: file, delegate: ProgressDelegate(progress))
        } catch is URLError {
            throw SendError.unreachable
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 || status == 204 else { throw SendError.failed(status) }
    }

    func cancel(sessionId: String, on device: NearbyDevice) async {
        _ = try? await post(device.url("cancel", query: ["sessionId": sessionId]), body: Data(), timeout: 5)
    }

    private func post(_ url: URL, body: Data, timeout: TimeInterval) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            let (data, response) = try await session.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch is URLError {
            throw SendError.unreachable
        }
    }

    // 自签名证书：只在局域网地址上接受，按指纹核对
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust, let trust = space.serverTrust,
              LANAddress.isLocal(space.host),
              let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first else {
            return (.performDefaultHandling, nil)
        }
        let fingerprint = SHA256.hash(data: SecCertificateCopyData(leaf) as Data).map { String(format: "%02x", $0) }.joined()
        let expected = lock.withLock { pins["\(space.host):\(space.port)"] }
        if let expected, !expected.isEmpty, expected != fingerprint { return (.cancelAuthenticationChallenge, nil) }
        return (.useCredential, URLCredential(trust: trust))
    }
}

/// 一个上传任务的进度
private final class ProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let progress: @Sendable (Int64) -> Void

    init(_ progress: @escaping @Sendable (Int64) -> Void) { self.progress = progress }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        progress(totalBytesSent)
    }
}
```

- [ ] **Step 4: 跑测试，确认通过**（`LocalSendClientTests`）。

  如果报 App Transport Security 拦截了 `http://127.0.0.1`（错误码 -1022）：在 `RestBreak/RestBreak/` 下新建 `Info.plist`，只放 `NSAppTransportSecurity` → `NSAllowsLocalNetworking = YES`，并在主 App 的 Debug、Release 配置里加 `INFOPLIST_FILE = RestBreak/Info.plist;`（`GENERATE_INFOPLIST_FILE` 保持 YES，两者会合并），然后重跑。

- [ ] **Step 5: 提交**

```bash
cd "<项目>" && git add RestBreak/RestBreak/Transfer/LocalSendClient.swift RestBreak/RestBreakTests/LocalSendClientTests.swift && git commit -m "手机互传：发送客户端（证书指纹、进度）

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: 灵动岛共用 + 更新进度

灵动岛目前由 `ReminderCoordinator` 私有持有一个 `NotchIsland`。手机互传必须用同一个（两个会叠在一起）。

**Files:**
- Modify: `RestBreak/RestBreak/UI/NotchIsland.swift`
- Modify: `RestBreak/RestBreak/App/ReminderCoordinator.swift:24`

- [ ] **Step 1: 改 `ReminderCoordinator`**

```swift
    private let island = NotchIsland()
```

改成

```swift
    /// 灵动岛只能有一个：手机互传也用这一个（BreakCoordinator 传过去）
    let island = NotchIsland()
```

- [ ] **Step 2: 给 `NotchIsland` 加协议和 `update`**

在 `NotchIsland.swift` 的 `/// 管理岛的显示、排队、自动收起` 这一行**上面**加：

```swift
/// 能显示灵动岛提示的东西（测试里换成假的）
@MainActor
protocol IslandPresenting: AnyObject {
    func show(_ item: IslandItem)
    func dismiss(key: String)
    func update(key: String, _ change: (inout IslandItem) -> Void)
}
```

把 `final class NotchIsland {` 改成 `final class NotchIsland: IslandPresenting {`，并在 `dismiss(prefix:)` 方法后面加：

```swift
    /// 改正在显示或排队的某一条（比如传输进度的百分比）；不在就什么都不做
    func update(key: String, _ change: (inout IslandItem) -> Void) {
        if var item = model.item, item.key == key {
            change(&item)
            model.item = item
        }
        if let index = queue.firstIndex(where: { $0.key == key }) { change(&queue[index]) }
    }
```

- [ ] **Step 3: 编译 + 跑提醒相关测试**（`<Suite>` 依次为 `ReminderProcessTests`、`PushGateTests`），预期通过。

- [ ] **Step 4: 提交**

```bash
cd "<项目>" && git add RestBreak/RestBreak/UI/NotchIsland.swift RestBreak/RestBreak/App/ReminderCoordinator.swift && git commit -m "灵动岛：可共用、可更新正在显示的一条

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 10: 保存位置

**Files:**
- Create: `RestBreak/RestBreak/Transfer/TransferFolder.swift`

沙盒 App 不能直接写「下载」：让用户选一次，存安全书签（做法同 `Services/PhotoFolderService.swift`）。选的就是「下载」时，存进里面的「星期五」子文件夹。这部分依赖系统选择窗口，不写单元测试，真机清单里验证。

- [ ] **Step 1: 写实现**

```swift
import AppKit

/// 收到的文件存在哪：用户选一次文件夹，记住安全书签
enum TransferFolder {
    /// 打开后的保存位置；用完要 close()（交还沙盒授权）
    struct Access {
        /// 书签解析出来的文件夹（拿着它的授权）；测试里为 nil
        let scope: URL?
        /// 真正存文件的地方（选的是「下载」时是「下载/星期五」）
        let target: URL

        func close() { scope?.stopAccessingSecurityScopedResource() }
    }

    /// 用户真正的家目录（沙盒里 NSHomeDirectory 是容器路径，不能用来指向「下载」）
    static var realHome: URL {
        if let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: directory), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    static var downloads: URL { realHome.appendingPathComponent("Downloads", isDirectory: true) }

    /// 弹窗选保存位置（默认指向「下载」）；取消返回 nil
    @MainActor
    static func choose() -> (name: String, bookmark: Data)? {
        let panel = NSOpenPanel()
        panel.title = "收到的文件存在哪"
        panel.message = "选「下载」的话，会存进里面的「星期五」文件夹"
        panel.prompt = "选择"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = downloads
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url,
              let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        else { return nil }
        return (displayName(of: url), bookmark)
    }

    /// 设置页里显示的名字
    static func displayName(of url: URL) -> String {
        isDownloads(url) ? "下载/星期五" : url.lastPathComponent
    }

    /// 解析书签、拿到授权、确保目标文件夹存在；文件夹没了（移动硬盘拔了等）返回 nil
    static func open(_ bookmark: Data) -> Access? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil,
                                 bookmarkDataIsStale: &stale),
              url.startAccessingSecurityScopedResource() else { return nil }
        let target = isDownloads(url) ? url.appendingPathComponent("星期五", isDirectory: true) : url
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        } catch {
            url.stopAccessingSecurityScopedResource()
            return nil
        }
        return Access(scope: url, target: target)
    }

    private static func isDownloads(_ url: URL) -> Bool {
        url.standardizedFileURL.resolvingSymlinksInPath().path == downloads.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
```

- [ ] **Step 2: 编译**

```bash
cd "<项目>/RestBreak" && DD="$HOME/Library/Developer/Xcode/DerivedData/RestBreak-xieyihui-spike" && xcodebuild -scheme RestBreak -configuration Debug -derivedDataPath "$DD" build -allowProvisioningUpdates 2>&1 | tail -5
```

预期 `** BUILD SUCCEEDED **`。

- [ ] **Step 3: 提交**

```bash
cd "<项目>" && git add RestBreak/RestBreak/Transfer/TransferFolder.swift && git commit -m "手机互传：保存位置（安全书签，下载里建「星期五」）

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 11: TransferCoordinator

**Files:**
- Create: `RestBreak/RestBreak/Transfer/TransferCoordinator.swift`
- Test: `RestBreak/RestBreakTests/TransferCoordinatorTests.swift`

- [ ] **Step 1: 写失败的测试**

```swift
import AppKit
import Foundation
import Testing
@testable import RestBreak

/// 假的灵动岛：记下显示过什么，可以替用户点按钮
@MainActor
final class FakeIsland: IslandPresenting {
    var shown: [IslandItem] = []
    var dismissed: [String] = []
    func show(_ item: IslandItem) { shown.append(item) }
    func dismiss(key: String) { dismissed.append(key) }
    func update(key: String, _ change: (inout IslandItem) -> Void) {
        if let index = shown.lastIndex(where: { $0.key == key }) { change(&shown[index]) }
    }
    func tap(_ title: String) { shown.last?.actions.first { $0.title == title }?.run() }
}

@Suite(.serialized)
@MainActor
struct TransferCoordinatorTests {
    private struct Fixture {
        let coordinator: TransferCoordinator
        let island: FakeIsland
        let folder: URL
        let board: NSPasteboard
    }

    private func make() throws -> Fixture {
        let root = try transferTempFolder()
        let island = FakeIsland()
        let board = NSPasteboard(name: .init("friday-transfer-" + UUID().uuidString))
        let coordinator = TransferCoordinator(island: island, store: TransferStore(fileURL: root.appendingPathComponent("store.json")),
                                              defaults: UserDefaults(suiteName: "friday-transfer-" + UUID().uuidString)!,
                                              pasteboard: board)
        let folder = root.appendingPathComponent("收到", isDirectory: true)
        coordinator.openFolder = { TransferFolder.Access(scope: nil, target: folder) }
        return Fixture(coordinator: coordinator, island: island, folder: folder, board: board)
    }

    private func request(_ files: [LSFileMeta]) -> LSPrepareUploadRequest {
        LSPrepareUploadRequest(info: phoneInfo, files: Dictionary(uniqueKeysWithValues: files.map { ($0.id, $0) }))
    }

    private let photo = LSFileMeta(id: "a", fileName: "a.jpg", size: 10, fileType: "image/jpeg")

    @Test func 信任的设备直接收() async throws {
        let f = try make()
        f.coordinator.store.trust("phone", alias: "华为手机")
        let decision = await f.coordinator.server(prepare: request([photo]), host: "192.168.1.8")
        guard case .accept(let map) = decision else { Issue.record("应该直接收"); return }
        #expect(map["a"] == f.folder.appendingPathComponent("a.jpg"))
        #expect(!f.island.shown.contains { $0.key.hasPrefix("transfer|ask") })
        #expect(f.coordinator.nearby.map(\.fingerprint) == ["phone"])
    }

    @Test func 陌生设备先问_点总是收后加入信任() async throws {
        let f = try make()
        let task = Task { await f.coordinator.server(prepare: request([photo]), host: "192.168.1.8") }
        try await transferWait { f.island.shown.contains { $0.key.hasPrefix("transfer|ask") } }
        // 大小的写法由系统按语言决定（「10 字节」或「10字节」），只核对前半句
        #expect(f.island.shown.last?.title.hasPrefix("华为手机 想发来 1 个文件") == true)
        f.island.tap("总是收")
        guard case .accept = await task.value else { Issue.record("应该收"); return }
        #expect(f.coordinator.store.isTrusted("phone"))
    }

    @Test func 陌生设备点拒_记一条被拒() async throws {
        let f = try make()
        let task = Task { await f.coordinator.server(prepare: request([photo]), host: "192.168.1.8") }
        try await transferWait { !f.island.shown.isEmpty }
        f.island.tap("拒")
        guard case .reject = await task.value else { Issue.record("应该拒"); return }
        #expect(f.coordinator.store.data.records.first?.outcome == .rejected)
        #expect(!f.coordinator.store.isTrusted("phone"))
    }

    @Test func 休息中陌生设备直接拒_不弹岛() async throws {
        let f = try make()
        f.coordinator.isBusy = { true }
        guard case .reject = await f.coordinator.server(prepare: request([photo]), host: "192.168.1.8") else {
            Issue.record("应该拒"); return
        }
        #expect(f.island.shown.isEmpty)
    }

    @Test func 文字放进剪贴板() async throws {
        let f = try make()
        f.coordinator.store.trust("phone", alias: "华为手机")
        let text = LSFileMeta(id: "t", fileName: "t.txt", size: 13, fileType: "text/plain", preview: "验证码 123456")
        guard case .message = await f.coordinator.server(prepare: request([text]), host: "192.168.1.8") else {
            Issue.record("应该当文字处理"); return
        }
        #expect(f.board.string(forType: .string) == "验证码 123456")
        #expect(f.coordinator.store.data.records.first?.text == "验证码 123456")
        #expect(f.island.shown.last?.title == "华为手机 发来一段文字，已复制")
    }

    @Test func 收完写记录_休息中等休息结束再提示() throws {
        let f = try make()
        f.coordinator.isBusy = { true }
        var session = ReceiveSession(sender: phoneInfo, host: "192.168.1.8", files: ["a": photo],
                                     accepted: ["a": f.folder.appendingPathComponent("a.jpg")])
        session.begin("a")
        _ = session.receive(10, for: "a")
        session.finish("a", ok: true)
        f.coordinator.server(ended: session, cancelled: false)

        let record = try #require(f.coordinator.store.data.records.first)
        #expect(record.outcome == .done)
        #expect(record.direction == .received)
        #expect(record.files == [TransferRecord.File(name: "a.jpg", size: 10, path: f.folder.appendingPathComponent("a.jpg").path, ok: true)])
        #expect(f.island.shown.isEmpty)

        f.coordinator.isBusy = { false }
        f.coordinator.breakEnded()
        #expect(f.island.shown.last?.title == "收到 1 个文件")
    }

    @Test func 本机信息() throws {
        let f = try make()
        let info = f.coordinator.localInfo
        #expect(info.protocol == "http")
        #expect(info.deviceType == "desktop")
        #expect(info.fingerprint == f.coordinator.fingerprint)
        #expect(info.alias.hasPrefix("星期五"))
        f.coordinator.preferences.alias = "我的 Mac"
        #expect(f.coordinator.localInfo.alias == "我的 Mac")
    }
}
```

- [ ] **Step 2: 跑测试，确认失败**（`TransferCoordinatorTests`）。

- [ ] **Step 3: 写实现**

`RestBreak/RestBreak/Transfer/TransferCoordinator.swift`：

```swift
import AppKit

struct TransferPreferences: Codable, Equatable {
    var enabled = false
    /// 在手机上显示的名字；空 = 「星期五 · <Mac 名>」
    var alias = ""
    var folderBookmark: Data?
    var folderName: String?
}

/// 手机互传的总调度：开关、发现设备、收文件（问不问、存哪、记录、灵动岛）、收文字、发文件。
/// 默认关闭；关闭时不监听端口、不收组播
@MainActor
final class TransferCoordinator: ObservableObject {
    @Published var preferences: TransferPreferences {
        didSet {
            guard oldValue != preferences else { return }
            if let data = try? JSONEncoder().encode(preferences) { defaults.set(data, forKey: Self.settingsKey) }
            apply(aliasChanged: oldValue.alias != preferences.alias)
        }
    }
    @Published private(set) var nearby: [NearbyDevice] = []
    /// 设置页上显示的问题（端口被占、收不到广播、保存位置不能用）
    @Published private(set) var problem: String?
    @Published private(set) var isSending = false

    let store: TransferStore
    let fingerprint: String
    /// 是否在休息（休息时陌生设备直接拒，提示等休息结束再显示）
    var isBusy: () -> Bool = { false }
    var onOpenSettings: (() -> Void)?
    /// 打开保存位置（测试里换成临时文件夹）
    var openFolder: () -> TransferFolder.Access? = { nil }

    static let settingsKey = "friday.transfer.settings.v1"
    static let fingerprintKey = "friday.transfer.fingerprint"
    static let receivingKey = "transfer|receiving"
    static let sendingKey = "transfer|sending"

    private let island: IslandPresenting
    private let server = LocalSendServer()
    private let discovery = LocalSendDiscovery()
    private let client = LocalSendClient()
    private let defaults: UserDefaults
    private let pasteboard: NSPasteboard
    private var running = false
    /// 正在接收时拿着保存位置的授权
    private var receivingFolder: TransferFolder.Access?
    /// 休息期间攒着的提示
    private var deferred: [IslandItem] = []
    private lazy var macName = Host.current().localizedName ?? "Mac"

    init(island: IslandPresenting, store: TransferStore = TransferStore(), defaults: UserDefaults = .standard,
         pasteboard: NSPasteboard = .general) {
        self.island = island
        self.store = store
        self.defaults = defaults
        self.pasteboard = pasteboard
        preferences = defaults.data(forKey: Self.settingsKey)
            .flatMap { try? JSONDecoder().decode(TransferPreferences.self, from: $0) } ?? TransferPreferences()
        // HTTP 模式下指纹是随机字符串：生成一次一直用，手机靠它认出「同一台星期五」
        if let saved = defaults.string(forKey: Self.fingerprintKey) {
            fingerprint = saved
        } else {
            fingerprint = UUID().uuidString.lowercased()
            defaults.set(fingerprint, forKey: Self.fingerprintKey)
        }
        openFolder = { [weak self] in self?.preferences.folderBookmark.flatMap(TransferFolder.open) }
        server.delegate = self
    }

    var defaultAlias: String { "星期五 · \(macName)" }

    var localInfo: LSDeviceInfo {
        LSDeviceInfo(alias: preferences.alias.isEmpty ? defaultAlias : preferences.alias, version: LocalSend.version,
                     deviceModel: "Mac", deviceType: "desktop", fingerprint: fingerprint,
                     port: Int(server.port ?? LocalSend.port), protocol: "http", download: false)
    }

    // MARK: - 开关

    func start() {
        store.purge()
        apply(aliasChanged: false)
    }

    func stop() {
        if running { turnOff() }
    }

    /// 设置页的总开关：第一次打开先选保存位置，取消就不打开
    func setEnabled(_ on: Bool) {
        if on, preferences.folderBookmark == nil {
            guard let folder = TransferFolder.choose() else { return }
            preferences.folderBookmark = folder.bookmark
            preferences.folderName = folder.name
        }
        preferences.enabled = on
    }

    func chooseFolder() {
        guard let folder = TransferFolder.choose() else { return }
        preferences.folderBookmark = folder.bookmark
        preferences.folderName = folder.name
    }

    private func apply(aliasChanged: Bool) {
        if preferences.enabled, !running {
            turnOn()
        } else if !preferences.enabled, running {
            turnOff()
        } else if running, aliasChanged {
            announce()   // 改了名字：重新喊一声，手机上马上看到新名字
        }
    }

    private func turnOn() {
        running = true
        problem = nil
        server.onReady = { [weak self] in
            self?.announce()
            self?.probeManualHosts()
        }
        server.onFailure = { [weak self] in self?.problem = $0 }
        server.start()
        discovery.onMessage = { [weak self] info, host in self?.heard(info, from: host) }
        do {
            try discovery.start()
        } catch {
            problem = "收不到局域网广播，手机可能找不到这台 Mac；可以在下面按 IP 添加手机"
        }
    }

    private func turnOff() {
        running = false
        server.stop()
        discovery.stop()
        nearby = []
    }

    // MARK: - 发现设备

    /// 喊一声：附近开着 LocalSend 的手机会回应
    func announce() {
        guard running else { return }
        var me = localInfo
        me.announce = true
        discovery.send(me)
    }

    private func heard(_ info: LSDeviceInfo, from host: String) {
        guard info.fingerprint != fingerprint else { return }   // 自己喊的
        let device = NearbyDevice(info: info, host: host)
        remember(device)
        guard info.announce == true else { return }
        // 对方刚上线：用 HTTP 告诉它「我在」；连不上再用组播回一声
        let me = localInfo
        Task {
            do {
                _ = try await client.register(me, to: device)
            } catch {
                var reply = me
                reply.announce = false
                discovery.send(reply)
            }
        }
    }

    private func remember(_ device: NearbyDevice) {
        guard device.fingerprint != fingerprint else { return }
        if device.https { client.pin(device) }
        nearby.removeAll { $0.fingerprint == device.fingerprint || ($0.host == device.host && $0.port == device.port) }
        nearby.append(device)
        nearby.sort { $0.alias < $1.alias }
    }

    /// 组播不通时：用户填手机上 LocalSend 显示的 IP
    func addManualHost(_ text: String) {
        let host = text.trimmingCharacters(in: .whitespaces)
        guard LANAddress.isLocal(host) else {
            problem = "「\(host)」不是局域网地址"
            return
        }
        store.addManualHost(host)
        probe(host)
    }

    private func probeManualHosts() {
        for host in store.data.manualHosts { probe(host) }
    }

    /// 试着连一下手动加的地址：官方 LocalSend 默认开加密，先试 HTTPS 再试 HTTP
    private func probe(_ host: String) {
        let me = localInfo
        Task {
            for https in [true, false] {
                let guess = NearbyDevice(fingerprint: "", alias: host, host: host, port: Int(LocalSend.port), https: https)
                if let info = try? await client.register(me, to: guess) {
                    remember(NearbyDevice(fingerprint: info.fingerprint, alias: info.alias, deviceModel: info.deviceModel,
                                          host: host, port: guess.port, https: https))
                    return
                }
            }
        }
    }

    // MARK: - 提示

    /// 发一条灵动岛提示；休息中先攒着。按钮点了以后收起这一条
    private func notify(key: String, symbol: String, compact: String, title: String, message: String,
                        actions: [IslandItem.Action] = []) {
        let close = { [weak self] in self?.island.dismiss(key: key) }
        let wrapped = actions.map { action in
            IslandItem.Action(title: action.title, primary: action.primary) {
                action.run()
                close()
            }
        }
        let item = IslandItem(key: key, intent: .info, symbol: symbol, kind: "手机互传", compact: compact,
                              title: title, message: message,
                              actions: wrapped.isEmpty ? [IslandItem.Action(title: "好的", primary: true) { close() }] : wrapped)
        if isBusy() { deferred.append(item) } else { island.show(item) }
    }

    /// 休息结束：把攒着的提示放出来
    func breakEnded() {
        let items = deferred
        deferred = []
        for item in items { island.show(item) }
    }

    private enum Answer { case reject, accept, always }

    /// 陌生设备发来东西：在灵动岛上问「拒 / 总是收 / 收」，30 秒没点算拒
    private func ask(title: String, message: String) async -> Answer {
        await withCheckedContinuation { continuation in
            let key = "transfer|ask|\(UUID().uuidString)"
            var answered = false
            let answer: (Answer) -> Void = { [weak self] value in
                guard !answered else { return }
                answered = true
                self?.island.dismiss(key: key)
                continuation.resume(returning: value)
            }
            island.show(IslandItem(key: key, intent: .info, symbol: "iphone.and.arrow.forward", kind: "手机互传",
                                   compact: "收文件？", title: title, message: message, firm: true, autoDismiss: 30,
                                   actions: [.init(title: "拒") { answer(.reject) },
                                             .init(title: "总是收") { answer(.always) },
                                             .init(title: "收", primary: true) { answer(.accept) }],
                                   onTimeout: { answer(.reject) }, onDropped: { answer(.reject) }))
        }
    }

    // MARK: - 发送

    /// 菜单「发送到手机…」：选文件或文件夹
    func chooseAndSend() {
        guard preferences.enabled else { onOpenSettings?(); return }
        let panel = NSOpenPanel()
        panel.title = "选择要发到手机的文件"
        panel.prompt = "发送"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        NSApp.activate()
        guard panel.runModal() == .OK else { return }
        send(panel.urls)
    }

    /// 发送（拖到菜单栏图标也走这里）
    func send(_ urls: [URL]) {
        guard preferences.enabled else { onOpenSettings?(); return }
        guard !isSending else {
            notify(key: "transfer|busy", symbol: "hourglass", compact: "稍等", title: "上一批还没发完", message: "发完再拖新的文件过来")
            return
        }
        let files = TransferPaths.expand(urls)
        guard !files.isEmpty else { return }
        isSending = true
        Task {
            if let device = await chooseDevice() { await send(files, to: device) }
            isSending = false
        }
    }

    private func chooseDevice() async -> NearbyDevice? {
        announce()
        if nearby.isEmpty { try? await Task.sleep(for: .seconds(2)) }   // 等手机回应
        switch nearby.count {
        case 0:
            notify(key: "transfer|nobody", symbol: "iphone.slash", compact: "没找到", title: "附近没找到手机",
                   message: "在手机上打开 LocalSend，和这台 Mac 连同一个 Wi‑Fi 再试")
            return nil
        case 1:
            return nearby[0]
        default:
            return DevicePicker.pick(nearby)
        }
    }

    private struct UploadJob: Sendable {
        let id: String
        let token: String
        let file: OutgoingFile
    }

    private func send(_ files: [OutgoingFile], to device: NearbyDevice) async {
        let ids = files.indices.map { "f\($0)" }
        var metas: [String: LSFileMeta] = [:]
        for (id, file) in zip(ids, files) {
            metas[id] = LSFileMeta(id: id, fileName: file.name, size: file.size, fileType: OutgoingFile.mimeType(for: file.name))
        }
        let total = files.reduce(0) { $0 + $1.size }
        island.show(IslandItem(key: Self.sendingKey, intent: .info, symbol: "iphone.and.arrow.forward", kind: "手机互传",
                               compact: "等对方", title: "发给 \(device.alias)",
                               message: "\(files.count) 个文件（\(Self.size(total))），等手机上点接收", autoDismiss: nil,
                               actions: [.init(title: "隐藏") { [weak self] in self?.island.dismiss(key: Self.sendingKey) }]))
        var outcome = TransferRecord.Outcome.failed
        var results: [String: Bool] = [:]
        do {
            switch try await client.prepareUpload(LSPrepareUploadRequest(info: localInfo, files: metas), to: device) {
            case .nothingToSend:
                outcome = .done
                for id in ids { results[id] = true }
            case .accepted(let response):
                let jobs = zip(ids, files).compactMap { id, file in response.files[id].map { UploadJob(id: id, token: $0, file: file) } }
                results = await upload(jobs, sessionId: response.sessionId, to: device, total: total)
                outcome = !jobs.isEmpty && jobs.allSatisfy { results[$0.id] == true } ? .done : .failed
            }
        } catch SendError.rejected {
            outcome = .rejected
        } catch SendError.unreachable {
            nearby.removeAll { $0.fingerprint == device.fingerprint }   // 连不上：多半离开了
        } catch {
            outcome = .failed
        }
        island.dismiss(key: Self.sendingKey)
        store.add(TransferRecord(date: Date(), device: device.alias, direction: .sent, outcome: outcome,
                                 files: zip(ids, files).map { id, file in
                                     TransferRecord.File(name: file.name, size: file.size, path: file.url.path, ok: results[id] == true)
                                 }))
        let sent = results.values.filter { $0 }.count
        switch outcome {
        case .done:
            notify(key: "transfer|sent|\(UUID().uuidString)", symbol: "checkmark.circle", compact: "已发送",
                   title: "已发给 \(device.alias)", message: "\(sent) 个文件（\(Self.size(total))）")
        case .rejected:
            notify(key: "transfer|sent|\(UUID().uuidString)", symbol: "xmark.circle", compact: "被拒",
                   title: "\(device.alias) 没有接收", message: "对方在手机上拒绝了这次发送")
        default:
            notify(key: "transfer|sent|\(UUID().uuidString)", symbol: "exclamationmark.triangle", compact: "失败",
                   title: "发给 \(device.alias) 没成功",
                   message: sent > 0 ? "发出 \(sent) 个，\(files.count - sent) 个失败" : "连不上手机：确认手机开着 LocalSend、和 Mac 在同一个 Wi‑Fi")
        }
    }

    /// 同时最多传 3 个文件；返回每个文件成没成功
    private func upload(_ jobs: [UploadJob], sessionId: String, to device: NearbyDevice, total: Int64) async -> [String: Bool] {
        let progress = SendProgress(total: total) { [weak self] percent in
            self?.island.update(key: Self.sendingKey) {
                $0.compact = "\(percent)%"
                $0.message = "正在发送 \(percent)%"
            }
        }
        let client = self.client
        return await withTaskGroup(of: (String, Bool).self) { group in
            var pending = jobs.makeIterator()
            var results: [String: Bool] = [:]
            for _ in 0..<3 {
                guard let job = pending.next() else { break }
                group.addTask {
                    do {
                        try await client.upload(job.file.url, to: device, sessionId: sessionId, fileId: job.id, token: job.token) {
                            progress.report(job.id, $0)
                        }
                        return (job.id, true)
                    } catch {
                        return (job.id, false)
                    }
                }
            }
            for await (id, ok) in group {
                results[id] = ok
                guard let job = pending.next() else { continue }
                group.addTask {
                    do {
                        try await client.upload(job.file.url, to: device, sessionId: sessionId, fileId: job.id, token: job.token) {
                            progress.report(job.id, $0)
                        }
                        return (job.id, true)
                    } catch {
                        return (job.id, false)
                    }
                }
            }
            return results
        }
    }

    // MARK: - 记录页用

    /// 记录里哪些文件还在。收到的文件在保存位置里，要先拿沙盒授权才看得到；发出的原文件不查（重启后没有授权），都当在
    func existingPaths(in record: TransferRecord) -> Set<String> {
        let paths = record.files.compactMap(\.path)
        guard record.direction == .received else { return Set(paths) }
        let access = openFolder()
        defer { access?.close() }
        return Set(paths.filter { FileManager.default.fileExists(atPath: $0) })
    }

    static func reveal(_ paths: [String]) {
        NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(fileURLWithPath: $0) })
    }

    static func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}

// MARK: - 接收（LocalSendServer 的回调）

extension TransferCoordinator: LocalSendServerDelegate {
    func server(didRegister info: LSDeviceInfo, host: String) {
        remember(NearbyDevice(info: info, host: host))
    }

    func server(prepare request: LSPrepareUploadRequest, host: String) async -> PrepareDecision {
        let device = NearbyDevice(info: request.info, host: host)
        remember(device)
        let name = request.info.alias
        let rejected = TransferRecord(date: Date(), device: name, direction: .received, outcome: .rejected,
                                      files: request.files.values.sorted { $0.fileName < $1.fileName }
                                          .map { TransferRecord.File(name: $0.fileName, size: $0.size, path: nil, ok: false) },
                                      text: request.message)
        if !store.isTrusted(device.fingerprint) {
            if isBusy() {   // 休息中不打扰：陌生设备直接拒
                store.add(rejected)
                return .reject
            }
            let what = request.message != nil ? "想发来一段文字" : "想发来 \(request.files.count) 个文件（\(Self.size(request.totalSize))）"
            let detail = request.message ?? request.files.values.map(\.fileName).sorted().prefix(3).joined(separator: "、")
            switch await ask(title: "\(name) \(what)", message: detail) {
            case .reject:
                store.add(rejected)
                return .reject
            case .always:
                store.trust(device.fingerprint, alias: name)
            case .accept:
                break
            }
        }

        if let text = request.message {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            store.add(TransferRecord(date: Date(), device: name, direction: .received, outcome: .done, text: text))
            notify(key: "transfer|text|\(UUID().uuidString)", symbol: "text.bubble", compact: "已复制",
                   title: "\(name) 发来一段文字，已复制", message: text)
            return .message
        }

        guard let folder = openFolder() else {
            var failed = rejected
            failed.outcome = .failed
            store.add(failed)
            notify(key: "transfer|nofolder", symbol: "folder.badge.questionmark", compact: "存不了",
                   title: "收不了 \(name) 的文件", message: "保存位置不能用了，去设置「手机互传」里重新选一下",
                   actions: [.init(title: "去设置", primary: true) { [weak self] in self?.onOpenSettings?() }])
            return .reject
        }
        var taken = Set<String>()
        var accepted: [String: URL] = [:]
        for (id, meta) in request.files.sorted(by: { $0.key < $1.key }) {
            guard let url = TransferPaths.destination(for: meta.fileName, in: folder.target, taken: taken) else { continue }
            taken.insert(url.path)
            accepted[id] = url
        }
        guard !accepted.isEmpty else {
            folder.close()
            return .reject
        }
        receivingFolder = folder
        if !isBusy() {
            island.show(IslandItem(key: Self.receivingKey, intent: .info, symbol: "arrow.down.circle", kind: "手机互传",
                                   compact: "0%", title: "正在接收 \(name) 的文件",
                                   message: "\(accepted.count) 个文件（\(Self.size(request.totalSize))）", autoDismiss: nil,
                                   actions: [.init(title: "隐藏") { [weak self] in self?.island.dismiss(key: Self.receivingKey) }]))
        }
        return .accept(accepted)
    }

    func server(progress session: ReceiveSession) {
        guard session.totalSize > 0 else { return }
        let percent = Int(Double(session.receivedSize) / Double(session.totalSize) * 100)
        island.update(key: Self.receivingKey) { $0.compact = "\(percent)%" }
    }

    func server(ended session: ReceiveSession, cancelled: Bool) {
        receivingFolder?.close()
        receivingFolder = nil
        island.dismiss(key: Self.receivingKey)
        let entries = session.entries.values.sorted { $0.meta.fileName < $1.meta.fileName }
        let files = entries.map {
            TransferRecord.File(name: $0.meta.fileName, size: $0.meta.size,
                                path: $0.state == .done ? $0.destination.path : nil, ok: $0.state == .done)
        }
        let saved = files.compactMap(\.path)
        let outcome: TransferRecord.Outcome = cancelled ? .cancelled : saved.count == files.count ? .done : .failed
        let name = session.sender.alias
        store.add(TransferRecord(date: Date(), device: name, direction: .received, outcome: outcome, files: files))

        let title: String
        switch outcome {
        case .done: title = "收到 \(saved.count) 个文件"
        case .cancelled: title = "\(name) 取消了发送"
        default: title = "有 \(files.count - saved.count) 个文件没收到"
        }
        let message = saved.isEmpty ? "来自 \(name)" : "来自 \(name)，已存好 \(saved.count) 个"
        notify(key: "transfer|received|\(session.id)", symbol: outcome == .done ? "checkmark.circle" : "exclamationmark.triangle",
               compact: outcome == .done ? "收到了" : "没收全", title: title, message: message,
               actions: saved.isEmpty ? [] : [.init(title: "在访达中显示", primary: true) { Self.reveal(saved) }])
    }
}

/// 多个文件同时发：汇总进度，最多每 0.5 秒更新一次灵动岛
final class SendProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [String: Int64] = [:]
    private var lastReport = Date.distantPast
    private let total: Int64
    private let onChange: @MainActor @Sendable (Int) -> Void

    init(total: Int64, onChange: @escaping @MainActor @Sendable (Int) -> Void) {
        self.total = total
        self.onChange = onChange
    }

    func report(_ id: String, _ bytes: Int64) {
        let percent: Int? = lock.withLock {
            sent[id] = bytes
            guard Date().timeIntervalSince(lastReport) >= 0.5 else { return nil }
            lastReport = Date()
            return total > 0 ? min(100, Int(Double(sent.values.reduce(0, +)) / Double(total) * 100)) : 0
        }
        guard let percent else { return }
        let onChange = self.onChange
        Task { @MainActor in onChange(percent) }
    }
}

/// 附近有好几台设备时：在鼠标位置弹个菜单选一台
@MainActor
enum DevicePicker {
    static func pick(_ devices: [NearbyDevice]) -> NearbyDevice? {
        let menu = NSMenu(title: "发送到")
        menu.autoenablesItems = false
        let header = NSMenuItem(title: "发送到…", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        let target = Target()
        for (index, device) in devices.enumerated() {
            let item = NSMenuItem(title: device.displayName, action: #selector(Target.choose(_:)), keyEquivalent: "")
            item.target = target
            item.tag = index
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        return target.chosen.map { devices[$0] }
    }

    private final class Target: NSObject {
        var chosen: Int?
        @objc func choose(_ item: NSMenuItem) { chosen = item.tag }
    }
}
```

- [ ] **Step 4: 跑测试，确认通过**（`TransferCoordinatorTests`）。

- [ ] **Step 5: 提交**

```bash
cd "<项目>" && git add RestBreak/RestBreak/Transfer/TransferCoordinator.swift RestBreak/RestBreakTests/TransferCoordinatorTests.swift && git commit -m "手机互传：总调度（询问、收文字、记录、发送）

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 12: 设置「手机互传」页

**Files:**
- Create: `RestBreak/RestBreak/Transfer/TransferSettingsPage.swift`
- Modify: `RestBreak/RestBreak/UI/SettingsWindow.swift`（`SettingsNavigation`、`SettingsPage`、页头分段、页面 switch）

- [ ] **Step 1: 写页面**

`RestBreak/RestBreak/Transfer/TransferSettingsPage.swift`：

```swift
import SwiftUI

/// 「手机互传」页的分段
enum TransferTab: String, CaseIterable, Identifiable {
    case setup = "设置"
    case history = "记录"

    var id: Self { self }
}

struct TransferSettingsPage: View {
    @EnvironmentObject private var app: BreakCoordinator
    @EnvironmentObject private var navigation: SettingsNavigation

    var body: some View {
        switch navigation.transferTab {
        case .setup: TransferSetup(model: app.transfer, store: app.transfer.store)
        case .history: TransferHistory(model: app.transfer, store: app.transfer.store)
        }
    }
}

/// 设置分段：要在 760×600 里一屏放下，列表多了在框里滚动
private struct TransferSetup: View {
    @ObservedObject var model: TransferCoordinator
    @ObservedObject var store: TransferStore
    @State private var manualHost = ""

    var body: some View {
        Card {
            SettingRow(title: "手机互传", subtitle: "手机装 LocalSend，和这台 Mac 连同一个 Wi‑Fi，就能互发文件和文字") {
                Toggle("", isOn: Binding(get: { model.preferences.enabled }, set: { model.setEnabled($0) })).blueSwitch()
            }
            if let problem = model.problem {
                Text(problem)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, SettingsTheme.cardPadding)
                    .padding(.bottom, 8)
            }
            RowDivider()
            SettingRow(title: "在手机上显示的名字") {
                TextField(model.defaultAlias, text: $model.preferences.alias)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
            }
            RowDivider()
            SettingRow(title: "收到的文件存到", subtitle: model.preferences.folderName ?? "还没选") {
                Button("更改…") { model.chooseFolder() }.buttonStyle(PillButtonStyle())
            }
        }

        Card {
            CardHeader(title: "附近的设备")
            ScrollView {
                VStack(spacing: 0) {
                    if model.nearby.isEmpty {
                        hint(model.preferences.enabled ? "还没发现设备：在手机上打开 LocalSend 看看" : "打开「手机互传」后显示")
                    }
                    ForEach(model.nearby) { device in
                        HStack {
                            Image(systemName: "iphone")
                            Text(device.displayName).font(.system(size: 12))
                            Spacer()
                            Text(device.host).font(.system(size: 11)).foregroundStyle(SettingsTheme.textSecondary)
                        }
                        .padding(.horizontal, SettingsTheme.cardPadding)
                        .padding(.vertical, 6)
                    }
                }
            }
            .frame(maxHeight: 96)
            HStack {
                TextField("找不到时填手机上 LocalSend 显示的 IP，如 192.168.1.8", text: $manualHost)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addHost)
                Button("添加", action: addHost).buttonStyle(PillButtonStyle()).disabled(manualHost.isEmpty)
                Button("刷新") { model.announce() }.buttonStyle(PillButtonStyle())
            }
            .disabled(!model.preferences.enabled)
            .padding(SettingsTheme.cardPadding)
        }

        Card {
            CardHeader(title: "信任的设备")
            ScrollView {
                VStack(spacing: 0) {
                    if store.data.trusted.isEmpty {
                        hint("在灵动岛上点过「总是收」的设备会出现在这里，它们发来的文件直接收")
                    }
                    ForEach(store.data.trusted) { device in
                        HStack {
                            Text(device.alias).font(.system(size: 12))
                            Spacer()
                            Button("取消信任") { store.untrust(device.fingerprint) }.buttonStyle(PillButtonStyle())
                        }
                        .padding(.horizontal, SettingsTheme.cardPadding)
                        .padding(.vertical, 6)
                    }
                }
            }
            .frame(maxHeight: 96)
        }
    }

    private func addHost() {
        model.addManualHost(manualHost)
        manualHost = ""
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(SettingsTheme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, SettingsTheme.cardPadding)
            .padding(.vertical, 10)
    }
}

/// 记录分段：最近 30 天，点一条展开文件列表
private struct TransferHistory: View {
    @ObservedObject var model: TransferCoordinator
    @ObservedObject var store: TransferStore
    @State private var expanded: UUID?
    @State private var existing: Set<String> = []

    var body: some View {
        Card {
            CardHeader(title: "最近 30 天")
            if store.data.records.isEmpty {
                Text("还没有传输记录")
                    .font(.system(size: 12))
                    .foregroundStyle(SettingsTheme.textSecondary)
                    .padding(SettingsTheme.cardPadding)
            }
            ForEach(Array(store.data.records.enumerated()), id: \.element.id) { index, record in
                if index > 0 { RowDivider() }
                row(record)
                if expanded == record.id { detail(record) }
            }
        }
    }

    private func row(_ record: TransferRecord) -> some View {
        HStack(spacing: 10) {
            Image(systemName: record.direction == .received ? "arrow.down.circle" : "arrow.up.circle")
                .font(.system(size: 16))
                .foregroundStyle(SettingsTheme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.direction == .received ? "从 \(record.device) 收到" : "发给 \(record.device)")
                    .font(.system(size: 13, weight: .medium))
                Text(summary(record))
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsTheme.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(outcome(record.outcome))
                .font(.system(size: 11))
                .foregroundStyle(record.outcome == .done ? SettingsTheme.textSecondary : .red)
        }
        .padding(.horizontal, SettingsTheme.cardPadding)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            if expanded == record.id {
                expanded = nil
            } else {
                expanded = record.id
                existing = model.existingPaths(in: record)
            }
        }
    }

    @ViewBuilder
    private func detail(_ record: TransferRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let text = record.text {
                Text(text).font(.system(size: 12)).textSelection(.enabled)
            }
            ForEach(Array(record.files.enumerated()), id: \.offset) { _, file in
                HStack {
                    Text(file.name).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(TransferCoordinator.size(file.size)).font(.system(size: 11)).foregroundStyle(SettingsTheme.textSecondary)
                    if let path = file.path {
                        let there = existing.contains(path)
                        Button(there ? "在访达中显示" : "文件已不在") { TransferCoordinator.reveal([path]) }
                            .buttonStyle(PillButtonStyle())
                            .disabled(!there)
                    } else {
                        Text("没收到").font(.system(size: 11)).foregroundStyle(.red)
                    }
                }
            }
        }
        .padding(.horizontal, SettingsTheme.cardPadding + 26)
        .padding(.bottom, 10)
    }

    private func summary(_ record: TransferRecord) -> String {
        let time = record.date.formatted(date: .abbreviated, time: .shortened)
        if let text = record.text { return "\(time) · 文字：\(text)" }
        return "\(time) · \(record.files.count) 个文件 · \(TransferCoordinator.size(record.totalSize))"
    }

    private func outcome(_ outcome: TransferRecord.Outcome) -> String {
        switch outcome {
        case .done: "成功"
        case .failed: "失败"
        case .rejected: "被拒"
        case .cancelled: "已取消"
        }
    }
}
```

- [ ] **Step 2: 接进设置窗口**（`UI/SettingsWindow.swift`）

1. `SettingsNavigation` 里 `@Published var remindersTab: RemindersTab = .setup` 下面加：
   ```swift
       /// 「手机互传」页当前显示哪一组
       @Published var transferTab: TransferTab = .setup
   ```
2. `SettingsPage` 里 `case clipboard = "历史剪贴板"` 下面加 `case transfer = "手机互传"`；`symbol` 的 switch 里 `case .clipboard: "doc.on.clipboard"` 下面加 `case .transfer: "iphone.and.arrow.forward"`。
3. 页头分段：在 `} else if page == .reminders {` 那个分支后面加：
   ```swift
                        } else if page == .transfer {
                            SegmentPicker(selection: $navigation.transferTab)
   ```
4. 页面 switch 里 `case .clipboard: ClipboardSettingsPage()` 下面加 `case .transfer: TransferSettingsPage()`。

- [ ] **Step 3: 编译 + 跑设置窗口测试**（先 build 命令同 Task 10 Step 2；再 `<Suite>` = `SettingsWindowTests`）。这一步 `BreakCoordinator.transfer` 还不存在会编译失败——**先做 Task 13 的 Step 1（BreakCoordinator 加 `transfer`）再回来编译**。

- [ ] **Step 4: 提交**

```bash
cd "<项目>" && git add RestBreak/RestBreak/Transfer/TransferSettingsPage.swift RestBreak/RestBreak/UI/SettingsWindow.swift && git commit -m "手机互传：设置页（设置 / 记录）

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 13: 接进 App：启动、休息、菜单、拖放

**Files:**
- Modify: `RestBreak/RestBreak/App/BreakCoordinator.swift`
- Modify: `RestBreak/RestBreak/App/RestBreakApp.swift`
- Modify: `RestBreak/RestBreak/UI/StatusBarController.swift`

- [ ] **Step 1: `BreakCoordinator` 持有并启动**

在 `let reminders = ReminderCoordinator()` 下面加：

```swift
    /// 手机互传（和提醒共用一个灵动岛）
    private(set) lazy var transfer = TransferCoordinator(island: reminders.island)
```

`start()` 里 `clipboard.start()` 下面加：

```swift
        // 休息中：陌生设备直接拒，传输提示等休息结束再显示
        transfer.isBusy = { [weak self] in
            guard let self else { return false }
            if case .onBreak = self.scheduler.state { return true }
            return false
        }
        transfer.start()
```

`handle(_:)` 里

```swift
            case .breakEnded:
                overlay.hide()
```

改成

```swift
            case .breakEnded:
                overlay.hide()
                transfer.breakEnded()
```

- [ ] **Step 2: `AppDelegate`**（`App/RestBreakApp.swift`）

`coordinator.clipboard.onOpenSettings = ...` 下面加：

```swift
        coordinator.transfer.onOpenSettings = { settingsWindow.show(page: .transfer) }
```

`applicationWillTerminate` 改成：

```swift
    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.flush()
        coordinator?.transfer.stop()
    }
```

- [ ] **Step 3: 菜单和拖放**（`UI/StatusBarController.swift`）

1. 类声明改成：
   ```swift
   final class StatusBarController: NSObject, NSMenuDelegate, NSWindowDelegate, NSDraggingDestination {
   ```
2. `private var lastSymbol = ""` 下面加：
   ```swift
       /// 菜单栏图标的窗口已经注册了拖放
       private var dropReady = false
   ```
3. `refresh()` 开头加：
   ```swift
           // 把文件拖到菜单栏图标上：发到手机（图标的窗口会把拖放消息转给 delegate，也就是这里）
           if !dropReady, let window = statusItem.button?.window {
               window.registerForDraggedTypes([.fileURL])
               window.delegate = self
               dropReady = true
           }
   ```
4. 菜单里 `addItem("剪贴板历史…", #selector(showClipboard))` 下面加：
   ```swift
           if coordinator.transfer.preferences.enabled {
               addItem("发送到手机…", #selector(sendToPhone))
           }
   ```
5. `@objc private func showClipboard()` 下面加：
   ```swift
       @objc private func sendToPhone() { coordinator.transfer.chooseAndSend() }

       // MARK: - 拖文件到图标

       func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
           coordinator.transfer.preferences.enabled && !Self.fileURLs(sender).isEmpty ? .copy : []
       }

       func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
           let urls = Self.fileURLs(sender)
           guard coordinator.transfer.preferences.enabled, !urls.isEmpty else { return false }
           coordinator.transfer.send(urls)
           return true
       }

       private static func fileURLs(_ info: NSDraggingInfo) -> [URL] {
           info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
       }
   ```

- [ ] **Step 4: 编译并跑全部测试**

```bash
cd "<项目>/RestBreak" && DD="$HOME/Library/Developer/Xcode/DerivedData/RestBreak-xieyihui-spike" && xcodebuild test -scheme RestBreak -destination platform=macOS -derivedDataPath "$DD" -allowProvisioningUpdates 2>&1 | tail -30
```

预期 `** TEST SUCCEEDED **`，测试总数比 299 多出本次新增的。

- [ ] **Step 5: 提交**（连同 Task 12 若还没提交）

```bash
cd "<项目>" && git add RestBreak/RestBreak/App/BreakCoordinator.swift RestBreak/RestBreak/App/RestBreakApp.swift RestBreak/RestBreak/UI/StatusBarController.swift && git commit -m "手机互传：接进 App（启动、休息、菜单、拖到图标发送）

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 14: 收尾：代码检查、文档、真机清单

**Files:**
- Create: `docs/transfer/2026-11-10-validation.md`
- Modify: `CLAUDE.md`、`docs/项目细节.md`、本计划（状态行）

- [ ] **Step 1: 按全局规则跑 `/simplify`**（检查新代码的复用和效率），有改动就重跑全部测试。

- [ ] **Step 2: 写真机清单** `docs/transfer/2026-11-10-validation.md`：

```markdown
# 手机互传验证记录

## 自动测试（2026-11-10）
- 新增：TransferProtocolTests、TransferDiscoveryTests、TransferPathsTests、TransferStoreTests、HTTPStreamReaderTests、ReceiveSessionTests、LocalSendServerTests、LocalSendClientTests、TransferCoordinatorTests。
- 组播在沙盒里能否收发：<填 Task 2 的结论>

## 真机清单（鸿蒙 + 卓易通装的 LocalSend）
1. 设置「手机互传」打开开关 → 选保存位置（选「下载」）→ 系统问「本地网络」点允许。
2. 手机 LocalSend「发送」页能看到「星期五 · <Mac 名>」。
3. 手机发 1 张照片：灵动岛问「收文件？」→ 点「收」→ 「下载/星期五」里有照片，岛上「收到 1 个文件」，点「在访达中显示」能定位。
4. 再发一次点「总是收」；第三次直接收，不再问；设置页「信任的设备」里有它，「取消信任」后又会问。
5. 一次发 5 个文件、发一个文件夹：都收到，文件夹结构保留；同名文件变成「名字 (1)」。
6. 手机发一段文字：⌘V 能粘出来，记录里有。
7. 点「拒」：手机提示被拒，记录里「被拒」。
8. 传到一半在手机上取消 / 关 Wi‑Fi：记录「已取消 / 失败」，没有半截文件。
9. 休息遮罩期间手机发来（信任设备）：不弹岛，休息结束后弹「收到 N 个文件」。
10. 菜单「发送到手机…」选 3 个文件 → 手机上接收 → 岛上显示进度和「已发给 …」。
11. 把文件 / 文件夹拖到菜单栏星期五图标上 → 同上。
12. 手机拒收电脑发的文件：岛上「没有接收」，记录「被拒」。
13. 记录页：点一条展开；把收到的文件删掉后再展开显示「文件已不在」。
14. 关掉开关：手机上「星期五」消失（可能要等手机刷新）。
15. 活动监视器：开关打开、空闲时 CPU 约 0%，「能耗」无明显变化。
16. 组播不通时：设置页填手机 IP →「附近的设备」出现手机，能发送。
```

- [ ] **Step 3: 更新 `docs/项目细节.md`**：末尾加一节「手机互传（LocalSend）」，写：协议做法 A（收 HTTP、发对接 HTTPS 指纹）、组播用 BSD 套接字的原因、文件流式写、一个会话 + 60 秒无动静结束、记录 30 天、数据位置 `Application Support/FridayTransfer/store.json`、设置键 `friday.transfer.settings.v1` / `friday.transfer.fingerprint`、休息时的规则、Task 2 的组播结论。

- [ ] **Step 4: 更新 `CLAUDE.md`**：
  - 「当前状态」加一条「手机互传（2026-11-10，本地 main，待真机验证）」，指向设计、计划、验证文档。
  - 「设置侧栏名字」加上「手机互传」（在「历史剪贴板」后）。
  - 「性能规则」的「不轮询」下加：手机互传开启时只监听一个 TCP 端口 + 一个组播套接字（DispatchSource），空闲 0 唤醒；关闭时都不开。
  - 「文档索引」加 `docs/transfer/`。

- [ ] **Step 5: 本计划开头状态改成「已完成（待真机验证）」，提交**

```bash
cd "<项目>" && git add docs/transfer CLAUDE.md docs/项目细节.md docs/superpowers/plans/2026-11-10-phone-transfer.md && git commit -m "手机互传：文档与真机验证清单

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

- [ ] **Step 6: 告诉用户**：用通俗中文说明做了什么、在 Xcode 里点三角运行后怎么按真机清单试；提醒第一次会弹「本地网络」授权。
