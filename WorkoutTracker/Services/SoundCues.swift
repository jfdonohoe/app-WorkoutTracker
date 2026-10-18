//
//  SoundCues.swift
//  WorkoutTracker
//
//  Timer audio cues:
//   • lowBeep / highBeep — the "raceway" countdown tones (short low beeps,
//     then one longer high beep). Synthesised sine tones, so there are no
//     audio assets to ship.
//   • endChime — the two-tone completion chime (system sound 1322), played
//     in the last second of a guided work timer. A rest ends on highBeep.
//
//  The audio session is `.ambient` + mix-with-others: cues play over the
//  user's music and, like the system chime, respect the silent switch.
//  Cues only play while the app is in the foreground; a backgrounded timer
//  relies on its local notification instead.
//

import Foundation
import AVFoundation
import AudioToolbox
import UIKit

@MainActor
final class SoundCues {
    static let shared = SoundCues()

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format: AVAudioFormat
    private lazy var lowBuffer = tone(frequency: 440, duration: 0.18)
    private lazy var highBuffer = tone(frequency: 880, duration: 0.5)

    private init() {
        format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    func lowBeep() {
        play(lowBuffer)
        haptic(.light)
    }

    func highBeep() {
        play(highBuffer)
        haptic(.heavy)
    }

    /// The existing two-tone "timer ended" chime.
    func endChime() {
        if WorkoutSettings.timerSounds { AudioServicesPlaySystemSound(1322) }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    // MARK: - Playback

    /// Silent when Settings ▸ Timer sounds is off (the haptics still play).
    private func play(_ buffer: AVAudioPCMBuffer?) {
        guard WorkoutSettings.timerSounds, let buffer, ensureRunning() else { return }
        player.scheduleBuffer(buffer, at: nil, options: .interrupts)
        player.play()   // unconditionally: isPlaying can be stale after an interruption
    }

    /// Start (or restart after an interruption / route change) the engine.
    private func ensureRunning() -> Bool {
        if engine.isRunning { return true }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.ambient, options: [.mixWithOthers])
            try session.setActive(true)
            try engine.start()
            return true
        } catch {
            return false
        }
    }

    /// A sine tone with 10 ms fades so it doesn't click.
    private func tone(frequency: Double, duration: Double) -> AVAudioPCMBuffer? {
        let sampleRate = format.sampleRate
        let frames = AVAudioFrameCount(sampleRate * duration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let data = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frames
        let total = Int(frames)
        let fade = Int(sampleRate * 0.01)
        for i in 0..<total {
            var amplitude = 0.6
            if i < fade { amplitude *= Double(i) / Double(fade) }
            if i > total - fade { amplitude *= Double(total - i) / Double(fade) }
            data[i] = Float(sin(2 * .pi * frequency * Double(i) / sampleRate) * amplitude)
        }
        return buffer
    }

    private func haptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }
}
