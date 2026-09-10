//
//  ProjectPrompt.swift
//  Moo
//
//  Creating a project means naming the terminal you are already in. There is
//  no folder picker: a project is a label, not a location.
//

import AppKit

@MainActor
enum ProjectPrompt {
    /// A single-field name prompt. Returns nil when cancelled or left blank.
    static func askForName(
        title: String,
        message: String,
        initialValue: String = ""
    ) -> String? {
        let field = NSTextField(string: initialValue)
        field.placeholderString = "Project name"
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

}
