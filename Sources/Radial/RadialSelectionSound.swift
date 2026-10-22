import AppKit
import Foundation

/// Keeps repeated native drag updates quiet and limits rapid sweeps across wedges.
struct RadialSoundGate {
    private var selection: Int?
    private var lastPlayback: TimeInterval?

    mutating func shouldPlay(selection next: Int?, enabled: Bool, now: TimeInterval) -> Bool {
        guard next != selection else { return false }
        selection = next
        guard enabled, next != nil else { return false }
        if let lastPlayback, now - lastPlayback < 0.045 { return false }
        lastPlayback = now
        return true
    }
}

@MainActor
final class RadialSelectionSound {
    static let shared = RadialSelectionSound()

    private var gate = RadialSoundGate()
    private let sound: NSSound?

    private init() {
        // A locally synthesized Yuzu click; no external audio assets or file I/O.
        sound = NSSound(data: Self.clickData())
        sound?.volume = 0.35
    }

    func selectionChanged(to index: Int?) {
        guard
            gate.shouldPlay(
                selection: index, enabled: AppSettings.shared.radialSoundEnabled,
                now: ProcessInfo.processInfo.systemUptime)
        else { return }
        sound?.stop()
        sound?.play()
    }

    static func clickData() -> Data {
        let sampleRate = 44_100
        let frameCount = 1_323  // 30 ms, mono 16-bit PCM.
        let byteCount = frameCount * 2
        var data = Data()
        func append16(_ value: UInt16) {
            data.append(UInt8(value & 0xff))
            data.append(UInt8((value >> 8) & 0xff))
        }
        func append32(_ value: UInt32) {
            append16(UInt16(value & 0xffff))
            append16(UInt16((value >> 16) & 0xffff))
        }
        data.append(contentsOf: "RIFF".utf8)
        append32(UInt32(36 + byteCount))
        data.append(contentsOf: "WAVEfmt ".utf8)
        append32(16)
        append16(1)
        append16(1)
        append32(UInt32(sampleRate))
        append32(UInt32(sampleRate * 2))
        append16(2)
        append16(16)
        data.append(contentsOf: "data".utf8)
        append32(UInt32(byteCount))
        for frame in 0..<frameCount {
            let time = Double(frame) / Double(sampleRate)
            let attack = min(1, time / 0.0015)
            let release = min(1, Double(frameCount - 1 - frame) / 100)
            let envelope = attack * release * exp(-time * 190)
            let tone = sin(2 * .pi * 1_180 * time) + 0.22 * sin(2 * .pi * 2_360 * time)
            let sample = Int16(tone * envelope * 14_000)
            append16(UInt16(bitPattern: sample))
        }
        return data
    }
}
