# CADQuickLook

A native macOS viewer for STEP, IGES, BREP, STL, and DXF files, with Finder thumbnails and interactive Quick Look previews.

## Features

- Perspective and orthographic views
- Onshape-style navigation and standard view snaps
- Automatic edge, diameter, face-area, and point-to-point measurements
- STEP assembly placement through Open CASCADE
- The same viewer and controls in the app and Quick Look

## Install

Download the latest build from [GitHub Releases](https://github.com/lflanagan/CADQuickLook/releases/latest), unzip it, and move `CADQuickLook.app` to Applications.

The app checks for updates once a day via [Sparkle](https://sparkle-project.org/) and can install them in place. Use **CADQuickLook › Check for Updates…** to check manually, or turn automatic checks off in Settings.

## Build

Requires an Apple silicon Mac, macOS 26, Xcode 26, Homebrew, and XcodeGen.

```sh
brew bundle
xcodegen generate
DEVELOPMENT_TEAM=YOUR_TEAM_ID ./script/build_and_run.sh --verify
./script/install.sh
```

Development builds link against Homebrew's Open CASCADE libraries. Release archives bundle them.

Set `DEVELOPMENT_TEAM` to sign development builds with your Apple Development certificate; it also prefixes the App Group that the app and Quick Look extensions use for shared preferences. Without it, builds are ad-hoc signed, preferences are not shared with the extensions, and macOS asks for privacy consent on every launch.

Maintainers can create a signed archive with:

```sh
SIGNING_IDENTITY="Developer ID Application: …" ./script/package_release.sh
```

### Publishing a release

1. Bump `CFBundleShortVersionString` and `CFBundleVersion` (kept equal) in `CADQuickLook/Info.plist`.
2. `SIGNING_IDENTITY="Developer ID Application: …" NOTARY_PROFILE=… ./script/package_release.sh`
3. `gh release create vX.Y.Z dist/CADQuickLook-X.Y.Z-arm64.zip --title "CADQuickLook X.Y.Z" --notes-file notes.md`
4. The `Publish Sparkle appcast` workflow signs the archive with the Ed25519 key in the `SPARKLE_PRIVATE_KEY` repository secret and uploads `appcast.xml` to the release, which the app reads from `releases/latest/download/appcast.xml`. To do the same locally with the key in your Keychain, run `./script/publish_appcast.sh vX.Y.Z`.

The Ed25519 key pair is created once with Sparkle's `generate_keys` (found under `.build/*/SourcePackages/artifacts/sparkle/Sparkle/bin/` after a build); the public half lives in `SUPublicEDKey` in `Info.plist`. Back up the private key: without it, existing installs can no longer verify updates.

Parasolid and other proprietary CAD formats require a licensed translator.

## License

MIT. Open CASCADE and bundled libraries retain their respective licenses; see [third-party notices](THIRD_PARTY_NOTICES.md).
