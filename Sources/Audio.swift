import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import os
import ScreenCaptureKit

enum Source: String, CaseIterable, Sendable {
    case room = "회의실"
    case online = "온라인"
}

struct ScribeError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

private struct ConversionInput: @unchecked Sendable {
    // The converter consumes this buffer synchronously on the capture queue.
    let buffer: AVAudioPCMBuffer
}

final class CaptureOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let channels: [Source: SpeechChannel]
    private let levels: @Sendable (Source, Double) -> Void
    private let failure: @Sendable (String, Bool) -> Void
    private let startedAt = ProcessInfo.processInfo.systemUptime
    // Both output types use the same serial queue.
    private var converters: [Source: AVAudioConverter] = [:]
    private var lastLevel: [Source: TimeInterval] = [:]
    private var reportedFailures: Set<Source> = []
    let queue = DispatchQueue(label: "local.meetingscribe.capture")

    init(channels: [Source: SpeechChannel], levels: @escaping @Sendable (Source, Double) -> Void,
         failure: @escaping @Sendable (String, Bool) -> Void) {
        self.channels = channels
        self.levels = levels
        self.failure = failure
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        failure(error.localizedDescription, true)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        let source: Source
        switch type {
        case .audio: source = .online
        case .microphone: source = .room
        default: return
        }
        accept(sampleBuffer, from: source)
    }

    func accept(_ sampleBuffer: CMSampleBuffer, from source: Source) {
        guard let channel = channels[source], sampleBuffer.numSamples > 0 else { return }
        guard let description = sampleBuffer.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let format = AVAudioFormat(streamDescription: asbd),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                           frameCapacity: AVAudioFrameCount(sampleBuffer.numSamples)) else {
            reportConversionFailure(source)
            return
        }
        buffer.frameLength = buffer.frameCapacity
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(buffer.frameLength), into: buffer.mutableAudioBufferList
        ) == noErr else {
            reportConversionFailure(source)
            return
        }

        updateLevel(buffer, source: source)
        let endTime = ProcessInfo.processInfo.systemUptime - startedAt
        if format == channel.format {
            channel.append(buffer, endTime: endTime)
            return
        }
        if converters[source]?.inputFormat != format {
            converters[source] = AVAudioConverter(from: format, to: channel.format)
        }
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * channel.format.sampleRate / format.sampleRate)) + 32
        guard let converter = converters[source],
              let converted = AVAudioPCMBuffer(pcmFormat: channel.format, frameCapacity: capacity) else {
            reportConversionFailure(source)
            return
        }
        let supplied = OSAllocatedUnfairLock(initialState: false)
        let input = ConversionInput(buffer: buffer)
        var error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, status in
            let alreadySupplied = supplied.withLock { used in
                defer { used = true }
                return used
            }
            status.pointee = alreadySupplied ? .noDataNow : .haveData
            return alreadySupplied ? nil : input.buffer
        }
        if status == .error {
            reportConversionFailure(source)
        } else if converted.frameLength > 0 {
            channel.append(converted, endTime: endTime)
        }
    }

    private func reportConversionFailure(_ source: Source) {
        if reportedFailures.insert(source).inserted {
            failure("\(source.rawValue) 오디오를 읽는 중 오류가 발생했습니다.", false)
        }
    }

    private func updateLevel(_ buffer: AVAudioPCMBuffer, source: Source) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - (lastLevel[source] ?? 0) >= 0.12 else { return }
        lastLevel[source] = now
        let frames = Int(buffer.frameLength)
        let stride = buffer.stride
        var peak = 0.0
        if let samples = buffer.floatChannelData {
            for index in 0..<frames { peak = max(peak, abs(Double(samples[0][index * stride]))) }
        } else if let samples = buffer.int16ChannelData {
            for index in 0..<frames { peak = max(peak, abs(Double(samples[0][index * stride])) / 32768) }
        } else if let samples = buffer.int32ChannelData {
            for index in 0..<frames { peak = max(peak, abs(Double(samples[0][index * stride])) / 2147483648) }
        }
        levels(source, min(1, sqrt(peak)))
    }
}

@MainActor
enum MeetingCapture {
    static func apps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            let id = $0.bundleIdentifier ?? ""
            return id == "us.zoom.xos" || id == "com.microsoft.teams" || id == "com.microsoft.teams2"
        }
    }

    static func start(bundleID: String, output: CaptureOutput) async throws -> SCStream {
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            throw ScribeError("시스템 설정 → 개인정보 보호 및 보안 → 마이크에서 접근을 허용하세요.")
        }
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw ScribeError("시스템 설정 → 개인정보 보호 및 보안 → 화면 및 시스템 오디오 녹음에서 권한을 허용한 뒤 앱을 다시 열어주세요.")
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first,
              let app = content.applications.first(where: { $0.bundleIdentifier == bundleID }) else {
            throw ScribeError("Zoom 또는 Teams 데스크톱 앱을 열고 회의에 접속한 뒤 다시 시도하세요.")
        }
        let filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 1
        config.captureMicrophone = true
        config.microphoneCaptureDeviceID = AVCaptureDevice.default(.microphone, for: .audio, position: .unspecified)?.uniqueID
        let stream = SCStream(filter: filter, configuration: config, delegate: output)
        try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: output.queue)
        try stream.addStreamOutput(output, type: .microphone, sampleHandlerQueue: output.queue)
        try await stream.startCapture()
        return stream
    }
}

// A room-only session requests microphone access without starting ScreenCaptureKit.
final class MicrophoneCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let controlQueue = DispatchQueue(label: "local.meetingscribe.microphone")
    private let destination: CaptureOutput

    private init(destination: CaptureOutput) { self.destination = destination }

    static func start(output: CaptureOutput) async throws -> MicrophoneCapture {
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            throw ScribeError("시스템 설정 → 개인정보 보호 및 보안 → 마이크에서 접근을 허용하세요.")
        }
        let capture = MicrophoneCapture(destination: output)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            capture.controlQueue.async {
                do {
                    try capture.startSession()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        return capture
    }

    private func startSession() throws {
        guard let device = AVCaptureDevice.default(.microphone, for: .audio, position: .unspecified) else {
            throw ScribeError("사용할 수 있는 마이크가 없습니다.")
        }
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioDataOutput()
        guard session.canAddInput(input), session.canAddOutput(output) else {
            throw ScribeError("마이크 입력을 연결할 수 없습니다.")
        }
        session.addInput(input)
        session.addOutput(output)
        output.setSampleBufferDelegate(self, queue: destination.queue)
        session.startRunning()
        guard session.isRunning else { throw ScribeError("마이크를 시작할 수 없습니다.") }
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            controlQueue.async { [self] in
                session.stopRunning()
                continuation.resume()
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        destination.accept(sampleBuffer, from: .room)
    }
}
