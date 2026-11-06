import AVFoundation
import CoreMedia
import ScreenCaptureKit

final class CallAudio: NSObject, SCStreamOutput, SCStreamDelegate {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
    private let queue = DispatchQueue(label: "charlado.call-audio")
    private var stream: SCStream?
    private var capture: AudioCapture?
    private var enabled = false
    private var didFail = false
    private var enabledAt = 0.0
    private var activeOffset = 0.0
    private var firstOffset: Double?

    func start(display: SCDisplay, application: SCRunningApplication) async throws {
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 1
        configuration.width = 16
        configuration.height = 16
        configuration.minimumFrameInterval = CMTime(seconds: 1, preferredTimescale: 1)
        let filter = SCContentFilter(display: display, including: [application], exceptingWindows: [])
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func enable(at offset: Double) {
        queue.sync {
            activeOffset = offset
            enabledAt = ProcessInfo.processInfo.systemUptime
            enabled = true
        }
    }

    func pause() { queue.sync { enabled = false } }

    func stop() async -> Double? {
        pause()
        if let stream {
            try? await stream.stopCapture()
            self.stream = nil
        }
        return queue.sync {
            guard let capture, capture.finish() == .recorded else { return nil }
            return firstOffset
        }
    }

    var incomplete: Bool { queue.sync { didFail } }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        queue.async { self.didFail = true }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio, enabled, sample.isValid,
              let description = CMSampleBufferGetFormatDescription(sample),
              let pcm = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(cmAudioFormatDescription: description),
                                         frameCapacity: AVAudioFrameCount(CMSampleBufferGetNumSamples(sample)))
        else { return }
        pcm.frameLength = pcm.frameCapacity
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0,
                frameCount: Int32(pcm.frameLength), into: pcm.mutableAudioBufferList) == noErr
        else { didFail = true; return }
        do {
            if capture == nil {
                capture = try AudioCapture(url: url, format: pcm.format)
                firstOffset = activeOffset + ProcessInfo.processInfo.systemUptime - enabledAt
            }
            capture?.append(pcm)
        } catch {
            didFail = true
        }
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}
