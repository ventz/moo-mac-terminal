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
