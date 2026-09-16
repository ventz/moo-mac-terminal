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
        let repo = try #require(text.range(of: "https://github.com/ventz/moo-mac-terminal"))
        let site = try #require(text.range(of: "https://moo.vpetkov.net"))
        let home = try #require(text.range(of: "https://vpetkov.net"))
        #expect(repo.lowerBound < site.lowerBound)
        #expect(site.lowerBound < home.lowerBound)

        var links = 0
        credits.enumerateAttribute(.link, in: NSRange(location: 0, length: credits.length)) { value, _, _ in
            if value != nil { links += 1 }
        }
        #expect(links == 5)
    }
}
