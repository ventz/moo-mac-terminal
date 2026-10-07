import Foundation

enum SelectionDefaults {
    /// App-wide: copy text to the clipboard as soon as it is selected with
    /// the mouse, as in iTerm2 and X11 terminals.
    ///
    /// Off by default, because it replaces whatever the clipboard held on
    /// every drag or double-click, which surprises anyone used to the Mac's
    /// select-then-⌘C.
    static let copyOnSelect = "copyOnSelect"
    static let copyOnSelectByDefault = false

    static func copiesOnSelect(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: copyOnSelect) as? Bool ?? copyOnSelectByDefault
    }
}
