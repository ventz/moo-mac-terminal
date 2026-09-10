//
//  BrowserToolbar.swift
//  Moo
//
//  Back, forward, reload, the address field, a progress line and an escape
//  hatch to the default browser. The find bar drops in below on ⌘F.
//

import AppKit
import SwiftUI

struct BrowserToolbar: View {
    var session: BrowserSession

    @State private var address = ""
    @State private var findText = ""
    @FocusState private var addressFocused: Bool
    @FocusState private var findFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button { session.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!session.canGoBack)
                    .help("Back")
                Button { session.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!session.canGoForward)
                    .help("Forward")
                Button {
                    if session.isLoading { session.stop() } else { session.reload() }
                } label: {
                    Image(systemName: session.isLoading ? "xmark" : "arrow.clockwise")
                }
                .help(session.isLoading ? "Stop" : "Reload (⌘R)")

                HStack(spacing: 4) {
                    if session.url != nil {
                        Image(systemName: session.isSecure ? "lock.fill" : "lock.open")
                            .font(.system(size: 10))
                            .foregroundStyle(session.isSecure ? .secondary : Color.orange)
                    }
                    TextField("Search or enter website name", text: $address)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .focused($addressFocused)
                        .onSubmit {
                            if session.load(input: address) {
                                addressFocused = false
                                session.focusPage()
                            }
                        }
                        .onExitCommand {
                            address = session.url?.absoluteString ?? ""
                            addressFocused = false
                            session.focusPage()
                        }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .textBackgroundColor).opacity(0.6))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(addressFocused ? Color.accentColor : Color(nsColor: .separatorColor))
                )

                Button { session.openInDefaultBrowser() } label: { Image(systemName: "safari") }
                    .disabled(session.url == nil)
                    .help("Open in the default browser")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)

            if session.isLoading {
                ProgressView(value: session.progress)
                    .progressViewStyle(.linear)
                    .frame(height: 2)
                    .padding(.horizontal, 8)
            }

            if session.isFindVisible {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Find in page", text: $findText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .focused($findFocused)
                        .onSubmit {
                            session.find(findText, backwards: NSEvent.modifierFlags.contains(.shift))
                        }
                        .onChange(of: findText) { _, text in
                            session.find(text)
                        }
                        .onExitCommand { session.hideFind() }
                    Button { session.find(findText, backwards: true) } label: { Image(systemName: "chevron.up") }
                        .help("Previous (⇧⌘G)")
                    Button { session.find(findText) } label: { Image(systemName: "chevron.down") }
                        .help("Next (⌘G)")
                    Button("Done") { session.hideFind() }
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 8)
                .padding(.bottom, 5)
            }

            if let error = session.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .background(.bar)
        .onAppear { address = session.url?.absoluteString ?? "" }
        // The field shows where the page actually is, except while the user
        // is typing something else into it.
        .onChange(of: session.url) { _, url in
            if !addressFocused { address = url?.absoluteString ?? "" }
        }
        .onChange(of: session.addressFocusRequest) {
            addressFocused = true
        }
        .onChange(of: session.findRequest) {
            findFocused = true
        }
    }
}
