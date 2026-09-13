import Foundation
import Darwin

final class Transport: @unchecked Sendable {
    private var fd: Int32 = -1
    private let queue = DispatchQueue(label: "recorder.socket.write")
    private let lock = NSLock()
    private var buffered = 0
    private var closed = false
    var onEvent: (([String: Any]) -> Void)?
    var onFailure: ((String) -> Void)?

    func connect(path: String) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var noSig: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSig, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { throw failure("连接路径过长") }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 104) { destination in
                _ = path.withCString { strcpy(destination, $0) }
            }
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else { Darwin.close(fd); fd = -1; throw failure("推理连接尚未就绪") }
        DispatchQueue.global(qos: .userInitiated).async { [self] in readLoop() }
    }

    private func failure(_ text: String) -> NSError { NSError(domain: "Recorder", code: 1, userInfo: [NSLocalizedDescriptionKey:text]) }

    func send(_ message: [String: Any]) {
        guard let payload = try? JSONSerialization.data(withJSONObject: message) else { return }
        _ = enqueue(kind: 74, payload: payload, audio: false)
    }

    func audio(_ pcm: Data, session: String, sequence: Int, start: Int) -> Bool {
        let meta: [String: Any] = ["session_id":session, "sequence":sequence, "start_sample":start, "sample_rate":16000, "channels":1, "format":"s16le"]
        guard let header = try? JSONSerialization.data(withJSONObject: meta) else { return false }
        var size = UInt32(header.count).bigEndian
        var payload = Data(bytes: &size, count: 4)
        payload.append(header); payload.append(pcm)
        return enqueue(kind: 65, payload: payload, audio: true)
    }

    private func enqueue(kind: UInt8, payload: Data, audio: Bool) -> Bool {
        lock.lock()
        if closed || (audio && buffered + payload.count > 320_000) { lock.unlock(); return false }
        buffered += payload.count
        lock.unlock()
        var size = UInt32(payload.count + 1).bigEndian
        var data = Data(bytes: &size, count: 4)
        data.append(kind); data.append(payload)
        queue.async { [self, data] in
            defer { lock.lock(); buffered -= payload.count; lock.unlock() }
            var offset = 0
            let succeeded = data.withUnsafeBytes { bytes -> Bool in
                while offset < data.count {
                    let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), data.count - offset)
                    if count <= 0 { return false }
                    offset += count
                }
                return true
            }
            if !succeeded { onFailure?("推理进程连接中断，请重新连接") }
        }
        return true
    }

    private func read(_ count: Int) -> Data? {
        var data = Data(count: count)
        let ok = data.withUnsafeMutableBytes { bytes -> Bool in
            var offset = 0
            while offset < count {
                let n = Darwin.read(fd, bytes.baseAddress!.advanced(by: offset), count - offset)
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
        return ok ? data : nil
    }

    private func readLoop() {
        while let header = read(4) {
            let size = header.reduce(0) { ($0 << 8) | Int($1) }
            guard size > 1, size <= 262144, let body = read(size), body.first == 74,
                  let event = try? JSONSerialization.jsonObject(with: body.dropFirst()) as? [String: Any] else { break }
            onEvent?(event)
        }
        lock.lock(); let expected = closed; lock.unlock()
        if !expected { onFailure?("推理进程已退出，已确认文字仍保留") }
    }

    func close() {
        lock.lock(); closed = true; lock.unlock()
        if fd >= 0 { shutdown(fd, SHUT_RDWR) }
        queue.sync { if fd >= 0 { Darwin.close(fd); fd = -1 } }
    }
}
