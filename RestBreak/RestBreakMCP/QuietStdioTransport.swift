import Foundation
import Logging
import MCP

/// 标准输入输出传输：和 SDK 自带的 StdioTransport 一样按行收发 JSON，
/// 区别是读取用「阻塞读」——没有数据时线程睡着，一点 CPU 都不用。
/// SDK 的版本把标准输入设成非阻塞，没数据时每 10 毫秒醒来查一次（实测空闲也占约 1% CPU），
/// 而这个小程序在每个打开的 Claude Code / Codex 会话里都会常驻一个，所以自己写一个。
actor QuietStdioTransport: Transport {
    nonisolated let logger = Logger(label: "friday.stdio", factory: { _ in SwiftLogNoOpLogHandler() })

    private let stream: AsyncThrowingStream<Data, Swift.Error>
    private let continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation
    private var started = false

    init() {
        (stream, continuation) = AsyncThrowingStream.makeStream()
    }

    func connect() async throws {
        guard !started else { return }
        started = true
        let continuation = self.continuation
        // 单独一个线程阻塞读标准输入；客户端关闭管道（EOF）时结束
        let thread = Thread {
            var pending = Data()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let count = read(STDIN_FILENO, &buffer, buffer.count)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { break }
                pending.append(contentsOf: buffer[0..<count])
                while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = pending[pending.startIndex..<newline]
                    pending = Data(pending[(newline + 1)...])
                    if !line.isEmpty { continuation.yield(Data(line)) }
                }
            }
            continuation.finish()
        }
        thread.name = "friday.stdin"
        thread.start()
    }

    func disconnect() async {
        continuation.finish()
    }

    /// 一条消息一行；阻塞写（客户端读得很快，消息也小）
    func send(_ data: Data) async throws {
        var message = data
        message.append(UInt8(ascii: "\n"))
        try message.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = write(STDOUT_FILENO, base + offset, raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw MCPError.internalError("写标准输出失败：errno \(errno)")
                }
                offset += written
            }
        }
    }

    nonisolated func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        stream
    }
}
