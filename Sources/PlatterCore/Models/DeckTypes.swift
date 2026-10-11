import Foundation

/// Which physical deck a control belongs to.
package enum DeckID: Int, CaseIterable, Identifiable {
    case a = 0
    case b = 1
    package var id: Int { rawValue }
    package var label: String { self == .a ? "A" : "B" }
}

/// How the pitch fader affects the audio. Cycles like the PITCH button on a DJ player.
package enum PitchMode: Int, CaseIterable, Identifiable {
    /// Tempo and pitch both follow the fader (turntable feel).
    case varispeed = 0
    /// Tempo follows the fader, pitch is held (key stays).
    case keyLock = 1
    /// Tempo is held, pitch follows the fader (BPM is unchanged).
    case bpmShift = 2

    package var id: Int { rawValue }
    package var label: String {
        switch self {
        case .varispeed: return "VARISPEED"
        case .keyLock: return "KEY LOCK"
        case .bpmShift: return "BPM SHIFT"
        }
    }

    package var shortLabel: String {
        switch self {
        case .varispeed: return "VAR"
        case .keyLock: return "KEY"
        case .bpmShift: return "BPM"
        }
    }

    package var next: PitchMode {
        let all = PitchMode.allCases
        return all[(rawValue + 1) % all.count]
    }
}

/// The effect on a channel.
package enum ChannelFX: String, CaseIterable {
    case off, echo, reverb

    package var label: String {
        switch self {
        case .off: return "FX OFF"
        case .echo: return "ECHO"
        case .reverb: return "REVERB"
        }
    }

    package var next: ChannelFX {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

package enum EQBand: String, CaseIterable {
    case low, mid, high
}
