import Darwin
import Foundation
import Metal

@MainActor
final class MinutesServer {
    static let shared = MinutesServer()

    private struct Completion: Decodable {
        let content: String
        let truncated: Bool?
        let stop_type: String?
    }

    private let session = URLSession(configuration: .ephemeral)
    private var process: Process?
    private var baseURL: URL?
    private var key = ""
    private var warming: Task<Void, Error>?

    func prewarm() {
        guard Minutes.unavailableReason == nil else { return }
        startIfNeeded()
    }

    private func startIfNeeded() {
        guard warming == nil, process?.isRunning != true else { return }
        warming = Task {
            defer { warming = nil }
            if MTLCreateSystemDefaultDevice() != nil {
                do { try await launch(useGPU: true); return }
                catch is CancellationError { stopProcess(); throw CancellationError() }
                catch { stopProcess() }
            }
            do { try await launch(useGPU: false) }
            catch { stopProcess(); throw error }
        }
    }

    func complete(_ prompt: String) async throws -> String {
        try Task.checkCancellation()
        startIfNeeded()
        if let warming {
            try await withTaskCancellationHandler {
                try await warming.value
            } onCancel: {
                warming.cancel()
            }
        }
        try Task.checkCancellation()
        guard let baseURL, process?.isRunning == true else {
            throw ScribeError("로컬 회의록 서버를 시작할 수 없습니다.")
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("completion"), timeoutInterval: 900)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "prompt": prompt, "n_predict": 3000, "temperature": 0.15,
            "stop": ["<|im_end|>", "<|endoftext|>"], "cache_prompt": true
        ])
        let payload: Data
        let response: URLResponse
        do {
            (payload, response) = try await session.data(for: request)
            try Task.checkCancellation()
        } catch {
            if Task.isCancelled {
                // Make the active slot available even if the server has not
                // detected a disconnected HTTP client yet.
                stopProcess()
                throw CancellationError()
            }
            throw error
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ScribeError("로컬 회의록 모델 요청이 실패했습니다.")
        }
        let completion = try JSONDecoder().decode(Completion.self, from: payload)
        guard completion.truncated != true, completion.stop_type != "limit" else {
            throw ScribeError("회의록이 생성 한도를 넘었습니다. 이전 초안을 보관했습니다.")
        }
        return completion.content
    }

    func shutdown() {
        warming?.cancel()
        stopProcess()
    }

    private func stopProcess() {
        if let process, process.isRunning { process.terminate() }
        process = nil
        baseURL = nil
    }

    private func launch(useGPU: Bool) async throws {
        try Task.checkCancellation()
        let port = try Self.availablePort()
        guard let address = URL(string: "http://127.0.0.1:\(port)") else {
            throw ScribeError("로컬 회의록 서버 주소를 만들 수 없습니다.")
        }
        key = UUID().uuidString
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        let watchParent = """
            owner=$1
            shift
            "$@" &
            server=$!
            trap 'kill "$server" 2>/dev/null; wait "$server"; exit 0' TERM INT HUP
            while kill -0 "$owner" 2>/dev/null && kill -0 "$server" 2>/dev/null; do sleep 1; done
            kill "$server" 2>/dev/null
            wait "$server"
            """
        child.arguments = ["-c", watchParent, "meetingscribe-server",
                           String(ProcessInfo.processInfo.processIdentifier), Minutes.executable.path] + [
            "-m", Minutes.model.path, "--host", "127.0.0.1", "--port", String(port),
            "--api-key", key, "--no-webui", "--parallel", "1", "-c", "16384",
            "-t", String(ScribeResources.computeThreads), "--log-disable"
        ] + (useGPU ? [] : ["--device", "none", "--no-op-offload", "-ngl", "0"])
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        process = child
        for _ in 0..<300 {
            try Task.checkCancellation()
            guard child.isRunning else { break }
            var request = URLRequest(url: address.appendingPathComponent("health"), timeoutInterval: 1)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            if let (_, response) = try? await session.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                baseURL = address
                return
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw ScribeError("로컬 회의록 서버에서 모델을 불러오지 못했습니다.")
    }

    private static func availablePort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ScribeError("로컬 포트를 열 수 없습니다.") }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let status = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                guard bind(descriptor, $0, length) == 0 else { return Int32(-1) }
                return getsockname(descriptor, $0, &length)
            }
        }
        guard status == 0 else { throw ScribeError("로컬 포트를 할당할 수 없습니다.") }
        return UInt16(bigEndian: address.sin_port)
    }
}
