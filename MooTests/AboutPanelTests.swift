import AppKit
import Testing
@testable import Moo

@MainActor
struct AboutPanelTests {
    @Test func creditsPutMooFirstAndLinkEveryAddress() throws {
        let credits = AppInfoCommands.credits
        let text = credits.string
        let moo = try #require(text.range(of: "Ventz Petkov"))
        let miguel = try #require(text.range(of: "Miguel de Icaza"))
        let nerdFonts = try #require(text.range(of: "Nerd Font"))
        #expect(moo.lowerBound < miguel.lowerBound)
        #expect(miguel.lowerBound < nerdFonts.lowerBound)
        #expect(text.contains("https://github.com/ventz\n"))

        var links = 0
        credits.enumerateAttribute(.link, in: NSRange(location: 0, length: credits.length)) { value, _, _ in
            if value != nil { links += 1 }
        }
        #expect(links == 6)
    }
}
