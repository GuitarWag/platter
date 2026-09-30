import Foundation
import AVFoundation
import os

/// The sound of a record under the hand. While the record is held, this voice plays a
/// decoded window of the track around the hand position: it follows the hand at the hand's
/// speed (forward, backward, or still = silent), with linear interpolation.
///
/// The main thread sets the target position; the render thread moves toward it a block at a
/// time, with smoothing so a 60 Hz hand update does not sound stepped.
final class ScratchVoice: @unchecked Sendable {
    private struct State {
        var left: [Float] = []
        var right: [Float] = []
        /// File frame of `left[0]`.
        var start: Double = 0
        var active = false
        /// Where the hand is (file frames) and where the audio is.
        var target: Double = 0
        var smoothed: Double = 0
        var current: Double = 0
        /// 0 ... 1 fade, so grabbing and letting go do not click.
        var gain: Float = 0
        /// Follows the record speed: a cartridge outputs nothing when the record stands
        /// still, so a still hand is silent (not a DC offset).
        var motion: Float = 0
    }

    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    let format: AVAudioFormat

    init(sampleRate: Double) {
        format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
    }

    /// Start at file frame `frame`, with an empty window until `load` arrives.
    func begin(at frame: Double) {
        state.withLockUnchecked {
            $0.active = true
            $0.target = frame
            $0.smoothed = frame
            $0.current = frame
            $0.left = []
            $0.right = []
        }
    }

    func load(left: [Float], right: [Float], start: Double) {
        state.withLockUnchecked {
            $0.left = left
            $0.right = right
            $0.start = start
        }
    }

    func move(to frame: Double) {
        state.withLockUnchecked { $0.target = frame }
    }

    func end() {
        state.withLockUnchecked { $0.active = false }
    }

    /// Render thread.
    func render(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, frames n: Int) {
        state.withLockUnchecked { s in
            guard s.active || s.gain > 1e-4 else {
                l.update(repeating: 0, count: n)
                r.update(repeating: 0, count: n)
                return
            }
            let from = s.current
            s.smoothed += (s.target - s.smoothed) * 0.5
            let to = s.smoothed
            let fadeTarget: Float = s.active ? 1 : 0
            // Speed relative to normal play: 1 = n frames per n samples.
            let speed = Float(abs(to - from) / Double(n))
            let motionTarget = min(1, speed / 0.1)
            let count = s.left.count
            for i in 0..<n {
                s.gain += (fadeTarget - s.gain) * 0.01
                s.motion += (motionTarget - s.motion) * 0.005
                let p = from + (to - from) * Double(i + 1) / Double(n) - s.start
                guard count > 1, p >= 0, p < Double(count - 1) else {
                    l[i] = 0
                    r[i] = 0
                    continue
                }
                let k = Int(p), f = Float(p - Double(k))
                let g = s.gain * s.motion
                l[i] = (s.left[k] + (s.left[k + 1] - s.left[k]) * f) * g
                r[i] = (s.right[k] + (s.right[k + 1] - s.right[k]) * f) * g
            }
            s.current = to
        }
    }

    /// The source node that plays this voice. Built outside the main actor: the block runs
    /// on the audio thread.
    nonisolated func makeNode() -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { [self] _, _, frameCount, bufferList in
            let abl = UnsafeMutableAudioBufferListPointer(bufferList)
            guard abl.count >= 2,
                  let l = abl[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = abl[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            self.render(l, r, frames: Int(frameCount))
            return noErr
        }
    }

    /// Decode `seconds` around `frame` of the file at `url`, as float stereo at `sampleRate`.
    static func decodeWindow(url: URL, around frame: Double, seconds: Double)
        throws -> (left: [Float], right: [Float], start: Double) {
        let file = try AVAudioFile(forReading: url)
        let sr = file.processingFormat.sampleRate
        let start = max(0, AVAudioFramePosition(frame - seconds / 2 * sr))
        let count = AVAudioFrameCount(min(Double(file.length - start), seconds * sr))
        guard count > 0, let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count) else {
            return ([], [], 0)
        }
        file.framePosition = start
        try file.read(into: buf, frameCount: count)
        guard let data = buf.floatChannelData else { return ([], [], 0) }
        let n = Int(buf.frameLength), ch = Int(buf.format.channelCount)
        let left = Array(UnsafeBufferPointer(start: data[0], count: n))
        let right = ch > 1 ? Array(UnsafeBufferPointer(start: data[1], count: n)) : left
        return (left, right, Double(start))
    }
}
