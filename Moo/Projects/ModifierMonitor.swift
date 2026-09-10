//
//  ModifierMonitor.swift
//  Moo
//
//  Tracks whether Command is held, so the sidebar can reveal its cmd+digit
//  badges only while they are relevant. Showing them permanently turns a
//  shortcut hint into visual noise on every row.
//

import AppKit
import Observation

@Observable
@MainActor
final class ModifierMonitor {
    static let shared = ModifierMonitor()

    private(set) var isCommandHeld = false

    @ObservationIgnored private var monitor: Any?

    private init() {
        // A local monitor is enough: the badges only matter while Moo is
        // the active app. It never consumes the event.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated {
                self?.update(event.modifierFlags)
            }
            return event
        }
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    private func update(_ flags: NSEvent.ModifierFlags) {
        let held = flags.contains(.command)
        guard held != isCommandHeld else { return }
        isCommandHeld = held
    }

    /// Resigning active leaves no flagsChanged event behind, so the badge
    /// would stay stuck on. Called when the app deactivates.
    func clear() {
        isCommandHeld = false
    }
}
