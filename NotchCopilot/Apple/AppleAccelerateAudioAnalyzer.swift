import Accelerate
import AVFoundation
import Foundation

struct AudioAnalysisResult: Sendable, Hashable {
    var rms: Float
    var peak: Float
}

struct AppleAccelerateAudioAnalyzer {
    func analyze(_ buffer: AVAudioPCMBuffer) -> AudioAnalysisResult {
        guard buffer.frameLength > 0 else {
            return AudioAnalysisResult(rms: 0, peak: 0)
        }
        let count = vDSP_Length(buffer.frameLength)

        var rms: Float = 0
        var peak: Float = 0
        if let channelData = buffer.floatChannelData {
            let channel = channelData[0]
            vDSP_rmsqv(channel, 1, &rms, count)
            vDSP_maxmgv(channel, 1, &peak, count)
        } else if let channelData = buffer.int16ChannelData {
            let channel = channelData[0]
            var floatSamples = [Float](repeating: 0, count: Int(buffer.frameLength))
            vDSP_vflt16(channel, 1, &floatSamples, 1, count)
            var scale = Float(Int16.max)
            vDSP_vsdiv(floatSamples, 1, &scale, &floatSamples, 1, count)
            vDSP_rmsqv(floatSamples, 1, &rms, count)
            vDSP_maxmgv(floatSamples, 1, &peak, count)
        }
        return AudioAnalysisResult(rms: min(max(rms, 0), 1), peak: min(max(peak, 0), 1))
    }

    func normalizedLevel(from rms: Float) -> CGFloat {
        CGFloat(min(max(rms * 22, 0.02), 1))
    }
}
