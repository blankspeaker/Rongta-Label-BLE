// SPDX-License-Identifier: GPL-3.0-or-later
// Talks to the launchd helper. This process does not open Bluetooth itself.
import Darwin
import Foundation

enum HelperSocket {
    static func exchange(line: String, timeoutSeconds: Int) -> CommandResult {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        if fd < 0 {
            return unreachable()
        }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(47221).bigEndian)
        _ = "127.0.0.1".withCString { inet_pton(AF_INET, $0, &addr.sin_addr) }
        var tv = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        let tvLen = socklen_t(MemoryLayout<timeval>.size)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, tvLen)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, tvLen)
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if connected != 0 {
            return unreachable()
        }
        let payload = Array((line + "\n").utf8)
        var sent = 0
        while sent < payload.count {
            let n = payload.withUnsafeBufferPointer { buf in
                write(fd, buf.baseAddress! + sent, payload.count - sent)
            }
            if n < 0 {
                if errno == EINTR { continue }
                return unreachable()
            }
            if n == 0 { break }
            sent += n
        }
        shutdown(fd, SHUT_WR)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while data.count < 1024 * 1024 {
            let n = read(fd, &buffer, buffer.count)
            if n == 0 { break }
            if n < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { break }
                break
            }
            data.append(buffer, count: n)
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        return finish(text)
    }

    /// Reads the helper reply as it arrives. `onUpdate` sees the bytes so far.
    static func exchangeStreaming(line: String, timeoutSeconds: Int, onUpdate: (String) -> Void) -> CommandResult {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        if fd < 0 {
            return unreachable()
        }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(47221).bigEndian)
        _ = "127.0.0.1".withCString { inet_pton(AF_INET, $0, &addr.sin_addr) }
        var tv = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        let tvLen = socklen_t(MemoryLayout<timeval>.size)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, tvLen)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, tvLen)
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if connected != 0 {
            return unreachable()
        }
        let payload = Array((line + "\n").utf8)
        var sent = 0
        while sent < payload.count {
            let n = payload.withUnsafeBufferPointer { buf in
                write(fd, buf.baseAddress! + sent, payload.count - sent)
            }
            if n < 0 {
                if errno == EINTR { continue }
                return unreachable()
            }
            if n == 0 { break }
            sent += n
        }
        shutdown(fd, SHUT_WR)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while data.count < 1024 * 1024 {
            let n = read(fd, &buffer, buffer.count)
            if n == 0 { break }
            if n < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { break }
                break
            }
            data.append(buffer, count: n)
            if let text = String(data: data, encoding: .utf8) {
                onUpdate(text)
            }
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        return finish(text)
    }

    /// One open scan. The write side stays open so the helper keeps listening until `session` is cancelled or the helper closes.
    static func exchangeWatch(line: String, session: WatchSession, onUpdate: (String) -> Void) -> CommandResult {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        if fd < 0 {
            return unreachable()
        }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(47221).bigEndian)
        _ = "127.0.0.1".withCString { inet_pton(AF_INET, $0, &addr.sin_addr) }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if connected != 0 || !session.take(fd) {
            close(fd)
            if session.isCancelled {
                return CommandResult(status: 0, stdout: "", stderr: "")
            }
            return unreachable()
        }
        defer { session.closeIfOwned() }
        let payload = Array((line + "\n").utf8)
        var sent = 0
        while sent < payload.count {
            let n = payload.withUnsafeBufferPointer { buf in
                write(fd, buf.baseAddress! + sent, payload.count - sent)
            }
            if n < 0 {
                if errno == EINTR { continue }
                if session.isCancelled {
                    return CommandResult(status: 0, stdout: "", stderr: "")
                }
                return unreachable()
            }
            if n == 0 { break }
            sent += n
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while data.count < 1024 * 1024 {
            let n = read(fd, &buffer, buffer.count)
            if n == 0 { break }
            if n < 0 {
                if errno == EINTR { continue }
                if session.isCancelled {
                    break
                }
                break
            }
            data.append(buffer, count: n)
            if let text = String(data: data, encoding: .utf8) {
                onUpdate(text)
            }
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        if session.isCancelled {
            return CommandResult(status: 0, stdout: text, stderr: "")
        }
        return finish(text)
    }

    private static func finish(_ text: String) -> CommandResult {
        let reply = SetupLogic.parseHelperReply(text)
        if reply.ok {
            return CommandResult(status: 0, stdout: text, stderr: "")
        }
        return CommandResult(status: 1, stdout: text, stderr: reply.message.isEmpty ? text : reply.message)
    }

    private static func unreachable() -> CommandResult {
        CommandResult(status: 1, stdout: "", stderr: "Could not reach the Bluetooth helper.")
    }
}

@_silgen_name("rongta_spawn_disclaimed_scan")
func rongta_spawn_disclaimed_scan(
    _ path: UnsafePointer<CChar>,
    _ all: Int32,
    _ out: UnsafeMutablePointer<CChar>,
    _ outLen: Int,
    _ err: UnsafeMutablePointer<CChar>,
    _ errLen: Int
) -> Int32

/// The setup app closes this to end a WATCH. The helper treats that close as the end of the scan.
final class WatchSession: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let current = fd
        fd = -1
        lock.unlock()
        if current >= 0 {
            shutdown(current, SHUT_RDWR)
            close(current)
        }
    }

    /// Takes ownership of `newFD`. Returns false when the session was already cancelled.
    func take(_ newFD: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if cancelled {
            return false
        }
        fd = newFD
        return true
    }

    func closeIfOwned() {
        lock.lock()
        let current = fd
        fd = -1
        lock.unlock()
        if current >= 0 {
            close(current)
        }
    }
}

enum DisclaimedSpawn {
    /// Last resort if launchd cannot start the helper. TCC is disclaimed onto rongta-ble.
    static func scan(path: String) -> CommandResult {
        let cap = 65536
        let out = UnsafeMutablePointer<CChar>.allocate(capacity: cap)
        let err = UnsafeMutablePointer<CChar>.allocate(capacity: cap)
        defer {
            out.deallocate()
            err.deallocate()
        }
        out.initialize(repeating: 0, count: cap)
        err.initialize(repeating: 0, count: cap)
        let code = path.withCString { rongta_spawn_disclaimed_scan($0, 0, out, cap, err, cap) }
        return CommandResult(status: code, stdout: String(cString: out), stderr: String(cString: err))
    }
}
