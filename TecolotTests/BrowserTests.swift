import Foundation
import Testing
@testable import Tecolot

final class BrowserAddressTests {
    @Test func explicitURLsLoadAsTyped() {
        #expect(BrowserSession.resolve(input: "https://example.com/a?b=1")?.absoluteString == "https://example.com/a?b=1")
        #expect(BrowserSession.resolve(input: "  http://localhost:3000/x ")?.absoluteString == "http://localhost:3000/x")
    }

    @Test func bareHostsGetAScheme() {
        #expect(BrowserSession.resolve(input: "example.com")?.absoluteString == "https://example.com")
        #expect(BrowserSession.resolve(input: "docs.example.com/guide")?.absoluteString == "https://docs.example.com/guide")
    }

    @Test func localHostsGetPlainHTTP() {
        #expect(BrowserSession.resolve(input: "localhost:3000")?.absoluteString == "http://localhost:3000")
        #expect(BrowserSession.resolve(input: "localhost")?.absoluteString == "http://localhost")
        #expect(BrowserSession.resolve(input: "127.0.0.1:8080/app")?.absoluteString == "http://127.0.0.1:8080/app")
        #expect(BrowserSession.resolve(input: "devbox:8080")?.absoluteString == "http://devbox:8080")
        #expect(BrowserSession.resolve(input: "mac.local")?.absoluteString == "http://mac.local")
    }

    @Test func everythingElseIsASearch() {
        let url = BrowserSession.resolve(input: "how do I quit vim")
        #expect(url?.host == "duckduckgo.com")
        #expect(url?.query?.contains("q=how%20do%20I%20quit%20vim") == true)
        #expect(BrowserSession.resolve(input: "swift")?.host == "duckduckgo.com")
        #expect(BrowserSession.resolve(input: "   ") == nil)
    }

    @Test func localHostClassification() {
        for host in ["localhost", "::1", "127.0.0.1", "10.0.0.5", "192.168.1.9", "172.16.0.1", "172.31.255.1", "box.local", "devbox"] {
            #expect(BrowserSession.isLocalHost(host), "\(host) should be local")
        }
        for host in ["example.com", "172.32.0.1", "172.15.0.1", "8.8.8.8", "github.com"] {
            #expect(!BrowserSession.isLocalHost(host), "\(host) should not be local")
        }
    }

    @Test func clipboardOnlyYieldsWebAddresses() {
        #expect(BrowserOpener.clipboardURL("https://example.com")?.host == "example.com")
        #expect(BrowserOpener.clipboardURL("  https://example.com\n")?.host == "example.com")
        #expect(BrowserOpener.clipboardURL("example.com") == nil)
        #expect(BrowserOpener.clipboardURL("https://a.com\nhttps://b.com") == nil)
        #expect(BrowserOpener.clipboardURL("some text") == nil)
    }
}

final class BrowserDownloadNamingTests {
    @Test func suggestedNamesAreSanitized() {
        #expect(BrowserSession.safeFilename("../../etc/passwd") == "etc-passwd")
        #expect(BrowserSession.safeFilename(".hidden") == "hidden")
        #expect(BrowserSession.safeFilename("  ") == "download")
        #expect(BrowserSession.safeFilename("report:final.pdf") == "report-final.pdf")
    }

    @Test func destinationsAreUniqueLikeFinder() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrowserDownloadNamingTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("report.pdf")

        #expect(BrowserSession.uniqueDestination(for: file) == file)
        FileManager.default.createFile(atPath: file.path, contents: Data())
        #expect(BrowserSession.uniqueDestination(for: file).lastPathComponent == "report 2.pdf")
        FileManager.default.createFile(atPath: directory.appendingPathComponent("report 2.pdf").path, contents: Data())
        #expect(BrowserSession.uniqueDestination(for: file).lastPathComponent == "report 3.pdf")
    }
}
