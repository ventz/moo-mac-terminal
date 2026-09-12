//
//  AttentionAlerts.swift
//  Moo
//
//  What Moo does, beyond listing it, when a pane asks for the user — and the
//  settings that choose which of those it uses. AttentionCenter always
//  records the entry; everything here is optional.
//
//    Visual   system banner, menu bar icon, Dock badge, Dock bounce, and the
//             "waiting" marks on tabs and project rows
//    Audio    a sound, and the message spoken aloud
//
//  None of it fires for the pane the user is already looking at: that
//  notification is dropped before it is recorded.
//

import AppKit
import AVFoundation
import Foundation

enum AttentionDefaults {
    static let showsBanners = "attentionShowsBanners"
    static let showsStatusItem = "attentionShowsStatusItem"
    static let showsDockBadge = "attentionShowsDockBadge"
    static let dockBounce = "attentionDockBounce"
    static let marksWaiting = "attentionMarksWaiting"
    static let sound = "attentionSound"
    static let soundVolume = "attentionSoundVolume"
    static let audioTiming = "attentionAudioTiming"
    static let speaksMessage = "attentionSpeaksMessage"

    static var bannersEnabled: Bool { bool(showsBanners, default: true) }
    static var statusItemEnabled: Bool { bool(showsStatusItem, default: true) }
    static var dockBadgeEnabled: Bool { bool(showsDockBadge, default: true) }
    static var marksWaitingEnabled: Bool { bool(marksWaiting, default: true) }

    private static func bool(_ key: String, default value: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? value
    }
}

/// Bouncing the Dock icon. macOS ignores the request while Moo is active.
enum AttentionDockBounce: String, CaseIterable, Identifiable {
    case off
    case once
    case untilActive

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "Off"
        case .once: return "Once"
        case .untilActive: return "Until Moo is active"
        }
    }
}

/// When the sound and speech play.
enum AttentionAudioTiming: String, CaseIterable, Identifiable {
    case always
    case inBackground

    var id: String { rawValue }

    var title: String {
        switch self {
        case .always: return "Always"
        case .inBackground: return "Only when Moo is in the background"
        }
    }
}

/// The alert settings, read from defaults once per alert. The defaults here
/// must match the `@AppStorage` defaults in NotificationsSettingsView.
struct AttentionAlertSettings: Equatable {
    static let noSound = ""
    static let defaultSound = "Glass"

    var dockBounce: AttentionDockBounce = .once
    var sound: String = defaultSound
    var volume: Double = 1
    var audioTiming: AttentionAudioTiming = .always
    var speaksMessage = false

    init() {}

    init(defaults: UserDefaults) {
        if let raw = defaults.string(forKey: AttentionDefaults.dockBounce),
           let bounce = AttentionDockBounce(rawValue: raw) {
            dockBounce = bounce
        }
        if let name = defaults.string(forKey: AttentionDefaults.sound) {
            sound = name
        }
        if defaults.object(forKey: AttentionDefaults.soundVolume) != nil {
            volume = min(max(defaults.double(forKey: AttentionDefaults.soundVolume), 0), 1)
        }
        if let raw = defaults.string(forKey: AttentionDefaults.audioTiming),
           let timing = AttentionAudioTiming(rawValue: raw) {
            audioTiming = timing
        }
        speaksMessage = defaults.object(forKey: AttentionDefaults.speaksMessage) as? Bool ?? false
    }

    var playsSound: Bool { !sound.isEmpty }

    func playsAudio(appIsActive: Bool) -> Bool {
        audioTiming == .always || !appIsActive
    }

    /// "home: Claude is waiting for your input". The project name only: the
    /// tab part of the location is often an agent's spinner title, which
    /// reads badly aloud.
    static func spokenText(for item: AttentionItem) -> String {
        let project = item.location.components(separatedBy: " › ").first ?? ""
        let message = item.body.isEmpty ? item.title : item.body
        return project.isEmpty ? message : "\(project): \(message)"
    }

    /// The sounds macOS ships plus any the user installed, by name — the
    /// names `NSSound(named:)` resolves.
    static func availableSounds() -> [String] {
        let fileManager = FileManager.default
        var directories = [
            URL(fileURLWithPath: "/System/Library/Sounds"),
            URL(fileURLWithPath: "/Library/Sounds")
        ]
        if let library = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first {
            directories.append(library.appendingPathComponent("Sounds"))
        }
        let audioExtensions: Set<String> = ["aiff", "aif", "caf", "wav", "mp3", "m4a"]
        var names = Set<String>()
        for directory in directories {
            guard let files = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ) else { continue }
            for file in files where audioExtensions.contains(file.pathExtension.lowercased()) {
                names.insert(file.deletingPathExtension().lastPathComponent)
            }
        }
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

/// Plays the Dock bounce, sound and speech for a new entry.
final class AttentionAlerts {
    static let shared = AttentionAlerts()

    /// Several panes asking at once should not play a chord, or talk over
    /// each other.
    static let audioInterval: TimeInterval = 2

    private var lastAudio = Date.distantPast
    private let speech = AVSpeechSynthesizer()
    /// Held so a playing sound is not deallocated mid-play.
    private var sound: NSSound?

    /// `isTest` is Settings' test button: audio plays even though Moo is
    /// frontmost, and the throttle is skipped.
    func alert(for item: AttentionItem, isTest: Bool = false) {
        let settings = AttentionAlertSettings(defaults: .standard)
        bounce(settings.dockBounce)

        let now = Date()
        guard isTest || settings.playsAudio(appIsActive: NSApp.isActive),
              isTest || now.timeIntervalSince(lastAudio) >= Self.audioInterval else {
            return
        }
        lastAudio = now
        if settings.playsSound {
            play(settings.sound, volume: settings.volume)
        }
        if settings.speaksMessage {
            // After the sound, not over it.
            let text = AttentionAlertSettings.spokenText(for: item)
            let delay = settings.playsSound ? 0.7 : 0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.speak(text, interrupting: isTest)
            }
        }
    }

    func play(_ name: String, volume: Double) {
        guard !name.isEmpty,
              let sound = NSSound(named: NSSound.Name(name))?.copy() as? NSSound else {
            return
        }
        self.sound?.stop()
        sound.volume = Float(min(max(volume, 0), 1))
        sound.play()
        self.sound = sound
    }

    private func bounce(_ bounce: AttentionDockBounce) {
        switch bounce {
        case .off: return
        case .once: NSApp.requestUserAttention(.informationalRequest)
        case .untilActive: NSApp.requestUserAttention(.criticalRequest)
        }
    }

    private func speak(_ text: String, interrupting: Bool) {
        if speech.isSpeaking {
            guard interrupting else { return }
            speech.stopSpeaking(at: .immediate)
        }
        speech.speak(AVSpeechUtterance(string: text))
    }
}
