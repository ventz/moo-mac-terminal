# Developing & Releasing Moo Terminal

Everything needed to build, sign, notarize and ship a release. Written so
someone with no prior context — or you, a year from now — can repeat it.

- [Build Prerequisites](#build-prerequisites)
- [Building](#building)
- [Why Signing Matters](#why-signing-matters)
- [One-Time Setup: Developer ID Certificate](#one-time-setup-developer-id-certificate)
- [One-Time Setup: Notarization Credentials](#one-time-setup-notarization-credentials)
- [Signing a Build](#signing-a-build)
- [Notarizing and Stapling](#notarizing-and-stapling)
- [In-App Updates](#in-app-updates)
- [Cutting a Release](#cutting-a-release)
- [Tracking Upstream](#tracking-upstream)
- [Troubleshooting](#troubleshooting)

---

## Build Prerequisites

- macOS 15+, Xcode 26+
- **Metal Toolchain** — a separate download, not part of a stock Xcode install:

```bash
xcodebuild -downloadComponent MetalToolchain    # one time, ~688 MB
```

The terminal engine compiles a Metal shader. Without the toolchain the build
fails ~90% of the way through with `cannot execute tool 'metal'`, which reads
like a source error but is not.

## Building

```bash
# Debug
xcodebuild build -project Moo.xcodeproj -scheme Moo \
  -configuration Debug -destination "platform=macOS" \
  -skipPackagePluginValidation -derivedDataPath build/DerivedData

# Release (universal: x86_64 + arm64)
xcodebuild build -project Moo.xcodeproj -scheme Moo \
  -configuration Release -destination "generic/platform=macOS" \
  -skipPackagePluginValidation -derivedDataPath build/DerivedDataRelease

# Tests
xcodebuild test -project Moo.xcodeproj -scheme Moo \
  -configuration Debug -destination "platform=macOS" \
  -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO \
  -derivedDataPath build/DerivedDataTest
```

`-skipPackagePluginValidation` is required — SwiftTerm ships a build-tool plugin.
Debug builds are arm64-only (`ONLY_ACTIVE_ARCH=YES`); Release is universal.

## Why Signing Matters

macOS applies three separate checks. Understanding which is which saves hours:

| Check | Question | Fails as |
|---|---|---|
| **Code signature** | Is the bundle intact and signed? | *"damaged and can't be opened"* |
| **Notarization** | Has Apple scanned this build? | *"Apple cannot check it for malicious software"* |
| **Library validation** | Do app and frameworks share a Team ID? | dyld crash on launch |

They are independent. `codesign --verify` passing tells you nothing about
whether the app will launch or whether Gatekeeper will accept it.

**Certificate types are not interchangeable.** They come from different
certificate authorities, and Gatekeeper's distribution policy is anchored on
one specific chain:

| Certificate | Issuer | Valid | Use |
|---|---|---|---|
| Apple Development | Apple WWDR CA | 1 year | Xcode ⌘R on your own Mac |
| **Developer ID Application** | **Developer ID CA** | **5 years** | **DMGs anyone can open** |
| Apple Distribution | Apple WWDR CA | 1 year | Mac App Store |

A development certificate can sign, but no amount of re-signing makes it
acceptable for distribution — it is issued by a CA Gatekeeper does not trust
for that purpose. Only *Developer ID Application* works, and only a **paid**
Apple Developer Program membership can issue one.

## One-Time Setup: Developer ID Certificate

### 1. Generate a Certificate Signing Request

Keychain Access → **Certificate Assistant** → *Request a Certificate From a
Certificate Authority*:

- **User Email Address**: your email
- **Common Name**: anything — **Apple discards this field**
- **Request is**: *Saved to disk*

> **The CSR's Common Name is ignored.** Apple issues the certificate with the
> legal name on the developer account, formatted as
> `Developer ID Application: <Account Name> (<TEAM_ID>)`. If that name is wrong,
> only Apple Developer Support can change it — do that *before* creating the
> certificate, because fixing it afterward means revoking and reissuing against
> a limited quota.

### 2. Request the certificate

<https://developer.apple.com/account/resources/certificates/add>

- Under **Software**, choose **Developer ID Application**
- **Profile Type**: *G2 Sub-CA (Xcode 11.4.1 or later)*
- Upload the `.certSigningRequest`, download the resulting `.cer`

### 3. Install and verify

```bash
security import ~/Downloads/developerID_application.cer -k ~/Library/Keychains/login.keychain-db
security find-identity -v -p codesigning | grep "Developer ID Application"
```

An identity only appears once the certificate is paired with the private key
the CSR was generated from. If it does not appear, the key is missing.

### 4. Back up the private key immediately

> Apple caps how many Developer ID certificates an account may hold and
> **cannot reissue a lost private key**. Lose it and the only path forward is
> revoking the certificate and issuing a new one against that quota. This is
> the single irreversible step in the whole process — do it before anything
> else.

The private key lives in the login keychain and can only be exported through
the Keychain Access GUI; there is no scriptable path that avoids interactive
prompts.

**1. Open Keychain Access** (`open -a "Keychain Access"`).

**2. Set both sidebar selections:**
- Keychains section → **login**
- Category section → **My Certificates**

*"My Certificates" is the one that matters.* That category lists only
certificates that have a matching private key. If the certificate appears
there, the export will include the key. The plain "Certificates" category also
lists key-less certificates, and exporting from it produces a file that looks
correct and is worthless.

**3. Search** for `Developer ID` and find the row:
`Developer ID Application: <Account Name> (<TEAM_ID>)`. Do not confuse it with
`Apple Development:` or `Mac Developer:`.

**4. Click the disclosure triangle** at the left of that row. A child row with
a key icon appears — that is the private key.

> No triangle means no private key attached. Stop: exporting would produce a
> useless file. Confirm with `security find-identity -v -p codesigning` — if the
> certificate is not listed as an identity, the key is genuinely missing.

**5. Select both rows**: click the certificate, then ⌘-click the key.

**6. Right-click → "Export 2 items…"**. If the menu says *1 item*, only one row
is selected; go back to step 5.

**7. Save** as Personal Information Exchange (`.p12`). Keychain Access defaults
the filename to `Certificates.p12` — rename it to something meaningful, e.g.
`DeveloperID.p12`. (⌘⇧G jumps to a typed path in the save dialog.)

**8. Two different password prompts, in order:**

| Prompt | What it wants |
|---|---|
| *"Enter a password which will be used to protect the exported items"* | **A new password you invent** — this encrypts the `.p12`. Generate it in the password manager and paste it |
| *"Keychain Access wants to export a key…"* | **Your macOS login password**, authorizing the export |

**9. Store the file and its password together** in a password manager. Either
alone is useless.

**10. Verify it actually contains the key** — a cert-only `.p12` is
indistinguishable from the outside:

```bash
openssl pkcs12 -info -in DeveloperID.p12 -noout
```

Enter the `.p12` password when prompted. The output must mention both
`Certificate bag` and **`Shrouded Keybag`**. If `Shrouded Keybag` is absent,
the key was not exported — redo from step 2, making sure the category is
**My Certificates** and that *two* items were selected.

`-noout` matters: without it the command prints the decrypted private key to
the terminal.

> **OpenSSL 3.x cannot read a Keychain Access `.p12` by default.** It fails with
> `Error outputting keys and certificates` and
> `unsupported ... Algorithm (RC2-40-CBC)`. That is not a bad password and not a
> corrupt file — OpenSSL 3 dropped RC2 from its default provider, and Keychain
> Access still uses `pbeWithSHA1And40BitRC2-CBC` for the certificate bag. If the
> output shows a `MAC:` line first, the password was already accepted.
>
> Use macOS's own LibreSSL, which still supports it:
> ```bash
> /usr/bin/openssl pkcs12 -info -in DeveloperID.p12 -noout
> ```
> or force the legacy provider: `openssl pkcs12 ... -legacy`.
>
> The weak RC2 cipher protects only the certificate bag, which is public data.
> The private key sits in a separate shrouded key bag. The export password and
> where the file is stored are what actually protect it.

As a rough sanity check, a cert-plus-key export runs around 3 KB; a cert-only
export is closer to 1.5 KB. Size is a hint, not proof — run the check above.

### 5. Restoring on another machine

```bash
security import DeveloperID.p12 -k ~/Library/Keychains/login.keychain-db
security find-identity -v -p codesigning | grep "Developer ID Application"
```

The identity appears only if the `.p12` carried the private key — which is the
same thing step 10 verifies, and the reason to verify now rather than during an
emergency.

## One-Time Setup: Notarization Credentials

Signing proves who built it; notarization proves Apple scanned it. Gatekeeper
requires both.

<https://appstoreconnect.apple.com/access/integrations/api> → **Team Keys** tab

- **Team Keys**, not Individual Keys — only team keys have the Issuer ID that
  `notarytool` needs
- **Access: Developer** is sufficient; do not grant Admin
- Download the `.p8` — **downloadable exactly once, ever**
- Copy the **Key ID** (in the key's row) and the **Issuer ID** (a UUID shown
  *above* the table, easy to miss)

```bash
mkdir -p ~/.appstoreconnect/private_keys
mv ~/Downloads/AuthKey_<KEY_ID>.p8 ~/.appstoreconnect/private_keys/
chmod 600 ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8

xcrun notarytool store-credentials "moo-notary" \
  --key ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8 \
  --key-id <KEY_ID> \
  --issuer <ISSUER_ID>
```

This validates against Apple and stores the profile in the login keychain, so
later commands need only `--keychain-profile "moo-notary"`.

## Signing a Build

Sign **inside-out**: nested code first, the app bundle last. Signing the outer
bundle first invalidates as soon as anything inside changes.

```bash
IDENTITY="Developer ID Application: <Account Name> (<TEAM_ID>)"
APP=build/DerivedDataRelease/Build/Products/Release/Moo.app

# 1. Every standalone Mach-O executable inside Frameworks.
#    Not just bundles -- see the warning below.
find "$APP/Contents/Frameworks" -type f -perm +111 | while read -r f; do
  file "$f" | grep -q "Mach-O" && \
    codesign --force --sign "$IDENTITY" -o runtime --timestamp "$f"
done

# 2. Nested bundles (.xpc, .app), deepest path first.
find "$APP/Contents/Frameworks" \( -name "*.xpc" -o -name "*.app" \) | sort -r \
  | while read -r p; do codesign --force --sign "$IDENTITY" -o runtime --timestamp "$p"; done

# 3. Framework version directories.
for v in "$APP/Contents/Frameworks/"*.framework/Versions/[A-Z]; do
  codesign --force --sign "$IDENTITY" -o runtime --timestamp "$v"
done

# 4. The app last.
codesign --force --sign "$IDENTITY" -o runtime --timestamp "$APP"

codesign --verify --deep --strict --verbose=2 "$APP"
```

> **Signing a framework does not sign standalone executables inside it.**
> Sparkle ships `Versions/B/Autoupdate`, a bare Mach-O that is neither a bundle
> nor the framework's main binary. Matching only `*.xpc` and `*.app` leaves it
> ad-hoc signed, `codesign --verify --deep --strict` still passes, and
> notarization fails with *"The binary is not signed with a valid Developer ID
> certificate"* and *"The signature does not include a secure timestamp"* for
> that path. Step 1 above exists to catch it. Audit before submitting:
>
> ```bash
> find "$APP/Contents/Frameworks" -type f -perm +111 | while read -r f; do
>   file "$f" | grep -q Mach-O || continue
>   codesign -dvv "$f" 2>&1 | grep -q "Authority=Developer ID Application" \
>     || echo "UNSIGNED: $f"
> done
> ```

Three details that are not optional:

- **`-o runtime`** enables the hardened runtime. Notarization rejects builds
  without it.
- **`--timestamp`** requests a secure timestamp from Apple. Notarization
  rejects builds without one. (`--timestamp=none` is for local ad-hoc only.)
- **No entitlements.** In particular `com.apple.security.get-task-allow` is a
  debugging entitlement and notarization **rejects any submission carrying it**.
  A Developer ID build ships with none.

## Notarizing and Stapling

```bash
scripts/create-dmg.sh "$APP" ~/Desktop/Moo.dmg "Moo"

xcrun notarytool submit ~/Desktop/Moo.dmg --keychain-profile "moo-notary" --wait
xcrun stapler staple ~/Desktop/Moo.dmg

# The real test — not codesign --verify
spctl --assess --type open --context context:primary-signature -vv ~/Desktop/Moo.dmg
```

**`accepted` is the finish line.** Anything else means recipients see a
warning.

Stapling attaches the notarization ticket to the DMG so it validates offline.
Skipping it means a first launch without network access fails.

If notarization is rejected, the log says exactly why:

```bash
xcrun notarytool log <submission-id> --keychain-profile "moo-notary"
```

## In-App Updates

Apple ships no update mechanism for apps distributed outside the Mac App
Store. Notarization is a *trust* check, not a delivery channel. Moo therefore
updates itself through **Sparkle**, which has been linked and wired since the
fork began (`Moo/UpdateCommands.swift`); what turned it on was publishing a
feed.

### How the switch works

`UpdatePolicy.permitsUpdates` refuses to start the updater unless `SUFeedURL`
is present in `Info.plist`, and refuses again for a `.debug` bundle
identifier or a bundle named "Moo Debug". A Debug build never checks for
updates, whatever the feed says.

The feed absence was the original off switch, chosen so the fork could never
inherit upstream's appcast and install Tecolot over Moo. Now that Moo has its
own feed, that reasoning still holds: **the feed URL must stay ours.**

### The pieces

| Piece | Where it lives | Public? |
|---|---|---|
| `SUFeedURL` | `Moo/Info.plist` → `https://moo.vpetkov.net/appcast.xml` | yes, it ships in the app |
| `SUPublicEDKey` | `Moo/Info.plist` | yes — it is the *public* half |
| Sparkle EdDSA **private** key | login keychain, item "Private key for signing Sparkle updates" | **no, never** |
| `appcast.xml` + DMGs | Cloudflare R2 bucket `moo-mac-terminal-autoupdate`, served at `moo.vpetkov.net` | yes |
| Past release archives | `~/moo-releases` (override with `MOO_RELEASE_DIR`) | local |

Two independent signatures protect an update, and both are required:

- The **Developer ID signature plus notarization** is what lets the downloaded
  app launch at all.
- The **EdDSA signature** in the appcast is what proves Sparkle downloaded the
  archive you actually published, and not something substituted in transit.

### Back up the Sparkle private key

Sparkle validates every update against `SUPublicEDKey`, which is baked into
every copy already installed. Lose the private key and no future build can
satisfy those copies — you cannot issue a new key pair without shipping a new
`SUPublicEDKey`, which only reaches users through an update you can no longer
sign. Every installed Moo would be stranded on its current version.

Export it once, into a password manager, alongside the Developer ID `.p12`:

```bash
# Sparkle's own tool, from the resolved package checkout
"$(find build -name generate_keys -path '*Sparkle/bin*' | head -1)" -x sparkle-private-key.txt
```

Store the file and delete the local copy. It is a secret in the same class as
the Developer ID private key — **never** in the repo, never in a release.

### The build number is what Sparkle compares

Sparkle orders releases by `CFBundleVersion` (`CURRENT_PROJECT_VERSION`), not
by the marketing version. It must increase on every published release or
installed copies will never see the new build. `MARKETING_VERSION` is only
what the updater displays.

### One-time setup on a new machine

```bash
npx wrangler@latest login                    # publishes to R2
security import sparkle-private-key.txt ...  # or re-import via generate_keys -f
```

## Cutting a Release

`scripts/release.sh` runs the whole chain — build, sign inside-out, package,
notarize, staple, generate the appcast and publish it to R2 — and refuses to
start if any credential is missing:

```bash
# 1. Bump MARKETING_VERSION and CURRENT_PROJECT_VERSION in the project, commit
# 2. Cut it
scripts/release.sh --notes notes.md

# Build and package only, publishing nothing
scripts/release.sh --dry-run
```

It publishes two objects: `Moo-<VERSION>.dmg` and `appcast.xml`, the feed
last, so nothing is ever advertised before it is downloadable. Installed
copies pick the update up on their next check; `Moo → Check for Updates…`
forces one.

Tag the release afterwards:

```bash
git tag -a v<VERSION> -m "Moo Terminal v<VERSION>"
git push origin v<VERSION>
```

Everything the script does by hand is documented above, step by step — read
[Signing a Build](#signing-a-build) and [Notarizing and
Stapling](#notarizing-and-stapling) before changing it.

**Both Apple tools are invoked by their real paths**
(`$(xcode-select -p)/usr/bin/…`) rather than through `xcrun`, which refuses to
launch anything until `sudo xcodebuild -license accept` has been run. Through
`xcrun`, a machine that has never accepted the license notarizes fine and then
fails at stapling, at the very end of a long release.

If a release is ever published **without** notarization, say so plainly in the
notes and give recipients the workaround, because the error message blames the
download rather than the signature:

```bash
xattr -dr com.apple.quarantine /Applications/Moo.app
```

## Tracking Upstream

Moo is a fork of [Tecolot](https://github.com/migueldeicaza/Tecolot). Keep the
`upstream` remote and pull from it periodically:

```bash
git fetch upstream
git log --oneline HEAD..upstream/main
git merge upstream/main            # or cherry-pick individual commits
```

Expect conflicts where the fork renamed things: `Moo/` vs upstream's
`Tecolot/`, `Moo.xcodeproj`, `Info.plist`, and the `MOO_*` shell-integration
variables. Resolve by keeping the fork's naming and taking upstream's logic.

**A fix that reproduces in Tecolot itself belongs upstream**, as a PR against
`migueldeicaza/Tecolot` — everyone benefits, and it shrinks the merge surface.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `cannot execute tool 'metal'` | Metal Toolchain missing | `xcodebuild -downloadComponent MetalToolchain` |
| Build fails on a package plugin | Missing flag | Add `-skipPackagePluginValidation` |
| App dies instantly at launch, `Library not loaded: @rpath/Sparkle.framework` … *"different Team IDs"* | Hardened runtime enforces library validation; ad-hoc signatures have no Team ID | Sign with a real certificate. `codesign --verify` passes anyway — verification is not a launch test |
| *"Moo.app is damaged"* on another Mac | Not signed with Developer ID | Sign properly, or `xattr -dr com.apple.quarantine` |
| *"Apple cannot check it for malicious software"* | Signed but not notarized | Notarize and staple |
| `spctl: rejected`, `origin=Apple Development…` | Wrong certificate type | Use Developer ID Application |
| Notarization rejected, `get-task-allow` in the log | Debug entitlement present | Sign with no entitlements |
| Notarization rejected, timestamp error | `--timestamp` omitted | Re-sign with `--timestamp` |
| Notarization rejected naming a binary inside a framework (e.g. `Sparkle.framework/.../Autoupdate`) | Signing the framework does not sign standalone executables nested in it | Sign every Mach-O individually first — see step 1 of Signing a Build |
| `security find-identity` does not list the certificate | Private key missing | Import the `.p12`, or regenerate the CSR and request a new certificate |
| `openssl pkcs12` fails with `unsupported ... RC2-40-CBC` | OpenSSL 3.x dropped RC2; Keychain Access still uses it | Use `/usr/bin/openssl` (LibreSSL) or add `-legacy`. The password was fine |
| Password prompt returns `Can't read Password` | No TTY — running through a non-interactive prompt | Run it in a real terminal window |
