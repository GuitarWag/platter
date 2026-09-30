import Foundation
import AVFoundation
import CoreAudio
import os

/// One deck's headphone feed: a stereo ring buffer. The mixer's tap thread writes post-EQ,
/// pre-fader audio when PFL is on; the headphone engine's render thread reads it.
final class CueFeed: @unchecked Sendable {
    private struct Ring {
        var left: [Float]
        var right: [Float]
        var write = 0
        var read = 0
        var count = 0
        var enabled = false
    }

    /// 1 s at 48 kHz. The feed is kept near `target` frames, so drift between two devices'
    /// clocks shows up as a skip, not as growing delay.
    private static let capacity = 48_000
    private static let target = 2_048
    private let ring = OSAllocatedUnfairLock(uncheckedState: Ring(left: [Float](repeating: 0, count: capacity),
                                                                    right: [Float](repeating: 0, count: capacity)))

    var enabled: Bool {
        get { ring.withLockUnchecked { $0.enabled } }
        set { ring.withLockUnchecked { $0.enabled = newValue; $0.count = 0; $0.read = $0.write } }
    }

    /// Frames waiting to be played.
    var buffered: Int { ring.withLockUnchecked { $0.count } }

    /// Tap thread. Mono buffers go to both sides.
    func write(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        let n = Int(buffer.frameLength), ch = Int(buffer.format.channelCount)
        ring.withLockUnchecked { r in
            guard r.enabled else { return }
            for i in 0..<n {
                r.left[r.write] = data[0][i]
                r.right[r.write] = data[ch > 1 ? 1 : 0][i]
                r.write = (r.write + 1) % Self.capacity
            }
            r.count = min(Self.capacity, r.count + n)
            // Too far behind (the headphone device runs slower): drop the oldest audio.
            if r.count > Self.target * 4 {
                let drop = r.count - Self.target
                r.read = (r.read + drop) % Self.capacity
                r.count -= drop
            }
        }
    }

    /// Render thread. Adds up to `n` frames into `l` and `r`; silence where the feed is empty.
    func mix(into l: UnsafeMutablePointer<Float>, _ rr: UnsafeMutablePointer<Float>, frames n: Int) {
        ring.withLockUnchecked { r in
            guard r.enabled else { return }
            let take = min(n, r.count)
            for i in 0..<take {
                l[i] += r.left[r.read]
                rr[i] += r.right[r.read]
                r.read = (r.read + 1) % Self.capacity
            }
            r.count -= take
        }
    }
}

/// The headphone output (PFL): a second engine on a chosen output device that plays the cue
/// feeds of the decks with PFL on.
@MainActor
final class CueOutput {
    let feeds: [DeckID: CueFeed] = [.a: CueFeed(), .b: CueFeed()]
    private var engine: AVAudioEngine?
    private(set) var deviceID: AudioDeviceID?
    /// Headphone level, 0 ... 1.
    var volume: Float = 0.8 {
        didSet { engine?.mainMixerNode.outputVolume = volume }
    }

    struct Device: Identifiable, Hashable {
        let id: AudioDeviceID
        let name: String
    }

    /// Start (or move) the headphone engine on `device`. `sampleRate` is the main graph's
    /// rate, which is the rate of the cue feeds; the engine converts to the device.
    func start(device: AudioDeviceID, sampleRate: Double) throws {
        stop()
        let e = AVAudioEngine()
        guard let unit = e.outputNode.audioUnit else { throw LibraryError("No headphone output unit.") }
        var dev = device
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                          &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else { throw LibraryError("Could not select the headphone device (\(status)).") }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            throw LibraryError("Unsupported sample rate \(sampleRate).")
        }
        let source = Self.makeSource(feeds: Array(feeds.values), format: format)
        e.attach(source)
        e.connect(source, to: e.mainMixerNode, format: format)
        e.mainMixerNode.outputVolume = volume
        e.prepare()
        try e.start()
        engine = e
        deviceID = device
    }

    func stop() {
        engine?.stop()
        engine = nil
        deviceID = nil
    }

    var isRunning: Bool { engine?.isRunning == true }

    /// The render block runs on the headphone device's audio thread; it touches only feeds.
    nonisolated private static func makeSource(feeds: [CueFeed], format: AVAudioFormat) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { _, _, frameCount, bufferList in
            let abl = UnsafeMutableAudioBufferListPointer(bufferList)
            let n = Int(frameCount)
            guard abl.count >= 2,
                  let l = abl[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = abl[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            l.update(repeating: 0, count: n)
            r.update(repeating: 0, count: n)
            for f in feeds { f.mix(into: l, r, frames: n) }
            return noErr
        }
    }

    /// Output devices, from CoreAudio.
    static func outputDevices() -> [Device] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                     mScope: kAudioObjectPropertyScopeOutput,
                                                     mElement: kAudioObjectPropertyElementMain)
            var s: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &s) == noErr, s > 0 else { return nil }
            var nameAddr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                      mScope: kAudioObjectPropertyScopeGlobal,
                                                      mElement: kAudioObjectPropertyElementMain)
            var name: Unmanaged<CFString>?
            var ns = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &ns, &name) == noErr, let n = name else { return nil }
            let deviceName = n.takeRetainedValue() as String
            // Hidden aggregates that CoreAudio makes for apps are not real outputs.
            guard !deviceName.hasPrefix("CADefaultDeviceAggregate") else { return nil }
            return Device(id: id, name: deviceName)
        }
    }
}

/// Writes the master output to a file while recording. The tap thread writes, the main
/// thread opens and closes.
final class Recorder: @unchecked Sendable {
    private let file = OSAllocatedUnfairLock<AVAudioFile?>(uncheckedState: nil)

    func open(_ f: AVAudioFile) { file.withLockUnchecked { $0 = f } }
    func close() { file.withLockUnchecked { $0 = nil } }

    func write(_ buffer: AVAudioPCMBuffer) {
        file.withLockUnchecked { try? $0?.write(from: buffer) }
    }
}
