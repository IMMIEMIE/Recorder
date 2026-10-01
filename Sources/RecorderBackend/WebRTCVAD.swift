import Foundation
import Cwebrtcvad

/// Thin wrapper over the WebRTC VAD C implementation (aggressiveness mode 2 in production).
public final class WebRTCVAD {
    private var handle: OpaquePointer?

    public init(aggressiveness: Int32) throws {
        var created: OpaquePointer?
        guard WebRtcVad_Create(&created) == 0, let created else {
            throw BackendError.value("VAD 初始化失败")
        }
        handle = created
        WebRtcVad_Init(created)
        WebRtcVad_set_mode(created, aggressiveness)
    }

    deinit {
        if let handle { WebRtcVad_Free(handle) }
    }

    public func isSpeech(_ pcm: Data, rate: Int32 = Int32(Backend.rate)) -> Bool {
        pcm.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            guard let handle, let base = raw.baseAddress, raw.count >= 2 else { return false }
            return WebRtcVad_Process(handle, rate, base.assumingMemoryBound(to: Int16.self), Int32(raw.count / 2)) == 1
        }
    }
}
