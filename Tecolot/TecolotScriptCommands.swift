//
//  TecolotScriptCommands.swift
//  Tecolot
//
//  AppleScript commands declared in Tecolot.sdef.
//

import AppKit

@objc(OpenTerminalScriptCommand)
final class OpenTerminalScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let directory = directParameter as? String
        WindowOpener.openWindow(spec: LaunchSpec(workingDirectory: directory))
        return nil
    }
}

@objc(OpenTerminalTabScriptCommand)
final class OpenTerminalTabScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        var spec = WindowOpener.inheritedTabSpec()
        if let directory = directParameter as? String, !directory.isEmpty {
            spec.workingDirectory = directory
        }
        WindowOpener.openTab(spec: spec)
        return nil
    }
}

@objc(PreviewMarkdownScriptCommand)
final class PreviewMarkdownScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let path = directParameter as? String, !path.isEmpty else {
            scriptErrorNumber = NSRequiredArgumentsMissingScriptError
            return nil
        }
        let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            scriptErrorNumber = NSFileNoSuchFileError
            scriptErrorString = "No file at \(url.path)"
            return nil
        }
        guard LinkRouter.isMarkdown(url.path) else {
            scriptErrorNumber = NSArgumentsWrongScriptError
            scriptErrorString = "Not a Markdown file: \(url.lastPathComponent)"
            return nil
        }
        NSApp.activate(ignoringOtherApps: true)
        if !MarkdownPreviewOpener.open(fileURL: url, from: nil) {
            scriptErrorNumber = NSInternalScriptError
            scriptErrorString = "No project is open to hold the preview"
        }
        return nil
    }
}

@objc(OpenURLScriptCommand)
final class OpenURLScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let text = directParameter as? String,
              let url = BrowserSession.resolve(input: text) else {
            scriptErrorNumber = NSRequiredArgumentsMissingScriptError
            return nil
        }
        NSApp.activate(ignoringOtherApps: true)
        if !BrowserOpener.open(url: url) {
            scriptErrorNumber = NSInternalScriptError
            scriptErrorString = "No project is open to hold the browser tab"
        }
        return nil
    }
}
